--!strict
--!native
--!optimize 2

--[[
	Lossy number encoding, opt-in.

	A quantized number is stored as round(value / precision), zigzagged so
	negatives stay small, then written as a varint. Decoding multiplies back.
	Worst-case error is half the precision, by construction.

	The win depends entirely on magnitude, and it is not always a win:

		precision   +-2048 studs        +-16384 studs
		0.01        ~3 bytes/component  ~4.3 bytes/component
		0.1         ~2.8               ~4
		f32          4 (fixed)          4 (fixed)

	Past roughly +-16000 studs at 0.01 precision the varint grows past f32 and
	quantizing costs more than it saves. Callers must therefore check
	`isWorthwhile` rather than quantizing unconditionally -- silently making
	packets larger while also losing precision would be the worst of both.
]]

local Quantize = {}

local round = math.round
local abs = math.abs

--[[
	Map a signed integer onto the non-negative range so that small negatives
	encode as small varints: 0, -1, 1, -2, 2 becomes 0, 1, 2, 3, 4.
]]
function Quantize.zigzag(value: number): number
	if value < 0 then
		return -value * 2 - 1
	end
	return value * 2
end

function Quantize.unzigzag(value: number): number
	if value % 2 == 1 then
		return -((value + 1) / 2)
	end
	return value / 2
end

--[[
	Byte width a varint of this value would occupy. Mirrors Writer.varint's
	ladder exactly; used to decide whether quantizing is actually smaller.
]]
function Quantize.varintLength(value: number): number
	if value <= 0xBF then
		return 1
	elseif value <= 8383 then
		return 2
	elseif value <= 1056959 then
		return 3
	elseif value <= 0xFFFFFFFF then
		return 5
	end
	return 9
end

--[[
	Cost in bytes of quantizing `value` at `precision`.
]]
function Quantize.cost(value: number, precision: number): number
	return Quantize.varintLength(Quantize.zigzag(round(value / precision)))
end

--[[
	Whether quantizing beats the 4 bytes an f32 would take.

	Strictly fewer bytes, not fewer-or-equal: at equal size the exact form is
	better, because it is also lossless.

	Non-finite values are never quantizable: NaN and the infinities have no
	meaningful integer form. Values beyond 2^53 / precision cannot be rounded
	to an exact integer either, so they are rejected before the cost test.
]]
local SAFE_INT = 2 ^ 53

function Quantize.isWorthwhile(value: number, precision: number): boolean
	if value ~= value or value == math.huge or value == -math.huge then
		return false
	end

	local scaled = value / precision
	if scaled >= SAFE_INT or scaled <= -SAFE_INT then
		return false
	end

	return Quantize.varintLength(Quantize.zigzag(round(scaled))) < 4
end

--[[
	Whether every component of a vector is worth quantizing. All-or-nothing so
	the decoder does not need a per-component flag.
]]
function Quantize.vectorWorthwhile(precision: number, ...: number): boolean
	for index = 1, select("#", ...) do
		local component = select(index, ...)
		if not Quantize.isWorthwhile(component, precision) then
			return false
		end
	end
	return true
end

function Quantize.encode(value: number, precision: number): number
	return Quantize.zigzag(round(value / precision))
end

function Quantize.decode(value: number, precision: number): number
	return Quantize.unzigzag(value) * precision
end

--[[
	Largest error quantizing at this precision can introduce.
]]
function Quantize.maxError(precision: number): number
	return precision / 2
end

--[[
	Validate a precision value. Zero or negative would divide by zero or invert
	the ordering; absurdly small values overflow the varint.
]]
function Quantize.validate(precision: number): ()
	if type(precision) ~= "number" or precision ~= precision then
		error("Zzzz: Precision must be a number", 0)
	end
	if precision <= 0 then
		error(`Zzzz: Precision must be greater than zero, got {precision}`, 0)
	end
	if precision > 1000 then
		error(`Zzzz: Precision of {precision} is too coarse to be useful`, 0)
	end
end

-- Header encoding -----------------------------------------------------------

--[[
	Precision travels in the packet header, so it needs a compact form.

	Codes 0-12 are 10^-n, covering 1, 0.1, 0.01 and so on. Codes 13+ cover the
	other precisions people actually reach for -- halves, quarters, fifths --
	so a precision like 0.25 still costs one header byte rather than eight.
	Eight bytes of header is enough to make a small quantized packet larger
	than the exact one it replaced, which defeats the point.

	Anything outside both sets falls back to a full f64 in the header.
]]
local EXTRA_PRECISIONS = { 0.5, 0.25, 0.2, 0.05, 0.025, 0.02, 0.005, 0.0025, 0.002 }
local EXTRA_BASE = 13

Quantize.EXTRA_PRECISIONS = EXTRA_PRECISIONS

function Quantize.precisionCode(precision: number): number?
	for exponent = 0, 12 do
		if 10 ^ -exponent == precision then
			return exponent
		end
	end

	for index, candidate in EXTRA_PRECISIONS do
		if candidate == precision then
			return EXTRA_BASE + index - 1
		end
	end

	return nil
end

function Quantize.precisionFromCode(code: number): number
	if code < EXTRA_BASE then
		return 10 ^ -code
	end

	local precision = EXTRA_PRECISIONS[code - EXTRA_BASE + 1]
	if not precision then
		error(`Zzzz: unknown precision code {code} in packet header`, 0)
	end
	return precision
end

-- Bit packing ---------------------------------------------------------------

--[[
	Whether a table is a dense array of booleans, and therefore packable at one
	bit each. Returns the count, or nil when it does not qualify.

	Under 8 entries there is nothing to gain: the count prefix plus one packed
	byte matches or beats what the plain path would do anyway.
]]
function Quantize.booleanArrayLength(value: { [any]: any }): number?
	local count = 0
	while rawget(value, count + 1) ~= nil do
		count += 1
	end

	if count < 8 then
		return nil
	end

	-- Any non-boolean entry, or any key outside the array run, disqualifies it.
	local total = 0
	for _, entry in pairs(value) do
		if type(entry) ~= "boolean" then
			return nil
		end
		total += 1
	end

	if total ~= count then
		return nil
	end

	return count
end

return Quantize
