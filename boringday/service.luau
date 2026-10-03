--!nonstrict
-- Headless half of the plugin: owns every fetch, every download and what is
-- currently set. The bar widget and panel are views onto it via
-- boringday.data, so work started from the panel finishes with it closed.

local model = require("./model.luau")

-- Only clears the transient status line, so it can be short and cheap.
local TICK_MS = 1000
local PIECE_LIMIT = 3
local SHUFFLE_ATTEMPTS = 4
local KEEP_WALLPAPERS = 20
local KEEP_THUMBS = 60

local data = {
  pieces = {},
  thumbs = {},
  current = nil,
  status = "",
  lastError = "",
  applying = false,
}

local state = { recentIds = {}, current = nil }
local dataDir, wallpaperDir, thumbDir, statePath
local pendingApply = nil
local pendingToday = nil
local fetching = false
local shuffling = false
local saving = false
local thumbQueue = {}
local thumbBusy = false
local statusClearAt = 0

local function sh(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  return value == nil and fallback or value
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
  statusClearAt = os.time() + 6
  publish()
end

local function fail(text)
  data.status = ""
  statusClearAt = 0
  data.lastError = text
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

-- ------------------------------------------------------------- thumbnails

local pumpThumbs

local function thumbPath(piece)
  return thumbDir .. "/" .. piece.id .. model.extensionFor(piece.thumbnailUrl)
end

pumpThumbs = function()
  if thumbBusy or #thumbQueue == 0 then
    return
  end
  local piece = table.remove(thumbQueue, 1)
  local dest = thumbPath(piece)
  if noctalia.fileExists(dest) then
    data.thumbs[piece.id] = dest
    publish()
    return pumpThumbs()
  end
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
    thumbBusy = false
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

local apply

local function refresh()
  if fetching then
    return
  end
  fetching = true
  data.lastError = ""
  data.status = noctalia.tr("loading")
  publish()
  local started = noctalia.http({ url = model.API_TRIPLE, method = "GET" }, function(res)
    fetching = false
    data.status = ""
    if res == nil or not res.ok or res.status ~= 200 then
      pendingToday = nil
      return fail(noctalia.tr("error.fetch"))
    end
    local ok, pieces = pcall(model.parseTriple, res.body or "")
    if not ok or #pieces == 0 then
      pendingToday = nil
      return fail(noctalia.tr("error.unreadable"))
    end
    while #pieces > PIECE_LIMIT do
      table.remove(pieces)
    end
    data.pieces = pieces
    ensureCurrentListed()
    publish()
    fetchThumbnails()
    local reason = pendingToday
    pendingToday = nil
    if reason ~= nil and pieces[1].isToday then
      apply(pieces[1], reason)
    end
  end)
  if not started then
    fetching = false
    pendingToday = nil
    fail(noctalia.tr("error.fetch"))
  end
end

-- ------------------------------------------------------------------ apply

local function notifyChange(piece)
  noctalia.notify(piece.name, model.subtitle(piece))
end

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
    notifyChange(piece)
  end
end

apply = function(piece, reason)
  if piece == nil or piece.url == nil then
    return
  end
  if wallpaperDir == nil then
    return fail(noctalia.tr("error.data_dir"))
  end
  if data.applying then
    pendingApply = { piece = piece, reason = reason }
    return
  end
  local out = wallpaperDir .. "/" .. piece.id .. model.extensionFor(piece.url)
  if out:find("%s") then
    return fail(noctalia.tr("error.set"))
  end
  data.applying = true
  data.lastError = ""
  data.status = noctalia.tr("setting", { name = piece.name })
  publish()
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
      data.lastError = noctalia.tr("error.set")
      publish()
    end
    local queued = pendingApply
    pendingApply = nil
    if queued then
      apply(queued.piece, queued.reason)
    end
  end, 300000)
  if not started then
    data.applying = false
    data.status = ""
    fail(noctalia.tr("error.set"))
  end
end

-- Before today's set has loaded, fetch it and set today's piece once it lands.
local function applyToday(reason)
  local today = data.pieces[1]
  if today ~= nil and today.isToday then
    apply(today, reason)
  else
    pendingToday = reason
    refresh()
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
-- just set.
local function shuffle(reason)
  if shuffling or data.applying then
    return
  end
  shuffling = true
  data.lastError = ""
  data.status = noctalia.tr("finding")
  publish()
  local attempts = 0
  local function ask()
    attempts = attempts + 1
    local started = noctalia.http({ url = model.API_RANDOM, method = "GET" }, function(res)
      if res == nil or not res.ok or res.status ~= 200 then
        shuffling = false
        data.status = ""
        return fail(noctalia.tr("error.fetch"))
      end
      local ok, piece = pcall(model.parseOne, res.body or "")
      if not ok or piece == nil then
        shuffling = false
        data.status = ""
        return fail(noctalia.tr("error.unreadable"))
      end
      if seen(piece.id) and attempts < SHUFFLE_ATTEMPTS then
        return ask()
      end
      shuffling = false
      data.status = ""
      apply(piece, reason)
    end)
    if not started then
      shuffling = false
      data.status = ""
      fail(noctalia.tr("error.fetch"))
    end
  end
  ask()
end

-- --------------------------------------------------------- save / open

local function savePiece(piece)
  if piece == nil or saving then
    return
  end
  saving = true
  data.lastError = ""
  data.status = noctalia.tr("saving", { name = piece.name })
  statusClearAt = 0
  publish()
  local script = FETCH
    .. "set -e\n"
    .. "name=" .. sh(model.downloadName(piece)) .. "\n"
    .. "dir=$(xdg-user-dir PICTURES 2>/dev/null || true)\n"
    .. "if [ -z \"${dir:-}\" ] || [ \"$dir\" = \"$HOME\" ]; then dir=\"$HOME/Pictures\"; fi\n"
    .. "mkdir -p \"$dir\"\n"
    .. "out=\"$dir/$name\"; n=2\n"
    .. "while [ -e \"$out\" ]; do out=\"$dir/${name%.*}-$n.${name##*.}\"; n=$((n + 1)); done\n"
    .. "fetch_image " .. sh(piece.url) .. " \"$out\" " .. model.MAX_IMAGE_BYTES .. "\n"
    .. "printf '%s' \"$out\"\n"
  local started = noctalia.runAsync(script, function(result)
    saving = false
    local path = noctalia.string.trim(result ~= nil and result.stdout or "")
    if result ~= nil and result.exitCode == 0 and path ~= "" then
      flash(noctalia.tr("saved", { path = path:sub(1, 400) }))
    else
      fail(noctalia.tr("error.save"))
    end
  end, 180000)
  if not started then
    saving = false
    fail(noctalia.tr("error.save"))
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

function update()
  if statusClearAt > 0 and os.time() >= statusClearAt then
    statusClearAt = 0
    data.status = ""
    publish()
  end
end

-- ------------------------------------------------------------- commands

local function command(cmd)
  local op = cmd.op
  if op == "refresh" then
    refresh()
  elseif op == "set" then
    apply(findPiece(cmd.id), "set")
  elseif op == "shuffle" then
    shuffle("shuffle")
  elseif op == "today" then
    applyToday("today")
  elseif op == "save" then
    savePiece(findPiece(cmd.id))
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
    refresh()
  end
end

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
  data.current = state.current
  publish()
  refresh()
end

noctalia.setUpdateInterval(TICK_MS)
init()
