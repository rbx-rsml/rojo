--[[
	Apply a patch to the DOM. Returns any portions of the patch that weren't
	possible to apply.

	Patches can come from the server or be generated by the client.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Packages = script.Parent.Parent.Parent.Packages
local Log = require(Packages.Log)

local PatchSet = require(script.Parent.Parent.PatchSet)
local Types = require(script.Parent.Parent.Types)
local invariant = require(script.Parent.Parent.invariant)

local decodeValue = require(script.Parent.decodeValue)
local reify = require(script.Parent.reify)
local reifyInstance, applyDeferredRefs = reify.reifyInstance, reify.applyDeferredRefs
local setProperty = require(script.Parent.setProperty)

local function applyPatch(instanceMap, patch)
	local patchTimestamp = DateTime.now():FormatLocalTime("LTS", "en-us")
	local historyRecording = ChangeHistoryService:TryBeginRecording("Rojo: Patch " .. patchTimestamp)
	if not historyRecording then
		-- There can only be one recording at a time
		Log.debug("Failed to begin history recording for " .. patchTimestamp .. ". Another recording is in progress.")
	end

	-- Tracks any portions of the patch that could not be applied to the DOM.
	local unappliedPatch = PatchSet.newEmpty()
	
	-- Contains a list of all of the ref properties that we'll need to assign. 
	-- It is imperative that refs are assigned after all instances are created 
	-- to ensure that referents can be mapped to instances correctly.
	local deferredRefs = {}

	for _, removedIdOrInstance in ipairs(patch.removed) do
		local removeInstanceSuccess = pcall(function()
			if Types.RbxId(removedIdOrInstance) then
				instanceMap:destroyId(removedIdOrInstance)
			else
				instanceMap:destroyInstance(removedIdOrInstance)
			end
		end)
		if not removeInstanceSuccess then
			table.insert(unappliedPatch.removed, removedIdOrInstance)
		end
	end

	for id, virtualInstance in pairs(patch.added) do
		if instanceMap.fromIds[id] ~= nil then
			-- This instance already exists. We might've already added it in a
			-- previous iteration of this loop, or maybe this patch was not
			-- supposed to list this instance.
			--
			-- It's probably fine, right?
			continue
		end

		-- Find the first ancestor of this instance that is marked for an
		-- addition.
		--
		-- This helps us make sure we only reify each instance once, and we
		-- start from the top.
		while patch.added[virtualInstance.Parent] ~= nil do
			id = virtualInstance.Parent
			virtualInstance = patch.added[id]
		end

		local parentInstance = instanceMap.fromIds[virtualInstance.Parent]

		if parentInstance == nil then
			-- This would be peculiar. If you create an instance with no
			-- parent, were you supposed to create it at all?
			if historyRecording then
				ChangeHistoryService:FinishRecording(historyRecording, Enum.FinishRecordingOperation.Commit)
			end
			invariant(
				"Cannot add an instance from a patch that has no parent.\nInstance {} with parent {}.\nState: {:#?}",
				id,
				virtualInstance.Parent,
				instanceMap
			)
		end

		local failedToReify = reifyInstance(deferredRefs, instanceMap, patch.added, id, parentInstance)

		if not PatchSet.isEmpty(failedToReify) then
			Log.debug("Failed to reify as part of applying a patch: {:#?}", failedToReify)
			PatchSet.assign(unappliedPatch, failedToReify)
		end
	end

	for _, update in ipairs(patch.updated) do
		local instance = instanceMap.fromIds[update.id]

		if instance == nil then
			-- We can't update an instance that doesn't exist.
			table.insert(unappliedPatch.updated, update)
			continue
		end

		-- Pause updates on this instance to avoid picking up our changes when
		-- two-way sync is enabled.
		instanceMap:pauseInstance(instance)

		-- Track any part of this update that could not be applied.
		local unappliedUpdate = {
			id = update.id,
			changedProperties = {},
		}
		local partiallyApplied = false

		-- If the instance's className changed, we have a bumpy ride ahead while
		-- we recreate this instance and move all of its children into the new
		-- version atomically...ish.
		if update.changedClassName ~= nil then
			-- If the instance's name also changed, we'll do it here, since this
			-- branch will skip the rest of the loop iteration.
			local newName = update.changedName or instance.Name

			-- TODO: When changing between instances that have similar sets of
			-- properties, like between an ImageLabel and an ImageButton, we
			-- should preserve all of the properties that are shared between the
			-- two classes unless they're changed as part of this patch. This is
			-- similar to how "class changer" Studio plugins work.
			--
			-- For now, we'll only apply properties that are mentioned in this
			-- update. Patches with changedClassName set only occur in specific
			-- circumstances, usually between Folder and ModuleScript instances.
			-- While this may result in some issues, like not preserving the
			-- "Archived" property, a robust solution is sufficiently
			-- complicated that we're pushing it off for now.
			local newProperties = update.changedProperties

			-- If the instance's ClassName changed, we'll kick into reify to
			-- create this instance. We'll handle moving all of children between
			-- the instances after the new one is created.
			local mockVirtualInstance = {
				Id = update.id,
				Name = newName,
				ClassName = update.changedClassName,
				Properties = newProperties,
				Children = {},
			}

			local mockAdded = {
				[update.id] = mockVirtualInstance,
			}

			local failedToReify = reifyInstance(deferredRefs, instanceMap, mockAdded, update.id, instance.Parent)

			local newInstance = instanceMap.fromIds[update.id]

			-- Some parts of reify may have failed, but this is not necessarily
			-- critical. If the instance wasn't recreated or has the wrong Name,
			-- we'll consider our attempt a failure.
			if instance == newInstance or newInstance.Name ~= newName then
				table.insert(unappliedPatch.updated, update)
				continue
			end

			-- Here are the non-critical failures. We know that the instance
			-- succeeded in creating and that assigning Name did not fail, but
			-- other property assignments might've failed.
			if not PatchSet.isEmpty(failedToReify) then
				PatchSet.assign(unappliedPatch, failedToReify)
			end

			-- Watch out, this is the scary part! Move all of the children of
			-- instance into newInstance.
			--
			-- TODO: If this fails part way through, should we move everything
			-- back? For now, we assume that moving things will not fail.
			for _, child in ipairs(instance:GetChildren()) do
				child.Parent = newInstance
			end

			-- See you later, original instance.

			-- Because the user might want to Undo this change, we cannot use Destroy
			-- since that locks that parent and prevents ChangeHistoryService from
			-- ever bringing it back. Instead, we parent to nil.

			-- TODO: Can this fail? Some kinds of instance may not appreciate
			-- being reparented, like services.
			instance.Parent = nil

			-- This completes your rebuilding a plane mid-flight safety
			-- instruction. Please sit back, relax, and enjoy your flight.
			continue
		end

		if update.changedName ~= nil then
			local setNameSuccess = pcall(function()
				instance.Name = update.changedName
			end)
			if not setNameSuccess then
				unappliedUpdate.changedName = update.changedName
				partiallyApplied = true
			end
		end

		if update.changedMetadata ~= nil then
			-- TODO: Support changing metadata. This will become necessary when
			-- Rojo persistently tracks metadata for each instance in order to
			-- remove extra instances.
			unappliedUpdate.changedMetadata = update.changedMetadata
			partiallyApplied = true
		end

		if update.changedProperties ~= nil then

			local function applyProperties(properties)
				for propertyName, propertyValue in pairs(properties) do
					-- Because refs may refer to instances that we haven't constructed yet,
					-- we defer applying any ref properties until all instances are created.
					if next(propertyValue) == "Ref" then
						table.insert(deferredRefs, {
							id = update.id,
							instance = instance,
							propertyName = propertyName,
							virtualValue = propertyValue,
						})
						continue
					end
	
					local decodeSuccess, decodedValue = decodeValue(propertyValue, instanceMap)
					if not decodeSuccess then
						unappliedUpdate.changedProperties[propertyName] = propertyValue
						partiallyApplied = true
						continue
					end
	
					local setPropertySuccess = setProperty(instance, propertyName, decodedValue)
					if not setPropertySuccess then
						unappliedUpdate.changedProperties[propertyName] = propertyValue
						partiallyApplied = true
					end
				end
			end

			local properties = update.changedProperties
			local postProperties = properties.PostProperties
			if postProperties then properties.PostProperties = nil end

			applyProperties(properties)
			if postProperties then applyProperties(postProperties.Attributes) end
		end

		if partiallyApplied then
			table.insert(unappliedPatch.updated, unappliedUpdate)
		end
	end

	if historyRecording then
		ChangeHistoryService:FinishRecording(historyRecording, Enum.FinishRecordingOperation.Commit)
	end

	applyDeferredRefs(instanceMap, deferredRefs, unappliedPatch)

	return unappliedPatch
end

return applyPatch
