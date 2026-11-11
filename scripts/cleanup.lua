local distribution = require("scripts.batch-distribution")
local fuel = require("scripts.fuel")
local ammoPolicy = require("scripts.ammo-policy")
-- Inventory Cleanup Hotkey

local this = {}
local drag = scripts.drag
local util = scripts.util
local metatables = scripts.metatables
local config = require("config")

local helpers = scripts.helpers
local _ = helpers.on

local function cleanupPort(entity)
    if entity.name == "recycler" then return "input" end
    if entity.name == "heating-tower" then return "fuel" end
end

local function blockedCleanupTarget(entity, item, prechecked)
    if item == "atomic-bomb" and entity.type:find("turret", 1, true) ~= nil then return true end
    -- Heating towers share the reactor type, but use the seeded-fuel rule.
    local port = cleanupPort(entity)
    if port then
        if prechecked then return false end
        local inventory = entity:inventory(port)
        return not inventory or inventory.is_empty()
    end
    return entity.type == "reactor" or entity.type == "fusion-reactor"
end

local function ammoSlotTargets(entities, item)
    local targets = metatables.new("entityAsIndex")
    local prototype = prototypes.item[item]
    for _index, entity in ipairs(entities) do
        entity = _(entity)
        local inventory = entity:inventory("ammo")
        if inventory and (entity.type == "car" or entity.type == "spider-vehicle" or entity:supportsAmmo(prototype))
            and inventory.can_insert({name = item, quality = "normal", count = 1}) then
            targets[entity] = entity
        end
    end
    return targets
end

local function dumpBatches(player, entities, items, dropToChests, dropToOutput, balance, requestedAmmo)
    local offY, marked = 0, metatables.new("entityAsIndex")
    for item in pairs(requestedAmmo or {}) do
        items[item] = items[item] or 0
    end
    for _index, offer in ipairs(ammoPolicy.orderedItems(items)) do
        local item = offer.item
        local function feedback(entity, inserted)
            if inserted ~= 0 then
                entity:spawnDistributionText(player, item, inserted, offY)
                if not marked[entity] then entity:mark(player); marked[entity] = true end
            end
        end
        local function insert(entity, amount, port)
            -- Eligibility was checked before balancing could debit seed items.
            return this.insert(player, entity, item, amount, port, true)
        end
        local refillRequestedAmmo = requestedAmmo and requestedAmmo[item]
        local personalAmmoMaximum
        local startingPersonalStock
        if refillRequestedAmmo and offer.maximum > 0 then
            personalAmmoMaximum = ammoPolicy.personalAllowance(player, item, "normal")
            if personalAmmoMaximum < math.huge then
                startingPersonalStock = player:playeritemcount(item, true, false, "normal")
            end
        end
        if offer.maximum > 0 then
            local targets = this.filterEntities(entities, item, dropToChests, dropToOutput, balance)
            distribution.apply(player, targets, item, "normal", {
                inventory = true, trash = true, balance = balance, maximum = offer.maximum,
                targetPort = cleanupPort, profile = "cleanup",
            }, insert, feedback)
        end
        if refillRequestedAmmo then
            if startingPersonalStock then
                local used = math.max(0, startingPersonalStock - player:playeritemcount(item, true, false, "normal"))
                personalAmmoMaximum = math.max(0, personalAmmoMaximum - used)
            end
            local targets = ammoSlotTargets(entities, item)
            if not _(targets):is("empty") then
                -- The batch planner applies the equipped-ammo reserve to the
                -- live inventory again after the request-limited pass.
                distribution.apply(player, targets, item, "normal", {
                    inventory = true, balance = balance, targetPort = function() return "ammo" end,
                    profile = "cleanup", personalAmmoMaximum = personalAmmoMaximum,
                }, insert, feedback)
            end
        end
        offY = offY - 0.5
    end
end

function this.on_inventory_cleanup(event)
    local player = _(game.players[event.player_index])
    if player:isnot("valid player") or not player:setting("enableInventoryCleanupHotkey") then return end

    local items, requestedAmmo = player:trashItems()
    if next(items) == nil and next(requestedAmmo) == nil then return end
    local area = _(player.position):perimeter(player:droprange())
    local entities = this.getEntities(area, player)
    if #entities == 0 then return end

    local dropToChests = player:setting("dropTrashToChests")
    local dropToOutput = player:setting("dropTrashToOutput")
    local balance = player:setting("distributionMode") ~= "distribute"
    dumpBatches(player, entities, items, dropToChests, dropToOutput, balance, requestedAmmo)
end

function this.distributeItems(player, entities, items, dropToChests, dropToOutput)
    dumpBatches(player, entities, items, dropToChests, dropToOutput, false)
end
function this.balanceItems(player, entities, items, dropToChests, dropToOutput)
    dumpBatches(player, entities, items, dropToChests, dropToOutput, true)
end

function this.insert(player, entity, item, amount, port, prechecked)
    if blockedCleanupTarget(entity, item, prechecked) then return 0 end

	local useFuelLimit = player:setting("cleanupUseFuelLimit")
	local useAmmoLimit = player:setting("cleanupUseAmmoLimit")
	local dropToOutput = player:setting("dropTrashToOutput")

    port = port or cleanupPort(entity)
    if port then
        return entity:customInsert(player, item, amount, false, true, false, useFuelLimit, useAmmoLimit, false,
            distribution.portMask(port))
    end

	if entity.type == "furnace" and entity:recipe():isnot("valid") then
		return entity:customInsert(player, item, amount, false, true, false, useFuelLimit, useAmmoLimit, false, {
			fuel     = true,
			ammo     = false,
			input    = false,
			output   = false,
			modules  = false,
			roboport = false,
			main     = false,
		})

	elseif entity:is("crafting machine") then
		return entity:customInsert(player, item, amount, false, true, false, useFuelLimit, useAmmoLimit, false, {
			fuel     = true,
			ammo     = false,
			input    = entity:recipe():hasIngredient(item),
			output   = dropToOutput and entity.type ~= "rocket-silo" and entity:recipe():hasProduct(item),
			modules  = false,
			roboport = false,
			main     = false,
		})

	elseif entity.prototype.logistic_mode == "requester" then
		return entity:customInsert(player, item, amount, false, true, false, useFuelLimit, useAmmoLimit, true, {
			fuel     = false,
			ammo     = false,
			input    = false,
			output   = false,
			modules  = false,
			roboport = false,
			main     = true,
		})

	elseif entity.type == "spider-vehicle" and entity.get_logistic_point(defines.logistic_member_index.character_requester) then
		return entity:customInsert(player, item, amount, false, true, false, useFuelLimit, useAmmoLimit, true, {
			fuel     = true,
			ammo     = true,
			input    = false,
			output   = false,
			modules  = false,
			roboport = false,
			main     = true,
		})
		
	elseif entity.type == "car" or entity.type == "spider-vehicle" then
		return entity:customInsert(player, item, amount, false, true, false, useFuelLimit, useAmmoLimit, false, {
			fuel     = true,
			ammo     = true,
			input    = false,
			output   = false,
			modules  = false,
			roboport = false,
			main     = false,
		})
	end
	
	-- Default priority insertion
	return entity:customInsert(player, item, amount, false, true, false, useFuelLimit, useAmmoLimit, false, {
		fuel     = true,
		ammo     = true,
		input    = true,
		output   = false,
		modules  = false,
		roboport = true,
		main     = true,
	}) 
end

function this.filterEntities(entities, item, dropToChests, dropToOutput, balance)
	local result = metatables.new("entityAsIndex")
	local prototype = prototypes.item[item]
	
	_(entities):each(function(__, entity)
		entity = _(entity)
        if blockedCleanupTarget(entity, item) then return end

        -- Preserve the original Cleanup eligibility rule. A full container
        -- is not silently added as a balancing source by the Space Age layer.
		if entity.can_insert(item) then
			if fuel.accepts(entity.burner, prototype) and entity:inventory("fuel").can_insert(item) then
				result[entity] = entity
			elseif entity.name == "recycler" or (entity:is("crafting machine") and entity:recipe():hasIngredient(item)) then
				result[entity] = entity
			elseif (entity.prototype.logistic_mode == "requester" or (entity.type == "spider-vehicle" and entity.get_logistic_point(defines.logistic_member_index.character_requester))) and entity:remainingRequest(item) > 0 then
				result[entity] = entity
			elseif dropToChests and (entity.type == "container" or entity.type == "logistic-container") and entity:itemcount(item) > 0 then
				result[entity] = entity
			elseif entity.type == "lab" and entity:inventory("lab_input").can_insert(item) then
				result[entity] = entity
			elseif (entity.type == "ammo-turret" or entity.type == "artillery-turret" or entity.type == "artillery-wagon") and entity:supportsAmmo(prototype) then
				result[entity] = entity
			elseif entity.type == "roboport" then
				result[entity] = entity
			elseif (entity.type == "car" or entity.type == "spider-vehicle") and prototype.type == "ammo" then
				result[entity] = entity
			end
		end
		
		if not result[entity] and dropToOutput and (entity.type == "furnace" or entity.type == "assembling-machine") and entity:recipe():hasProduct(item) then
			result[entity] = entity
		end
	end)
	
	return result
end

function this.getEntities(area, player)
	local entities = {}

	for __,entity in ipairs(player.surface.find_entities_filtered{ area = area, force = player.force }) do

		if _(entity):is("valid") and 
		   entity.operable and 
		   not entity.to_be_deconstructed(player.force) and 
		   not _(entity):isIgnored(player) then
			
			entities[#entities + 1] = entity
		end
	end
	
	return entities
end



return this
