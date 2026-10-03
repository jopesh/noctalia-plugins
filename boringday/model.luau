--!nonstrict
-- Pure helpers for the anotherboring.day plugin: endpoints, URL rewriting,
-- response parsing and state (de)serialization. A port of Model.js from the
-- Omarchy plugin. Nothing here talks to the host, so the fiddly parts —
-- thumbnail transforms, malformed payloads, an interval typed by hand — can be
-- reasoned about alone.

local M = {}

M.API_TRIPLE = "https://service.anotherboring.day/api/wallpapers/raycast-triple"
M.API_RANDOM = "https://service.anotherboring.day/api/wallpapers/random-human"
M.ART_PAGE = "https://anotherboring.day/art/"

M.INTERVALS = { 3600, 10800, 43200, 86400 }
M.MIN_INTERVAL = 300
M.MAX_INTERVAL = 86400

-- Everything off the network is treated as hostile, so every payload has a
-- ceiling. Byte ceilings are enforced by curl mid-download; the rest here.
M.MAX_JSON_CHARS = 256 * 1024
M.MAX_STATE_CHARS = 64 * 1024
M.MAX_THUMB_BYTES = 8 * 1024 * 1024
M.MAX_IMAGE_BYTES = 64 * 1024 * 1024
M.MAX_ID_CHARS = 64
M.MAX_NAME_CHARS = 200
M.MAX_LINE_CHARS = 120
M.MAX_DESCRIPTION_CHARS = 4000
M.MAX_URL_CHARS = 2048
M.MAX_SCANNED_RECORDS = 32
M.MAX_PIECES = 8
M.MAX_RECENT = 10

function M.clampInterval(seconds)
  local n = tonumber(seconds)
  if n == nil or n ~= n or n <= 0 or n == math.huge then
    return 3600
  end
  return math.max(M.MIN_INTERVAL, math.min(M.MAX_INTERVAL, math.floor(n + 0.5)))
end

local function plural(count, unit)
  return count .. " " .. unit .. (count == 1 and "" or "s")
end

function M.intervalLabel(seconds)
  local n = M.clampInterval(seconds)
  if n % 3600 == 0 then
    return plural(n // 3600, "hour")
  elseif n % 60 == 0 then
    return plural(n // 60, "minute")
  end
  return plural(n, "second")
end

-- Reads after "every": "every hour", not "every 1 hour".
function M.everyLabel(seconds)
  local n = M.clampInterval(seconds)
  return n == 3600 and "hour" or M.intervalLabel(n)
end

-- 0-based index of the preset, or -1 for a hand-typed value, so no chip is
-- selected rather than the wrong one.
function M.intervalIndex(seconds)
  local n = M.clampInterval(seconds)
  for i, v in ipairs(M.INTERVALS) do
    if v == n then
      return i - 1
    end
  end
  return -1
end

-- An off-preset value snaps to the first preset larger than it.
function M.nextInterval(seconds)
  local n = M.clampInterval(seconds)
  for _, v in ipairs(M.INTERVALS) do
    if v > n then
      return v
    end
  end
  return M.INTERVALS[1]
end

-- ----------------------------------------------------------------- sanitizing

local function cut(s, max)
  if #s <= max then
    return s
  end
  s = s:sub(1, max)
  -- Do not leave half a UTF-8 sequence at the end.
  while #s > 0 and not utf8.len(s) do
    s = s:sub(1, #s - 1)
  end
  return s
end

-- Control characters and angle brackets are stripped at the boundary: a title
-- is a title, not markup, and these strings reach surfaces (tooltips,
-- notification bodies) that decide for themselves whether it looks like rich
-- text.
function M.boundedText(value, max, fallback)
  if value == nil or type(value) == "table" then
    return fallback
  end
  local s = tostring(value):gsub("[%c<>]+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    return fallback
  end
  return cut(s, max)
end

-- Only https survives, and only the characters a URL is made of: that rules
-- out a newline or space in a curl argument as much as file:// and data:.
function M.boundedUrl(value)
  if type(value) ~= "string" or #value == 0 or #value > M.MAX_URL_CHARS then
    return ""
  end
  if not value:match("^https://[%w%._~:/%?#%[%]@!$&'%(%)%*%+,;=%%%-]+$") then
    return ""
  end
  return value
end

function M.isSafeId(id)
  return type(id) == "string" and #id >= 1 and #id <= M.MAX_ID_CHARS and id:match("^[%w_%-]+$") ~= nil
end

-- anotherboring.day serves images from two CDNs, each with its own resize
-- syntax. Anything else is handed back untouched.
function M.thumbnailUrl(url, width)
  if type(url) ~= "string" or url == "" then
    return ""
  end
  local w = math.max(1, math.floor(tonumber(width) or 640))
  if url:find("cloudinary.com", 1, true) and url:find("/upload/", 1, true) then
    local a, b = url:find("/upload/", 1, true)
    return url:sub(1, a - 1) .. "/upload/w_" .. w .. ",c_limit,q_auto,f_auto/" .. url:sub(b + 1)
  end
  if url:find("imagedelivery.net", 1, true) then
    local head, last = url:match("^(.*)/([^/]+)$")
    if head then
      return head .. "/w=" .. w .. ",fit=contain"
    end
  end
  return url
end

-- Cloudflare Images URLs end in a variant name rather than an extension.
function M.extensionFor(url)
  local path = tostring(url or ""):gsub("[?#].*$", "")
  local last = path:match("([^/]*)$") or ""
  local ext = last:match("^.+(%.[%w]+)$")
  if ext == nil then
    return ".jpg"
  end
  ext = ext:lower()
  local ok = { [".jpg"] = 1, [".jpeg"] = 1, [".png"] = 1, [".webp"] = 1, [".gif"] = 1, [".bmp"] = 1, [".avif"] = 1 }
  return ok[ext] and ext or ".jpg"
end

function M.normalize(raw)
  if type(raw) ~= "table" or not M.isSafeId(raw.id) then
    return nil
  end
  local url = M.boundedUrl(raw.url)
  if url == "" then
    return nil
  end
  local thumb = M.thumbnailUrl(url, 640)
  return {
    id = raw.id,
    name = M.boundedText(raw.name, M.MAX_NAME_CHARS, "Untitled"),
    artist = M.boundedText(raw.artist, M.MAX_LINE_CHARS, "Unknown artist"),
    creationDate = M.boundedText(raw.creationDate, M.MAX_LINE_CHARS, ""),
    description = M.boundedText(raw.description, M.MAX_DESCRIPTION_CHARS, ""),
    movement = M.boundedText(raw.movement, M.MAX_LINE_CHARS, ""),
    genre = M.boundedText(raw.genre, M.MAX_LINE_CHARS, ""),
    url = url,
    thumbnailUrl = thumb,
    thumbnailIsOriginal = thumb == url,
    artPage = M.ART_PAGE .. raw.id,
    isToday = false,
  }
end

local function decode(text, maxChars)
  if type(text) ~= "string" or #text > maxChars then
    return nil
  end
  return noctalia.json.decode(text)
end

-- The triple endpoint returns { today, random = [...] }. Today comes first.
function M.parseTriple(text)
  local json = decode(text, M.MAX_JSON_CHARS)
  if type(json) ~= "table" then
    return {}
  end
  local out = {}
  local today = M.normalize(json.today)
  if today then
    today.isToday = true
    table.insert(out, today)
  end
  local list = type(json.random) == "table" and json.random or {}
  for i = 1, math.min(#list, M.MAX_SCANNED_RECORDS) do
    if #out >= M.MAX_PIECES then
      break
    end
    local piece = M.normalize(list[i])
    if piece and not (today and piece.id == today.id) then
      table.insert(out, piece)
    end
  end
  return out
end

function M.parseOne(text)
  return M.normalize(decode(text, M.MAX_JSON_CHARS))
end

function M.subtitle(piece)
  if not piece then
    return ""
  end
  if piece.creationDate ~= "" then
    return piece.artist .. "  ·  " .. piece.creationDate
  end
  return piece.artist
end

function M.credit(piece)
  if not piece then
    return ""
  end
  if piece.creationDate == "" then
    return piece.artist
  end
  return piece.artist .. ", " .. piece.creationDate
end

function M.tags(piece)
  local out = {}
  if piece then
    if piece.movement ~= "" then
      table.insert(out, piece.movement)
    end
    if piece.genre ~= "" then
      table.insert(out, piece.genre)
    end
  end
  return out
end

-- A file name a human recognizes in ~/Pictures, with the id appended so two
-- pieces sharing a title never overwrite each other.
function M.downloadName(piece)
  if not piece then
    return "wallpaper.jpg"
  end
  local base = tostring(piece.name or "wallpaper"):gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  base = base:sub(1, 60)
  if base == "" then
    base = "wallpaper"
  end
  return base .. "-" .. piece.id .. M.extensionFor(piece.url)
end

function M.pushRecent(ids, id, cap)
  local limit = math.min(tonumber(cap) or 5, M.MAX_RECENT)
  local out = {}
  if M.isSafeId(id) then
    table.insert(out, id)
  end
  for _, v in ipairs(type(ids) == "table" and ids or {}) do
    if #out >= limit then
      break
    end
    if v ~= id and M.isSafeId(v) then
      table.insert(out, v)
    end
  end
  return out
end

-- A corrupt or absent state file degrades to empty state. `current` goes
-- through normalize() like a fresh API record: it is handed to curl. A
-- timestamp in the future would park rotation, so it is clamped to now.
function M.parseState(text, now)
  local empty = { lastSwitchAt = 0, recentIds = {}, current = nil }
  local ok, json = pcall(decode, text, M.MAX_STATE_CHARS)
  if not ok or type(json) ~= "table" then
    return empty
  end
  local when = tonumber(json.lastSwitchAt) or 0
  local ids = {}
  for _, v in ipairs(type(json.recentIds) == "table" and json.recentIds or {}) do
    if #ids >= M.MAX_RECENT then
      break
    end
    if M.isSafeId(v) then
      table.insert(ids, v)
    end
  end
  local state = {
    lastSwitchAt = when > 0 and math.min(when, now) or 0,
    recentIds = ids,
    current = M.normalize(json.current),
  }
  if type(json.autoRotate) == "boolean" then
    state.autoRotate = json.autoRotate
  end
  if tonumber(json.intervalSeconds) then
    state.intervalSeconds = M.clampInterval(json.intervalSeconds)
  end
  return state
end

function M.stateJson(state)
  return noctalia.json.encode({
    version = 1,
    lastSwitchAt = tonumber(state.lastSwitchAt) or 0,
    recentIds = state.recentIds or {},
    current = state.current,
    autoRotate = state.autoRotate,
    intervalSeconds = state.intervalSeconds,
  })
end

return M
