--!strict
--!optimize 2

--[[
	Property discovery for full Instance serialization.

	Built on ReflectionService:GetPropertiesOfClass, so there is no bundled API
	dump to keep in sync and no HTTP call at runtime.

	Each entry the service returns looks like:

		{
			Name = "Anchored",
			Serialized = true,
			Owner = "BasePart",
			Type = { EngineType = "bool", ScriptType = "boolean" },
			Permits = { Read = <SecurityCapabilities>, Write = <SecurityCapabilities> },
			Display = { Category = "Part" },
		}

	Two filters are needed to get from that to a usable list:

	  Serialized == true
	      Drops computed values like AssemblyMass and ExtentsSize, which are
	      derived from other properties and cannot be written back.

	  Permits must be non-empty
	      Drops the lowercase legacy aliases (size, shape, formFactorRaw) that
	      are marked serialized but raise on assignment.

	A handful of properties survive both filters under a name Luau cannot
	address. Those are mapped through ALIAS below -- without it, a Part loses
	its Size and Color, which is not a subtle failure.
]]

local Reflection = {}

local ReflectionService = game:GetService("ReflectionService")

--[[
	Serialized property name -> the name scripts can actually read and write.

	These exist because the engine stores a property under one name and exposes
	it under another. The stored name is marked Serialized but is either
	unreadable from script or carries no permits; the scriptable name is marked
	Serialized = false. Both filters below would therefore drop the property
	entirely, which is how a Part silently loses its Size and Colour and a weld
	silently loses the parts it welds.
]]
local ALIAS: { [string]: string } = {
	size = "Size",
	shape = "Shape",
	Color3uint8 = "Color",
	formFactorRaw = "FormFactor",
	MaterialVariantSerialized = "MaterialVariant",

	-- Constraint and joint endpoints. Without these, welds, motors and every
	-- other joint rebuild pointing at nothing.
	Part0Internal = "Part0",
	Part1Internal = "Part1",
	Attachment0Internal = "Attachment0",
	Attachment1Internal = "Attachment1",
}

Reflection.ALIAS = ALIAS

--[[
	Properties that are writable and serialized but should never be captured.

	Parent is handled by the hierarchy walk itself; writing it during rebuild
	would parent children into the live tree at the wrong moment.
]]
local SKIP: { [string]: boolean } = {
	Parent = true,
	Archivable = true,
}

Reflection.SKIP = SKIP

export type PropertyList = { string }

local classCache: { [string]: PropertyList } = {}
local defaultCache: { [string]: Instance? } = {}

--[[
	Ordered list of writable property names for a class.

	Sorted so that encoder and decoder agree on ordering regardless of the
	order the reflection service happens to return, and cached because the
	reflection call is not cheap and class lists never change at runtime.
]]
function Reflection.propertiesOf(className: string): PropertyList
	local cached = classCache[className]
	if cached then
		return cached
	end

	local ok, entries = pcall(function()
		return ReflectionService:GetPropertiesOfClass(className)
	end)

	if not ok or type(entries) ~= "table" then
		classCache[className] = {}
		return classCache[className]
	end

	local names: PropertyList = {}
	local seen: { [string]: boolean } = {}

	--[[
		Names present on this class, so a storage-only property can be matched
		against a scriptable sibling.
	]]
	local available: { [string]: boolean } = {}
	for _, entry in entries :: { any } do
		available[entry.Name] = true
	end

	--[[
		Derive the scriptable name for a storage-only property.

		The engine's convention is a suffix -- Part0Internal for Part0,
		MaterialVariantSerialized for MaterialVariant -- so stripping the suffix
		and checking that the result is a real property on this class catches
		future cases without needing them listed by hand. ALIAS stays for the
		irregular ones (size, shape, Color3uint8) that follow no pattern.
	]]
	local function scriptableName(rawName: string): string?
		local explicit = ALIAS[rawName]
		if explicit then
			return explicit
		end

		for _, suffix in { "Internal", "Serialized", "Xml", "_XML" } do
			if #rawName > #suffix and rawName:sub(-#suffix) == suffix then
				local base = rawName:sub(1, #rawName - #suffix)
				if available[base] then
					return base
				end
			end
		end

		return nil
	end

	for _, entry in entries :: { any } do
		if entry.Serialized then
			local rawName = entry.Name

			local permits = entry.Permits
			local hasPermits = false
			if type(permits) == "table" then
				for _ in permits :: { [any]: any } do
					hasPermits = true
					break
				end
			end

			-- A storage-only property (serialized, no permits) is usable only
			-- through its scriptable counterpart.
			local name = if hasPermits then rawName else scriptableName(rawName)

			if name and not seen[name] and not SKIP[name] then
				seen[name] = true
				table.insert(names, name)
			end
		end
	end

	table.sort(names)
	classCache[className] = names
	return names
end

--[[
	A pristine instance of a class, used to recognise values still at their
	default so they can be left out of the packet entirely.

	Returns nil for classes that cannot be constructed from script (services,
	abstract classes); callers then capture every readable property instead.
]]
function Reflection.defaultFor(className: string): Instance?
	if defaultCache[className] ~= nil then
		return defaultCache[className]
	end

	local ok, instance = pcall(Instance.new, className)
	local result = if ok then instance else nil

	-- false marks "already tried and failed", so the pcall runs once per class.
	defaultCache[className] = result or (false :: any)
	return result
end

function Reflection.canCreate(className: string): boolean
	return Reflection.defaultFor(className) ~= nil
end

--[[
	Capture the properties of `instance` that differ from a fresh instance of
	its class. Returns a name -> value map.

	`shouldCapture` lets the caller veto individual values -- used to hold back
	Instance-valued properties, which need reference ids rather than raw values.
]]
function Reflection.capture(
	instance: Instance,
	shouldCapture: ((name: string, value: any) -> boolean)?
): { [string]: any }
	local className = instance.ClassName
	local names = Reflection.propertiesOf(className)
	local default = Reflection.defaultFor(className)
	local captured: { [string]: any } = {}

	for _, name in names do
		local readOk, value = pcall(function()
			return (instance :: any)[name]
		end)

		if readOk then
			local differs = true

			if default then
				local defaultOk, defaultValue = pcall(function()
					return (default :: any)[name]
				end)
				if defaultOk and defaultValue == value then
					differs = false
				end
			end

			if differs and (not shouldCapture or shouldCapture(name, value)) then
				captured[name] = value
			end
		end
	end

	return captured
end

--[[
	Write captured properties back onto an instance.

	Individual failures are collected rather than raised: a property may be
	writable in Studio but locked at runtime, and losing one property is a far
	better outcome than losing the whole rebuild.
]]
--[[
	Names that can safely be used to index an Instance.

	A corrupted packet carries arbitrary bytes where a property name belongs,
	and the engine warns that indexing with a string holding trailing bytes
	"will error in the future". Restricting to identifier-shaped names keeps
	that out of the engine entirely, and no real property name is excluded.
]]
local function isPropertyName(name: string): boolean
	return string.match(name, "^[%a_][%w_]*$") ~= nil
end

Reflection.isPropertyName = isPropertyName

function Reflection.apply(instance: Instance, properties: { [string]: any }): { string }
	local failures: { string } = {}

	for name, value in properties do
		if not isPropertyName(name) then
			table.insert(failures, name)
			continue
		end

		local ok = pcall(function()
			(instance :: any)[name] = value
		end)
		if not ok then
			table.insert(failures, name)
		end
	end

	return failures
end

function Reflection.clearCache(): ()
	table.clear(classCache)
	table.clear(defaultCache)
end

return Reflection
