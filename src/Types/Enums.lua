--!strict
--!optimize 2

--[[
	Enum item indexing.

	Roblox enum values are sparse: Enum.Material.Neon is value 288 and
	Enum.KeyCode.LeftShift is 304, so writing the raw value costs two varint
	bytes where the item's position in its own type costs one.

	Both sides build the same table from GetEnumItems(), whose order is stable
	for a given engine build. That ordering is the only assumption here, and it
	is the same one any API-dump-free approach has to make.

	Tables are built lazily and cached: there are 622 enum types and 3,585
	items in total, and a packet touches a handful.
]]

local Enums = {}

type IndexTable = {
	toIndex: { [number]: number }, -- enum value -> 1-based position
	toItem: { EnumItem }, -- position -> item
}

local cache: { [any]: IndexTable } = {}

local function tableFor(enumType: any): IndexTable
	local existing = cache[enumType]
	if existing then
		return existing
	end

	local toIndex: { [number]: number } = {}
	local toItem: { EnumItem } = {}

	local ok, items = pcall(function()
		return enumType:GetEnumItems()
	end)

	if ok then
		for index, item in items do
			toIndex[item.Value] = index
			toItem[index] = item
		end
	end

	local built = { toIndex = toIndex, toItem = toItem }
	cache[enumType] = built
	return built
end

--[[
	Position of an item within its type, or nil if the engine does not list it.
]]
function Enums.indexOf(item: EnumItem): number?
	return tableFor(item.EnumType).toIndex[item.Value]
end

--[[
	The item at a position, or nil when the index is out of range -- which a
	corrupted packet can easily produce.
]]
function Enums.itemAt(enumType: any, index: number): EnumItem?
	return tableFor(enumType).toItem[index]
end

--[[
	Resolve a type name to its Enum object.

	Indexing Enum with an unknown name raises rather than returning nil, so
	this has to be guarded rather than nil-checked.
]]
function Enums.typeFromName(name: string): any?
	local ok, enumType = pcall(function()
		return (Enum :: any)[name]
	end)
	if ok then
		return enumType
	end
	return nil
end

-- Global type index -------------------------------------------------------

--[[
	A stable id for every enum type the engine exposes.

	Enum:GetEnums() returns types in sorted order, so numbering that list gives
	both sides the same ids without a hardcoded table and without an API dump.
	A type's id is two varint bytes at worst, against the ten or more its name
	would cost.

	The ordering depends on the engine build. Two clients on the same build
	agree, which is the case that matters for networking; a packet written by
	one build and read by another falls back to the name, which is why the name
	form is kept rather than removed.
]]
local typeToId: { [any]: number }? = nil
local idToType: { any }? = nil

local function buildIndex(): ()
	if typeToId then
		return
	end

	local names: { string } = {}
	local byName: { [string]: any } = {}

	local ok, list = pcall(function()
		return Enum:GetEnums()
	end)

	if ok then
		for _, enumType in list do
			local name = tostring(enumType)
			table.insert(names, name)
			byName[name] = enumType
		end
	end

	table.sort(names)

	local forward: { [any]: number } = {}
	local backward: { any } = {}
	for index, name in names do
		local enumType = byName[name]
		forward[enumType] = index
		backward[index] = enumType
	end

	typeToId = forward
	idToType = backward
end

--[[
	Global id for an enum type, or nil when this build does not list it.
]]
function Enums.globalId(enumType: any): number?
	buildIndex()
	return (typeToId :: { [any]: number })[enumType]
end

--[[
	The enum type at a global id, or nil when the id is out of range -- which a
	packet from a different engine build, or a corrupted one, can produce.
]]
function Enums.typeFromGlobalId(id: number): any?
	buildIndex()
	return (idToType :: { any })[id]
end

function Enums.clearCache(): ()
	table.clear(cache)
	typeToId = nil
	idToType = nil
end

return Enums
