local choice = {}
local windowName = "ed_module_choice"

local options = {
    module = {locale = "ed-module-choice", ports = {"input", "modules", "cancel"}},
    nutrients = {locale = "ed-nutrient-choice", ports = {"input", "fuel", "both", "cancel"}},
}

function choice.allows(kind, port)
    local option = options[kind]
    if not option or port == "cancel" then return false end
    for _, allowed in ipairs(option.ports) do
        if port == allowed then return true end
    end
    return false
end

function choice.open(player, kind)
    local option = options[kind]
    choice.close(player)
    local window = player.gui.screen.add{
        type = "frame", name = windowName, direction = "vertical",
        caption = {option.locale .. ".title"},
    }
    window.add{type = "label", caption = {option.locale .. ".prompt"}}
    local buttons = window.add{type = "flow", direction = "horizontal"}
    for _, port in ipairs(option.ports) do
        buttons.add{
            type = "button", name = port, caption = {option.locale .. "." .. port},
            style = port == "cancel" and "red_button" or nil,
        }
    end
    window.auto_center = true
    player.opened = window
end

function choice.close(player)
    local window = player.gui.screen[windowName]
    if window then window.destroy() end
end

function choice.isWindow(player, element)
    return element and element.valid and element == player.gui.screen[windowName]
end

function choice.button(player, element)
    if not element or not element.valid or element.type ~= "button" then return end
    local parent = element.parent
    if parent and choice.isWindow(player, parent.parent) then return element.name end
end

return choice
