#!/usr/bin/env bash
# Start, stop, check and update Ovis in WSL2 on the Herdr app's Windows herdr-core.
#
#   ovis-wsl.sh start | stop | restart | status | pair | update | token create|rotate
#   ovis-wsl.sh service install | uninstall | status | logs     (start with WSL, as a systemd user service)
#   ovis-wsl.sh run                                             (foreground; what the service runs)
#   ovis-wsl.sh keepalive | keepalive stop                      (what the Windows logon task runs; see ovis-wsl-task.ps1)
#
# It only ever starts or stops the Ovis server it started. It never runs `hc server
# start|stop|restart`, `hc ls` or `hc server status` (each starts a core when none runs), only
# `hc.exe --version`, so the Windows core and its terminals are never touched. Ovis starts only
# once the Herdr app's core is running (`tasklist.exe`), because `hc connect` would start one.
# With the service installed, start, stop and restart go through systemd, so there is one Ovis.
#
# Settings, all optional, in $OVIS_CONFIG_DIR/wsl.env (KEY=value lines) or the environment:
#   OVIS_HC_BIN   the Windows hc.exe as WSL sees it (default: found under %LOCALAPPDATA%)
#   PORT          Ovis's port on loopback (default 7317)
#   OVIS_URL      the HTTPS address a phone opens, only to print it with a pairing code
# The token lives in $OVIS_CONFIG_DIR/token.env (mode 600) and is never printed.
set -euo pipefail

REPO="${OVIS_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CONFIG_DIR="${OVIS_CONFIG_DIR:-$HOME/.config/ovis}"
RUN_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ovis-wsl"
PID_FILE="$RUN_DIR/server.pid"
LOG_FILE="$RUN_DIR/server.log"

die() { printf 'ovis-wsl: %s\n' "$*" >&2; exit 1; }

# one KEY from a KEY=value file, without executing it
file_setting() { [ -r "$2" ] && sed -n "s/^$1=//p" "$2" | tail -n 1 || true; }

private_dir() { mkdir -p "$1" && chmod 700 "$1"; }

settings() {
  PORT="${PORT:-$(file_setting PORT "$CONFIG_DIR/wsl.env")}"; PORT="${PORT:-7317}"
  OVIS_HC_BIN="${OVIS_HC_BIN:-$(file_setting OVIS_HC_BIN "$CONFIG_DIR/wsl.env")}"
  if [ -z "$OVIS_HC_BIN" ]; then
    local local_app
    local_app="$(powershell.exe -NoProfile -Command '$env:LOCALAPPDATA' 2>/dev/null | tr -d '\r')" || true
    [ -n "$local_app" ] || die "cannot read %LOCALAPPDATA%: set OVIS_HC_BIN to the Windows hc.exe (/mnt/c/.../herdr-core/hc.exe)"
    OVIS_HC_BIN="$(wslpath -u "$local_app")/Programs/herdr-core/hc.exe"
  fi
  [ -f "$OVIS_HC_BIN" ] || die "no hc.exe at $OVIS_HC_BIN (set OVIS_HC_BIN)"
}

token_file() { printf '%s/token.env' "$CONFIG_DIR"; }

token_value() {
  local file mode
  file="$(token_file)"
  [ -f "$file" ] || return 0
  mode="$(stat -c %a "$file")"
  [ "$mode" = 600 ] || die "$file must be mode 600 (is $mode): chmod 600 '$file'"
  file_setting OVIS_TOKEN "$file"
}

UNIT=ovis-wsl.service
UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT"

has_unit() { [ -f "$UNIT_FILE" ]; }

# a herdr-core process on Windows, asked without starting anything
core_running() { tasklist.exe /FI 'IMAGENAME eq herdr-core.exe' /NH 2>/dev/null | tr -d '\r' | grep -qi 'herdr-core'; }

# settings, binaries and the token, in $TOKEN; nothing is started
prepare() {
  settings
  command -v bun >/dev/null || die "bun is not installed"
  "$OVIS_HC_BIN" --version | grep -q '^hc ' || die "$OVIS_HC_BIN does not answer --version as hc"
  private_dir "$CONFIG_DIR"
  TOKEN="$(token_value)"
  [ -n "$TOKEN" ] || die "no token: run '$0 token create' first"
}

running_pid() {
  local pid
  [ -f "$PID_FILE" ] || return 1
  pid="$(cat "$PID_FILE")"
  # only the server this script started: a reused pid is not ours
  [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q 'server/index.ts' || return 1
  printf '%s' "$pid"
}

cmd_start() {
  if has_unit; then
    systemctl --user start "$UNIT"
    wait_listening
    return 0
  fi
  prepare
  if running_pid >/dev/null; then die "already running (pid $(running_pid))"; fi
  if ss -ltn "sport = :$PORT" | grep -q LISTEN; then die "port $PORT is already in use"; fi
  core_running || die "no herdr-core is running on Windows: open the Herdr app first (Ovis would start a core of its own)"
  private_dir "$RUN_DIR"
  # exec keeps the subshell's pid as the server's, so the pid file names the server itself
  ( cd "$REPO" && umask 077 \
    && exec env OVIS_RUNTIME=herdr-core OVIS_HC_BIN="$OVIS_HC_BIN" OVIS_TOKEN="$TOKEN" HOST=127.0.0.1 PORT="$PORT" \
       setsid nohup bun run server/index.ts >>"$LOG_FILE" 2>&1 </dev/null ) &
  echo $! >"$PID_FILE"
  wait_listening
}

wait_listening() {
  settings
  for _ in $(seq 1 30); do
    if ss -ltn "sport = :$PORT" | grep -q LISTEN; then printf 'Ovis is listening on 127.0.0.1:%s\n' "$PORT"; return 0; fi
    sleep 1
  done
  die "did not start within 30 s (manual: $LOG_FILE; service: $0 service logs)"
}

# In the foreground, for systemd: waits for the Windows core, then becomes the server (logs go to the journal)
cmd_run() {
  prepare
  if ss -ltn "sport = :$PORT" | grep -q LISTEN; then die "port $PORT is already in use"; fi
  local waited=0
  until core_running; do
    [ $((waited % 60)) -ne 0 ] || echo "waiting for the Herdr app's core on Windows (Ovis never starts one)"
    sleep 5; waited=$((waited + 5))
  done
  cd "$REPO"
  umask 077
  exec env OVIS_RUNTIME=herdr-core OVIS_HC_BIN="$OVIS_HC_BIN" OVIS_TOKEN="$TOKEN" HOST=127.0.0.1 PORT="$PORT" bun run server/index.ts
}

# Keeps this distribution from stopping, for the Windows logon task: one `sleep` under a lock (a second
# call returns at once), named so that `keepalive stop` ends it and nothing else.
cmd_keepalive() {
  if [ "${1:-}" = stop ]; then pkill -f '^ovis-wsl-keepalive' || echo "no keepalive running"; return 0; fi
  flock -n /tmp/ovis-wsl-keepalive.lock bash -c 'exec -a ovis-wsl-keepalive sleep infinity' || true
}

cmd_stop() {
  if has_unit && systemctl --user is-active --quiet "$UNIT"; then
    systemctl --user stop "$UNIT"
    echo "stopped (the Windows core and its terminals keep running)"
    return 0
  fi
  local pid
  pid="$(running_pid)" || { echo "not running"; rm -f "$PID_FILE"; return 0; }
  kill "$pid"
  for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && die "pid $pid did not stop"
  rm -f "$PID_FILE"
  echo "stopped (the Windows core and its terminals keep running)"
}

cmd_service() {
  case "${1:-}" in
    install)
      systemctl --user show-environment >/dev/null 2>&1 || die "no systemd user session: add [boot] systemd=true to /etc/wsl.conf and restart WSL"
      prepare
      if running_pid >/dev/null; then die "a manually started Ovis runs (pid $(running_pid)): '$0 stop' first"; fi
      local bun_dir win; bun_dir="$(dirname "$(command -v bun)")"; win=/mnt/c/Windows/System32
      mkdir -p "$(dirname "$UNIT_FILE")"
      ( umask 077; cat >"$UNIT_FILE" <<UNITEOF
[Unit]
Description=Ovis on the Windows herdr-core, loopback only
# at most 5 starts in 5 minutes: a failing Ovis stops being retried
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$(readlink -f "${BASH_SOURCE[0]}") run
Restart=on-failure
RestartSec=10
# bun, and tasklist.exe / powershell.exe through WSL interop
Environment=PATH=$bun_dir:/usr/local/bin:/usr/bin:/bin:$win:$win/WindowsPowerShell/v1.0
NoNewPrivileges=yes
UMask=0077

[Install]
WantedBy=default.target
UNITEOF
      )
      systemctl --user daemon-reload
      systemctl --user enable --now "$UNIT"
      echo "installed and started: $UNIT_FILE"
      loginctl show-user "$USER" -p Linger | grep -q yes || echo "note: run 'loginctl enable-linger $USER' so it starts without a login"
      ;;
    uninstall)
      has_unit || { echo "not installed"; return 0; }
      systemctl --user disable --now "$UNIT" || true
      rm -f "$UNIT_FILE"
      systemctl --user daemon-reload
      systemctl --user reset-failed "$UNIT" 2>/dev/null || true
      echo "removed (Ovis is stopped; the Windows core is untouched)"
      ;;
    status) systemctl --user status "$UNIT" --no-pager ;;
    logs) journalctl --user -u "$UNIT" --no-pager -n "${2:-50}" ;;
    *) die "usage: service install|uninstall|status|logs" ;;
  esac
}

cmd_status() {
  settings
  if has_unit; then
    echo "service: $(systemctl --user is-active "$UNIT" || true), $(systemctl --user is-enabled "$UNIT" || true)"
  elif pid="$(running_pid)"; then echo "ovis: running, pid $pid, 127.0.0.1:$PORT"; else echo "ovis: not running"; fi
  if core_running; then echo "windows core: running"; else echo "windows core: NOT running (open the Herdr app)"; fi
  echo "hc.exe: $("$OVIS_HC_BIN" --version)"
  if ss -ltn | awk -v p=":$PORT\$" '$4 ~ p {print $4}' | grep -v '^127\.0\.0\.1:' | grep -q .; then echo "WARNING: port $PORT listens beyond loopback"; fi
}

# A six-digit pairing code for one more device (good for 10 minutes), the way Settings → Phone & devices makes it.
cmd_pair() {
  settings
  ss -ltn "sport = :$PORT" | grep -q LISTEN || die "Ovis is not running: $0 start"
  local token reply
  token="$(token_value)"
  reply="$(curl -fsS -m 10 -X POST -H "Authorization: Bearer $token" -H 'x-herdr-machine: 1' -H 'content-type: application/json' \
    -d '{}' "http://127.0.0.1:$PORT/api/devices/pair/start")" || die "could not start a pairing"
  printf '%s' "$reply" | bun -e 'const d = JSON.parse(await Bun.stdin.text()); const c = String(d.code); console.log(`Pairing code: ${c.slice(0, 3)} ${c.slice(3)}  (one device, until ${new Date(d.expires_at).toLocaleTimeString()})`)'
  local url; url="${OVIS_URL:-$(file_setting OVIS_URL "$CONFIG_DIR/wsl.env")}"
  [ -z "$url" ] || echo "Open $url on the phone and enter the code."
}

cmd_update() {
  cd "$REPO"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes in $REPO: commit or stash first"
  local was_running=0
  if running_pid >/dev/null || { has_unit && systemctl --user is-active --quiet "$UNIT"; }; then was_running=1; fi
  git fetch --quiet origin
  git merge --ff-only '@{upstream}' || die "cannot fast-forward: merge or rebase by hand"
  bun install --frozen-lockfile
  if [ "$was_running" = 1 ]; then cmd_stop; cmd_start; fi
}

cmd_token() {
  local file; file="$(token_file)"
  case "${1:-}" in
    create) [ ! -e "$file" ] || die "$file exists: use 'token rotate'" ;;
    rotate) ;;
    *) die "usage: token create|rotate" ;;
  esac
  private_dir "$CONFIG_DIR"
  ( umask 077 && printf 'OVIS_TOKEN=%s\n' "$(openssl rand -hex 32)" >"$file" )
  chmod 600 "$file"
  echo "token written to $file (mode 600, not shown). Restart Ovis to use it."
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  run) cmd_run ;;
  keepalive) shift; cmd_keepalive "${1:-}" ;;
  service) shift; cmd_service "${1:-}" "${2:-}" ;;
  status) cmd_status ;;
  pair) cmd_pair ;;
  update) cmd_update ;;
  token) shift; cmd_token "${1:-}" ;;
  *) die "usage: $0 start|stop|restart|status|run|keepalive|service|pair|update|token create|rotate" ;;
esac
