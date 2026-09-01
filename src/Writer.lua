--!strict
--!native
--!optimize 2

--[[
	Growable buffer writer.

	Holds a buffer, a cursor, and the allocated size. Every write reserves
	space first via `ensure`, which replaces `self.buff` on growth -- so never
	cache `self.buff` across a write.
]]

local Writer = {}
Writer.__index = Writer

local INITIAL_SIZE = 256

local countlz = bit32.countlz
local lshift = bit32.lshift
local band = bit32.band
local rshift = bit32.rshift

export type Writer = typeof(setmetatable(
	{} :: {
		buff: buffer,
		cursor: number,
		size: number,
	},
	Writer
))

function Writer.new(initialSize: number?): Writer
	local size = initialSize or INITIAL_SIZE
	return setmetatable({
		buff = buffer.create(size),
		cursor = 0,
		size = size,
	}, Writer)
end

--[[
	Grow so that `bytes` more fit past the cursor. New size is the next power
	of two at or above what is needed.
]]
function Writer.ensure(self: Writer, bytes: number): ()
	local needed = self.cursor + bytes
	if needed <= self.size then
		return
	end

	local newSize = lshift(1, 32 - countlz(needed - 1))
	local newBuff = buffer.create(newSize)
	buffer.copy(newBuff, 0, self.buff, 0, self.cursor)
	self.buff = newBuff
	self.size = newSize
end

-- Fixed-width ---------------------------------------------------------------

function Writer.u8(self: Writer, value: number): ()
	local cursor = self.cursor
	if cursor + 1 > self.size then
		Writer.ensure(self, 1)
	end
	buffer.writeu8(self.buff, cursor, value)
	self.cursor = cursor + 1
end

function Writer.u16(self: Writer, value: number): ()
	local cursor = self.cursor
	if cursor + 2 > self.size then
		Writer.ensure(self, 2)
	end
	buffer.writeu16(self.buff, cursor, value)
	self.cursor = cursor + 2
end

function Writer.u32(self: Writer, value: number): ()
	local cursor = self.cursor
	if cursor + 4 > self.size then
		Writer.ensure(self, 4)
	end
	buffer.writeu32(self.buff, cursor, value)
	self.cursor = cursor + 4
end

function Writer.i8(self: Writer, value: number): ()
	local cursor = self.cursor
	if cursor + 1 > self.size then
		Writer.ensure(self, 1)
	end
	buffer.writei8(self.buff, cursor, value)
	self.cursor = cursor + 1
end

function Writer.i16(self: Writer, value: number): ()
	local cursor = self.cursor
	if cursor + 2 > self.size then
		Writer.ensure(self, 2)
	end
	buffer.writei16(self.buff, cursor, value)
	self.cursor = cursor + 2
end

function Writer.i32(self: Writer, value: number): ()
	local cursor = self.cursor
	if cursor + 4 > self.size then
		Writer.ensure(self, 4)
	end
	buffer.writei32(self.buff, cursor, value)
	self.cursor = cursor + 4
end

function Writer.f32(self: Writer, value: number): ()
	local cursor = self.cursor
	if cursor + 4 > self.size then
		Writer.ensure(self, 4)
	end
	buffer.writef32(self.buff, cursor, value)
	self.cursor = cursor + 4
end

function Writer.f64(self: Writer, value: number): ()
	local cursor = self.cursor
	if cursor + 8 > self.size then
		Writer.ensure(self, 8)
	end
	buffer.writef64(self.buff, cursor, value)
	self.cursor = cursor + 8
end

-- Varint --------------------------------------------------------------------

--[[
	Dense prefix varint over [0, 2^53). The first byte's value selects the
	width, which keeps single-byte range wide (0-191 rather than 0-127) and
	makes decoding one branch rather than a loop.

	  0x00..0xBF  1 byte   value = b0                              [0, 191]
	  0xC0..0xDF  2 bytes  value = (b0 & 0x1F) << 8 | b1 + 192     [192, 8383]
	  0xE0..0xEF  3 bytes  value = (b0 & 0x0F) << 16 | u16 + 8384  [8384, 1056959]
	  0xF0        5 bytes  value = u32
	  0xF1        9 bytes  value = f64 (integer-valued, up to 2^53)
]]
local INLINE_MAX = 0xBF
local TWO_TAG = 0xC0
local TWO_MASK = 0x1F
local THREE_TAG = 0xE0
local THREE_MASK = 0x0F
local FIVE_TAG = 0xF0
local WIDE_TAG = 0xF1

local TWO_BIAS = 192
local THREE_BIAS = 8384
local TWO_MAX = 8383
local THREE_MAX = 1056959
local U32_MAX = 0xFFFFFFFF

Writer.INLINE_MAX = INLINE_MAX
Writer.TWO_TAG = TWO_TAG
Writer.TWO_MASK = TWO_MASK
Writer.THREE_TAG = THREE_TAG
Writer.THREE_MASK = THREE_MASK
Writer.FIVE_TAG = FIVE_TAG
Writer.WIDE_TAG = WIDE_TAG
Writer.TWO_BIAS = TWO_BIAS
Writer.THREE_BIAS = THREE_BIAS

function Writer.varint(self: Writer, value: number): ()
	if value <= INLINE_MAX then
		local cursor = self.cursor
		if cursor + 1 > self.size then
			Writer.ensure(self, 1)
		end
		buffer.writeu8(self.buff, cursor, value)
		self.cursor = cursor + 1
		return
	end

	if value <= TWO_MAX then
		local cursor = self.cursor
		if cursor + 2 > self.size then
			Writer.ensure(self, 2)
		end
		local adjusted = value - TWO_BIAS
		local b = self.buff
		buffer.writeu8(b, cursor, TWO_TAG + rshift(adjusted, 8))
		buffer.writeu8(b, cursor + 1, band(adjusted, 0xFF))
		self.cursor = cursor + 2
		return
	end

	if value <= THREE_MAX then
		local cursor = self.cursor
		if cursor + 3 > self.size then
			Writer.ensure(self, 3)
		end
		local adjusted = value - THREE_BIAS
		local b = self.buff
		buffer.writeu8(b, cursor, THREE_TAG + rshift(adjusted, 16))
		buffer.writeu16(b, cursor + 1, band(adjusted, 0xFFFF))
		self.cursor = cursor + 3
		return
	end

	if value <= U32_MAX then
		local cursor = self.cursor
		if cursor + 5 > self.size then
			Writer.ensure(self, 5)
		end
		local b = self.buff
		buffer.writeu8(b, cursor, FIVE_TAG)
		buffer.writeu32(b, cursor + 1, value)
		self.cursor = cursor + 5
		return
	end

	-- Beyond u32: store as f64. Exact for integers up to 2^53.
	local cursor = self.cursor
	if cursor + 9 > self.size then
		Writer.ensure(self, 9)
	end
	local b = self.buff
	buffer.writeu8(b, cursor, WIDE_TAG)
	buffer.writef64(b, cursor + 1, value)
	self.cursor = cursor + 9
end

-- Bytes ---------------------------------------------------------------------

function Writer.string(self: Writer, value: string): ()
	local length = #value
	Writer.varint(self, length)
	if length == 0 then
		return
	end

	local cursor = self.cursor
	if cursor + length > self.size then
		Writer.ensure(self, length)
	end
	buffer.writestring(self.buff, cursor, value)
	self.cursor = cursor + length
end

function Writer.buffer(self: Writer, value: buffer): ()
	local length = buffer.len(value)
	Writer.varint(self, length)
	if length == 0 then
		return
	end

	local cursor = self.cursor
	if cursor + length > self.size then
		Writer.ensure(self, length)
	end
	buffer.copy(self.buff, cursor, value, 0, length)
	self.cursor = cursor + length
end

-- Output --------------------------------------------------------------------

--[[
	Trimmed copy of everything written so far. The writer stays usable.
]]
function Writer.toBuffer(self: Writer): buffer
	local out = buffer.create(self.cursor)
	buffer.copy(out, 0, self.buff, 0, self.cursor)
	return out
end

function Writer.toString(self: Writer): string
	return buffer.readstring(self.buff, 0, self.cursor)
end

function Writer.reset(self: Writer): ()
	self.cursor = 0
end

return Writer
