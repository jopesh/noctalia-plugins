# WinBoat

Noctalia bar indicator and controls for the Windows container created by
[WinBoat](https://github.com/TibixDev/winboat).

- Green means running; muted means stopped; red means an error or unavailable runtime.
- Left-click opens the panel. Right-click starts or stops the container directly.
- The panel provides Start/Stop and Refresh controls and displays command errors.
- **Open** launches the configured RDP desktop command (`~/.local/bin/winboat-rdp` by default).
- While running, the panel reads CPU and RAM usage from WinBoat's Windows guest API.
- Docker and Podman are supported. The default container name is `WinBoat`.
- The panel runtime selector switches immediately; the runtime setting controls the persistent default.
- The widget setting **Show status text** can hide the text beside the bar icon.

WinBoat allows up to 120 seconds for Windows to shut down gracefully, so a stop
can remain in progress for about two minutes.

IPC controls are also available:

```sh
noctalia msg plugin johnschmidt/winboat:service all refresh
noctalia msg plugin johnschmidt/winboat:service all start
noctalia msg plugin johnschmidt/winboat:service all stop
```
