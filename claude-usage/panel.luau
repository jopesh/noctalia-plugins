--!nonstrict
-- Claude Usage panel — every limit window drawn on its own time axis.
--
-- The track IS the window: its left edge is when the window opened, its right
-- edge is the reset. Two lanes share that scale — how much you have USED, and
-- how much of the window has ELAPSED — so pacing is the gap between two
-- lengths rather than a tick you have to read against a fill. Dashes carry the
-- used lane on to where this rate lands it by reset, and a 2px marker is now.
--
-- Nothing here stacks: the ui tree has no absolute positioning, so a lane is a
-- row of boxes sized by flexGrow with the marker inserted at the split — the
-- same technique the old 16-cell bar used, minus the cells.
--
-- Per-model windows share the weekly window, so they share its axis: they are
-- lanes inside the weekly card rather than sections of their own.

local LANE_H = 12 -- used lanes
local GHOST_H = 6 -- the elapsed lane under them
local LABEL_W = 44
local VALUE_W = 34
local LANE_R = 6 -- the rail is a pill; LANE_H / 2
local SEG_R = 4 -- segments sit inside it, so they round a little less
local DASH_H = 4 -- a dash is a lighter weight than the fill, not a smaller one
local DASH_UNITS = 5 -- window-percent per dash + gap, at the panel's width
local MAX_DASHES = 14
local MIN_SPAN = 0.5 -- window-percent below which a segment is noise, not information
local MIN_DASH = 2 -- a lone stub dash reads as a tail on the fill, not as a projection

local data = noctalia.state.get("claude_usage.data") or { status = "loading", windows = {} }

-- Titles for the windows the service publishes, keyed by its stable id. Kept
-- here rather than in the service so translated labels never reach the disk
-- cache, where they would outlive a language change.
local TITLES = {
  session = "window.session",
  weekly = "window.weekly",
}

local function modelName(id)
  return tostring(id):match("^model:(.+)$")
end

local function windowTitle(id)
  local key = TITLES[id]
  if key ~= nil then
    return noctalia.tr(key)
  end
  local model = modelName(id)
  if model ~= nil then
    return noctalia.tr("window.model_only", { model = model })
  end
  return tostring(id)
end

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

-- Font for every text node in the panel. The setting takes either an installed
-- family name ("JetBrainsMono NFM") or a path to a font file, which has to be
-- registered with loadFont first. Resolved once per distinct setting value
-- rather than per render, since loadFont hits the filesystem.
local fontFamily = nil
local fontSource = nil

local function resolveFont()
  local raw = cfg("font_family", "")
  if type(raw) ~= "string" then
    raw = ""
  end
  raw = noctalia.string.trim(raw)
  if raw == fontSource then
    return
  end

  fontSource = raw
  if raw == "" then
    fontFamily = nil -- inherit the shell font
  elseif raw:find("/") ~= nil then
    local family, err = noctalia.loadFont(raw)
    fontFamily = family
    if family == nil then
      noctalia.log("claude-usage: could not load font " .. raw .. ": " .. (err or "unknown error"))
    end
  else
    fontFamily = raw
  end
end

-- ui.label with the configured font applied. Props are inline literals at every
-- call site, so mutating them here is safe.
local function label(props)
  props.fontFamily = fontFamily
  return ui.label(props)
end

-- ── numbers and time ────────────────────────────────────────────────────────

local function fmtDuration(seconds)
  if seconds < 0 then
    seconds = 0
  end
  local days = math.floor(seconds / 86400)
  local hours = math.floor(seconds % 86400 / 3600)
  local minutes = math.floor(seconds % 3600 / 60)
  if days > 0 then
    return string.format("%dd %dh", days, hours)
  end
  if hours > 0 then
    return string.format("%dh %02dm", hours, minutes)
  end
  return string.format("%dm", minutes)
end

-- A clock time for today, a weekday and a clock time for anything further out.
local function fmtWhen(timestamp)
  if noctalia.formatTime("%j", timestamp) == noctalia.formatTime("%j", os.time()) then
    return noctalia.formatTime("%H:%M", timestamp)
  end
  return noctalia.formatTime("%a %H:%M", timestamp)
end

local function usageColor(value)
  local warn = tonumber(cfg("warn_threshold", 70)) or 70
  local critical = tonumber(cfg("critical_threshold", 90)) or 90
  if value >= critical then
    return cfg("color_critical", "#f38ba8")
  end
  if value >= warn then
    return cfg("color_warn", "#f9e2af")
  end
  return cfg("color_ok", "#a6e3a1")
end

-- Stale numbers lose their colour, the way the bar widget dims its text: a red
-- 91% that was true fourteen hours ago is worse than no colour at all.
local function laneColor(value)
  if data.stale then
    return "on_surface_variant"
  end
  return usageColor(value)
end

local function pacingOn()
  return cfg("show_pace_marker", true) ~= false
end

local function hasWindow(window)
  return type(window.resetsAt) == "number"
    and type(window.windowSecs) == "number"
    and window.windowSecs > 0
end

local function elapsedPct(window)
  if not hasWindow(window) then
    return nil
  end
  local remaining = window.resetsAt - os.time()
  return math.clamp(math.floor((window.windowSecs - remaining) * 100 / window.windowSecs), 0, 100)
end

-- Where the used lane lands by the reset if this rate holds.
local function projection(used, elapsed)
  if elapsed == nil or elapsed <= 0 then
    return nil
  end
  return math.clamp(used * 100 / elapsed, used, 100)
end

-- When the lane reaches 100%, or nil when this rate never gets it there before
-- the window resets. Projections off stale numbers would be fiction, so they
-- are suppressed along with the colours.
local function emptyAt(window, used, elapsed)
  if data.stale or elapsed == nil or elapsed <= 0 or used <= elapsed or not hasWindow(window) then
    return nil
  end
  return window.resetsAt - window.windowSecs + window.windowSecs * elapsed / used
end

-- ── lanes ───────────────────────────────────────────────────────────────────

-- The projection, as dashes rather than a fill: there is no dash pattern in the
-- tree, so it is a nested row whose dash count follows the span.
local function dashes(span, color, key)
  local count = math.clamp(math.floor(span / DASH_UNITS + 0.5), 1, MAX_DASHES)
  local boxes = {}
  for i = 1, count do
    table.insert(boxes, ui.box({
      key = "d" .. i,
      flexGrow = 1,
      height = DASH_H,
      radius = 2,
      fill = color,
    }))
  end
  return ui.row({ key = key, gap = 3, align = "center", flexGrow = span }, boxes)
end

-- Used, projected and remaining as ordered segments, with the now marker cut in
-- wherever the elapsed share falls — inside the fill when you are ahead of
-- pace, inside the dashes when you are behind it.
local function laneTrack(used, elapsed, projected, color, height)
  local top = math.max(used, projected or used)
  local stops = {
    { 0, used, "fill" },
    { used, top, "dash" },
    { top, 100, "rest" },
  }

  local nodes = {}
  local marked = elapsed == nil
  local index = 0

  for _, stop in ipairs(stops) do
    local from, to, kind = stop[1], stop[2], stop[3]
    local cuts = { { from, to } }
    if not marked and elapsed >= from and elapsed <= to then
      cuts = { { from, elapsed }, { elapsed, to } }
    end

    for position, cut in ipairs(cuts) do
      local span = cut[2] - cut[1]
      if span > (kind == "dash" and MIN_DASH or MIN_SPAN) then
        index += 1
        if kind == "dash" then
          table.insert(nodes, dashes(span, color, "s" .. index))
        else
          table.insert(nodes, ui.box({
            key = "s" .. index,
            flexGrow = span,
            height = height,
            radius = SEG_R,
            fill = kind == "fill" and color or "on_surface_variant/0.22",
          }))
        end
      end
      if position == 1 and #cuts == 2 then
        marked = true
        index += 1
        table.insert(nodes, ui.box({
          key = "s" .. index,
          width = 2,
          height = height,
          radius = 1,
          fill = "on_surface",
        }))
      end
    end
  end

  return ui.row({
    gap = 0,
    align = "center",
    flexGrow = 1,
    height = height,
    radius = LANE_R,
    fill = "on_surface_variant/0.22",
  }, nodes)
end

-- The elapsed lane needs no marker: its own right edge is now.
local function elapsedTrack(elapsed)
  local nodes = {
    ui.box({
      key = "e1",
      flexGrow = math.max(elapsed, 0.05),
      height = GHOST_H,
      radius = GHOST_H / 2,
      fill = "on_surface_variant/0.45",
    }),
  }
  if elapsed < 100 then
    table.insert(nodes, ui.box({
      key = "e2",
      flexGrow = 100 - elapsed,
      height = GHOST_H,
      radius = GHOST_H / 2,
      fill = "on_surface_variant/0.22",
    }))
  end
  return ui.row({
    gap = 0,
    align = "center",
    flexGrow = 1,
    height = GHOST_H,
    radius = GHOST_H / 2,
    fill = "on_surface_variant/0.22",
  }, nodes)
end

-- The two text columns are fixed-width ROWS, not fixed-width labels: minWidth
-- is a container prop, and a label sizes to its text whatever you pass it. Sized
-- here so every track in the panel starts and ends on the same two x positions,
-- whether its label reads "All" or "Elapsed".
local function column(width, justify, child)
  return ui.row({ minWidth = width, maxWidth = width, align = "center", justify = justify }, { child })
end

local function laneRow(key, name, track, valueText, valueColor)
  return ui.row({ key = key, gap = 8, align = "center" }, {
    column(LABEL_W, "start", label({
      text = name,
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
    })),
    track,
    column(VALUE_W, "end", label({
      text = valueText,
      fontSize = 11,
      fontWeight = "bold",
      color = valueColor,
    })),
  })
end

local function usedLane(key, name, window, elapsed)
  local used = window.pct or 0
  local color = laneColor(used)
  local projected = elapsed ~= nil and projection(used, elapsed) or nil
  return laneRow(key, name, laneTrack(used, elapsed, projected, color, LANE_H), tostring(used) .. "%", color)
end

local function elapsedLane(elapsed)
  return laneRow(
    "elapsed",
    noctalia.tr("lane.elapsed"),
    elapsedTrack(elapsed),
    tostring(elapsed) .. "%",
    "on_surface_variant"
  )
end

-- The axis labels: how far into the window you are, and when it resets.
local function scaleRow(window)
  if not hasWindow(window) then
    return nil
  end
  local remaining = math.max(0, window.resetsAt - os.time())
  return ui.row({ key = "scale", gap = 8, align = "center" }, {
    column(LABEL_W, "start", label({ text = "" })),
    label({
      text = noctalia.tr("window.elapsed_in", { time = fmtDuration(window.windowSecs - remaining) }),
      fontSize = 9,
      color = "on_surface_variant",
      flexGrow = 1,
      textAlign = "start",
      maxLines = 1,
    }),
    label({
      text = noctalia.tr("window.resets_at", { time = fmtWhen(window.resetsAt) }),
      fontSize = 9,
      color = "on_surface_variant",
      textAlign = "end",
      maxLines = 1,
    }),
    column(VALUE_W, "end", label({ text = "" })),
  })
end

-- ── blocks ──────────────────────────────────────────────────────────────────

local function remainingText(window)
  if type(window.resetsAt) ~= "number" then
    return noctalia.tr("window.resets_unknown")
  end
  local remaining = window.resetsAt - os.time()
  if remaining <= 0 then
    return noctalia.tr("time.now")
  end
  return noctalia.tr("window.left", { time = fmtDuration(remaining) })
end

local function block(key, title, rightText, lanes, verdict)
  local rows = {
    ui.row({ gap = 6, align = "center" }, {
      label({ text = title, fontSize = 12, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      label({ text = rightText, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.column({
      key = "card",
      gap = 6,
      align = "stretch",
      padding = 10,
      radius = 8,
      fill = "on_surface_variant/0.10",
    }, lanes),
  }

  if verdict ~= nil then
    table.insert(rows, ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = "trending-up", size = 11, color = verdict.color }),
      label({ text = verdict.text, fontSize = 11, color = verdict.color, flexGrow = 1, maxLines = 2 }),
    }))
  end

  return ui.column({ key = key, gap = 5, align = "stretch" }, rows)
end

-- One window, one card: the used lane, the elapsed lane under it, the axis.
local function windowBlock(window)
  local elapsed = pacingOn() and elapsedPct(window) or nil
  local lanes = { usedLane("used", noctalia.tr("lane.used"), window, elapsed) }
  if elapsed ~= nil then
    table.insert(lanes, elapsedLane(elapsed))
  end

  local scale = scaleRow(window)
  if scale ~= nil then
    table.insert(lanes, scale)
  end

  local verdict = nil
  local at = emptyAt(window, window.pct or 0, elapsed)
  if at ~= nil then
    verdict = {
      text = noctalia.tr("verdict.empty_by", { time = fmtWhen(at) }),
      color = usageColor(window.pct or 0),
    }
  end

  return block(tostring(window.id), windowTitle(window.id), remainingText(window), lanes, verdict)
end

-- The weekly window and every per-model window share one axis: same length,
-- same reset, same elapsed share. The verdict names whichever lane runs out
-- first, since that is the one that will stop you.
local function weeklyBlock(weekly, models)
  local base = weekly or models[1]
  local elapsed = pacingOn() and elapsedPct(base) or nil
  local lanes = {}
  local soonest = nil

  local function consider(name, window, isTotal)
    local at = emptyAt(window, window.pct or 0, elapsed)
    if at ~= nil and (soonest == nil or at < soonest.at) then
      soonest = { at = at, name = name, used = window.pct or 0, isTotal = isTotal }
    end
  end

  if weekly ~= nil then
    table.insert(lanes, usedLane("all", noctalia.tr("lane.all"), weekly, elapsed))
    consider(noctalia.tr("lane.all"), weekly, true)
  end

  for index, window in ipairs(models) do
    local name = modelName(window.id) or tostring(window.id)
    table.insert(lanes, usedLane("m" .. index, name, window, elapsed))
    consider(name, window, false)
  end

  if elapsed ~= nil then
    table.insert(lanes, elapsedLane(elapsed))
  end

  local scale = scaleRow(base)
  if scale ~= nil then
    table.insert(lanes, scale)
  end

  local verdict = nil
  if soonest ~= nil then
    local key = soonest.isTotal and "verdict.empty_by" or "verdict.lane_empty_by"
    verdict = {
      text = noctalia.tr(key, { lane = soonest.name, time = fmtWhen(soonest.at) }),
      color = usageColor(soonest.used),
    }
  end

  return block("weekly", noctalia.tr("window.weekly"), remainingText(base), lanes, verdict)
end

-- Spend has no window behind it, so it gets a lane and no axis.
local function spendBlock()
  local spend = data.spend
  if spend == nil then
    return nil
  end

  local used = spend.pct or 0
  local color = laneColor(used)
  local rightText = spend.usedText or ""
  if spend.limitText ~= nil then
    rightText = noctalia.tr("extra.used_of", { used = rightText, limit = spend.limitText })
  end

  local lanes = {
    laneRow(
      "spend",
      noctalia.tr("lane.spend"),
      laneTrack(used, nil, nil, color, LANE_H),
      tostring(used) .. "%",
      color
    ),
  }

  return block("spend", noctalia.tr("extra.title"), rightText, lanes, nil)
end

-- Empty lanes in the right shape, so the panel doesn't jump when the first
-- payload lands. Only ever seen before the first fetch — after that there is
-- always a cached payload to show as stale.
local function skeletonBlock(key, laneCount)
  local lanes = {}
  for index = 1, laneCount do
    table.insert(lanes, ui.row({ key = "sk" .. index, gap = 8, align = "center" }, {
      column(LABEL_W, "start", ui.box({ width = 30, height = 9, radius = 4, fill = "on_surface_variant/0.22" })),
      ui.box({
        flexGrow = 1,
        height = index == laneCount and GHOST_H or LANE_H,
        radius = LANE_R,
        fill = "on_surface_variant/0.12",
      }),
      column(VALUE_W, "end", label({ text = "" })),
    }))
  end

  return ui.column({ key = key, gap = 5, align = "stretch" }, {
    ui.box({ width = 54, height = 10, radius = 5, fill = "on_surface_variant/0.22" }),
    ui.column({
      key = "card",
      gap = 6,
      align = "stretch",
      padding = 10,
      radius = 8,
      fill = "on_surface_variant/0.10",
    }, lanes),
  })
end

-- ── chrome ──────────────────────────────────────────────────────────────────

local function header()
  return ui.row({ gap = 7, align = "center" }, {
    ui.glyph({ name = "sparkles", size = 15, color = "primary" }),
    label({
      text = data.plan or noctalia.tr("title"),
      fontSize = 13,
      fontWeight = "bold",
      flexGrow = 1,
      maxLines = 1,
    }),
    ui.button({
      glyph = "refresh",
      glyphSize = 12,
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("ui.refresh"),
      onClick = function()
        noctalia.state.set("claude_usage.cmd", { op = "refresh" })
      end,
    }),
  })
end

-- Only states you can act on get the banner. A request that never got an answer
-- resolves itself, and says so in the footer instead.
local function errorBanner()
  if data.error == nil or data.error.transient then
    return nil
  end
  return ui.row({
    key = "error",
    gap = 6,
    align = "center",
    fill = "error/0.15",
    radius = 8,
    paddingH = 8,
    paddingV = 6,
  }, {
    ui.glyph({ name = "alert-triangle", size = 13, color = "error" }),
    label({
      text = data.error.message or noctalia.tr("status.unknown"),
      fontSize = 11,
      color = "error",
      flexGrow = 1,
      maxLines = 2,
    }),
  })
end

-- How old the displayed numbers are, in claudebar's wording. Negative ages
-- (clock skew) return nil and the caller drops the parenthetical.
local function relAge(seconds)
  if seconds < 0 then
    return nil
  end
  if seconds < 60 then
    return noctalia.tr("age.now")
  end
  if seconds < 3600 then
    return noctalia.tr("age.minutes", { count = tostring(math.floor(seconds / 60)) })
  end
  if seconds < 86400 then
    return noctalia.tr("age.hours", { count = tostring(math.floor(seconds / 3600)) })
  end
  return noctalia.tr("age.days", { count = tostring(math.floor(seconds / 86400)) })
end

local function footer()
  local fetchedAt = type(data.fetchedAt) == "number" and data.fetchedAt or nil

  if fetchedAt == nil then
    return ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "clock", size = 11, color = "on_surface_variant" }),
      label({ text = noctalia.tr("footer.never"), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    })
  end

  if data.stale then
    -- Say when the numbers are from and how old they are: a stale panel that
    -- only dims its text looks identical to a fresh one at a glance.
    local color = cfg("color_warn", "#f9e2af")
    local age = relAge(os.time() - fetchedAt)
    local time = noctalia.formatTime("%H:%M", fetchedAt)
    -- "Waiting" while a request is still going unanswered, "Stale" once the
    -- reason is something you have to fix.
    local waiting = data.error ~= nil and data.error.transient
    local key = waiting and "footer.waiting" or "footer.stale"
    if age ~= nil then
      key ..= "_age"
    end
    return ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "player-pause", size = 11, color = color }),
      label({ text = noctalia.tr(key, { time = time, age = age }), fontSize = 11, color = color, flexGrow = 1 }),
    })
  end

  return ui.row({ gap = 6, align = "center" }, {
    ui.box({ width = 5, height = 5, radius = 3, fill = cfg("color_ok", "#a6e3a1") }),
    label({
      text = noctalia.tr("footer.updated", { time = noctalia.formatTime("%H:%M", fetchedAt) }),
      fontSize = 11,
      color = "on_surface_variant",
      flexGrow = 1,
    }),
  })
end

-- ── render ──────────────────────────────────────────────────────────────────

-- Session stands alone; weekly and the per-model windows share one card;
-- anything the service grows later falls through to a card of its own.
local function blocks()
  local session, weekly, models, others = nil, nil, {}, {}

  for _, window in ipairs(data.windows or {}) do
    if window.id == "session" then
      session = window
    elseif window.id == "weekly" then
      weekly = window
    elseif modelName(window.id) ~= nil then
      table.insert(models, window)
    else
      table.insert(others, window)
    end
  end

  local out = {}
  if session ~= nil then
    table.insert(out, windowBlock(session))
  end
  if weekly ~= nil or #models > 0 then
    table.insert(out, weeklyBlock(weekly, models))
  end
  for _, window in ipairs(others) do
    table.insert(out, windowBlock(window))
  end

  local spend = spendBlock()
  if spend ~= nil then
    table.insert(out, spend)
  end

  return out
end

local function render()
  resolveFont()

  local body = {}

  local banner = errorBanner()
  if banner ~= nil then
    table.insert(body, banner)
  end

  local content = blocks()
  if #content == 0 and banner == nil then
    table.insert(body, skeletonBlock("skeleton-session", 2))
    table.insert(body, skeletonBlock("skeleton-weekly", 4))
  end
  for _, node in ipairs(content) do
    table.insert(body, node)
  end

  panel.render(ui.column({
    flexGrow = 1,
    gap = 10,
    padding = 12,
    align = "stretch",
    radius = 12,
    border = "primary/0.55",
    borderWidth = 1,
  }, {
    header(),
    ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, body),
    footer(),
  }))
end

function onOpen(_context)
  data = noctalia.state.get("claude_usage.data") or data
  panel.setWantsSecondTicks(true)
  render()
end

function update()
  render()
end

noctalia.state.watch("claude_usage.data", function(value)
  if type(value) == "table" then
    data = value
    render()
  end
end)
