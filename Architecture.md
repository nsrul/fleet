# Director Architecture

Status: the workspace foundation, daemon lifecycle (issue #1), PTY-backed sessions (issue #2), the Unix local API (issue #3), and a SwiftUI two-pane macOS prototype (issue #4) are implemented. Persistence, ordered replay, and the Windows named-pipe transport are planned for later work.

Companion diagram: `assets/architecture.png`.

## 1. Purpose

Director is a desktop workspace for running and coordinating coding agents. Agents and shells are owned by a long-lived local daemon, not by the desktop window. Closing the UI detaches the viewer; running processes continue until they exit or the daemon stops.

The architecture separates process ownership from presentation:

- The daemon owns runtime state and operating-system processes.
- The engine contains lifecycle and session logic and has no transport or signal handling.
- The protocol defines shared, versioned vocabulary for future clients.
- Frontends and adapters are replaceable because they never own agent processes.

## 2. System context

```text
Desktop UI (SwiftUI, prototype) ─┐
CLI adapter (planned) ─┼─ Unix socket (#3) ──────────┐
MCP adapter (planned) ─┘                             │
                                                     v
                                            director-daemon
                                                     │
                                                     v
                                            director-engine
                                                     │
                                                     v
                                               PTY + child
                                                     │
                                                     v
                                        installed agent CLI / shell
                                                     │
                                                     v
                                          model provider (direct)
```

Installed agent CLIs use their own credentials, permissions, and provider connections. Director launches them; it does not proxy model traffic or duplicate their authentication.

## 3. Component responsibilities

### `director-daemon`

- Long-running foreground process with no UI.
- Owns the Tokio runtime, configuration, JSON logging, and shutdown signals.
- Serves the versioned local API over a user-owned Unix socket, including framing, handshake, peer checks, and bounded client queues.
- Registers signal handlers before reporting readiness and removes the socket on shutdown.
- Stops the engine with a five-second deadline.
- Current limitation: Windows has no local transport yet; the daemon starts without an API there.

### `director-engine`

- Library independent of clients, transport, and OS signals.
- Owns the engine lifecycle and the session registry.
- Provides session spawn, input, output, resize, termination, and exit tracking.
- Contains no daemon-specific logging setup or socket code.

### `director-protocol`

- Shared protocol version, lifecycle state vocabulary, and local API messages.
- Defines commands, responses, error codes, output/status events, base64 byte wrappers, and frame/input limits.
- Contains serialization types only; framing and transport live in the daemon.
- The engine must not depend on the protocol crate; mapping between runtime types and wire types happens at the daemon boundary.

### macOS frontend (`apps/macos`)

- SwiftUI application shell with AppKit interop for terminal hosting.
- `DirectorKit` local package contains the typed local API client (`DirectorAPI`) and a CLI probe (`DirectorProbe`).
- `AppModel` owns connection state, sessions, attach/input/resize calls, focus, layout, and git status. `TerminalController` owns each SwiftTerm view and its delegate.
- SwiftTerm 1.99.1 renders terminal output, scrollback, selection, and keyboard input. The daemon sends raw PTY bytes; the frontend owns emulation.
- Layout follows the Figma prototype: 256 pt sidebar, terminal panes, 504 pt git context panel, stacked or side-by-side panes.
- Current limitation: one project, no persistence, and no session-list-changed event. Externally created sessions require reconnect or relaunch. Fork starts a new process with the same program and working directory, not a forked conversation.

### Future components

- **Windows local transport:** a restricted named pipe with the same protocol, deferred from this Unix-only pass; the non-Unix daemon reports `api="unavailable"`.
- **Persistence and reattachment (#5):** SQLite metadata plus session journals, snapshot or ordered replay, and accurate interrupted-session status after a daemon restart.
- **Cross-platform frontend:** a second frontend or a shared renderer if Windows or Linux becomes a target.

## 4. Runtime and concurrency model

The daemon currently uses a single-threaded Tokio runtime. Session support therefore keeps PTY I/O off the runtime thread. API connections are asynchronous tasks on that runtime; PTY and child I/O remain on the existing blocking pool.

The daemon shares the engine through a `tokio::sync::Mutex`. Connection tasks hold the lock only while looking up, creating, or listing sessions. Input, resize, terminate, and streaming operate on cloned session handles after the lock is released, so slow terminal work does not serialize unrelated clients.

The session implementation uses three kinds of work per session:

1. **Reader:** a blocking PTY read loop on Tokio's blocking thread pool, forwarding byte chunks into a bounded channel.
2. **Output pump:** an asynchronous task that assigns sequence numbers, updates the bounded backlog, and broadcasts chunks to subscribers.
3. **Exit watcher:** a blocking `wait` on the child, publishing the normalized exit status through a `watch` channel.

The session registry and each session handle remain usable independently. No global lock is held across an `await`, and long-running blocking operations are confined to the blocking pool.

```text
                 ┌──────────────── Session ────────────────┐
child process ◄─►│ PTY master                              │
                 │   │ reader (blocking task)              │
                 │   ▼                                     │
                 │ bounded mpsc ──► output pump (async)    │
                 │                    │                    │
                 │                    ├─► bounded backlog  │
                 │                    └─► broadcast chunks │
                 │                                         │
                 │ exit watcher ──► watch<SessionStatus>   │
                 └─────────────────────────────────────────┘
```

The output backlog is bounded, for example to the most recent 1 MiB. A chatty child cannot grow memory without limit. Subscribers that fall behind receive a lag signal rather than an unbounded queue.

## 5. Session model

A session represents one PTY-backed terminal process.

### Identity

- `SessionId` is an opaque, caller-supplied identifier.
- IDs must be non-empty and bounded in length.
- Duplicate IDs are rejected while the session exists.
- A failed spawn does not reserve the ID.

### Specification

A `SessionSpec` contains:

- program and arguments;
- working directory;
- environment overrides;
- initial terminal size.

`CommandBuilder` inherits the daemon's full environment by default. Per-session overrides are layered on top. This preserves `PATH`, `HOME`, agent credentials, and agent-specific configuration without Director reading or storing secrets. Commands are executed directly, without shell wrapping, so arguments are not subject to shell quoting or injection.

If `TERM` is absent from the inherited environment, the session layer may set `TERM=xterm-256color` so terminal-aware programs have a usable baseline.

### Status

```rust
pub enum SessionStatus {
    Running,
    Exited(SessionExit),
}
```

`SessionExit` records success, the process exit code, and the signal name when present. Status is published through a `watch` channel, which retains the latest value and makes late observation reliable.

### Lifecycle

```text
spawn requested
      │
      ├── validation/spawn failure ──► no session registered
      │
      ▼
   Running ── child exits ──► Exited
      │
      └── terminate ──► signal/kill ──► Exited
```

Termination is idempotent. Input and resize operations against an exited session return a clear closed-session error rather than panicking.

## 6. Operations

### Spawn

1. Validate the session specification and reject duplicate IDs.
2. Open a PTY at the requested size.
3. Build the command with program, arguments, working directory, and environment overrides.
4. Spawn the child attached to the slave side of the PTY.
5. Start the reader, output pump, and exit watcher.
6. Register the session and return a cloneable handle.

### Input

Input is raw bytes written to the PTY master. Writes are serialized and performed on a blocking task so large pastes cannot stall the runtime. The PTY performs normal terminal line discipline and echo handling.

### Output

Output is raw PTY bytes, including ANSI control sequences. The engine does not decode UTF-8 or interpret screen state.

Each chunk has a monotonic sequence number. A snapshot exposes the current backlog and sequence range; subscribers receive ordered chunks from a broadcast channel. Slow subscribers receive `Lagged` and are expected to resynchronize from a later snapshot. Full terminal-state snapshots remain part of issue #5.

### Resize

Resize validates non-zero rows and columns, calls `MasterPty::resize`, and updates the recorded size. On Unix the child receives the normal resize notification (`SIGWINCH`).

### Termination

- **Unix:** signal the PTY's process group, using the child PID as a fallback, so descendants do not become orphans. Send `SIGTERM`, allow a short grace period, then send `SIGKILL`.
- **Windows:** terminate the direct child through `portable-pty`; process-tree containment through Job Objects is not part of issue #2 and is a documented limitation.
- **Engine shutdown:** terminate all running sessions concurrently with bounded waits, then mark the engine stopped.
- **Drop safety:** dropping the last owner of a session makes a best-effort termination signal so a panic or early engine drop does not silently leave a child running.

## 7. Local API

Issue #3 adds a versioned API for local clients. The transport is Unix-only in this pass; the wire vocabulary and framing are shared with future adapters.

### Transport and ownership

- The default socket is `$XDG_RUNTIME_DIR/director/daemon.sock`, or `<system-temp>/director-<uid>/daemon.sock` when `XDG_RUNTIME_DIR` is unset (`$TMPDIR` is used when defined). `--socket <path>`/`--socket=<path>` overrides `DIRECTOR_SOCKET`, which overrides the default. Relative paths resolve against the working directory, and paths longer than 100 bytes are rejected.
- The daemon creates missing parent directories and restricts the default parent to `0700`. It refuses a symlinked parent, a parent owned by another user (so a socket placed directly in `/tmp` is rejected), a non-socket file at the socket path, or a socket owned by another user.
- Existing sockets are removed only after a one-second connect probe reports `ConnectionRefused` or `NotFound`. A successful connection means another daemon is live; a timeout aborts startup rather than risking a second daemon.
- The socket is restricted to `0600`, and each accepted peer is checked with `peer_cred()`; only the daemon user's UID is served. Credential lookup failures and foreign peers are rejected before any protocol message is read.
- The socket file is removed on shutdown only when its device and inode still match the bound socket, so a replacement process would not have its socket deleted.

### Framing and handshake

Each frame is a 4-byte big-endian length followed by that many bytes of UTF-8 JSON. The length covers only the JSON payload. Frames whose total size exceeds 4 MiB are rejected before the body is read. Terminal bytes use standard base64 strings.

The first client frame must be `hello` with `protocol_version: 1` within five seconds. The daemon replies with `welcome` (protocol, daemon version, engine state) or `rejected` with a stable error code. Requests before `hello` return `handshake_required`; a second hello is invalid. Every request carries a client-chosen `request_id`, which is echoed in its response.

### Commands

| Command | Parameters | Success payload |
| --- | --- | --- |
| `create_session` | `id`, `program`, `args`, `cwd`, `env`, `size` | `session` |
| `list_sessions` | — | `sessions` |
| `inspect_session` | `id` | `session` |
| `stop_session` | `id` | `exit` |
| `input` | `id`, base64 `data` | `acknowledged` |
| `resize` | `id`, `size` | `acknowledged` |
| `attach_session` | `id` | `attached` |
| `detach_session` | `id` | `acknowledged` |

Input is limited to 1 MiB per request. Terminal sizes require non-zero rows and columns. Create-session requests reject empty programs or working directories, NUL bytes, and malformed environment names before reaching the engine.

### Attach stream

An attach response contains session metadata plus a retained output snapshot (`data`, `first_seq`, `next_seq`, `truncated`). The engine keeps at most the newest 1 MiB. After the response, the server streams ordered `output` events with monotonically increasing sequence numbers and `status` events when the session changes state. The initial status in the attach response is not repeated.

A client may attach to each session at most once per connection. Detaching stops that session's events and returns `acknowledged`. On daemon shutdown, attached clients receive `daemon_stopping` and the connection closes. A client that cannot keep up is disconnected; when its queue still has room, it receives `slow_client` first. The client should reconnect and attach again to resynchronize from a snapshot rather than treating the stream as resumable.

### Limits and backpressure

- At most 32 clients are served concurrently. Excess connections receive `slow_client` and close.
- Each client has a bounded outbound queue of 64 frames and an 8 MiB byte budget. A full queue or exhausted budget closes the connection instead of growing memory or dropping ordered events.
- Handshakes time out after five seconds.
- Shutdown gives connections 500 ms to finish and the writer task up to one second to drain; remaining tasks are aborted before socket removal.

### Error codes

Errors are returned as a `response` with an `error` result, or as `rejected` before the handshake completes. Codes are grouped as follows:

- Handshake/message: `unsupported_protocol`, `handshake_required`, `handshake_timeout`, `invalid_message`, `invalid_request`.
- Session/operation: `invalid_session_id`, `duplicate_session`, `session_not_found`, `session_closed`, `already_attached`, `not_attached`, `invalid_program`, `missing_working_directory`, `invalid_terminal_size`, `spawn_failed`, `input_failed`, `resize_failed`, `termination_failed`, `termination_timed_out`.
- Resource/state: `engine_stopped`, `slow_client`, `internal`.

Messages are intended to be clear and actionable. They do not include terminal bytes or environment values.

## 8. Public engine surface

The implemented API is approximately:

```rust
pub struct SessionHandle { /* shared session state */ }

impl SessionHandle {
    pub fn id(&self) -> &SessionId;
    pub fn pid(&self) -> Option<u32>;
    pub fn status(&self) -> SessionStatus;
    pub fn status_changes(&self) -> watch::Receiver<SessionStatus>;
    pub async fn input(&self, bytes: &[u8]) -> Result<(), SessionError>;
    pub fn resize(&self, size: TerminalSize) -> Result<(), SessionError>;
    pub async fn terminate(&self) -> Result<SessionExit, SessionError>;
    pub async fn wait(&self) -> SessionExit;
    pub fn output_snapshot(&self) -> OutputSnapshot;
    pub fn subscribe_output(&self) -> broadcast::Receiver<OutputChunk>;
}

impl Engine {
    pub fn state(&self) -> EngineState;
    pub fn spawn_session(&mut self, spec: SessionSpec) -> Result<SessionHandle, EngineError>;
    pub fn session(&self, id: &SessionId) -> Option<SessionHandle>;
    pub fn sessions(&self) -> Vec<SessionInfo>;
    pub async fn shutdown(&mut self);
}
```

The names may still evolve. The boundaries should not: the engine exposes runtime semantics, not wire messages, and handles remain cloneable so I/O and observation do not require borrowing the whole engine.

## 9. Error model

The engine uses typed errors rather than exposing `anyhow` at its public boundary. `SessionError` includes:

- `InvalidSessionId`
- `InvalidProgram`
- `MissingWorkingDirectory`
- `InvalidTerminalSize`
- `DuplicateSessionId`
- `SessionNotFound`
- `SessionClosed`
- `SpawnFailed`
- `InputFailed`
- `ResizeFailed`
- `TerminationFailed`
- `TerminationTimedOut`
- `MissingRuntime`
- `TaskFailed`

`EngineError` adds `Stopped` for operations attempted after engine shutdown.

Spawn failures do not leave a partially registered session. Termination and shutdown are best-effort with bounded waits; failures are reported or logged but must not wedge the daemon indefinitely.

At the daemon boundary, engine errors map to stable `ErrorCode` values instead of exposing Rust variant names. The local API adds transport-level categories for handshake, framing, attachment, backpressure, and shutdown. See section 7 for the full list.

## 10. Security and configuration

- Director does not read, copy, or log agent credentials.
- Environment values and terminal bytes are never logged. API error messages are built from metadata, not terminal data.
- Structured logs may include session ID, program, PID, size, and exit status.
- Programs are executed directly with explicit arguments; no implicit shell is used.
- The local socket is owner-only (`0600`), its default parent is private (`0700`), and peers are checked against the daemon user's UID before the handshake.
- Socket-parent ownership and symlinks are checked; live daemons are not replaced, and stale sockets are removed only after a bounded connect probe.
- Agent CLIs retain their own authentication and permission systems.

## 11. Failure handling

| Failure | Behavior |
| --- | --- |
| PTY cannot be opened | Spawn fails; no session is registered. |
| Program does not exist | Spawn fails; the ID remains reusable. |
| Duplicate ID | Spawn is rejected. |
| Child exits | Exit status is recorded and published once. |
| PTY read returns EOF or Unix `EIO` | Treated as normal end of output. |
| Unexpected read error | Logged; exit tracking continues independently. |
| Input after exit | Returns a closed-session error. |
| Resize with zero rows/columns | Rejected before reaching the PTY. |
| Termination signal fails | Reported; shutdown still proceeds within its deadline. |
| Socket parent is a symlink or owned by another user | Startup fails with a clear configuration error. |
| Another daemon is listening | Startup fails instead of replacing the live socket. |
| Socket is stale | Removed after a bounded failed-connect probe. |
| Handshake missing, late, or version-mismatched | Client is rejected with a stable code; no request is executed. |
| Frame exceeds 4 MiB | Client is rejected before the body is read. |
| Client is slow | Its connection closes with `slow_client`; other clients and the child are unaffected. |
| Daemon stops with attached clients | Clients receive `daemon_stopping`; connections and socket are closed. |
| Daemon crash or reboot | Live sessions stop; restoration requires agent support and is addressed by #5. |

## 12. Testing strategy

Tests use real PTYs but do not require agent CLIs to be installed. Shell commands and `stty` act as deterministic stand-ins.

Unit coverage:

- session-ID and terminal-size validation;
- bounded-buffer eviction and monotonic sequence numbers;
- protocol message round trips and stable JSON shapes;
- frame codec limits and malformed-input handling;
- outbound queue and byte-budget limits;
- socket-path configuration and listener ownership/staleness behavior.

Integration coverage (Unix-gated, with bounded waits):

- spawn, PID, and running status;
- working-directory and environment inheritance, including per-session overrides;
- input/output round trip;
- resize visibility through `stty size`;
- explicit termination and idempotence;
- normal and non-zero exits;
- process-group termination including a grandchild;
- two concurrent sessions with independent I/O, environment, and termination;
- engine shutdown terminating all sessions;
- handshake version checks, malformed and oversized frames, and owner-only socket permissions;
- create/list/inspect/stop through the API, ordered output/input/status, snapshot replay, resize, and multi-client attachment;
- live-daemon and stale-socket startup behavior;
- attached-client notification and socket removal on shutdown.

Daemon subprocess tests also cover startup, readiness, JSON logs on stderr, and clean SIGINT/SIGTERM shutdown.

Verification:

```sh
cargo test --workspace --locked
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo metadata --no-deps --format-version 1 --locked
```

The macOS prototype adds `apps/macos/scripts/verify-terminal.sh`, which runs the
`DirectorKit` unit tests, starts a real daemon on a temporary socket, and runs
`DirectorProbe --smoke` for create, input/output, Unicode, resize, and exit. The
app-level checklist covers two live panes, keyboard input, Unicode, selection
and copy, scrollback, pane/window resize, focus switching, and reattachment
after relaunch. It was exercised with Claude Code 2.1.311 and Gemini CLI 0.46.0
on macOS 27. The app has no CI job yet; see `apps/macos/README.md`.

## 13. Key decisions

| Decision | Rationale | Consequence |
| --- | --- | --- |
| Use `portable-pty` | Cross-platform PTY/ConPTY support with resize and process-group information. | Blocking API must be bridged into Tokio. |
| Keep sessions in the engine | Preserves client independence and matches process ownership. | The daemon becomes a thin host and future transport adapter. |
| Use Tokio blocking tasks for PTY I/O | The daemon runtime must stay responsive. | Each session consumes blocking-pool capacity for its reader and wait. |
| Caller-supplied session IDs | Makes commands deterministic and lets clients correlate responses. | The engine must reject duplicates and validate IDs. |
| Bounded output backlog | Prevents unbounded memory growth. | Old output is discarded and slow subscribers must resynchronize. |
| Raw bytes, no terminal emulation | Separates process I/O from rendering concerns. | A real terminal screen cannot be reconstructed until #5. |
| SwiftUI + SwiftTerm for the macOS prototype | Native shell with a mature terminal widget instead of writing emulation. | Mac-only frontend; SwiftTerm is a pinned third-party dependency; other platforms need a separate decision. |
| Process-group termination on Unix | Prevents orphaned descendants. | Windows needs a different mechanism and currently has weaker guarantees. |
| Unix socket plus length-prefixed JSON | Gives strict ownership/permission control with a debuggable, versioned wire format. | Windows needs a named-pipe transport; JSON/base64 costs some throughput. |
| Daemon-level engine mutex | API tasks need shared access on the current-thread runtime without changing engine ownership semantics. | Long engine operations are serialized at command boundaries; session I/O uses cloned handles. |
| Disconnect slow clients | Keeps memory bounded and preserves ordering rather than silently dropping events. | Clients must reattach to resynchronize from a snapshot. |
| No automatic restart | Avoids pretending a crashed process is recoverable. | Accurate exit reporting takes priority over availability. |

## 14. Milestones

| Issue | Scope | Status |
| --- | --- | --- |
| #1 | Rust workspace, engine lifecycle, standalone daemon, logging, signals | Done |
| #2 | PTY-backed sessions, I/O, resize, termination, exit tracking, concurrency | Done |
| #3 | Versioned local session API over a user-owned Unix socket | Done (named pipe deferred) |
| #4 | UI framework decision and two-pane terminal prototype | Done (SwiftUI prototype) |
| #5 | Persistence, ordered replay, UI reattachment | Planned |

The ordering is intentional: transport and UI depend on the engine owning sessions; reattachment depends on a stable session and event model.

## 15. Out of scope

- Worktree isolation, scheduling, task coordination, and permission policy.
- Agent detection or an agent registry.
- Model-provider proxying.
- Browser or OS automation.
- Remote/SSH transport.
- Automatic recovery of processes after a daemon crash or machine reboot.

## 16. Open questions

- Which mechanism should contain process trees on Windows (Job Objects versus another approach)?
- How should a GUI-launched daemon obtain the user's login-shell environment?
- What retention policy should apply to exited sessions and their output backlogs?
- Which terminal-state representation will issue #5 use for snapshots, and how will it interoperate with the chosen frontend terminal widget?
- If Windows or Linux becomes a target, should the SwiftUI frontend be ported, a second native frontend be built, or a shared web terminal be adopted?
- When should a Windows named-pipe transport be added, and should socket discovery differ there?
- How should the protocol evolve beyond version 1 while keeping old clients diagnosable?
