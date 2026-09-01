--!strict
--!native
--!optimize 2

--[[
	Zzzz tag space.

	Every encoded value begins with one tag byte. The high bit (0x80) is a
	dictionary-key marker: when set, the value that follows is a table key and
	the value after that is its paired value. That leaves 0x00-0x7F (128 slots)
	for actual tags, which is why nothing below may exceed 0x7F.

	Layout:
	  0x00-0x0F  singletons (no payload)
	  0x10-0x2F  small integers 0-31 folded into the tag itself
	  0x30-0x39  numbers
	  0x3A-0x3F  folded struct hits, shape ids 1-6
	  0x40-0x4C  strings and buffers
	  0x50-0x57  tables and references
	  0x58-0x5F  folded string references, distances 0-7
	  0x60-0x7F  Roblox datatypes

	Free: 0x0E-0x0F, 0x7F.
]]

local Tags = {}

-- Dictionary-key marker ---------------------------------------------------

Tags.KEY_BIT = 0x80
Tags.TAG_MASK = 0x7F

-- Singletons: the whole value is the tag, no payload follows ---------------

Tags.NIL = 0x00
Tags.FALSE = 0x01
Tags.TRUE = 0x02
Tags.EMPTY_STRING = 0x03
Tags.EMPTY_TABLE = 0x04
Tags.NAN = 0x05
Tags.INF = 0x06
Tags.NEG_INF = 0x07
Tags.NEG_ZERO = 0x08

-- Small integers -----------------------------------------------------------
-- 0..31 encode as SMALL_INT_BASE + n, so they cost exactly one byte total.

Tags.SMALL_INT_BASE = 0x10
Tags.SMALL_INT_MAX = 31

-- Numbers ------------------------------------------------------------------

Tags.U8 = 0x30
Tags.U16 = 0x31
Tags.U32 = 0x32
Tags.I8 = 0x33
Tags.I16 = 0x34
Tags.I32 = 0x35
Tags.F32 = 0x36
Tags.F64 = 0x37
Tags.VARINT = 0x38 -- unsigned, exceeds u32
Tags.NEG_VARINT = 0x39 -- magnitude varint, value is negative

-- Strings and buffers ------------------------------------------------------

Tags.STRING = 0x40 -- varint length + bytes
Tags.STRING_REF = 0x41 -- varint index into the string dictionary
Tags.BUFFER = 0x42
Tags.BOOL_ARRAY = 0x43 -- varint count, then ceil(count / 8) packed bytes

-- Quantized forms. Lossy, opt-in via the Precision option, and only emitted
-- when the result is actually smaller than the exact encoding.
Tags.QUANT_NUMBER = 0x44
Tags.QUANT_VECTOR2 = 0x45
Tags.QUANT_VECTOR3 = 0x46
Tags.QUANT_CFRAME = 0x47 -- quantized position + rotation id or quaternion

-- Tables and references ----------------------------------------------------

Tags.ARRAY = 0x50 -- varint count, then values
Tags.MAP = 0x51 -- varint pair count, then key/value pairs
Tags.MIXED = 0x52 -- varint array count, varint pair count, then both
Tags.TABLE_REF = 0x53 -- varint index; covers shared refs and cycles
Tags.INSTANCE = 0x54 -- varint index into the instance array
Tags.INSTANCE_TREE = 0x55 -- full hierarchy: class, properties, children
Tags.STRUCT = 0x56 -- varint shape id, then values in the shape's key order
Tags.STRUCT_DEF = 0x57 -- varint shape id, key count, keys; then values

--[[
	A map of same-shaped structs, written as columns.

	`{ user1 = {...}, user2 = {...} }` is a columnar table wearing a map's
	clothes -- same fields on every value, and the keys are a column like any
	other. The structure cache writes each struct's fields one at a time, each
	tagged; this writes them as columns with the keys as one more.

	Measured on four thousand such structs: 80,561 bytes to 40,109, as 3,999
	tagged field-writes became five packed columns.

	The payload is an ordinary columnar array whose rows carry the key under a
	reserved name, so the decoder reads it with the machinery it already has and
	lifts the keys back out.

	Numbered 0x0D rather than something beside the other table tags, because the
	table range is full: 0x50-0x57 is taken and 0x58-0x5F is the eight folded
	string distances. This was first given 0x59, which the decoder read as
	"folded string reference 1" -- the layout comment at the top of this file
	says which slots are free, and it is worth reading before adding a tag.
]]
Tags.STRUCT_COLUMNS = 0x0D

-- Roblox datatypes ---------------------------------------------------------

Tags.VECTOR2 = 0x60
Tags.VECTOR3 = 0x61
Tags.VECTOR2INT16 = 0x62
Tags.VECTOR3INT16 = 0x63
Tags.CFRAME = 0x64 -- rotation id or quaternion + position
Tags.CFRAME_POS = 0x65 -- identity rotation, position only
Tags.UDIM = 0x66
Tags.UDIM2 = 0x67
Tags.RECT = 0x68
Tags.COLOR3 = 0x69 -- 12 bytes, full float precision
Tags.COLOR3_U8 = 0x6A -- 3 bytes, when all channels round-trip through 0-255
Tags.BRICKCOLOR = 0x6B
Tags.COLORSEQUENCE = 0x6C
Tags.COLORSEQUENCEKEYPOINT = 0x6D
Tags.NUMBERSEQUENCE = 0x6E
Tags.NUMBERSEQUENCEKEYPOINT = 0x6F
Tags.NUMBERRANGE = 0x70
--[[
	Enum types are interned per packet.

	Writing the type name every time cost 10-11 bytes for the first
	Enum.KeyCode.A and 4 for each repeat, which is embarrassing next to the two
	bytes a schema-based encoder spends. A packet only ever touches a handful
	of enum types, so the type gets an id in order of first use: the name is
	written once and every later item of that type costs a single byte for it.

	The value is stored as the item's index within its own type rather than its
	raw Value, because Roblox values are sparse -- Material.Neon is value 288
	but item 3.
]]
Tags.ENUMITEM = 0x71 -- varint type id, varint item index
Tags.ENUMITEM_DEF = 0x0B -- varint type id, type name, varint item index
Tags.ENUM = 0x72 -- varint type id
Tags.ENUM_DEF = 0x0C -- varint type id, type name
Tags.AXES = 0x73
Tags.FACES = 0x74
Tags.FONT = 0x75
Tags.DATETIME = 0x76
Tags.PHYSICALPROPERTIES = 0x77
Tags.RAY = 0x78
Tags.REGION3 = 0x79
Tags.REGION3INT16 = 0x7A
Tags.TWEENINFO = 0x7B

--[[
	Integral forms.

	Placed geometry sits on whole studs far more often than not, and UI offsets
	are always integers. Storing those as zigzag varints rather than fixed
	floats is lossless and much smaller -- Vector3.new(4, 2, 1) costs 4 bytes
	rather than 13.

	Chosen per value: the encoder only emits these when every component is
	integral and the result is actually smaller.
]]
Tags.VECTOR3_INT = 0x7C -- 3 zigzag varints
Tags.VECTOR2_INT = 0x7D -- 2 zigzag varints
Tags.CFRAME_INT = 0x7E -- 3 zigzag varints + rotation id or quaternion

--[[
	Compact UDim family.

	A UDim2 was 16 bytes of payload, of which 12 were typically zero: scales
	are nearly always 0, 0.5 or 1, and offsets are small integers, yet both
	took four bytes flat. These forms carry a flag byte naming which scales are
	the common constants, then zigzag varint offsets.

	Placed in the 0x48 block rather than after TWEENINFO: 0x7F is TAG_MASK, and
	a tag equal to the mask cannot be distinguished from a masked key tag.
]]
Tags.UDIM_COMPACT = 0x48
Tags.UDIM2_COMPACT = 0x49

--[[
	Columnar arrays.

	An array whose entries are all tables with the same string keys is written
	as one column per key rather than one block per row. Values of a single
	type end up adjacent, which lets a boolean column bit-pack and gives a
	later compression pass far more structure to work with.

	COLUMNS_DEF carries the key names; COLUMNS refers back to a shape already
	defined. A column may be preceded by a dictionary when its values are
	strings drawn from a small set.
]]
Tags.COLUMNS_DEF = 0x4A -- varint shape id, key count, keys, row count, columns
Tags.COLUMNS = 0x4B -- varint shape id, row count, columns
Tags.COLUMN_DICT = 0x4C -- varint entry count, entries, then varint indices

--[[
	Folded tags.

	A tag byte and a one-byte payload is two bytes for a value carrying almost
	no information. These ranges fold the payload into the tag, the way
	MessagePack folds fixstr and fixmap, so the common case costs one byte.

	Which payloads are worth folding is not obvious, and the two MessagePack
	folds are the wrong answer here. Measured on a 200-player save:

		STRUCT hits     3502 values     <- worth folding
		STRING_REF      3294 values     <- worth folding
		small arrays     400 values
		short strings    227 values
		small maps         0 values     <- the structure cache already ate these

	fixmap earns nothing because a record-shaped map becomes a STRUCT before it
	is ever written, and fixstr earns little because strings intern: the second
	occurrence onward is a reference, not a string.

	Only 23 tag slots were free and just one run of eight, so the string fold
	takes that run and the struct fold takes six. Six is not a compromise in
	practice: a payload with six or fewer shapes -- which is what real save data
	looks like -- folds every hit either way, and the two sizes differ only past
	that.
]]

--[[
	Recently used strings, by distance rather than by id.

	STRING_REF carries an id, and an id is a poor thing to fold on: it depends on
	how much of the packet came first. Measured, string reference ids clustered
	around 13-22, so folding "id <= 8" would have caught none of them.

	Distance from the most recently used string does not have that problem. It is
	small because reuse is local, whatever the packet size, and folding the
	nearest eight caught 2069 bytes where folding the lowest eight ids caught 2.

	FOLD_STRING_MTF + n means "the string n places back", n in 0..7, and the list
	moves that string to the front afterwards. Anything further away stays a
	STRING_REF: a string interned early and untouched since has a small id and a
	large distance, so keeping the id form as the fallback is what makes this
	never larger than not folding at all.
]]
Tags.FOLD_STRING_MTF = 0x58
Tags.FOLD_STRING_MTF_COUNT = 8

--[[
	Struct hits for the first eight shapes.

	FOLD_STRUCT + n means STRUCT with shape id n + 1, so ids 1-6 cost one byte
	rather than two. Shapes are numbered in order of first use and real payloads
	define very few, so this covers almost every hit; anything past it stays a
	STRUCT with a varint id.
]]
Tags.FOLD_STRUCT = 0x3A
Tags.FOLD_STRUCT_COUNT = 6

--[[
	A bit-packed boolean array whose length repeats the previous one's.

	BOOL_ARRAY costs a tag plus a varint count before its bits. Save data holds
	the same fixed-width flag block per player -- forty achievements, a row of
	quest states -- so that count is written thousands of times and is the same
	every time. Two thousand forty-flag blocks spent 4,000 bytes saying "forty".

	This tag means "as long as the last boolean array", so the count disappears
	and only the tag remains. The first array of a given length still writes it.
]]
Tags.BOOL_ARRAY_SAME = 0x4D

--[[
	A new string sharing a prefix with the one written before it.

	Interning removes repeats but does nothing for strings that are merely
	similar, and save data is full of those: "Player1".."Player2000",
	"rbxassetid://..." with the id varying, quest and badge names built from a
	common stem. Each pays for its shared head every time.

	This form writes how many leading bytes it shares with the previous new
	string, then only the bytes that differ. Two thousand names beginning
	"Player" spent 12,000 bytes saying so.

	Measured over string columns, keeping the caller's order:

		Player1..2000        -80%
		rbxassetid://...     -77%
		small vocabulary     -17%
		real usernames        -4%

	The last row is why this is chosen per string against the plain form rather
	than applied always.
]]
Tags.STRING_PREFIXED = 0x4E

--[[
	A string sharing both ends with the one before it.

	Front coding alone shares the head, which leaves a common *tail* paid in
	full every time. That tail is not a rare shape: a key path, a file name, a
	url and an id all tend to end alike, and the varying part sits in the
	middle.

		"com.example.service.item.1.enabled"
		"com.example.service.item.2.enabled"

	Front coding shares the first twenty-five bytes and then stores ".enabled"
	again for every row -- 6,092 bytes over five hundred of them, against a
	shared-tail form's cost of one more length byte a string.

	Two lengths and the middle, so the head and tail are each stored once for
	the run. Chosen per string like the prefixed form, and against it, since a
	string with no common tail should not pay the extra byte.
]]
Tags.STRING_AFFIXED = 0x09

--[[
	A flat array of Roblox datatypes, written through the column forms.

	Every scheme that knows what a Rect or a Color3 is lives in the column
	writer, and that writer only ever sees a key of an array of records. A bare
	`{ Rect, Rect, ... }` has no key, so it reached none of them: five hundred
	sorted Rects cost 8,505 bytes here against 117 under a one-field struct.

	The payload is that struct -- each value wrapped as a single-field row --
	so this tag is only a marker saying to unwrap what follows. Chosen against
	the plain array by measurement, since a column of unrelated values gains
	nothing and would only pay for the shape.
]]
Tags.DATATYPE_ARRAY = 0x0A

--[[
	A flat array of numbers, encoded as a column rather than value by value.

	Every column form in this library works on an array of *records*: it reads
	one key across many rows. A plain `{1.5, 2.5, 3.5}` has no keys, so it never
	reached any of them and each value paid a tag and its payload. That is the
	most natural way to write a vector, a polygon, a sample buffer or a set of
	weights, and it was the one shape where a packet came out larger than JSON:

		12,246 two-decimal floats   114,095 B as values, ~23,000 B as a column
		the same floats wrapped in {v = x} tables        1.91 B each

	The array itself is the column. After the tag comes a form byte saying which
	encoding carried it, then that form's payload.
]]
Tags.NUMBER_ARRAY = 0x4F

--[[
	The remaining Roblox datatypes, behind one tag and a sub-type byte.

	Four types were left unserializable -- a packet holding one raised rather
	than encoding it. They are rare enough that a tag each would be poor use of
	the last free slot in the space, and they carry enough payload that one
	extra byte is immaterial.

	`Random` is deliberately absent. Its seed and internal state cannot be read
	back, so a decoded copy could only be a fresh generator that agrees about
	nothing; a serializer that silently substituted one would be worse than the
	error the caller gets now.

		0  PathWaypoint          position, action, label
		1  RaycastParams         filter type, flags, collision group
		2  OverlapParams         filter type, max parts, flags, collision group
		3  CatalogSearchParams   keyword, prices, sorts and filters

	Instance filters are not carried: FilterDescendantsInstances holds live
	references whose meaning does not survive the trip, and the params arrive
	with an empty filter for the caller to repopulate.
]]
Tags.EXTRA_DATATYPE = 0x7F

Tags.EXTRA_PATHWAYPOINT = 0
Tags.EXTRA_RAYCASTPARAMS = 1
Tags.EXTRA_OVERLAPPARAMS = 2
Tags.EXTRA_CATALOGSEARCHPARAMS = 3
Tags.EXTRA_FLOATCURVEKEY = 4
Tags.EXTRA_VALUECURVEKEY = 5
Tags.EXTRA_ROTATIONCURVEKEY = 6
Tags.EXTRA_PATH2DCONTROLPOINT = 7
Tags.EXTRA_CONTENT = 8

-- Format header ------------------------------------------------------------

Tags.VERSION = 1

return table.freeze(Tags)
