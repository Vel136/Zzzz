---
sidebar_position: 6
sidebar_label: "Benchmarks"
---

# Benchmarks

Every figure on this page comes from `src/BenchSchema.lua`, run inside Roblox Studio. Each row is the fastest of three timed attempts, and every payload round trips through a deep structural comparison - both directions, so a key present only after decoding is caught too - before its numbers are reported. A faster encode that does not decode back to the original is not a faster encode.

:::caution Read the ratios, not the milliseconds
These timings were measured in Studio on one machine. They move with hardware, with Studio's own load, and between runs of identical code - the same unchanged row has been measured at 2,125 ms and 1,514 ms in two consecutive sessions. Treat the millisecond columns as an indication of scale, not a target to reproduce. The **byte** columns are exact and did not vary between runs.
:::

---

## Schema vs Adaptive

Zzzz normally discovers everything at encode time: whether an array is columnar, what shape its rows have, which fields lift into columns, and which form each column takes. A schema records those decisions once so later encodes replay them.

The table below runs both paths over thirteen shapes with `StructureCache`, `BitPack` and `Columnar` enabled throughout, so the only variable is the data.

| dataset | values | adaptive | schema (self) | schema (sample) | adaptive bytes | bytes vs adaptive |
|---|--:|--:|--:|--:|--:|--:|
| player saves | 698,120 | 429.66ms | 359.55ms | 325.50ms | 397,204 | +2.8% |
| world entities | 239,274 | 295.61ms | 220.59ms | 225.86ms | 303,970 | +0.0% |
| wide flat rows | 600,000 | 393.46ms | 125.09ms | 118.56ms | 1,200,369 | +0.0% |
| telemetry stream | 100,000 | 225.39ms | 101.19ms | 87.49ms | 203,277 | +0.0% |
| movement snapshots | 50,000 | 47.98ms | 28.66ms | 40.65ms | 442,564 | +0.0% |
| string documents | 90,000 | 108.27ms | 65.22ms | 70.48ms | 1,403,156 | +0.0% |
| sparse optionals | 75,078 | 136.37ms | 134.57ms | 136.93ms | 114,809 | +0.0% |
| deep nested trees | 336,639 | 287.83ms | 239.35ms | 282.81ms | 1,510,768 | +0.0% |
| numeric matrix | 240,000 | 1513.95ms | 106.37ms | 121.79ms | 2,161,305 | +0.0% |
| categorical grid | 120,000 | 34.42ms | 27.78ms | 33.21ms | 30,163 | +0.0% |
| fixture: mixed bag | 28,177 | 26.92ms | 38.80ms | - | 271,670 | +0.0% |
| fixture: sales rows | 15,740 | 11.04ms | 8.32ms | - | 24,205 | +0.0% |
| fixture: nested recs | 44,192 | 49.32ms | 66.06ms | - | 262,433 | +0.0% |

**self** derives the schema on the payload and then encodes that same payload. It measures the replay path cleanly, but it flatters it: the schema has seen every value, so no plan can miss.

**sample** derives on one batch and encodes a *different* batch from the same generator. This is how a schema is actually used - derived once, saved, replayed on data that did not exist when it was derived. The three fixture rows are fixed tables on disk and cannot produce a second batch, so they report `self` only.

---

## What the Schema Buys

| dataset | shape | speedup | derive | saved schema |
|---|---|--:|--:|--:|
| numeric matrix | homogeneous float block | **14.23x** | 1553.7ms | 1,113 B |
| wide flat rows | 40 independent int columns | **3.15x** | 437.6ms | 331 B |
| telemetry stream | monotonic ts, drifting float | **2.23x** | 222.1ms | 74 B |
| movement snapshots | Vector3 + CFrame heavy | 1.67x | 57.5ms | 68 B |
| string documents | dictionary + free text | 1.66x | 117.6ms | 70 B |
| world entities | optional, runs, equal cols | 1.34x | 286.7ms | 252 B |
| fixture: sales rows | clean record array | 1.33x | 11.0ms | 225 B |
| categorical grid | all low-cardinality strings | 1.24x | 35.4ms | 67 B |
| deep nested trees | recursive, non-columnar | 1.20x | 303.1ms | 80 B |
| player saves | uniform records, nested arrays | 1.19x | 413.8ms | 985 B |
| sparse optionals | most fields absent per row | 1.01x | 158.3ms | 204 B |
| fixture: nested recs | deep heterogeneous | 0.75x | 65.2ms | 270 B |
| fixture: mixed bag | heterogeneous, sparse array | 0.69x | 39.1ms | 16 B |

A schema wins where there is a lot to discover and the discovery dominates. The numeric matrix is the clearest case: 240,000 floats across 200 columns, where working out the column forms was almost all of a 1,514 ms encode and replaying them costs 106 ms.

A schema loses where there is nothing to record. `fixture: mixed bag` and `fixture: nested recs` are heterogeneous and recursive - no stable column shape exists to freeze, so the schema adds a lookup per write and buys nothing back. `sparse optionals` breaks even for a related reason: the presence pattern has to be recomputed per batch whatever the schema says.

Two practical consequences:

- **Derivation has to amortise.** The numeric matrix costs 1,554 ms to derive and saves about 1,408 ms per encode, so it pays for itself on the second encode and profits from the third. Derive per call and you are strictly worse off than not having a schema.
- **Saved schemas are small.** 16 B to 1,113 B across every shape here. Persist them with `Schema:Save` and load with `Zzzz.loadSchema`; there is no reason to re-derive on each server start.

---

## Bytes

Ten of the thirteen shapes encode to byte-identical output whether the forms were discovered or replayed. The worst case is `player saves` at **+2.8%**, and the cross-batch column stays within +3.0% everywhere.

That closeness is the point of recording *forms* rather than types. A declared `u16` for a sequential id pays eleven bits a row; the recorded form says "differenced" and pays two. An earlier design storing declared widths came out 26% larger than the adaptive path it was meant to replace.

The cross-batch result is the one worth trusting most: no dataset was refused, no plan miss surfaced, and `telemetry stream` and `sparse optionals` came out marginally *smaller* than adaptive. Schemas generalise across batches of the same shape without falling back - which is the use the feature exists for.

---

## Against JSON

A separate run over a 1,000-player save payload, 1,098,001 values:

| | size | encode | throughput |
|---|--:|--:|--:|
| JSON | 7,804,327 B (7.44 MB) | 75.05ms | 14.63M values/sec |
| Zzzz adaptive | 366,538 B (357.95 KB) | 918.88ms | 1.19M values/sec |
| Zzzz compiled | 438,593 B (428.31 KB) | 207.49ms | 5.29M values/sec |

**21.3x smaller than JSON** adaptively, 17.8x compiled, with the schema derivation costing 271.38ms once.

Decode is the cheaper half in both cases - 117.20ms adaptive (9.37M values/sec), 101.32ms through the schema (10.84M values/sec). A server writing a save pays encode; a client reading one pays decode, and that side is roughly eight times faster than adaptive encoding.

Zzzz does not compress. If you want the bytes smaller still, the engine already has native zstd:

```lua
local packet = Zz:Serialize(data)
local small = EncodingService:CompressBuffer(packet, Enum.CompressionAlgorithm.Zstd)
```

---

## Running Them Yourself

```lua
local Bench = require(ReplicatedStorage.Zzzz.BenchSchema)
Bench.run()
```

The built-in dataset behind the published player-save figures is separate:

```lua
require(ReplicatedStorage.Zzzz.Benchmark)()          -- player saves
require(ReplicatedStorage.Zzzz.Benchmark).runMixed() -- mixed shapes
```

For a single value rather than a suite:

```lua
print(Zz:BenchmarkToString(value, 100))
```

---

## A Note on Reading Encode Times

Encode figures in Studio move by a factor of two between runs of identical code. Six consecutive runs of one unchanged configuration:

```
108   108   107   117   121   199 ms
```

So a row is only meaningful against the other rows in its own run. Across runs, compare ratios rather than milliseconds. Reading them as absolutes has produced several wrong conclusions in the course of developing this library, including a "regression" that was the machine slowing down and an "improvement" that was it speeding up.
