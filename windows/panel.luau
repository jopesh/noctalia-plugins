--!nonstrict
local data = noctalia.state.get("windows.data") or { state = "loading" }

local function command(op)
  noctalia.state.set("windows.cmd", { op = op })
end

local function statusColor()
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

local function uptimeText()
  local seconds = tonumber(data.uptime)
  if seconds == nil then
    return "—"
  end
  local days = math.floor(seconds / 86400)
  local hours = math.floor((seconds % 86400) / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  if days > 0 then return string.format("%dd %dh", days, hours) end
  if hours > 0 then return string.format("%dh %dm", hours, minutes) end
  return string.format("%dm", minutes)
end

local function metric(label, value)
  return ui.column({
    gap = 2,
    paddingH = 9,
    paddingV = 7,
    radius = 8,
    fill = "on_surface_variant/0.08",
    flexGrow = 1,
  }, {
    ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
    ui.label({ text = value, fontSize = 12, fontWeight = "bold", maxLines = 1 }),
  })
end

local function render()
  local running = data.state == "running"
  local up = running or data.state == "booting" or data.state == "preparing"

  local body = {
    ui.row({ gap = 9, align = "center" }, {
      ui.row({
        width = 38,
        height = 38,
        radius = 10,
        fill = statusColor() .. "/0.14",
        align = "center",
        justify = "center",
      }, {
        ui.glyph({ name = "brand-windows", size = 21, color = statusColor() }),
      }),
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.row({ gap = 6, align = "center" }, {
        ui.box({ width = 8, height = 8, radius = 4, fill = statusColor() }),
        ui.label({ text = statusText(), color = statusColor(), fontSize = 12, fontWeight = "bold" }),
      }),
    }),

    -- Sizing comes from the compose file, so these track the VM's real config.
    ui.row({ gap = 8, align = "stretch" }, {
      metric(noctalia.tr("metric.uptime"), uptimeText()),
      metric(noctalia.tr("metric.memory"), tostring(data.ram or "—")),
      metric(noctalia.tr("metric.cores"), tostring(data.cores or "—")),
    }),

    ui.label({
      text = noctalia.tr("detail.endpoints", {
        user = tostring(data.username or "—"),
        rdp = tostring(data.rdpPort or 3389),
        web = tostring(data.webPort or 8006),
      }),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
    }),
  }

  local message = data.controlError
  if message == nil or message == "" then message = data.error end
  if message ~= nil and message ~= "" then
    table.insert(body, ui.label({
      text = message,
      fontSize = 10,
      color = "#f38ba8",
      maxLines = 2,
    }))
  end

  table.insert(body, ui.row({ gap = 8, align = "center" }, {
    ui.button({
      key = "primary",
      text = data.pendingConnect and noctalia.tr("action.cancel") or noctalia.tr("action.connect"),
      glyph = data.pendingConnect and "x" or "device-desktop",
      variant = "primary",
      controlSize = "sm",
      flexGrow = 1,
      enabled = not data.busy and data.state ~= "error" and data.state ~= "loading",
      onClick = function()
        command("connect")
        -- Keep the panel open while a cold VM boots; there is progress to watch.
        if running then panel.close() end
      end,
    }),
    ui.button({
      key = "power",
      text = up and noctalia.tr("action.stop") or noctalia.tr("action.start"),
      glyph = up and "player-stop" or "player-play",
      variant = "filled",
      controlSize = "sm",
      flexGrow = 1,
      enabled = not data.busy and data.state ~= "loading",
      onClick = function() command(up and "stop" or "start") end,
    }),
    ui.button({
      key = "web",
      glyph = "world",
      glyphSize = 13,
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("action.web"),
      enabled = up,
      onClick = function() command("web") panel.close() end,
    }),
    ui.button({
      key = "refresh",
      glyph = "refresh",
      glyphSize = 13,
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("action.refresh"),
      onClick = function() command("refresh") end,
    }),
  }))

  panel.render(ui.column({ padding = 12, gap = 9, align = "stretch" }, body))
end

function onOpen(_context) command("refresh") render() end
function update() render() end
noctalia.state.watch("windows.data", function(value)
  if type(value) == "table" then data = value render() end
end)
render()
