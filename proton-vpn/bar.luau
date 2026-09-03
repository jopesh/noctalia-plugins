--!nonstrict
-- Proton VPN bar widget — glyph, optional server label, and a status tooltip.

local data = noctalia.state.get("proton_vpn.data") or { status = "loading" }

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  return value == nil and fallback or value
end

local function color()
  if data.busy then
    return "primary"
  end
  if data.status == "connected" then
    return cfg("color_connected", "#a6e3a1")
  end
  if data.status == "error" or data.status == "unavailable" or data.status == "signin_required" then
    return "error"
  end
  return "on_surface_variant"
end

local BUSY_KEYS = {
  connect = "action.connecting",
  disconnect = "action.disconnecting",
  config = "action.working",
}

local function statusText()
  if data.busy then
    return noctalia.tr(BUSY_KEYS[data.operation] or "action.working")
  end
  return noctalia.tr("status." .. tostring(data.status or "error"))
end

local function label()
  if data.busy then
    return "…"
  end
  if data.status == "connected" and data.serverName ~= nil then
    return data.serverName
  end
  return noctalia.tr("status.off")
end

-- "DE#402 · Frankfurt, Germany · 35% load" once the helper has resolved the
-- active server; the bare server name until then.
local function tooltip()
  local server = data.server
  if data.status ~= "connected" or type(server) ~= "table" then
    return statusText()
  end
  local parts = { server.name or data.serverName or "" }
  if server.city ~= nil and server.country ~= nil then
    table.insert(parts, noctalia.tr("detail.place", { city = server.city, country = server.country }))
  end
  if type(server.load) == "number" then
    table.insert(parts, noctalia.tr("detail.load", { load = tostring(math.floor(server.load)) }))
  end
  return table.concat(parts, " · ")
end

local function render()
  local children = { ui.glyph({ name = cfg("glyph", "shield-lock"), size = 15, color = color() }) }
  if cfg("show_label", true) ~= false then
    table.insert(children, ui.label({ text = label(), color = "on_surface" }))
  end
  barWidget.setTooltip(tooltip())
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("johnschmidt/proton-vpn:panel")
end

function onRightClick()
  if data.busy then
    return
  end
  if data.status == "connected" then
    noctalia.state.set("proton_vpn.cmd", { op = "disconnect" })
  else
    noctalia.state.set("proton_vpn.cmd", { op = "connect", kind = "fastest" })
  end
end

noctalia.state.watch("proton_vpn.data", function(value)
  if type(value) == "table" then
    data = value
    render()
  end
end)

render()
