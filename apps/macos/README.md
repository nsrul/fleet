# Fleet for macOS

A SwiftUI prototype of the Fleet desktop workspace. It shows one project with
two live terminal panes, backed by the Rust `fleet-daemon` through the
versioned local API. The visual design follows the
[Figma file](https://www.figma.com/design/QSQKCfkfjButfQp2irkhB9/director.?node-id=11-2).

This is issue #4's two-pane prototype, not a finished app.

## Target platform

- macOS 14 (Sonoma) or newer; built and verified on macOS 27.
- Apple Silicon (`arm64`). The project has no Intel-specific code, but Intel and
  older macOS versions were not tested.
- Xcode 16 or newer with Swift 6. The prototype was built with Xcode 27.1 /
  Swift 6.4 in Swift 6 language mode with complete concurrency checking.
- Rust toolchain for `fleet-daemon` (edition 2024, Rust 1.85+).
- XcodeGen is optional. The generated `Fleet.xcodeproj` is checked in; install
  XcodeGen (`brew install xcodegen`) only if you change `project.yml`.

The app is ad-hoc signed and not sandboxed. It is a local development build, not
a distributable application.

## Terminal rendering

Terminal emulation is provided by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
1.99.1 (MIT), pinned in `project.yml`. `TerminalHostView` wraps SwiftTerm's
`TerminalView` in an `NSViewRepresentable`; `TerminalController` owns the view,
the delegate, focus, clipboard, and resize plumbing.

The daemon sends raw PTY bytes and the app feeds them to SwiftTerm, so the
frontend owns terminal emulation, scrollback, selection, keyboard handling, and
Unicode rendering. The daemon does not interpret escape sequences. SwiftTerm
reports its grid size after layout; the app sends that size through the
`resize` API, and the PTY and agent TUI reflow.

Because the daemon keeps only a bounded raw output backlog and has no terminal
state snapshot yet, attaching to an existing session replays bytes and lets
SwiftTerm rebuild as much of the screen as the retained output allows. Accurate
terminal-state snapshots and ordered replay remain issue #5 work.

The app targets AppKit through SwiftUI on macOS. It does not use SwiftTerm's
iOS terminal view or a web terminal emulator.

## Build and run

From the repository root:

```sh
apps/macos/scripts/build.sh
apps/macos/scripts/run.sh
```

`build.sh` builds the Rust daemon, regenerates the Xcode project when XcodeGen
is installed, and builds `Fleet.app` into `apps/macos/.build`. `run.sh`
starts a daemon on `~/.fleet/daemon.sock` if one is not already listening,
then opens the app.

While editing the interface, `scripts/watch.sh` does the same pair on every
save and relaunches the app, which is the closest thing to live reload this
project has. See [`scripts/README.md`](../../scripts/README.md).

To build manually:

```sh
cargo build -p fleet-daemon --locked
cd apps/macos
xcodebuild \
  -project Fleet.xcodeproj \
  -scheme Fleet \
  -configuration Debug \
  -derivedDataPath .build \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build \
  CODE_SIGNING_ALLOWED=NO
open .build/Build/Products/Debug/Fleet.app
```

The `-skipPackagePluginValidation` and `-skipMacroValidation` flags avoid
interactive prompts for SwiftTerm's build-tool plugin in local builds.

### Daemon and environment

The app connects to `~/.fleet/daemon.sock` by default. `FLEET_SOCKET`
overrides the path. If nothing is listening and auto-start is enabled, the app
looks for `fleet-daemon` in this order: `FLEET_DAEMON`, the app bundle's
resources, `target/debug`, `target/release`, `~/.fleet/bin`, Homebrew paths,
and `PATH`. Daemon logs go to `~/Library/Logs/Fleet/daemon.log`.

New sessions use the selected working directory. `FLEET_WORKDIR` supplies the
default when the app starts. The agent picker offers installed CLIs from
`AgentCatalog` plus a custom command.

## Demo with two live panes

```sh
apps/macos/scripts/demo.sh
```

The script builds the app, starts a daemon if needed, creates two sessions with
the same working directory, and opens Fleet. It prefers Claude Code and
Codex, falls back to Claude Code and Gemini CLI, and finally to two shells. The
session IDs are `demo-claude` / `demo-codex` or `demo-claude` / `demo-gemini`
(or `demo-shell-1` / `demo-shell-2`). Existing demo sessions are stopped first.

Each pane has its own tabs. Drag a tab to an edge of the workspace to split
side by side or stacked. The daemon keeps that arrangement, so quitting the
app and opening it again restores the tabs and replays each session. Settings
chooses the direction used by Split Pane.

## Screenshot preview

```sh
scripts/preview.sh
```

`FLEET_PREVIEW=1` fills the window with Claude Code sessions and paints the
Claude Code screen in the terminal. The daemon is not started, and a Fleet
window that is already open is left alone.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Cmd+T` / `Cmd+N` | New agent sheet, opened in the focused pane |
| `Cmd+W` | Close the active tab. The session keeps running |
| `Cmd+Shift+W` | Close the window |
| `Cmd+1` through `Cmd+9` | Select that tab in the focused pane |
| `Control+Tab` / `Control+Shift+Tab` | Next or previous tab |
| `Cmd+Option+Right` / `Left` | Move focus between panes |
| `Cmd+Shift+\` | Split the focused pane and pick the other session |
| `Cmd+K` | Clear the focused terminal |
| `Cmd+0` | Show or hide the context panel |
| `Cmd+Shift+R` | Refresh git status |
| `Cmd+,` | Settings |
| `Cmd+A`, `Cmd+C`, `Cmd+V` | Select all, copy, paste in the focused terminal |

## Verification

```sh
apps/macos/scripts/verify-terminal.sh
```

The script runs the `FleetKit` unit tests, starts a real daemon on a temporary
socket, and runs `FleetProbe --smoke`. The smoke test checks create, input,
output, Unicode (`café 日本語`), resize, and exit. It then prints the manual UI
checklist.

The prototype was exercised in the running app with Claude Code 2.1.311 and
Gemini CLI 0.46.0 on macOS 27:

| Check | Result |
| --- | --- |
| Two panes attach to two independent live sessions | Pass |
| Keyboard input reaches the focused agent composer | Pass |
| Unicode `café 日本語` renders without replacement glyphs | Pass |
| `Cmd+A` / `Cmd+C` copies terminal text to the system clipboard | Pass |
| Scrollback moves through retained output | Pass |
| Window resize changes the PTY grid (83×20 → 51×18) and reflows both TUIs | Pass |
| `Cmd+1` / `Cmd+2` switches focus between panes | Pass |
| Quit and relaunch reattaches to still-running agents | Pass |

Wheel scrolling is captured by full-screen agent TUIs while their mouse
reporting is enabled, which is normal terminal behavior. Use the agent's own
scroll keys or `Page Up` / `Page Down` in that state.

## What the prototype includes

- 256 pt sidebar with project header, filters, session rows, context menus, and
  a daemon status footer.
- Tabbed panes, side-by-side or stacked, with session titles, focus, and status.
- Context panel that follows the focused agent's working tree, shows the diff
  for the file the agent just changed, and can open a shell for Helix.
- New-agent sheet with agent presets, working directory, and optional name.
- Settings for appearance, terminal font, cursor, spacing, and scrollback,
  the keyboard-split direction, stop confirmation, the new-agent folder, the socket path,
  and daemon auto-start.
- Reconnect flow and an empty state when the daemon is unavailable.

## Agent integration

Claude Code, Codex, Gemini CLI, and OpenCode sessions receive the app's
`orchestrate`, `watch`, and `plan` MCP tools through a loopback server. The
wiring is process-scoped: Fleet does not edit the user's own agent
configuration. The per-agent transport, the steps for adding another CLI, and
the verification checklist are in
[`docs/AGENT_INTEGRATION.md`](../../docs/AGENT_INTEGRATION.md).

## Known limitations

- One project at a time; no project switching or worktree management.
- No persistence. Sessions live only as long as the daemon process, and the
  daemon currently keeps a bounded raw output backlog rather than terminal state.
- No session-list-changed event. Sessions created by another client appear only
  after reconnecting or relaunching.
- Fork starts a new process with the same program, arguments, environment,
  working directory, and terminal size; it does not fork the agent's
  conversation.
- The context panel reads git status and file diffs for the selected session's
  working directory. It does not stage or commit.
- "Running" is derived from session status. "Needs you" is not implemented, so
  the sidebar labels its filters "All agents" and "Running".
- The app is not sandboxed and has no notarization or macOS CI job.
  [`docs/RELEASE.md`](../../docs/RELEASE.md) is the procedure for the signed
  release zip produced by `scripts/release.sh`.

## Source layout

```text
apps/macos/
  Fleet/                 SwiftUI app
    App/AppModel.swift      connection, sessions, attach/input/resize, git state
    Terminal/               SwiftTerm bridge, controller, delegate
    UI/                     sidebar, panes, context panel, sheets, theme
    Services/               agent catalog, daemon launcher, git reader
    Resources/              app icon
  FleetKit/              local Swift package
    Sources/FleetAPI/    local API client and protocol types
    Sources/FleetProbe/  CLI smoke test and session helper
    Tests/FleetAPITests/ unit tests
  scripts/                  build, run, demo, verify, release
  project.yml               XcodeGen source of truth
```

The frontend decision is recorded in
[`docs/decisions/0001-MACOS-FRONTEND.md`](../../docs/decisions/0001-MACOS-FRONTEND.md).
