--!nonstrict
-- Headless half of the plugin: owns every fetch, every download and what is
-- currently set. The bar widget and panel are views onto it via
-- boringday.data, so work started from the panel finishes with it closed.

local model = require("./model.luau")

-- Clears the transient status line and notices a new calendar day; both are
-- a couple of comparisons, so the tick can be short.
local TICK_MS = 1000
local PIECE_LIMIT = 3
local SHUFFLE_ATTEMPTS = 4
local KEEP_WALLPAPERS = 20
local KEEP_THUMBS = 60
local FLASH_SECONDS = 6
-- After a failed fetch of today's set, try again on this schedule (doubling)
-- so a shell started offline catches up without anyone clicking refresh.
local RETRY_MIN_SECONDS = 60
local RETRY_MAX_SECONDS = 1800

local data = {
  pieces = {},
  thumbs = {},
  current = nil,
  status = "",
  lastError = "",
  applying = false,
  fetching = false,
  shuffling = false,
  saving = false,
}

local state = { recentIds = {}, current = nil, pieces = {}, fetchedDay = "" }
local dataDir, wallpaperDir, thumbDir, statePath
local pendingApply = nil
local pendingToday = nil
local thumbQueue = {}
local thumbBusy = false
local statusClearAt = 0
local retryAt = 0
local retryDelay = RETRY_MIN_SECONDS
local shownDay = ""

local function sh(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  return value == nil and fallback or value
end

local function today()
  return noctalia.formatTime("%Y-%m-%d")
end

local function publish()
  data.current = state.current
  noctalia.state.set("boringday.data", data)
end

local function persist()
  if statePath == nil then
    return
  end
  noctalia.writeFile(statePath, model.stateJson(state))
end

local function flash(text)
  data.status = text
  statusClearAt = os.time() + FLASH_SECONDS
  publish()
end

-- A failure from the command line has nobody watching the panel, so it also
-- raises a notification; one from the panel is shown there.
local function fail(text, reason)
  data.status = ""
  statusClearAt = 0
  data.lastError = text
  publish()
  if reason == "cli" then
    noctalia.notifyError(noctalia.tr("title"), text)
  end
end

local function begin(text)
  data.lastError = ""
  data.status = text
  statusClearAt = 0
  publish()
end

-- ------------------------------------------------------------------- shell

-- Fetch with a byte ceiling curl enforces mid-download, then check the
-- file's own magic bytes: a response that is not a jpeg/png/gif/webp is not
-- going near the wallpaper daemon. $1 url, $2 out, $3 max bytes.
local FETCH = [[
fetch_image() {
  url=$1; out=$2; max=$3
  tmp=$(mktemp "$out.XXXXXX") || return 1
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL --proto '=https' --proto-redir '=https' --max-redirs 5 \
    --max-filesize "$max" --max-time 120 -o "$tmp" -- "$url" || return 1
  magic=$(head -c 12 "$tmp" | od -An -tx1 | tr -d ' \n')
  case $magic in
    ffd8ff*|89504e47*|47494638*|52494646????????57454250*) ;;
    *) return 3 ;;
  esac
  chmod 644 "$tmp"
  mv -f "$tmp" "$out"
}
]]

-- Oldest first, never `spare`, and never a download still in flight (its
-- temp file is the newest thing in the directory, so it sorts last anyway).
local function prune(dir, keep, spare)
  local names = noctalia.listDir(dir)
  if type(names) ~= "table" or #names <= keep then
    return
  end
  local files = {}
  for _, name in ipairs(names) do
    local path = dir .. "/" .. name
    local info = noctalia.fileInfo(path)
    if type(info) == "table" and not info.isDir and path ~= spare then
      table.insert(files, { path = path, mtime = info.mtime or 0 })
    end
  end
  table.sort(files, function(a, b) return a.mtime > b.mtime end)
  for i = keep + 1, #files do
    noctalia.removeFile(files[i].path)
  end
end

local function wallpaperPath(piece)
  return wallpaperDir .. "/" .. piece.id .. model.extensionFor(piece.url)
end

-- ------------------------------------------------------------- thumbnails

local function thumbPath(piece)
  return thumbDir .. "/" .. piece.id .. model.extensionFor(piece.thumbnailUrl)
end

local function pumpThumbs()
  while not thumbBusy and #thumbQueue > 0 do
    local piece = table.remove(thumbQueue, 1)
    local dest = thumbPath(piece)
    if noctalia.fileExists(dest) then
      data.thumbs[piece.id] = dest
      publish()
    else
      thumbBusy = true
      local limit = piece.thumbnailIsOriginal and model.MAX_IMAGE_BYTES or model.MAX_THUMB_BYTES
      local command = FETCH .. "fetch_image " .. sh(piece.thumbnailUrl) .. " " .. sh(dest) .. " " .. limit
      local started = noctalia.runAsync(command, function(result)
        thumbBusy = false
        if result ~= nil and result.exitCode == 0 then
          data.thumbs[piece.id] = dest
          publish()
        end
        pumpThumbs()
      end, 150000)
      if not started then
        -- The host would not start a process; the next refresh tries again.
        thumbBusy = false
        thumbQueue = {}
      end
    end
  end
end

-- Only the listed pieces (and the current one) keep a thumbnail entry, so the
-- published map stays small and never points at a file prune() removed.
local function fetchThumbnails()
  if thumbDir == nil then
    return
  end
  local wanted = table.clone(data.pieces)
  if state.current then
    table.insert(wanted, state.current)
  end
  local thumbs, queued = {}, {}
  thumbQueue = {}
  for _, piece in ipairs(wanted) do
    if data.thumbs[piece.id] ~= nil then
      thumbs[piece.id] = data.thumbs[piece.id]
    elseif not queued[piece.id] then
      queued[piece.id] = true
      table.insert(thumbQueue, piece)
    end
  end
  data.thumbs = thumbs
  pumpThumbs()
  prune(thumbDir, KEEP_THUMBS, nil)
end

-- -------------------------------------------------------------- the list

local function ensureCurrentListed()
  local cur = state.current
  if cur == nil then
    return
  end
  for _, piece in ipairs(data.pieces) do
    if piece.id == cur.id then
      return
    end
  end
  if #data.pieces >= PIECE_LIMIT then
    table.remove(data.pieces)
  end
  table.insert(data.pieces, cur)
end

-- The set is cached with the day it was fetched for. Once that day has
-- passed its first piece is no longer today's, so the flag comes off rather
-- than the panel calling yesterday "Today".
local function showSet(pieces, day)
  shownDay = today()
  local stale = day ~= shownDay
  local list = {}
  for i = 1, math.min(#pieces, PIECE_LIMIT) do
    local piece = table.clone(pieces[i])
    if stale then
      piece.isToday = false
    end
    table.insert(list, piece)
  end
  data.pieces = list
  ensureCurrentListed()
end

local apply

local function refresh(reason)
  if data.fetching then
    return
  end
  data.fetching = true
  begin(noctalia.tr("loading"))
  local function failed(text)
    data.fetching = false
    retryAt = os.time() + retryDelay
    retryDelay = math.min(retryDelay * 2, RETRY_MAX_SECONDS)
    local waiting = pendingToday
    pendingToday = nil
    fail(text, waiting or reason)
  end
  local started = noctalia.http({ url = model.API_TRIPLE, method = "GET" }, function(res)
    if res == nil or not res.ok or res.status ~= 200 then
      return failed(noctalia.tr("error.fetch"))
    end
    local ok, pieces = pcall(model.parseTriple, res.body or "")
    if not ok or #pieces == 0 then
      return failed(noctalia.tr("error.unreadable"))
    end
    data.fetching = false
    data.status = ""
    retryAt = 0
    retryDelay = RETRY_MIN_SECONDS
    while #pieces > PIECE_LIMIT do
      table.remove(pieces)
    end
    state.pieces = pieces
    state.fetchedDay = today()
    persist()
    showSet(pieces, state.fetchedDay)
    publish()
    fetchThumbnails()
    local waiting = pendingToday
    pendingToday = nil
    if waiting ~= nil and pieces[1].isToday then
      apply(pieces[1], waiting)
    end
  end)
  if not started then
    failed(noctalia.tr("error.fetch"))
  end
end

-- ------------------------------------------------------------------ apply

local function recordApplied(piece, reason)
  state.current = piece
  state.recentIds = model.pushRecent(state.recentIds, piece.id, 5)
  persist()
  -- A shuffled piece is not in today's set; list it so the panel shows what
  -- is on the wall, with its thumbnail.
  ensureCurrentListed()
  publish()
  fetchThumbnails()
  -- A click in the panel gets its feedback from the panel; notify only for
  -- changes nobody is looking at.
  if cfg("notify", true) == true and reason == "cli" then
    noctalia.notify(piece.name, model.subtitle(piece))
  end
end

apply = function(piece, reason)
  if piece == nil or piece.url == nil then
    return
  end
  if wallpaperDir == nil then
    return fail(noctalia.tr("error.data_dir"), reason)
  end
  if data.applying then
    pendingApply = { piece = piece, reason = reason }
    return
  end
  local out = wallpaperPath(piece)
  if out:find("%s") then
    return fail(noctalia.tr("error.set"), reason)
  end
  data.applying = true
  begin(noctalia.tr("setting", { name = piece.name }))
  -- A cached copy is reused; touching it keeps prune() off what is on the wall.
  local script = FETCH
    .. "set -e\n"
    .. "out=" .. sh(out) .. "\n"
    .. "[ -s \"$out\" ] || fetch_image " .. sh(piece.url) .. " \"$out\" " .. model.MAX_IMAGE_BYTES .. "\n"
    .. "touch \"$out\"\n"
    .. "noctalia msg wallpaper-set \"$out\"\n"
  local started = noctalia.runAsync(script, function(result)
    data.applying = false
    data.status = ""
    if result ~= nil and result.exitCode == 0 and not noctalia.string.trim(result.stdout or ""):find("^error") then
      recordApplied(piece, reason)
      prune(wallpaperDir, KEEP_WALLPAPERS, out)
    else
      fail(noctalia.tr("error.set"), reason)
    end
    local queued = pendingApply
    pendingApply = nil
    if queued then
      apply(queued.piece, queued.reason)
    end
  end, 300000)
  if not started then
    data.applying = false
    fail(noctalia.tr("error.set"), reason)
  end
end

-- Before today's set has loaded, fetch it and set today's piece once it lands.
local function applyToday(reason)
  local first = data.pieces[1]
  if first ~= nil and first.isToday and state.fetchedDay == today() then
    apply(first, reason)
  else
    pendingToday = reason
    refresh(reason)
  end
end

local function seen(id)
  for _, v in ipairs(state.recentIds) do
    if v == id then
      return true
    end
  end
  return false
end

-- Ask the random endpoint, retrying a few times if it hands back something we
-- just set. A shuffle that lands while another piece is being set queues
-- behind it rather than being dropped.
local function shuffle(reason)
  if data.shuffling then
    return
  end
  data.shuffling = true
  begin(noctalia.tr("finding"))
  local attempts = 0
  local function ask()
    attempts += 1
    local started = noctalia.http({ url = model.API_RANDOM, method = "GET" }, function(res)
      if res == nil or not res.ok or res.status ~= 200 then
        data.shuffling = false
        return fail(noctalia.tr("error.fetch"), reason)
      end
      local ok, piece = pcall(model.parseOne, res.body or "")
      if not ok or piece == nil then
        data.shuffling = false
        return fail(noctalia.tr("error.unreadable"), reason)
      end
      if seen(piece.id) and attempts < SHUFFLE_ATTEMPTS then
        return ask()
      end
      data.shuffling = false
      data.status = ""
      apply(piece, reason)
    end)
    if not started then
      data.shuffling = false
      fail(noctalia.tr("error.fetch"), reason)
    end
  end
  ask()
end

-- --------------------------------------------------------- save / open

-- The wallpaper cache usually already holds the full image (it is on the
-- wall, or was recently), so a save is a local copy; otherwise it downloads.
local function savePiece(piece, reason)
  if piece == nil or data.saving then
    return
  end
  data.saving = true
  begin(noctalia.tr("saving", { name = piece.name }))
  local cached = wallpaperDir ~= nil and wallpaperPath(piece) or ""
  local script = FETCH
    .. "set -e\n"
    .. "name=" .. sh(model.downloadName(piece)) .. "\n"
    .. "cached=" .. sh(cached) .. "\n"
    .. "dir=$(xdg-user-dir PICTURES 2>/dev/null || true)\n"
    .. "if [ -z \"${dir:-}\" ] || [ \"$dir\" = \"$HOME\" ]; then dir=\"$HOME/Pictures\"; fi\n"
    .. "mkdir -p \"$dir\"\n"
    .. "out=\"$dir/$name\"; n=2\n"
    .. "while [ -e \"$out\" ]; do out=\"$dir/${name%.*}-$n.${name##*.}\"; n=$((n + 1)); done\n"
    .. "if [ -n \"$cached\" ] && [ -s \"$cached\" ]; then cp -- \"$cached\" \"$out\"\n"
    .. "else fetch_image " .. sh(piece.url) .. " \"$out\" " .. model.MAX_IMAGE_BYTES .. "; fi\n"
    .. "printf '%s' \"$out\"\n"
  local started = noctalia.runAsync(script, function(result)
    data.saving = false
    local path = noctalia.string.trim(result ~= nil and result.stdout or "")
    if result ~= nil and result.exitCode == 0 and path ~= "" then
      path = path:sub(1, 400)
      flash(noctalia.tr("saved", { path = path }))
      if reason == "cli" then
        noctalia.notify(noctalia.tr("title"), noctalia.tr("saved", { path = path }))
      end
    else
      fail(noctalia.tr("error.save"), reason)
    end
  end, 180000)
  if not started then
    data.saving = false
    fail(noctalia.tr("error.save"), reason)
  end
end

local function openPage(piece)
  if piece ~= nil and model.boundedUrl(piece.artPage) ~= "" then
    noctalia.runAsync("xdg-open " .. sh(piece.artPage))
  end
end

local function findPiece(id)
  for _, piece in ipairs(data.pieces) do
    if piece.id == id then
      return piece
    end
  end
  if state.current and state.current.id == id then
    return state.current
  end
  return nil
end

-- ------------------------------------------------------------------ tick

-- A new calendar day means a new piece of the day: yesterday's loses its
-- "Today" mark at once (even offline), and today's set is fetched, retried on
-- a backoff if that fails.
function update()
  local now = os.time()
  if statusClearAt > 0 and now >= statusClearAt then
    statusClearAt = 0
    data.status = ""
    publish()
  end
  if dataDir ~= nil and shownDay ~= today() then
    showSet(state.pieces, state.fetchedDay)
    publish()
    fetchThumbnails()
  end
  if dataDir ~= nil and not data.fetching and state.fetchedDay ~= today() and now >= retryAt then
    refresh(nil)
  end
end

-- ------------------------------------------------------------- commands

local function command(cmd)
  local op = cmd.op
  if op == "refresh" then
    refresh(nil)
  elseif op == "set" then
    apply(findPiece(cmd.id), "set")
  elseif op == "shuffle" then
    shuffle("shuffle")
  elseif op == "today" then
    applyToday("today")
  elseif op == "save" then
    savePiece(findPiece(cmd.id), "save")
  elseif op == "open" then
    openPage(findPiece(cmd.id) or state.current)
  end
end

noctalia.state.watch("boringday.cmd", function(value)
  if type(value) == "table" then
    command(value)
    noctalia.state.set("boringday.cmd", nil)
  end
end)

-- noctalia msg plugin johnschmidt/boringday:service all <event>
function onIpc(event, _payload)
  if event == "random" then
    shuffle("cli")
  elseif event == "today" then
    applyToday("cli")
  elseif event == "refresh" then
    refresh("cli")
  elseif event == "save" then
    savePiece(state.current, "cli")
  elseif event == "open" then
    openPage(state.current)
  end
end

-- The last fetched set is shown straight away, with whatever thumbnails are
-- already on disk, so the panel is useful before (or without) the network.
-- If it is not today's, the first tick fetches today's.
local function init()
  dataDir = noctalia.pluginDataDir()
  if dataDir == nil then
    data.lastError = noctalia.tr("error.data_dir")
    publish()
    return
  end
  wallpaperDir = dataDir .. "/wallpapers"
  thumbDir = dataDir .. "/thumbs"
  statePath = dataDir .. "/state.json"
  noctalia.mkdirAll(wallpaperDir)
  noctalia.mkdirAll(thumbDir)
  local text = noctalia.readFile(statePath)
  if type(text) == "string" then
    state = model.parseState(text)
  end
  showSet(state.pieces, state.fetchedDay)
  publish()
  fetchThumbnails()
end

noctalia.setUpdateInterval(TICK_MS)
init()
