-- Read-only ammunition ranking and the character's protected ammunition reserve.
local this = {}
local ranks = {}
local function plain(value)
    return type(value) == "table" and rawget(value, "__on") or value
end
local function matches(stack, item, quality)
    return stack and stack.valid_for_read and stack.name == item and stack.quality.name == quality
end

local function damageScore(prototype)
    local state = {left=512, depth=0, entities={}}
    local actions, deliveries, effects, entityDamage
    local function sum(value, fn)
        if not value or state.left <= 0 or state.depth >= 32 then return 0 end
        state.left = state.left - 1; state.depth = state.depth + 1
        local result = 0
        if value.type then result = fn(value)
        else for _, entry in ipairs(value) do result = result + fn(entry) end end
        state.depth = state.depth - 1
        return result
    end
    entityDamage = function(name)
        if not name or state.entities[name] then return 0 end
        local entity = prototypes.entity[name]
        if not entity then return 0 end
        state.entities[name] = true
        local damage = actions(entity.attack_result) + actions(entity.final_attack_result)
        state.entities[name] = nil
        return damage
    end
    effects = function(value)
        return sum(value, function(effect)
            local damage = 0
            if effect.type == "damage" then damage = math.max(0, effect.damage.amount)
            elseif effect.action then damage = actions(effect.action)
            elseif effect.type == "create-entity" then damage = entityDamage(effect.entity_name) end
            return damage * (effect.repeat_count or 1) * (effect.probability or 1)
        end)
    end
    deliveries = function(value)
        return sum(value, function(delivery)
            return effects(delivery.target_effects) + entityDamage(delivery.projectile or delivery.stream or delivery.beam)
        end)
    end
    actions = function(value)
        return sum(value, function(action)
            return deliveries(action.action_delivery) * (action.repeat_count or 1) * (action.probability or 1)
        end)
    end
    local ammo = prototype.get_ammo_type()
    return ammo and actions(ammo.action) or 0
end

function this.rank(value)
    local prototype = type(value) == "string" and prototypes.item[value] or plain(value)
    local rank = ranks[prototype.name]
    if not rank then
        rank = {name=prototype.name, category=prototype.ammo_category.name,
            damage=damageScore(prototype), order=prototype.order or ""}
        ranks[prototype.name] = rank
    end
    return rank
end

-- Ascending strength for replacement lists; stronger items receive higher rank.
function this.less(a, b)
    a, b = this.rank(a), this.rank(b)
    if a.category ~= b.category then return a.category < b.category end
    if a.damage ~= b.damage then return a.damage < b.damage end
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
end

function this.orderedItems(items)
    local result = {}
    for item, count in pairs(plain(items)) do
        result[#result + 1] = {item=item, maximum=count, ammo=prototypes.item[item].type == "ammo"}
    end
    table.sort(result, function(a, b)
        if a.ammo ~= b.ammo then return a.ammo end
        if not a.ammo then return a.item < b.item end
        local ar, br = this.rank(a.item), this.rank(b.item)
        if ar.category ~= br.category then return ar.category < br.category end
        -- Follow native ammo progression, including normal -> explosive rockets.
        -- Raw direct damage alone can invert variants with different splash damage.
        if ar.order ~= br.order then return ar.order < br.order end
        return this.less(a.item, b.item)
    end)
    return result
end

-- Weapon slots are never distribution sources. Their equipped item/quality
-- protects a total of 100 items on the character, including main and cursor.
-- Vehicle cargo and trash are not counted as a personal combat reserve.
function this.personalAllowance(player, item, quality)
    player, quality = plain(player), quality or "normal"
    local character = player.character
    if not (character and character.valid) then return math.huge end
    local inventory = character.get_inventory(defines.inventory.character_ammo)
    if not inventory then return math.huge end
    local equipped = 0
    for i = 1, #inventory do
        local slot = inventory[i]
        if matches(slot, item, quality) then equipped = equipped + slot.count end
    end
    if equipped == 0 then return math.huge end
    local main = player.get_main_inventory()
    local total = equipped + (main and main.valid and main.get_item_count{name=item,quality=quality} or 0)
    if matches(player.cursor_stack, item, quality) then total = total + player.cursor_stack.count end
    return math.max(0, total - 100)
end

return this
