local choice = {}
local windowName = "ed_module_choice"

function choice.open(player)
    local window = player.gui.screen.add{
        type = "frame", name = windowName, direction = "vertical",
        caption = {"ed-module-choice.title"},
    }
    window.add{type = "label", caption = {"ed-module-choice.prompt"}}
    local buttons = window.add{type = "flow", direction = "horizontal"}
    for _, port in ipairs({"input", "modules", "cancel"}) do
        buttons.add{
            type = "button", name = port, caption = {"ed-module-choice." .. port},
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
