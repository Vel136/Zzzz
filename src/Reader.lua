--!strict
--!native
--!optimize 2

--[[
	Bounds-checked buffer reader.

	Mirrors Writer. Every read validates that the requested bytes exist before
	touching the buffer, so a truncated or hostile packet raises a Zzzz error
	rather than a raw buffer access fault or a silent garbage value.
]]

local Writer = require(script.Parent.Writer)

local Reader = {}
Reader.__index = Reader

local band = bit32.band

local INLINE_MAX = Writer.INLINE_MAX
local TWO_TAG = Writer.TWO_TAG
local TWO_MASK = Writer.TWO_MASK
local THREE_TAG = Writer.THREE_TAG
local THREE_MASK = Writer.THREE_MASK
local FIVE_TAG = Writer.FIVE_TAG
local WIDE_TAG = Writer.WIDE_TAG
local TWO_BIAS = Writer.TWO_BIAS
local THREE_BIAS = Writer.THREE_BIAS

local TWO_END = 0xDF
local THREE_END = 0xEF

export type Reader = typeof(setmetatable(
	{} :: {
		buff: buffer,
		cursor: number,
		length: number,
	},
	Reader
))

function Reader.new(buff: buffer, offset: number?): Reader
	return setmetatable({
		buff = buff,
		cursor = offset or 0,
		length = buffer.len(buff),
	}, Reader)
end

function Reader.fromString(value: string, offset: number?): Reader
	return Reader.new(buffer.fromstring(value), offset)
end

--[[
	Raise if fewer than `bytes` remain. Called before every read.
]]
local function check(self: Reader, bytes: number): ()
	if self.cursor + bytes > self.length then
		error(
			`Zzzz: truncated packet -- wanted {bytes} byte(s) at offset {self.cursor}, only {self.length - self.cursor} remain`,
			0
		)
	end
end

Reader.check = check

function Reader.remaining(self: Reader): number
	return self.length - self.cursor
end

--[[
	Read a count that is about to size an allocation.

	A count is a promise about bytes that follow, so it can be checked against
	the bytes that actually remain before anything is allocated. Without this,
	a sixteen-byte packet claiming fifty million entries costs 313ms of
	allocation before the truncation is noticed -- cheap for an attacker,
	expensive for a server thread.

	`bytesPerEntry` is the smallest number of bytes one entry can occupy: 1 for
	a tagged value, 4 for an f32, and so on. A count is rejected outright when
	the remaining bytes could not encode that many entries even at their
	smallest.

	`allowance` covers forms that pack several entries into one byte, such as
	the bit-packed boolean array where eight entries share a byte.
]]
function Reader.count(self: Reader, bytesPerEntry: number, allowance: number?): number
	local value = Reader.varint(self)
	if value == 0 then
		return 0
	end

	local remaining = self.length - self.cursor
	local minimumBytes = value * bytesPerEntry / (allowance or 1)

	if minimumBytes > remaining then
		error(
			`Zzzz: packet claims {value} entries but only {remaining} byte(s) remain`,
			0
		)
	end

	return value
end

function Reader.atEnd(self: Reader): boolean
	return self.cursor >= self.length
end

-- Fixed-width ---------------------------------------------------------------

function Reader.u8(self: Reader): number
	check(self, 1)
	local cursor = self.cursor
	self.cursor = cursor + 1
	return buffer.readu8(self.buff, cursor)
end

function Reader.u16(self: Reader): number
	check(self, 2)
	local cursor = self.cursor
	self.cursor = cursor + 2
	return buffer.readu16(self.buff, cursor)
end

function Reader.u32(self: Reader): number
	check(self, 4)
	local cursor = self.cursor
	self.cursor = cursor + 4
	return buffer.readu32(self.buff, cursor)
end

function Reader.i8(self: Reader): number
	check(self, 1)
	local cursor = self.cursor
	self.cursor = cursor + 1
	return buffer.readi8(self.buff, cursor)
end

function Reader.i16(self: Reader): number
	check(self, 2)
	local cursor = self.cursor
	self.cursor = cursor + 2
	return buffer.readi16(self.buff, cursor)
end

function Reader.i32(self: Reader): number
	check(self, 4)
	local cursor = self.cursor
	self.cursor = cursor + 4
	return buffer.readi32(self.buff, cursor)
end

function Reader.f32(self: Reader): number
	check(self, 4)
	local cursor = self.cursor
	self.cursor = cursor + 4
	return buffer.readf32(self.buff, cursor)
end

function Reader.f64(self: Reader): number
	check(self, 8)
	local cursor = self.cursor
	self.cursor = cursor + 8
	return buffer.readf64(self.buff, cursor)
end

-- Varint --------------------------------------------------------------------

function Reader.varint(self: Reader): number
	check(self, 1)
	local cursor = self.cursor
	local b = self.buff
	local b0 = buffer.readu8(b, cursor)

	if b0 <= INLINE_MAX then
		self.cursor = cursor + 1
		return b0
	end

	if b0 <= TWO_END then
		check(self, 2)
		self.cursor = cursor + 2
		return band(b0, TWO_MASK) * 256 + buffer.readu8(b, cursor + 1) + TWO_BIAS
	end

	if b0 <= THREE_END then
		check(self, 3)
		self.cursor = cursor + 3
		return band(b0, THREE_MASK) * 65536 + buffer.readu16(b, cursor + 1) + THREE_BIAS
	end

	if b0 == FIVE_TAG then
		check(self, 5)
		self.cursor = cursor + 5
		return buffer.readu32(b, cursor + 1)
	end

	if b0 == WIDE_TAG then
		check(self, 9)
		local value = buffer.readf64(b, cursor + 1)
		--[[
			The wide form carries a double, so a corrupted packet can put a
			negative, fractional or NaN value where a count belongs. Callers
			use these to size allocations and index buffers, both of which
			require a non-negative integer.
		]]
		if value ~= value or value < 0 or value % 1 ~= 0 then
			error(`Zzzz: malformed varint value at offset {cursor}`, 0)
		end
		self.cursor = cursor + 9
		return value
	end

	error(`Zzzz: malformed varint prefix {b0} at offset {cursor}`, 0)
end

-- Bytes ---------------------------------------------------------------------

function Reader.string(self: Reader): string
	local length = Reader.varint(self)
	if length == 0 then
		return ""
	end

	check(self, length)
	local cursor = self.cursor
	self.cursor = cursor + length
	return buffer.readstring(self.buff, cursor, length)
end

function Reader.buffer(self: Reader): buffer
	-- Checked before allocating: the bytes have to be present already.
	local length = Reader.count(self, 1)
	local out = buffer.create(length)
	if length == 0 then
		return out
	end

	check(self, length)
	local cursor = self.cursor
	self.cursor = cursor + length
	buffer.copy(out, 0, self.buff, cursor, length)
	return out
end

return Reader
