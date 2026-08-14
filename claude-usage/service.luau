--!nonstrict
-- Claude Usage service — owns credentials, polling and parsing.
--
-- Publishes:  claude_usage.data = {
--   status, error, stale, plan, fetchedAt,
--   windows = { { id, pct, resetsAt, windowSecs }, ... },
--   spend   = { pct, usedText, limitText } | nil,
-- }
-- Commands:  claude_usage.cmd = { op = "refresh" }
-- IPC:       refresh
--
-- Windows carry no labels or glyphs: presentation is panel.luau's job, keyed off
-- the stable `id` ("session", "weekly", "model:<Name>"). Keeping translated text
-- out of here also keeps it out of the disk cache, which would otherwise pin the
-- old language until the next successful fetch. `spend` is the one exception —
-- its money strings are pre-formatted because both renderers need them and, at
-- plugin_api 9, there is no shared module to put the currency logic in.
--
-- Cache: pluginDataDir()/usage.json — last good payload, so the bar has
-- something to show immediately after a shell restart instead of an empty
-- capsule while the first request is in flight.

local CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" -- Claude CLI OAuth client
local USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
local TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
local OAUTH_BETA = "anthropic-beta: oauth-2025-04-20"

local CREDS = noctalia.expandPath("~/.claude/.credentials.json")
local REFRESH_BUFFER = 300 -- refresh the access token 5 min before it expires
local MIN_INTERVAL = 300 -- /usage rate-limits hard below this
local MAX_BACKOFF = 1800
local TICK_MS = 5000

local SESSION_WINDOW = 5 * 3600
local WEEKLY_WINDOW = 7 * 86400
local MAX_SCOPED = 4 -- a hostile payload must not grow the panel without bound

local MONEY_SYMBOLS = { USD = "$", EUR = "€", GBP = "£", JPY = "¥", CAD = "$", AUD = "$" }

local data = { status = "loading", stale = false, windows = {} }
local nextFetchAt = 0
local inFlight = false
local failures = 0
local warnedCredsWrite = false

-- ---------------------------------------------------------------- utilities

local function num(value)
  if type(value) == "number" then
    return value
  end
  return nil
end

local function str(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function pct(value)
  local n = num(value)
  if n == nil then
    return nil
  end
  n = math.floor(n + 0.5)
  if n < 0 then
    return 0
  end
  if n > 100000 then
    return 100
  end
  return n
end

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

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

-- "2026-08-14T21:40:00.020116+00:00" / "...Z" / "... " (assumed UTC) -> epoch
local function parseIso(value)
  local text = str(value)
  if text == nil then
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

local function fmtMoney(minor, currency, exponent)
  local value = math.floor(minor)
  local places = math.floor(exponent)
  if places < 0 or places > 6 then
    places = 2
  end

  local sign = ""
  if value < 0 then
    sign = "-"
    value = -value
  end

  local divisor = math.floor(10 ^ places)
  local body
  if places > 0 then
    body = string.format("%d.%0" .. places .. "d", math.floor(value / divisor), value % divisor)
  else
    body = tostring(value)
  end

  local symbol = MONEY_SYMBOLS[currency or ""]
  if symbol ~= nil then
    return sign .. symbol .. body
  end
  if currency ~= nil and currency ~= "" then
    return sign .. body .. " " .. currency
  end
  return sign .. body
end

-- ------------------------------------------------------------- state output

local function publish()
  noctalia.state.set("claude_usage.data", data)
end

local function setError(kind, message)
  data.status = "error"
  data.error = { kind = kind, message = message }
  -- Keep the last known windows around and flag them, so a transient network
  -- blip degrades to "stale numbers + a warning" rather than an empty panel.
  data.stale = #data.windows > 0
  publish()
end

-- ------------------------------------------------------------------- cache

local function cachePath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/usage.json"
end

local function saveCache()
  local path = cachePath()
  if path == nil then
    return
  end
  local encoded = noctalia.json.encode({
    plan = data.plan,
    fetchedAt = data.fetchedAt,
    windows = data.windows,
    spend = data.spend,
  })
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

local function loadCache()
  local path = cachePath()
  if path == nil then
    return
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" or type(decoded.windows) ~= "table" then
    return
  end
  data.plan = decoded.plan
  data.fetchedAt = decoded.fetchedAt
  data.windows = decoded.windows
  data.spend = decoded.spend
  data.stale = true
  publish()
end

-- ------------------------------------------------------------- credentials

local function readCreds()
  local raw = noctalia.readFile(CREDS)
  if raw == nil then
    return nil, "no_creds"
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" or type(decoded.claudeAiOauth) ~= "table" then
    return nil, "bad_creds"
  end
  return decoded, nil
end

-- Atomic, permission-preserving credential update: create the temp file, tighten
-- it to 0600 *before* the secrets land in it, then rename over the original. A
-- crash mid-write leaves the original untouched.
local function writeCreds(root, accessToken, refreshToken, expiresAt, done)
  root.claudeAiOauth.accessToken = accessToken
  root.claudeAiOauth.refreshToken = refreshToken
  root.claudeAiOauth.expiresAt = expiresAt

  local encoded = noctalia.json.encode(root)
  if encoded == nil or #encoded < 2 then
    done(false)
    return
  end

  local tmp = CREDS .. ".noctalia.tmp"
  noctalia.writeFile(tmp, "")
  noctalia.runAsync({ "chmod", "600", tmp }, function(result)
    if result == nil or result.exitCode ~= 0 then
      noctalia.removeFile(tmp)
      done(false)
      return
    end

    noctalia.writeFile(tmp, encoded)
    local info = noctalia.fileInfo(tmp)
    if info == nil or (num(info.size) or 0) < #encoded then
      -- Never rename a short write over a working login.
      noctalia.removeFile(tmp)
      done(false)
      return
    end

    noctalia.renameFile(tmp, CREDS)
    done(true)
  end)
end

local function refreshAccessToken(root, cb)
  if cfg("allow_token_refresh", true) == false then
    cb(nil, "token_expired")
    return
  end

  local refreshToken = str(root.claudeAiOauth.refreshToken)
  if refreshToken == nil then
    cb(nil, "no_refresh_token")
    return
  end

  local body = noctalia.json.encode({
    grant_type = "refresh_token",
    client_id = CLIENT_ID,
    refresh_token = refreshToken,
  })

  noctalia.http({
    url = TOKEN_URL,
    method = "POST",
    headers = {
      "Content-Type: application/json",
      OAUTH_BETA,
      "User-Agent: claude-cli/1.0",
    },
    body = body,
  }, function(res)
    if res == nil or not res.ok or res.status ~= 200 or str(res.body) == nil then
      cb(nil, "refresh_failed")
      return
    end

    local payload = noctalia.json.decode(res.body)
    if type(payload) ~= "table" or str(payload.access_token) == nil then
      cb(nil, "refresh_failed")
      return
    end

    local accessToken = payload.access_token
    local expiresIn = num(payload.expires_in) or 3600
    local expiresAt = math.floor(os.time() * 1000 + expiresIn * 1000)

    -- Re-read immediately before writing: Claude Code may have rewritten other
    -- fields since we loaded the file, and we only want to replace the token.
    local fresh = readCreds() or root
    writeCreds(fresh, accessToken, payload.refresh_token or refreshToken, expiresAt, function(written)
      if not written and not warnedCredsWrite then
        warnedCredsWrite = true
        noctalia.notifyError(
          noctalia.tr("title"),
          noctalia.tr("status.creds_write_failed")
        )
      end
      cb(accessToken, nil, fresh)
    end)
  end)
end

-- cb(accessToken, err, root) — hands back the decoded credentials it already
-- holds, so callers needing another field don't re-read the file.
local function withToken(cb)
  local root, err = readCreds()
  if root == nil then
    cb(nil, err)
    return
  end

  local accessToken = str(root.claudeAiOauth.accessToken)
  if accessToken == nil then
    cb(nil, "no_token")
    return
  end

  local expiresAt = num(root.claudeAiOauth.expiresAt) or 0
  local expiresSec = math.floor(expiresAt / 1000)
  if expiresSec > 0 and expiresSec < os.time() + REFRESH_BUFFER then
    refreshAccessToken(root, cb)
    return
  end

  cb(accessToken, nil, root)
end

local function planLabel(root)
  if root == nil then
    return nil
  end
  local subscription = str(root.claudeAiOauth.subscriptionType) or "unknown"
  local tier = str(root.claudeAiOauth.rateLimitTier) or ""
  local label = subscription:sub(1, 1):upper() .. subscription:sub(2)
  if tier:find("20x", 1, true) then
    label ..= " 20x"
  elseif tier:find("5x", 1, true) then
    label ..= " 5x"
  end
  return "Claude " .. label
end

-- ------------------------------------------------------------------ parsing

local function mkWindow(id, value, resetsAt, windowSecs)
  return { id = id, pct = value, resetsAt = resetsAt, windowSecs = windowSecs }
end

-- The at-most-one-of-each windows, in display order. `kind` is the modern
-- limits[] discriminator, `legacy` the older top-level field carrying the same
-- window. Adding an upstream window type is one row here.
local SINGLE_WINDOWS = {
  { kind = "session", legacy = "five_hour", id = "session", windowSecs = SESSION_WINDOW },
  { kind = "weekly_all", legacy = "seven_day", id = "weekly", windowSecs = WEEKLY_WINDOW },
}

-- Per-model weekly windows in the older shape, before limits[] carried them.
local LEGACY_SCOPED = {
  { field = "seven_day_opus", model = "Opus" },
  { field = "seven_day_sonnet", model = "Sonnet" },
}

local function legacyWindow(node, id, windowSecs)
  if type(node) ~= "table" then
    return nil
  end
  local value = pct(node.utilization)
  if value == nil then
    return nil
  end
  return mkWindow(id, value, parseIso(node.resets_at), windowSecs)
end

-- Newer payloads describe every window in limits[]; the five_hour/seven_day_*
-- fields are the older shape and stay as a fallback.
local function buildWindows(payload)
  local singles = {}
  local scoped = {}

  if type(payload.limits) == "table" then
    for _, limit in ipairs(payload.limits) do
      if type(limit) == "table" then
        local value = pct(limit.percent) or 0
        local resetsAt = parseIso(limit.resets_at)
        if limit.kind == "weekly_scoped" and #scoped < MAX_SCOPED then
          local model = nil
          if type(limit.scope) == "table" and type(limit.scope.model) == "table" then
            model = str(limit.scope.model.display_name)
          end
          if model ~= nil then
            table.insert(scoped, mkWindow("model:" .. model, value, resetsAt, WEEKLY_WINDOW))
          end
        else
          for _, desc in ipairs(SINGLE_WINDOWS) do
            if desc.kind == limit.kind and singles[desc.kind] == nil then
              singles[desc.kind] = mkWindow(desc.id, value, resetsAt, desc.windowSecs)
            end
          end
        end
      end
    end
  end

  local windows = {}
  local weekly = nil
  for _, desc in ipairs(SINGLE_WINDOWS) do
    local window = singles[desc.kind] or legacyWindow(payload[desc.legacy], desc.id, desc.windowSecs)
    if window ~= nil then
      table.insert(windows, window)
      if desc.id == "weekly" then
        weekly = window
      end
    end
  end

  if #scoped == 0 then
    for _, entry in ipairs(LEGACY_SCOPED) do
      local window = legacyWindow(payload[entry.field], "model:" .. entry.model, WEEKLY_WINDOW)
      if window ~= nil then
        table.insert(scoped, window)
      end
    end
  end

  for _, window in ipairs(scoped) do
    -- A scoped window usually omits its own reset; it shares the weekly one.
    if window.resetsAt == nil and weekly ~= nil then
      window.resetsAt = weekly.resetsAt
    end
    table.insert(windows, window)
  end

  return windows
end

-- Shown whenever there is real spend data. The API reports is_enabled = false
-- once credits run out while still reporting the spend, which is exactly the
-- moment you want to see it.
local function spendEntry(used, limit, currency, exponent, rawPercent)
  if used <= 0 and (limit == nil or limit <= 0) then
    return nil
  end
  local percent = pct(rawPercent)
  if percent == nil and limit ~= nil and limit > 0 then
    percent = pct(used / limit * 100)
  end
  return {
    pct = percent or 0,
    usedText = fmtMoney(used, currency, exponent),
    limitText = limit ~= nil and fmtMoney(limit, currency, exponent) or nil,
  }
end

-- The two payload shapes differ only in where the same five values live.
local function buildSpend(payload)
  local spend = payload.spend
  if type(spend) == "table" and type(spend.used) == "table" then
    local limit = nil
    if type(spend.limit) == "table" then
      limit = num(spend.limit.amount_minor)
    end
    return spendEntry(
      num(spend.used.amount_minor) or 0,
      limit,
      str(spend.used.currency),
      num(spend.used.exponent) or 2,
      spend.percent
    )
  end

  local extra = payload.extra_usage
  if type(extra) == "table" then
    return spendEntry(
      num(extra.used_credits) or 0,
      num(extra.monthly_limit),
      str(extra.currency),
      num(extra.decimal_places) or 2,
      extra.utilization
    )
  end

  return nil
end

-- ----------------------------------------------------------------- polling

local function interval()
  return math.max(MIN_INTERVAL, math.floor(num(cfg("refresh_interval", MIN_INTERVAL)) or MIN_INTERVAL))
end

local function scheduleNext(ok, retryAfter)
  local now = os.time()
  if ok then
    failures = 0
    nextFetchAt = now + interval()
    return
  end

  failures += 1
  local delay = interval() * math.min(2 ^ (failures - 1), 8)
  if retryAfter ~= nil then
    delay = math.max(delay, retryAfter)
  end
  nextFetchAt = now + math.min(delay, MAX_BACKOFF)
end

local function onUsageResponse(res, root)
  inFlight = false

  if res == nil or not res.ok then
    setError("network", noctalia.tr("status.offline"))
    scheduleNext(false)
    return
  end

  if res.status == 401 or res.status == 403 then
    setError("auth", noctalia.tr("status.unauthorized"))
    scheduleNext(false)
    return
  end

  if res.status == 429 then
    setError("rate_limited", noctalia.tr("status.rate_limited"))
    scheduleNext(false, 600)
    return
  end

  if res.status ~= 200 or str(res.body) == nil then
    setError("http", noctalia.tr("status.http_error", { status = tostring(res.status or 0) }))
    scheduleNext(false)
    return
  end

  local payload = noctalia.json.decode(res.body)
  if type(payload) ~= "table" then
    setError("parse", noctalia.tr("status.bad_payload"))
    scheduleNext(false)
    return
  end

  local windows = buildWindows(payload)
  if #windows == 0 then
    setError("parse", noctalia.tr("status.bad_payload"))
    scheduleNext(false)
    return
  end

  data.status = "ok"
  data.error = nil
  data.stale = false
  data.plan = planLabel(root) or data.plan
  data.fetchedAt = os.time()
  data.windows = windows
  data.spend = buildSpend(payload)
  publish()
  saveCache()
  scheduleNext(true)
end

local function fetch()
  if inFlight then
    return
  end
  inFlight = true

  withToken(function(token, err, root)
    if token == nil then
      inFlight = false
      setError(err or "auth", noctalia.tr("status." .. (err or "no_token")))
      scheduleNext(false)
      return
    end

    noctalia.http({
      url = USAGE_URL,
      method = "GET",
      headers = {
        "Authorization: Bearer " .. token,
        OAUTH_BETA,
        "Accept: application/json",
      },
    }, function(res)
      onUsageResponse(res, root)
    end)
  end)
end

local function forceRefresh()
  failures = 0
  nextFetchAt = 0
  fetch()
end

-- ---------------------------------------------------------------- lifecycle

function update()
  if inFlight or os.time() < nextFetchAt then
    return
  end
  fetch()
end

function onConfigChanged()
  forceRefresh()
end

function onIpc(event, _payload)
  if event == "refresh" then
    forceRefresh()
  end
end

noctalia.state.watch("claude_usage.cmd", function(value)
  if type(value) ~= "table" then
    return
  end
  if value.op == "refresh" then
    forceRefresh()
  end
  -- Clear the key so an identical next command still registers as a change.
  noctalia.state.set("claude_usage.cmd", nil)
end)

noctalia.setUpdateInterval(TICK_MS)
loadCache()
