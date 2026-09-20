--!nonstrict
local data = noctalia.state.get("windows.data") or { state = "loading" }

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  return value == nil and fallback or value
end

local function color()
  if data.busy or data.pendingConnect then return "primary" end
  if data.state == "running" then return "#a6e3a1" end
  if data.state == "booting" or data.state == "preparing" then return "#f9e2af" end
  if data.state == "error" then return "#f38ba8" end
  return "on_surface_variant"
end

local function statusText()
  if data.busy then
    return noctalia.tr(data.operation == "stop" and "action.stopping" or "action.starting")
  end
  if data.pendingConnect then
    return noctalia.tr("action.connecting")
  end
  return noctalia.tr("state." .. tostring(data.state or "error"))
end

local function render()
  local children = { ui.glyph({ name = cfg("glyph", "brand-windows"), size = 15, color = color() }) }
  if cfg("show_label", true) ~= false then
    table.insert(children, ui.label({ text = statusText(), color = "on_surface" }))
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
end

function update() render() end
function onClick() noctalia.togglePanel("johnschmidt/windows:panel") end

-- Right-click is the no-panel path, and escalates along the VM's own states:
-- connect once Windows answers RDP, stop while it is up, start when it is off.
function onRightClick()
  if data.busy then return end
  if data.state == "running" then
    noctalia.state.set("windows.cmd", { op = "connect" })
  elseif data.state == "stopped" or data.state == "error" then
    noctalia.state.set("windows.cmd", { op = "start" })
  else
    noctalia.state.set("windows.cmd", { op = "stop" })
  end
end

noctalia.state.watch("windows.data", function(value)
  if type(value) == "table" then data = value render() end
end)

barWidget.clearTooltip()
render()
