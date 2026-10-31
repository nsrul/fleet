#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Removing Rust build artifacts"
if command -v cargo >/dev/null 2>&1; then
  (cd "$ROOT" && cargo clean)
else
  rm -rf "$ROOT/target"
fi

echo "==> Removing macOS build artifacts"
rm -rf "$ROOT/apps/macos/.build"
rm -rf "$ROOT/apps/macos/FleetKit/.build"
rm -rf "$ROOT/apps/macos/Fleet.xcodeproj/project.xcworkspace/xcuserdata"
rm -rf "$ROOT/apps/macos/Fleet.xcodeproj/xcuserdata"

echo "Done. The generated Xcode project and Package.resolved were kept."
