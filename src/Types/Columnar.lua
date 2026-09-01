--!strict
--!native
--!optimize 2

--[[
	Columnar array detection.

	An array of records is normally written row by row, repeating a shape id
	per row and paying a tag byte per value. Written column by column instead,
	values of one type sit adjacent: a boolean column bit-packs, a
	low-cardinality string column collapses to a dictionary, and a later
	compression pass finds far more structure. Measured at 27% smaller after
	zstd on a realistic save.

	The transform rebuilds each row as a fresh table, and that is the whole
	difficulty. Zzzz has preserved shared references and cycles since v1:

		local shared = { a = 1, b = 2 }
		local rows = { { a = 1, b = 2 }, shared, shared }

		row form:      decoded[2] == decoded[3]  -> true
		columnar:      decoded[2] == decoded[3]  -> false

	Silently losing that identity is worse than any byte saving, so an array
	only qualifies when no row is shared with anything else and no row can
	reach itself. `qualifies` is deliberately conservative: it answers "is this
	provably safe", not "is this probably fine".
]]

local Columnar = {}

--[[
	Smallest array worth transforming. Below this the shape definition and the
	per-column framing cost more than writing the rows directly.
]]
local MIN_ROWS = 4

--[[
	Where a lone column starts paying for the layout. Measured: at four rows the
	struct cache is still ahead, at six the column is.
]]
local SINGLE_COLUMN_MIN_ROWS = 6

--[[
	Bytes Writer.varint spends on a non-negative value. Mirrors its ladder.
]]
local function varintWidth(value: number): number
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
	Widest string id a packed shared-id column will carry. Beyond this the ids
	are wide enough that the plain reference form is no worse.
]]
local MAX_SHARED_ID_BITS = 24

--[[
	Widest shape worth transforming, matching the structure cache's own cap.

	This was 64 on both sides, which turned out to be a cliff rather than a
	bound: two hundred records of seventy fields cost 67,642 bytes against
	36,257 at sixty-four, because past the cap every record rewrote all of its
	key names. Nothing on the wire requires a limit -- key counts are varints --
	so it sits where scanning a shape is still trivial.
]]
local MAX_KEYS = 256

Columnar.MIN_ROWS = MIN_ROWS
Columnar.MAX_KEYS = MAX_KEYS

export type Shape = {
	rowCount: number,
	keys: { string },
	signature: string,
}

--[[
	Whether `value` is reachable from itself, following table values only.

	A row that participates in a cycle cannot be rebuilt column by column: the
	cycle is only expressible as a reference back to a table that exists, and
	columnar rows do not exist until every column has been read.
]]
--[[
	The stack and the visited set, reused across calls.

	This allocated both per call, and it is called once per row of every array
	that reaches the cycle check -- 31,867 times on the canonical payload, so
	63,734 tables, nearly all of them for rows holding no nested table at all.
	Measured on the 2,000 player rows alone: 21.6 ms allocating against 13.2 ms
	pooled, a 39% saving on the check.

	`visited` is stamped with a generation rather than cleared. Clearing is
	O(size) and the set is usually tiny but occasionally large, so the cost
	falls on exactly the rows that were cheapest; a counter makes the reset
	free. The generation only ever increases, so a stamp from an earlier call
	can never be mistaken for this one's.

	Not re-entrant, which is safe here: the walk calls nothing that could call
	back into it, and Luau is single-threaded within a script.
]]
local cycleStack: { any } = {}
local cycleVisited: { [any]: number } = {}
local cycleGeneration = 0

local function reachesSelf(root: { [any]: any }): boolean
	cycleGeneration += 1
	local generation = cycleGeneration

	cycleStack[1] = root
	local top = 1
	local found = false

	while top > 0 do
		local current = cycleStack[top] :: { [any]: any }
		--[[
			Cleared as it is popped, so a walk does not pin every table it
			visited until some later call happens to overwrite the slot.
		]]
		cycleStack[top] = nil
		top -= 1

		for key, entry in pairs(current) do
			if type(key) == "table" then
				if key == root then
					found = true
					break
				end
				if cycleVisited[key] ~= generation then
					cycleVisited[key] = generation
					top += 1
					cycleStack[top] = key
				end
			end

			if type(entry) == "table" then
				if entry == root then
					found = true
					break
				end
				if cycleVisited[entry] ~= generation then
					cycleVisited[entry] = generation
					top += 1
					cycleStack[top] = entry
				end
			end
		end

		if found then
			break
		end
	end

	--[[
		Whatever the walk left behind, released before returning.

		Returning straight out of the loop on a cycle would leave the remaining
		entries in the shared stack, holding those tables alive until a later
		call overwrote the slots -- a leak the per-call version could not have,
		since its stack died with it. `visited` needs no such care: it is keyed
		by generation and its stale entries are overwritten, not read.
	]]
	for index = 1, top do
		cycleStack[index] = nil
	end

	return found
end

--[[
	Decide whether an array can be written as columns.

	`seenTables` is the encoder's own id map: a table already in it has been
	written before, so it is shared and rebuilding it as a fresh row would
	break that identity.

	Returns the row count and the sorted key list, or nil.
]]
function Columnar.qualifies(
	value: { [any]: any },
	seenTables: { [any]: number }
): (number?, { string }?)
	local rowCount = 0
	while rawget(value, rowCount + 1) ~= nil do
		rowCount += 1
	end

	if rowCount < MIN_ROWS then
		return nil
	end

	-- Must be a pure array: a stray map entry has nowhere to live in a
	-- columnar layout.
	local total = 0
	for _ in pairs(value) do
		total += 1
	end
	if total ~= rowCount then
		return nil
	end

	local signature: string? = nil
	local keys: { string }? = nil
	local rowsSeen: { [any]: boolean } = {}

	--[[
		The previous row's keys, for the same-shape fast path below. A row whose
		keys match the last one's has the same signature, so nothing needs
		building or comparing for it.
	]]
	local previousKeys: { string }? = nil
	local previousKeySet: { [string]: boolean } = {}
	local previousKeyCount = 0
	-- Set only when rows disagree about their keys; see the union below.
	local union: { [string]: boolean }? = nil
	local mixed = false

	for index = 1, rowCount do
		local row = value[index]

		if type(row) ~= "table" then
			return nil
		end

		-- Shared with something already written, or repeated within this very
		-- array. Either way its identity would not survive the rebuild.
		if seenTables[row] ~= nil or rowsSeen[row] then
			return nil
		end
		rowsSeen[row] = true

		--[[
			Most rows of a columnar array have the shape the row before it had --
			that sameness is what makes the array columnar at all. So the keys
			are checked against the last row's before any are collected, and a
			match skips the sort, the per-key format and the concat below.

			Measured on the canonical payload, which puts 26,007 rows through
			here at about four keys each: 26,007 sorts, 26,007 concats and
			104,028 `string.format` calls, nearly every one producing a string
			equal to the one before it.

			The check is exact rather than a heuristic: same count, and every
			key present in the previous set. Two rows satisfying both carry the
			same keys, so they have the same signature.
		]]
		local matchesPrevious = previousKeys ~= nil
		local rowKeyCount = 0

		for key, entry in pairs(row) do
			if type(key) ~= "string" then
				return nil
			end
			-- A table value inside a row is fine, but only if it cannot lead
			-- back to the row itself.
			if type(entry) == "table" and entry == row then
				return nil
			end
			rowKeyCount += 1
			if matchesPrevious and not previousKeySet[key] then
				matchesPrevious = false
			end
		end

		if matchesPrevious and rowKeyCount ~= previousKeyCount then
			matchesPrevious = false
		end

		if matchesPrevious then
			--[[
				Same keys as the row before, so the same signature.

				Skipping is safe even when the rows disagree among themselves.
				The comparison below only does something when a row's signature
				differs from the FIRST row's, and then it adds both key sets to
				a union -- a set, so adding the same keys twice changes nothing.
				A row identical to its predecessor therefore has nothing to
				contribute that the predecessor did not already contribute.

				`keys` is likewise assigned only from the first row, which never
				takes this path because there is no previous row to match.

				Worked through on rows A A B B A: the second A and the second B
				both skip, and the union ends as {A, B} either way.
			]]
			continue
		end

		local rowKeys = table.create(rowKeyCount)
		for key in pairs(row) do
			table.insert(rowKeys, key)
		end

		--[[
			A row may hold any number of keys, including none.

			An empty row is not a broken row: it is one where every key of the
			shape happens to be absent, which is exactly what the optional form
			exists to carry. Demanding at least one key here rejected the whole
			array over a single such row -- 166 empty rows in 500 sent the other
			334 back to plain encoding.

			The array-level minimum is checked once the union is known, since a
			row cannot tell on its own how many columns the shape has.
		]]
		if #rowKeys > MAX_KEYS then
			return nil
		end

		table.sort(rowKeys)

		--[[
			Length-prefixed, for the same reason the structure cache is: Luau
			keys are byte strings, so a separator-joined signature would let
			{x, "y\0z"} and {"x\0y", z} collide.
		]]
		local parts = table.create(#rowKeys)
		for keyIndex, key in rowKeys do
			parts[keyIndex] = string.format("%d:%s", #key, key)
		end
		local rowSignature = table.concat(parts)

		--[[
			Remembered for the next row, which usually carries the same keys and
			can then skip everything above.
		]]
		previousKeys = rowKeys
		previousKeyCount = #rowKeys
		table.clear(previousKeySet)
		for _, key in rowKeys do
			previousKeySet[key] = true
		end

		if signature == nil then
			signature = rowSignature
			keys = rowKeys
		elseif rowSignature ~= signature then
			--[[
				Rows that disagree about which keys they carry.

				This used to reject the array outright, which was expensive out of
				all proportion: one optional field on a twentieth of the rows sent
				4,000 otherwise perfectly columnar records back to plain key-value
				encoding, eight times larger. The data was columnar; only the
				*absence* was not.

				So the key set becomes the union, and a key some rows lack becomes
				an optional column -- a validity bitmap plus the values that are
				actually there, which is what Parquet's definition levels and
				Arrow's validity bitmaps do. Presence costs a bit a row.
			]]
			union = union or {}
			for _, key in keys :: { string } do
				union[key] = true
			end
			for _, key in rowKeys do
				union[key] = true
			end
			mixed = true
		end
	end

	--[[
		A mixed array's key list is the union, sorted, so every row agrees on the
		column order even where it does not agree on the contents.
	]]
	if mixed and union then
		local merged: { string } = {}
		for key in union do
			table.insert(merged, key)
		end
		if #merged > MAX_KEYS then
			return nil
		end
		table.sort(merged)
		keys = merged
	end

	--[[
		A single column pays too, which this used to deny.

		The rule was that fewer than two columns could not carry the layout, and
		it was never measured. A one-field record is an ordinary shape -- an id
		list, a column of samples, a wrapper someone will add a field to later --
		and refusing it sent every row through the struct cache at a tag and a
		value apiece. Measured on `{ x = <random 1..1000000> }`:

			  20 rows    164 B ->  80 B
			 100 rows    790 B -> 276 B
			1000 rows  7,842 B -> 2,527 B     7.84 -> 2.53 B a value

		The crossover is at six rows; below that the shape header and the plan
		outweigh what a column saves, and the struct cache is genuinely better.
	]]
	if keys == nil or #keys < 1 then
		return nil
	end
	if #keys < 2 and rowCount < SINGLE_COLUMN_MIN_ROWS then
		return nil
	end

	-- Cycles are the expensive check, so it runs last and only on rows that
	-- have already passed everything else.
	for index = 1, rowCount do
		if reachesSelf(value[index]) then
			return nil
		end
	end

	return rowCount, keys
end

Columnar.reachesSelf = reachesSelf

--[[
	Whether a column of tables is really several columns wearing a coat.

	Every scheme in this file works on a column of leaf values. A column whose
	values are *tables* has none, so it falls through to the plain form and each
	table is written out whole, row by row -- and nothing here can reach the
	numbers inside it.

	That is a lot of the packet. A player record with

		stats    = { health, mana, stamina, armor }
		settings = { music, sfx, sensitivity, quality }

	holds eight fields that never become columns, because they sit one level
	down. Two thousand players is four thousand little maps, each paying a key
	reference and a tagged value per field. Hoisting `stats.health` into a
	column of its own hands it to frequency, differencing, bit-packing and the
	decimal form like any other:

		canonical benchmark   190,563 B -> 159,584 B   -16.3%

	This is the *structural* half of columnar encoding, which the Lance work
	calls out as the under-studied one: everything else here is a compressive
	encoding, and no compressive encoding can see a column that was never
	formed. Nor can zstd afterwards -- it sees the records interleaved in the
	byte stream and has no idea a field repeats every eight values.

	Only maps with the same keys in every row are hoisted. That is the shape
	worth having -- a struct in all but name -- and it needs no presence bitmap
	or length column, which is what the general nested models spend their
	complexity on. Arrays of records are left alone: the columnar path already
	recurses into those on its own.

	A *fixed-length array* is hoisted too, by position.

		pos = { x, y, z }

	is three columns as surely as a map with three names, and refusing it was
	costing more than anything else measured this round: a `pos` of three
	numbers held the whole array to 4,736 bytes over 500 rows where the same
	numbers spelled `x`, `y`, `z` cost 233 -- twenty times, for the naming
	alone. A `pos` *identical in every row* still cost 2,515 bytes, five a row
	for a constant, because no scheme could see inside it.

	Only uniform lengths qualify, which is what makes the positions a shape:
	rows of differing length have no fixed column count and would need a length
	column, the thing this form exists to avoid. The second return says which
	kind was found, since the two rebuild differently on the way back -- the
	names are keys, the positions are indices.
]]
local HOIST_MIN_ROWS = 4

function Columnar.hoistableKeys(
	column: { any },
	seenTables: { [any]: number }
): ({ string }?, boolean?)
	local count = #column
	if count < HOIST_MIN_ROWS then
		return nil
	end

	local keys: { string }? = nil
	local signature: string? = nil
	local seenHere: { [any]: boolean } = {}
	--[[
		Which shape the first row set. The two cannot mix: a column of maps and
		a column of arrays share no key naming, and the signature check below
		would reject the mixture anyway, but deciding it once up front keeps the
		per-row test to a single branch.
	]]
	local isArray: boolean? = nil

	for index = 1, count do
		local row = column[index]
		if type(row) ~= "table" then
			return nil
		end

		--[[
			A table already written elsewhere, or appearing twice in this column,
			would lose its identity if it were taken apart and rebuilt: the two
			references would come back as two separate maps.

			`seenTables` catches the first case only for tables written before
			this array, so the repeats within the column are tracked here.
		]]
		if seenTables[row] ~= nil or seenHere[row] then
			return nil
		end
		seenHere[row] = true

		local rowIsArray = rawget(row, 1) ~= nil
		if isArray == nil then
			isArray = rowIsArray
		elseif isArray ~= rowIsArray then
			return nil
		end

		local rowKeys = {}
		if rowIsArray then
			--[[
				Positions, named by their index so they travel as keys like any
				other. A trailing map entry means this is not a plain array, and
				a plain array is the only thing whose positions form a shape.
			]]
			local length = 0
			while rawget(row, length + 1) ~= nil do
				length += 1
			end

			local total = 0
			for _ in pairs(row) do
				total += 1
			end
			if total ~= length then
				return nil
			end

			for position = 1, length do
				local entry = row[position]
				if type(entry) == "table" then
					return nil
				end
				if entry ~= entry then
					return nil
				end
				table.insert(rowKeys, tostring(position))
			end
		else
			for key, entry in pairs(row) do
				if type(key) ~= "string" then
					return nil
				end
				--[[
					A table value is allowed through, and lifted by the round
					after this one.

					This used to refuse the whole struct on meeting one, which
					made `profile = { class, progress = {...} }` unhoistable
					entirely -- `class` stayed buried because `progress` was a
					table. The caller now runs this pass repeatedly, so a table
					here becomes a column of tables that the next round lifts,
					and the recursion the old comment worried about happens in
					the caller where the cycle checks are.

					A shared or cyclic table still cannot be taken apart, and
					that is what `seenTables` and `seenHere` above test. What is
					removed here is only the refusal to look one level further.
				]]
				if entry == nil or entry ~= entry then
					return nil
				end
				table.insert(rowKeys, key)
			end
		end

		if #rowKeys < 1 or #rowKeys > MAX_KEYS then
			return nil
		end

		table.sort(rowKeys)

		-- Length-prefixed for the same reason `qualifies` does it.
		local parts = table.create(#rowKeys)
		for keyIndex, key in rowKeys do
			parts[keyIndex] = string.format("%d:%s", #key, key)
		end
		local rowSignature = table.concat(parts)

		if signature == nil then
			signature = rowSignature
			keys = rowKeys
		elseif rowSignature ~= signature then
			return nil
		end
	end

	return keys, isArray
end

Columnar.HOIST_MIN_ROWS = HOIST_MIN_ROWS

--[[
	Whether a column of ARRAYS can be written as one table instead of many.

	Hoisting reaches into a nested MAP -- `stats` becomes `stats.health` and
	`stats.mana` -- because every row has exactly one of each. An array cannot be
	hoisted that way: one row's inventory holds five items and another's holds
	twenty, so there is no fixed set of positions to lift.

	So each such array is written as its own columnar block, and the cost of that
	is severe. Measured on two thousand inventories holding 29,867 items between
	them:

		as two thousand arrays    93,219 bytes    125.05 ms
		as one array + lengths    72,395          52.93

	22% smaller and 2.4x faster, and the form census says why. Split, the
	encoder wrote 7,547 columns -- 1,996 of them shared-string columns of about
	fourteen values each. Batched, it wrote four, and the item names became a
	single dictionary. Twenty distinct names cost almost nothing amortised over
	thirty thousand rows and can never pay for themselves over fourteen.

	The batching is exact: the items are concatenated in row order and a vector
	of lengths says where each array ended, so the split is recovered by walking
	that vector. Nothing is approximated and no row moves.

	This returns the lengths and the concatenated rows when the column qualifies,
	and nil when it does not. The conditions are what the columnar path needs of
	any array, applied to the concatenation rather than to each piece:

	  * every value is a plain array of tables
	  * no array is shared or repeated, since taking one apart and rebuilding it
	    would break a reference elsewhere in the packet
	  * the concatenation is long enough to be worth a columnar block at all

	`qualifies` is left to judge the concatenated rows themselves -- whether they
	share a shape, whether any row is cyclic. Duplicating those checks here would
	be a second implementation of the same rules, and this file has already been
	bitten once by a reconstruction disagreeing with the thing it reconstructed.
]]
--[[
	Both gates were 8 and 32 by judgment, and measurement brought them down.

	Encoding the same data with batching allowed and forbidden, and reading
	where the two lines cross:

		arrays, 10 rows each      4: +21   6: +15   8: +27   24: +106   64: +863
		rows, 32 arrays          32: +163            256: +226        1,024: +1,062
		many tiny arrays        128 arrays x 1 row: +751

	Four arrays is where the first saving appears, and nothing above it loses
	meaningfully. The row sweep has no crossover at all -- every size tested
	won -- so that gate only has to be low enough not to interfere.

	The awkward case both gates were built to exclude turned out not to exist.
	A hundred and twenty-eight arrays of one row each is the least amortisable
	shape available, and batching still saved 751 bytes: the framing those
	arrays each carried outweighs anything the concatenation adds.

	One band does lose: ten to sixteen arrays give up 22 to 28 bytes, and then
	twenty-four gains 106. That is not a threshold, it is the UNBATCHED side
	hitting a favourable plan-cache boundary -- the batched column is flat
	across it while the split one dips. A gate placed there would exclude every
	size above it to avoid twenty-five bytes, so the band is accepted as the
	price of the sizes on either side.

	Below four arrays, `hoistableKeys` and the tuple path already handle the
	small cases, and the concatenation has nothing to amortise.
]]
local BATCH_MIN_ARRAYS = 4
local BATCH_MIN_ROWS = 8

function Columnar.batchableArrays(
	column: { any },
	rowCount: number,
	seenTables: { [any]: number }
): ({ any }?, { number }?)
	--[[
		Read from the table rather than the local, so a benchmark can move the
		gate and have the qualifier see it. The two are assigned together below
		and nothing but a test ever changes them.
	]]
	if rowCount < Columnar.BATCH_MIN_ARRAYS then
		return nil
	end

	local lengths = table.create(rowCount)
	local total = 0
	local seenHere: { [any]: boolean } = {}

	for index = 1, rowCount do
		local inner = column[index]
		if type(inner) ~= "table" then
			return nil
		end

		--[[
			A shared or repeated array would come back as two separate arrays if
			it were taken apart and rebuilt, so the whole batch is refused rather
			than silently losing the identity.
		]]
		if seenTables[inner] ~= nil or seenHere[inner] then
			return nil
		end
		seenHere[inner] = true

		--[[
			A plain array of tables, with nothing hiding past its numeric run. A
			map entry alongside the items would have nowhere to go in the
			concatenation.
		]]
		local length = 0
		while rawget(inner, length + 1) ~= nil do
			length += 1
		end

		local entries = 0
		for _ in pairs(inner) do
			entries += 1
		end
		if entries ~= length then
			return nil
		end

		--[[
			An empty array is allowed and carries a length of zero -- a player
			with nothing in their inventory is ordinary, and refusing the batch
			over one would give up the saving on all the others.
		]]
		for slot = 1, length do
			if type(inner[slot]) ~= "table" then
				return nil
			end
		end

		lengths[index] = length
		total += length
	end

	if total < Columnar.BATCH_MIN_ROWS then
		return nil
	end

	--[[
		Concatenated in row order, which is what makes the lengths sufficient to
		split it again.
	]]
	local rows = table.create(total)
	local cursor = 0
	for index = 1, rowCount do
		local inner = column[index]
		for slot = 1, lengths[index] do
			cursor += 1
			rows[cursor] = inner[slot]
		end
	end

	return rows, lengths
end

Columnar.BATCH_MIN_ARRAYS = BATCH_MIN_ARRAYS
Columnar.BATCH_MIN_ROWS = BATCH_MIN_ROWS

--[[
	Whether a MAP of same-shaped structs is really a table.

	`{ user1 = {...}, user2 = {...} }` is a columnar table wearing a map's
	clothes: every value has the same fields, and the keys are a column like any
	other. But the columnar path only ever looks at arrays, so this shape
	reaches the structure cache instead -- which writes each struct's fields one
	at a time, each with its own type tag.

	Measured on four thousand such structs:

		as a map        80,561 bytes    3,999 structs written field by field
		as columns      40,109                5 columns

	50.2% smaller, and the counters say why: four thousand tagged field-writes
	became five packed columns. The shape is common -- save data keyed by user
	id, settings keyed by category, a world keyed by region name -- and nothing
	in the encoder currently recognises it.

	The transposition is exact. The keys become a column of their own, sorted so
	the order is deterministic, and each field becomes a column beside it. What
	comes back is rebuilt by reading the key column and the field columns
	together.

	Returns the rows and the key order, or nil. The conditions are what makes
	the rebuild exact rather than approximate:

	  * every value is a plain string-keyed map, no arrays and no scalars
	  * every value has the SAME keys, since a column needs a value per row
	  * no value is shared or repeated, which taking one apart would break
	  * `key` is not among the fields, since the key column would collide

	The last is a real restriction and it is checked rather than assumed: a
	struct that already has a field called `key` cannot be transposed without
	renaming something, and renaming is how a rebuild goes wrong.
]]
local TRANSPOSE_MIN_STRUCTS = 8
local TRANSPOSE_KEY_FIELD = "\0key"
--[[
	The reserved field an array-valued map carries its list under.

	Reserved for the same reason the key is: a leading NUL cannot collide with
	anything a caller writes. Here there is no field name to collide with anyway
	-- the value is a bare array -- but the two travel as columns of one row and
	both need names.
]]
local TRANSPOSE_ITEMS_FIELD = "\0items"

function Columnar.transposableMap(
	value: { [any]: any },
	seenTables: { [any]: number }
): ({ any }?, { string }?)
	local names: { string } = {}

	for key, entry in pairs(value) do
		if type(key) ~= "string" then
			return nil
		end
		if type(entry) ~= "table" then
			return nil
		end
		table.insert(names, key)
	end

	if #names < TRANSPOSE_MIN_STRUCTS then
		return nil
	end

	--[[
		Sorted, so two encodes of the same map produce the same packet. `pairs`
		makes no promise about order and a packet that changed between runs
		would break every comparison anyone made of it.
	]]
	table.sort(names)

	local fieldSet: { [string]: boolean }? = nil
	local fieldCount = 0
	local seenHere: { [any]: boolean } = {}

	--[[
		Whether the values are ARRAYS rather than string-keyed maps.

		`{ region1 = { ... }, region2 = { ... } }` where each value is a list is
		the shape a per-region leaderboard takes, and it is common. Its values
		have no field names at all, so the per-field checks below cannot apply
		-- but the transposition still works, and the array lands in a column
		that batching then concatenates.

		Decided from the first value and enforced on the rest: a map mixing
		arrays and maps has no single transposition and is refused.
	]]
	local firstValue = value[names[1]]
	local valuesAreArrays = rawget(firstValue, 1) ~= nil

	if valuesAreArrays then
		local rows = table.create(#names)

		for index, name in names do
			local entry = value[name]

			if seenTables[entry] ~= nil or seenHere[entry] then
				return nil
			end
			seenHere[entry] = true

			--[[
				A plain array and nothing else. A map entry alongside the items
				would have nowhere to go once the array becomes a column value.
			]]
			local length = 0
			while rawget(entry, length + 1) ~= nil do
				length += 1
			end

			local total = 0
			for _ in pairs(entry) do
				total += 1
			end
			if total ~= length then
				return nil
			end

			rows[index] = {
				[TRANSPOSE_KEY_FIELD] = name,
				[TRANSPOSE_ITEMS_FIELD] = entry,
			}
		end

		return rows, names
	end

	for _, name in names do
		local entry = value[name]

		if seenTables[entry] ~= nil or seenHere[entry] then
			return nil
		end
		seenHere[entry] = true

		--[[
			Every value must be the same kind. An array here, where the first
			value was a map, has no place in the columns being built.
		]]
		if rawget(entry, 1) ~= nil then
			return nil
		end

		local count = 0
		for field, inner in pairs(entry) do
			if type(field) ~= "string" then
				return nil
			end
			--[[
				A table value is allowed through, and handled downstream.

				This refused them, on the reasoning that a column of tables is a
				different problem. It is -- and batching and hoisting are the
				mechanisms for it, both of which run on the transposed rows.
				Refusing here meant a map whose values held anything nested
				reached neither.

				Measured on forty regions each holding fifty records: 7,617
				bytes as a map against 5,361 transposed and batched, 29.6%. The
				census shows why -- forty columnar blocks became two, and
				twenty-seven short string columns became one dictionary.
			]]
			count += 1

			if fieldSet == nil then
				continue
			end
			if not fieldSet[field] then
				return nil
			end
		end

		if fieldSet == nil then
			fieldSet = {}
			for field in pairs(entry) do
				fieldSet[field] = true
			end
			fieldCount = count
		elseif count ~= fieldCount then
			--[[
				Same key names AND the same number of them. The loop above
				proves every field is in the first struct's set; this proves
				none is missing, which together mean the sets are equal.
			]]
			return nil
		end
	end

	if fieldSet == nil or fieldCount < 1 then
		return nil
	end

	--[[
		The key column is named with a leading NUL so it cannot collide with a
		real field -- a struct may legitimately have a field called `key`, and
		a NUL is not something a Luau identifier or a JSON key carries.
	]]
	if fieldSet[TRANSPOSE_KEY_FIELD] then
		return nil
	end

	local rows = table.create(#names)
	for index, name in names do
		local entry = value[name]
		local row = table.clone(entry)
		row[TRANSPOSE_KEY_FIELD] = name
		rows[index] = row
	end

	return rows, names
end

Columnar.TRANSPOSE_MIN_STRUCTS = TRANSPOSE_MIN_STRUCTS
Columnar.TRANSPOSE_KEY_FIELD = TRANSPOSE_KEY_FIELD
Columnar.TRANSPOSE_ITEMS_FIELD = TRANSPOSE_ITEMS_FIELD

--[[
	Whether an array's rows are tuples of one fixed width.

	`qualifies` insists on string keys, so an array of positional rows -- CSV
	lines, coordinate pairs, anything that came through JSON as a list of lists
	-- reached no column at all. The cost of that was the largest single figure
	measured: 500 rows of `{ i, i + 1, i + 2 }` took 4,653 bytes where the same
	numbers under the names `a`, `b`, `c` took 224. Twenty times, for the
	spelling.

	A tuple is a record whose fields are numbered, so rather than teach every
	scheme in this file a second kind of key, the caller renames the positions
	and hands the result to the ordinary path. One flag on the shape is enough
	to put them back.

	Uniform width is the whole of the test. Rows of differing length have no
	fixed column count, and a nested table has to stay a value: hoisting is
	what reaches inside those, one level further down.
]]
function Columnar.tupleWidth(value: { any }, rowCount: number): number?
	if rowCount < MIN_ROWS then
		return nil
	end

	local width: number? = nil

	for index = 1, rowCount do
		local row = value[index]
		if type(row) ~= "table" then
			return nil
		end

		local length = 0
		while rawget(row, length + 1) ~= nil do
			length += 1
		end
		if length < 1 or length > MAX_KEYS then
			return nil
		end

		-- A map entry alongside the positions means this is not a tuple.
		local total = 0
		for _ in pairs(row) do
			total += 1
		end
		if total ~= length then
			return nil
		end

		if width == nil then
			width = length
		elseif width ~= length then
			return nil
		end
	end

	return width
end

--[[
	Whether a column of strings should be written through a dictionary.

	The decision is a byte count, not a ratio. Without a dictionary each value
	costs a tag plus either its bytes (first sight) or a reference (after), and
	strings intern across the whole packet so a repeat is about two bytes. With
	one, each value is a varint index -- one byte for the first 191 entries --
	and the distinct values are written once.

	An earlier version required distinct * 2 <= count, which sounds reasonable
	and is far too strict: a real inventory of 15 items drawn from 20 names has
	around 12 distinct values and was rejected, even though indexing still wins.
	Comparing modelled sizes instead catches those.
]]

--[[
	Widest dictionary a column will build.

	This was 255, so an id fit in a byte, and that turned out to be about four
	times too strict. A column of 2,000 rows drawn from 256 colours -- one more
	than the cap -- was refused outright and paid four bytes a row where the
	dictionary would have paid one and a half:

		128 distinct   1.14 B/row
		255 distinct   1.52 B/row
		256 distinct   4.01 B/row      <- the cap, not the data

	Modelled against the plain form at four bytes a value over 2,000 rows, the
	dictionary still wins by 3.7 kB at 512 entries and by 1.4 kB at 1,024,
	turning over somewhere before 4,096. The columnar-format literature puts the
	same threshold in the thousands rather than the hundreds.

	The id width follows from the entry count rather than being fixed, so a
	dictionary past 255 costs nine or ten bits an id instead of eight. Whether
	that pays is measured per column below, against the row count -- a cap alone
	cannot know, since the crossover moves with how many rows share the entries.
]]
local MAX_DICTIONARY_ENTRIES = 4095

--[[
	Widest id the packed index uses, which follows from the entry cap: 4,095
	entries need twelve bits. Encoder and Decoder mirror this, and the three
	must agree or an index reads back as a different entry.
]]
local MAX_DICTIONARY_ID_BITS = 12

function Columnar.dictionaryFor(
	column: { any }
): ({ string }?, { [string]: number }?)
	local count = #column
	if count < MIN_ROWS then
		return nil
	end

	local lookup: { [string]: number } = {}
	local entries: { string } = {}
	local distinctBytes = 0

	for index = 1, count do
		local entry = column[index]
		if type(entry) ~= "string" then
			return nil
		end

		if not lookup[entry] then
			local id = #entries + 1
			if id > MAX_DICTIONARY_ENTRIES then
				return nil
			end
			entries[id] = entry
			lookup[entry] = id
			-- Tag plus length prefix plus the bytes themselves.
			distinctBytes += 2 + #entry
		end
	end

	-- Nothing repeats, so a dictionary is pure overhead.
	if #entries == count then
		return nil
	end

	--[[
		With a dictionary: the distinct values once, plus a packed id per row --
		the ids are bounded by the entry count, so they cost the width that holds
		it rather than a byte apiece.
		Without: roughly two bytes per row once interning takes hold, plus the
		distinct values anyway on their first appearance.
	]]
	-- The id width follows the entry count, up to the cap's twelve bits.
	local idBits = 1
	while idBits < MAX_DICTIONARY_ID_BITS and 2 ^ idBits < #entries do
		idBits += 1
	end

	local withDictionary = distinctBytes + math.ceil(count * idBits / 8)
	local withoutDictionary = distinctBytes + (count - #entries) * 2

	if withDictionary >= withoutDictionary then
		return nil
	end

	return entries, lookup
end

--[[
	Whether a column of Roblox datatypes repeats itself enough to index.

	`dictionaryFor` above refuses anything that is not a string, and until now
	nothing else caught these: a column of Color3, EnumItem, UDim2 or Vector3
	fell to the plain form and wrote every value in full, however few distinct
	ones it held. A palette, a material, a set of anchor points and a handful of
	sizes are all small vocabularies stored as if every row were unique.

	Measured on two thousand rows drawn from eight colours:

		as written values   8,023 B
		as eight entries and a packed id   ~782 B

	Datatypes compare equal by value in Luau, but they do not all *hash* by
	value, and this originally keyed the lookup on the value itself as if they
	did. Only Vector3 actually does:

		Rect.new(0,0,5,0) == Rect.new(0,0,5,0)   -->  true
		t[Rect.new(0,0,5,0)] after t[an equal Rect] = 1   -->  nil

	Color3, Rect, NumberRange, UDim2 and the rest all take the second line, so
	every row looked distinct, `#entries == count` held, and the form declined
	on the one shape it exists to catch. A column of five hundred Rects drawn
	from ten distinct values cost 8,514 bytes -- the same as if they were all
	different -- against 104 for the same numbers as plain scalars.

	So the key is derived from the value rather than being the value, by reading
	the components out and packing them exactly.

	`tostring` is the obvious candidate and it is wrong twice over, which is why
	it is not used: it rounds, so Color3.new(0.1, 0, 0) and
	Color3.new(0.10000001, 0, 0) print alike and would be *merged* -- silent
	corruption, not a missed saving -- and four BrickColor palette entries share
	a name outright. The keys below use `string.pack` on the raw components, so
	two values share a key only when every component is bit-identical.

	Returns the distinct values in first-appearance order and a lookup from
	the *key* to an id, plus the keying function itself so the caller can find
	the id for a row, or nil when indexing does not pay.
]]

--[[
	An exact key for one datatype value.

	Doubles, packed rather than printed, so no component is rounded on the way
	in. A type absent from this table has no key and no dictionary: better to
	miss the form than to guess at a value's identity.
]]
local DATATYPE_KEYS: { [string]: (any) -> string } = {
	Color3 = function(v: Color3)
		return string.pack("ddd", v.R, v.G, v.B)
	end,
	Vector3 = function(v: Vector3)
		return string.pack("ddd", v.X, v.Y, v.Z)
	end,
	Vector2 = function(v: Vector2)
		return string.pack("dd", v.X, v.Y)
	end,
	UDim = function(v: UDim)
		return string.pack("dd", v.Scale, v.Offset)
	end,
	UDim2 = function(v: UDim2)
		return string.pack(
			"dddd",
			v.X.Scale,
			v.X.Offset,
			v.Y.Scale,
			v.Y.Offset
		)
	end,
	Rect = function(v: Rect)
		return string.pack("dddd", v.Min.X, v.Min.Y, v.Max.X, v.Max.Y)
	end,
	NumberRange = function(v: NumberRange)
		return string.pack("dd", v.Min, v.Max)
	end,
	-- Identity, not appearance: four palette entries share a name.
	BrickColor = function(v: BrickColor)
		return string.pack("d", v.Number)
	end,
	-- Enum names are unique across every type, unlike BrickColor's.
	EnumItem = function(v: any)
		return tostring(v)
	end,
	Font = function(v: Font)
		return string.pack("dd", v.Weight.Value, if v.Style == Enum.FontStyle.Normal then 0 else 1)
			.. v.Family
	end,
}
local DATATYPE_DICTIONARY_TYPES: { [string]: boolean } = {
	Color3 = true,
	EnumItem = true,
	UDim2 = true,
	UDim = true,
	Vector3 = true,
	Vector2 = true,
	BrickColor = true,
	Rect = true,
	NumberRange = true,
	Font = true,
}

function Columnar.datatypeDictionaryFor(
	column: { any },
	perValueBytes: number
): ({ any }?, { [string]: number }?, ((any) -> string)?)
	local count = #column
	if count < MIN_ROWS then
		return nil
	end

	local kind = typeof(column[1])
	if not DATATYPE_DICTIONARY_TYPES[kind] then
		return nil
	end

	local keyOf = DATATYPE_KEYS[kind]
	if keyOf == nil then
		return nil
	end

	local lookup: { [string]: number } = {}
	local entries: { any } = {}

	for index = 1, count do
		local entry = column[index]
		--[[
			One type only. A mixed column would need a tag per entry, which is
			what the plain form already does.
		]]
		if typeof(entry) ~= kind then
			return nil
		end

		local key = keyOf(entry)
		if lookup[key] == nil then
			local id = #entries + 1
			if id > MAX_DICTIONARY_ENTRIES then
				return nil
			end
			entries[id] = entry
			lookup[key] = id
		end
	end

	-- Nothing repeats, so a dictionary is pure overhead.
	if #entries == count then
		return nil
	end

	--[[
		With a dictionary: every distinct value once, then a packed id a row.
		Without: the value again on every row, at whatever the plain form
		charges for one -- which the caller measures, since it varies by type.
	]]
	local idBits = 1
	while idBits < MAX_DICTIONARY_ID_BITS and 2 ^ idBits < #entries do
		idBits += 1
	end

	local withDictionary = #entries * perValueBytes + math.ceil(count * idBits / 8) + 1
	local withoutDictionary = count * perValueBytes

	if withDictionary >= withoutDictionary then
		return nil
	end

	return entries, lookup, keyOf
end

--[[
	Pull a datatype column apart into one numeric column per component.

	Vector2, Vector3 and CFrame have delta forms of their own above. Everything
	else with a fixed set of numbers inside it had nothing: when the values
	repeated, the dictionary caught them, and when they varied it wrote each one
	whole, however plainly columnar the components were. Measured over 500 rows
	of `Rect.new(0, 0, i, i)`:

		as Rects                            8,514 B
		the same numbers as four scalars       104 B

	Eighty-one times, and the numbers were already sorted. A Rect is four
	columns wearing a coat, exactly as `hoistableKeys` found a map to be several
	columns wearing one, so the answer is the same: take it apart, let the
	ordinary schemes -- differencing, bit-packing, run-length, frequency -- see
	the components, and put it back on the way out.

	Only types whose components are *exactly* recoverable belong here. Anything
	whose constructor rounds or normalises its input would come back changed,
	and a form that loses data is worse than one that costs bytes. Vector2 and
	Vector3 hold float32 components, so they are deliberately absent: the delta
	forms already cover them and know that precision.
]]
local DATATYPE_COMPONENTS: {
	[string]: { arity: number, split: (any) -> { number }, build: ({ number }) -> any },
} = {
	Rect = {
		arity = 4,
		split = function(v: Rect)
			return { v.Min.X, v.Min.Y, v.Max.X, v.Max.Y }
		end,
		build = function(c: { number })
			return Rect.new(c[1], c[2], c[3], c[4])
		end,
	},
	NumberRange = {
		arity = 2,
		split = function(v: NumberRange)
			return { v.Min, v.Max }
		end,
		build = function(c: { number })
			return NumberRange.new(c[1], c[2])
		end,
	},
	UDim2 = {
		arity = 4,
		split = function(v: UDim2)
			return { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset }
		end,
		build = function(c: { number })
			return UDim2.new(c[1], c[2], c[3], c[4])
		end,
	},
	UDim = {
		arity = 2,
		split = function(v: UDim)
			return { v.Scale, v.Offset }
		end,
		build = function(c: { number })
			return UDim.new(c[1], c[2])
		end,
	},
	Color3 = {
		arity = 3,
		split = function(v: Color3)
			return { v.R, v.G, v.B }
		end,
		build = function(c: { number })
			return Color3.new(c[1], c[2], c[3])
		end,
	},
}

Columnar.DATATYPE_COMPONENTS = DATATYPE_COMPONENTS

--[[
	Whether a datatype column is worth splitting into components.

	The split only pays when the components are duller than the values: four
	columns each cost a plan of their own, so a column of genuinely unrelated
	Rects would come out larger. Rather than model that, the caller measures --
	it encodes the components and compares -- and this reports only whether the
	shape allows it at all.
]]
function Columnar.datatypeSplitFor(column: { any }): { { number } }?
	local count = #column
	if count < MIN_ROWS then
		return nil
	end

	local kind = typeof(column[1])
	local spec = DATATYPE_COMPONENTS[kind]
	if spec == nil then
		return nil
	end

	local columns: { { number } } = table.create(spec.arity)
	for component = 1, spec.arity do
		columns[component] = table.create(count)
	end

	for index = 1, count do
		local entry = column[index]
		if typeof(entry) ~= kind then
			return nil
		end

		local parts = spec.split(entry)
		for component = 1, spec.arity do
			local value = parts[component]
			--[[
				A NaN component would not come back equal to itself, so the
				column could never be verified as exact.
			]]
			if value ~= value then
				return nil
			end
			columns[component][index] = value
		end
	end

	return columns
end

--[[
	Whether a string column should be written as packed references into the
	packet's own string table, rather than as its own dictionary.

	`dictionaryFor` builds a dictionary per column, and pays for it per column.
	That is the right answer for one big array and the wrong one for many small
	ones: two thousand inventories drawn from the same twenty item names rebuild
	the same dictionary two thousand times, and each is too short to amortise it.
	Measured on that shape it fired 29 times out of 2000 -- the rest fell back to
	interned string references at roughly two bytes each.

	Strings are already interned across the whole packet, so the ids exist; the
	only reason a reference costs two bytes is the tag in front of it. Writing
	the column as fixed-width packed ids removes both the tag and the repeated
	dictionary:

		2000 inventories, 20 item names
		as string references   51,917 B
		as packed shared ids   28,152 B     -45%

	The width comes from the largest id in the column, so a column drawn from a
	small vocabulary packs narrowly even when the packet's string table is large.

	`idOf` reports the packet-wide id a string already holds, or nil when it has
	not been written yet -- a column containing a first occurrence cannot use
	this form, because the bytes have to appear somewhere.

	Returns the bit width and the modelled saving, or nil.
]]
function Columnar.sharedStringIdsFor(
	column: { any },
	idOf: (string) -> number?
): (number?, number?)
	local count = #column
	if count < MIN_ROWS then
		return nil
	end

	local highest = 0
	local plainBytes = 0
	local seen: { [string]: boolean } = {}

	for index = 1, count do
		local entry = column[index]
		if type(entry) ~= "string" then
			return nil
		end

		local id = idOf(entry)
		if not id then
			return nil
		end
		if id > highest then
			highest = id
		end

		--[[
			What the column costs today: a tag plus the id for a repeat, or the
			whole string on its first appearance in this column.
		]]
		if seen[entry] then
			plainBytes += 1 + varintWidth(id)
		else
			seen[entry] = true
			plainBytes += 1 + varintWidth(id)
		end
	end

	local bits = 1
	while bits < MAX_SHARED_ID_BITS and 2 ^ bits <= highest do
		bits += 1
	end
	if 2 ^ bits <= highest then
		return nil
	end

	-- A width byte, then the packed ids.
	local packedBytes = 1 + math.ceil(count * bits / 8)
	if packedBytes >= plainBytes then
		return nil
	end

	return bits, plainBytes - packedBytes
end

--[[
	Whether a column of integers should be packed at a fixed bit width.

	A column of small integers pays a tag byte plus a width per value, and the
	width is chosen per value against fixed boundaries -- so `level` in 1..100
	costs two bytes each, one for the tag and one for a u8, while seven bits
	would hold every value in it.

	Stored as a base plus a span: subtracting the minimum turns any contiguous
	range into 0..span, so a column of large but tightly clustered values --
	timestamps, ids -- packs as narrowly as one starting at zero. The base is a
	zigzag varint, which is why negatives cost nothing extra.

	Returns the base, the bit width, and the modelled saving, or nil when
	packing would not actually be smaller.
]]
--[[
	The widest a packed field may be.

	The packer accumulates `value * 2^held` and spills bytes, so the accumulator
	reaches about 2^(bits+8) before it drains. A double is exact to 2^53, and
	measured with all-ones values the round trip breaks at 47 bits -- the
	accumulator hits 2^54 there and every value comes back wrong. 46 still
	holds, so 45 keeps a bit of margin.

	This was 32, which refused any column whose values span more than four
	bytes. Timestamps in milliseconds, ids from a global counter and hashes all
	live above that line and fell to the plain form.
]]
local MAX_PACK_BITS = 45

--[[
	Widest value this may difference.

	The bound is 2^52, not 2^53. A seed travels as a zigzag varint, and zigzag
	doubles its input -- so a value at 2^53 becomes 2^54, past the range a double
	holds exactly, and the low bit is lost on the way back. Halving the bound
	keeps the zigzagged form inside 2^53.

	Differences are bounded separately by the bit width, which never exceeds 32.
]]
local MAX_DIFFERENCE_VALUE = 2 ^ 52

--[[
	Bytes a signed value costs once zigzagged, which is how every delta, base and
	seed is written.
]]
local function zigzagWidth(value: number): number
	return varintWidth(if value < 0 then -value * 2 - 1 else value * 2)
end

local function integerCost(v: number): number
	-- Mirrors Number.selectTag: 0-31 fold into the tag, everything else pays a
	-- tag plus its width.
	if v >= 0 and v <= 31 then
		return 1
	end
	if v >= 0 and v <= 255 then
		return 2
	end
	if v >= -128 and v < 0 then
		return 2
	end
	if v >= 0 and v <= 65535 then
		return 3
	end
	if v >= -32768 and v < 0 then
		return 3
	end
	if v >= -2147483648 and v <= 4294967295 then
		return 5
	end

	--[[
		Past a 32-bit tag the plain form falls back to a varint, which is nine
		bytes at this magnitude -- so the value costs a tag and nine, not the
		five this used to claim for everything above 65,535.

		Understating it made every qualifier believe large integers were cheap
		to write plainly, so a column of them looked like a poor candidate for
		packing when it was a good one. Measured, a 40-bit value encodes in nine
		bytes where this returned five.
	]]
	return 10
end

function Columnar.bitPackFor(column: { any }): (number?, number?, number?)
	local count = #column
	if count < MIN_ROWS then
		return nil
	end

	local low, high = math.huge, -math.huge
	local plainBytes = 0

	for index = 1, count do
		local entry = column[index]
		if type(entry) ~= "number" or entry % 1 ~= 0 then
			return nil
		end
		if entry < low then
			low = entry
		end
		if entry > high then
			high = entry
		end
		plainBytes += integerCost(entry)
	end

	local span = high - low
	if span < 0 or span ~= span or span == math.huge then
		return nil
	end

	local bits = if span > 0 then math.ceil(math.log(span + 1, 2)) else 1
	if bits < 1 then
		bits = 1
	end
	if bits > MAX_PACK_BITS then
		return nil
	end

	--[[
		Cost of the packed form: the kind byte is paid either way, so it is not
		counted here. A width byte, the zigzag base varint, then the bits.
	]]
	local baseBytes = if low >= -95 and low <= 95 then 1 elseif low >= -4191 and low <= 4191 then 2 else 5
	local packedBytes = 1 + baseBytes + math.ceil(count * bits / 8)

	if packedBytes >= plainBytes then
		return nil
	end

	return low, bits, plainBytes - packedBytes
end

Columnar.MAX_PACK_BITS = MAX_PACK_BITS
Columnar.MAX_DICTIONARY_ENTRIES = MAX_DICTIONARY_ENTRIES
Columnar.MAX_DICTIONARY_ID_BITS = MAX_DICTIONARY_ID_BITS
Columnar.varintWidth = varintWidth

--[[
	Whether a column is determined by another column through a lookup.

	Save data is full of fields that are functions of other fields: a class
	implies its home region, a rarity implies its colour, a weapon type implies
	its damage kind. Every scheme so far compresses a column against itself, so
	such a column pays in full for information another column already carries.

	The mapping is stored once -- one target value per distinct source value --
	and the column itself disappears. Rows that break the mapping travel as
	exceptions, which is what lets it fire on nearly-determined columns rather
	than only perfect ones. That generalisation matters: a display name that
	equals a class 97% of the time is the same shape with a few exceptions.

	Measured on 2000 records:

		region from class      751 B ->   8 B    -99%   (perfectly determined)
		displayName from class 751 B -> 416 B    -45%   (55 exceptions)

	This is the 1-to-1 Dictionary scheme from the CWI work on multi-column
	compression, which found it the most common correlation in real data by a
	wide margin -- 489 instances against 30 for the numeric correlation Zzzz
	already had.

	Values are compared by identity, so this works for strings, numbers and
	booleans alike; whatever the caller stored comes back unchanged.

	`sourceIds` and `targetIds` map each distinct value to a small integer, which
	is how the mapping and exceptions are written. Returns the mapping keyed by
	source id, the exception rows and their target ids, and the saving.
]]
export type MappedPlan = {
	mapping: { [number]: number },
	sourceValues: { any },
	targetValues: { any },
	exceptionRows: { number },
	exceptionIds: { number },
	targetBits: number,
}

local MAPPED_MIN_ROWS = 8

function Columnar.mappedFor(
	source: { any },
	target: { any },
	soloBytes: number,
	extraBytes: number?,
	--[[
		The distinct counts, when the caller already has them.

		This form's own rejection tests are on the distinct counts of both
		columns -- neither may be as varied as the column is long -- but it
		could not reach them without first numbering both columns into
		dictionaries, which is a full walk of two thousand rows to learn a
		number the caller computed when it built the columns.

		The correlation search calls this for every ordered pair. On the
		canonical payload that is two thousand pairs, mostly booleans hoisted
		out of an achievements array, and each walked both columns in full to
		discover that two distinct values cannot key a mapping worth having:
		572 microseconds a pair, 1,175 ms in total, to find nothing.

		Passing the counts in turns that into two comparisons. They are
		optional so the function still works standalone, and they are trusted
		rather than checked -- a caller that passes a wrong count gets a wrong
		answer, which is why only `correlationPlan` passes them.
	]]
	knownDistinctSource: number?,
	knownDistinctTarget: number?
): (MappedPlan?, number?)
	local count = #target
	if count < MAPPED_MIN_ROWS or #source ~= count then
		return nil
	end

	--[[
		The same bound the loop below reaches after numbering both columns,
		applied first when the caller already knows the answer.
	]]
	if knownDistinctSource and knownDistinctSource * 2 > count then
		return nil
	end
	if knownDistinctTarget and knownDistinctTarget * 2 > count then
		return nil
	end

	--[[
		Number both columns. A column with as many distinct values as rows
		carries no repetition for a mapping to exploit, and the mapping would be
		as large as the column it replaces.
	]]
	local sourceIds: { [any]: number } = {}
	local sourceValues = {}
	local targetIds: { [any]: number } = {}
	local targetValues = {}

	for index = 1, count do
		local sourceValue = source[index]
		local targetValue = target[index]
		if sourceValue == nil or targetValue == nil then
			return nil
		end
		-- NaN is never equal to itself, so it cannot key a mapping.
		if sourceValue ~= sourceValue or targetValue ~= targetValue then
			return nil
		end

		if sourceIds[sourceValue] == nil then
			table.insert(sourceValues, sourceValue)
			sourceIds[sourceValue] = #sourceValues
		end
		if targetIds[targetValue] == nil then
			table.insert(targetValues, targetValue)
			targetIds[targetValue] = #targetValues
		end
	end

	local distinctSource = #sourceValues
	local distinctTarget = #targetValues

	if distinctSource * 2 > count or distinctTarget * 2 > count then
		return nil
	end

	--[[
		For each source value, the target it maps to most often. Everything else
		becomes an exception, so the choice minimises them.
	]]
	local tally: { [number]: { [number]: number } } = {}
	for index = 1, count do
		local sourceId = sourceIds[source[index]]
		local targetId = targetIds[target[index]]
		local row = tally[sourceId]
		if row == nil then
			row = {}
			tally[sourceId] = row
		end
		row[targetId] = (row[targetId] or 0) + 1
	end

	local mapping: { [number]: number } = {}
	for sourceId, row in tally do
		local best, bestCount = nil, -1
		for targetId, seen in row do
			--[[
				Ties broken by the lower id so the mapping does not depend on
				table iteration order, which Luau does not guarantee.
			]]
			if seen > bestCount or (seen == bestCount and targetId < (best or math.huge)) then
				best, bestCount = targetId, seen
			end
		end
		mapping[sourceId] = best
	end

	local exceptionRows = {}
	local exceptionIds = {}
	for index = 1, count do
		local expected = mapping[sourceIds[source[index]]]
		local actual = targetIds[target[index]]
		if actual ~= expected then
			table.insert(exceptionRows, index)
			table.insert(exceptionIds, actual)
		end
	end

	--[[
		Too many exceptions and the column is not really determined; the patching
		costs more than it saves and slows decoding besides. The CWI work draws
		this line at a tenth of the rows.
	]]
	if #exceptionRows * 10 > count then
		return nil
	end

	local targetBits = 1
	while targetBits < MAX_PACK_BITS and 2 ^ targetBits <= distinctTarget do
		targetBits += 1
	end

	--[[
		Cost: the distinct target values, the mapping as one packed id per
		distinct source value, then the exceptions as a row index and an id each.
		The source column is untouched -- it is written as it would have been.
	]]
	local total = varintWidth(distinctTarget)
	for _, value in targetValues do
		total += if type(value) == "string" then 2 + #value else 5
	end
	total += 1 + math.ceil(distinctSource * targetBits / 8)
	total += varintWidth(#exceptionRows)
	for index, row in exceptionRows do
		total += varintWidth(row) + math.ceil(targetBits / 8)
	end

	if total + (extraBytes or 0) >= soloBytes then
		return nil
	end

	return {
		mapping = mapping,
		sourceValues = sourceValues,
		targetValues = targetValues,
		exceptionRows = exceptionRows,
		exceptionIds = exceptionIds,
		targetBits = targetBits,
	}, soloBytes - total
end

Columnar.MAPPED_MIN_ROWS = MAPPED_MIN_ROWS

--[[
	Whether a column is one of several values a source value permits.

	`mappedFor` handles a source that determines its target outright. Far more
	common is a source that narrows it: a country implies one of its cities, a
	weapon class one of its damage types, a rarity one of a handful of tints.
	Such a column is not determined, so a mapping cannot carry it, but it is far
	from free -- the target's own dictionary spans every value in the packet
	when each row only ever holds one of a few.

	The fix is to give each distinct source its own run of the targets it
	admits. A row then stores an index into that run rather than into the whole
	dictionary, which is narrower whenever the widest run is smaller than the
	target's distinct count.

	This is the 1-to-N Dictionary scheme from the CWI work, which found it the
	second most common correlation in real data -- 363 instances against 489 for
	the 1-to-1 form above.

	It is far narrower here than that count suggests, because Zzzz's plain form
	is not what the paper compares against. The paper's baseline is a dictionary
	rebuilt per column, so restricting codes to [0,N) narrows every row against
	[0,distinct). Zzzz already writes columns as packed ids into one packet-wide
	string table, so the only gain left is the few bits between the two widths --
	while the runs still cost a length per source and every value written into
	them.

	The result is that it needs both heavy sharing and many rows before the
	per-row bits outgrow that fixed cost:

		 400 rows, 64 distinct, 2 per source     351 B ->   660 B   loses
		2000 rows, 64 distinct, 2 per source    1751 B ->   860 B   wins
		30000 rows, 1024 distinct, 2 per source 41251 B -> 13481 B   wins

	Where each source owns targets no other source uses -- fifty cities across
	five countries, nothing shared -- there is nothing to gain and the form is
	correctly refused.

	Runs are laid out in source id order and the decoder rebuilds their offsets
	by walking the same order, so only the run lengths and the values travel.
	Unlike the 1-to-1 form there are no exceptions: every value a source admits
	is in its run by construction, so the form is exact.
]]
export type MultiMappedPlan = {
	sourceValues: { any },
	runLengths: { number },
	runValues: { any },
	codes: { number },
	codeBits: number,
}

--[[
	Whether the narrowed form is already out of reach.

	`multiMappedFor` writes one packed code per row, at the width needed to
	index the longest run of admitted targets. That is a floor it pays whatever
	else it finds:

		max run   2   ->  1 bit  a row
		max run   3   ->  2 bits a row
		max run   8   ->  3 bits a row

	A boolean target costs a bit a row on its own, so a run length of two only
	ties and anything longer loses. Two independent booleans reach a run of two
	within a handful of rows.

	It had no cheap gate at all, and its own early bail fires only on
	high-cardinality SOURCES -- true of a random integer column, never of a coin
	flip.

	The 409 ms this was written to remove came from a reconstruction of the
	search outside the encoder, and that reconstruction passed a solo cost the
	encoder does not use -- so its gates fired differently and it timed a search
	that does not happen. Adding this gate did not move the benchmark. It is
	kept because the bound is sound and the call is cheap, not because it was
	shown to be worth anything on real data.

	The bound is sound rather than sampled-estimate: runs only ever grow as more
	rows are read, so the longest run seen in a prefix is a lower bound on the
	longest in the column, and a floor computed from it can only understate the
	real cost. Returning false means "cost it properly".
]]
local MULTI_MAPPED_SAMPLE_ROWS = 64

function Columnar.multiMappedRuledOut(
	source: { any },
	target: { any },
	rowCount: number,
	soloBytes: number
): boolean
	local limit = math.min(MULTI_MAPPED_SAMPLE_ROWS, rowCount)
	if limit < 2 then
		return false
	end

	--[[
		Spread rather than leading, for the reason `mappedRuledOut` is: a column
		sorted by its source value shows one group and one run at the front
		however varied it is further down.
	]]
	local stride = math.max(1, rowCount // limit)

	local runSeen: { [any]: { [any]: boolean } } = {}
	local runLength: { [any]: number } = {}
	local longest = 1

	for step = 0, limit - 1 do
		local index = 1 + step * stride
		if index > rowCount then
			break
		end

		local sourceValue = source[index]
		local targetValue = target[index]

		-- A hole or a NaN makes the form decline outright.
		if
			sourceValue == nil
			or targetValue == nil
			or sourceValue ~= sourceValue
			or targetValue ~= targetValue
		then
			return true
		end

		local seen = runSeen[sourceValue]
		if seen == nil then
			seen = {}
			runSeen[sourceValue] = seen
			runLength[sourceValue] = 0
		end

		if not seen[targetValue] then
			seen[targetValue] = true
			local length = runLength[sourceValue] + 1
			runLength[sourceValue] = length
			if length > longest then
				longest = length
			end
		end
	end

	--[[
		The codes alone, at the width the longest run seen so far demands. Any
		unread row can only lengthen a run, never shorten one.
	]]
	local bits = 1
	while bits < MAX_PACK_BITS and 2 ^ bits < longest do
		bits += 1
	end

	return math.ceil(rowCount * bits / 8) >= soloBytes
end

function Columnar.multiMappedFor(
	source: { any },
	target: { any },
	soloBytes: number,
	extraBytes: number?
): (MultiMappedPlan?, number?)
	local count = #target
	if count < MAPPED_MIN_ROWS or #source ~= count then
		return nil
	end

	--[[
		Number the source, and collect the distinct targets each source value
		admits. Insertion order is kept so the decoder can reproduce it.
	]]
	local sourceIds: { [any]: number } = {}
	local sourceValues = {}
	local runs: { { any } } = {}
	local runSeen: { { [any]: number } } = {}

	for index = 1, count do
		local sourceValue = source[index]
		local targetValue = target[index]
		if sourceValue == nil or targetValue == nil then
			return nil
		end
		-- NaN is never equal to itself, so it cannot key a run.
		if sourceValue ~= sourceValue or targetValue ~= targetValue then
			return nil
		end

		local sourceId = sourceIds[sourceValue]
		if sourceId == nil then
			--[[
				The check below wants a source no more varied than half the
				column. Distinct sources only ever grow, so a column already past
				that bound can never come back under it, and the tables this loop
				is filling would be built only to be discarded.

				Bailing here rather than after the loop is what keeps the
				correlation search affordable: this qualifier was 24% of encode
				time on the canonical benchmark, nearly all of it spent building
				runs for pairs that were rejected a moment later.
			]]
			if (#sourceValues + 1) * 2 > count then
				return nil
			end

			table.insert(sourceValues, sourceValue)
			sourceId = #sourceValues
			sourceIds[sourceValue] = sourceId
			runs[sourceId] = {}
			runSeen[sourceId] = {}
		end

		local seen = runSeen[sourceId]
		if seen[targetValue] == nil then
			local run = runs[sourceId]
			table.insert(run, targetValue)
			seen[targetValue] = #run
		end
	end

	local distinctSource = #sourceValues
	if distinctSource * 2 > count then
		return nil
	end

	--[[
		The widest run sets the code width. A source that admits as many targets
		as the column has distinct values has narrowed nothing, and the form
		degenerates into a dictionary with extra framing.
	]]
	local widest = 0
	local totalValues = 0
	for sourceId = 1, distinctSource do
		local run = runs[sourceId]
		totalValues += #run
		if #run > widest then
			widest = #run
		end
	end

	local codeBits = 1
	while codeBits < MAX_PACK_BITS and 2 ^ codeBits < widest do
		codeBits += 1
	end

	--[[
		How wide a shared string id is, for costing the repeats below. Mirrors
		the width `columnAnySoloBytes` assumes for the plain form.
	]]
	local distinctTarget = 0
	local distinctSeen: { [any]: boolean } = {}
	for _, run in runs do
		for _, entry in run do
			if not distinctSeen[entry] then
				distinctSeen[entry] = true
				distinctTarget += 1
			end
		end
	end

	local idBits = 1
	while idBits < 32 and 2 ^ idBits <= distinctTarget do
		idBits += 1
	end

	--[[
		Every distinct target now appears once per source that admits it. A
		target shared by many sources is written many times, so the runs can
		outgrow the single dictionary they replace -- that is what the cost
		comparison below is for.
	]]
	local runLengths = table.create(distinctSource)
	local runValues = table.create(totalValues)
	for sourceId = 1, distinctSource do
		local run = runs[sourceId]
		runLengths[sourceId] = #run
		for _, entry in run do
			table.insert(runValues, entry)
		end
	end

	local codes = table.create(count)
	for index = 1, count do
		local sourceId = sourceIds[source[index]]
		codes[index] = runSeen[sourceId][target[index]] - 1
	end

	--[[
		Cost: the run lengths, the values they hold, then one packed code per
		row. The source column is untouched -- it is written as it would have
		been.

		A value shared by several sources appears in each of their runs, but
		strings intern across the whole packet, so only its first appearance
		writes bytes -- and that first appearance is paid by the plain form too,
		which cancels it. Charging every repeat its full length instead made a
		50-city column look 707 bytes against a 301-byte plain form and rejected
		the very shape this scheme exists for.
	]]
	local total = varintWidth(distinctSource)
	for _, length in runLengths do
		total += varintWidth(length)
	end

	--[[
		Every run value is written, so every run value is charged.

		An earlier version charged a string's first appearance nothing, on the
		grounds that the plain form interns it too and the two cancel. They do
		not: the plain form writes the column as ids into a table it was going to
		build anyway, while this writes the value itself into the runs. On the
		canonical benchmark that under-count let the form claim a saving and cost
		4,528 bytes -- a qualifier is worthless if it can approve a loss.

		A repeat still costs only its id, since the string is interned by then.
	]]
	local counted: { [any]: boolean } = {}
	for _, entry in runValues do
		if type(entry) == "string" then
			if counted[entry] then
				total += math.ceil(idBits / 8)
			else
				counted[entry] = true
				total += 2 + #entry
			end
		else
			total += 5
		end
	end
	total += 1 + math.ceil(count * codeBits / 8)

	if total + (extraBytes or 0) >= soloBytes then
		return nil
	end

	return {
		sourceValues = sourceValues,
		runLengths = runLengths,
		runValues = runValues,
		codes = codes,
		codeBits = codeBits,
	}, soloBytes - total
end

--[[
	Whether an integer column sits in a distinct range per source value.

	The packed forms size a column by its whole range, so a column whose values
	cluster by category pays for the span between categories on every row. A
	publication year by author, a price band by tier, a spawn height by region:
	each group is narrow, the column as a whole is not.

	Giving each distinct source value its own reference -- the smallest target
	it maps to -- and storing the offset from it collapses the width to the
	widest group rather than the whole column:

		400 rows, years 1836-1999 over 6 authors
		  frame of reference   8 bits a row    400 B
		  per-author           2 bits a row    100 B

	This is the Dictionary-FOR scheme from the CWI work. It differs from the
	fitted form above in what it assumes: `correlationFor` wants a straight line
	through the pair and fails on categories, while this wants nothing but that
	each category be narrow, and says nothing about the relationship between
	them.

	References are written in source id order, which the decoder reproduces from
	the reference column, so only the reference values and the offsets travel.
]]
export type DictionaryForPlan = {
	sourceValues: { any },
	references: { number },
	offsets: { number },
	offsetBits: number,
}

function Columnar.dictionaryForFor(
	source: { any },
	target: { any },
	soloBytes: number,
	extraBytes: number?
): (DictionaryForPlan?, number?)
	local count = #target
	if count < MAPPED_MIN_ROWS or #source ~= count then
		return nil
	end

	local sourceIds: { [any]: number } = {}
	local sourceValues = {}
	local minimums: { number } = {}
	local maximums: { number } = {}

	for index = 1, count do
		local sourceValue = source[index]
		local targetValue = target[index]
		if sourceValue == nil or sourceValue ~= sourceValue then
			return nil
		end
		--[[
			Integers only. A float offset is not exact once it is packed, and a
			non-number has no frame of reference to take.
		]]
		if type(targetValue) ~= "number" or targetValue % 1 ~= 0 then
			return nil
		end

		local sourceId = sourceIds[sourceValue]
		if sourceId == nil then
			table.insert(sourceValues, sourceValue)
			sourceId = #sourceValues
			sourceIds[sourceValue] = sourceId
			minimums[sourceId] = targetValue
			maximums[sourceId] = targetValue
		else
			if targetValue < minimums[sourceId] then
				minimums[sourceId] = targetValue
			end
			if targetValue > maximums[sourceId] then
				maximums[sourceId] = targetValue
			end
		end
	end

	local distinctSource = #sourceValues
	if distinctSource * 2 > count then
		return nil
	end

	--[[
		The widest group sets the offset width; a single wide group defeats the
		form even when every other one is narrow.
	]]
	local widest = 0
	for sourceId = 1, distinctSource do
		local span = maximums[sourceId] - minimums[sourceId]
		if span > widest then
			widest = span
		end
	end

	--[[
		2^53 is where integer arithmetic stops being exact, so a span past it
		cannot be packed and read back unchanged.
	]]
	if widest >= 2 ^ 53 then
		return nil
	end

	local offsetBits = 1
	while offsetBits < MAX_PACK_BITS and 2 ^ offsetBits <= widest do
		offsetBits += 1
	end
	if offsetBits >= MAX_PACK_BITS and widest >= 2 ^ MAX_PACK_BITS then
		return nil
	end

	local references = table.create(distinctSource)
	for sourceId = 1, distinctSource do
		references[sourceId] = minimums[sourceId]
	end

	local offsets = table.create(count)
	for index = 1, count do
		offsets[index] = target[index] - references[sourceIds[source[index]]]
	end

	--[[
		Cost: one reference per distinct source value, then one packed offset
		per row. The source column is untouched.
	]]
	local total = varintWidth(distinctSource)
	for _, reference in references do
		total += integerCost(reference)
	end
	total += 1 + math.ceil(count * offsetBits / 8)

	if total + (extraBytes or 0) >= soloBytes then
		return nil
	end

	return {
		sourceValues = sourceValues,
		references = references,
		offsets = offsets,
		offsetBits = offsetBits,
	}, soloBytes - total
end

--[[
	Whether a column is another column, give or take a few rows.

	The narrowest of the correlation forms and the cheapest: no dictionary, no
	mapping, no per-row anything. Two columns that hold the same values need
	only one of them on the wire, and the other is a reference plus whatever
	rows disagree.

	Roblox save data is full of these. A part's `Position` and its
	`CFrame.Position`. `health` and `maxHealth` on a freshly spawned player. A
	display name that is the class name until someone renames it. Each pays for
	itself twice today.

	Measured on 400 rows differing in 8 of them:

		maxHealth -> health     402 B ->  29 B    -93%

	That is the highest saving of any scheme here, which matches the CWI work --
	it found Equality the strongest of the six by average gain (4.8x) even
	though it fires less often than the dictionary forms.

	The 1-to-1 mapping can express this too, and does when the exceptions are
	few enough, but it pays for a dictionary this does not need: 85 B against
	29 B on the same shape. Both are offered and the cost decides.

	Values compare by identity, so a column matches whatever the caller stored.

	The exception rows ascend by construction, which is worth something: their
	gaps are far smaller than the rows themselves, and a column of small numbers
	packs where a column of large ones does not. So the rows are offered twice --
	as varints, and as gaps packed at the width of the widest gap -- and the
	cheaper wins. On 309 exceptions across 30,000 rows that is 758 B against
	272 B, because a row index past 16,383 costs three varint bytes while every
	gap between them still fits in seven bits.

	`rowBits` is zero when the varints won, and the width of a packed gap
	otherwise.
]]
export type EqualityPlan = {
	exceptionRows: { number },
	exceptionValues: { any },
	rowBits: number,
}

--[[
	Whether a pair is worth costing at all.

	`equalityFor` scans every row of both columns before it can decline, and it
	is offered for every ordered pair of columns in every array. On data with no
	equal columns that is the whole of the work and none of the benefit: the
	correlation search doubled encode time on the canonical benchmark -- 393 ms
	to 918 ms, a flat 0.21 ms per array -- to find nothing.

	The columnar formats answer this by predicting from a sample rather than
	measuring in full; BtrBlocks and Vortex size a sample at ~1% and estimate
	the ratio before committing. A sample used as an *estimate* is unsound here,
	though. Rejecting a pair because more than a tenth of the sample disagreed
	throws away real correlations whenever two exceptions happen to land early:
	measured, that wrongly rejected 200 of 200 qualifying pairs.

	So the sample is used as a bound instead. Exceptions found so far can only
	grow as the scan continues, so once they exceed what the form allows for the
	whole column, no unseen row can bring the pair back. That makes a rejection
	final rather than probable, and the gate cannot cost a byte:

		real correlations wrongly rejected      0 of 380
		unrelated pairs skipped               200 of 200

	`sampleRows` rows are examined. Returning false means "cost it properly",
	not "it qualifies".
]]
local EQUALITY_SAMPLE_ROWS = 24
local EQUALITY_SAMPLE_SHARE = 16

function Columnar.equalityRuledOut(
	source: { any },
	target: { any },
	rowCount: number,
	sampleRows: number?
): boolean
	--[[
		A spread sixteenth of the column, at least `EQUALITY_SAMPLE_ROWS`.

		This read eight LEADING rows and compared the differences found against
		a tenth of the whole column -- so on two thousand rows it needed two
		hundred disagreements and could see at most eight. It could not fire,
		and measured 1.2 ms while leaving `equalityFor` to walk every pair in
		full at 151 microseconds each, 400 ms in total.

		Leading rows are the wrong sample besides: two columns that agree at the
		front and diverge later pass a leading probe entirely, and `mappedFor`'s
		equivalent was already scattered for that reason.
	]]
	local wanted = sampleRows
		or math.max(EQUALITY_SAMPLE_ROWS, rowCount // EQUALITY_SAMPLE_SHARE)
	local limit = math.min(wanted, rowCount)
	if limit < 2 then
		return false
	end

	local stride = math.max(1, rowCount // limit)
	local differing = 0
	local seenRows = 0

	for step = 0, limit - 1 do
		local index = 1 + step * stride
		if index > rowCount then
			break
		end

		local sourceValue = source[index]
		local targetValue = target[index]

		--[[
			A hole or a NaN makes the form decline outright, so meeting one is
			itself a rejection -- and neither compares usefully anyway.
		]]
		if targetValue == nil or targetValue ~= targetValue or sourceValue ~= sourceValue then
			return true
		end

		seenRows += 1
		if sourceValue ~= targetValue then
			differing += 1
		end
	end

	--[[
		The rate in the sample, against the tenth `equalityFor` allows. An
		estimate rather than a bound, for the reasons set out above
		`mappedRuledOut`: the sound form of this test cannot fire.
	]]
	return differing * 10 > seenRows
end

Columnar.EQUALITY_SAMPLE_ROWS = EQUALITY_SAMPLE_ROWS

--[[
	Whether a mapping between two columns is already ruled out.

	`equalityRuledOut` above covers one of the four correlated forms. The other
	three -- mapped, narrowed, and dictionary-for -- run on every pair with no
	cheap gate at all, and each makes three full passes over both columns before
	it can decline: numbering both into dictionaries, tallying source against
	target, then counting exceptions. On a pair that qualifies for nothing, all
	three passes are wasted.

	The bound is the same one `mappedFor` itself applies: a mapping stores one
	target per distinct source, so rows sharing a source value but disagreeing on
	the target force exceptions, and `mappedFor` declines once those exceed a
	tenth of the rows. The count taken here can only be lower than the full
	column's -- unsampled rows add to it, and a target that wins its group in the
	sample may lose in full, which adds more again -- so a sample already past
	that tenth cannot be redeemed by the rows it has not read.

	That soundness is the whole point, and it is why this does not follow the CWI
	framework's design directly. That work samples ~1% and *estimates* the ratio,
	accepting false rejections because it can measure the real size afterwards
	and reverse a bad choice. Zzzz has no reverse stage -- a pair rejected here
	is never revisited -- and estimating was measured on this codebase to reject
	200 of 200 qualifying pairs, because two exceptions landing early is enough
	to condemn a column that is otherwise perfectly determined.

	This began as a bound rather than an estimate, for that reason, and the
	bound was measured useless: see the note above the return, where comparing
	sampled exceptions against a tenth of the whole column turned out to be a
	test that essentially cannot fire. It is now a rate test over a spread
	sixteenth of the column, which is an estimate and can be wrong -- bounded by
	the sample being scattered rather than leading, and by the threshold being
	the form's own tenth, so a misjudged pair is one whose saving was marginal.

	Returning false means "cost it properly", never "it qualifies".

	Rows are taken spread across the column rather than from the front. The CWI
	measurements found scattered tuples strictly better than leading runs for
	this kind of gate, since these forms exploit no relationship between
	neighbours -- and a column sorted by the source value would otherwise show a
	single group and no exceptions at all in its first eight rows.
]]
--[[
	The sample is a fraction of the column rather than a fixed count.

	A fixed twenty-four rows makes the bound sound but useless. The rule it
	tests is "exceptions exceed a tenth of the rows", and comparing exceptions
	found in twenty-four samples against a tenth of two thousand rows can
	essentially never fire: two independent booleans produce about twelve
	exceptions in twenty-four samples -- half of them, which extrapolates to a
	thousand in the full column -- and `12 * 10 > 2000` is false.

	Measured consequence: two thousand pairs reached `mappedFor` on the
	canonical payload, each making three full passes to discover what the probe
	was meant to reject, at 572 microseconds a pair and 1,175 ms in total.

	Sampling a fixed FRACTION keeps the bound sound -- exceptions in a sample
	are still a lower bound on exceptions in the whole -- while making the
	comparison meaningful, because the tenth is then a tenth of what was
	actually looked at.
]]
local MAPPED_SAMPLE_ROWS = 24
local MAPPED_SAMPLE_SHARE = 16

function Columnar.mappedRuledOut(
	source: { any },
	target: { any },
	rowCount: number,
	sampleRows: number?
): boolean
	--[[
		At least `MAPPED_SAMPLE_ROWS`, and a sixteenth of the column beyond
		that, so the tenth being tested is a tenth of something real.
	]]
	local wanted = sampleRows
		or math.max(MAPPED_SAMPLE_ROWS, rowCount // MAPPED_SAMPLE_SHARE)
	local limit = math.min(wanted, rowCount)
	if limit < 2 then
		return false
	end

	--[[
		A stride across the whole column, so the rows examined are spread rather
		than consecutive. At least one, so a short column still advances.
	]]
	local stride = math.max(1, rowCount // limit)

	--[[
		How often each source value was seen with each target.

		The exception count has to be derived the way `mappedFor` derives it, or
		the bound is not a bound. That form keeps the target each source maps to
		MOST OFTEN and makes every other row an exception -- so counting "differs
		from the first target seen" over-counts: a source seen with A, B, B has
		one exception under the form, since B wins the group, but two under a
		first-seen comparison.

		Over-counting here would reject pairs the form would have accepted, which
		is precisely the unsound-estimate failure this gate exists to avoid.
	]]
	local tally: { [any]: { [any]: number } } = {}
	local seenRows = 0

	for step = 0, limit - 1 do
		local index = 1 + step * stride
		if index > rowCount then
			break
		end

		local sourceValue = source[index]
		local targetValue = target[index]

		--[[
			A hole or a NaN makes the form decline outright, so meeting one is
			itself a rejection -- and neither keys a mapping.
		]]
		if
			sourceValue == nil
			or targetValue == nil
			or sourceValue ~= sourceValue
			or targetValue ~= targetValue
		then
			return true
		end

		local group = tally[sourceValue]
		if group == nil then
			group = {}
			tally[sourceValue] = group
		end
		group[targetValue] = (group[targetValue] or 0) + 1
		seenRows += 1
	end

	--[[
		Every sampled row that is not the winning target of its group. This is a
		lower bound on the full column's exception count for two reasons: the
		rows not sampled can only add more, and a target winning its group in the
		sample may lose it in full, which would only raise the count further.
	]]
	local exceptions = seenRows
	for _, group in tally do
		local best = 0
		for _, seen in group do
			if seen > best then
				best = seen
			end
		end
		exceptions -= best
	end

	--[[
		The exception RATE in the sample, against the tenth `mappedFor` allows.

		This is an estimate, not a bound, and the change was made deliberately
		after the bound was measured useless. Comparing sampled exceptions
		against a tenth of the WHOLE column is sound -- unsampled rows can only
		add -- but it can essentially never fire: two independent booleans
		produce about half the sample as exceptions, and even a sixteenth of a
		two-thousand-row column gives 62, where 620 is still far below 2,000.

		Those figures came from a reconstruction of the search built outside
		the encoder, and counting inside it afterwards showed `mappedFor` is
		called ZERO times on that payload -- the reconstruction passed a
		different `anySolo` than the encoder computes, so its gates fired
		differently and it measured a search that does not happen.

		What the rate test is worth is therefore unmeasured on real data. It is
		kept because it is cheap and because the bound it replaced provably
		could not fire, not because a benchmark moved.

		An estimate can be wrong in the direction that costs bytes -- a pair
		whose sampled region disagrees more than the column as a whole is
		condemned. Two things bound that risk:

		  * the sample is a spread sixteenth of the column, not eight leading
		    rows, so an unrepresentative region has to be unrepresentative
		    everywhere rather than merely at the front

		  * the threshold is the form's own tenth, and a pair near enough to
		    that line to be misjudged is a pair whose saving was marginal

		This is the trade the CWI framework makes for the same reason, with the
		same acceptance: they sample at ~1%, tolerate false rejections, and
		measure the real size afterwards.
	]]
	return exceptions * 10 > seenRows
end

Columnar.MAPPED_SAMPLE_ROWS = MAPPED_SAMPLE_ROWS

--[[
	Whether the grouping forms can possibly beat carrying a column alone.

	`mappedFor` and `equalityFor` each have a bounded probe; `multiMappedFor`
	and `dictionaryForFor` had none, and both make a full pass before they can
	decline. On the canonical benchmark that is 91.5% of the pair search:

		57 hoisted columns, 40 of them booleans from an achievements array
		3,192 ordered pairs, 2,920 of which involve a boolean
		1,891 ms added at 2,000 players, to save zero bytes

	A boolean column defeats the early bail those forms already have. That bail
	fires when a source has more distinct values than half the column -- true of
	a high-cardinality column, never true of a coin flip -- so forty independent
	booleans each build their runs in full before the cost model rejects them.

	The bound here is the floor both forms pay REGARDLESS of what they find:
	one packed code per row, at a width of at least one bit. A column already
	costing less than a bit a row cannot be improved by a form whose cheapest
	possible output is a bit a row, whatever structure the pair turns out to
	have.

	That is a bound rather than an estimate -- it compares against the form's
	best case, not a sampled guess at its real case -- so it cannot reject a
	pair the form would have taken. Returning false means "cost it properly".
]]
function Columnar.groupingRuledOut(
	rowCount: number,
	distinctSource: number,
	soloBytes: number
): boolean
	if distinctSource < 2 then
		--[[
			One distinct source value groups everything together, which is not a
			grouping at all -- the forms decline it themselves, and cheaply.
		]]
		return true
	end

	--[[
		The codes alone, at one bit each. Both forms write one per row and no
		width is narrower, so this is the least either can cost before a single
		run length, dictionary entry or exception is counted.
	]]
	local floorBytes = math.ceil(rowCount / 8)
	return floorBytes >= soloBytes
end

function Columnar.equalityFor(
	source: { any },
	target: { any },
	soloBytes: number,
	extraBytes: number?
): (EqualityPlan?, number?)
	local count = #target
	if count < MAPPED_MIN_ROWS or #source ~= count then
		return nil
	end

	local exceptionRows = {}
	local exceptionValues = {}

	for index = 1, count do
		local sourceValue = source[index]
		local targetValue = target[index]
		if targetValue == nil then
			return nil
		end
		--[[
			NaN never equals itself, so a column holding one can never be called
			equal to anything -- including a column holding the same NaN.
		]]
		if targetValue ~= targetValue or sourceValue ~= sourceValue then
			return nil
		end

		if sourceValue ~= targetValue then
			table.insert(exceptionRows, index)
			table.insert(exceptionValues, targetValue)
		end
	end

	--[[
		Too many exceptions and the columns are not really the same; the patch
		list costs more than it saves. The same tenth the CWI work draws for the
		mapped form, and for the same reason.
	]]
	if #exceptionRows * 10 > count then
		return nil
	end

	--[[
		Cost: the exception count, then the row indices, then a value for each.
		The source column is untouched -- it is written as it would have been.

		The indices are costed both ways. Packed gaps carry a width byte and
		round up to a byte at the end, so they lose on a handful of exceptions in
		a short column and win once the indices outgrow a single varint byte.
	]]
	local total = varintWidth(#exceptionRows)

	local varintRows = 0
	local widestGap = 0
	local previousRow = 0
	for _, row in exceptionRows do
		varintRows += varintWidth(row)
		local gap = row - previousRow
		if gap > widestGap then
			widestGap = gap
		end
		previousRow = row
	end

	local rowBits = 0
	if #exceptionRows > 0 then
		local gapBits = if widestGap > 1 then math.ceil(math.log(widestGap + 1, 2)) else 1
		if gapBits <= MAX_PACK_BITS then
			local packedRows = 1 + math.ceil(#exceptionRows * gapBits / 8)
			if packedRows < varintRows then
				rowBits = gapBits
				total += packedRows
			else
				total += varintRows
			end
		else
			total += varintRows
		end
	end

	for index = 1, #exceptionRows do
		local entry = exceptionValues[index]
		if type(entry) == "string" then
			total += 2 + #entry
		elseif type(entry) == "number" and entry % 1 == 0 then
			total += integerCost(entry)
		else
			total += 5
		end
	end

	if total + (extraBytes or 0) >= soloBytes then
		return nil
	end

	return {
		exceptionRows = exceptionRows,
		exceptionValues = exceptionValues,
		rowBits = rowBits,
	}, soloBytes - total
end

--[[
	Whether a column is better written as runs than as rows.

	Every other form here pays something for each row. A column that holds the
	same value many times in a row need not: the value and how many times it
	repeats is the whole of it.

	This is worth stating plainly because it is the scheme most often assumed to
	be free and most often is not. Uniformly random data has no runs at all --
	every value is a run of one, so the length is pure overhead and the column
	grows. Measured on 400 rows:

		sorted guild ids, 8 runs     152 B ->  17 B    -89%
		200 true then 200 false       50 B ->   7 B    -86%
		random booleans               50 B     rejected
		random item names            151 B     rejected

	The rejections matter as much as the wins. Zzzz already bit-packs booleans
	at a bit a row and dictionary-encodes repeated strings, so RLE has to beat
	those, not the plain form -- and on shuffled data it does not come close.

	Where it does win is data with order to it: a roster sorted by team, terrain
	sampled in scan order, a log where several events share a timestamp, an
	inventory grouped by slot.

	The lengths get the same treatment as the equal form's exception rows, for
	the same reason: they cluster. A column of runs is rarely a column of one
	very long run and many short ones, so the widest length is usually close to
	the typical one, and packing at that width beats a varint apiece.

	`lengthBits` is zero when the varints won, and the packed width otherwise.
]]
export type RunLengthPlan = {
	values: { any },
	lengths: { number },
	lengthBits: number,
}

local RLE_MIN_ROWS = 8

function Columnar.runLengthFor(
	column: { any },
	soloBytes: number,
	extraBytes: number?
): (RunLengthPlan?, number?)
	local count = #column
	if count < RLE_MIN_ROWS then
		return nil
	end

	--[[
		Count the runs before building them.

		This built `values` and `lengths` as it walked and only then asked
		whether there were few enough runs to be worth anything -- so a column of
		unsorted data, which produces a run per row, allocated two tables the
		size of itself purely to discover that it had.

		The bail below is `runCount * 2 > count`, and `runCount` only ever grows,
		so the answer is known the moment it passes half. Scanning first lets
		that abort at the halfway point on exactly the columns that were paying
		most, and a column that does qualify pays one extra comparison per row.

		Measured over the write loop's real 8,060 columns this was the second
		most expensive qualifier of twelve, at 25.0 ms of 114.3. After the
		rewrite, 5.5 ms -- and the early abort is most of that, since a payload
		of unsorted columns reaches the halfway point and stops rather than
		walking to the end.
	]]
	local runCount = 0
	local previous: any = nil
	local started = false

	for index = 1, count do
		local entry = column[index]
		if entry == nil or entry ~= entry then
			return nil
		end
		if not started or previous ~= entry then
			runCount += 1
			--[[
				Past half, no arrangement of the rest can bring it back under the
				threshold, so there is nothing left to learn from the remaining
				rows.
			]]
			if runCount * 2 > count then
				return nil
			end
			previous = entry
			started = true
		end
	end

	--[[
		A run per row is what random data produces, and it is strictly worse
		than writing the rows. Bail before costing it.

		Re-checked here rather than trusted from the loop: a column short enough
		that the early abort never fired still has to pass.
	]]
	if runCount * 2 > count then
		return nil
	end

	--[[
		Runs confirmed worth having, so now they are built. Both tables are
		sized to the count the scan established rather than grown by insertion,
		and the nil and NaN checks are not repeated -- the scan above returned
		on either.
	]]
	local values = table.create(runCount)
	local lengths = table.create(runCount)
	local cursor = 0

	for index = 1, count do
		local entry = column[index]
		if cursor > 0 and values[cursor] == entry then
			lengths[cursor] += 1
		else
			cursor += 1
			values[cursor] = entry
			lengths[cursor] = 1
		end
	end

	--[[
		Cost: the run count, then a value and a length for each. Strings intern,
		so a repeated value costs its reference rather than its bytes -- but a
		run's value is distinct from its neighbours by construction, so only
		values recurring in a later run are charged that way.
	]]
	local total = varintWidth(runCount)
	local counted: { [any]: boolean } = {}

	local varintLengths = 0
	local widestLength = 0
	for _, length in lengths do
		varintLengths += varintWidth(length)
		if length > widestLength then
			widestLength = length
		end
	end

	local lengthBits = 0
	local packBits = if widestLength > 1 then math.ceil(math.log(widestLength + 1, 2)) else 1
	if packBits <= MAX_PACK_BITS then
		local packedLengths = 1 + math.ceil(runCount * packBits / 8)
		if packedLengths < varintLengths then
			lengthBits = packBits
			total += packedLengths
		else
			total += varintLengths
		end
	else
		total += varintLengths
	end

	for index = 1, runCount do
		local entry = values[index]

		if type(entry) == "boolean" then
			total += 1
		elseif type(entry) == "string" then
			if counted[entry] then
				total += 2
			else
				counted[entry] = true
				total += 2 + #entry
			end
		elseif type(entry) == "number" and entry % 1 == 0 then
			total += integerCost(entry)
		else
			total += 5
		end
	end

	if total + (extraBytes or 0) >= soloBytes then
		return nil
	end

	return {
		values = values,
		lengths = lengths,
		lengthBits = lengthBits,
	}, soloBytes - total
end

Columnar.RLE_MIN_ROWS = RLE_MIN_ROWS

--[[
	Whether a string column is really a column of dates.

	`YYYY-MM-DD` is the most common way a date reaches a serializer, and it is
	the most expensive: ten bytes of text for a value that is one number. Zzzz
	sees only bytes, so a column of them goes to the packet's string table and
	pays for every distinct date it holds. On a thousand sales records spanning
	twenty months that is 488 entries at twelve bytes each -- 5,856 bytes of
	table, against 1,125 bytes of ids referencing it. The table is the cost, and
	the ids were never the problem.

	As a day number the column has no table at all. Six hundred distinct days
	span ten bits, so the whole column is 1,250 bytes:

		488 dates as strings   5,856 B table + 1,125 B ids
		the same as day counts             1,250 B packed

	The conversion is Howard Hinnant's civil-from-days, which is exact over the
	whole proleptic Gregorian calendar -- verified here across 109,938
	consecutive dates from 1900 to 2200.

	Exactness of the *number* is not enough, though. The caller gets back a
	string, so the test is whether re-rendering reproduces the original bytes.
	That is what refuses `2024-1-4` (which would come back zero-padded),
	`2024-02-30` (which parses and is not a date), and anything with stray
	characters. A column containing one such value is not a date column, and
	the form declines rather than guessing.
]]
local DATE_MIN_ROWS = 8

local function daysFromCivil(year: number, month: number, day: number): number
	local shifted = if month <= 2 then year - 1 else year
	local era = math.floor(shifted / 400)
	local yearOfEra = shifted - era * 400
	local shiftedMonth = (month + 9) % 12
	local dayOfYear = math.floor((153 * shiftedMonth + 2) / 5) + day - 1
	local dayOfEra = yearOfEra * 365
		+ math.floor(yearOfEra / 4)
		- math.floor(yearOfEra / 100)
		+ dayOfYear
	return era * 146097 + dayOfEra - 719468
end

local function civilFromDays(z: number): (number, number, number)
	local shifted = z + 719468
	local era = math.floor(shifted / 146097)
	local dayOfEra = shifted - era * 146097
	local yearOfEra = math.floor(
		(dayOfEra - math.floor(dayOfEra / 1460) + math.floor(dayOfEra / 36524) - math.floor(
			dayOfEra / 146096
		)) / 365
	)
	local year = yearOfEra + era * 400
	local dayOfYear = dayOfEra - (365 * yearOfEra + math.floor(yearOfEra / 4) - math.floor(
		yearOfEra / 100
	))
	local shiftedMonth = math.floor((5 * dayOfYear + 2) / 153)
	local day = dayOfYear - math.floor((153 * shiftedMonth + 2) / 5) + 1
	local month = if shiftedMonth < 10 then shiftedMonth + 3 else shiftedMonth - 9
	return (if month <= 2 then year + 1 else year), month, day
end

Columnar.daysFromCivil = daysFromCivil
Columnar.civilFromDays = civilFromDays

export type DatePlan = {
	days: { number },
	low: number,
	bits: number,
	--[[
		Set when differencing the day numbers beat packing them as offsets. A
		log, an export, anything written once a day is a constant stride, and
		the offsets then carry the whole span on every row for no reason.
	]]
	order: number?,
	seeds: { number }?,
}

function Columnar.dateFor(
	column: { any },
	soloBytes: number,
	extraBytes: number?
): (DatePlan?, number?)
	local count = #column
	if count < DATE_MIN_ROWS then
		return nil
	end

	local days = table.create(count)
	local low, high = math.huge, -math.huge

	for index = 1, count do
		local entry = column[index]
		if type(entry) ~= "string" or #entry ~= 10 then
			return nil
		end

		local yearText, monthText, dayText = string.match(entry, "^(%d%d%d%d)-(%d%d)-(%d%d)$")
		if yearText == nil then
			return nil
		end

		local year = tonumber(yearText) :: number
		local month = tonumber(monthText) :: number
		local day = tonumber(dayText) :: number
		if month < 1 or month > 12 or day < 1 or day > 31 then
			return nil
		end

		local value = daysFromCivil(year, month, day)

		--[[
			The caller gets a string back, so the number being right is not the
			test -- reproducing the bytes is. This is what refuses a date that
			does not exist, since `2024-02-30` converts to March 1st and renders
			as something the caller never wrote.
		]]
		local checkYear, checkMonth, checkDay = civilFromDays(value)
		if string.format("%04d-%02d-%02d", checkYear, checkMonth, checkDay) ~= entry then
			return nil
		end

		days[index] = value
		if value < low then
			low = value
		end
		if value > high then
			high = value
		end
	end

	local span = high - low
	local bits = if span > 0 then math.ceil(math.log(span + 1, 2)) else 1
	if bits < 1 then
		bits = 1
	end
	if bits > MAX_PACK_BITS then
		return nil
	end

	--[[
		The width, the base, then the packed day numbers. The base is zigzagged
		on the wire because dates before 1970 are negative, so it is costed that
		way rather than as a plain varint -- which would read a negative as one
		byte and understate the form.
	]]
	local total = 1 + Columnar.zigzagWidth(low) + math.ceil(count * bits / 8)
	local order: number? = nil
	local seeds: { number }? = nil

	--[[
		Dates arrive on a stride far more often than not -- a daily log, a
		nightly export, a row per calendar day -- and packing them as offsets
		from the earliest makes every row carry the whole span. Differencing
		removes the stride instead, and on two thousand consecutive days it is
		the difference between eleven bits a row and one:

			flat pack     2,752 B
			differenced     253 B

		The same offer the decimal form makes, for the same reason.
	]]
	local packOrder, packSeeds, packBits = Columnar.differencedPackFor(days)
	if packOrder and packSeeds and packBits and packBits < bits then
		local differenced = 1
		for _, seed in packSeeds do
			differenced += zigzagWidth(seed)
		end
		differenced += math.ceil(count * packBits / 8)

		if differenced < total then
			total = differenced
			order = packOrder
			seeds = packSeeds
			bits = packBits
		end
	end

	if total + (extraBytes or 0) >= soloBytes then
		return nil
	end

	return {
		days = days,
		low = low,
		bits = bits,
		order = order,
		seeds = seeds,
	}, soloBytes - total
end

Columnar.DATE_MIN_ROWS = DATE_MIN_ROWS

--[[
	Whether a string column is a constant prefix around a fixed-width number.

	Identifiers are usually not text. `TXN-100001`, `REP-189`, `ORD-0042` are a
	label and a counter, and a serializer that sees only bytes pays for the
	label once per distinct value. On a thousand sales records that is a
	thousand distinct `TXN-1000NN` strings -- 12,000 bytes of string table for
	1,000 numbers that span ten bits.

	This is the narrow case of what the PIDS work calls attribute decomposition:
	infer a pattern, split the column into sub-attributes, and encode each with
	the scheme that suits it. PIDS infers general patterns by search; this takes
	only the shape that dominates identifier columns -- const + fixed-width int
	-- because it is the one worth a wire format of its own.

		1,000 TXN ids as strings   12,000 B of table
		as prefix + 10-bit ints         1,262 B

	The width is fixed rather than inferred per row, and that matters: 999 of
	those 1,000 counters carry a leading zero, so a decoder that renders the
	number without padding returns `TXN-101` where the caller wrote
	`TXN-100001`. Every value is rebuilt and compared during qualification, so
	a column that cannot be reproduced byte for byte is refused rather than
	guessed at.
]]
local PREFIXED_INT_MIN_ROWS = 8
local PREFIXED_INT_MIN_PREFIX = 2

export type PrefixedIntPlan = {
	prefix: string,
	suffix: string,
	width: number,
	values: { number },
	low: number,
	bits: number,
	--[[
		Set when differencing the counters beat packing them as offsets. A
		sparse counter that still ascends -- ids allocated in blocks, keys from
		a shared sequence -- carries its whole span on every row otherwise.
	]]
	order: number?,
	seeds: { number }?,
}

function Columnar.prefixedIntFor(
	column: { any },
	soloBytes: number,
	extraBytes: number?
): (PrefixedIntPlan?, number?)
	local count = #column
	if count < PREFIXED_INT_MIN_ROWS then
		return nil
	end

	local first = column[1]
	if type(first) ~= "string" then
		return nil
	end

	--[[
		The longest head every value shares. A column of one distinct value
		would make this the whole string and leave nothing to pack, which the
		width check below refuses.
	]]
	local prefix = first
	for index = 2, count do
		local entry = column[index]
		if type(entry) ~= "string" then
			return nil
		end

		local shared = 0
		local limit = math.min(#prefix, #entry)
		while shared < limit and string.byte(prefix, shared + 1) == string.byte(entry, shared + 1) do
			shared += 1
		end
		prefix = string.sub(prefix, 1, shared)

		if #prefix < PREFIXED_INT_MIN_PREFIX then
			return nil
		end
	end

	--[[
		The longest tail every value shares, found the same way.

		A constant suffix is as common as a constant prefix and just as wasteful
		-- `assets/models/item_1.rbxm` is a label, a number and an extension,
		and refusing the column over the extension left it three times larger
		than it needed to be. The suffix is measured on what remains after the
		prefix so the two cannot overlap on a short value.
	]]
	local suffix = string.sub(first, #prefix + 1)
	for index = 2, count do
		local rest = string.sub(column[index] :: string, #prefix + 1)
		local shared = 0
		local limit = math.min(#suffix, #rest)
		while
			shared < limit
			and string.byte(suffix, #suffix - shared) == string.byte(rest, #rest - shared)
		do
			shared += 1
		end
		suffix = string.sub(suffix, #suffix - shared + 1)
	end

	--[[
		A digit belongs to the number, not to the fixed text around it. Trimming
		trailing digits off the suffix keeps `item_12.rbxm` and `item_2.rbxm`
		from agreeing on a `2` that is really part of the counter.
	]]
	while #suffix > 0 and string.match(string.sub(suffix, 1, 1), "%d") do
		suffix = string.sub(suffix, 2)
	end
	while #prefix > 0 and string.match(string.sub(prefix, -1), "%d") do
		prefix = string.sub(prefix, 1, -2)
	end

	if #prefix < PREFIXED_INT_MIN_PREFIX and #suffix < PREFIXED_INT_MIN_PREFIX then
		return nil
	end

	--[[
		The counter's width. A column whose numbers are all the same width is
		zero-padded and must be rendered that way; one with mixed widths is not
		padded at all, and rendering it with `%d` reproduces it. Anything else --
		a padded column with an over-wide value, say -- fails the rebuild check
		below and the form declines.
	]]
	local width = #first - #prefix - #suffix
	if width < 1 or width > 18 then
		return nil
	end

	local fixedWidth = true
	for index = 2, count do
		if #(column[index] :: string) ~= #prefix + width + #suffix then
			fixedWidth = false
			break
		end
	end

	local values = table.create(count)
	local low, high = math.huge, -math.huge

	for index = 1, count do
		local entry = column[index]
		local tail = string.sub(entry, #prefix + 1, #entry - #suffix)
		if #tail < 1 or #tail > 18 then
			return nil
		end
		if string.match(tail, "^%d+$") == nil then
			return nil
		end

		local value = tonumber(tail) :: number

		--[[
			The caller gets a string back, so the number being right is not the
			test. `TXN-100001` holds `0001`, and rendering `1` without the
			padding returns something the caller never wrote -- which is the
			case there, on 999 of 1,000 rows.
		]]
		local rendered = if fixedWidth
			then prefix .. string.format(`%0{width}d`, value) .. suffix
			else prefix .. tostring(value) .. suffix
		if rendered ~= entry then
			return nil
		end

		values[index] = value
		if value < low then
			low = value
		end
		if value > high then
			high = value
		end
	end

	local span = high - low
	local bits = if span > 0 then math.ceil(math.log(span + 1, 2)) else 1
	if bits < 1 then
		bits = 1
	end
	if bits > MAX_PACK_BITS then
		return nil
	end

	--[[
		A counter that simply ascends is refused, and this is the one rule here
		that is about what happens *after* Zzzz.

		`TXN-100001` through `TXN-101000` is a thousand ids that differ by one.
		As text that is enormously redundant and a general-purpose compressor
		removes nearly all of it; measured through zstd at level 22, the ten
		thousand bytes of text become 935. Bit-packing the same counter gives
		1,250 bytes that no longer compress at all -- 1,260 after zstd -- so the
		form wins 8,750 bytes raw and loses 325 once the packet is compressed.

		Costing only the raw form takes that trade every time. A dense run has
		nothing left for packing to find that a compressor would not have found
		more cheaply, so it is left as text and the form keeps the cases where
		the counter is sparse or scattered, where packing wins either way.
	]]
	local dense = span > 0 and (span + 1) <= count * 2
	if dense then
		return nil
	end

	--[[
		The prefix once, its length, the width, the base, then the packed
		numbers. The prefix is the whole point: it is written a single time in
		place of once per distinct value.
	]]
	local total = 1
		+ #prefix
		+ 1
		+ #suffix
		+ 1
		+ Columnar.zigzagWidth(low)
		+ math.ceil(count * bits / 8)

	local order: number? = nil
	local seeds: { number }? = nil

	--[[
		A counter can be sparse enough to pass the density gate above and still
		ascend -- ids handed out in blocks, keys drawn from a shared sequence,
		anything sorted before it was written. Packing those as offsets makes
		every row carry the whole span; differencing carries the step instead:

			ascending by 977    1,197 B ->   71 B
			sorted at random    1,696 B -> 1,381 B
			random order        1,696 B      no gain, order 0

		The same offer the decimal and date forms make.
	]]
	local packOrder, packSeeds, packBits = Columnar.differencedPackFor(values)
	if packOrder and packSeeds and packBits and packBits < bits then
		local differenced = 1 + #prefix + 1 + #suffix + 1
		for _, seed in packSeeds do
			differenced += zigzagWidth(seed)
		end
		differenced += math.ceil(count * packBits / 8)

		if differenced < total then
			total = differenced
			order = packOrder
			seeds = packSeeds
			bits = packBits
		end
	end

	if total + (extraBytes or 0) >= soloBytes then
		return nil
	end

	return {
		prefix = prefix,
		suffix = suffix,
		--[[
			Zero means the counter was not zero-padded and is rendered with as
			many digits as it has; anything else is the fixed width every value
			shares.
		]]
		width = if fixedWidth then width else 0,
		values = values,
		low = low,
		bits = bits,
		order = order,
		seeds = seeds,
	}, soloBytes - total
end

Columnar.PREFIXED_INT_MIN_ROWS = PREFIXED_INT_MIN_ROWS

--[[
	Whether a column is present on only some of its rows.

	Every other form in this file needs a complete column and returns `nil` the
	moment it meets a hole. That is the right instinct -- a hole is not a value
	and cannot be differenced, packed or mapped -- but it left an ordinary shape
	with no representation at all. An inventory where only some items are
	enchanted, a quest log where only finished quests have a completion time, a
	player row where a guild is optional: all of them fell back to plain
	key-value encoding for *every* row, several times larger.

	The separation the columnar formats settled on is to treat presence as
	structure rather than data. Arrow calls it a validity bitmap, Parquet a
	definition level, ORC a present bit-vector; all three store which rows have
	a value separately from what the values are, and store nothing at all for
	the rows that do not.

	Here that is a bit a row for the bitmap, then the present values as a
	complete column that every other form can then encode normally. Measured
	against the fallback on 4,000 rows:

		one field missing on  5% of rows    29,015 B -> ~5,210 B   5.6x
		one field missing on 50% of rows    27,215 B -> ~4,525 B   6.0x
		one field missing on 90% of rows    25,615 B -> ~3,935 B   6.5x

	`present` is the bitmap and `values` the rows that have one, in row order.
]]
export type OptionalPlan = {
	present: { boolean },
	values: { any },
}

function Columnar.optionalFor(column: { any }, rowCount: number): OptionalPlan?
	--[[
		Look before allocating.

		This built `present` and `values` up front and filled them while it
		walked, then threw both away when the column turned out to have no holes
		-- which is the overwhelmingly common case. It is also the FIRST
		qualifier the write loop asks, so it ran on every column of every array:
		8,060 columns on the canonical payload, 16,120 tables allocated, almost
		all of them discarded immediately.

		Measured over those columns, it was the single most expensive qualifier
		of the twelve, at 29.3 ms of 114.3. After the rewrite, 4.8 ms -- sixth
		of twelve, and the whole qualifier block fell to 87.3.

		A hole costs one comparison per row to find. Counting them first means a
		complete column -- no holes -- pays that scan and nothing else, and only
		a column that is genuinely optional allocates anything.

		The NaN refusal has to stay in the scan rather than move below it: a NaN
		anywhere means the form declines, and finding that out early also skips
		the allocation.
	]]
	local missing = 0
	for index = 1, rowCount do
		local entry = column[index]
		if entry == nil then
			missing += 1
		elseif entry ~= entry then
			--[[
				NaN is a value that is present, so it belongs in the value
				column -- but no form downstream can hold one, and the plain
				form writes it faithfully. Refusing here keeps the hole and the
				not-a-number cases from being confused with each other.
			]]
			return nil
		end
	end

	--[[
		Nothing missing means the column is not optional at all, and the caller
		has better forms for it. Nothing present means there is no column here,
		only an absence, which the shape itself already records.

		Checked before anything is built, which is the point of the scan above.
	]]
	if missing == 0 or missing == rowCount then
		return nil
	end

	--[[
		Only now, with holes confirmed, is it worth building the two tables.
		`values` is sized to what the scan counted rather than grown by
		insertion.
	]]
	local present = table.create(rowCount)
	local values = table.create(rowCount - missing)
	local cursor = 0

	for index = 1, rowCount do
		local entry = column[index]
		if entry == nil then
			present[index] = false
		else
			present[index] = true
			cursor += 1
			values[cursor] = entry
		end
	end

	--[[
		The bitmap is a bit a row whether or not the holes are worth it, and a
		column with a handful of them pays more for the map than the absences
		save. Every other form here costs itself before it is chosen; this one
		did not, and fired on any column with a single hole -- which cost bytes
		on a nested dataset rather than saving them.

		A hole saves writing one value. The cheapest a value can be is a byte,
		so that is what it is credited with: the comparison stays conservative
		and the form is only taken when it wins on the pessimistic count.
	]]
	local bitmapBytes = math.ceil(rowCount / 8)
	if bitmapBytes >= missing then
		return nil
	end

	return {
		present = present,
		values = values,
	}
end

--[[
	Whether a float column is really a column of decimals.

	Every other numeric form here refuses a value with a fractional part, and
	for good reason: a double cannot be differenced or bit-packed without
	changing it. So a float column falls through to a tag and eight bytes a
	row, and stays there.

	That is a lot to pay for data that is usually not floating-point at all. A
	sensitivity slider is hundredths, a volume is tenths, a price ends in .99, a
	position sits on a half-stud grid. Each was a decimal before it was a
	double, and the double is only how it got stored.

	The fix is to find the decimal back. For a whole column, one exponent `e`
	and one factor `f` such that

		encode:  d = round(n * 10^e / 10^f)
		decode:  n = d * 10^f / 10^e

	returns the original bits. The integers `d` then go through frame of
	reference and bit-packing like any other integer column:

		2000 sensitivity values   18,000 B -> 1,757 B    -90%

	This is ALP (Afroozeh, Kuffo and Boncz, SIGMOD 2024). The factor `f` is
	what makes it work where a plain "multiply until the decimals run out"
	does not: a high exponent recovers the exact double where a low one fails,
	but produces huge integers, and dividing the trailing zeros back out leaves
	a small integer that still decodes exactly.

	The paper searches per 1024-value vector; a column here is one block, so
	the pair is chosen once for the column and written once.

	Values that do not survive the round trip travel as exceptions, capped at a
	tenth of the rows. Data that never was decimal -- physics velocities, true
	doubles -- blows that cap or packs no smaller, and is refused:

		true random doubles       18,000 B     rejected
		physics velocities        18,000 B     rejected
]]
export type DecimalPlan = {
	exponent: number,
	factor: number,
	values: { number },
	low: number,
	bits: number,
	exceptionRows: { number },
	exceptionValues: { number },
	--[[
		Set only when differencing beat the flat pack. `order` is 0, 1 or 2 and
		`seeds` are the values that reseed each integration; when absent the
		integers are packed as offsets from `low`, as they always were.
	]]
	order: number?,
	seeds: { number }?,
}

--[[
	10^e is exact in a double up to e = 22, which is the whole usable range;
	past that the powers themselves stop being representable.
]]
local MAX_DECIMAL_EXPONENT = 18
local DECIMAL_MIN_ROWS = 8

--[[
	`minRows` overrides the eight-row floor, and only one caller does so.

	Eight is right for a column inside a shape: the form's framing competes with
	whatever else could carry those rows, and below eight the alternatives win.
	A flat array is a different bargain -- there is no alternative form at all,
	only a tag and eight bytes per value -- so the framing is repaid at two
	values, and refusing those arrays is what left a mixed packet larger than
	JSON.
]]
function Columnar.decimalFor(
	column: { any },
	soloBytes: number,
	extraBytes: number?,
	minRows: number?
): (DecimalPlan?, number?)
	local count = #column
	if count < (minRows or DECIMAL_MIN_ROWS) then
		return nil
	end

	--[[
		Integer columns are already served by the differenced and packed forms,
		which are cheaper than carrying an exponent. Only a column with a real
		fractional part has anything to gain here.
	]]
	local fractional = false
	for index = 1, count do
		local entry = column[index]
		if type(entry) ~= "number" then
			return nil
		end
		-- NaN and the infinities have no decimal form.
		if entry ~= entry or entry == math.huge or entry == -math.huge then
			return nil
		end
		if entry % 1 ~= 0 then
			fractional = true
		end
	end
	if not fractional then
		return nil
	end

	local best: DecimalPlan? = nil
	local bestTotal = math.huge

	--[[
		The search is over pairs, but a column shares one decimal precision far
		more often than not, so the first exponent that encodes everything is
		usually the answer. Trying `f` from `e` downwards finds the smallest
		integers first.
	]]
	for exponent = 0, MAX_DECIMAL_EXPONENT do
		local scale = 10 ^ exponent

		for factor = 0, exponent do
			local divisor = 10 ^ factor
			local encoded = table.create(count)
			local exceptionRows = {}
			local exceptionValues = {}
			local low, high = math.huge, -math.huge
			local viable = true

			for index = 1, count do
				local entry = column[index]
				local scaled = entry * scale / divisor

				--[[
					Past 2^53 a double cannot hold an exact integer, so the
					rounding below would not survive the return trip.
				]]
				if scaled ~= scaled or scaled >= 2 ^ 53 or scaled <= -(2 ^ 53) then
					viable = false
					break
				end

				local rounded = if scaled >= 0
					then math.floor(scaled + 0.5)
					else -math.floor(-scaled + 0.5)

				if rounded * divisor / scale == entry then
					encoded[index] = rounded
					if rounded < low then
						low = rounded
					end
					if rounded > high then
						high = rounded
					end
				else
					--[[
						A value the pair cannot express. It still needs a slot in
						the packed run, and the low end is the cheapest one that
						cannot widen the column.
					]]
					encoded[index] = nil
					table.insert(exceptionRows, index)
					table.insert(exceptionValues, entry)
					if #exceptionRows * 10 > count then
						viable = false
						break
					end
				end
			end

			if viable and #exceptionRows < count then
				--[[
					Exceptions take the column's low value in the packed run, so
					they cost their own storage and nothing in width.
				]]
				for _, row in exceptionRows do
					encoded[row] = low
				end

				local span = high - low
				local bits = 1
				while bits < MAX_PACK_BITS and 2 ^ bits <= span do
					bits += 1
				end

				if 2 ^ bits > span then
					--[[
						Cost: the pair, the frame of reference, the packed
						integers, then any exceptions as a row and a full double.
					]]
					local total = 2 + zigzagWidth(low) + 1
					total += math.ceil(count * bits / 8)
					total += varintWidth(#exceptionRows)
					total += #exceptionRows * (varintWidth(count) + 9)

					if total < bestTotal then
						bestTotal = total
						best = {
							exponent = exponent,
							factor = factor,
							values = encoded,
							low = low,
							bits = bits,
							exceptionRows = exceptionRows,
							exceptionValues = exceptionValues,
						}
					end
				end
			end
		end

		--[[
			A pair that encodes the whole column exactly will not be beaten by a
			higher exponent, which can only make the integers larger.
		]]
		if best and #best.exceptionRows == 0 then
			break
		end
	end

	if best == nil then
		return nil
	end

	--[[
		The scaled integers may have a trend, and until now nothing removed it.

		The pair search finds the exponent that makes the values integral, then
		packs them at the width of their whole range -- which is frame of
		reference, not differencing. A decimal column that climbs pays for its
		range on every row even when each step is identical. Measured on two
		thousand rows:

			price drifting up    3,255 B -> 1,756 B    order 1, 13 bits -> 7
			sensor at 1dp        2,755 B ->   256 B    order 2, 11 bits -> 1
			cumulative total     4,505 B ->   256 B    order 2, 18 bits -> 1
			random 2dp             4,255 B      no gain, order 0 chosen

		So the integers are offered to the same differencing the integer columns
		use, and the cheaper of the two wins. A column with no trend picks order
		0 and is unchanged, which is why the control above is untouched.

		Only exception-free plans are differenced: an exception holds `low` in
		the packed run as a placeholder, and differencing a placeholder would
		make the reconstruction depend on a value that is not really there.
	]]
	if #best.exceptionRows == 0 then
		local order, seeds, packBits = Columnar.differencedPackFor(best.values)
		if order and seeds and packBits and packBits < best.bits then
			local differencedTotal = 2 + 1 + 1
			for _, seed in seeds do
				differencedTotal += zigzagWidth(seed)
			end
			differencedTotal += math.ceil(count * packBits / 8)
			differencedTotal += varintWidth(0)

			if differencedTotal < bestTotal then
				bestTotal = differencedTotal
				best.order = order
				best.seeds = seeds
				best.bits = packBits
			end
		end
	end

	if bestTotal + (extraBytes or 0) >= soloBytes then
		return nil
	end

	return best, soloBytes - bestTotal
end

Columnar.DECIMAL_MIN_ROWS = DECIMAL_MIN_ROWS

--[[
	Whether an integer column should be differenced before it is packed.

	`bitPackFor` stores value - min, which is frame of reference: it removes the
	column's offset but not its trend. A column that climbs steadily still needs
	enough bits for its whole range, so a thousand timestamps 33ms apart need 15
	bits each even though every step is identical.

	Differencing removes the trend instead:

		order 0   the values          FOR, what bitPackFor already does
		order 1   first differences   a steady climb becomes a constant
		order 2   second differences  a constant rate becomes a run of zeros

	Order 2 is the "delta of delta" TurboPFor and Gorilla use for metronomic
	series -- timestamps on a fixed tick, frame counters, autosave epochs. On a
	genuinely constant interval it collapses the column to 1-bit zeros:

		500 tick timestamps    FOR 944 B    delta 443 B    delta-of-delta 70 B

	It is chosen, never assumed, because it is actively worse on data that only
	looks similar. Second differences of an irregular climb are as random as the
	first, plus one more value of framing:

		ids += random(1, 9)    delta 315 B    delta-of-delta 316 B
		levels 1..50           FOR  377 B     delta-of-delta 501 B

	Each order is costed exactly and the smallest wins, so the trend-removal only
	applies where the trend is real. Across mixed column shapes this is 46.5%
	smaller than frame of reference alone, and never larger.

	Returns the order, the base values that seed the reconstruction, the bit
	width, and the saving -- or nil when plain packing is already best.
]]
local MAX_DIFFERENCE_ORDER = 2

local function packedCost(count: number, bits: number, baseCount: number): number
	--[[
		A width byte, an order byte, the seed values as zigzag varints, then the
		bits themselves. Seeds are counted at their real width rather than
		assumed, since a timestamp seed is five bytes and a small one is one.
	]]
	return 2 + baseCount + math.ceil(count * bits / 8)
end

function Columnar.differencedPackFor(
	column: { any }
): (number?, { number }?, number?, number?)
	local count = #column
	if count < MIN_ROWS then
		return nil
	end

	--[[
		Validate before allocating, like the two qualifiers above.

		`values` was allocated at full size and filled as the column was checked,
		so a column that fails at its FIRST entry -- a string column, a float
		column, anything not integral -- still paid for a table the length of
		itself. That is the common case: this is asked of every column, and most
		columns are not integers.

		The scan below touches each entry once and allocates nothing until the
		column is known to qualify. A column that does qualify is walked twice
		instead of once, which is the trade: one extra pass over integers, in
		exchange for no allocation at all on everything else.

		Measured over the write loop's 8,060 real columns, this was the most
		expensive qualifier of the twelve at 35.2 ms of 87.3 -- and it is the
		one every column reaches, because it is not gated on row count or type.
		Removing the early allocation took it to 21.4 ms, and merging the two
		passes and dropping the copy took it to 17.2 -- 35.2 to 17.2 in all,
		while the whole qualifier block went 114.3 to 71.3.

		The identical change applied to `frequencyFor` measured nothing, because
		that one is only ever reached with an integral column already in hand.
		See the note there.
	]]
	--[[
		The first entry first, so a non-integer column costs one check rather
		than a walk. The full scan still follows, so a column that is integral
		only at its head is refused exactly as before.
	]]
	local first = column[1]
	if type(first) ~= "number" or first % 1 ~= 0 then
		return nil
	end

	--[[
		One pass that validates, prices and finds the range together.

		Splitting the validation out was the previous fix here, and it left two
		full walks where the original had one -- the check, then a copy that
		summed `integerCost`. Both touch every value, and the second only exists
		to build `values`.

		`values` was itself only ever a copy of `column`: order 0 reads it
		without modifying it, and the higher orders build fresh tables of their
		own. So the copy is dropped and order 0 reads the column directly, which
		removes an allocation the size of every integer column in the payload.

		Order 0's range is also computed here rather than in the loop below. It
		is a min and a max over the same values this pass already visits, and
		computing it twice was the only reason the loop needed a separate branch
		for order 0 at all.

		The range feeds the packed bit width, so an error of one in either bound
		is an error of one in the width -- which either corrupts the packet or
		silently costs bytes. `test_differenced_rewrite.lua` pins both sides of a
		bit boundary for that reason: a span of 255 must choose 8 bits and 256
		must choose 9, and both are checked by encoding and reading back rather
		than by inspecting the plan.
	]]
	local plainBytes = 0
	local low = math.huge
	local high = -math.huge

	for index = 1, count do
		local entry = column[index]
		if type(entry) ~= "number" or entry % 1 ~= 0 then
			return nil
		end
		if entry > MAX_DIFFERENCE_VALUE or entry < -MAX_DIFFERENCE_VALUE then
			return nil
		end
		plainBytes += integerCost(entry)
		if entry < low then
			low = entry
		end
		if entry > high then
			high = entry
		end
	end

	local bestOrder: number? = nil
	local bestSeeds: { number }? = nil
	local bestBits: number? = nil
	local bestBytes = plainBytes

	--[[
		Order 0 is the values themselves, offset by the minimum -- the same form
		bitPackFor produces. Higher orders difference the previous series and
		zigzag it, since differences go negative.
	]]
	local series = column
	local seeds: { number } = {}

	for order = 0, MAX_DIFFERENCE_ORDER do
		if order > 0 then
			local length = #series
			if length < 2 then
				break
			end

			-- The first element of each order seeds the reconstruction.
			table.insert(seeds, series[1])

			local differences = table.create(length - 1)
			for index = 2, length do
				differences[index - 1] = series[index] - series[index - 1]
			end
			series = differences
		end

		local length = #series
		if length == 0 then
			break
		end

		--[[
			Order 0 packs value - min; the higher orders pack the zigzagged
			differences, whose own minimum is not worth removing separately.

			Order 0's range came from the validating pass above, which already
			visited exactly these values -- so what was a second min-and-max walk
			over the whole column is now a subtraction.
		]]
		local widest = 0
		local packLow = 0

		if order == 0 then
			packLow = low
			widest = high - low
		else
			for index = 1, length do
				local value = series[index]
				local zigzagged = if value < 0 then -value * 2 - 1 else value * 2
				if zigzagged > widest then
					widest = zigzagged
				end
			end
		end

		if widest ~= widest or widest == math.huge then
			break
		end

		local bits = 1
		while bits < MAX_PACK_BITS and 2 ^ bits <= widest do
			bits += 1
		end

		if 2 ^ bits > widest then
			--[[
				Seeds for orders above zero, or the minimum for order zero. Both
				travel as zigzag varints.
			]]
			local seedBytes = 0
			local candidateSeeds: { number }
			if order == 0 then
				candidateSeeds = { packLow }
			else
				candidateSeeds = table.clone(seeds)
			end
			for _, seed in candidateSeeds do
				seedBytes += zigzagWidth(seed)
			end

			local candidateBytes = packedCost(length, bits, seedBytes)
			if candidateBytes < bestBytes then
				bestOrder = order
				bestSeeds = candidateSeeds
				bestBits = bits
				bestBytes = candidateBytes
			end
		end
	end

	if not bestOrder then
		return nil
	end

	return bestOrder, bestSeeds, bestBits, plainBytes - bestBytes
end

--[[
	Whether a column repeats on a fixed period.

	Cyclic data is everywhere in a game and no form here saw it. An hour of the
	day, a weekday, a patrol route, an idle bob, a looping tween, terrain
	sampled on a grid, `index % teamCount`. Every one of those is a short cycle
	repeated, and all three existing forms miss the structure for different
	reasons:

		dictionary    sees 60 distinct values, pays log2(60) = 5.9 bits a row,
		              and never notices the ORDER is fixed
		differencing  turns it into +1 fifty-nine times and -59 once; the
		              outlier sets the packed width, so every row pays for it
		run length    needs repeats of the same value, and a cycle has none

	The advantage grows without limit in the row count, because the form's cost
	is the period and nothing else. Measured as whole packets, one column:

		    32 rows, period 8     20 B    5.00 bits a row
		   500 rows, period 8     21 B    0.34
		 2,000 rows, period 8     21 B    0.08
		10,000 rows, period 8     22 B    0.02

	Five hundred times the rows for one extra byte. It is chosen from 32 rows
	upward, and across many arrays it still wins at eight rows each -- the
	per-array descriptor is small enough that the crossover is lower than a
	cost model of the form alone predicts.

	Measured as whole packets, against the modelled cost of whichever form the
	encoder would otherwise have picked -- 1,000 rows a column:

		hour of day             627 B ->  33 B   -94.7%
		weekday                 377 B ->  21 B   -94.4%
		levels 1-60             752 B ->  63 B   -91.6%
		cycle on a rising base  753 B ->  64 B   -91.5%
		looping tween, 2s     1,176 B -> 228 B   -80.6%
		one break per 97 rows   814 B -> 177 B   -78.3%
		patrol path             504 B -> 133 B   -73.6%

		across the set        5,003 B -> 719 B   -85.6%

	The `after` figures are real packets and carry framing the `before` model
	does not -- a shape id, the key name, a plan definition, the row count. A
	cost model of the form alone puts `levels 1-60` at 13 bytes rather than 63;
	the other fifty are what it costs to be a column in a packet at all, and
	they are charged here rather than hidden.

	An entropy floor put `levels 1-60` at 51.7x its theoretical minimum, the
	widest gap measured anywhere in the library; this closes 98.3% of it.

	Three things the form has to get right, each of which a first attempt got
	wrong and the cost model caught:

	  * IT COMPOSES WITH DIFFERENCING rather than competing. A cycle on a
	    rising base -- a looping animation on a moving object, which is far
	    more common than a loop returning exactly to its start -- never repeats
	    a raw value. Differencing removes the trend and leaves the cycle, since
	    the derivative of a periodic function is periodic.

	  * PERIOD 1 IS NOT A CYCLE. It is a constant, which has its own form and
	    reaches 0.13 bits a row. Claiming it reported a 96% win against a
	    baseline no encoder would have chosen.

	  * A DIFFERENCED STRAIGHT LINE IS NOT A CYCLE. `1, 2, 3, ...` differences
	    to a single repeated value; calling that "period 2" claimed a 94.5% win
	    on a column plain differencing had already collapsed.
]]
local CYCLE_MIN_ROWS = 32
local CYCLE_MAX_PERIOD = 128
--[[
	A period has to appear at least four times to be one. Two occurrences is a
	coincidence and the form would be storing half the column to describe the
	other half.
]]
local CYCLE_MIN_REPEATS = 4
local CYCLE_PROBES = 16

export type CyclicPlan = {
	period: number,
	cycle: { number },
	-- Set when the cycle was found in the column's differences rather than in
	-- its values, in which case `seed` starts the reconstruction.
	differenced: boolean,
	seed: number?,
	exceptionRows: { number },
	exceptionValues: { number },
}

--[[
	The smallest exact period of `values`, or nil.

	Candidates are rejected on a spread of probes before any is confirmed in
	full. A period p means `values[i] == values[i + p]` everywhere, so a single
	disagreeing probe rules it out -- and probing sixteen positions rejects a
	non-cyclic column in 127 comparisons where confirming every candidate in
	full takes 8,382:

		column            exact checks    probed checks
		levels 1-60              2,827            1,157
		period 120               8,258            1,143
		not cyclic               8,382              127

	The probe only ever rejects; every survivor is then confirmed against the
	whole column, so a wrong period cannot reach the wire. That is the same
	bound-not-estimate rule `mappedRuledOut` follows, and for the same reason.
]]
local function exactPeriod(values: { number }, count: number): number?
	local limit = math.min(CYCLE_MAX_PERIOD, count // CYCLE_MIN_REPEATS)

	for period = 2, limit do
		local probed = true

		--[[
			Positions spread across the column rather than consecutive ones. A
			cycle that breaks only in its second half would survive any number
			of probes taken from the front.
		]]
		local span = count - period
		if span > 0 then
			for probe = 0, CYCLE_PROBES - 1 do
				local index = 1 + (probe * span) // CYCLE_PROBES
				if values[index] ~= values[index + period] then
					probed = false
					break
				end
			end
		end

		if probed then
			local exact = true
			for index = 1, count do
				--[[
					`(index - 1) % period + 1` rather than `index % period`
					because Luau indexes from one; the off-by-one would compare
					every row against the wrong element of the cycle.
				]]
				if values[index] ~= values[(index - 1) % period + 1] then
					exact = false
					break
				end
			end
			if exact then
				return period
			end
		end
	end

	return nil
end

--[[
	What a cyclic plan costs: the period, the cycle itself, and any exceptions.

	The cycle is a column in its own right, so it is priced with the packing
	rules rather than written plainly -- a cycle that ramps packs, and one with
	few distinct values is short enough that it hardly matters.
]]
local function cyclicCost(
	period: number,
	cycle: { number },
	low: number,
	high: number,
	exceptionRows: { number },
	exceptionValues: { number },
	differenced: boolean
): number
	local total = 1 + varintWidth(period)

	local bits = 1
	local span = high - low
	while bits < 64 and 2 ^ bits <= span do
		bits += 1
	end

	total += 1 + zigzagWidth(low) + math.ceil(period * bits / 8)

	if differenced then
		total += 1
	end

	total += varintWidth(#exceptionRows)
	for index, row in exceptionRows do
		total += varintWidth(row) + zigzagWidth(exceptionValues[index])
	end

	return total
end

--[[
	Whether `column` is better carried as a cycle.

	`soloBytes` is what it costs in whatever form the encoder would otherwise
	choose, and `extraBytes` covers a plan definition this form may introduce.
	Returns the plan and the saving, or nil.
]]
function Columnar.cyclicFor(
	column: { any },
	soloBytes: number,
	extraBytes: number?
): (CyclicPlan?, number?)
	local count = #column
	if count < CYCLE_MIN_ROWS then
		return nil
	end

	local values = table.create(count)
	for index = 1, count do
		local entry = column[index]
		--[[
			Integers only. A float column reaches this through the decimal
			form's scaled integers, which is where the looping-tween measurement
			above comes from; letting raw floats in would compare values that
			are equal in every way that matters and unequal by a bit.
		]]
		if type(entry) ~= "number" or entry % 1 ~= 0 then
			return nil
		end
		if entry > MAX_DIFFERENCE_VALUE or entry < -MAX_DIFFERENCE_VALUE then
			return nil
		end
		values[index] = entry
	end

	local best: CyclicPlan? = nil
	local bestBytes = soloBytes - (extraBytes or 0)

	--[[
		The values themselves, then their differences. Two passes rather than
		one because a cycle riding on a trend is invisible to the first and is
		the more common shape of the two.
	]]
	for _, differenced in { false, true } do
		local series = values
		local seed: number? = nil

		if differenced then
			if count < CYCLE_MIN_ROWS + 1 then
				continue
			end
			seed = values[1]
			local steps = table.create(count - 1)
			local distinct = 0
			local seen: { [number]: boolean } = {}
			for index = 2, count do
				local step = values[index] - values[index - 1]
				steps[index - 1] = step
				if not seen[step] then
					seen[step] = true
					distinct += 1
				end
			end
			--[[
				One distinct difference is a straight line, which plain
				differencing already collapses to a single packed bit. Claiming
				it here would win against a baseline that had already solved the
				column.
			]]
			if distinct < 2 then
				continue
			end
			series = steps
		end

		local seriesCount = #series
		local period = exactPeriod(series, seriesCount)

		--[[
			No exact period, so try the near ones: a cycle whose few departures
			are cheaper to list than to abandon the form for.

			Candidates are probed before being costed. Without that this walked
			every period from 2 to 128 and counted exceptions across the whole
			column for each, which took 3.967 ms on a column with no cycle at
			all -- and a column with no cycle is what almost every integer
			column in a packet is. The probe brings that to a fraction by
			rejecting on a handful of comparisons.

			The threshold is deliberately loose: a period whose probes mostly
			agree is worth costing properly, since the exception path exists for
			exactly the cycles that do not fit perfectly. It only has to be
			tight enough to reject noise.
		]]
		local candidates: { number } = {}
		if period then
			table.insert(candidates, period)
		else
			local limit = math.min(CYCLE_MAX_PERIOD, seriesCount // CYCLE_MIN_REPEATS)
			for candidate = 2, limit do
				local span = seriesCount - candidate
				if span > 0 then
					local agreed = 0
					for probe = 0, CYCLE_PROBES - 1 do
						local index = 1 + (probe * span) // CYCLE_PROBES
						if series[index] == series[index + candidate] then
							agreed += 1
						end
					end
					--[[
						Three quarters of the probes, against the tenth of rows
						the exception rule allows. A real cycle with scattered
						departures still clears this; noise does not.
					]]
					if agreed * 4 >= CYCLE_PROBES * 3 then
						table.insert(candidates, candidate)
					end
				end
			end
		end

		for _, candidate in candidates do
			local cycle = table.create(candidate)
			local cycleLow, cycleHigh = series[1], series[1]
			for index = 1, candidate do
				local entry = series[index]
				cycle[index] = entry
				if entry < cycleLow then
					cycleLow = entry
				end
				if entry > cycleHigh then
					cycleHigh = entry
				end
			end

			--[[
				A cycle whose every element is the same value is not a cycle.

				It describes a constant series, which the constant and run-length
				forms already carry for nothing, and the exception list then does
				all the real work -- badly. Measured before this guard: a column
				of `i % 500` over 1,000 rows, whose differences are +1 four
				hundred and ninety-nine times and one -499, was claimed as
				"period 2" and reported saving 389 bytes against a column plain
				differencing already held in 128.

				The cycle has to vary for the period to mean anything.
			]]
			if cycleHigh == cycleLow then
				continue
			end

			local exceptionRows = {}
			local exceptionValues = {}
			local tooMany = false

			for index = 1, seriesCount do
				local expected = cycle[(index - 1) % candidate + 1]
				if series[index] ~= expected then
					table.insert(exceptionRows, index)
					table.insert(exceptionValues, series[index])
					if #exceptionRows * 10 > seriesCount then
						tooMany = true
						break
					end
				end
			end

			if not tooMany then
				local total = cyclicCost(
					candidate,
					cycle,
					cycleLow,
					cycleHigh,
					exceptionRows,
					exceptionValues,
					differenced
				)
				if total < bestBytes then
					bestBytes = total
					best = {
						period = candidate,
						cycle = cycle,
						differenced = differenced,
						seed = seed,
						exceptionRows = exceptionRows,
						exceptionValues = exceptionValues,
					}
				end
			end
		end
	end

	if best == nil then
		return nil
	end

	return best, soloBytes - bestBytes
end

Columnar.CYCLE_MIN_ROWS = CYCLE_MIN_ROWS
Columnar.CYCLE_MAX_PERIOD = CYCLE_MAX_PERIOD

--[[
	Whether a column holds one value, or one dominant value plus exceptions.

	Real save data is skewed in a way uniformly-random test data is not. Most
	players never prestige, most items are unenchanted, most optional counters
	sit at their default. Frame of reference and differencing both size a column
	by its *range*, so a column of two thousand zeros with three large outliers
	still pays full width for every row.

	Two forms cover this, following BtrBlocks:

		one value   every row identical -- the value alone, nothing per row
		frequency   one dominant value, a bitmap saying where, then the rest

	The gain tracks how dominant the top value is:

		 50% zeros   3503 B -> 3328 B    -5%
		 90% zeros   2405 B ->  865 B   -64%
		 98% zeros   2074 B ->  364 B   -82%
		100% zeros    253 B ->    2 B   -99%

	Both are chosen against the packed forms by modelled size, so an even
	distribution -- where the bitmap costs more than it saves -- keeps whatever
	`differencedPackFor` chose.

	Returns the dominant value, the exceptions with their row indices, and the
	saving; or nil. A `nil` exception list means every row holds the value.
]]
export type FrequencyPlan = {
	value: number,
	exceptionRows: { number },
	exceptions: { number },
	exceptionBits: number,
	-- Zero for a bitmap, otherwise the width the row gaps pack at.
	gapBits: number,
}

function Columnar.frequencyFor(
	column: { any },
	soloBytes: number,
	extraBytes: number?
): (FrequencyPlan?, number?)
	local count = #column
	if count < MIN_ROWS then
		return nil
	end

	--[[
		No cheap pre-check here, and the reason is worth recording.

		A first-entry guard was added on the same reasoning that took
		`differencedPackFor` from 35.2 ms to 21.4 -- allocate nothing until the
		column is known to be integral -- and it measured nothing at all: 15.8 ms
		before, 18.9 after, which is noise either way.

		The difference is who calls it. `differencedPackFor` is asked of every
		column, gated on neither type nor row count, so most of its calls are
		refusals. This is reached through `columnFrequency`, which the write loop
		only calls after `columnSolo` has already established the column is
		integral -- so the guard tested something that was never false, on a path
		that never carries a string column.

		The same change, sound in both places, worth 39% in one and nothing in
		the other. What decides it is the call site, not the function.
	]]
	local counts: { [number]: number } = {}
	local top, topCount = nil, 0

	for index = 1, count do
		local entry = column[index]
		if type(entry) ~= "number" or entry % 1 ~= 0 then
			return nil
		end
		if entry > MAX_DIFFERENCE_VALUE or entry < -MAX_DIFFERENCE_VALUE then
			return nil
		end

		local seen = (counts[entry] or 0) + 1
		counts[entry] = seen
		if seen > topCount then
			top, topCount = entry, seen
		end
	end

	--[[
		Below half, the bitmap costs a bit per row for too little in return and
		the packed forms are already better. BtrBlocks draws the same line.
	]]
	if top == nil or topCount * 2 < count then
		return nil
	end

	local exceptionRows = {}
	local exceptions = {}
	local widest = 0

	for index = 1, count do
		local entry = column[index]
		if entry ~= top then
			table.insert(exceptionRows, index)
			table.insert(exceptions, entry)
			local zigzagged = if entry < 0 then -entry * 2 - 1 else entry * 2
			if zigzagged > widest then
				widest = zigzagged
			end
		end
	end

	local exceptionBits = 1
	if #exceptions > 0 then
		while exceptionBits < MAX_PACK_BITS and 2 ^ exceptionBits <= widest do
			exceptionBits += 1
		end
		if 2 ^ exceptionBits <= widest then
			return nil
		end
	end

	--[[
		Cost: the dominant value, a width byte, and -- when there are any
		exceptions -- their positions plus their packed values. A column with
		none needs neither, which is the one-value form.

		Positions travel one of two ways and the cheaper wins.

		A BITMAP is a bit per row, which is right when the exceptions are
		numerous: at half the rows nothing describes their positions in less.
		But it is a bit per row whatever the count, and a skewed column is
		exactly the case where that is far too much. An entropy floor put a
		99:1 column at 0.08 bits a row against the bitmap's 1.00 -- a 15x gap on
		the scattered version, where runs cannot rescue it either.

		GAPS are the distance from one exception to the next, packed at the
		width of the widest. Ten exceptions across a thousand rows cost twelve
		bytes that way against the bitmap's hundred and twenty-five:

			rare rows    bitmap    gaps    entropy floor
			        1     125 B     4 B          1.4 B
			       10     125 B    12 B         10.1 B
			      100     125 B    65 B         58.6 B
			      300     125 B   115 B        110.2 B
			      500     125 B   190 B        125.0 B

		Which is the same choice `equalityFor` already makes for its own
		exception rows, and for the same reason -- the gaps between ascending
		positions are far smaller than the positions themselves.
	]]
	local total = zigzagWidth(top) + 1
	local gapBits = 0

	if #exceptions > 0 then
		local bitmapBytes = math.ceil(count / 8)

		--[[
			The widest gap between consecutive exceptions, which sets the packed
			width. Measured from row zero so the first position is a gap too.
		]]
		local widestGap = 0
		local previous = 0
		for _, row in exceptionRows do
			local gap = row - previous
			if gap > widestGap then
				widestGap = gap
			end
			previous = row
		end

		local bits = 1
		while bits < MAX_PACK_BITS and 2 ^ bits <= widestGap do
			bits += 1
		end

		--[[
			A width byte and the gaps themselves. Only worth it when it beats
			the bitmap outright -- a tie keeps the bitmap, which decodes without
			a running sum.
		]]
		local gapBytes = 1 + math.ceil(#exceptionRows * bits / 8)
		if 2 ^ bits > widestGap and gapBytes < bitmapBytes then
			gapBits = bits
			total += gapBytes
		else
			total += bitmapBytes
		end

		total += math.ceil(#exceptions * exceptionBits / 8)
	end

	--[[
		`extraBytes` is what choosing this form costs beyond the column itself.

		Taking this form may introduce a column plan the packet did not otherwise
		need, and a plan definition costs a few bytes a lone column cannot
		recover: measured on a dataset where only two columns qualified, two new
		plans cost six bytes while the columns saved less, making the packet
		larger for having the feature at all.

		Only the caller knows whether the plan is new, so it passes the cost in.
		A column whose plan already exists passes zero and is judged on its own
		merits, which is the common case once several columns share a shape.
	]]
	if total + (extraBytes or 0) >= soloBytes then
		return nil
	end

	return {
		value = top,
		exceptionRows = exceptionRows,
		exceptions = exceptions,
		exceptionBits = exceptionBits,
		--[[
			Zero means the positions travel as a bitmap; anything else is the
			width the gaps between them pack at. The encoder must write whichever
			the cost above assumed, or the packet will not match its own plan.
		]]
		gapBits = gapBits,
	}, soloBytes - total
end

--[[
	Cross-field correlation: encoding one integer column relative to another.

	Two fields in the same record are often two views of one quantity -- health
	and maxHealth, a position's Y and the ground height beneath it, level and the
	xp threshold for it. Encoded independently, each pays for its own full range.
	Encoded as a residual against the other, only the difference between them is
	stored, and that difference is usually tiny.

	The relationship is fitted as `b ~= slope * a + intercept`, not as a plain
	subtraction. Subtraction only catches the case where the two are the same
	magnitude, and misses the scaled one entirely -- xp against level costs MORE
	as a difference than encoded alone, and 41% less once the slope is fitted:

		                      alone   difference   fitted
		xp from level          4254         4503     2503
		armor from level       2253         2253      753
		health from maxHealth  2003         1503     1253

	Slope and intercept are rounded to integers so the residual stays exact. A
	non-integral slope simply produces a wider residual, which then loses the
	comparison and the column is encoded alone -- there is no accuracy to lose.

	Returns the slope, the intercept, the packed residual's bit width, and the
	saving; or nil when encoding the column on its own is at least as small.
]]
--[[
	How many rows an array needs before the correlated forms are offered at all.

	Every correlated form carries fixed framing before it saves a byte: a plan
	definition, a dictionary of the distinct target values, a mapping or a
	slope. On a short array that framing is most of what the column costs, so
	the form cannot win however perfectly the columns are correlated.

	Measured on a four-column array whose every column IS determined by another
	-- the most favourable case there is:

		rows      plain    correlated    saved
		   8        116           116        0
		  16        122           122        0
		  32        134           134        0
		  48        146           146        0
		  64        252           197       55
		 128        396           258      138

	Nothing at all below 64. The search ran on every one of those and found
	nothing it could take.

	What it costs to run anyway, on 900 arrays -- which is the shape a payload
	of records each holding a small inventory actually has:

		rows each    plain      correlated    overhead    bytes saved
		       20    133 ms        1,001 ms       7.5x             64
		       32    205 ms        2,431 ms      11.9x            112

	A second of searching for sixty-four bytes. This was 16, and on the
	canonical benchmark that let 934 inventories of five to twenty-five items
	each run a full pair search: 2,001 calls to `correlationPlan`, 934 of them
	past this gate, 6,242 qualifier calls.

	Set where the forms begin to earn their framing rather than where they
	become theoretically possible.
]]
local CORRELATION_MIN_ROWS = 64

function Columnar.correlationFor(
	reference: { number },
	column: { number },
	soloBytes: number,
	extraBytes: number?
): (number?, number?, number?, number?)
	local count = #column
	if count < CORRELATION_MIN_ROWS or #reference ~= count then
		return nil
	end

	--[[
		Least squares, in integers. The sums stay well inside 2^53 for any column
		the rest of the encoder would accept, since components are bounded and
		counts are bounded by the packet size.
	]]
	local sumA, sumB = 0, 0
	for index = 1, count do
		local a, b = reference[index], column[index]
		if a % 1 ~= 0 or b % 1 ~= 0 then
			return nil
		end
		if
			a > MAX_DIFFERENCE_VALUE
			or a < -MAX_DIFFERENCE_VALUE
			or b > MAX_DIFFERENCE_VALUE
			or b < -MAX_DIFFERENCE_VALUE
		then
			return nil
		end
		sumA += a
		sumB += b
	end

	local meanA = sumA / count
	local meanB = sumB / count

	local covariance, variance = 0, 0
	for index = 1, count do
		local deviation = reference[index] - meanA
		covariance += deviation * (column[index] - meanB)
		variance += deviation * deviation
	end

	--[[
		A reference column with no spread carries no information about anything,
		so there is nothing to fit against.
	]]
	if variance == 0 then
		return nil
	end

	local slope = math.round(covariance / variance)
	local intercept = math.round(meanB - slope * meanA)

	-- A zero slope makes the residual the column itself, offset -- which is what
	-- the ordinary packed form already does, and cheaper.
	if slope == 0 then
		return nil
	end

	local widest = 0
	for index = 1, count do
		local residual = column[index] - (slope * reference[index] + intercept)
		local zigzagged = if residual < 0 then -residual * 2 - 1 else residual * 2
		if zigzagged > widest then
			widest = zigzagged
		end
	end

	if widest ~= widest or widest == math.huge then
		return nil
	end

	local bits = 1
	while bits < MAX_PACK_BITS and 2 ^ bits <= widest do
		bits += 1
	end
	if 2 ^ bits <= widest then
		return nil
	end

	--[[
		Cost: the referenced column's index, the slope and intercept, a width
		byte, then the packed residual.
	]]
	local total = 1
		+ zigzagWidth(slope)
		+ zigzagWidth(intercept)
		+ 1
		+ math.ceil(count * bits / 8)

	if total + (extraBytes or 0) >= soloBytes then
		return nil
	end

	return slope, intercept, bits, soloBytes - total
end

Columnar.CORRELATION_MIN_ROWS = CORRELATION_MIN_ROWS
Columnar.integerCost = integerCost

--[[
	Whether a column of Vector3s should be written as deltas from a base.

	A column of positions pays a tag plus three zigzag varints per row, and each
	varint is sized against fixed boundaries -- so a part at (1200, 40, -1500)
	costs two bytes per component even when every part in the column sits within
	a few studs of its neighbours. Subtracting a shared base turns those into
	deltas near zero, which is one byte per component.

	The boundaries that decide it, from Writer.varint through zigzag:

		|delta| <=     95   1 byte
		|delta| <=  4,191   2 bytes
		|delta| <= 528,479  3 bytes

	Three things are chosen here, each only when it pays for itself.

	BASE. The base is not the centroid. What matters is the varint width of the
	deltas, not the geometric centre, and the two disagree whenever the column is
	skewed. Two candidates are tried:

		first    the first row's value, which costs nothing to transmit -- it is
		         the row whose delta is zero
		median   the per-component median, which is what rescues a column whose
		         first row is a far outlier

	Anchoring on the first row alone is not safe: when that row is the outlier,
	every other row's delta is enormous and the delta form loses to the plain one
	outright. Measured over twelve distributions, first-only forfeits the entire
	saving on such a column -- 148,200 bytes against 77,220 -- while the median
	recovers it. Centroid and min/max midpoint were measured too and earn 0.04%
	between them, which does not pay for the pass they cost.

	RUNS. A column holding two distant groups of positions -- two islands, two
	rooms -- has no single good base. It is split into contiguous runs, each with
	its own base. Runs are contiguous by construction: reordering rows would be
	visible to the caller, so a run break is only ever a length, never a
	per-row cluster id. A per-row id would cost a byte each and eat the saving.

	A run ends where admitting the next value would widen the run's varint class.
	The greedy rule is deliberate: an optimal partition needs a quadratic DP for
	a few tenths of a percent over this.

	Returns a list of runs, each { base = Vector3-ish triple, count = n }, and
	the modelled saving -- or nil when the plain form is at least as small.
]]
local DELTA_MIN_ROWS = 3
local RUN_MIN_ROWS = 4

--[[
	Widest component the integral form accepts, matching Encoder's own cutoff:
	the largest value a three-byte varint holds. Past this the exact float form
	is smaller anyway.
]]
local INT_COMPONENT_MAX = 1056959

Columnar.zigzagWidth = zigzagWidth

--[[
	The core below works on a list of component arrays rather than named x/y/z,
	so one implementation serves Vector2, Vector3 and CFrame positions. `axes` is
	{ xs, ys } or { xs, ys, zs }; everything else follows from #axes.
]]
type Axes = { { number } }

--[[
	Bytes a run of rows costs as deltas from `base`, excluding the run framing.
]]
local function deltaRunBytes(
	axes: Axes,
	from: number,
	to: number,
	base: { number }
): number
	local total = 0
	for axis, values in axes do
		local component = base[axis]
		total += zigzagWidth(component)
		for index = from, to do
			total += zigzagWidth(values[index] - component)
		end
	end
	return total
end

--[[
	Cost of packing a run's deltas at a fixed bit width, and that width.

	The width comes from the largest zigzagged delta across every component, so
	one width serves the whole run. Returns nil when the span needs more bits
	than the packed form carries, in which case the varint form stands.
]]
local MAX_DELTA_BITS = 32

local function packedRunBytes(
	axes: Axes,
	from: number,
	to: number,
	base: { number }
): (number?, number?)
	local widest = 0
	for axis, values in axes do
		local component = base[axis]
		for index = from, to do
			local delta = values[index] - component
			local zigzagged = if delta < 0 then -delta * 2 - 1 else delta * 2
			if zigzagged > widest then
				widest = zigzagged
			end
		end
	end

	local bits = 1
	while bits < MAX_DELTA_BITS and 2 ^ bits <= widest do
		bits += 1
	end
	if 2 ^ bits <= widest then
		return nil
	end

	--[[
		Just the packed bits for every component of every row. The width byte is
		framing -- both forms pay it -- so framingBytes counts it, not this.
	]]
	local count = (to - from + 1) * #axes
	return math.ceil(count * bits / 8), bits
end

--[[
	Cheapest base for rows [from, to], as described above: the first value, or
	the per-component median. Returns the base, the run's byte cost, and the bit
	width when packing beat the varint form.
]]
local function chooseBase(
	axes: Axes,
	from: number,
	to: number
): ({ number }, number, number?)
	local first = table.create(#axes)
	for axis, values in axes do
		first[axis] = values[from]
	end

	local base = first
	local best = deltaRunBytes(axes, from, to, first)
	local count = to - from + 1

	if count >= DELTA_MIN_ROWS then
		local median = table.create(#axes)
		local sorted = table.create(count)
		for axis, values in axes do
			for index = from, to do
				sorted[index - from + 1] = values[index]
			end
			table.sort(sorted)
			median[axis] = sorted[(count + 1) // 2]
		end

		local medianBytes = deltaRunBytes(axes, from, to, median)
		if medianBytes < best then
			base, best = median, medianBytes
		end
	end

	--[[
		The base is settled; now the cascade. Both bases are compared as varints
		above because that is the form whose cost varies with the base -- packing
		then re-measures the winner's deltas, and takes over only when it is
		strictly smaller.

		The base itself is a varint either way, so it is added after the choice
		rather than being part of it.
	]]
	local baseBytes = 0
	for axis in axes do
		baseBytes += zigzagWidth(base[axis])
	end

	local varintBytes = best - baseBytes
	local packedBytes, bits = packedRunBytes(axes, from, to, base)

	if packedBytes and bits and packedBytes < varintBytes then
		return base, baseBytes + packedBytes, bits
	end

	return base, best
end

--[[
	Widest varint any component's span would need. This is what decides a run
	break: the run holds while admitting a value keeps every component inside the
	same width class.
]]
local function spanWidth(low: { number }, high: { number }): number
	local widest = 0
	for axis, lowValue in low do
		local width = zigzagWidth(high[axis] - lowValue)
		if width > widest then
			widest = width
		end
	end
	return widest
end

--[[
	A run's deltas are written one of two ways, whichever is smaller.

	`bits = nil` means each delta is its own zigzag varint, which is best when
	the deltas are small and uneven -- a varint costs one byte for anything under
	96 and pays nothing for the values that happen to be tiny.

	`bits = n` means every delta is packed at a fixed n-bit width, the cascade
	Parquet calls DELTA_BINARY_PACKED. This wins because a varint quantizes to
	whole bytes while a packed width does not: a run whose deltas need 8 bits
	pays two bytes per component as a varint -- 8 bits of magnitude lands past
	the 191 zigzag boundary -- and exactly one byte packed. That single case is
	the most common run shape measured, and the cascade is worth 18.8% of all
	delta bytes overall.
]]
export type DeltaRun = {
	base: { number },
	count: number,
	bits: number?,
}

--[[
	Split component arrays into greedy contiguous runs, each with its own base.

	Returns the runs and the total bytes their deltas and bases cost, framing
	excluded. Shared by every datatype that delta-encodes.
]]
local function buildRuns(axes: Axes, count: number): ({ DeltaRun }, number)
	local runs: { DeltaRun } = {}
	local deltaBytes = 0

	local axisCount = #axes
	local low = table.create(axisCount)
	local high = table.create(axisCount)
	for axis, values in axes do
		low[axis] = values[1]
		high[axis] = values[1]
	end

	local runStart = 1

	for index = 2, count do
		--[[
			Whether admitting this row widens the run's varint class. Computed
			against a copy of the bounds so the run's own span is untouched when
			the answer is no.
		]]
		local currentWidth = spanWidth(low, high)

		local joinedWidest = 0
		for axis, values in axes do
			local value = values[index]
			local axisLow = if value < low[axis] then value else low[axis]
			local axisHigh = if value > high[axis] then value else high[axis]
			local width = zigzagWidth(axisHigh - axisLow)
			if width > joinedWidest then
				joinedWidest = width
			end
		end

		if joinedWidest > currentWidth and index - runStart >= RUN_MIN_ROWS then
			local base, bytes, bits = chooseBase(axes, runStart, index - 1)
			table.insert(runs, { base = base, count = index - runStart, bits = bits })
			deltaBytes += bytes

			runStart = index
			for axis, values in axes do
				low[axis] = values[index]
				high[axis] = values[index]
			end
		else
			for axis, values in axes do
				local value = values[index]
				if value < low[axis] then
					low[axis] = value
				elseif value > high[axis] then
					high[axis] = value
				end
			end
		end
	end

	local base, bytes, bits = chooseBase(axes, runStart, count)
	table.insert(runs, { base = base, count = count - runStart + 1, bits = bits })
	deltaBytes += bytes

	return runs, deltaBytes
end

--[[
	Framing: a run count, then a length per run. The kind byte is paid either
	way, so it is not counted on either side.

	Counts are plain varints, not zigzagged -- they are never negative. Using the
	zigzag width here overcharges every count in 96..191 by a byte, which
	understates the saving and can decline a column that would have won.
]]
local function framingBytes(runs: { DeltaRun }): number
	local framing = varintWidth(#runs)
	for _, run in runs do
		-- A length, plus the width byte naming which delta form the run uses.
		framing += varintWidth(run.count) + 1
	end
	return framing
end

--[[
	Pull one integral component out of every row, or nil when any value is
	fractional or too wide for the integral form.
]]
local function integralAxis(
	column: { any },
	count: number,
	read: (any) -> number
): { number }?
	local values = table.create(count)
	for index = 1, count do
		local value = read(column[index])
		if value % 1 ~= 0 or value > INT_COMPONENT_MAX or value < -INT_COMPONENT_MAX then
			return nil
		end
		values[index] = value
	end
	return values
end

--[[
	Widest power-of-ten scale worth trying. Mirrors decimalFor's own cap: a
	value scaled by 10^6 already covers six decimal places, far past anything
	Studio's Properties panel or a physics step produces, and every step
	beyond this narrows INT_COMPONENT_MAX's usable range for no realistic
	gain.
]]
local MAX_DECIMAL_FACTOR = 6

--[[
	Round-tripping scratch for the f32 check below. Vector3/Vector2/CFrame
	components are f32 the moment they are read off the datatype, but the
	scaled-and-divided-back reconstruction below runs in Lua's f64, so an
	exact-looking f64 result can still differ from the f32 the decoder will
	actually reconstruct. Forcing both sides through the same f32 round trip
	is what Number.lua already does when it picks between F32 and F64.
]]
local decimalScratch = buffer.create(4)

local function f32Round(value: number): number
	buffer.writef32(decimalScratch, 0, value)
	return buffer.readf32(decimalScratch, 0)
end

--[[
	One shared scale for every axis at once, verified exact -- the same
	pseudodecimal technique decimalFor uses for a lone numeric column, applied
	here so a column of positions with a real fractional part (0.01 precision
	placements, physics state) is not forced into the plain fixed-size form
	just because it fails the raw-integer check.

	Tries factor = 0 first (plain integers, what integralAxis already
	covered) and grows until every component of every row round-trips
	exactly through `entry * scale`, rounded, divided back by `scale`. The
	reconstruction is passed through f32Round before comparing, since that
	is the precision Vector3.new/Vector2.new/CFrame.new actually store --
	comparing the f64 division directly against an already-f32 entry would
	reject columns that decode exactly fine.

	A column that never lands on an exact decimal at any tried scale -- true
	floats, not decimal quantities wearing float clothing -- returns nil and
	the caller falls back to the plain per-value form, same as before.

	Returns the integer axes and the factor that produced them; the caller
	writes the factor once so the decoder knows to divide every reconstructed
	component by 10^factor.
]]
local function decimalAxes(
	axesReads: { (any) -> number },
	column: { any },
	count: number
): ({ { number } }?, number?)
	local axisCount = #axesReads

	for factor = 0, MAX_DECIMAL_FACTOR do
		local scale = 10 ^ factor
		local axes = table.create(axisCount)
		local viable = true

		for axis = 1, axisCount do
			local read = axesReads[axis]
			local values = table.create(count)

			for index = 1, count do
				local entry = read(column[index])
				local scaled = entry * scale

				--[[
					Past 2^53 a double cannot hold an exact integer, so the
					rounding below would not survive the return trip.
				]]
				if
					scaled ~= scaled
					or scaled >= 2 ^ 53
					or scaled <= -(2 ^ 53)
				then
					viable = false
					break
				end

				local rounded = if scaled >= 0
					then math.floor(scaled + 0.5)
					else -math.floor(-scaled + 0.5)

				if
					f32Round(rounded / scale) ~= entry
					or rounded > INT_COMPONENT_MAX
					or rounded < -INT_COMPONENT_MAX
				then
					viable = false
					break
				end

				values[index] = rounded
			end

			if not viable then
				break
			end
			axes[axis] = values
		end

		if viable then
			return axes, factor
		end
	end

	return nil
end

--[[
	Bytes a Vector3 column costs one row at a time today, at the given
	decimal factor: VECTOR3_INT's tag-plus-three-varints when the column is
	genuinely integral (factor 0), or plain VECTOR3's tag-plus-three-f32 for
	anything scaled -- a scaled column was never eligible for VECTOR3_INT in
	the first place, so that is the form it is actually displacing.
]]
local function vector3PlainBytes(xs: { number }, ys: { number }, zs: { number }, count: number, factor: number): number
	if factor == 0 then
		local total = 0
		for index = 1, count do
			total += 1 + zigzagWidth(xs[index]) + zigzagWidth(ys[index]) + zigzagWidth(zs[index])
		end
		return total
	end
	return count * 13
end

function Columnar.deltaVectorFor(column: { any }): ({ DeltaRun }?, number?, number?)
	local count = #column
	if count < DELTA_MIN_ROWS then
		return nil
	end

	for index = 1, count do
		if typeof(column[index]) ~= "Vector3" then
			return nil
		end
	end

	--[[
		Raw integers first -- the cheap, common case, and the one whose cost
		model (VECTOR3_INT) is exact. Only when a component has a real
		fractional part does the pseudodecimal search run: the same
		scale-and-verify technique decimalFor uses for a lone numeric column,
		applied across all three axes at once so one factor serves the whole
		row.
	]]
	local xs = integralAxis(column, count, function(entry): number
		return (entry :: Vector3).X
	end)
	local ys, zs, factor = nil, nil, 0

	if xs then
		ys = integralAxis(column, count, function(entry): number
			return (entry :: Vector3).Y
		end)
		zs = ys and integralAxis(column, count, function(entry): number
			return (entry :: Vector3).Z
		end)
	end

	if not (xs and ys and zs) then
		local axes: { { number } }?
		axes, factor = decimalAxes({
			function(entry): number
				return (entry :: Vector3).X
			end,
			function(entry): number
				return (entry :: Vector3).Y
			end,
			function(entry): number
				return (entry :: Vector3).Z
			end,
		}, column, count)

		if not axes or not factor or factor == 0 then
			return nil
		end

		xs, ys, zs = axes[1], axes[2], axes[3]
	end

	local plainBytes = vector3PlainBytes(xs :: { number }, ys :: { number }, zs :: { number }, count, factor :: number)

	local runs, deltaBytes = buildRuns({ xs :: { number }, ys :: { number }, zs :: { number } }, count)

	local total = framingBytes(runs) + deltaBytes
	if total >= plainBytes then
		return nil
	end

	return runs, plainBytes - total, factor
end

--[[
	Whether a column of Vector2s should be delta encoded.

	Identical in every respect to the Vector3 form, two components instead of
	three. UI offsets and grid coordinates are the columns this catches.
]]
function Columnar.deltaVector2For(column: { any }): ({ DeltaRun }?, number?, number?)
	local count = #column
	if count < DELTA_MIN_ROWS then
		return nil
	end

	for index = 1, count do
		if typeof(column[index]) ~= "Vector2" then
			return nil
		end
	end

	local xs = integralAxis(column, count, function(entry): number
		return (entry :: Vector2).X
	end)
	local ys, factor = nil, 0

	if xs then
		ys = integralAxis(column, count, function(entry): number
			return (entry :: Vector2).Y
		end)
	end

	if not (xs and ys) then
		local axes: { { number } }?
		axes, factor = decimalAxes({
			function(entry): number
				return (entry :: Vector2).X
			end,
			function(entry): number
				return (entry :: Vector2).Y
			end,
		}, column, count)

		if not axes or not factor or factor == 0 then
			return nil
		end

		xs, ys = axes[1], axes[2]
	end

	--[[
		VECTOR2_INT's tag-plus-two-varints at factor 0, or plain VECTOR2's
		tag-plus-two-f32 for a scaled column, which was never eligible for
		the integral form in the first place.
	]]
	local plainBytes = 0
	if factor == 0 then
		for index = 1, count do
			plainBytes += 1 + zigzagWidth((xs :: { number })[index]) + zigzagWidth((ys :: { number })[index])
		end
	else
		plainBytes = count * 9
	end

	local runs, deltaBytes = buildRuns({ xs :: { number }, ys :: { number } }, count)

	local total = framingBytes(runs) + deltaBytes
	if total >= plainBytes then
		return nil
	end

	return runs, plainBytes - total, factor
end

--[[
	Whether a column of CFrames should have its positions delta encoded.

	Only the position is delta'd. Rotation is carried per row exactly as the
	single-value form writes it -- a rotation id, or a marker plus a packed
	quaternion -- because a rotation is already one byte in the common case and
	there is nothing for a base to subtract.

	That rotation payload dilutes the saving without ever reversing it: it is the
	same size in both forms, so it cancels out of the comparison and neither side
	counts it here.
]]
function Columnar.deltaCFrameFor(column: { any }): ({ DeltaRun }?, number?, number?)
	local count = #column
	if count < DELTA_MIN_ROWS then
		return nil
	end

	for index = 1, count do
		if typeof(column[index]) ~= "CFrame" then
			return nil
		end
	end

	local xs = integralAxis(column, count, function(entry): number
		return (entry :: CFrame).Position.X
	end)
	local ys, zs, factor = nil, nil, 0

	if xs then
		ys = integralAxis(column, count, function(entry): number
			return (entry :: CFrame).Position.Y
		end)
		zs = ys and integralAxis(column, count, function(entry): number
			return (entry :: CFrame).Position.Z
		end)
	end

	if not (xs and ys and zs) then
		local axes: { { number } }?
		axes, factor = decimalAxes({
			function(entry): number
				return (entry :: CFrame).Position.X
			end,
			function(entry): number
				return (entry :: CFrame).Position.Y
			end,
			function(entry): number
				return (entry :: CFrame).Position.Z
			end,
		}, column, count)

		if not axes or not factor or factor == 0 then
			return nil
		end

		xs, ys, zs = axes[1], axes[2], axes[3]
	end

	--[[
		CFRAME_INT's tag, three varints and the rotation at factor 0, or the
		position's plain three-f32 form when scaled -- the rotation term is
		identical in the delta form either way, so both sides of the
		comparison omit it.
	]]
	local plainBytes = 0
	if factor == 0 then
		for index = 1, count do
			plainBytes += 1
				+ zigzagWidth((xs :: { number })[index])
				+ zigzagWidth((ys :: { number })[index])
				+ zigzagWidth((zs :: { number })[index])
		end
	else
		plainBytes = count * 12
	end

	local runs, deltaBytes = buildRuns({ xs :: { number }, ys :: { number }, zs :: { number } }, count)

	local total = framingBytes(runs) + deltaBytes
	if total >= plainBytes then
		return nil
	end

	return runs, plainBytes - total, factor
end

Columnar.DELTA_MIN_ROWS = DELTA_MIN_ROWS
Columnar.RUN_MIN_ROWS = RUN_MIN_ROWS
Columnar.MAX_DECIMAL_FACTOR = MAX_DECIMAL_FACTOR

--[[
	Whether a column is entirely booleans, and so can be bit-packed.
]]
function Columnar.isBooleanColumn(column: { any }): boolean
	local count = #column
	if count < 8 then
		return false
	end

	for index = 1, count do
		if type(column[index]) ~= "boolean" then
			return false
		end
	end

	return true
end

return Columnar
