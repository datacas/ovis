#!/usr/bin/env bash
# Start, stop, check and update Ovis in WSL2 on the Herdr app's Windows herdr-core.
#
#   ovis-wsl.sh start | stop | restart | status | update | token create|rotate
#
# It only ever starts or stops the Ovis server it started. It never runs `hc server
# start|stop|restart`, `hc ls` or `hc server status` (each starts a core when none runs), only
# `hc.exe --version`, so the Windows core and its terminals are never touched.
#
# Settings, all optional, in $OVIS_CONFIG_DIR/wsl.env (KEY=value lines) or the environment:
#   OVIS_HC_BIN   the Windows hc.exe as WSL sees it (default: found under %LOCALAPPDATA%)
#   PORT          Ovis's port on loopback (default 7317)
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

running_pid() {
  local pid
  [ -f "$PID_FILE" ] || return 1
  pid="$(cat "$PID_FILE")"
  # only the server this script started: a reused pid is not ours
  [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q 'server/index.ts' || return 1
  printf '%s' "$pid"
}

cmd_start() {
  settings
  command -v bun >/dev/null || die "bun is not installed"
  if running_pid >/dev/null; then die "already running (pid $(running_pid))"; fi
  if ss -ltn "sport = :$PORT" | grep -q LISTEN; then die "port $PORT is already in use"; fi
  "$OVIS_HC_BIN" --version | grep -q '^hc ' || die "$OVIS_HC_BIN does not answer --version as hc"
  private_dir "$CONFIG_DIR"; private_dir "$RUN_DIR"
  local token; token="$(token_value)"
  [ -n "$token" ] || die "no token: run '$0 token create' first"
  # exec keeps the subshell's pid as the server's, so the pid file names the server itself
  ( cd "$REPO" && umask 077 \
    && exec env OVIS_RUNTIME=herdr-core OVIS_HC_BIN="$OVIS_HC_BIN" OVIS_TOKEN="$token" HOST=127.0.0.1 PORT="$PORT" \
       setsid nohup bun run server/index.ts >>"$LOG_FILE" 2>&1 </dev/null ) &
  echo $! >"$PID_FILE"
  for _ in $(seq 1 30); do
    if ss -ltn "sport = :$PORT" | grep -q LISTEN; then printf 'Ovis is listening on 127.0.0.1:%s (pid %s)\n' "$PORT" "$(cat "$PID_FILE")"; return 0; fi
    sleep 1
  done
  die "did not start within 30 s; see $LOG_FILE"
}

cmd_stop() {
  local pid
  pid="$(running_pid)" || { echo "not running"; rm -f "$PID_FILE"; return 0; }
  kill "$pid"
  for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && die "pid $pid did not stop"
  rm -f "$PID_FILE"
  echo "stopped (the Windows core and its terminals keep running)"
}

cmd_status() {
  settings
  if pid="$(running_pid)"; then echo "ovis: running, pid $pid, 127.0.0.1:$PORT"; else echo "ovis: not running"; fi
  echo "hc.exe: $("$OVIS_HC_BIN" --version)"
  if ss -ltn | awk -v p=":$PORT\$" '$4 ~ p {print $4}' | grep -v '^127\.0\.0\.1:' | grep -q .; then echo "WARNING: port $PORT listens beyond loopback"; fi
}

cmd_update() {
  cd "$REPO"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes in $REPO: commit or stash first"
  local was_running=0; running_pid >/dev/null && was_running=1
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
  status) cmd_status ;;
  update) cmd_update ;;
  token) shift; cmd_token "${1:-}" ;;
  *) die "usage: $0 start|stop|restart|status|update|token create|rotate" ;;
esac
