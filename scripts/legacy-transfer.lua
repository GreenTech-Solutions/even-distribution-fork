-- Compatibility for quantity-based helper calls outside a native batch.
-- Pools contain only items still in transit, separated by item and quality.
-- Commit actual successful writes; failed inserts consume no freshness.
-- Mixed stacks use a weighted average, subject to native spoil-tick rounding.
local this = {}
local pool, spoilable = {}, {}

local function plain(obj)
    if type(obj) == "table" and rawget(obj, "__on") ~= nil then return rawget(obj, "__on") end
    return obj
end
local function key(item, quality) return item .. "/" .. (quality or "normal") end
function this.isSpoilable(item)
    local cached = spoilable[item]
    if cached == nil then
        local proto = prototypes.item[item]
        cached = proto ~= nil and (proto.get_spoil_ticks() or 0) > 0
        spoilable[item] = cached
    end
    return cached
end
local function add(item, quality, count, weighted)
    if count <= 0 then return end
    local k = key(item, quality)
    local p = pool[k]
    if p then
        p.average = (p.average * p.count + weighted) / (p.count + count)
        p.count = p.count + count
    else pool[k] = {count=count, average=weighted / count} end
end
local function consume(item, quality, count)
    if count <= 0 then return end
    local k = key(item, quality)
    local p = pool[k]
    if not p then return end
    if count >= p.count then pool[k] = nil
    else p.count = p.count - count end
end

-- One pass, stopping after the requested amount. Nonperishables stay native.
function this.removeFromInventory(inv, item, count, quality)
    if count <= 0 then return 0 end
    inv = plain(inv)
    if not (inv and inv.valid) then return 0 end
    quality = quality or "normal"
    if not this.isSpoilable(item) then
        return inv.remove{name=item, count=count, quality=quality}
    end
    local removed, weighted = 0, 0
    for i=1,#inv do
        local stack = inv[i]
        if stack.valid_for_read and stack.name == item and stack.quality.name == quality then
            local taken = math.min(stack.count, count - removed)
            weighted = weighted + taken * stack.spoil_percent
            stack.count = stack.count - taken
            removed = removed + taken
            if removed >= count then break end
        end
    end
    add(item, quality, removed, weighted)
    return removed
end
function this.recordStack(stack, count)
    stack = plain(stack)
    if count > 0 and stack.valid_for_read and this.isSpoilable(stack.name) then
        count = math.min(count, stack.count)
        add(stack.name, stack.quality.name, count, count * stack.spoil_percent)
    end
end
function this.peek(stack)
    stack = plain(stack)
    if stack and stack.valid_for_read and this.isSpoilable(stack.name) then
        return {name=stack.name, quality=stack.quality.name, spoil=stack.spoil_percent}
    end
end
function this.record(snapshot, count)
    if snapshot and count > 0 then
        add(snapshot.name, snapshot.quality, count, count * snapshot.spoil)
    end
end

-- Preparing a definition is read-only. The successful write commits its count.
function this.def(item, count, quality)
    local result = {name=item, count=count, quality=quality or "normal"}
    local p = pool[key(item, quality)]
    if p and p.count > 0 then result.spoil_percent = math.min(1, math.max(0, p.average)) end
    return result
end
function this.insert(target, item, count, quality)
    if count <= 0 then return 0 end
    local inserted = target.insert(this.def(item, count, quality))
    consume(item, quality, inserted)
    return inserted
end
function this.setStack(stack, item, count, quality)
    if not stack or count <= 0 then return false end
    local success = stack.set_stack(this.def(item, count, quality))
    if success then consume(item, quality, stack.count) end
    return success
end
function this.spill(surface, parameters, item, count, quality)
    parameters.stack = this.def(item, count, quality)
    local entities = surface.spill_item_stack(parameters)
    if pool[key(item, quality)] then
        local spilled = 0
        for _,entity in pairs(entities or {}) do
            if entity.valid then
                local stack = entity.stack
                if stack.valid_for_read and stack.name == item and stack.quality.name == (quality or "normal") then
                    spilled = spilled + stack.count
                end
            end
        end
        consume(item, quality, math.min(count, spilled))
    end
    return entities
end
return this
