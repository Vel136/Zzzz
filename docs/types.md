---
sidebar_position: 5
sidebar_label: "Supported Types"
---

# Supported Types

What Zzzz can serialize, and what each value costs with default options.

Sizes are measured by serializing the value on its own and subtracting the 3-byte packet header, so each figure includes the value's tag byte. A value inside a larger payload often costs less, since repeated strings and tables are stored once and referenced afterwards.

Several types have more than one form. The encoder picks per value and uses the smaller one, so a whole-number `Vector3` costs less than a fractional one.

---

## Luau Types

| Type | Size | Notes |
|---|--:|---|
| `nil` | 1 B | |
| `boolean` | 1 B | `true` and `false` both |
| `number` | 1-9 B | see below |
| `string` | 1 B + length | `""` is 1 B |
| `buffer` | 1 B + length | |
| `table` | varies | see below |

Functions, coroutines and userdata are not supported.

### Numbers

| Value | Size |
|---|--:|
| `0` to `31` | 1 B |
| `32` | 2 B |
| `300` | 3 B |
| `70000` | 5 B |
| `1.5` | 5 B |
| `0.1` | 9 B |
| `NaN`, `inf`, `-inf`, `-0` | 1 B |

Integers use an integer form when one fits. `1.5` fits single precision and costs 5 B; `0.1` does not and costs 9 B.

### Strings

| Value | Size |
|---|--:|
| `""` | 1 B |
| `"hello"` | 6 B |
| 20 characters | 21 B |

A string repeated within a payload is stored once. Later occurrences cost 1-2 B. Strings sharing a prefix or suffix with a nearby string store only the differing part.

### Tables

| Value | Size |
|---|--:|
| `{}` | 1 B |
| `{1, 2, 3}` | 4 B |
| `{a = 1}` | 5 B |
| `{1, a = 2}` | 7 B |

Arrays, maps and mixed tables each have their own form. Shared references and cycles are preserved: a table appearing twice is written once, and `t.self == t` still holds after a round trip.

Nesting is limited to `MaxDepth` (default 512) and total node count to `MaxNodes` (default 100,000). Exceeding either raises an error.

---

## Roblox Types

### Vectors and Geometry

| Type | Size | Example |
|---|--:|---|
| `Vector2` | 3 B | `Vector2.new(4, 2)` |
| `Vector2` | 9 B | `Vector2.new(4.5, 2.25)` |
| `Vector3` | 4 B | `Vector3.new(4, 2, 1)` |
| `Vector3` | 13 B | `Vector3.new(4.5, 2.25, 1.125)` |
| `Vector2int16` | 5 B | |
| `Vector3int16` | 7 B | |
| `CFrame` | 5 B | position only, whole numbers |
| `CFrame` | 9 B | with rotation |
| `Ray` | 25 B | |
| `Region3` | 25 B | |
| `Region3int16` | 13 B | |

Whole-number vectors use a smaller form than fractional ones.

:::note CFrame rotation is lossy
Positions round trip exactly. Rotations are stored as a rotation id for common orientations and a packed quaternion otherwise, and come back accurate to roughly three decimal places. Store the components as numbers if you need them exact.
:::

### UI

| Type | Size |
|---|--:|
| `UDim` | 3 B |
| `UDim2` | 4 B |
| `Rect` | 17 B |

### Colour

| Type | Size | Notes |
|---|--:|---|
| `Color3` | 4 B | channels expressible in 0-255 |
| `Color3` | 13 B | otherwise |
| `BrickColor` | 2 B | |
| `ColorSequence` | 33 B | two keypoints |
| `ColorSequenceKeypoint` | 17 B | |

### Numbers and Ranges

| Type | Size |
|---|--:|
| `NumberRange` | 9 B |
| `NumberSequence` | 25 B |
| `NumberSequenceKeypoint` | 13 B |

### Enums

| Type | Size |
|---|--:|
| `EnumItem` | 5 B |
| `Enum` | 4 B |

Enum type names are stored once per packet. The first `EnumItem` of a given type pays for the name; later items of that type cost less.

### Other

| Type | Size |
|---|--:|
| `Axes` | 2 B |
| `Faces` | 2 B |
| `DateTime` | 9 B |
| `TweenInfo` | 15 B |
| `PhysicalProperties` | 21 B |
| `Font` | 44 B |
| `PathWaypoint` | 15 B |
| `RaycastParams` | 13 B |
| `OverlapParams` | 13 B |
| `CatalogSearchParams` | 16 B |
| `FloatCurveKey` | 10 B |
| `ValueCurveKey` | varies |
| `RotationCurveKey` | varies |
| `Path2DControlPoint` | varies |
| `Content` | 17 B |

:::caution Instance filters are not carried
`RaycastParams` and `OverlapParams` come back with an empty `FilterDescendantsInstances`. Repopulate it yourself after decoding.
:::

`Random` is not supported. Its internal state cannot be read back, so it raises an error rather than being encoded.

---

## Instances

An Instance reference costs 1-2 B in the packet. The Instance itself travels in the side array that `Serialize` returns:

```lua
local packet, instances = Zz:Serialize({ part = workspace.Part })
local data = Zz:Deserialize(packet, instances)
```

Identity is preserved. The same Instance referenced twice is one entry in the array, and the decoded value points at the original Instance.

Under `InstanceMode = "full"` the hierarchy is written into the packet instead: ClassName, non-default properties, attributes, tags and children. The side array then carries only Instances referenced from outside the serialized tree. Only `Archivable` instances are included.

See [Options](./options) for when to use full mode, and the security note that goes with it.
