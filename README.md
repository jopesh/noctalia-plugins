# claude-noctalia

Personal [Noctalia](https://noctalia.dev) plugin source.

| Plugin | What it does |
| --- | --- |
| [`claude-usage`](claude-usage/) | Claude Code usage limits in the bar — session, weekly and per-model windows, pacing, reset countdowns, and extra-usage spend |
| [`agents`](agents/) | One bar icon and one panel for every AI coding subscription — limits, prepaid balance, tokens by day and by model. A port of [omarchy's Quickshell `agents` plugin](https://github.com/basecamp/omarchy/tree/quattro/shell/plugins/agents) |
| [`winboat`](winboat/) | WinBoat Docker/Podman container status with start and stop controls |
| [`proton-vpn`](proton-vpn/) | Proton VPN status, a dot-matrix world map, and one-click connect by country or city |
| [`boringday`](boringday/) | Fine art from anotherboring.day as your wallpaper — today's piece plus two more, one-click set, optional rotation. A port of [omarchy-boringday](https://github.com/jopesh/omarchy-boringday) |

Both read Anthropic's OAuth usage endpoint, so running both doubles the request
rate against an endpoint that rate-limits hard. They are otherwise independent:
separate state keys, separate data directories, and either can sit in the bar
without the other.

## Layout

This repo is a Noctalia **plugin source**: one directory per plugin, each with
its own `plugin.toml`. Noctalia is already pointed at it via a `path` source in
`~/.local/state/noctalia/settings.toml`:

```toml
[[plugins.source]]
kind = "path"
location = "~/Developer/claude-noctalia"
name = "my-plugins"
```

`plugin_api` is a *maximum*, not a minimum: a manifest above what the installed
shell supports loads as `disabled incompatible`. noctalia 5.0.0-beta.8 tops out
at 23 — notably one short of the argv-table form of `runAsync` (24), so
subprocess arguments still have to be shell-quoted by hand.

Entry scripts hot-reload on save. Manifest (`plugin.toml`) changes need a
config reload:

```sh
noctalia msg config-reload
noctalia msg plugins list
```

## Checks

```sh
# Official offline linter: cross-checks getConfig() calls against declared settings
noctalia plugins lint .

# Community-repo manifest/README validator (only needed before publishing).
# The script lives in the official-plugins repo, not here — fetch it first:
git clone --depth 1 https://github.com/noctalia-dev/official-plugins /tmp/official-plugins
python3 /tmp/official-plugins/.github/workflows/validate-plugins.py --root .
```

The community validator also wants a `thumbnail.webp` per plugin — that's a
publishing requirement only, and needs a real screenshot of the widget.
