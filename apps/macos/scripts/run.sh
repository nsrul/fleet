#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$APP_DIR/../.." && pwd)"
SOCKET="${FLEET_SOCKET:-$HOME/.fleet/daemon.sock}"
LOG_DIR="${TMPDIR:-/tmp}"
BUILD=1

if [ "${1:-}" = "--no-build" ]; then
  BUILD=0
fi

if [ "$BUILD" -eq 1 ]; then
  "$SCRIPT_DIR/build.sh"
fi

APP_BINARY="$APP_DIR/.build/Build/Products/Debug/Fleet.app/Contents/MacOS/Fleet"
APP_DYLIB="$APP_DIR/.build/Build/Products/Debug/Fleet.app/Contents/MacOS/Fleet.debug.dylib"
if [ ! -x "$APP_BINARY" ]; then
  echo "error: Fleet.app is not built; run apps/macos/scripts/build.sh first." >&2
  exit 1
fi

# A running Fleet keeps the binary it launched with. After a rebuild, quit
# it so the new app is the one that opens.
if pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
  running_pid="$(pgrep -f "$APP_BINARY" | head -1)"
  binary_mtime="$(stat -f %m "$APP_DYLIB" 2>/dev/null || stat -f %m "$APP_BINARY")"
  start="$(ps -p "$running_pid" -o lstart= | sed 's/^ *//')"
  start_epoch="$(date -j -f "%a %b %e %T %Y" "$start" "+%s" 2>/dev/null || echo 0)"
  if [ "$binary_mtime" -gt "$start_epoch" ]; then
    osascript -e 'tell application "Fleet" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
      pgrep -f "$APP_BINARY" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
      kill "$running_pid" >/dev/null 2>&1 || true
      sleep 0.2
    fi
  fi
fi

if [ ! -S "$SOCKET" ]; then
  if [ ! -x "$ROOT/target/debug/fleet-daemon" ]; then
    echo "error: fleet-daemon is not built; run apps/macos/scripts/build.sh first." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$SOCKET")"
  chmod 700 "$(dirname "$SOCKET")" 2>/dev/null || true
  "$ROOT/target/debug/fleet-daemon" --socket "$SOCKET" \
    > "$LOG_DIR/fleet-daemon.log" 2>&1 &
  echo $! > "$LOG_DIR/fleet-daemon.pid"
  for _ in $(seq 1 30); do
    [ -S "$SOCKET" ] && break
    sleep 0.1
  done
fi

if [ ! -S "$SOCKET" ]; then
  echo "error: fleet-daemon did not open $SOCKET" >&2
  echo "       See $LOG_DIR/fleet-daemon.log" >&2
  exit 1
fi

if pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
  osascript -e 'tell application "Fleet" to activate' >/dev/null 2>&1 || true
else
  FLEET_SOCKET="$SOCKET" "$APP_BINARY" \
    > "$LOG_DIR/fleet-app.log" 2>&1 &
fi

echo "Fleet is using $SOCKET"
echo "Daemon log: $LOG_DIR/fleet-daemon.log"
echo "App log:    $LOG_DIR/fleet-app.log"
