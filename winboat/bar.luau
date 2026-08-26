--!nonstrict
local data = noctalia.state.get("winboat.data") or { status = "loading" }

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  return value == nil and fallback or value
end

local function color()
  if data.busy then return "primary" end
  if data.status == "running" then return "#a6e3a1" end
  if data.status == "paused" or data.status == "restarting" then return "#f9e2af" end
  if data.status == "dead" or data.status == "error" or data.status == "unavailable" or data.status == "missing" then return "#f38ba8" end
  return "on_surface_variant"
end

local function statusText()
  if data.busy then
    return noctalia.tr(data.operation == "stop" and "action.stopping" or "action.starting")
  end
  return noctalia.tr("status." .. tostring(data.status or "error"))
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
function onClick() noctalia.togglePanel("johnschmidt/winboat:panel") end
function onRightClick()
  if not data.busy then
    noctalia.state.set("winboat.cmd", { op = data.status == "running" and "stop" or "start" })
  end
end

noctalia.state.watch("winboat.data", function(value)
  if type(value) == "table" then data = value render() end
end)

barWidget.clearTooltip()
render()
