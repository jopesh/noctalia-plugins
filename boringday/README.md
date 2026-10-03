# Another Boring Piece — for Noctalia

Hand-picked fine art from [anotherboring.day](https://anotherboring.day) as your
wallpaper. A bar icon opens today's piece plus two more, one click sets any of
them.

A port of the Omarchy Quickshell plugin
[`jopesh/omarchy-boringday`](https://github.com/jopesh/omarchy-boringday). Same
public endpoints, no account, no API key. Requires `curl`; `xdg-open` and
`xdg-user-dir` for the open and save buttons.

## Using it

Click the bar icon to open the panel; right-click shuffles a random piece
without opening anything, middle-click refetches today's set. The icon takes
the accent color while a piece is being fetched or set, and turns red (with the
reason in its tooltip) when something failed.

The panel opens on whatever is on your wall. A shuffled piece joins the list,
so it is always one row away; browsing the rows previews a piece, and the
wallpaper only changes when you set it.

| Key | Action |
| --- | --- |
| `j` / `k` (or `↓` / `↑`) | Move the cursor — previews that piece |
| `Enter` | Set the previewed piece as the wallpaper |
| `t` | Set today's piece |
| `s` | Shuffle — set a random piece |
| `d` | Save a copy to your pictures folder |
| `o` | Open the piece's page on anotherboring.day |
| `r` | Fetch today's set again |

## From the command line

```sh
noctalia msg plugin johnschmidt/boringday:service all random          # set a random piece
noctalia msg plugin johnschmidt/boringday:service all today           # set today's piece
noctalia msg plugin johnschmidt/boringday:service all refresh         # refetch today's set
noctalia msg plugin johnschmidt/boringday:service all save            # save what is on the wall
noctalia msg plugin johnschmidt/boringday:service all open            # open its page
```

`today` fetches the set first if it has not loaded yet. Bind `random` to a
timer (systemd, cron) if you want the wall to rotate on its own. Nobody is
looking at the panel when these run, so failures raise an error notification.

## Settings

`notify` (on by default) sends a notification naming the piece whenever the
command line changes the wallpaper; changes made from the panel are not
announced. Errors from the command line are always reported.

## How it works

The wallpaper is set with `noctalia msg wallpaper-set <path>`. Images are
fetched with `curl` into the plugin's data directory (newest 20 wallpapers and
60 thumbnails kept) and rendered from local files. Nothing off the network is
taken on trust: curl refuses to exceed a byte ceiling mid-download, every image
is checked against its own magic bytes before it is previewed or set, and
records are cut to a bounded shape (`model.luau`, a port of `Model.js`).

The last fetched set is cached alongside what is on the wall, so the panel is
filled the moment the shell starts, offline included. The set is fetched again
when the calendar day changes; if that fails it is retried after one minute,
doubling up to half an hour. Saving a copy reuses the cached full-size image
when there is one instead of downloading it again.

Not ported from the Omarchy version: adding a piece to the current theme's
backgrounds (`t` there; `t` here sets today's piece) — Omarchy-specific; use
save-a-copy instead.

## Checks

```sh
luau boringday/tools/model_test.luau   # offline checks for model.luau
```

The artwork belongs to anotherboring.day and the respective museums and
estates; this plugin only points your desktop at it.
