local fuel = require("scripts.fuel")
local batches = require("scripts.batches")
local distribution = require("scripts.batch-distribution")
local this = {}
local util = scripts.util
local visuals = scripts.visuals
local metatables = scripts.metatables
local config = require("config")

local helpers = scripts.helpers
local _ = helpers.on

function this.on_tick(event) -- handles distribution events
    -- Visit only snapshots due now; idle players need no per-tick scan.
    local expirations = storage.hoverExpirations or {}
    local due = expirations[event.tick]
    if due then
        for _, cache in pairs(due) do
            if cache.selectedEvent and cache.selectedEvent.tick < event.tick then
                batches.discard(cache.selectedEvent.snapshot)
                cache.selectedEvent = nil
                cache.snapshotExpiry, cache.snapshotPlayer = nil, nil
            end
        end
        expirations[event.tick] = nil
    end
	local distrEvents = storage.distrEvents

	if distrEvents[event.tick] then
		for player_index, cache in pairs(distrEvents[event.tick]) do
			local player = _(game.players[player_index])
	
			if player:is("valid player") then
				if player:setting("distributionMode") == "distribute" then
					this.distributeItems(player, cache)
				else
					this.balanceItems(player, cache)
				end
			end

			this.resetCache(cache)
		end

		distrEvents[event.tick] = nil
	end
end

local function distribute(player, cache, balance)
    local item, quality = cache.item, cache.quality or "normal"
    local takeCar = player:setting("takeFromCar")
    distribution.apply(player, cache.entities, item, quality, {
        inventory = player:setting("takeFromInventory"), car = takeCar,
        balance = balance, half = cache.half,
        -- Original drag Even Distribute offers one equal share per entity.
        -- Rejected shares stay with the player; only Cleanup retries them.
        retryFull = false,
        profile = "drag", quality = quality,
    }, function(entity, amount, port)
        return entity:customInsert(player, item, amount, takeCar, false,
            player:setting("replaceItems"), player:setting("dragUseFuelLimit"),
            player:setting("dragUseAmmoLimit"), false, port and distribution.portMask(port) or {output = false}, quality)
    end, function(entity, inserted, full)
        entity:spawnDistributionText(player, item, inserted, 0,
            full and config.colors.targetFull or (inserted == 0 and config.colors.insufficientItems or config.colors.default))
    end)
end

function this.distributeItems(player, cache) distribute(player, cache, false) end
function this.balanceItems(player, cache) distribute(player, cache, true) end

function this.on_fast_entity_transfer_hook(event)
	local index        = event.player_index
	local player       = _(game.players[index]); if player:isnot("valid player") then return end
	local cache        = _(storage.cache[index])
	cache.half = false
end

function this.on_fast_entity_split_hook(event)
	local index        = event.player_index
	local player       = _(game.players[index]); if player:isnot("valid player") then return end
	local cache        = _(storage.cache[index])
	cache.half = true
end

function this.on_selected_entity_changed(event)
    local index = event.player_index
    local player = _(game.players[index]); if player:isnot("valid player") or not player:setting("enableDragDistribute") then return end
    local cache = _(storage.cache[index])
    local previous = cache.selectedEvent
    this.unscheduleSnapshot(cache)
    cache.selectedEvent = nil
    local cursor_stack = _(player.cursor_stack)
    local selected = _(player.selected)
    if cursor_stack:isnot("valid stack") or selected:isnot("valid") or selected:isIgnored(player) then
        batches.discard(previous and previous.snapshot)
        return
    end
    local item, quality = cursor_stack.name, cursor_stack.quality.name
    if cache.item and (cache.item ~= item or (cache.quality or "normal") ~= quality) then
        this.finishPending(player, cache)
    end
    cache.selectedEvent = {
        tick = event.tick,
        item = item,
        quality = quality,
        itemCount = selected:itemcount(item, nil, nil, quality),
        cursorStackCount = cursor_stack.count,
        snapshot = batches.snapshot(selected, cursor_stack, item, quality, player, previous and previous.snapshot),
    }
    storage.hoverExpirations = storage.hoverExpirations or {}
    local expires = event.tick + 1
    storage.hoverExpirations[expires] = storage.hoverExpirations[expires] or {}
    storage.hoverExpirations[expires][index] = cache:toPlain()
    cache.snapshotExpiry = expires
    cache.snapshotPlayer = index
end

function this.unscheduleSnapshot(cache)
    local expires = cache.snapshotExpiry
    local due = expires and storage.hoverExpirations and storage.hoverExpirations[expires]
    if due then
        due[cache.snapshotPlayer] = nil
        if not next(due) then storage.hoverExpirations[expires] = nil end
    end
    cache.snapshotExpiry, cache.snapshotPlayer = nil, nil
end

function this.on_player_fast_transferred(event)
	local index    = event.player_index
	local player   = _(game.players[index]); if player:isnot("valid player") or not player:setting("enableDragDistribute") then return end
	local cache    = _(storage.cache[index])
	local selected = _(player.selected)    ; if selected:isnot("valid") or selected:isIgnored(player) then return end

	if cache.selectedEvent and cache.selectedEvent.tick == event.tick and event.entity == selected:toPlain() then

		if event.from_player then
			-- distribute...

			if cache.selectedEvent.item then
                local selectedEvent = cache.selectedEvent
                if cache.item and (cache.item ~= selectedEvent.item or (cache.quality or "normal") ~= (selectedEvent.quality or "normal")) then
                    this.finishPending(player, cache)
                end
                cache:set{
					item             = selectedEvent.item,
                    quality          = selectedEvent.quality or "normal",
					itemCount        = selected:itemcount(selectedEvent.item, nil, nil, selectedEvent.quality) - selectedEvent.itemCount,
					cursorStackCount = selectedEvent.cursorStackCount,
				}

				this.onStackTransferred(selected, player, cache) -- handle stack transfer
			end
		else
			-- take...
		end
	end
end

function this.onStackTransferred(entity, player, cache) -- handle vanilla drag stack transfer
	local takeFromInv      = player:setting("takeFromInventory")
	local takeFromCar      = player:setting("takeFromCar")
	local distributionMode = player:setting("distributionMode")
	local item = cache.item
	local quality = cache.quality or "normal"
	local first = #cache.entities > 0 and util.epairs(cache.entities)() or nil

	if _(entity):is("valid") and not _(entity):isIgnored(player) and this.isEntityEligible(entity, item, quality) and 
	   (_(first):isnot("valid") or ((first.type == "car" or  first.type == "spider-vehicle") and (entity.type == "car" or  entity.type == "spider-vehicle"))
	   				 		    or ((first.type ~= "car" and first.type ~= "spider-vehicle") and (entity.type ~= "car" and entity.type ~= "spider-vehicle"))) then
	
		local distrEvents = storage.distrEvents -- register new distribution event
		if cache.applyTick and distrEvents[cache.applyTick] then distrEvents[cache.applyTick][player.index] = nil end
		
		-- wait before applying distribution (seconds defined in mod config)
		cache.applyTick = game.tick + math.max(math.ceil(60 * _(player):setting("distributionDelay")), 1)
		
		distrEvents[cache.applyTick] = distrEvents[cache.applyTick] or {}
		distrEvents[cache.applyTick][player.index] = cache

		if not cache.entities[entity] then
			cache.markers[entity] = entity:mark(player, item)
			cache.entities[entity] = entity
		end

		if cache.itemCount == 0 then
			player.play_sound{ path = "utility/inventory_move" }
		end
	end

    -- Undo only the provisional native transfer. Actual movement happens once,
    -- over the entire selected group, after locking its consumption bracket.
    batches.undo(cache.selectedEvent and cache.selectedEvent.snapshot)
    if cache.selectedEvent then cache.selectedEvent.snapshot = nil end

    local batch, targets = distribution.plan(player, cache.entities, item, quality, {
        inventory = takeFromInv, car = takeFromCar,
        balance = distributionMode == "balance", half = cache.half,
    })
    distribution.preview(batch, targets, function(target, amount)
        visuals.update(cache.markers[target], item, amount)
    end)

	player.clear_local_flying_texts()
end

function this.isEntityEligible(entity, item, quality)
	quality = quality or "normal"
	local prototype = prototypes.item[item]
	entity = _(entity)
	
	if entity.can_insert{ name = item, quality = quality } then
		return true
	elseif fuel.accepts(entity.burner, prototype) then
		return true
	elseif entity:is("crafting machine") and entity:recipe():hasIngredient(item) then
		return true
	elseif entity.type == "furnace" and not entity.get_recipe() and entity:canSmelt(item) then
		return true
	elseif entity.type == "rocket-silo" then
		return true
	elseif entity.type == "lab" and entity:inventory("lab_input").can_insert{ name = item, quality = quality } then
		return true
	elseif (entity.type == "ammo-turret" or entity.type == "artillery-turret" or entity.type == "artillery-wagon") and entity:supportsAmmo(prototype) then
		return true
	elseif entity.type == "roboport" and (prototype.type == "repair-tool" or (prototype.place_result and prototype.place_result.max_payload_size ~= nil)) then
		return true
	elseif entity.prototype.module_inventory_size and entity.prototype.module_inventory_size > 0 and prototype.type == "module" then
		return true
	elseif entity:inventory("main") then
		return true
	end
	
	return false
end

function this.finishPending(player, cache)
    if not cache.item then return end
    if cache.applyTick and storage.distrEvents[cache.applyTick] then
        storage.distrEvents[cache.applyTick][player.index] = nil
    end
    if player:setting("distributionMode") == "balance" then
        this.balanceItems(player, cache)
    else
        this.distributeItems(player, cache)
    end
    this.resetCache(cache)
end

function this.resetCache(cache)
    this.unscheduleSnapshot(cache)
    batches.discard(cache.selectedEvent and cache.selectedEvent.snapshot)
	cache.item = nil
	cache.quality = nil
	cache.selectedEvent = nil
	cache.applyTick = nil
	cache.cursorStackCount = nil
	cache.itemCount = nil
	cache.half = false
	cache.entities = metatables.new("entityAsIndex")
	visuals.unmark(cache)
end

function this.on_pre_player_mined_item(event) -- remove mined/dead entities from cache
	local entity = event.entity
	
	for __,cache in pairs(storage.cache) do
		if cache.entities[entity] then
			_(cache.markers[entity]):unmark() -- remove markers
			cache.markers[entity] = nil
			cache.entities[entity] = nil
		end
	end
end

this.on_robot_pre_mined = this.on_pre_player_mined_item
this.on_entity_died = this.on_pre_player_mined_item

function this.script_raised_destroy(event)
	event = event or {}
	event.entity = event.entity or event.destroyed_entity or event.destroyedEntity or event.target or nil
	
	if _(event.entity):is("valid") then this.on_pre_player_mined_item(event) end
end

function this.on_player_died(event) -- resets distribution cache and events for that player
	local cache = storage.cache[event.player_index]
	
	if cache then
        local applyTick = cache.applyTick
		this.resetCache(cache)
		
		local distrEvents = storage.distrEvents -- remove distribution event
		if applyTick and distrEvents[applyTick] then
			distrEvents[applyTick][event.player_index] = nil
		end
	end
end

this.on_player_left_game = this.on_player_died

return this
