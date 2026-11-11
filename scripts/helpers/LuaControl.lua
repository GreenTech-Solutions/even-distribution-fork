local transfers = require("scripts.transfers")
local fuel = require("scripts.fuel")
local config = require("config")
local control = scripts.helpers
local _ = scripts.helpers.on

-- Helper functions for LuaControl --

function control:request(item, quality)
	quality = quality or "normal" -- fetch specific item request
	local count = 0
	local logisticPoint = _(self:requesterPoint())
    
    if logisticPoint:is("valid") then
        local filters = logisticPoint.filters

        if filters then
            _(filters):each(function(__, filter)
                if filter and filter.name == item and filter.count > count and (filter.quality or "normal") == quality then 
                    count = math.max(count, filter.count)
                end
            end)
        end
    end
	
	return count
end

function control:requesterPoint()
    if self.is_player() and _(self.character):is("valid") then
        return self.character.get_requester_point()
    elseif self.is_player() and _(self.cutscene_character):is("valid") then
        return self.cutscene_character.get_requester_point()
    else
        return self.get_requester_point()
    end
end

function control:logisticSlots(byQuality)
	local logisticSlots = {}
	local logisticPoint = _(self:requesterPoint())

    if logisticPoint:is("valid") then
        local filters = logisticPoint.filters

        if filters then
            _(filters):each(function(__, filter)
                if not filter or not filter.name then return end
                local quality = filter.quality or (byQuality and "any" or "normal")
                if byQuality then
                    logisticSlots[quality] = logisticSlots[quality] or {}
                    logisticSlots[quality][filter.name] = filter
                elseif quality == "normal" then
                    logisticSlots[filter.name] = filter
                end
            end)
        end
    end
	
	return logisticSlots
end

function control:stackMatches(stack, item, quality)
    return stack and stack.valid_for_read and stack.name == item and stack.quality.name == (quality or "normal")
end

function control:itemcount(item, includeInv, includeCar, quality)
    if self.is_player() then
        return self:playeritemcount(item, includeInv, includeCar, quality)
    else
        return self.get_item_count{ name = item, quality = quality or "normal" }
    end
end

function control:remainingRequest(item, quality)
	return self:request(item, quality) - self:itemcount(item, nil, nil, quality)
end

function control:inventory(name)
    if name == nil or name == "main" then -- get main inventory
        return self.get_main_inventory() or
               (self.type == "container" and self.get_inventory(defines.inventory.chest)) or
               (self.type == "logistic-container" and self.get_inventory(defines.inventory.chest)) or
               (self.type == "car" and self.get_inventory(defines.inventory.car_trunk)) or
               (self.type == "spider-vehicle" and self.get_inventory(defines.inventory.car_trunk)) or
               (self.type == "cargo-wagon" and self.get_inventory(defines.inventory.cargo_wagon)) or
               (self.type == "rocket-silo" and self.get_inventory(defines.inventory.rocket_silo_rocket))

    elseif name == "input" then
        return (self.type == "furnace" and self.get_inventory(defines.inventory.crafter_input)) or
               (self.type == "assembling-machine" and self.get_inventory(defines.inventory.crafter_input)) or
               (self.type == "lab" and self.get_inventory(defines.inventory.lab_input)) or
               (self.type == "rocket-silo" and self.get_inventory(defines.inventory.crafter_input))
    
    elseif name == "output" then
        return self.get_output_inventory()
    
    elseif name == "modules" then
        return self.get_module_inventory()
    
    elseif name == "ammo" then
        return (self.type == "ammo-turret" and self.get_inventory(defines.inventory.turret_ammo)) or
               (self.type == "car" and self.get_inventory(defines.inventory.car_ammo)) or
               (self.type == "spider-vehicle" and self.get_inventory(defines.inventory.car_ammo)) or
               (self.type == "artillery-wagon" and self.get_inventory(defines.inventory.artillery_wagon_ammo)) or
               (self.type == "artillery-turret" and self.get_inventory(defines.inventory.artillery_turret_ammo)) or
               (self.type == "character" and self.get_inventory(defines.inventory.character_ammo)) or
               (self.type == "character" and self.get_inventory(defines.inventory.editor_ammo))
    
    elseif name == "fuel" then
        return self.get_fuel_inventory()
    
    elseif name == "burnt_result" then
        return self.get_burnt_result_inventory()
    end
    
    -- get specific inventory
    return self.get_inventory(defines.inventory[name])
end

function control:contents(name, byQuality)
    if name == nil and self.is_player() then 
        return self:playercontents(byQuality)
    end

    local inv = self:inventory(name)
    if _(inv):isnot("valid") then return {} end

    local contents = inv.get_contents()
    local contents_converted = {}
    for __, content in pairs(contents) do
        if byQuality then
            local quality = content.quality
            contents_converted[quality] = contents_converted[quality] or {}
            contents_converted[quality][content.name] = content.count
        elseif content.quality == "normal" then
            contents_converted[content.name] = content.count
        end
    end
    return contents_converted
end

local function insert(self, name, item, amount, quality)
    if amount <= 0 then return 0 end
    local inv = self:inventory(name)
    if inv then
        -- inv.sort_and_merge()
        local inserted = transfers.insert(inv, item, amount, quality)
        if inserted < amount then  -- retry for things like furnace ingredients (can be overfilled)
            inserted = inserted + transfers.insert(inv, item, amount - inserted, quality)
        end

        return inserted
    end
    return 0
end

-- priority insert with fuel and ammo limits
function control:customInsert(player, item, amount, takenFromCar, takenFromTrash, replaceItems, useFuelLimit, useAmmoLimit, useRequestLimit, allowed, quality)
    quality = quality or "normal"
    if amount <= 0 then return 0 end

    local inserted = 0
    local prototype = _(prototypes.item[item])

    -- allow/disallow insertion into specific inventories by passing table with true/false values (default is allow)
    allowed = _({
        fuel     = true, -- set default values
        ammo     = true,
        input    = true,
        output   = true,
        modules  = true,
        roboport = true,
        main     = true,
    }):set(allowed or {}):toPlain()
    
    if allowed.fuel and prototype:is("fuel") then
        local inv = self:inventory("fuel")
        if inv and fuel.accepts(self.burner, prototype) then
            local limit = useFuelLimit and math.min(amount, math.max(0, player:itemLimit(prototype, config.fuelLimitProfiles) - inv.get_item_count{ name = item, quality = quality })) or amount

            local insertedHere = insert(self, "fuel", item, limit, quality)
            limit = limit - insertedHere

            -- no space left --> replace inferior items
            if replaceItems and limit > 0 then
                for __,inferiorFuel in pairs(fuel.replacements(prototype, storage.fuelList)) do
                    if inferiorFuel.name == prototype.name or limit <= 0 then break end

                    local returnToPlayer = 0
                    while limit > 0 do
                        local stack = inv.find_item_stack{ name = inferiorFuel.name, quality = quality }
                        if transfers.batchActive() then
                            local n = transfers.replace(player, stack, item, limit, quality, takenFromCar, takenFromTrash)
                            if n <= 0 then break end
                            limit = limit - n
                            insertedHere = insertedHere + n
                        else
                            local returnCount = stack and stack.count or 0
                            local oldSpoil = stack and transfers.peek(stack)
                            if transfers.setStack(stack, item, limit, quality) then
                                transfers.record(oldSpoil, returnCount)
                                limit = limit - stack.count
                                insertedHere = insertedHere + stack.count
                                returnToPlayer = returnToPlayer + returnCount
                            else
                                break
                            end
                        end
                    end

                    if returnToPlayer > 0 then
                        player:returnItems(inferiorFuel.name, returnToPlayer, takenFromCar, takenFromTrash, quality)
                    end
                end
            end

            inserted = inserted + insertedHere
            amount = amount - insertedHere
        end
    end

    if amount <= 0 then return inserted end
	if allowed.ammo and prototype:is("ammo") then
        local inv = self:inventory("ammo")
        if inv then
            local limit = useAmmoLimit and math.min(amount, math.max(0, player:itemLimit(prototype, config.ammoLimitProfiles) - inv.get_item_count{ name = item, quality = quality })) or amount

            local insertedHere = insert(self, "ammo", item, limit, quality)
            limit = limit - insertedHere

            -- no space left --> replace inferior items
            if replaceItems and limit > 0 then
                for __,inferiorAmmo in pairs(storage.ammoList[prototype.ammo_category.name]) do
                    if inferiorAmmo.name == prototype.name or limit <= 0 then break end

                    local returnToPlayer = 0
                    while limit > 0 do
                        local stack = inv.find_item_stack{ name = inferiorAmmo.name, quality = quality }
                        if transfers.batchActive() then
                            local n = transfers.replace(player, stack, item, limit, quality, takenFromCar, takenFromTrash)
                            if n <= 0 then break end
                            limit = limit - n
                            insertedHere = insertedHere + n
                        else
                            local returnCount = stack and stack.count or 0
                            local oldSpoil = stack and transfers.peek(stack)
                            if transfers.setStack(stack, item, limit, quality) then
                                transfers.record(oldSpoil, returnCount)
                                limit = limit - stack.count
                                insertedHere = insertedHere + stack.count
                                returnToPlayer = returnToPlayer + returnCount
                            else
                                break
                            end
                        end
                    end
                    
                    if returnToPlayer > 0 then
                        player:returnItems(inferiorAmmo.name, returnToPlayer, takenFromCar, takenFromTrash, quality)
                    end
                end
            end

            inserted = inserted + insertedHere
            amount = amount - insertedHere
        end
    end
    
    if amount <= 0 then return inserted end
    if allowed.input then
        local insertedHere = insert(self, "input", item, amount, quality)
        inserted = inserted + insertedHere
        amount = amount - insertedHere
        if insertedHere > 0 then allowed.main = false end
	end
    
    if amount <= 0 then return inserted end
    if allowed.output and self:recipe():hasProduct(item) then
        local insertedHere = insert(self, "output", item, amount, quality)
        inserted = inserted + insertedHere
        amount = amount - insertedHere
	end

    if amount <= 0 then return inserted end
    if allowed.modules then
        local insertedHere = insert(self, "modules", item, amount, quality)
        inserted = inserted + insertedHere
        amount = amount - insertedHere
        if insertedHere > 0 then allowed.main = false end
    end

    if allowed.roboport and self.type == "roboport" then
        if amount <= 0 then return inserted end
        local insertedHere = insert(self, "roboport_robot", item, amount, quality)
        inserted = inserted + insertedHere
        amount = amount - insertedHere

        if amount <= 0 then return inserted end
        insertedHere = insert(self, "roboport_material", item, amount, quality)
        inserted = inserted + insertedHere
        amount = amount - insertedHere
    end
    
    if amount <= 0 then return inserted end
    if allowed.main then
        local limit = useRequestLimit and math.min(amount, math.max(0, self:remainingRequest(item, quality))) or amount
        local insertedHere = insert(self, "main", item, limit, quality)
        
        inserted = inserted + insertedHere
        amount = amount - insertedHere
	end

    return inserted
end
