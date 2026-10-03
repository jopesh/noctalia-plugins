--!nonstrict
local PANEL_ID = "johnschmidt/boringday:panel"

local data = noctalia.state.get("boringday.data") or {}

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  return value == nil and fallback or value
end

local function render()
  local color = (data.lastError ~= nil and data.lastError ~= "") and "error" or "on_surface"
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, {
    ui.glyph({ name = cfg("glyph", "photo"), size = 16, color = color }),
  }))
  if data.current ~= nil then
    barWidget.setTooltip(data.current.name .. "\n" .. data.current.artist)
  else
    barWidget.clearTooltip()
  end
end

function onClick() noctalia.togglePanel(PANEL_ID) end
function onRightClick() noctalia.state.set("boringday.cmd", { op = "shuffle" }) end
function onMiddleClick() noctalia.state.set("boringday.cmd", { op = "refresh" }) end

noctalia.state.watch("boringday.data", function(value)
  if type(value) == "table" then data = value render() end
end)

render()
