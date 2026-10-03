--!nonstrict
-- Offline checks for model.luau. Needs only the stock `luau` binary
-- (https://github.com/luau-lang/luau/releases):
--
--   luau boringday/tools/model_test.luau
--
-- The JSON codec (model.json) is stubbed with a lookup table: decode() hands
-- back whatever fixture was registered under the text, encode() registers its
-- argument, so a stateJson -> parseState round trip goes through the real
-- field handling.

local fixtures = {}
local encoded = 0
local stub = {
  decode = function(text) return fixtures[text] end,
  encode = function(value)
    encoded += 1
    local key = "encoded:" .. encoded
    fixtures[key] = value
    return key
  end,
}

local M = require("../model")
M.json = stub

local failures = 0
local function check(name, cond)
  if not cond then
    failures += 1
    print("FAIL " .. name)
  end
end

-- boundedText / UTF-8 truncation
check("ascii cut", M.boundedText("abcdef", 3, "x") == "abc")
check("complete 2-byte kept", M.boundedText("aé", 3, "x") == "aé")
check("half 2-byte dropped", M.boundedText("abé", 3, "x") == "ab")
check("partial 3-byte dropped", M.boundedText("ab€", 4, "x") == "ab")
check("partial 4-byte dropped", M.boundedText("a😀", 4, "x") == "a")
check("complete 4-byte kept", M.boundedText("a😀", 5, "x") == "a😀")
check("long multibyte stays valid", utf8.len(M.boundedText(string.rep("é", 100), 51, "x")) == 25)
check("control chars and markup stripped", M.boundedText("a<b>\nc", 50, "x") == "a b c")
check("blank falls back", M.boundedText("  \t ", 50, "x") == "x")
check("table falls back", M.boundedText({}, 50, "x") == "x")

-- boundedUrl
check("https kept", M.boundedUrl("https://a.b/c.jpg") == "https://a.b/c.jpg")
check("http rejected", M.boundedUrl("http://a.b/c.jpg") == "")
check("file rejected", M.boundedUrl("file:///etc/passwd") == "")
check("space rejected", M.boundedUrl("https://a.b/c d.jpg") == "")
check("newline rejected", M.boundedUrl("https://a.b/c\nd") == "")

-- ids
check("safe id", M.isSafeId("abc_DEF-123"))
check("dotted id rejected", not M.isSafeId("../x"))
check("empty id rejected", not M.isSafeId(""))

-- thumbnails and extensions
check("cloudinary resized",
  M.thumbnailUrl("https://res.cloudinary.com/x/image/upload/v1/a.jpg", 640)
    == "https://res.cloudinary.com/x/image/upload/w_640,c_limit,q_auto,f_auto/v1/a.jpg")
check("cloudflare resized",
  M.thumbnailUrl("https://imagedelivery.net/h/id/public", 640) == "https://imagedelivery.net/h/id/w=640,fit=contain")
check("other host untouched", M.thumbnailUrl("https://x.y/a.png", 640) == "https://x.y/a.png")
check("extension from path", M.extensionFor("https://x.y/a.PNG?v=1") == ".png")
check("variant name defaults to jpg", M.extensionFor("https://imagedelivery.net/h/id/public") == ".jpg")
check("odd extension defaults to jpg", M.extensionFor("https://x.y/a.exe") == ".jpg")

-- download names
check("download name", M.downloadName({ id = "abc", name = "The Starry Night", url = "https://x.y/a.png" })
  == "The-Starry-Night-abc.png")
check("unnamed download", M.downloadName({ id = "abc", name = "???", url = "https://x.y/a" }) == "wallpaper-abc.jpg")

-- recent ids
local recent = M.pushRecent({ "a", "b", "c" }, "b", 3)
check("recent moves to front", recent[1] == "b" and recent[2] == "a" and recent[3] == "c")
check("recent capped", #M.pushRecent({ "a", "b", "c", "d" }, "e", 2) == 2)

-- parsing the API
local function raw(id, extra)
  local r = { id = id, url = "https://x.y/" .. id .. ".jpg", name = "Piece " .. id, artist = "Someone" }
  for k, v in pairs(extra or {}) do
    r[k] = v
  end
  return r
end
fixtures.triple = { today = raw("t"), random = { raw("t"), raw("r1"), { id = "bad id" }, raw("r2") } }
local set = M.parseTriple("triple")
check("today first", set[1].id == "t" and set[1].isToday)
check("today not repeated, junk dropped", #set == 3 and set[2].id == "r1" and set[3].id == "r2")
check("random not today", not set[2].isToday)
check("unreadable triple is empty", #M.parseTriple("nope") == 0)
check("oversized payload refused", #M.parseTriple(string.rep(" ", M.MAX_JSON_CHARS + 1)) == 0)
fixtures.one = raw("o", { url = "javascript:alert(1)" })
check("unsafe url drops record", M.parseOne("one") == nil)

-- state round trip
local state = {
  recentIds = { "t", "r1" },
  current = set[2],
  pieces = set,
  fetchedDay = "2026-10-03",
}
local back = M.parseState(M.stateJson(state))
check("state current", back.current ~= nil and back.current.id == "r1")
check("state pieces", #back.pieces == 3 and back.pieces[1].isToday and not back.pieces[2].isToday)
check("state day", back.fetchedDay == "2026-10-03")
check("state recent", #back.recentIds == 2)
fixtures.badstate = { recentIds = { "ok", "../no" }, fetchedDay = "tomorrow", pieces = { { id = "x" } } }
local bad = M.parseState("badstate")
check("bad state ids filtered", #bad.recentIds == 1)
check("bad state day dropped", bad.fetchedDay == "")
check("bad state pieces dropped", #bad.pieces == 0)
check("corrupt state is empty", #M.parseState("garbage").pieces == 0)

if failures > 0 then
  error(failures .. " check(s) failed", 0)
end
print("model: all checks passed")
