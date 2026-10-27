#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$APP_DIR/../.." && pwd)"
SOCKET="${DIRECTOR_SOCKET:-$HOME/.director/daemon.sock}"
LOG_DIR="${TMPDIR:-/tmp}"
BUILD=1

if [ "${1:-}" = "--no-build" ]; then
  BUILD=0
fi

if [ "$BUILD" -eq 1 ]; then
  "$SCRIPT_DIR/build.sh"
fi

APP_BINARY="$APP_DIR/.build/Build/Products/Debug/Director.app/Contents/MacOS/Director"
if [ ! -x "$APP_BINARY" ]; then
  echo "error: Director.app is not built; run apps/macos/scripts/build.sh first." >&2
  exit 1
fi

if [ ! -S "$SOCKET" ]; then
  if [ ! -x "$ROOT/target/debug/director-daemon" ]; then
    echo "error: director-daemon is not built; run apps/macos/scripts/build.sh first." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$SOCKET")"
  chmod 700 "$(dirname "$SOCKET")" 2>/dev/null || true
  "$ROOT/target/debug/director-daemon" --socket "$SOCKET" \
    > "$LOG_DIR/director-daemon.log" 2>&1 &
  echo $! > "$LOG_DIR/director-daemon.pid"
  for _ in $(seq 1 30); do
    [ -S "$SOCKET" ] && break
    sleep 0.1
  done
fi

if [ ! -S "$SOCKET" ]; then
  echo "error: director-daemon did not open $SOCKET" >&2
  echo "       See $LOG_DIR/director-daemon.log" >&2
  exit 1
fi

if pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
  osascript -e 'tell application "Director" to activate' >/dev/null 2>&1 || true
else
  DIRECTOR_SOCKET="$SOCKET" "$APP_BINARY" \
    > "$LOG_DIR/director-app.log" 2>&1 &
fi

echo "Director is using $SOCKET"
echo "Daemon log: $LOG_DIR/director-daemon.log"
echo "App log:    $LOG_DIR/director-app.log"
