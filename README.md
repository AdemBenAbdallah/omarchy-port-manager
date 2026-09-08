# Port Manager

Every port listening on this machine, named by the project that holds it.

![Port Manager in the Omarchy bar]<img width="643" height="475" alt="image" src="https://github.com/user-attachments/assets/c4f89d7f-4710-4a90-80b3-9efb3b245b31" />

One bar icon shows how many dev servers are up. Click it and the panel answers
the three questions you actually have, in that order: **what is running**, **is
it reachable from outside this machine**, and **how do I stop it**.

```
󰒍 2
┌──────────────────────────────────────────────────┐
│ 󰒍  Port Manager                     [1 exposed]  │
│    2 DEV SERVERS                             ↻   │
│  ┌────────────────────────────────────────────┐  │
│  │ Filter by port, project, stack, or PID…    │  │
│  └────────────────────────────────────────────┘  │
│  DEV SERVERS                                     │
│  ▌3000    checkout-api              (EXPOSED)    │
│           Rails · puma · PID 4412 · 1h 6m · 91 MB│
│  ▌5173    docs-site                              │
│           Vite · node · PID 4820 · 12m · 78 MB   │
│  ⌄ OTHER SOCKETS YOU OWN  (2)                a   │
│  ⌄ SYSTEM SOCKETS  (11)                      s   │
│  ↑↓ move  ⏎ open  y copy URL  x stop  X force    │
└──────────────────────────────────────────────────┘
```

## What it does

- **Names the port by its project.** The owning process's working directory is
  walked up to the nearest git checkout, so port 5173 reads `checkout-api`, not
  `node`. This is the thing you actually wanted to know.
- **Detects the stack.** Vite, Next.js, Django, Rails, Go, Rust, Docker,
  Postgres, and the rest get a glyph and a label from the command line.
- **Flags what is exposed.** A socket bound to `0.0.0.0` is reachable from your
  network; one bound to `127.0.0.1` is not. Exposed rows get a red rail, a
  pill, and a count in the bar icon's tooltip.
- **Keeps the noise out of the way.** Dev servers lead. Your ephemeral sockets
  and the system's collapse into two sections you open with `a` and `s`.
  Nothing is hidden — it is just not first.
- **Names system ports it cannot inspect.** `ss` will not tell a normal user
  which process owns port 53, so the panel says "DNS" rather than "unknown".
- **Stops things safely.** Only processes your own user owns can be signalled,
  never PID 1, and every stop is armed before it fires — and it is bound to
  one specific process, not to a PID that may have been recycled.

## Keys

| Key | Action |
|-----|--------|
| `↑` `↓` / `j` `k` | Move the cursor |
| `⏎` / `o` | Open `http://localhost:<port>` |
| `y` | Copy the URL |
| `c` | Copy the full command line |
| `e` | Open the project directory |
| `x` | Stop (SIGTERM) — press twice |
| `X` | Force kill (SIGKILL) — press twice |
| `a` / `s` | Expand your other sockets / system sockets |
| `/` or any digit | Jump to the filter |
| `r` | Refresh |
| `Esc` | Close |

Mouse works throughout: click a row to open it, middle-click to copy, and the
open / copy / stop buttons appear on the row under the cursor.

### Stopping is armed, not confirmed

The first `x` arms the row and starts a three-second bar that drains along its
bottom edge. The second `x` sends the signal. Move the cursor, or wait, and it
disarms. This is deliberately not a modal dialog: a dialog steals focus and
breaks the keyboard flow for the one action you are most likely to repeat.

After a SIGTERM the backend waits up to 1.5s to see whether the process
actually exited, so the panel reports what happened rather than guessing.

### Why a PID is not enough

The panel acts on a snapshot, and Linux recycles PIDs. If the listener you are
looking at exits and the kernel hands its PID to something else you also own, a
plain owner check would pass on that stranger and stop the wrong program.

So every row carries an identity — its PID paired with the process start time
from `/proc/<pid>/stat`, which the kernel cannot hand to a second process — and
the stop request carries it too. The backend refuses outright if it no longer
matches, and tells you the listener is gone rather than signalling anything.
The signal itself goes through `os.pidfd_open()` and
`signal.pidfd_send_signal()`: a pidfd refers to a *process*, not a number, so
even if the PID were recycled in the instant between the check and the signal,
the kernel reports `ESRCH` instead of delivering it to the new owner. The
identity is also re-read after the pidfd is open, and is part of the arm key,
so a row that changes underneath you disarms instead of firing.

On a kernel or interpreter without pidfd the code falls back to `os.kill`,
still gated on the same identity check immediately beforehand.

## Install

```bash
omarchy plugin add https://github.com/AdemBenAbdallah/omarchy-port-manager.git --enable --yes
```

That is the whole install. `omarchy plugin add` clones the repository, validates
the manifest, and shows you the code before anything is enabled; it runs no
install hook and requests no elevated privileges.

To install without the plugin manager, place the contents of this repository in
a directory named for the plugin id — `~/.config/omarchy/plugins/io.github.adembenabdallah.port-manager/`
— then run `omarchy-restart-shell` and
`omarchy plugin enable io.github.adembenabdallah.port-manager`.

> Changing a plugin's `entryPoints` requires `omarchy-restart-shell`, not just
> `rescanPlugins` — the bar caches the widget component by URL.

## Settings

Setup → Plugins → Port Manager, or inline in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|-----|---------|---------|
| `refreshIntervalSec` | `20` | Background refresh for the bar count. The open panel always polls every 2.5s. |
| `showCount` | `true` | Print the dev-server count next to the bar icon. |

## From the terminal

The panel is not the only way in. The backend is a standalone script, which is
what you want the moment a port conflict shows up in a shell rather than on
screen:

```bash
cd ~/.config/omarchy/plugins/io.github.adembenabdallah.port-manager

python3 port-manager.py                 # every listening socket, as JSON
python3 port-manager.py check 3000      # free? who holds it? next free port?
python3 port-manager.py kill-port 3000  # stop whatever holds it
python3 port-manager.py stop 12345      # stop by PID (--force for SIGKILL)

# The panel always passes --identity so a recycled PID can never be hit.
# Given by hand, the identity is read fresh at the start of the call instead.
python3 port-manager.py stop 12345 --identity 12345:2332266
```

And over shell IPC:

```bash
omarchy-shell port-manager toggle
omarchy-shell port-manager refresh
omarchy-shell port-manager ports        # current rows as JSON
```

## Safety

- A process is only signalled when `/proc/<pid>` is owned by your uid **and**
  its start time still matches the one recorded when the row was listed.
- Signals are delivered through a pidfd, so a recycled PID cannot be hit.
- PID 1 and below are refused outright.
- Everything runs as your own user. No privilege escalation, no network access.
- The only external command is `ss -H -ltnup` from `iproute2`; everything else
  is a read from `/proc`.

## Requirements

Omarchy Quattro (shell plugin API v1), `iproute2` for `ss`, `wl-clipboard` for
copy, and `xdg-utils` for open.

Python 3.9+ and Linux 5.3+ for pidfd signalling, which is what Omarchy ships.
On anything older the plugin still works and still refuses to signal a process
whose identity changed; it just falls back to `os.kill` for the delivery.

## Layout

| File | Role |
|------|------|
| `manifest.json` | Plugin identity, entry point, settings schema |
| `Panel.qml` | Bar widget and panel — the only entry point |
| `Model.js` | Filtering, grouping, and string shaping |
| `port-manager.py` | Socket enumeration and process control |
| `test_stop_safety.py` | Regression tests for the stop path — `python3 test_stop_safety.py` |

## License

MIT
