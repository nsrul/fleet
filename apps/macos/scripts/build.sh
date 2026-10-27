#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$APP_DIR/../.." && pwd)"

cd "$ROOT"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is required. Install Xcode 16 or newer." >&2
  exit 1
fi

cargo build -p director-daemon --locked

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$APP_DIR" && xcodegen generate)
else
  echo "warning: xcodegen is not installed; using the checked-in Xcode project." >&2
  echo "         Install it with: brew install xcodegen" >&2
fi

# SwiftTerm ships a build-tool plugin that Xcode asks to validate on first use.
# The prototype is ad-hoc signed; skip validation for local, non-distributed builds.
xcodebuild \
  -project "$APP_DIR/Director.xcodeproj" \
  -scheme Director \
  -configuration Debug \
  -derivedDataPath "$APP_DIR/.build" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build \
  CODE_SIGNING_ALLOWED=NO

echo
echo "Built: $APP_DIR/.build/Build/Products/Debug/Director.app"
