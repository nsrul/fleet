# Fleet

Fleet is a macOS app for running installed coding-agent CLIs in one window. A Rust daemon owns each process and its PTY. The app attaches as a client, so closing the window leaves those sessions running.

## Product

Presets launch Claude Code (`claude`), Codex (`codex`), Cursor Agent (`cursor-agent`), Gemini CLI (`gemini`), OpenCode (`opencode`), a login shell, or a custom command. Each agent keeps its own credentials and talks to its model provider directly.

The sidebar lists every session and can show two of them as terminal panes. Each session has its own working directory. The daemon reports a session as running or exited. The sidebar filters are local UI state:

- Running: the process is alive and produced output in the last few seconds.
- Idle: the process is alive but quiet, or it exited successfully.
- Needs you: the terminal bell rang, until the pane is focused or the user types, or the process exited with a failure.

## Stack

The app targets macOS 14 and later. The interface is SwiftUI. Each terminal is an AppKit view (`NSViewRepresentable`) around SwiftTerm 1.99.1, which owns emulation, scrollback, selection, and keyboard input. The daemon forwards raw PTY bytes.

Rust crates:

- `crates/engine` (`fleet-engine`): session lifecycle and PTYs. No sockets and no signal handling.
- `crates/protocol` (`fleet-protocol`): shared API types. The engine does not depend on this crate.
- `crates/daemon` (`fleet-daemon`): Tokio runtime, Unix-socket API, and shutdown.

The Mac client is Swift, in `apps/macos/FleetKit` (`FleetAPI`). The socket protocol is version 1. Session state is memory-only and disappears when the daemon stops. A Windows build of the daemon starts without that API.

## Where to change things

- App UI: `apps/macos/Fleet`. The Xcode project is generated from `apps/macos/project.yml` and checked in.
- Terminal hosting: `apps/macos/Fleet/Terminal`.
- Local API client: `apps/macos/FleetKit`.
- Process ownership and the wire protocol: the Rust crates. Read `ARCHITECTURE.md` first.
- Frontend decision: `docs/decisions/0001-MACOS-FRONTEND.md`.

Root `scripts/` are the entry points (`dev.sh`, `watch.sh`, `build.sh`, `test.sh`, `verify.sh`). Their macOS implementations live in `apps/macos/scripts/`.
