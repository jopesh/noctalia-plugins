# claude-noctalia

Personal [Noctalia](https://noctalia.dev) plugin source.

| Plugin | What it does |
| --- | --- |
| [`claude-usage`](claude-usage/) | Claude Code usage limits in the bar — session, weekly and per-model windows, pacing, reset countdowns, and extra-usage spend |

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

Entry scripts hot-reload on save. Manifest (`plugin.toml`) changes need a
config reload:

```sh
noctalia msg config-reload
noctalia msg plugins list
```

## Checks

```sh
# Official offline linter: cross-checks getConfig() calls against declared settings
noctalia plugins lint claude-usage

# Community-repo manifest/README validator (only needed before publishing).
# The script lives in the official-plugins repo, not here — fetch it first:
git clone --depth 1 https://github.com/noctalia-dev/official-plugins /tmp/official-plugins
python3 /tmp/official-plugins/.github/workflows/validate-plugins.py --root .
```

The community validator also wants a `thumbnail.webp` per plugin — that's a
publishing requirement only, and needs a real screenshot of the widget.
