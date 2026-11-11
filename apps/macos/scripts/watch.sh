#!/usr/bin/env bash
set -euo pipefail

# Rebuild and relaunch Fleet whenever the macOS sources change, so UI edits
# appear without running the build by hand.
#
# The daemon is never restarted, so sessions keep running and every agent
# stays connected across a reload. Only the app window is replaced, which
# means scroll position and selection in the panes are lost.
#
# Uses watchexec when it is installed and falls back to polling the source
# tree otherwise. Both modes build and launch once, then wait for changes.
#
# Usage: scripts/watch.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BINARY="$APP_DIR/.build/Build/Products/Debug/Fleet.app/Contents/MacOS/Fleet"

LOG_DIR="${TMPDIR:-/tmp}"
RUN_LOG="$LOG_DIR/fleet-watch.log"

POLL_INTERVAL=1
DEBOUNCE="500ms"

# Sources that need a rebuild, and the extensions worth reacting to.
WATCH_PATHS=("$APP_DIR/Fleet" "$APP_DIR/FleetKit" "$APP_DIR/project.yml")
EXTENSIONS="swift,yml,yaml,plist,strings,json"

# Build products, git state, and the generated Xcode project must never
# retrigger the watcher.
IGNORES=(
  "$APP_DIR/.build/**"
  "$APP_DIR/FleetKit/.build/**"
  "$APP_DIR/Fleet.xcodeproj/**"
  "**/.git/**"
)

# Build and relaunch. A full build prints thousands of lines, so only the
# first one (when there is no app yet) is streamed; later ones stay quiet and
# report a summary, dumping errors only when something fails.
reload() {
  if [ ! -x "$APP_BINARY" ]; then
    echo "watch: first build, this can take a few minutes" >&2
    if ! "$SCRIPT_DIR/run.sh"; then
      echo "watch: build failed; still watching for changes" >&2
      return 1
    fi
    return 0
  fi

  local started elapsed
  started="$(date +%s)"
  : > "$RUN_LOG"
  if "$SCRIPT_DIR/run.sh" >> "$RUN_LOG" 2>&1; then
    elapsed=$(( $(date +%s) - started ))
    echo "watch: reloaded in ${elapsed}s"
    return 0
  fi

  echo "watch: build failed, still watching. Errors from $RUN_LOG:" >&2
  grep -E 'error(:|\[)' "$RUN_LOG" | tail -n 20 >&2 || tail -n 20 "$RUN_LOG" >&2
  return 1
}

# A cheap fingerprint of every watched source file: modification time plus
# path for each one. Any add, remove, or save changes it.
snapshot() {
  {
    find "${WATCH_PATHS[@]}" -type f \
      \( -name '*.swift' -o -name '*.yml' -o -name '*.yaml' \
         -o -name '*.plist' -o -name '*.strings' -o -name '*.json' \) \
      -not -path '*/.build/*' \
      -exec stat -f '%m %N' {} +
  } | sort | shasum | cut -d ' ' -f 1
}

poll_loop() {
  echo "watch: polling every ${POLL_INTERVAL}s (install watchexec for kernel events)" >&2
  reload || true
  previous="$(snapshot)"
  while :; do
    sleep "$POLL_INTERVAL"
    current="$(snapshot)"
    if [ "$current" != "$previous" ]; then
      previous="$current"
      reload || true
    fi
  done
}

# Internal: watchexec runs this script again for a single reload, so the
# startup and change paths share the same logic. A failed build exits
# non-zero so watchexec reports it, but it keeps watching.
if [ "${1:-}" = "--reload-once" ]; then
  reload
  exit $?
fi

if command -v watchexec >/dev/null 2>&1; then
  args=()
  for path in "${WATCH_PATHS[@]}"; do
    args+=(--watch "$path")
  done
  for path in "${IGNORES[@]}"; do
    args+=(--ignore "$path")
  done
  echo "watch: rebuilding on change with watchexec (Ctrl-C to stop)" >&2
  exec watchexec \
    "${args[@]}" \
    --exts "$EXTENSIONS" \
    --debounce "$DEBOUNCE" \
    -- "$SCRIPT_DIR/watch.sh" --reload-once
fi

poll_loop
