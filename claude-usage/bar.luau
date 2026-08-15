--!nonstrict
-- Claude Usage bar widget — compact readout, opens the detail panel on click.
--
-- The service owns all fetching; this entry only formats. Countdowns are
-- rendered here rather than published as strings so they tick every second
-- without waking the network.

local data = noctalia.state.get("claude_usage.data") or { status = "loading", windows = {} }

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

-- Font for the bar text. Mirrors panel.luau's copy — plugin_api 9 has no shared
-- modules, so the two must be kept in step by hand. Resolved once per distinct
-- setting value rather than per render, since loadFont hits the filesystem.
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

-- Returns nil when there is no reset, matching panel.luau's copy of this
-- function so the two stay diffable; callers supply their own placeholder.
local function fmtCountdown(resetsAt)
  if type(resetsAt) ~= "number" then
    return nil
  end
  local remaining = resetsAt - os.time()
  if remaining <= 0 then
    return noctalia.tr("time.now")
  end
  local days = math.floor(remaining / 86400)
  local hours = math.floor(remaining % 86400 / 3600)
  local minutes = math.floor(remaining % 3600 / 60)
  if days > 0 then
    return string.format("%dd %dh", days, hours)
  end
  return string.format("%dh %02dm", hours, minutes)
end

local function windowById(id)
  for _, window in ipairs(data.windows or {}) do
    if window.id == id then
      return window
    end
  end
  return nil
end

local function highestWindow()
  local best = nil
  for _, window in ipairs(data.windows or {}) do
    if best == nil or (window.pct or 0) > (best.pct or 0) then
      best = window
    end
  end
  return best
end

local function sourceWindow()
  local mode = cfg("source_window", "session")
  if mode == "weekly" then
    return windowById("weekly") or windowById("session")
  end
  if mode == "highest" then
    return highestWindow()
  end
  return windowById("session") or highestWindow()
end

local function usageColor(value)
  if cfg("color_by_usage", true) == false then
    return "on_surface"
  end
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

-- Actual usage minus elapsed time in the window: positive means burning faster
-- than the window refills.
local function paceIndicator(window)
  if window == nil or type(window.resetsAt) ~= "number" or type(window.windowSecs) ~= "number" then
    return ""
  end
  local remaining = window.resetsAt - os.time()
  local elapsed = math.floor((window.windowSecs - remaining) * 100 / window.windowSecs)
  elapsed = math.clamp(elapsed, 0, 100)
  local delta = (window.pct or 0) - elapsed
  if delta > 0 then
    return "↑"
  elseif delta < 0 then
    return "↓"
  end
  return "→"
end

local function placeholders(source)
  local session = windowById("session")
  local weekly = windowById("weekly")
  return {
    pct = tostring(source ~= nil and source.pct or 0),
    reset = fmtCountdown(source ~= nil and source.resetsAt or nil) or "—",
    pace = paceIndicator(source),
    session = tostring(session ~= nil and session.pct or 0),
    session_reset = fmtCountdown(session ~= nil and session.resetsAt or nil) or "—",
    weekly = tostring(weekly ~= nil and weekly.pct or 0),
    weekly_reset = fmtCountdown(weekly ~= nil and weekly.resetsAt or nil) or "—",
    plan = data.plan or "",
    spend = data.spend ~= nil and data.spend.usedText or "",
  }
end

local function render()
  resolveFont()

  local children = {}

  -- A hard error with nothing to show is worth a warning capsule. A transient
  -- one isn't: it will clear itself, so fall through to the neutral 0% readout
  -- rather than crying wolf every time the network hiccups at login.
  local hardError = data.error ~= nil and not data.error.transient

  if hardError and (data.windows == nil or #data.windows == 0) then
    table.insert(children, ui.glyph({ name = "alert-triangle", size = 14, color = "error" }))
    table.insert(children, ui.label({ text = noctalia.tr("title"), fontFamily = fontFamily, color = "error" }))
  else
    local source = sourceWindow()
    local value = source ~= nil and source.pct or 0
    local color = usageColor(value)

    if cfg("show_glyph", true) ~= false then
      table.insert(children, ui.glyph({
        name = cfg("glyph", "sparkles"),
        size = 14,
        color = data.stale and "on_surface_variant" or color,
      }))
    end

    local subs = placeholders(source)
    -- %w excludes "_", which would leave {session_reset} unsubstituted.
    local text = tostring(cfg("format", "{session}% · {session_reset}")):gsub("{([%w_]+)}", function(key)
      return subs[key] or ""
    end)

    table.insert(children, ui.label({
      text = text,
      fontFamily = fontFamily,
      color = data.stale and "on_surface_variant" or "on_surface",
    }))

    -- Dimming alone reads as a theme quirk, not as "these numbers are old", so
    -- stale data also gets claudebar's ⏸ marker. The panel footer says how old.
    if data.stale then
      table.insert(children, ui.glyph({
        name = "player-pause",
        size = 12,
        color = cfg("color_warn", "#f9e2af"),
      }))
    end
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("johnschmidt/claude-usage:panel")
end

function onRightClick()
  noctalia.state.set("claude_usage.cmd", { op = "refresh" })
end

noctalia.state.watch("claude_usage.data", function(value)
  if type(value) == "table" then
    data = value
    render()
  end
end)

-- No hover tooltip: the panel is the detail view. Cleared once on load rather
-- than every tick, so a hot reload also drops a tooltip set by a previous build.
barWidget.clearTooltip()
noctalia.setUpdateInterval(1000)
render()
