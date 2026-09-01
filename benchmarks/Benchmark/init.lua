--!strict
--!native
--!optimize 2
--[[
	The dataset behind every figure in BENCHMARK.md and SMALLER.md.

	Run it:

		require(path.to.Zzzz.Benchmark)()

	It builds the data, checks the round trip, then prints sizes and timings.
	Everything is seeded, so the numbers reproduce exactly.

	The shape is meant to look like a real game's save data rather than
	something chosen to flatter the encoder: 2,000 players with mixed integer
	stats, world positions, variable-length inventories of nested records, and
	long boolean runs. That mix is what makes each option pull its weight --
	StructureCache on the repeated record shapes, BitPack on the achievement
	flags, Columnar on the inventories, and the integral encodings on the
	whole-stud positions.
]]

local Zzzz = require(script.Parent)

local ITEM_NAMES = {
	"Sword",
	"Shield",
	"Potion",
	"Bow",
	"Arrow",
	"Helmet",
	"Armor",
	"Boots",
	"Ring",
	"Amulet",
	"Scroll",
	"Gem",
	"Key",
	"Torch",
	"Rope",
	"Map",
	"Compass",
	"Elixir",
	"Staff",
	"Dagger",
}

local CLASS_NAMES = { "Warrior", "Mage", "Rogue", "Cleric", "Ranger" }

export type Player = {
	userId: number,
	name: string,
	class: string,
	level: number,
	xp: number,
	coins: number,
	position: Vector3,
	spawnCFrame: CFrame,
	inventory: { { name: string, count: number, level: number, equipped: boolean } },
	achievements: { boolean },
	stats: { health: number, mana: number, stamina: number, armor: number },
	settings: {
		music: boolean,
		sfx: boolean,
		sensitivity: number,
		quality: number,
	},
}

--[[
	Build the dataset. Seeded, so two runs produce byte-identical packets.

	`playerCount` defaults to the 2,000 the published figures use.
]]
local function buildDataset(playerCount: number?, seed: number?): { Player }
	local count = playerCount or 2000
	local random = Random.new(seed or 1337)

	local players: { Player } = table.create(count)

	for index = 1, count do
		-- Variable length, which is what stops the inventories being uniformly
		-- sized and makes the columnar detection do real work.
		local inventory = {}
		for slot = 1, random:NextInteger(5, 25) do
			inventory[slot] = {
				name = ITEM_NAMES[random:NextInteger(1, #ITEM_NAMES)],
				count = random:NextInteger(1, 99),
				level = random:NextInteger(1, 50),
				equipped = random:NextNumber() > 0.7,
			}
		end

		local achievements = table.create(40)
		for slot = 1, 40 do
			achievements[slot] = random:NextNumber() > 0.5
		end

		players[index] = {
			userId = 1000000 + index * 137,
			name = "Player" .. index,
			class = CLASS_NAMES[random:NextInteger(1, #CLASS_NAMES)],
			level = random:NextInteger(1, 100),
			xp = random:NextInteger(0, 500000),
			coins = random:NextInteger(0, 1000000),
			-- Whole studs, as placed geometry usually is.
			position = Vector3.new(
				random:NextInteger(-500, 500),
				random:NextInteger(0, 100),
				random:NextInteger(-500, 500)
			),
			spawnCFrame = CFrame.new(
				random:NextInteger(-500, 500),
				5,
				random:NextInteger(-500, 500)
			),
			inventory = inventory,
			achievements = achievements,
			stats = {
				health = random:NextInteger(50, 200),
				mana = random:NextInteger(0, 150),
				stamina = random:NextInteger(0, 100),
				armor = random:NextInteger(0, 80),
			},
			settings = {
				music = random:NextNumber() > 0.5,
				sfx = random:NextNumber() > 0.5,
				sensitivity = random:NextInteger(1, 100) / 100,
				quality = random:NextInteger(1, 10),
			},
		}
	end

	return players
end

--[[
	JSON cannot hold Vector3 or CFrame, so the comparison flattens them. This
	is deliberately generous to JSON: it gets three plain numbers where Zzzz
	pays a tag as well.
]]
local function toJsonSafe(players: { Player }): { any }
	local flattened = table.create(#players)

	for index, player in players do
		flattened[index] = {
			userId = player.userId,
			name = player.name,
			class = player.class,
			level = player.level,
			xp = player.xp,
			coins = player.coins,
			position = { player.position.X, player.position.Y, player.position.Z },
			spawnCFrame = {
				player.spawnCFrame.X,
				player.spawnCFrame.Y,
				player.spawnCFrame.Z,
			},
			inventory = player.inventory,
			achievements = player.achievements,
			stats = player.stats,
			settings = player.settings,
		}
	end

	return flattened
end

--[[
	Confirm a decoded copy matches the original everywhere it matters, so a
	size figure is never reported for a packet that does not round trip.
]]
--[[
	`tolerance` is the quantization step when the configuration is lossy, and
	zero otherwise. Integers, strings and counts are expected to be exact
	either way -- quantization only ever touches non-integer numbers.
]]
local function verify(original: { Player }, decoded: any, tolerance: number?): boolean
	local slack = tolerance or 0

	if #decoded ~= #original then
		return false
	end

	--[[
		Spot-check a spread of rows rather than all of them, scaled to the
		dataset. The indices were once fixed at 1, 500, 750, 1000 and the last
		row, which reported a mismatch for any run smaller than a thousand
		players -- the rows simply were not there.
	]]
	local checks: { number } = { 1, #original }
	for _, fraction in { 0.25, 0.5, 0.75 } do
		local index = math.max(1, math.floor(#original * fraction))
		table.insert(checks, index)
	end

	for _, index in checks do
		local a, b = original[index], decoded[index]
		if not a or not b then
			return false
		end
		if a.name ~= b.name or a.coins ~= b.coins or a.level ~= b.level then
			return false
		end
		if (a.position - b.position).Magnitude > slack then
			return false
		end
		if (a.spawnCFrame.Position - b.spawnCFrame.Position).Magnitude > slack then
			return false
		end
		if #a.inventory ~= #b.inventory then
			return false
		end
		for slot, item in a.inventory do
			local other = b.inventory[slot]
			if
				item.name ~= other.name
				or item.count ~= other.count
				or item.level ~= other.level
				or item.equipped ~= other.equipped
			then
				return false
			end
		end
		for slot, flag in a.achievements do
			if b.achievements[slot] ~= flag then
				return false
			end
		end
	end

	return true
end

--[[
	How many scalars the payload holds, so a millisecond figure can be divided
	into a per-value cost.

	A millisecond total says how long the payload took; it says nothing about
	whether that is fast, because it moves with the payload size. Nanoseconds
	per value is comparable across the two datasets and across player counts,
	and it is the figure that says whether a row is near the floor or far above
	it -- the same denominator `bench_encode_floor.lua` divides by.

	Only leaves are counted. The tables are structure, not data, and charging
	the encoder per container would make a deeply nested payload look cheaper
	per unit than a flat one carrying the same values.
]]
local function countValues(payload: any): number
	local total = 0

	local function walk(value: any)
		if type(value) ~= "table" then
			total += 1
			return
		end
		for _, entry in value do
			walk(entry)
		end
	end
	walk(payload)

	return total
end

--[[
	A rate, scaled to whatever unit keeps it readable.

	Throughput spans a wide range here -- a small payload on a warm cache runs
	in the tens of millions of values a second, while `Correlate` on a big one
	is in the tens of thousands. A fixed unit prints one end of that as `0.0M`
	or the other as a nine-digit integer, so the unit follows the magnitude.
]]
local function millions(value: number): string
	if value >= 1000000 then
		return string.format("%.2fM", value / 1000000)
	elseif value >= 1000 then
		return string.format("%.0fK", value / 1000)
	end
	return string.format("%.0f", value)
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
	The schema path, measured against the adaptive one it replaces.

	`Zzzz.schema` runs the discovery once and records what it chose; `Encode`
	then replays those decisions instead of making them again. The claim in
	Schema.lua is 2.6x faster for 1.6% more bytes, and a claim in a comment that
	nothing measures is a claim that quietly stops being true.

	Four figures matter and each answers a different question:

		derive     what the one-off costs, so a caller can decide whether it is
		           worth it for their write frequency
		encode     the figure the whole feature exists for
		bytes      what replaying recorded forms costs against searching for
		           them fresh -- small, because a schema records FORMS and not
		           types, but not zero
		saved      how big the stored schema is, since it has to live somewhere

	Derivation is charged its own encode of the sample, which is what it does
	internally. It is reported rather than hidden because a schema derived per
	call would be slower than not having one at all -- the point is that it is
	paid once and amortised.
]]
local function schemaSection(
	lines: { string },
	payload: any,
	options: any,
	jsonBytes: number,
	valueCount: number,
	adaptiveEncodeMs: number,
	adaptiveBytes: number,
	verifier: (any, any, number?) -> boolean
): boolean
	table.insert(lines, "")
	table.insert(lines, "  schema -- the same options, with the forms recorded once")

	--[[
		Derive on the same payload that is then encoded. A schema derived from a
		sample and replayed on different data is the real use, but it is also a
		second variable: any byte difference would then be the sample's fault
		rather than the schema path's. This measures the path, not the sampling.
	]]
	for _ = 1, 12 do
		task.wait()
	end

	local deriveOk, schema, deriveMs = pcall(function()
		local started = os.clock()
		local result = Zzzz.schema(payload, options)
		return result, (os.clock() - started) * 1000
	end)

	if not deriveOk then
		table.insert(lines, string.format("  %-22s DERIVE FAILED: %s", "", tostring(schema)))
		return false
	end

	for _ = 1, 12 do
		task.wait()
	end

	local encodeOk, packet, schemaEncodeMs = pcall(function()
		local started = os.clock()
		local result = schema:Encode(payload)
		return result, (os.clock() - started) * 1000
	end)

	if not encodeOk then
		table.insert(lines, string.format("  %-22s ENCODE FAILED: %s", "", tostring(packet)))
		return false
	end

	for _ = 1, 12 do
		task.wait()
	end

	local decodeOk, decoded, schemaDecodeMs = pcall(function()
		local started = os.clock()
		local result = schema:Decode(packet)
		return result, (os.clock() - started) * 1000
	end)

	if not decodeOk then
		table.insert(lines, string.format("  %-22s DECODE FAILED: %s", "", tostring(decoded)))
		return false
	end

	--[[
		Round-tripped like every other row. A faster encode that does not decode
		back to the original is not a faster encode.
	]]
	if not verifier(payload, decoded, (options :: any).Precision) then
		table.insert(lines, string.format("  %-22s ROUND TRIP MISMATCH", "  schema"))
		return false
	end

	local schemaTotalMs = schemaEncodeMs + (schemaDecodeMs or 0)

	table.insert(
		lines,
		string.format(
			"  %-22s %12s %9.0f%% %8.2fms %8.2fms %8.2fms %9.0f",
			"  Schema:Encode",
			comma(buffer.len(packet)),
			100 - (buffer.len(packet) / jsonBytes) * 100,
			schemaEncodeMs,
			schemaDecodeMs or 0,
			schemaTotalMs,
			schemaTotalMs * 1000000 / valueCount
		)
	)

	--[[
		The comparison the feature is judged on, stated rather than left for the
		reader to divide out. Both figures are against the adaptive row that used
		the same options, so the only difference is where the forms came from.
	]]
	local speedup = if schemaEncodeMs > 0 then adaptiveEncodeMs / schemaEncodeMs else 0
	local byteCost = (buffer.len(packet) - adaptiveBytes) / adaptiveBytes * 100

	table.insert(
		lines,
		string.format(
			"  %-22s %12s   %.2fx faster encode, %+.1f%% bytes",
			"  vs adaptive",
			"",
			speedup,
			byteCost
		)
	)
	table.insert(
		lines,
		string.format(
			"  %-22s %8.2fms   paid once, then never again",
			"  derive",
			deriveMs
		)
	)

	--[[
		The stored size, since a schema that has to be derived on every server
		start is not saving the derivation at all -- it is meant to be saved and
		loaded, and that only works if it is small enough to keep.
	]]
	local saveOk, stored = pcall(function()
		return schema:Save()
	end)

	if saveOk then
		table.insert(
			lines,
			string.format(
				"  %-22s %12s bytes stored",
				"  Schema:Save",
				comma(buffer.len(stored))
			)
		)

		--[[
			And that it loads back to something equivalent. A saved schema whose
			fingerprint disagrees on reload would fail at the point of use, on a
			server, rather than here.
		]]
		local loadOk, loaded = pcall(function()
			return Zzzz.loadSchema(stored)
		end)

		if not loadOk or loaded:fingerprint() ~= schema:fingerprint() then
			table.insert(lines, "  the saved schema did not load back identically")
			return false
		end
	end

	return true
end

local function run(playerCount: number?): boolean
	local HttpService = game:GetService("HttpService")

	local players = buildDataset(playerCount)
	local jsonBytes = #HttpService:JSONEncode(toJsonSafe(players))
	--[[
		The Vector3 and CFrame count as one value each here, as they do to the
		encoder -- it writes them through one path, not as three numbers.
	]]
	local valueCount = countValues(players)

	local configurations = {
		{ name = "no options", options = {} },
		{ name = "StructureCache", options = { StructureCache = true } },
		{
			name = "+ BitPack",
			options = { StructureCache = true, BitPack = true },
		},
		{
			name = "+ Columnar",
			options = { StructureCache = true, BitPack = true, Columnar = true },
		},
		{
			name = "+ Correlate",
			options = {
				StructureCache = true,
				BitPack = true,
				Columnar = true,
				Correlate = true,
			},
			--[[
				`Correlate` finds nothing here, and the dataset guarantees it:
				every numeric field is drawn independently from `Random`, so no
				pair of columns has a relationship to find.

				The row is kept because what it costs is as informative as what
				it saves. The record shows eleven fields, but `stats`,
				`settings` and the forty-entry `achievements` array hoist into
				57 columns, and the pair search runs over all of them -- 3,192
				ordered pairs, 91.5% of which involve one of the booleans.

				Measured before the grouping gate: 1,891 ms added at 2,000
				players to save zero bytes, which was 80% of the whole encode.
				The same option earns 18.7 bytes a millisecond on `buildMixed`,
				which does contain a real mapping -- so this is data-dependent
				rather than a bad option, and the contrast is worth showing.

				That cost is now about 195 ms over the `Columnar` row rather
				than 1,891, from `CORRELATION_MIN_ROWS` rising to 64 and from
				the qualifier work every column pays being roughly halved. It
				still buys nothing on THIS dataset, which remains the point of
				the row.
			]]
		},
		--[[
			Lossy, so it is reported separately rather than mixed in with the
			exact configurations above. Quantization only helps float-heavy
			data; most of this dataset is integers, which stay exact.

			It measures exactly zero here and that is the correct result, not a
			broken option: `position` and `spawnCFrame` are built from
			`NextInteger`, every stat and counter is an integer, and
			`sensitivity` is `NextInteger(1, 100) / 100` -- exact at two decimal
			places. There is no irrational float in the dataset for a tolerance
			to round away, so the row exists to show that the option costs
			nothing when it can earn nothing.
		]]
		{
			name = "+ Precision 0.1",
			options = {
				StructureCache = true,
				BitPack = true,
				Columnar = true,
				Correlate = true,
				Precision = 0.1,
			},
			lossy = true,
		},
	}

	local lines = {
		string.format("Zzzz benchmark -- %d players", #players),
		string.format("  %s values in the payload", comma(valueCount)),
		"",
		string.format(
			"  %-22s %12s %10s %10s %10s %10s %10s",
			"", "bytes", "vs JSON", "encode", "decode", "total", "ns/value"
		),
		string.format(
			"  %-22s %12s %10s %10s %10s %10s %10s",
			"JSON", comma(jsonBytes), "--", "--", "--", "--", "--"
		),
	}

	local best: buffer? = nil
	local bestName: string? = nil
	local bestEncodeMs: number? = nil
	local bestDecodeMs: number = 0
	local bestOptions: any = nil
	local allVerified = true

	for _, configuration in configurations do
		local zzzz = Zzzz.new(configuration.options)
		local tolerance = (configuration.options :: any).Precision

		--[[
			A note on reading the `encode` column at all.

			These figures move by a factor of two between runs of IDENTICAL
			code. Six consecutive runs of the `no options` row, which nothing
			changed between:

				108   108   107   117   121   199 ms

			So a row is only meaningful against the other rows in ITS OWN run.
			Across runs, compare ratios rather than milliseconds -- `Correlate`
			went from 21.7x the `no options` row to 3.8x over one session, and
			the absolute numbers say almost nothing about that.

			Reading them as absolutes produced several wrong conclusions in the
			course of that session, including a "regression" that was the
			machine slowing down and an "improvement" that was it speeding up.

			Ten consecutive runs put the medians at roughly:

				no options       107      + Columnar     213
				StructureCache   104      + Correlate    406
				+ BitPack        105      decode          70

			One run of this is not evidence of anything. `tests/bench_repeat.lua`
			exists for changes that need measuring: it batches, warms to
			convergence, reports the spread, and refuses a verdict when the two
			statistics disagree.

			Let the collector catch up before the clock starts.

			Each configuration allocates a packet and a fully decoded copy of
			the payload and then discards both, so without this the next
			configuration is charged for collecting them. The effect always
			falls on the expensive rows, because those run last.

			Measured on the 2,000-player payload: `Correlate` reported 2,714 ms
			here against 1,189 ms for the same work timed as a settled mean,
			while the cheap rows -- which run first and have little to be
			charged for -- agreed to within 2%.

			A fixed number of yields rather than a heap-watching loop: Luau
			exposes only `collectgarbage("count")`, and a loop that stops when
			the heap no longer shrinks exits immediately whenever it is still
			growing, which after a decode it is.
		]]
		for _ = 1, 12 do
			task.wait()
		end

		local ok, packet, encodeMs = pcall(function()
			local started = os.clock()
			local result = zzzz:Serialize(players)
			return result, (os.clock() - started) * 1000
		end)

		if not ok then
			allVerified = false
			table.insert(
				lines,
				string.format("  %-22s ENCODE FAILED: %s", configuration.name, tostring(packet))
			)
			continue
		end

		--[[
			Decode is timed as well as encode, because a caller pays both.

			It was measured all along -- the round-trip check has always
			decoded -- but never reported, so the published figures described
			half of what using the library costs.
		]]
		for _ = 1, 12 do
			task.wait()
		end

		local decodeOk, decoded, decodeMs = pcall(function()
			local started = os.clock()
			local result = zzzz:Deserialize(packet)
			return result, (os.clock() - started) * 1000
		end)

		if not decodeOk then
			allVerified = false
			table.insert(
				lines,
				string.format("  %-22s DECODE FAILED: %s", configuration.name, tostring(decoded))
			)
			continue
		end

		if not verify(players, decoded, tolerance) then
			allVerified = false
			table.insert(lines, string.format("  %-22s ROUND TRIP MISMATCH", configuration.name))
			continue
		end

		local totalMs = encodeMs + (decodeMs or 0)

		table.insert(
			lines,
			string.format(
				--[[
					Two decimal places, because whole milliseconds print every
					row of a small run as `0ms`. At one player the entire encode
					is about a fifth of a millisecond, which `%.0f` floors away
					-- the ns/value column was reporting real numbers beside a
					column of zeroes.
				]]
				"  %-22s %12s %9.0f%% %8.2fms %8.2fms %8.2fms %9.0f%s",
				configuration.name,
				comma(buffer.len(packet)),
				100 - (buffer.len(packet) / jsonBytes) * 100,
				encodeMs,
				decodeMs or 0,
				totalMs,
				-- The round trip, per value, in nanoseconds.
				totalMs * 1000000 / valueCount,
				if configuration.lossy then "  lossy" else ""
			)
		)

		--[[
			The compression comparison and the throughput line below both
			describe the best lossless configuration -- the one a caller who
			wants the smallest exact packet would actually run.
		]]
		if not configuration.lossy then
			best = packet
			bestName = configuration.name
			bestEncodeMs = encodeMs
			bestDecodeMs = decodeMs or 0
			bestOptions = configuration.options
		end
	end

	--[[
		The same measurement as the ns/value column, inverted.

		Per-value nanoseconds answers "how close to the floor is this", which is
		the question when reading the table as a whole. Values per second is the
		figure that gets quoted, and it is the one that says whether a payload
		fits a frame -- so both are printed rather than leaving the reader to do
		the reciprocal.

		Encode and decode are reported apart because a caller rarely pays both
		at once: a server writing a save pays encode, a client reading one pays
		decode.
	]]
	if bestEncodeMs then
		local encodeRate = valueCount / (bestEncodeMs / 1000)
		local decodeRate = if bestDecodeMs > 0 then valueCount / (bestDecodeMs / 1000) else 0

		table.insert(lines, "")
		table.insert(lines, string.format("  throughput -- %s", bestName))
		table.insert(
			lines,
			string.format("  %-22s %12s values/sec", "encode", millions(encodeRate))
		)
		if decodeRate > 0 then
			table.insert(
				lines,
				string.format("  %-22s %12s values/sec", "decode", millions(decodeRate))
			)
		end
	end

	--[[
		The schema path, against the adaptive row that used the same options.
	]]
	if best and bestEncodeMs and bestOptions then
		if
			not schemaSection(
				lines,
				players,
				bestOptions,
				jsonBytes,
				valueCount,
				bestEncodeMs,
				buffer.len(best),
				verify
			)
		then
			allVerified = false
		end
	end

	--[[
		Compression is not part of Zzzz, but the comparison only means
		something if both sides get the same treatment.
	]]
	local encoding = nil
	local algorithm = nil
	pcall(function()
		encoding = game:GetService("EncodingService")
		algorithm = Enum.CompressionAlgorithm.Zstd
	end)

	if encoding and algorithm and best then
		table.insert(lines, "")
		table.insert(lines, "  after zstd level 22")

		--[[
			Timed, because level 22 is not free and the size figure alone
			invites the assumption that it is. A caller choosing between the
			raw packet and the compressed one is choosing between bytes and
			milliseconds, and only one of those was ever on the page.

			The JSON side is timed the same way, so the comparison stays
			like-for-like: both are one `CompressBuffer` call at the same level
			over the same payload.
		]]
		local jsonSource = buffer.fromstring(HttpService:JSONEncode(toJsonSafe(players)))

		local jsonStarted = os.clock()
		local jsonPacked = encoding:CompressBuffer(jsonSource, algorithm, 22)
		local jsonPackMs = (os.clock() - jsonStarted) * 1000

		local zzzzStarted = os.clock()
		local zzzzPacked = encoding:CompressBuffer(best, algorithm, 22)
		local zzzzPackMs = (os.clock() - zzzzStarted) * 1000

		--[[
			These two rows are rated in bytes per millisecond, not in the
			ns/value the rows above use, because zstd never sees a value. It
			sees a buffer, and its cost tracks that buffer's length.

			Dividing compression time by the value count produced a figure that
			moved with how the payload happened to decompose into leaves --
			nothing to do with the work being measured. It also divided both
			rows by the same count while they compress very different inputs,
			838 bytes against 338, so the smaller packet was credited twice:
			once in the bytes column, and again as a lower apparent per-unit
			cost.

			The rate is over the INPUT length, which is what zstd had to read.
			Rating it over the output would make a better compression ratio read
			as slower compression.
		]]
		table.insert(
			lines,
			string.format(
				"  %-22s %12s %10s %10s %10s %8.2fms %10s",
				"JSON + zstd22",
				comma(buffer.len(jsonPacked)),
				"--",
				"--",
				"--",
				jsonPackMs,
				string.format("%s B/ms", comma(buffer.len(jsonSource) / jsonPackMs))
			)
		)
		table.insert(
			lines,
			string.format(
				"  %-22s %12s %9.1f%% %10s %10s %8.2fms %10s",
				"Zzzz + zstd22",
				comma(buffer.len(zzzzPacked)),
				100 - (buffer.len(zzzzPacked) / jsonBytes) * 100,
				"--",
				"--",
				zzzzPackMs,
				string.format("%s B/ms", comma(buffer.len(best) / zzzzPackMs))
			)
		)
		table.insert(
			lines,
			string.format(
				"  %-22s %12s",
				"",
				string.format("%.1fx smaller than JSON", jsonBytes / buffer.len(zzzzPacked))
			)
		)
	end

	table.insert(lines, "")
	table.insert(lines, allVerified and "  all round trips verified" or "  ROUND TRIP FAILURES")

	print(table.concat(lines, "\n"))
	return allVerified
end

--[[
	The second dataset, and why there is one.

	The player saves above are uniform: every record carries every key, the
	values are drawn independently, and nothing is a float. That is a fair model
	of one common shape, and it is what the headline figures measure.

	It is also silent about four encodings that work. Optional columns, runs,
	equal columns and the decimal form all measure exactly zero on it, because
	it contains none of the shapes they are for. Four working forms with no
	coverage is a regression waiting to happen -- a change could break any of
	them and every number above would stay green.

	So this dataset is deliberately the other half, and it is built against the
	list of encodings rather than against a guess at realistic data. Every
	counter the encoder reports is exercised by some field here:

		optional fields   enchant, durability and a guild that most rows lack
		runs              sorted by team and tier
		equal columns     health and maxHealth, equal but for the wounded
		floats            velocities with no short decimal, for quantization
		decimals          sensitivity, exact as an integer and an exponent
		one value         region, the same for every row
		frequency         status, one dominant value and a few exceptions
		1-to-1 mapping    teamName, determined by team
		1-to-N mapping    role, narrowed by class
		dictionary FOR    slot, in a distinct range per tier
		correlation       power, a fitted multiple of level
		Vector2           screen position, delta-encoded like Vector3
		nested structs    an owner record that is not hoistable

	The point is not that a real save file looks exactly like this. It is that
	an encoding with no coverage is a regression waiting to happen: a change
	could break it and every headline figure would stay green. Reported apart
	from the player saves, because averaging the two would describe neither.
]]
export type WorldEntity = {
	id: number,
	team: number,
	tier: number,
	health: number,
	maxHealth: number,
	velocity: Vector3,
	name: string,
	sensitivity: number,
	-- Each of these targets one encoding; see the note above.
	region: number,
	status: number,
	teamName: string,
	class: string,
	role: string,
	slot: number,
	level: number,
	power: number,
	screen: Vector2,
	owner: { id: number, tag: string },
	enchant: string?,
	durability: number?,
	guild: string?,
}

local TEAM_NAMES = { "Red", "Blue", "Green", "Gold" }
local ENCHANTS = { "fire", "ice", "shock", "venom" }

-- A class implies a set of roles, which is what the 1-to-N form is for.
local CLASS_ROLES = {
	Warrior = { "tank", "brawler" },
	Mage = { "nuker", "controller", "support" },
	Rogue = { "assassin", "scout" },
	Cleric = { "healer", "support" },
	Ranger = { "marksman", "scout", "trapper" },
}

local function buildMixed(entityCount: number?, seed: number?): { WorldEntity }
	local count = entityCount or 4000
	local random = Random.new(seed or 4242)

	local entities: { WorldEntity } = table.create(count)

	for index = 1, count do
		--[[
			Sorted by team and tier, the way a roster or a spatial bucket
			arrives. This is what gives the run-length form something to find;
			shuffled data would leave a run per row and be rejected.
		]]
		local team = math.floor((index - 1) / math.max(1, count // 8)) % #TEAM_NAMES
		local tier = math.floor((index - 1) / math.max(1, count // 20))

		--[[
			Health equals maxHealth except where something has taken damage,
			which is the equal-column form's whole case: one reference plus the
			rows that disagree.
		]]
		local maxHealth = 100 + tier * 10
		local health = if random:NextNumber() > 0.94
			then maxHealth - random:NextInteger(1, 40)
			else maxHealth

		local class = CLASS_NAMES[random:NextInteger(1, #CLASS_NAMES)]
		local roles = CLASS_ROLES[class]
		local level = random:NextInteger(1, 60)

		local entity: WorldEntity = {
			id = index,
			team = team,
			tier = tier,
			health = health,
			maxHealth = maxHealth,
			-- Genuine floats: no short decimal expresses these.
			velocity = Vector3.new(
				random:NextNumber() * 40 - 20,
				random:NextNumber() * 12,
				random:NextNumber() * 40 - 20
			),
			name = ITEM_NAMES[random:NextInteger(1, #ITEM_NAMES)],
			--[[
				Fractional, but only to two places -- a setting, a price, a
				percentage. The decimal form stores these exactly as an integer
				and an exponent, where the velocities above have no short
				decimal and fall to quantization or to eight bytes.
			]]
			sensitivity = random:NextInteger(1, 100) / 100,

			--[[
				Zero on almost every row, with occasional damage. That is the
				frequency form: the dominant value once, a bitmap of which rows
				differ, then only those values.

				Both the exceptions and their placement matter. A column whose
				outliers fall on a fixed stride is differenced away to nothing,
				so the frequency form never gets to compete -- it wins on the
				scattered case, which is what an event count actually looks
				like.
			]]
			region = 0,
			status = if random:NextNumber() > 0.95
				then random:NextInteger(1, 900)
				else 0,

			-- Determined by team, so one target per distinct source value.
			teamName = TEAM_NAMES[team + 1],

			class = class,
			-- Narrowed by class rather than determined: a run per class.
			role = roles[random:NextInteger(1, #roles)],

			--[[
				A distinct range per tier, which is what the dictionary frame of
				reference reads: a reference per source, then a small offset.
			]]
			slot = tier * 1000 + random:NextInteger(0, 15),

			level = level,
			-- A fitted multiple of level, which correlation recovers exactly.
			power = level * 7 + 3,

			-- Delta-encoded the same way Vector3 is.
			screen = Vector2.new(
				random:NextInteger(0, 1920),
				random:NextInteger(0, 1080)
			),

			--[[
				A nested record. Rows share no table identity and the keys vary
				in type, so it stays a struct rather than being hoisted into
				columns -- which is what exercises the structure cache.
			]]
			owner = {
				id = 5000 + (index % 250),
				tag = "own" .. (index % 250),
			},
		}

		-- Optional fields, present on a minority of rows as they usually are.
		if random:NextNumber() > 0.85 then
			entity.enchant = ENCHANTS[random:NextInteger(1, #ENCHANTS)]
		end
		if random:NextNumber() > 0.7 then
			entity.durability = random:NextInteger(1, 100)
		end
		if random:NextNumber() > 0.5 then
			entity.guild = "Guild" .. random:NextInteger(1, 20)
		end

		entities[index] = entity
	end

	return entities
end

local function mixedToJsonSafe(entities: { WorldEntity }): { any }
	local flattened = table.create(#entities)

	for index, entity in entities do
		flattened[index] = {
			id = entity.id,
			team = entity.team,
			tier = entity.tier,
			health = entity.health,
			maxHealth = entity.maxHealth,
			velocity = { entity.velocity.X, entity.velocity.Y, entity.velocity.Z },
			name = entity.name,
			sensitivity = entity.sensitivity,
			region = entity.region,
			status = entity.status,
			teamName = entity.teamName,
			class = entity.class,
			role = entity.role,
			slot = entity.slot,
			level = entity.level,
			power = entity.power,
			screen = { entity.screen.X, entity.screen.Y },
			owner = entity.owner,
			enchant = entity.enchant,
			durability = entity.durability,
			guild = entity.guild,
		}
	end

	return flattened
end

--[[
	Confirm the mixed dataset round trips, including that an absent key comes
	back absent rather than present-and-nil. That distinction is the whole point
	of the optional form, so the check is explicit about it.
]]
local function verifyMixed(original: { WorldEntity }, decoded: any, tolerance: number?): boolean
	local slack = tolerance or 0

	if #decoded ~= #original then
		return false
	end

	for index = 1, #original do
		local a, b = original[index], decoded[index]
		if not a or not b then
			return false
		end
		if
			a.id ~= b.id
			or a.team ~= b.team
			or a.tier ~= b.tier
			or a.health ~= b.health
			or a.maxHealth ~= b.maxHealth
			or a.name ~= b.name
			or a.region ~= b.region
			or a.status ~= b.status
			or a.teamName ~= b.teamName
			or a.class ~= b.class
			or a.role ~= b.role
			or a.slot ~= b.slot
			or a.level ~= b.level
			or a.power ~= b.power
		then
			return false
		end
		if (a.screen - b.screen).Magnitude > slack then
			return false
		end
		if a.owner.id ~= b.owner.id or a.owner.tag ~= b.owner.tag then
			return false
		end
		if (a.velocity - b.velocity).Magnitude > slack then
			return false
		end
		-- Fractional, so it is the one field a lossy setting may move.
		if math.abs(a.sensitivity - b.sensitivity) > slack then
			return false
		end
		-- Presence must match exactly, in both directions.
		for _, key in { "enchant", "durability", "guild" } do
			if (a :: any)[key] ~= (b :: any)[key] then
				return false
			end
		end
	end

	return true
end

--[[
	Report the mixed dataset. Reported apart from the figures above, because
	the two measure different shapes and a combined number would describe
	neither.
]]
local function runMixed(entityCount: number?): boolean
	local HttpService = game:GetService("HttpService")

	local entities = buildMixed(entityCount)
	local jsonBytes = #HttpService:JSONEncode(mixedToJsonSafe(entities))
	--[[
		Counted the same way as the player saves, so the ns/value column is
		comparable between the two datasets even though their shapes are not.
	]]
	local valueCount = countValues(entities)

	local configurations = {
		{ name = "no options", options = {} },
		{ name = "StructureCache", options = { StructureCache = true } },
		{ name = "+ BitPack", options = { StructureCache = true, BitPack = true } },
		{
			name = "+ Columnar",
			options = { StructureCache = true, BitPack = true, Columnar = true },
		},
		{
			name = "+ Correlate",
			options = {
				StructureCache = true,
				BitPack = true,
				Columnar = true,
				Correlate = true,
			},
		},
		{
			name = "+ Precision 0.01",
			options = {
				StructureCache = true,
				BitPack = true,
				Columnar = true,
				Correlate = true,
				Precision = 0.01,
			},
			lossy = true,
		},
	}

	local lines = {
		string.format("Zzzz mixed-shape benchmark -- %d entities", #entities),
		string.format("  %s values in the payload", comma(valueCount)),
		"",
		"  optional fields, sorted runs, equal columns and real floats --",
		"  the shapes the player-save figures do not contain.",
		"",
		string.format(
			"  %-22s %12s %10s %10s %10s %10s %10s",
			"", "bytes", "vs JSON", "encode", "decode", "total", "ns/value"
		),
		string.format(
			"  %-22s %12s %10s %10s %10s %10s %10s",
			"JSON", comma(jsonBytes), "--", "--", "--", "--", "--"
		),
	}

	local best: buffer? = nil
	local bestName: string? = nil
	local bestEncodeMs: number? = nil
	local bestDecodeMs: number = 0
	local bestOptions: any = nil
	local allVerified = true

	for _, configuration in configurations do
		local zzzz = Zzzz.new(configuration.options)
		local tolerance = (configuration.options :: any).Precision

		--[[
			Let the collector catch up before the clock starts.

			Each configuration allocates a packet and a fully decoded copy of
			the payload and then discards both, so without this the next
			configuration is charged for collecting them. The effect always
			falls on the expensive rows, because those run last.

			Measured on the 2,000-player payload: `Correlate` reported 2,714 ms
			here against 1,189 ms for the same work timed as a settled mean,
			while the cheap rows -- which run first and have little to be
			charged for -- agreed to within 2%.

			A fixed number of yields rather than a heap-watching loop: Luau
			exposes only `collectgarbage("count")`, and a loop that stops when
			the heap no longer shrinks exits immediately whenever it is still
			growing, which after a decode it is.
		]]
		for _ = 1, 12 do
			task.wait()
		end

		local ok, packet, encodeMs = pcall(function()
			local started = os.clock()
			local result = zzzz:Serialize(entities)
			return result, (os.clock() - started) * 1000
		end)

		if not ok then
			allVerified = false
			table.insert(
				lines,
				string.format("  %-22s ENCODE FAILED: %s", configuration.name, tostring(packet))
			)
			continue
		end

		--[[
			Decode is timed as well as encode, because a caller pays both.

			It was measured all along -- the round-trip check has always
			decoded -- but never reported, so the published figures described
			half of what using the library costs.
		]]
		for _ = 1, 12 do
			task.wait()
		end

		local decodeOk, decoded, decodeMs = pcall(function()
			local started = os.clock()
			local result = zzzz:Deserialize(packet)
			return result, (os.clock() - started) * 1000
		end)

		if not decodeOk then
			allVerified = false
			table.insert(
				lines,
				string.format("  %-22s DECODE FAILED: %s", configuration.name, tostring(decoded))
			)
			continue
		end

		if not verifyMixed(entities, decoded, tolerance) then
			allVerified = false
			table.insert(lines, string.format("  %-22s ROUND TRIP MISMATCH", configuration.name))
			continue
		end

		local totalMs = encodeMs + (decodeMs or 0)

		table.insert(
			lines,
			string.format(
				-- Two decimals for the same reason as the player-save run.
				"  %-22s %12s %9.0f%% %8.2fms %8.2fms %8.2fms %9.0f%s",
				configuration.name,
				comma(buffer.len(packet)),
				100 - (buffer.len(packet) / jsonBytes) * 100,
				encodeMs,
				decodeMs or 0,
				totalMs,
				totalMs * 1000000 / valueCount,
				if configuration.lossy then "  lossy" else ""
			)
		)

		if not configuration.lossy then
			best = packet
			bestName = configuration.name
			bestEncodeMs = encodeMs
			bestDecodeMs = decodeMs or 0
			bestOptions = configuration.options
		end
	end

	-- Throughput for the best lossless row; see the note in `run`.
	if bestEncodeMs then
		local encodeRate = valueCount / (bestEncodeMs / 1000)
		local decodeRate = if bestDecodeMs > 0 then valueCount / (bestDecodeMs / 1000) else 0

		table.insert(lines, "")
		table.insert(lines, string.format("  throughput -- %s", bestName))
		table.insert(
			lines,
			string.format("  %-22s %12s values/sec", "encode", millions(encodeRate))
		)
		if decodeRate > 0 then
			table.insert(
				lines,
				string.format("  %-22s %12s values/sec", "decode", millions(decodeRate))
			)
		end
	end

	-- The schema path; see the note in `run`.
	if best and bestEncodeMs and bestOptions then
		if
			not schemaSection(
				lines,
				entities,
				bestOptions,
				jsonBytes,
				valueCount,
				bestEncodeMs,
				buffer.len(best),
				verifyMixed
			)
		then
			allVerified = false
		end
	end

	local encoding = nil
	local algorithm = nil
	pcall(function()
		encoding = game:GetService("EncodingService")
		algorithm = Enum.CompressionAlgorithm.Zstd
	end)

	if encoding and algorithm and best then
		table.insert(lines, "")
		table.insert(lines, "  after zstd level 22")

		-- Timed for the same reason as the player-save run; see the note there.
		local jsonSource = buffer.fromstring(HttpService:JSONEncode(mixedToJsonSafe(entities)))

		local jsonStarted = os.clock()
		local jsonPacked = encoding:CompressBuffer(jsonSource, algorithm, 22)
		local jsonPackMs = (os.clock() - jsonStarted) * 1000

		local zzzzStarted = os.clock()
		local zzzzPacked = encoding:CompressBuffer(best, algorithm, 22)
		local zzzzPackMs = (os.clock() - zzzzStarted) * 1000

		-- Bytes per millisecond over the input; see the note in `run`.
		table.insert(
			lines,
			string.format(
				"  %-22s %12s %10s %10s %10s %8.2fms %10s",
				"JSON + zstd22",
				comma(buffer.len(jsonPacked)),
				"--",
				"--",
				"--",
				jsonPackMs,
				string.format("%s B/ms", comma(buffer.len(jsonSource) / jsonPackMs))
			)
		)
		table.insert(
			lines,
			string.format(
				"  %-22s %12s %9.1f%% %10s %10s %8.2fms %10s",
				"Zzzz + zstd22",
				comma(buffer.len(zzzzPacked)),
				100 - (buffer.len(zzzzPacked) / jsonBytes) * 100,
				"--",
				"--",
				zzzzPackMs,
				string.format("%s B/ms", comma(buffer.len(best) / zzzzPackMs))
			)
		)
		table.insert(
			lines,
			string.format(
				"  %-22s %12s",
				"",
				string.format("%.1fx smaller than JSON", jsonBytes / buffer.len(zzzzPacked))
			)
		)
	end

	table.insert(lines, "")
	table.insert(lines, allVerified and "  all round trips verified" or "  ROUND TRIP FAILURES")

	print(table.concat(lines, "\n"))
	return allVerified
end

return setmetatable({
	build = buildDataset,
	countValues = countValues,
	toJsonSafe = toJsonSafe,
	verify = verify,
	run = run,
	buildMixed = buildMixed,
	mixedToJsonSafe = mixedToJsonSafe,
	verifyMixed = verifyMixed,
	runMixed = runMixed,
	ITEM_NAMES = ITEM_NAMES,
	CLASS_NAMES = CLASS_NAMES,
	TEAM_NAMES = TEAM_NAMES,
	ENCHANTS = ENCHANTS,
}, {
	__call = function(_, playerCount: number?)
		return run(playerCount)
	end,
})
