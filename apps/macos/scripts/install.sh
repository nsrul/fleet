#!/usr/bin/env bash
# Build the current checkout and install it, replacing older Fleet installs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$APP_DIR/../.." && pwd)"

INSTALL_DIR="${FLEET_INSTALL_DIR:-$HOME/Applications}"
DAEMON_DIR="${FLEET_DAEMON_DIR:-$HOME/.fleet/bin}"
APP_DEST="$INSTALL_DIR/Fleet.app"
DAEMON_DEST="$DAEMON_DIR/fleet-daemon"
APP_SRC="$APP_DIR/.build/Build/Products/Release/Fleet.app"
DAEMON_SRC="$ROOT/target/release/fleet-daemon"

# Locations Fleet already searches. An older copy in any of them would keep
# launching after this install.
APP_PATHS=(
  "$HOME/Applications/Fleet.app"
  "/Applications/Fleet.app"
  "$APP_DEST"
)
DAEMON_PATHS=(
  "$HOME/.fleet/bin/fleet-daemon"
  "/opt/homebrew/bin/fleet-daemon"
  "/usr/local/bin/fleet-daemon"
  "$DAEMON_DEST"
)

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: Fleet.app installs on macOS." >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required. Install a Rust toolchain (1.85 or newer)." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is required. Install Xcode 16 or newer." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$DAEMON_DIR"
if [ ! -w "$INSTALL_DIR" ]; then
  echo "error: $INSTALL_DIR is not writable. Set FLEET_INSTALL_DIR to a directory you own." >&2
  exit 1
fi
if [ ! -w "$DAEMON_DIR" ]; then
  echo "error: $DAEMON_DIR is not writable. Set FLEET_DAEMON_DIR to a directory you own." >&2
  exit 1
fi
# The app binds its socket in ~/.fleet. An explicit socket path does not
# tighten that directory, so match the permissions run.sh uses.
if [ "$DAEMON_DIR" = "$HOME/.fleet/bin" ]; then
  chmod 700 "$HOME/.fleet" 2>/dev/null || true
fi
chmod 700 "$DAEMON_DIR" 2>/dev/null || true

cd "$ROOT"

echo "==> Building fleet-daemon (release)"
cargo build -p fleet-daemon --release --locked

echo
echo "==> Building Fleet.app (Release)"
if command -v xcodegen >/dev/null 2>&1; then
  (cd "$APP_DIR" && xcodegen generate)
else
  echo "warning: xcodegen is not installed; using the checked-in Xcode project." >&2
  echo "         Install it with: brew install xcodegen" >&2
fi

# Release keeps the project's ad-hoc signature. Debug builds skip signing.
xcodebuild \
  -project "$APP_DIR/Fleet.xcodeproj" \
  -scheme Fleet \
  -configuration Release \
  -derivedDataPath "$APP_DIR/.build" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build

if [ ! -d "$APP_SRC" ]; then
  echo "error: Release build did not produce $APP_SRC" >&2
  exit 1
fi
if [ ! -x "$DAEMON_SRC" ]; then
  echo "error: release build did not produce $DAEMON_SRC" >&2
  exit 1
fi
if ! cmp -s "$DAEMON_SRC" "$APP_SRC/Contents/Resources/fleet-daemon"; then
  echo "error: Fleet.app does not contain the release fleet-daemon." >&2
  exit 1
fi

if pgrep -x Fleet >/dev/null 2>&1 || pgrep -x fleet-daemon >/dev/null 2>&1; then
  echo
  echo "==> Stopping older Fleet processes"
fi

if pgrep -x Fleet >/dev/null 2>&1; then
  osascript -e 'tell application "Fleet" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    pgrep -x Fleet >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x Fleet >/dev/null 2>&1; then
    killall Fleet >/dev/null 2>&1 || true
    sleep 0.2
  fi
fi

# SIGTERM is the daemon's clean shutdown. The installed app would otherwise
# keep talking to the previous binary on the default socket.
if pgrep -x fleet-daemon >/dev/null 2>&1; then
  pkill -TERM -x fleet-daemon >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    pgrep -x fleet-daemon >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x fleet-daemon >/dev/null 2>&1; then
    pkill -KILL -x fleet-daemon >/dev/null 2>&1 || true
    sleep 0.2
  fi
fi

echo "==> Removing older installs"
for app in "${APP_PATHS[@]}"; do
  if [ ! -d "$app" ]; then
    continue
  fi
  if [ ! -w "$(dirname "$app")" ]; then
    echo "warning: leaving $app in place; $(dirname "$app") is not writable." >&2
    continue
  fi
  rm -rf "$app"
  echo "    removed $app"
done

for daemon in "${DAEMON_PATHS[@]}"; do
  if [ ! -e "$daemon" ] && [ ! -L "$daemon" ]; then
    continue
  fi
  if [ -L "$daemon" ]; then
    echo "warning: leaving symlink $daemon in place." >&2
    continue
  fi
  if [ ! -w "$(dirname "$daemon")" ]; then
    echo "warning: leaving $daemon in place; $(dirname "$daemon") is not writable." >&2
    continue
  fi
  rm -f "$daemon"
  echo "    removed $daemon"
done

echo "==> Installing Fleet.app"
ditto "$APP_SRC" "$APP_DEST"
if ! codesign --verify --deep --strict "$APP_DEST" >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DEST"
fi
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

echo "==> Installing fleet-daemon"
cp "$DAEMON_SRC" "$DAEMON_DEST"
chmod 755 "$DAEMON_DEST"
xattr -d com.apple.quarantine "$DAEMON_DEST" 2>/dev/null || true

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP_DEST" >/dev/null
fi

echo
echo "Installed Fleet.app:  $APP_DEST"
echo "Installed daemon:     $DAEMON_DEST"
echo
echo "Open it with: open \"$APP_DEST\""
