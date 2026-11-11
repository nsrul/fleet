# Development scripts

Convenience scripts for building, running, testing, and verifying Fleet.
Run them from anywhere; each resolves the repository root itself.

| Script | What it does |
| --- | --- |
| `scripts/dev.sh` | Builds the daemon and app once, then launches Fleet. |
| `scripts/watch.sh` | Rebuilds and relaunches Fleet when macOS sources change. |
| `scripts/build.sh` | Builds `fleet-daemon` and the macOS app. |
| `scripts/install.sh` | Builds a release from this checkout, quits Fleet, stops `fleet-daemon`, removes older installs, and installs `Fleet.app` and `fleet-daemon`. |
| `scripts/run.sh` | Builds if needed, starts a daemon when necessary, and opens Fleet. |
| `scripts/demo.sh` | Opens Fleet with two live agent sessions. |
| `scripts/preview.sh` | Opens a UI-only Fleet window for screenshots, with Claude Code sessions and no daemon. |
| `scripts/test.sh` | Runs the Rust workspace tests and the `FleetKit` tests. |
| `scripts/verify.sh` | Runs formatting, Clippy, tests, protocol smoke checks, and the app build. |
| `scripts/clean.sh` | Removes Rust and macOS build artifacts. Keeps the generated Xcode project. |
| `scripts/release.sh` | Builds a Release `Fleet.app` with the release daemon, signs it, and writes a zip and a dmg under `dist/`. |

The macOS-specific implementations live in `apps/macos/scripts/`. The root
scripts are stable entry points so the commands do not change if the app layout
does.

## Common flows

First-time build and run:

```sh
scripts/dev.sh
```

Live UI reload while editing the app:

```sh
scripts/watch.sh
```

`watch.sh` builds and launches once, then rebuilds and relaunches on every save
under `apps/macos/Fleet`, `apps/macos/FleetKit`, and `apps/macos/project.yml`.
It uses `watchexec` when installed (`brew install watchexec`) and otherwise
falls back to polling every second. The daemon is left running, so sessions and
their agents stay alive across a reload; only the window is replaced, so pane
scroll position and selection reset. A failed build leaves the previous app
running and the watcher keeps going, so fixing the error is enough to reload.

Two live panes with installed agent CLIs:

```sh
scripts/demo.sh
```

A screenshot window filled with Claude Code sessions. It does not start the daemon:

```sh
scripts/preview.sh
```

Before opening a pull request:

```sh
scripts/verify.sh
```

`verify.sh` needs Xcode, a Rust toolchain, and the agent CLIs only for the
optional manual checklist printed by `apps/macos/scripts/verify-terminal.sh`.
The automated checks use `/bin/sh` and do not need agent credentials.

GitHub Actions runs formatting, Clippy, and the Rust workspace tests on Linux,
and `scripts/verify.sh` on macOS. The workflow is
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml). Set
`FLEET_CI_LOG_DIR` to keep the smoke-test daemon log after `verify-terminal.sh`
exits.

Release build:

```sh
scripts/release.sh
scripts/release.sh --sign "Developer ID Application: Name (TEAMID)"
```

The version, signing choice, checks, and archive layout are in
[`docs/RELEASE.md`](../docs/RELEASE.md).

## Environment

- `FLEET_SOCKET` overrides the daemon socket (default
  `~/.fleet/daemon.sock`).
- `FLEET_WORKDIR` sets the default working directory for new sessions.
- `FLEET_DAEMON` points at a specific `fleet-daemon` binary.
- `FLEET_INSTALL_DIR` is where `scripts/install.sh` puts `Fleet.app` (default
  `~/Applications`).
- `FLEET_DAEMON_DIR` is where `scripts/install.sh` puts `fleet-daemon` (default
  `~/.fleet/bin`).
- `TMPDIR` controls where run logs and PID files are written.
