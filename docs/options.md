---
sidebar_position: 4
sidebar_label: "Options"
---

# Options

Every option is off by default. Zzzz still encodes compactly with none of them set - narrow tags, varints, and interning are always on. The options below trade encode time for fewer bytes, and each one helps on some shapes and does nothing on others.

```lua
local Zz = Zzzz.new({
    StructureCache = true,
    BitPack = true,
    Columnar = true,
})
```

Option names are matched without regard to case. An unknown name raises an error rather than being ignored.

---

## What They Are Worth

Measured on 500 player saves (uniform records, nested inventories, 40-flag boolean arrays) and 2,000 float-heavy movement records, in Studio:

| Options | Saves | Floats |
|---|--:|--:|
| defaults | 141,037 B | 60,013 B |
| `StructureCache` | 87,219 B | 54,017 B |
| `+ BitPack` | 69,220 B | 54,017 B |
| `+ Columnar` | 28,324 B | 52,022 B |
| `+ Correlate` | 28,324 B | 52,022 B |
| `+ Precision = 0.1` | 28,324 B | 24,604 B |

Encode time on the saves payload moved from 22ms at defaults to 40ms with `Columnar`, and to 69ms with `Correlate` added. Timings vary with hardware and Studio load.

Two things to read from that table. `Columnar` does most of the work on record-shaped data, taking the saves payload to a fifth of its default size. `Correlate` changes nothing here and costs 29ms doing it, because nothing in this data correlates.

---

## StructureCache

Sends the keys of repeated table shapes once instead of per table.

```lua
Zzzz.new({ StructureCache = true })
```

**Use it when** your data holds many tables with the same keys - an array of player records, a list of items, anything record-shaped. This is the most broadly useful option and the first one to reach for.

**Skip it when** your tables have varying keys, or there are few of them. It costs a little CPU to track shapes that never repeat.

On the saves payload above it removed 38% of the bytes on its own.

---

## BitPack

Packs dense arrays of 8 or more booleans at one bit each.

```lua
Zzzz.new({ BitPack = true })
```

1,000 booleans cost 1,005 B by default and 130 B with `BitPack`. Lossless.

**Use it when** you store flag arrays - achievements, quest states, unlocked levels, per-slot occupancy.

**Skip it when** your booleans are scattered as individual fields rather than collected in arrays. It only acts on runs of 8 or more.

---

## Columnar

Writes arrays of uniform records as one column per field rather than one block per row.

```lua
Zzzz.new({ Columnar = true, BitPack = true })
```

Values of a single type end up adjacent, which lets each column pick a form that suits it: a boolean column bit packs, a low-cardinality string column becomes a dictionary, integers pack at a fixed bit width, and `Vector3`s are written as deltas from a nearby base.

**Use it when** you have arrays of records with the same fields. This is where the largest wins are - the saves payload dropped from 69,220 B to 28,324 B.

**Skip it when** your data is deeply nested, recursive, or heterogeneous. There is no column shape to find, and you pay the search for nothing.

Lossless. Pairs naturally with `BitPack`, which is what packs the boolean columns.

Arrays whose rows are shared with something else, or take part in a cycle, are skipped automatically - rebuilding those as fresh tables would break reference identity.

---

## Correlate

Encodes an integer column as a residual against another column in the same records.

```lua
Zzzz.new({ Columnar = true, Correlate = true })
```

Two fields are often two views of one quantity - `health` and `maxHealth`, `level` and the `xp` for it. Encoded independently each pays for its own full range; encoded against the other, only the difference is stored. The relationship is fitted as slope and intercept, so a scaled pairing is caught as well as an equal one.

**Use it when** you know your records contain related numeric fields, and you have measured that it helps.

**Skip it otherwise.** It requires `Columnar`, costs a correlation pass over every numeric column, and does nothing at all unless the data actually has related fields. On the saves payload it cost 29ms and saved zero bytes.

Check with `Zz:Inspect` before enabling it in production.

---

## Precision

Rounds numbers to a step before encoding.

```lua
Zzzz.new({ Precision = 0.01 })  -- two decimal places
```

**Lossy.** Worst-case error is half the precision.

Applies to non-integer numbers, `Vector2`, `Vector3` and `CFrame` positions. Integers are left exact, since they already encode at least as small. Individual values fall back to their exact form whenever quantizing would not be smaller.

**Use it when** your data is float-heavy and the exact values do not matter - positions, velocities, rotations, anything already approximate. On the float payload above, `Precision = 0.1` more than halved the size.

**Skip it when** your data is mostly integers. It measured zero change on the saves payload, because there was nothing inexact to round.

The precision travels inside the packet, so any reader decodes it correctly regardless of its own settings.

---

## InstanceMode

Controls how Instances are stored.

```lua
Zzzz.new({ InstanceMode = "full" })
```

`"reference"` (the default) stores Instances as indices into the side array that `Serialize` returns. `"full"` serializes the whole hierarchy - ClassName, non-default properties, attributes, tags, children - so it can be rebuilt in a different session or place.

**Use `"full"` when** you need to persist or transfer a hierarchy itself, such as saving a player-built structure to a DataStore.

**Use `"reference"` for everything else**, especially anything arriving over the network.

:::danger Full mode rebuilds whatever the packet describes
A packet is data, and one that has been tampered with can name any creatable ClassName and any writable property, including a `Script` and its `Source`. Nothing is parented during decode, so the result is inert until you parent it, but inspect a packet from an untrusted source before it goes near the DataModel.

Do not use full mode on anything a client sent you.
:::

---

## GuardDiff

Whether `Diff` also encodes the full value, so it never returns a packet larger than a plain `Serialize`.

```lua
Zzzz.new({ GuardDiff = false })
```

On by default. This is the one option that starts enabled.

**Leave it on** unless you know your traffic is sparse. On a tick where most values changed, a patch can come out larger than a full encode, and without the guard that is what gets sent.

**Turn it off** when you have measured your change rate and know patches will win. `Zz:DiffOnly` does the same thing per call without changing the instance setting.

The guard is skipped automatically when the changed fraction proves the comparison cannot go the other way, so on sparse ticks it costs little.

---

## MaxDepth and MaxNodes

```lua
Zzzz.new({ MaxDepth = 512, MaxNodes = 100000 })
```

Limits on table nesting and total node count, in both directions. Defaults are 512 and 100,000.

On decode these are safety limits rather than preferences. A hand-crafted packet of nested table tags costs two bytes per level, and without a bound the decoder would recurse until the stack gave out.

Raise them if you have legitimately deep or large data. Exceeding either raises an error.

---

## Choosing

For most save data and record arrays:

```lua
Zzzz.new({ StructureCache = true, BitPack = true, Columnar = true })
```

For float-heavy network traffic where exactness does not matter:

```lua
Zzzz.new({ Columnar = true, Precision = 0.01 })
```

For deeply nested or heterogeneous data, the defaults are often as good as anything - the column search has nothing to find.

Measure before committing:

```lua
print(Zz:InspectToString(value))
```

See [Benchmarks](./benchmarks) for how these options behave across thirteen different shapes.
