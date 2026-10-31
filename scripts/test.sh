#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Rust workspace tests"
cargo test --workspace --locked

echo
echo "==> FleetKit tests"
(cd "$ROOT/apps/macos/FleetKit" && swift test)
