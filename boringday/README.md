# Another Boring Piece — for Noctalia

Hand-picked fine art from [anotherboring.day](https://anotherboring.day) as your
wallpaper. A bar icon opens today's piece plus two more, one click sets any of
them, and an optional schedule keeps the wall moving.

A port of the Omarchy Quickshell plugin
[`jopesh/omarchy-boringday`](https://github.com/jopesh/omarchy-boringday). Same
public endpoints, no account, no API key. Requires `curl`; `xdg-open` and
`xdg-user-dir` for the open and save buttons.

## Using it

Click the bar icon to open the panel; right-click shuffles a random piece
without opening anything, middle-click refetches today's set. The icon takes
the accent color while rotation is on.

Browsing the three rows previews a piece; the wallpaper only changes when you
set it.

| Key | Action |
| --- | --- |
| `j` / `k` (or `↓` / `↑`) | Move the cursor — previews that piece |
| `Enter` | Set the previewed piece as the wallpaper |
| `s` | Shuffle — set a random piece |
| `d` | Save a copy to your pictures folder |
| `o` | Open the piece's page on anotherboring.day |
| `r` | Fetch today's set again |
| `a` | Toggle automatic rotation |
| `i` | Cycle the rotation period (1h / 3h / 12h / 24h) |

## From the command line

```sh
noctalia msg plugin johnschmidt/boringday:service all random          # set a random piece
noctalia msg plugin johnschmidt/boringday:service all today           # set today's piece
noctalia msg plugin johnschmidt/boringday:service all refresh         # refetch today's set
noctalia msg plugin johnschmidt/boringday:service all auto toggle     # on | off | toggle
noctalia msg plugin johnschmidt/boringday:service all interval 1800   # seconds
```

## Settings

`auto_rotate`, `interval_seconds` (300–86400) and `notify` live in the plugin
settings. The panel's toggle and interval chips are remembered by the service
and override the settings file until the next time the settings are edited.
The schedule is wall-clock: the last change is persisted, so a restart resumes
it rather than granting a fresh period.

## How it works

The wallpaper is set with `noctalia msg wallpaper-set <path>`. Images are
fetched with `curl` into the plugin's data directory (newest 20 wallpapers and
60 thumbnails kept) and rendered from local files. Nothing off the network is
taken on trust: curl refuses to exceed a byte ceiling mid-download, every image
is checked against its own magic bytes before it is previewed or set, and
records are cut to a bounded shape (`model.luau`, a port of `Model.js`).

Not ported from the Omarchy version: adding a piece to the current theme's
backgrounds (`t`) — Omarchy-specific; use save-a-copy instead.

The artwork belongs to anotherboring.day and the respective museums and
estates; this plugin only points your desktop at it.
