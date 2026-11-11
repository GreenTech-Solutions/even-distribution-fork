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

local function collectDumpOffers(contents, trash, requests, anyQualityRequests, defaultTrash, useMinimum, dumpAmmo)
    local requestedAmmo = {}
    if not dumpAmmo then
        for item in pairs(trash) do
            if prototypes.item[item].type == "ammo" then trash[item] = nil end
        end
    end
    for item, count in pairs(contents) do
        local isAmmo = prototypes.item[item].type == "ammo"
        if dumpAmmo or not isAmmo then
            local targetAmount = count
            local slot = requests[item] or anyQualityRequests[item]
            if not slot then
                targetAmount = defaultTrash[item]
            elseif useMinimum and slot.count > 0 then
                targetAmount = slot.count
            elseif slot.max_count ~= nil then
                targetAmount = slot.max_count
            end
            if slot and isAmmo and item ~= "atomic-bomb" and (targetAmount == nil or targetAmount > 0) then
                requestedAmmo[item] = true
            end
            if targetAmount ~= nil and count > targetAmount then
                trash[item] = (trash[item] or 0) + count - targetAmount
            end
        end
    end
    return trash, requestedAmmo
end

function player:dumpOffers()
    local byQuality = self:setting("cleanupHigherQuality") == true
    local useMinimum = self:setting("cleanupRequestOverflow")
    local dumpAmmo = self:setting("cleanupDumpAmmo") ~= false
    local contents = self:contents(nil, byQuality)
    local trash = self:contents("character_trash", byQuality)
    local requests = self:has("valid", "character") and _(self.character):logisticSlots(byQuality) or {}
    if not byQuality then
        contents, trash, requests = {normal = contents}, {normal = trash}, {normal = requests}
    end

    local offers = {}
    local anyQualityRequests = requests.any or {}
    for quality in pairs(contents) do
        trash[quality] = trash[quality] or {}
    end
    for quality, trashItems in pairs(trash) do
        local items, requestedAmmo = collectDumpOffers(contents[quality] or {}, trashItems, requests[quality] or {},
            anyQualityRequests, storage.defaultTrash, useMinimum, dumpAmmo)
        if next(items) or next(requestedAmmo) then
            offers[#offers + 1] = {quality = quality, items = items, requestedAmmo = requestedAmmo}
        end
    end
    if #offers > 1 then
        table.sort(offers, function(a, b)
            local levelA, levelB = prototypes.quality[a.quality].level, prototypes.quality[b.quality].level
            if levelA ~= levelB then return levelA < levelB end
            return a.quality < b.quality
        end)
    end
    return offers
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

function player:playercontents(byQuality)
    local contents = self:contents("main", byQuality)
    local cursor = self.cursor_stack
    if cursor and cursor.valid_for_read then
        local item, quality = cursor.name, cursor.quality.name
        if byQuality then
            contents[quality] = contents[quality] or {}
            local items = contents[quality]
            items[item] = (items[item] or 0) + cursor.count
        elseif quality == "normal" then
            contents[item] = (contents[item] or 0) + cursor.count
        end
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
