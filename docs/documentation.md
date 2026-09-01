---
sidebar_position: 2
sidebar_label: "Overview"
---

# Zzzz

*Zero schema serialization for Luau.*

Zzzz takes any Luau value and turns it into a compact buffer. There is no type declaration to write and no schema to keep in sync with your data. It walks the value, works out the shape, and picks the narrowest wire representation for every piece: a folded tag for a small integer, an interned reference for a repeated string or table, an integral form for a whole number Vector3, a bit packed run for a dense array of booleans.

Zzzz does not compress. It makes the bytes structurally small and stops there. Layer general compression on top if you want it further reduced:

```lua
local packet = Zz:Serialize(data)
local small = EncodingService:CompressBuffer(packet, Enum.CompressionAlgorithm.Zstd)
```

---

## One File. One Require.

```lua
local Zzzz = require(ReplicatedStorage.Zzzz)
local Zz = Zzzz.new()
```

---

## Serializing

```lua
local packet, instances = Zz:Serialize(value)
```

Any Luau value is accepted: numbers, strings, booleans, tables (arrays, maps, or mixed), nested tables, shared references, cycles, and Roblox datatypes such as Vector3, CFrame, Color3, UDim2, and Instances.

`instances` is a side array. In `"reference"` InstanceMode it holds every Instance the value referred to; in `"full"` mode it holds only Instances referred to from outside the serialized hierarchy. Roblox already replicates Instance references natively, so they cannot travel inside a buffer, and this is how they cross regardless.

---

## Deserializing

```lua
local value = Zz:Deserialize(packet, instances)
```

Pass the same `instances` array back that Serialize returned. If the original value held no Instances the array is empty and this argument can be omitted.

---

## Options

```lua
Zzzz.new({
    InstanceMode = "full",
    StructureCache = true,
    Precision = 0.01,
    BitPack = true,
    Columnar = true,
    Correlate = false,
    GuardDiff = true,
    MaxDepth = 512,
    MaxNodes = 100000,
})
```

Option names are matched without regard to case, so `StructureCache`, `structureCache`, and `structurecache` all set the same option. An option name that does not match any known option raises immediately rather than being silently ignored.

### InstanceMode

`"reference"` (default) stores Instances as indices into the side array. `"full"` serializes the whole hierarchy: ClassName, non-default properties, attributes, tags, and children, so it can be rebuilt in a different session or place.

`"full"` rebuilds whatever the packet describes. A packet is data, and a hostile one can name any creatable ClassName and any writable property, including a Script and its Source. Nothing is parented during decode, so the result is inert until the caller parents it, but a packet from an untrusted source must be inspected before it goes anywhere near the DataModel. Do not use `"full"` on anything a client sent you. Reference mode is the safe default for network input.

### StructureCache

Sends the keys of a repeated table shape once instead of per table. Large wins on arrays of similar records; costs a little CPU.

### Columnar

Writes arrays of uniform records as one column per field rather than one block per row. Values of a single type end up adjacent, so a boolean column bit packs, a low cardinality string column becomes a dictionary, a column of integers packs at a fixed bit width, a column of Vector3s is written as deltas from a nearby base, and a later compression pass finds far more structure.

Lossless, and skipped for any array whose rows are shared with something else or take part in a cycle, since rebuilding those as fresh tables would break reference identity.

### Precision

Rounds numbers to this step before encoding, for example 0.01 keeps two decimal places. Lossy: worst case error is half the precision.

Applies to non-integer numbers, Vector2, Vector3, and CFrame positions. Integers are left exact, since they already encode at least as small. Individual values fall back to their exact form whenever quantizing would not actually be smaller.

The precision travels inside the packet, so any reader decodes it correctly regardless of its own settings.

### Correlate

Encodes an integer column as a residual against another column in the same records, when the two are related, such as health against maxHealth, or level against the xp for it. Encoded independently each pays for its own full range; encoded against the other, only the difference is stored.

Requires Columnar. Costs a correlation pass over the numeric columns, and does nothing at all unless the data actually has related fields. Off by default for that reason.

### BitPack

Packs dense arrays of 8 or more booleans at one bit each: 1,000 booleans become 125 bytes rather than 1,000.

### GuardDiff

Whether `Diff` encodes the full form as well, to guarantee it never returns a packet larger than a plain `Serialize`. On by default.

The guarantee costs a second encode of the current value on every call. Turning it off makes `Diff` behave as `DiffOnly` does: the patch is returned whatever its size. Leave it on unless the traffic is known to be sparse.

### MaxDepth / MaxNodes

Deepest table nesting to accept, and the largest number of table or row nodes to accept, in both directions. On decode this is a safety limit, not a preference: a hand crafted packet of nested table tags is only two bytes per level, and without a bound the decoder recurses until Luau's own stack gives out.

---

## Diffing

```lua
local packet = Zz:Diff(lastSent, state)
local state = Zz:Patch(lastSent, packet)
```

`Diff` serializes only what differs from a value the receiver already holds. It writes both the patch and the full form and returns whichever is smaller, so it can never be worse than calling `Serialize` directly.

Measured against a full re-send of the same data:

| Change | Patch size relative to full |
|--------|------------------------------|
| Nothing moved | 36x smaller |
| 5% of rows moved | 12x smaller |
| 25% of rows moved | 3x smaller |
| Everything moved | full form wins, and is what gets sent |

The guarantee costs a second encode. `DiffOnly` skips it:

```lua
local packet = Zz:DiffOnly(lastSent, state)
```

Reach for `DiffOnly` once traffic is known to be sparse. On a tick where most values changed, a patch can exceed a full Serialize, so send `Serialize` directly for those rather than hoping.

`Patch` accepts either a patch or a whole packet, so the caller does not have to track which `Diff` produced:

```lua
local state = Zz:Patch(lastSent, packet, instances)
```

`Zzzz.IsPatch` reports which kind a packet is, if the caller wants to know:

```lua
if Zz:IsPatch(packet) then
    -- ...
end
```

### Keeping the Two Sides in Step

A patch is only meaningful against the exact value it was diffed from, and nothing in the packet says which value that was. Applied to the wrong baseline, a patch produces a wrong value rather than an error, and every later patch builds on it.

Over an ordered, reliable transport, such as a Roblox RemoteEvent, keep one baseline per receiver and diff against the last value sent:

```lua
local packet = Zz:Diff(lastSent[player], state)
lastSent[player] = state
```

Send a full `Serialize` to start, and again whenever a receiver's baseline is in doubt: a rejoin, a reconnect, a dropped patch.

---

## Schemas

Zzzz normally works out the shape and encoding of every column at encode time. On a server writing the same shape repeatedly, that discovery is repeated unchanged every time. A schema records what the encoder chose once, so later encodes replay the decisions rather than making them again.

```lua
local Schema = Zzzz.schema(sampleData, options)
local packet = Schema:Encode(data)
local data = Schema:Decode(packet)
```

Measured on 2,000 flat rows: 7.07 ms discovering, 2.69 ms replaying, for 1.6% more bytes.

The sample must be representative rather than merely well formed. The schema inherits its ranges, so a sample where no player passed level 100 produces a schema that falls back when one does. It falls back safely and reports it in `stats.planMisses`; it never writes a truncated value.

`options` are the same ones `Zzzz.new` takes, and are part of the schema.

### Patching with a Schema

```lua
local packet = Schema:DiffOnly(previous, current)  -- no guard
local packet = Schema:Diff(previous, current)       -- never worse
```

`Schema:Diff` makes the same promise `Zz:Diff` makes, and it costs less to keep: `Zz:Diff` runs a full adaptive encode to compare against, while `Schema:Diff` runs the compiled one.

### Saving a Schema

```lua
local stored = Schema:Save()
local Schema = Zzzz.loadSchema(stored)
```

Errors if the bytes were written by a different version of the library, or if they have been altered.

---

## Inspecting

```lua
local report = Zz:Inspect(value)
print(Zz:InspectToString(value))
```

Describes what a value costs to serialize without sending it anywhere: packet size, how many structure shapes were reused, and a breakdown of the value types involved.

```lua
local report = Zz:InspectDiff(baseline, current)
print(Zz:InspectDiffToString(baseline, current))
```

`InspectDiff` answers what a patch costs and what each of its columns chose. A patch's size is decided per column, and a column reported as `tagged` is one that could not be taken apart, which is usually the answer when a patch is larger than expected.

```lua
for _, column in Zz:InspectDiff(before, after).Columns do
    print(column.Key, column.Form, column.Bits)
end
```

---

## Benchmarking

```lua
local result = Zz:Benchmark(value, 100)
print(Zz:BenchmarkToString(value, 100))
```

Times a round trip. Reports per call milliseconds averaged over the given number of iterations, plus packet size. A warm up pass runs first so initial compilation does not skew the result.

---

## Strings

For DataStores or anywhere else that will not take a buffer:

```lua
local text, instances = Zz:SerializeToString(value)
local value = Zz:DeserializeFromString(text, instances)
```

---

## License

MIT License. Copyright (c) 2026 Ve Development.
