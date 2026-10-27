#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$APP_DIR/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/director-verify.XXXXXX")"
SOCKET="$TMP/daemon.sock"
DAEMON_PID=""

cleanup() {
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== DirectorKit unit tests"
(cd "$APP_DIR/DirectorKit" && swift test)

echo
echo "== Build director-daemon"
(cd "$ROOT" && cargo build -p director-daemon --locked)

echo
echo "== Protocol smoke test against a real daemon"
"$ROOT/target/debug/director-daemon" --socket "$SOCKET" > "$TMP/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 30); do
  [ -S "$SOCKET" ] && break
  sleep 0.1
done
if [ ! -S "$SOCKET" ]; then
  echo "error: daemon did not start; log follows" >&2
  cat "$TMP/daemon.log" >&2
  exit 1
fi

(cd "$APP_DIR/DirectorKit" && swift run DirectorProbe --socket "$SOCKET" --smoke)

cat <<'EOF'

== App-level checks (manual)

Run `scripts/demo.sh`, then verify in the two live panes:

  1. Keyboard input: click a pane and type. Text appears in the agent composer.
  2. Unicode: type `café 日本語`. The characters render without replacement glyphs.
  3. Selection/copy: Cmd+A, Cmd+C, then `pbpaste` contains terminal text.
  4. Scrollback: run `/help` in Claude Code and scroll with the wheel. The
     terminal view moves through the retained buffer. Full-screen agent TUIs
     may capture wheel events while mouse reporting is enabled.
  5. Resize: resize the window or drag the pane divider. The status bar columns
     and rows update and the agent TUI reflows.
  6. Reattach: quit Director, reopen it, and confirm both agent processes are
     still running and their output is replayed.

The prototype was verified on macOS 27 with Claude Code 2.1.311 and Gemini CLI
0.46.0. See apps/macos/README.md for the recorded results.
EOF
