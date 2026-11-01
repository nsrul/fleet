#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD=1

if [ "${1:-}" = "--no-build" ]; then
  BUILD=0
fi

if [ "$BUILD" -eq 1 ]; then
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild is required. Install Xcode 16 or newer." >&2
    exit 1
  fi
  if command -v xcodegen >/dev/null 2>&1; then
    (cd "$APP_DIR" && xcodegen generate)
  else
    echo "warning: xcodegen is not installed; using the checked-in Xcode project." >&2
  fi
  xcodebuild \
    -project "$APP_DIR/Fleet.xcodeproj" \
    -scheme Fleet \
    -configuration Debug \
    -derivedDataPath "$APP_DIR/.build" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    build \
    CODE_SIGNING_ALLOWED=NO
fi

APP_BUNDLE="$APP_DIR/.build/Build/Products/Debug/Fleet.app"
if [ ! -d "$APP_BUNDLE" ]; then
  echo "error: Fleet.app is not built. Run scripts/preview.sh without --no-build." >&2
  exit 1
fi

VERSION=""
if command -v claude >/dev/null 2>&1; then
  VERSION="$(claude --version 2>/dev/null | awk '{print $1}')"
fi

OPEN=(open -n "$APP_BUNDLE" --env FLEET_PREVIEW=1)
if [ -n "$VERSION" ]; then
  OPEN+=(--env "FLEET_PREVIEW_CLAUDE_VERSION=$VERSION")
fi
"${OPEN[@]}"

echo
echo "Fleet preview is open. The window is UI only: no daemon and no agent processes."
echo "The sidebar is filled with Claude Code sessions. The terminal is the Claude Code screen."
if [ -n "$VERSION" ]; then
  echo "Claude Code version on this Mac: $VERSION"
fi
echo "Quit this window when you are done. Other Fleet windows and live sessions are left running."
