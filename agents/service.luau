--!nonstrict
-- Agents service — the port of omarchy's Main.qml.
--
-- All extraction lives behind bin/agents-usage-update, which writes one JSON
-- record per agent into the usage directory; this entry only discovers those
-- records, watches them for changes, optionally merges snapshots synced from
-- other machines, and publishes the result.
--
-- Publishes:  agents.data = {
--   providers = { <displayProvider>, ... },   -- display order, id-sorted
--   syncStatusText = string,
--   revision = number,                        -- bumps on every republish
-- }
--             agents.selected = "<providerId>"
--
-- Commands:   agents.cmd = { op = "refresh" | "limits" | "next" }
-- IPC:        refresh | next
--
-- QML got file watching and subprocesses for free; here a 2s tick polls the
-- directory fingerprint (three small stat calls) and noctalia.runAsync owns the
-- collectors. Sync, which upstream drove through `mkdir` and a `bash -c` cat
-- loop because QML has no synchronous filesystem, is plain Luau here.

local RECORD_POLL_MS = 2000
local MIN_REFRESH_INTERVAL = 30
local DEFAULT_REFRESH_INTERVAL = 900
local LIMITS_RETRY_SECONDS = 30
local SYNC_DEBOUNCE_SECONDS = 1
local UPDATE_TIMEOUT_MS = 60000
local RECENT_DAYS = 7

local usageDir = nil
local updateBin = nil

local records = {} -- id -> record
local recordIds = {} -- sorted
local signature = "" -- directory fingerprint; a change means "reload"
local dataRevision = 0

local updateRunning = false
local pendingUpdateKind = ""
local nextRefreshAt = 0
local limitsRetryAt = 0
local retryAgentIds = {}

local aggregate = nil
local syncRevision = 0
local syncStatusText = ""
local syncDueAt = 0
local detectedHostname = ""

-- ---------------------------------------------------------------- settings

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function refreshInterval()
  local value = tonumber(cfg("refresh_interval", DEFAULT_REFRESH_INTERVAL)) or DEFAULT_REFRESH_INTERVAL
  return math.max(MIN_REFRESH_INTERVAL, math.floor(value))
end

-- Upstream nests `providers.<id>.enabled` under the widget's settings and
-- defaults every discovered agent to on. Noctalia settings do not nest, so the
-- equivalent that keeps "a new collector needs no plugin change" true is a list
-- of the ids to leave out.
local function disabledAgents()
  local list = cfg("disabled_agents", nil)
  local set = {}
  if type(list) == "table" then
    for _, id in ipairs(list) do
      if type(id) == "string" then
        set[noctalia.string.trim(id)] = true
      end
    end
  end
  return set
end

local function providerEnabled(id)
  return disabledAgents()[id] ~= true
end

local function trimmed(key)
  local value = cfg(key, "")
  if type(value) ~= "string" then
    return ""
  end
  return noctalia.string.trim(value)
end

local function syncConfigured()
  return cfg("sync_enabled", false) == true and trimmed("sync_dir") ~= ""
end

-- ------------------------------------------------------------------ paths

local function resolvePaths()
  if usageDir == nil then
    local stateHome = noctalia.getenv("NOCTALIA_AGENTS_USAGE_DIR")
    if stateHome ~= nil and stateHome ~= "" then
      usageDir = stateHome
    else
      local xdg = noctalia.getenv("XDG_STATE_HOME")
      if xdg == nil or xdg == "" then
        xdg = noctalia.expandPath("~/.local/state")
      end
      usageDir = xdg .. "/noctalia-agents/usage"
    end
  end
  if updateBin == nil then
    local dir = noctalia.pluginDir()
    if dir ~= nil then
      updateBin = dir .. "/bin/agents-usage-update"
    end
  end
end

-- ------------------------------------------------------------------ format

local function numberValue(value)
  local n = tonumber(value)
  if n == nil or n ~= n then
    return 0
  end
  return math.floor(n + 0.5)
end

local function emptyTokenBucket()
  return { inputTokens = 0, outputTokens = 0, cacheReadInputTokens = 0, cacheCreationInputTokens = 0 }
end

local function recentDateStrings()
  local now = os.time()
  local out = {}
  for offset = RECENT_DAYS - 1, 0, -1 do
    table.insert(out, noctalia.formatTime("%Y-%m-%d", now - offset * 86400))
  end
  return out
end

-- ---------------------------------------------------------------- discovery

local function readRecords()
  local names = noctalia.listDir(usageDir)
  if names == nil then
    return {}, {}
  end

  local ids = {}
  for _, name in ipairs(names) do
    local id = name:match("^(.+)%.json$")
    if id ~= nil and id:sub(1, 1) ~= "." then
      table.insert(ids, id)
    end
  end
  table.sort(ids)

  local loaded = {}
  for _, id in ipairs(ids) do
    local raw = noctalia.readFile(usageDir .. "/" .. id .. ".json")
    if raw ~= nil then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" then
        loaded[id] = decoded
      else
        noctalia.log("agents: ignoring bad usage record " .. id .. ".json")
      end
    end
  end
  return loaded, ids
end

-- Cheap enough to run on every tick: one listDir plus one stat per record. A
-- record that a collector rewrote lands within a tick, which is what the QML
-- FileView watch bought upstream.
local function directorySignature()
  local names = noctalia.listDir(usageDir)
  if names == nil then
    return ""
  end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    if name:match("%.json$") ~= nil then
      local info = noctalia.fileInfo(usageDir .. "/" .. name)
      local mtime = info ~= nil and info.mtime or 0
      local size = info ~= nil and info.size or 0
      table.insert(parts, name .. ":" .. tostring(mtime) .. ":" .. tostring(size))
    end
  end
  return table.concat(parts, "|")
end

-- ------------------------------------------------------------------- sync

local function hostname()
  if detectedHostname == "" then
    local raw = noctalia.readFile("/etc/hostname")
    if raw ~= nil then
      detectedHostname = noctalia.string.trim(raw)
    end
  end
  return detectedHostname
end

local function safeDeviceId(raw)
  local value = noctalia.string.trim(tostring(raw or ""))
  if value == "" then
    value = noctalia.getenv("HOSTNAME") or hostname() or noctalia.getenv("HOST") or noctalia.getenv("USER") or "device"
  end
  value = tostring(value):gsub("[^A-Za-z0-9_.%-]+", "-"):gsub("^[._%-]+", ""):gsub("[._%-]+$", "")
  if value == "" then
    value = "device"
  end
  if #value > 80 then
    value = value:sub(1, 80)
  end
  return value
end

local function safeSnapshotFileName()
  local value = trimmed("sync_file_name")
  if value == "" then
    value = safeDeviceId(trimmed("sync_device_id")) .. ".json"
  end
  value = value:match("[^/]*$") or ""
  value = value:gsub("[^A-Za-z0-9_.%-]+", "-"):gsub("^[._%-]+", ""):gsub("[._%-]+$", "")
  if value == "" then
    value = safeDeviceId(trimmed("sync_device_id")) .. ".json"
  end
  if value:lower():match("%.json$") == nil then
    value ..= ".json"
  end
  if #value > 100 then
    value = value:sub(1, 95) .. ".json"
  end
  return value
end

local function syncEffectiveDir()
  return noctalia.expandPath(trimmed("sync_dir"))
end

local function syncEffectiveDeviceId()
  local configured = trimmed("sync_device_id")
  if configured ~= "" then
    return safeDeviceId(configured)
  end
  return safeDeviceId((safeSnapshotFileName():gsub("%.json$", "")))
end

local function cloneValue(value, fallback)
  if type(value) ~= "table" then
    return fallback
  end
  local encoded = noctalia.json.encode(value)
  if encoded == nil then
    return fallback
  end
  local decoded = noctalia.json.decode(encoded)
  if decoded == nil then
    return fallback
  end
  return decoded
end

-- Snapshots keep the field names omarchy writes, so a fleet of machines running
-- either shell still merges cleanly in both directions.
local function providerSnapshot(record)
  return {
    providerId = tostring(record.id),
    providerName = tostring(record.name or record.id),
    ready = record.ready == true,
    hasLocalStats = record.hasLocalStats ~= false,
    hasPromptStats = record.hasPromptStats ~= false,
    scope = tostring(record.scope or "device"),
    todayPrompts = numberValue(record.todayPrompts),
    todaySessions = numberValue(record.todaySessions),
    todayTotalTokens = numberValue(record.todayTotalTokens),
    todayTokensByModel = cloneValue(record.todayTokensByModel, {}),
    recentDays = cloneValue(record.recentDays, {}),
    totalPrompts = numberValue(record.totalPrompts),
    totalSessions = numberValue(record.totalSessions),
    activeDays = numberValue(record.activeDays),
    activeDates = cloneValue(record.activeDates, {}),
    modelUsage = cloneValue(record.modelUsage, {}),
  }
end

local function localSnapshot()
  local providers = {}
  for _, id in ipairs(recordIds) do
    local record = records[id]
    if record ~= nil and record.id ~= nil and providerEnabled(tostring(record.id)) then
      providers[tostring(record.id)] = providerSnapshot(record)
    end
  end
  return {
    schemaVersion = 1,
    deviceId = syncEffectiveDeviceId(),
    updatedAt = noctalia.formatTime("%Y-%m-%dT%H:%M:%S"),
    providers = providers,
  }
end

-- Device-scoped stats add up across machines; account-scoped stats (Fireworks'
-- billing API) are replicas of the same upstream truth on every synced device,
-- so the widest value wins — summing them would double every token per machine.
local function combineNumber(additive, current, value)
  if additive then
    return numberValue(current) + numberValue(value)
  end
  return math.max(numberValue(current), numberValue(value))
end

local function combineObjectNumbers(additive, target, source)
  if type(source) ~= "table" then
    return
  end
  for key, value in pairs(source) do
    target[key] = combineNumber(additive, target[key], value)
  end
end

local function countKeys(map)
  local n = 0
  for _ in pairs(map) do
    n += 1
  end
  return n
end

local function sortedKeys(map)
  local keys = {}
  for key in pairs(map) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

local function aggregateSnapshots(snapshots)
  local dates = recentDateStrings()
  local devices = {}
  local providers = {}

  local function providerAcc(id)
    if providers[id] ~= nil then
      return providers[id]
    end
    local recentByDay = {}
    for _, date in ipairs(dates) do
      recentByDay[date] = 0
    end
    providers[id] = {
      providerId = id,
      providerName = "",
      ready = false,
      hasLocalStats = false,
      hasPromptStats = false,
      todayPrompts = 0,
      todaySessions = 0,
      todayTotalTokens = 0,
      todayTokensByModel = {},
      recentByDay = recentByDay,
      totalPrompts = 0,
      totalSessions = 0,
      activeDays = 0,
      activeDates = {},
      modelUsage = {},
      devices = {},
    }
    return providers[id]
  end

  for _, snapshot in ipairs(snapshots) do
    local device = safeDeviceId(snapshot.deviceId or "device")
    devices[device] = true
    for providerId, stats in pairs(snapshot.providers or {}) do
      if type(stats) == "table" then
        local acc = providerAcc(tostring(providerId))
        acc.devices[device] = true
        if type(stats.providerName) == "string" and stats.providerName ~= "" and acc.providerName == "" then
          acc.providerName = stats.providerName
        end
        acc.ready = acc.ready or stats.ready == true
        acc.hasLocalStats = acc.hasLocalStats or stats.hasLocalStats ~= false
        -- Snapshots from before the field existed only came from agents that
        -- count prompts, so a missing value reads as true.
        acc.hasPromptStats = acc.hasPromptStats or stats.hasPromptStats ~= false

        local additive = tostring(stats.scope or "device") ~= "account"
        acc.todayPrompts = combineNumber(additive, acc.todayPrompts, stats.todayPrompts)
        acc.todaySessions = combineNumber(additive, acc.todaySessions, stats.todaySessions)
        acc.todayTotalTokens = combineNumber(additive, acc.todayTotalTokens, stats.todayTotalTokens)
        acc.totalPrompts = combineNumber(additive, acc.totalPrompts, stats.totalPrompts)
        acc.totalSessions = combineNumber(additive, acc.totalSessions, stats.totalSessions)

        -- Active days overlap between machines, so union the dates rather than
        -- summing counts. Snapshots written before activeDates existed only
        -- carry a count; the widest one stands in for them.
        for _, date in ipairs(stats.activeDates or {}) do
          acc.activeDates[tostring(date)] = true
        end
        acc.activeDays = math.max(acc.activeDays, numberValue(stats.activeDays))
        combineObjectNumbers(additive, acc.todayTokensByModel, stats.todayTokensByModel)

        for _, day in ipairs(stats.recentDays or {}) do
          if type(day) == "table" then
            local date = tostring(day.date or "")
            if acc.recentByDay[date] ~= nil then
              acc.recentByDay[date] = combineNumber(additive, acc.recentByDay[date], day.messageCount)
            end
          end
        end

        for modelId, bucket in pairs(stats.modelUsage or {}) do
          local target = acc.modelUsage[modelId]
          if target == nil then
            target = emptyTokenBucket()
            acc.modelUsage[modelId] = target
          end
          combineObjectNumbers(additive, target, bucket)
        end
      end
    end
  end

  local outProviders = {}
  for id, acc in pairs(providers) do
    local recentDays = {}
    for _, date in ipairs(dates) do
      table.insert(recentDays, { date = date, messageCount = acc.recentByDay[date] or 0 })
    end
    local providerDevices = sortedKeys(acc.devices)
    outProviders[id] = {
      providerId = acc.providerId,
      providerName = acc.providerName,
      ready = acc.ready or #providerDevices > 0,
      hasLocalStats = acc.hasLocalStats,
      hasPromptStats = acc.hasPromptStats,
      todayPrompts = acc.todayPrompts,
      todaySessions = acc.todaySessions,
      todayTotalTokens = acc.todayTotalTokens,
      todayTokensByModel = acc.todayTokensByModel,
      recentDays = recentDays,
      totalPrompts = acc.totalPrompts,
      totalSessions = acc.totalSessions,
      activeDays = math.max(acc.activeDays, countKeys(acc.activeDates)),
      modelUsage = acc.modelUsage,
      deviceCount = #providerDevices,
      devices = providerDevices,
    }
  end

  return {
    schemaVersion = 1,
    updatedAt = noctalia.formatTime("%Y-%m-%dT%H:%M:%S"),
    deviceCount = countKeys(devices),
    devices = sortedKeys(devices),
    providers = outProviders,
  }
end

local function syncedStatsFor(providerId)
  if not syncConfigured() or aggregate == nil or aggregate.providers == nil then
    return nil
  end
  return aggregate.providers[providerId]
end

local publish -- forward declaration; runSync republishes on completion

local function runSync()
  if not syncConfigured() then
    return
  end

  local dir = syncEffectiveDir()
  local ok = noctalia.mkdirAll(dir)
  if not ok then
    syncStatusText = noctalia.tr("sync.mkdir_failed")
    publish()
    return
  end

  local encoded = noctalia.json.encode(localSnapshot(), true)
  if encoded ~= nil then
    noctalia.writeFile(dir .. "/" .. safeSnapshotFileName(), encoded .. "\n")
  end

  local names = noctalia.listDir(dir)
  if names == nil then
    syncStatusText = noctalia.tr("sync.scan_failed")
    publish()
    return
  end

  table.sort(names)
  local snapshots = {}
  for _, name in ipairs(names) do
    if name:match("%.json$") ~= nil then
      local raw = noctalia.readFile(dir .. "/" .. name)
      if raw ~= nil then
        local decoded = noctalia.json.decode(raw)
        if type(decoded) == "table" and type(decoded.providers) == "table" then
          table.insert(snapshots, decoded)
        else
          noctalia.log("agents/sync: ignoring bad snapshot " .. name)
        end
      end
    end
  end

  aggregate = aggregateSnapshots(snapshots)
  syncStatusText = ""
  syncRevision += 1
  publish()
end

local function scheduleSync()
  if not syncConfigured() then
    return
  end
  syncDueAt = os.time() + SYNC_DEBOUNCE_SECONDS
end

-- --------------------------------------------------------------- providers

local function balanceValue(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local remaining = tonumber(raw.remaining)
  if remaining == nil or remaining < 0 then
    return nil
  end
  local funded = tonumber(raw.funded)
  return {
    remaining = remaining,
    funded = (funded ~= nil and funded > 0) and funded or 0,
    spent = math.max(0, tonumber(raw.spent) or 0),
    currency = tostring(raw.currency or "USD"),
    estimated = raw.estimated == true,
  }
end

local function pick(synced, stats, record, key, fallback)
  local source = synced and stats or record
  local value = source[key]
  if value == nil then
    return fallback
  end
  return value
end

local function displayProvider(record)
  local id = tostring(record.id)
  local stats = syncedStatsFor(id)
  local synced = stats ~= nil
  local deviceCount = 0
  if synced then
    deviceCount = numberValue(stats.deviceCount or (aggregate ~= nil and aggregate.deviceCount) or 0)
  end

  local function stat(key, fallback)
    return pick(synced, stats or {}, record, key, fallback)
  end

  return {
    providerId = id,
    providerName = tostring(record.name or record.id),
    ready = record.ready == true or synced,
    usageStatusText = tostring(record.usageStatusText or ""),
    authHelpText = tostring(record.authHelpText or ""),

    -- Rate limits and balances stay per-account and are never merged across
    -- devices.
    limits = type(record.limits) == "table" and record.limits or {},
    tierLabel = tostring(record.tierLabel or ""),
    balance = balanceValue(record.balance),

    todayPrompts = numberValue(stat("todayPrompts", 0)),
    todaySessions = numberValue(stat("todaySessions", 0)),
    todayTotalTokens = numberValue(stat("todayTotalTokens", 0)),
    todayTokensByModel = stat("todayTokensByModel", {}),
    recentDays = stat("recentDays", {}),
    totalPrompts = numberValue(stat("totalPrompts", 0)),
    totalSessions = numberValue(stat("totalSessions", 0)),
    activeDays = numberValue(stat("activeDays", 0)),
    modelUsage = stat("modelUsage", {}),
    hasLocalStats = stat("hasLocalStats", true) ~= false,
    hasPromptStats = stat("hasPromptStats", true) ~= false,

    syncEnabled = synced,
    syncDeviceCount = deviceCount,
    syncUpdatedAt = aggregate ~= nil and tostring(aggregate.updatedAt or "") or "",
  }
end

-- All-time keeps a quiet day from hiding an agent; today's counts admit a
-- machine whose only source is history.jsonl, which knows nothing older.
local function providerHasData(provider)
  return provider.totalPrompts > 0
    or provider.totalSessions > 0
    or provider.activeDays > 0
    or provider.todayPrompts > 0
    or provider.todaySessions > 0
    or #provider.limits > 0
    or provider.balance ~= nil
end

-- An agent earns a place in the bar and the panel by being switched on in
-- settings and having actually produced numbers — locally or on a synced
-- device. With nothing to show, the whole module collapses out of the bar
-- rather than sitting there dimmed.
local function enabledProviders()
  local out = {}
  local localIds = {}

  for _, id in ipairs(recordIds) do
    local record = records[id]
    if record ~= nil and record.id ~= nil then
      local recordId = tostring(record.id)
      localIds[recordId] = true
      if providerEnabled(recordId) then
        local provider = displayProvider(record)
        if providerHasData(provider) then
          table.insert(out, provider)
        end
      end
    end
  end

  -- An agent that only ever ran on another machine has no local record, but its
  -- synced numbers still deserve a tab. Rate limits stay blank — they are
  -- per-account and never travel.
  if syncConfigured() and aggregate ~= nil and type(aggregate.providers) == "table" then
    for _, syncedId in ipairs(sortedKeys(aggregate.providers)) do
      if not localIds[syncedId] and providerEnabled(syncedId) then
        local stats = aggregate.providers[syncedId]
        local provider = displayProvider({ id = syncedId, name = stats.providerName or syncedId })
        if providerHasData(provider) then
          table.insert(out, provider)
        end
      end
    end
  end

  return out
end

-- ------------------------------------------------------------------ output

local lastProviders = {}

function publish()
  dataRevision += 1
  lastProviders = enabledProviders()
  noctalia.state.set("agents.data", {
    providers = lastProviders,
    syncStatusText = syncStatusText,
    revision = dataRevision,
  })

  -- The selection follows the provider, not the slot it happens to sit in, so
  -- it is only reset when the provider it names is gone for good.
  local selected = noctalia.state.get("agents.selected")
  local stillThere = false
  for _, provider in ipairs(lastProviders) do
    if provider.providerId == selected then
      stillThere = true
      break
    end
  end
  if not stillThere then
    noctalia.state.set("agents.selected", #lastProviders > 0 and lastProviders[1].providerId or "")
  end
end

local function selectNext(step)
  local count = #lastProviders
  if count == 0 then
    return
  end
  local selected = noctalia.state.get("agents.selected")
  local index = 1
  for i, provider in ipairs(lastProviders) do
    if provider.providerId == selected then
      index = i
      break
    end
  end
  local wrapped = ((index - 1 + step) % count + count) % count
  noctalia.state.set("agents.selected", lastProviders[wrapped + 1].providerId)
end

-- ----------------------------------------------------------------- updates

local runUpdate -- forward declaration; the exit callback drains the queue

-- A collector that could not reach its limits endpoint at all — typically the
-- seconds after login before the network is up — writes retryAdvised into its
-- record. Honor it with one sooner try instead of waiting out the full refresh
-- interval; a run that reaches the endpoint clears the flag. Only the advising
-- agents rerun, so an outage at one provider does not put every other collector
-- on a 30-second treadmill.
local function scheduleLimitsRetry()
  local advising = {}
  for _, id in ipairs(recordIds) do
    local record = records[id]
    if record ~= nil and record.retryAdvised == true and providerEnabled(tostring(record.id or id)) then
      table.insert(advising, tostring(record.id or id))
    end
  end
  retryAgentIds = advising
  limitsRetryAt = #advising > 0 and os.time() + LIMITS_RETRY_SECONDS or 0
end

local function recordsChanged()
  publish()
  scheduleLimitsRetry()
  scheduleSync()
end

local function rescan()
  local signatureNow = directorySignature()
  if signatureNow == signature then
    return false
  end
  signature = signatureNow
  records, recordIds = readRecords()
  recordsChanged()
  return true
end

-- runAsync's argv-table form needs plugin_api >= 24, and this plugin targets 23
-- so it still loads on the current release; below that the host rejects a table
-- outright ("string expected, got table") and the callback never fires. So the
-- command is built as one /bin/sh line, with every dynamic value quoted.
local function sh(value)
  return "'" .. (tostring(value):gsub("'", "'\\''")) .. "'"
end

local function updateCommand(kind, agentIds)
  local parts = { sh(updateBin) }
  if kind == "force" then
    table.insert(parts, "--force")
  elseif kind == "limits" then
    table.insert(parts, "--limits-only")
  end
  table.insert(parts, "--dir")
  table.insert(parts, sh(usageDir))
  for id in pairs(disabledAgents()) do
    table.insert(parts, "--except")
    table.insert(parts, sh(id))
  end
  for _, id in ipairs(agentIds or {}) do
    table.insert(parts, sh(id))
  end
  return table.concat(parts, " ")
end

function runUpdate(kind, agentIds)
  resolvePaths()
  if updateBin == nil then
    return
  end
  if updateRunning then
    -- Collapse queued requests to one full rerun; a forced refresh outranks the
    -- cheaper kinds it might have been queued behind.
    if kind == "force" or pendingUpdateKind == "" then
      pendingUpdateKind = kind
    end
    return
  end

  updateRunning = true
  local started = noctalia.runAsync(updateCommand(kind, agentIds), function(result)
    updateRunning = false
    if result ~= nil and noctalia.string.trim(result.stderr or "") ~= "" then
      noctalia.log("agents: " .. noctalia.string.trim(result.stderr))
    end
    rescan()
    if pendingUpdateKind ~= "" then
      local queued = pendingUpdateKind
      pendingUpdateKind = ""
      runUpdate(queued)
    end
  end, UPDATE_TIMEOUT_MS)

  -- A rejected launch never calls back, and a stuck updateRunning would mean no
  -- refresh ever again — the one failure mode with no way out.
  if not started then
    updateRunning = false
    noctalia.log("agents: could not start " .. tostring(updateBin))
  end
end

-- Opening the panel wants the numbers that go stale on the wire, not another
-- walk over every transcript on disk — the collectors reuse their recent scans
-- in this mode.
local function refreshLimits()
  runUpdate("limits")
end

local function refreshAll(force)
  runUpdate(force and "force" or "normal")
end

-- --------------------------------------------------------------- lifecycle

function update()
  local now = os.time()

  if syncDueAt > 0 and now >= syncDueAt then
    syncDueAt = 0
    runSync()
  end

  if limitsRetryAt > 0 and now >= limitsRetryAt then
    limitsRetryAt = 0
    runUpdate("limits", retryAgentIds)
  end

  -- The periodic refresh keeps its own cadence whether or not a run is already
  -- going, so a panel-open "limits" pass never pushes the full scan out.
  if now >= nextRefreshAt then
    nextRefreshAt = now + refreshInterval()
    refreshAll(false)
  end

  rescan()
end

function onConfigChanged()
  -- Enablement and the sync target both change what the collectors are asked
  -- for, so a settings edit is worth one full rerun.
  publish()
  scheduleSync()
  refreshAll(false)
end

function onIpc(event, _payload)
  if event == "refresh" then
    refreshAll(true)
  elseif event == "next" then
    selectNext(1)
  end
end

noctalia.state.watch("agents.cmd", function(value)
  if type(value) ~= "table" then
    return
  end
  if value.op == "refresh" then
    refreshAll(true)
  elseif value.op == "limits" then
    refreshLimits()
  elseif value.op == "next" then
    selectNext(1)
  end
  -- Clear the key so an identical next command still registers as a change.
  noctalia.state.set("agents.cmd", nil)
end)

resolvePaths()
noctalia.setUpdateInterval(RECORD_POLL_MS)
if not rescan() then
  -- Nothing on disk yet — publish the empty list anyway, so the bar widget has
  -- a definite "no agents" to hide on instead of an absent key.
  publish()
end
if syncConfigured() then
  scheduleSync()
end
