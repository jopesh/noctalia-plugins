--!nonstrict
-- Today's piece plus two more. Pure view: every action is a command to the
-- service, which owns the state, so closing the panel stops nothing.
-- Browsing previews a piece; the wallpaper only changes when you set it.

local model = require("./model.luau")

local data = noctalia.state.get("boringday.data") or {}
-- The selection follows a piece, not a row: the list can change under it
-- (a refresh, a shuffled piece joining) without the cursor jumping.
local selectedId = nil
local lastCurrentId = nil
local render

local function pieces()
  return type(data.pieces) == "table" and data.pieces or {}
end

local function currentId()
  return data.current ~= nil and data.current.id or nil
end

local function selectedIndex()
  local list = pieces()
  for i, piece in ipairs(list) do
    if piece.id == selectedId then
      return i
    end
  end
  return #list > 0 and 1 or 0
end

local function selection()
  return pieces()[selectedIndex()]
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
  return piece ~= nil and currentId() == piece.id
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

local function pieceRow(piece, active)
  local mark = piece.isToday and noctalia.tr("today") or ""
  return ui.row({
    key = "piece:" .. piece.id,
    gap = 8, align = "center", paddingH = 8, paddingV = 6, radius = 8,
    fill = active and "primary/0.16" or "on_surface_variant/0.06",
    onClick = function() selectedId = piece.id render() end,
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

local function actions(piece)
  local busy = data.applying == true
  local applied = isApplied(piece)
  return ui.row({ gap = 6, align = "center" }, {
    ui.button({
      text = noctalia.tr(applied and "action.on_wall" or "action.set"),
      glyph = applied and "check" or "photo-check",
      variant = "primary", controlSize = "sm", flexGrow = 2,
      enabled = piece ~= nil and not busy and not applied,
      onClick = function() command("set", { id = piece.id }) end,
    }),
    ui.button({
      glyph = "arrows-shuffle", variant = "filled", controlSize = "sm", tooltip = noctalia.tr("action.shuffle"),
      enabled = data.shuffling ~= true, onClick = function() command("shuffle") end,
    }),
    ui.button({
      glyph = "download", variant = "outline", controlSize = "sm", tooltip = noctalia.tr("action.save"),
      enabled = piece ~= nil and data.saving ~= true, onClick = function() command("save", { id = piece.id }) end,
    }),
    ui.button({
      glyph = "external-link", variant = "outline", controlSize = "sm", tooltip = noctalia.tr("action.open"),
      enabled = piece ~= nil, onClick = function() command("open", { id = piece.id }) end,
    }),
    ui.button({
      glyph = "refresh", variant = "outline", controlSize = "sm", tooltip = noctalia.tr("action.refresh"),
      enabled = data.fetching ~= true, onClick = function() command("refresh") end,
    }),
  })
end

render = function()
  local list = pieces()
  local piece = selection()
  selectedId = piece and piece.id or nil
  local line, lineColor = heroLine()
  local rows = {}
  for _, p in ipairs(list) do
    table.insert(rows, pieceRow(p, p.id == selectedId))
  end
  if #rows == 0 then
    local empty = data.fetching and noctalia.tr("loading") or noctalia.tr("no_pieces")
    table.insert(rows, ui.label({ text = empty, color = "on_surface_variant", fontSize = 11 }))
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
    actions(piece),
  }

  panel.render(ui.scroll({ flexGrow = 1, padding = 12, gap = 10, align = "stretch" }, body))
end

local function step(delta)
  local list = pieces()
  if #list > 0 then
    local index = ((selectedIndex() - 1 + delta) % #list) + 1
    selectedId = list[index].id
    render()
  end
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  local piece = selection()
  if chord == "j" or chord == "Down" then
    step(1)
  elseif chord == "k" or chord == "Up" then
    step(-1)
  elseif chord == "Return" and piece and not isApplied(piece) then
    command("set", { id = piece.id })
  elseif chord == "t" then
    command("today")
  elseif chord == "s" then
    command("shuffle")
  elseif chord == "d" and piece then
    command("save", { id = piece.id })
  elseif chord == "o" and piece then
    command("open", { id = piece.id })
  elseif chord == "r" then
    command("refresh")
  end
end

-- Opening the panel lands on what is on the wall.
function onOpen(_context)
  data = noctalia.state.get("boringday.data") or data
  selectedId = currentId()
  lastCurrentId = selectedId
  render()
end

function onIpc(event, _payload)
  if event == "close" or event == "hide" then
    panel.close()
  end
end

-- When the wallpaper changes (a shuffle, the command line) the cursor
-- follows it, so the preview shows what just went up.
noctalia.state.watch("boringday.data", function(value)
  if type(value) == "table" then
    data = value
    local id = currentId()
    if id ~= lastCurrentId then
      lastCurrentId = id
      selectedId = id
    end
    render()
  end
end)

selectedId = currentId()
lastCurrentId = selectedId
render()
