# Director Architecture

Status: the workspace foundation and daemon lifecycle are implemented (issue #1). PTY-backed sessions are designed but not implemented (issue #2). The local API, desktop UI, and persistence are planned for later issues.

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
Desktop UI (planned)  ─┐
CLI adapter (planned) ─┼─ local socket (planned, #3) ─┐
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
- Registers signal handlers before reporting readiness.
- Stops the engine with a five-second deadline.
- Current limitation: it exposes no command channel, so clients cannot create sessions yet.

### `director-engine`

- Library independent of clients, transport, and OS signals.
- Owns the engine lifecycle and, after issue #2, the session registry.
- Provides session spawn, input, output, resize, termination, and exit tracking.
- Contains no daemon-specific logging setup or socket code.

### `director-protocol`

- Shared protocol version and serializable state vocabulary.
- Current contents are lifecycle-related (`PROTOCOL_VERSION`, `DaemonState`).
- Session command and event messages belong here when issue #3 defines the local API.
- The engine must not depend on the protocol crate; mapping between runtime types and wire types happens at the daemon boundary.

### Future components

- **Local API (#3):** a user-owned Unix socket, or restricted named pipe on Windows, with version negotiation, bounded client queues, and ordered output/status events.
- **Desktop UI (#4):** GPUI or SwiftUI/AppKit, rendering terminal panes from daemon streams.
- **Persistence and reattachment (#5):** SQLite metadata plus session journals, snapshot or ordered replay, and accurate interrupted-session status after a daemon restart.

## 4. Runtime and concurrency model

The daemon currently uses a single-threaded Tokio runtime. Session support must therefore not block the runtime thread with PTY I/O.

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

## 7. Public engine surface

The planned API is approximately:

```rust
pub struct SessionHandle { /* shared session state */ }

impl SessionHandle {
    pub fn id(&self) -> &SessionId;
    pub fn pid(&self) -> Option<u32>;
    pub fn status(&self) -> SessionStatus;
    pub fn status_changes(&self) -> watch::Receiver<SessionStatus>;
    pub async fn input(&self, bytes: &[u8]) -> Result<()>;
    pub fn resize(&self, size: TerminalSize) -> Result<()>;
    pub async fn terminate(&self) -> Result<SessionExit>;
    pub async fn wait(&self) -> SessionExit;
    pub fn output_snapshot(&self) -> OutputSnapshot;
    pub fn subscribe_output(&self) -> broadcast::Receiver<OutputChunk>;
}

impl Engine {
    pub fn spawn_session(&mut self, spec: SessionSpec) -> Result<SessionHandle>;
    pub fn session(&self, id: &SessionId) -> Option<SessionHandle>;
    pub fn sessions(&self) -> Vec<SessionInfo>;
    pub async fn shutdown(&mut self);
}
```

The names may change during implementation. The boundaries should not: the engine exposes runtime semantics, not wire messages, and handles remain cloneable so I/O and observation do not require borrowing the whole engine.

## 8. Error model

The engine uses typed errors rather than `anyhow` at its public boundary. Expected variants include:

- `DuplicateSessionId`
- `SessionNotFound`
- `SpawnFailed`
- `SessionClosed`
- `InvalidTerminalSize`
- `WriteFailed`
- `ResizeFailed`
- `TerminationFailed`

Spawn failures do not leave a partially registered session. Termination and shutdown are best-effort with bounded waits; failures are reported or logged but must not wedge the daemon indefinitely.

## 9. Security and configuration

- Director does not read, copy, or log agent credentials.
- Environment values and terminal bytes are never logged.
- Structured logs may include session ID, program, PID, size, and exit status.
- Programs are executed directly with explicit arguments; no implicit shell is used.
- The local API must enforce user ownership of the socket or pipe and apply permission policy when issue #3 is implemented.
- Agent CLIs retain their own authentication and permission systems.

## 10. Failure handling

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
| Daemon crash or reboot | Live sessions stop; restoration requires agent support and is addressed by #5. |

## 11. Testing strategy

Tests use real PTYs but do not require agent CLIs to be installed. Shell commands and `stty` act as deterministic stand-ins.

Unit coverage:

- terminal-size and session-ID validation;
- duplicate and missing session errors;
- bounded-buffer eviction and monotonic sequence numbers.

Integration coverage (Unix-gated, with bounded waits):

- spawn, PID, and running status;
- working-directory and environment inheritance;
- per-session environment overrides;
- input/output round trip;
- resize visibility through `stty size`;
- explicit termination and idempotence;
- normal and non-zero exits;
- process-group termination including a grandchild;
- two concurrent sessions with independent I/O, resize, and termination;
- engine shutdown terminating all sessions.

Existing daemon subprocess tests remain valid: startup, readiness, JSON logs on stderr, and clean signal shutdown.

Verification:

```sh
cargo test --workspace --locked
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo metadata --no-deps --format-version 1 --locked
```

## 12. Key decisions

| Decision | Rationale | Consequence |
| --- | --- | --- |
| Use `portable-pty` | Cross-platform PTY/ConPTY support with resize and process-group information. | Blocking API must be bridged into Tokio. |
| Keep sessions in the engine | Preserves client independence and matches process ownership. | The daemon becomes a thin host and future transport adapter. |
| Use Tokio blocking tasks for PTY I/O | The daemon runtime must stay responsive. | Each session consumes blocking-pool capacity for its reader and wait. |
| Caller-supplied session IDs | Makes commands deterministic and lets clients correlate responses. | The engine must reject duplicates and validate IDs. |
| Bounded output backlog | Prevents unbounded memory growth. | Old output is discarded and slow subscribers must resynchronize. |
| Raw bytes, no terminal emulation | Separates process I/O from rendering concerns. | A real terminal screen cannot be reconstructed until #5. |
| Process-group termination on Unix | Prevents orphaned descendants. | Windows needs a different mechanism and currently has weaker guarantees. |
| No automatic restart | Avoids pretending a crashed process is recoverable. | Accurate exit reporting takes priority over availability. |

## 13. Milestones

| Issue | Scope | Status |
| --- | --- | --- |
| #1 | Rust workspace, engine lifecycle, standalone daemon, logging, signals | Done |
| #2 | PTY-backed sessions, I/O, resize, termination, exit tracking, concurrency | Designed |
| #3 | Versioned local session API over a user-owned socket/pipe | Planned |
| #4 | UI framework decision and two-pane terminal prototype | Planned |
| #5 | Persistence, ordered replay, UI reattachment | Planned |

The ordering is intentional: transport and UI depend on the engine owning sessions; reattachment depends on a stable session and event model.

## 14. Out of scope

- Worktree isolation, scheduling, task coordination, and permission policy.
- Agent detection or an agent registry.
- Model-provider proxying.
- Browser or OS automation.
- Remote/SSH transport.
- Automatic recovery of processes after a daemon crash or machine reboot.

## 15. Open questions

- Which mechanism should contain process trees on Windows (Job Objects versus another approach)?
- How should a GUI-launched daemon obtain the user's login-shell environment?
- What retention policy should apply to exited sessions and their output backlogs?
- Which terminal-state representation will issue #5 use for snapshots, and how will it interoperate with the chosen frontend terminal widget?
- What backpressure policy should the local API use for slow clients: disconnect, drop to snapshot, or both?
