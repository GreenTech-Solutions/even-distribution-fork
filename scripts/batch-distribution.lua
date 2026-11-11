-- Original allocation policy, with a separate Space Age stack adapter:
-- drag offers one equal share; Cleanup retries rejected shares; Balance
-- redistributes leftovers using the original cumulative rounding order.
-- Brackets/quality choose eligible sources, not a different allocation mode.
local batches = require("scripts.batches")
local fuel = require("scripts.fuel")
local ammoPolicy = require("scripts.ammo-policy")
local config = require("config")
local this = {}

local function plain(value)
    return type(value) == "table" and rawget(value, "__on") or value
end

-- Limits belong to the original insertion policy. With sources left in place,
-- count their usable allocation rather than treating excess stock as a credit
-- above a configured fuel/ammo cap. Recipe input remains a separate route.
local function allocationLimit(player, entity, port, item, options)
    if not options.profile then return math.huge end
    if port == "input" then return math.huge end
    if options.profile == "drag" and not port and entity:inventory("main") then return math.huge end
    local prototype = prototypes.item[item]
    local input = entity:inventory("input")
    if not port and input and (input.get_item_count{name=item,quality=options.quality or "normal"}>0
        or (entity:is("crafting machine") and entity:recipe():hasIngredient(item))) then return math.huge end
    if (port == "fuel" or not port) and entity:inventory("fuel") and fuel.accepts(entity.burner, prototype)
        and player:setting(options.profile .. "UseFuelLimit") then
        return player:itemLimit(prototype, config.fuelLimitProfiles)
    end
    if (port == "ammo" or not port) and prototype.type == "ammo" and entity:inventory("ammo")
        and player:setting(options.profile .. "UseAmmoLimit") then
        return player:itemLimit(prototype, config.ammoLimitProfiles)
    end
    return math.huge
end

function this.plan(player, entities, item, quality, options)
    local sources = options.targetsOnly and {} or batches.playerSources(player, options.inventory, options.car, options.trash)
    local ammunition = prototypes.item[item].type == "ammo"
    -- Player stock chooses the next batch. Old items already delivered to the
    -- machines must not keep that bracket selected forever on later gestures.
    local playerBatch = batches.select(sources, item, quality, nil, ammunition)
    local targets, targetsByOwner = {}, {}
    local function addTarget(entity, inventory, port)
        local owner = inventory or plain(entity)
        targets[#targets + 1] = {entity = entity, plain = owner, port = port, current = 0, received = 0,
            capacity = allocationLimit(player, entity, port, item, options)}
        targetsByOwner[owner] = targetsByOwner[owner] or {}
        targetsByOwner[owner][#targetsByOwner[owner] + 1] = targets[#targets]
        if options.balance then
            if inventory then batches.addInventory(sources, inventory, owner)
            else batches.addEntity(sources, entity) end
        end
    end
    for entity in scripts.util.epairs(entities) do
        if entity.valid then
            entity = scripts.helpers.on(entity)
            local port = options.targetPort and options.targetPort(entity)
            if port then
                -- Cleanup may target only a seeded input/fuel inventory. Do not
                -- draw balancing stock from recycler outputs or spent fuel.
                local inventory = entity:inventory(port)
                if inventory then addTarget(entity, inventory, port) end
            else
                local consumesTwice = entity:is("crafting machine") and entity:recipe():hasIngredient(item)
                    and fuel.accepts(entity.burner, prototypes.item[item])
                local fuelInventory = consumesTwice and entity:inventory("fuel")
                local inputInventory = consumesTwice and entity:inventory("input")
                if fuelInventory and inputInventory then
                    -- A fuel that is also a recipe ingredient has two independent
                    -- destinations. Fuel caps apply only to the fuel destination.
                    addTarget(entity, fuelInventory, "fuel")
                    addTarget(entity, inputInventory, "input")
                else addTarget(entity) end
            end
        end
    end
    -- The player bracket selects what is offered, not how the selected mode
    -- works. Balance includes ALL existing target stock of this item/quality;
    -- Even Distribute leaves that stock in place and splits only player stock.
    local includeAll = ammunition or (options.balance and function(owner) return owner ~= plain(player) end)
    local batch = batches.select(sources, item, quality, playerBatch.count > 0 and playerBatch.bracket or nil, includeAll)
    local playerCount, rawPlayerCount = 0, 0
    local personal = ammunition and ammoPolicy.personalAllowance(player, item, quality) or math.huge
    for _, entry in ipairs(batch.entries) do
        if entry.owner == plain(player) then
            rawPlayerCount = rawPlayerCount + entry.limit
            if entry.personal then
                entry.limit = math.min(entry.limit, personal)
                personal = personal - entry.limit
            end
            playerCount = playerCount + entry.limit
        end
    end
    local quota = options.half and math.min(playerCount, math.ceil(rawPlayerCount / 2)) or playerCount
    if options.maximum then quota = math.min(quota, options.maximum) end
    batch.count = 0
    for _, entry in ipairs(batch.entries) do
        if entry.owner == plain(player) then
            entry.limit = math.min(entry.limit, quota)
            quota = quota - entry.limit
        end
        entry.available = entry.limit
        batch.count = batch.count + entry.limit
        for _, target in ipairs(targetsByOwner[entry.owner] or {}) do
            target.current = target.current + entry.limit
        end
    end
    batch.targetsByOwner = targetsByOwner
    return batch, targets
end

function this.portMask(port)
    local allowed = {fuel=false,ammo=false,input=false,output=false,modules=false,roboport=false,main=false}
    allowed[port] = true
    return allowed
end

local function aggregate(targets, value, callback)
    local byEntity, rows = {}, {}
    for _, target in ipairs(targets) do
        local owner = plain(target.entity)
        local row = byEntity[owner]
        if not row then
            row = {entity=target.entity,amount=0};byEntity[owner]=row;rows[#rows+1]=row
        end
        row.amount = row.amount + value(target)
        row.full = row.full or target.full
    end
    for _, row in ipairs(rows) do callback(row.entity, row.amount, row.full) end
end

function this.preview(batch, targets, update)
    if #targets == 0 then return end
    local base, extra = math.floor(batch.count / #targets), batch.count % #targets
    for i, target in ipairs(targets) do target.preview = base + (i <= extra and 1 or 0) end
    aggregate(targets, function(target) return target.preview end, update)
end

local function applyOnce(player, entities, item, quality, options, insert, feedback)
    local batch, targets = this.plan(player, entities, item, quality, options)
    if #targets == 0 or batch.count <= 0 then return end
    local activeTargets = {}
    for _, target in ipairs(targets) do activeTargets[#activeTargets + 1] = target end
    local total = batch.count
    batch.onDebit = function(owner, count)
        for _, target in ipairs(batch.targetsByOwner[owner] or {}) do
            target.current = target.current - count; target.received = target.received - count
        end
    end
    batches.run(batch, batch.count, function()
        local pass = 0
        -- At most one pass per rejected target plus the final successful pass.
        while #activeTargets > 0 do
            pass = pass + 1
            local remaining = options.balance and total or batch.remaining
            if options.balance and pass > 1 then
                -- Original Balance removes the stock once, then distributes
                -- each leftover as an additional share. Do not recompute an
                -- ideal absolute average after a full target: that changes
                -- which entity receives the rounding remainders.
                remaining = batch.count
                for _, target in ipairs(targets) do remaining = remaining - target.allocated end
            end
            if remaining <= 0 then break end
            local base, extra = math.floor(remaining / #activeTargets), remaining % #activeTargets
            local desired, byOwner = {}, {}
            local limited = {}
            for i, target in ipairs(activeTargets) do
                desired[target] = base + (i <= extra and 1 or 0)
                if options.balance and pass > 1 then desired[target] = desired[target] + target.allocated end
                if options.balance and desired[target] > target.capacity then
                    desired[target] = target.capacity
                    limited[target] = true
                end
                byOwner[target.plain] = options.balance and math.max(0, target.current - desired[target]) or 0
            end
            if options.balance then
                for _, entry in ipairs(batch.entries) do
                    if entry.owner == plain(player) then entry.limit = entry.available
                    else
                        local excess = byOwner[entry.owner] or 0
                        entry.limit = math.min(entry.available, excess)
                        byOwner[entry.owner] = excess - entry.limit
                    end
                end
            end
            local rejected = {}
            for _, target in ipairs(activeTargets) do
                local amount = desired[target] - (options.balance and target.current or 0)
                if amount > 0 then
                    batch.destination = target.plain
                    local n = insert(target.entity, amount, target.port)
                    target.current = target.current + n
                    target.received = target.received + n
                    if n < amount then target.full = true; rejected[target] = true end
                end
                -- Virtual allocation follows the original remove-then-insert
                -- policy. Physical surplus may still be at its source until a
                -- successful insertion needs it; never count that as allocated.
                target.allocated = rejected[target] and target.current or desired[target]
                if limited[target] then target.full = true; rejected[target] = true end
            end
            local nextTargets = {}
            for _, target in ipairs(activeTargets) do
                if rejected[target] then
                    if options.balance then total = total - target.current end
                else nextTargets[#nextTargets + 1] = target end
            end
            activeTargets = nextTargets
            -- Keep the original distinction between single-pass drag and
            -- retrying inventory cleanup. The stack adapter must not change
            -- that policy just because insertion rejected part of a share.
            if not options.balance and options.retryFull == false then break end
            if not next(rejected) then break end
        end
        if options.balance then
            -- Original Balance returns stock exceeding all usable destinations.
            -- Return directly from its live source, committing only what fits.
            -- If the player has no room, keep the excess at its source.
            local excess = {}
            for _, target in ipairs(targets) do
                excess[target.plain] = math.max(0, target.current - (target.allocated or target.current))
            end
            for _, entry in ipairs(batch.entries) do
                local n = excess[entry.owner] or 0
                entry.limit = math.min(entry.available, n)
                excess[entry.owner] = n - entry.limit
            end
            batch.destination = plain(player)
            batches.insert(plain(player), item, batch.remaining, quality)
        end
    end)
    aggregate(targets, function(target) return target.received end, feedback)
end

function this.apply(player, entities, item, quality, options, insert, feedback)
    local prototype = prototypes.item[item]
    local mergesUsedItems = prototype.type == "ammo" or (prototype.get_durability(quality) or 0) > 0
    if not options.balance or not mergesUsedItems then
        return applyOnce(player, entities, item, quality, options, insert, feedback)
    end
    -- Native stacking can turn several used magazines/tools into fewer items
    -- without losing shots/durability. Rebalance actual counts within this same
    -- operation, drawing no additional stock from the player.
    local targets = {}
    local function targetCount(target)
        if target.inventory then return target.inventory.get_item_count{name=item, quality=quality} end
        return target.entity:itemcount(item, nil, nil, quality)
    end
    for entity in scripts.util.epairs(entities) do
        if entity.valid then
            local port = options.targetPort and options.targetPort(entity)
            local target = {entity = entity, inventory = port and entity:inventory(port) or nil}
            target.original = targetCount(target)
            targets[#targets + 1] = target
        end
    end
    local function status()
        local total, low, high = 0, math.huge, 0
        for _, target in ipairs(targets) do
            local count = targetCount(target)
            total = total + count; low = math.min(low, count); high = math.max(high, count)
        end
        return total, high - low
    end
    local function noteFull(entity, _, full)
        if full then
            for _, target in ipairs(targets) do if plain(entity) == plain(target.entity) then target.full = true end end
        end
    end
    applyOnce(player, entities, item, quality, options, insert, noteFull)
    local sources, partials = {}, 0
    for _, target in ipairs(targets) do
        if target.inventory then batches.addInventory(sources, target.inventory, target.inventory)
        else batches.addEntity(sources, target.entity) end
    end
    for _, source in ipairs(sources) do
        local s = source.stack
        if s.valid_for_read and s.name == item and s.quality.name == (quality or "normal") then
            if (s.is_ammo and s.ammo < s.prototype.magazine_size) or
               (s.is_tool and s.durability < s.prototype.get_durability(s.quality)) then partials = partials + 1 end
        end
    end
    -- A further pass is needed only after a native merge reduces item count;
    -- each such reduction consumes at least one of the remaining partial heads.
    for i = 1, partials + 1 do
        local before, spread = status()
        if spread <= 1 then break end
        applyOnce(player, entities, item, quality,
            {balance = true, targetsOnly = true, targetPort = options.targetPort}, insert, noteFull)
        local after = status()
        if after >= before then break end
    end
    for _, target in ipairs(targets) do
        feedback(target.entity, targetCount(target) - target.original, target.full)
    end
end

return this
