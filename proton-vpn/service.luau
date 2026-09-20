--!nonstrict
-- Proton VPN service — cheap nmcli status polling, serialised CLI control, and
-- the Python helper that turns the server-list cache into a compact list plus a
-- dot-matrix SVG map.
--
-- Publishes: proton_vpn.data   (shape documented in README.md)
-- Commands:  proton_vpn.cmd    (cleared to nil once handled, like johnschmidt/windows)
-- IPC:       refresh | connect | disconnect
--
-- proton-vpn-cli burns ~0.7 s of CPU before it prints anything and always emits
-- an EventletDeprecationWarning block on stderr, so stderr alone never means
-- failure and `protonvpn status` is never used for polling. NetworkManager
-- names the tunnel profile "ProtonVPN <SERVER_NAME>" and deletes it on
-- disconnect, which makes nmcli the whole status source.

local TICK_MS = 1000
local NMCLI_TIMEOUT_MS = 5000
local QUERY_TIMEOUT_MS = 30000 -- `config list` / `info`
local HELPER_TIMEOUT_MS = 10000
local CONTROL_TIMEOUT_MS = 60000 -- runAsync clamps timeouts to 60 s
local NMCLI_ACTIVE = "nmcli -t -f NAME,TYPE,STATE connection show --active"

-- CLI setting name -> field name in data.features.
local FEATURE_FIELDS = {
  ["netshield"] = "netshield",
  ["kill-switch"] = "kill_switch",
  ["port-forwarding"] = "port_forwarding",
  ["vpn-accelerator"] = "vpn_accelerator",
  ["moderate-nat"] = "moderate_nat",
  ["ipv6"] = "ipv6",
}

-- Substrings that mark a stderr line as part of the eventlet warning banner.
local NOISE_NEEDLES = { "Eventlet", "eventlet", "Warning", "warnings", "from " }

local data = { status = "loading", busy = false, cliAvailable = false }

local busy = false -- one connect/disconnect/config operation at a time
local polling = false
local helperRunning = false
local featuresRunning = false
local accountRunning = false
local nmcliOk = nil -- nil until the first poll answers
local signinRequired = false
local nextPollAt = 0
local nextHelperAt = 0
local helperKey = nil -- the inputs data.servers / data.mapPath were built from

-- Error slots, merged into data.error by priority so a helper hiccup never
-- hides "the CLI is missing" and a stale operation error never sticks around.
local errAvailability = nil
local errOperation = nil
local errHelper = nil
local errStatus = nil

-- ── settings ────────────────────────────────────────────────────────────────

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  return value == nil and fallback or value
end

local function trimmed(key, fallback)
  local value = cfg(key, fallback)
  if type(value) ~= "string" then
    return fallback
  end
  value = noctalia.string.trim(value)
  return value == "" and fallback or value
end

-- Quotes one argument for /bin/sh -c. plugin_api 23 has no argv-table runAsync,
-- so every dynamic value passes through here.
local function sh(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function cliPath()
  local value = trimmed("cli_path", "protonvpn")
  if value:sub(1, 2) == "~/" then
    value = noctalia.expandPath(value)
  end
  return value
end

local function cli()
  return sh(cliPath())
end

local function pollInterval()
  return math.clamp(tonumber(cfg("poll_interval", 5)) or 5, 2, 60)
end

local function serversInterval()
  return math.clamp(tonumber(cfg("servers_refresh", 15)) or 15, 5, 120) * 60
end

-- ── publishing ──────────────────────────────────────────────────────────────

local function refreshStatus()
  if errAvailability ~= nil then
    data.status = "unavailable"
  elseif nmcliOk == nil then
    data.status = "loading"
  elseif nmcliOk == false then
    data.status = "error"
  elseif signinRequired then
    data.status = "signin_required"
  elseif data.serverName ~= nil then
    data.status = "connected"
  else
    data.status = "disconnected"
  end
end

local function publish()
  data.busy = busy
  data.error = errAvailability or errOperation or errHelper or errStatus
  noctalia.state.set("proton_vpn.data", data)
end

-- ── output parsing ──────────────────────────────────────────────────────────

-- nmcli -t escapes ":" inside NAME as "\:", and Proton server names never
-- contain one, so a plain [^:]+ capture is unambiguous.
local function parseActiveServer(output)
  for line in output:gmatch("[^\n]+") do
    local name = line:match("^ProtonVPN ([^:]+):wireguard:activated$")
    if name ~= nil then
      return noctalia.string.trim(name)
    end
  end
  return nil
end

local function parseFeatures(output)
  local features = {}
  local locked = false
  for line in output:gmatch("[^\n]+") do
    local name, value = line:match("^([%w%-]+)%s%s+(.-)%s*$")
    local field = name ~= nil and FEATURE_FIELDS[name] or nil
    if field ~= nil then
      features[field] = value
      if value:find("Upgrade", 1, true) ~= nil then
        locked = true
      end
    end
  end
  return features, locked
end

local function isNoise(line)
  if line == "" or line:match("^%s") ~= nil then
    return true
  end
  for _, needle in ipairs(NOISE_NEEDLES) do
    if line:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function firstLine(streams, matches)
  for _, stream in ipairs(streams) do
    for line in stream:gmatch("[^\n]+") do
      if matches(line) then
        return noctalia.string.trim(line)
      end
    end
  end
  return nil
end

local function lastMeaningfulLine(stderr)
  local found = nil
  for line in stderr:gmatch("[^\n]+") do
    if not isNoise(line) then
      local text = noctalia.string.trim(line)
      if text ~= "" then
        found = text
      end
    end
  end
  return found
end

-- The CLI reports "Error: Proton VPN desktop app is currently running" on
-- STDOUT with exit code 0, so stdout is searched first and the exit code is
-- only a fallback signal.
local function commandFailure(result)
  if result == nil then
    return noctalia.tr("error.launch")
  end
  if result.timedOut then
    return noctalia.tr("error.timeout")
  end
  local streams = { result.stdout or "", result.stderr or "" }
  local text = firstLine(streams, function(line)
    return line:match("^Error:") ~= nil
  end)
  if text == nil then
    text = firstLine(streams, function(line)
      return line:match("^Usage:") ~= nil
    end)
  end
  if text == nil then
    text = firstLine(streams, function(line)
      return line:find("Connection failed", 1, true) ~= nil
    end)
  end
  if text ~= nil then
    return (text:gsub("^Error:%s*", ""))
  end
  if result.exitCode ~= 0 then
    return lastMeaningfulLine(result.stderr or "") or noctalia.tr("error.generic")
  end
  return nil
end

local function resultText(result)
  if result == nil then
    return ""
  end
  return (result.stdout or "") .. "\n" .. (result.stderr or "")
end

-- ── availability ────────────────────────────────────────────────────────────

local function available(name)
  if name:find("/") ~= nil then
    return noctalia.fileExists(name)
  end
  return noctalia.commandExists(name)
end

local function checkAvailability()
  local cliOk = available(cliPath())
  data.cliAvailable = cliOk
  if not cliOk then
    errAvailability = { message = noctalia.tr("error.no_cli"), transient = false }
  elseif not noctalia.commandExists("nmcli") then
    errAvailability = { message = noctalia.tr("error.no_nmcli"), transient = false }
  else
    errAvailability = nil
  end
  return errAvailability == nil
end

-- ── account ─────────────────────────────────────────────────────────────────

local function checkAccount()
  if accountRunning or not data.cliAvailable then
    return
  end
  accountRunning = true
  local started = noctalia.runAsync(cli() .. " info", function(result)
    accountRunning = false
    local text = resultText(result)
    local account = text:match("Account:%s*'([^']+)'")
    if account ~= nil then
      data.account = account
      signinRequired = false
    elseif text:find("Authentication required", 1, true) ~= nil then
      data.account = nil
      signinRequired = true
    else
      noctalia.log("proton-vpn: could not read the account name")
    end
    refreshStatus()
    publish()
  end, QUERY_TIMEOUT_MS)
  if not started then
    accountRunning = false
  end
end

-- Any command may answer "Authentication required" once the session expires.
local function handleAuthText(text)
  if text:find("Authentication required", 1, true) == nil then
    return false
  end
  signinRequired = true
  data.account = nil
  checkAccount()
  return true
end

-- ── features ────────────────────────────────────────────────────────────────

local function loadFeatures()
  if featuresRunning or not data.cliAvailable then
    return
  end
  featuresRunning = true
  local started = noctalia.runAsync(cli() .. " config list", function(result)
    featuresRunning = false
    local text = resultText(result)
    if handleAuthText(text) then
      refreshStatus()
      publish()
      return
    end
    local features, locked = parseFeatures(result ~= nil and result.stdout or "")
    if next(features) ~= nil then
      -- A readable settings table proves the session is valid, so this is also
      -- where "sign-in required" clears after the user signs in.
      signinRequired = false
      data.features = features
      data.featuresLocked = locked
      refreshStatus()
      publish()
    end
  end, QUERY_TIMEOUT_MS)
  if not started then
    featuresRunning = false
  end
end

-- ── status polling ──────────────────────────────────────────────────────────

local function pollNmcli()
  if polling then
    return
  end
  polling = true
  local started = noctalia.runAsync(NMCLI_ACTIVE, function(result)
    polling = false
    if result == nil or result.timedOut or result.exitCode ~= 0 then
      nmcliOk = false
      errStatus = { message = noctalia.tr("error.nmcli"), transient = true }
    else
      nmcliOk = true
      errStatus = nil
      local name = parseActiveServer(result.stdout or "")
      data.serverName = name
      if name == nil then
        data.server = nil
      elseif data.server ~= nil and data.server.name ~= name then
        data.server = { name = name }
      end
    end
    data.checkedAt = os.time()
    refreshStatus()
    publish()
  end, NMCLI_TIMEOUT_MS)
  if not started then
    polling = false
    nmcliOk = false
    errStatus = { message = noctalia.tr("error.nmcli"), transient = true }
    refreshStatus()
    publish()
  end
end

-- ── server list + map helper ────────────────────────────────────────────────

local function applyHelperPayload(payload)
  if type(payload.countries) == "table" and type(payload.cities) == "table" then
    data.servers = {
      generatedAt = payload.generatedAt,
      countries = payload.countries,
      cities = payload.cities,
    }
  end
  data.mapPath = payload.mapPath
  if data.serverName == nil then
    data.server = nil
  elseif type(payload.active) == "table" and payload.active.name == data.serverName then
    data.server = payload.active
  elseif data.server == nil or data.server.name ~= data.serverName then
    data.server = { name = data.serverName }
  end
end

local function runHelper(key, now)
  local pluginDir = noctalia.pluginDir()
  local dataDir = noctalia.pluginDataDir()
  if pluginDir == nil or dataDir == nil then
    return
  end
  helperRunning = true
  helperKey = key -- claimed up front: a failing helper must not retry every tick
  nextHelperAt = now + serversInterval()

  local command = "python3 " .. sh(pluginDir .. "/bin/proton-vpn-map")
    .. " --data-dir " .. sh(dataDir)
    .. (noctalia.isDarkMode() and " --dark" or " --light")
    .. " --color-server " .. sh(trimmed("color_server", "#6d4aff"))
    .. " --color-connected " .. sh(trimmed("color_connected", "#a6e3a1"))
  if data.serverName ~= nil then
    command ..= " --active " .. sh(data.serverName)
  end

  local started = noctalia.runAsync(command, function(result)
    helperRunning = false
    local payload = result ~= nil and noctalia.json.decode(result.stdout or "") or nil
    if type(payload) ~= "table" then
      noctalia.log("proton-vpn: map helper produced no JSON")
      return
    end
    if payload.ok ~= true then
      -- Only no_cache is actionable ("sign in once so the CLI downloads the
      -- list"); everything else keeps the previous data and goes to the log.
      if payload.error == "no_cache" then
        errHelper = { message = payload.message or noctalia.tr("error.no_servers"), transient = false }
        publish()
      else
        noctalia.log("proton-vpn: map helper failed: " .. tostring(payload.error) .. " — " .. tostring(payload.message))
      end
      return
    end
    errHelper = nil
    applyHelperPayload(payload)
    publish()
  end, HELPER_TIMEOUT_MS)

  if not started then
    helperRunning = false
  end
end

-- Re-runs on a server change, a theme flip, a colour change, or the interval.
local function maybeRunHelper(now)
  if busy or helperRunning or nmcliOk == nil then
    return
  end
  local key = table.concat({
    data.serverName or "",
    noctalia.isDarkMode() and "dark" or "light",
    trimmed("color_server", "#6d4aff"),
    trimmed("color_connected", "#a6e3a1"),
  }, "|")
  if key == helperKey and now < nextHelperAt then
    return
  end
  runHelper(key, now)
end

-- ── control ─────────────────────────────────────────────────────────────────

local function runControl(operation, command, after)
  if busy or not data.cliAvailable then
    return
  end
  busy = true
  data.operation = operation
  errOperation = nil
  data.notice = nil
  publish()

  local started = noctalia.runAsync(command, function(result)
    busy = false
    data.operation = nil
    local message = commandFailure(result)
    if message ~= nil then
      errOperation = { message = message, transient = false }
      -- The panel is usually closed while a bar right-click runs, so the
      -- failure is also raised as a notification.
      noctalia.notifyError(noctalia.tr("title"), message)
    end
    handleAuthText(resultText(result))
    if after ~= nil then
      after(message == nil)
    end
    helperKey = nil -- the active server probably changed: redraw the map
    nextPollAt = 0
    refreshStatus()
    publish()
    pollNmcli()
  end, CONTROL_TIMEOUT_MS)

  if not started then
    busy = false
    data.operation = nil
    errOperation = { message = noctalia.tr("error.launch"), transient = false }
    publish()
  end
end

-- `--city` wins over `--country` in the CLI, so only one target is ever sent.
local function connectCommand(cmd)
  local parts = { cli(), "connect" }
  local value = type(cmd.value) == "string" and noctalia.string.trim(cmd.value) or ""
  if value ~= "" then
    if cmd.kind == "server" then
      table.insert(parts, sh(value))
    elseif cmd.kind == "country" then
      table.insert(parts, "--country " .. sh(value))
    elseif cmd.kind == "city" then
      table.insert(parts, "--city " .. sh(value))
    end
  end
  if cmd.p2p then
    table.insert(parts, "--p2p")
  end
  if cmd.securecore then
    table.insert(parts, "--securecore")
  end
  if cmd.tor then
    table.insert(parts, "--tor")
  end
  return table.concat(parts, " ")
end

local function connect(cmd)
  runControl("connect", connectCommand(cmd))
end

local function disconnect()
  runControl("disconnect", cli() .. " disconnect")
end

local function setFeature(name, value)
  if FEATURE_FIELDS[name] == nil or type(value) ~= "string" or value == "" then
    return
  end
  runControl("config", cli() .. " config set " .. sh(name) .. " " .. sh(value), function(ok)
    -- The CLI refuses some changes (kill switch while connected), so the table
    -- is reloaded either way rather than assuming the new value took.
    loadFeatures()
    if ok and name == "ipv6" and data.serverName ~= nil then
      data.notice = noctalia.tr("notice.ipv6")
    end
  end)
end

-- Deliberately keeps errOperation and notice: the panel sends a refresh on
-- every open, and a failed connect must survive that to be seen at all.
local function refresh()
  nextPollAt = 0
  pollNmcli()
  loadFeatures()
  if signinRequired then
    checkAccount()
  end
end

local function refreshServers()
  helperKey = nil
  nextHelperAt = 0
  errHelper = nil
end

local function signin()
  if not noctalia.runInTerminal(cli() .. " signin") then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.no_terminal"))
  end
end

-- ── host callbacks ──────────────────────────────────────────────────────────

function update()
  local now = os.time()
  if busy then
    return
  end
  if now >= nextPollAt then
    nextPollAt = now + pollInterval()
    -- Availability rides the poll cadence: commandExists hits the filesystem.
    local wasAvailable = errAvailability == nil
    local isAvailable = checkAvailability()
    if isAvailable ~= wasAvailable then
      refreshStatus()
      publish()
      if isAvailable then
        loadFeatures()
        checkAccount()
      end
    end
    if isAvailable then
      pollNmcli()
    end
  end
  if errAvailability == nil then
    maybeRunHelper(now)
  end
end

function onConfigChanged()
  helperKey = nil -- colours or the CLI path may have changed
  nextHelperAt = 0
  nextPollAt = 0
  checkAvailability()
  refreshStatus()
  publish()
  loadFeatures()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  elseif event == "connect" then
    connect({ kind = "fastest" })
  elseif event == "disconnect" then
    disconnect()
  end
end

noctalia.state.watch("proton_vpn.cmd", function(value)
  if type(value) == "table" then
    local op = value.op
    if op == "connect" then
      connect(value)
    elseif op == "disconnect" then
      disconnect()
    elseif op == "refresh" then
      refresh()
    elseif op == "refresh_servers" then
      refreshServers()
    elseif op == "set_feature" then
      setFeature(value.name, value.value)
    elseif op == "signin" then
      signin()
    end
  end
  noctalia.state.set("proton_vpn.cmd", nil)
end)

noctalia.setUpdateInterval(TICK_MS)
if checkAvailability() then
  pollNmcli()
  loadFeatures()
  checkAccount()
end
refreshStatus()
publish()
