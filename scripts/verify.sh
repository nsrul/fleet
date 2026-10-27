#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Rust formatting"
cargo fmt --all -- --check

echo
echo "==> Rust clippy"
cargo clippy --workspace --all-targets --locked -- -D warnings

echo
echo "==> Rust workspace tests"
cargo test --workspace --locked

echo
echo "==> Cargo metadata"
cargo metadata --no-deps --format-version 1 --locked

echo
echo "==> macOS protocol, terminal, and app checks"
"$ROOT/apps/macos/scripts/verify-terminal.sh"

echo
echo "==> macOS app build"
"$ROOT/apps/macos/scripts/build.sh"
