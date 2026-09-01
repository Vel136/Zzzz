--!strict
--!native
--!optimize 2

--[[
	Value encoder.

	Walks a Luau value and writes it to a Writer. All mutable state lives on
	the context table passed in, never on the module, so two encodes can run
	concurrently without interfering.

	Reference handling: every table is assigned an id the moment it is first
	seen, BEFORE its contents are walked. A table encountered again -- whether
	shared by two fields or reached by a cycle back to itself -- emits a
	TABLE_REF to that id instead of recursing. One mechanism, both features.

	Strings are interned the same way: first occurrence writes the bytes and
	claims an id, later occurrences write a STRING_REF.
]]

local Tags = require(script.Parent.Tags)
local Number = require(script.Parent.Number)
local Writer = require(script.Parent.Writer)
local CFrameCodec = require(script.Parent.Types.CFrameCodec)
local Columnar = require(script.Parent.Types.Columnar)
local Enums = require(script.Parent.Types.Enums)
local Instances = require(script.Parent.Types.Instances)
local Quantize = require(script.Parent.Types.Quantize)

local Encoder = {}

local KEY_BIT = Tags.KEY_BIT
local SMALL_INT_BASE = Tags.SMALL_INT_BASE

export type Options = {
	instanceMode: string?, -- "reference" (default) or "full"
	structureCache: boolean?,
	columnar: boolean?,
	correlate: boolean?,
	precision: number?, -- lossy number quantization; nil means exact
	bitPack: boolean?,
	maxDepth: number?,
	maxNodes: number?,
}

export type Context = {
	writer: Writer.Writer,
	tableIds: { [any]: number },
	nextTableId: number,
	stringIds: { [string]: number },
	nextStringId: number,
	--[[
		The most recently referenced strings, nearest first. Only the folding
		window is kept, so this is a bounded list rather than a full history.
	]]
	recentStrings: { string },
	instances: { Instance },
	instanceIds: { [Instance]: number },
	depth: number,
	maxDepth: number,
	maxNodes: number,
	instanceMode: string,
	precision: number?,
	bitPack: boolean,
	-- Structure cache: maps a shape signature to an id, so a table whose keys
	-- have been seen before sends values only.
	--[[
		Column plans: the descriptive bytes of a column encoding, interned so
		arrays of the same shape holding similar data pay for them once.
	]]
	-- Length of the last bit-packed boolean array, so a repeat can omit it.
	-- The previous new string, for front coding.
	lastNewString: string?,
	lastBooleanCount: number?,
	columnPlans: { [string]: number },
	columnPlanKinds: { [string]: boolean },
	nextColumnPlanId: number,
	shapeIds: { [string]: number },
	shapeKeys: { [number]: { any } },
	nextShapeId: number,
	enumTypeIds: { [any]: number },
	nextEnumTypeId: number,
	structureCache: boolean,
	columnar: boolean,
	correlate: boolean,
	stats: { [string]: number },
	--[[
		Set only while a schema is being derived. `writeColumns` records the form
		each column chose here, keyed by the column's name, so a compiled encoder
		can replay those choices instead of re-deriving them.

		Nil on every ordinary encode, and reading it costs one comparison per
		column when it is nil.
	]]
	planRecord: { [string]: { kind: number, descriptors: { number } } }?,
	--[[
		Set while encoding against a schema. Where a column's key appears here,
		the recorded form is applied directly and the twelve qualifiers are
		skipped; where it does not, the ordinary search runs, so a column the
		sample never contained is still encoded well rather than badly.
	]]
	planSchema: { [string]: { kind: number, descriptors: { number } } }?,
	planFingerprint: number?,
	--[[
		Whether each shape yielded any correlation, keyed by its key names.
		Recorded while deriving a schema and consulted while encoding against
		one, so a shape that found nothing does not pay the quadratic pair
		search again. See `correlationPlan`.
	]]
	correlationRecord: { [string]: boolean }?,
	correlationSchema: { [string]: boolean }?,
	correlationPending: string?,
}

local DEFAULT_MAX_DEPTH = 512
local DEFAULT_MAX_NODES = 100000

--[[
	The changed fraction above which a guarded diff computes the whole encode
	and compares exactly, rather than returning the patch on the strength of the
	fraction alone.

	Lives here because this is where `changedFraction` is produced, and the two
	only mean anything together. Both `Zzzz:Diff` and `Schema:Diff` read it, so
	a single definition keeps them from drifting apart -- a guard that skipped at
	one threshold on one path and another elsewhere would be a guarantee that
	held inconsistently, which is worse than one that does not hold at all.
]]
Encoder.GUARD_VERIFY_FRACTION = 0.5

function Encoder.newContext(options: Options?): Context
	local resolved = options or {}
	return {
		writer = Writer.new(),
		tableIds = {},
		nextTableId = 0,
		stringIds = {},
		nextStringId = 0,
		recentStrings = {},
		instances = {},
		instanceIds = {},
		depth = 0,
		maxDepth = resolved.maxDepth or DEFAULT_MAX_DEPTH,
		maxNodes = resolved.maxNodes or DEFAULT_MAX_NODES,
		instanceMode = resolved.instanceMode or "reference",
		precision = resolved.precision,
		bitPack = resolved.bitPack == true,
		lastNewString = nil,
		lastBooleanCount = nil,
		columnPlans = {},
		columnPlanKinds = {},
		nextColumnPlanId = 0,
		shapeIds = {},
		shapeKeys = {},
		nextShapeId = 0,
		enumTypeIds = {},
		nextEnumTypeId = 0,
		structureCache = resolved.structureCache == true,
		columnar = resolved.columnar == true,
		correlate = resolved.correlate == true,
		-- Benchmark only; see `columnPack` in `writeColumns`.
		noColumnMemo = (resolved :: any).noColumnMemo == true,
		planRecord = nil,
		planSchema = nil,
		planFingerprint = nil,
		correlationRecord = nil,
		correlationSchema = nil,
		correlationPending = nil,
		stats = {},
	}
end

-- Datatype writers ----------------------------------------------------------

--[[
	Keyed by typeof(). Each entry writes its tag (with the key bit already
	applied by the caller) and then its payload.
]]
local datatypeWriters: { [string]: (Context, any, number) -> () } = {}

local function tag(ctx: Context, tagByte: number, keyMark: number): ()
	Writer.u8(ctx.writer, tagByte + keyMark)
end

--[[
	Whether every component is a whole number small enough that zigzag varints
	beat the fixed floats.

	The cutoff is 4 bytes per component, matching f32. Anything wider and the
	exact float form is both smaller and simpler, so it wins.
]]
local zigzag = Quantize.zigzag

--[[
	Shared with the columnar path so the delta's cost model and its packing
	agree with the one the full form uses.
]]
local varintWidth = Columnar.varintWidth
local MAX_PACK_BITS = Columnar.MAX_PACK_BITS
local MAX_DICTIONARY_ID_BITS = Columnar.MAX_DICTIONARY_ID_BITS

local INT_COMPONENT_MAX = 1056959 -- largest value a 3-byte varint holds

local function integralComponents(...: number): boolean
	for index = 1, select("#", ...) do
		local component = select(index, ...)
		if component % 1 ~= 0 then
			return false
		end
		if component > INT_COMPONENT_MAX or component < -INT_COMPONENT_MAX then
			return false
		end
	end
	return true
end

Encoder.integralComponents = integralComponents

datatypeWriters.Vector2 = function(ctx, value: Vector2, keyMark)
	local writer = ctx.writer
	local x, y = value.X, value.Y

	local precision = ctx.precision
	if precision and Quantize.vectorWorthwhile(precision, x, y) then
		tag(ctx, Tags.QUANT_VECTOR2, keyMark)
		Writer.varint(writer, Quantize.encode(x, precision))
		Writer.varint(writer, Quantize.encode(y, precision))
		ctx.stats.quantized = (ctx.stats.quantized or 0) + 1
		return
	end

	-- Lossless integral form, tried before the float form.
	if integralComponents(x, y) then
		tag(ctx, Tags.VECTOR2_INT, keyMark)
		Writer.varint(writer, zigzag(x))
		Writer.varint(writer, zigzag(y))
		return
	end

	tag(ctx, Tags.VECTOR2, keyMark)
	Writer.f32(writer, x)
	Writer.f32(writer, y)
end

datatypeWriters.Vector3 = function(ctx, value: Vector3, keyMark)
	local writer = ctx.writer
	local x, y, z = value.X, value.Y, value.Z

	local precision = ctx.precision
	if precision and Quantize.vectorWorthwhile(precision, x, y, z) then
		tag(ctx, Tags.QUANT_VECTOR3, keyMark)
		Writer.varint(writer, Quantize.encode(x, precision))
		Writer.varint(writer, Quantize.encode(y, precision))
		Writer.varint(writer, Quantize.encode(z, precision))
		ctx.stats.quantized = (ctx.stats.quantized or 0) + 1
		return
	end

	if integralComponents(x, y, z) then
		tag(ctx, Tags.VECTOR3_INT, keyMark)
		Writer.varint(writer, zigzag(x))
		Writer.varint(writer, zigzag(y))
		Writer.varint(writer, zigzag(z))
		return
	end

	tag(ctx, Tags.VECTOR3, keyMark)
	Writer.f32(writer, x)
	Writer.f32(writer, y)
	Writer.f32(writer, z)
end

datatypeWriters.Vector2int16 = function(ctx, value: Vector2int16, keyMark)
	tag(ctx, Tags.VECTOR2INT16, keyMark)
	Writer.i16(ctx.writer, value.X)
	Writer.i16(ctx.writer, value.Y)
end

datatypeWriters.Vector3int16 = function(ctx, value: Vector3int16, keyMark)
	tag(ctx, Tags.VECTOR3INT16, keyMark)
	Writer.i16(ctx.writer, value.X)
	Writer.i16(ctx.writer, value.Y)
	Writer.i16(ctx.writer, value.Z)
end

--[[
	CFrame picks the cheapest of three forms:
	  identity rotation  -> CFRAME_POS, 12 bytes of position only
	  axis-aligned       -> CFRAME + rotation id, 13 bytes
	  anything else      -> CFRAME + 0 + packed quaternion, 17 bytes
]]
datatypeWriters.CFrame = function(ctx, value: CFrame, keyMark)
	local writer = ctx.writer
	local rotationId = CFrameCodec.rotationId(value)
	local position = value.Position

	--[[
		Quantized form: position as three varints, then the same rotation byte
		the exact form uses. Rotation is already only 1 or 5 bytes, so there is
		nothing further to gain there.
	]]
	local precision = ctx.precision
	if
		precision
		and Quantize.vectorWorthwhile(precision, position.X, position.Y, position.Z)
	then
		tag(ctx, Tags.QUANT_CFRAME, keyMark)
		Writer.varint(writer, Quantize.encode(position.X, precision))
		Writer.varint(writer, Quantize.encode(position.Y, precision))
		Writer.varint(writer, Quantize.encode(position.Z, precision))

		if rotationId then
			Writer.u8(writer, rotationId)
		else
			Writer.u8(writer, 0)
			Writer.u32(writer, CFrameCodec.packQuaternion(CFrameCodec.toQuaternion(value)))
		end
		ctx.stats.quantized = (ctx.stats.quantized or 0) + 1
		return
	end

	--[[
		Lossless integral form. Parts placed on whole studs -- most of a built
		map -- pay 4 to 8 bytes here rather than 13 to 18.
	]]
	if integralComponents(position.X, position.Y, position.Z) then
		tag(ctx, Tags.CFRAME_INT, keyMark)
		Writer.varint(writer, zigzag(position.X))
		Writer.varint(writer, zigzag(position.Y))
		Writer.varint(writer, zigzag(position.Z))

		if rotationId then
			Writer.u8(writer, rotationId)
		else
			Writer.u8(writer, 0)
			Writer.u32(writer, CFrameCodec.packQuaternion(CFrameCodec.toQuaternion(value)))
		end
		return
	end

	if rotationId == 1 then
		-- Identity rotation: skip the rotation byte entirely.
		tag(ctx, Tags.CFRAME_POS, keyMark)
		Writer.f32(writer, position.X)
		Writer.f32(writer, position.Y)
		Writer.f32(writer, position.Z)
		return
	end

	tag(ctx, Tags.CFRAME, keyMark)
	Writer.f32(writer, position.X)
	Writer.f32(writer, position.Y)
	Writer.f32(writer, position.Z)

	if rotationId then
		Writer.u8(writer, rotationId)
	else
		Writer.u8(writer, 0)
		Writer.u32(writer, CFrameCodec.packQuaternion(CFrameCodec.toQuaternion(value)))
	end
end

--[[
	Scales that show up constantly in real UI, encoded as a 2-bit code in a
	flag byte instead of a 4-byte float. Code 3 means "not one of these, a
	float follows".
]]
local SCALE_CODES = { [0] = 0, [0.5] = 1, [1] = 2 }
local CODE_SCALES = { [0] = 0, 0.5, 1 }
local SCALE_LITERAL = 3

Encoder.SCALE_CODES = SCALE_CODES
Encoder.CODE_SCALES = CODE_SCALES

--[[
	UDim as a flag byte plus a zigzag varint offset.

	Offsets are integers by definition, so the varint is lossless. A
	non-integral offset cannot occur through the constructor, but guard anyway
	and fall back rather than silently truncating.
]]
datatypeWriters.UDim = function(ctx, value: UDim, keyMark)
	local writer = ctx.writer
	local scale, offset = value.Scale, value.Offset

	if offset % 1 == 0 then
		local code = SCALE_CODES[scale] or SCALE_LITERAL
		tag(ctx, Tags.UDIM_COMPACT, keyMark)
		Writer.u8(writer, code)
		if code == SCALE_LITERAL then
			Writer.f32(writer, scale)
		end
		Writer.varint(writer, zigzag(offset))
		return
	end

	tag(ctx, Tags.UDIM, keyMark)
	Writer.f32(writer, scale)
	Writer.i32(writer, offset)
end

--[[
	UDim2: one flag byte carries both scale codes (2 bits each), then any
	literal scales, then both offsets as zigzag varints.

	UDim2.new(0, 200, 0, 50) goes from 16 payload bytes to 4.
]]
datatypeWriters.UDim2 = function(ctx, value: UDim2, keyMark)
	local writer = ctx.writer
	local x, y = value.X, value.Y

	if x.Offset % 1 == 0 and y.Offset % 1 == 0 then
		local xCode = SCALE_CODES[x.Scale] or SCALE_LITERAL
		local yCode = SCALE_CODES[y.Scale] or SCALE_LITERAL

		tag(ctx, Tags.UDIM2_COMPACT, keyMark)
		Writer.u8(writer, xCode + yCode * 4)

		if xCode == SCALE_LITERAL then
			Writer.f32(writer, x.Scale)
		end
		if yCode == SCALE_LITERAL then
			Writer.f32(writer, y.Scale)
		end

		Writer.varint(writer, zigzag(x.Offset))
		Writer.varint(writer, zigzag(y.Offset))
		return
	end

	tag(ctx, Tags.UDIM2, keyMark)
	Writer.f32(writer, x.Scale)
	Writer.i32(writer, x.Offset)
	Writer.f32(writer, y.Scale)
	Writer.i32(writer, y.Offset)
end

datatypeWriters.Rect = function(ctx, value: Rect, keyMark)
	tag(ctx, Tags.RECT, keyMark)
	local writer = ctx.writer
	Writer.f32(writer, value.Min.X)
	Writer.f32(writer, value.Min.Y)
	Writer.f32(writer, value.Max.X)
	Writer.f32(writer, value.Max.Y)
end

--[[
	Color3 is stored as three bytes when the colour came from a 0-255 triple,
	which covers essentially every colour authored in Studio, and as three
	floats otherwise.

	The test has to be a round-trip, not `channel * 255 == round(channel * 255)`.
	Roblox holds channels as float32, so Color3.fromRGB(255, 128, 0).G * 255
	comes back as 128.0000075698 -- exact comparison fails and every fromRGB
	colour would silently pay 12 bytes instead of 3.
]]
local function color3ToBytes(value: Color3): (number?, number?, number?)
	local r = math.round(value.R * 255)
	local g = math.round(value.G * 255)
	local b = math.round(value.B * 255)

	if r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255 then
		return nil, nil, nil
	end

	-- Only take the byte form if rebuilding from it lands on the same colour.
	local rebuilt = Color3.fromRGB(r, g, b)
	if rebuilt.R == value.R and rebuilt.G == value.G and rebuilt.B == value.B then
		return r, g, b
	end

	return nil, nil, nil
end

datatypeWriters.Color3 = function(ctx, value: Color3, keyMark)
	local writer = ctx.writer
	local r, g, b = color3ToBytes(value)
	if r then
		tag(ctx, Tags.COLOR3_U8, keyMark)
		Writer.u8(writer, r :: number)
		Writer.u8(writer, g :: number)
		Writer.u8(writer, b :: number)
		return
	end

	tag(ctx, Tags.COLOR3, keyMark)
	Writer.f32(writer, value.R)
	Writer.f32(writer, value.G)
	Writer.f32(writer, value.B)
end

datatypeWriters.BrickColor = function(ctx, value: BrickColor, keyMark)
	tag(ctx, Tags.BRICKCOLOR, keyMark)
	Writer.varint(ctx.writer, value.Number)
end

datatypeWriters.NumberRange = function(ctx, value: NumberRange, keyMark)
	tag(ctx, Tags.NUMBERRANGE, keyMark)
	Writer.f32(ctx.writer, value.Min)
	Writer.f32(ctx.writer, value.Max)
end

datatypeWriters.NumberSequenceKeypoint = function(ctx, value: NumberSequenceKeypoint, keyMark)
	tag(ctx, Tags.NUMBERSEQUENCEKEYPOINT, keyMark)
	Writer.f32(ctx.writer, value.Time)
	Writer.f32(ctx.writer, value.Value)
	Writer.f32(ctx.writer, value.Envelope)
end

datatypeWriters.NumberSequence = function(ctx, value: NumberSequence, keyMark)
	tag(ctx, Tags.NUMBERSEQUENCE, keyMark)
	local writer = ctx.writer
	local keypoints = value.Keypoints
	Writer.varint(writer, #keypoints)
	for _, keypoint in keypoints do
		Writer.f32(writer, keypoint.Time)
		Writer.f32(writer, keypoint.Value)
		Writer.f32(writer, keypoint.Envelope)
	end
end

datatypeWriters.ColorSequenceKeypoint = function(ctx, value: ColorSequenceKeypoint, keyMark)
	tag(ctx, Tags.COLORSEQUENCEKEYPOINT, keyMark)
	local writer = ctx.writer
	local color = value.Value
	Writer.f32(writer, value.Time)
	Writer.f32(writer, color.R)
	Writer.f32(writer, color.G)
	Writer.f32(writer, color.B)
end

datatypeWriters.ColorSequence = function(ctx, value: ColorSequence, keyMark)
	tag(ctx, Tags.COLORSEQUENCE, keyMark)
	local writer = ctx.writer
	local keypoints = value.Keypoints
	Writer.varint(writer, #keypoints)
	for _, keypoint in keypoints do
		local color = keypoint.Value
		Writer.f32(writer, keypoint.Time)
		Writer.f32(writer, color.R)
		Writer.f32(writer, color.G)
		Writer.f32(writer, color.B)
	end
end

datatypeWriters.Ray = function(ctx, value: Ray, keyMark)
	tag(ctx, Tags.RAY, keyMark)
	local writer = ctx.writer
	local origin, direction = value.Origin, value.Direction
	Writer.f32(writer, origin.X)
	Writer.f32(writer, origin.Y)
	Writer.f32(writer, origin.Z)
	Writer.f32(writer, direction.X)
	Writer.f32(writer, direction.Y)
	Writer.f32(writer, direction.Z)
end

datatypeWriters.Region3 = function(ctx, value: Region3, keyMark)
	tag(ctx, Tags.REGION3, keyMark)
	local writer = ctx.writer
	-- Region3 exposes CFrame + Size; min/max reconstructs it exactly.
	local center = value.CFrame.Position
	local half = value.Size / 2
	local min, max = center - half, center + half
	Writer.f32(writer, min.X)
	Writer.f32(writer, min.Y)
	Writer.f32(writer, min.Z)
	Writer.f32(writer, max.X)
	Writer.f32(writer, max.Y)
	Writer.f32(writer, max.Z)
end

datatypeWriters.Region3int16 = function(ctx, value: Region3int16, keyMark)
	tag(ctx, Tags.REGION3INT16, keyMark)
	local writer = ctx.writer
	local min, max = value.Min, value.Max
	Writer.i16(writer, min.X)
	Writer.i16(writer, min.Y)
	Writer.i16(writer, min.Z)
	Writer.i16(writer, max.X)
	Writer.i16(writer, max.Y)
	Writer.i16(writer, max.Z)
end

datatypeWriters.Axes = function(ctx, value: Axes, keyMark)
	tag(ctx, Tags.AXES, keyMark)
	local bits = 0
	if value.X then
		bits += 1
	end
	if value.Y then
		bits += 2
	end
	if value.Z then
		bits += 4
	end
	Writer.u8(ctx.writer, bits)
end

datatypeWriters.Faces = function(ctx, value: Faces, keyMark)
	tag(ctx, Tags.FACES, keyMark)
	local bits = 0
	if value.Top then
		bits += 1
	end
	if value.Bottom then
		bits += 2
	end
	if value.Left then
		bits += 4
	end
	if value.Right then
		bits += 8
	end
	if value.Front then
		bits += 16
	end
	if value.Back then
		bits += 32
	end
	Writer.u8(ctx.writer, bits)
end

datatypeWriters.PhysicalProperties = function(ctx, value: PhysicalProperties, keyMark)
	tag(ctx, Tags.PHYSICALPROPERTIES, keyMark)
	local writer = ctx.writer
	Writer.f32(writer, value.Density)
	Writer.f32(writer, value.Friction)
	Writer.f32(writer, value.Elasticity)
	Writer.f32(writer, value.FrictionWeight)
	Writer.f32(writer, value.ElasticityWeight)
end

datatypeWriters.DateTime = function(ctx, value: DateTime, keyMark)
	tag(ctx, Tags.DATETIME, keyMark)
	Writer.f64(ctx.writer, value.UnixTimestampMillis)
end

datatypeWriters.TweenInfo = function(ctx, value: TweenInfo, keyMark)
	tag(ctx, Tags.TWEENINFO, keyMark)
	local writer = ctx.writer
	Writer.f32(writer, value.Time)
	Writer.u8(writer, value.EasingStyle.Value)
	Writer.u8(writer, value.EasingDirection.Value)
	Writer.i32(writer, value.RepeatCount)
	Writer.u8(writer, value.Reverses and 1 or 0)
	Writer.f32(writer, value.DelayTime)
end

--[[
	The remaining datatypes, behind one tag and a sub-type byte.

	These four were unserializable -- a packet holding one raised rather than
	encoding it. They share a tag because the datatype space has a single slot
	left and they are rare enough that one extra byte does not matter beside
	their payloads.

	`Random` is deliberately still refused. Its seed and internal state cannot
	be read back, so a decoded copy could only be a fresh generator agreeing
	with the original about nothing. Returning one anyway would be a silent
	wrong answer where the caller currently gets a clear error.
]]
datatypeWriters.PathWaypoint = function(ctx, value: PathWaypoint, keyMark)
	tag(ctx, Tags.EXTRA_DATATYPE, keyMark)
	local writer = ctx.writer
	Writer.u8(writer, Tags.EXTRA_PATHWAYPOINT)
	Writer.f32(writer, value.Position.X)
	Writer.f32(writer, value.Position.Y)
	Writer.f32(writer, value.Position.Z)
	Writer.u8(writer, value.Action.Value)
	Writer.string(writer, value.Label)
end

--[[
	Instance filters are not carried. `FilterDescendantsInstances` and the newer
	`ExcludeInstances` / `IncludeInstances` hold live references whose meaning
	does not survive the trip, so the params arrive with an empty filter for the
	caller to repopulate. Everything that describes *how* to cast is kept.
]]
datatypeWriters.RaycastParams = function(ctx, value: RaycastParams, keyMark)
	tag(ctx, Tags.EXTRA_DATATYPE, keyMark)
	local writer = ctx.writer
	Writer.u8(writer, Tags.EXTRA_RAYCASTPARAMS)
	Writer.u8(writer, value.FilterType.Value)
	Writer.u8(writer, value.IgnoreWater and 1 or 0)
	Writer.u8(writer, value.RespectCanCollide and 1 or 0)
	Writer.u8(writer, value.BruteForceAllSlow and 1 or 0)
	Writer.string(writer, value.CollisionGroup)
end

datatypeWriters.OverlapParams = function(ctx, value: OverlapParams, keyMark)
	tag(ctx, Tags.EXTRA_DATATYPE, keyMark)
	local writer = ctx.writer
	Writer.u8(writer, Tags.EXTRA_OVERLAPPARAMS)
	Writer.u8(writer, value.FilterType.Value)
	Writer.u8(writer, value.RespectCanCollide and 1 or 0)
	Writer.u8(writer, value.BruteForceAllSlow and 1 or 0)
	Writer.varint(writer, value.MaxParts)
	Writer.string(writer, value.CollisionGroup)
end

datatypeWriters.CatalogSearchParams = function(ctx, value: CatalogSearchParams, keyMark)
	tag(ctx, Tags.EXTRA_DATATYPE, keyMark)
	local writer = ctx.writer
	Writer.u8(writer, Tags.EXTRA_CATALOGSEARCHPARAMS)
	Writer.string(writer, value.SearchKeyword)
	Writer.varint(writer, value.MinPrice)
	Writer.varint(writer, value.MaxPrice)
	Writer.u8(writer, value.SortType.Value)
	Writer.u8(writer, value.SortAggregation.Value)
	Writer.u8(writer, value.CategoryFilter.Value)
	Writer.u8(writer, value.SalesTypeFilter.Value)
	Writer.u8(writer, value.IncludeOffSale and 1 or 0)
	Writer.string(writer, value.CreatorName)

	--[[
		Both filters are lists of enum items, written as their numeric values.
	]]
	local bundleTypes = value.BundleTypes
	Writer.varint(writer, #bundleTypes)
	for _, item in bundleTypes do
		Writer.u8(writer, item.Value)
	end

	local assetTypes = value.AssetTypes
	Writer.varint(writer, #assetTypes)
	for _, item in assetTypes do
		Writer.u8(writer, item.Value)
	end
end

--[[
	Animation curve keys and the Path2D control point.

	Each is a small record of readable properties, so each is written as those
	properties. `RotationCurveKey` holds a CFrame, which goes through the same
	writer any other CFrame does rather than being flattened here.
]]
datatypeWriters.FloatCurveKey = function(ctx, value: FloatCurveKey, keyMark)
	tag(ctx, Tags.EXTRA_DATATYPE, keyMark)
	local writer = ctx.writer
	Writer.u8(writer, Tags.EXTRA_FLOATCURVEKEY)
	Writer.f32(writer, value.Time)
	Writer.f32(writer, value.Value)
	Writer.u8(writer, value.Interpolation.Value)
end

datatypeWriters.ValueCurveKey = function(ctx, value: any, keyMark)
	tag(ctx, Tags.EXTRA_DATATYPE, keyMark)
	local writer = ctx.writer
	Writer.u8(writer, Tags.EXTRA_VALUECURVEKEY)
	Writer.f32(writer, value.Time)
	Writer.f32(writer, value.Value)
	Writer.u8(writer, value.Interpolation.Value)
end

--[[
	The CFrame and the UDim2s are written component by component rather than
	through the value writer, which is declared further down and would be nil
	here. These are rare enough that the compact forms are not worth the
	forward reference.
]]
datatypeWriters.RotationCurveKey = function(ctx, value: RotationCurveKey, keyMark)
	tag(ctx, Tags.EXTRA_DATATYPE, keyMark)
	local writer = ctx.writer
	Writer.u8(writer, Tags.EXTRA_ROTATIONCURVEKEY)
	Writer.f32(writer, value.Time)
	Writer.u8(writer, value.Interpolation.Value)

	local components = { value.Value:GetComponents() }
	for _, component in components do
		Writer.f32(writer, component)
	end
end

datatypeWriters.Path2DControlPoint = function(ctx, value: Path2DControlPoint, keyMark)
	tag(ctx, Tags.EXTRA_DATATYPE, keyMark)
	local writer = ctx.writer
	Writer.u8(writer, Tags.EXTRA_PATH2DCONTROLPOINT)

	for _, udim2 in { value.Position, value.LeftTangent, value.RightTangent } do
		Writer.f32(writer, udim2.X.Scale)
		Writer.i32(writer, udim2.X.Offset)
		Writer.f32(writer, udim2.Y.Scale)
		Writer.i32(writer, udim2.Y.Offset)
	end
end

--[[
	Content refers to an asset either by uri or by a live Object. Only the uri
	form survives a round trip -- an Object reference means nothing once the
	packet is decoded elsewhere -- so an object-backed Content is refused rather
	than silently returned as an empty one.
]]
datatypeWriters.Content = function(ctx, value: Content, keyMark)
	local sourceType = value.SourceType
	if sourceType == Enum.ContentSourceType.Object then
		error("Zzzz: cannot serialize Content backed by an Object", 0)
	end

	tag(ctx, Tags.EXTRA_DATATYPE, keyMark)
	local writer = ctx.writer
	Writer.u8(writer, Tags.EXTRA_CONTENT)
	Writer.u8(writer, sourceType.Value)
	Writer.string(writer, value.Uri or "")
end

Encoder.datatypeWriters = datatypeWriters

-- Core walk -----------------------------------------------------------------

local writeValue: (Context, any, boolean) -> ()

--[[
	Widest record the structure cache will learn, matching Columnar.MAX_KEYS so
	the two paths agree on what counts as a record.
]]
local MAX_SHAPE_KEYS = 256

--[[
	What one value of each type costs the plain form, tag included.

	These are measured, not guessed -- each is the difference between encoding a
	value once and encoding it twice -- and a test pins them so a change to the
	datatype writers cannot leave the dictionary costing the wrong thing. They
	are deliberately conservative: a Vector3 of whole studs writes narrower than
	four bytes, and under-crediting the plain form only makes the dictionary
	harder to choose.
]]
--[[
	Wire ids for the types a column can be split into components.

	Fixed and append-only: the id is what tells the decoder which constructor to
	rebuild with, so renumbering these would silently reinterpret old packets.
]]
local DATATYPE_SPLIT_IDS: { [string]: number } = {
	Rect = 1,
	NumberRange = 2,
	UDim2 = 3,
	UDim = 4,
	Color3 = 5,
}

local DATATYPE_VALUE_BYTES: { [string]: number } = {
	Color3 = 4,
	EnumItem = 3,
	UDim2 = 4,
	UDim = 3,
	Vector3 = 4,
	Vector2 = 3,
	BrickColor = 2,
	Rect = 17,
	NumberRange = 9,
	Font = 4,
}

--[[
	Signature for the structure cache.

	Only tables whose keys are all strings qualify -- those are the record-like
	tables where repeating the keys actually costs something. Keys are sorted
	so that two tables written in different iteration orders still match.

	Keys are length-prefixed rather than joined by a separator. Luau strings
	are byte strings and may contain anything, so a separator-joined signature
	is ambiguous: {x, "y\0z"} and {"x\0y", z} both join to "x\0y\0z" under a
	\0 separator, which would map two different shapes onto one id and decode
	the second table into the wrong fields -- or, measurably, into nothing at
	all. Prefixing each key with its length makes the signature injective.

	Returns nil when the table does not qualify.
]]
local function shapeSignature(value: { [any]: any }, mapCount: number): string?
	--[[
		A one-key table cannot save anything: the definition costs more.

		The upper bound exists because the signature is built and hashed for
		every table, and a very wide one makes that scan expensive for a shape
		unlikely to repeat. It was 64, which is narrow enough to be a cliff on
		ordinary data: two hundred records of seventy fields cost 67,642 bytes
		against 36,257 at sixty-four, because past the cap every record rewrites
		all of its key names.

		Nothing on the wire requires it -- key counts are varints -- so it is
		set where the scan cost is still trivial and real records fit under it.
	]]
	if mapCount < 2 or mapCount > MAX_SHAPE_KEYS then
		return nil
	end

	local keys = table.create(mapCount)
	for key in pairs(value) do
		if type(key) ~= "string" then
			return nil
		end
		table.insert(keys, key)
	end

	table.sort(keys)

	--[[
		Concatenated rather than formatted, which is nearly twice as quick.

		`string.format` parses its template at runtime on every call; the
		concatenation allocates two intermediates and does not. Measured over a
		twelve-key signature, 20,000 times:

			string.format        0.0026 ms
			tostring .. concat   0.0014 ms
			interpolation        0.0017 ms

		Taken because it is one line, not because it matters much: the canonical
		payload builds a couple of thousand signatures, so this is about 2 ms of
		a ~340 ms encode. Worth having, not worth calling an optimisation.
	]]
	local parts = table.create(mapCount)
	for index, key in keys do
		parts[index] = tostring(#key) .. ":" .. key
	end
	return table.concat(parts)
end

local FOLD_STRING_MTF = Tags.FOLD_STRING_MTF
local FOLD_STRING_MTF_COUNT = Tags.FOLD_STRING_MTF_COUNT

--[[
	Move `value` to the front of the recently-used list, and report how far back
	it was. Returns nil when it was not in the window at all.

	The list is capped at the folding width, so this is a scan and a shift over
	at most eight entries -- cheaper than the table churn a full LRU would cost,
	and the entries past the window are exactly the ones the fold cannot encode
	anyway.
]]
local function touchRecent(recent: { string }, value: string): number?
	local found: number? = nil
	for index = 1, #recent do
		if recent[index] == value then
			found = index
			break
		end
	end

	if found then
		table.remove(recent, found)
	elseif #recent >= FOLD_STRING_MTF_COUNT then
		table.remove(recent)
	end

	table.insert(recent, 1, value)

	-- Distances are zero-based: the front of the list is distance 0.
	return if found then found - 1 else nil
end

--[[
	String, with interning. First occurrence writes the bytes; every later
	occurrence writes a reference to the id claimed here.

	A reference to one of the last few strings folds into a single tag byte
	instead. The fold is by distance rather than by id, and it falls back to the
	id form rather than replacing it -- see the Tags commentary for why both of
	those matter.
]]
local function writeString(ctx: Context, value: string, keyMark: number): ()
	if value == "" then
		tag(ctx, Tags.EMPTY_STRING, keyMark)
		return
	end

	local existingId = ctx.stringIds[value]
	if existingId then
		local distance = touchRecent(ctx.recentStrings, value)
		if distance then
			tag(ctx, FOLD_STRING_MTF + distance, keyMark)
			ctx.stats.foldedStrings = (ctx.stats.foldedStrings or 0) + 1
			return
		end

		tag(ctx, Tags.STRING_REF, keyMark)
		Writer.varint(ctx.writer, existingId)
		return
	end

	local id = ctx.nextStringId + 1
	ctx.nextStringId = id
	ctx.stringIds[value] = id
	touchRecent(ctx.recentStrings, value)

	--[[
		Front coding: write only what differs from the previous new string.

		Chosen per string against the plain form, because a shared prefix is not
		guaranteed -- real usernames share almost nothing, and paying a prefix
		byte for a zero-length match would make those larger.
	]]
	local previous = ctx.lastNewString
	if previous then
		local shared = 0
		local limit = math.min(#previous, #value)
		-- Capped at 255 so the prefix length is a single byte.
		if limit > 255 then
			limit = 255
		end
		while shared < limit and string.byte(previous, shared + 1) == string.byte(value, shared + 1) do
			shared += 1
		end

		--[[
			The prefixed form costs a length byte and the suffix; the plain form
			costs the varint length and the whole string. Worth it only once the
			shared head outweighs that extra byte.
		]]
		--[[
			The tail as well, when there is one.

			Front coding leaves a shared ending paid in full every string, and
			endings repeat: a key path, a url, a filename, an id with a suffix.
			The two matches must not overlap -- between them they may claim no
			more than the shorter string -- or the middle would be negative.
		]]
		local tail = 0
		if shared > 1 then
			local tailLimit = math.min(#previous, #value) - shared
			if tailLimit > 255 then
				tailLimit = 255
			end
			while
				tail < tailLimit
				and string.byte(previous, #previous - tail)
					== string.byte(value, #value - tail)
			do
				tail += 1
			end
		end

		--[[
			The affixed form costs one byte more than the prefixed one, so the
			tail has to be longer than that to pay for itself.
		]]
		if tail > 1 then
			ctx.lastNewString = value
			tag(ctx, Tags.STRING_AFFIXED, keyMark)
			Writer.u8(ctx.writer, shared)
			Writer.u8(ctx.writer, tail)
			Writer.string(ctx.writer, string.sub(value, shared + 1, #value - tail))
			ctx.stats.affixedStrings = (ctx.stats.affixedStrings or 0) + 1
			return
		end

		if shared > 1 then
			ctx.lastNewString = value
			tag(ctx, Tags.STRING_PREFIXED, keyMark)
			Writer.u8(ctx.writer, shared)
			Writer.string(ctx.writer, string.sub(value, shared + 1))
			ctx.stats.prefixedStrings = (ctx.stats.prefixedStrings or 0) + 1
			return
		end
	end

	ctx.lastNewString = value
	tag(ctx, Tags.STRING, keyMark)
	Writer.string(ctx.writer, value)
end

--[[
	Identify an enum type, as a global id where possible.

	The engine lists its enum types in sorted order, so numbering that list
	gives both sides the same ids -- two varint bytes at worst, against the ten
	or more the name costs. A zero marker introduces the name form instead,
	which covers a type this build does not list and keeps packets readable
	across engine versions.
]]
local function writeEnumType(ctx: Context, enumType: any): ()
	local globalId = Enums.globalId(enumType)

	if globalId then
		Writer.varint(ctx.writer, globalId)
		return
	end

	Writer.varint(ctx.writer, 0)
	writeString(ctx, tostring(enumType), 0)
end

local function writeNumber(ctx: Context, value: number, keyMark: number): ()
	local writer = ctx.writer

	--[[
		Quantize only non-integers. Integers already have exact encodings that
		are at least as small, and rounding them would lose information for no
		benefit at all.
	]]
	local precision = ctx.precision
	if precision and value % 1 ~= 0 and Quantize.isWorthwhile(value, precision) then
		Writer.u8(writer, Tags.QUANT_NUMBER + keyMark)
		Writer.varint(writer, Quantize.encode(value, precision))
		ctx.stats.quantized = (ctx.stats.quantized or 0) + 1
		return
	end

	local tagByte = Number.selectTag(value)

	Writer.u8(writer, tagByte + keyMark)

	-- Singletons and folded small integers carry no payload.
	if tagByte >= SMALL_INT_BASE and tagByte <= SMALL_INT_BASE + Tags.SMALL_INT_MAX then
		return
	end
	if
		tagByte == Tags.NAN
		or tagByte == Tags.INF
		or tagByte == Tags.NEG_INF
		or tagByte == Tags.NEG_ZERO
	then
		return
	end

	if tagByte == Tags.U8 then
		Writer.u8(writer, value)
	elseif tagByte == Tags.U16 then
		Writer.u16(writer, value)
	elseif tagByte == Tags.U32 then
		Writer.u32(writer, value)
	elseif tagByte == Tags.I8 then
		Writer.i8(writer, value)
	elseif tagByte == Tags.I16 then
		Writer.i16(writer, value)
	elseif tagByte == Tags.I32 then
		Writer.i32(writer, value)
	elseif tagByte == Tags.VARINT then
		Writer.varint(writer, value)
	elseif tagByte == Tags.NEG_VARINT then
		Writer.varint(writer, -value)
	elseif tagByte == Tags.F32 then
		Writer.f32(writer, value)
	else
		Writer.f64(writer, value)
	end
end

--[[
	Split a table into its array part and its map part.

	The array part is the run 1..n with no holes. Everything else -- string
	keys, [0], negative and fractional indices, and anything past a hole -- is
	a map entry. This keeps sparse tables faithful rather than silently
	dropping their gaps.
]]
--[[
	Write a run of booleans as one bit each, eight to a byte.
]]
local function writeBooleanBits(ctx: Context, values: { any }, count: number): ()
	local writer = ctx.writer
	local byte = 0
	local bit = 0

	for index = 1, count do
		if values[index] then
			byte += 2 ^ bit
		end
		bit += 1
		if bit == 8 then
			Writer.u8(writer, byte)
			byte, bit = 0, 0
		end
	end

	if bit > 0 then
		Writer.u8(writer, byte)
	end
end

--[[
	Write an array of uniform records as one column per key.

	Layout, after the tag:

		shape id, [key count, keys...] on first use
		row count
		per column: a kind byte, then the column's values

	Column kinds:
		0  plain      -- each value written normally
		1  booleans   -- bit-packed, one bit per row
		2  dictionary -- distinct values once, then an index per row
		3  bitpacked  -- integers at a fixed bit width, as offsets from a base
		4  delta vec3 -- Vector3s as deltas from a per-run base
		5  delta vec2 -- Vector2s, the same way
		6  delta cf   -- CFrame positions the same way, rotations carried as-is
		7  differenced -- integers differenced 0, 1 or 2 times, then bit-packed
		8  correlated  -- integers as a residual against another column
		9  shared ids  -- strings as packed ids into the packet's string table
		10 frequency   -- one dominant value, a bitmap, then the exceptions
		11 mapped      -- values looked up from another column, plus exceptions

	The columns follow the sorted key order recorded with the shape, so the
	decoder knows which column belongs to which key without repeating names.
]]
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
--[[
	A column that repeats on a fixed period. See `Columnar.cyclicFor` for why
	no existing form saw these and what they are worth -- an entropy floor put
	a `levels 1-60` column at 51.7x its theoretical minimum, the widest gap
	measured anywhere in the library, and this closes 98.3% of it.
]]
local COLUMN_CYCLIC = 22

--[[
	A column of arrays, written as one table plus the lengths that split it.

	Every other form here encodes a column of VALUES. This one encodes a column
	of arrays -- two thousand inventories, a quest log per player -- by
	concatenating them into a single columnar block and writing a vector saying
	where each one ended.

	Measured on the canonical payload's inventories, 29,867 items across 2,000
	arrays:

		as separate arrays    93,219 bytes    125.05 ms
		batched               72,395           52.93

	The saving is not framing, though there is framing in it. Split, the encoder
	wrote 7,547 columns of about fourteen values; batched, four columns of
	thirty thousand. A dictionary of twenty item names is free at that length and
	impossible at fourteen, so 1,996 shared-string columns became one dictionary.
	The forms a long column can afford are the whole of the difference.
]]
local COLUMN_BATCHED = 23

--[[
	Which form carried a flat numeric array. A byte rather than a plan, because
	these arrays are written wherever they appear rather than in a shape's
	column order, so there is nothing to intern the choice against.
]]
local NUMBER_ARRAY_DECIMAL = 0
local NUMBER_ARRAY_DIFFERENCED = 1

--[[
	A flat array pays a tag and up to eight bytes for every value it holds, and
	the column framing is about seven bytes in total, so the trade is repaid at
	two values and grows from there. Measured against the plain form:

		2 floats   18 B -> 11 B      6 floats   54 B -> 19 B
		4 floats   36 B -> 15 B      8 floats   72 B -> 22 B

	The qualifiers still decide; this only stops the arrays too short to hold a
	saving from being costed at all.
]]
local NUMBER_ARRAY_MIN_ROWS = 2

Encoder.COLUMN_PLAIN = COLUMN_PLAIN
Encoder.COLUMN_BOOLEANS = COLUMN_BOOLEANS
Encoder.COLUMN_DICTIONARY = COLUMN_DICTIONARY
Encoder.COLUMN_BITPACKED = COLUMN_BITPACKED
Encoder.COLUMN_DELTA_VECTOR3 = COLUMN_DELTA_VECTOR3
Encoder.COLUMN_DELTA_VECTOR2 = COLUMN_DELTA_VECTOR2
Encoder.COLUMN_DELTA_CFRAME = COLUMN_DELTA_CFRAME
Encoder.COLUMN_DIFFERENCED = COLUMN_DIFFERENCED
Encoder.COLUMN_CORRELATED = COLUMN_CORRELATED
Encoder.COLUMN_SHARED_STRINGS = COLUMN_SHARED_STRINGS
Encoder.COLUMN_FREQUENCY = COLUMN_FREQUENCY
Encoder.COLUMN_MAPPED = COLUMN_MAPPED
Encoder.COLUMN_MULTI_MAPPED = COLUMN_MULTI_MAPPED
Encoder.COLUMN_DICTIONARY_FOR = COLUMN_DICTIONARY_FOR
Encoder.COLUMN_EQUALITY = COLUMN_EQUALITY
Encoder.COLUMN_RUN_LENGTH = COLUMN_RUN_LENGTH
Encoder.COLUMN_DECIMAL = COLUMN_DECIMAL
Encoder.COLUMN_OPTIONAL = COLUMN_OPTIONAL
Encoder.COLUMN_DATE = COLUMN_DATE
Encoder.COLUMN_PREFIXED_INT = COLUMN_PREFIXED_INT
Encoder.COLUMN_DATATYPE_DICT = COLUMN_DATATYPE_DICT
Encoder.COLUMN_DATATYPE_SPLIT = COLUMN_DATATYPE_SPLIT

--[[
	COLUMN_BITPACKED is no longer written: COLUMN_DIFFERENCED at order 0 is the
	same form plus an order byte, and it can reach the differenced orders that a
	fixed frame of reference cannot. The decoder still reads kind 3, so packets
	written before this change keep decoding.
]]

--[[
	Write a column of positions as deltas from a per-run base.

	Layout, after the kind byte:

		run count
		per run: length, the base's components, a width byte, then the deltas

	The width byte is 0 when each delta is its own zigzag varint, and n when all
	of them are packed at a fixed n bits -- the cascade Parquet calls
	DELTA_BINARY_PACKED. Columnar picks whichever is smaller per run.

	Runs are contiguous and in the original order, so the decoder walks them
	front to back and never needs a per-row cluster id. The Columnar qualifier
	has already proved this is smaller than the plain form.

	`components` pulls one row's numbers out, so the same writer serves Vector2,
	Vector3 and CFrame positions. `afterRow` writes anything the datatype carries
	beyond position -- a CFrame's rotation -- immediately after that row's deltas.

	`afterRow` output always follows the whole run's deltas rather than
	interleaving with them. A packed run has no byte boundary between rows to
	interrupt, so it could not interleave; writing the varint form the same way
	keeps one layout for the decoder to mirror.

	`factor` is the shared pseudodecimal scale Columnar.decimalAxes found, 0
	when the column was already integral. It is written once, up front, so
	the decoder knows to divide every reconstructed component by 10^factor --
	the same scale-and-verify technique decimalFor uses for a lone numeric
	column, extended to a whole row of axes at once. `components` still reads
	the original unscaled value, so it is scaled here to match `run.base`,
	which Columnar already produced in scaled integer terms.
]]
local function writeDeltaRuns(
	ctx: Context,
	values: { any },
	runs: { Columnar.DeltaRun },
	components: (any, { number }) -> (),
	factor: number,
	afterRow: ((any) -> ())?
): ()
	local writer = ctx.writer
	local scratch = table.create(3)
	local scale = if factor == 0 then 1 else 10 ^ factor

	Writer.varint(writer, #runs)
	Writer.u8(writer, factor)

	local index = 1
	for _, run in runs do
		local base = run.base
		local axisCount = #base
		local bits = run.bits

		Writer.varint(writer, run.count)
		for axis = 1, axisCount do
			Writer.varint(writer, zigzag(base[axis]))
		end

		Writer.u8(writer, bits or 0)

		local runStart = index

		if not bits then
			for _ = 1, run.count do
				components(values[index], scratch)
				for axis = 1, axisCount do
					local scaled = if factor == 0 then scratch[axis] else math.round(scratch[axis] * scale)
					Writer.varint(writer, zigzag(scaled - base[axis]))
				end
				index += 1
			end
		else
			--[[
				Packed form. Bits fill from the low end of the accumulator upward
				and spill a byte at a time, matching writeBitPacked and the order
				the reader consumes them.
			]]
			local accumulator = 0
			local held = 0

			for _ = 1, run.count do
				components(values[index], scratch)
				for axis = 1, axisCount do
					local scaled = if factor == 0 then scratch[axis] else math.round(scratch[axis] * scale)
					accumulator += zigzag(scaled - base[axis]) * 2 ^ held
					held += bits

					while held >= 8 do
						Writer.u8(writer, accumulator % 256)
						accumulator = (accumulator - accumulator % 256) / 256
						held -= 8
					end
				end
				index += 1
			end

			if held > 0 then
				Writer.u8(writer, accumulator % 256)
			end
		end

		-- Anything trailing the positions follows the run's deltas, in row order.
		if afterRow then
			for offset = 0, run.count - 1 do
				afterRow(values[runStart + offset])
			end
		end
	end
end

local function vector3Components(entry: any, out: { number }): ()
	local value = entry :: Vector3
	out[1], out[2], out[3] = value.X, value.Y, value.Z
end

local function vector2Components(entry: any, out: { number }): ()
	local value = entry :: Vector2
	out[1], out[2] = value.X, value.Y
end

local function cframeComponents(entry: any, out: { number }): ()
	local position = (entry :: CFrame).Position
	out[1], out[2], out[3] = position.X, position.Y, position.Z
end

--[[
	A CFrame's rotation, in the same shape the single-value forms use: an
	axis-aligned id, or a zero marker followed by a packed quaternion.
]]
local function writeRotation(ctx: Context, value: CFrame): ()
	local writer = ctx.writer
	local rotationId = CFrameCodec.rotationId(value)

	if rotationId then
		Writer.u8(writer, rotationId)
	else
		Writer.u8(writer, 0)
		Writer.u32(writer, CFrameCodec.packQuaternion(CFrameCodec.toQuaternion(value)))
	end
end

--[[
	Write an integer column differenced `order` times, then bit-packed.

	Layout, after the kind byte:

		order byte, width byte
		order 0: the minimum, as a zigzag varint
		order 1+: one seed per order, as zigzag varints
		then the packed series

	Order 0 packs value - min, which is what COLUMN_BITPACKED does. Orders above
	that pack zigzagged differences, so the decoder rebuilds by running prefix
	sums back up through the orders.
]]
--[[
	Whether a recorded differenced plan still fits, and the seeds it needs.

	`differencedPackFor` searches for the best order and width. This does
	neither: it differences the column to the order the schema recorded and
	checks the results against the width the schema recorded, which is all that
	replaying a plan requires. The search over orders and the cost comparison
	between them are what a schema exists to skip.

	Returns nil when the column is not integral, or when the differences no
	longer fit -- both meaning the schema no longer describes this data, and the
	caller falls back to deriving a fresh plan.

	The check cannot be skipped. A width that fitted the sample is a fact about
	the sample, and writing a value that exceeds it truncates silently: the
	packet decodes cleanly and the number is wrong. Measured, the check costs
	nothing, because the column has to be walked to be written regardless.
]]
local function differencedSeedsFor(
	column: { any },
	rowCount: number,
	order: number,
	bits: number
): ({ number }?, boolean)
	if rowCount < 2 and order > 0 then
		return nil, false
	end

	--[[
		Order 0 packs value - min, so the seed is the minimum and the check is
		against the span rather than against differences.
	]]
	if order == 0 then
		local low = math.huge
		local high = -math.huge
		for index = 1, rowCount do
			local entry = column[index]
			if type(entry) ~= "number" or entry % 1 ~= 0 then
				return nil, false
			end
			if entry < low then
				low = entry
			end
			if entry > high then
				high = entry
			end
		end
		if high - low >= 2 ^ bits then
			return nil, false
		end
		return { low }, true
	end

	--[[
		Higher orders difference repeatedly, keeping the first element of each
		round as its seed. The series is rebuilt here rather than shared with
		`writeDifferenced`, which builds its own -- two walks over a column that
		is at most a few thousand values, against the twelve qualifiers and
		three-order search this replaces.
	]]
	local series: { number } = table.create(rowCount)
	for index = 1, rowCount do
		local entry = column[index]
		if type(entry) ~= "number" or entry % 1 ~= 0 then
			return nil, false
		end
		series[index] = entry
	end

	local seeds = table.create(order)
	for _ = 1, order do
		local length = #series
		if length < 2 then
			return nil, false
		end
		table.insert(seeds, series[1])

		local differences = table.create(length - 1)
		for index = 2, length do
			differences[index - 1] = series[index] - series[index - 1]
		end
		series = differences
	end

	local limit = 2 ^ bits
	for index = 1, #series do
		local value = series[index]
		local zigzagged = if value < 0 then -value * 2 - 1 else value * 2
		if zigzagged >= limit then
			return nil, false
		end
	end

	return seeds, true
end

local function writeDifferenced(
	ctx: Context,
	column: { any },
	rowCount: number,
	order: number,
	seeds: { number },
	bits: number
): ()
	local writer = ctx.writer

	-- Order and width travel in the column's plan, not here.
	for _, seed in seeds do
		Writer.varint(writer, zigzag(seed))
	end

	--[[
		Build the series that actually gets packed: the values offset by their
		minimum at order 0, or the differences of differences above that.
	]]
	local series = table.create(rowCount)
	if order == 0 then
		local minimum = seeds[1]
		for index = 1, rowCount do
			series[index] = column[index] - minimum
		end
	else
		for index = 1, rowCount do
			series[index] = column[index]
		end
		for _ = 1, order do
			local length = #series
			local differences = table.create(length - 1)
			for index = 2, length do
				differences[index - 1] = series[index] - series[index - 1]
			end
			series = differences
		end
		for index = 1, #series do
			series[index] = zigzag(series[index])
		end
	end

	--[[
		Bits fill from the low end of the accumulator upward and spill a byte at
		a time, matching writeBitPacked and the order the reader consumes them.
	]]
	local accumulator = 0
	local held = 0

	for index = 1, #series do
		accumulator += series[index] * 2 ^ held
		held += bits

		while held >= 8 do
			Writer.u8(writer, accumulator % 256)
			accumulator = (accumulator - accumulator % 256) / 256
			held -= 8
		end
	end

	if held > 0 then
		Writer.u8(writer, accumulator % 256)
	end
end

--[[
	Write a column as a residual against another column.

	The residual is `value - (slope * reference + intercept)`, zigzagged and
	packed at a fixed width, in the same low-bits-first order every other packed
	form uses.
]]
local function writeCorrelated(
	ctx: Context,
	column: { any },
	reference: { number },
	rowCount: number,
	slope: number,
	intercept: number,
	bits: number
): ()
	local writer = ctx.writer
	local accumulator = 0
	local held = 0

	for index = 1, rowCount do
		local residual = column[index] - (slope * reference[index] + intercept)
		accumulator += zigzag(residual) * 2 ^ held
		held += bits

		while held >= 8 do
			Writer.u8(writer, accumulator % 256)
			accumulator = (accumulator - accumulator % 256) / 256
			held -= 8
		end
	end

	if held > 0 then
		Writer.u8(writer, accumulator % 256)
	end
end

--[[
	What an integer column costs under the best form that does not depend on
	another column: the packed and differenced orders, or plain tags.

	Frequency and correlation both need something to beat, and it has to be the
	same number the encoder would otherwise emit -- not the plain cost, which
	would make them look better than they are.
]]
local function columnSoloBytes(column: { any }): number
	local plainBytes = 0
	for index = 1, #column do
		local entry = column[index]
		if type(entry) ~= "number" or entry % 1 ~= 0 then
			return math.huge
		end
		plainBytes += Columnar.integerCost(entry)
	end

	local _, _, _, saving = Columnar.differencedPackFor(column)
	return plainBytes - (saving or 0)
end

--[[
	What a column of any type costs without a mapping, near enough to compare.

	Strings go through the packet's string table, so a repeat costs its packed
	id; numbers go through the packed and differenced forms; anything else pays a
	tag and its payload. This only has to be good enough to rank one form against
	another, and it is never optimistic about the alternative.
]]
--[[
	How many distinct values a column holds, for the cost estimates that size a
	dictionary by it.
]]
local function distinctOf(column: { any }): number
	local seen: { [any]: boolean } = {}
	local distinct = 0
	for index = 1, #column do
		local entry = column[index]
		--[[
			A column may hold holes -- an optional key absent on this row -- and
			a hole is not a value to count. Neither a hole nor a NaN can index
			`seen`, which is what made this throw rather than merely miscount.
			Both are counted as distinct rather than skipped, since a column
			holding them is one no dictionary form will take anyway.
		]]
		if entry == nil then
			-- A hole is not a value, so it is not a distinct one either.
		elseif entry ~= entry then
			-- Every NaN counts as its own, which is what refuses a dictionary.
			distinct += 1
		elseif not seen[entry] then
			seen[entry] = true
			distinct += 1
		end
	end
	return distinct
end

local function columnAnySoloBytes(ctx: Context, column: { any }, distinct: number): number
	local first = column[1]
	local kind = typeof(first)

	if kind == "number" then
		local solo = columnSoloBytes(column)
		--[[
			`columnSoloBytes` gives up on a fractional value and returns
			infinity, which is the right answer for the integer forms and the
			wrong one here: a float column is not free to carry, it costs a tag
			and eight bytes a row, and the decimal form may carry it for far
			less.

			Left as infinity, every correlation form sees an unbounded saving
			against it and takes the column before the decimal form is even
			offered. That is what made `Correlate` cost 4,295 bytes on the
			canonical benchmark once hoisting exposed a float column to the
			pairwise search.
		]]
		if solo == math.huge then
			return #column * 9
		end
		return solo
	end

	if kind == "string" then
		local bits = 1
		while bits < 32 and 2 ^ bits <= distinct do
			bits += 1
		end
		local total = math.ceil(#column * bits / 8) + 1
		--[[
			Whichever distinct strings are new still have to appear somewhere, so
			they are counted against both forms and cancel out. Only the ones
			already interned are free.
		]]
		return total
	end

	if kind == "boolean" then
		return math.ceil(#column / 8)
	end

	-- Datatypes: a tag and a payload each, which the mapping replaces entirely.
	return #column * 4
end


--[[
	Decide which columns are worth encoding against which others.

	Three things make this more than a nested loop.

	COST. A candidate is only accepted when the fitted residual is provably
	smaller than encoding the column alone, using the same modelled byte counts
	every other column form is chosen by.

	PRUNING. Costing every ordered pair is quadratic in the number of keys and
	linear in rows on top. A correlation coefficient is one cheap pass and
	rejects almost everything: on a realistic shape it left five pairs of a
	hundred and twenty-two while keeping 98% of the available bytes.

	CYCLES. The search naturally finds both directions of a relationship --
	health from maxHealth and maxHealth from health -- and a decoder can resolve
	neither. Candidates are taken strongest first and any that would close a
	cycle is dropped, so the result is a forest: every column has at most one
	reference, and following references always terminates.
]]
local CORRELATION_MIN_R = 0.9

--[[
	A column's mean and variance, which do not depend on what it is paired with.

	The coefficient below needs both for each side. Computed inside it, they are
	recomputed for every pair the search considers -- so a shape with sixteen
	numeric columns walks each column thirty times to derive the same two numbers
	each time. Hoisting them to the caller makes the per-pair work one pass for
	the covariance alone.

	Variance is accumulated against the mean rather than as the sum of squares,
	which is the numerically stable form: the textbook `E[x^2] - E[x]^2` cancels
	catastrophically on columns whose values are large and close together, and a
	tick counter or a world coordinate is exactly that.
]]
local function columnMoments(values: { number }, count: number): (number, number)
	local sum = 0
	for index = 1, count do
		sum += values[index]
	end
	local mean = sum / count

	local variance = 0
	for index = 1, count do
		local difference = values[index] - mean
		variance += difference * difference
	end

	return mean, variance
end

--[[
	Pearson's r, given each column's mean and variance already.

	Note that no sampled form of this is offered. A sampled coefficient is an
	estimate, not a bound -- it can fall on either side of the real value -- so
	rejecting a pair on one would discard real correlations, which is the failure
	`mappedRuledOut` documents at length. The pair work here is one pass, and the
	passes it used to repeat are hoisted into `columnMoments` instead.
]]
local function correlationCoefficient(
	a: { number },
	b: { number },
	count: number,
	meanA: number,
	varianceA: number,
	meanB: number,
	varianceB: number
): number
	local denominator = math.sqrt(varianceA * varianceB)
	if denominator == 0 then
		return 0
	end

	local covariance = 0
	for index = 1, count do
		covariance += (a[index] - meanA) * (b[index] - meanB)
	end

	return covariance / denominator
end

type CorrelationLink = {
	referenceKey: string,
	referenceIndex: number,
	slope: number,
	intercept: number,
	bits: number,
	mapped: Columnar.MappedPlan?,
	multiMapped: Columnar.MultiMappedPlan?,
	dictionaryFor: Columnar.DictionaryForPlan?,
	equality: Columnar.EqualityPlan?,
}

--[[
	`hoisted` carries the columns lifted out of nested maps, whose keys do not
	exist on the rows themselves. Reading through it keeps every form below --
	correlated, mapped, equal -- available to a hoisted field.
]]
local function correlationPlan(
	ctx: Context,
	value: { [any]: any },
	rowCount: number,
	keys: { string },
	hoisted: { [string]: { any } },
	--[[
		Which hoisted keys came from an ARRAY rather than a nested map.

		Hoisting a fixed-length array turns each element into a column of its
		own, and the pair search is quadratic in the column count -- so a
		forty-element achievements array contributes 1,560 ordered pairs by
		itself, against 110 for the eleven fields the record actually declares.

		Measured on the canonical payload: hoisting takes the search from 11
		columns to 52, which is 24x the pairs, and that -- not the number of
		column forms -- is where `Correlate`'s time goes.
	]]
	hoistedFromArray: { [string]: boolean }?
): ({ [any]: any }, { string })
	local plan: { [any]: any } = { referenced = {} }

	local function cellOf(row: number, key: string): any
		local lifted = hoisted[key]
		if lifted then
			return lifted[row]
		end
		return value[row][key]
	end

	--[[
		`CORRELATION_MIN_ROWS` is what keeps this affordable on a payload of
		many small arrays. Measured on 900 arrays of correlated columns:

			rows each    overhead    searches run    bytes saved
			        8        1.0x               0              0
			       20        1.0x               0              0
			       32        1.0x               0              0
			       64        1.5x             514         28,651

		Below the minimum nothing runs and nothing is lost, because a short
		array cannot pay a correlated form's framing whatever it holds. See the
		constant's own note for the byte measurements behind it.
	]]
	if not ctx.correlate or rowCount < Columnar.CORRELATION_MIN_ROWS then
		return plan, keys
	end

	--[[
		A schema that found no correlations skips the search entirely.

		`correlationPlan` is quadratic in the column count and runs over every
		row, and the schema did not record its result -- so `Schema:Encode` paid
		the whole pair search on every call while replaying only the column
		forms. On the canonical payload that is most of what the encode costs:
		Correlate is about 650 ms against Columnar's 200, and the schema encode
		sat at 620 because the search dominated whatever the replay saved.

		Batching is what made this matter. Two thousand inventories of fifteen
		rows were all below `CORRELATION_MIN_ROWS`, so the search never ran on
		them; concatenated into one block of thirty thousand they are far above
		it, and the search runs on columns two thousand times longer.

		So the schema records whether a shape yielded any correlation at all,
		keyed by the shape's own signature. A shape that found none last time
		will find none again on data of the same shape -- and if the data has
		changed enough to disagree, the cost is a correlation not taken, which
		is bytes rather than corruption.
	]]
	local correlationRecord = ctx.correlationRecord
	local correlationSchema = ctx.correlationSchema

	if correlationRecord ~= nil or correlationSchema ~= nil then
		--[[
			The shape's identity, which is what the record is keyed by. Built
			from the key names because two arrays of one shape produce one entry
			rather than one each.
		]]
		local parts = table.create(#keys)
		for index, key in keys do
			parts[index] = key
		end
		local shapeKey = table.concat(parts, "\0")

		if correlationSchema ~= nil and correlationSchema[shapeKey] == false then
			--[[
				Recorded as finding nothing. The search would run to the same
				conclusion, so it is skipped and the columns are written in
				their own order.
			]]
			ctx.stats.correlationSkips = (ctx.stats.correlationSkips or 0) + 1
			return plan, keys
		end

		if correlationRecord ~= nil then
			--[[
				Noted here rather than after the search, so the key exists even
				when the search finds nothing -- which is the case worth
				recording.
			]]
			correlationRecord[shapeKey] = false
			ctx.correlationPending = shapeKey
		end
	end

	--[[
		Every column, built once, with the integer ones noted as they are built.

		This used to be two passes: one here collecting integer columns for the
		fitted search, and another below collecting every usable column for the
		mapping forms. Both walked all `rowCount` rows of all `#keys` columns
		through `cellOf`, which is a closure and a table lookup per value -- on
		the canonical payload, 52 columns of 2,000 rows built twice, 208,000
		closure calls to produce one set that contains the other.

		`numeric` is a subset of `anyColumn` by definition: a column of whole
		numbers with no holes and no NaN is usable, and a usable column is
		numeric exactly when every value is a whole number. So one pass
		produces both, and the integer test rides along on the walk that was
		happening anyway.
	]]
	local numeric: { [string]: { number } } = {}
	local keyIndex: { [string]: number } = {}
	local anyColumn: { [string]: { any } } = {}
	local distinctCount: { [string]: number } = {}
	local anySolo: { [string]: number } = {}
	--[[
		Columns collected but not yet priced. `soloFor` prices one when a
		pair first asks, which on a shape that correlates nothing is never.
	]]
	local soloPending: { [string]: { any } } = {}

	--[[
		How many columns hoisted out of one array may enter the pair search.

		The search is quadratic in the column count, so a long array dominates
		it: forty achievements are 1,560 ordered pairs against the 110 the
		record's own eleven fields contribute. The cost grows as the square of
		the array length while the chance of finding a correlation between two
		of its elements does not -- an array element predicts another only when
		the array carries redundant structure, like flags where unlocking the
		fifth implies the first four.

		So short arrays stay in, whole: a three-element vector, a four-slot
		loadout, a stat block. Past the cap the remainder is skipped, and what
		is lost is a correlation between two elements of a long array, which is
		the case least likely to exist and most expensive to look for.

		Columns hoisted from nested MAPS are not capped. `stats.health` against
		`stats.maxHealth` is the archetypal correlation, and a struct has a
		handful of fields rather than dozens.
	]]
	local ARRAY_HOIST_SEARCH_CAP = 8
	local arrayHoistSeen: { [string]: number } = {}

	for index, key in keys do
		keyIndex[key] = index

		--[[
			Past the cap, the column is still ENCODED -- it simply does not
			enter the pair search, so it can neither reference another column
			nor be referenced.
		]]
		if hoistedFromArray and hoistedFromArray[key] then
			--[[
				Group by the array the key was lifted from, which is everything
				before the final dot. Two different arrays each get their own
				allowance.
			]]
			local group = string.match(key, "^(.*)%.[^.]*$") or key
			local taken = (arrayHoistSeen[group] or 0) + 1
			arrayHoistSeen[group] = taken
			if taken > ARRAY_HOIST_SEARCH_CAP then
				continue
			end
		end

		local column = table.create(rowCount)
		local seen: { [any]: boolean } = {}
		local distinct = 0
		local usable = true
		local integral = true

		for row = 1, rowCount do
			local entry = cellOf(row, key)
			--[[
				A hole or a NaN makes every form here decline, so the column is
				not collected at all.
			]]
			if entry == nil or entry ~= entry then
				usable = false
				break
			end
			column[row] = entry

			if not seen[entry] then
				seen[entry] = true
				distinct += 1
			end

			--[[
				`type(entry) == "boolean"` is tested because a boolean is not a
				number and must not enter the fitted search, where it would be
				arithmetic on `true`.
			]]
			if integral then
				if type(entry) ~= "number" or entry % 1 ~= 0 then
					integral = false
				end
			end
		end

		if usable then
			--[[
				Every usable column is collected, not only the repetitive ones.

				The dictionary forms need repetition -- a column with as many
				distinct values as rows has nothing for a mapping to exploit --
				so they still check `distinctCount` before costing a pair.
				Equality does not: two columns of entirely distinct values are
				its best case, and gating the collection on repetition hid
				exactly those from it.
			]]
			anyColumn[key] = column
			distinctCount[key] = distinct

			if integral then
				numeric[key] = column
			end

			--[[
				What the column costs on its own, which is what a correlated
				form has to beat.

				The plain cost is not the right bar when a single-column form
				would carry the column better: a float column that the decimal
				form can hold in a tenth of the space must be compared against
				*that*, or a correlated form claims it on a saving that was
				never available. Left uncompared, the narrowed form took the
				benchmark's one float column and cost 1,760 bytes.
			]]
			--[[
				What the column will ACTUALLY cost, which is what a correlated
				form has to beat.

				The plain estimate is not the right bar when a single-column form
				would carry the column better: a float column the decimal form
				holds in a tenth of the space must be compared against *that*, or
				a correlated form claims a saving that was never available.

				That has now been got wrong three times, once per form added:

					decimal    the narrowed form took the benchmark's one float
					           column and cost 1,760 bytes
					cyclic     sixteen periodic columns went from 637 bytes to
					           1,432 with `Correlate` on -- worse by 124.8%
					frequency  a column of one dominant value plus eight
					           exceptions cost two bytes more than leaving it

				So every single-column form that can beat the plain estimate is
				asked here rather than remembered one at a time. Each is offered
				the running figure and takes its saving off it, so the result is
				the best the column can do alone -- and a correlated form must
				beat that rather than the plain cost.

				Adding a single-column form without adding it here is a silent
				size regression: the packet still decodes, it is merely larger,
				and only a size comparison notices.

				The forms are offered in sequence and each takes its saving off
				the running figure, which understates the column's cost whenever
				two of them fire and their savings are not additive. That is the
				safe direction: an understated cost makes a correlated form
				harder to justify, so the error loses a saving rather than
				adding bytes. Overstating it would do the opposite.
			]]
			--[[
				The solo cost is deferred until a pair actually wants it.

				This ran five qualifiers on every column before any pair was
				considered -- the decimal search, the cyclic search, the frequency
				map, the run-length walk and the difference search, each a full pass
				or more. The write loop runs the same five on the same columns
				moments later.

				On the canonical payload that was 383 ms to find nothing: fifty-seven
				columns, several of them thirty thousand rows, priced in full so that
				a correlated form would have something to beat -- and no correlated
				form was ever taken.

				So the figure is computed on demand and remembered. A shape where
				every pair is ruled out on cheaper grounds never computes it at all,
				and a shape where one pair survives computes it for the two columns
				that pair names rather than for all of them.

				The values it produces are identical -- this is the same arithmetic,
				moved.
			]]
			soloPending[key] = column
		end
	end

	--[[
		What a column costs on its own, computed when a pair first asks.

		See `soloPending` above for why this is deferred. The result is cached, so
		a column named by several pairs is priced once.
	]]
	local function soloFor(key: string): number
		local known = anySolo[key]
		if known ~= nil then
			return known
		end

		local column = soloPending[key]
		if column == nil then
			--[[
				Not a usable column, so no correlated form can take it. Infinity
				makes every comparison against it fail, which is what the collection
				loop's `usable` flag already meant.
			]]
			return math.huge
		end

		local solo = columnAnySoloBytes(ctx, column, distinctCount[key] or 0)

		local decimal, decimalSaving = Columnar.decimalFor(column, solo, 0)
		if decimal and decimalSaving then
			solo -= decimalSaving
		end

		local cyclic, cyclicSaving = Columnar.cyclicFor(column, solo, 0)
		if cyclic and cyclicSaving then
			solo -= cyclicSaving
		end

			--[[
				Runs and the frequency bitmap both carry a skewed column for
				almost nothing, and a column that is one value in ninety-nine
				rows out of a hundred is the shape `equalityFor` is most likely
				to claim -- so leaving these out is exactly where it loses.
			]]
		local frequency, frequencySaving = Columnar.frequencyFor(column, solo, 0)
		if frequency and frequencySaving then
			solo -= frequencySaving
		end

		local runLength, runLengthSaving = Columnar.runLengthFor(column, solo, 0)
		if runLength and runLengthSaving then
			solo -= runLengthSaving
		end

		anySolo[key] = solo
		return solo
	end

	--[[
		The numeric columns, for the fitted-relationship search below. Mapped
		columns are searched separately and over every type, so a shape with
		fewer than two numeric columns still gets that pass.
	]]
	local names = {}
	for key in numeric do
		table.insert(names, key)
	end
	table.sort(names)

	--[[
		What each numeric column costs on its own, so a candidate has something
		to beat.

		`anySolo` already holds this and holds it better: it starts from the
		same plain estimate and then subtracts what the decimal and cyclic forms
		would save, so it is what the column will ACTUALLY cost rather than what
		it would cost written plainly.

		This used `columnSoloBytes` alone, which knows about neither, so the
		fitted form was costed against a bar no encoder would have settled for.
		On sixteen columns whose values are all periodic that made `Correlate`
		produce 1,432 bytes where leaving it off produced 637.
	]]
	--[[
		There is no eager `solo` table here, and the reason is worth recording.

		One existed: a loop that called `soloFor` for every numeric column before
		the pair search began. It was written at the same time as the deferral it
		defeated -- the pricing was moved to be on demand, and then forced for
		every column three lines later. The measurement said so plainly: 383 ms
		before the change and 412 after, which is noise.

		Its single consumer is `correlationFor` below, which is reached only by a
		pair that survived every cheaper gate. Asking `soloFor` there prices the
		columns those pairs name and no others.
	]]

	local candidates = {}

	--[[
		Mapped columns are searched over every collected column rather than only
		the numeric ones.

		A column determined by another -- a class implying its region, a rarity
		implying its colour -- is the most common correlation in real data by a
		wide margin, and it is not a numeric relationship, so the coefficient
		gate below cannot see it.

		The columns themselves were built above, in the single pass that also
		found the numeric ones.
	]]


	local mappedNames = {}
	for key in anyColumn do
		table.insert(mappedNames, key)
	end
	table.sort(mappedNames)

	--[[
		Which columns can key one of the grouping forms at all.

		Mapped, narrowed and dictionary-for all store something per distinct
		source value, so a source with as many distinct values as the column is
		long carries no groups worth the framing -- every one of the three
		declines it, and `mappedFor` only discovers that after numbering both
		columns into dictionaries.

		The test is the one the forms apply internally, hoisted to the caller
		where `distinctCount` is already known. This is the CWI framework's
		cheapest lever: prune a pair on statistics collected in the pass that
		built the columns, before touching a row of it. Their rules are the same
		shape -- "skip the pair if the number of unique values of the source
		exceeds 10% of the tuple count" for one form, 25% for another.

		A high-cardinality column is not skipped as a TARGET: equality's best
		case is two columns of entirely distinct values, and gating targets here
		is what hid exactly those from it once before.
	]]
	local groupableSource: { [string]: boolean } = {}
	--[[
		A source has to be able to predict enough to pay for the form.

		The test was `distinctCount * 2 <= rowCount`, which asks only whether the
		source repeats. A boolean column passes it trivially -- two distinct values
		against two thousand rows -- and the canonical payload hoists `achievements`
		into forty of them, so forty columns entered the loop as sources and were
		compared against every target.

		Counted: 2,310 of the 2,444 admitted pairs have a source of two distinct
		values. 94.5%, and the payload takes no correlation at all.

		A two-value source predicts at most one bit. The mapping it would key costs
		a reference, an id width and every exception, and cannot save more than the
		target's own form already does -- so the pairs it generates are work whose
		answer is known before the gate runs.

		`MIN_SOURCE_DISTINCT` is three rather than two so the boundary is not the
		value being excluded. The mixed dataset's real mappings are keyed by `team`
		at four distinct values, `class` at five, `tier` at twenty and `level` at
		sixty; none is near this bound.

		Unlike shrinking the gate's sample -- which was measured and found UNSOUND,
		rejecting pairs the form would have accepted -- refusing a source that
		cannot pay loses nothing, because there was nothing to lose.
	]]
	local MIN_SOURCE_DISTINCT = 3

	for _, key in mappedNames do
		local count = distinctCount[key]
		groupableSource[key] = count >= MIN_SOURCE_DISTINCT
			and count * 2 <= rowCount
	end

	for _, reference in mappedNames do
		--[[
			A source that can key no grouping form rules out its whole row of
			pairs, so the test belongs here rather than inside the inner loop
			where it was repeated once per target.
		]]
		if not groupableSource[reference] then
			continue
		end

		for _, target in mappedNames do
			if reference == target then
				continue
			end
			--[[
				A mapping stores one target per distinct source, so a source with
				more distinct values than the target has nothing to say about it.
			]]
			if distinctCount[reference] > distinctCount[target] * 4 then
				continue
			end
			--[[
				A mapping stores one target per distinct source, so neither side
				can be as varied as the column is long. `mappedFor` checks this
				too; skipping the pair here avoids building the tally first. The
				source half is `groupableSource` above.
			]]
			if distinctCount[target] * 2 > rowCount then
				continue
			end


			--[[
				A few rows spread across both columns are enough to rule most
				pairs out, and ruling one out here skips three full passes:
				`mappedFor` numbers both columns into dictionaries, tallies source
				against target, then counts exceptions, and only then may decline.

				The bound is sound -- it fires only when the disagreements already
				seen exceed the tenth `mappedFor` allows for the whole column, and
				disagreements only grow -- so this cannot cost a byte. See
				`mappedRuledOut` for why a bound rather than the estimate the CWI
				framework uses.
			]]
			if Columnar.mappedRuledOut(anyColumn[reference], anyColumn[target], rowCount) then
				continue
			end

			--[[
				A margin covering a plan definition, since choosing this form may
				introduce one the packet did not otherwise need.
			]]
			local mapped, saving = Columnar.mappedFor(
				anyColumn[reference],
				anyColumn[target],
				soloFor(target),
				4
			)
			if mapped and saving then
				table.insert(candidates, {
					reference = reference,
					target = target,
					mapped = mapped,
					saving = saving,
				})
			end
		end
	end

	--[[
		Columns a source narrows rather than determines, and integer columns
		that sit in a distinct range per source value.

		Both are offered for the same pairs the mapped pass just considered, and
		all three compete on saving alone -- a pair that qualifies for more than
		one form takes whichever is smallest.
	]]
	for _, reference in mappedNames do
		--[[
			Both grouping forms key on the source, so a source as varied as the
			column is long carries no groups worth the framing. Equality does not
			group, so it still runs for these -- and its best case is two columns
			of entirely distinct values, which is exactly what this skips.
		]]
		local groupable = groupableSource[reference]

		for _, target in mappedNames do
			if reference == target then
				continue
			end

			--[[
				Neither grouping form can beat a target that already costs less
				than the codes they would write for it.

				Both write one packed code per row at a width of at least one
				bit, so a column already under a bit a row is out of reach
				whatever structure the pair has. Bit-packed booleans are exactly
				that, and the benchmark payload hoists forty of them out of an
				achievements array -- 91.5% of its pair search, 1,891 ms, zero
				bytes.

				The early bail inside `multiMappedFor` does not catch these: it
				fires on sources with many distinct values, and a boolean has
				two.
			]]
			local groupingOut = Columnar.groupingRuledOut(
				rowCount,
				distinctCount[reference],
				soloFor(target)
			)

			--[[
				A run per distinct source value, so a source with as many
				distinct values as the target narrows nothing worth the framing.
			]]
			if
				groupable
				and not groupingOut
				and distinctCount[reference] < distinctCount[target]
				--[[
					The narrowed form writes one packed code per row at the
					width its longest run of admitted targets demands, and that
					floor alone can exceed what the target already costs. Its
					own early bail only fires on high-cardinality sources, so a
					pair of booleans walked every row to discover a run of two.

					Measured after the array-hoist cap: 409 ms of a 540 ms pair
					search, 76% of what remained.
				]]
				and not Columnar.multiMappedRuledOut(
					anyColumn[reference],
					anyColumn[target],
					rowCount,
					soloFor(target)
				)
			then
				local multiMapped, saving = Columnar.multiMappedFor(
					anyColumn[reference],
					anyColumn[target],
					soloFor(target),
					4
				)
				if multiMapped and saving then
					table.insert(candidates, {
						reference = reference,
						target = target,
						multiMapped = multiMapped,
						saving = saving,
					})
				end
			end

			if groupable and not groupingOut then
				local dictionaryFor, forSaving = Columnar.dictionaryForFor(
					anyColumn[reference],
					anyColumn[target],
					soloFor(target),
					4
				)
				if dictionaryFor and forSaving then
					table.insert(candidates, {
						reference = reference,
						target = target,
						dictionaryFor = dictionaryFor,
						saving = forSaving,
					})
				end
			end

			--[[
				Two columns holding the same values, give or take a few rows.
				Cheaper than the mapping that can also express it, since it
				carries no dictionary at all.
			]]
			--[[
				A few rows are enough to rule most pairs out, and ruling one out
				here saves scanning both columns in full. The bound is sound --
				it only fires when the exceptions already seen exceed what the
				form could accept for the whole column -- so this costs nothing
				in size and roughly halves the time the search takes.
			]]
			if Columnar.equalityRuledOut(anyColumn[reference], anyColumn[target], rowCount) then
				continue
			end

			local equality, equalitySaving = Columnar.equalityFor(
				anyColumn[reference],
				anyColumn[target],
				soloFor(target),
				4
			)
			if equality and equalitySaving then
				table.insert(candidates, {
					reference = reference,
					target = target,
					equality = equality,
					saving = equalitySaving,
				})
			end
		end
	end

	--[[
		Each numeric column's mean and variance, once.

		These are properties of the column, not of the pair, and the coefficient
		needs both sides' before it can compute anything. Derived inside the pair
		loop they were recomputed once per partner.
	]]
	local meanOf: { [string]: number } = {}
	local varianceOf: { [string]: number } = {}
	for _, key in names do
		meanOf[key], varianceOf[key] = columnMoments(numeric[key], rowCount)
	end

	for _, reference in names do
		--[[
			A column that never varies correlates with nothing: the coefficient's
			denominator is zero and every pair it appears in scores zero. Skipping
			its whole row costs nothing and saves a pass per partner.
		]]
		if varianceOf[reference] == 0 then
			continue
		end

		for _, target in names do
			if reference == target then
				continue
			end
			if varianceOf[target] == 0 then
				continue
			end
			if
				math.abs(correlationCoefficient(
					numeric[reference],
					numeric[target],
					rowCount,
					meanOf[reference],
					varianceOf[reference],
					meanOf[target],
					varianceOf[target]
				))
				< CORRELATION_MIN_R
			then
				continue
			end

			--[[
				A margin covering the plan definition this form introduces, the
				same one the mapped and narrowed passes pay. Without it the
				fitted form is costed as though its plan were free, and a shape
				with many columns accepts a run of candidates that each save
				less than the definition they add -- which cost the canonical
				benchmark 4,295 bytes once hoisting gave it eighteen more
				columns to pair up.
			]]
			local slope, intercept, bits, saving = Columnar.correlationFor(
				numeric[reference],
				numeric[target],
				soloFor(target),
				4
			)
			if slope and intercept and bits and saving then
				table.insert(candidates, {
					reference = reference,
					target = target,
					slope = slope,
					intercept = intercept,
					bits = bits,
					saving = saving,
				})
			end
		end
	end

	if #candidates == 0 then
		return plan, keys
	end

	table.sort(candidates, function(a, b)
		if a.saving ~= b.saving then
			return a.saving > b.saving
		end
		-- Ties broken by name so the plan does not depend on table order.
		if a.target ~= b.target then
			return a.target < b.target
		end
		return a.reference < b.reference
	end)

	--[[
		Take candidates strongest first, skipping any whose target already has a
		reference or whose reference chain leads back to the target.
	]]
	local referenceOf: { [string]: string } = {}

	--[[
		The walk is bounded by the number of keys, not by the numeric columns
		alone. Mapped columns may reference any type, so a shape with no numeric
		columns would otherwise bound the walk at zero and reject every candidate
		as a cycle on its first step.
	]]
	local function leadsTo(from: string, goal: string): boolean
		local current: string? = from
		local guard = 0
		while current do
			if current == goal then
				return true
			end
			guard += 1
			if guard > #keys then
				return true
			end
			current = referenceOf[current]
		end
		return false
	end

	for _, candidate in candidates do
		if referenceOf[candidate.target] then
			continue
		end
		if leadsTo(candidate.reference, candidate.target) then
			continue
		end

		referenceOf[candidate.target] = candidate.reference
		plan[candidate.target] = {
			referenceKey = candidate.reference,
			referenceIndex = keyIndex[candidate.reference],
			slope = candidate.slope,
			intercept = candidate.intercept,
			bits = candidate.bits,
			mapped = candidate.mapped,
			multiMapped = candidate.multiMapped,
			dictionaryFor = candidate.dictionaryFor,
			equality = candidate.equality,
		} :: CorrelationLink
		plan.referenced[candidate.reference] = true

		--[[
			This shape does yield correlations, so a later encode against the
			same schema must run the search rather than skipping it. Recorded
			the moment the first one is accepted; the gate above wrote `false`
			before the search began, so a shape that finds nothing keeps it.
		]]
		local pending = ctx.correlationPending
		if pending ~= nil and ctx.correlationRecord ~= nil then
			ctx.correlationRecord[pending] = true
		end
	end

	--[[
		Emission order: a column follows whatever it references. Depth-first over
		the forest, then everything else in the shape's own order.
	]]
	local writeOrder = {}
	local placed: { [string]: boolean } = {}
	local function place(key: string)
		if placed[key] then
			return
		end
		local link = plan[key]
		if link then
			place(link.referenceKey)
		end
		placed[key] = true
		table.insert(writeOrder, key)
	end
	for _, key in keys do
		place(key)
	end

	return plan, writeOrder
end

local function writeColumns(
	ctx: Context,
	value: { [any]: any },
	rowCount: number,
	keys: { string },
	keyMark: number,
	--[[
		Whether `value` is a rename of positional rows. The columns are written
		the same either way; the flag rides on the shape so the decoder knows to
		turn the names back into indices.
	]]
	fromTuples: boolean?,
	-- The caller's own rows, when `value` is a rename of them. These are what
	-- other references in the packet point at, so these are what own the ids.
	identityRows: { any }?
): ()
	local writer = ctx.writer

	--[[
		Maps that are really structs become columns of their own.

		A key whose value is the same shape of map in every row -- a `stats` or
		a `settings` -- carries fields that no scheme here can reach while they
		sit one level down. Hoisting them to `stats.health` and so on turns each
		into an ordinary column, and everything below applies unchanged.

		The hoisted rows are handed to `hoisted`, which the column loop reads
		instead of the row when it meets one of these keys. Nothing else in this
		function needs to know it happened.
	]]
	local hoisted: { [string]: { any } } = {}
	--[[
		Which hoists came from an array rather than a map. The rebuild differs:
		a name goes back as a key, a position goes back as an index, and the
		decoder cannot tell "1" from a map key spelled "1" without being told.
	]]
	local hoistedFromArray: { [string]: boolean } = {}

	if ctx.columnar then
		--[[
			Hoisting, repeated while it keeps finding tables.

			One pass lifts `stats` into `stats.health` and `stats.mana`. A field
			one level further in -- `profile.progress.xp` -- stays a struct and
			is written a field at a time, each with its own tag. Measured on two
			thousand records shaped that way: 44,908 bytes against 28,395 for
			the same data flattened, so 36.8% sat behind a second pass.

			Iterated rather than made recursive. `hoistableKeys` refuses a nested
			table on purpose -- recursing inside it would walk without the cycle
			checks the caller does -- so the fix is to run the pass it already
			does again on the columns it produced. Each round sees ordinary
			one-level columns and applies the tested logic to them.

			`HOIST_MAX_DEPTH` bounds it. A pathological shape could nest as far
			as `maxDepth` allows, and each round costs a pass over every column;
			three levels covers the grouping real save data does, and past that
			the remaining structs are written as they were before.
		]]
		local HOIST_MAX_DEPTH = 3

		local expanded: { string } = {}
		local anyHoist = false

		--[[
			Columns that came out of a round still holding tables, which is what
			the next round works on. Empty after the first round on any payload
			that nests only one level, so the loop below runs once and stops.
		]]
		local pending: { [string]: { any } } = {}

		for _, key in keys do
			--[[
				Only a key whose values are tables can be hoisted, and the first
				row answers that.

				This built the whole column first and then tested `column[1]`,
				so every key of every array allocated a table and copied every
				value into it to ask a question about one. On the canonical
				payload -- two thousand inventories of four columns and about
				fourteen rows -- that is eight thousand tables and a hundred and
				twelve thousand copies, every one of them discarded, because no
				inventory column holds a table.

				The column is still built where the test passes, since
				`hoistableKeys` needs it.
			]]
			local innerKeys, innerIsArray = nil, nil
			local column: { any }? = nil

			if type(value[1][key]) == "table" then
				local built = table.create(rowCount)
				for index = 1, rowCount do
					built[index] = value[index][key]
				end
				column = built
				innerKeys, innerIsArray = Columnar.hoistableKeys(built, ctx.tableIds)
			end

			if innerKeys and column then
				anyHoist = true
				for _, innerKey in innerKeys do
					--[[
						A dot is the natural join, and a collision with a real
						key that already contains one is caught by the check
						below rather than assumed away.
					]]
					local hoistedKey = `{key}.{innerKey}`
					-- An array's inner keys are its indices, spelled as text so
					-- they can travel as names; the values are still at numbers.
					local lookup: any = if innerIsArray
						then tonumber(innerKey)
						else innerKey
					local values = table.create(rowCount)
					for index = 1, rowCount do
						values[index] = column[index][lookup]
					end
					hoisted[hoistedKey] = values
					if innerIsArray then
						hoistedFromArray[hoistedKey] = true
					end
					table.insert(expanded, hoistedKey)

					--[[
						A lifted column that itself holds tables is what the
						next round works on. Noted here rather than tested
						here, so the round below sees a complete set.
					]]
					if type(values[1]) == "table" then
						pending[hoistedKey] = values
					end
				end
			else
				table.insert(expanded, key)
			end
		end

		--[[
			Further rounds, each lifting what the round before it produced.

			The columns are already built, so a round reads them directly rather
			than re-extracting from the rows -- which is also why this cannot
			simply call itself: the first pass reads `value[index][key]` and
			every later one reads a column.
		]]
		for _ = 2, HOIST_MAX_DEPTH do
			if next(pending) == nil then
				break
			end

			local nextPending: { [string]: { any } } = {}

			for parentKey, parentColumn in pending do
				local innerKeys, innerIsArray =
					Columnar.hoistableKeys(parentColumn, ctx.tableIds)

				if innerKeys then
					--[[
						The parent name leaves the shape: its fields replace it,
						exactly as in the first round. Removing it from
						`expanded` keeps the two in step, since a name that
						stayed would be written as a column of tables the
						decoder would rebuild alongside the lifted fields.
					]]
					for index, key in expanded do
						if key == parentKey then
							table.remove(expanded, index)
							break
						end
					end
					hoisted[parentKey] = nil
					hoistedFromArray[parentKey] = nil

					for _, innerKey in innerKeys do
						local hoistedKey = `{parentKey}.{innerKey}`
						local lookup: any = if innerIsArray
							then tonumber(innerKey)
							else innerKey

						local values = table.create(rowCount)
						for index = 1, rowCount do
							local inner = parentColumn[index]
							values[index] = if type(inner) == "table"
								then inner[lookup]
								else nil
						end

						hoisted[hoistedKey] = values
						if innerIsArray then
							hoistedFromArray[hoistedKey] = true
						end
						table.insert(expanded, hoistedKey)

						if type(values[1]) == "table" then
							nextPending[hoistedKey] = values
						end
					end
				end
			end

			pending = nextPending
		end

		--[[
			A hoisted name that collides with a key the shape already has would
			make the two indistinguishable on the way back, so the whole hoist
			is abandoned rather than half-applied.
		]]
		if anyHoist then
			local seen: { [string]: boolean } = {}
			local safe = true
			for _, key in expanded do
				if seen[key] then
					safe = false
					break
				end
				seen[key] = true
			end

			if safe then
				table.sort(expanded)
				keys = expanded
				ctx.stats.hoistedColumns = (ctx.stats.hoistedColumns or 0)
					+ #expanded
			else
				hoisted = {}
			end
		end
	end

	-- Reuse the structure cache's shape ids, so an array of the same records
	-- seen twice defines its keys only once.
	--[[
		Hoisting is part of the shape, not just of this array: the same key
		names mean different things depending on whether they were lifted, so a
		hoisted shape must not share an id with a flat one that happens to spell
		its keys the same way.
	]]
	--[[
		This is rebuilt per array, and caching it against the previous array's
		keys was tried and reverted.

		The redundancy is real and easy to count: the canonical payload writes
		2,001 arrays that share 2 distinct shapes, so 1,999 of them build a
		string equal to the one just built. Caching it is also easy to get
		right -- same key count, same names in order, neither side hoisted.

		It measured nothing. Three server runs of the same A/B harness, on the
		shape chosen to isolate it -- 2,000 arrays of 2 columns, where the
		signature is nearly all the per-array work there is:

			+16.7%    -10.2%    -4.3%

		The first run is why this note exists rather than a cache. Read alone it
		looks like a decisive result on exactly the shape predicted; it is a
		sample from a distribution centred near zero and about twenty points
		wide. A control payload the cache cannot help swung -7.5% over the same
		runs, and two of those runs were the encoder timed against ITSELF.

		The same idea applied to the per-column plan key in `writePlan`, which
		repeats four times as often, likewise measured nothing. Luau interns
		short strings; a few thousand of a handful of bytes are not the cost,
		whatever the count suggests.

		Anything claimed here needs a mean of several runs and a control that
		cannot move, or it is noise. See `tests/README.md`.
	]]
	-- Concatenated rather than formatted; see `shapeSignature` for the timings.
	local parts = table.create(#keys)
	for index, key in keys do
		local mark = if hoisted[key]
			then (if hoistedFromArray[key] then "#" else "^")
			else ""
		parts[index] = tostring(#key) .. ":" .. key .. mark
	end
	-- A tuple shape and a map shape spelling the same names are different
	-- shapes: one comes back as a list, the other as a record.
	local signature = table.concat(parts) .. (if fromTuples then "@" else "")

	local shapeId = ctx.shapeIds[signature]
	if shapeId then
		tag(ctx, Tags.COLUMNS, keyMark)
		Writer.varint(writer, shapeId)
	else
		shapeId = ctx.nextShapeId + 1
		ctx.nextShapeId = shapeId
		ctx.shapeIds[signature] = shapeId
		ctx.shapeKeys[shapeId] = keys

		tag(ctx, Tags.COLUMNS_DEF, keyMark)
		Writer.varint(writer, shapeId)
		Writer.varint(writer, #keys)
		for _, key in keys do
			writeString(ctx, key, 0)
		end

		--[[
			Which keys were lifted out of a nested map. Written as indices into
			the key list rather than inferred from the names, since a key is
			allowed to contain a dot of its own.
		]]
		local hoistIndices = {}
		for index, key in keys do
			if hoisted[key] then
				--[[
					The index carries its own kind in the low bit: doubled for a
					map hoist, doubled and set for one lifted out of an array.
					Packing it here rather than in a second list keeps the whole
					thing one byte a hoist for the first sixty-three keys, which
					is every shape that has ever been measured.
				]]
				local encoded = index * 2
				if hoistedFromArray[key] then
					encoded += 1
				end
				table.insert(hoistIndices, encoded)
			end
		end
		--[[
			The hoist count carries the tuple flag in its low bit, for the same
			reason each index carries its own kind there: a separate byte would
			be paid by every shape ever written, and no shape needs one.
		]]
		local header = #hoistIndices * 2
		if fromTuples then
			header += 1
		end
		Writer.varint(writer, header)
		for _, encoded in hoistIndices do
			Writer.varint(writer, encoded)
		end
	end

	Writer.varint(writer, rowCount)

	--[[
		Every row is claimed as a table id before any column is written.

		The decoder builds all rows up front for the same reason, so the two
		sides agree on which id belongs to which row. Without this a reference
		elsewhere in the packet would resolve to the wrong table.
	]]
	local identity = identityRows or value
	for index = 1, rowCount do
		local id = ctx.nextTableId + 1
		ctx.nextTableId = id
		ctx.tableIds[identity[index]] = id
	end

	--[[
		Cross-field correlation, planned before anything is written.

		A column encoded as a residual against another needs that other column to
		exist first, so the plan is computed up front and the columns are written
		in dependency order. `correlationPlan` returns, per key, the key it should
		be encoded against -- or nothing, when it is cheaper alone.
	]]
	local plan, writeOrder = correlationPlan(
		ctx,
		value,
		rowCount,
		keys,
		hoisted,
		hoistedFromArray
	)

	local column = table.create(rowCount)
	local materialised: { [string]: { number } } = {}

	--[[
		Each column names its own key by index before anything else, because the
		write order is not the shape's key order once a column is encoded against
		another. The decoder then needs no agreement on ordering, only on shape.
	]]
	local keyIndexOf: { [string]: number } = {}
	for index, key in keys do
		keyIndexOf[key] = index
	end

	--[[
		Column plan cache.

		The bytes describing HOW a column is encoded -- which key, which kind,
		what bit width, what difference order -- repeat across arrays of the same
		shape holding similar data. Two thousand inventories produced only 33
		distinct plans between them, one covering 62% of them.

		Each column therefore emits a plan id. A plan seen before costs one byte
		and the descriptive bytes are skipped; a new one costs its id plus those
		bytes, once. What always stays per array is the data a plan cannot know:
		row counts, difference seeds, correlation slopes, packed payloads.
	]]
	local plans = ctx.columnPlans

	--[[
		What defining a plan for this key and kind would cost, or zero when one
		already exists.

		A form whose saving is smaller than a plan definition makes the packet
		larger when it is the only column of its kind, and pays for itself once
		a second column shares the plan. Since the descriptor bytes vary per
		column, this asks only whether the key and kind have been seen -- close
		enough to decide a handful of bytes, and never optimistic.
	]]
	local seenKinds: { [string]: boolean } = ctx.columnPlanKinds
	local PLAN_DEFINITION_BYTES = 4

	--[[
		Bound once rather than read from the context per column. Nil on every
		encode that is not deriving a schema, which is all of them except the
		single call `Zzzz.schema` makes.
	]]
	local planRecord = ctx.planRecord
	local planSchema = ctx.planSchema

	local function planDefinitionCost(keyIndex: number, kind: number): number
		return if seenKinds[`{keyIndex}:{kind}`] then 0 else PLAN_DEFINITION_BYTES
	end

	--[[
		There is no form-hint cache here, and the measurement that removed one
		is worth keeping.

		A payload of many arrays of one shape asks the same questions of each --
		is this column cyclic, is it an exact decimal -- and re-deriving the same
		answers looked like obvious waste. Three caching schemes were built. The
		first kept a refusal forever, so four hundred arrays that turned cyclic
		at the hundred and first found none of the three hundred. The second
		rechecked every sixteenth array, which loses the form on the other
		fifteen. The third keyed refusals on a fingerprint of the column, which
		was correct.

		Then the cost was measured, across 8,012 columns and 143,468 values:

			computing the fingerprints    59.9 ms
			asking cyclicFor               4.2 ms
			asking decimalFor              3.0 ms

		The cache cost fourteen times what it saved. Describing a column well
		enough to know the answer was already cheap costs more than asking, and
		no refinement of the key changes that -- the questions being cached are
		themselves a fraction of a percent of the encode.

		The re-planning cost is real: the same 119,468 values take 173 ms in one
		array and 330 ms in two thousand. But it is not these two forms, and a
		cache is the wrong shape of answer for whatever it is.
	]]


	--[[
		Emit a column's plan: its key, kind and any width or order bytes.

		`descriptors` holds the bytes that describe the encoding and nothing
		else. On a repeat they are replaced by the plan's id; on first sight the
		id is followed by the bytes themselves.

		Returns nothing -- the caller writes the column's data afterwards either
		way, since data is never part of a plan.
	]]
	--[[
		There is no schema-aware plan encoding here, and the measurement that
		removed one is worth keeping.

		A schema holds the form of every column it covers, so a packet written
		for a decoder that also holds it need not describe those columns at all.
		The framing looked substantial when counted: 7,987 plan references and
		twenty definitions on the canonical payload, about 13,700 bytes, 8.4% of
		the packet.

		Built, it made the packet LARGER. Columns are not written in the shape's
		key order -- a column encoded against another must follow it -- so a
		marker saying "the schema knows this one" still needs the key index
		after it. That is two varints where a plan reference was one, and a
		reference is already a single byte. The canonical payload went from
		161,967 to 163,949: about eight thousand bytes spent to avoid fifty-nine.

		The 8.4% was never recoverable. It is almost entirely references, and the
		reference format is already as small as a per-column marker can be. Only
		the definitions -- 59 bytes of it -- were ever in reach.

		So a schema-encoded packet stays slightly larger than an adaptive one, by
		the width of the plans widened to cover every array. That is under one
		percent, it is the price of replay working at all, and it buys the encode
		speed the schema exists for.
	]]

	local function writePlan(keyIndex: number, kind: number, descriptors: { number }): ()
		--[[
			Recorded before it is written, when a schema is being derived.

			`keys` is the shape's key list and `keyIndex` indexes into it, so the
			name is one lookup away -- and the name is what a schema must store,
			since a plan has to be found again in a payload whose arrays may be
			ordered differently.
		]]
		if planRecord then
			local key = keys[keyIndex]
			if key ~= nil then
				local existing = planRecord[key]

				if existing == nil then
					planRecord[key] = {
						kind = kind,
						descriptors = table.clone(descriptors),
					}
				elseif existing.kind == kind then
					--[[
						Widened to cover every array, not kept from the first.

						A key name identifies one column within one shape, but a
						payload of two thousand inventories has two thousand
						columns called `count`, each with its own range. Keeping
						the first plan recorded a width that fitted the first
						inventory and missed on most of the rest: measured on the
						canonical payload, 1,478 misses against 530 replays, and
						a schema slower than no schema at all.

						So the widths widen. A plan of the same kind whose
						descriptors are larger describes a column the recorded
						one could not hold, and taking the maximum makes the
						recorded plan cover both. On the differenced form the
						descriptors are the order and the bit width, and a wider
						width always fits where a narrower one did.

						Only same-kind plans combine. A key that is differenced
						in one array and a dictionary in another has no single
						plan covering both, and the first is kept -- the other
						arrays fall back, which is correct if slower.

						And only the WIDTH widens, never the order. Differencing
						order 2 is not a wider version of order 0, it is a
						different transform: order 0 packs the values and order 2
						packs the differences of their differences. A plan that
						took the maximum of both would describe an encoding
						neither array chose, and would fit neither.

						So an order disagreement keeps the first plan and lets
						the other arrays fall back, which is what a genuinely
						different column deserves.
					]]
					if kind == COLUMN_DIFFERENCED then
						if descriptors[1] == existing.descriptors[1] then
							if descriptors[2] > existing.descriptors[2] then
								existing.descriptors[2] = descriptors[2]
							end
						end
					else
						--[[
							Every other form's descriptors are widths, counts or
							flags, where larger subsumes smaller. A frequency
							column's exception width, a run-length column's
							length width: a plan carrying the larger of two
							covers both columns.
						]]
						local descriptorCount = #descriptors
						if descriptorCount == #existing.descriptors then
							for index = 1, descriptorCount do
								local candidate = descriptors[index]
								if candidate > existing.descriptors[index] then
									existing.descriptors[index] = candidate
								end
							end
						end
					end
				end
			end
		end

		--[[
			Built per descriptor byte, which looks wasteful and measured as
			nothing.

			Rewriting this to take every byte in one `string.char` and join in
			one `table.concat` was tried, on the reasoning that a four-descriptor
			plan allocated six strings where two would do, across about eight
			thousand calls. Timed on the isolating shape -- one array of 24
			columns, where the per-column key is all there is to save -- it
			measured -0.3%, which is to say nothing at all.

			Luau interns short strings and these keys are a handful of bytes, so
			the allocations being counted were never the cost. Left as it was.
		]]
		local signature = string.char(kind)
		for _, byteValue in descriptors do
			signature ..= string.char(byteValue % 256)
		end
		signature = `{keyIndex}:{signature}`

		--[[
			One varint carries both cases. An even value is a definition and
			holds the key index; an odd one is a reference and holds a plan id.
			Reusing the low bit this way keeps a definition the same size it was
			before plans existed, so an array too small to repeat anything is not
			penalised for the mechanism.
		]]
		local existing = plans[signature]
		if existing then
			Writer.varint(writer, existing * 2 + 1)
			ctx.stats.planHits = (ctx.stats.planHits or 0) + 1
			return
		end

		local id = ctx.nextColumnPlanId + 1
		ctx.nextColumnPlanId = id
		plans[signature] = id
		seenKinds[`{keyIndex}:{kind}`] = true

		--[[
			Zero introduces a definition; the id is implicit in the order
			defined. The key index rides in the same varint as that marker --
			key * 2, with the low bit clear -- so a definition costs exactly what
			the old unplanned form did and a packet that never repeats a plan is
			never larger for having the mechanism.
		]]
		Writer.varint(writer, keyIndex * 2)
		Writer.u8(writer, kind)
		for _, byteValue in descriptors do
			Writer.u8(writer, byteValue)
		end
		ctx.stats.planDefs = (ctx.stats.planDefs or 0) + 1
	end


	for _, key in writeOrder do
		--[[
			The column table is reused across keys, so a key that is absent on a
			row must clear that slot rather than inherit the previous key's
			value. `table.clear` is cheaper than allocating per key and leaves
			the holes genuinely nil for `optionalFor` to find.
		]]
		table.clear(column)

		local lifted = hoisted[key]
		if lifted then
			for index = 1, rowCount do
				column[index] = lifted[index]
			end
		else
			for index = 1, rowCount do
				column[index] = value[index][key]
			end
		end

		local keyIndex = keyIndexOf[key]

		--[[
			The recorded form, where a schema supplied one.

			This is the whole point of a schema: the twelve qualifiers below
			are skipped and the form the sample chose is applied directly.
			Measured on 2,000 flat rows, 7.07 ms of discovery becomes 2.69 of
			replay for 1.6% more bytes.

			Only the forms whose validity can be established DURING the write
			are replayed. `writeDifferenced` walks the column to difference it,
			so checking each result against the recorded width rides along on a
			traversal that was happening anyway -- measured at zero. A form
			needing a separate proof pass would cost more to verify than to
			re-derive, and falls through instead.

			A plan that does not fit this data is not an error in the caller's
			schema so much as a statement that the schema no longer describes
			the payload. It falls through to the ordinary search, which produces
			a correct packet at the ordinary price. Silently writing a truncated
			value is the one outcome that must never happen, and the check below
			is what prevents it.
		]]
		--[[
			What the schema recorded for this column, if anything.

			Two uses, and the second is the more valuable one.

			A REPLAYABLE kind is applied directly below and the qualifiers are
			skipped entirely.

			Any other recorded kind still says which form won when the sample was
			encoded, and that is enough to skip the ones that lost. Selecting a
			form is not mostly the cost of finding the winner -- it is the cost of
			pricing eleven rivals to prove they lost. `differencedPackFor` runs on
			a string column to return nil; `frequencyFor` builds a map of counts
			to decline. A schema saying "this column is a dictionary" makes all of
			that skippable without needing a replay branch for the dictionary
			form itself.

			That is why `recordedKind` is read here rather than inside the
			branches: every qualifier below consults it, and a column the schema
			does not know is unaffected because the value is nil.
		]]
		local recordedKind: number? = nil
		if planSchema then
			local recorded = planSchema[key]
			if recorded then
				recordedKind = recorded.kind
			end
		end

		if planSchema then
			local recorded = planSchema[key]

			if recordedKind == COLUMN_DIFFERENCED then
				local order = recorded.descriptors[1]
				local bits = recorded.descriptors[2]
				local seeds, fits = differencedSeedsFor(column, rowCount, order, bits)

				if fits and seeds then
					--[[
						The plan is not written, only a marker saying the schema
						has it. That is the whole of the byte saving: one varint
						per column instead of a plan reference, and no definition
						at all.
					]]
					writePlan(keyIndex, COLUMN_DIFFERENCED, { order, bits })
					writeDifferenced(ctx, column, rowCount, order, seeds, bits)
					ctx.stats.planReplays = (ctx.stats.planReplays or 0) + 1
					continue
				end

				--[[
					Counted, because a schema whose plans stop fitting is one
					the caller should derive again -- and a silent fallback
					would leave them paying full price while believing they
					were not.
				]]
				ctx.stats.planMisses = (ctx.stats.planMisses or 0) + 1

			elseif recordedKind == COLUMN_BOOLEANS then
				--[[
					The simplest plan to replay: it carries no width, because a
					boolean column is one bit a row whatever it holds. So there
					is nothing that can fail to fit, and the only question is
					whether the column is still boolean -- which `columnIsBoolean`
					answers with one walk that the qualifiers would have made
					anyway.

					`ctx.bitPack` is checked because a schema derived with bit
					packing on can be handed to an encode with it off, and
					writing a packed column the decoder was not told to expect
					would produce a packet neither side agrees about.

					`Columnar.isBooleanColumn` rather than the loop's memoised
					`columnIsBoolean`, which is declared further down: this
					branch runs before the qualifiers that memo serves, and
					moving the memo up to reach it would put the whole per-column
					preamble ahead of the replay it exists to skip.
				]]
				if ctx.bitPack and Columnar.isBooleanColumn(column) then
					writePlan(keyIndex, COLUMN_BOOLEANS, {})
					writeBooleanBits(ctx, column, rowCount)
					ctx.stats.booleanColumns = (ctx.stats.booleanColumns or 0) + 1
					ctx.stats.planReplays = (ctx.stats.planReplays or 0) + 1
					continue
				end

				ctx.stats.planMisses = (ctx.stats.planMisses or 0) + 1
			end
		end

		--[[
			Whether a form is worth asking, given what the schema recorded.

			`true` when the schema said nothing about this column -- an unknown
			column gets the full search, which is what makes a schema safe to
			hand data it was not derived from.

			`true` when the schema recorded THIS form, so it is asked and
			presumably wins again.

			`false` otherwise: the sample chose something else, so this form lost
			once already and pricing it again is work whose answer is known. A
			column whose data changed enough to prefer a different form now
			simply keeps the recorded one, which is a slightly larger packet
			rather than a wrong one.

			The exception is `COLUMN_PLAIN` at the end of the chain, which is not
			gated: it is the fallback every column must be able to reach.
		]]
		local function schemaWants(kind: number): boolean
			return recordedKind == nil or recordedKind == kind
		end

		--[[
			A column some rows lack: the validity bitmap, then the values that
			are actually there as a column of their own.

			This comes before every other form because they all assume a complete
			column -- they return nil at the first hole, which is what sent an
			otherwise columnar array back to plain key-value encoding for all its
			rows.

			The values that remain are a complete column, and the whole point is
			that every form should be able to carry them. Writing them one at a
			time was the form's first shape and it was expensive out of all
			proportion: half a column of ids cost 2,134 bytes where the same ids
			complete on every row cost 97, because none of the string or integer
			forms could reach inside.

			So the present values are handed back to the encoder as an array of
			single-key rows, which re-enters the columnar path and picks whatever
			form suits them -- dates, prefixed ints, dictionaries, differencing,
			all of it. Measured against writing them plainly:

				dates          816 B ->   372 B
				prefixed ids 2,134 B ->   130 B
				Color3       1,087 B ->   213 B
				integers       859 B ->   123 B

			The wrapper row is the price of re-entry, and the qualifiers charge
			for it in the usual way: the nested form is only chosen when it beats
			writing the values directly.
		]]
		local optional = if ctx.columnar and schemaWants(COLUMN_OPTIONAL)
			then Columnar.optionalFor(column, rowCount)
			else nil
		if optional then
			local inner = optional.values
			local innerDecimal = Columnar.decimalFor(
				inner,
				#inner * 9,
				planDefinitionCost(keyIndex, COLUMN_OPTIONAL) + 4
			)

			--[[
				This branch writes the integers as offsets from `low`, so a plan
				that chose to difference them instead cannot be written here. The
				flat form is still correct, just not the cheapest, so the plan is
				dropped rather than mis-written.
			]]
			if innerDecimal and innerDecimal.order then
				innerDecimal = nil
			end

			--[[
				Re-entry is worth it once there are enough values for a column to
				beat writing them one at a time. Below that the wrapper rows and
				the nested shape cost more than they save, and the decimal form
				or the plain fallback is the better answer.

				`Columnar.MIN_ROWS` is the same floor the columnar path itself
				uses, so a nested array that would be refused is never built.
			]]
			local innerForm = if innerDecimal then 1 else 0
			if innerDecimal == nil and #inner >= Columnar.MIN_ROWS then
				innerForm = 2
			end

			writePlan(keyIndex, COLUMN_OPTIONAL, { innerForm })
			writeBooleanBits(ctx, optional.present, rowCount)
			Writer.varint(writer, #inner)

			if innerForm == 2 then
				--[[
					The values as an array of single-key rows, which re-enters
					the columnar path and picks whatever form suits them.
				]]
				local wrapped = table.create(#inner)
				for index, entry in inner do
					wrapped[index] = { v = entry }
				end
				writeValue(ctx, wrapped, false)
				ctx.stats.optionalColumns = (ctx.stats.optionalColumns or 0) + 1
				continue
			end

			if innerDecimal then
				Writer.u8(writer, innerDecimal.bits)
				Writer.u8(writer, innerDecimal.exponent)
				Writer.u8(writer, innerDecimal.factor)
				Writer.varint(writer, zigzag(innerDecimal.low))

				local accumulator, held = 0, 0
				for _, entry in innerDecimal.values do
					accumulator += (entry - innerDecimal.low) * 2 ^ held
					held += innerDecimal.bits
					while held >= 8 do
						Writer.u8(writer, accumulator % 256)
						accumulator = (accumulator - accumulator % 256) / 256
						held -= 8
					end
				end
				if held > 0 then
					Writer.u8(writer, accumulator % 256)
				end

				Writer.varint(writer, #innerDecimal.exceptionRows)
				for index, row in innerDecimal.exceptionRows do
					Writer.varint(writer, row)
					Writer.f64(writer, innerDecimal.exceptionValues[index])
				end
			else
				for _, entry in inner do
					writeValue(ctx, entry, false)
				end
			end

			ctx.stats.optionalColumns = (ctx.stats.optionalColumns or 0) + 1
			continue
		end

		--[[
			A correlated column: the reference's index in the shape's key order,
			the fitted slope and intercept, then the packed residual.

			Reference and width describe the encoding, so they belong to the
			plan. Slope and intercept are fitted per array and do not.
		]]
		local link = plan[key]

		--[[
			A mapped column: the distinct target values, one target per distinct
			source value, then the rows that break the mapping.

			Source values are numbered in order of first appearance, which the
			decoder can reproduce from the reference column it has already read,
			so only the target side travels.
		]]
		if link and link.mapped then
			local mapped = link.mapped
			writePlan(keyIndex, COLUMN_MAPPED, { link.referenceIndex, mapped.targetBits })

			Writer.varint(writer, #mapped.targetValues)
			for _, entry in mapped.targetValues do
				writeValue(ctx, entry, false)
			end

			--[[
				The mapping, one packed target id per distinct source value, in
				source id order.
			]]
			local accumulator, held = 0, 0
			for sourceId = 1, #mapped.sourceValues do
				accumulator += (mapped.mapping[sourceId] - 1) * 2 ^ held
				held += mapped.targetBits
				while held >= 8 do
					Writer.u8(writer, accumulator % 256)
					accumulator = (accumulator - accumulator % 256) / 256
					held -= 8
				end
			end
			if held > 0 then
				Writer.u8(writer, accumulator % 256)
			end

			-- Then the rows the mapping gets wrong.
			Writer.varint(writer, #mapped.exceptionRows)
			for index, row in mapped.exceptionRows do
				Writer.varint(writer, row)
				Writer.varint(writer, mapped.exceptionIds[index] - 1)
			end

			ctx.stats.mappedColumns = (ctx.stats.mappedColumns or 0) + 1
			materialised[key] = table.clone(column)
			continue
		end

		--[[
			A narrowed column: the length of each source value's run of
			admissible targets, those targets, then one packed index per row.

			Runs travel in source id order, which the decoder reproduces from the
			reference column, so the source side stays off the wire exactly as it
			does for the mapped form.
		]]
		if link and link.multiMapped then
			local multiMapped = link.multiMapped
			writePlan(keyIndex, COLUMN_MULTI_MAPPED, { link.referenceIndex, multiMapped.codeBits })

			Writer.varint(writer, #multiMapped.runLengths)
			for _, length in multiMapped.runLengths do
				Writer.varint(writer, length)
			end
			for _, entry in multiMapped.runValues do
				writeValue(ctx, entry, false)
			end

			local accumulator, held = 0, 0
			for _, code in multiMapped.codes do
				accumulator += code * 2 ^ held
				held += multiMapped.codeBits
				while held >= 8 do
					Writer.u8(writer, accumulator % 256)
					accumulator = (accumulator - accumulator % 256) / 256
					held -= 8
				end
			end
			if held > 0 then
				Writer.u8(writer, accumulator % 256)
			end

			ctx.stats.multiMappedColumns = (ctx.stats.multiMappedColumns or 0) + 1
			materialised[key] = table.clone(column)
			continue
		end

		--[[
			A column in a distinct range per source value: one reference per
			distinct source value, then the offset from it packed at the width of
			the widest group.
		]]
		if link and link.dictionaryFor then
			local dictionaryFor = link.dictionaryFor
			writePlan(
				keyIndex,
				COLUMN_DICTIONARY_FOR,
				{ link.referenceIndex, dictionaryFor.offsetBits }
			)

			Writer.varint(writer, #dictionaryFor.references)
			for _, reference in dictionaryFor.references do
				Writer.varint(writer, zigzag(reference))
			end

			local accumulator, held = 0, 0
			for _, offset in dictionaryFor.offsets do
				accumulator += offset * 2 ^ held
				held += dictionaryFor.offsetBits
				while held >= 8 do
					Writer.u8(writer, accumulator % 256)
					accumulator = (accumulator - accumulator % 256) / 256
					held -= 8
				end
			end
			if held > 0 then
				Writer.u8(writer, accumulator % 256)
			end

			ctx.stats.dictionaryForColumns = (ctx.stats.dictionaryForColumns or 0) + 1
			materialised[key] = table.clone(column)
			continue
		end

		--[[
			A column that is another column: nothing but the rows that disagree.

			The reference travels in the plan, so a pair that matches outright
			costs a single zero here.
		]]
		if link and link.equality then
			local equality = link.equality
			writePlan(keyIndex, COLUMN_EQUALITY, { link.referenceIndex, equality.rowBits })

			Writer.varint(writer, #equality.exceptionRows)

			--[[
				The rows ascend, so their gaps pack where the rows themselves do
				not. A width of zero means the gaps were not worth packing and
				the rows travel as varints.
			]]
			if equality.rowBits > 0 then
				local accumulator, held = 0, 0
				local previous = 0
				for _, row in equality.exceptionRows do
					accumulator += (row - previous) * 2 ^ held
					previous = row
					held += equality.rowBits
					while held >= 8 do
						Writer.u8(writer, accumulator % 256)
						accumulator = (accumulator - accumulator % 256) / 256
						held -= 8
					end
				end
				if held > 0 then
					Writer.u8(writer, accumulator % 256)
				end
			else
				for _, row in equality.exceptionRows do
					Writer.varint(writer, row)
				end
			end

			for _, entry in equality.exceptionValues do
				writeValue(ctx, entry, false)
			end

			ctx.stats.equalityColumns = (ctx.stats.equalityColumns or 0) + 1
			materialised[key] = table.clone(column)
			continue
		end

		if link then
			writePlan(keyIndex, COLUMN_CORRELATED, { link.referenceIndex, link.bits })
			Writer.varint(writer, zigzag(link.slope))
			Writer.varint(writer, zigzag(link.intercept))
			writeCorrelated(
				ctx,
				column,
				materialised[link.referenceKey],
				rowCount,
				link.slope,
				link.intercept,
				link.bits
			)
			ctx.stats.correlatedColumns = (ctx.stats.correlatedColumns or 0) + 1
			materialised[key] = table.clone(column)
			continue
		end

		-- Kept only while some later column might reference it.
		if plan.referenced[key] then
			materialised[key] = table.clone(column)
		end

		--[[
			A column that repeats on a fixed period.

			Offered before runs and the dictionary because both would otherwise
			claim these columns and carry them far more expensively: a
			dictionary sees sixty distinct values and pays six bits a row
			without noticing the order is fixed, and a cycle holds no repeats
			for runs to find at all.

			Costed against the same any-type estimate every other form here
			competes with, so a column whose cycle is not worth the framing
			keeps whatever it would have had.
		]]
		--[[
			The distinct count, computed once and shared.

			`distinctOf` walks the column building a `seen` table, and the
			cyclic branch here and the run-length branch below were each calling
			it -- eighty lines apart, for the same number, on every column of
			every array. On the canonical payload that is eight thousand columns
			walked twice.

			Lazy rather than hoisted above the loop, because neither branch
			always runs: the cyclic form skips columns shorter than its minimum,
			and run-length takes a cheaper path for bit-packed booleans. A
			column that reaches neither never pays for the walk.
		]]
		local cachedDistinct: number? = nil
		local function columnDistinct(): number
			local value = cachedDistinct
			if value == nil then
				value = distinctOf(column)
				cachedDistinct = value
			end
			return value
		end

		--[[
			The same treatment for the two solo-cost estimates, which are far more
			expensive than the distinct walk and were repeated just as blindly.

			Both end in `differencedPackFor`, which is not a scan but a SEARCH: it
			copies the column, then differences it up to three times, each order
			allocating a table and walking what the order before it produced. Four
			tables and four passes to answer one question about cost.

			Within a single column, four calls asked it:

				cyclicFor's estimate          columnAnySoloBytes
				runLengthFor's estimate       columnAnySoloBytes
				frequencyFor, RLE rival       columnSoloBytes
				frequencyFor, standalone      columnSoloBytes

			The column cannot change between them -- it is filled once at the top
			of the iteration and only read afterwards -- so all four are the same
			number, computed up to four times over eight thousand columns.

			`columnAnySoloBytes` wraps `columnSoloBytes` for numeric columns and
			handles the other types itself, so the two are memoised separately
			rather than one in terms of the other.

			A fifth caller wants the same search: the differenced form itself,
			which needs the order, seeds and width to WRITE, where the estimates
			needed only the saving. So the search is memoised whole and the
			estimate reads the saving out of it, rather than the two running it
			separately and one discarding most of the answer.

			Lazy for the same reason `columnDistinct` is: none of these is reached
			on every column. A boolean column takes the bit-packed path and prices
			nothing, and a column below `CYCLE_MIN_ROWS` never asks the cyclic
			form at all.

			Measured with `bench_repeat.lua`, both paths alternating in one
			process with the order randomised per round, seven pairs each:

				                             off      on   saved   pairs won
				4,000 x 6 integer columns   32.1    22.4     32%         7/7
				2,000 small arrays         124.5   101.4     19%         7/7
				the canonical payload      289.5   259.2     11%         7/7
				4,000 x 6 STRING columns    27.7    28.2      --         2/7

			The string row is the control and the reason the rest is believable:
			`differencedPackFor` declines at its first value there, so the memo
			has nothing to save. It saved nothing -- the median said -1.8%, the
			best-to-best said +0.1%, and it won two pairs of seven, which is what
			no effect looks like. Every other row won all seven with both
			statistics agreeing on the sign.

			The packets are byte-identical with the memo on and off, on all four
			payloads.

			Worth contrasting with the string-signature caches tried just before
			this, which had the same shape of argument -- obvious redundancy,
			counted directly -- and measured nothing at all. The difference is
			what the repeated work COSTS: a few interned short strings against a
			search that allocates four tables and walks the column four times.
			See `tests/README.md`.
		]]
		local packSearched = false
		local packOrder: number?, packSeeds: { number }?, packBits: number?
		local packSaving: number?

		--[[
			`noColumnMemo` restores the old behaviour -- every caller running its
			own search -- so a benchmark can time both in one process. Absolute
			timings here move too much between runs for a before-and-after taken
			minutes apart to mean anything. Nothing outside a benchmark sets it.
		]]
		local memoise = not (ctx :: any).noColumnMemo

		local function columnPack(): (number?, { number }?, number?, number?)
			if not memoise then
				return Columnar.differencedPackFor(column)
			end
			if not packSearched then
				packSearched = true
				packOrder, packSeeds, packBits, packSaving =
					Columnar.differencedPackFor(column)
			end
			return packOrder, packSeeds, packBits, packSaving
		end

		--[[
			`columnSoloBytes` inlined here so it can share the search above. The
			free function it replaces is still used by the correlation planner,
			which has no per-column memo to hang this on.
		]]
		local cachedSolo: number? = nil
		local function columnSolo(): number
			local value = if memoise then cachedSolo else nil
			if value == nil then
				--[[
					`#column` rather than `rowCount`, matching `columnSoloBytes`
					exactly. A column with holes has already been claimed by the
					optional form above, so the two agree wherever this runs --
					but the estimate must not depend on that being true, since a
					disagreement would silently price the wrong number of values.
				]]
				value = 0
				for index = 1, #column do
					local entry = column[index]
					if type(entry) ~= "number" or entry % 1 ~= 0 then
						value = math.huge
						break
					end
					value += Columnar.integerCost(entry)
				end

				if value ~= math.huge then
					local _, _, _, saving = columnPack()
					value -= saving or 0
				end
				cachedSolo = value
			end
			return value
		end

		local cachedAnySolo: number? = nil
		local function columnAnySolo(): number
			local value = if memoise then cachedAnySolo else nil
			if value == nil then
				--[[
					Mirrors `columnAnySoloBytes` for the numeric case so it reads
					the shared search; every other type is delegated, since those
					branches do no differencing and nothing is duplicated.
				]]
				if typeof(column[1]) == "number" then
					local solo = columnSolo()
					-- A fractional column is not free; see `columnAnySoloBytes`.
					value = if solo == math.huge then #column * 9 else solo
				else
					value = columnAnySoloBytes(ctx, column, columnDistinct())
				end
				cachedAnySolo = value
			end
			return value
		end

		--[[
			`cyclicFor` refuses a column shorter than `CYCLE_MIN_ROWS` on its
			first line, so pricing the alternative first is work thrown away.
			The canonical payload is two thousand inventories of about fourteen
			items -- eight thousand columns, every one below that bound.
		]]
		local cyclic, cyclicSaving = nil, nil
		if rowCount >= Columnar.CYCLE_MIN_ROWS and schemaWants(COLUMN_CYCLIC) then
			cyclic, cyclicSaving = Columnar.cyclicFor(
				column,
				columnAnySolo(),
				planDefinitionCost(keyIndex, COLUMN_CYCLIC)
			)
		end

		if cyclic and cyclicSaving then
			local cycle = cyclic.cycle
			local low, high = cycle[1], cycle[1]
			for _, entry in cycle do
				if entry < low then
					low = entry
				end
				if entry > high then
					high = entry
				end
			end

			local bits = 1
			local span = high - low
			while bits < Columnar.MAX_PACK_BITS and 2 ^ bits <= span do
				bits += 1
			end

			writePlan(keyIndex, COLUMN_CYCLIC, {
				cyclic.period,
				bits,
				if cyclic.differenced then 1 else 0,
			})

			--[[
				The low value the cycle packs against, then the cycle itself at
				the width named in the plan. The seed comes first when the cycle
				was found in the differences, since the reconstruction starts
				from it.
			]]
			if cyclic.differenced then
				Writer.varint(writer, zigzag(cyclic.seed :: number))
			end
			Writer.varint(writer, zigzag(low))

			local accumulator, held = 0, 0
			for _, entry in cycle do
				accumulator += (entry - low) * 2 ^ held
				held += bits
				while held >= 8 do
					Writer.u8(writer, accumulator % 256)
					accumulator = (accumulator - accumulator % 256) / 256
					held -= 8
				end
			end
			if held > 0 then
				Writer.u8(writer, accumulator % 256)
			end

			-- Then the rows the cycle gets wrong.
			Writer.varint(writer, #cyclic.exceptionRows)
			for index, row in cyclic.exceptionRows do
				Writer.varint(writer, row)
				Writer.varint(writer, zigzag(cyclic.exceptionValues[index]))
			end

			ctx.stats.cyclicColumns = (ctx.stats.cyclicColumns or 0) + 1
			if plan.referenced[key] then
				materialised[key] = table.clone(column)
			end
			continue
		end

		--[[
			Runs, where a column repeats the same value many times over.

			Costed against whichever form would otherwise carry the column --
			bit-packed bits for booleans, the any-type estimate for everything
			else -- because RLE has to beat those, not the plain rows. Shuffled
			data produces a run per row and is rejected before it is written.
		]]
		--[[
			Also asked twice: once to price run-length against the packed width,
			and again below to choose the boolean form itself.

			Cheap to refuse -- it exits at the first non-boolean, so a numeric
			column pays one check -- but a column that IS boolean is walked in
			full both times, and the canonical payload hoists forty achievement
			flags per record into columns of exactly that kind.
		]]
		local cachedBoolean: boolean? = nil
		local function columnIsBoolean(): boolean
			local value = if memoise then cachedBoolean else nil
			if value == nil then
				value = Columnar.isBooleanColumn(column)
				cachedBoolean = value
			end
			return value
		end

		local runLengthSolo = if ctx.bitPack and columnIsBoolean()
			then math.ceil(rowCount / 8)
			else columnAnySolo()

		local runLength, runLengthSaving = nil, nil
		if schemaWants(COLUMN_RUN_LENGTH) then
			runLength, runLengthSaving = Columnar.runLengthFor(
				column,
				runLengthSolo,
				planDefinitionCost(keyIndex, COLUMN_RUN_LENGTH)
			)
		end

		--[[
			Runs and one dominant value describe overlapping shapes, and neither
			form dominates the other. A column that is 99% zeros holds long runs
			and RLE wins; the same column with its zeros scattered holds a run
			per row and the frequency bitmap wins. Measured on 4,000 rows:

				90% dominant    RLE 1,964 B    frequency 1,015 B
				95% dominant    RLE 1,181 B    frequency   794 B
				99% dominant    RLE   270 B    frequency   563 B

			RLE is tried first, so without this it simply claimed every such
			column -- 346 bytes worse than the frequency form on a scattered
			column that qualified for both. Whichever saves more wins, which is
			how every other pair of competing forms here is settled.
		]]
		--[[
			The frequency form, asked once and used twice.

			It is consulted here as run-length's rival and again below on its own
			account, with the SAME column, the same solo cost and the same plan
			cost -- so the second call recomputed what the first had just thrown
			away. Like the difference search above it is not a cheap test: a map
			of value counts, two growing tables of exceptions, and two full
			passes over the column.

			Memoised for the same reason and with the same caveat: the column is
			filled once at the top of the iteration and only read afterwards, so
			the two calls cannot disagree.
		]]
		local frequencySearched = false
		local frequencyPlan: Columnar.FrequencyPlan?, frequencySaving: number?

		local function columnFrequency(): (Columnar.FrequencyPlan?, number?)
			if not memoise then
				return Columnar.frequencyFor(
					column,
					columnSolo(),
					planDefinitionCost(keyIndex, COLUMN_FREQUENCY)
				)
			end
			if not frequencySearched then
				frequencySearched = true
				frequencyPlan, frequencySaving = Columnar.frequencyFor(
					column,
					columnSolo(),
					planDefinitionCost(keyIndex, COLUMN_FREQUENCY)
				)
			end
			return frequencyPlan, frequencySaving
		end

		if runLength and runLengthSaving then
			local rival, rivalSaving = columnFrequency()
			if rival and rivalSaving and rivalSaving > runLengthSaving then
				runLength = nil
			end
		end

		if runLength then
			writePlan(keyIndex, COLUMN_RUN_LENGTH, { runLength.lengthBits })
			Writer.varint(writer, #runLength.values)

			--[[
				Lengths first and together, so they can pack at a common width.
				Zero means they were cheaper as varints.
			]]
			if runLength.lengthBits > 0 then
				local accumulator, held = 0, 0
				for _, length in runLength.lengths do
					accumulator += length * 2 ^ held
					held += runLength.lengthBits
					while held >= 8 do
						Writer.u8(writer, accumulator % 256)
						accumulator = (accumulator - accumulator % 256) / 256
						held -= 8
					end
				end
				if held > 0 then
					Writer.u8(writer, accumulator % 256)
				end
			else
				for _, length in runLength.lengths do
					Writer.varint(writer, length)
				end
			end

			for _, entry in runLength.values do
				writeValue(ctx, entry, false)
			end
			ctx.stats.runLengthColumns = (ctx.stats.runLengthColumns or 0) + 1
			continue
		end

		if ctx.bitPack and columnIsBoolean() then
			writePlan(keyIndex, COLUMN_BOOLEANS, {})
			writeBooleanBits(ctx, column, rowCount)
			ctx.stats.booleanColumns = (ctx.stats.booleanColumns or 0) + 1
			continue
		end

		--[[
			Fixed-width integers, optionally differenced first so a column with a
			trend packs as narrowly as one without. Order 0 is plain frame of
			reference, which is what COLUMN_BITPACKED carried on its own.

			Tried before the dictionary because a numeric column never qualifies
			for one, and before the plain form because it is only offered when it
			is provably smaller.
		]]
		--[[
			One dominant value, or one value throughout.

			Tried before the packed forms because those size a column by its
			range: two thousand zeros with three outliers still pay full width
			per row. Only offered when provably smaller, so an even distribution
			falls through to whatever differencing chooses.
		]]
		-- The same search the run-length rivalry above already ran.
		local frequency = if schemaWants(COLUMN_FREQUENCY) then columnFrequency() else nil
		if frequency then
			local exceptionCount = #frequency.exceptions
			--[[
				`gapBits` is zero for a bitmap and otherwise the width the row
				gaps pack at. It rides in the plan because it describes the
				encoding rather than the data, and because the decoder must know
				which form to read before it reads anything.
			]]
			writePlan(keyIndex, COLUMN_FREQUENCY, {
				frequency.exceptionBits,
				frequency.gapBits,
			})
			Writer.varint(writer, zigzag(frequency.value))
			Writer.varint(writer, exceptionCount)

			if exceptionCount > 0 then
				if frequency.gapBits > 0 then
					--[[
						The distance from each exception to the last, packed at a
						shared width. A skewed column spends a bit a row on the
						bitmap where its exceptions deserve a tenth of that: ten
						exceptions across a thousand rows are twelve bytes here
						against a hundred and twenty-five.
					]]
					local accumulator, held = 0, 0
					local previous = 0
					for _, row in frequency.exceptionRows do
						accumulator += (row - previous) * 2 ^ held
						previous = row
						held += frequency.gapBits
						while held >= 8 do
							Writer.u8(writer, accumulator % 256)
							accumulator = (accumulator - accumulator % 256) / 256
							held -= 8
						end
					end
					if held > 0 then
						Writer.u8(writer, accumulator % 256)
					end
				else
					-- A bit per row saying which rows hold something else.
					local byte, bit = 0, 0
					local nextException = 1
					for index = 1, rowCount do
						if frequency.exceptionRows[nextException] == index then
							byte += 2 ^ bit
							nextException += 1
						end
						bit += 1
						if bit == 8 then
							Writer.u8(writer, byte)
							byte, bit = 0, 0
						end
					end
					if bit > 0 then
						Writer.u8(writer, byte)
					end
				end

				-- Then the exception values, packed at one shared width.
				local accumulator, held = 0, 0
				for _, entry in frequency.exceptions do
					accumulator += zigzag(entry) * 2 ^ held
					held += frequency.exceptionBits
					while held >= 8 do
						Writer.u8(writer, accumulator % 256)
						accumulator = (accumulator - accumulator % 256) / 256
						held -= 8
					end
				end
				if held > 0 then
					Writer.u8(writer, accumulator % 256)
				end
			end

			if exceptionCount == 0 then
				ctx.stats.oneValueColumns = (ctx.stats.oneValueColumns or 0) + 1
			else
				ctx.stats.frequencyColumns = (ctx.stats.frequencyColumns or 0) + 1
			end
			continue
		end

		--[[
			Decimals wearing a float's clothes.

			Tried after the integer forms, which refuse a fractional value, and
			before the plain form, which is where such a column would otherwise
			land at a tag and eight bytes a row. That is the baseline it has to
			beat, and the only one available.
		]]
		--[[
			`decimalFor` searches exponents for one that makes every value
			integral, which is a pass over the column per exponent tried. A
			column of plain integers or of true doubles answers no at every
			exponent, and a repeat of the same shape will answer no again.
		]]
		local decimal = if schemaWants(COLUMN_DECIMAL)
			then Columnar.decimalFor(
				column,
				rowCount * 9,
				planDefinitionCost(keyIndex, COLUMN_DECIMAL)
			)
			else nil
		if decimal then
			--[[
				The order says how the scaled integers were packed: zero for
				offsets from `low` as before, one or two when differencing the
				trend out was cheaper.
			]]
			--[[
				Width and order share one descriptor byte. A width never exceeds
				45 and an order never exceeds 2, so six bits and two bits fit
				together -- which keeps a decimal plan exactly the size it was
				before the order existed. A second byte would have cost one byte
				per distinct plan, which is small but is a loss the qualifier
				never costed.
			]]
			local decimalOrder = decimal.order or 0
			writePlan(keyIndex, COLUMN_DECIMAL, { decimal.bits + decimalOrder * 64 })
			Writer.u8(writer, decimal.exponent)
			Writer.u8(writer, decimal.factor)

			if decimalOrder > 0 then
				writeDifferenced(
					ctx,
					decimal.values,
					rowCount,
					decimalOrder,
					decimal.seeds :: { number },
					decimal.bits
				)
			else
				Writer.varint(writer, zigzag(decimal.low))

				local accumulator, held = 0, 0
				for _, entry in decimal.values do
					accumulator += (entry - decimal.low) * 2 ^ held
					held += decimal.bits
					while held >= 8 do
						Writer.u8(writer, accumulator % 256)
						accumulator = (accumulator - accumulator % 256) / 256
						held -= 8
					end
				end
				if held > 0 then
					Writer.u8(writer, accumulator % 256)
				end
			end

			-- Values no exponent could express, as they were.
			Writer.varint(writer, #decimal.exceptionRows)
			for index, row in decimal.exceptionRows do
				Writer.varint(writer, row)
				Writer.f64(writer, decimal.exceptionValues[index])
			end

			ctx.stats.decimalColumns = (ctx.stats.decimalColumns or 0) + 1
			continue
		end

		--[[
			The same search the estimates above already ran, read from the memo
			rather than repeated. This is the only caller that needs more than
			the saving: the order and width go in the plan and the seeds are
			data, so all three are written out.
		]]
		local order, seeds, bits = columnPack()
		if order and seeds and bits then
			-- Order and width describe the encoding; the seeds are data.
			writePlan(keyIndex, COLUMN_DIFFERENCED, { order, bits })
			writeDifferenced(ctx, column, rowCount, order, seeds, bits)
			if order > 0 then
				ctx.stats.differencedColumns = (ctx.stats.differencedColumns or 0) + 1
			else
				ctx.stats.bitPackedColumns = (ctx.stats.bitPackedColumns or 0) + 1
			end
			continue
		end

		--[[
			Positions as deltas from a per-run base. Only offered when the
			qualifier has proved it smaller than the plain form, and only for
			integral components -- delta arithmetic on floats is not exact.
		]]
		local deltaRuns, _deltaVectorSaving, deltaVectorFactor = Columnar.deltaVectorFor(column)
		if deltaRuns then
			writePlan(keyIndex, COLUMN_DELTA_VECTOR3, {})
			writeDeltaRuns(ctx, column, deltaRuns, vector3Components, deltaVectorFactor :: number)
			ctx.stats.deltaVectorColumns = (ctx.stats.deltaVectorColumns or 0) + 1
			continue
		end

		local delta2Runs, _delta2Saving, delta2Factor = Columnar.deltaVector2For(column)
		if delta2Runs then
			writePlan(keyIndex, COLUMN_DELTA_VECTOR2, {})
			writeDeltaRuns(ctx, column, delta2Runs, vector2Components, delta2Factor :: number)
			ctx.stats.deltaVector2Columns = (ctx.stats.deltaVector2Columns or 0) + 1
			continue
		end

		--[[
			CFrames: position delta'd, rotation written per row exactly as the
			single-value form writes it. A rotation is already one byte in the
			common case, so there is nothing for a base to subtract.
		]]
		local deltaCFrameRuns, _deltaCFrameSaving, deltaCFrameFactor = Columnar.deltaCFrameFor(column)
		if deltaCFrameRuns then
			writePlan(keyIndex, COLUMN_DELTA_CFRAME, {})
			writeDeltaRuns(ctx, column, deltaCFrameRuns, cframeComponents, deltaCFrameFactor :: number, function(entry)
				writeRotation(ctx, entry :: CFrame)
			end)
			ctx.stats.deltaCFrameColumns = (ctx.stats.deltaCFrameColumns or 0) + 1
			continue
		end

		--[[
			A column of datatypes drawn from a small vocabulary.

			A palette of colours, a set of materials, a handful of sizes: the
			string forms below refuse these and the delta forms above only take
			the geometric ones, so they fell to the plain form and wrote every
			value in full. Two thousand rows of eight colours cost 8,023 bytes
			that way against about 780 as eight entries and a packed id.

			The per-value cost is measured rather than assumed, since it differs
			by type -- a Color3 repeat is four bytes, a BrickColor two.
		]]
		local datatypeBytes = DATATYPE_VALUE_BYTES[typeof(column[1])]
		if ctx.columnar and datatypeBytes then
			local entries, lookup, keyOf =
				Columnar.datatypeDictionaryFor(column, datatypeBytes)

			if entries and lookup and keyOf then
				writePlan(keyIndex, COLUMN_DATATYPE_DICT, {})
				Writer.varint(writer, #entries)
				for _, entry in entries do
					writeValue(ctx, entry, false)
				end

				local idBits = 1
				while idBits < MAX_DICTIONARY_ID_BITS and 2 ^ idBits < #entries do
					idBits += 1
				end

				local accumulator, held = 0, 0
				for index = 1, rowCount do
					accumulator += (lookup[keyOf(column[index])] - 1) * 2 ^ held
					held += idBits
					while held >= 8 do
						Writer.u8(writer, accumulator % 256)
						accumulator = (accumulator - accumulator % 256) / 256
						held -= 8
					end
				end
				if held > 0 then
					Writer.u8(writer, accumulator % 256)
				end

				ctx.stats.datatypeDictColumns = (ctx.stats.datatypeDictColumns or 0) + 1
				continue
			end
		end

		--[[
			A datatype column taken apart into its components.

			The dictionary above catches these when they repeat; this catches
			them when they vary, which is where the plain form was at its worst
			-- 500 sorted Rects cost 8,514 bytes against 104 for the same four
			numbers as scalars.

			The components are handed back as rows of a nested array, which
			re-enters the columnar path and lets differencing, bit-packing and
			the rest see numbers that were previously sealed inside a userdata.
			The same re-entry trick the optional column uses, for the same
			reason: the forms are worth more than a bespoke encoder per type.

			Written only when it actually comes out smaller. The components each
			pay for a plan of their own, so a column of unrelated values would
			grow, and rather than model that the two forms are both encoded and
			the shorter kept.
		]]
		if ctx.columnar then
			local componentColumns = Columnar.datatypeSplitFor(column)
			local splitId = DATATYPE_SPLIT_IDS[typeof(column[1])]

			if componentColumns and splitId then
				--[[
					Measure both. `mark` is where this column's bytes begin, so
					the plain form can be written, sized, and rolled back if the
					split turns out to be the smaller of the two.
				]]
				local wrapped = table.create(rowCount)
				for index = 1, rowCount do
					local row = {}
					for component, values in componentColumns do
						row[tostring(component)] = values[index]
					end
					wrapped[index] = row
				end

				local probe = Encoder.newContext({
					structureCache = true,
					columnar = true,
					correlate = ctx.correlate,
					bitPack = ctx.bitPack,
					precision = ctx.precision,
				})
				local splitOk = pcall(writeValue, probe, wrapped, false)
				local splitBytes = if splitOk
					then probe.writer.cursor
					else math.huge

				local plainProbe = Encoder.newContext({
					structureCache = true,
					columnar = true,
					bitPack = ctx.bitPack,
					precision = ctx.precision,
				})
				local plainOk = pcall(function()
					for index = 1, rowCount do
						writeValue(plainProbe, column[index], false)
					end
				end)
				local plainBytes = if plainOk
					then plainProbe.writer.cursor
					else math.huge

				if splitBytes < plainBytes then
					writePlan(keyIndex, COLUMN_DATATYPE_SPLIT, { splitId })
					writeValue(ctx, wrapped, false)
					ctx.stats.datatypeSplitColumns = (ctx.stats.datatypeSplitColumns or 0)
						+ 1
					continue
				end
			end
		end

		--[[
			Dates, which are integers wearing a string.

			Tried before the shared string ids because it is the one form that
			removes strings from the packet rather than referencing them. Every
			other string form leaves the distinct values in the table and argues
			about how cheaply to point at them; this one means they are never
			written at all.

			That is also why the baseline here is computed rather than taken from
			`columnAnySoloBytes`. That function deliberately leaves the table
			entries out, on the grounds that competing forms all pay them and
			they cancel -- true for every string form except this one. A date
			column that is 488 distinct values of ten characters carries 5,856
			bytes of table that only this form avoids, and costing it as though
			they cancelled would hide the entire saving.
		]]
		if ctx.columnar and typeof(column[1]) == "string" then
			local unseen: { [string]: boolean } = {}
			local tableBytes = 0
			local idBits = 1
			local distinctHere = 0

			for index = 1, rowCount do
				local entry = column[index]
				if type(entry) ~= "string" then
					distinctHere = 0
					break
				end
				if not unseen[entry] then
					unseen[entry] = true
					distinctHere += 1
					-- Only a string the packet has not already interned is a saving.
					if ctx.stringIds[entry] == nil then
						tableBytes += 2 + #entry
					end
				end
			end

			if distinctHere > 0 then
				while idBits < 32 and 2 ^ idBits <= distinctHere do
					idBits += 1
				end

				local stringSolo = 1 + math.ceil(rowCount * idBits / 8) + tableBytes
				local date = if schemaWants(COLUMN_DATE)
					then Columnar.dateFor(
						column,
						stringSolo,
						planDefinitionCost(keyIndex, COLUMN_DATE)
					)
					else nil

				if date then
					--[[
						Width and order share the descriptor byte, six bits and
						two, exactly as the decimal plan packs them.
					]]
					local dateOrder = date.order or 0
					writePlan(keyIndex, COLUMN_DATE, { date.bits + dateOrder * 64 })

					if dateOrder > 0 then
						writeDifferenced(
							ctx,
							date.days,
							rowCount,
							dateOrder,
							date.seeds :: { number },
							date.bits
						)
					else
						Writer.varint(writer, zigzag(date.low))

						local accumulator, held = 0, 0
						for _, day in date.days do
							accumulator += (day - date.low) * 2 ^ held
							held += date.bits
							while held >= 8 do
								Writer.u8(writer, accumulator % 256)
								accumulator = (accumulator - accumulator % 256) / 256
								held -= 8
							end
						end
						if held > 0 then
							Writer.u8(writer, accumulator % 256)
						end
					end

					ctx.stats.dateColumns = (ctx.stats.dateColumns or 0) + 1
					continue
				end

				--[[
					Identifiers: a constant label around a fixed-width counter.

					Costed against the same baseline as the date form and for the
					same reason -- it is the other scheme that removes strings
					from the packet rather than pointing at them. A thousand
					distinct `TXN-1000NN` values carry 12,000 bytes of table that
					only this form avoids.
				]]
				local prefixed = if schemaWants(COLUMN_PREFIXED_INT)
					then Columnar.prefixedIntFor(
						column,
						stringSolo,
						planDefinitionCost(keyIndex, COLUMN_PREFIXED_INT)
					)
					else nil

				if prefixed then
					--[[
						Order rides in the width descriptor: a counter is never
						wider than eighteen digits, so five bits hold the width
						and two the order, and the plan stays two bytes.
					]]
					local prefixedOrder = prefixed.order or 0
					writePlan(
						keyIndex,
						COLUMN_PREFIXED_INT,
						{ prefixed.bits, prefixed.width + prefixedOrder * 32 }
					)
					Writer.string(writer, prefixed.prefix)
					Writer.string(writer, prefixed.suffix)

					if prefixedOrder > 0 then
						writeDifferenced(
							ctx,
							prefixed.values,
							rowCount,
							prefixedOrder,
							prefixed.seeds :: { number },
							prefixed.bits
						)
					else
						Writer.varint(writer, zigzag(prefixed.low))

						local accumulator, held = 0, 0
						for _, value in prefixed.values do
							accumulator += (value - prefixed.low) * 2 ^ held
							held += prefixed.bits
							while held >= 8 do
								Writer.u8(writer, accumulator % 256)
								accumulator = (accumulator - accumulator % 256) / 256
								held -= 8
							end
						end
						if held > 0 then
							Writer.u8(writer, accumulator % 256)
						end
					end

					ctx.stats.prefixedIntColumns = (ctx.stats.prefixedIntColumns or 0) + 1
					continue
				end
			end
		end

		--[[
			Strings as packed ids into the packet's own string table.

			Tried before the per-column dictionary, which rebuilds itself for
			every array and so cannot pay on the many-small-arrays shape that
			real save data actually has.
		]]
		local sharedBits = Columnar.sharedStringIdsFor(column, function(entry)
			return ctx.stringIds[entry]
		end)
		if sharedBits then
			-- The width describes the encoding; the packed ids are data.
			writePlan(keyIndex, COLUMN_SHARED_STRINGS, { sharedBits })

			local accumulator = 0
			local held = 0
			for index = 1, rowCount do
				accumulator += ctx.stringIds[column[index]] * 2 ^ held
				held += sharedBits

				while held >= 8 do
					Writer.u8(writer, accumulator % 256)
					accumulator = (accumulator - accumulator % 256) / 256
					held -= 8
				end
			end
			if held > 0 then
				Writer.u8(writer, accumulator % 256)
			end

			ctx.stats.sharedStringColumns = (ctx.stats.sharedStringColumns or 0) + 1
			continue
		end

		local entries, lookup = Columnar.dictionaryFor(column)
		if entries and lookup then
			writePlan(keyIndex, COLUMN_DICTIONARY, {})
			Writer.varint(writer, #entries)
			for _, entry in entries do
				writeString(ctx, entry, 0)
			end

			--[[
				The ids are bounded by the entry count, so they pack at a width
				the decoder can derive rather than one the plan has to carry.

				A varint apiece spends a whole byte on a dictionary of twenty --
				where five bits would do -- and two bytes once past 128 entries.
				Worth 37% of the id bytes on a long column, and the width costs
				nothing because the entry count precedes it on the wire.
			]]
			-- Entries are capped at 255, so eight bits always suffice.
			local idBits = 1
			while idBits < MAX_DICTIONARY_ID_BITS and 2 ^ idBits < #entries do
				idBits += 1
			end

			local accumulator, held = 0, 0
			for index = 1, rowCount do
				accumulator += (lookup[column[index]] - 1) * 2 ^ held
				held += idBits

				while held >= 8 do
					Writer.u8(writer, accumulator % 256)
					accumulator = (accumulator - accumulator % 256) / 256
					held -= 8
				end
			end
			if held > 0 then
				Writer.u8(writer, accumulator % 256)
			end
			ctx.stats.dictionaryColumns = (ctx.stats.dictionaryColumns or 0) + 1
			continue
		end

		--[[
			A column of arrays, batched into one columnar block.

			Last before the plain fallback, because it only applies where the
			plain form would otherwise write each array separately -- which is
			what it exists to avoid. Every scalar form above has already
			declined, since a column of tables suits none of them.

			The saving is large and it is not framing. Two thousand inventories
			written apart produced 7,547 columns of about fourteen values;
			concatenated they produce four columns of thirty thousand, and forms
			that cannot pay for themselves over fourteen rows -- a dictionary of
			item names above all -- become nearly free. 93,219 bytes to 72,395,
			and 125 ms to 53.

			`writeValue` on the concatenated rows rather than a direct columnar
			call: the rows are an ordinary array of records and the whole point
			is that the existing path handles them well. Re-entering it also
			means a batched block can itself contain batchable columns, which is
			what a quest log inside an inventory would need.
		]]
		if ctx.columnar and type(column[1]) == "table" then
			local batchRows, lengths = Columnar.batchableArrays(
				column,
				rowCount,
				ctx.tableIds
			)

			if batchRows and lengths then
				writePlan(keyIndex, COLUMN_BATCHED, {})

				--[[
					The lengths first, packed at the width the longest array
					needs. They are the only thing the decoder cannot recover
					from the block itself, and they are small: two thousand
					inventories of five to twenty-five items need five bits
					each.
				]]
				local widest = 0
				for _, length in lengths do
					if length > widest then
						widest = length
					end
				end

				local lengthBits = 1
				while lengthBits < 32 and 2 ^ lengthBits <= widest do
					lengthBits += 1
				end

				Writer.u8(writer, lengthBits)

				local accumulator, held = 0, 0
				for _, length in lengths do
					accumulator += length * 2 ^ held
					held += lengthBits
					while held >= 8 do
						Writer.u8(writer, accumulator % 256)
						accumulator = (accumulator - accumulator % 256) / 256
						held -= 8
					end
				end
				if held > 0 then
					Writer.u8(writer, accumulator % 256)
				end

				--[[
					Then the concatenation, as an ordinary value. The rows keep
					their identities -- `batchableArrays` refused the batch if any
					array was shared -- so references elsewhere in the packet
					still resolve.
				]]
				writeValue(ctx, batchRows, false)

				ctx.stats.batchedColumns = (ctx.stats.batchedColumns or 0) + 1
				continue
			end
		end

		writePlan(keyIndex, COLUMN_PLAIN, {})
		for index = 1, rowCount do
			writeValue(ctx, column[index], false)
		end
	end

	ctx.stats.columnarArrays = (ctx.stats.columnarArrays or 0) + 1
end

local function measureTable(value: { [any]: any }): (number, number)
	local arrayCount = 0
	while rawget(value, arrayCount + 1) ~= nil do
		arrayCount += 1
	end

	local total = 0
	for _ in pairs(value) do
		total += 1
	end

	return arrayCount, total - arrayCount
end

local function writeTable(ctx: Context, value: { [any]: any }, keyMark: number): ()
	local existingId = ctx.tableIds[value]
	if existingId then
		tag(ctx, Tags.TABLE_REF, keyMark)
		Writer.varint(ctx.writer, existingId)
		return
	end

	-- Claim the id before descending. A cycle that leads back here will then
	-- find it and emit a TABLE_REF rather than recursing forever.
	local id = ctx.nextTableId + 1
	ctx.nextTableId = id
	ctx.tableIds[value] = id

	local depth = ctx.depth + 1
	if depth > ctx.maxDepth then
		error(`Zzzz: table nesting exceeded {ctx.maxDepth} levels`, 0)
	end
	ctx.depth = depth

	local writer = ctx.writer
	local arrayCount, mapCount = measureTable(value)

	if arrayCount == 0 and mapCount == 0 then
		tag(ctx, Tags.EMPTY_TABLE, keyMark)
		ctx.depth = depth - 1
		return
	end

	--[[
		Columnar arrays.

		Tried before anything else, because it subsumes the row-by-row
		structure cache for arrays of records. Columnar.qualifies refuses any
		array whose rows are shared or cyclic, so reference identity survives.
	]]
	if ctx.columnar and mapCount == 0 and arrayCount >= Columnar.MIN_ROWS then
		local rowCount, keys = Columnar.qualifies(value, ctx.tableIds)
		if rowCount and keys then
			writeColumns(ctx, value, rowCount, keys, keyMark, false)
			ctx.depth = depth - 1
			return
		end

		--[[
			Positional rows, renamed and sent down the same path.

			`qualifies` wants string keys, so tuples arrive here unclaimed. They
			are records all the same, so the positions become names, the ordinary
			machinery runs, and a flag on the shape turns them back. Every check
			`qualifies` makes still has to pass on the renamed rows -- sharing,
			cycles, depth -- which is why the renamed copy goes through it rather
			than around it.
		]]
		local width = Columnar.tupleWidth(value, arrayCount)
		if width then
			local renamed = table.create(arrayCount)
			for index = 1, arrayCount do
				local row = value[index]
				local named = {}
				for position = 1, width do
					named[tostring(position)] = row[position]
				end
				renamed[index] = named
			end

			local tupleRows, tupleKeys = Columnar.qualifies(renamed, ctx.tableIds)
			if tupleRows and tupleKeys then
				--[[
					The rows written are the copies, so the originals are the ones
					that must own the ids -- a reference elsewhere in the packet
					points at the row the caller handed in, not at the rename.
				]]
				writeColumns(ctx, renamed, tupleRows, tupleKeys, keyMark, true, value)
				ctx.depth = depth - 1
				return
			end
		end
	end

	--[[
		A flat array of numbers, as a column of its own.

		The columnar path above needs an array of records -- it reads one key
		across many rows -- so a plain `{1.5, 2.5, 3.5}` fell past it and paid a
		tag and a payload per value. Nothing else caught it either: measured, a
		flat array of a thousand two-decimal floats cost 8.80 bytes each, while
		the same numbers wrapped in single-key tables cost 1.91.

		That gap was the whole reason a mixed-type packet came out larger than
		JSON. Here the array is handed to the same qualifiers a column would
		get, and the cheapest wins; a form byte records which.
	]]
	--[[
		A flat array of datatypes, wrapped so it can reach the column forms.

		Every scheme that understands a datatype lives in the column writer, and
		that writer only ever sees a *key* of an array of records. A bare
		`{ Rect, Rect, ... }` has no key, so it reached none of them and wrote
		each value whole -- 8,505 bytes for five hundred sorted Rects, against
		117 for the same values under a one-key struct.

		Wrapping each value as a single-field row costs a shape header once and
		hands the column to the split, the dictionary and the delta forms alike.
		The same re-entry the optional column and the tuple form use.
	]]
	if ctx.columnar and mapCount == 0 and arrayCount >= Columnar.MIN_ROWS then
		local kind = typeof(value[1])
		if
			kind ~= "number"
			and kind ~= "string"
			and kind ~= "boolean"
			and kind ~= "table"
			and (
				Columnar.DATATYPE_COMPONENTS[kind] ~= nil
				or DATATYPE_VALUE_BYTES[kind] ~= nil
			)
		then
			local uniform = true
			for index = 1, arrayCount do
				if typeof(value[index]) ~= kind then
					uniform = false
					break
				end
			end

			if uniform then
				local wrapped = table.create(arrayCount)
				for index = 1, arrayCount do
					wrapped[index] = { v = value[index] }
				end

				--[[
					Both forms measured, not assumed. A column of unrelated
					values gains nothing from the wrap and would only pay the
					shape header, so the plain array wins and is kept.
				]]
				local probe = Encoder.newContext({
					structureCache = true,
					columnar = true,
					correlate = ctx.correlate,
					bitPack = ctx.bitPack,
					precision = ctx.precision,
				})
				local wrapOk = pcall(writeValue, probe, wrapped, false)

				local plainProbe = Encoder.newContext({
					precision = ctx.precision,
					bitPack = ctx.bitPack,
				})
				local plainOk = pcall(writeValue, plainProbe, value, false)

				if
					wrapOk
					and plainOk
					and probe.writer.cursor < plainProbe.writer.cursor
				then
					tag(ctx, Tags.DATATYPE_ARRAY, keyMark)
					writeValue(ctx, wrapped, false)
					ctx.stats.datatypeArrays = (ctx.stats.datatypeArrays or 0) + 1
					ctx.depth = depth - 1
					return
				end
			end
		end
	end

	if ctx.columnar and mapCount == 0 and arrayCount >= NUMBER_ARRAY_MIN_ROWS then
		local numeric = true
		for index = 1, arrayCount do
			if type(value[index]) ~= "number" then
				numeric = false
				break
			end
		end

		if numeric then
			local column = table.create(arrayCount)
			for index = 1, arrayCount do
				column[index] = value[index]
			end

			--[[
				What the array costs as it would otherwise be written: a tag and
				a payload for each value. Integers fold small values into the
				tag, so they are costed properly rather than assumed to be nine
				bytes.
			]]
			local plain = 0
			for index = 1, arrayCount do
				local entry = column[index]
				if entry % 1 == 0 and entry == entry and math.abs(entry) < 2 ^ 53 then
					plain += Columnar.integerCost(entry)
				else
					plain += 9
				end
			end

			local decimal = Columnar.decimalFor(column, plain, 3, NUMBER_ARRAY_MIN_ROWS)

			if decimal then
				--[[
					Width and order share a byte here for the same reason they do
					in a column plan: six bits of width, two of order.
				]]
				local decimalOrder = decimal.order or 0
				tag(ctx, Tags.NUMBER_ARRAY, keyMark)
				Writer.varint(writer, arrayCount)
				Writer.u8(writer, NUMBER_ARRAY_DECIMAL)
				Writer.u8(writer, decimal.bits + decimalOrder * 64)
				Writer.u8(writer, decimal.exponent)
				Writer.u8(writer, decimal.factor)

				if decimalOrder > 0 then
					writeDifferenced(
						ctx,
						decimal.values,
						arrayCount,
						decimalOrder,
						decimal.seeds :: { number },
						decimal.bits
					)
				else
					Writer.varint(writer, zigzag(decimal.low))

					local accumulator, held = 0, 0
					for _, entry in decimal.values do
						accumulator += (entry - decimal.low) * 2 ^ held
						held += decimal.bits
						while held >= 8 do
							Writer.u8(writer, accumulator % 256)
							accumulator = (accumulator - accumulator % 256) / 256
							held -= 8
						end
					end
					if held > 0 then
						Writer.u8(writer, accumulator % 256)
					end
				end

				Writer.varint(writer, #decimal.exceptionRows)
				for index, row in decimal.exceptionRows do
					Writer.varint(writer, row)
					Writer.f64(writer, decimal.exceptionValues[index])
				end

				ctx.stats.numberArrayColumns = (ctx.stats.numberArrayColumns or 0) + 1
				ctx.depth = depth - 1
				return
			end

			local order, seeds, packBits, packSaving = Columnar.differencedPackFor(column)
			if order and seeds and packBits and packSaving and packSaving > 3 then
				tag(ctx, Tags.NUMBER_ARRAY, keyMark)
				Writer.varint(writer, arrayCount)
				Writer.u8(writer, NUMBER_ARRAY_DIFFERENCED)
				Writer.u8(writer, order)
				Writer.u8(writer, packBits)
				writeDifferenced(ctx, column, arrayCount, order, seeds, packBits)

				ctx.stats.numberArrayColumns = (ctx.stats.numberArrayColumns or 0) + 1
				ctx.depth = depth - 1
				return
			end
		end
	end

	--[[
		Bit packing. A dense array of 8 or more booleans becomes a count plus
		one bit per entry, turning 1000 booleans from 1000 bytes into 125.
	]]
	if ctx.bitPack and mapCount == 0 and arrayCount >= 8 then
		local booleanCount = Quantize.booleanArrayLength(value)
		if booleanCount then
			--[[
				The count is omitted when it repeats the previous boolean
				array's. Fixed-width flag blocks -- forty achievements a player,
				a row of quest states -- are otherwise two bytes of framing each,
				and the count half of that never changes.
			]]
			if booleanCount == ctx.lastBooleanCount then
				tag(ctx, Tags.BOOL_ARRAY_SAME, keyMark)
				ctx.stats.boolArraysSameLength = (ctx.stats.boolArraysSameLength or 0) + 1
			else
				tag(ctx, Tags.BOOL_ARRAY, keyMark)
				Writer.varint(writer, booleanCount)
				ctx.lastBooleanCount = booleanCount
			end

			local byte = 0
			local bit = 0
			for index = 1, booleanCount do
				if value[index] then
					byte += 2 ^ bit
				end
				bit += 1
				if bit == 8 then
					Writer.u8(writer, byte)
					byte, bit = 0, 0
				end
			end
			-- Flush the trailing partial byte.
			if bit > 0 then
				Writer.u8(writer, byte)
			end

			ctx.depth = depth - 1
			return
		end
	end

	--[[
		Structure cache.

		A pure string-keyed table is a "shape". The first time a shape is seen
		its keys are written once and given an id; every later table with the
		same keys sends STRUCT + the id + the values, and the keys never appear
		again. For arrays of similar records -- the common case in save data
		and replication -- this removes most of the packet.
	]]
	--[[
		A map of same-shaped structs, transposed into columns.

		Tried before the structure cache, because the structure cache is what
		this replaces: it writes each struct's fields one at a time, each with
		its own type tag, where the columnar path would write one column per
		field. Measured on four thousand structs, 80,561 bytes became 40,109 --
		3,999 tagged field-writes becoming five packed columns.

		The keys travel as a column of their own under a reserved name, so the
		whole thing is an ordinary columnar array and the decoder needs no new
		machinery beyond lifting the keys back out.

		`Columnar.transposableMap` refuses anything the rebuild could not undo
		exactly: differing field sets, nested tables, shared structs, or a
		struct that already carries the reserved name.
	]]
	if ctx.columnar and arrayCount == 0 and mapCount >= Columnar.TRANSPOSE_MIN_STRUCTS then
		local transposed = Columnar.transposableMap(value, ctx.tableIds)
		if transposed then
			tag(ctx, Tags.STRUCT_COLUMNS, keyMark)
			writeValue(ctx, transposed, false)
			ctx.stats.transposedMaps = (ctx.stats.transposedMaps or 0) + 1
			ctx.depth = depth - 1
			return
		end
	end

	if ctx.structureCache and arrayCount == 0 and mapCount > 0 then
		local signature = shapeSignature(value, mapCount)
		if signature then
			local shapeId = ctx.shapeIds[signature]

			if shapeId then
				--[[
					The first few shape ids fold into the tag. Real payloads
					define very few shapes, so this covers nearly every hit.
				]]
				if shapeId <= Tags.FOLD_STRUCT_COUNT then
					tag(ctx, Tags.FOLD_STRUCT + shapeId - 1, keyMark)
				else
					tag(ctx, Tags.STRUCT, keyMark)
					Writer.varint(writer, shapeId)
				end
				local keys = ctx.shapeKeys[shapeId]
				for _, key in keys do
					writeValue(ctx, value[key], false)
				end
				ctx.stats.structHits = (ctx.stats.structHits or 0) + 1
				ctx.depth = depth - 1
				return
			end

			local keys = table.create(mapCount)
			for key in pairs(value) do
				table.insert(keys, key)
			end
			table.sort(keys)

			shapeId = ctx.nextShapeId + 1
			ctx.nextShapeId = shapeId
			ctx.shapeIds[signature] = shapeId
			ctx.shapeKeys[shapeId] = keys

			tag(ctx, Tags.STRUCT_DEF, keyMark)
			Writer.varint(writer, shapeId)
			Writer.varint(writer, #keys)
			for _, key in keys do
				writeString(ctx, key, 0)
			end
			for _, key in keys do
				writeValue(ctx, value[key], false)
			end
			ctx.stats.structDefs = (ctx.stats.structDefs or 0) + 1
			ctx.depth = depth - 1
			return
		end
	end

	if mapCount == 0 then
		tag(ctx, Tags.ARRAY, keyMark)
		Writer.varint(writer, arrayCount)
	elseif arrayCount == 0 then
		tag(ctx, Tags.MAP, keyMark)
		Writer.varint(writer, mapCount)
	else
		tag(ctx, Tags.MIXED, keyMark)
		Writer.varint(writer, arrayCount)
		Writer.varint(writer, mapCount)
	end

	for index = 1, arrayCount do
		writeValue(ctx, value[index], false)
	end

	if mapCount > 0 then
		for key, entry in pairs(value) do
			local isArrayIndex = type(key) == "number"
				and key % 1 == 0
				and key >= 1
				and key <= arrayCount
			if not isArrayIndex then
				writeValue(ctx, key, true)
				writeValue(ctx, entry, false)
			end
		end
	end

	ctx.depth = depth - 1
end

--[[
	Instances are written as an index into a side array that travels alongside
	the buffer. Roblox replicates Instance references natively, so this is the
	only form that stays correct across the network boundary.
]]
local function writeInstance(ctx: Context, value: Instance, keyMark: number): ()
	local existingId = ctx.instanceIds[value]
	if not existingId then
		existingId = #ctx.instances + 1
		ctx.instances[existingId] = value
		ctx.instanceIds[value] = existingId
	end

	tag(ctx, Tags.INSTANCE, keyMark)
	Writer.varint(ctx.writer, existingId)
end

--[[
	Full Instance mode: the hierarchy travels inside the packet.

	The tree is flattened first so that every node has an index, then written
	node by node. Instance-valued properties become either an internal index
	(pointing at another node in this same tree) or an external index (into the
	side array), which is what lets a serialized weld rebind to the rebuilt
	parts rather than the originals.
]]
local function writeInstanceTree(ctx: Context, value: Instance, keyMark: number): ()
	local tree = Instances.flatten(value, ctx.instances, ctx.instanceIds, ctx.maxNodes)
	local writer = ctx.writer
	local nodes = tree.nodes

	tag(ctx, Tags.INSTANCE_TREE, keyMark)
	Writer.varint(writer, #nodes)

	for _, node in nodes do
		writeString(ctx, node.className, 0)
		Writer.varint(writer, node.parentIndex)

		local propertyCount = 0
		for _ in node.properties do
			propertyCount += 1
		end
		Writer.varint(writer, propertyCount)
		for name, propertyValue in node.properties do
			writeString(ctx, name, 0)
			writeValue(ctx, propertyValue, false)
		end

		local referenceCount = 0
		for _ in node.references do
			referenceCount += 1
		end
		Writer.varint(writer, referenceCount)
		for name, reference in node.references do
			writeString(ctx, name, 0)
			Writer.u8(writer, reference.kind)
			Writer.varint(writer, reference.index)
		end

		local attributeCount = 0
		for _ in node.attributes do
			attributeCount += 1
		end
		Writer.varint(writer, attributeCount)
		for name, attributeValue in node.attributes do
			writeString(ctx, name, 0)
			writeValue(ctx, attributeValue, false)
		end

		Writer.varint(writer, #node.tags)
		for _, tagName in node.tags do
			writeString(ctx, tagName, 0)
		end
	end
end

function writeValue(ctx: Context, value: any, isKey: boolean): ()
	local keyMark = isKey and KEY_BIT or 0
	local valueType = typeof(value)

	if value == nil then
		tag(ctx, Tags.NIL, keyMark)
		return
	end

	if valueType == "boolean" then
		tag(ctx, value and Tags.TRUE or Tags.FALSE, keyMark)
		return
	end

	if valueType == "number" then
		writeNumber(ctx, value, keyMark)
		return
	end

	if valueType == "string" then
		writeString(ctx, value, keyMark)
		return
	end

	if valueType == "table" then
		writeTable(ctx, value, keyMark)
		return
	end

	if valueType == "buffer" then
		tag(ctx, Tags.BUFFER, keyMark)
		Writer.buffer(ctx.writer, value)
		return
	end

	if valueType == "Instance" then
		if ctx.instanceMode == "full" then
			writeInstanceTree(ctx, value, keyMark)
		else
			writeInstance(ctx, value, keyMark)
		end
		return
	end

	--[[
		Enum types are interned per packet: the name is written once and every
		later value of that type costs one byte for it. The item's position in
		its own type is written rather than its raw value, since Roblox values
		are sparse.
	]]
	if valueType == "EnumItem" then
		local enumType = value.EnumType
		local index = Enums.indexOf(value)
		if not index then
			error(`Zzzz: cannot serialize {tostring(value)}, the engine does not list it`, 0)
		end

		local typeId = ctx.enumTypeIds[enumType]
		if typeId then
			tag(ctx, Tags.ENUMITEM, keyMark)
			Writer.varint(ctx.writer, typeId)
		else
			typeId = ctx.nextEnumTypeId + 1
			ctx.nextEnumTypeId = typeId
			ctx.enumTypeIds[enumType] = typeId

			tag(ctx, Tags.ENUMITEM_DEF, keyMark)
			Writer.varint(ctx.writer, typeId)
			writeEnumType(ctx, enumType)
		end

		Writer.varint(ctx.writer, index)
		return
	end

	if valueType == "Enum" then
		local typeId = ctx.enumTypeIds[value]

		if typeId then
			tag(ctx, Tags.ENUM, keyMark)
			Writer.varint(ctx.writer, typeId)
		else
			typeId = ctx.nextEnumTypeId + 1
			ctx.nextEnumTypeId = typeId
			ctx.enumTypeIds[value] = typeId

			tag(ctx, Tags.ENUM_DEF, keyMark)
			Writer.varint(ctx.writer, typeId)
			writeEnumType(ctx, value)
		end
		return
	end

	if valueType == "Font" then
		tag(ctx, Tags.FONT, keyMark)
		writeString(ctx, value.Family, 0)
		Writer.u8(ctx.writer, value.Weight.Value // 100)
		Writer.u8(ctx.writer, value.Style.Value)
		return
	end

	local datatypeWriter = datatypeWriters[valueType]
	if datatypeWriter then
		datatypeWriter(ctx, value, keyMark)
		return
	end

	error(`Zzzz: cannot serialize value of type "{valueType}"`, 0)
end

Encoder.writeValue = writeValue

--[[
	Encode a single root value. Returns the buffer and the instance array,
	which must be passed back to Decoder together.
]]
--[[
	Packet header: version byte, flag byte, then the precision if quantization
	is on.

	Precision has to travel with the packet. A quantized value is a bare
	integer on the wire and is meaningless without the scale that produced it,
	so a reader configured differently -- or not configured at all -- would
	silently decode wrong numbers.

	It is stored as a single exponent byte rather than an f64. Precisions are
	almost always a power of ten (0.01, 0.1, 0.5), and an 8-byte header wiped
	out the entire saving on small packets: a quantized Vector3 payload is 9
	bytes against 12 exact, so paying 8 for the header made the packet larger
	overall. One byte keeps the win. Anything not representable as 10^-n falls
	back to the full f64 form.
]]
local FLAG_STRUCTURE_CACHE = 1
local FLAG_PRECISION = 2
local FLAG_PRECISION_EXACT = 4

--[[
	Marks the packet as a patch against a baseline rather than a whole value.
	Costs nothing: the flags byte is written either way.
]]
local FLAG_DELTA = 8

local precisionCode = Quantize.precisionCode

local function writeHeader(ctx: Context, extraFlags: number?): ()
	local writer = ctx.writer
	Writer.u8(writer, Tags.VERSION)

	local precision = ctx.precision
	local code = if precision then precisionCode(precision) else nil

	local flags = extraFlags or 0
	if ctx.structureCache then
		flags += FLAG_STRUCTURE_CACHE
	end
	if precision then
		flags += FLAG_PRECISION
		if not code then
			flags += FLAG_PRECISION_EXACT
		end
	end
	Writer.u8(writer, flags)

	if precision then
		if code then
			Writer.u8(writer, code)
		else
			Writer.f64(writer, precision)
		end
	end
end

Encoder.precisionCode = precisionCode

Encoder.FLAG_STRUCTURE_CACHE = FLAG_STRUCTURE_CACHE
Encoder.FLAG_PRECISION = FLAG_PRECISION

--[[
	Drop the precision from the header when nothing ended up quantized.

	Every value can individually fall back to its exact form, so a packet can
	carry a precision that nothing uses -- and then the header byte is pure
	overhead that makes the packet larger than not asking for precision at all.
	Rewriting the two header bytes is cheaper than predicting the outcome.
]]
local function trimUnusedPrecision(ctx: Context): buffer
	local packet = Writer.toBuffer(ctx.writer)

	if not ctx.precision or (ctx.stats.quantized or 0) > 0 then
		return packet
	end

	local flags = buffer.readu8(packet, 1)
	local precisionBytes = if bit32.band(flags, FLAG_PRECISION_EXACT) ~= 0 then 8 else 1
	local length = buffer.len(packet)

	local trimmed = buffer.create(length - precisionBytes)
	buffer.writeu8(trimmed, 0, buffer.readu8(packet, 0))
	buffer.writeu8(
		trimmed,
		1,
		bit32.band(flags, bit32.bnot(FLAG_PRECISION + FLAG_PRECISION_EXACT))
	)
	buffer.copy(trimmed, 2, packet, 2 + precisionBytes, length - 2 - precisionBytes)
	return trimmed
end

function Encoder.encode(value: any, options: Options?): (buffer, { Instance })
	local ctx = Encoder.newContext(options)
	writeHeader(ctx)
	writeValue(ctx, value, false)
	return trimUnusedPrecision(ctx), ctx.instances
end

--[[
	Encode into a context the caller already holds.

	`Schema` needs this in both directions: to derive, it hands in a context
	carrying a `planRecord` and reads the recorded choices back afterwards; to
	encode, it hands in one carrying a `planSchema` and the write loop replays
	those choices instead of searching for them.

	Identical to `encode` in every other respect, and the context is the only
	thing that distinguishes the three cases.
]]
function Encoder.encodeWith(ctx: Context, value: any): buffer
	writeHeader(ctx)
	writeValue(ctx, value, false)
	return trimUnusedPrecision(ctx)
end

--[[
	Same as encode, but also returns the context so callers can read stats.
	Used by Inspect.
]]
function Encoder.encodeWithContext(value: any, options: Options?): (buffer, { Instance }, Context)
	local ctx = Encoder.newContext(options)
	writeHeader(ctx)
	writeValue(ctx, value, false)
	return trimUnusedPrecision(ctx), ctx.instances, ctx
end

-- Baseline delta -------------------------------------------------------------

--[[
	Patch ops. One byte each, ahead of whatever the op carries.

	SET replaces a key with an ordinary encoded value, REMOVE deletes one, and
	DESCEND recurses into a table both sides hold -- so a change deep in a tree
	does not rewrite its ancestors. END closes a table's op list.
]]
local OP_END = 0
local OP_SET = 1
local OP_REMOVE = 2
local OP_DESCEND = 3

--[[
	An array of uniform records, written as changed rows only: the keys once,
	then per changed row an index gap, a field mask, and the changed values.
	Closes the per-field op-and-key overhead the general form pays.
]]
local OP_ROWS = 4

Encoder.OP_END = OP_END
Encoder.OP_SET = OP_SET
Encoder.OP_REMOVE = OP_REMOVE
Encoder.OP_DESCEND = OP_DESCEND
Encoder.OP_ROWS = OP_ROWS
Encoder.FLAG_DELTA = FLAG_DELTA

--[[
	Whether a field differs between two values, for the purpose of a patch.

	`~=` alone is not enough, in both directions.

	IEEE 754 says -0 == 0, so a field going from 0 to -0 compares equal, no mask
	bit is set, nothing is sent, and the receiver keeps the wrong sign -- a
	distinction Zzzz preserves everywhere else, since it has a NEG_ZERO tag for
	exactly this. Comparing reciprocals separates them: 1/0 is inf, 1/-0 is -inf.

	NaN has the opposite problem: it is never equal to itself, so a field
	holding NaN before and after would be called changed and resent every tick
	forever. Two NaNs are unchanged, which is what a receiver holding one
	already has.
]]
local function fieldChanged(before: any, value: any): boolean
	if before == value then
		-- Equal, unless they are zeros of opposite sign.
		return before == 0
			and type(before) == "number"
			and type(value) == "number"
			and (1 / before) ~= (1 / value)
	end

	-- Unequal, unless both are NaN.
	return not (
		type(before) == "number"
		and type(value) == "number"
		and before ~= before
		and value ~= value
	)
end

--[[
	Whether two tables differ anywhere inside.

	Identity is only a shortcut here, not the answer: a tick of state usually
	rebuilds its rows, so the tables are new objects holding equal values, and
	comparing them by identity alone would call every row changed and write a
	DESCEND for each -- framing for information that is not there. Measured on
	2000 unchanged rows, that cost 9,718 bytes to say nothing at all.

	So this compares contents, and memoises the answer: a pair is walked once
	however many times it is reached, which matters for shared subtables.

	`pending` holds the pairs currently being compared. A cycle that reaches one
	of them again is treated as equal, which is the only answer that terminates
	and the right one: the cycle is equal exactly when everything else about the
	pair is.
]]
local function tablesDiffer(
	ctx: Context,
	baseline: { [any]: any },
	current: { [any]: any },
	memo: { [any]: { [any]: boolean } },
	pending: { [any]: { [any]: boolean } },
	depth: number
): boolean
	--[[
		The cycle guard below stops a value that loops back on itself, but not
		one that is merely deep: ten thousand levels of honest nesting walks
		this function down until the C stack gives out, and a crash is a worse
		answer than an error.

		Serialize has counted depth since v1. This counts the same way, against
		the same limit, so a value Serialize refuses is one Diff refuses too
		rather than one it dies on.
	]]
	if depth > ctx.maxDepth then
		error(`Zzzz: table nesting exceeded {ctx.maxDepth} levels`, 0)
	end

	if baseline == current then
		return false
	end

	local knownFor = memo[current]
	if knownFor ~= nil then
		local known = knownFor[baseline]
		if known ~= nil then
			return known
		end
	end

	local pendingFor = pending[current]
	if pendingFor and pendingFor[baseline] then
		return false
	end

	if pendingFor == nil then
		pendingFor = {}
		pending[current] = pendingFor
	end
	pendingFor[baseline] = true

	local differs = false

	for key, value in pairs(current) do
		local before = baseline[key]
		if type(before) == "table" and type(value) == "table" then
			if tablesDiffer(ctx, before, value, memo, pending, depth + 1) then
				differs = true
				break
			end
			continue
		end
		if not fieldChanged(before, value) then
			continue
		end
		differs = true
		break
	end

	if not differs then
		for key in pairs(baseline) do
			if current[key] == nil then
				differs = true
				break
			end
		end
	end

	pendingFor[baseline] = nil

	if knownFor == nil then
		knownFor = {}
		memo[current] = knownFor
	end
	knownFor[baseline] = differs

	return differs
end

--[[
	Write the ops that turn `baseline` into `current`.

	Keys equal on both sides are skipped, and that is the entire saving. Keys
	both sides hold as tables descend, but only when something inside actually
	differs -- an unchanged subtree costs nothing rather than an op and a key.
	Everything else is a SET, and keys the baseline holds that the current value
	does not are a REMOVE.

	`seen` guards cycles: a table already being written higher in the walk closes
	immediately rather than recursing forever. It is keyed on the current table,
	since that is the one whose contents the ops describe.
]]
--[[
	Widest record the row form handles. The mask is a varint of this many bits,
	and past 32 fields a record is not the uniform row this form is built for.
]]
local DELTA_ROW_MAX_FIELDS = 32

--[[
	Smallest array of records worth the shared key list. Below this the keys
	cost more than repeating them per row would.
]]
local DELTA_ROWS_MIN = 4

--[[
	Whether an array is rows of one uniform record shape, present on both sides.

	This is what lets the row form drop the per-field op byte and the per-field
	key: every changed row carries the same fields in the same order, so the
	keys travel once and a bitmask names which of them a row is sending.

	Returns the key list, in a fixed order, or nil when the array is not that
	shape -- a row missing on either side, a row that is not a table, a row whose
	keys differ from the first, a nested table anywhere, or too few rows to
	repay the key list.
]]
local function recordRowKeys(
	baseline: { [any]: any },
	current: { [any]: any }
): { string }?
	local count = #current
	if count < DELTA_ROWS_MIN or #baseline ~= count then
		return nil
	end

	-- A stray map entry has nowhere to live in the row form.
	local total = 0
	for _ in pairs(current) do
		total += 1
	end
	if total ~= count then
		return nil
	end

	local keys: { string }? = nil
	local keyCount = 0

	for index = 1, count do
		local row = current[index]
		local before = baseline[index]

		if type(row) ~= "table" or type(before) ~= "table" then
			return nil
		end

		if keys == nil then
			local found: { string } = {}
			for key, value in pairs(row) do
				if type(key) ~= "string" or type(value) == "table" then
					return nil
				end
				table.insert(found, key)
			end
			if #found == 0 or #found > DELTA_ROW_MAX_FIELDS then
				return nil
			end
			table.sort(found)
			keys = found
			keyCount = #found
		end

		--[[
			Every row must hold exactly these keys, on both sides. Counting and
			then checking membership is enough: equal counts plus every key
			present means the sets match.
		]]
		local rowTotal = 0
		for _ in pairs(row) do
			rowTotal += 1
		end
		if rowTotal ~= keyCount then
			return nil
		end

		local beforeTotal = 0
		for _ in pairs(before) do
			beforeTotal += 1
		end
		if beforeTotal ~= keyCount then
			return nil
		end

		for _, key in keys :: { string } do
			local value = row[key]
			if value == nil or type(value) == "table" then
				return nil
			end
			if before[key] == nil then
				return nil
			end
		end
	end

	return keys
end

--[[
	Widest power-of-ten a row column will scale by. Matches Columnar's own cap:
	six decimal places is past anything Studio or a physics step produces, and
	every further step narrows the integer range for no realistic gain.
]]
local DELTA_ROW_MAX_FACTOR = 6

--[[
	Largest scaled integer a row column will carry, so a value that scales into
	varint territory no cheaper than its float form is left alone.
]]
local DELTA_ROW_INT_MAX = 1056959

--[[
	Roblox datatypes a delta column can take apart.

	A Vector3 column is three numeric columns wearing a hat: once its components
	are pulled out, everything the numeric path already does -- scaling, delta
	against the baseline, packing at a shared width -- applies unchanged. Without
	this a position field pays its full tagged cost, which measured 13 bytes a
	row against about 3.4 for the same numbers as separate fields: a four-fold
	penalty for using the idiomatic type.

	Measured saving per datatype, on 500 changed rows moving realistically:

		Rect            88%        Vector3 (2dp)   74%
		Vector3 (int)   80%        CFrame          74%
		Vector2         75%        UDim2           74%
		NumberRange     72%        Color3          53%

	`read` pulls the components out in a fixed order; `build` puts them back in
	the same order. Only datatypes whose whole value is those numbers appear
	here -- a CFrame's rotation is not recoverable from its position, so a
	rotated CFrame is refused below rather than silently flattened.
]]
type DatatypeColumns = {
	--[[
		Names the type on the wire. A component count is not enough to identify
		it -- a Vector3 and an unrotated CFrame are both three numbers -- so the
		id travels and the decoder rebuilds from that.
	]]
	id: number,
	count: number,
	read: (any, { number }) -> (),
	build: ({ number }) -> any,
	--[[
		Values this form cannot represent are refused, so nothing is lost by
		taking a column apart. Absent means every value of the type qualifies.
	]]
	accepts: ((any) -> boolean)?,
}

local DATATYPE_VECTOR3 = 1
local DATATYPE_VECTOR2 = 2
local DATATYPE_CFRAME = 3
local DATATYPE_COLOR3 = 4
local DATATYPE_UDIM = 5
local DATATYPE_UDIM2 = 6
local DATATYPE_RECT = 7
local DATATYPE_NUMBERRANGE = 8

local IDENTITY_ROTATION = CFrame.identity - CFrame.identity.Position

local datatypeColumns: { [string]: DatatypeColumns } = {
	Vector3 = {
		id = DATATYPE_VECTOR3,
		count = 3,
		read = function(value, out)
			local v = value :: Vector3
			out[1], out[2], out[3] = v.X, v.Y, v.Z
		end,
		build = function(parts)
			return Vector3.new(parts[1], parts[2], parts[3])
		end,
	},
	Vector2 = {
		id = DATATYPE_VECTOR2,
		count = 2,
		read = function(value, out)
			local v = value :: Vector2
			out[1], out[2] = v.X, v.Y
		end,
		build = function(parts)
			return Vector2.new(parts[1], parts[2])
		end,
	},
	--[[
		Only unrotated CFrames. The columns carry a position and nothing else,
		so a rotated one would come back upright -- silently wrong, which is
		worse than paying the tagged cost.
	]]
	CFrame = {
		id = DATATYPE_CFRAME,
		count = 3,
		read = function(value, out)
			local p = (value :: CFrame).Position
			out[1], out[2], out[3] = p.X, p.Y, p.Z
		end,
		build = function(parts)
			return CFrame.new(parts[1], parts[2], parts[3])
		end,
		accepts = function(value)
			return (value :: CFrame) - (value :: CFrame).Position == IDENTITY_ROTATION
		end,
	},
	--[[
		Channels travel as their 0..255 form, which is what colours are
		authored as and what makes them small integers rather than thirds.
		A colour that is not exactly a fromRGB is refused.
	]]
	Color3 = {
		id = DATATYPE_COLOR3,
		count = 3,
		read = function(value, out)
			local c = value :: Color3
			out[1] = math.round(c.R * 255)
			out[2] = math.round(c.G * 255)
			out[3] = math.round(c.B * 255)
		end,
		build = function(parts)
			return Color3.fromRGB(parts[1], parts[2], parts[3])
		end,
		accepts = function(value)
			local c = value :: Color3
			return Color3.fromRGB(
				math.round(c.R * 255),
				math.round(c.G * 255),
				math.round(c.B * 255)
			) == c
		end,
	},
	UDim = {
		id = DATATYPE_UDIM,
		count = 2,
		read = function(value, out)
			local u = value :: UDim
			out[1], out[2] = u.Scale, u.Offset
		end,
		build = function(parts)
			return UDim.new(parts[1], parts[2])
		end,
	},
	UDim2 = {
		id = DATATYPE_UDIM2,
		count = 4,
		read = function(value, out)
			local u = value :: UDim2
			out[1], out[2] = u.X.Scale, u.X.Offset
			out[3], out[4] = u.Y.Scale, u.Y.Offset
		end,
		build = function(parts)
			return UDim2.new(parts[1], parts[2], parts[3], parts[4])
		end,
	},
	Rect = {
		id = DATATYPE_RECT,
		count = 4,
		read = function(value, out)
			local r = value :: Rect
			out[1], out[2] = r.Min.X, r.Min.Y
			out[3], out[4] = r.Max.X, r.Max.Y
		end,
		build = function(parts)
			return Rect.new(parts[1], parts[2], parts[3], parts[4])
		end,
	},
	NumberRange = {
		id = DATATYPE_NUMBERRANGE,
		count = 2,
		read = function(value, out)
			local n = value :: NumberRange
			out[1], out[2] = n.Min, n.Max
		end,
		build = function(parts)
			return NumberRange.new(parts[1], parts[2])
		end,
	},
}

Encoder.datatypeColumns = datatypeColumns

--[[
	Which decomposition a column can use, if any.

	Every changed value in the column must be the same datatype and must be one
	the form can rebuild exactly. A column that mixes types, or holds a rotated
	CFrame among unrotated ones, falls back to tagged values whole.
]]
local function columnDatatype(
	rows: { any },
	changedRows: { number },
	changedMasks: { number },
	key: string,
	bit: number
): (string?, DatatypeColumns?)
	local name: string? = nil
	local form: DatatypeColumns? = nil
	local changedCount = #changedRows

	for order = 1, changedCount do
		local index = changedRows[order]
		if not bit32.btest(changedMasks[order], bit) then
			continue
		end

		local value = rows[index][key]
		local valueType = typeof(value)

		if name == nil then
			local candidate = datatypeColumns[valueType]
			if candidate == nil then
				return nil
			end
			name = valueType
			form = candidate
		elseif valueType ~= name then
			return nil
		end

		local accepts = (form :: DatatypeColumns).accepts
		if accepts and not accepts(value) then
			return nil
		end
	end

	if name == nil then
		return nil
	end

	return name, form
end

--[[
	The scale that turns one column's changed values into exact integers.

	This is the pseudodecimal technique the columnar path already uses, applied
	to a delta's row columns -- and it is worth far more here than anywhere
	else, because of what a two-decimal value costs through the tagged path:

		-14.23   9 bytes   F64, since 2dp is not exact in f32
		 -1423   3 bytes   I16
		scaled   2 bytes   zigzag varint, in a column that declared its scale

	Measured on 100 changed rows of three such fields: 2,870 bytes tagged
	against 794 scaled, a 72% cut, which took the form from 1.59x Serdes's size
	to 0.44x.

	Returns nil when the column is not decimal -- true floats, non-numbers, or
	values too wide once scaled -- and the column falls back to tagged values.
]]
local decimalScratch = buffer.create(4)

local function f32Round(value: number): number
	buffer.writef32(decimalScratch, 0, value)
	return buffer.readf32(decimalScratch, 0)
end

--[[
	`single` says the values came out of a datatype, whose components Roblox
	stores as f32.

	The exactness check has to match where the value came from, and getting this
	backwards silently costs everything:

		a plain Lua number is f64, so `rounded / scale` must equal it exactly --
		testing at f32 would accept a factor that truncates -14.234567

		a Vector3 component is f32, so -14.23 reads back as -14.229999542236328
		and an f64 comparison fails -- measured, 1,917 of 2,000 such values --
		which rejected the column and sent it tagged instead

	The decoder reconstructs a datatype component by handing `scaled / scale` to
	Vector3.new, which truncates to f32 in the same way, so f32 is the honest
	comparison there and f64 is the honest one for a bare number.
]]
--[[
	`count` says how many entries `values` holds, for callers whose array is
	preallocated and so carries trailing nils that `#` cannot be trusted past.
	Omitted, the array's own length is used.
]]
local function columnDecimalFactor(
	values: { number },
	single: boolean?,
	count: number?
): number?
	local anyFractional = false
	local last = count or #values

	for entry = 1, last do
		local value = values[entry]
		if type(value) ~= "number" then
			return nil
		end
		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end

		--[[
			`% 1 == 0` is not the same as "is an integer this form can carry",
			and two kinds of value slip through it:

				-0        -0 % 1 is 0, and scaling it gives the integer 0, whose
				          reciprocal is +inf rather than -inf. The sign is lost
				          and `==` will not say so, since IEEE 754 has -0 == 0.

				5e-324    a subnormal below the ones place, so `% 1` is also 0.
				          It is not zero, but every scale rounds it to zero.

			Both would take the all-integer path below and travel as 0. Rather
			than name each case, the test is whether the value survives the
			trip: scale 1, round, and compare. Anything that does not is left to
			the tagged form, which handles both correctly today.
		]]
		local asInteger = if value >= 0
			then math.floor(value + 0.5)
			else -math.floor(-value + 0.5)

		local integral = asInteger == value
		if integral and value == 0 then
			integral = (1 / asInteger) == (1 / value)
		end

		if not integral then
			if math.abs(value) < 1 and value ~= 0 then
				--[[
					Smaller than the ones place. A fractional value this small
					has no scale that reaches it -- 10^6 still rounds 5e-324 to
					zero -- so there is nothing for the loop below to find.
				]]
				if math.abs(value) < 1e-7 then
					return nil
				end
			end
			anyFractional = true
		end
	end


	--[[
		An all-integer column is already exact at scale 1, which costs nothing
		to declare and lets the delta and packed forms below work on it. A
		fractional column has to find a scale before any of that applies.
	]]
	if not anyFractional then
		return 0
	end

	for factor = 1, DELTA_ROW_MAX_FACTOR do
		local scale = 10 ^ factor
		local viable = true

		for entry = 1, last do
			local value = values[entry]
			local scaled = value * scale

			if scaled ~= scaled or scaled >= 2 ^ 53 or scaled <= -(2 ^ 53) then
				viable = false
				break
			end

			local rounded = if scaled >= 0
				then math.floor(scaled + 0.5)
				else -math.floor(-scaled + 0.5)

			-- At the precision the value will actually be rebuilt at.
			local restored = rounded / scale
			if single then
				restored = f32Round(restored)
			end

			--[[
				A value that rounds away to zero is caught here: a subnormal
				like 5e-324 scales to something under half at every factor, so
				`restored` is 0 and the comparison fails, and the column falls
				back to the tagged form.

				The zero-sign case cannot reach this point -- a negative zero is
				refused above, before a scale is ever tried -- but the reciprocal
				check stays because `==` alone would call 0 and -0 equal, and a
				future caller could reach here with one.
			]]
			local exact = restored == value
			if exact and value == 0 then
				exact = (1 / restored) == (1 / value)
			end

			if
				rounded > DELTA_ROW_INT_MAX
				or rounded < -DELTA_ROW_INT_MAX
				or not exact
			then
				viable = false
				break
			end
		end

		if viable then
			return factor
		end
	end

	return nil
end

--[[
	How a scaled column's integers travel.

	ABSOLUTE writes each value as it stands. DELTA writes how far it moved from
	the baseline, which is narrower whenever movement is small next to position
	-- a part that shifted a stud is a one-byte varint however far from the
	origin it sits. Measured over a tick of 2000 entities, that alone was 45%.

	Either can then be PACKED at one shared bit width instead of varints, the
	DELTA_BINARY_PACKED cascade the columnar path already uses: a varint
	quantises to whole bytes, a packed width does not, which was a further 10%.

	Both choices are measured per column rather than assumed, since neither
	always wins -- a teleport's delta is as wide as its position, and a column
	of uneven values packs no better than it varints.
]]
local COLUMN_VARINT_ABSOLUTE = 0
local COLUMN_VARINT_DELTA = 1
local COLUMN_PACKED_ABSOLUTE = 2
local COLUMN_PACKED_DELTA = 3

Encoder.COLUMN_VARINT_ABSOLUTE = COLUMN_VARINT_ABSOLUTE
Encoder.COLUMN_VARINT_DELTA = COLUMN_VARINT_DELTA
Encoder.COLUMN_PACKED_ABSOLUTE = COLUMN_PACKED_ABSOLUTE
Encoder.COLUMN_PACKED_DELTA = COLUMN_PACKED_DELTA

--[[
	How the set of changed rows travels.

	GAPS writes each changed index as its distance from the last, which is
	cheapest while few rows changed. BITMAP spends one bit per row of the whole
	array, which overtakes gaps once about a tenth of them move -- measured, 324
	bytes against 114 at 1% changed, and 3,631 against 5,381 at half.

	Neither dominates, so both are measured.
]]
local ROWSET_GAPS = 0
local ROWSET_BITMAP = 1

Encoder.ROWSET_GAPS = ROWSET_GAPS
Encoder.ROWSET_BITMAP = ROWSET_BITMAP

--[[
	How the field masks travel.

	One varint per changed row is what this was, and it is mostly padding: a
	four-field record needs four bits and spent eight, and a tick that moves one
	field of many repeats the identical mask on every changed row.

		UNIFORM   every mask the same -- written once for the whole block
		PACKED    all masks at the record's field count, so four fields cost
		          four bits rather than a byte
		VARINT    one varint each, kept for the case where the field count is
		          wide enough that packing saves nothing

	Uniform is the common shape for a positions-only tick, and takes the masks
	from a byte a row to a byte a packet.
]]
local MASK_UNIFORM = 0
local MASK_PACKED = 1
local MASK_VARINT = 2

Encoder.MASK_UNIFORM = MASK_UNIFORM
Encoder.MASK_PACKED = MASK_PACKED
Encoder.MASK_VARINT = MASK_VARINT

--[[
	Bytes a run of integers costs as varints, and as a packed block.

	Returns the varint cost, the packed cost, and the width the packed form
	would use -- or nil for the packed cost when the values need more bits than
	the form carries.
]]
--[[
	The packed half of `columnCosts`, from a sum and a maximum that a caller has
	already accumulated.

	Split out so the patch write loop can price a column while it scales it,
	rather than walking the same values again afterwards. The rule for what fits
	lives here rather than in both places.
]]
local function packedCostFor(
	varintBytes: number,
	widest: number,
	count: number
): (number, number?, number?)
	local bits = 1
	while bits < MAX_PACK_BITS and 2 ^ bits <= widest do
		bits += 1
	end

	if 2 ^ bits <= widest then
		return varintBytes, nil, nil
	end

	-- The width byte is paid either way, so it is not counted on either side.
	return varintBytes, math.ceil(count * bits / 8), bits
end

local function columnCosts(values: { number }): (number, number?, number?)
	local varintBytes = 0
	local widest = 0
	local count = #values

	for index = 1, count do
		local z = zigzag(values[index])
		varintBytes += varintWidth(z)
		if z > widest then
			widest = z
		end
	end

	return packedCostFor(varintBytes, widest, count)
end

--[[
	Write already-non-negative integers packed at a fixed width, low bits first,
	spilling a byte at a time -- the order writeBitPacked and the reader use.

	Used for field masks, which are bit sets rather than quantities: zigzagging
	one would double its width for nothing.
]]
local function writePackedUnsigned(
	writer: Writer.Writer,
	values: { number },
	bits: number
): ()
	local accumulator = 0
	local held = 0
	local count = #values

	for index = 1, count do
		accumulator += values[index] * 2 ^ held
		held += bits

		while held >= 8 do
			Writer.u8(writer, accumulator % 256)
			accumulator = (accumulator - accumulator % 256) / 256
			held -= 8
		end
	end

	if held > 0 then
		Writer.u8(writer, accumulator % 256)
	end
end

--[[
	Write integers packed at a fixed width, low bits first, spilling a byte at a
	time -- the order writeBitPacked and the reader both use.
]]
local function writePackedIntegers(
	writer: Writer.Writer,
	values: { number },
	bits: number
): ()
	local accumulator = 0
	local held = 0
	local count = #values

	for index = 1, count do
		accumulator += zigzag(values[index]) * 2 ^ held
		held += bits

		while held >= 8 do
			Writer.u8(writer, accumulator % 256)
			accumulator = (accumulator - accumulator % 256) / 256
			held -= 8
		end
	end

	if held > 0 then
		Writer.u8(writer, accumulator % 256)
	end
end

--[[
	Write an array of uniform records as changed rows only.

	Layout:

		key count, then the keys
		a scale byte per column: 0 for tagged values, n for scaled integers
		the row-set form, then the changed rows as gaps or as a bitmap
		a field mask per changed row
		then, column by column, the changed values of that column

	Values are grouped by column rather than by row, which is what lets a column
	choose one encoding for all of its values -- absolute or delta, varint or
	packed -- instead of paying a decision per value.

	Against the general op form this drops one op byte and one key reference per
	changed field; against a tagged value it drops the tag and, for the
	two-decimal quantities a tick is mostly made of, seven payload bytes with it.
]]
local function writeRecordRows(
	ctx: Context,
	baseline: { [any]: any },
	current: { [any]: any },
	keys: { string }
): ()
	local writer = ctx.writer
	local count = #current
	local keyCount = #keys

	Writer.varint(writer, keyCount)
	for _, key in keys do
		writeValue(ctx, key, false)
	end

	--[[
		Which rows changed, and their masks. Both are wanted before anything is
		written: the scales and encodings below are chosen over exactly the
		values that will travel, and no others.
	]]
	local changedRows: { number } = {}
	local changedMasks: { number } = {}

	--[[
		The powers of two the mask is built from, computed once rather than per
		field. `2 ^ (position - 1)` inside the inner loop is a power per field
		per row -- 12,000 of them on 2,000 six-column rows -- for a value that
		depends only on the position.
	]]
	local bits = table.create(keyCount)
	for position = 1, keyCount do
		bits[position] = 2 ^ (position - 1)
	end

	for index = 1, count do
		local row = current[index]
		local before = baseline[index]

		--[[
			The same table on both sides cannot differ from itself.

			A tick that rebuilds only the rows it touched -- clone the moved
			ones, keep the rest -- leaves most rows identical by IDENTITY, and
			those need no field comparison at all. Where a caller rebuilds every
			row this costs one pointer comparison per row and finds nothing,
			which is why it is a shortcut here rather than the answer: see
			`tablesDiffer`, which makes the same distinction for the same reason.
		]]
		if before ~= row then
			local mask = 0

			for position = 1, keyCount do
				--[[
					The key read once. It was indexed twice per field, once for
					each side, which is a second table lookup for a value
					already in hand.
				]]
				local key = keys[position]
				if fieldChanged(before[key], row[key]) then
					mask += bits[position]
				end
			end

			if mask ~= 0 then
				table.insert(changedRows, index)
				table.insert(changedMasks, mask)
			end
		end
	end

	local changedCount = #changedRows

	--[[
		How much of the array this patch actually carries, recorded for the
		guard in `Zzzz:Diff`.

		The guard's question is whether the patch is smaller than encoding the
		whole value, and answering it exactly costs a whole encode -- which on a
		sparse tick is most of what `Diff` costs, spent confirming something
		that was never close. What it needs instead is a cheap signal, and the
		mask scan above has already produced one: it visited every row and every
		field to decide which changed, so the changed FRACTION is known for
		free.

		The fraction predicts the ratio because both sides scale with the same
		data -- a patch carrying a tenth of the rows against a whole encode
		carrying all of them. Measured on 2,000 six-column rows:

			  0% moved     patch is   0.4% of the whole encode
			 10%                      7.5%
			 50%                     29.1%
			100%                     55.5%
			replaced                159.4%

		This is a hint, not a promise. It is only ever used to decide whether
		the exact comparison is worth making, never to replace it -- see the
		guard in `Zzzz.Diff`. A payload whose changed rows are far wider than
		its unchanged ones would sit above this line, which is exactly why the
		guard verifies rather than trusts it.

		Kept on the context rather than returned, so the ordinary paths that do
		not care are unaffected.
	]]
	local rowFraction = if count > 0 then changedCount / count else 0
	local previousFraction = ctx.stats.changedFraction
	if previousFraction == nil or rowFraction > previousFraction then
		ctx.stats.changedFraction = rowFraction
	end

	--[[
		Plan every column before writing any of them.

		A column is one of three things: a datatype taken apart into its
		components, a plain numeric column, or neither -- in which case its
		values travel tagged, as they always did. The plan carries the component
		values already extracted, since choosing a scale needs them anyway.
	]]
	type ColumnPlan = {
		kind: number,
		datatype: number?,
		axes: { { number } }?,
		factors: { number }?,
		baselineAxes: { { number } }?,
		--[[
			False when some changed row had no baseline value of the same shape,
			so the delta forms are withheld -- see where it is set.
		]]
		deltaSafe: boolean?,
		--[[
			How many entries `axes` holds. The arrays are preallocated at the
			changed-row count, so their `#` is not their length.
		]]
		count: number?,
	}

	local COLUMN_KIND_TAGGED = 0
	local COLUMN_KIND_NUMBER = 1
	local COLUMN_KIND_DATATYPE = 2

	local scratch = table.create(4)
	local plans: { ColumnPlan } = table.create(keyCount)

	for position = 1, keyCount do
		local key = keys[position]
		local bit = 2 ^ (position - 1)

		--[[
			Pull this column's changed values apart into one array per
			component: a Vector3 gives three, a plain number gives one. The
			baseline's are pulled too, since a delta needs both sides.
		]]
		local axisCount = 1
		local form: DatatypeColumns? = nil
		local _name: string?

		_name, form = columnDatatype(current, changedRows, changedMasks, key, bit)
		if form then
			axisCount = form.count
		end

		--[[
			Sized up front rather than grown.

			These take one value per changed row, and the count is known before
			the loop starts -- so `table.create` reserves it once instead of the
			array doubling its way there. Measured at 2,000 rows three quarters
			moved, the extraction was 18.5% of the patch, the single largest
			piece of it, and most of that was the growth and the `table.insert`
			calls rather than the reads.

			`filled` counts what has been written, since the arrays are now
			indexed directly. A changed ROW does not mean a changed value in
			every column -- the mask decides that -- so the count is per column
			and not simply `changedCount`.
		]]
		local axes: { { number } } = table.create(axisCount)
		local baselineAxes: { { number } } = table.create(axisCount)
		for axis = 1, axisCount do
			axes[axis] = table.create(changedCount)
			baselineAxes[axis] = table.create(changedCount)
		end
		local filled = 0

		local usable = true

		--[[
			Whether every changed row has a baseline of the same shape to
			subtract from.

			When one does not -- a field that changed type, or one the baseline
			never held -- the delta form is not just unhelpful, it is dangerous:
			the decoder would read the missing side as zero and hand back the
			movement itself as though it were the value. Measured on a
			deliberately mismatched baseline, a field whose true value was 99
			came back as 59, a number in neither side's state.

			That is unavoidable when the caller supplies the wrong baseline, but
			it must not happen when they supply the right one, so a column whose
			own baseline is incomplete is denied the delta form here.
		]]
		local deltaSafe = true

		for order = 1, changedCount do
		local index = changedRows[order]
			if not bit32.btest(changedMasks[order], bit) then
				continue
			end

			local value = current[index][key]
			local before = baseline[index][key]

			--[[
				Written by index rather than appended. The arrays were sized for
				this above, so `filled` is the cursor and no growth happens.
			]]
			filled += 1

			if form then
				form.read(value, scratch)
				for axis = 1, axisCount do
					axes[axis][filled] = scratch[axis]
				end

				if typeof(before) == typeof(value) then
					form.read(before, scratch)
					for axis = 1, axisCount do
						baselineAxes[axis][filled] = scratch[axis]
					end
				else
					deltaSafe = false
					for axis = 1, axisCount do
						baselineAxes[axis][filled] = 0
					end
				end
			else
				if type(value) ~= "number" then
					usable = false
					break
				end
				axes[1][filled] = value

				if type(before) == "number" and before == before then
					baselineAxes[1][filled] = before
				else
					deltaSafe = false
					baselineAxes[1][filled] = 0
				end
			end
		end

		--[[
			`filled` rather than `#axes[1]`: the arrays were created at the
			changed-row count and a column touched by fewer rows than that has
			trailing nils, which `#` may or may not see past. The cursor is the
			only honest length.
		]]
		if not usable or filled == 0 then
			plans[position] = { kind = COLUMN_KIND_TAGGED }
			continue
		end

		--[[
			Every component needs a scale it can be exact at. One that cannot --
			an irrational, or a value too wide once scaled -- takes the whole
			column back to tagged values, since a half-decomposed datatype has
			no form to travel in.
		]]
		local factors = table.create(axisCount)
		for axis = 1, axisCount do
			--[[
				A datatype's components are f32, a bare number is f64, and the
				check has to match or the column is rejected for values that in
				fact round-trip exactly.
			]]
			local factor = columnDecimalFactor(axes[axis], form ~= nil, filled)
			if factor == nil then
				usable = false
				break
			end

			--[[
				The baseline is scaled too, when the delta form wins, so it has
				to survive the same scale -- a baseline past 2^53 rounds to a
				number that is not the one the decoder will compute, and the
				delta would be built on it.

				Only the magnitude is checked here rather than exactness: the
				delta form is a difference of two scaled integers, so the
				baseline only has to scale to the same integer on both sides,
				which it does whenever the multiply is in range.
			]]
			local scale = 10 ^ factor
			local befores = baselineAxes[axis]
			for entry = 1, filled do
				local scaledBefore = befores[entry] * scale
				if
					scaledBefore ~= scaledBefore
					or scaledBefore >= 2 ^ 53
					or scaledBefore <= -(2 ^ 53)
				then
					usable = false
					break
				end
			end
			if not usable then
				break
			end

			factors[axis] = factor
		end

		if not usable then
			plans[position] = { kind = COLUMN_KIND_TAGGED }
			continue
		end

		plans[position] = {
			kind = if form then COLUMN_KIND_DATATYPE else COLUMN_KIND_NUMBER,
			datatype = if form then form.id else nil,
			axes = axes,
			factors = factors,
			baselineAxes = baselineAxes,
			deltaSafe = deltaSafe,
			--[[
				How many entries the axes actually hold. The arrays are sized at
				the changed-row count and a column the mask touched less often
				than that has trailing nils, so `#` is not the length -- this is.
			]]
			count = filled,
		}
	end

	--[[
		The column plan on the wire: a kind byte, then for a decomposed column
		its component count and a scale per component.
	]]
	for position = 1, keyCount do
		local plan = plans[position]
		Writer.u8(writer, plan.kind)

		if plan.kind == COLUMN_KIND_TAGGED then
			continue
		end

		local factors = plan.factors :: { number }
		if plan.kind == COLUMN_KIND_DATATYPE then
			--[[
				The id, not the component count: a Vector3 and an unrotated
				CFrame are both three numbers, and only the id tells them apart.
				The count follows from the id.
			]]
			Writer.u8(writer, plan.datatype :: number)
		end
		for _, factor in factors do
			Writer.u8(writer, factor)
		end
	end

	--[[
		The row set, whichever way is smaller.

		Gaps cost a varint per changed row; the bitmap costs a bit per row of
		the whole array whether it changed or not. The crossover sits near a
		tenth changed, so both are measured rather than guessed.
	]]
	local gapBytes = 0
	local previous = 0
	for order = 1, changedCount do
		local index = changedRows[order]
		gapBytes += varintWidth(index - previous)
		previous = index
	end
	local bitmapBytes = math.ceil(count / 8)

	if bitmapBytes < gapBytes then
		Writer.u8(writer, ROWSET_BITMAP)
		Writer.varint(writer, changedCount)

		local changed: { [number]: boolean } = {}
		for order = 1, changedCount do
			changed[changedRows[order]] = true
		end

		local accumulator = 0
		local held = 0
		for index = 1, count do
			if changed[index] then
				accumulator += 2 ^ held
			end
			held += 1
			if held == 8 then
				Writer.u8(writer, accumulator)
				accumulator = 0
				held = 0
			end
		end
		if held > 0 then
			Writer.u8(writer, accumulator)
		end
	else
		Writer.u8(writer, ROWSET_GAPS)
		Writer.varint(writer, changedCount)

		previous = 0
		for order = 1, changedCount do
			local index = changedRows[order]
			Writer.varint(writer, index - previous)
			previous = index
		end
	end

	-- The masks, in whichever of the three forms is smallest.
	local uniform = true
	local firstMask = changedMasks[1]
	for order = 1, changedCount do
		if changedMasks[order] ~= firstMask then
			uniform = false
			break
		end
	end

	if uniform and changedCount > 0 then
		Writer.u8(writer, MASK_UNIFORM)
		Writer.varint(writer, firstMask)
	else
		local packedBytes = math.ceil(changedCount * keyCount / 8)
		local varintBytes = 0
		for order = 1, changedCount do
			varintBytes += varintWidth(changedMasks[order])
		end

		if packedBytes <= varintBytes then
			Writer.u8(writer, MASK_PACKED)
			writePackedUnsigned(writer, changedMasks, keyCount)
		else
			Writer.u8(writer, MASK_VARINT)
			for order = 1, changedCount do
				Writer.varint(writer, changedMasks[order])
			end
		end
	end

	--[[
		Now the values, one component at a time.

		Each component picks its own form: a Vector3's Y often barely moves while
		its X and Z do, and nothing forces them to agree. The scale is already
		settled, so this only prices absolute against delta and varint against
		packed.
	]]
	for position = 1, keyCount do
		local plan = plans[position]

		if plan.kind == COLUMN_KIND_TAGGED then
			local key = keys[position]
			local bit = 2 ^ (position - 1)
			for order = 1, changedCount do
		local index = changedRows[order]
				if bit32.btest(changedMasks[order], bit) then
					writeValue(ctx, current[index][key], false)
				end
			end
			continue
		end

		local axes = plan.axes :: { { number } }
		local baselineAxes = plan.baselineAxes :: { { number } }
		local factors = plan.factors :: { number }

		local axisCount = #axes

		for axis = 1, axisCount do
			local scale = 10 ^ factors[axis]
			local values = axes[axis]
			local befores = baselineAxes[axis]
			--[[
				From the plan, not from `#values`: the axes are preallocated at
				the changed-row count and a column the mask touched less often
				has trailing nils behind the real entries.
			]]
			local valueCount = plan.count :: number

			--[[
				The delta forms are only offered when every changed row had a
				baseline of the same shape. Without that, a decoder reads the
				missing side as zero and reconstructs the movement as the value.
			]]
			local deltaSafe = plan.deltaSafe ~= false

			local absolute = table.create(valueCount)
			local deltas = if deltaSafe then table.create(valueCount) else nil

			--[[
				Scaled and priced in one pass.

				This was three passes over the same values: one to scale them
				into `absolute` and `deltas`, then one `columnCosts` over each to
				price the varint and packed forms. `columnCosts` needs only a sum
				of varint widths and the largest zigzag, and both accumulate as
				easily here as in a loop of their own.

				The delta array is not built at all where the delta forms are
				withheld -- there is nothing to price it against, so scaling the
				baseline and subtracting would be work for a form that cannot be
				chosen.
			]]
			local absVarintBytes = 0
			local absWidest = 0
			local deltaVarintBytes = 0
			local deltaWidest = 0

			for entry = 1, valueCount do
				local scaled = values[entry] * scale
				local rounded = if scaled >= 0
					then math.floor(scaled + 0.5)
					else -math.floor(-scaled + 0.5)

				absolute[entry] = rounded

				local z = zigzag(rounded)
				absVarintBytes += varintWidth(z)
				if z > absWidest then
					absWidest = z
				end

				if deltas then
					local scaledBefore = befores[entry] * scale
					local beforeRounded = if scaledBefore >= 0
						then math.floor(scaledBefore + 0.5)
						else -math.floor(-scaledBefore + 0.5)

					local difference = rounded - beforeRounded
					deltas[entry] = difference

					local dz = zigzag(difference)
					deltaVarintBytes += varintWidth(dz)
					if dz > deltaWidest then
						deltaWidest = dz
					end
				end
			end

			local absVarint, absPacked, absBits =
				packedCostFor(absVarintBytes, absWidest, valueCount)

			local deltaVarint, deltaPacked, deltaBits
			if deltas then
				deltaVarint, deltaPacked, deltaBits =
					packedCostFor(deltaVarintBytes, deltaWidest, valueCount)
			end

			--[[
				This search was once recorded into a schema and replayed, on the
				theory that choosing the form was worth skipping. Measured across
				three shapes it was 0.94x, 1.14x and 0.98x -- nothing, within
				noise, and sometimes worse for the lookup it added.

				The reason is the order of the work above. `columnDatatype`, the
				extraction, `columnDecimalFactor` and the scaling all run before
				a form can be chosen, and all are per value; this is two passes
				over arrays already built. A recorded form cannot skip the work
				that produced its own inputs, so roughly 2% of the column is all
				there was to win.

				Kept as a search because that is what it should be.
			]]
			local form = COLUMN_VARINT_ABSOLUTE
			local best = absVarint
			local chosen: { number } = absolute
			local chosenBits: number? = nil

			--[[
				`deltas` is nil where the delta forms were withheld, and the costs
				beside it are nil with it, so neither branch that would select it
				can be reached in that case. Bound here so the selection reads as
				a value rather than a maybe.
			]]
			local deltaValues = deltas

			if deltaValues and deltaVarint and deltaVarint < best then
				form = COLUMN_VARINT_DELTA
				best = deltaVarint
				chosen = deltaValues
			end
			if absPacked and absBits and absPacked < best then
				form = COLUMN_PACKED_ABSOLUTE
				best = absPacked
				chosen = absolute
				chosenBits = absBits
			end
			if deltaValues and deltaPacked and deltaBits and deltaPacked < best then
				form = COLUMN_PACKED_DELTA
				best = deltaPacked
				chosen = deltaValues
				chosenBits = deltaBits
			end

			Writer.u8(writer, form)

			--[[
				What each component chose, for Inspect and for working out where
				a patch's bytes went. Kept as a list rather than a count: which
				column picked what is the useful part.
			]]
			local chosenStats = ctx.stats.deltaColumns
			if chosenStats == nil then
				chosenStats = {}
				ctx.stats.deltaColumns = chosenStats
			end
			table.insert(chosenStats, {
				key = keys[position],
				axis = axis,
				kind = plan.kind,
				factor = factors[axis],
				form = form,
				bits = chosenBits,
				count = #chosen,
				bytes = best,
			})

			if chosenBits then
				Writer.u8(writer, chosenBits)
				writePackedIntegers(writer, chosen, chosenBits)
			else
				for _, value in chosen do
					Writer.varint(writer, zigzag(value))
				end
			end
		end
	end
end

local function diffTable(
	ctx: Context,
	baseline: { [any]: any },
	current: { [any]: any },
	seen: { [any]: boolean },
	memo: { [any]: { [any]: boolean } },
	pending: { [any]: { [any]: boolean } },
	depth: number
): ()
	local writer = ctx.writer

	--[[
		Counted for the same reason tablesDiffer counts: a deep value must raise
		rather than exhaust the stack, and must raise at the depth Serialize
		would have raised at.
	]]
	if depth > ctx.maxDepth then
		error(`Zzzz: table nesting exceeded {ctx.maxDepth} levels`, 0)
	end

	if seen[current] then
		Writer.u8(writer, OP_END)
		return
	end
	seen[current] = true

	--[[
		Uniform rows take the record form, which is cheaper per changed field
		than the general ops below. Everything else falls through unchanged.
	]]
	local rowKeys = recordRowKeys(baseline, current)
	if rowKeys then
		Writer.u8(writer, OP_ROWS)
		writeRecordRows(ctx, baseline, current, rowKeys)
		seen[current] = nil
		return
	end

	for key, value in pairs(current) do
		local before = baseline[key]

		if type(before) == "table" and type(value) == "table" then
			if not tablesDiffer(ctx, before, value, memo, pending, depth + 1) then
				continue
			end
			Writer.u8(writer, OP_DESCEND)
			writeValue(ctx, key, false)
			diffTable(ctx, before, value, seen, memo, pending, depth + 1)
			continue
		end

		if not fieldChanged(before, value) then
			continue
		end

		Writer.u8(writer, OP_SET)
		writeValue(ctx, key, false)
		writeValue(ctx, value, false)
	end

	for key in pairs(baseline) do
		if current[key] == nil then
			Writer.u8(writer, OP_REMOVE)
			writeValue(ctx, key, false)
		end
	end

	Writer.u8(writer, OP_END)
	seen[current] = nil
end

--[[
	Encode a patch from `baseline` to `current`.

	Only tables have an interior to diff. Anything else is written whole, and
	the caller's guard will find the full form no larger and use that instead.
]]
function Encoder.encodeDelta(
	baseline: any,
	current: any,
	options: Options?
): (buffer, { Instance })
	local ctx = Encoder.newContext(options)
	writeHeader(ctx, FLAG_DELTA)

	if type(baseline) == "table" and type(current) == "table" then
		Writer.u8(ctx.writer, OP_DESCEND)
		diffTable(ctx, baseline, current, {}, {}, {}, 1)
	else
		Writer.u8(ctx.writer, OP_SET)
		writeValue(ctx, current, false)
	end

	return trimUnusedPrecision(ctx), ctx.instances
end

--[[
	Encode a patch using a context the caller has already configured.

	The counterpart of `encodeWith` for the patch path. `Schema:DiffOnly` uses it
	to write a patch under the schema's own plans and options, so a compiled
	round trip never depends on how some separate instance was configured.
]]
function Encoder.encodeDeltaWith(ctx: Context, baseline: any, current: any): buffer
	writeHeader(ctx, FLAG_DELTA)

	if type(baseline) == "table" and type(current) == "table" then
		Writer.u8(ctx.writer, OP_DESCEND)
		diffTable(ctx, baseline, current, {}, {}, {}, 1)
	else
		Writer.u8(ctx.writer, OP_SET)
		writeValue(ctx, current, false)
	end

	return trimUnusedPrecision(ctx)
end

--[[
	Same as encodeDelta, but hands back the context so a caller can read
	`stats.deltaColumns` -- what each column chose, and what it cost.
]]
function Encoder.encodeDeltaWithContext(
	baseline: any,
	current: any,
	options: Options?
): (buffer, { Instance }, Context)
	local ctx = Encoder.newContext(options)
	writeHeader(ctx, FLAG_DELTA)

	if type(baseline) == "table" and type(current) == "table" then
		Writer.u8(ctx.writer, OP_DESCEND)
		diffTable(ctx, baseline, current, {}, {}, {}, 1)
	else
		Writer.u8(ctx.writer, OP_SET)
		writeValue(ctx, current, false)
	end

	return trimUnusedPrecision(ctx), ctx.instances, ctx
end

return Encoder
