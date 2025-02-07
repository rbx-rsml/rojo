--!nolint LocalShadow

--[[
	Attempts to set a property on the given instance.
]]

local Packages = script.Parent.Parent.Parent.Packages
local Log = require(Packages.Log)
local RbxDom = require(Packages.RbxDom)
local Error = require(script.Parent.Error)

local function setProperty(instance, propertyName, value)
	if propertyName == "StyledProperties" then
		-- Currently integers don't work in styled properties (bug), so
		-- instead we are resorting to turning stringified enums into enums.
		for styledPropName, styledPropValue in value do
			if type(styledPropValue) ~= "string" then continue end
			if not string.match(styledPropValue, "^Enum") then continue end
			
			local split = string.split(styledPropValue, ".")
			if #split ~= 3 then continue end

			local ok, enum = pcall(function() return Enum[split[2]] end)
			if not ok then continue end

			local ok, enumVariant = pcall(function() return enum[split[3]] end)
			if not ok then continue end

			value[styledPropName] = enumVariant
		end

		instance:SetProperties(value)
		return true
	end

	local descriptor = RbxDom.findCanonicalPropertyDescriptor(instance.ClassName, propertyName)

	-- We can skip unknown properties; they're not likely reflected to Lua.
	--
	-- A good example of a property like this is `Model.ModelInPrimary`, which
	-- is serialized but not reflected to Lua.
	if descriptor == nil then
		Log.trace("Skipping unknown property {}.{}", instance.ClassName, propertyName)

		return true
	end

	if descriptor.scriptability == "None" or descriptor.scriptability == "Read" then
		return false,
			Error.new(Error.UnwritableProperty, {
				className = instance.ClassName,
				propertyName = propertyName,
			})
	end

	local writeSuccess, err = descriptor:write(instance, value)

	if not writeSuccess then
		if err.kind == RbxDom.Error.Kind.Roblox and err.extra:find("lacking permission") then
			return false,
				Error.new(Error.LackingPropertyPermissions, {
					className = instance.ClassName,
					propertyName = propertyName,
				})
		end

		return false,
			Error.new(Error.OtherPropertyError, {
				className = instance.ClassName,
				propertyName = propertyName,
			})
	end

	return true
end

return setProperty
