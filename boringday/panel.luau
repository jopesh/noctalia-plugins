--!nonstrict
-- Today's piece plus two more. Pure view: every action is a command to the
-- service, which owns the state, so closing the panel stops nothing.
-- Browsing previews a piece; the wallpaper only changes when you set it.

local model = require("./model.luau")

local data = noctalia.state.get("boringday.data") or {}
local selected = 1

local function pieces()
  return type(data.pieces) == "table" and data.pieces or {}
end

local function current()
  return pieces()[selected]
end

local function command(op, extra)
  local payload = extra or {}
  payload.op = op
  noctalia.state.set("boringday.cmd", payload)
end

local function heroLine()
  if data.lastError ~= nil and data.lastError ~= "" then
    return data.lastError, "error"
  end
  if data.status ~= nil and data.status ~= "" then
    return data.status, "primary"
  end
  return noctalia.tr("tagline"), "on_surface_variant"
end

local function isApplied(piece)
  return data.current ~= nil and piece ~= nil and data.current.id == piece.id
end

local function preview(piece)
  local path = piece ~= nil and type(data.thumbs) == "table" and data.thumbs[piece.id] or nil
  if path ~= nil then
    return ui.image({ key = "preview", path = path, width = 356, height = 200, radius = 8, fit = "cover" })
  end
  return ui.row({
    width = 356, height = 200, radius = 8, fill = "on_surface_variant/0.10",
    align = "center", justify = "center",
  }, {
    ui.glyph({ name = "photo", size = 32, color = "on_surface_variant" }),
  })
end

local function pieceRow(index, piece)
  local active = index == selected
  local mark = piece.isToday and noctalia.tr("today") or ""
  return ui.row({
    key = "piece:" .. piece.id,
    gap = 8, align = "center", paddingH = 8, paddingV = 6, radius = 8,
    fill = active and "primary/0.16" or "on_surface_variant/0.06",
    onClick = function() selected = index render() end,
  }, {
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = piece.name, fontSize = 12, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = model.credit(piece), fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.label({ text = mark, fontSize = 10, color = "primary", fontWeight = "bold" }),
    isApplied(piece) and ui.glyph({ name = "check", size = 14, color = "primary" })
      or ui.spacer({ width = 14 }),
  })
end

local function rotation()
  local chips = {}
  local active = model.intervalIndex(data.intervalSeconds or 3600)
  for i, seconds in ipairs(model.INTERVALS) do
    table.insert(chips, ui.button({
      key = "interval:" .. seconds,
      text = (seconds // 3600) .. "h",
      variant = "ghost",
      controlSize = "sm",
      selected = active == i - 1,
      flexGrow = 1,
      enabled = data.autoRotate == true,
      tooltip = noctalia.tr("rotation.every", { period = model.everyLabel(seconds) }),
      onClick = function() command("interval", { seconds = seconds }) end,
    }))
  end
  return ui.column({ gap = 6 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("rotation.label"), fontSize = 12, flexGrow = 1 }),
      ui.toggle({
        checked = data.autoRotate == true,
        onChange = function(value) command("auto", { value = value }) end,
      }),
    }),
    ui.row({ gap = 4, align = "center", padding = 3, radius = 8, fill = "on_surface_variant/0.10" }, chips),
  })
end

local function render()
  local list = pieces()
  if selected > #list then
    selected = math.max(1, #list)
  end
  local piece = current()
  local line, lineColor = heroLine()
  local rows = {}
  for i, p in ipairs(list) do
    table.insert(rows, pieceRow(i, p))
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("no_pieces"), color = "on_surface_variant", fontSize = 11 }))
  end

  local tags = {}
  for _, tag in ipairs(model.tags(piece)) do
    table.insert(tags, ui.label({ text = tag, fontSize = 10, color = "on_surface_variant" }))
  end

  local body = {
    ui.row({ gap = 9, align = "center" }, {
      ui.glyph({ name = "photo", size = 20, color = "primary" }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("title"), fontSize = 15, fontWeight = "bold" }),
        ui.label({ text = line, fontSize = 10, color = lineColor, maxLines = 1 }),
      }),
    }),
    preview(piece),
    ui.column({ gap = 2 }, {
      ui.label({ text = piece and piece.name or "", fontSize = 14, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = model.credit(piece), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
      ui.row({ gap = 10 }, tags),
      ui.label({
        text = piece and piece.description or "",
        fontSize = 10, color = "on_surface_variant", maxLines = 3,
      }),
    }),
    ui.column({ gap = 4 }, rows),
    ui.row({ gap = 6, align = "center" }, {
      ui.button({
        text = noctalia.tr("action.set"), glyph = "photo-check", variant = "primary", controlSize = "sm",
        flexGrow = 2, enabled = piece ~= nil and data.applying ~= true,
        onClick = function() command("set", { id = piece.id }) end,
      }),
      ui.button({
        glyph = "arrows-shuffle", variant = "filled", controlSize = "sm", tooltip = noctalia.tr("action.shuffle"),
        enabled = data.applying ~= true, onClick = function() command("shuffle") end,
      }),
      ui.button({
        glyph = "download", variant = "outline", controlSize = "sm", tooltip = noctalia.tr("action.save"),
        enabled = piece ~= nil, onClick = function() command("save", { id = piece.id }) end,
      }),
      ui.button({
        glyph = "external-link", variant = "outline", controlSize = "sm", tooltip = noctalia.tr("action.open"),
        enabled = piece ~= nil, onClick = function() command("open", { id = piece.id }) end,
      }),
      ui.button({
        glyph = "refresh", variant = "outline", controlSize = "sm", tooltip = noctalia.tr("action.refresh"),
        onClick = function() command("refresh") end,
      }),
    }),
    rotation(),
  }

  panel.render(ui.scroll({ flexGrow = 1, padding = 12, gap = 10, align = "stretch" }, body))
end

local function step(delta)
  local count = #pieces()
  if count > 0 then
    selected = ((selected - 1 + delta) % count) + 1
    render()
  end
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  local piece = current()
  if chord == "j" or chord == "Down" then
    step(1)
  elseif chord == "k" or chord == "Up" then
    step(-1)
  elseif chord == "Return" and piece then
    command("set", { id = piece.id })
  elseif chord == "s" then
    command("shuffle")
  elseif chord == "d" and piece then
    command("save", { id = piece.id })
  elseif chord == "o" and piece then
    command("open", { id = piece.id })
  elseif chord == "r" then
    command("refresh")
  elseif chord == "a" then
    command("auto")
  elseif chord == "i" then
    command("interval")
  end
end

function onOpen(_context)
  data = noctalia.state.get("boringday.data") or data
  selected = 1
  render()
end

function onIpc(event, _payload)
  if event == "close" or event == "hide" then
    panel.close()
  end
end

noctalia.state.watch("boringday.data", function(value)
  if type(value) == "table" then data = value render() end
end)

render()
