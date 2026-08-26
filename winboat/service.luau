--!nonstrict
-- Polls the WinBoat container and serializes start/stop operations.

local POLL_MS = 1000
local CONTROL_TIMEOUT_MS = 140000 -- WinBoat's compose config allows a 120s graceful stop.
local STATS_INTERVAL = 3

local data = { status = "loading", busy = false }
local inFlight = false
local nextCheckAt = 0
local nextStatsAt = 0
local runtimeOverride = nil

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

local function runtime()
  local value = runtimeOverride or trimmed("runtime", "docker")
  return value == "podman" and "podman" or "docker"
end

local function containerName()
  return trimmed("container_name", "WinBoat")
end

local function sh(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function publish()
  data.runtime = runtime()
  data.container = containerName()
  noctalia.state.set("winboat.data", data)
end

local function resultError(result)
  return noctalia.string.trim(result ~= nil and result.stderr or "")
end

local function fetchStats()
  if inFlight or data.status ~= "running" then
    return
  end
  inFlight = true
  local command = runtime() .. " port " .. sh(containerName()) .. " 7148/tcp"
  local started = noctalia.runAsync(command, function(result)
    nextStatsAt = os.time() + STATS_INTERVAL
    local output = noctalia.string.trim(result ~= nil and result.stdout or "")
    local port = output:match("127%.0%.0%.1:(%d+)") or output:match(":(%d+)")
    if result == nil or result.exitCode ~= 0 or port == nil then
      inFlight = false
      data.cpuPercent = nil
      data.memoryUsage = nil
      data.memoryUsedMb = nil
      data.memoryTotalMb = nil
      data.memoryPercent = nil
      publish()
      return
    end

    noctalia.http({ url = "http://127.0.0.1:" .. port .. "/metrics", method = "GET" }, function(response)
      inFlight = false
      if response == nil or not response.ok or response.status ~= 200 then
        data.cpuPercent = nil
        data.memoryUsage = nil
        data.memoryUsedMb = nil
        data.memoryTotalMb = nil
        data.memoryPercent = nil
        publish()
        return
      end
      local payload = noctalia.json.decode(response.body or "")
      local cpu = type(payload) == "table" and payload.cpu or nil
      local ram = type(payload) == "table" and payload.ram or nil
      if type(cpu) ~= "table" or type(ram) ~= "table" then
        data.cpuPercent = nil
        data.memoryUsage = nil
        data.memoryUsedMb = nil
        data.memoryTotalMb = nil
        data.memoryPercent = nil
      else
        data.cpuPercent = tonumber(cpu.usage)
        data.memoryUsedMb = tonumber(ram.used)
        data.memoryTotalMb = tonumber(ram.total)
        data.memoryPercent = tonumber(ram.percentage)
      end
      publish()
    end)
  end, 10000)
  if not started then
    inFlight = false
    data.cpuPercent = nil
    data.memoryUsedMb = nil
    data.memoryTotalMb = nil
    data.memoryPercent = nil
    publish()
  end
end

local function inspect()
  if inFlight then
    return
  end
  inFlight = true
  local function probe(name)
    return "if command -v " .. name .. " >/dev/null 2>&1; then "
      .. "state=$(" .. name .. " inspect --format " .. sh("{{.State.Status}}") .. " " .. sh(containerName()) .. " 2>/dev/null); "
      .. "if [ -n \"$state\" ]; then printf '" .. name .. "|%s\\n' \"$state\"; "
      .. "else printf '" .. name .. "|missing\\n'; fi; "
      .. "else printf '" .. name .. "|unavailable\\n'; fi"
  end
  local command = probe("docker") .. "; " .. probe("podman")
  local started = noctalia.runAsync(command, function(result)
    inFlight = false
    local output = noctalia.string.trim(result ~= nil and result.stdout or "")
    local statuses = {}
    for name, status in output:gmatch("([%a]+)|([^\n]+)") do
      statuses[name] = noctalia.string.trim(status):lower()
    end
    data.runtimeAvailability = {
      docker = statuses.docker ~= nil and statuses.docker ~= "missing" and statuses.docker ~= "unavailable",
      podman = statuses.podman ~= nil and statuses.podman ~= "missing" and statuses.podman ~= "unavailable",
    }
    data.status = statuses[runtime()] or "unavailable"
    data.error = nil
    if data.status ~= "running" then
      data.cpuPercent = nil
      data.memoryUsage = nil
      data.memoryUsedMb = nil
      data.memoryTotalMb = nil
      data.memoryPercent = nil
    end
    data.checkedAt = os.time()
    publish()
    if data.status == "running" then
      fetchStats()
    end
  end, 10000)
  if not started then
    inFlight = false
    data.status = "unavailable"
    data.error = "Could not launch " .. runtime()
    publish()
  end
end

local function control(op)
  if inFlight or data.busy then
    return
  end
  if op ~= "start" and op ~= "stop" then
    return
  end
  inFlight = true
  data.busy = true
  data.operation = op
  data.error = nil
  publish()

  local command = runtime() .. " container " .. op .. " " .. sh(containerName())
  local started = noctalia.runAsync(command, function(result)
    inFlight = false
    data.busy = false
    data.operation = nil
    local message = resultError(result)
    if result == nil or result.exitCode ~= 0 then
      data.error = message ~= "" and message or ("Could not " .. op .. " container")
    end
    publish()
    inspect()
  end, CONTROL_TIMEOUT_MS)
  if not started then
    inFlight = false
    data.busy = false
    data.operation = nil
    data.error = "Could not launch " .. runtime()
    publish()
  end
end

local function openSession()
  local command = cfg("open_command", "~/.local/bin/winboat-rdp")
  if type(command) ~= "string" then
    return
  end
  command = noctalia.string.trim(command)
  if command == "" then
    return
  end
  if command:sub(1, 2) == "~/" and command:find("%s") == nil then
    command = sh(noctalia.expandPath(command))
  end
  if not noctalia.runAsync(command) then
    noctalia.notifyError(noctalia.tr("title"), "Could not launch the RDP session")
  end
end

local function setRuntime(value)
  if inFlight or data.busy or (value ~= "docker" and value ~= "podman")
      or type(data.runtimeAvailability) ~= "table" or data.runtimeAvailability[value] ~= true then
    return
  end
  runtimeOverride = value
  data.status = "loading"
  data.error = nil
  publish()
  nextCheckAt = 0
  inspect()
end

function update()
  local now = os.time()
  if not inFlight and not data.busy and now >= nextCheckAt then
    nextCheckAt = now + math.max(2, tonumber(cfg("refresh_interval", 5)) or 5)
    inspect()
  elseif not inFlight and not data.busy and data.status == "running" and now >= nextStatsAt then
    fetchStats()
  end
end

function onConfigChanged()
  runtimeOverride = nil
  nextCheckAt = 0
  inspect()
end

function onIpc(event, _payload)
  if event == "refresh" then inspect() elseif event == "start" or event == "stop" then control(event) end
end

noctalia.state.watch("winboat.cmd", function(value)
  if type(value) == "table" then
    if value.op == "refresh" then
      inspect()
    elseif value.op == "set_runtime" then
      setRuntime(value.runtime)
    elseif value.op == "open" then
      openSession()
    else
      control(value.op)
    end
  end
  noctalia.state.set("winboat.cmd", nil)
end)

noctalia.setUpdateInterval(POLL_MS)
publish()
inspect()
