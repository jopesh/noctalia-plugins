--!nonstrict
-- Agents panel — the port of omarchy's Panel.qml dashboard.
--
-- Strictly a display: everything it draws comes out of the usage records the
-- service publishes. Sections, in order:
--
--   Hero              the mark, the tool, and the plan it runs on
--   Subscription      one chip per enabled agent, only when there is a choice
--   Status            auth and endpoint problems, when a record reports one
--   Balance           prepaid agents report a credit ledger instead of limits
--   Limits            percentage used, a meter, and the reset countdown
--   Tokens by day     one row per day for the last week, today picked out
--   Tokens by model   tokens per model, scaled to the heaviest model
--
-- Upstream shows the per-row detail in a hover tooltip. Noctalia's panel tree
-- has no tooltip primitive outside buttons, so the same text lands in a detail
-- line under its section, revealed by the same hover.

local shared = require("./shared.luau")

local MAX_MODEL_ROWS = 4
local DAY_LABEL_WIDTH = 46
local MODEL_LABEL_WIDTH = 96
local VALUE_WIDTH = 54
local METER_HEIGHT = 6

local data = noctalia.state.get("agents.data") or { providers = {} }
local selected = noctalia.state.get("agents.selected") or ""

-- Which row the pointer is over, per section. Rendered as a detail line rather
-- than a tooltip, so both sections keep one at a time.
local hoveredDay = ""
local hoveredModel = ""

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function providers()
  return data.providers or {}
end

local function provider()
  return shared.selectedProvider(providers(), selected)
end

-- ------------------------------------------------------------------ pieces

-- The header doubles as the section's detail slot: hovering a row swaps the
-- title for that row's detail and swaps back on leave. Adding a line instead
-- would grow the scroll content, which pops the scrollbar in and out under the
-- pointer — so the one always-present line in the section carries it, and the
-- panel's height never moves.
local function sectionHeader(title, detail)
  local hovered = detail ~= nil and detail ~= ""
  return ui.label({
    text = hovered and detail or title,
    fontSize = 10,
    fontWeight = not hovered and "bold" or nil,
    color = "on_surface_variant",
    maxLines = 1,
  })
end

local function meter(value, alarming)
  return ui.progress({
    progress = shared.clamp(value, 0, 1),
    height = METER_HEIGHT,
    radius = METER_HEIGHT / 2,
    fill = alarming and "error" or "on_surface",
    track = "on_surface_variant/0.22",
  })
end

local function detailLine(text)
  return ui.label({
    text = text,
    fontSize = 11,
    color = "on_surface_variant",
    maxLines = 2,
    visible = text ~= "",
  })
end

-- ------------------------------------------------------------------- hero

-- The plan you pay for, under the name of the tool it pays for. Limits live in
-- their own section; the hero just says what this is.
local function heroMeta(current)
  if current == nil then
    return ""
  end
  if current.usageStatusText ~= "" then
    return current.usageStatusText
  end
  local tier = current.tierLabel or ""
  if tier == "" then
    return noctalia.tr("hero.subscription")
  end
  return tier:sub(1, 1):upper() .. tier:sub(2)
end

local function heroMark(current)
  local path = current ~= nil and shared.iconPath(current.providerId) or nil
  if path ~= nil then
    return ui.image({ path = path, width = 28, height = 28, fit = "contain" })
  end
  return ui.glyph({ name = cfg("glyph", "robot"), size = 26, color = "on_surface" })
end

local function hero(current)
  return ui.row({ key = "hero", gap = 10, align = "center" }, {
    heroMark(current),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({
        text = current.providerName,
        fontSize = 15,
        fontWeight = "bold",
        color = "on_surface",
        maxLines = 1,
      }),
      ui.label({ text = heroMeta(current), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
  })
end

-- --------------------------------------------------------- subscriptions

local function providerSwitch()
  local list = providers()
  if #list < 2 then
    return nil
  end
  local index = shared.providerIndex(list, selected)
  local chips = {}
  for i, entry in ipairs(list) do
    local providerId = entry.providerId
    table.insert(chips, ui.button({
      key = providerId,
      text = entry.providerName,
      fontSize = 11,
      controlSize = "sm",
      variant = "outline",
      selected = i == index,
      flexGrow = 1,
      -- onClick handlers take no arguments, so the chip's identity has to ride
      -- in a closure rather than in the node's key.
      onClick = function()
        noctalia.state.set("agents.selected", providerId)
      end,
    }))
  end
  return ui.row({ key = "switch", gap = 6, align = "center" }, chips)
end

-- ------------------------------------------------------------------ status

local function statusCard(current)
  if current.usageStatusText == "" or current.authHelpText == "" then
    return nil
  end
  return ui.row({
    key = "status",
    gap = 6,
    align = "center",
    fill = "error/0.10",
    border = "error/0.35",
    borderWidth = 1,
    radius = 8,
    paddingH = 10,
    paddingV = 8,
  }, {
    ui.glyph({ name = "alert-triangle", size = 13, color = "error" }),
    ui.label({
      text = current.authHelpText,
      fontSize = 11,
      color = "on_surface_variant",
      flexGrow = 1,
      maxLines = 3,
    }),
  })
end

-- ----------------------------------------------------------------- balance

local function balanceSection(current)
  local balance = current.balance
  if balance == nil then
    return nil
  end

  local alarming = shared.balanceAlarming(balance)
  local rows = {
    sectionHeader(noctalia.tr("section.balance")),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("balance.prepaid"), fontSize = 13, flexGrow = 1 }),
      ui.label({
        text = shared.formatMoney(balance.remaining, balance.currency),
        fontSize = 12,
        fontWeight = "bold",
        color = alarming and "error" or "on_surface",
      }),
    }),
  }

  -- The meter shows what is left, not what is used: a prepaid account drains
  -- toward empty rather than filling toward a cap.
  if balance.funded > 0 then
    table.insert(rows, meter(balance.remaining / balance.funded, alarming))
    local detail = noctalia.tr("balance.detail", {
      spent = shared.formatMoney(balance.spent, balance.currency),
      funded = shared.formatMoney(balance.funded, balance.currency),
    })
    if balance.estimated then
      detail ..= " · " .. noctalia.tr("balance.estimated")
    end
    table.insert(rows, detailLine(detail))
  end

  return ui.column({ key = "balance", gap = 8, align = "stretch" }, rows)
end

-- ------------------------------------------------------------------ limits

local function limitRow(window, index)
  local alarming = window.percent >= 0.9
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = window.title, fontSize = 13, flexGrow = 1, maxLines = 1 }),
      ui.label({
        text = tostring(math.floor(window.percent * 100 + 0.5)) .. "%",
        fontSize = 12,
        fontWeight = "bold",
        color = alarming and "error" or "on_surface",
      }),
    }),
    meter(window.percent, alarming),
  }

  local remaining = shared.resetSecondsFor(window)
  if remaining ~= nil and remaining > 0 then
    table.insert(rows, detailLine(noctalia.tr("limits.resets_in", { time = shared.formatDuration(remaining) })))
  end

  return ui.column({ key = "limit" .. tostring(index), gap = 5, align = "stretch" }, rows)
end

local function limitsSection(current)
  local windows = shared.limitWindows(current)
  if #windows == 0 then
    return nil
  end
  local rows = { sectionHeader(noctalia.tr("section.limits")) }
  for index, window in ipairs(windows) do
    table.insert(rows, limitRow(window, index))
  end
  return ui.column({ key = "limits", gap = 10, align = "stretch" }, rows)
end

-- --------------------------------------------------------------- by day

local function weekPeak(current)
  local peak = 0
  for _, day in ipairs(current.recentDays or {}) do
    peak = math.max(peak, shared.num(day.messageCount))
  end
  return math.max(1, peak)
end

local function dayDetail(current)
  if hoveredDay == "" then
    return ""
  end
  for _, day in ipairs(current.recentDays or {}) do
    if shared.str(day.date) == hoveredDay then
      local subst = {
        day = shared.dayStamp(day.date),
        tokens = shared.formatTokenCount(day.messageCount),
      }
      -- Prompt and session counts only exist for today, so they ride along here
      -- instead of taking a section of their own. Billing-API agents never count
      -- prompts, and "0 prompts" would read as a quiet day, not a gap.
      if hoveredDay == shared.todayDate() and current.hasPromptStats ~= false then
        subst.prompts = tostring(current.todayPrompts)
        subst.sessions = tostring(current.todaySessions)
        return noctalia.tr("day.detail_today", subst)
      end
      return noctalia.tr("day.detail", subst)
    end
  end
  return ""
end

local function daySection(current)
  local days = current.recentDays or {}
  if #days == 0 then
    return nil
  end

  local today = shared.todayDate()
  local peak = weekPeak(current)
  local rows = { sectionHeader(noctalia.tr("section.tokens_by_day"), dayDetail(current)) }

  for _, day in ipairs(days) do
    -- By date, not by position: the Claude stats-cache fallback can hand us a
    -- window that stops short of today.
    local date = shared.str(day.date)
    local isToday = date == today
    local tokens = shared.num(day.messageCount)
    table.insert(rows, ui.row({
      key = date,
      gap = 8,
      align = "center",
      onHover = "onDayHover",
    }, {
      ui.label({
        text = isToday and noctalia.tr("day.today") or shared.dayName(date),
        fontSize = 11,
        fontWeight = isToday and "bold" or nil,
        color = isToday and "on_surface" or "on_surface_variant",
        width = DAY_LABEL_WIDTH,
      }),
      ui.progress({
        progress = shared.clamp(tokens / peak, 0, 1),
        flexGrow = 1,
        height = METER_HEIGHT,
        radius = METER_HEIGHT / 2,
        fill = isToday and "on_surface" or "on_surface/0.55",
        track = "on_surface_variant/0.22",
      }),
      ui.label({
        text = shared.formatTokenCount(tokens),
        fontSize = 11,
        fontWeight = "bold",
        color = isToday and "on_surface" or "on_surface_variant",
        width = VALUE_WIDTH,
        textAlign = "end",
      }),
    }))
  end

  return ui.column({ key = "days", gap = 6, align = "stretch" }, rows)
end

-- -------------------------------------------------------------- by model

local function modelRows(current)
  local rows = {}
  for id, bucket in pairs(current.modelUsage or {}) do
    if type(bucket) == "table" then
      local input = shared.num(bucket.inputTokens)
      local output = shared.num(bucket.outputTokens)
      local cacheRead = shared.num(bucket.cacheReadInputTokens)
      local cacheWrite = shared.num(bucket.cacheCreationInputTokens)
      table.insert(rows, {
        id = tostring(id),
        name = shared.friendlyModelName(id),
        total = input + output + cacheRead + cacheWrite,
        input = input,
        output = output,
        cacheRead = cacheRead,
        cacheWrite = cacheWrite,
      })
    end
  end
  table.sort(rows, function(a, b)
    if a.total == b.total then
      return a.id < b.id
    end
    return a.total > b.total
  end)
  while #rows > MAX_MODEL_ROWS do
    table.remove(rows)
  end
  return rows
end

local function modelSection(current)
  local rows = modelRows(current)
  if #rows == 0 then
    return nil
  end

  local detail = ""
  for _, row in ipairs(rows) do
    if row.id == hoveredModel then
      detail = noctalia.tr("model.detail", {
        input = shared.formatTokenCount(row.input),
        output = shared.formatTokenCount(row.output),
        cacheRead = shared.formatTokenCount(row.cacheRead),
        cacheWrite = shared.formatTokenCount(row.cacheWrite),
      })
    end
  end

  -- Scaled to the heaviest model, so the top row is always full — the same
  -- scale-to-peak the weekly chart uses for its busiest day.
  local peak = math.max(1, rows[1].total)
  local children = { sectionHeader(noctalia.tr("section.tokens_by_model"), detail) }

  for _, row in ipairs(rows) do
    table.insert(children, ui.row({
      key = row.id,
      gap = 8,
      align = "center",
      onHover = "onModelHover",
    }, {
      ui.label({ text = row.name, fontSize = 12, width = MODEL_LABEL_WIDTH, maxLines = 1 }),
      ui.progress({
        progress = shared.clamp(row.total / peak, 0, 1),
        flexGrow = 1,
        height = METER_HEIGHT,
        radius = METER_HEIGHT / 2,
        fill = "on_surface/0.55",
        track = "on_surface_variant/0.22",
      }),
      ui.label({
        text = shared.formatTokenCount(row.total),
        fontSize = 11,
        fontWeight = "bold",
        color = "on_surface_variant",
        width = VALUE_WIDTH,
        textAlign = "end",
      }),
    }))
  end

  return ui.column({ key = "models", gap = 6, align = "stretch" }, children)
end

-- ------------------------------------------------------------------ footer

-- Only speaks up when the numbers cover more than this machine.
local function footer(current)
  local text = ""
  if shared.str(data.syncStatusText) ~= "" then
    text = data.syncStatusText
  elseif current ~= nil and current.syncEnabled and current.syncDeviceCount > 0 then
    text = noctalia.trp("sync.merged", current.syncDeviceCount)
  end
  return ui.label({
    text = text,
    fontSize = 11,
    color = "on_surface_variant",
    textAlign = "center",
    visible = text ~= "",
  })
end

-- ------------------------------------------------------------------ render

local function render()
  local current = provider()

  if current == nil then
    panel.render(ui.column({ flexGrow = 1, padding = 16, gap = 10, align = "center", justify = "center" }, {
      ui.glyph({ name = cfg("glyph", "robot"), size = 28, color = "on_surface_variant" }),
      ui.label({
        text = noctalia.tr("empty"),
        fontSize = 12,
        color = "on_surface_variant",
        textAlign = "center",
        maxLines = 3,
      }),
    }))
    return
  end

  local body = { hero(current) }

  local function push(node, separatorBefore)
    if node == nil then
      return
    end
    if separatorBefore then
      table.insert(body, ui.separator({ spacing = 2 }))
    end
    table.insert(body, node)
  end

  push(providerSwitch(), false)
  push(statusCard(current), false)

  -- Balance and limits share one separator: an agent reports a credit ledger or
  -- rate-limit windows, and the pair reads as one "what's left" block.
  local balance = balanceSection(current)
  local limits = limitsSection(current)
  push(balance, true)
  push(limits, balance == nil)

  push(daySection(current), true)
  push(modelSection(current), true)

  panel.render(ui.column({
    flexGrow = 1,
    gap = 10,
    padding = 12,
    align = "stretch",
  }, {
    ui.scroll({ flexGrow = 1, gap = 12, align = "stretch" }, body),
    footer(current),
  }))
end

-- --------------------------------------------------------------- handlers

function onDayHover(state, key)
  hoveredDay = state == "true" and tostring(key) or ""
  render()
end

function onModelHover(state, key)
  hoveredModel = state == "true" and tostring(key) or ""
  render()
end

local function selectStep(step)
  local list = providers()
  if #list == 0 then
    return
  end
  local index = shared.providerIndex(list, selected) - 1
  local wrapped = ((index + step) % #list + #list) % #list
  noctalia.state.set("agents.selected", list[wrapped + 1].providerId)
end

-- h / l switch subscription, r or Enter refresh. Escape stays with the host, so
-- a panel can never capture its own dismissal.
function onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "h" then
    selectStep(-1)
  elseif chord == "l" then
    selectStep(1)
  elseif chord == "r" or chord == "Return" then
    noctalia.state.set("agents.cmd", { op = "refresh" })
  end
end

function onOpen(_context)
  data = noctalia.state.get("agents.data") or data
  selected = noctalia.state.get("agents.selected") or selected
  hoveredDay = ""
  hoveredModel = ""
  noctalia.state.set("agents.panelOpen", true)
  -- Opening wants the numbers that go stale on the wire, not another walk over
  -- every transcript on disk.
  noctalia.state.set("agents.cmd", { op = "limits" })
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  noctalia.state.set("agents.panelOpen", false)
end

function onIpc(event, _payload)
  if event == "close" or event == "hide" then
    panel.close()
  end
end

-- Countdowns read the clock on every tick, so a panel that sits open keeps
-- telling the truth about when a window resets.
function update()
  render()
end

noctalia.state.watch("agents.data", function(value)
  if type(value) == "table" then
    data = value
    render()
  end
end)

noctalia.state.watch("agents.selected", function(value)
  if type(value) == "string" then
    selected = value
    hoveredDay = ""
    hoveredModel = ""
    render()
  end
end)
