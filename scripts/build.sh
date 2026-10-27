#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Building director-daemon and Director.app"
"$ROOT/apps/macos/scripts/build.sh"
