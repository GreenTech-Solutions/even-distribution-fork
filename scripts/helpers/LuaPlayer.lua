local transfers = require("scripts.transfers")
local config = require("config")
local player = scripts.helpers
local _ = scripts.helpers.on

-- Helper functions for LuaPlayer --

function player:setting(name)
	if name == "enableDragDistribute" then
		if settings.global["disable-distribute"].value then return false end
	elseif name == "enableInventoryCleanupHotkey" then
		if settings.global["disable-inventory-cleanup"].value then return false end
	elseif name == "cleanupDropRange" then
		return math.min(storage.settings[self.index].cleanupDropRange, settings.global["global-max-inventory-cleanup-range"].value)
	end

	local setting = storage.settings[self.index][name]
	if setting == nil and self.mod_settings[name] then return self.mod_settings[name].value end
	return setting
end

function player:changeSetting(name, newValue)
	local setting = storage.settings[self.index]
	if setting[name] == nil and self.mod_settings[name] then 
		self.mod_settings[name] = { value = newValue } 
	else
		setting[name] = newValue
	end
end

function player:droprange()
	return math.min(self.reach_distance * config.rangeMultiplier, self:setting("cleanupDropRange"))
end

function player:trashItems()
	local cleanupRequestOverflow = self:setting("cleanupRequestOverflow")
	local defaultTrash           = storage.defaultTrash
	local trash                  = self:contents("character_trash")
	local logisticSlots          = self:has("valid", "character") and _(self.character):logisticSlots() or {}

	for item,count in pairs(self:contents()) do

		local targetAmount = count
		local slot = logisticSlots[item]

		if not slot then -- default if no logistic slot with this item
			targetAmount = defaultTrash[item]

		elseif cleanupRequestOverflow and slot.count > 0 then -- request overflow
			targetAmount = slot.count

		elseif slot.max_count ~= nil then -- max value set to infinity = no autotrash
			targetAmount = slot.max_count
		end

		if targetAmount ~= nil then
			local surplus = count - targetAmount
			if surplus > 0 then trash[item] = (trash[item] or 0) + surplus end
		end
	end
	
	return trash
end

function player:playeritemcount(item, includeInv, includeCar, quality)
	quality = quality or "normal"
	local count = 0
	
	local cursor_stack = self.cursor_stack
	if self:stackMatches(cursor_stack, item, quality) then
		count = count + cursor_stack.count
	elseif not includeInv and not includeCar then
		return storage.cache[self.index].cursorStackCount or 0
	end

	if includeInv then
		local mainInv = self:inventory(); 
		if _(mainInv):is("valid") then count = count + mainInv.get_item_count{ name = item, quality = quality } end
	end

	if includeCar and self.driving and self:has("valid", "vehicle") then
		local vehicleInv = _(self.vehicle):inventory("car_trunk")
		if _(vehicleInv):is("valid") then count = count + vehicleInv.get_item_count{ name = item, quality = quality } end
	end
		   
	return count
end

function player:playercontents()
	local contents     = self:contents("main")
	local cursor_stack = self.cursor_stack
	
	if cursor_stack and cursor_stack.valid_for_read and cursor_stack.quality.name == "normal" then
		local item = cursor_stack.name
		contents[item] = (contents[item] or 0) + cursor_stack.count
	end
		   
	return contents
end

function player:removeItems(item, amount, takeFromInv, takeFromCar, takeFromTrash, quality)
	quality = quality or "normal"
	local removed = 0
	if takeFromTrash then
		local trash = self:inventory("character_trash")
		if _(trash):is("valid") then
			removed = transfers.removeFromInventory(trash, item, amount, quality)
			if amount <= removed then return removed end
		end
	end	

	if takeFromInv then
		local main = self:inventory()
		if _(main):is("valid") then
			removed = removed + transfers.removeFromInventory(main, item, amount - removed, quality)
			if amount <= removed then return removed end
		end
	end
	
	local cursor_stack = self.cursor_stack
	if self:stackMatches(cursor_stack, item, quality) then
		local result = math.min(cursor_stack.count, amount - removed)
		transfers.recordStack(cursor_stack, result)
		removed = removed + result
		cursor_stack.count = cursor_stack.count - result
		if amount <= removed then return removed end
	elseif not takeFromInv and not takeFromCar and not takeFromTrash then
		local main = self:inventory()
		if _(main):is("valid") then
			return removed + transfers.removeFromInventory(main, item, amount - removed, quality)
		end
	end
	
	if takeFromCar and self.driving and self:has("valid", "vehicle") then
		local vehicleInv = _(self.vehicle):inventory("car_trunk")
		if _(vehicleInv):is("valid") then removed = removed + transfers.removeFromInventory(vehicleInv, item, amount - removed, quality) end
	end
	
	return removed
end

function player:returnItems(item, amount, takenFromCar, takenFromTrash, quality)
	quality = quality or "normal"
	local remaining = amount - transfers.insert(self, item, amount, quality)
	
	if remaining > 0 and takenFromCar and self.driving and self:has("valid", "vehicle") then
        local vehicleInv = _(self.vehicle):inventory("car_trunk")
        if _(vehicleInv):is("valid") then remaining = remaining - transfers.insert(vehicleInv, item, remaining, quality) end
	end
	
	if remaining > 0 and takenFromTrash then
        local trash = self:inventory("character_trash")
        if _(trash):is("valid") then remaining = remaining - transfers.insert(trash, item, remaining, quality) end
	end
	
	if remaining > 0 then
		self.print({"cant-clear-cursor", {"item-name."..item}})
		transfers.spill(self.surface, {
			position = self.position, 
			enable_looted = false,
			allow_belts = false
		}, item, remaining, quality)
	end
end

function player:itemLimit(prototype, profile)
	if profile then
		local limit = self:setting(profile.valueSetting)
		local type = self:setting(profile.typeSetting)

		if type == "items" then
			return math.ceil(limit)
		elseif type == "stacks" then
			return math.ceil(limit * (prototype.stack_size or 1))
		elseif type == "mj" then
			return math.ceil((limit * 1000000) / (prototype.fuel_value or 1))
		end
	end

	return math.huge
end
