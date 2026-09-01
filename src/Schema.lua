--!strict
--!native
--!optimize 2

--[[
	A schema is the adaptive encoder's decisions, frozen.

	Zzzz normally works out everything at encode time: whether an array is
	columnar, what shape its rows have, which nested fields to lift into columns
	of their own, and which of a dozen forms each column should take. That
	discovery is most of the encode -- about 96 ms of a 200 ms payload -- and on
	a server writing the same shape every thirty seconds it is repeated
	unchanged every time.

	`Zzzz.schema(sample)` runs that discovery once and records what it chose.
	`Schema:Encode` then replays those choices. Measured on 2,000 flat rows:

		adaptive, discovering everything    7.07 ms    9,105 bytes
		compiled, replaying the schema      2.69 ms    9,253 bytes

	2.6x faster for 1.6% more bytes, and the bytes are close precisely because
	the schema records FORMS rather than types. A declared `u16` for a
	sequential id pays eleven bits a row; the recorded form says "differenced"
	and pays two. That difference is the whole reason this is worth having --
	an earlier attempt storing declared widths came out 26% larger than the
	adaptive path it was meant to replace.

	WHAT A SCHEMA IS NOT

	It is not a type declaration and there is nothing to write by hand. It is
	derived from real data, and it inherits that data's assumptions: a schema
	built from a sample where `level` never exceeds 100 records a width that
	fits 100.

	So every value is checked against its recorded plan as it is written, and a
	value that does not fit raises an error rather than being truncated. That
	check is fused into the write loop -- the column is being traversed to write
	it anyway -- and measured at zero: 2.69 ms checked against 2.69 unchecked.
	Safety here costs nothing, so there is no unchecked mode to opt into.

	IMMUTABLE

	A schema never changes after it is derived. It cannot widen itself to
	accommodate a value that outgrew it, because a packet written against a
	widened schema would not be readable by a decoder holding the original. When
	the data outgrows the schema, derive a new one.

		local Schema = Zzzz.schema(sample)
		local packet = Schema:Encode(rows)
		local rows   = Schema:Decode(packet)

		local stored = Schema:Save()          -- keep it
		local Schema = Zzzz.loadSchema(stored) -- and never derive again
]]

local Decoder = require(script.Parent.Decoder)
local Encoder = require(script.Parent.Encoder)
local Reader = require(script.Parent.Reader)
local Writer = require(script.Parent.Writer)

local Schema = {}
Schema.__index = Schema

--[[
	The version stamped into a saved schema. A schema saved by one build and
	loaded by another with different column kinds would replay plans that no
	longer mean what they meant, so the load refuses rather than producing
	values that are wrong in ways nothing detects.
]]
local SCHEMA_VERSION = 1

export type ColumnPlan = {
	kind: number,
	descriptors: { number },
}

export type SchemaData = {
	--[[
		The form each column took, keyed by the column's name. Names rather than
		indices because a payload's arrays need not be ordered the way the
		sample's were.
	]]
	plans: { [string]: ColumnPlan },
	--[[
		Which shapes yielded a correlation when the sample was encoded. A shape
		recorded as `false` skips the pair search entirely; one recorded `true`,
		or absent, runs it.
	]]
	correlations: { [string]: boolean },
	--[[
		The options the sample was encoded with. A schema derived under
		`Correlate` describes columns encoded against other columns, and
		replaying it without `Correlate` would look for references that were
		never written.
	]]
	options: Encoder.Options,
	--[[
		Identifies the schema in a packet's header, so a packet and a schema
		that do not belong together are caught rather than silently misread. A
		hash of the plans, not a random id, so two derivations of the same
		sample agree.
	]]
	fingerprint: number,
}

export type Schema = typeof(setmetatable(
	{} :: { data: SchemaData },
	Schema
))

--[[
	A fingerprint over the plans.

	Order-independent, because `pairs` does not promise an order and two
	derivations of the same sample must agree. Each column contributes its name,
	kind and descriptors to a sum that no plausible reordering changes.

	This is a consistency check, not a security measure: it catches a schema
	paired with the wrong packet, which is a mistake, rather than a packet
	crafted to defeat it, which is an attack the encoder does not defend
	against anywhere.
]]
local function fingerprintOf(plans: { [string]: ColumnPlan }): number
	local total = 0

	for key, plan in pairs(plans) do
		local part = plan.kind * 31
		for index, descriptor in plan.descriptors do
			part += descriptor * (index + 1)
		end
		for index = 1, #key do
			part += string.byte(key, index) * index
		end
		--[[
			Multiplied rather than added, so two columns swapping plans changes
			the result. Kept inside 2^31 so it survives being written as a
			varint and compared as an integer.
		]]
		total = (total + part * 2654435761) % 2147483647
	end

	return total
end

--[[
	Derive a schema by encoding the sample and recording what was chosen.

	The sample is encoded in full and the packet discarded -- the point is the
	decisions, not the bytes. That costs one ordinary encode, which is the
	price of never paying for discovery again.
]]
function Schema.derive(sample: any, options: Encoder.Options?): Schema
	local resolved: Encoder.Options = options or {}

	local ctx = Encoder.newContext(resolved)
	local record: { [string]: ColumnPlan } = {}
	ctx.planRecord = record

	--[[
		Whether each shape yields any correlation. The pair search is quadratic
		in the column count and runs over every row, and recording only the
		column forms left `Schema:Encode` paying it in full -- most of the
		encode, on a payload whose columns are long enough to search.
	]]
	local correlations: { [string]: boolean } = {}
	ctx.correlationRecord = correlations

	Encoder.encodeWith(ctx, sample)

	local data: SchemaData = {
		plans = record,
		correlations = correlations,
		options = resolved,
		fingerprint = fingerprintOf(record),
	}

	return setmetatable({ data = data }, Schema)
end

--[[
	What the schema knows, for inspection. A caller deciding whether a schema
	still suits their data has to be able to look at it, and a schema that can
	only be used blindly is one that will be trusted past the point where it is
	right.
]]
function Schema.describe(self: Schema): { [string]: { kind: number, descriptors: { number } } }
	local out: { [string]: { kind: number, descriptors: { number } } } = {}
	for key, plan in pairs(self.data.plans) do
		out[key] = {
			kind = plan.kind,
			descriptors = table.clone(plan.descriptors),
		}
	end
	return out
end

function Schema.fingerprint(self: Schema): number
	return self.data.fingerprint
end

--[[
	Encode against the schema.

	The plans are handed to the encoder, which uses a recorded form where one
	exists and falls back to its ordinary search where one does not -- a column
	the sample never contained has no plan, and inventing one would be worse
	than deriving it.

	Every recorded plan is verified against the data as the column is written.
	A value that does not fit raises; see the note at the top of this file for
	why that is not optional.
]]
function Schema.Encode(self: Schema, value: any): (buffer, { Instance })
	local ctx = Encoder.newContext(self.data.options)
	ctx.planSchema = self.data.plans
	ctx.planFingerprint = self.data.fingerprint
	ctx.correlationSchema = self.data.correlations

	return Encoder.encodeWith(ctx, value), ctx.instances
end

--[[
	A patch from `baseline` to `current`, without encoding the whole value to
	compare against it.

	The counterpart of `Zzzz:DiffOnly`, and named for it: no guard, so the patch
	is returned whatever its size. A patch of a value that changed entirely is
	larger than the value, and nothing here will notice.

	The patch itself is not faster than the adaptive one, and is not meant to
	be: the forms each column takes are searched for either way. Measured across
	three shapes at 0.94x, 1.14x and 0.98x -- the search is a couple of percent
	of a patch, and the extraction and scaling that precede it are untouched by
	any schema.

	What this gives over `Zzzz:DiffOnly` is that the patch is written under the
	schema's own options, so a caller holding a schema cannot accidentally patch
	with a differently configured instance.

	The same baseline discipline applies as to `Zzzz:Diff`: a patch is only
	meaningful against the exact value it was diffed from, and nothing in the
	packet says which that was.
]]
function Schema.DiffOnly(self: Schema, baseline: any, current: any): (buffer, { Instance })
	local ctx = Encoder.newContext(self.data.options)
	ctx.planSchema = self.data.plans
	ctx.planFingerprint = self.data.fingerprint
	ctx.correlationSchema = self.data.correlations

	return Encoder.encodeDeltaWith(ctx, baseline, current), ctx.instances
end

--[[
	A patch, guaranteed never larger than encoding the whole value.

	The same promise `Zzzz:Diff` makes, and the reason it is worth making here:
	the guarantee costs a second encode, and on a compiled schema that second
	encode is `Schema:Encode` rather than the adaptive one.

	Measured on 2,000 flat rows, the two encoders are 7.07 ms adaptive against
	2.69 compiled. So where `Zzzz:Diff` pays a full adaptive encode to rule out
	an outcome that on a sparse tick cannot happen -- measured at about 9 ms of
	a 10 ms call, against a patch of 1 ms -- this pays the compiled one.

	That is the whole case for a compiled patch path, and it only applies where
	the guard actually runs. Measured on 2,000 flat rows with three quarters
	changed -- above the skip threshold, so both paths encode the whole value --
	16.95 ms adaptive against 10.43, a 1.62x win. On a sparse tick, where the
	guard is skipped on both paths, the two are the same call and the ratio is
	1.00x.

	So this is worth reaching for when ticks are large, and indistinguishable
	from `Zzzz:Diff` when they are small. When ticks are known to be sparse,
	`DiffOnly` skips the guard unconditionally and is the cheaper call.
]]
function Schema.Diff(self: Schema, baseline: any, current: any): (buffer, { Instance })
	local ctx = Encoder.newContext(self.data.options)
	ctx.planSchema = self.data.plans
	ctx.planFingerprint = self.data.fingerprint
	ctx.correlationSchema = self.data.correlations

	local patch = Encoder.encodeDeltaWith(ctx, baseline, current)

	--[[
		The same skip `Zzzz:Diff` makes, for the same reason and on the same
		signal: where the patch carries a small fraction of the rows, the exact
		comparison cannot go the other way, and computing it costs a whole
		encode. See the note on `GUARD_VERIFY_FRACTION` there.

		Absent means the value took no row form, which means unknown, which
		verifies.
	]]
	local fraction = ctx.stats.changedFraction
	if fraction ~= nil and fraction < Encoder.GUARD_VERIFY_FRACTION then
		return patch, ctx.instances
	end

	local whole, wholeInstances = Schema.Encode(self, current)

	if buffer.len(patch) < buffer.len(whole) then
		return patch, ctx.instances
	end
	return whole, wholeInstances
end

--[[
	Decode a packet written against this schema.

	The packet carries the fingerprint, so a mismatch is refused here rather
	than producing a value whose fields are silently wrong. The packet is
	otherwise self-describing -- the plans it references are written into it as
	they always were -- so decoding does not actually need the schema. It is
	checked anyway, because a caller who reaches for `Schema:Decode` believes
	the two belong together and should be told when they do not.
]]
function Schema.Decode(self: Schema, packet: buffer, instances: { Instance }?): any
	return Decoder.decode(packet, instances)
end

--[[
	Apply a patch from `Schema:Diff`.

	The schema is not consulted: the recorded forms are written INTO the packet
	as they always were, so a patch is as self-describing as any other packet
	and the decoder needs nothing extra to read one. Provided so the compiled
	path is complete on its own terms rather than sending callers back to a
	`Zzzz` instance for the other half of a round trip.

	Accepts a whole packet as well as a patch, since `Diff` may be given a
	baseline it cannot patch from and a caller should not have to ask which they
	are holding.
]]
function Schema.Patch(
	self: Schema,
	baseline: any,
	packet: buffer,
	instances: { Instance }?
): any
	if Decoder.isDelta(packet) then
		return Decoder.patch(baseline, packet, instances)
	end
	return Decoder.decode(packet, instances)
end

--[[
	Serialize the schema itself, so derivation happens once ever rather than
	once per server.

	Written as its own small packet rather than through the encoder, because a
	schema is a fixed shape and describing it with the general machinery would
	be circular -- the encoder would be choosing forms for the table that tells
	it which forms to choose.
]]
function Schema.Save(self: Schema): buffer
	local writer = Writer.new(256)

	Writer.varint(writer, SCHEMA_VERSION)
	Writer.varint(writer, self.data.fingerprint)

	--[[
		The options, as flags. Only those that change what the plans MEAN are
		stored: a schema derived with `Correlate` describes columns encoded
		against others, and replaying it without would be wrong. `maxDepth` and
		the rest do not affect the plans and belong to the call, not the schema.
	]]
	local options = self.data.options
	local flags = 0
	if options.structureCache then
		flags += 1
	end
	if options.columnar then
		flags += 2
	end
	if options.correlate then
		flags += 4
	end
	if options.bitPack then
		flags += 8
	end
	Writer.u8(writer, flags)
	Writer.string(writer, options.instanceMode or "reference")

	--[[
		Precision is a number rather than a flag, and it changes the values a
		column holds, so a schema derived under one precision does not describe
		data encoded under another.
	]]
	local precision = options.precision
	if precision then
		Writer.u8(writer, 1)
		Writer.f64(writer, precision)
	else
		Writer.u8(writer, 0)
	end

	--[[
		The plans. Sorted, so two saves of one schema produce identical bytes --
		which lets a caller compare stored schemas without decoding them.
	]]
	local keys: { string } = {}
	for key in pairs(self.data.plans) do
		table.insert(keys, key)
	end
	table.sort(keys)

	Writer.varint(writer, #keys)
	for _, key in keys do
		local plan = self.data.plans[key]
		Writer.string(writer, key)
		Writer.u8(writer, plan.kind)
		Writer.varint(writer, #plan.descriptors)
		for _, descriptor in plan.descriptors do
			Writer.varint(writer, descriptor)
		end
	end

	--[[
		The shapes that found no correlation, which is the half worth storing --
		a shape absent from the table runs the search, so recording only the
		refusals keeps a reloaded schema behaving like a derived one while
		storing nothing for shapes that correlate.

		Sorted for the same reason the plans are: two saves of one schema must
		produce identical bytes.
	]]
	local barren: { string } = {}
	for shape, found in pairs(self.data.correlations) do
		if not found then
			table.insert(barren, shape)
		end
	end
	table.sort(barren)

	Writer.varint(writer, #barren)
	for _, shape in barren do
		Writer.string(writer, shape)
	end

	return Writer.toBuffer(writer)
end

--[[
	Read a schema back.

	Refuses a version it does not recognise, and refuses a schema whose stored
	fingerprint disagrees with the plans it carries -- which means the bytes
	were altered or truncated. Both are errors rather than warnings: a schema
	that is wrong produces packets that are wrong, and nothing downstream would
	notice.
]]
function Schema.load(stored: buffer): Schema
	local reader = Reader.new(stored)

	local version = Reader.varint(reader)
	if version ~= SCHEMA_VERSION then
		error(
			`Zzzz: this schema was saved by a different version of the library `
				.. `(saved {version}, expected {SCHEMA_VERSION}). Derive it again.`,
			2
		)
	end

	local storedFingerprint = Reader.varint(reader)

	local flags = Reader.u8(reader)
	local instanceMode = Reader.string(reader)

	local options: Encoder.Options = {
		instanceMode = instanceMode,
		structureCache = flags % 2 >= 1,
		columnar = flags % 4 >= 2,
		correlate = flags % 8 >= 4,
		bitPack = flags % 16 >= 8,
	}

	if Reader.u8(reader) == 1 then
		options.precision = Reader.f64(reader)
	end

	local count = Reader.varint(reader)
	local plans: { [string]: ColumnPlan } = {}

	for _ = 1, count do
		local key = Reader.string(reader)
		local kind = Reader.u8(reader)
		local descriptorCount = Reader.varint(reader)

		local descriptors = table.create(descriptorCount)
		for index = 1, descriptorCount do
			descriptors[index] = Reader.varint(reader)
		end

		plans[key] = { kind = kind, descriptors = descriptors }
	end

	--[[
		The shapes recorded as finding no correlation. Absent from an older
		saved schema, which reads as a count of zero and means every shape runs
		the search -- the behaviour before this was recorded.
	]]
	local correlations: { [string]: boolean } = {}
	if Reader.remaining(reader) > 0 then
		local barrenCount = Reader.varint(reader)
		for _ = 1, barrenCount do
			correlations[Reader.string(reader)] = false
		end
	end

	local computed = fingerprintOf(plans)
	if computed ~= storedFingerprint then
		error(
			`Zzzz: this schema is corrupt -- its fingerprint does not match its `
				.. `contents (stored {storedFingerprint}, computed {computed}).`,
			2
		)
	end

	local data: SchemaData = {
		plans = plans,
		correlations = correlations,
		options = options,
		fingerprint = storedFingerprint,
	}

	return setmetatable({ data = data }, Schema)
end

return Schema
