#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Build once, then launch the app without rebuilding.
"$ROOT/scripts/build.sh"
exec "$ROOT/apps/macos/scripts/run.sh" --no-build
