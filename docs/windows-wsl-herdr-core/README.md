# Ovis in WSL2 on the Herdr app's Windows core

Ovis runs in WSL2 and shows the terminals of the herdr-core that the Herdr app keeps on Windows,
the same sessions the app shows, with no bridge and no change to Ovis. WSL runs the Windows
`hc.exe` through Windows interop; Ovis already speaks to herdr-core through `hc connect`
(protocol over stdin/stdout, `server/herdr-core/connection.ts`), which interop carries as it does a
pipe.

```
Android browser ──tailnet──▶ Ovis (WSL2, bun, 127.0.0.1) ──stdin/stdout──▶ hc.exe connect ──▶ core (Windows)
                                                                                             ▲
Herdr app (Windows) ─────────────────────────────────────────────────────────────────────────┘
```

Both clients are viewers of one core, so what a person types in either is the same terminal.

## Requirements

- Windows 11 with the Herdr app (herdr-core 0.1.19 was verified) and a running core.
- WSL2 with `interop` on (the default) and Bun. Ovis checked out and `bun install` done.
- The core is not started, stopped or restarted by anything below.

## Configure

`OVIS_HC_BIN` names the Windows `hc.exe` as WSL sees it; `OVIS_RUNTIME=herdr-core` picks the runtime.
The path is the one the Herdr app installs per user (adjust the user name):

```bash
export OVIS_RUNTIME=herdr-core
export OVIS_HC_BIN="/mnt/c/Users/<you>/AppData/Local/Programs/herdr-core/hc.exe"
HOST=127.0.0.1 PORT=7317 bun run server
```

Nothing else is needed: `hc.exe` finds the core by itself. Check first, read-only:

```bash
"$OVIS_HC_BIN" --version        # hc 0.1.19
"$OVIS_HC_BIN" server status    # the running core, never a new one
"$OVIS_HC_BIN" ls --json
```

Discovery runs only `--version` on a candidate (`server/herdr-core/discovery.ts`), so looking for
`hc` never starts a core.

### What shows up

| In Ovis | Comes from |
|---|---|
| A machine for the Windows core (its Windows terminals, e.g. `pwsh.exe`) | the core's own terminals |
| A machine per `hc machine` the core has (here `wsl-ubuntu`, with its workspaces, tabs and panes) | the core's machines; the Herdr app's `herdr.space` / `herdr.tab` labels |
| Agent kind and state (idle, working, done) | herdr-core's terminal state |
| Project folder | each terminal's `cwd`; a WSL path is a real path to the server, so `git worktree list` there works |

A Windows folder (`C:\...`) is not a path the Linux server can run git in: repository and worktree
facts for a Windows terminal are not shown. Worktrees Ovis itself opens carry the `ovis.worktree`
label; ones created in the Herdr app appear only as the folder their terminals are in.

## Typing

Text sent to a pane (`POST /api/pane/input`) is typed without Enter; `POST /api/pane/keys` with
`["Enter"]` sends it. Ovis never sends either by itself, and nothing typed during a disconnect is
sent on reconnect: it waits as a draft.

## Start, stop, update

`ovis-wsl.sh` (this folder) starts Ovis on loopback with `OVIS_RUNTIME=herdr-core`, `OVIS_HC_BIN` set
to the Windows `hc.exe` and the token below. It finds `hc.exe` under `%LOCALAPPDATA%` itself;
`OVIS_HC_BIN` or `$OVIS_CONFIG_DIR/wsl.env` (`KEY=value` lines, also `PORT`) overrides it.

```bash
S=docs/windows-wsl-herdr-core/ovis-wsl.sh
$S token create     # once: ~/.config/ovis/token.env, directory 700, file 600; never printed
$S start            # 127.0.0.1:7317; log in ~/.local/state/ovis-wsl/server.log (mode 600)
$S status           # pid, hc.exe version, a warning if the port listens beyond loopback
$S stop             # stops only the server it started (checked by its command line)
$S pair             # a six-digit code for one more device, valid 10 minutes (set OVIS_URL in wsl.env to print the address too)
$S update           # git fetch + fast-forward + bun install --frozen-lockfile; restarts only if it ran
$S token rotate     # a new token; restart to use it, and sign each device in again
```

The script never runs `hc server start|stop|restart`, `hc ls` or `hc server status` (each starts a core
when none runs): only `hc.exe --version`. Stopping Ovis ends its `hc.exe connect` child; the core and every
terminal keep running. It installs no Windows service, scheduled task or firewall rule. A server started
this way ends when WSL shuts down; start it again, or install the service (next section). No state is lost: terminals live in the core.

## Start with Windows

Three pieces, none of which starts, stops or restarts the Windows core:

| Piece | Who starts it | What it does |
|---|---|---|
| Tailscale | its own Windows service (automatic, installed with it) | the tailnet and `tailscale serve` (kept in Tailscale's config across restarts) |
| WSL + the Ovis service | a Windows scheduled task for your user, at logon (`ovis-wsl-task.ps1`) | starts the distribution and keeps it up, so systemd starts `ovis-wsl.service` |
| The Herdr app and its core | **you**: the Herdr app has no start-with-Windows entry on this PC (no Run key, Startup shortcut or task) | the terminals Ovis shows |

`ovis-wsl.service` is a systemd **user** service (it needs no root and sees only your files). It runs
`ovis-wsl.sh run`: it reads the token from `token.env`, forces `127.0.0.1`, and **waits until a
`herdr-core.exe` runs on Windows** before starting Ovis, because `hc connect` would start a core of its own.
`Restart=on-failure` with at most 5 starts in 5 minutes. Logs go to the journal. The service needs
`Linger=yes` (`loginctl show-user $USER -p Linger`) to start without a login session.

```bash
S=docs/windows-wsl-herdr-core/ovis-wsl.sh
$S service install        # writes ~/.config/systemd/user/ovis-wsl.service, enables and starts it
$S status                 # service state, Windows core, hc.exe version, loopback warning
$S service logs 100       # journalctl --user -u ovis-wsl
$S restart                # with the service installed, start/stop/restart go through systemd: one Ovis
```

```powershell
# Windows PowerShell, your user, no administrator rights
.\docs\windows-wsl-herdr-core\ovis-wsl-task.ps1 -Install -Script /home/<you>/<path>/docs/windows-wsl-herdr-core/ovis-wsl.sh
Start-ScheduledTask 'Ovis WSL keepalive'      # or wait for the next logon
.\docs\windows-wsl-herdr-core\ovis-wsl-task.ps1 -Status
```

The service runs the script from the checkout, so keep that checkout on a branch that has it (after an
`update`, `service logs` shows a failure at once). The task's hidden window flashes once at logon.

To start the Herdr app with Windows too (not done here): add a shortcut to
`%LOCALAPPDATA%\Programs\herdr-app\herdr-app.exe` in `shell:startup`. Without it, after a reboot Ovis waits (`status` says
`windows core: NOT running`) until you open the Herdr app, then comes up by itself within seconds.

If the Windows core stops while Ovis runs, Ovis's next `hc connect` starts a core of its own (hc does that
for any client); open the Herdr app again if that happens.

### Remove it all

```bash
docs/windows-wsl-herdr-core/ovis-wsl.sh service uninstall   # stops and removes the user service
docs/windows-wsl-herdr-core/ovis-wsl.sh keepalive stop      # ends the keepalive sleep, if it still runs
```
```powershell
.\docs\windows-wsl-herdr-core\ovis-wsl-task.ps1 -Uninstall   # removes the task and ends its keepalive
```

Tailscale's `serve` and its Windows service stay until you remove them (`tailscale serve --https=443 off`).

## Android over Tailscale

Verified here: Windows reaches Ovis in WSL at `http://127.0.0.1:7317`. This WSL runs
`networkingMode=mirrored` (`wslinfo --networking-mode`), where loopback is shared between Windows and WSL;
a Windows `Invoke-WebRequest` got 401 without the token and 200 with it, and Ovis listens on
`127.0.0.1` only. With the default NAT mode, `localhost` forwarding to WSL is on by default as well, but
that was not tested. Not verified: Tailscale itself (not installed on this PC), the phone.

**Who gets in.** Ovis trusts a Tailscale login only when it can compare it with this PC's login from
`tailscale status`, which Ovis runs where it runs. In WSL there is no `tailscale`, so a phone is not
recognised as "you": it enters the **token** (once per browser, kept for a year) or a six-digit **pairing
code** from Settings → Devices and PCs → Connect a device. With a token set, everything else needs it too (this PC
included) ([Access and safety](../guide.md#access-and-safety)).

1. Install Tailscale on Windows (needs approval; it adds a Windows service of its own):
   ```powershell
   winget install --id Tailscale.Tailscale -e
   tailscale up        # sign in; the phone's Tailscale app signs in to the same tailnet
   tailscale status
   ```
2. Start Ovis (above). Check from Windows PowerShell that it answers on loopback and wants the token:
   ```powershell
   curl.exe -s -o NUL -w "%{http_code}" http://127.0.0.1:7317/api/machines    # 401
   ```
3. Publish it inside the tailnet only, over HTTPS (needs approval; it changes Tailscale's own
   configuration, not a firewall or the router; `--bg` keeps it until you turn it off):
   ```powershell
   tailscale serve --bg --https=443 http://127.0.0.1:7317
   tailscale serve status        # must say "(tailnet only)"
   ```
4. Check that nothing is public:
   ```powershell
   tailscale funnel status       # must report no Funnel: nothing listed, or "No serve config"
   tailscale serve status        # no "(Funnel on)" next to the address
   ```
   ```bash
   docs/windows-wsl-herdr-core/ovis-wsl.sh status    # no WARNING: still 127.0.0.1 only
   ```
   Do not run `tailscale funnel`: it publishes to the internet. Open no router port, and no
   firewall rule is needed (the only listener is on loopback).
5. On the phone (Tailscale on), open `https://<pc>.<tailnet>.ts.net` in Chrome, enter the token (read it
   on the PC with `sed -n 's/^OVIS_TOKEN=//p' ~/.config/ovis/token.env`, not in a shared screen or log),
   then Settings → Devices and PCs → Connect a device (or the browser's Install app).
6. Undo: `tailscale serve --https=443 off` (Windows), `$S stop` (WSL). The core is untouched either way.

Checks on the phone: on Wi-Fi and again on mobile data the address opens; the workspaces and panes match
the Herdr app's; output updates without reloading; after locking the phone, the page reconnects.

## Tests

- `bun test server/herdr-core/discovery.test.ts`: an `hc.exe` path named by `OVIS_HC_BIN` on Linux.
- Isolated check (what the 2026-11-09 run did): a second Windows core under its own session,
  `HC_SESSION=ovis-wsltest` and `WSLENV=HC_SESSION` (WSLENV lists the variable by name, without a
  `/u` flag), so `hc.exe` reads it. Start it with `hc.exe server start`, make terminals with
  `hc.exe run --bg --name <n> <cmd>`, point a throwaway Ovis (`OVIS_STATE_DIR` in a temp folder,
  loopback, own port) at it with the same two variables, then stop it with
  `HC_SESSION=ovis-wsltest hc.exe server stop` after `server status` shows its own core id, not
  the real one.

| Check | Result |
|---|---|
| Ovis finds the real core and lists its workspaces and panes (read-only) | PASS |
| Read, input once, Enter once, in an isolated Windows core | PASS |
| Live `/ws` attach streams output (Unicode intact) from the isolated core | PASS |
| `hc.exe connect` killed: Ovis reopens it, panes and ticker continue, nothing is typed twice | PASS |
| Invalid pane, missing fields, wrong JSON: 404 / 400, no write | PASS |
| One real idle pane viewed with `keep_size`; size, turn, labels and foreground unchanged | PASS |
| `ovis-wsl.sh` start / status / stop; Windows localhost: 401 without the token, 200 with it; loopback only; token absent from the log; core untouched | PASS |
| Systemd user service: start/stop/restart/status/logs; `kill -9` restarts it (`Restart=on-failure`); a second `run` is refused (port, then state dir); token not in the unit or journal; loopback only | PASS |
| `run` waits for a Windows core and never starts one (checked with a stand-in `tasklist.exe`) | PASS |
| Logon task: created for the user, one keepalive at a time, `Start-ScheduledTask` twice leaves one `sleep` | PASS |
| Android over Tailscale Serve (Wi-Fi and mobile data), pairing, interaction, reconnection | PASS (checked by the user on a phone) |
| Cold start after a Windows restart (task, WSL, service, core, Tailscale) | NOT RUN (needs a restart) |
| Auth rejects an unauthenticated non-loopback client | NOT RUN (loopback only) |
| `tailscale serve` HTTPS, tailnet only, no Funnel (`tailscale serve status`: tailnet only; no `AllowFunnel`) | PASS |
| Windows (`C:\...`) repository and worktree facts from WSL | Not supported |

## Troubleshooting

- `hc could not be started`: the path in `OVIS_HC_BIN` is wrong or interop is off (`cat /proc/sys/fs/binfmt_misc/WSLInterop*`).
- Ovis shows no machine: `"$OVIS_HC_BIN" server status` must answer from WSL; if it names a different core, check `HC_SESSION` in the environment.
- A variable does not reach `hc.exe`: list it in `WSLENV` (`export WSLENV=HC_SESSION`).

## Uninstall

Remove the automatic start (above), run `ovis-wsl.sh stop`, then delete `~/.config/ovis/token.env` and `~/.local/state/ovis-wsl`, and turn the Tailscale publication off if you made it. The core, the Herdr app and every terminal
are untouched.
