--!nonstrict
-- Helpers shared by bar.luau and panel.luau.
--
-- This is the port of the normalization Panel.qml did inline: the collectors
-- report limits in two dialects ("Session (5-hour)" vs "5h window") and this
-- lands both on one record, so the meters and the bar icon speak a single
-- language. Nothing here talks to the host beyond noctalia.tr.

local M = {}

M.SECTION_KEYS = { day = "day", model = "model" }

function M.clamp(value, lo, hi)
  if value < lo then
    return lo
  end
  if value > hi then
    return hi
  end
  return value
end

function M.num(value)
  if type(value) == "number" then
    return value
  end
  return 0
end

function M.str(value)
  if type(value) == "string" then
    return value
  end
  return ""
end

-- ------------------------------------------------------------------- time

-- os.time() reads a table as *local* time; shift by the zone offset to get the
-- epoch for the same fields interpreted as UTC.
local function utcOffset(ts)
  local utc = os.date("!*t", ts)
  if type(utc) ~= "table" then
    return 0
  end
  utc.isdst = false
  local ok, localised = pcall(os.time, utc)
  if not ok or type(localised) ~= "number" then
    return 0
  end
  return ts - localised
end

-- "2026-08-16T15:09:59.686143+00:00" / "...Z" / "... " (assumed UTC) -> epoch
function M.parseIso(value)
  local text = M.str(value)
  if text == "" then
    return nil
  end
  local y, mo, d, h, mi, s = text:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)")
  if y == nil then
    return nil
  end
  local ok, epoch = pcall(os.time, {
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
    isdst = false,
  })
  if not ok or type(epoch) ~= "number" then
    return nil
  end
  epoch += utcOffset(epoch)

  -- Honour an explicit numeric offset; "Z" and a bare timestamp are already UTC.
  local sign, oh, om = text:match("([+-])(%d%d):?(%d%d)%s*$")
  if sign ~= nil then
    local offset = tonumber(oh) * 3600 + tonumber(om) * 60
    if sign == "+" then
      epoch -= offset
    else
      epoch += offset
    end
  end
  return epoch
end

-- Seconds until a window's reset, or nil when it has none / will not parse.
function M.resetSecondsFor(window)
  if window == nil or M.str(window.resetAt) == "" then
    return nil
  end
  local epoch = M.parseIso(window.resetAt)
  if epoch == nil then
    return nil
  end
  return epoch - os.time()
end

function M.formatDuration(seconds)
  if seconds == nil or seconds <= 0 then
    return noctalia.tr("time.now")
  end
  local minutes = math.floor(seconds / 60)
  local hours = math.floor(minutes / 60)
  local days = math.floor(hours / 24)
  if days > 0 then
    return string.format("%dd %dh", days, hours % 24)
  end
  if hours > 0 then
    return string.format("%dh %dm", hours, minutes % 60)
  end
  return string.format("%dm", math.max(1, minutes))
end

-- Local calendar date, so a panel left open across midnight moves its "Today"
-- row with the clock.
function M.todayDate()
  return noctalia.formatTime("%Y-%m-%d")
end

local DAY_KEYS = { "day.sun", "day.mon", "day.tue", "day.wed", "day.thu", "day.fri", "day.sat" }

function M.dayName(date)
  local epoch = M.parseIso(M.str(date) .. "T00:00:00")
  if epoch == nil then
    return M.str(date)
  end
  -- parseIso read the date as UTC; ask for the weekday in the same frame.
  local parts = os.date("!*t", epoch)
  if type(parts) ~= "table" then
    return M.str(date)
  end
  return noctalia.tr(DAY_KEYS[parts.wday] or "day.sun")
end

-- "Mon 8/16" — the long form the hover detail uses.
function M.dayStamp(date)
  local epoch = M.parseIso(M.str(date) .. "T00:00:00")
  if epoch == nil then
    return M.str(date)
  end
  local parts = os.date("!*t", epoch)
  if type(parts) ~= "table" then
    return M.str(date)
  end
  return string.format("%s %d/%d", M.dayName(date), parts.month, parts.day)
end

-- --------------------------------------------------------------- numbers

function M.formatTokenCount(value)
  local n = M.num(value)
  if n >= 1e9 then
    return string.format("%.1fB", n / 1e9)
  end
  if n >= 1e6 then
    return string.format("%.1fM", n / 1e6)
  end
  if n >= 1e3 then
    return string.format("%.1fK", n / 1e3)
  end
  return tostring(math.floor(n))
end

local CURRENCY_PREFIX = { USD = "$", EUR = "€", GBP = "£" }

function M.formatMoney(value, currency)
  local amount = M.num(value)
  local code = M.str(currency)
  if code == "" then
    code = "USD"
  end
  code = code:upper()
  local prefix = CURRENCY_PREFIX[code]
  if prefix == nil then
    prefix = code .. " "
  end
  return prefix .. string.format("%.2f", amount)
end

-- --------------------------------------------------------------- models

local function modelWordCase(word)
  if word == "gpt" then
    return "GPT"
  end
  if word == "deepseek" then
    return "DeepSeek"
  end
  return word:sub(1, 1):upper() .. word:sub(2)
end

-- Model ids arrive hyphenated with the version split across segments
-- (`claude-opus-4-8`, `gpt-5.6-sol`). Rejoin the numeric run into one version
-- and title-case the words around it.
function M.friendlyModelName(id)
  local name = M.str(id)
  if name == "" then
    return noctalia.tr("model.unknown")
  end
  name = name:gsub("^claude%-", ""):gsub("%-%d%d%d%d%d%d%d%d$", "")

  local words = {}
  local version = {}
  for part in name:gmatch("[^%-]+") do
    if part:match("^%d") ~= nil then
      table.insert(version, part)
    else
      if #version > 0 then
        table.insert(words, table.concat(version, "."))
        version = {}
      end
      table.insert(words, modelWordCase(part))
    end
  end
  if #version > 0 then
    table.insert(words, table.concat(version, "."))
  end
  if #words == 0 then
    return noctalia.tr("model.unknown")
  end
  return table.concat(words, " ")
end

-- ---------------------------------------------------------------- limits

local function windowIsLong(text)
  return text:find("week", 1, true) ~= nil
    or text:find("7-day", 1, true) ~= nil
    or text:find("seven", 1, true) ~= nil
    or text:find("month", 1, true) ~= nil
    or text:find("30-day", 1, true) ~= nil
end

-- Reads "5h", "5-hour", "30m", "30 minutes" out of a label. Lua has no \b, so
-- the unit is captured as a whole word and matched against its spellings —
-- which is what the JS word boundary was buying.
local function windowSpanSeconds(label)
  local text = M.str(label):lower()
  if text:find("month", 1, true) ~= nil or text:find("30-day", 1, true) ~= nil then
    return 30 * 24 * 3600
  end
  if windowIsLong(text) then
    return 7 * 24 * 3600
  end

  local minutes = nil
  for value, unit in text:gmatch("(%d+)%s*%-?%s*(%a+)") do
    if unit == "h" or unit:sub(1, 4) == "hour" then
      return tonumber(value) * 3600
    end
    if minutes == nil and (unit == "m" or unit:sub(1, 3) == "min") then
      minutes = tonumber(value) * 60
    end
  end
  return minutes or 0
end

local function windowTitle(label)
  local text = M.str(label):lower()
  if text:find("month", 1, true) ~= nil then
    return noctalia.tr("window.monthly")
  end
  if windowIsLong(text) then
    return noctalia.tr("window.weekly")
  end
  if text:find("session", 1, true) ~= nil or windowSpanSeconds(label) > 0 then
    return noctalia.tr("window.session")
  end
  local plain = noctalia.string.trim((M.str(label):gsub("%s*%b()%s*", "")))
  if plain == "" then
    return noctalia.tr("window.limit")
  end
  return plain
end

-- A collector that already knows which window a limit belongs to says so, and
-- that beats reading it back out of the label: a model-scoped limit is titled
-- after its model, and a name like "Opus 5 (1M context)" would parse as a
-- one-minute window.
function M.limitWindows(provider)
  if provider == nil then
    return {}
  end
  local out = {}
  for _, entry in ipairs(provider.limits or {}) do
    if type(entry) == "table" then
      local percent = tonumber(entry.percent)
      if percent ~= nil and percent >= 0 then
        local title = M.str(entry.title)
        if title == "" then
          title = windowTitle(entry.label)
        end
        table.insert(out, { title = title, percent = percent, resetAt = M.str(entry.resetsAt) })
      end
    end
  end
  return out
end

-- The window that decides how much room is left — the fullest one, since that
-- is what stops the next prompt.
function M.bindingWindow(provider)
  local best = nil
  for _, window in ipairs(M.limitWindows(provider)) do
    if best == nil or window.percent > best.percent then
      best = window
    end
  end
  return best
end

-- A prepaid account runs low the way a subscription window fills up: the last
-- 10% of the funded credits lights the same alarm.
function M.balanceAlarming(balance)
  return balance ~= nil
    and M.num(balance.funded) > 0
    and M.num(balance.remaining) / M.num(balance.funded) <= 0.1
end

function M.alarming(provider)
  if provider == nil then
    return false
  end
  local headline = M.bindingWindow(provider)
  if headline ~= nil and headline.percent >= 0.9 then
    return true
  end
  return M.balanceAlarming(provider.balance)
end

-- --------------------------------------------------------------- selection

function M.providerIndex(providers, selectedId)
  for index, provider in ipairs(providers) do
    if provider.providerId == selectedId then
      return index
    end
  end
  return 1
end

function M.selectedProvider(providers, selectedId)
  if #providers == 0 then
    return nil
  end
  return providers[M.providerIndex(providers, selectedId)]
end

-- Marks resolve by convention, so a new agent's record needs nothing from the
-- renderers: assets/<id>.svg if it ships one, the bar glyph if it does not.
-- Agents that ship a white mark carry an `assets/<id>-light.svg` twin for light
-- surfaces; marks that work on both (Claude's brand orange) ship one file.
function M.iconPath(providerId)
  local dir = noctalia.pluginDir()
  if dir == nil or M.str(providerId) == "" then
    return nil
  end
  local candidates = {}
  if not noctalia.isDarkMode() then
    table.insert(candidates, dir .. "/assets/" .. providerId .. "-light.svg")
  end
  table.insert(candidates, dir .. "/assets/" .. providerId .. ".svg")
  for _, path in ipairs(candidates) do
    if noctalia.fileExists(path) then
      return path
    end
  end
  return nil
end

return M
