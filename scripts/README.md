# Development scripts

Convenience scripts for building, running, testing, and verifying Director.
Run them from anywhere; each resolves the repository root itself.

| Script | What it does |
| --- | --- |
| `scripts/dev.sh` | Builds the daemon and app once, then launches Director. |
| `scripts/build.sh` | Builds `director-daemon` and the macOS app. |
| `scripts/run.sh` | Builds if needed, starts a daemon when necessary, and opens Director. |
| `scripts/demo.sh` | Opens Director with two live agent sessions. |
| `scripts/test.sh` | Runs the Rust workspace tests and the `DirectorKit` tests. |
| `scripts/verify.sh` | Runs formatting, Clippy, tests, protocol smoke checks, and the app build. |
| `scripts/clean.sh` | Removes Rust and macOS build artifacts. Keeps the generated Xcode project. |

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

## Environment

- `DIRECTOR_SOCKET` overrides the daemon socket (default
  `~/.director/daemon.sock`).
- `DIRECTOR_WORKDIR` sets the default working directory for new sessions.
- `DIRECTOR_DAEMON` points at a specific `director-daemon` binary.
- `TMPDIR` controls where run logs and PID files are written.
