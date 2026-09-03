# Proton VPN

Noctalia bar indicator, world map and connect controls for
[proton-vpn-cli](https://github.com/ProtonVPN/proton-vpn-cli).

- Green means connected; muted means disconnected; red means an error, a missing
  CLI, or an expired session.
- Left-click opens the panel. Right-click connects to the fastest server, or
  disconnects when a tunnel is up.
- The panel shows a dot-matrix world map with every Proton city, the connected
  one ringed, plus quick connect, a country/city picker and the CLI settings.
- P2P, Secure Core and Tor are sticky chips: whatever is lit is passed to every
  connect you start from the panel.
- The location list filters fuzzily over country names and "City, Country", and
  renders at most 60 rows at a time.
- NetShield, kill switch, port forwarding, VPN accelerator, moderate NAT and
  IPv6 map straight onto `protonvpn config set`. Values the CLI reports as
  *Upgrade to enable* disable the whole section.
- A failed connect, disconnect or setting change shows in the panel banner
  until the next operation, and is also raised as a desktop notification.
- The widget setting **Show status text** can hide the server name beside the
  bar icon.

## Before it works

Sign in once, in a terminal, so the CLI stores a session and downloads the
server list:

```sh
protonvpn signin
```

The plugin never asks for credentials and never runs `signin` on its own — the
panel's **Sign in…** button just opens a terminal for you. Until that has
happened the status reads *Sign-in required* and the map shows the hint from the
server-list helper.

**The Proton VPN desktop app must not be running.** It owns the D-Bus name
`proton.vpn.app.gtk`, and while it does, every CLI call answers `Error: Proton
VPN desktop app is currently running` — on standard output, with exit code 0.
That text is surfaced in the panel's error banner.

## How it reads status

`protonvpn status` costs about 0.7 seconds of CPU per call, so it is never
polled. The CLI's NetworkManager backend names the tunnel profile
`ProtonVPN <SERVER_NAME>` and deletes it on disconnect, so the status source is:

```sh
nmcli -t -f NAME,TYPE,STATE connection show --active
```

matched against `^ProtonVPN ([^:]+):wireguard:activated$`.

The server list cache (`~/.cache/Proton/VPN/serverlist.json`) is 24 MB, far too
much for Luau. `bin/proton-vpn-map` reduces it to a compact country/city list
and renders the map as an SVG, keyed by the cache's mtime so repeat calls are
cheap. It re-runs when the connected server, the theme mode or a colour setting
changes, and otherwise on the **Server list interval**.

A connect blocks until the CLI answers, which can take ten seconds or more; the
plugin allows sixty, the longest `runAsync` permits.

IPC controls are also available:

```sh
noctalia msg plugin johnschmidt/proton-vpn:service all refresh
noctalia msg plugin johnschmidt/proton-vpn:service all connect
noctalia msg plugin johnschmidt/proton-vpn:service all disconnect
```

`connect` picks the fastest server, ignoring the panel's feature chips.

## State

The service publishes `proton_vpn.data`; the widget and panel are pure views
over it, and send `proton_vpn.cmd` back.

```lua
{
  status = "loading"|"connected"|"disconnected"|"unavailable"|"signin_required"|"error",
  busy = false, operation = nil|"connect"|"disconnect"|"config",
  serverName = nil|"DE#402",                -- from nmcli
  server = nil|{ name, code, country, city, load, features, tier, lat, lon, secureCore, entryCode },
  error = nil|{ message = "…", transient = bool },
  notice = nil|"…",
  features = nil|{ netshield, kill_switch, port_forwarding, vpn_accelerator, moderate_nat, ipv6 },
  featuresLocked = false,                   -- the CLI said "Upgrade to enable"
  servers = nil|{ generatedAt, countries, cities },
  mapPath = nil|"/…/map-<hash>.svg",
  account = nil|"you@proton.me",
  cliAvailable = bool, checkedAt = unix,
}
```

```lua
{ op = "connect", kind = "fastest"|"country"|"city"|"server", value = nil|"DE"|"Frankfurt"|"DE#402",
  p2p = bool?, securecore = bool?, tor = bool? }
{ op = "disconnect" } | { op = "refresh" } | { op = "refresh_servers" }
{ op = "set_feature", name = "netshield"|"kill-switch"|"port-forwarding"|"vpn-accelerator"|"moderate-nat"|"ipv6", value = "…" }
{ op = "signin" }
```
