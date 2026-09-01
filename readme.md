# Zzzz

Zero schema serialization for Luau.

**[Creator Store](https://create.roblox.com/store/asset/74623943046652/Zzzz)** | **Version:** v1.0.0

Zzzz takes any Luau value and turns it into a compact buffer with no type declarations to write and no schema to keep in sync. Hand it a table and it works out the shape, picks the narrowest tag for every value, interns repeated strings and tables, and can bit pack, columnar pack, quantize, and diff against a previous value when you want to squeeze further.

---

## Install

```lua
local Zzzz = require(path.to.Zzzz)
local Zz = Zzzz.new()
```

---

## Quick Start

```lua
local Zzzz = require(path.to.Zzzz)
local Zz = Zzzz.new()

local packet, instances = Zz:Serialize({
    Coins = 5000,
    Position = Vector3.new(10, 20, 30),
    Inventory = { "Sword", "Potion" },
})

local data = Zz:Deserialize(packet, instances)
```

`instances` is a side array of any Roblox Instances found in the value. Roblox already replicates Instance references natively, so they cannot travel inside a buffer, and Serialize hands them back separately. Pass the array straight back into Deserialize. If your data holds no Instances the array is empty and can be ignored.

---

## Options

```lua
Zzzz.new({
    InstanceMode = "full",     -- serialize hierarchies, not references
    StructureCache = true,     -- send repeated table shapes once
    Precision = 0.01,          -- lossy: round numbers to 2 decimals
    BitPack = true,            -- 1 bit per boolean in dense arrays
    Columnar = true,           -- one column per field for uniform arrays
    Correlate = false,         -- encode related integer columns as residuals
    GuardDiff = true,          -- Diff never returns a packet worse than Serialize
    MaxDepth = 512,
    MaxNodes = 100000,
})
```

Option names are matched without regard to case, and an unknown option name raises immediately rather than being silently ignored.

**InstanceMode.** `"reference"` (default) stores Instances as indices into the side array. `"full"` serializes the whole hierarchy: ClassName, non-default properties, attributes, tags, and children, so it can be rebuilt in a different session or place.

`"full"` rebuilds whatever the packet describes. A packet is data, and a hostile one can name any creatable ClassName and any writable property, including a Script and its Source. Nothing is parented during decode, so the result is inert until the caller parents it, but a packet from an untrusted source must be inspected before it goes anywhere near the DataModel. Do not use `"full"` on anything a client sent you. Reference mode is the safe default for network input.

**StructureCache.** Sends the keys of a repeated table shape once instead of per table. Large wins on arrays of similar records.

**Columnar.** Writes arrays of uniform records as one column per field rather than one block per row, so a compression pass finds far more structure. Lossless, and skipped for any array whose rows are shared elsewhere or take part in a cycle.

**Precision.** Rounds numbers to this step before encoding. Lossy: worst case error is half the precision. Applies to non-integer numbers, Vector2, Vector3, and CFrame positions. Integers are left exact. The precision travels inside the packet, so any reader decodes it correctly regardless of its own settings.

**Correlate.** Encodes an integer column as a residual against another related column in the same records, such as health against maxHealth. Requires Columnar. Off by default because it costs a correlation pass and only helps when the data actually has related fields.

**BitPack.** Packs dense arrays of 8 or more booleans at one bit each.

**GuardDiff.** Whether `Diff` also encodes the full form, to guarantee it never returns a packet larger than a plain Serialize. Costs a second encode. Turn it off, or use `DiffOnly`, when traffic is known to be sparse.

**MaxDepth / MaxNodes.** Safety limits on decode as well as a preference on encode, so a hand crafted packet of deeply nested tags cannot exhaust the stack.

---

## Core API

```lua
local packet, instances = Zz:Serialize(value)
local value = Zz:Deserialize(packet, instances)
```

Zzzz does not compress. It makes the bytes structurally small: narrow tags, varints, interning, references, packed rotations, and stops there. Layer general compression on top if you want it further reduced:

```lua
local packet = Zz:Serialize(data)
local small = EncodingService:CompressBuffer(packet, Enum.CompressionAlgorithm.Zstd)
```

---

## Diffing

Send only what changed since a value the receiver already holds.

```lua
local packet = Zz:Diff(lastSent, state)
local state = Zz:Patch(lastSent, packet)
```

`Diff` writes both a patch and the full form and returns whichever is smaller, so it can never be worse than calling Serialize directly. That guarantee costs a second encode; `DiffOnly` skips it and returns the patch unconditionally, which is worth reaching for once you know your ticks are sparse.

`Patch` accepts either a patch or a whole packet, so the caller never has to track which `Diff` produced. `Zzzz.IsPatch` reports which one a given packet is if you want to know.

A patch is only meaningful against the exact value it was diffed from. Keep one baseline per receiver and diff against the last value you sent it, or the last value it acknowledged over a reliable channel:

```lua
local packet = Zz:Diff(lastSent[player], state)
lastSent[player] = state
```

Send a full `Serialize` to start, and again whenever a receiver's baseline is in doubt.

---

## Schemas

Derive a schema from sample data so a server writing the same shape repeatedly can replay its encoding decisions instead of rediscovering them every call.

```lua
local Schema = Zzzz.schema(sampleData, options)
local packet = Schema:Encode(data)
local data = Schema:Decode(packet)

local stored = Schema:Save()
local Schema = Zzzz.loadSchema(stored)
```

A schema also patches:

```lua
local packet = Schema:DiffOnly(previous, current)
local packet = Schema:Diff(previous, current)
```

The sample must be representative. A schema inherits the ranges seen in the sample, and a value outside that range falls back safely rather than writing a truncated value.

---

## Inspecting Costs

```lua
print(Zz:InspectToString(value))
print(Zz:InspectDiffToString(baseline, current))
```

`Inspect` reports packet size, table and string counts, and a breakdown by value type. `InspectDiff` reports what each column of a patch chose and how many bytes it cost, which is usually the fastest way to see why a patch came out larger than expected.

---

## Benchmarking

```lua
print(Zz:BenchmarkToString(value, 100))
```

Times a round trip over the given number of iterations and reports average serialize time, deserialize time, and packet size.

---

## Strings

For DataStores or anything else that will not take a buffer directly:

```lua
local text, instances = Zz:SerializeToString(value)
local value = Zz:DeserializeFromString(text, instances)
```

---

## License

MIT License. Copyright (c) 2026 Ve Development.
