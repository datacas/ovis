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

## Run it in the background, safely

Run Ovis in a shell you own (`tmux`, or a Herdr pane) and stop it with its process only. Stopping
Ovis ends only its `hc.exe connect` child; the core and its terminals keep running. Do not add a
Windows service, scheduled task or firewall rule for this: none is needed.

## Android over Tailscale

Not installed by this setup, and these steps are not yet run on a device. Steps for when you are ready (WSL has its own network, so install
Tailscale on **Windows** and keep Ovis on loopback inside WSL; WSL2 forwards `localhost` to Windows
by default):

1. Install Tailscale on Windows and on the phone; sign both in to the same tailnet.
2. In WSL, start Ovis on loopback with a token, so nothing but the tailnet can reach it:
   ```bash
   export OVIS_TOKEN="$(openssl rand -hex 32)"   # keep it in ~/.config/ovis/env; never print or commit it
   HOST=127.0.0.1 PORT=7317 bun run server
   ```
3. On Windows (PowerShell), serve it to the tailnet over HTTPS (no router port, not public):
   ```powershell
   tailscale serve --bg --https=443 http://127.0.0.1:7317
   tailscale serve status
   ```
4. Open the `https://<pc>.<tailnet>.ts.net` address on the phone and pair it. Undo with
   `tailscale serve --https=443 off`.

Never bind `0.0.0.0`, and never use `tailscale funnel` (public). Whoever reaches Ovis can type into
the user's terminals.

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
| Android device, Tailscale from mobile data | NOT RUN (needs the device and Tailscale) |
| Auth rejects an unauthenticated non-loopback client | NOT RUN (loopback only) |
| Windows (`C:\...`) repository and worktree facts from WSL | Not supported |

## Troubleshooting

- `hc could not be started`: the path in `OVIS_HC_BIN` is wrong or interop is off (`cat /proc/sys/fs/binfmt_misc/WSLInterop*`).
- Ovis shows no machine: `"$OVIS_HC_BIN" server status` must answer from WSL; if it names a different core, check `HC_SESSION` in the environment.
- A variable does not reach `hc.exe`: list it in `WSLENV` (`export WSLENV=HC_SESSION`).

## Uninstall

Stop the Ovis process and remove the two variables. The core, the Herdr app and every terminal
are untouched.
