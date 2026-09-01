--!strict
--!native
--!optimize 2

--[[
	Zzzz -- Lazy Developer Needs This.

	Zero-schema serialization for Luau.

		local Zzzz = require(path.Zzzz)
		local Zz = Zzzz.new()

		local packet, instances = Zz:Serialize({
			Coins = 5000,
			Position = Vector3.new(10, 20, 30),
			Inventory = { "Sword", "Potion" },
		})

		local data = Zz:Deserialize(packet, instances)

	No schema. No type declarations. Hand it a value and it works out the rest.

	Options:

		Zzzz.new({
			InstanceMode = "full",     -- serialize hierarchies, not references
			StructureCache = true,     -- send repeated table shapes once
			Precision = 0.01,          -- lossy: round numbers to 2 decimals
			BitPack = true,            -- 1 bit per boolean in dense arrays
			MaxDepth = 512,
			MaxNodes = 100000,
		})

	Zzzz does not compress. It makes the bytes structurally small -- narrow
	tags, varints, interning, references, packed rotations -- and stops there.
	If you want general compression on top, the engine already has it:

		local packet = Zz:Serialize(data)
		local small = EncodingService:CompressBuffer(packet, Enum.CompressionAlgorithm.Zstd)

	That is native zstd and no Luau implementation will beat it.

	Instances cannot travel inside a buffer in reference mode -- Roblox
	replicates references natively, so Serialize returns them in a side array.
	Pass that array back to Deserialize. With no Instances in your data the
	array is empty and can be ignored.
]]

local Decoder = require(script.Decoder)
local Encoder = require(script.Encoder)
local Schema = require(script.Schema)
local Reader = require(script.Reader)
local Quantize = require(script.Types.Quantize)
local Reflection = require(script.Types.Reflection)
local Tags = require(script.Tags)
local Writer = require(script.Writer)

local Zzzz = {}
Zzzz.__index = Zzzz

export type Options = {
	--[[
		"reference" (default) stores Instances as indices into a side array.
		"full" serializes the whole hierarchy -- ClassName, non-default
		properties, attributes, tags, children -- so it can be rebuilt in a
		different session or place.

		SECURITY: "full" rebuilds whatever the packet describes. A packet is
		data, and a hostile one can name any creatable ClassName and any
		writable property -- including a Script and its Source. Nothing is
		parented during decode, so the result is inert until the caller
		parents it, but a packet from an untrusted source must be inspected
		before it goes anywhere near the DataModel.

		Do not use "full" on anything a client sent you. Reference mode is the
		safe default for network input.
	]]
	InstanceMode: string?,

	--[[
		Send the keys of repeated table shapes once instead of per table.
		Large wins on arrays of similar records; costs a little CPU.
	]]
	StructureCache: boolean?,

	--[[
		Write arrays of uniform records as one column per field rather than one
		block per row. Values of a single type end up adjacent, so a boolean
		column bit-packs, a low-cardinality string column becomes a dictionary,
		a column of integers packs at a fixed bit width, a column of Vector3s is
		written as deltas from a nearby base, and a later compression pass finds
		far more structure.

		Lossless, and skipped for any array whose rows are shared with
		something else or take part in a cycle -- rebuilding those as fresh
		tables would break reference identity.

		Pairs naturally with BitPack, which is what packs the boolean columns.
	]]
	Columnar: boolean?,

	--[[
		Round numbers to this step before encoding -- 0.01 keeps two decimal
		places. Lossy: worst-case error is half the precision.

		Applies to non-integer numbers, Vector2, Vector3 and CFrame positions.
		Integers are left exact, since they already encode at least as small.
		Individual values fall back to their exact form whenever quantizing
		would not actually be smaller, which happens past roughly 16,000 studs
		at 0.01 precision.

		The precision travels inside the packet, so any reader decodes it
		correctly regardless of its own settings.
	]]
	Precision: number?,

	--[[
		Encode an integer column as a residual against another column in the same
		records, when the two are related.

		Two fields are often two views of one quantity -- health and maxHealth, a
		position's Y and the ground beneath it, level and the xp for it. Encoded
		independently each pays for its own full range; encoded against the
		other, only the difference is stored.

		The relationship is fitted as slope and intercept, so a scaled pairing
		such as xp against level is caught as well as an equal-magnitude one.
		Both are rounded to integers, which keeps the residual exact -- a
		relationship that is not integral simply produces a wider residual, loses
		the size comparison, and the column is encoded on its own.

		Requires Columnar, costs a correlation pass over the numeric columns, and
		does nothing at all unless the data actually has related fields. Off by
		default for that reason.
	]]
	Correlate: boolean?,

	--[[
		Pack dense arrays of 8 or more booleans at one bit each: 1,000 booleans
		become 125 bytes rather than 1,000. Lossless.
	]]
	BitPack: boolean?,

	--[[
		Whether `Diff` encodes the full form as well, to guarantee it never
		returns a packet larger than a plain `Serialize`. On by default.

		The guarantee costs a second encode of the current value on every call,
		which is most of what `Diff` spends when the patch was always going to
		win. Turning it off makes `Diff` behave as `DiffOnly` does: the patch is
		returned whatever its size.

		Leave it on unless the traffic is known to be sparse. A tick where most
		values changed can produce a patch several times larger than the full
		form, and without the guard that is what gets sent.
	]]
	GuardDiff: boolean?,

	--[[
		Deepest table nesting to accept, in both directions.

		On decode this is a safety limit, not a preference: a hand-crafted
		packet of nested table tags is only two bytes per level, and without a
		bound the decoder recurses until Luau's own stack gives out.
	]]
	MaxDepth: number?,

	MaxNodes: number?,
}

export type Zzzz = typeof(setmetatable(
	{} :: {
		instanceMode: string,
		structureCache: boolean,
		columnar: boolean,
		correlate: boolean,
		precision: number?,
		bitPack: boolean,
		guardDiff: boolean,
		maxDepth: number,
		maxNodes: number,
	},
	Zzzz
))

local DEFAULT_MAX_DEPTH = 512
local DEFAULT_MAX_NODES = 100000

Zzzz.Version = Tags.VERSION

-- Options -------------------------------------------------------------------

--[[
	Every option this library accepts, keyed by its name folded to lower case.

	Options are matched without regard to case, so `StructureCache`,
	`structureCache` and `sTructurecachE` all name the same thing. The canonical
	spelling is what the value maps to, and is what the documentation and the
	error messages use.

	The reason is a bug that was genuinely expensive to find. The options table
	was read by exact key -- `resolved.StructureCache` -- so a table written with
	lower-case names set nothing at all, and nothing said so. Worse, the two
	entry points disagreed about what "nothing" meant: `Zzzz.new` tested
	`== true` and defaulted every option OFF, while `Zzzz.schema` tested
	`~= false` and defaulted them all ON. The same table therefore produced a
	plain encode from one call and a fully optimised one from the other, and the
	difference looked exactly like a compression result -- 1,886 KB against 427
	KB, which reads as a 4.4x win for schemas rather than as a typo.

	So the fix is two things, and it needs both. Matching case-insensitively
	means a near-miss spelling works; rejecting unknown keys means a spelling
	that is not a near miss is reported rather than ignored.
]]
local OPTION_NAMES = {
	instancemode = "InstanceMode",
	structurecache = "StructureCache",
	columnar = "Columnar",
	correlate = "Correlate",
	precision = "Precision",
	bitpack = "BitPack",
	guarddiff = "GuardDiff",
	maxdepth = "MaxDepth",
	maxnodes = "MaxNodes",
}

--[[
	The canonical option names, for the "did you mean" line in the error below.
	Built once, sorted, so the message is stable between runs.
]]
local OPTION_LIST = {}
for _, canonical in OPTION_NAMES do
	table.insert(OPTION_LIST, canonical)
end
table.sort(OPTION_LIST)
local OPTION_LIST_TEXT = table.concat(OPTION_LIST, ", ")

--[[
	Fold an options table to its canonical spellings, and reject anything that
	names no option at all.

	A key that is not a string, or whose lower-case form is not an option, is an
	error rather than a value to ignore. That is the whole point: an option the
	caller believed they set and which silently did nothing is worse than a
	packet that is merely larger, because nothing downstream reveals it.
]]
local function normaliseOptions(options: any): { [string]: any }
	if options == nil then
		return {}
	end

	if type(options) ~= "table" then
		error(`Zzzz: options must be a table, got {typeof(options)}`, 0)
	end

	local resolved: { [string]: any } = {}

	for key, value in pairs(options) do
		if type(key) ~= "string" then
			error(`Zzzz: option names must be strings, got a {typeof(key)} key`, 0)
		end

		local canonical = OPTION_NAMES[string.lower(key)]
		if canonical == nil then
			error(
				`Zzzz: unknown option "{key}". Valid options are: {OPTION_LIST_TEXT}`,
				0
			)
		end

		--[[
			Two spellings of one option in the same table. Taking either silently
			would make the result depend on `pairs` order, which is not stable, so
			the call is refused instead.
		]]
		if resolved[canonical] ~= nil then
			error(
				`Zzzz: option "{canonical}" given more than once (names are matched without case)`,
				0
			)
		end

		resolved[canonical] = value
	end

	return resolved
end

Zzzz.normaliseOptions = normaliseOptions

-- Construction --------------------------------------------------------------

function Zzzz.new(options: Options?): Zzzz
	local resolved = normaliseOptions(options)

	local instanceMode = resolved.InstanceMode or "reference"
	if instanceMode ~= "reference" and instanceMode ~= "full" then
		error(`Zzzz: InstanceMode must be "reference" or "full", got "{instanceMode}"`, 0)
	end

	if resolved.Precision then
		Quantize.validate(resolved.Precision)
	end

	return setmetatable({
		instanceMode = instanceMode,
		structureCache = resolved.StructureCache == true,
		columnar = resolved.Columnar == true,
		correlate = resolved.Correlate == true,
		precision = resolved.Precision,
		bitPack = resolved.BitPack == true,
		guardDiff = resolved.GuardDiff ~= false,
		maxDepth = resolved.MaxDepth or DEFAULT_MAX_DEPTH,
		maxNodes = resolved.MaxNodes or DEFAULT_MAX_NODES,
	}, Zzzz)
end

-- Schemas ---------------------------------------------------------------------

--[[
	Derive a schema from real data.

	Zzzz normally works out the shape and the encoding of every column at encode
	time. On a server writing the same shape repeatedly, that discovery is
	repeated unchanged every time and is most of what the encode costs. A schema
	records what the encoder chose once, so later encodes replay the decisions
	rather than making them again.

		local Schema = Zzzz.schema(sampleSaves)
		local packet = Schema:Encode(saves)

	Measured on 2,000 flat rows: 7.07 ms discovering, 2.69 ms replaying, for
	1.6% more bytes.

	The sample must be representative rather than merely well-formed -- the
	schema inherits its ranges, so a sample where no player passed level 100
	produces a schema that has to fall back when one does. It falls back safely
	and reports it in `stats.planMisses`; it never writes a truncated value.

	`options` are the same ones `Zzzz.new` takes, and are part of the schema: a
	schema derived with `Columnar` describes columns, and encoding without it
	would have nothing to replay them into.

	PATCHES

	A schema patches as well as encodes, mirroring the two calls the main API
	has:

		local Schema = Zzzz.schema(sample, options)
		local packet = Schema:DiffOnly(previous, current)  -- no guard
		local packet = Schema:Diff(previous, current)      -- never worse

	`Schema:Diff` makes the same promise `Zzzz:Diff` makes -- never a packet
	larger than encoding the whole value -- and that promise costs a second
	encode. The difference is which encoder pays it: `Zzzz:Diff` runs a full
	adaptive encode, which on a sparse tick is most of the call, while
	`Schema:Diff` runs the compiled one. That is where a compiled patch path
	actually earns its place.

	The patch itself is searched for either way -- the forms each column takes
	are not recorded, because measuring showed there was nothing there to win.
	The search is a couple of percent of a patch, and the extraction and scaling
	that produce its inputs cannot be skipped by any schema.
]]
function Zzzz.schema(sample: any, options: Options?): Schema.Schema
	local resolved = options or {}

	return Schema.derive(sample, {
		instanceMode = resolved.InstanceMode or "reference",
		structureCache = resolved.StructureCache ~= false,
		columnar = resolved.Columnar ~= false,
		correlate = resolved.Correlate == true,
		precision = resolved.Precision,
		bitPack = resolved.BitPack ~= false,
		maxDepth = resolved.MaxDepth or DEFAULT_MAX_DEPTH,
		maxNodes = resolved.MaxNodes or DEFAULT_MAX_NODES,
	})
end

--[[
	Read back a schema saved with `Schema:Save`, so derivation happens once ever
	rather than once per server start. Errors if the bytes were written by a
	different version of the library, or if they have been altered.
]]
function Zzzz.loadSchema(stored: buffer): Schema.Schema
	return Schema.load(stored)
end

local function encoderOptions(self: Zzzz): Encoder.Options
	return {
		instanceMode = self.instanceMode,
		structureCache = self.structureCache,
		columnar = self.columnar,
		correlate = self.correlate,
		precision = self.precision,
		bitPack = self.bitPack,
		maxDepth = self.maxDepth,
		maxNodes = self.maxNodes,
	}
end

-- Core API ------------------------------------------------------------------

--[[
	Serialize any supported value.

	Returns the packet buffer and the Instance array. In reference mode the
	array holds every Instance the value referred to; in full mode it holds
	only those referred to from outside the serialized hierarchy.
]]
function Zzzz.Serialize(self: Zzzz, value: any): (buffer, { Instance })
	return Encoder.encode(value, encoderOptions(self))
end

--[[
	Rebuild a value from a packet.
]]
function Zzzz.Deserialize(self: Zzzz, packet: buffer, instances: { Instance }?): any
	return Decoder.decode(packet, instances, self.maxDepth, self.maxNodes)
end

-- Baseline delta -------------------------------------------------------------

--[[
	Serialize only what differs from a value the receiver already holds.

		local packet = Zz:Diff(lastSent, state)
		local state = Zz:Patch(lastSent, packet)

	Measured against a full re-send of the same data, over 720 combinations of
	shape, movement rate and jitter:

		nothing moved        36x smaller
		5% of rows moved     12x
		25% of rows moved     3x
		everything moved     the full form wins, and is what gets sent

	That last row is why this measures both. A patch is only smaller while the
	change is sparse: once most values differ, the change masks are overhead and
	the patched values are no narrower than the originals -- a teleport differs
	from its baseline by as much as it differs from zero. Worst case measured
	1.47x the full form, so both are written and the smaller is returned. The
	patch can never lose, only fail to win.

	The returned packet is a patch or a whole value, and `Patch` accepts either,
	so the caller does not have to care which was cheaper. `Zzzz.IsPatch` tells
	them if they want to know.

	WHAT THE GUARANTEE COSTS

	Measured on 2,000 entities with a twentieth of them moved:

		the patch itself      0.79 ms
		the full Serialize   14.14 ms
		Diff                 15.16 ms

	The patch is not the expensive part and never was. Nearly all of Diff's time
	is the full form, encoded only so its size can be compared -- on a sparse
	tick, work that was never going to change the answer.

	`DiffOnly` skips it and is roughly twenty times faster. Reach for it once the
	traffic is understood; keep `Diff` while it is not.

	KEEPING THE TWO SIDES IN STEP

	A patch is only meaningful against the exact value it was diffed from, and
	nothing in the packet says which value that was. That is deliberate -- a
	baseline identifier would cost bytes on every packet and only the transport
	knows what it should be -- but it makes the failure mode worth stating
	plainly, because it is silent:

		applied to the wrong baseline, a patch produces a wrong value rather
		than an error, and every later patch builds on it

	Nothing here detects that. Guarding it is the caller's job, and the standard
	shape is the one snapshot protocols use: number each snapshot, have the
	receiver acknowledge what it holds, and diff against the last acknowledged
	value rather than the last sent one.

		local acknowledged = history[client.lastAck]
		local packet = Zz:Diff(acknowledged, state)

	Over an ordered, reliable transport -- which a Roblox RemoteEvent is -- the
	simpler form is enough: keep one baseline per receiver, patch it, and send
	the next diff against the result.

		local packet = Zz:Diff(lastSent[player], state)
		lastSent[player] = state

	Send a full `Serialize` to start, and again whenever a receiver's baseline
	is in doubt -- a rejoin, a reconnect, a dropped patch. `Diff` against a
	stale baseline is not recoverable from the packet alone.
]]
--[[
	Above this changed fraction, the whole encode is computed and compared
	exactly. Below it, the patch is returned without one.

	Chosen from the measured relationship between the two, on 2,000 six-column
	rows:

		  0% moved     patch is   0.4% of the whole encode
		 10%                      7.5%
		 25%                     15.9%
		 50%                     29.1%
		100%                     55.5%
		replaced                159.4%

	Even a wholly rewritten value -- every field different, the case that beats
	the patch -- moves 100% of its rows, so it lands above any threshold below
	one. The margin is wide: a patch does not approach its whole encode until
	well past half the rows have changed, and the sparse ticks this exists for
	sit two orders of magnitude below.

	0.5 rather than something tighter because the cost of being wrong is
	asymmetric. Guessing "verify" when the patch would have won wastes an encode
	-- the behaviour before this existed. Guessing "skip" when it would have
	lost breaks the guarantee, silently. So the threshold sits far below where
	the two curves meet, and everything near the crossing is verified.

	Defined in the encoder, beside the fraction it is compared against.
]]
local GUARD_VERIFY_FRACTION = Encoder.GUARD_VERIFY_FRACTION

function Zzzz.Diff(self: Zzzz, baseline: any, current: any): (buffer, { Instance })
	local options = encoderOptions(self)

	--[[
		The context comes back so the guard can read how much of the value
		actually changed; see `changedFraction` in the encoder.
	]]
	local patch, patchInstances, ctx =
		Encoder.encodeDeltaWithContext(baseline, current, options)

	--[[
		The guard costs a second encode, which is the price of never returning a
		packet larger than a plain Serialize. A caller who knows their ticks are
		sparse can decline it outright -- see `DiffOnly`.
	]]
	if not self.guardDiff then
		return patch, patchInstances
	end

	--[[
		Skip the comparison where its answer is not in doubt.

		The guarantee is unchanged: this only decides whether the exact check is
		worth making, and every case that could plausibly fail it is still
		checked exactly. What it removes is a full encode on ticks where the
		patch is a fiftieth of the whole value, which is what a patch is for.

		`changedFraction` is absent when the value took no row form at all -- a
		map, a scalar, a shape the columnar patch does not handle. Absent means
		unknown, and unknown verifies.
	]]
	local fraction = ctx.stats.changedFraction
	if fraction ~= nil and fraction < GUARD_VERIFY_FRACTION then
		return patch, patchInstances
	end

	local whole, wholeInstances = Encoder.encode(current, options)

	if buffer.len(patch) < buffer.len(whole) then
		return patch, patchInstances
	end
	return whole, wholeInstances
end

--[[
	A patch, without encoding the full form to compare against it.

	`Diff` promises never to be worse than not patching at all, and buys that
	with a second, full `Serialize` to compare against.

	That used to be almost the whole cost of the call -- 0.79 ms of patch against
	15.16 ms guarded, on 2,000 entities with a twentieth moved. It no longer is:
	`Diff` skips the comparison where the changed fraction proves it cannot go
	the other way, so on a sparse tick the two calls are within noise of each
	other. Measured at a tenth moved, 1.007 ms guarded against 1.131 unguarded.

	So the reason to reach for this is now narrow. It is the right call when
	ticks are known to be large -- above half the rows changed, where `Diff`
	does encode the whole value -- and the caller has already decided a patch is
	what they want regardless of size.

		-- a tick loop, where the shape of the change is known in advance
		local packet = Zz:DiffOnly(lastSent, state)

	The risk is real and bounded. On a tick where most values changed, a patch
	can exceed a full Serialize -- measured at worst 3.3x on a full refresh. Send
	`Serialize` directly for those rather than hoping, and keep `Diff` wherever
	the change rate is genuinely unknown, which now costs little.

	`Patch` reads the result either way.
]]
function Zzzz.DiffOnly(self: Zzzz, baseline: any, current: any): (buffer, { Instance })
	return Encoder.encodeDelta(baseline, current, encoderOptions(self))
end

--[[
	Rebuild a value from whatever `Diff` returned.

	Takes a patch or a whole packet: `Diff` returns whichever was smaller, so
	this accepts both rather than making the caller track it.

	The baseline is not modified. Tables the patch touches are copied on the way
	down and tables it does not touch are shared with the baseline, so applying
	a sparse patch costs what changed rather than what exists -- and the caller
	keeps a usable old value.

	A patch applied to the wrong baseline does not error, and the result is worse
	than merely stale.

	Columns that chose the delta form carry how far a value moved, not what it
	became, so applying one to a baseline that lacks the field adds the movement
	to nothing. Measured: a field whose true value was 99 came back as 59, the
	delta alone, having been added to an absent field read as zero. That number
	appears in neither the sender's state nor the receiver's -- it is invented by
	the mismatch.

	Nothing downstream will say so. See `Diff` for how to keep the two sides in
	step, and prefer a full `Serialize` whenever a receiver's baseline is in
	doubt.

	A malformed packet does error. Truncation, an unknown op, a row index outside
	the baseline, a bit width past the format's limit and nesting past `MaxDepth`
	are all rejected rather than guessed at.
]]
function Zzzz.Patch(
	self: Zzzz,
	baseline: any,
	packet: buffer,
	instances: { Instance }?
): any
	if Decoder.isDelta(packet) then
		return Decoder.patch(baseline, packet, instances, self.maxDepth, self.maxNodes)
	end
	return Decoder.decode(packet, instances, self.maxDepth, self.maxNodes)
end

--[[
	Whether a packet is a patch rather than a whole value.
]]
function Zzzz.IsPatch(_self: Zzzz, packet: buffer): boolean
	return Decoder.isDelta(packet)
end

--[[
	Serialize to a string rather than a buffer, for DataStores and anywhere
	else that will not take a buffer.
]]
function Zzzz.SerializeToString(self: Zzzz, value: any): (string, { Instance })
	local packet, instances = Zzzz.Serialize(self, value)
	return buffer.tostring(packet), instances
end

function Zzzz.DeserializeFromString(
	self: Zzzz,
	packet: string,
	instances: { Instance }?
): any
	return Zzzz.Deserialize(self, buffer.fromstring(packet), instances)
end

-- Developer experience ------------------------------------------------------

export type Report = {
	Bytes: number,
	Instances: number,
	StructureDefinitions: number,
	StructureHits: number,
	Strings: number,
	Tables: number,
	Types: { [string]: number },
}

local function countTypes(value: any, counts: { [string]: number }, seen: { [any]: boolean }): ()
	local valueType = typeof(value)

	if valueType == "table" then
		if seen[value] then
			return
		end
		seen[value] = true
		counts.table = (counts.table or 0) + 1
		for key, entry in pairs(value) do
			countTypes(key, counts, seen)
			countTypes(entry, counts, seen)
		end
		return
	end

	counts[valueType] = (counts[valueType] or 0) + 1
end

--[[
	Describe what a value costs to serialize, without sending it anywhere.

	Reports the packet size, how many structure shapes were reused, and a
	breakdown of the value types involved -- enough to see where the bytes are
	actually going.
]]
function Zzzz.Inspect(self: Zzzz, value: any): Report
	local packet, instances, ctx = Encoder.encodeWithContext(value, encoderOptions(self))

	local counts: { [string]: number } = {}
	countTypes(value, counts, {})

	local report: Report = {
		Bytes = buffer.len(packet),
		Instances = #instances,
		StructureDefinitions = ctx.stats.structDefs or 0,
		StructureHits = ctx.stats.structHits or 0,
		Strings = ctx.nextStringId,
		Tables = ctx.nextTableId,
		Types = counts,
	}

	return report
end

export type DeltaColumnReport = {
	Key: string,
	Axis: number,
	Scale: number,
	Form: string,
	Bits: number?,
	Values: number,
	Bytes: number,
}

export type DeltaReport = {
	Bytes: number,
	FullBytes: number,
	IsPatch: boolean,
	Columns: { DeltaColumnReport },
}

local DELTA_FORM_NAMES = {
	[0] = "varint absolute",
	[1] = "varint delta",
	[2] = "packed absolute",
	[3] = "packed delta",
}

--[[
	Describe what a patch costs, and what each of its columns chose.

	`Inspect` answers "why is this value this size"; this answers the question a
	patch actually raises, which is "why did this tick cost what it did". The
	two are different because a patch's size is decided per column: a Vector3
	that packs its deltas at nine bits and one that falls back to tagged values
	differ by several times, and nothing in the byte count says which happened.

		for _, column in Zz:InspectDiff(before, after).Columns do
			print(column.Key, column.Form, column.Bits)
		end

	A column reported as `tagged` is one that could not be taken apart -- a
	string, a mixed-type field, a value no scale represents exactly. That is
	usually the answer when a patch is larger than expected.

	`FullBytes` is what a plain Serialize would have cost, since `Diff` returns
	whichever is smaller and a patch that lost is worth knowing about.
]]
function Zzzz.InspectDiff(self: Zzzz, baseline: any, current: any): DeltaReport
	local options = encoderOptions(self)

	local patch, _instances, ctx = Encoder.encodeDeltaWithContext(baseline, current, options)
	local whole = Encoder.encode(current, options)

	local columns: { DeltaColumnReport } = {}
	for _, entry in ctx.stats.deltaColumns or {} do
		table.insert(columns, {
			Key = entry.key,
			Axis = entry.axis,
			Scale = entry.factor,
			Form = DELTA_FORM_NAMES[entry.form] or tostring(entry.form),
			Bits = entry.bits,
			Values = entry.count,
			Bytes = entry.bytes,
		})
	end

	return {
		Bytes = buffer.len(patch),
		FullBytes = buffer.len(whole),
		IsPatch = buffer.len(patch) < buffer.len(whole),
		Columns = columns,
	}
end

--[[
	Human-readable form of InspectDiff, for printing during development.
]]
function Zzzz.InspectDiffToString(self: Zzzz, baseline: any, current: any): string
	local report = Zzzz.InspectDiff(self, baseline, current)

	local lines = {
		"Zzzz patch",
		("  patch           %d bytes"):format(report.Bytes),
		("  full Serialize  %d bytes"):format(report.FullBytes),
		("  sent            %s"):format(if report.IsPatch then "the patch" else "the full form"),
	}

	if #report.Columns == 0 then
		table.insert(lines, "  columns         none decomposed -- every field travelled tagged")
		return table.concat(lines, "\n")
	end

	local payload = 0
	for _, column in report.Columns do
		payload += column.Bytes
	end

	table.insert(lines, ("  columns         %d, %d bytes of payload"):format(
		#report.Columns, payload))

	for _, column in report.Columns do
		table.insert(lines, ("    %-14s axis %d  scale %d  %-16s %-5s %5d values %6d B"):format(
			column.Key,
			column.Axis,
			column.Scale,
			column.Form,
			if column.Bits then column.Bits .. "b" else "-",
			column.Values,
			column.Bytes
		))
	end

	return table.concat(lines, "\n")
end

--[[
	Human-readable form of Inspect, for printing during development.
]]
function Zzzz.InspectToString(self: Zzzz, value: any): string
	local report = Zzzz.Inspect(self, value)

	local lines = {
		"Zzzz packet",
		("  size            %d bytes"):format(report.Bytes),
	}

	table.insert(lines, ("  tables          %d"):format(report.Tables))
	table.insert(lines, ("  unique strings  %d"):format(report.Strings))

	if report.Instances > 0 then
		table.insert(lines, ("  instances       %d"):format(report.Instances))
	end

	if report.StructureDefinitions > 0 then
		table.insert(
			lines,
			("  structures      %d defined, %d reused"):format(
				report.StructureDefinitions,
				report.StructureHits
			)
		)
	end

	local typeNames = {}
	for typeName in report.Types do
		table.insert(typeNames, typeName)
	end
	table.sort(typeNames)

	if #typeNames > 0 then
		table.insert(lines, "  types")
		for _, typeName in typeNames do
			table.insert(lines, ("    %-14s %d"):format(typeName, report.Types[typeName]))
		end
	end

	return table.concat(lines, "\n")
end

export type BenchmarkResult = {
	Iterations: number,
	SerializeMs: number,
	DeserializeMs: number,
	Bytes: number,
}

--[[
	Time a round trip. Reports per-call milliseconds averaged over `iterations`.
]]
function Zzzz.Benchmark(self: Zzzz, value: any, iterations: number?): BenchmarkResult
	local runs = iterations or 100

	-- One warm-up pass so the first call's compilation does not skew results.
	local packet, instances = Zzzz.Serialize(self, value)
	Zzzz.Deserialize(self, packet, instances)

	local serializeStart = os.clock()
	for _ = 1, runs do
		Zzzz.Serialize(self, value)
	end
	local serializeElapsed = os.clock() - serializeStart

	local deserializeStart = os.clock()
	for _ = 1, runs do
		Zzzz.Deserialize(self, packet, instances)
	end
	local deserializeElapsed = os.clock() - deserializeStart

	return {
		Iterations = runs,
		SerializeMs = (serializeElapsed / runs) * 1000,
		DeserializeMs = (deserializeElapsed / runs) * 1000,
		Bytes = buffer.len(packet),
	}
end

function Zzzz.BenchmarkToString(self: Zzzz, value: any, iterations: number?): string
	local result = Zzzz.Benchmark(self, value, iterations)
	return table.concat({
		("Zzzz benchmark (%d iterations)"):format(result.Iterations),
		("  serialize    %.4f ms"):format(result.SerializeMs),
		("  deserialize  %.4f ms"):format(result.DeserializeMs),
		("  size         %d bytes"):format(result.Bytes),
	}, "\n")
end

-- Internals, exposed for tests and for building on top of Zzzz.
Zzzz.Encoder = Encoder
Zzzz.Decoder = Decoder
Zzzz.Writer = Writer
Zzzz.Reader = Reader
Zzzz.Quantize = Quantize
Zzzz.Reflection = Reflection
Zzzz.Tags = Tags

return Zzzz
