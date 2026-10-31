# Releasing Fleet for macOS

A release is a versioned zip of `Fleet.app` with the matching release
`fleet-daemon` inside it. `scripts/release.sh` builds, checks the version,
signs, and packages. It does not tag a commit, open a GitHub release,
notarize, or install the app. Those publish steps are separate and are
written below.

The current release is **0.1.0**. The GitHub tag and the release title are
both `0.1.0`. That archive is ad-hoc signed.

Run the script on the Mac that will sign the build. The root script resolves
the repository and runs `apps/macos/scripts/release.sh`.

## Version

Two strings must be the same before the script will build:

| Source | Field | What it becomes |
| --- | --- | --- |
| `Cargo.toml` | `[workspace.package]` `version` | Daemon version (`CARGO_PKG_VERSION`) |
| `apps/macos/project.yml` | `MARKETING_VERSION` | `CFBundleShortVersionString` |

`apps/macos/Fleet/Info.plist` reads the marketing version from the Xcode
project. Crate manifests use `version.workspace = true`, so the workspace
field is the only daemon version to edit.

`CURRENT_PROJECT_VERSION` in `project.yml` is the build number shown in
Settings as `0.1.0 (1)`. Leave it at `1` for the first 0.1.0 archive. Bump it
when you ship again without changing the marketing version.

For a later release, change the workspace version and `MARKETING_VERSION`
together, then run the script. Do not edit `Fleet.xcodeproj/project.pbxproj`
by hand. When XcodeGen is installed, the script regenerates the project from
`project.yml`.

The script stops if either string is missing, if the two strings differ, or
if the built app's short version does not match.

## Before the build

You need macOS, Xcode 16 or newer (`xcodebuild`), a Rust toolchain (`cargo`),
and the system tools `codesign`, `ditto`, `file`, `lipo`, and `shasum`.
XcodeGen is optional (`brew install xcodegen`). Install it when `project.yml`
has changed and the checked-in project should be regenerated.

From the repository root:

```sh
scripts/verify.sh
```

`verify.sh` runs formatting, Clippy, tests, protocol checks, and a Debug app
build. Release packaging starts after that passes.

The release script does not quit a running Fleet. Debug and Release builds
share the bundle id `dev.fleet.macos`, so macOS will not launch a second copy
beside one that is already open. Quit Fleet before you open the release app,
and only when its agent sessions can stop.

`dist/` is gitignored. `scripts/clean.sh` deletes it along with the other
build products.

## Choose a signature

List the identities in the login keychain:

```sh
security find-identity -v -p codesigning
```

Use a line that starts with `Developer ID Application:`. An Apple Development
certificate signs a local build; it does not identify a copy you hand to
someone else.

### This Mac only

```sh
scripts/release.sh
```

The same ad-hoc signature is `--sign "-"`. The zip runs on the machine that
built it. Gatekeeper will not accept it as a Developer ID app. The 0.1.0
GitHub release uses this ad-hoc command. Publishing that zip is in
[Publish the ad-hoc archive](#publish-the-ad-hoc-archive).

### A specific Developer ID

Pass the full certificate name, including the team id in parentheses:

```sh
scripts/release.sh --sign "Developer ID Application: Name (TEAMID)"
```

The name must match one identity exactly. If it does not, the script prints
the keychain list and stops before building. `codesign` may prompt to use the
private key. Timestamping contacts Apple, so this step needs network.

A Developer ID signature uses the hardened runtime. The script still does not
notarize. Gatekeeper blocks that zip on another Mac until the archive is
notarized and stapled.

`--help` prints the same contract:

```sh
scripts/release.sh --help
```

## What the script does

1. Require macOS and the tools listed above.
2. Read the workspace version and `MARKETING_VERSION`, and require them to match.
3. When `--sign` is not `-`, require that identity in the keychain.
4. Build `target/release/fleet-daemon` with `cargo build -p fleet-daemon --release --locked`.
5. Regenerate the Xcode project when `xcodegen` is on `PATH`.
6. Build the Release configuration into `apps/macos/.build` with code signing turned off. `ARCHS` is the daemon binary's architecture (`lipo -archs`), and `ONLY_ACTIVE_ARCH` is `YES`. Cargo builds `fleet-daemon` for the host, which on this Mac is `arm64`. Xcode's default Release build is universal (`x86_64` and `arm64`); that Intel slice was not tested and would not match the daemon. The Copy fleet-daemon build phase then puts `target/release/fleet-daemon` in the bundle before anything is signed.
7. Require `Fleet.app` and `Contents/Resources/fleet-daemon`. Require the bundled daemon to be byte-identical to `target/release/fleet-daemon`. Require the built short version to match the workspace version.
8. Sign inside out. Nested Mach-O files under `Contents/Frameworks` are signed first, then each `.framework` bundle, then other nested Mach-O files (including `Contents/Resources/fleet-daemon`), then `Fleet.app`. The main executable is sealed with the app bundle.
9. Ad-hoc signing uses `codesign --sign -`. A Developer ID uses `--timestamp --options runtime` and that identity.
10. Run `codesign --verify --strict` on the bundled daemon and on the app.
11. Name the zip from the version and the architectures reported by `lipo -archs` on the built app. With the architecture pin above, the 0.1.0 Apple Silicon archive is `dist/Fleet-0.1.0-macos-arm64.zip`. Write a SHA-256 checksum beside it.

The built app remains at:

```text
apps/macos/.build/Build/Products/Release/Fleet.app
```

## Check the archive

Replace the filename if `lipo` reported a different architecture.

```sh
cd dist
shasum -a 256 -c Fleet-0.1.0-macos-arm64.zip.sha256
cd ..

rm -rf /tmp/fleet-release
mkdir -p /tmp/fleet-release
ditto -x -k dist/Fleet-0.1.0-macos-arm64.zip /tmp/fleet-release

codesign --verify --strict --verbose=2 /tmp/fleet-release/Fleet.app
codesign --verify --strict --verbose=2 /tmp/fleet-release/Fleet.app/Contents/Resources/fleet-daemon
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /tmp/fleet-release/Fleet.app/Contents/Info.plist
lipo -archs /tmp/fleet-release/Fleet.app/Contents/MacOS/Fleet
lipo -archs /tmp/fleet-release/Fleet.app/Contents/Resources/fleet-daemon
```

`CFBundleShortVersionString` must print `0.1.0`. Both `lipo` lines must be the same architecture. For 0.1.0 that is `arm64`.

Do not `cmp` the expanded daemon to `target/release/fleet-daemon`. The script does that before signing. `codesign` then writes the signature into the bundled daemon, so the bytes differ.

To see which identity signed a Developer ID build:

```sh
codesign -dv --verbose=4 /tmp/fleet-release/Fleet.app 2>&1 | grep '^Authority='
```

An ad-hoc build has `Signature=adhoc` and no `Authority` line.

Expand with `ditto`, not `unzip`, so the code signature is preserved. After
the checks above, and after quitting any running Fleet, open the expanded app:

```sh
open /tmp/fleet-release/Fleet.app
```

The release script does not copy the app to `~/Applications` or install
`fleet-daemon` on `PATH`. The running app uses the daemon in its own
`Contents/Resources`.

## Land the change

Release tooling and this document go through a pull request. Do not commit
them on `main`. Cut the branch from `origin/main`:

```sh
git fetch origin
git switch -c feat/macos-release-0.1.0 origin/main
```

Commit the script, this document, and the links that name them. Leave `dist/`
untracked. Leave an unrelated `Cargo.lock` diff out of the commit. The commit
title is a conventional commit. The pull request body has `## Summary` and
`## Test plan`.

```sh
git push -u origin HEAD
gh pr create --title "feat(macos): add the 0.1.0 release" --body-file /tmp/fleet-pr.md
```

Build the archive from that same commit. If a later commit changes the script
or the version, rebuild before tagging. The tag is not moved after the GitHub
release exists.

## Publish the ad-hoc archive

Do this on the commit you will tag, after `scripts/verify.sh` has passed.
`verify.sh` is the Debug check. The release build is separate.

```sh
scripts/verify.sh
scripts/release.sh
```

Run the [archive checks](#check-the-archive). Then confirm the signature is
ad hoc:

```sh
codesign -dv --verbose=4 /tmp/fleet-release/Fleet.app 2>&1 | grep '^Signature='
```

The line must be `Signature=adhoc`. There must be no `Authority=` line.

Create the GitHub release from that commit. The tag and the title are
`0.1.0`. `--target` is the full SHA of the commit you built. Without
`--target`, `gh` tags the latest commit on `main`, which is the wrong commit
while this change is still only on the pull request branch.

Write the notes to a file and pass them with `--notes-file`. For 0.1.0 the
notes are:

```text
Fleet 0.1.0 for macOS.

The archive is ad-hoc signed on Apple Silicon (arm64). It is not notarized.
Gatekeeper rejects the app after download. Expand it with ditto so the
signature stays intact. Fleet requires macOS 14 or newer and bundles the
matching release fleet-daemon.

shasum -a 256 -c Fleet-0.1.0-macos-arm64.zip.sha256
ditto -x -k Fleet-0.1.0-macos-arm64.zip .
codesign --verify --strict --verbose=2 Fleet.app
```

Upload the zip path the script prints, and the `.sha256` file beside it. For
this 0.1.0 Apple Silicon build those are `dist/Fleet-0.1.0-macos-arm64.zip`
and `dist/Fleet-0.1.0-macos-arm64.zip.sha256`.

```sh
gh release create 0.1.0 \
  dist/Fleet-0.1.0-macos-arm64.zip \
  dist/Fleet-0.1.0-macos-arm64.zip.sha256 \
  --target "<full SHA of the built commit>" \
  --title "0.1.0" \
  --notes-file /tmp/fleet-0.1.0-notes.md
```

The release is then at
<https://github.com/nsrul/fleet/releases/tag/0.1.0>.

Fetch the tag afterward:

```sh
git fetch --tags origin
```

A download from GitHub is quarantined. This ad-hoc archive will not open
through a normal double-click on another Mac. Notarization is still required
before that.

## Out of scope

- Notarization (`notarytool`, stapling) and App Store submission.
- A universal binary. The zip contains the architecture of the machine that ran the script.
- Sandbox entitlements. The app remains unsandboxed, matching `project.yml`.

