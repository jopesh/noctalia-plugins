--!nonstrict
-- Agents bar widget — the port of Panel.qml's BarIconButton.
--
-- Nothing to report, nothing in the bar: the widget hides itself the moment the
-- provider list is empty, so a machine that has never run an AI coding agent
-- draws nothing and the icon arrives on its own the first time a scan finds
-- usage. The alarm state follows the selected subscription, the same one the
-- panel is showing.
--
-- Left click opens the panel, right click launches the agent, middle click
-- steps to the next subscription.

local shared = require("./shared.luau")

local PANEL_ID = "johnschmidt/agents:panel"

local data = noctalia.state.get("agents.data") or { providers = {} }
local selected = noctalia.state.get("agents.selected") or ""

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function render()
  local providers = data.providers or {}
  if #providers == 0 then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local provider = shared.selectedProvider(providers, selected)
  local alarming = shared.alarming(provider)

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, {
    ui.glyph({
      name = cfg("glyph", "robot"),
      size = 16,
      color = alarming and "error" or "on_surface",
    }),
  }))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

-- Upstream shells out to `omarchy-agent --pick`, which is omarchy's own picker.
-- The transferable part is "right click starts the agent in a terminal", so the
-- command is a setting instead.
function onRightClick()
  local command = cfg("launch_command", "claude")
  if type(command) ~= "string" then
    return
  end
  command = noctalia.string.trim(command)
  if command == "" then
    return
  end
  noctalia.runInTerminal(command)
end

function onMiddleClick()
  noctalia.state.set("agents.cmd", { op = "next" })
end

-- open/close/toggle need to know whether the panel is already up; the panel
-- entry publishes that, since noctalia.togglePanel is the only lever here.
function onIpc(event, _payload)
  local open = noctalia.state.get("agents.panelOpen") == true
  if event == "toggle" then
    noctalia.togglePanel(PANEL_ID)
  elseif (event == "open" or event == "show") and not open then
    noctalia.togglePanel(PANEL_ID)
  elseif (event == "close" or event == "hide") and open then
    noctalia.togglePanel(PANEL_ID)
  end
end

noctalia.state.watch("agents.data", function(value)
  if type(value) == "table" then
    data = value
    render()
  end
end)

noctalia.state.watch("agents.selected", function(value)
  if type(value) == "string" then
    selected = value
    render()
  end
end)

-- The panel is the detail view; the icon says only whether something is full.
barWidget.clearTooltip()
render()
