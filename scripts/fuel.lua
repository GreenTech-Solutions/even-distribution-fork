local fuel = {}
function fuel.is_fuel(prototype)
    local categories = prototype and prototype.fuel_categories
    return categories ~= nil and next(categories) ~= nil
end
function fuel.accepts(burner, prototype)
    if not burner then return false end
    for _, category in pairs(prototype.fuel_categories or {}) do
        if burner.fuel_categories[category] then return true end
    end
    return false
end
function fuel.less(a,b)
    for _, key in ipairs({"fuel_value", "fuel_acceleration_multiplier", "fuel_top_speed_multiplier", "fuel_emissions_multiplier"}) do
        if a[key] ~= b[key] then return a[key] < b[key] end
    end
    return a.name < b.name
end
function fuel.build_list(items)
    local result = {}
    for _, item in pairs(items) do
        for _, category in pairs(item.fuel_categories or {}) do
            result[category] = result[category] or {}
            table.insert(result[category], item)
        end
    end
    for _, list in pairs(result) do table.sort(list, fuel.less) end
    return result
end
function fuel.replacements(prototype, lists)
    local result, seen = {}, {}
    for _, category in pairs(prototype.fuel_categories or {}) do
        for _, item in pairs(lists[category] or {}) do
            if not seen[item.name] then result[#result+1] = item; seen[item.name] = true end
        end
    end
    table.sort(result, fuel.less)
    return result
end
return fuel
