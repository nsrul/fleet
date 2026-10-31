#!/usr/bin/env bash
# Build a release Fleet.app, optionally Developer ID-sign it, and zip it.
# Entry point: scripts/release.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$APP_DIR/../.." && pwd)"
DIST="$ROOT/dist"
SIGN_IDENTITY="-"

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [--sign IDENTITY]

Build the release fleet-daemon and Fleet.app, sign the bundle, and write
dist/Fleet-<version>-macos-<arch>.zip.

  --sign IDENTITY   Codesign with this identity. Use the full certificate name:
                      --sign "Developer ID Application: Name (TEAMID)"
                    "-" signs ad-hoc, which is also the default.

Without --sign the app is ad-hoc signed so it runs on this Mac. A Developer ID
signature is not notarized; Gatekeeper still blocks that zip on other Macs
until it is notarized.

The version is read from the Cargo workspace and MARKETING_VERSION. They must
match.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sign)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "error: --sign requires an identity" >&2
        usage >&2
        exit 1
      fi
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$(uname)" != "Darwin" ]; then
  echo "error: this release script must run on macOS." >&2
  exit 1
fi

for tool in cargo xcodebuild codesign ditto file lipo shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required." >&2
    exit 1
  fi
done

workspace_version() {
  awk '
    $0 ~ /^\[workspace\.package\]/ { in_pkg = 1; next }
    $0 ~ /^\[/ { in_pkg = 0 }
    in_pkg && $0 ~ /^version = / {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "$ROOT/Cargo.toml"
}

marketing_version() {
  awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' "$APP_DIR/project.yml"
}

VERSION="$(workspace_version)"
MARKETING="$(marketing_version)"
if [ -z "$VERSION" ] || [ -z "$MARKETING" ]; then
  echo "error: could not read the workspace version or MARKETING_VERSION." >&2
  exit 1
fi
if [ "$VERSION" != "$MARKETING" ]; then
  echo "error: Cargo version $VERSION does not match MARKETING_VERSION $MARKETING." >&2
  exit 1
fi

if [ "$SIGN_IDENTITY" != "-" ]; then
  listed="$(security find-identity -v -p codesigning)" || {
    echo "error: could not list code-signing identities." >&2
    exit 1
  }
  names="$(printf '%s\n' "$listed" | sed -n 's/.*"\(.*\)"$/\1/p')"
  if ! printf '%s\n' "$names" | grep -Fxq "$SIGN_IDENTITY"; then
    echo "error: no code-signing identity named: $SIGN_IDENTITY" >&2
    echo "Available identities:" >&2
    printf '%s\n' "$listed" >&2
    exit 1
  fi
fi

cd "$ROOT"

echo "==> Building release fleet-daemon $VERSION"
cargo build -p fleet-daemon --release --locked

DAEMON="$ROOT/target/release/fleet-daemon"
if [ ! -x "$DAEMON" ]; then
  echo "error: release fleet-daemon was not produced." >&2
  exit 1
fi

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$APP_DIR" && xcodegen generate)
else
  echo "warning: xcodegen is not installed; using the checked-in Xcode project." >&2
  echo "         Install it with: brew install xcodegen" >&2
fi

echo
echo "==> Building Release Fleet.app"
# Sign after the bundled daemon is copied so the identity covers the helper.
xcodebuild \
  -project "$APP_DIR/Fleet.xcodeproj" \
  -scheme Fleet \
  -configuration Release \
  -derivedDataPath "$APP_DIR/.build" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

APP="$APP_DIR/.build/Build/Products/Release/Fleet.app"
BUNDLED="$APP/Contents/Resources/fleet-daemon"
if [ ! -d "$APP" ] || [ ! -x "$APP/Contents/MacOS/Fleet" ]; then
  echo "error: Release Fleet.app was not produced." >&2
  exit 1
fi
if [ ! -x "$BUNDLED" ]; then
  echo "error: Fleet.app does not contain fleet-daemon." >&2
  exit 1
fi
if ! cmp -s "$DAEMON" "$BUNDLED"; then
  echo "error: the bundled fleet-daemon is not the release binary." >&2
  exit 1
fi

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
  echo "error: built app version is $BUILT_VERSION, expected $VERSION." >&2
  exit 1
fi

is_macho() {
  file -b "$1" | grep -q 'Mach-O'
}

sign_path() {
  local target="$1"
  echo "==> Signing $(basename "$target")"
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$target"
  else
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$target"
  fi
}

echo
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "==> Ad-hoc signing Fleet.app"
else
  echo "==> Signing Fleet.app with: $SIGN_IDENTITY"
fi

# Inside out: nested Mach-O files, then framework bundles, then the app seal.
if [ -d "$APP/Contents/Frameworks" ]; then
  while IFS= read -r -d '' path; do
    if is_macho "$path"; then
      sign_path "$path"
    fi
  done < <(find "$APP/Contents/Frameworks" -type f -print0)
  while IFS= read -r -d '' path; do
    sign_path "$path"
  done < <(find "$APP/Contents/Frameworks" -depth -type d -name '*.framework' -print0)
fi

while IFS= read -r -d '' path; do
  if [ "$path" = "$APP/Contents/MacOS/Fleet" ]; then
    continue
  fi
  if is_macho "$path"; then
    sign_path "$path"
  fi
done < <(find "$APP/Contents/Resources" "$APP/Contents/MacOS" -type f -print0)

sign_path "$APP"

echo
echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$BUNDLED"
codesign --verify --strict --verbose=2 "$APP"

ARCH="$(lipo -archs "$APP/Contents/MacOS/Fleet" | tr ' ' '-')"
ZIP="$DIST/Fleet-${VERSION}-macos-${ARCH}.zip"
mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256"

echo
echo "==> Packaging $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(
  cd "$DIST"
  shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256"
)

echo
echo "Release $VERSION"
echo "App:      $APP"
echo "Archive:  $ZIP"
echo "Checksum: $ZIP.sha256"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "Signature: ad-hoc"
else
  echo "Signature: $SIGN_IDENTITY"
  echo "This archive is signed and not notarized."
fi
