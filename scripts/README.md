# Development scripts

Convenience scripts for building, running, testing, and verifying Fleet.
Run them from anywhere; each resolves the repository root itself.

| Script | What it does |
| --- | --- |
| `scripts/dev.sh` | Builds the daemon and app once, then launches Fleet. |
| `scripts/build.sh` | Builds `fleet-daemon` and the macOS app. |
| `scripts/install.sh` | Builds a release from this checkout, quits Fleet, stops `fleet-daemon`, removes older installs, and installs `Fleet.app` and `fleet-daemon`. |
| `scripts/run.sh` | Builds if needed, starts a daemon when necessary, and opens Fleet. |
| `scripts/demo.sh` | Opens Fleet with two live agent sessions. |
| `scripts/test.sh` | Runs the Rust workspace tests and the `FleetKit` tests. |
| `scripts/verify.sh` | Runs formatting, Clippy, tests, protocol smoke checks, and the app build. |
| `scripts/clean.sh` | Removes Rust and macOS build artifacts. Keeps the generated Xcode project. |
| `scripts/release.sh` | Builds a Release `Fleet.app` with the release daemon, signs it, and zips it under `dist/`. |

The macOS-specific implementations live in `apps/macos/scripts/`. The root
scripts are stable entry points so the commands do not change if the app layout
does.

## Common flows

First-time build and run:

```sh
scripts/dev.sh
```

Two live panes with installed agent CLIs:

```sh
scripts/demo.sh
```

Before opening a pull request:

```sh
scripts/verify.sh
```

`verify.sh` needs Xcode, a Rust toolchain, and the agent CLIs only for the
optional manual checklist printed by `apps/macos/scripts/verify-terminal.sh`.
The automated checks use `/bin/sh` and do not need agent credentials.

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
