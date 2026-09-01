--!strict
--!native
--!optimize 2

--[[
	Value decoder.

	Mirrors Encoder exactly. The id counters must advance in the same order on
	both sides -- tables are registered the moment their tag is read, before
	their contents are filled, which is what lets a TABLE_REF inside a table
	resolve to the table currently being built.

	Every read goes through Reader, so a truncated or malformed packet raises a
	Zzzz error rather than reading past the end of the buffer.
]]

local Tags = require(script.Parent.Tags)
local Reader = require(script.Parent.Reader)
local CFrameCodec = require(script.Parent.Types.CFrameCodec)
local Enums = require(script.Parent.Types.Enums)
local Instances = require(script.Parent.Types.Instances)
local Quantize = require(script.Parent.Types.Quantize)

local Decoder = {}

local KEY_BIT = Tags.KEY_BIT
local TAG_MASK = Tags.TAG_MASK
local SMALL_INT_BASE = Tags.SMALL_INT_BASE
local SMALL_INT_MAX = Tags.SMALL_INT_MAX

local ID_TO_ROTATION = CFrameCodec.ID_TO_ROTATION

export type Context = {
	reader: Reader.Reader,
	tables: { [number]: any },
	nextTableId: number,
	strings: { [number]: string },
	nextStringId: number,
	-- Mirrors the encoder's recently-used list, updated on every string.
	recentStrings: { string },
	instances: { Instance },
	shapes: { [number]: { any } },
	shapeHoists: { [number]: { [number]: boolean } },
	shapeTuples: { [number]: boolean },
	-- The previous new string, for front coding. Mirrors the encoder.
	lastNewString: string?,
	-- Length of the last bit-packed boolean array, mirroring the encoder.
	lastBooleanCount: number?,
	--[[
		Column plans, mirroring the encoder's. Interned per packet so arrays of
		the same shape describe their columns once.
	]]
	columnPlans: { [number]: any },
	nextColumnPlanId: number,
	enumTypes: { [number]: any },
	problems: { string },
	precision: number?,
	depth: number,
	maxDepth: number,
	maxNodes: number,
}

local DEFAULT_MAX_DEPTH = 512
local DEFAULT_MAX_NODES = 100000

function Decoder.newContext(
	reader: Reader.Reader,
	instances: { Instance }?,
	precision: number?,
	maxDepth: number?,
	maxNodes: number?
): Context
	return {
		reader = reader,
		tables = {},
		nextTableId = 0,
		strings = {},
		nextStringId = 0,
		recentStrings = {},
		instances = instances or {},
		shapes = {},
		shapeHoists = {},
		shapeTuples = {},
		lastNewString = nil,
		lastBooleanCount = nil,
		columnPlans = {},
		nextColumnPlanId = 0,
		enumTypes = {},
		problems = {},
		precision = precision,
		depth = 0,
		maxDepth = maxDepth or DEFAULT_MAX_DEPTH,
		maxNodes = maxNodes or DEFAULT_MAX_NODES,
	}
end

-- Datatype readers ----------------------------------------------------------

local datatypeReaders: { [number]: (Context) -> any } = {}

local unzigzag = Quantize.unzigzag

-- Column kinds, mirroring Encoder.
local COLUMN_PLAIN = 0
local COLUMN_BOOLEANS = 1
local COLUMN_DICTIONARY = 2
local COLUMN_BITPACKED = 3
local COLUMN_DELTA_VECTOR3 = 4
local COLUMN_DELTA_VECTOR2 = 5
local COLUMN_DELTA_CFRAME = 6
local COLUMN_DIFFERENCED = 7
local COLUMN_CORRELATED = 8
local COLUMN_SHARED_STRINGS = 9
local COLUMN_FREQUENCY = 10
local COLUMN_MAPPED = 11
local COLUMN_MULTI_MAPPED = 12
local COLUMN_DICTIONARY_FOR = 13
local COLUMN_EQUALITY = 14
local COLUMN_RUN_LENGTH = 15
local COLUMN_DECIMAL = 16
local COLUMN_OPTIONAL = 17
local COLUMN_DATE = 18
local COLUMN_PREFIXED_INT = 19
local COLUMN_DATATYPE_DICT = 20
local COLUMN_DATATYPE_SPLIT = 21
-- A column that repeats on a fixed period.
local COLUMN_CYCLIC = 22
--[[
	A column of arrays written as one block plus the lengths that split it.
	See the encoder for why: two thousand fourteen-row arrays became four
	thirty-thousand-row columns, 93,219 bytes to 72,395.
]]
local COLUMN_BATCHED = 23

--[[
	The reserved field a transposed map carries its key under.

	Spelled the same as `Columnar.TRANSPOSE_KEY_FIELD` and kept separate rather
	than imported: the decoder does not otherwise depend on the column forms,
	and one shared string is not worth the coupling. The leading NUL is what
	makes it impossible for a caller's own field to collide.
]]
local TRANSPOSE_KEY_FIELD = "\0key"
local TRANSPOSE_ITEMS_FIELD = "\0items"

--[[
	Rebuild a datatype from the components the encoder took it apart into.

	Keyed by the wire id the encoder assigned, which is fixed and append-only:
	the id is the only thing saying which constructor a column's numbers belong
	to, so these must never be renumbered.
]]
local DATATYPE_SPLIT_BUILDERS: { [number]: { arity: number, build: ({ number }) -> any } } = {
	[1] = {
		arity = 4,
		build = function(c)
			return Rect.new(c[1], c[2], c[3], c[4])
		end,
	},
	[2] = {
		arity = 2,
		build = function(c)
			return NumberRange.new(c[1], c[2])
		end,
	},
	[3] = {
		arity = 4,
		build = function(c)
			return UDim2.new(c[1], c[2], c[3], c[4])
		end,
	},
	[4] = {
		arity = 2,
		build = function(c)
			return UDim.new(c[1], c[2])
		end,
	},
	[5] = {
		arity = 3,
		build = function(c)
			return Color3.new(c[1], c[2], c[3])
		end,
	},
}

--[[
	Howard Hinnant's civil-from-days, inlined rather than imported so decoding
	stays independent of the qualifier module. The encoder holds the matching
	days-from-civil, and the pair is exact across the proleptic Gregorian
	calendar -- verified over 109,938 consecutive dates.
]]
local function civilFromDays(z: number): (number, number, number)
	local shifted = z + 719468
	local era = math.floor(shifted / 146097)
	local dayOfEra = shifted - era * 146097
	local yearOfEra = math.floor(
		(dayOfEra - math.floor(dayOfEra / 1460) + math.floor(dayOfEra / 36524) - math.floor(
			dayOfEra / 146096
		)) / 365
	)
	local year = yearOfEra + era * 400
	local dayOfYear = dayOfEra - (365 * yearOfEra + math.floor(yearOfEra / 4) - math.floor(
		yearOfEra / 100
	))
	local shiftedMonth = math.floor((5 * dayOfYear + 2) / 153)
	local day = dayOfYear - math.floor((153 * shiftedMonth + 2) / 5) + 1
	local month = if shiftedMonth < 10 then shiftedMonth + 3 else shiftedMonth - 9
	return (if month <= 2 then year + 1 else year), month, day
end

--[[
	Mirrors Columnar.MAX_SHARED_ID_BITS. A corrupt packet claiming a wider field
	would read far past the buffer.
]]
local MAX_SHARED_ID_BITS = 24

local MAX_DIFFERENCE_ORDER = 2

--[[
	Must match the encoder's cap. The unpacker accumulates the same way the
	packer does, so it inherits the same 2^53 exactness bound -- the round trip
	breaks at 47 bits, and 45 leaves a margin.
]]
local MAX_PACK_BITS = 45

--[[
	Widest id a packed dictionary index uses. Must match Columnar's own cap of
	4,095 entries: an index read at the wrong width resolves to a different
	entry, which is silent rather than an error.
]]
--[[
	The largest dictionary a packet may claim, and the width its ids pack at.

	These must match `Columnar.MAX_DICTIONARY_ENTRIES` and
	`MAX_DICTIONARY_ID_BITS` exactly. They did not: the encoder was raised from
	255 entries to 4,095 and the decoder was left at 255, so the encoder could
	produce a packet its own decoder refused -- which is what a map of forty
	arrays batched into one column did, by making a column long enough to hold
	five hundred distinct names.

	The two derive the id width identically, so the packets were always
	readable; only the guard was stale. Twelve bits is what makes 4,095 the
	bound.
]]
local MAX_DICTIONARY_ENTRIES = 4095
local MAX_DICTIONARY_ID_BITS = 12

--[[
	Widest pseudodecimal scale a delta-run column's factor byte can carry.
	Must match Columnar.decimalAxes's own cap.
]]
local MAX_DECIMAL_FACTOR = 6

--[[
	How many descriptor bytes each column kind carries in its plan.

	A plan holds only what describes the encoding. Everything a plan cannot know
	-- seeds, slopes, row payloads -- follows per array. A kind absent from this
	table is unknown and rejected before anything is read.
]]
local DESCRIPTOR_COUNTS: { [number]: number } = {
	[COLUMN_PLAIN] = 0,
	[COLUMN_BOOLEANS] = 0,
	[COLUMN_DICTIONARY] = 0,
	[COLUMN_BITPACKED] = 1,
	[COLUMN_DELTA_VECTOR3] = 0,
	[COLUMN_DELTA_VECTOR2] = 0,
	[COLUMN_DELTA_CFRAME] = 0,
	[COLUMN_DIFFERENCED] = 2,
	[COLUMN_CORRELATED] = 2,
	[COLUMN_SHARED_STRINGS] = 1,
	--[[
		The width the exception values pack at, then the width their row gaps
		pack at -- or zero when the positions travel as a bitmap instead.
	]]
	[COLUMN_FREQUENCY] = 2,
	[COLUMN_MAPPED] = 2,
	[COLUMN_MULTI_MAPPED] = 2,
	[COLUMN_DICTIONARY_FOR] = 2,
	[COLUMN_EQUALITY] = 2,
	[COLUMN_RUN_LENGTH] = 1,
	[COLUMN_DECIMAL] = 1,
	[COLUMN_OPTIONAL] = 1,
	[COLUMN_DATE] = 1,
	[COLUMN_PREFIXED_INT] = 2,
	[COLUMN_DATATYPE_DICT] = 0,
	-- The wire id of the type to rebuild.
	[COLUMN_DATATYPE_SPLIT] = 1,
	--[[
		The period, the bit width of the cycle's values, and a flag saying
		whether the cycle was found in the column's differences rather than its
		values. Three bytes describe the encoding; the cycle itself, the low
		value it packs against and any exceptions are data and travel per array.
	]]
	[COLUMN_CYCLIC] = 3,
	--[[
		No descriptors: the length width is data rather than plan, because it
		depends on the longest array this particular column holds.
	]]
	[COLUMN_BATCHED] = 0,
}

--[[
	Build a value through a constructor that validates its arguments.

	Roblox constructors raise their own errors -- "NumberRange: invalid range",
	"ColorSequence: color value out of range", DateTime range failures -- and a
	corrupted packet reaches them with arbitrary numbers. Left alone those
	propagate as raw engine errors naming this module's internal line numbers,
	so a caller cannot tell a bad packet from a bug in Zzzz. Re-raised here as
	a Zzzz error, which is what every other decode failure looks like.
]]
local function construct<T>(what: string, constructor: (...any) -> T, ...: any): T
	local ok, result = pcall(constructor, ...)
	if not ok then
		error(`Zzzz: packet holds an invalid {what} ({tostring(result)})`, 0)
	end
	return result
end

datatypeReaders[Tags.VECTOR2] = function(ctx)
	local reader = ctx.reader
	return Vector2.new(Reader.f32(reader), Reader.f32(reader))
end

datatypeReaders[Tags.VECTOR3] = function(ctx)
	local reader = ctx.reader
	return Vector3.new(Reader.f32(reader), Reader.f32(reader), Reader.f32(reader))
end

-- Integral forms: whole-number components as zigzag varints.
datatypeReaders[Tags.VECTOR2_INT] = function(ctx)
	local reader = ctx.reader
	return Vector2.new(
		unzigzag(Reader.varint(reader)),
		unzigzag(Reader.varint(reader))
	)
end

datatypeReaders[Tags.VECTOR3_INT] = function(ctx)
	local reader = ctx.reader
	return Vector3.new(
		unzigzag(Reader.varint(reader)),
		unzigzag(Reader.varint(reader)),
		unzigzag(Reader.varint(reader))
	)
end

datatypeReaders[Tags.VECTOR2INT16] = function(ctx)
	local reader = ctx.reader
	return Vector2int16.new(Reader.i16(reader), Reader.i16(reader))
end

datatypeReaders[Tags.VECTOR3INT16] = function(ctx)
	local reader = ctx.reader
	return Vector3int16.new(Reader.i16(reader), Reader.i16(reader), Reader.i16(reader))
end

datatypeReaders[Tags.CFRAME_POS] = function(ctx)
	local reader = ctx.reader
	return CFrame.new(Reader.f32(reader), Reader.f32(reader), Reader.f32(reader))
end

datatypeReaders[Tags.CFRAME] = function(ctx)
	local reader = ctx.reader
	local x = Reader.f32(reader)
	local y = Reader.f32(reader)
	local z = Reader.f32(reader)
	local rotationId = Reader.u8(reader)

	if rotationId ~= 0 then
		local rotation = ID_TO_ROTATION[rotationId]
		if not rotation then
			error(`Zzzz: unknown CFrame rotation id {rotationId}`, 0)
		end
		return CFrame.new(x, y, z) * rotation
	end

	local qx, qy, qz, qw = CFrameCodec.unpackQuaternion(Reader.u32(reader))
	return CFrame.new(x, y, z, qx, qy, qz, qw)
end

datatypeReaders[Tags.CFRAME_INT] = function(ctx)
	local reader = ctx.reader
	local x = unzigzag(Reader.varint(reader))
	local y = unzigzag(Reader.varint(reader))
	local z = unzigzag(Reader.varint(reader))
	local rotationId = Reader.u8(reader)

	if rotationId ~= 0 then
		local rotation = ID_TO_ROTATION[rotationId]
		if not rotation then
			error(`Zzzz: unknown CFrame rotation id {rotationId}`, 0)
		end
		return CFrame.new(x, y, z) * rotation
	end

	local qx, qy, qz, qw = CFrameCodec.unpackQuaternion(Reader.u32(reader))
	return CFrame.new(x, y, z, qx, qy, qz, qw)
end

datatypeReaders[Tags.UDIM] = function(ctx)
	local reader = ctx.reader
	return UDim.new(Reader.f32(reader), Reader.i32(reader))
end

datatypeReaders[Tags.UDIM2] = function(ctx)
	local reader = ctx.reader
	return UDim2.new(
		Reader.f32(reader),
		Reader.i32(reader),
		Reader.f32(reader),
		Reader.i32(reader)
	)
end

-- Compact UDim family: 2-bit scale codes plus zigzag varint offsets.
local CODE_SCALES = { [0] = 0, 0.5, 1 }
local SCALE_LITERAL = 3

local function readScale(reader: Reader.Reader, code: number): number
	if code == SCALE_LITERAL then
		return Reader.f32(reader)
	end
	return CODE_SCALES[code]
end

datatypeReaders[Tags.UDIM_COMPACT] = function(ctx)
	local reader = ctx.reader
	local code = Reader.u8(reader)
	local scale = readScale(reader, code)
	return UDim.new(scale, unzigzag(Reader.varint(reader)))
end

datatypeReaders[Tags.UDIM2_COMPACT] = function(ctx)
	local reader = ctx.reader
	local codes = Reader.u8(reader)
	local xCode = codes % 4
	local yCode = (codes - xCode) / 4

	-- Literal scales appear in order, before either offset.
	local xScale = readScale(reader, xCode)
	local yScale = readScale(reader, yCode)

	local xOffset = unzigzag(Reader.varint(reader))
	local yOffset = unzigzag(Reader.varint(reader))

	return UDim2.new(xScale, xOffset, yScale, yOffset)
end

datatypeReaders[Tags.RECT] = function(ctx)
	local reader = ctx.reader
	return Rect.new(
		Reader.f32(reader),
		Reader.f32(reader),
		Reader.f32(reader),
		Reader.f32(reader)
	)
end

datatypeReaders[Tags.COLOR3] = function(ctx)
	local reader = ctx.reader
	return Color3.new(Reader.f32(reader), Reader.f32(reader), Reader.f32(reader))
end

datatypeReaders[Tags.COLOR3_U8] = function(ctx)
	local reader = ctx.reader
	return Color3.fromRGB(Reader.u8(reader), Reader.u8(reader), Reader.u8(reader))
end

datatypeReaders[Tags.BRICKCOLOR] = function(ctx)
	return construct("BrickColor", BrickColor.new, Reader.varint(ctx.reader))
end

datatypeReaders[Tags.NUMBERRANGE] = function(ctx)
	local reader = ctx.reader
	local minimum = Reader.f32(reader)
	local maximum = Reader.f32(reader)
	return construct("NumberRange", NumberRange.new, minimum, maximum)
end

datatypeReaders[Tags.NUMBERSEQUENCEKEYPOINT] = function(ctx)
	local reader = ctx.reader
	return NumberSequenceKeypoint.new(
		Reader.f32(reader),
		Reader.f32(reader),
		Reader.f32(reader)
	)
end

datatypeReaders[Tags.NUMBERSEQUENCE] = function(ctx)
	local reader = ctx.reader
	-- Three f32 per keypoint; reject a count the remaining bytes cannot hold.
	local count = Reader.count(reader, 12)
	local keypoints = table.create(count)
	for index = 1, count do
		keypoints[index] = NumberSequenceKeypoint.new(
			Reader.f32(reader),
			Reader.f32(reader),
			Reader.f32(reader)
		)
	end
	return construct("NumberSequence", NumberSequence.new, keypoints)
end

datatypeReaders[Tags.COLORSEQUENCEKEYPOINT] = function(ctx)
	local reader = ctx.reader
	local time = Reader.f32(reader)
	return ColorSequenceKeypoint.new(
		time,
		Color3.new(Reader.f32(reader), Reader.f32(reader), Reader.f32(reader))
	)
end

datatypeReaders[Tags.COLORSEQUENCE] = function(ctx)
	local reader = ctx.reader
	-- Time plus three colour channels, all f32.
	local count = Reader.count(reader, 16)
	local keypoints = table.create(count)
	for index = 1, count do
		local time = Reader.f32(reader)
		keypoints[index] = ColorSequenceKeypoint.new(
			time,
			Color3.new(Reader.f32(reader), Reader.f32(reader), Reader.f32(reader))
		)
	end
	return construct("ColorSequence", ColorSequence.new, keypoints)
end

datatypeReaders[Tags.RAY] = function(ctx)
	local reader = ctx.reader
	local origin = Vector3.new(Reader.f32(reader), Reader.f32(reader), Reader.f32(reader))
	local direction = Vector3.new(Reader.f32(reader), Reader.f32(reader), Reader.f32(reader))
	return Ray.new(origin, direction)
end

datatypeReaders[Tags.REGION3] = function(ctx)
	local reader = ctx.reader
	local min = Vector3.new(Reader.f32(reader), Reader.f32(reader), Reader.f32(reader))
	local max = Vector3.new(Reader.f32(reader), Reader.f32(reader), Reader.f32(reader))
	return Region3.new(min, max)
end

datatypeReaders[Tags.REGION3INT16] = function(ctx)
	local reader = ctx.reader
	local min = Vector3int16.new(Reader.i16(reader), Reader.i16(reader), Reader.i16(reader))
	local max = Vector3int16.new(Reader.i16(reader), Reader.i16(reader), Reader.i16(reader))
	return Region3int16.new(min, max)
end

datatypeReaders[Tags.AXES] = function(ctx)
	local bits = Reader.u8(ctx.reader)
	local axes = {}
	if bit32.band(bits, 1) ~= 0 then
		table.insert(axes, Enum.Axis.X)
	end
	if bit32.band(bits, 2) ~= 0 then
		table.insert(axes, Enum.Axis.Y)
	end
	if bit32.band(bits, 4) ~= 0 then
		table.insert(axes, Enum.Axis.Z)
	end
	return Axes.new(table.unpack(axes))
end

datatypeReaders[Tags.FACES] = function(ctx)
	local bits = Reader.u8(ctx.reader)
	local faces = {}
	if bit32.band(bits, 1) ~= 0 then
		table.insert(faces, Enum.NormalId.Top)
	end
	if bit32.band(bits, 2) ~= 0 then
		table.insert(faces, Enum.NormalId.Bottom)
	end
	if bit32.band(bits, 4) ~= 0 then
		table.insert(faces, Enum.NormalId.Left)
	end
	if bit32.band(bits, 8) ~= 0 then
		table.insert(faces, Enum.NormalId.Right)
	end
	if bit32.band(bits, 16) ~= 0 then
		table.insert(faces, Enum.NormalId.Front)
	end
	if bit32.band(bits, 32) ~= 0 then
		table.insert(faces, Enum.NormalId.Back)
	end
	return Faces.new(table.unpack(faces))
end

datatypeReaders[Tags.PHYSICALPROPERTIES] = function(ctx)
	local reader = ctx.reader
	return PhysicalProperties.new(
		Reader.f32(reader),
		Reader.f32(reader),
		Reader.f32(reader),
		Reader.f32(reader),
		Reader.f32(reader)
	)
end

datatypeReaders[Tags.DATETIME] = function(ctx)
	return construct(
		"DateTime",
		DateTime.fromUnixTimestampMillis,
		Reader.f64(ctx.reader)
	)
end

datatypeReaders[Tags.TWEENINFO] = function(ctx)
	local reader = ctx.reader
	local time = Reader.f32(reader)
	local styleValue = Reader.u8(reader)
	local directionValue = Reader.u8(reader)
	local repeatCount = Reader.i32(reader)
	local reverses = Reader.u8(reader) ~= 0
	local delayTime = Reader.f32(reader)

	local style = Enum.EasingStyle:FromValue(styleValue) or Enum.EasingStyle.Quad
	local direction = Enum.EasingDirection:FromValue(directionValue)
		or Enum.EasingDirection.Out

	return TweenInfo.new(time, style, direction, repeatCount, reverses, delayTime)
end

--[[
	The remaining datatypes, behind one tag and a sub-type byte.

	Enum values are looked up rather than trusted: a packet naming a value the
	running client does not know would otherwise produce nil where an EnumItem
	belongs, so each falls back to the default the constructor would have used.
]]
datatypeReaders[Tags.EXTRA_DATATYPE] = function(ctx)
	local reader = ctx.reader
	local kind = Reader.u8(reader)

	if kind == Tags.EXTRA_PATHWAYPOINT then
		local x = Reader.f32(reader)
		local y = Reader.f32(reader)
		local z = Reader.f32(reader)
		local actionValue = Reader.u8(reader)
		local label = Reader.string(reader)

		local action = Enum.PathWaypointAction:FromValue(actionValue)
			or Enum.PathWaypointAction.Walk
		return PathWaypoint.new(Vector3.new(x, y, z), action, label)
	end

	if kind == Tags.EXTRA_RAYCASTPARAMS then
		local filterValue = Reader.u8(reader)
		local ignoreWater = Reader.u8(reader) ~= 0
		local respectCanCollide = Reader.u8(reader) ~= 0
		local bruteForce = Reader.u8(reader) ~= 0
		local collisionGroup = Reader.string(reader)

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType:FromValue(filterValue)
			or Enum.RaycastFilterType.Exclude
		params.IgnoreWater = ignoreWater
		params.RespectCanCollide = respectCanCollide
		params.BruteForceAllSlow = bruteForce
		params.CollisionGroup = collisionGroup
		return params
	end

	if kind == Tags.EXTRA_OVERLAPPARAMS then
		local filterValue = Reader.u8(reader)
		local respectCanCollide = Reader.u8(reader) ~= 0
		local bruteForce = Reader.u8(reader) ~= 0
		local maxParts = Reader.varint(reader)
		local collisionGroup = Reader.string(reader)

		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType:FromValue(filterValue)
			or Enum.RaycastFilterType.Exclude
		params.RespectCanCollide = respectCanCollide
		params.BruteForceAllSlow = bruteForce
		params.MaxParts = maxParts
		params.CollisionGroup = collisionGroup
		return params
	end

	if kind == Tags.EXTRA_CATALOGSEARCHPARAMS then
		local keyword = Reader.string(reader)
		local minPrice = Reader.varint(reader)
		local maxPrice = Reader.varint(reader)
		local sortValue = Reader.u8(reader)
		local aggregationValue = Reader.u8(reader)
		local categoryValue = Reader.u8(reader)
		local salesValue = Reader.u8(reader)
		local includeOffSale = Reader.u8(reader) ~= 0
		local creatorName = Reader.string(reader)

		local bundleCount = Reader.count(reader, 1)
		local bundleTypes = table.create(bundleCount)
		for index = 1, bundleCount do
			bundleTypes[index] = Enum.BundleType:FromValue(Reader.u8(reader))
		end

		local assetCount = Reader.count(reader, 1)
		local assetTypes = table.create(assetCount)
		for index = 1, assetCount do
			assetTypes[index] = Enum.AvatarAssetType:FromValue(Reader.u8(reader))
		end

		local params = CatalogSearchParams.new()
		params.SearchKeyword = keyword
		params.MinPrice = minPrice
		params.MaxPrice = maxPrice
		params.SortType = Enum.CatalogSortType:FromValue(sortValue)
			or Enum.CatalogSortType.Relevance
		params.SortAggregation = Enum.CatalogSortAggregation:FromValue(aggregationValue)
			or Enum.CatalogSortAggregation.AllTime
		params.CategoryFilter = Enum.CatalogCategoryFilter:FromValue(categoryValue)
			or Enum.CatalogCategoryFilter.None
		params.SalesTypeFilter = Enum.SalesTypeFilter:FromValue(salesValue)
			or Enum.SalesTypeFilter.All
		params.IncludeOffSale = includeOffSale
		params.CreatorName = creatorName

		--[[
			An unknown enum value reads back as nil, which these setters reject,
			so a list that lost an entry is dropped rather than half-applied.
		]]
		local bundlesOk = true
		for _, item in bundleTypes do
			if item == nil then
				bundlesOk = false
				break
			end
		end
		if bundlesOk and bundleCount > 0 then
			params.BundleTypes = bundleTypes
		end

		local assetsOk = true
		for _, item in assetTypes do
			if item == nil then
				assetsOk = false
				break
			end
		end
		if assetsOk and assetCount > 0 then
			params.AssetTypes = assetTypes
		end

		return params
	end

	if kind == Tags.EXTRA_FLOATCURVEKEY or kind == Tags.EXTRA_VALUECURVEKEY then
		local time = Reader.f32(reader)
		local value = Reader.f32(reader)
		local interpolation = Enum.KeyInterpolationMode:FromValue(Reader.u8(reader))
			or Enum.KeyInterpolationMode.Linear

		if kind == Tags.EXTRA_FLOATCURVEKEY then
			return FloatCurveKey.new(time, value, interpolation)
		end
		return (ValueCurveKey :: any).new(time, value, interpolation)
	end

	if kind == Tags.EXTRA_ROTATIONCURVEKEY then
		local time = Reader.f32(reader)
		local interpolation = Enum.KeyInterpolationMode:FromValue(Reader.u8(reader))
			or Enum.KeyInterpolationMode.Linear

		local components = table.create(12)
		for index = 1, 12 do
			components[index] = Reader.f32(reader)
		end

		return RotationCurveKey.new(
			time,
			CFrame.new(
				components[1], components[2], components[3],
				components[4], components[5], components[6],
				components[7], components[8], components[9],
				components[10], components[11], components[12]
			),
			interpolation
		)
	end

	if kind == Tags.EXTRA_PATH2DCONTROLPOINT then
		local parts = table.create(3)
		for index = 1, 3 do
			local xScale = Reader.f32(reader)
			local xOffset = Reader.i32(reader)
			local yScale = Reader.f32(reader)
			local yOffset = Reader.i32(reader)
			parts[index] = UDim2.new(xScale, xOffset, yScale, yOffset)
		end
		return Path2DControlPoint.new(parts[1], parts[2], parts[3])
	end

	if kind == Tags.EXTRA_CONTENT then
		local sourceValue = Reader.u8(reader)
		local uri = Reader.string(reader)

		--[[
			Only the uri form is written, so anything else names a source this
			build cannot rebuild and the empty Content is the honest answer.
		]]
		if Enum.ContentSourceType:FromValue(sourceValue) == Enum.ContentSourceType.Uri then
			return Content.fromUri(uri)
		end
		return Content.none
	end

	error(`Zzzz: unknown extra datatype {kind}`, 0)
end

Decoder.datatypeReaders = datatypeReaders

-- Core walk -----------------------------------------------------------------

local readValue: (Context) -> any

local FOLD_STRING_MTF = Tags.FOLD_STRING_MTF
local FOLD_STRING_MTF_COUNT = Tags.FOLD_STRING_MTF_COUNT

--[[
	Mirror of the encoder's touchRecent: move `value` to the front of the
	recently-used list, dropping the oldest once the window is full.

	Both sides must run this on every string -- new ones, id references and
	folded references alike -- or the two lists drift and a folded distance
	resolves to the wrong string.
]]
local function touchRecent(recent: { string }, value: string): ()
	for index = 1, #recent do
		if recent[index] == value then
			table.remove(recent, index)
			table.insert(recent, 1, value)
			return
		end
	end

	if #recent >= FOLD_STRING_MTF_COUNT then
		table.remove(recent)
	end
	table.insert(recent, 1, value)
end

--[[
	Register a newly read string: claim its id, put it at the front of the
	recently-used list, and remember it as the base for front coding.

	Both spellings of a new string go through here, so the encoder's and the
	decoder's notion of "the previous new string" cannot drift.
]]
local function registerString(ctx: Context, value: string): string
	local id = ctx.nextStringId + 1
	ctx.nextStringId = id
	ctx.strings[id] = value
	touchRecent(ctx.recentStrings, value)
	ctx.lastNewString = value
	return value
end

local function readString(ctx: Context): string
	return registerString(ctx, Reader.string(ctx.reader))
end

--[[
	A string sharing a prefix with the previous new one: the shared length, then
	the bytes that differ.
]]
local function readPrefixedString(ctx: Context): string
	local reader = ctx.reader
	local shared = Reader.u8(reader)

	local previous = ctx.lastNewString
	if previous == nil then
		error("Zzzz: prefixed string has no previous string to extend", 0)
	end
	if shared > #previous then
		error(
			`Zzzz: prefixed string claims {shared} shared bytes of {#previous}`,
			0
		)
	end

	return registerString(ctx, string.sub(previous, 1, shared) .. Reader.string(reader))
end

--[[
	A string sharing both ends with the one before it.

	Head, tail and the middle between them. The two claims are checked against
	each other as well as against the previous string: together they may not
	exceed it, or the halves would overlap and the result would repeat bytes
	that were only stored once.
]]
local function readAffixedString(ctx: Context): string
	local reader = ctx.reader
	local shared = Reader.u8(reader)
	local tail = Reader.u8(reader)

	local previous = ctx.lastNewString
	if previous == nil then
		error("Zzzz: affixed string has no previous string to extend", 0)
	end
	if shared + tail > #previous then
		error(
			`Zzzz: affixed string claims {shared}+{tail} shared bytes of {#previous}`,
			0
		)
	end

	local middle = Reader.string(reader)
	return registerString(
		ctx,
		string.sub(previous, 1, shared)
			.. middle
			.. string.sub(previous, #previous - tail + 1)
	)
end

--[[
	Guard the recursion depth.

	MaxDepth was originally enforced only while encoding, which left the
	decoder unbounded: a hand-crafted packet of nested table tags recursed
	until Luau's own stack gave out, raising a raw "stack overflow" naming this
	module rather than a Zzzz error. It also meant a packet could decode into a
	value the very same instance then refused to re-encode.

	Every construct that recurses claims a level here and releases it after.
]]
local function enterTable(ctx: Context): number
	local depth = ctx.depth + 1
	if depth > ctx.maxDepth then
		error(`Zzzz: packet nesting exceeded {ctx.maxDepth} levels`, 0)
	end
	ctx.depth = depth
	return depth
end

--[[
	Read a struct body: the values, in the shape's key order.

	Shared by both spellings -- STRUCT with a varint id, and the folded tags that
	carry the id themselves -- so the two cannot drift apart.
]]
local function readStruct(ctx: Context, shapeId: number): any
	local depth = enterTable(ctx)

	local keys = ctx.shapes[shapeId]
	if not keys then
		error(`Zzzz: structure shape {shapeId} not defined`, 0)
	end

	local result = {}
	local id = ctx.nextTableId + 1
	ctx.nextTableId = id
	ctx.tables[id] = result

	for index = 1, #keys do
		local key = keys[index]
		local value = readValue(ctx)
		-- Same guard as the definition path: a shape reached through a
		-- corrupted id can hold keys Luau refuses.
		if key ~= nil and key == key then
			result[key] = value
		end
	end

	ctx.depth = depth - 1
	return result
end

--[[
	Read an enum type identified by global id, or by name after a zero marker.

	A packet written on a different engine build can carry a global id this
	build does not have, so an unknown id is an error rather than a silent nil.
]]
local function readEnumType(ctx: Context): any
	local globalId = Reader.varint(ctx.reader)

	if globalId ~= 0 then
		local enumType = Enums.typeFromGlobalId(globalId)
		if not enumType then
			error(
				`Zzzz: enum type id {globalId} is not known to this engine build`,
				0
			)
		end
		return enumType
	end

	local enumName = readValue(ctx)
	if type(enumName) ~= "string" then
		error("Zzzz: enum type name is not a string", 0)
	end

	local enumType = Enums.typeFromName(enumName)
	if not enumType then
		error(`Zzzz: unknown Enum type "{enumName}"`, 0)
	end
	return enumType
end

local function readTable(ctx: Context, tagByte: number): any
	local depth = enterTable(ctx)
	local reader = ctx.reader
	local result = {}

	-- Register before filling, so a TABLE_REF encountered inside this table
	-- resolves back to it. This is what makes cycles work.
	local id = ctx.nextTableId + 1
	ctx.nextTableId = id
	ctx.tables[id] = result

	-- Each entry is at least a tag byte, and each pair needs two of them.
	local arrayCount, mapCount = 0, 0
	if tagByte == Tags.ARRAY then
		arrayCount = Reader.count(reader, 1)
	elseif tagByte == Tags.MAP then
		mapCount = Reader.count(reader, 2)
	else
		arrayCount = Reader.count(reader, 1)
		mapCount = Reader.count(reader, 2)
	end

	for index = 1, arrayCount do
		result[index] = readValue(ctx)
	end

	for _ = 1, mapCount do
		local key = readValue(ctx)
		local value = readValue(ctx)
		-- Luau refuses nil and NaN as table keys, and a corrupted packet can
		-- decode either. Both are dropped rather than allowed to raise.
		if key ~= nil and key == key then
			result[key] = value
		end
	end

	ctx.depth = depth - 1
	return result
end

function readValue(ctx: Context): any
	local raw = Reader.u8(ctx.reader)
	local tagByte = bit32.band(raw, TAG_MASK)

	-- Folded small integers.
	if tagByte >= SMALL_INT_BASE and tagByte <= SMALL_INT_BASE + SMALL_INT_MAX then
		return tagByte - SMALL_INT_BASE
	end

	if tagByte == Tags.NIL then
		return nil
	end
	if tagByte == Tags.FALSE then
		return false
	end
	if tagByte == Tags.TRUE then
		return true
	end
	if tagByte == Tags.EMPTY_STRING then
		return ""
	end

	if tagByte == Tags.EMPTY_TABLE then
		local result = {}
		local id = ctx.nextTableId + 1
		ctx.nextTableId = id
		ctx.tables[id] = result
		return result
	end

	if tagByte == Tags.NAN then
		return 0 / 0
	end
	if tagByte == Tags.INF then
		return math.huge
	end
	if tagByte == Tags.NEG_INF then
		return -math.huge
	end
	if tagByte == Tags.NEG_ZERO then
		return -0
	end

	local reader = ctx.reader

	if tagByte == Tags.U8 then
		return Reader.u8(reader)
	end
	if tagByte == Tags.U16 then
		return Reader.u16(reader)
	end
	if tagByte == Tags.U32 then
		return Reader.u32(reader)
	end
	if tagByte == Tags.I8 then
		return Reader.i8(reader)
	end
	if tagByte == Tags.I16 then
		return Reader.i16(reader)
	end
	if tagByte == Tags.I32 then
		return Reader.i32(reader)
	end
	if tagByte == Tags.F32 then
		return Reader.f32(reader)
	end
	if tagByte == Tags.F64 then
		return Reader.f64(reader)
	end
	if tagByte == Tags.VARINT then
		return Reader.varint(reader)
	end
	if tagByte == Tags.NEG_VARINT then
		return -Reader.varint(reader)
	end

	if tagByte == Tags.STRING then
		return readString(ctx)
	end

	if tagByte == Tags.STRING_PREFIXED then
		return readPrefixedString(ctx)
	end

	if tagByte == Tags.STRING_AFFIXED then
		return readAffixedString(ctx)
	end

	if tagByte == Tags.STRING_REF then
		local id = Reader.varint(reader)
		local value = ctx.strings[id]
		if value == nil then
			error(`Zzzz: string reference {id} not defined`, 0)
		end
		touchRecent(ctx.recentStrings, value)
		return value
	end

	--[[
		A folded reference to one of the last few strings. The tag carries the
		distance back, and reading it moves that string to the front -- exactly
		what the encoder did when it chose the fold.
	]]
	if
		tagByte >= FOLD_STRING_MTF
		and tagByte < FOLD_STRING_MTF + FOLD_STRING_MTF_COUNT
	then
		local distance = tagByte - FOLD_STRING_MTF
		local value = ctx.recentStrings[distance + 1]
		if value == nil then
			error(`Zzzz: folded string reference {distance} is out of range`, 0)
		end
		touchRecent(ctx.recentStrings, value)
		return value
	end

	--[[
		A folded struct hit: the tag carries the shape id.
	]]
	if tagByte >= Tags.FOLD_STRUCT and tagByte < Tags.FOLD_STRUCT + Tags.FOLD_STRUCT_COUNT then
		return readStruct(ctx, tagByte - Tags.FOLD_STRUCT + 1)
	end

	if tagByte == Tags.BUFFER then
		return Reader.buffer(reader)
	end

	--[[
		A flat numeric array carried as a column: the count, a byte saying which
		form encoded it, then that form's payload.
	]]
	--[[
		A flat array of datatypes, written as single-field rows so it could use
		the column forms. Unwrapping is the whole of the read: the rows carry
		their own encoding, whatever the writer chose for them.
	]]
	if tagByte == Tags.DATATYPE_ARRAY then
		local depth = enterTable(ctx)

		--[[
			The id is claimed before the rows are read, so a reference inside
			them resolves to this array rather than to whatever the wrapper
			happens to allocate first.
		]]
		local values = {}
		local id = ctx.nextTableId + 1
		ctx.nextTableId = id
		ctx.tables[id] = values

		local rows = readValue(ctx)
		if type(rows) ~= "table" then
			error("Zzzz: datatype array's rows are not a table", 0)
		end

		for index = 1, #rows do
			local row = rows[index]
			if type(row) ~= "table" then
				error(`Zzzz: datatype array is missing row {index}`, 0)
			end
			values[index] = row.v
		end

		ctx.depth = depth - 1
		return values
	end

	if tagByte == Tags.NUMBER_ARRAY then
		--[[
			Values are bit-packed and can be as narrow as one bit, so the
			allowance is 8 -- the same one the boolean array passes, and for the
			same reason. Costing a packed entry at a whole byte would refuse a
			perfectly good packet.
		]]
		local count = Reader.count(reader, 1, 8)
		local form = Reader.u8(reader)

		local result = table.create(count)

		local id = ctx.nextTableId + 1
		ctx.nextTableId = id
		ctx.tables[id] = result

		if form == 0 then
			-- Decimals stored as integers, exactly as the column form stores them.
			local descriptor = Reader.u8(reader)
			local bits = descriptor % 64
			local decimalOrder = (descriptor - bits) / 64

			if bits < 1 or bits > MAX_PACK_BITS then
				error(`Zzzz: number array bit width {bits} out of range`, 0)
			end
			if decimalOrder > MAX_DIFFERENCE_ORDER then
				error(`Zzzz: number array difference order {decimalOrder} out of range`, 0)
			end

			local exponent = Reader.u8(reader)
			local factor = Reader.u8(reader)
			if exponent > 18 or factor > exponent then
				error(`Zzzz: number array claims exponent {exponent} factor {factor}`, 0)
			end

			local scale = 10 ^ exponent
			local divisor = 10 ^ factor

			if decimalOrder > 0 then
				local seeds = table.create(decimalOrder)
				for index = 1, decimalOrder do
					seeds[index] = unzigzag(Reader.varint(reader))
				end

				local packedCount = count - decimalOrder
				if packedCount < 1 then
					error("Zzzz: number array is too short for its difference order", 0)
				end

				Reader.check(reader, math.ceil(packedCount * bits / 8))

				local accumulator, held = 0, 0
				local limit = 2 ^ bits
				local series = table.create(packedCount)

				for index = 1, packedCount do
					while held < bits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end
					local packed = accumulator % limit
					accumulator = (accumulator - packed) / limit
					held -= bits
					series[index] = unzigzag(packed)
				end

				for level = decimalOrder, 1, -1 do
					local integrated = table.create(#series + 1)
					local running = seeds[level]
					integrated[1] = running
					for index = 1, #series do
						running += series[index]
						integrated[index + 1] = running
					end
					series = integrated
				end

				for index = 1, count do
					result[index] = series[index] * divisor / scale
				end
			else
				local low = unzigzag(Reader.varint(reader))

				Reader.check(reader, math.ceil(count * bits / 8))

				local accumulator, held = 0, 0
				local limit = 2 ^ bits

				for index = 1, count do
					while held < bits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end
					local packed = accumulator % limit
					accumulator = (accumulator - packed) / limit
					held -= bits
					result[index] = (low + packed) * divisor / scale
				end
			end

			local exceptionCount = Reader.count(reader, 9)
			if exceptionCount > count then
				error(
					`Zzzz: number array claims {exceptionCount} exceptions of {count}`,
					0
				)
			end
			for _ = 1, exceptionCount do
				local at = Reader.varint(reader)
				if at < 1 or at > count then
					error(`Zzzz: number array exception names value {at}`, 0)
				end
				result[at] = Reader.f64(reader)
			end
		elseif form == 1 then
			--[[
				Integers differenced 0, 1 or 2 times, then bit-packed -- the same
				series the differenced column carries, read the same way: the
				seeds, the packed differences, then prefix sums back up through
				the orders.
			]]
			local order = Reader.u8(reader)
			if order > MAX_DIFFERENCE_ORDER then
				error(`Zzzz: number array difference order {order} out of range`, 0)
			end

			local bits = Reader.u8(reader)
			if bits < 1 or bits > MAX_PACK_BITS then
				error(`Zzzz: number array bit width {bits} out of range`, 0)
			end

			local seedCount = if order == 0 then 1 else order
			local seeds = table.create(seedCount)
			for index = 1, seedCount do
				seeds[index] = unzigzag(Reader.varint(reader))
			end

			local packedCount = count - order
			if packedCount < 1 then
				error("Zzzz: number array is too short for its difference order", 0)
			end

			Reader.check(reader, math.ceil(packedCount * bits / 8))

			local accumulator, held = 0, 0
			local limit = 2 ^ bits
			local series = table.create(packedCount)

			for index = 1, packedCount do
				while held < bits do
					accumulator += Reader.u8(reader) * 2 ^ held
					held += 8
				end
				local packed = accumulator % limit
				accumulator = (accumulator - packed) / limit
				held -= bits

				series[index] = if order == 0 then seeds[1] + packed else unzigzag(packed)
			end

			for level = order, 1, -1 do
				local integrated = table.create(#series + 1)
				local running = seeds[level]
				integrated[1] = running
				for index = 1, #series do
					running += series[index]
					integrated[index + 1] = running
				end
				series = integrated
			end

			for index = 1, count do
				result[index] = series[index]
			end
		else
			error(`Zzzz: number array names unknown form {form}`, 0)
		end

		return result
	end

	--[[
		Bit-packed boolean array: a count, then one bit per entry.
	]]
	if tagByte == Tags.BOOL_ARRAY or tagByte == Tags.BOOL_ARRAY_SAME then
		--[[
			Eight booleans share a byte, so the allowance is 8. BOOL_ARRAY_SAME
			carries no count of its own and repeats the last one, which is what
			makes a run of fixed-width flag blocks cost one byte of framing each
			rather than two.
		]]
		local count
		if tagByte == Tags.BOOL_ARRAY_SAME then
			count = ctx.lastBooleanCount
			if count == nil then
				error("Zzzz: boolean array repeats a length that was never given", 0)
			end
			-- Bound it against the bytes left, as Reader.count would have.
			Reader.check(reader, math.ceil(count / 8))
		else
			count = Reader.count(reader, 1, 8)
			ctx.lastBooleanCount = count
		end

		local result = table.create(count)

		local id = ctx.nextTableId + 1
		ctx.nextTableId = id
		ctx.tables[id] = result

		local byte = 0
		for index = 1, count do
			local bit = (index - 1) % 8
			if bit == 0 then
				byte = Reader.u8(reader)
			end
			result[index] = bit32.band(bit32.rshift(byte, bit), 1) == 1
		end

		return result
	end

	--[[
		Quantized forms. Precision comes from the packet header, so a reader
		that was configured differently still decodes these correctly.
	]]
	if
		tagByte == Tags.QUANT_NUMBER
		or tagByte == Tags.QUANT_VECTOR2
		or tagByte == Tags.QUANT_VECTOR3
		or tagByte == Tags.QUANT_CFRAME
	then
		local precision = ctx.precision
		if not precision then
			error("Zzzz: packet contains quantized values but no precision in its header", 0)
		end

		if tagByte == Tags.QUANT_NUMBER then
			return Quantize.decode(Reader.varint(reader), precision)
		end

		if tagByte == Tags.QUANT_VECTOR2 then
			return Vector2.new(
				Quantize.decode(Reader.varint(reader), precision),
				Quantize.decode(Reader.varint(reader), precision)
			)
		end

		if tagByte == Tags.QUANT_VECTOR3 then
			return Vector3.new(
				Quantize.decode(Reader.varint(reader), precision),
				Quantize.decode(Reader.varint(reader), precision),
				Quantize.decode(Reader.varint(reader), precision)
			)
		end

		local x = Quantize.decode(Reader.varint(reader), precision)
		local y = Quantize.decode(Reader.varint(reader), precision)
		local z = Quantize.decode(Reader.varint(reader), precision)
		local rotationId = Reader.u8(reader)

		if rotationId ~= 0 then
			local rotation = ID_TO_ROTATION[rotationId]
			if not rotation then
				error(`Zzzz: unknown CFrame rotation id {rotationId}`, 0)
			end
			return CFrame.new(x, y, z) * rotation
		end

		local qx, qy, qz, qw = CFrameCodec.unpackQuaternion(Reader.u32(reader))
		return CFrame.new(x, y, z, qx, qy, qz, qw)
	end

	if tagByte == Tags.ARRAY or tagByte == Tags.MAP or tagByte == Tags.MIXED then
		return readTable(ctx, tagByte)
	end

	--[[
		Structure cache. A definition carries its keys once and registers them
		under a shape id; every later table with that shape carries only values.
	]]
	--[[
		Columnar arrays: one column per key rather than one block per row.

		Rows are created and registered before any column is read, mirroring
		the encoder, so a reference elsewhere in the packet resolves to the
		same row the encoder had in mind.
	]]
	if tagByte == Tags.COLUMNS_DEF or tagByte == Tags.COLUMNS then
		local depth = enterTable(ctx)

		--[[
			The array claims its own id first, then each row claims one, which
			is the order the encoder assigns them in. The two sides have to
			agree exactly or a TABLE_REF elsewhere resolves to the wrong table.
		]]
		local rows = {}
		local arrayId = ctx.nextTableId + 1
		ctx.nextTableId = arrayId
		ctx.tables[arrayId] = rows

		local shapeId = Reader.varint(reader)

		local keys: { any }
		--[[
			Which keys were hoisted out of a nested map travels with the shape,
			rather than being inferred from the name. A key may legitimately
			contain a dot, and guessing from the text alone would take such a
			key apart on the way back.

			Each entry says which kind: `false` for a key lifted out of a map,
			`true` for a position lifted out of an array. The two rebuild
			differently and the name alone cannot tell them apart, since a map
			is free to have a key spelled "1".
		]]
		local hoistedAt: { [number]: boolean }
		-- Whether these rows were positional and must go back that way.
		local fromTuples = false
		if tagByte == Tags.COLUMNS_DEF then
			local keyCount = Reader.count(reader, 2)
			keys = table.create(keyCount)
			for index = 1, keyCount do
				local key = readValue(ctx)
				if type(key) ~= "string" then
					error("Zzzz: columnar shape has a non-string key", 0)
				end
				keys[index] = key
			end

			hoistedAt = {}
			-- Count doubled, low bit set when the rows were tuples.
			local header = Reader.varint(reader)
			local hoistCount = header // 2
			fromTuples = header % 2 == 1
			if hoistCount > keyCount then
				error(
					`Zzzz: columnar shape claims {hoistCount} hoisted of {keyCount} keys`,
					0
				)
			end
			for _ = 1, hoistCount do
				-- Index doubled, low bit set when the hoist came from an array.
				local encoded = Reader.varint(reader)
				local at = encoded // 2
				if at < 1 or at > keyCount then
					error(`Zzzz: hoisted column names key {at}`, 0)
				end
				hoistedAt[at] = encoded % 2 == 1
			end

			ctx.shapes[shapeId] = keys
			ctx.shapeHoists[shapeId] = hoistedAt
			ctx.shapeTuples[shapeId] = fromTuples
		else
			keys = ctx.shapes[shapeId]
			if not keys then
				error(`Zzzz: columnar shape {shapeId} not defined`, 0)
			end
			hoistedAt = ctx.shapeHoists[shapeId] or {}
			fromTuples = ctx.shapeTuples[shapeId] == true
		end

		--[[
			Bound the row count against the bytes remaining.

			A row has no minimum size any more: a one-value column stores its
			value once and nothing per row, so a thousand rows of such columns
			occupy a handful of bytes. The count is therefore bounded only by
			what could be allocated at all, and every column that does consume
			bytes per row checks its own block before reading it.
		]]
		local rowCount = Reader.varint(reader)
		if rowCount > ctx.maxNodes then
			error(
				`Zzzz: columnar array claims {rowCount} rows, above the {ctx.maxNodes} limit`,
				0
			)
		end

		for index = 1, rowCount do
			local row = {}
			rows[index] = row
			local id = ctx.nextTableId + 1
			ctx.nextTableId = id
			ctx.tables[id] = row
		end

		--[[
			Columns are not necessarily written in the shape's key order: a
			column encoded against another has to follow it. Each column names
			its own key by index, so the two sides need not agree on an order,
			only on the shape.

			Decoded integer columns are kept here while any later column might
			reference them.
		]]
		local decodedColumns: { [string]: { number } } = {}

		for _ = 1, #keys do
			--[[
				A column's plan -- its key, kind and any width or order bytes --
				is interned per packet, because arrays of the same shape holding
				similar data describe their columns identically. A zero
				introduces a definition; anything else is a reference to one.
			]]
			local marker = Reader.varint(reader)
			local plan

			if marker % 2 == 0 then
				local definedKey = marker / 2
				local definedKind = Reader.u8(reader)
				local descriptorCount = DESCRIPTOR_COUNTS[definedKind]
				if descriptorCount == nil then
					error(`Zzzz: unknown column kind {definedKind}`, 0)
				end

				local descriptors = table.create(descriptorCount)
				for index = 1, descriptorCount do
					descriptors[index] = Reader.u8(reader)
				end

				plan = { key = definedKey, kind = definedKind, descriptors = descriptors }
				ctx.nextColumnPlanId += 1
				ctx.columnPlans[ctx.nextColumnPlanId] = plan
			else
				local planId = (marker - 1) / 2
				plan = ctx.columnPlans[planId]
				if plan == nil then
					error(`Zzzz: column plan {planId} not defined`, 0)
				end
			end

			local keyIndex = plan.key
			local key = keys[keyIndex]
			if key == nil then
				error(`Zzzz: column names key {keyIndex}, which the shape lacks`, 0)
			end

			local kind = plan.kind
			local descriptors = plan.descriptors

			if kind == COLUMN_CORRELATED then
				--[[
					A residual against another column: that column's key index,
					the fitted slope and intercept, then the packed residual.
				]]
				local referenceIndex = descriptors[1]
				local referenceKey = keys[referenceIndex]
				if referenceKey == nil then
					error(
						`Zzzz: correlated column references key {referenceIndex}, which the shape lacks`,
						0
					)
				end

				local reference = decodedColumns[referenceKey]
				if reference == nil then
					error(
						`Zzzz: correlated column references "{referenceKey}", which has not been read`,
						0
					)
				end

				local slope = unzigzag(Reader.varint(reader))
				local intercept = unzigzag(Reader.varint(reader))

				local bits = descriptors[2]
				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: column bit width {bits} out of range`, 0)
				end

				Reader.check(reader, math.ceil(rowCount * bits / 8))

				local accumulator = 0
				local held = 0
				local limit = 2 ^ bits
				local restored = table.create(rowCount)

				for index = 1, rowCount do
					while held < bits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end

					local packed = accumulator % limit
					accumulator = (accumulator - packed) / limit
					held -= bits

					local entry = slope * reference[index] + intercept + unzigzag(packed)
					restored[index] = entry
					rows[index][key] = entry
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_DATATYPE_SPLIT then
				--[[
					A datatype rebuilt from one column per component. The
					components arrive as an ordinary nested array -- that is the
					whole point of the form, since it lets them use every scheme
					a numeric column can -- so reading them is one readValue and
					the rest is reassembly.
				]]
				local spec = DATATYPE_SPLIT_BUILDERS[descriptors[1]]
				if spec == nil then
					error(
						`Zzzz: column names datatype {descriptors[1]}, which this version cannot rebuild`,
						0
					)
				end

				local parts = readValue(ctx)
				if type(parts) ~= "table" then
					error("Zzzz: split datatype column's components are not a table", 0)
				end

				local restored = table.create(rowCount)
				local scratch = table.create(spec.arity)

				for index = 1, rowCount do
					local row = parts[index]
					if type(row) ~= "table" then
						error(
							`Zzzz: split datatype column is missing row {index}`,
							0
						)
					end
					for component = 1, spec.arity do
						local value = row[tostring(component)]
						if type(value) ~= "number" then
							error(
								`Zzzz: split datatype row {index} is missing component {component}`,
								0
							)
						end
						scratch[component] = value
					end
					local built = construct("datatype", spec.build, scratch)
					restored[index] = built
					rows[index][key] = built
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_DATATYPE_DICT then
				--[[
					A small vocabulary of datatypes: the distinct values once,
					then a packed id a row. The id width follows from the entry
					count, which precedes them, so the plan carries nothing.
				]]
				local entryCount = Reader.count(reader, 1)
				if entryCount > MAX_DICTIONARY_ENTRIES then
					error(
						`Zzzz: datatype dictionary claims {entryCount} entries, over the {MAX_DICTIONARY_ENTRIES} cap`,
						0
					)
				end

				local entries = table.create(entryCount)
				for index = 1, entryCount do
					entries[index] = readValue(ctx)
				end

				local idBits = 1
				while idBits < MAX_DICTIONARY_ID_BITS and 2 ^ idBits < entryCount do
					idBits += 1
				end

				Reader.check(reader, math.ceil(rowCount * idBits / 8))

				local accumulator, held = 0, 0
				local limit = 2 ^ idBits
				local restored = table.create(rowCount)

				for index = 1, rowCount do
					while held < idBits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end
					local packed = accumulator % limit
					accumulator = (accumulator - packed) / limit
					held -= idBits

					local entry = entries[packed + 1]
					if entry == nil then
						error(`Zzzz: datatype dictionary has no entry {packed + 1}`, 0)
					end
					restored[index] = entry
					rows[index][key] = entry
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_DATE then
				--[[
					Dates as day numbers: the base, then the offsets packed at
					the width of the span. The text is rebuilt rather than
					stored, which is the whole point -- the encoder only chose
					this form after checking that rebuilding reproduces the
					caller's bytes exactly.
				]]
				--[[
					Width and order share the descriptor: six bits of width, two
					of difference order. Dates on a stride are differenced rather
					than packed as offsets, which is most of them.
				]]
				local dateDescriptor = descriptors[1]
				local bits = dateDescriptor % 64
				local dateOrder = (dateDescriptor - bits) / 64

				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: date column bit width {bits} out of range`, 0)
				end
				if dateOrder > MAX_DIFFERENCE_ORDER then
					error(`Zzzz: date column difference order {dateOrder} out of range`, 0)
				end

				local restored = table.create(rowCount)
				local days = table.create(rowCount)

				if dateOrder > 0 then
					local seeds = table.create(dateOrder)
					for index = 1, dateOrder do
						seeds[index] = unzigzag(Reader.varint(reader))
					end

					local packedCount = rowCount - dateOrder
					if packedCount < 1 then
						error("Zzzz: date column is too short for its difference order", 0)
					end

					Reader.check(reader, math.ceil(packedCount * bits / 8))

					local accumulator, held = 0, 0
					local limit = 2 ^ bits
					local series = table.create(packedCount)

					for index = 1, packedCount do
						while held < bits do
							accumulator += Reader.u8(reader) * 2 ^ held
							held += 8
						end
						local packed = accumulator % limit
						accumulator = (accumulator - packed) / limit
						held -= bits
						series[index] = unzigzag(packed)
					end

					for level = dateOrder, 1, -1 do
						local integrated = table.create(#series + 1)
						local running = seeds[level]
						integrated[1] = running
						for index = 1, #series do
							running += series[index]
							integrated[index + 1] = running
						end
						series = integrated
					end

					for index = 1, rowCount do
						days[index] = series[index]
					end
				else
					local low = unzigzag(Reader.varint(reader))
					Reader.check(reader, math.ceil(rowCount * bits / 8))

					local accumulator, held = 0, 0
					local limit = 2 ^ bits

					for index = 1, rowCount do
						while held < bits do
							accumulator += Reader.u8(reader) * 2 ^ held
							held += 8
						end
						local packed = accumulator % limit
						accumulator = (accumulator - packed) / limit
						held -= bits
						days[index] = low + packed
					end
				end

				for index = 1, rowCount do
					local year, month, day = civilFromDays(days[index])
					if year < 0 or year > 9999 then
						error(`Zzzz: date column names year {year}`, 0)
					end
					local entry = string.format("%04d-%02d-%02d", year, month, day)
					restored[index] = entry
					rows[index][key] = entry
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_PREFIXED_INT then
				--[[
					A constant label around a fixed-width counter: the label
					once, then the numbers packed at the width of their span.

					The counter is rendered zero-padded to the recorded width,
					which is what reproduces the caller's bytes -- `TXN-100001`
					holds `0001`, and rendering `1` would return a string they
					never wrote.
				]]
				local bits = descriptors[1]
				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: prefixed column bit width {bits} out of range`, 0)
				end

				--[[
					The width descriptor carries the order in its high bits: five
					bits of width, two of order. A counter is never wider than
					eighteen digits, so the pair fits one byte.
				]]
				local widthDescriptor = descriptors[2]
				local width = widthDescriptor % 32
				local prefixedOrder = (widthDescriptor - width) / 32

				if width > 18 then
					error(`Zzzz: prefixed column counter width {width} out of range`, 0)
				end
				if prefixedOrder > MAX_DIFFERENCE_ORDER then
					error(`Zzzz: prefixed column difference order {prefixedOrder} out of range`, 0)
				end

				local prefix = Reader.string(reader)
				local suffix = Reader.string(reader)
				local restored = table.create(rowCount)
				local counters = table.create(rowCount)
				--[[
					Width zero means the counter was never zero-padded, so it is
					rendered with as many digits as it has.
				]]
				local format = if width > 0 then `%0{width}d` else "%d"

				if prefixedOrder > 0 then
					local seeds = table.create(prefixedOrder)
					for index = 1, prefixedOrder do
						seeds[index] = unzigzag(Reader.varint(reader))
					end

					local packedCount = rowCount - prefixedOrder
					if packedCount < 1 then
						error("Zzzz: prefixed column is too short for its difference order", 0)
					end

					Reader.check(reader, math.ceil(packedCount * bits / 8))

					local accumulator, held = 0, 0
					local limit = 2 ^ bits
					local series = table.create(packedCount)

					for index = 1, packedCount do
						while held < bits do
							accumulator += Reader.u8(reader) * 2 ^ held
							held += 8
						end
						local packed = accumulator % limit
						accumulator = (accumulator - packed) / limit
						held -= bits
						series[index] = unzigzag(packed)
					end

					for level = prefixedOrder, 1, -1 do
						local integrated = table.create(#series + 1)
						local running = seeds[level]
						integrated[1] = running
						for index = 1, #series do
							running += series[index]
							integrated[index + 1] = running
						end
						series = integrated
					end

					for index = 1, rowCount do
						counters[index] = series[index]
					end
				else
					local low = unzigzag(Reader.varint(reader))
					Reader.check(reader, math.ceil(rowCount * bits / 8))

					local accumulator, held = 0, 0
					local limit = 2 ^ bits

					for index = 1, rowCount do
						while held < bits do
							accumulator += Reader.u8(reader) * 2 ^ held
							held += 8
						end
						local packed = accumulator % limit
						accumulator = (accumulator - packed) / limit
						held -= bits
						counters[index] = low + packed
					end
				end

				for index = 1, rowCount do
					local entry = prefix .. string.format(format, counters[index]) .. suffix
					restored[index] = entry
					rows[index][key] = entry
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_OPTIONAL then
				--[[
					A column some rows lack: the validity bitmap, then only the
					values that are actually there.

					The rows without one are left untouched rather than written
					as anything -- an absent key is absent, not nil-valued, and
					the difference is what the caller gets back.
				]]
				local present = table.create(rowCount)
				local byte = 0
				local expected = 0
				for index = 1, rowCount do
					local bit = (index - 1) % 8
					if bit == 0 then
						byte = Reader.u8(reader)
					end
					local has = bit32.band(bit32.rshift(byte, bit), 1) == 1
					present[index] = has
					if has then
						expected += 1
					end
				end

				--[[
					The values may be packed, bit-packed or nested inside their
					own columnar array, any of which can be far smaller than a
					byte apiece -- so the allowance is generous. The real check is
					the one below: the count must match the bitmap exactly.
				]]
				local valueCount = Reader.count(reader, 1, 64)
				if valueCount ~= expected then
					error(
						`Zzzz: optional column carries {valueCount} values for {expected} present rows`,
						0
					)
				end

				--[[
					The values that are there form a complete column, so they may
					carry a column encoding of their own. One descriptor byte
					says which: zero for a value at a time, one for the decimal
					form, which is what a nullable measurement almost always is.
				]]
				local values = table.create(valueCount)

				if descriptors[1] == 2 then
					--[[
						The values were handed back to the encoder as an array of
						single-key rows so they could take a column form of their
						own. Unwrapping is the whole of the read.
					]]
					local wrapped = readValue(ctx)
					if type(wrapped) ~= "table" then
						error("Zzzz: optional column's nested values are not a table", 0)
					end
					for index = 1, valueCount do
						local row = wrapped[index]
						if type(row) ~= "table" then
							error(`Zzzz: optional column's nested row {index} is missing`, 0)
						end
						values[index] = row.v
					end
				elseif descriptors[1] == 1 then
					local bits = Reader.u8(reader)
					if bits < 1 or bits > MAX_PACK_BITS then
						error(`Zzzz: optional column decimal width {bits} out of range`, 0)
					end
					local exponent = Reader.u8(reader)
					local factor = Reader.u8(reader)
					if exponent > 18 or factor > exponent then
						error(
							`Zzzz: optional column claims exponent {exponent} factor {factor}`,
							0
						)
					end

					local low = unzigzag(Reader.varint(reader))
					local scale = 10 ^ exponent
					local divisor = 10 ^ factor

					Reader.check(reader, math.ceil(valueCount * bits / 8))

					local accumulator, held = 0, 0
					local limit = 2 ^ bits

					for index = 1, valueCount do
						while held < bits do
							accumulator += Reader.u8(reader) * 2 ^ held
							held += 8
						end
						local packed = accumulator % limit
						accumulator = (accumulator - packed) / limit
						held -= bits
						values[index] = (low + packed) * divisor / scale
					end

					local exceptionCount = Reader.count(reader, 1)
					if exceptionCount > valueCount then
						error(
							`Zzzz: optional column claims {exceptionCount} decimal exceptions of {valueCount}`,
							0
						)
					end
					for _ = 1, exceptionCount do
						local at = Reader.varint(reader)
						if at < 1 or at > valueCount then
							error(`Zzzz: optional column decimal exception names value {at}`, 0)
						end
						values[at] = Reader.f64(reader)
					end
				else
					for index = 1, valueCount do
						values[index] = readValue(ctx)
					end
				end

				local restored = table.create(rowCount)
				local taken = 0
				for index = 1, rowCount do
					if present[index] then
						taken += 1
						local entry = values[taken]
						restored[index] = entry
						rows[index][key] = entry
					end
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_BOOLEANS then
				local byte = 0
				for index = 1, rowCount do
					local bit = (index - 1) % 8
					if bit == 0 then
						byte = Reader.u8(reader)
					end
					rows[index][key] = bit32.band(bit32.rshift(byte, bit), 1) == 1
				end
			elseif kind == COLUMN_MAPPED then
				--[[
					Values looked up from another column: the distinct targets,
					one target per distinct source value, then the rows that break
					the mapping.

					Source values are numbered here in order of first appearance,
					exactly as the encoder numbered them, so the mapping needs no
					source side on the wire. The reference column is read from the
					rows themselves, which lets a mapping reference a column of
					any type rather than only a numeric one.
				]]
				local referenceIndex = descriptors[1]
				local referenceKey = keys[referenceIndex]
				if referenceKey == nil then
					error(
						`Zzzz: mapped column references key {referenceIndex}, which the shape lacks`,
						0
					)
				end

				local bits = descriptors[2]
				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: column bit width {bits} out of range`, 0)
				end

				local targetCount = Reader.count(reader, 1)
				local targetValues = table.create(targetCount)
				for index = 1, targetCount do
					targetValues[index] = readValue(ctx)
				end

				--[[
					Number the reference column's distinct values, in the order
					they first appear. A row whose reference is nil means the
					referenced column was never read, which a corrupt packet can
					produce.
				]]
				local sourceIds: { [any]: number } = {}
				local distinctSource = 0
				for index = 1, rowCount do
					local entry = rows[index][referenceKey]
					if entry == nil then
						error(
							`Zzzz: mapped column references "{referenceKey}", which has not been read`,
							0
						)
					end
					if sourceIds[entry] == nil then
						distinctSource += 1
						sourceIds[entry] = distinctSource
					end
				end

				Reader.check(reader, math.ceil(distinctSource * bits / 8))

				local accumulator, held = 0, 0
				local limit = 2 ^ bits
				local mapping = table.create(distinctSource)

				for index = 1, distinctSource do
					while held < bits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end
					local packed = accumulator % limit
					accumulator = (accumulator - packed) / limit
					held -= bits

					local entry = targetValues[packed + 1]
					if entry == nil then
						error(`Zzzz: mapped column has no target {packed}`, 0)
					end
					mapping[index] = entry
				end

				for index = 1, rowCount do
					rows[index][key] = mapping[sourceIds[rows[index][referenceKey]]]
				end

				-- Then the rows the mapping gets wrong.
				local exceptionCount = Reader.count(reader, 2)
				if exceptionCount > rowCount then
					error(
						`Zzzz: mapped column claims {exceptionCount} exceptions of {rowCount} rows`,
						0
					)
				end

				for _ = 1, exceptionCount do
					local row = Reader.varint(reader)
					if row < 1 or row > rowCount then
						error(`Zzzz: mapped column exception names row {row}`, 0)
					end
					local targetId = Reader.varint(reader)
					local entry = targetValues[targetId + 1]
					if entry == nil then
						error(`Zzzz: mapped column has no target {targetId}`, 0)
					end
					rows[row][key] = entry
				end

				--[[
					A mapped column can itself be referenced.

					This branch writes its values straight into the rows, since that
					is all rebuilding the column requires. But the correlated,
					narrowed and framed forms read their reference out of
					`decodedColumns`, not out of the rows -- so a column that landed
					here was invisible to them, and a packet whose encoder had
					planned such a link failed to decode at all:

						Zzzz: correlated column references "a4", which has not
						been read

					The encoder allows the link because its own `materialised` table
					is populated by every form including this one, so the two sides
					disagreed about what a reference could name. Recorded here after
					the exceptions are patched in, so what is published is the
					finished column rather than the mapping's guess at it.
				]]
				local restored = table.create(rowCount)
				for index = 1, rowCount do
					restored[index] = rows[index][key]
				end
				decodedColumns[key] = restored
			elseif kind == COLUMN_MULTI_MAPPED then
				--[[
					One of several values a source value permits: the length of
					each source's run of admissible targets, those targets, then
					one packed index into the run per row.

					Source values are numbered here in order of first appearance,
					exactly as the encoder numbered them, so the runs need no
					source side on the wire.
				]]
				local referenceIndex = descriptors[1]
				local referenceKey = keys[referenceIndex]
				if referenceKey == nil then
					error(
						`Zzzz: narrowed column references key {referenceIndex}, which the shape lacks`,
						0
					)
				end

				local bits = descriptors[2]
				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: column bit width {bits} out of range`, 0)
				end

				local runCount = Reader.count(reader, 1)
				local runLengths = table.create(runCount)
				local totalValues = 0
				for index = 1, runCount do
					local length = Reader.varint(reader)
					if length < 1 or length > rowCount then
						error(`Zzzz: narrowed column run holds {length} of {rowCount} rows`, 0)
					end
					runLengths[index] = length
					totalValues += length
				end

				--[[
					Runs are contiguous, so a start offset per source is all that
					is needed to find one.
				]]
				local runStarts = table.create(runCount)
				local cursor = 0
				for index = 1, runCount do
					runStarts[index] = cursor
					cursor += runLengths[index]
				end

				local runValues = table.create(totalValues)
				for index = 1, totalValues do
					runValues[index] = readValue(ctx)
				end

				local sourceIds: { [any]: number } = {}
				local distinctSource = 0
				for index = 1, rowCount do
					local entry = rows[index][referenceKey]
					if entry == nil then
						error(
							`Zzzz: narrowed column references "{referenceKey}", which has not been read`,
							0
						)
					end
					if sourceIds[entry] == nil then
						distinctSource += 1
						sourceIds[entry] = distinctSource
					end
				end

				if distinctSource ~= runCount then
					error(
						`Zzzz: narrowed column has {runCount} runs for {distinctSource} source values`,
						0
					)
				end

				Reader.check(reader, math.ceil(rowCount * bits / 8))

				local accumulator, held = 0, 0
				local limit = 2 ^ bits
				local restored = table.create(rowCount)

				for index = 1, rowCount do
					while held < bits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end
					local packed = accumulator % limit
					accumulator = (accumulator - packed) / limit
					held -= bits

					local sourceId = sourceIds[rows[index][referenceKey]]
					if packed >= runLengths[sourceId] then
						error(
							`Zzzz: narrowed column names entry {packed} of a {runLengths[sourceId]} run`,
							0
						)
					end

					local entry = runValues[runStarts[sourceId] + packed + 1]
					restored[index] = entry
					rows[index][key] = entry
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_DICTIONARY_FOR then
				--[[
					A value in a distinct range per source value: one reference
					per distinct source value, then the offset from it packed at
					the width of the widest group.
				]]
				local referenceIndex = descriptors[1]
				local referenceKey = keys[referenceIndex]
				if referenceKey == nil then
					error(
						`Zzzz: framed column references key {referenceIndex}, which the shape lacks`,
						0
					)
				end

				local bits = descriptors[2]
				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: column bit width {bits} out of range`, 0)
				end

				local referenceCount = Reader.count(reader, 1)
				local references = table.create(referenceCount)
				for index = 1, referenceCount do
					references[index] = unzigzag(Reader.varint(reader))
				end

				local sourceIds: { [any]: number } = {}
				local distinctSource = 0
				for index = 1, rowCount do
					local entry = rows[index][referenceKey]
					if entry == nil then
						error(
							`Zzzz: framed column references "{referenceKey}", which has not been read`,
							0
						)
					end
					if sourceIds[entry] == nil then
						distinctSource += 1
						sourceIds[entry] = distinctSource
					end
				end

				if distinctSource ~= referenceCount then
					error(
						`Zzzz: framed column has {referenceCount} references for {distinctSource} source values`,
						0
					)
				end

				Reader.check(reader, math.ceil(rowCount * bits / 8))

				local accumulator, held = 0, 0
				local limit = 2 ^ bits
				local restored = table.create(rowCount)

				for index = 1, rowCount do
					while held < bits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end
					local packed = accumulator % limit
					accumulator = (accumulator - packed) / limit
					held -= bits

					local entry = references[sourceIds[rows[index][referenceKey]]] + packed
					restored[index] = entry
					rows[index][key] = entry
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_EQUALITY then
				--[[
					A column that is another column: the rows that disagree, and
					nothing else. The reference is read from the rows themselves,
					so a column of any type can stand in for another.
				]]
				local referenceIndex = descriptors[1]
				local referenceKey = keys[referenceIndex]
				if referenceKey == nil then
					error(
						`Zzzz: equal column references key {referenceIndex}, which the shape lacks`,
						0
					)
				end

				local restored = table.create(rowCount)
				for index = 1, rowCount do
					local entry = rows[index][referenceKey]
					if entry == nil then
						error(
							`Zzzz: equal column references "{referenceKey}", which has not been read`,
							0
						)
					end
					restored[index] = entry
					rows[index][key] = entry
				end

				local exceptionCount = Reader.count(reader, 2)
				if exceptionCount > rowCount then
					error(
						`Zzzz: equal column claims {exceptionCount} exceptions of {rowCount} rows`,
						0
					)
				end

				--[[
					The rows arrive together, either as varints or as gaps packed
					at the width the plan names, then the values follow.
				]]
				local rowBits = descriptors[2]
				if rowBits > MAX_PACK_BITS then
					error(`Zzzz: equal column gap width {rowBits} out of range`, 0)
				end

				local exceptionRows = table.create(exceptionCount)

				if rowBits > 0 then
					Reader.check(reader, math.ceil(exceptionCount * rowBits / 8))

					local accumulator, held = 0, 0
					local limit = 2 ^ rowBits
					local previous = 0

					for index = 1, exceptionCount do
						while held < rowBits do
							accumulator += Reader.u8(reader) * 2 ^ held
							held += 8
						end
						local gap = accumulator % limit
						accumulator = (accumulator - gap) / limit
						held -= rowBits

						--[[
							A zero gap would name the same row twice, and the rows
							ascend by construction, so it cannot arise from a
							packet this encoder wrote.
						]]
						if gap < 1 then
							error(`Zzzz: equal column exception gap {gap} does not advance`, 0)
						end

						previous += gap
						if previous > rowCount then
							error(`Zzzz: equal column exception names row {previous}`, 0)
						end
						exceptionRows[index] = previous
					end
				else
					for index = 1, exceptionCount do
						local row = Reader.varint(reader)
						if row < 1 or row > rowCount then
							error(`Zzzz: equal column exception names row {row}`, 0)
						end
						exceptionRows[index] = row
					end
				end

				for index = 1, exceptionCount do
					local row = exceptionRows[index]
					local entry = readValue(ctx)
					restored[row] = entry
					rows[row][key] = entry
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_CYCLIC then
				--[[
					A column that repeats on a fixed period: one cycle of values
					and the rows that depart from it.

					The cycle may describe the column's differences rather than
					its values, in which case a seed starts the reconstruction --
					that is what carries a loop riding on a trend, which is the
					more common of the two shapes.
				]]
				local period = descriptors[1]
				local bits = descriptors[2]
				local differenced = descriptors[3] ~= 0

				--[[
					A period of zero would divide by zero below and one is a
					constant, which has its own form. Neither is producible by
					the encoder, so meeting one means the packet is corrupt.
				]]
				if period < 2 then
					error(`Zzzz: cyclic column claims period {period}`, 0)
				end
				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: cyclic column bit width {bits} out of range`, 0)
				end

				--[[
					The series the cycle describes is one shorter than the column
					when it holds differences, since n values have n-1 steps.
				]]
				local seriesCount = if differenced then rowCount - 1 else rowCount
				if seriesCount < 1 then
					error(`Zzzz: cyclic column has too few rows`, 0)
				end

				local seed = if differenced then unzigzag(Reader.varint(reader)) else nil
				local low = unzigzag(Reader.varint(reader))

				Reader.check(reader, math.ceil(period * bits / 8))

				local cycle = table.create(period)
				local accumulator, held = 0, 0
				local limit = 2 ^ bits

				for index = 1, period do
					while held < bits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end
					local packed = accumulator % limit
					accumulator = (accumulator - packed) / limit
					held -= bits
					cycle[index] = low + packed
				end

				local series = table.create(seriesCount)
				for index = 1, seriesCount do
					series[index] = cycle[(index - 1) % period + 1]
				end

				-- Then the rows the cycle gets wrong.
				local exceptionCount = Reader.count(reader, 2)
				if exceptionCount > seriesCount then
					error(
						`Zzzz: cyclic column claims {exceptionCount} exceptions of {seriesCount}`,
						0
					)
				end

				for _ = 1, exceptionCount do
					local row = Reader.varint(reader)
					if row < 1 or row > seriesCount then
						error(`Zzzz: cyclic column exception names row {row}`, 0)
					end
					series[row] = unzigzag(Reader.varint(reader))
				end

				local restored = table.create(rowCount)
				if differenced then
					--[[
						The column is the running sum of the steps from the seed.
					]]
					restored[1] = seed
					for index = 2, rowCount do
						restored[index] = restored[index - 1] + series[index - 1]
					end
				else
					for index = 1, rowCount do
						restored[index] = series[index]
					end
				end

				for index = 1, rowCount do
					rows[index][key] = restored[index]
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_RUN_LENGTH then
				--[[
					Runs: a value and how many times it repeats, until the rows
					are filled. The lengths must account for every row exactly --
					a short count would leave rows nil and a long one would write
					past the column.
				]]
				local runCount = Reader.count(reader, 1)
				local restored = table.create(rowCount)
				local filled = 0

				--[[
					The lengths arrive together, either as varints or packed at
					the width the plan names, then the values follow.
				]]
				local lengthBits = descriptors[1]
				if lengthBits > MAX_PACK_BITS then
					error(`Zzzz: run length width {lengthBits} out of range`, 0)
				end

				local lengths = table.create(runCount)

				if lengthBits > 0 then
					Reader.check(reader, math.ceil(runCount * lengthBits / 8))

					local accumulator, held = 0, 0
					local limit = 2 ^ lengthBits

					for index = 1, runCount do
						while held < lengthBits do
							accumulator += Reader.u8(reader) * 2 ^ held
							held += 8
						end
						local length = accumulator % limit
						accumulator = (accumulator - length) / limit
						held -= lengthBits
						lengths[index] = length
					end
				else
					for index = 1, runCount do
						lengths[index] = Reader.varint(reader)
					end
				end

				for index = 1, runCount do
					local length = lengths[index]
					if length < 1 or filled + length > rowCount then
						error(
							`Zzzz: run of {length} overruns {rowCount} rows at {filled}`,
							0
						)
					end
					local entry = readValue(ctx)
					for _ = 1, length do
						filled += 1
						restored[filled] = entry
						rows[filled][key] = entry
					end
				end

				if filled ~= rowCount then
					error(`Zzzz: runs fill {filled} of {rowCount} rows`, 0)
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_DECIMAL then
				--[[
					Decimals stored as integers: the exponent and factor that
					recover them, a frame of reference, the packed integers, then
					the values no exponent could express.
				]]
				--[[
					Width and order share the descriptor: the low six bits carry
					the width, the high two the difference order. A width never
					exceeds 45 and an order never exceeds 2, so the pair fits a
					byte and a decimal plan stays the size it always was.
				]]
				local descriptor = descriptors[1]
				local bits = descriptor % 64
				local decimalOrder = (descriptor - bits) / 64

				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: column bit width {bits} out of range`, 0)
				end

				local exponent = Reader.u8(reader)
				local factor = Reader.u8(reader)
				--[[
					10^e stops being exact well before this, and a factor above
					the exponent would scale the wrong way.
				]]
				if exponent > 18 or factor > exponent then
					error(`Zzzz: decimal column claims exponent {exponent} factor {factor}`, 0)
				end

				local scale = 10 ^ exponent
				local divisor = 10 ^ factor
				local restored = table.create(rowCount)

				--[[
					The order says how the scaled integers were packed: zero for
					offsets from a frame of reference, one or two when the
					encoder found a trend worth differencing out.
				]]
				if decimalOrder > MAX_DIFFERENCE_ORDER then
					error(`Zzzz: decimal column difference order {decimalOrder} out of range`, 0)
				end

				if decimalOrder > 0 then
					local seedCount = decimalOrder
					local seeds = table.create(seedCount)
					for index = 1, seedCount do
						seeds[index] = unzigzag(Reader.varint(reader))
					end

					local packedCount = rowCount - decimalOrder
					if packedCount < 1 then
						error("Zzzz: decimal column is too short for its difference order", 0)
					end

					Reader.check(reader, math.ceil(packedCount * bits / 8))

					local accumulator, held = 0, 0
					local limit = 2 ^ bits
					local series = table.create(packedCount)

					for index = 1, packedCount do
						while held < bits do
							accumulator += Reader.u8(reader) * 2 ^ held
							held += 8
						end
						local packed = accumulator % limit
						accumulator = (accumulator - packed) / limit
						held -= bits
						series[index] = unzigzag(packed)
					end

					for level = decimalOrder, 1, -1 do
						local integrated = table.create(#series + 1)
						local running = seeds[level]
						integrated[1] = running
						for index = 1, #series do
							running += series[index]
							integrated[index + 1] = running
						end
						series = integrated
					end

					for index = 1, rowCount do
						local entry = series[index] * divisor / scale
						restored[index] = entry
						rows[index][key] = entry
					end
				else
					local low = unzigzag(Reader.varint(reader))

					Reader.check(reader, math.ceil(rowCount * bits / 8))

					local accumulator, held = 0, 0
					local limit = 2 ^ bits

					for index = 1, rowCount do
						while held < bits do
							accumulator += Reader.u8(reader) * 2 ^ held
							held += 8
						end
						local packed = accumulator % limit
						accumulator = (accumulator - packed) / limit
						held -= bits

						local entry = (low + packed) * divisor / scale
						restored[index] = entry
						rows[index][key] = entry
					end
				end

				local exceptionCount = Reader.count(reader, 9)
				if exceptionCount > rowCount then
					error(
						`Zzzz: decimal column claims {exceptionCount} exceptions of {rowCount} rows`,
						0
					)
				end

				for _ = 1, exceptionCount do
					local row = Reader.varint(reader)
					if row < 1 or row > rowCount then
						error(`Zzzz: decimal column exception names row {row}`, 0)
					end
					local entry = Reader.f64(reader)
					restored[row] = entry
					rows[row][key] = entry
				end

				decodedColumns[key] = restored
			elseif kind == COLUMN_FREQUENCY then
				--[[
					One dominant value, a bitmap saying which rows hold something
					else, then those exceptions packed at one width. With no
					exceptions the bitmap is absent and every row is the value.
				]]
				local bits = descriptors[1]
				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: column bit width {bits} out of range`, 0)
				end

				local dominant = unzigzag(Reader.varint(reader))
				local exceptionCount = Reader.varint(reader)
				if exceptionCount > rowCount then
					error(
						`Zzzz: frequency column claims {exceptionCount} exceptions of {rowCount} rows`,
						0
					)
				end

				if exceptionCount == 0 then
					for index = 1, rowCount do
						rows[index][key] = dominant
					end
					decodedColumns[key] = table.create(rowCount, dominant)
				else
					--[[
						Positions arrive as a bitmap or as packed gaps, and the
						plan says which. Gaps are far cheaper on a skewed column,
						where a bit a row is an order of magnitude more than the
						exceptions are worth.
					]]
					local gapBits = descriptors[2]
					if gapBits > MAX_PACK_BITS then
						error(`Zzzz: frequency column gap width {gapBits} out of range`, 0)
					end

					local positionBytes = if gapBits > 0
						then math.ceil(exceptionCount * gapBits / 8)
						else math.ceil(rowCount / 8)

					Reader.check(
						reader,
						positionBytes + math.ceil(exceptionCount * bits / 8)
					)

					-- Which rows are exceptions.
					local isException = table.create(rowCount, false)

					if gapBits > 0 then
						local accumulator, held = 0, 0
						local limit = 2 ^ gapBits
						local row = 0

						for _ = 1, exceptionCount do
							while held < gapBits do
								accumulator += Reader.u8(reader) * 2 ^ held
								held += 8
							end
							local gap = accumulator % limit
							accumulator = (accumulator - gap) / limit
							held -= gapBits

							row += gap
							--[[
								Gaps ascend by construction, so a zero gap or one
								that runs past the column means the packet is
								corrupt -- and an unchecked row would index
								outside the table.
							]]
							if gap < 1 or row > rowCount then
								error(
									`Zzzz: frequency column exception at row {row} of {rowCount}`,
									0
								)
							end
							isException[row] = true
						end
					else
						local byte = 0
						for index = 1, rowCount do
							local bit = (index - 1) % 8
							if bit == 0 then
								byte = Reader.u8(reader)
							end
							isException[index] = bit32.band(bit32.rshift(byte, bit), 1) == 1
						end
					end

					-- Then their values, in row order.
					local accumulator, held = 0, 0
					local limit = 2 ^ bits
					local restored = table.create(rowCount)

					for index = 1, rowCount do
						if isException[index] then
							while held < bits do
								accumulator += Reader.u8(reader) * 2 ^ held
								held += 8
							end
							local packed = accumulator % limit
							accumulator = (accumulator - packed) / limit
							held -= bits
							restored[index] = unzigzag(packed)
						else
							restored[index] = dominant
						end
						rows[index][key] = restored[index]
					end

					decodedColumns[key] = restored
				end
			elseif kind == COLUMN_SHARED_STRINGS then
				--[[
					Strings as packed ids into the packet's own string table.
					The strings themselves were written earlier in the packet, so
					every id here must already resolve.
				]]
				local bits = descriptors[1]
				if bits < 1 or bits > MAX_SHARED_ID_BITS then
					error(`Zzzz: shared string id width {bits} out of range`, 0)
				end

				Reader.check(reader, math.ceil(rowCount * bits / 8))

				local accumulator = 0
				local held = 0
				local limit = 2 ^ bits

				for index = 1, rowCount do
					while held < bits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end

					local id = accumulator % limit
					accumulator = (accumulator - id) / limit
					held -= bits

					local entry = ctx.strings[id]
					if entry == nil then
						error(`Zzzz: string reference {id} not defined`, 0)
					end
					rows[index][key] = entry
				end
			elseif kind == COLUMN_DICTIONARY then
				local entryCount = Reader.count(reader, 1)
				--[[
					The encoder caps dictionaries at `MAX_DICTIONARY_ENTRIES` and
					derives the id width from that bound. A packet claiming more
					would make the two disagree about how wide each id is, so it
					is refused rather than decoded into silent nonsense.
				]]
				if entryCount > MAX_DICTIONARY_ENTRIES then
					error(
						`Zzzz: column dictionary claims {entryCount} entries, over the {MAX_DICTIONARY_ENTRIES} cap`,
						0
					)
				end
				local entries = table.create(entryCount)
				for index = 1, entryCount do
					entries[index] = readValue(ctx)
				end
				--[[
					The ids are packed at the narrowest width that holds the
					entry count, which was just read -- so the width is derived
					rather than carried, and the encoder derives it identically.
				]]
				local idBits = 1
				while idBits < MAX_DICTIONARY_ID_BITS and 2 ^ idBits < entryCount do
					idBits += 1
				end

				Reader.check(reader, math.ceil(rowCount * idBits / 8))

				local accumulator, held = 0, 0
				local limit = 2 ^ idBits

				for index = 1, rowCount do
					while held < idBits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end
					local packed = accumulator % limit
					accumulator = (accumulator - packed) / limit
					held -= idBits

					local entry = entries[packed + 1]
					if entry == nil then
						error(`Zzzz: column dictionary has no entry {packed + 1}`, 0)
					end
					rows[index][key] = entry
				end
			elseif kind == COLUMN_BITPACKED then
				--[[
					Fixed-width integers, low bits first, as the encoder wrote
					them. The width comes from the column's plan and is validated
					before use: a corrupt packet claiming 0 or 200 bits would
					otherwise loop forever or read far past the buffer.

					No longer written -- COLUMN_DIFFERENCED at order 0 supersedes
					it -- but still read, so older packets keep decoding.
				]]
				local bits = descriptors[1]
				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: column bit width {bits} out of range`, 0)
				end

				local base = unzigzag(Reader.varint(reader))

				-- Ensure the whole packed run is present before reading it.
				Reader.check(reader, math.ceil(rowCount * bits / 8))

				local accumulator = 0
				local held = 0
				local limit = 2 ^ bits

				for index = 1, rowCount do
					while held < bits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end

					local offset = accumulator % limit
					accumulator = (accumulator - offset) / limit
					held -= bits

					rows[index][key] = base + offset
				end
			elseif
				kind == COLUMN_DELTA_VECTOR3
				or kind == COLUMN_DELTA_VECTOR2
				or kind == COLUMN_DELTA_CFRAME
			then
				--[[
					Positions as deltas from a per-run base. Runs are contiguous
					and in order, so the rows fill front to back.

					The run lengths are summed against the row count rather than
					trusted: a corrupt packet could otherwise claim runs that
					overrun the rows, or stop short and leave holes.
				]]
				local axisCount = if kind == COLUMN_DELTA_VECTOR2 then 2 else 3

				-- A run costs a length plus one byte per base component.
				local runCount = Reader.count(reader, axisCount + 1)

				--[[
					The pseudodecimal scale every base and delta in this column
					was written at -- 0 for the plain integral case, matching
					every packet written before this existed. Applied once at
					reconstruction rather than to the deltas themselves, since
					the deltas and bases already share the scale Columnar chose.
				]]
				local factor = Reader.u8(reader)
				if factor > MAX_DECIMAL_FACTOR then
					error(`Zzzz: delta position factor {factor} out of range`, 0)
				end
				local scale = if factor == 0 then 1 else 10 ^ factor

				local filled = 0

				for _ = 1, runCount do
					--[[
						The width byte has not been read yet, so the tightest
						bound available here is the packed form at its narrowest:
						one bit per component, eight of them to a byte. The exact
						check happens below, once the run's form is known.
					]]
					local runLength = Reader.count(reader, axisCount, 8)
					if filled + runLength > rowCount then
						error("Zzzz: delta position runs overrun the column", 0)
					end

					local baseX = unzigzag(Reader.varint(reader))
					local baseY = unzigzag(Reader.varint(reader))
					local baseZ = if axisCount == 3
						then unzigzag(Reader.varint(reader))
						else 0

					--[[
						Zero means the deltas are individual zigzag varints;
						anything else is the fixed width they are packed at. The
						width is validated before use, since a corrupt packet
						claiming 200 bits would read far past the buffer.
					]]
					local bits = Reader.u8(reader)
					if bits > MAX_PACK_BITS then
						error(`Zzzz: delta bit width {bits} out of range`, 0)
					end

					--[[
						Pull one delta, from whichever form this run uses. The
						packed reader keeps its state in the upvalues below.
					]]
					local accumulator = 0
					local held = 0
					local limit = 2 ^ bits

					local function nextDelta(): number
						if bits == 0 then
							return unzigzag(Reader.varint(reader))
						end

						while held < bits do
							accumulator += Reader.u8(reader) * 2 ^ held
							held += 8
						end

						local packed = accumulator % limit
						accumulator = (accumulator - packed) / limit
						held -= bits
						return unzigzag(packed)
					end

					--[[
						Now the form is known, so the run can be bounded exactly:
						the packed block's byte length, or one byte per component
						at minimum for the varint form.
					]]
					if bits > 0 then
						Reader.check(
							reader,
							math.ceil(runLength * axisCount * bits / 8)
						)
					else
						Reader.check(reader, runLength * axisCount)
					end

					local runStart = filled + 1

					for _ = 1, runLength do
						filled += 1

						if kind == COLUMN_DELTA_VECTOR2 then
							local rawX = baseX + nextDelta()
							local rawY = baseY + nextDelta()
							rows[filled][key] = if factor == 0
								then Vector2.new(rawX, rawY)
								else Vector2.new(rawX / scale, rawY / scale)
							continue
						end

						local x = baseX + nextDelta()
						local y = baseY + nextDelta()
						local z = baseZ + nextDelta()

						if factor ~= 0 then
							x /= scale
							y /= scale
							z /= scale
						end

						if kind == COLUMN_DELTA_VECTOR3 then
							rows[filled][key] = Vector3.new(x, y, z)
							continue
						end

						--[[
							CFrame positions are rebuilt first and the rotations
							applied below, because a packed run carries all of its
							rotations after the bit stream rather than interleaved.
						]]
						rows[filled][key] = Vector3.new(x, y, z)
					end

					--[[
						CFrame rotations, in row order. For a varint run these sit
						between the rows on the wire, but reading them here in the
						same order is equivalent -- and for a packed run it is the
						only correct order, since bits do not stop on byte
						boundaries.
					]]
					if kind == COLUMN_DELTA_CFRAME then
						for row = runStart, filled do
							local position = rows[row][key] :: Vector3

							local rotationId = Reader.u8(reader)
							if rotationId ~= 0 then
								local rotation = ID_TO_ROTATION[rotationId]
								if not rotation then
									error(
										`Zzzz: unknown CFrame rotation id {rotationId}`,
										0
									)
								end
								rows[row][key] = CFrame.new(
									position.X,
									position.Y,
									position.Z
								) * rotation
							else
								local qx, qy, qz, qw =
									CFrameCodec.unpackQuaternion(Reader.u32(reader))
								rows[row][key] = CFrame.new(
									position.X,
									position.Y,
									position.Z,
									qx,
									qy,
									qz,
									qw
								)
							end
						end
					end
				end

				if filled ~= rowCount then
					error(
						`Zzzz: delta position column covered {filled} of {rowCount} rows`,
						0
					)
				end
			elseif kind == COLUMN_DIFFERENCED then
				--[[
					Integers differenced 0, 1 or 2 times, then bit-packed.

					Order 0 is a minimum plus offsets, the same form kind 3
					carries. Above that the packed series holds zigzagged
					differences, and the values come back by running prefix sums
					up through the orders, seeding each with the value the encoder
					set aside.
				]]
				local order = descriptors[1]
				if order > MAX_DIFFERENCE_ORDER then
					error(`Zzzz: difference order {order} out of range`, 0)
				end

				local bits = descriptors[2]
				if bits < 1 or bits > MAX_PACK_BITS then
					error(`Zzzz: column bit width {bits} out of range`, 0)
				end

				local seedCount = if order == 0 then 1 else order
				local seeds = table.create(seedCount)
				for index = 1, seedCount do
					seeds[index] = unzigzag(Reader.varint(reader))
				end

				--[[
					Each difference drops one element, so the packed series is
					shorter than the column by exactly the order.
				]]
				local packedCount = rowCount - order
				if packedCount < 1 then
					error("Zzzz: differenced column is too short for its order", 0)
				end

				Reader.check(reader, math.ceil(packedCount * bits / 8))

				local accumulator = 0
				local held = 0
				local limit = 2 ^ bits
				local series = table.create(packedCount)

				for index = 1, packedCount do
					while held < bits do
						accumulator += Reader.u8(reader) * 2 ^ held
						held += 8
					end

					local packed = accumulator % limit
					accumulator = (accumulator - packed) / limit
					held -= bits

					series[index] = if order == 0
						then seeds[1] + packed
						else unzigzag(packed)
				end

				--[[
					Undo the differencing, innermost order first. Each pass puts
					its seed back at the front and integrates.
				]]
				for level = order, 1, -1 do
					local integrated = table.create(#series + 1)
					local running = seeds[level]
					integrated[1] = running
					for index = 1, #series do
						running += series[index]
						integrated[index + 1] = running
					end
					series = integrated
				end

				for index = 1, rowCount do
					rows[index][key] = series[index]
				end

				-- Kept in case a later column is encoded against this one.
				decodedColumns[key] = series
			elseif kind == COLUMN_BATCHED then
				--[[
					A column of arrays that were written as one block.

					The lengths come first, packed at a width the encoder chose,
					then the concatenation as an ordinary value. Splitting it is
					walking the lengths and taking that many rows for each array.

					The encoder batches only when every array is unshared, so
					handing each slice a fresh table cannot break a reference
					elsewhere in the packet.
				]]
				local lengthBits = Reader.u8(ctx.reader)
				if lengthBits < 1 or lengthBits > 32 then
					error(`Zzzz: batched column has an impossible length width {lengthBits}`, 0)
				end

				local lengths = table.create(rowCount)
				local accumulator, held = 0, 0
				local mask = 2 ^ lengthBits

				for index = 1, rowCount do
					while held < lengthBits do
						accumulator += Reader.u8(ctx.reader) * 2 ^ held
						held += 8
					end
					lengths[index] = accumulator % mask
					accumulator = (accumulator - accumulator % mask) / mask
					held -= lengthBits
				end

				local batchRows = readValue(ctx)
				if type(batchRows) ~= "table" then
					error("Zzzz: batched column did not carry an array", 0)
				end

				--[[
					Sliced back in row order, which is the order they were
					concatenated in. A total that overruns what the block holds
					means the lengths and the block disagree, which is a corrupt
					packet rather than a recoverable state.
				]]
				local cursor = 0
				for index = 1, rowCount do
					local length = lengths[index]
					local inner = table.create(length)
					for slot = 1, length do
						cursor += 1
						local entry = batchRows[cursor]
						if entry == nil then
							error(
								"Zzzz: batched column ran out of rows -- its lengths "
									.. "and its contents disagree",
								0
							)
						end
						inner[slot] = entry
					end
					rows[index][key] = inner
				end
			elseif kind == COLUMN_PLAIN then
				for index = 1, rowCount do
					rows[index][key] = readValue(ctx)
				end
			else
				error(`Zzzz: unknown column kind {kind}`, 0)
			end
		end

		--[[
			Put back the maps the encoder took apart.

			A key holding a dot was hoisted out of a nested map: `stats.health`
			was `stats` holding `health`. The columns carry no marker for this --
			the dotted name is the whole of it -- so rebuilding is a pass over
			the keys, and a shape that never hoisted has no dots and pays a
			single scan.

			Which keys these are came from the shape, not from the text, so a key
			that genuinely contains a dot is left alone.
		]]
		local hoistedKeys: { { any } }? = nil
		for index, key in keys do
			local kind = hoistedAt[index]
			if kind ~= nil then
				if hoistedKeys == nil then
					hoistedKeys = {}
				end
				table.insert(hoistedKeys :: { { any } }, { key, kind })
			end
		end

		if hoistedKeys then
			for _, entry in hoistedKeys do
				local key: string, fromArray: boolean = entry[1], entry[2]

				--[[
					Every dot, not just the first.

					One level of hoisting produces `stats.health`, and the split
					was written for exactly that. A second level produces
					`profile.progress.xp`, and splitting once would rebuild
					`profile` holding a literal key `progress.xp` rather than a
					`progress` holding `xp` -- values in the right place under a
					name that never existed.

					So the name is split into all its parts and walked. A single
					dot yields two parts and behaves exactly as before.
				]]
				local parts: { string } = {}
				local from = 1
				while true do
					local dot = string.find(key, ".", from, true)
					if dot == nil then
						table.insert(parts, string.sub(key, from))
						break
					end
					table.insert(parts, string.sub(key, from, dot - 1))
					from = dot + 1
				end

				for _, part in parts do
					if part == "" then
						error(`Zzzz: hoisted column has an empty name in "{key}"`, 0)
					end
				end
				if #parts < 2 then
					error(`Zzzz: hoisted column "{key}" carries no nesting`, 0)
				end

				--[[
					Only the LAST part can be an array position: the intermediate
					names are the maps the value is nested inside, and the flag
					describes where the value finally sits.
				]]
				local inner = parts[#parts]

				--[[
					A position goes back where it came from, as a number. The
					text is the encoder's own `tostring` of an index, so anything
					else means a hand-made packet.
				]]
				local target: any = inner
				if fromArray then
					local position = tonumber(inner)
					if
						position == nil
						or position < 1
						or position % 1 ~= 0
					then
						error(
							`Zzzz: array hoist "{key}" has a non-index position`,
							0
						)
					end
					target = position
				end

				for index = 1, rowCount do
					local row = rows[index]

					--[[
						Descend through every part but the last, creating the
						maps as they are needed. One level walks once and is
						what this always did; two levels walk twice.
					]]
					local nested: any = row
					for position = 1, #parts - 1 do
						local part = parts[position]
						local step = nested[part]
						if step == nil then
							step = {}
							nested[part] = step
						elseif type(step) ~= "table" then
							error(
								`Zzzz: hoisted column "{key}" collides with a value at "{part}"`,
								0
							)
						end
						nested = step
					end

					nested[target] = row[key]
					row[key] = nil
				end
			end
		end

		--[[
			Positional rows, put back.

			The rows were written under the names "1".."n" so they could use the
			ordinary column machinery; here the names go away again. The rows are
			filled in place rather than replaced, because their ids were claimed
			before any column was read and a reference elsewhere in the packet
			already points at these tables.
		]]
		if fromTuples then
			--[[
				The name is the position spelled out, not the key at that slot:
				the shape's keys are sorted as text, so a ten-wide tuple lists
				"1", "10", "2" and reading them in order would scramble it.
			]]
			local width = #keys
			for index = 1, rowCount do
				local row = rows[index]
				local values = table.create(width)
				for position = 1, width do
					values[position] = row[tostring(position)]
				end
				for position = 1, width do
					row[tostring(position)] = nil
				end
				table.move(values, 1, width, 1, row)
			end
		end

		ctx.depth = depth - 1
		return rows
	end

	if tagByte == Tags.STRUCT_DEF then
		local depth = enterTable(ctx)
		local shapeId = Reader.varint(reader)
		-- Every key is at least a tag byte, and every key needs a value.
		local keyCount = Reader.count(reader, 2)

		local keys = table.create(keyCount)
		for index = 1, keyCount do
			keys[index] = readValue(ctx)
		end
		ctx.shapes[shapeId] = keys

		local result = {}
		local id = ctx.nextTableId + 1
		ctx.nextTableId = id
		ctx.tables[id] = result

		for index = 1, keyCount do
			local key = keys[index]
			local value = readValue(ctx)
			-- A shape's keys are strings when written; a corrupted definition
			-- can hold anything, including values Luau refuses as keys.
			if key ~= nil and key == key then
				result[key] = value
			end
		end

		ctx.depth = depth - 1
		return result
	end

	if tagByte == Tags.STRUCT then
		return readStruct(ctx, Reader.varint(reader))
	end

	if tagByte == Tags.STRUCT_COLUMNS then
		--[[
			A map of same-shaped structs the encoder wrote as columns.

			The payload is an ordinary columnar array whose rows carry their map
			key under a reserved name, so it decodes with the machinery already
			above and what remains is lifting the keys back out.

			The reserved name begins with a NUL, which nothing a caller writes
			can collide with -- so a row missing it is a corrupt packet rather
			than an ambiguous one.
		]]
		local rows = readValue(ctx)
		if type(rows) ~= "table" then
			error("Zzzz: transposed map did not carry an array", 0)
		end

		local out = {}
		for index = 1, #rows do
			local row = rows[index]
			if type(row) ~= "table" then
				error("Zzzz: transposed map holds a row that is not a table", 0)
			end

			local key = row[TRANSPOSE_KEY_FIELD]
			if type(key) ~= "string" then
				error(
					`Zzzz: transposed map row {index} carries no key`,
					0
				)
			end

			row[TRANSPOSE_KEY_FIELD] = nil

			--[[
				A map whose values were ARRAYS travels as rows of a key and
				a list, so what goes back into the map is the list itself
				rather than the row holding it. A map of structs carries no
				items field and the row IS the value.
			]]
			local items = row[TRANSPOSE_ITEMS_FIELD]
			if items ~= nil then
				if type(items) ~= "table" then
					error(
						`Zzzz: transposed map row {index} carries a non-array list`,
						0
					)
				end
				out[key] = items
			else
				out[key] = row
			end
		end

		return out
	end

	if tagByte == Tags.INSTANCE_TREE then
		-- Class name, parent index and four counts is the smallest node.
		local nodeCount = Reader.count(reader, 6)

		-- The same limit the encoder applies. Rebuilding a tree constructs an
		-- Instance per node, which is far more expensive than the bytes that
		-- ask for it, so the bound has to hold in this direction too.
		if nodeCount > ctx.maxNodes then
			error(
				`Zzzz: packet declares {nodeCount} instances, over the {ctx.maxNodes} limit`,
				0
			)
		end

		local nodes = table.create(nodeCount)

		--[[
			Every name in a node -- the class, the properties, the attributes,
			the tags -- is a string when written. A corrupted packet can decode
			any value in those positions, so each is checked rather than used
			directly: a number where a property name belongs would index the
			table with the wrong type and raise from deep inside the rebuild.
		]]
		local function readName(what: string): string
			local name = readValue(ctx)
			if type(name) ~= "string" then
				error(`Zzzz: packet has a non-string {what} in an instance tree`, 0)
			end
			return name
		end

		for index = 1, nodeCount do
			local className = readName("class name")
			local parentIndex = Reader.varint(reader)

			local properties = {}
			local propertyCount = Reader.count(reader, 2)
			for _ = 1, propertyCount do
				local name = readName("property name")
				properties[name] = readValue(ctx)
			end

			local references = {}
			local referenceCount = Reader.count(reader, 3)
			for _ = 1, referenceCount do
				local name = readName("reference name")
				local kind = Reader.u8(reader)
				local target = Reader.varint(reader)
				references[name] = { kind = kind, index = target }
			end

			local attributes = {}
			local attributeCount = Reader.count(reader, 2)
			for _ = 1, attributeCount do
				local name = readName("attribute name")
				attributes[name] = readValue(ctx)
			end

			local tagCount = Reader.count(reader, 1)
			local tags = table.create(tagCount)
			for tagIndex = 1, tagCount do
				tags[tagIndex] = readName("tag")
			end

			nodes[index] = {
				className = className,
				parentIndex = parentIndex,
				properties = properties,
				references = references,
				attributes = attributes,
				tags = tags,
			}
		end

		local root, problems = Instances.rebuild({ nodes = nodes }, ctx.instances)
		for _, problem in problems do
			table.insert(ctx.problems, problem)
		end
		return root
	end

	if tagByte == Tags.TABLE_REF then
		local id = Reader.varint(reader)
		local value = ctx.tables[id]
		if value == nil then
			error(`Zzzz: table reference {id} not defined`, 0)
		end
		return value
	end

	if tagByte == Tags.INSTANCE then
		local id = Reader.varint(reader)
		return ctx.instances[id]
	end

	--[[
		Enum types are interned per packet, so a definition carries the name and
		claims an id, and later items of that type carry only the id. The
		payload is the item's position within its type, not its raw value.
	]]
	if tagByte == Tags.ENUMITEM or tagByte == Tags.ENUMITEM_DEF then
		local typeId = Reader.varint(reader)
		local enumType

		if tagByte == Tags.ENUMITEM_DEF then
			enumType = readEnumType(ctx)
			ctx.enumTypes[typeId] = enumType
		else
			enumType = ctx.enumTypes[typeId]
			if not enumType then
				error(`Zzzz: enum type {typeId} not defined`, 0)
			end
		end

		local index = Reader.varint(reader)
		local item = Enums.itemAt(enumType, index)
		if not item then
			error(`Zzzz: {tostring(enumType)} has no item at index {index}`, 0)
		end
		return item
	end

	if tagByte == Tags.ENUM or tagByte == Tags.ENUM_DEF then
		local typeId = Reader.varint(reader)

		if tagByte == Tags.ENUM_DEF then
			local enumType = readEnumType(ctx)
			ctx.enumTypes[typeId] = enumType
			return enumType
		end

		local enumType = ctx.enumTypes[typeId]
		if not enumType then
			error(`Zzzz: enum type {typeId} not defined`, 0)
		end
		return enumType
	end

	if tagByte == Tags.FONT then
		local family = readValue(ctx)
		local weight = Reader.u8(reader) * 100
		local style = Reader.u8(reader)
		return construct(
			"Font",
			Font.new,
			family,
			Enum.FontWeight:FromValue(weight) or Enum.FontWeight.Regular,
			Enum.FontStyle:FromValue(style) or Enum.FontStyle.Normal
		)
	end

	local datatypeReader = datatypeReaders[tagByte]
	if datatypeReader then
		return datatypeReader(ctx)
	end

	error(`Zzzz: unknown tag {tagByte}`, 0)
end

Decoder.readValue = readValue

function Decoder.decode(
	source: buffer,
	instances: { Instance }?,
	maxDepth: number?,
	maxNodes: number?
): any
	local value = Decoder.decodeWithContext(source, instances, maxDepth, maxNodes)
	return value
end

--[[
	Decode and hand back the context, so callers can inspect any problems
	reported while rebuilding an Instance tree.
]]
function Decoder.decodeWithContext(
	source: buffer,
	instances: { Instance }?,
	maxDepth: number?,
	maxNodes: number?
): (any, Context)
	local reader = Reader.new(source)

	local version = Reader.u8(reader)
	if version ~= Tags.VERSION then
		error(
			`Zzzz: packet format version {version} is not supported (this build reads version {Tags.VERSION})`,
			0
		)
	end

	--[[
		Flag byte:
		  bit 0  the encoder used the structure cache
		  bit 1  a precision value follows, and the packet contains quantized
		         values that cannot be decoded without it
		  bit 2  that precision is a full f64 rather than a single exponent byte
	]]
	local flags = Reader.u8(reader)

	local precision: number? = nil
	if bit32.band(flags, 2) ~= 0 then
		if bit32.band(flags, 4) ~= 0 then
			precision = Reader.f64(reader)
		else
			precision = Quantize.precisionFromCode(Reader.u8(reader))
		end
	end

	local ctx = Decoder.newContext(reader, instances, precision, maxDepth, maxNodes)
	return readValue(ctx), ctx
end

-- Baseline delta -------------------------------------------------------------

local OP_END = 0
local OP_SET = 1
local OP_REMOVE = 2
local OP_DESCEND = 3
local OP_ROWS = 4

local FLAG_DELTA = 8

--[[
	Must match the encoder's cap: the row form's mask covers at most this many
	fields, so a wider mask is a corrupt packet rather than a bigger record.
]]
local DELTA_ROW_MAX_FIELDS = 32

--[[
	Must match the encoder's cap: a row column scales by at most this power of
	ten, so a wider scale is a corrupt packet rather than more precision.
]]
local DELTA_ROW_MAX_FACTOR = 6

--[[
	How a scaled column's integers travelled: absolute or as a delta from the
	baseline, each either as varints or packed at a fixed width. Must match the
	encoder's numbering.
]]
local COLUMN_VARINT_ABSOLUTE = 0
local COLUMN_VARINT_DELTA = 1
local COLUMN_PACKED_ABSOLUTE = 2
local COLUMN_PACKED_DELTA = 3

--[[
	How the changed-row set travelled: a varint gap per changed row, or one bit
	per row of the whole array.
]]
local ROWSET_GAPS = 0
local ROWSET_BITMAP = 1

--[[
	How the field masks travelled. A tick that moves one field of many gives
	every changed row the same mask, which is then written once rather than
	repeated; otherwise they are packed at the record's field count, or written
	as varints when that is no wider.
]]
local MASK_UNIFORM = 0
local MASK_PACKED = 1
local MASK_VARINT = 2

--[[
	What a column carried: values tagged as usual, a plain numeric column, or a
	datatype taken apart into numeric components.
]]
local COLUMN_KIND_TAGGED = 0
local COLUMN_KIND_NUMBER = 1
local COLUMN_KIND_DATATYPE = 2

--[[
	Rebuild a datatype from the components the encoder took it apart into, keyed
	by how many there were and named by the id that follows.

	The order matches Encoder.datatypeColumns' `read`, which is the contract
	between the two -- a component list means nothing without it.
]]
local DATATYPE_BUILDERS: { [number]: (parts: { number }) -> any } = {}

--[[
	How many components each id carries. Read from the id rather than sent, so a
	packet cannot claim a count its type does not have.
]]
local DATATYPE_COUNTS: { [number]: number } = {}

local DATATYPE_VECTOR3 = 1
local DATATYPE_VECTOR2 = 2
local DATATYPE_CFRAME = 3
local DATATYPE_COLOR3 = 4
local DATATYPE_UDIM = 5
local DATATYPE_UDIM2 = 6
local DATATYPE_RECT = 7
local DATATYPE_NUMBERRANGE = 8

DATATYPE_BUILDERS[DATATYPE_VECTOR3] = function(parts)
	return Vector3.new(parts[1], parts[2], parts[3])
end
DATATYPE_BUILDERS[DATATYPE_VECTOR2] = function(parts)
	return Vector2.new(parts[1], parts[2])
end
DATATYPE_BUILDERS[DATATYPE_CFRAME] = function(parts)
	return CFrame.new(parts[1], parts[2], parts[3])
end
DATATYPE_BUILDERS[DATATYPE_COLOR3] = function(parts)
	return Color3.fromRGB(parts[1], parts[2], parts[3])
end
DATATYPE_BUILDERS[DATATYPE_UDIM] = function(parts)
	return UDim.new(parts[1], parts[2])
end
DATATYPE_BUILDERS[DATATYPE_UDIM2] = function(parts)
	return UDim2.new(parts[1], parts[2], parts[3], parts[4])
end
DATATYPE_BUILDERS[DATATYPE_RECT] = function(parts)
	return Rect.new(parts[1], parts[2], parts[3], parts[4])
end
DATATYPE_BUILDERS[DATATYPE_NUMBERRANGE] = function(parts)
	return NumberRange.new(parts[1], parts[2])
end

DATATYPE_COUNTS[DATATYPE_VECTOR3] = 3
DATATYPE_COUNTS[DATATYPE_VECTOR2] = 2
DATATYPE_COUNTS[DATATYPE_CFRAME] = 3
DATATYPE_COUNTS[DATATYPE_COLOR3] = 3
DATATYPE_COUNTS[DATATYPE_UDIM] = 2
DATATYPE_COUNTS[DATATYPE_UDIM2] = 4
DATATYPE_COUNTS[DATATYPE_RECT] = 4
DATATYPE_COUNTS[DATATYPE_NUMBERRANGE] = 2

--[[
	What typeof() a baseline value must be for its components to be readable. A
	field that changed type had its delta anchored at zero by the encoder, so
	the accessor is skipped rather than run on the wrong type.
]]
local EXPECTED_TYPEOF: { [number]: string } = {
	[DATATYPE_VECTOR3] = "Vector3",
	[DATATYPE_VECTOR2] = "Vector2",
	[DATATYPE_CFRAME] = "CFrame",
	[DATATYPE_COLOR3] = "Color3",
	[DATATYPE_UDIM] = "UDim",
	[DATATYPE_UDIM2] = "UDim2",
	[DATATYPE_RECT] = "Rect",
	[DATATYPE_NUMBERRANGE] = "NumberRange",
}

Decoder.FLAG_DELTA = FLAG_DELTA

--[[
	Whether a packet is a patch rather than a whole value.

	Reads the header without consuming the packet, so a caller handed an
	unlabelled buffer can route it correctly.
]]
function Decoder.isDelta(source: buffer): boolean
	if buffer.len(source) < 2 then
		return false
	end
	return bit32.band(buffer.readu8(source, 1), FLAG_DELTA) ~= 0
end

--[[
	Apply one table's ops.

	The baseline is never modified. Each table the patch touches is cloned on
	the way down and every table it does not touch is shared with the baseline,
	so applying a patch costs what changed rather than what exists -- and the
	caller keeps a usable old value.
]]
--[[
	Read a column's integers, packed at a fixed width, low bits first. Mirrors
	writePackedIntegers.
]]
local function readPackedIntegers(
	ctx: Context,
	count: number,
	bits: number
): { number }
	local reader = ctx.reader

	if bits < 1 or bits > MAX_PACK_BITS then
		error(`Zzzz: patch column bit width {bits} out of range`, 0)
	end

	Reader.check(reader, math.ceil(count * bits / 8))

	local values = table.create(count)
	local accumulator = 0
	local held = 0
	local limit = 2 ^ bits

	for index = 1, count do
		while held < bits do
			accumulator += Reader.u8(reader) * 2 ^ held
			held += 8
		end

		local packed = accumulator % limit
		accumulator = (accumulator - packed) / limit
		held -= bits
		values[index] = unzigzag(packed)
	end

	return values
end

--[[
	Apply the row form. Mirrors writeRecordRows:

		the keys, then a scale byte per column
		the row-set form, then the changed rows as gaps or as a bitmap
		a field mask per changed row
		then, column by column, that column's changed values

	Only the rows named are touched; every other row is shared with the baseline
	rather than copied, which is what keeps applying a sparse tick proportional
	to what moved.
]]
local function patchRecordRows(
	ctx: Context,
	baseline: { [any]: any }
): { [any]: any }
	local reader = ctx.reader
	local result = table.clone(baseline)

	local keyCount = Reader.varint(reader)
	if keyCount < 1 or keyCount > DELTA_ROW_MAX_FIELDS then
		error(`Zzzz: patch row field count {keyCount} out of range`, 0)
	end

	local keys = table.create(keyCount)
	for index = 1, keyCount do
		keys[index] = readValue(ctx)
	end

	--[[
		The column plan: what each column carried, and at what scale. A tagged
		column has no scale; a numeric one has a single scale; a datatype one
		names its type and then carries a scale per component.
	]]
	local kinds = table.create(keyCount)
	local datatypes = table.create(keyCount)
	local columnScales = table.create(keyCount)

	for position = 1, keyCount do
		local kind = Reader.u8(reader)
		kinds[position] = kind

		if kind == COLUMN_KIND_TAGGED then
			continue
		end

		local axisCount = 1
		if kind == COLUMN_KIND_DATATYPE then
			local id = Reader.u8(reader)
			local count = DATATYPE_COUNTS[id]
			if count == nil then
				error(`Zzzz: patch column names unknown datatype {id}`, 0)
			end
			datatypes[position] = id
			axisCount = count
		elseif kind ~= COLUMN_KIND_NUMBER then
			error(`Zzzz: unknown patch column kind {kind}`, 0)
		end

		local scales = table.create(axisCount)
		for axis = 1, axisCount do
			local factor = Reader.u8(reader)
			if factor > DELTA_ROW_MAX_FACTOR then
				error(`Zzzz: patch row column scale {factor} out of range`, 0)
			end
			scales[axis] = if factor == 0 then 1 else 10 ^ factor
		end
		columnScales[position] = scales
	end

	local rowCount = #baseline

	--[[
		The changed rows, however they travelled. Both forms produce the same
		ascending list of indices.
	]]
	local rowSet = Reader.u8(reader)
	local changedCount = Reader.count(reader, 1)
	if changedCount > rowCount then
		error("Zzzz: patch changes more rows than the baseline holds", 0)
	end

	local changedRows = table.create(changedCount)

	if rowSet == ROWSET_BITMAP then
		Reader.check(reader, math.ceil(rowCount / 8))

		local found = 0
		local accumulator = 0
		local held = 0

		for index = 1, rowCount do
			if held == 0 then
				accumulator = Reader.u8(reader)
				held = 8
			end
			if accumulator % 2 == 1 then
				found += 1
				if found > changedCount then
					error("Zzzz: patch bitmap names more rows than it declared", 0)
				end
				changedRows[found] = index
			end
			accumulator = (accumulator - accumulator % 2) / 2
			held -= 1
		end

		if found ~= changedCount then
			error("Zzzz: patch bitmap names fewer rows than it declared", 0)
		end
	elseif rowSet == ROWSET_GAPS then
		Reader.check(reader, changedCount)

		local index = 0
		for order = 1, changedCount do
			index += Reader.varint(reader)
			if index < 1 or index > rowCount then
				error(`Zzzz: patch row index {index} is outside the baseline`, 0)
			end
			changedRows[order] = index
		end
	else
		error(`Zzzz: unknown patch row-set form {rowSet}`, 0)
	end

	local limit = 2 ^ keyCount
	local changedMasks = table.create(changedCount)

	--[[
		The masks arrive one of three ways. Mirrors the encoder: a tick where one
		field of many moves has the same mask on every row, and says so once.
	]]
	local maskForm = if changedCount > 0 then Reader.u8(reader) else MASK_VARINT

	if changedCount == 0 then
		-- Nothing to read.
	elseif maskForm == MASK_UNIFORM then
		local mask = Reader.varint(reader)
		if mask >= limit then
			error("Zzzz: patch row mask names fields the row does not have", 0)
		end
		for order = 1, changedCount do
			changedMasks[order] = mask
		end
	elseif maskForm == MASK_PACKED then
		Reader.check(reader, math.ceil(changedCount * keyCount / 8))

		local accumulator = 0
		local held = 0
		for order = 1, changedCount do
			while held < keyCount do
				accumulator += Reader.u8(reader) * 2 ^ held
				held += 8
			end
			local mask = accumulator % limit
			accumulator = (accumulator - mask) / limit
			held -= keyCount
			changedMasks[order] = mask
		end
	elseif maskForm == MASK_VARINT then
		Reader.check(reader, changedCount)
		for order = 1, changedCount do
			local mask = Reader.varint(reader)
			if mask >= limit then
				error("Zzzz: patch row mask names fields the row does not have", 0)
			end
			changedMasks[order] = mask
		end
	else
		error(`Zzzz: unknown patch mask form {maskForm}`, 0)
	end

	--[[
		Rows are cloned up front because the values arrive column by column, so
		a row is filled across several passes rather than in one.
	]]
	for order = 1, changedCount do
		local index = changedRows[order]
		local before = baseline[index]
		if type(before) ~= "table" then
			error("Zzzz: patch row is not a table in the baseline", 0)
		end
		result[index] = table.clone(before)
	end

	--[[
		Pull one component's numbers out of a baseline value, so a delta has
		something to add to. Mirrors Encoder.datatypeColumns' `read`.
	]]
	local function baselineComponent(value: any, id: number?, axis: number): number
		if id == nil then
			return if type(value) == "number" and value == value then value else 0
		end

		--[[
			A field that changed type has no component to subtract, and the
			encoder anchored its delta at zero for exactly that case. Reading the
			accessor here would error on the wrong type instead.
		]]
		if not EXPECTED_TYPEOF[id] or typeof(value) ~= EXPECTED_TYPEOF[id] then
			return 0
		end

		if id == DATATYPE_VECTOR3 then
			local v = value :: Vector3
			return if axis == 1 then v.X elseif axis == 2 then v.Y else v.Z
		elseif id == DATATYPE_VECTOR2 then
			local v = value :: Vector2
			return if axis == 1 then v.X else v.Y
		elseif id == DATATYPE_CFRAME then
			local p = (value :: CFrame).Position
			return if axis == 1 then p.X elseif axis == 2 then p.Y else p.Z
		elseif id == DATATYPE_COLOR3 then
			local c = value :: Color3
			local channel = if axis == 1 then c.R elseif axis == 2 then c.G else c.B
			return math.round(channel * 255)
		elseif id == DATATYPE_UDIM then
			local u = value :: UDim
			return if axis == 1 then u.Scale else u.Offset
		elseif id == DATATYPE_UDIM2 then
			local u = value :: UDim2
			if axis == 1 then
				return u.X.Scale
			elseif axis == 2 then
				return u.X.Offset
			elseif axis == 3 then
				return u.Y.Scale
			end
			return u.Y.Offset
		elseif id == DATATYPE_RECT then
			local r = value :: Rect
			if axis == 1 then
				return r.Min.X
			elseif axis == 2 then
				return r.Min.Y
			elseif axis == 3 then
				return r.Max.X
			end
			return r.Max.Y
		end

		local n = value :: NumberRange
		return if axis == 1 then n.Min else n.Max
	end

	for position = 1, keyCount do
		local key = keys[position]
		local bit = 2 ^ (position - 1)
		local kind = kinds[position]

		if kind == COLUMN_KIND_TAGGED then
			for order = 1, changedCount do
				if bit32.btest(changedMasks[order], bit) then
					result[changedRows[order]][key] = readValue(ctx)
				end
			end
			continue
		end

		--[[
			How many values this column carries, which is what sizes its packed
			blocks -- only the rows whose mask names this field sent one.
		]]
		local present = 0
		for order = 1, changedCount do
			if bit32.btest(changedMasks[order], bit) then
				present += 1
			end
		end

		if present == 0 then
			continue
		end

		local id = datatypes[position]
		local scales = columnScales[position]
		local axisCount = #scales

		--[[
			Each component arrives as its own block, so they are gathered first
			and the values assembled afterwards.
		]]
		local components = table.create(axisCount)

		for axis = 1, axisCount do
			local form = Reader.u8(reader)
			if form > COLUMN_PACKED_DELTA then
				error(`Zzzz: unknown patch column form {form}`, 0)
			end

			local raw: { number }
			if form == COLUMN_PACKED_ABSOLUTE or form == COLUMN_PACKED_DELTA then
				raw = readPackedIntegers(ctx, present, Reader.u8(reader))
			else
				Reader.check(reader, present)
				raw = table.create(present)
				for entry = 1, present do
					raw[entry] = unzigzag(Reader.varint(reader))
				end
			end

			local isDelta = form == COLUMN_VARINT_DELTA or form == COLUMN_PACKED_DELTA
			local scale = scales[axis]
			local resolved = table.create(present)
			local entry = 0

			for order = 1, changedCount do
				if not bit32.btest(changedMasks[order], bit) then
					continue
				end

				entry += 1
				local scaled = raw[entry]

				if isDelta then
					--[[
						A delta is against the baseline's own scaled integer, so
						the baseline is scaled the same way before adding.
					]]
					local before = baselineComponent(baseline[changedRows[order]][key], id, axis)
					local scaledBefore = before * scale
					scaled += if scaledBefore >= 0
						then math.floor(scaledBefore + 0.5)
						else -math.floor(-scaledBefore + 0.5)
				end

				resolved[entry] = scaled / scale
			end

			components[axis] = resolved
		end

		local build = if id then DATATYPE_BUILDERS[id] else nil
		local parts = table.create(axisCount)
		local entry = 0

		for order = 1, changedCount do
			if not bit32.btest(changedMasks[order], bit) then
				continue
			end

			entry += 1
			local index = changedRows[order]

			if build then
				for axis = 1, axisCount do
					parts[axis] = components[axis][entry]
				end
				result[index][key] = build(parts)
			else
				result[index][key] = components[1][entry]
			end
		end
	end

	return result
end

--[[
	A patch is network data like any other packet, and DESCEND recurses.

	Without a bound, a packet carrying a few thousand nested DESCEND ops walks
	this function down until the C stack gives out -- the recursive-graph denial
	of service that deserialization guidance warns about, and one the value
	decoder already defends against with the same counter.
]]
local function patchTable(ctx: Context, baseline: { [any]: any }): { [any]: any }
	ctx.depth += 1
	if ctx.depth > ctx.maxDepth then
		error(`Zzzz: patch nests deeper than the {ctx.maxDepth} limit`, 0)
	end

	--[[
		The row form describes a whole table rather than adding to an op list,
		so it is read here rather than in the loop below and returns directly.
	]]
	local first = Reader.u8(ctx.reader)
	if first == OP_ROWS then
		local rows = patchRecordRows(ctx, baseline)
		ctx.depth -= 1
		return rows
	end

	local result = table.clone(baseline)
	local op = first

	while true do
		if op == OP_END then
			break
		elseif op == OP_SET then
			local key = readValue(ctx)
			result[key] = readValue(ctx)
		elseif op == OP_REMOVE then
			result[readValue(ctx)] = nil
		elseif op == OP_DESCEND then
			local key = readValue(ctx)
			local child = result[key]
			if type(child) ~= "table" then
				error(
					"Zzzz: patch descends into a key the baseline does not hold as a table",
					0
				)
			end
			result[key] = patchTable(ctx, child)
		else
			error(`Zzzz: unknown patch op {op}`, 0)
		end

		op = Reader.u8(ctx.reader)
	end

	ctx.depth -= 1
	return result
end

--[[
	Rebuild a value by applying a patch to the baseline it was built against.

	The baseline must be exactly the value the patch was diffed from. Nothing in
	the packet identifies which one that was -- that contract belongs to the
	layer that owns the connection, the same way it does in any snapshot
	protocol.
]]
function Decoder.patch(
	baseline: any,
	source: buffer,
	instances: { Instance }?,
	maxDepth: number?,
	maxNodes: number?
): any
	local reader = Reader.new(source)

	local version = Reader.u8(reader)
	if version ~= Tags.VERSION then
		error(
			`Zzzz: packet format version {version} is not supported (this build reads version {Tags.VERSION})`,
			0
		)
	end

	local flags = Reader.u8(reader)
	if bit32.band(flags, FLAG_DELTA) == 0 then
		error("Zzzz: Patch was given a whole packet, not a patch -- use Deserialize", 0)
	end

	local precision: number? = nil
	if bit32.band(flags, 2) ~= 0 then
		if bit32.band(flags, 4) ~= 0 then
			precision = Reader.f64(reader)
		else
			precision = Quantize.precisionFromCode(Reader.u8(reader))
		end
	end

	local ctx = Decoder.newContext(reader, instances, precision, maxDepth, maxNodes)

	local op = Reader.u8(reader)
	if op == OP_DESCEND then
		if type(baseline) ~= "table" then
			error("Zzzz: patch expects a table baseline", 0)
		end
		return patchTable(ctx, baseline)
	elseif op == OP_SET then
		return readValue(ctx)
	end

	error(`Zzzz: unknown patch op {op}`, 0)
end

return Decoder
