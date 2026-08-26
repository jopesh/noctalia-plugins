--!nonstrict
local data = noctalia.state.get("winboat.data") or { status = "loading" }

local function statusText()
  if data.busy then
    return noctalia.tr(data.operation == "stop" and "action.stopping" or "action.starting")
  end
  return noctalia.tr("status." .. tostring(data.status or "error"))
end

local function statusColor()
  if data.busy then return "primary" end
  if data.status == "running" then return "#a6e3a1" end
  if data.status == "paused" or data.status == "restarting" then return "#f9e2af" end
  if data.status == "dead" or data.status == "error" or data.status == "unavailable" or data.status == "missing" then return "#f38ba8" end
  return "on_surface_variant"
end

local function command(op)
  noctalia.state.set("winboat.cmd", { op = op })
end

local function runtimeSelector()
  local buttons = {}
  for _, runtime in ipairs({ "docker", "podman" }) do
    local available = type(data.runtimeAvailability) == "table" and data.runtimeAvailability[runtime] == true
    table.insert(buttons, ui.button({
      key = runtime,
      text = runtime == "docker" and "Docker" or "Podman",
      variant = "ghost",
      controlSize = "sm",
      selected = data.runtime == runtime,
      flexGrow = 1,
      enabled = not data.busy and available,
      onClick = function()
        noctalia.state.set("winboat.cmd", { op = "set_runtime", runtime = runtime })
      end,
    }))
  end
  return ui.row({
    gap = 4,
    align = "center",
    padding = 3,
    radius = 8,
    fill = "on_surface_variant/0.10",
  }, buttons)
end

local function resourceCard(label, value, detail, progress)
  return ui.column({
    gap = 5,
    paddingH = 9,
    paddingV = 7,
    radius = 8,
    fill = "on_surface_variant/0.08",
    flexGrow = 1,
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = label, fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = value, fontSize = 11, fontWeight = "bold" }),
    }),
    ui.progress({
      progress = math.clamp((progress or 0) / 100, 0, 1),
      height = 4,
      radius = 2,
      fill = "primary",
      track = "on_surface_variant/0.18",
    }),
    ui.label({ text = detail, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
  })
end

local function render()
  local running = data.status == "running" or data.status == "restarting" or data.status == "paused"
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
    runtimeSelector(),
    ui.row({ gap = 8, align = "stretch" }, {
      resourceCard(
        noctalia.tr("resource.cpu"),
        data.cpuPercent ~= nil and string.format("%.1f%%", data.cpuPercent) or "—",
        data.cpuPercent ~= nil and noctalia.tr("resource.guest") or noctalia.tr("resource.waiting"),
        data.cpuPercent
      ),
      resourceCard(
        noctalia.tr("resource.memory"),
        data.memoryUsedMb ~= nil and string.format("%.1f GiB", data.memoryUsedMb / 1024) or "—",
        data.memoryPercent ~= nil and data.memoryTotalMb ~= nil
          and noctalia.tr("resource.memory_used", {
            percent = string.format("%.1f", data.memoryPercent),
            total = string.format("%.1f", data.memoryTotalMb / 1024),
          })
          or noctalia.tr("resource.waiting"),
        data.memoryPercent
      ),
    }),
  }

  table.insert(body, ui.row({ gap = 8, align = "center" }, {
    ui.button({
      text = noctalia.tr("action.open"),
      glyph = "device-desktop",
      variant = "primary",
      controlSize = "sm",
      flexGrow = 1,
      enabled = type(data.runtimeAvailability) == "table" and data.runtimeAvailability[data.runtime] == true,
      onClick = function()
        command("open")
        panel.close()
      end,
    }),
    ui.button({
      text = running and noctalia.tr("action.stop") or noctalia.tr("action.start"),
      glyph = running and "player-stop" or "player-play",
      variant = "filled",
      controlSize = "sm",
      flexGrow = 1,
      enabled = not data.busy,
      onClick = function() command(running and "stop" or "start") end,
    }),
    ui.button({
      text = noctalia.tr("action.refresh"),
      glyph = "refresh",
      variant = "outline",
      controlSize = "sm",
      flexGrow = 1,
      enabled = not data.busy,
      onClick = function() command("refresh") end,
    }),
  }))

  panel.render(ui.column({ padding = 12, gap = 9, align = "stretch" }, body))
end

function onOpen(_context) command("refresh") render() end
function update() render() end
noctalia.state.watch("winboat.data", function(value)
  if type(value) == "table" then data = value render() end
end)
render()
