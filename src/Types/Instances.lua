--!strict
--!optimize 2

--[[
	Full Instance serialization.

	Flattens a hierarchy into a list of nodes, each carrying a ClassName, its
	non-default properties, its attributes, its tags, and the index of its
	parent within the same list.

	Instance-valued properties are the interesting part. A WeldConstraint's
	Part0 or a SelectionBox's Adornee may point at something inside the tree
	being serialized, or at something outside it:

	  inside  -> stored as a node index, and rebound to the rebuilt copy
	  outside -> stored as an index into the external instance array, exactly
	             like v1's reference mode

	Getting this wrong is what makes naive serializers produce welds that still
	point at the original parts.
]]

local Reflection = require(script.Parent.Reflection)

local Instances = {}

local CollectionService = game:GetService("CollectionService")

-- Property values that are themselves Instances get one of these markers so
-- the decoder knows which table to resolve against.
local INTERNAL = 0
local EXTERNAL = 1

Instances.INTERNAL = INTERNAL
Instances.EXTERNAL = EXTERNAL

export type Reference = {
	kind: number,
	index: number,
}

export type Node = {
	className: string,
	parentIndex: number, -- 0 for the root
	properties: { [string]: any },
	references: { [string]: Reference },
	attributes: { [string]: any },
	tags: { string },
}

export type Tree = {
	nodes: { Node },
}

--[[
	Walk an instance and its descendants into a flat node list.

	`externals` is appended to for any Instance-valued property pointing
	outside the tree; the caller passes it through to the encoder so those
	references travel in the side array.
]]
function Instances.flatten(
	root: Instance,
	externals: { Instance },
	externalIds: { [Instance]: number },
	maxNodes: number?
): Tree
	local limit = maxNodes or 100000
	local nodes: { Node } = {}

	-- Assign every instance in the tree an index up front, so a property that
	-- points forward (a weld referencing a part serialized later) still
	-- resolves.
	local indexOf: { [Instance]: number } = {}
	local ordered: { Instance } = {}

	local function collect(instance: Instance)
		if #ordered >= limit then
			error(`Zzzz: instance tree exceeded {limit} nodes`, 0)
		end
		local index = #ordered + 1
		ordered[index] = instance
		indexOf[instance] = index
		for _, child in instance:GetChildren() do
			if child.Archivable then
				collect(child)
			end
		end
	end

	collect(root)

	for index, instance in ordered do
		local parent = instance.Parent
		local parentIndex = 0
		if parent and indexOf[parent] then
			parentIndex = indexOf[parent]
		end

		local references: { [string]: Reference } = {}

		--[[
			Hold back Instance-valued properties from the plain capture: they
			are recorded as references instead, since a raw Instance cannot be
			written into a buffer.
		]]
		local properties = Reflection.capture(instance, function(name, value)
			if typeof(value) ~= "Instance" then
				return true
			end

			local internalIndex = indexOf[value]
			if internalIndex then
				references[name] = { kind = INTERNAL, index = internalIndex }
			else
				local externalIndex = externalIds[value]
				if not externalIndex then
					externalIndex = #externals + 1
					externals[externalIndex] = value
					externalIds[value] = externalIndex
				end
				references[name] = { kind = EXTERNAL, index = externalIndex }
			end

			return false
		end)

		local attributes: { [string]: any } = {}
		for key, value in instance:GetAttributes() do
			attributes[key] = value
		end

		local tags: { string } = {}
		local tagsOk, instanceTags = pcall(function()
			return CollectionService:GetTags(instance)
		end)
		if tagsOk then
			tags = instanceTags
		end

		nodes[index] = {
			className = instance.ClassName,
			parentIndex = parentIndex,
			properties = properties,
			references = references,
			attributes = attributes,
			tags = tags,
		}
	end

	return { nodes = nodes }
end

--[[
	Rebuild a hierarchy from a flat node list.

	Runs in three passes because none of them can be merged safely:
	  1. construct every instance, so indices can be resolved
	  2. apply properties and parent them
	  3. bind Instance-valued references, now that every target exists
]]
function Instances.rebuild(tree: Tree, externals: { Instance }): (Instance?, { string })
	local nodes = tree.nodes
	local built: { Instance } = {}
	local problems: { string } = {}

	for index, node in nodes do
		local ok, instance = pcall(Instance.new, node.className)
		if not ok or not instance then
			table.insert(problems, `cannot create {node.className}`)
			-- A placeholder keeps indices aligned for everything that follows.
			instance = Instance.new("Folder")
			instance.Name = node.className
		end
		built[index] = instance
	end

	for index, node in nodes do
		local instance = built[index]

		local failures = Reflection.apply(instance, node.properties)
		for _, name in failures do
			table.insert(problems, `{node.className}.{name} not writable`)
		end

		for key, value in node.attributes do
			pcall(function()
				instance:SetAttribute(key, value)
			end)
		end

		for _, tag in node.tags do
			pcall(function()
				CollectionService:AddTag(instance, tag)
			end)
		end
	end

	-- References last: every instance now exists, so internal targets resolve.
	for index, node in nodes do
		local instance = built[index]
		for name, reference in node.references do
			local target: Instance? = if reference.kind == INTERNAL
				then built[reference.index]
				else externals[reference.index]

			-- Same name check as Reflection.apply: a corrupted packet must not
			-- reach the engine with an arbitrary byte string as a field name.
			if target and Reflection.isPropertyName(name) then
				local ok = pcall(function()
					(instance :: any)[name] = target
				end)
				if not ok then
					table.insert(problems, `{node.className}.{name} reference not writable`)
				end
			end
		end
	end

	-- Parent after properties so that anything reacting to being parented sees
	-- a fully configured instance.
	for index, node in nodes do
		if node.parentIndex ~= 0 then
			local parent = built[node.parentIndex]
			if parent then
				pcall(function()
					built[index].Parent = parent
				end)
			end
		end
	end

	return built[1], problems
end

return Instances
