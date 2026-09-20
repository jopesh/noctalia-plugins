--!nonstrict
-- Polls bin/windows-status and drives `docker compose` through pkexec.
--
-- The split matters: status is unprivileged and cheap (~40 ms), so it runs on
-- every tick, while pkexec is slow enough (1.5-4 s) that it is reserved for the
-- two operations that genuinely need root. Nothing here ever blocks waiting for
-- Windows to boot -- a requested connect is remembered as a deadline and fired
-- from an ordinary poll once the guest answers RDP.

local POLL_MS = 1000
local STATUS_TIMEOUT_MS = 8000
local START_TIMEOUT_MS = 180000
local STOP_TIMEOUT_MS = 140000 -- The compose file allows a 120 s graceful stop.
local CONNECT_DEADLINE = 600 -- How long a queued connect waits for a cold boot.

local data = { state = "loading", busy = false }
local statusInFlight = false
local controlInFlight = false
local nextPollAt = 0
local connectUntil = nil

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
-- so every dynamic value has to be quoted by hand.
local function sh(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function composePath()
  return noctalia.expandPath(trimmed("compose_file", "~/Windows/docker-compose.yml"))
end

local function binPath(name)
  local dir = noctalia.pluginDir()
  return dir ~= nil and (dir .. "/bin/" .. name) or nil
end

local function publish()
  data.pendingConnect = connectUntil ~= nil
  noctalia.state.set("windows.data", data)
end

-- Two error channels on purpose. applyStatus() runs every poll and clears
-- data.error, which would wipe a "pkexec refused" message within one interval;
-- controlError persists until the next control attempt or a manual refresh.
local function fail(message)
  data.error = message
  publish()
end

local function failControl(message)
  data.controlError = message
  publish()
end

-- ------------------------------------------------------------------ status

local function clearVitals()
  data.uptime = nil
  data.pid = nil
  data.ram = nil
  data.cores = nil
  data.username = nil
  data.rdpReady = false
end

local function applyStatus(payload)
  if type(payload) ~= "table" then
    -- No JSON at all: the probe itself failed, which is a different problem
    -- from a compose file it could not make sense of.
    data.state = "error"
    data.error = noctalia.tr("error.probe_failed")
    clearVitals()
    return
  end
  if payload.ok ~= true then
    data.state = "error"
    data.error = noctalia.tr(payload.error == "no_compose" and "error.no_compose" or "error.bad_compose",
      { path = composePath() })
    clearVitals()
    return
  end

  data.state = payload.state or "stopped"
  data.error = nil
  data.ram = payload.ram
  data.cores = payload.cores
  data.username = payload.username
  data.rdpPort = payload.rdp_port
  data.webPort = payload.web_port
  data.rdpReady = payload.rdp_ready == true
  data.uptime = payload.uptime_s
  data.pid = payload.pid
end

local function poll()
  if statusInFlight then
    return
  end
  local bin = binPath("windows-status")
  if bin == nil then
    data.state = "error"
    fail(noctalia.tr("error.no_plugin_dir"))
    return
  end
  statusInFlight = true
  local command = sh(bin) .. " --compose " .. sh(composePath())
  local started = noctalia.runAsync(command, function(result)
    statusInFlight = false
    -- windows-status exits 1 on a bad compose file but still prints its JSON,
    -- so the payload is what decides, not the exit code.
    applyStatus(noctalia.json.decode(result ~= nil and result.stdout or ""))
    publish()
  end, STATUS_TIMEOUT_MS)
  if not started then
    statusInFlight = false
    data.state = "error"
    fail(noctalia.tr("error.no_status_bin"))
  end
end

-- ------------------------------------------------------------------ connect

local function launchRdp()
  -- An empty rdp_command setting means "use the bundled launcher".
  local command = trimmed("rdp_command", nil)
  if command == nil then
    local bin = binPath("windows-rdp")
    if bin == nil then
      failControl(noctalia.tr("error.no_plugin_dir"))
      return
    end
    command = sh(bin) .. " --compose " .. sh(composePath())
  end
  if not noctalia.runAsync(command) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.rdp_failed"))
  end
end

local function openWeb()
  local port = tonumber(data.webPort) or 8006
  if not noctalia.runAsync("xdg-open " .. sh("http://127.0.0.1:" .. port)) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.web_failed"))
  end
end

-- ------------------------------------------------------------------ control

local function control(op, onDone)
  if controlInFlight or (op ~= "start" and op ~= "stop") then
    return false
  end
  controlInFlight = true
  data.busy = true
  data.operation = op
  data.controlError = nil
  publish()

  local action = op == "start" and "up -d" or "stop"
  local command = "pkexec /usr/bin/docker compose -f " .. sh(composePath()) .. " " .. action
  local started = noctalia.runAsync(command, function(result)
    controlInFlight = false
    data.busy = false
    data.operation = nil
    local code = result ~= nil and result.exitCode or -1
    if code ~= 0 then
      -- pkexec reserves 126 for a dismissed prompt and 127 for an authorization
      -- or exec failure; both mean root was refused, not that docker failed.
      if code == 126 or code == 127 then
        data.controlError = noctalia.tr("error.not_authorized")
      else
        local stderr = noctalia.string.trim(result ~= nil and result.stderr or "")
        data.controlError = stderr ~= "" and stderr or noctalia.tr("error.command_failed", { op = op })
      end
      connectUntil = nil
    elseif onDone ~= nil then
      onDone()
    end
    publish()
    nextPollAt = 0
  end, op == "start" and START_TIMEOUT_MS or STOP_TIMEOUT_MS)

  if not started then
    controlInFlight = false
    data.busy = false
    data.operation = nil
    connectUntil = nil
    failControl(noctalia.tr("error.no_pkexec"))
    return false
  end
  return true
end

local function connect()
  if data.state == "running" then
    launchRdp()
    return
  end
  if connectUntil ~= nil then -- A second click cancels the queued connect.
    connectUntil = nil
    publish()
    return
  end
  if data.state == "booting" or data.state == "preparing" then
    connectUntil = os.time() + CONNECT_DEADLINE
    publish()
    return
  end
  if cfg("auto_connect", true) == false or controlInFlight then
    failControl(noctalia.tr("error.not_running"))
    return
  end
  connectUntil = os.time() + CONNECT_DEADLINE
  if not control("start") then
    connectUntil = nil
    publish()
  end
end

local function stop()
  connectUntil = nil
  control("stop")
end

-- --------------------------------------------------------------------- loop

function update()
  local now = os.time()
  if now >= nextPollAt then
    nextPollAt = now + math.max(2, tonumber(cfg("refresh_interval", 5)) or 5)
    poll()
  end
  if connectUntil ~= nil then
    if data.state == "running" then
      connectUntil = nil
      publish()
      launchRdp()
    elseif now > connectUntil then
      connectUntil = nil
      failControl(noctalia.tr("error.connect_timeout"))
    end
  end
end

function onConfigChanged()
  nextPollAt = 0
  poll()
end

function onIpc(event, _payload)
  if event == "refresh" then
    poll()
  elseif event == "start" then
    control("start")
  elseif event == "stop" then
    stop()
  elseif event == "connect" then
    connect()
  elseif event == "web" then
    openWeb()
  end
end

noctalia.state.watch("windows.cmd", function(value)
  if type(value) == "table" then
    if value.op == "refresh" then
      data.controlError = nil
      nextPollAt = 0
      poll()
    elseif value.op == "connect" then
      connect()
    elseif value.op == "web" then
      openWeb()
    elseif value.op == "stop" then
      stop()
    elseif value.op == "start" then
      control("start")
    end
  end
  noctalia.state.set("windows.cmd", nil)
end)

noctalia.setUpdateInterval(POLL_MS)
publish()
poll()
