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

Every window is drawn on its own time axis. The track *is* the window: its left
edge is when the window opened, its right edge is the reset. Two lanes share
that scale —

- **Used** — how much of the limit is gone, as a share of the whole window
- **Elapsed** — how much of the window has gone

— so pacing is the gap between two lengths rather than a tick you have to read
against a fill. Dashes carry the used lane on to where this rate lands it by
the reset, and the bright hairline is now. Under the lanes, the axis says how
far into the window you are and when it resets.

The session window gets a card of its own. The weekly window and every
per-model window share one window, so they share one axis: `All` plus a lane
per model, in a single card. Extra-usage spend gets a lane and no axis, because
there is no window behind it.

A line under a card names the lane that runs out first, and when
(`Opus empty by ~Sat 00:00`) — only when a lane is actually on course to empty
before its reset. Nothing to say, nothing said.

Stale numbers lose their colour entirely, the way the bar widget dims its text,
and their projections are suppressed: a red 91% that was true fourteen hours ago
is worse than no colour at all. The elapsed lane keeps advancing while it waits,
since it is computed locally from the reset time — so a stale panel visibly
drifts apart instead of quietly lying.

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
| Show pacing | on | The elapsed lane, the now marker and the projection dashes |
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

### Stale data

Whenever the numbers on screen aren't from the latest fetch — the cache after a
shell restart, a failed request, an expired login — the widget dims them and
appends a `⏸` marker, and the panel footer says when they are from and how old
they are (`Stale — data from 22:28 (14 h ago)`) instead of `Updated 22:28`.
That's the state to expect after a night away from Claude Code until the next
successful fetch lands.

A request whose reply never arrives (typically the token refresh fired at shell
start, before the network is up) is abandoned after 60s so polling resumes; a
late reply for an abandoned request is ignored. Without that, one hung request
at login pinned the widget on the previous day's numbers indefinitely.

Failures are told apart the way claudebar tells them apart:

- **A request that got no answer** (offline, hung, abandoned) stays quiet. The
  numbers go stale and the footer reads `Waiting for network — data from …`;
  there is no error banner, because it resolves itself. The first retry is 15s
  later, so a shell that started before the network was up catches up in
  seconds instead of at the next 300s tick.
- **Anything you have to act on** (401/403, HTTP errors, an unusable
  credentials file, a failed token refresh) gets the red banner, and the
  auth-class failures also raise one desktop notification per episode — nothing
  on screen will change until you run `claude`. A successful fetch ends the
  episode, so the next break notifies again.

Manual refreshes — the panel button, right-click, `noctalia msg plugin
johnschmidt/claude-usage:service all refresh` — are held to one request per 60s,
matching claudebar's cache TTL. A click inside that window isn't dropped; it
brings the next fetch forward to the earliest allowed moment.

An HTTP 429 backs off on its own ladder: 10 min, doubling per consecutive 429,
up to an hour, and the button is ignored entirely until that passes. The
endpoint's `Retry-After` has been observed at ~59 minutes, but `noctalia.http`
returns only `{ ok, status, body }` — no headers — so the server's own number
can't be read and the ladder approximates it.

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
