# Director for macOS

A SwiftUI prototype of the Director desktop workspace. It shows one project with
two live terminal panes, backed by the Rust `director-daemon` through the
versioned local API. The visual design follows the
[Director Figma file](https://www.figma.com/design/QSQKCfkfjButfQp2irkhB9/director.?node-id=11-2).

This is issue #4's two-pane prototype, not a finished app.

## Target platform

- macOS 14 (Sonoma) or newer; built and verified on macOS 27.
- Apple Silicon (`arm64`). The project has no Intel-specific code, but Intel and
  older macOS versions were not tested.
- Xcode 16 or newer with Swift 6. The prototype was built with Xcode 27.1 /
  Swift 6.4 in Swift 6 language mode with complete concurrency checking.
- Rust toolchain for `director-daemon` (edition 2024, Rust 1.85+).
- XcodeGen is optional. The generated `Director.xcodeproj` is checked in; install
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
is installed, and builds `Director.app` into `apps/macos/.build`. `run.sh`
starts a daemon on `~/.director/daemon.sock` if one is not already listening,
then opens the app.

To build manually:

```sh
cargo build -p director-daemon --locked
cd apps/macos
xcodebuild \
  -project Director.xcodeproj \
  -scheme Director \
  -configuration Debug \
  -derivedDataPath .build \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build \
  CODE_SIGNING_ALLOWED=NO
open .build/Build/Products/Debug/Director.app
```

The `-skipPackagePluginValidation` and `-skipMacroValidation` flags avoid
interactive prompts for SwiftTerm's build-tool plugin in local builds.

### Daemon and environment

The app connects to `~/.director/daemon.sock` by default. `DIRECTOR_SOCKET`
overrides the path. If nothing is listening and auto-start is enabled, the app
looks for `director-daemon` in this order: `DIRECTOR_DAEMON`, the app bundle's
resources, `target/debug`, `target/release`, `~/.director/bin`, Homebrew paths,
and `PATH`. Daemon logs go to `~/Library/Logs/Director/daemon.log`.

New sessions use the selected working directory. `DIRECTOR_WORKDIR` supplies the
default when the app starts. The agent picker offers installed CLIs from
`AgentCatalog` plus a custom command.

## Demo with two live panes

```sh
apps/macos/scripts/demo.sh
```

The script builds the app, starts a daemon if needed, creates two sessions with
the same working directory, and opens Director. It prefers Claude Code and
Codex, falls back to Claude Code and Gemini CLI, and finally to two shells. The
session IDs are `demo-claude` / `demo-codex` or `demo-claude` / `demo-gemini`
(or `demo-shell-1` / `demo-shell-2`). Existing demo sessions are stopped first.

The layout defaults to stacked panes. Use the layout control in the toolbar to
switch to side-by-side, or the keyboard shortcuts below.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Cmd+1` / `Cmd+2` | Focus the first or second pane |
| `Cmd+N` | New agent sheet |
| `Cmd+\` | Split or unsplit the second pane |
| `Cmd+K` | Clear the focused terminal |
| `Cmd+0` | Show or hide the context panel |
| `Cmd+Shift+R` | Refresh git status |
| `Cmd+,` | Settings |
| `Cmd+A`, `Cmd+C`, `Cmd+V` | Select all, copy, paste in the focused terminal |

## Verification

```sh
apps/macos/scripts/verify-terminal.sh
```

The script runs the `DirectorKit` unit tests, starts a real daemon on a temporary
socket, and runs `DirectorProbe --smoke`. The smoke test checks create, input,
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
- Stacked or side-by-side terminal panes with session metadata, focus, Split,
  Fork, and status bars.
- 504 pt context panel with branch and working-tree changes read from git, plus
  Changes/Artifacts tabs.
- New-agent sheet with agent presets, working directory, and optional name.
- Settings for appearance (Light/Dark/System), terminal font size, socket path,
  and daemon auto-start.
- Reconnect flow and an empty state when the daemon is unavailable.

## Known limitations

- One project at a time; no project switching or worktree management.
- No persistence. Sessions live only as long as the daemon process, and the
  daemon currently keeps a bounded raw output backlog rather than terminal state.
- No session-list-changed event. Sessions created by another client appear only
  after reconnecting or relaunching.
- Fork starts a new process with the same program and working directory; it does
  not fork the agent's conversation.
- The context panel reads git status for the selected session's working
  directory. It does not stage, commit, or diff file contents.
- "Running" is derived from session status. "Needs you" is not implemented, so
  the sidebar labels its filters "All agents" and "Running".
- The app is not sandboxed, has no notarization or release packaging, and has no
  macOS CI job.

## Source layout

```text
apps/macos/
  Director/                 SwiftUI app
    App/AppModel.swift      connection, sessions, attach/input/resize, git state
    Terminal/               SwiftTerm bridge, controller, delegate
    UI/                     sidebar, panes, context panel, sheets, theme
    Services/               agent catalog, daemon launcher, git reader
    Resources/              app icon
  DirectorKit/              local Swift package
    Sources/DirectorAPI/    local API client and protocol types
    Sources/DirectorProbe/  CLI smoke test and session helper
    Tests/DirectorAPITests/ unit tests
  scripts/                  build, run, demo, verify
  project.yml               XcodeGen source of truth
```

The frontend decision is recorded in
[`docs/decisions/0001-macos-frontend.md`](../../docs/decisions/0001-macos-frontend.md).
