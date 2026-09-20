# Windows

Noctalia bar indicator and controls for a [dockurr/windows](https://github.com/dockur/windows)
container — the compose-based Windows VM in `~/Windows`.

## Status without root

The Docker socket is root-owned here, so every `docker` call has to go through
`pkexec` and costs 1.5–4 s. Polling that once per bar tick is not viable, and it
is not necessary either: `bin/windows-status` reads everything unprivileged in
about 40 ms.

- **running** — a `qemu-system-x86_64` process in a Docker cgroup. The cgroup
  check is what stops an unrelated libvirt VM from turning the indicator green;
  it matches loosely so both the systemd and cgroupfs drivers work.
- **rdp_ready** — an X.224 Connection Request to the RDP port, requiring a
  Connection Confirm back. A listen check proves nothing: docker-proxy binds 3389
  the moment the container starts, long before Windows can answer.
- **uptime, memory, cores, ports, username** — from `/proc` and the compose file.

That gives four states instead of the usual two:

| State | Meaning |
| --- | --- |
| `stopped` | Nothing bound, no VM process |
| `preparing` | Container up, QEMU not yet launched — ISO download or disk prep |
| `booting` | QEMU running, Windows not answering RDP yet |
| `running` | Windows answers the RDP handshake |

`pkexec` is reserved for the two operations that genuinely need root:
`docker compose up -d` and `docker compose stop`.

## Connect

**Connect** on a cold VM runs `compose up -d`, then watches readiness on the
ordinary poll and opens RDP the moment Windows answers — nothing blocks, and the
panel stays live while the guest boots. Clicking again cancels the queued
connect. Turn off **Start the VM when connecting** to make Connect a no-op while
the VM is down.

Left-click opens the panel. Right-click escalates along the VM's own states:
connect once Windows answers RDP, stop while it is up, start when it is off.

## Configuration

Everything guest-facing is read from `docker-compose.yml` at run time: RDP and
console ports from its `ports:` list, credentials and VM sizing from its
`environment:` block. Editing the compose file is enough to reconfigure the
plugin. The only plugin settings are the compose path, the poll interval, an
optional RDP command override, and the auto-start toggle.

## Scripts

Both work standalone, outside Noctalia:

```sh
bin/windows-status --compose ~/Windows/docker-compose.yml   # one JSON object
bin/windows-rdp --dry-run                                   # show the argv
bin/windows-rdp --wait                                      # block until Windows answers, then connect
bin/windows-rdp --scale 150                                 # force a scale instead of detecting one
bin/windows-rdp -- /f                                        # extra xfreerdp3 flags
```

### Scaling

`--scale auto` (the default) reads the scale of the monitor the session opens
on — the *focused* output, since that is where the window lands — and passes it
to the guest, so Windows renders at the right size on a HiDPI display instead of
being scaled up as a blurry bitmap.

RDP carries two scale factors, and they have different rules: `DESKTOP_SCALE_FACTOR`
is free between 100 and 500, while `DEVICE_SCALE_FACTOR` may only be 100, 140 or
180, so a fractional Wayland scale is snapped onto the nearest of those three.

| Monitor scale | Flags |
| --- | --- |
| 1.0 | *none* — identical to not having the feature |
| 1.25 | `/scale-desktop:125 /scale-device:140` |
| 1.5 | `/scale-desktop:150 /scale-device:140` |
| 1.75 | `/scale-desktop:175 /scale-device:180` |
| 2.0 | `/scale-desktop:200 /scale-device:180` |

Detection asks `niri msg --json focused-output`. On another compositor, or if
niri cannot be reached, no flags are emitted and the session behaves as before —
set the **RDP scaling** setting to a percentage to pin it by hand. An
`rdp_command` override takes the whole command line over, scaling included.

`windows-rdp` connects with `/dynamic-resolution`, `/sound:sys:pulse`,
`/microphone:sys:pulse`, `+clipboard` and `/cert:ignore`. The password is passed
as `/p:`, so it is visible in the process list — `/from-stdin` would avoid that
but silently ignores a piped password, and the compose file it comes from is
world-readable anyway.

## Requirements

`docker`, `pkexec`, `python3` and `xfreerdp3`.

polkit answers `auth_admin` for `org.freedesktop.policykit.exec` here, so Start
and Stop raise a password prompt through Noctalia's own polkit agent. polkit
caches the authorization for about five minutes, so a start followed later by a
stop usually prompts once. An unanswered prompt would block `pkexec` forever, so
the call is bounded by `timeout` and reported rather than left to freeze the bar.

Status, Connect and the web console need no privileges at all and work whether or
not the prompt is answered.

## IPC

```sh
noctalia msg plugin johnschmidt/windows:service all refresh
noctalia msg plugin johnschmidt/windows:service all start
noctalia msg plugin johnschmidt/windows:service all stop
noctalia msg plugin johnschmidt/windows:service all connect
noctalia msg plugin johnschmidt/windows:service all web
```
