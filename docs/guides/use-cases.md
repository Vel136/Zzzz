---
sidebar_position: 1
---

# Use Cases

Practical patterns for common Zzzz scenarios.

---

## Basic Round Trip

```lua
local Zzzz = require(ReplicatedStorage.Zzzz)
local Zz = Zzzz.new()

local packet, instances = Zz:Serialize({
    Coins = 5000,
    Position = Vector3.new(10, 20, 30),
})

local data = Zz:Deserialize(packet, instances)
```

---

## Saving Player Data to a DataStore

DataStores take strings, not buffers, so use the string entry points.

```lua
local dataStore = DataStoreService:GetDataStore("PlayerSaves")

local function save(player, saveData)
    local text = Zz:SerializeToString(saveData)
    dataStore:SetAsync("Player_" .. player.UserId, text)
end

local function load(player)
    local text = dataStore:GetAsync("Player_" .. player.UserId)
    if not text then
        return nil
    end
    return Zz:DeserializeFromString(text)
end
```

---

## Sending State Over a RemoteEvent

```lua
local remote = ReplicatedStorage.StateUpdate

local function sendState(player, state)
    local packet, instances = Zz:Serialize(state)
    remote:FireClient(player, packet, instances)
end

remote.OnClientEvent:Connect(function(packet, instances)
    local state = Zz:Deserialize(packet, instances)
    applyState(state)
end)
```

---

## Diffing a Tick Loop

Send only what changed since the last tick, with the guarantee it is never worse than a full Serialize.

```lua
local lastSent = {}

local function onHeartbeat()
    for _, player in Players:GetPlayers() do
        local state = buildStateFor(player)
        local packet = Zz:Diff(lastSent[player], state)
        remote:FireClient(player, packet)
        lastSent[player] = state
    end
end
```

On the receiving side:

```lua
local baseline = nil

remote.OnClientEvent:Connect(function(packet)
    baseline = Zz:Patch(baseline, packet)
    render(baseline)
end)
```

---

## Skipping the Diff Guard on Known-Sparse Traffic

Once you have measured that a tick loop only ever touches a small fraction of rows, skip the second encode `Diff` pays for.

```lua
local function onHeartbeat()
    for _, player in Players:GetPlayers() do
        local state = buildStateFor(player)
        local packet = Zz:DiffOnly(lastSent[player], state)
        remote:FireClient(player, packet)
        lastSent[player] = state
    end
end
```

---

## Compiling a Schema for a Repeated Shape

Useful when a server writes the same record shape over and over, such as an inventory row or a leaderboard entry.

```lua
local sample = fetchSampleSaves()
local Schema = Zzzz.schema(sample, { Columnar = true })

local function save(playerSave)
    local packet = Schema:Encode(playerSave)
    dataStore:SetAsync(key, buffer.tostring(packet))
end
```

Save the schema itself once, rather than deriving it on every server start:

```lua
local storedSchema = Schema:Save()
-- write storedSchema somewhere persistent, then on later starts:
local Schema = Zzzz.loadSchema(storedSchema)
```

---

## Replicating an Instance Hierarchy

Use `"full"` InstanceMode only for data your own server produced, never for anything a client sent.

```lua
local Zz = Zzzz.new({ InstanceMode = "full" })

local packet = Zz:Serialize(workspace.PrebuiltRig)
-- store or send packet
local rebuilt = Zz:Deserialize(packet)
rebuilt.Parent = workspace
```

---

## Quantizing Positions for Bandwidth

Trade a small amount of precision for smaller packets on frequently sent positional data.

```lua
local Zz = Zzzz.new({ Precision = 0.01 })

local packet = Zz:Serialize({
    Position = character.PrimaryPart.Position,
    Rotation = character.PrimaryPart.CFrame,
})
```

---

## Bit Packing Dense Flag Arrays

```lua
local Zz = Zzzz.new({ BitPack = true })

local packet = Zz:Serialize({
    Achievements = achievementFlags, -- an array of 40+ booleans
})
```

---

## Columnar Encoding for Arrays of Records

Best for arrays of many similarly shaped rows, such as inventories or leaderboard snapshots.

```lua
local Zz = Zzzz.new({ Columnar = true, StructureCache = true })

local packet = Zz:Serialize({
    Leaderboard = leaderboardRows, -- { { Name = ..., Score = ... }, ... }
})
```

---

## Diagnosing an Unexpectedly Large Packet

```lua
print(Zz:InspectToString(saveData))
```

```lua
print(Zz:InspectDiffToString(lastSent, currentState))
```

A column reported as `tagged` in the diff report is one that could not be taken apart into a cheaper form, and is usually where the extra bytes are going.

---

## Benchmarking Before Shipping a Change

```lua
print(Zz:BenchmarkToString(sampleSaveData, 200))
```

Run this before and after changing options like `Columnar` or `Correlate` to see whether the tradeoff is actually worth it for your specific data shape.
