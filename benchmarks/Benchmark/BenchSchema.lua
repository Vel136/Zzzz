--!strict
--!native
--!optimize 2
--[[
	Schema vs adaptive, across ten dataset shapes at large sizes.

	The question is narrow: what does replaying a schema's recorded forms buy
	over discovering them, in encode time, and what does it cost in bytes.

	Two schema columns, because they answer different questions and only one of
	them is the real use:

	  self    derive on the payload, then encode that same payload. This is what
	          Benchmark.lua's schemaSection does. It measures the replay path
	          cleanly but flatters it -- the schema has seen every value, so no
	          plan can miss.

	  sample  derive on one batch, encode a DIFFERENT batch from the same
	          generator. This is how a schema is actually used: derived once,
	          saved, replayed on data that did not exist when it was derived. A
	          value outside a recorded plan's range falls back, which costs
	          bytes and shows up in planMisses.

	Fixture datasets (Variant1-3) cannot produce a second batch, so they report
	self only. Their `sample` column reads "--".

	Every row round-trips before its numbers are reported. A faster encode that
	does not decode back to the original is not a faster encode.
]]

local RS = game:GetService("ReplicatedStorage")
local Zzzz = require(RS.Zzzz)
local Bench = require(RS.Zzzz.Benchmark)

-- Options held constant across every dataset, so the only variable is shape.
local OPTIONS = {
	StructureCache = true,
	BitPack = true,
	Columnar = true,
}

-- Settle the collector before a clock starts; see the note in Benchmark.lua.
local function settle()
	for _ = 1, 10 do
		task.wait()
	end
end

local function comma(value: number): string
	local text = tostring(math.floor(value))
	local out = ""
	while #text > 3 do
		out = "," .. string.sub(text, -3) .. out
		text = string.sub(text, 1, -4)
	end
	return text .. out
end

--[[
	Time a function as the best of `runs` rather than the mean.

	Benchmark.lua documents encode figures moving by 2x between runs of
	identical code -- 108,108,107,117,121,199 ms for one unchanged row. The
	minimum is the run least disturbed by the collector and by whatever else the
	machine was doing, and it is far more stable across sessions than a mean,
	which any single outlier drags.
]]
local function timeBest(runs: number, fn: () -> any): (number, any)
	local best = math.huge
	local result: any = nil
	for _ = 1, runs do
		settle()
		local started = os.clock()
		local value = fn()
		local elapsed = (os.clock() - started) * 1000
		if elapsed < best then
			best = elapsed
		end
		result = value
	end
	return best, result
end

--[[
	Leaf count, matching Benchmark.countValues, so ns/value is comparable to the
	figures already published.
]]
local countValues = Bench.countValues

--[[
	Deep structural comparison, used to round-trip every dataset.

	Benchmark.lua verifies by spot-checking named fields, which needs a verifier
	per shape. Ten shapes makes that ten verifiers, so this compares generically
	instead -- and being exhaustive rather than a spot check, it is strictly the
	stronger test.

	NaN is treated as equal to itself: it round-trips as NaN, and `~=` would
	report that as a mismatch.
]]
local function deepEqual(a: any, b: any, path: string): (boolean, string?)
	local ta, tb = typeof(a), typeof(b)
	if ta ~= tb then
		return false, string.format("%s: type %s vs %s", path, ta, tb)
	end

	if ta == "table" then
		for key, value in pairs(a) do
			local ok, why = deepEqual(value, (b :: any)[key], path .. "." .. tostring(key))
			if not ok then
				return false, why
			end
		end
		-- The other direction, so a key present only in the decoded copy is
		-- caught. Presence must match exactly for the optional-column form.
		for key in pairs(b) do
			if (a :: any)[key] == nil then
				return false, string.format("%s.%s: extra key after decode", path, tostring(key))
			end
		end
		return true, nil
	end

	if ta == "number" then
		if a ~= a and b ~= b then
			return true, nil
		end
		if a ~= b then
			return false, string.format("%s: %s vs %s", path, tostring(a), tostring(b))
		end
		return true, nil
	end

	--[[
		CFrame rotation is packed lossily by design -- see the rotation forms in
		Tags.lua -- so an exact compare is the wrong check for it. Position is
		still held exact, since only the rotation is approximated.

		The tolerance is on the rotation matrix components, which are direction
		cosines in [-1, 1]; 1e-2 is far tighter than the packing's worst case and
		far looser than the float noise.
	]]
	if ta == "CFrame" then
		if (a.Position - b.Position).Magnitude > 1e-4 then
			return false, string.format("%s: position %s vs %s", path, tostring(a.Position), tostring(b.Position))
		end
		local ax, ay, az = a.XVector, a.YVector, a.ZVector
		local bx, by, bz = b.XVector, b.YVector, b.ZVector
		if
			(ax - bx).Magnitude > 1e-2
			or (ay - by).Magnitude > 1e-2
			or (az - bz).Magnitude > 1e-2
		then
			return false, string.format("%s: rotation beyond tolerance", path)
		end
		return true, nil
	end

	if a ~= b then
		return false, string.format("%s: %s vs %s", path, tostring(a), tostring(b))
	end
	return true, nil
end

-- Datasets -------------------------------------------------------------------

--[[
	Ten shapes, chosen so that each stresses a different part of the encoder.
	`build(seed)` returns a fresh payload; two calls with different seeds give
	the derive-sample and the encode-payload for the `sample` column.

	`fixture` marks a dataset that is a fixed table on disk rather than a
	generator -- it cannot produce a second batch, so it reports self only.
]]
local datasets = {}

--[[
	1. Player saves. The published headline shape: uniform records, mixed integer
	stats, variable-length nested inventories, long boolean runs.
]]
table.insert(datasets, {
	name = "player saves",
	note = "uniform records, nested arrays",
	build = function(seed: number)
		return Bench.build(6000, seed)
	end,
})

--[[
	2. The mixed world entities. Optional fields, sorted runs, equal columns,
	real floats, 1-to-1 and 1-to-N mappings, a fitted correlation.
]]
table.insert(datasets, {
	name = "world entities",
	note = "optional, runs, equal cols",
	build = function(seed: number)
		return Bench.buildMixed(12000, seed)
	end,
})

--[[
	3. Wide flat rows. Forty independent integer columns and nothing nested --
	the shape a schema should replay best, since every column is a plain column
	and the discovery it skips is the whole of the work.
]]
table.insert(datasets, {
	name = "wide flat rows",
	note = "40 independent int columns",
	build = function(seed: number)
		local random = Random.new(seed)
		local rows = table.create(15000)
		for index = 1, 15000 do
			local row = {}
			for column = 1, 40 do
				row["f" .. column] = random:NextInteger(0, 65535)
			end
			rows[index] = row
		end
		return rows
	end,
})

--[[
	4. Telemetry. A monotonic timestamp, a slowly drifting float, a scattered
	event code -- the differenced, quantized and frequency forms respectively.
	This is the shape where a schema's recorded form beats a declared type most
	clearly: `tick` is sequential and pays a couple of bits differenced.
]]
table.insert(datasets, {
	name = "telemetry stream",
	note = "monotonic ts, drifting float",
	build = function(seed: number)
		local random = Random.new(seed)
		local rows = table.create(20000)
		local tick = 1700000000
		local temperature = 20.0
		for index = 1, 20000 do
			tick += random:NextInteger(1, 3)
			temperature += random:NextNumber() * 0.2 - 0.1
			rows[index] = {
				tick = tick,
				sensor = random:NextInteger(1, 12),
				temperature = temperature,
				-- Zero on almost every row: the frequency form's case.
				event = if random:NextNumber() > 0.97 then random:NextInteger(1, 50) else 0,
				valid = random:NextNumber() > 0.02,
			}
		end
		return rows
	end,
})

--[[
	5. Movement snapshots. Vector3 and CFrame heavy, which routes through the
	position-delta and rotation-packing paths rather than the integer ones.
]]
table.insert(datasets, {
	name = "movement snapshots",
	note = "Vector3 + CFrame heavy",
	build = function(seed: number)
		local random = Random.new(seed)
		local rows = table.create(10000)
		local position = Vector3.new(0, 5, 0)
		for index = 1, 10000 do
			-- A walk rather than independent draws, so successive positions are
			-- close and the delta form has something to find.
			position += Vector3.new(
				random:NextNumber() * 4 - 2,
				random:NextNumber() * 0.4 - 0.2,
				random:NextNumber() * 4 - 2
			)
			rows[index] = {
				id = index,
				position = position,
				velocity = Vector3.new(
					random:NextNumber() * 20 - 10,
					random:NextNumber() * 6,
					random:NextNumber() * 20 - 10
				),
				pivot = CFrame.new(position) * CFrame.Angles(0, random:NextNumber() * 6.28, 0),
				grounded = random:NextNumber() > 0.3,
			}
		end
		return rows
	end,
})

--[[
	6. String-heavy documents. Low-cardinality tags and repeated authors, which
	is the dictionary case, plus free text that cannot be dictionaried at all.
]]
table.insert(datasets, {
	name = "string documents",
	note = "dictionary + free text",
	build = function(seed: number)
		local random = Random.new(seed)
		local AUTHORS = {}
		for index = 1, 50 do
			AUTHORS[index] = "author_" .. index
		end
		local TAGS = { "news", "sport", "tech", "food", "travel", "music", "film", "science" }
		local WORDS = {
			"the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
			"lorem", "ipsum", "dolor", "sit", "amet", "consectetur",
		}
		local rows = table.create(12000)
		for index = 1, 12000 do
			local words = {}
			for slot = 1, random:NextInteger(8, 30) do
				words[slot] = WORDS[random:NextInteger(1, #WORDS)]
			end
			local tags = {}
			for slot = 1, random:NextInteger(1, 4) do
				tags[slot] = TAGS[random:NextInteger(1, #TAGS)]
			end
			rows[index] = {
				id = index,
				author = AUTHORS[random:NextInteger(1, #AUTHORS)],
				title = "Document number " .. index,
				body = table.concat(words, " "),
				tags = tags,
				published = random:NextNumber() > 0.25,
			}
		end
		return rows
	end,
})

--[[
	7. Sparse optional records. Most fields absent on most rows, which is the
	optional-column form under real pressure -- a schema records which columns
	are optional, and a batch whose presence pattern differs from the sample is
	where a derived-elsewhere schema is most likely to fall back.
]]
table.insert(datasets, {
	name = "sparse optionals",
	note = "most fields absent per row",
	build = function(seed: number)
		local random = Random.new(seed)
		local rows = table.create(15000)
		for index = 1, 15000 do
			local row: { [string]: any } = { id = index }
			for column = 1, 20 do
				-- Present on roughly a fifth of rows.
				if random:NextNumber() > 0.8 then
					row["opt" .. column] = random:NextInteger(1, 1000)
				end
			end
			rows[index] = row
		end
		return rows
	end,
})

--[[
	8. Deeply nested trees. Recursion rather than columns: the columnar path has
	nothing to grip, so this measures the plain adaptive walk against a schema
	that can record almost nothing. Expected to be the row where a schema buys
	least, and that is worth showing.
]]
table.insert(datasets, {
	name = "deep nested trees",
	note = "recursive, non-columnar",
	build = function(seed: number)
		local random = Random.new(seed)
		local function node(depth: number): any
			if depth <= 0 then
				return random:NextInteger(1, 10000)
			end
			local branch: { [string]: any } = {
				label = "n" .. random:NextInteger(1, 200),
				weight = random:NextNumber() * 100,
			}
			for slot = 1, random:NextInteger(2, 4) do
				branch["child" .. slot] = node(depth - 1)
			end
			return branch
		end
		local roots = table.create(700)
		for index = 1, 700 do
			roots[index] = node(5)
		end
		return roots
	end,
})

--[[
	9. Large numeric matrix. A single homogeneous block of floats -- no keys, no
	structure, nothing to discover. The floor case: whatever a schema saves here
	is the fixed overhead of discovery, not per-column work.
]]
table.insert(datasets, {
	name = "numeric matrix",
	note = "homogeneous float block",
	build = function(seed: number)
		local random = Random.new(seed)
		local rows = table.create(1200)
		for index = 1, 1200 do
			local row = table.create(200)
			for column = 1, 200 do
				row[column] = random:NextNumber() * 1000 - 500
			end
			rows[index] = row
		end
		return rows
	end,
})

--[[
	10. Enum-ish categorical grid. Every column low-cardinality, which should be
	dictionaried end to end -- the shape where recorded forms and discovered
	ones ought to agree exactly.
]]
table.insert(datasets, {
	name = "categorical grid",
	note = "all low-cardinality strings",
	build = function(seed: number)
		local random = Random.new(seed)
		local LEVELS = { "low", "medium", "high", "critical" }
		local STATES = { "idle", "running", "stopped", "failed", "queued" }
		local ZONES = { "north", "south", "east", "west" }
		local rows = table.create(20000)
		for index = 1, 20000 do
			rows[index] = {
				id = index,
				level = LEVELS[random:NextInteger(1, #LEVELS)],
				state = STATES[random:NextInteger(1, #STATES)],
				zone = ZONES[random:NextInteger(1, #ZONES)],
				retries = random:NextInteger(0, 5),
				ok = random:NextNumber() > 0.15,
			}
		end
		return rows
	end,
})

--[[
	The three on-disk fixtures. Fixed tables, so `sample` is not measurable --
	but they are real data the library is expected to handle, and Variant1 in
	particular is a heterogeneous grab-bag with holes, which nothing generated
	above resembles.
]]
for _, entry in {
	{ module = "Variant1", name = "fixture: mixed bag", note = "heterogeneous, sparse array" },
	{ module = "Variant2", name = "fixture: sales rows", note = "clean record array" },
	{ module = "Variant3", name = "fixture: nested recs", note = "deep heterogeneous" },
} do
	local moduleName = entry.module
	table.insert(datasets, {
		name = entry.name,
		note = entry.note,
		fixture = true,
		build = function(_seed: number)
			return require(RS.Zzzz.DataTests[moduleName])
		end,
	})
end

-- Run ------------------------------------------------------------------------

--[[
	`REPEATS` is the number of timed attempts each measurement takes, of which
	the fastest is kept. Three is enough to discard a collector pause without
	making the whole run take minutes.
]]
local REPEATS = 3

local function pct(from: number, to: number): string
	if from == 0 then
		return "--"
	end
	return string.format("%+.1f%%", (to - from) / from * 100)
end

--[[
	Wrapped in a function rather than run at require time: a ModuleScript caches
	its result, so a top-level run would report nothing on the second call.
]]
local function run(): boolean

local lines = {}

table.insert(lines, "Zzzz -- schema vs adaptive, ten shapes")
table.insert(lines, string.format(
	"  options: StructureCache, BitPack, Columnar   |   best of %d timed runs",
	REPEATS
))
table.insert(lines, "")
table.insert(lines, string.format(
	"  %-20s %9s %10s %10s %10s %8s %8s %9s",
	"dataset", "values", "adaptive", "schema", "sample", "bytes", "b/self", "b/sample"
))
table.insert(lines, string.format(
	"  %-20s %9s %10s %10s %10s %8s %8s %9s",
	"", "", "encode", "self", "batch", "adaptive", "", ""
))
table.insert(lines, string.rep("-", 98))

local failures = {}
local summary = {}

for _, dataset in datasets do
	local payload = dataset.build(1000)
	local values = countValues(payload)

	local zzzz = Zzzz.new(OPTIONS)

	-- Adaptive: discover everything, every time.
	local adaptiveMs, packet = timeBest(REPEATS, function()
		return zzzz:Serialize(payload)
	end)
	local adaptiveBytes = buffer.len(packet)

	-- Round-trip the adaptive packet before believing any of its numbers.
	local decoded = zzzz:Deserialize(packet)
	local ok, why = deepEqual(payload, decoded, dataset.name)
	if not ok then
		table.insert(failures, string.format("%s: adaptive round trip -- %s", dataset.name, why))
	end

	--[[
		Schema, self: derive on this payload, encode this payload. Derivation is
		timed separately -- it is paid once and amortised, so folding it into the
		encode figure would describe a use nobody makes.
	]]
	local deriveMs, schema = timeBest(1, function()
		return Zzzz.schema(payload, OPTIONS)
	end)

	local selfMs, selfPacket = timeBest(REPEATS, function()
		return schema:Encode(payload)
	end)
	local selfBytes = buffer.len(selfPacket)

	local selfDecoded = schema:Decode(selfPacket)
	local selfOk, selfWhy = deepEqual(payload, selfDecoded, dataset.name)
	if not selfOk then
		table.insert(failures, string.format("%s: schema(self) round trip -- %s", dataset.name, selfWhy))
	end

	--[[
		Schema, sample: derive on one batch, encode a different one. The real
		use, and the one that can miss.
	]]
	local sampleText, sampleBytesText = "--", "--"
	local sampleMs: number? = nil
	local sampleBytes: number? = nil

	if not dataset.fixture then
		local other = dataset.build(2000)
		local otherValues = countValues(other)
		local sampleSchema = Zzzz.schema(payload, OPTIONS)

		local encodeOk, encodeErr = pcall(function()
			local ms, sPacket = timeBest(REPEATS, function()
				return sampleSchema:Encode(other)
			end)
			sampleMs = ms
			sampleBytes = buffer.len(sPacket)

			local sDecoded = sampleSchema:Decode(sPacket)
			local dOk, dWhy = deepEqual(other, sDecoded, dataset.name)
			if not dOk then
				table.insert(failures, string.format("%s: schema(sample) round trip -- %s", dataset.name, dWhy))
			end
		end)

		if not encodeOk then
			--[[
				A schema that refuses a value outside its recorded plan is
				behaving as documented -- it errors rather than truncating. That
				is a result, not a crash, so it is reported in the row.
			]]
			sampleText = "REFUSED"
			sampleBytesText = "--"
			table.insert(summary, string.format(
				"  %s -- schema derived on one batch refused another: %s",
				dataset.name,
				tostring(encodeErr):sub(1, 120)
			))
		else
			--[[
				The two batches have different value counts, so bytes are
				compared per value rather than absolutely -- otherwise a batch
				that happened to be larger would read as a schema penalty.
			]]
			local adaptivePerValue = adaptiveBytes / values
			local samplePerValue = (sampleBytes :: number) / otherValues
			sampleText = string.format("%.2fms", sampleMs :: number)
			sampleBytesText = pct(adaptivePerValue, samplePerValue)
		end
	end

	table.insert(lines, string.format(
		"  %-20s %9s %8.2fms %8.2fms %10s %8s %8s %9s",
		dataset.name,
		comma(values),
		adaptiveMs,
		selfMs,
		sampleText,
		comma(adaptiveBytes),
		pct(adaptiveBytes, selfBytes),
		sampleBytesText
	))

	table.insert(summary, string.format(
		"  %-20s %-28s  %.2fx faster encode, derive %.1fms, saved schema %s B",
		dataset.name,
		dataset.note,
		if selfMs > 0 then adaptiveMs / selfMs else 0,
		deriveMs,
		(function()
			local saveOk, stored = pcall(function()
				return schema:Save()
			end)
			return if saveOk then comma(buffer.len(stored)) else "n/a"
		end)()
	))
end

table.insert(lines, "")
table.insert(lines, "  per dataset")
for _, line in summary do
	table.insert(lines, line)
end

table.insert(lines, "")
if #failures == 0 then
	table.insert(lines, "  all round trips verified (deep structural compare, both directions)")
else
	table.insert(lines, "  ROUND TRIP FAILURES")
	for _, line in failures do
		table.insert(lines, "    " .. line)
	end
end

print(table.concat(lines, "\n"))
return #failures == 0

end

return setmetatable({ run = run }, { __call = function()
	return run()
end })
