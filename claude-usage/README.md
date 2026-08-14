# Claude Usage

Claude Code usage limits in the Noctalia bar — session, weekly and per-model
windows, pacing, reset countdowns, and extra-usage spend. The headless service
owns credentials and polling and publishes a snapshot to shared state; the bar
widget and panel are thin clients of it.

Inspired by [claudebar](https://github.com/mryll/claudebar), the Waybar widget
that does the same job.

## Plugin

| Field | Value |
| --- | --- |
| ID | `johnschmidt/claude-usage` |
| Entries | Service: `service`; bar widget: `bar`; panel: `panel` |

## Usage

### Bar widget

Add the `bar` widget to your bar. It shows the tracked window's usage and its
reset countdown, tinted by your warning/critical thresholds. Click it to open
the panel; right-click to force a refresh.

### Panel

One section per limit window: a cell bar, a pacing marker, the percentage and a
reset countdown. Extra-usage spend follows when there is any, then the time of
the last successful fetch and a refresh button.

The pacing marker sits at the point you'd be at if usage were spread evenly
across the window: a fill left of the marker means you're under pace (`↓`),
right of it means you're burning faster than the window refills (`↑`).

### IPC

```sh
# Open the panel
noctalia msg panel-toggle johnschmidt/claude-usage:panel

# Force a refresh now
noctalia msg plugin johnschmidt/claude-usage:service all refresh
```

## Settings

Plugin-wide, in Settings → Plugins:

| Setting | Default | Notes |
| --- | --- | --- |
| Refresh interval | `300` | Seconds; 300 is the floor the API imposes |
| Warning threshold | `70` | Percentage at which bars turn the warning colour |
| Critical threshold | `90` | Percentage at which bars turn the critical colour |
| Normal / Warning / Critical colour | `#a6e3a1` / `#f9e2af` / `#f38ba8` | Any colour |
| Show pacing marker | on | The in-bar elapsed-time marker |
| Refresh expired tokens | on | Advanced; see [Token refresh](#token-refresh) |

Per bar widget:

| Setting | Default | Notes |
| --- | --- | --- |
| Bar format | `{session}% · {session_reset}` | Placeholders below |
| Bar window | Session | Which window `{pct}`/`{reset}`/`{pace}` track |
| Show glyph | on | |
| Glyph | `sparkles` | Must be a real Tabler/Nerd-Font name |
| Panel font | *(shell font)* | See [Fonts](#fonts) |
| Colour by usage | on | Tint the glyph by threshold |

Per panel:

| Setting | Default | Notes |
| --- | --- | --- |
| Panel font | *(shell font)* | See [Fonts](#fonts) |

Format placeholders: `{pct}` `{reset}` `{pace}` `{session}` `{session_reset}`
`{weekly}` `{weekly_reset}` `{plan}` `{spend}`.

## Notes

### Fonts

The bar widget and the panel each take a font setting, applied to every text
node they draw (glyphs keep using the icon font). Two accepted forms:

- an **installed family name**, e.g. `JetBrainsMono NFM SemiBold` — list yours
  with `fc-list : family | tr ',' '\n' | sort -u`
- a **path to a font file** (`.ttf`/`.otf`), which is registered with
  `noctalia.loadFont` on first use; a path that fails to load is logged and
  falls back to the shell font

Leave a setting empty to inherit the shell font. The value is resolved once per
distinct setting value, not per render, so pointing at a file costs one
filesystem read rather than one per second.

Note that Noctalia's built-in per-widget `font_family` does **not** apply to
plugin widgets — setting it in `[widget.<id>]` by hand logs
`unknown setting` and is ignored. The plugin declares its own `font_family`,
which binds to that same key, so an existing hand-written value starts working
once the plugin is enabled.

### Requirements

- Claude Code logged in — the plugin reads `~/.claude/.credentials.json`
- `chmod` on `PATH` (coreutils) for the credential write path

### Data source

`GET https://api.anthropic.com/api/oauth/usage`, the same undocumented endpoint
Claude Code's own `/usage` view uses, authenticated with your Claude Code OAuth
token.

Both response shapes are handled: the newer `limits[]` / `spend` objects are
preferred, with the older `five_hour` / `seven_day_*` / `extra_usage` fields as
a fallback. Money is formatted from the currency the API reports, so non-USD
accounts render correctly.

**The endpoint rate-limits aggressively.** Polling below 300s will earn you
HTTP 429s, so `refresh_interval` is clamped to a 300s floor. Failures back off
exponentially (up to 30 min) and the last good payload is cached in the
plugin's data dir, so a restart or a network blip shows stale numbers rather
than an empty widget.

### Token refresh

When the access token is within 5 minutes of expiry the service refreshes it
and writes the new token back to `~/.claude/.credentials.json` — the same thing
claudebar does, and what keeps the widget alive when you haven't run Claude
Code for a while.

The write is done carefully: a temp file is created, `chmod`ed to `600` *before*
the token is written into it, verified for length, then renamed over the
original. A crash mid-write leaves your existing login untouched. The file is
re-read immediately before writing so a concurrent Claude Code update of other
fields isn't clobbered.

The residual risk is unavoidable: if Claude Code refreshes at the same moment,
one of the two refresh tokens is invalidated and you'll need to run `claude`
again. Set **Refresh expired tokens** to off to make the plugin strictly
read-only, at the cost of the widget going stale until you next use Claude Code.
