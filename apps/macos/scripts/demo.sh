#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$APP_DIR/../.." && pwd)"
SOCKET="${DIRECTOR_SOCKET:-$HOME/.director/daemon.sock}"
LOG_DIR="${TMPDIR:-/tmp}"

"$SCRIPT_DIR/build.sh"

mkdir -p "$(dirname "$SOCKET")"
chmod 700 "$(dirname "$SOCKET")" 2>/dev/null || true

if [ ! -S "$SOCKET" ]; then
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
  exit 1
fi

CLAUDE="$(command -v claude || true)"
CODEX="$(command -v codex || true)"
GEMINI="$(command -v gemini || true)"

if [ -n "$CLAUDE" ] && [ -n "$CODEX" ]; then
  PROGRAMS=("$CLAUDE" "$CODEX")
  IDS=("demo-claude" "demo-codex")
elif [ -n "$CLAUDE" ] && [ -n "$GEMINI" ]; then
  PROGRAMS=("$CLAUDE" "$GEMINI")
  IDS=("demo-claude" "demo-gemini")
else
  PROGRAMS=("/bin/zsh" "/bin/zsh")
  IDS=("demo-shell-1" "demo-shell-2")
fi

# Remove demo sessions from a previous run. Missing sessions are fine.
(
  cd "$APP_DIR/DirectorKit"
  for id in "${IDS[@]}"; do
    swift run DirectorProbe --socket "$SOCKET" --stop "$id" >/dev/null 2>&1 || true
  done
)

(
  cd "$APP_DIR/DirectorKit"
  swift run DirectorProbe \
    --socket "$SOCKET" \
    --cwd "$ROOT" \
    --program "${PROGRAMS[0]}" \
    --program "${PROGRAMS[1]}" \
    --id "${IDS[0]}" \
    --id "${IDS[1]}" \
    --keep
)

APP_BINARY="$APP_DIR/.build/Build/Products/Debug/Director.app/Contents/MacOS/Director"
osascript -e 'tell application "Director" to quit' >/dev/null 2>&1 || true
sleep 0.5
DIRECTOR_SOCKET="$SOCKET" "$APP_BINARY" \
  > "$LOG_DIR/director-app.log" 2>&1 &

echo
echo "Two live panes: ${IDS[0]} (${PROGRAMS[0]}) and ${IDS[1]} (${PROGRAMS[1]})."
echo "Socket: $SOCKET"
echo "Daemon log: $LOG_DIR/director-daemon.log"
