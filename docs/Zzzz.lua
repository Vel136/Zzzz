-- MIT License
--
-- Copyright (c) 2026 Ve Development

--[=[
	@class Zzzz

	Zero schema serialization for Luau.

	Zzzz takes any Luau value and turns it into a compact buffer with no type
	declarations to write and no schema to keep in sync. It works out the shape
	and picks the narrowest wire representation for every value.

	```lua
	local Zzzz = require(ReplicatedStorage.Zzzz)
	local Zz = Zzzz.new()

	local packet, instances = Zz:Serialize({
	    Coins = 5000,
	    Position = Vector3.new(10, 20, 30),
	})

	local data = Zz:Deserialize(packet, instances)
	```
]=]

--[=[
	@function new
	@within Zzzz
	@param options table? -- InstanceMode, StructureCache, Precision, BitPack, Columnar, Correlate, GuardDiff, MaxDepth, MaxNodes
	@return Zzzz

	Creates a new Zzzz instance.

	```lua
	local Zz = Zzzz.new({
	    Precision = 0.01,
	    Columnar = true,
	})
	```
]=]

--[=[
	@function schema
	@within Zzzz
	@param sample any -- representative sample data
	@param options table?
	@return Schema

	Derives a schema from sample data, so a repeated shape can be encoded by
	replaying recorded decisions instead of rediscovering them each call.

	```lua
	local Schema = Zzzz.schema(sampleSaves, { Columnar = true })
	local packet = Schema:Encode(saves)
	```
]=]

--[=[
	@function loadSchema
	@within Zzzz
	@param stored buffer -- bytes from Schema:Save
	@return Schema

	Reads back a schema saved with `Schema:Save`, so derivation happens once
	rather than once per server start.

	```lua
	local Schema = Zzzz.loadSchema(storedBytes)
	```
]=]

--[=[
	@method Serialize
	@within Zzzz
	@param value any
	@return buffer
	@return {Instance}

	Serializes any supported value. Returns the packet buffer and a side array
	of Instances the value referred to, since Instance references cannot travel
	inside a buffer.

	```lua
	local packet, instances = Zz:Serialize(value)
	```
]=]

--[=[
	@method Deserialize
	@within Zzzz
	@param packet buffer
	@param instances {Instance}?
	@return any

	Rebuilds a value from a packet.

	```lua
	local value = Zz:Deserialize(packet, instances)
	```
]=]

--[=[
	@method Diff
	@within Zzzz
	@param baseline any
	@param current any
	@return buffer
	@return {Instance}

	Serializes only what differs from a value the receiver already holds.
	Writes both a patch and the full form and returns whichever is smaller, so
	it is never larger than a plain Serialize.

	```lua
	local packet = Zz:Diff(lastSent, state)
	```
]=]

--[=[
	@method DiffOnly
	@within Zzzz
	@param baseline any
	@param current any
	@return buffer
	@return {Instance}

	A patch, without encoding the full form to compare against it. Roughly
	twenty times faster than Diff on sparse traffic, but a patch can exceed the
	full form's size when most of the data changed.

	```lua
	local packet = Zz:DiffOnly(lastSent, state)
	```
]=]

--[=[
	@method Patch
	@within Zzzz
	@param baseline any
	@param packet buffer
	@param instances {Instance}?
	@return any

	Rebuilds a value from whatever Diff or DiffOnly returned. Accepts a patch
	or a whole packet, so the caller does not have to track which was sent.

	```lua
	local state = Zz:Patch(lastSent, packet, instances)
	```
]=]

--[=[
	@method IsPatch
	@within Zzzz
	@param packet buffer
	@return boolean

	Reports whether a packet is a patch rather than a whole value.

	```lua
	if Zz:IsPatch(packet) then
	    print("patch")
	end
	```
]=]

--[=[
	@method SerializeToString
	@within Zzzz
	@param value any
	@return string
	@return {Instance}

	Serializes to a string rather than a buffer, for DataStores and anywhere
	else that will not take a buffer.

	```lua
	local text, instances = Zz:SerializeToString(value)
	```
]=]

--[=[
	@method DeserializeFromString
	@within Zzzz
	@param packet string
	@param instances {Instance}?
	@return any

	Rebuilds a value from a string produced by SerializeToString.

	```lua
	local value = Zz:DeserializeFromString(text, instances)
	```
]=]

--[=[
	@method Inspect
	@within Zzzz
	@param value any
	@return table

	Describes what a value costs to serialize without sending it anywhere:
	packet size, structure reuse, and a breakdown of the value types involved.

	```lua
	local report = Zz:Inspect(value)
	```
]=]

--[=[
	@method InspectToString
	@within Zzzz
	@param value any
	@return string

	Human readable form of Inspect, for printing during development.

	```lua
	print(Zz:InspectToString(value))
	```
]=]

--[=[
	@method InspectDiff
	@within Zzzz
	@param baseline any
	@param current any
	@return table

	Describes what a patch costs and what form each of its columns chose.

	```lua
	local report = Zz:InspectDiff(baseline, current)
	```
]=]

--[=[
	@method InspectDiffToString
	@within Zzzz
	@param baseline any
	@param current any
	@return string

	Human readable form of InspectDiff, for printing during development.

	```lua
	print(Zz:InspectDiffToString(baseline, current))
	```
]=]

--[=[
	@method Benchmark
	@within Zzzz
	@param value any
	@param iterations number?
	@return table

	Times a round trip. Reports per call milliseconds averaged over the given
	number of iterations, and packet size.

	```lua
	local result = Zz:Benchmark(value, 100)
	```
]=]

--[=[
	@method BenchmarkToString
	@within Zzzz
	@param value any
	@param iterations number?
	@return string

	Human readable form of Benchmark, for printing during development.

	```lua
	print(Zz:BenchmarkToString(value, 100))
	```
]=]
