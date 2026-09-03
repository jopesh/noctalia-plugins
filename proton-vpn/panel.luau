--!nonstrict
-- Proton VPN panel — map, quick connect, location picker and CLI settings.
--
-- Everything here is a view over proton_vpn.data; the only local state is what
-- the user is doing right now (filter text, expanded countries, connect flags).

local MAP_WIDTH = 376
local MAP_HEIGHT = 144
local MAX_ROWS = 60 -- rendering every one of ~194 cities makes the scroll crawl

-- CLI value <-> option index, in the order the select shows them.
local NETSHIELD = {
  values = { "off", "malware-only", "malware-ads-trackers" },
  keys = { "features.netshield_off", "features.netshield_malware", "features.netshield_full" },
}
local KILL_SWITCH = {
  values = { "off", "standard" },
  keys = { "features.off", "features.standard" },
}

local BUSY_KEYS = {
  connect = "action.connecting",
  disconnect = "action.disconnecting",
  config = "action.working",
}

local data = noctalia.state.get("proton_vpn.data") or { status = "loading", busy = false }

local filter = ""
local expanded = {}
local flags = { p2p = false, securecore = false, tor = false }

local render -- forward declaration: the control callbacks re-render

-- ── shared bits ─────────────────────────────────────────────────────────────

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  return value == nil and fallback or value
end

local function connectedColor()
  return cfg("color_connected", "#a6e3a1")
end

local function send(cmd)
  noctalia.state.set("proton_vpn.cmd", cmd)
end

local function connect(kind, value)
  send({
    op = "connect",
    kind = kind,
    value = value,
    p2p = flags.p2p,
    securecore = flags.securecore,
    tor = flags.tor,
  })
end

-- Alpha suffixes ("primary/0.14") only work on palette roles; a hex colour
-- from the settings has to carry its alpha as #rrggbbaa instead.
local function tint(color, alpha)
  if type(color) == "string" and color:match("^#%x%x%x%x%x%x$") ~= nil then
    return color .. string.format("%02x", math.floor(alpha * 255 + 0.5))
  end
  return color .. "/" .. tostring(alpha)
end

local function statusColor()
  if data.busy then
    return "primary"
  end
  if data.status == "connected" then
    return connectedColor()
  end
  if data.status == "error" or data.status == "unavailable" or data.status == "signin_required" then
    return "error"
  end
  return "on_surface_variant"
end

local function statusText()
  if data.busy then
    return noctalia.tr(BUSY_KEYS[data.operation] or "action.working")
  end
  return noctalia.tr("status." .. tostring(data.status or "error"))
end

local function activeError()
  local err = data.error
  if type(err) ~= "table" or err.transient then
    return nil
  end
  return err.message
end

-- ── header ──────────────────────────────────────────────────────────────────

local function header()
  local color = statusColor()
  return ui.row({ gap = 9, align = "center" }, {
    ui.row({ width = 38, height = 38, radius = 10, fill = tint(color, 0.14), align = "center", justify = "center" }, {
      ui.glyph({ name = "shield-lock", size = 21, color = color }),
    }),
    ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    ui.row({ gap = 6, align = "center" }, {
      ui.box({ width = 8, height = 8, radius = 4, fill = color }),
      ui.label({ text = statusText(), color = color, fontSize = 12, fontWeight = "bold", maxLines = 1 }),
    }),
  })
end

-- ── map ─────────────────────────────────────────────────────────────────────

local function mapSection()
  if type(data.mapPath) == "string" and data.mapPath ~= "" then
    return ui.image({ key = "map", path = data.mapPath, width = MAP_WIDTH, height = MAP_HEIGHT, fit = "contain" })
  end
  return ui.column({
    key = "map",
    width = MAP_WIDTH,
    height = MAP_HEIGHT,
    radius = 10,
    fill = "on_surface_variant/0.08",
    align = "center",
    justify = "center",
    paddingH = 18,
  }, {
    ui.label({
      text = activeError() or noctalia.tr("map.loading"),
      fontSize = 11,
      color = "on_surface_variant",
      textAlign = "center",
      maxLines = 3,
    }),
  })
end

local function captionText()
  if data.busy then
    return noctalia.tr(BUSY_KEYS[data.operation] or "action.working")
  end
  local server = data.server
  if data.status ~= "connected" or type(server) ~= "table" then
    return noctalia.tr("detail.not_connected")
  end
  local parts = { server.name or data.serverName or "" }
  if server.city ~= nil and server.country ~= nil then
    table.insert(parts, noctalia.tr("detail.place", { city = server.city, country = server.country }))
  end
  if type(server.load) == "number" then
    table.insert(parts, noctalia.tr("detail.load", { load = tostring(math.floor(server.load)) }))
  end
  if server.secureCore and server.entryCode ~= nil then
    table.insert(parts, noctalia.tr("detail.secure_core", { code = server.entryCode }))
  end
  return table.concat(parts, " · ")
end

local function caption()
  return ui.label({
    text = captionText(),
    fontSize = 11,
    color = "on_surface_variant",
    textAlign = "center",
    maxLines = 1,
  })
end

-- ── banners ─────────────────────────────────────────────────────────────────

local function banner()
  local message = activeError()
  if message == nil then
    return nil
  end
  return ui.row({
    key = "error",
    gap = 6,
    align = "center",
    fill = "error/0.15",
    radius = 8,
    paddingH = 8,
    paddingV = 6,
  }, {
    ui.glyph({ name = "alert-triangle", size = 13, color = "error" }),
    ui.label({ text = message, fontSize = 11, color = "error", flexGrow = 1, maxLines = 2 }),
  })
end

local function notice()
  if type(data.notice) ~= "string" or data.notice == "" then
    return nil
  end
  return ui.row({ key = "notice", gap = 6, align = "center" }, {
    ui.glyph({ name = "info-circle", size = 12, color = "on_surface_variant" }),
    ui.label({ text = data.notice, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
  })
end

-- ── actions ─────────────────────────────────────────────────────────────────

local function primaryAction()
  if data.status == "signin_required" then
    return ui.button({
      key = "primary",
      text = noctalia.tr("action.signin"),
      glyph = "login",
      variant = "primary",
      controlSize = "sm",
      flexGrow = 1,
      enabled = not data.busy,
      onClick = function()
        send({ op = "signin" })
      end,
    })
  end
  if data.status == "connected" then
    return ui.button({
      key = "primary",
      text = noctalia.tr("action.disconnect"),
      glyph = "plug-connected-x",
      variant = "destructive",
      controlSize = "sm",
      flexGrow = 1,
      enabled = not data.busy,
      onClick = function()
        send({ op = "disconnect" })
      end,
    })
  end
  return ui.button({
    key = "primary",
    text = noctalia.tr("action.connect"),
    glyph = "bolt",
    variant = "primary",
    controlSize = "sm",
    flexGrow = 1,
    enabled = not data.busy and data.status ~= "unavailable",
    onClick = function()
      connect("fastest", nil)
    end,
  })
end

local function actions()
  return ui.row({ gap = 8, align = "center" }, {
    primaryAction(),
    ui.button({
      key = "refresh",
      text = noctalia.tr("action.refresh"),
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      enabled = not data.busy,
      onClick = function()
        send({ op = "refresh" })
      end,
    }),
  })
end

-- ── connect flags ───────────────────────────────────────────────────────────

local CHIPS = {
  { id = "p2p", labelKey = "feature.p2p" },
  { id = "securecore", labelKey = "feature.secure_core" },
  { id = "tor", labelKey = "feature.tor" },
}

local function chips()
  local buttons = {}
  for _, chip in ipairs(CHIPS) do
    table.insert(buttons, ui.button({
      key = "chip-" .. chip.id,
      text = noctalia.tr(chip.labelKey),
      variant = "ghost",
      controlSize = "sm",
      fontSize = 11,
      flexGrow = 1,
      selected = flags[chip.id],
      enabled = not data.busy,
      onClick = function()
        flags[chip.id] = not flags[chip.id]
        render()
      end,
    }))
  end
  return ui.row({ gap = 4, align = "center", padding = 3, radius = 8, fill = "on_surface_variant/0.10" }, buttons)
end

-- ── location picker ─────────────────────────────────────────────────────────

local function pickerRow(spec)
  local children = {}
  -- ui.spacer is a flexible filler (it grows), so fixed gaps are boxes.
  if spec.indent then
    table.insert(children, ui.box({ key = spec.key .. "-in", width = 14, height = 1, fill = "#00000000" }))
  end
  table.insert(children, ui.box({
    key = spec.key .. "-dot",
    width = 6,
    height = 6,
    radius = 3,
    fill = spec.active and connectedColor() or "#00000000",
  }))
  table.insert(children, ui.column({ key = spec.key .. "-text", gap = 1, flexGrow = 1 }, {
    ui.label({ text = spec.title, fontSize = 12, maxLines = 1 }),
    ui.label({ text = spec.subtitle, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
  }))
  table.insert(children, ui.button({
    key = spec.key .. "-go",
    glyph = "bolt",
    glyphSize = 13,
    variant = "ghost",
    controlSize = "sm",
    tooltip = spec.tooltip,
    enabled = not data.busy,
    onClick = spec.onConnect,
  }))

  return ui.row({
    key = spec.key,
    gap = 6,
    align = "center",
    paddingH = 6,
    paddingV = 3,
    radius = 6,
    fill = spec.active and "primary/0.10" or nil,
    onClick = spec.onSelect,
  }, children)
end

local function countryMeta(country)
  local cities = type(country.cities) == "table" and #country.cities or 0
  return noctalia.tr(cities == 1 and "detail.country_meta_one" or "detail.country_meta", {
    count = tostring(cities),
    load = tostring(math.floor(tonumber(country.minLoad) or 0)),
  })
end

local function cityMeta(city)
  local servers = math.floor(tonumber(city.servers) or 0)
  return noctalia.tr(servers == 1 and "detail.city_meta_one" or "detail.city_meta", {
    count = tostring(servers),
    load = tostring(math.floor(tonumber(city.minLoad) or 0)),
  })
end

local function countryRow(country, activeCode)
  local code = country.code or country.name or "?"
  return pickerRow({
    key = "co-" .. code,
    title = country.name or code,
    subtitle = countryMeta(country),
    active = activeCode == country.code,
    tooltip = noctalia.tr("action.connect_here"),
    onSelect = function()
      expanded[code] = not expanded[code]
      render()
    end,
    onConnect = function()
      connect("country", country.code or country.name)
    end,
  })
end

local function cityRow(city, activeCity)
  return pickerRow({
    key = "ci-" .. tostring(city.code) .. "-" .. tostring(city.city),
    title = city.city or "",
    subtitle = cityMeta(city),
    indent = true,
    active = activeCity == city.city,
    tooltip = noctalia.tr("action.connect_here"),
    onSelect = function()
      connect("city", city.city)
    end,
    onConnect = function()
      connect("city", city.city)
    end,
  })
end

local function citiesOf(servers, code)
  local out = {}
  for _, city in ipairs(servers.cities or {}) do
    if city.code == code then
      table.insert(out, city)
    end
  end
  return out
end

-- Fuzzy hits, best first; countries are matched on their name, cities on
-- "City, Country" so "york us" finds New York.
local function ranked(items, query, textOf)
  local hits = {}
  for _, item in ipairs(items) do
    local score = noctalia.fuzzyScore(query, textOf(item))
    if score ~= nil then
      table.insert(hits, { score = score, item = item })
    end
  end
  table.sort(hits, function(a, b)
    return a.score > b.score
  end)
  return hits
end

local function locationRows(servers)
  local rows = {}
  local activeCode = type(data.server) == "table" and data.server.code or nil
  local activeCity = type(data.server) == "table" and data.server.city or nil
  local query = noctalia.string.trim(filter)
  local shown = {}

  local countries = servers.countries or {}
  if query ~= "" then
    local hits = ranked(countries, query, function(country)
      return country.name or country.code or ""
    end)
    countries = {}
    for _, hit in ipairs(hits) do
      table.insert(countries, hit.item)
    end
  end

  for _, country in ipairs(countries) do
    if #rows >= MAX_ROWS then
      return rows
    end
    local code = country.code or country.name or "?"
    table.insert(rows, countryRow(country, activeCode))
    if expanded[code] then
      for _, city in ipairs(citiesOf(servers, country.code)) do
        if #rows >= MAX_ROWS then
          return rows
        end
        shown[tostring(city.code) .. "/" .. tostring(city.city)] = true
        table.insert(rows, cityRow(city, activeCity))
      end
    end
  end

  if query ~= "" then
    local hits = ranked(servers.cities or {}, query, function(city)
      return (city.city or "") .. ", " .. (city.country or "")
    end)
    for _, hit in ipairs(hits) do
      if #rows >= MAX_ROWS then
        return rows
      end
      local city = hit.item
      if not shown[tostring(city.code) .. "/" .. tostring(city.city)] then
        table.insert(rows, cityRow(city, activeCity))
      end
    end
  end

  return rows
end

local function locationList()
  local servers = data.servers
  local rows
  if type(servers) ~= "table" or type(servers.countries) ~= "table" then
    rows = { ui.label({ key = "none", text = noctalia.tr("ui.no_servers"), fontSize = 11, color = "on_surface_variant" }) }
  else
    rows = locationRows(servers)
    if #rows == 0 then
      rows = { ui.label({ key = "none", text = noctalia.tr("ui.no_matches"), fontSize = 11, color = "on_surface_variant" }) }
    end
  end

  return ui.column({ flexGrow = 1, minHeight = 110, gap = 6, align = "stretch" }, {
    ui.input({
      key = "filter",
      value = filter,
      placeholder = noctalia.tr("ui.filter"),
      controlSize = "sm",
      fontSize = 12,
      onChange = function(value)
        filter = value
        render()
      end,
    }),
    ui.scroll({ key = "list", flexGrow = 1, gap = 2, align = "stretch" }, rows),
  })
end

-- ── CLI features ────────────────────────────────────────────────────────────

local function optionIndex(spec, value)
  for index, candidate in ipairs(spec.values) do
    if candidate == value then
      return index - 1 -- ui.select indices are zero-based
    end
  end
  return nil -- unknown or "Upgrade to enable": fall back to the placeholder
end

local function optionTexts(spec)
  local out = {}
  for index, key in ipairs(spec.keys) do
    out[index] = noctalia.tr(key)
  end
  return out
end

local function featureSelect(id, name, labelText, spec, value, enabled)
  return ui.column({ key = id, gap = 3, flexGrow = 1 }, {
    ui.label({ text = labelText, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    ui.select({
      key = id .. "-select",
      options = optionTexts(spec),
      selectedIndex = optionIndex(spec, value),
      placeholder = noctalia.tr("features.unknown"),
      controlSize = "sm",
      enabled = enabled,
      onChange = function(index)
        local picked = spec.values[(tonumber(index) or -1) + 1]
        if picked ~= nil and picked ~= value then
          send({ op = "set_feature", name = name, value = picked })
        end
      end,
    }),
  })
end

local function featureToggle(id, name, labelKey, value, enabled)
  return ui.row({ key = id, gap = 6, align = "center", flexGrow = 1 }, {
    ui.toggle({
      key = id .. "-toggle",
      checked = value == "on",
      enabled = enabled and (value == "on" or value == "off"),
      onChange = function(state)
        send({ op = "set_feature", name = name, value = state == "true" and "on" or "off" })
      end,
    }),
    ui.label({ text = noctalia.tr(labelKey), fontSize = 11, flexGrow = 1, maxLines = 1 }),
  })
end

local function featuresSection()
  local features = data.features or {}
  local enabled = not data.busy and data.featuresLocked ~= true and data.status ~= "unavailable"
  -- The CLI refuses a kill-switch change while the tunnel is up, so the label
  -- carries the reason the control is dead.
  local connected = data.status == "connected"

  return ui.column({ gap = 6, align = "stretch" }, {
    ui.row({ gap = 8, align = "end" }, {
      featureSelect("netshield", "netshield", noctalia.tr("features.netshield"), NETSHIELD, features.netshield, enabled),
      featureSelect(
        "killswitch",
        "kill-switch",
        noctalia.tr(connected and "features.kill_switch_connected" or "features.kill_switch"),
        KILL_SWITCH,
        features.kill_switch,
        enabled and not connected
      ),
    }),
    ui.row({ gap = 8, align = "center" }, {
      featureToggle("pf", "port-forwarding", "features.port_forwarding", features.port_forwarding, enabled),
      featureToggle("va", "vpn-accelerator", "features.vpn_accelerator", features.vpn_accelerator, enabled),
    }),
    ui.row({ gap = 8, align = "center" }, {
      featureToggle("nat", "moderate-nat", "features.moderate_nat", features.moderate_nat, enabled),
      featureToggle("ipv6", "ipv6", "features.ipv6", features.ipv6, enabled),
    }),
  })
end

-- ── footer ──────────────────────────────────────────────────────────────────

local function footer()
  local text = noctalia.tr("footer.never")
  if type(data.checkedAt) == "number" then
    text = noctalia.tr("footer.updated", { time = noctalia.formatTime("%H:%M", data.checkedAt) })
  end
  return ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = "clock", size = 11, color = "on_surface_variant" }),
    ui.label({ text = text, fontSize = 10, color = "on_surface_variant" }),
    ui.label({
      text = data.account or "",
      fontSize = 10,
      color = "on_surface_variant",
      opacity = 0.7,
      flexGrow = 1,
      maxLines = 1,
      textAlign = "end",
    }),
    ui.button({
      key = "reload",
      glyph = "reload",
      glyphSize = 12,
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("action.refresh_servers"),
      enabled = not data.busy,
      onClick = function()
        send({ op = "refresh_servers" })
      end,
    }),
  })
end

-- ── assembly ────────────────────────────────────────────────────────────────

function render()
  local body = { header(), mapSection(), caption() }

  local errorRow = banner()
  if errorRow ~= nil then
    table.insert(body, errorRow)
  end
  local noticeRow = notice()
  if noticeRow ~= nil then
    table.insert(body, noticeRow)
  end

  table.insert(body, actions())
  table.insert(body, chips())
  table.insert(body, locationList())
  table.insert(body, ui.separator({ spacing = 2 }))
  table.insert(body, featuresSection())
  table.insert(body, ui.separator({ spacing = 2 }))
  table.insert(body, footer())

  panel.render(ui.column({ flexGrow = 1, padding = 12, gap = 8, align = "stretch" }, body))
end

function onOpen(_context)
  data = noctalia.state.get("proton_vpn.data") or data
  panel.setWantsSecondTicks(false)
  send({ op = "refresh" })
  render()
end

function update()
  render()
end

noctalia.state.watch("proton_vpn.data", function(value)
  if type(value) == "table" then
    data = value
    render()
  end
end)

render()
