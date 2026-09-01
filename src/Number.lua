--!strict
--!native
--!optimize 2

--[[
	Number tag selection.

	Picks the narrowest encoding that reproduces the value exactly. Order
	matters: the special cases (NaN, infinities, negative zero) must be caught
	before the integer ladder, because -0 compares equal to 0 and NaN compares
	equal to nothing.

	Non-integers are tested by round-tripping through a 4-byte scratch buffer;
	if f32 gives the value back unchanged it is exact for this value and costs
	half of f64.
]]

local Tags = require(script.Parent.Tags)

local Number = {}

local floor = math.floor
local scratch = buffer.create(4)

local SMALL_INT_BASE = Tags.SMALL_INT_BASE
local SMALL_INT_MAX = Tags.SMALL_INT_MAX

local U8_MAX = 0xFF
local U16_MAX = 0xFFFF
local U32_MAX = 0xFFFFFFFF
local I8_MIN = -0x80
local I16_MIN = -0x8000
local I32_MIN = -0x80000000
local SAFE_INT = 2 ^ 53

--[[
	Returns the tag byte for `value`. Small non-negative integers return a
	folded tag (SMALL_INT_BASE + value) that carries the number in the tag
	itself and has no payload.
]]
function Number.selectTag(value: number): number
	-- NaN is not equal to itself; must be tested first.
	if value ~= value then
		return Tags.NAN
	end

	if value == math.huge then
		return Tags.INF
	end

	if value == -math.huge then
		return Tags.NEG_INF
	end

	if value == 0 then
		-- Distinguishes -0 from 0: only -0 gives -inf when inverted.
		if 1 / value == -math.huge then
			return Tags.NEG_ZERO
		end
		return SMALL_INT_BASE
	end

	if floor(value) == value then
		if value > 0 then
			if value <= SMALL_INT_MAX then
				return SMALL_INT_BASE + value
			end
			if value <= U8_MAX then
				return Tags.U8
			end
			if value <= U16_MAX then
				return Tags.U16
			end
			if value <= U32_MAX then
				return Tags.U32
			end
			if value <= SAFE_INT then
				return Tags.VARINT
			end
		else
			if value >= I8_MIN then
				return Tags.I8
			end
			if value >= I16_MIN then
				return Tags.I16
			end
			if value >= I32_MIN then
				return Tags.I32
			end
			if value >= -SAFE_INT then
				return Tags.NEG_VARINT
			end
		end
		-- Integers beyond 2^53 lose precision as integers; fall through to
		-- the float path, which stores them exactly as doubles.
	end

	buffer.writef32(scratch, 0, value)
	if buffer.readf32(scratch, 0) == value then
		return Tags.F32
	end

	return Tags.F64
end

return Number
