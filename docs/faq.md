---
sidebar_position: 7
---

# FAQ

Answers to the questions that come up most often.

---

## General

**What is Zzzz?**

Zzzz is zero schema serialization for Luau. Hand it any value and it works out the shape and the encoding on its own, with no type declarations to write and no schema to keep in sync.

---

**Does Zzzz compress data?**

Yes, but structurally rather than through a general entropy coder like zstd: narrow tags, varints, interning, references, columnar layouts, and packed rotations. It does not run a general compression pass on top of that. If you want one anyway, layer the engine's own:

```lua
local packet = Zz:Serialize(data)
local small = EncodingService:CompressBuffer(packet, Enum.CompressionAlgorithm.Zstd)
```

Native zstd is not something a Luau implementation will beat, so Zzzz does not try to.

---

**Is Zzzz free to use?**

Yes. Zzzz is released under the MIT License.

---

## Instances

**Why does Serialize return two values?**

The second value is a side array of any Roblox Instances found in the data. Roblox already replicates Instance references natively, so they cannot travel inside a buffer, and Serialize hands them back separately. Pass that array to Deserialize. If your data has no Instances, the array is empty and can be ignored.

---

**What is the difference between InstanceMode "reference" and "full"?**

`"reference"`, the default, stores Instances as indices into the side array: the safe default for anything a client sent you. `"full"` serializes the whole hierarchy, ClassName, non-default properties, attributes, tags, and children, so it can be rebuilt somewhere else entirely.

---

**Is "full" InstanceMode safe to use on untrusted input?**

No. A packet is data, and a hostile one written in full mode can name any creatable ClassName and any writable property, including a Script and its Source. Nothing is parented during decode, so the result is inert until the caller parents it, but a packet from an untrusted source must be inspected before it goes anywhere near the DataModel. Do not use `"full"` on anything a client sent you.

---

## Precision and Loss

**Does Zzzz ever lose data?**

Only if you opt into the `Precision` option, which rounds non-integer numbers, and Vector2, Vector3, and CFrame positions, to a chosen step before encoding. Worst case error is half the precision. Integers are always left exact. Without `Precision` set, Zzzz is lossless.

---

**If I set Precision, will a reader with a different Precision setting decode correctly?**

Yes. The precision travels inside the packet header, so any reader decodes it correctly regardless of its own configured setting.

---

## Diffing

**What does Diff give me over Serialize?**

`Diff` sends only what changed since a value the receiver already holds, which is far smaller when most of the data is unchanged between ticks. It guarantees the result is never larger than a plain `Serialize` would have been, since it computes both and returns the smaller.

---

**When should I use DiffOnly instead of Diff?**

`DiffOnly` skips the guarantee and its extra encode, returning the patch whatever its size. Reach for it once you know your traffic is sparse. If most values change on a given tick, a patch can come out larger than the full form, so `Diff` or a direct `Serialize` is the safer default until you have measured your own traffic.

---

**What happens if I apply a patch to the wrong baseline?**

It does not error. It produces a value that is wrong in a way nothing detects, and every later patch built on it inherits the error. Keep one baseline per receiver, and diff against the last value actually sent or acknowledged.

---

## Schemas

**When is a schema worth deriving?**

When a server writes the same data shape repeatedly, and that shape is record-like rather than deeply nested.

A schema records the encoding decisions once so later encodes replay them instead of rediscovering them. Measured across thirteen shapes, that ranged from 14.2x faster on wide uniform numeric data to 0.69x on heterogeneous recursive data, where it is slower than not having one. Bytes were identical on ten of the thirteen.

Derivation is paid once, so it only pays off if you encode more than once with the same schema. Save it with `Schema:Save` rather than deriving on each server start. See [Benchmarks](./benchmarks).

---

**Can a schema go stale?**

Yes. A schema inherits the ranges of the sample it was derived from. A value that falls outside those ranges is still encoded correctly; the schema falls back safely rather than writing a truncated value. Derive a new schema once the data has clearly outgrown the old one.

---

## Performance

**How do I see what a packet actually costs?**

```lua
print(Zz:InspectToString(value))
print(Zz:InspectDiffToString(baseline, current))
```

`Inspect` breaks a packet down by size, table count, and value type. `InspectDiff` breaks a patch down by column, which is the fastest way to see why a particular patch came out larger than expected.

---

**How do I time a round trip?**

```lua
print(Zz:BenchmarkToString(value, 100))
```
