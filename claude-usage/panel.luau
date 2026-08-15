--!nonstrict
-- Claude Usage panel — one section per limit window, plus extra-usage spend.
--
-- Bars are drawn as discrete cells rather than ui.progress so the pacing marker
-- can sit inside the track: it shows how far through the window you are, so a
-- fill left of the marker means you are under pace, right of it means ahead.

local BAR_CELLS = 16

local data = noctalia.state.get("claude_usage.data") or { status = "loading", windows = {} }

-- Presentation for each window the service publishes, keyed by its stable id.
-- Kept here rather than in the service so translated labels never reach the
-- disk cache, where they would outlive a language change.
local PRESENTATION = {
  session = { labelKey = "window.session", glyph = "hourglass" },
  weekly = { labelKey = "window.weekly", glyph = "calendar" },
}

local function windowLabel(id)
  local preset = PRESENTATION[id]
  if preset ~= nil then
    return noctalia.tr(preset.labelKey), preset.glyph
  end
  local model = tostring(id):match("^model:(.+)$")
  if model ~= nil then
    return noctalia.tr("window.model_only", { model = model }), "cpu"
  end
  return tostring(id), "chart-bar"
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

local function elapsedPct(window)
  if type(window.resetsAt) ~= "number" or type(window.windowSecs) ~= "number" or window.windowSecs <= 0 then
    return nil
  end
  local remaining = window.resetsAt - os.time()
  return math.clamp(math.floor((window.windowSecs - remaining) * 100 / window.windowSecs), 0, 100)
end

local function bar(value, color, markerPct)
  local filled = math.clamp(math.floor(value * BAR_CELLS / 100 + 0.5), 0, BAR_CELLS)
  local marker = nil
  if markerPct ~= nil then
    marker = math.clamp(math.floor(markerPct * BAR_CELLS / 100), 0, BAR_CELLS - 1)
  end

  local cells = {}
  for i = 1, BAR_CELLS do
    if marker ~= nil and i == marker + 1 then
      table.insert(cells, ui.box({
        key = "m" .. i,
        width = 2,
        height = 9,
        radius = 1,
        fill = "on_surface_variant",
      }))
    end
    table.insert(cells, ui.box({
      key = "c" .. i,
      flexGrow = 1,
      height = 9,
      radius = 2,
      fill = i <= filled and color or "on_surface_variant/0.22",
    }))
  end

  return ui.row({ gap = 2, align = "center", flexGrow = 1 }, cells)
end

local function windowSection(window)
  local value = window.pct or 0
  local color = usageColor(value)
  local elapsed = nil
  if cfg("show_pace_marker", true) ~= false then
    elapsed = elapsedPct(window)
  end

  local trailing = { label({ text = tostring(value) .. "%", fontWeight = "bold", color = color }) }
  if elapsed ~= nil then
    local delta = value - elapsed
    if delta > 0 then
      table.insert(trailing, label({ text = "↑", color = color, fontSize = 11 }))
    elseif delta < 0 then
      table.insert(trailing, label({ text = "↓", color = "on_surface_variant", fontSize = 11 }))
    end
  end

  local countdown = fmtCountdown(window.resetsAt)
  local title, glyph = windowLabel(window.id)

  return ui.column({ key = window.id, gap = 5, align = "stretch" }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = glyph, size = 13, color = "primary" }),
      label({ text = title, fontWeight = "bold", fontSize = 13, flexGrow = 1 }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      bar(value, color, elapsed),
      ui.row({ gap = 3, align = "center", minWidth = 46, justify = "end" }, trailing),
    }),
    ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = "clock", size = 11, color = "on_surface_variant" }),
      label({
        text = countdown ~= nil
          and noctalia.tr("window.resets_in", { time = countdown })
          or noctalia.tr("window.resets_unknown"),
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }),
  })
end

local function spendSection()
  local spend = data.spend
  if spend == nil then
    return nil
  end

  local value = spend.pct or 0
  local color = usageColor(value)

  local rows = {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "shopping-cart", size = 13, color = "primary" }),
      label({ text = noctalia.tr("extra.title"), fontWeight = "bold", fontSize = 13, flexGrow = 1 }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      bar(value, color, nil),
      label({ text = spend.usedText or "", fontWeight = "bold", color = color, minWidth = 46, textAlign = "end" }),
    }),
  }

  if spend.limitText ~= nil then
    table.insert(rows, ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = "wallet", size = 11, color = "on_surface_variant" }),
      label({
        text = noctalia.tr("extra.limit", { amount = spend.limitText }),
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }))
  end

  return ui.column({ key = "spend", gap = 5, align = "stretch" }, rows)
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
    label({ text = data.error.message or noctalia.tr("status.unknown"), fontSize = 11, color = "error", flexGrow = 1, maxLines = 2 }),
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
  local glyph = "clock"
  local color = "on_surface_variant"
  local text

  if fetchedAt == nil then
    text = noctalia.tr("footer.never")
  elseif data.stale then
    -- Say when the numbers are from and how old they are: a stale panel that
    -- only dims its text looks identical to a fresh one at a glance.
    glyph = "player-pause"
    color = cfg("color_warn", "#f9e2af")
    local age = relAge(os.time() - fetchedAt)
    local time = noctalia.formatTime("%H:%M", fetchedAt)
    -- "Waiting" while a request is still going unanswered, "Stale" once the
    -- reason is something you have to fix.
    local waiting = data.error ~= nil and data.error.transient
    local key = waiting and "footer.waiting" or "footer.stale"
    if age ~= nil then
      key ..= "_age"
    end
    text = noctalia.tr(key, { time = time, age = age })
  else
    text = noctalia.tr("footer.updated", { time = noctalia.formatTime("%H:%M", fetchedAt) })
  end

  return ui.row({ gap = 5, align = "center" }, {
    ui.glyph({ name = glyph, size = 11, color = color }),
    label({ text = text, fontSize = 11, color = color, flexGrow = 1 }),
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

local function render()
  resolveFont()

  local body = {}

  local banner = errorBanner()
  if banner ~= nil then
    table.insert(body, banner)
  end

  local windows = data.windows or {}
  if #windows == 0 and banner == nil then
    table.insert(body, label({
      text = noctalia.tr("status.loading"),
      color = "on_surface_variant",
      fontSize = 12,
    }))
  end

  for _, window in ipairs(windows) do
    table.insert(body, windowSection(window))
  end

  local spend = spendSection()
  if spend ~= nil then
    table.insert(body, ui.separator({ spacing = 2 }))
    table.insert(body, spend)
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
    label({
      text = data.plan or noctalia.tr("title"),
      fontSize = 14,
      fontWeight = "bold",
      color = "primary",
      textAlign = "center",
    }),
    ui.separator({ spacing = 2 }),
    ui.scroll({ flexGrow = 1, gap = 14, align = "stretch" }, body),
    ui.separator({ spacing = 2 }),
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
