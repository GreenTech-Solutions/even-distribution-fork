-- Controller for the Even Distribution settings GUI

local this = {}
local util = scripts.util
local gui = scripts["gui-tools"]
local templates = scripts["settings-gui.gui-templates"].templates
local unified = script.active_mods.GUI_Unifyer ~= nil

local helpers = scripts.helpers
local _ = helpers.on

local function applyUnifiedButtonStyle(player, button)
	local style = settings.get_player_settings(player:toPlain()).gu_button_style_setting
	if style then button.style = style.value end
end

local function sizeUnifiedPane(player, window)
	local displayHeight = player.display_resolution.height / player.display_scale
	-- A standalone window has no inventory frame to size the scroll pane.
	window.settings_content.style.height = math.max(120, math.min(600, math.floor(displayHeight * 0.85) - 48))
end

function this.on_init()
	for __,player in pairs(game.players) do
		player = _(player)
		if player:is("valid") then 
			gui.destroy(player, templates.settingsWindow, player.gui.relative)
			gui.destroy(player, templates.settingsWindow, player.gui.screen)
			gui.destroy(player, templates.settingsButton, player.gui.relative)
			if not unified then
				local top = player.gui.top
				local frame = top.mod_gui_top_frame
				local flow = top.mod_gui_button_flow or (frame and frame.mod_gui_inner_frame)
				if flow then gui.destroy(player, templates.settingsButton, flow) end
			end
			this.buildButton(player)
		end
	end
end

this.on_configuration_changed = this.on_init

function this.on_player_created(event)
	local player = _(game.players[event.player_index])
	
	if player:is("valid") then 
		this.destroyGUI(player)
		this.buildButton(player)
	end
end

function this.on_runtime_mod_setting_changed(event)
	if unified and event.setting == "gu_button_style_setting" then
		local player = _(game.get_player(event.player_index))
		if player:is("valid player") then
			local button = gui.get(player, templates.settingsButton)
			if button then applyUnifiedButtonStyle(player, button) end
		end
	elseif event.setting == "disable-distribute" or
	   event.setting == "disable-inventory-cleanup" then

		local player = _(game.players[event.player_index])
		if player:is("valid player") and gui.get(player, templates.settingsWindow) then
			this.buildGUI(player)
		end
	end
end

function this.buildGUI(player)
	local window = gui.create(player, templates.settingsWindow, { })
	if unified then
		sizeUnifiedPane(player, window)
		window.auto_center = true
		player:toPlain().opened = window
	end
end

function this.destroyGUI(player)
	gui.destroy(player, templates.settingsWindow)
end

function this.buildButton(player)
	local button = gui.create(player, templates.settingsButton, { })
	if unified then applyUnifiedButtonStyle(player, button) end
end

function this.destroyButton(player)
	gui.destroy(player, templates.settingsButton)
end

function this.toggleGUI(player)
	if gui.get(player, templates.settingsWindow) then
		this.closeGUI(player)
	else
		if not unified then this.destroyButton(player) end
		this.buildGUI(player)
	end
end

function this.closeGUI(player)
	this.destroyGUI(player)
	if not unified then this.buildButton(player) end
end

if unified then
	function this.on_player_display_resolution_changed(event)
		local player = _(game.get_player(event.player_index))
		if player:is("valid") then
			local window = gui.get(player, templates.settingsWindow)
			if window then sizeUnifiedPane(player, window) end
		end
	end

	this.on_player_display_scale_changed = this.on_player_display_resolution_changed

	function this.on_gui_closed(event)
		local element = event.element
		if element and element.valid and element.name == templates.settingsWindow.name then
			local player = _(game.get_player(event.player_index))
			if element == gui.get(player, templates.settingsWindow) then this.destroyGUI(player) end
		end
	end
end

return this
