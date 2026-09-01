---
sidebar_position: 1
---

# Getting Started

Zzzz is zero schema serialization for Luau. Hand it any value and it works out the shape, packs it into a compact buffer, and hands you back exactly what you put in.

---

## Installation

Drop `Zzzz` into `ReplicatedStorage` and require it.

```lua
local Zzzz = require(ReplicatedStorage.Zzzz)
```

Zzzz has no external dependencies.

---

## Creating an Instance

```lua
local Zzzz = require(ReplicatedStorage.Zzzz)
local Zz = Zzzz.new()
```

`Zzzz.new` accepts an optional options table. See [Documentation](./documentation) for the full list.

---

## Serializing and Deserializing

```lua
local packet, instances = Zz:Serialize({
    Coins = 5000,
    Position = Vector3.new(10, 20, 30),
    Inventory = { "Sword", "Potion" },
})

local data = Zz:Deserialize(packet, instances)
```

`packet` is a `buffer`. `instances` is a side array of any Roblox Instances found in the value, since Instance references cannot travel inside a buffer. Pass it back to Deserialize unchanged. If your data has no Instances the array is empty and can be ignored.

---

## Quick Reference

| I want to... | Method |
|--------------|--------|
| Serialize a value | [`Zz:Serialize`](../api/Zzzz#Serialize) |
| Deserialize a packet | [`Zz:Deserialize`](../api/Zzzz#Deserialize) |
| Send only what changed | [`Zz:Diff`](../api/Zzzz#Diff) |
| Apply a patch | [`Zz:Patch`](../api/Zzzz#Patch) |
| Compile a repeated shape | [`Zzzz.schema`](../api/Zzzz#schema) |
| See what a packet costs | [`Zz:Inspect`](../api/Zzzz#Inspect) |
| Time a round trip | [`Zz:Benchmark`](../api/Zzzz#Benchmark) |
| See practical examples | [Use Cases](./guides/use-cases) |
