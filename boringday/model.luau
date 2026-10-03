--!nonstrict
-- Pure helpers for the anotherboring.day plugin: endpoints, URL rewriting,
-- response parsing and state (de)serialization. A port of Model.js from the
-- Omarchy plugin. Nothing here talks to the host, so the fiddly parts —
-- thumbnail transforms, malformed payloads — can be reasoned about alone.

local M = {}

M.API_TRIPLE = "https://service.anotherboring.day/api/wallpapers/raycast-triple"
M.API_RANDOM = "https://service.anotherboring.day/api/wallpapers/random-human"
M.ART_PAGE = "https://anotherboring.day/art/"

-- The host's JSON codec; tools/model_test.luau swaps in a stub.
M.json = noctalia ~= nil and noctalia.json or nil

-- Everything off the network is treated as hostile, so every payload has a
-- ceiling. Byte ceilings are enforced by curl mid-download; the rest here.
M.MAX_JSON_CHARS = 256 * 1024
-- The state file caches the last set, descriptions and all; JSON escaping can
-- inflate non-ASCII text several times over.
M.MAX_STATE_CHARS = 512 * 1024
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

-- ----------------------------------------------------------------- sanitizing

local function cut(s: string, max: number): string
  if #s <= max then
    return s
  end
  s = s:sub(1, max)
  -- Do not leave half a UTF-8 sequence at the end. Walk back over trailing
  -- continuation bytes to the lead byte, and drop the sequence only when it
  -- is incomplete.
  local i = #s
  while i > 1 and i > #s - 3 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do
    i -= 1
  end
  local lead = s:byte(i)
  if lead >= 0xC0 then
    local need = lead < 0xE0 and 2 or lead < 0xF0 and 3 or 4
    if #s - i + 1 < need then
      s = s:sub(1, i - 1)
    end
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
    local head = url:match("^(.*)/[^/]+$")
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
  return M.json.decode(text)
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

local function restore(raw)
  local piece = M.normalize(raw)
  if piece then
    piece.isToday = raw.isToday == true
  end
  return piece
end

-- A corrupt or absent state file degrades to empty state. Every cached piece
-- goes through normalize() like a fresh API record: it is handed to curl.
function M.parseState(text)
  local empty = { recentIds = {}, current = nil, pieces = {}, fetchedDay = "" }
  local ok, json = pcall(decode, text, M.MAX_STATE_CHARS)
  if not ok or type(json) ~= "table" then
    return empty
  end
  local ids = {}
  for _, v in ipairs(type(json.recentIds) == "table" and json.recentIds or {}) do
    if #ids >= M.MAX_RECENT then
      break
    end
    if M.isSafeId(v) then
      table.insert(ids, v)
    end
  end
  local pieces = {}
  for _, raw in ipairs(type(json.pieces) == "table" and json.pieces or {}) do
    if #pieces >= M.MAX_PIECES then
      break
    end
    local piece = restore(raw)
    if piece then
      table.insert(pieces, piece)
    end
  end
  local day = type(json.fetchedDay) == "string" and json.fetchedDay:match("^%d%d%d%d%-%d%d%-%d%d$") or ""
  return { recentIds = ids, current = M.normalize(json.current), pieces = pieces, fetchedDay = day }
end

function M.stateJson(state)
  return M.json.encode({
    version = 2,
    recentIds = state.recentIds or {},
    current = state.current,
    pieces = state.pieces or {},
    fetchedDay = state.fetchedDay or "",
  })
end

return M
