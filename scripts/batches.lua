-- One player consumption bracket per item/quality and operation, except ammo.
-- Ammo crosses all brackets in one operation, with used heads first.
-- Sources are debited
-- only after successful native insertion, so rejected items never need a return
-- slot or a spill fallback. Native stacks carry their complete item metadata.
local this = {}
local active

local function plain(value)
    if type(value) == "table" and rawget(value, "__on") ~= nil then return rawget(value, "__on") end
    return value
end
local function matches(stack, item, quality)
    return stack and stack.valid and stack.valid_for_read and stack.name == item and stack.quality.name == quality
end
local function third(remaining)
    if remaining <= 1 / 3 then return 1 end
    if remaining <= 2 / 3 then return 2 end
    return 3
end

-- Ammo/tool stacks contain ONE partially used head item and count-1 full items.
-- Health and spoilage apply to the complete stack. A stack may therefore span
-- two brackets; its full tail must not accompany its partly consumed head.
function this.parts(stack)
    local rest = math.min(1, stack.health, 1 - stack.spoil_percent)
    local head = rest
    if stack.is_ammo then
        local maximum = stack.prototype.magazine_size
        if maximum and maximum > 0 then head = math.min(head, stack.ammo / maximum) end
    end
    if stack.is_tool then
        local maximum = stack.prototype.get_durability(stack.quality)
        if maximum and maximum > 0 then head = math.min(head, stack.durability / maximum) end
    end
    return third(head), third(rest), head, rest
end

function this.addInventory(sources, inventory, owner, personal)
    inventory = plain(inventory)
    if not (inventory and inventory.valid) then return end
    for i = 1, #inventory do
        sources[#sources + 1] = {stack = inventory[i], owner = owner, personal = personal}
    end
end

function this.playerSources(player, takeInventory, takeCar, takeTrash)
    player = plain(player)
    local wrap = scripts.helpers.on
    local p, sources = wrap(player), {}
    if takeTrash then this.addInventory(sources, p:inventory("character_trash"), player) end
    if takeInventory then this.addInventory(sources, p:inventory(), player, true) end
    if player.cursor_stack and player.cursor_stack.valid then
        sources[#sources + 1] = {stack = player.cursor_stack, owner = player, personal = true}
    end
    if takeCar and player.driving and player.vehicle and player.vehicle.valid then
        this.addInventory(sources, wrap(player.vehicle):inventory("car_trunk"), player)
    end
    return sources
end

function this.addEntity(sources, entity)
    entity = plain(entity)
    for i = 1, entity.get_max_inventory_index() do
        this.addInventory(sources, entity.get_inventory(i), entity)
    end
end

function this.select(sources, item, quality, lockedBracket, includeAll)
    quality = quality or "normal"
    local bracket, entries = 4, {}
    for _, source in ipairs(sources) do
        local s = source.stack
        if matches(s, item, quality) then
            local head, tail, headRest, tailRest = this.parts(s)
            if not lockedBracket then
                bracket = math.min(bracket, head)
                if s.count > 1 then bracket = math.min(bracket, tail) end
            end
            entries[#entries + 1] = {stack = s, owner = source.owner, personal = source.personal, head = head, tail = tail,
                headRest = headRest, tailRest = tailRest}
        end
    end
    bracket = lockedBracket or bracket
    local count, selected = 0, {}
    local function add(entry, n, bucket, priority, tailOnly)
        local all = includeAll == true or (type(includeAll) == "function" and includeAll(entry.owner))
        if n <= 0 or (not all and bucket ~= bracket) then return end
        selected[#selected + 1] = {stack = entry.stack, owner = entry.owner, personal = entry.personal,
            limit = n, tailOnly = tailOnly, priority = priority, order = #selected + 1}
        count = count + n
    end
    for _, entry in ipairs(entries) do
        local s = entry.stack
        if entry.headRest ~= entry.tailRest then
            add(entry, 1, entry.head, entry.headRest, false)
            add(entry, s.count - 1, entry.tail, entry.tailRest, true)
        else
            add(entry, s.count, entry.head, entry.headRest, false)
        end
    end
    table.sort(selected, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.order < b.order
    end)
    return {entries = selected, item = item, quality = quality, bracket = bracket, count = count}
end

local function prepare(batch, rollbackOnNoMove)
    -- Retain .4's weighted freshness merge, restricted to the locked bracket.
    -- The unselected brackets are neither removed nor rewritten.
    if prototypes.item[batch.item].get_spoil_ticks(batch.quality) <= 0 then return end
    local groups = {}
    local originalSpoilage = rollbackOnNoMove and {}
    for _, entry in ipairs(batch.entries) do
        if entry.limit > 0 and entry.limit == entry.stack.count then
            -- Other properties can also make an item the most-used third.
            -- Don't rejuvenate an old stack by averaging it with damaged but
            -- fresh stock that happens to belong to that same active bracket.
            local ageBracket = third(1 - entry.stack.spoil_percent)
            local group = groups[ageBracket] or {count = 0, weight = 0, entries = {}}
            groups[ageBracket] = group
            group.count = group.count + entry.stack.count
            group.weight = group.weight + entry.stack.count * entry.stack.spoil_percent
            group.entries[#group.entries + 1] = entry
        end
    end
    for _, group in pairs(groups) do
        local mean = group.weight / group.count
        for _, entry in ipairs(group.entries) do
            -- Spoilable stacks normally have no partial head. If a mod combines
            -- both properties, don't rewrite an unselected full tail.
            if originalSpoilage and originalSpoilage[entry.stack] == nil then
                originalSpoilage[entry.stack] = entry.stack.spoil_percent
            end
            entry.stack.spoil_percent = mean
        end
    end
    return originalSpoilage
end

local function payload(batch, entry, amount)
    local s = entry.stack
    local n = math.min(amount, entry.limit, s.count, s.prototype.stack_size)
    if n <= 0 then return nil end
    local p = batch.scratch[1]
    p.set_stack(s)
    p.count = n
    -- Reducing count natively resets the head to full, so restore its state.
    if s.is_ammo then p.ammo = entry.tailOnly and s.prototype.magazine_size or s.ammo end
    if s.is_tool then p.durability = entry.tailOnly and s.prototype.get_durability(s.quality) or s.durability end
    return p
end

local function commit(batch, entry, inserted)
    if inserted <= 0 then return end
    local s = entry.stack
    local ammo = entry.tailOnly and s.is_ammo and s.ammo
    local durability = entry.tailOnly and s.is_tool and s.durability
    s.count = s.count - inserted
    if s.valid_for_read then
        if ammo then s.ammo = ammo end
        if durability then s.durability = durability end
    end
    entry.limit = entry.limit - inserted
    if entry.available then entry.available = entry.available - inserted end
    batch.remaining = batch.remaining - inserted
    if batch.onDebit then batch.onDebit(entry.owner, inserted) end
end

function this.insert(target, item, amount, quality)
    local batch = active
    if not batch or batch.item ~= item or batch.quality ~= (quality or "normal") then return nil end
    target = plain(target)
    local inserted = 0
    for _, entry in ipairs(batch.entries) do
        if inserted >= amount or batch.remaining <= 0 then break end
        if entry.limit > 0 and matches(entry.stack, item, batch.quality) and entry.owner ~= batch.destination then
            while entry.limit > 0 and inserted < amount and batch.remaining > 0 do
                local p = payload(batch, entry, math.min(amount - inserted, batch.remaining))
                if not p then break end
                local n = target.insert(p)
                commit(batch, entry, n)
                inserted = inserted + n
                if n == 0 then break end
            end
        end
    end
    return inserted
end

function this.isActive() return active ~= nil end

-- A replacement is permitted only with a reserved empty return slot. If the
-- player cannot carry the displaced item, leave the original target unchanged.
function this.replace(player, target, item, amount, quality, takeCar, takeTrash)
    local batch = active
    target, player = plain(target), plain(player)
    if not batch or not target or not target.valid_for_read then return 0 end
    local donor
    for _, entry in ipairs(batch.entries) do
        if entry.limit > 0 and entry.owner ~= batch.destination and matches(entry.stack, item, quality) then donor = entry; break end
    end
    if not donor or batch.remaining <= 0 then return 0 end
    local p = payload(batch, donor, math.min(amount, batch.remaining))
    if not p or not target.can_set_stack(p) then return 0 end
    local wrap, inventories = scripts.helpers.on, {}
    inventories[#inventories + 1] = wrap(player):inventory()
    if takeCar and player.driving and player.vehicle and player.vehicle.valid then inventories[#inventories + 1] = wrap(player.vehicle):inventory("car_trunk") end
    if takeTrash then inventories[#inventories + 1] = wrap(player):inventory("character_trash") end
    local reserved
    for _, inv in ipairs(inventories) do
        inv = plain(inv)
        if inv and inv.valid then
            local slot = inv.find_empty_stack{name = target.name, quality = target.quality.name}
            if slot and slot.can_set_stack(target) then reserved = slot; break end
        end
    end
    if not reserved then return 0 end
    if not reserved.transfer_stack(target) then return 0 end
    if not target.set_stack(p) then target.transfer_stack(reserved); return 0 end
    local n = target.count
    commit(batch, donor, n)
    return n
end

function this.run(batch, budget, callback, rollbackOnNoMove)
    assert(not active, "Nested distribution batch")
    batch.remaining = math.min(batch.count, budget or batch.count)
    if batch.remaining <= 0 then return end
    local initialRemaining = batch.remaining
    local originalSpoilage = prepare(batch, rollbackOnNoMove)
    batch.scratch = game.create_inventory(1)
    active = batch
    local ok, err = pcall(callback, batch)
    active = nil
    batch.scratch.destroy()
    batch.scratch = nil
    if originalSpoilage and batch.remaining == initialRemaining then
        for stack, spoilPercent in pairs(originalSpoilage) do
            stack.spoil_percent = spoilPercent
        end
    end
    if not ok then error(err) end
end

-- Vanilla performs its cursor transfer before raising on_player_fast_transferred.
-- Keep native copies while hovering so that this provisional transfer can be
-- undone without first merging the cursor with a different consumption bracket.
function this.snapshot(entity, cursor, item, quality, player, previous)
    entity, cursor = plain(entity), plain(cursor)
    local result = {inventories = {}, item = item, quality = quality, cursor = cursor}
    local sources, seen = {cursor}, {}
    local function capture(inv)
        if not (inv and inv.valid) or seen[inv] then return end
        seen[inv] = true
        local record = {inventory = inv, slots = {}}
        result.inventories[#result.inventories + 1] = record
        if inv.get_item_count{name = item, quality = quality} == 0 then return end
        for i = 1, #inv do
            if matches(inv[i], item, quality) then
                sources[#sources + 1] = inv[i]
                record.slots[#record.slots + 1] = {slot = i, index = #sources}
            end
        end
    end
    for i = 1, entity.get_max_inventory_index() do capture(entity.get_inventory(i)) end
    -- Native cursor refill can debit another main-inventory stack before the
    -- fast-transfer event. Restoring only the cursor would delete that refill.
    player = plain(player)
    if player then capture(player.get_main_inventory()) end
    -- Reuse only the allocation, never its old contents or inventory records.
    local backup = previous and previous.backup
    if backup and backup.valid and #backup == #sources then
        result.backup = backup
        previous.backup = nil
    else
        this.discard(previous)
        result.backup = game.create_inventory(#sources)
    end
    for i, stack in ipairs(sources) do result.backup[i].set_stack(stack) end
    return result
end

function this.discard(snapshot)
    if snapshot and snapshot.backup and snapshot.backup.valid then snapshot.backup.destroy() end
end

function this.undo(snapshot)
    if not (snapshot and snapshot.backup and snapshot.backup.valid) then return end
    -- A foreign cursor change must never be overwritten. In that case retain
    -- vanilla's already completed transfer instead of synthesizing a return.
    if not snapshot.cursor.valid or
       (snapshot.cursor.valid_for_read and not matches(snapshot.cursor, snapshot.item, snapshot.quality)) then
        this.discard(snapshot)
        return
    end
    -- Old hover snapshots saved by previous versions have no inventory records.
    -- Keep the native transfer rather than applying an incomplete rollback.
    if snapshot.slots then this.discard(snapshot); return end
    local function quantity(s)
        if not matches(s, snapshot.item, snapshot.quality) then return 0 end
        if s.is_ammo then return s.count - 1 + s.ammo / s.prototype.magazine_size end
        if s.is_tool then return s.count - 1 + s.durability / s.prototype.get_durability(s.quality) end
        return s.count
    end
    local before, current = 0, quantity(snapshot.cursor)
    for i = 1, #snapshot.backup do before = before + quantity(snapshot.backup[i]) end
    local plans = {}
    for _, record in ipairs(snapshot.inventories) do
        local inv = record.inventory
        if not inv.valid then this.discard(snapshot); return end
        -- Plan ALL inventories before clearing ANY slot. Auto-sorting may have
        -- moved unrelated items into the former source or destination slots.
        local available = {}
        for i = 1, #inv do
            current = current + quantity(inv[i])
            if not inv[i].valid_for_read or matches(inv[i], snapshot.item, snapshot.quality) then
                available[i] = true
            end
        end
        local restores = {}
        for _, entry in ipairs(record.slots) do
            local chosen
            local original = snapshot.backup[entry.index]
            if available[entry.slot] and inv[entry.slot].can_set_stack(original) then chosen = entry.slot
            else
                for i = 1, #inv do
                    if available[i] and inv[i].can_set_stack(original) then chosen = i; break end
                end
            end
            if not chosen then this.discard(snapshot); return end
            available[chosen] = nil
            restores[#restores + 1] = {slot = chosen, index = entry.index}
        end
        plans[#plans + 1] = {inventory = inv, restores = restores}
    end
    -- A different mod or a changed transfer may have altered the stock. Never
    -- overwrite that live state with an older count. Native ammo/tool merging
    -- is allowed: compare remaining shots/uses rather than raw stack counts.
    if math.abs(before - current) > 0.00001 then this.discard(snapshot); return end
    if not snapshot.cursor.can_set_stack(snapshot.backup[1]) then this.discard(snapshot); return end
    for _, plan in ipairs(plans) do
        local inv = plan.inventory
        for i = 1, #inv do
            if matches(inv[i], snapshot.item, snapshot.quality) then inv[i].clear() end
        end
        for _, entry in ipairs(plan.restores) do inv[entry.slot].set_stack(snapshot.backup[entry.index]) end
    end
    snapshot.cursor.set_stack(snapshot.backup[1])
    this.discard(snapshot)
end

return this
