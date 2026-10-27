//! Versioned local session API over a user-owned Unix socket.

mod codec;
mod listener;
mod outbound;

use std::{
    collections::HashMap,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use anyhow::{Context, Result, anyhow};
use director_engine::{
    Engine, EngineError, EngineState, OutputChunk, OutputSnapshot as EngineOutputSnapshot,
    SessionError, SessionExit as EngineSessionExit, SessionHandle, SessionId,
    SessionInfo as EngineSessionInfo, SessionSpec, SessionStatus as EngineSessionStatus,
    TerminalSize as EngineTerminalSize,
};
use director_protocol::{
    DaemonState, PROTOCOL_VERSION,
    api::{
        ApiError, AttachedSession, Base64Bytes, ClientMessage, Command, CreateSession, ErrorCode,
        Event, ResponseData, ResponseResult, ServerMessage, SessionExit, SessionInfo,
        SessionStatus, TerminalSize,
    },
};
use tokio::{
    io::AsyncWriteExt,
    net::UnixStream,
    sync::{Mutex, Semaphore, broadcast, watch},
    task::{JoinHandle, JoinSet},
    time::timeout,
};
use tracing::{debug, warn};

use self::{codec::FrameError, listener::LocalListener, outbound::Outbound};

const MAX_CLIENTS: usize = 32;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const CONNECTION_GRACE: Duration = Duration::from_millis(500);
const WRITER_DRAIN_TIMEOUT: Duration = Duration::from_secs(1);

static NEXT_CLIENT_ID: AtomicU64 = AtomicU64::new(1);

pub struct ApiServer {
    listener: LocalListener,
    state: Arc<ApiState>,
    clients: Arc<Semaphore>,
    connections: JoinSet<()>,
    shutdown: watch::Sender<bool>,
}

struct ApiState {
    engine: Arc<Mutex<Engine>>,
    shutdown: watch::Sender<bool>,
}

impl ApiServer {
    pub async fn bind(
        path: &Path,
        private_parent: bool,
        engine: Arc<Mutex<Engine>>,
    ) -> Result<Self> {
        let listener = LocalListener::bind(path, private_parent).await?;
        let (shutdown, _) = watch::channel(false);
        Ok(Self {
            listener,
            state: Arc::new(ApiState {
                engine,
                shutdown: shutdown.clone(),
            }),
            clients: Arc::new(Semaphore::new(MAX_CLIENTS)),
            connections: JoinSet::new(),
            shutdown,
        })
    }

    pub fn socket_path(&self) -> &Path {
        self.listener.path()
    }

    pub async fn run(&mut self) -> Result<()> {
        loop {
            enum Next {
                Accepted(std::io::Result<UnixStream>),
                Joined(Option<std::result::Result<(), tokio::task::JoinError>>),
            }

            let next = tokio::select! {
                accepted = self.listener.accept() => Next::Accepted(accepted),
                joined = self.connections.join_next(), if !self.connections.is_empty() => {
                    Next::Joined(joined)
                }
            };

            match next {
                Next::Accepted(result) => {
                    let stream = result.context("accept a local client")?;
                    let client_id = NEXT_CLIENT_ID.fetch_add(1, Ordering::Relaxed);
                    let peer_uid = match stream.peer_cred() {
                        Ok(credentials) => credentials.uid(),
                        Err(error) => {
                            debug!(
                                client_id,
                                error = %error,
                                event = "client_rejected",
                                reason = "peer_credentials_unavailable",
                            );
                            continue;
                        }
                    };
                    if peer_uid != listener::current_uid() {
                        warn!(
                            client_id,
                            peer_uid,
                            event = "client_rejected",
                            reason = "peer_not_owner",
                        );
                        continue;
                    }

                    let permit = match self.clients.clone().try_acquire_owned() {
                        Ok(permit) => permit,
                        Err(_) => {
                            warn!(
                                client_id,
                                event = "client_rejected",
                                reason = "too_many_clients",
                            );
                            let mut stream = stream;
                            let message = ServerMessage::Rejected {
                                error: ApiError::new(
                                    ErrorCode::SlowClient,
                                    "the daemon has too many connected clients",
                                ),
                            };
                            if let Ok(frame) = codec::encode(&message) {
                                let _ =
                                    timeout(Duration::from_millis(100), stream.write_all(&frame))
                                        .await;
                            }
                            continue;
                        }
                    };

                    let state = Arc::clone(&self.state);
                    let shutdown = self.shutdown.subscribe();
                    debug!(client_id, event = "client_connected");
                    self.connections.spawn(async move {
                        let _permit = permit;
                        handle_connection(client_id, stream, state, shutdown).await;
                        debug!(client_id, event = "client_disconnected");
                    });
                }
                Next::Joined(Some(Err(error))) => {
                    warn!(error = %error, event = "api_connection_task_failed");
                }
                Next::Joined(Some(Ok(())) | None) => {}
            }
        }
    }

    pub async fn shutdown(&mut self) {
        let _ = self.shutdown.send(true);
        self.listener.close();

        let deadline = tokio::time::Instant::now() + CONNECTION_GRACE;
        while !self.connections.is_empty() {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            match timeout(remaining, self.connections.join_next()).await {
                Ok(Some(Ok(()))) => {}
                Ok(Some(Err(error))) => {
                    debug!(error = %error, event = "api_connection_shutdown_task_failed");
                }
                Ok(None) | Err(_) => break,
            }
        }

        self.connections.abort_all();
        while let Some(result) = self.connections.join_next().await {
            if let Err(error) = result {
                debug!(error = %error, event = "api_connection_aborted");
            }
        }
        self.listener.remove();
    }
}

async fn handle_connection(
    client_id: u64,
    stream: UnixStream,
    state: Arc<ApiState>,
    shutdown: watch::Receiver<bool>,
) {
    let (reader, writer) = stream.into_split();
    let (outbound, frames, writer_closed) = Outbound::new();
    let closed = outbound.subscribe_closed();
    let writer = tokio::spawn(outbound::write_loop(writer, frames, writer_closed));

    Connection {
        client_id,
        reader,
        outbound: Some(outbound),
        closed,
        shutdown,
        state,
        attachments: HashMap::new(),
        writer: Some(writer),
    }
    .run()
    .await;
}

struct Connection {
    client_id: u64,
    reader: tokio::net::unix::OwnedReadHalf,
    outbound: Option<Outbound>,
    closed: watch::Receiver<bool>,
    shutdown: watch::Receiver<bool>,
    state: Arc<ApiState>,
    attachments: HashMap<SessionId, JoinHandle<()>>,
    writer: Option<JoinHandle<()>>,
}

impl Drop for Connection {
    fn drop(&mut self) {
        for (_, task) in self.attachments.drain() {
            task.abort();
        }
        if let Some(writer) = self.writer.take() {
            writer.abort();
        }
    }
}

impl Connection {
    async fn run(mut self) {
        match self.serve().await {
            Ok(()) => {}
            Err(error) => {
                debug!(client_id = self.client_id, error = %error, event = "client_ended");
            }
        }
        self.finish().await;
    }

    async fn serve(&mut self) -> Result<()> {
        if *self.shutdown.borrow() {
            return Ok(());
        }

        let hello = match timeout(
            HANDSHAKE_TIMEOUT,
            codec::read::<ClientMessage, _>(&mut self.reader),
        )
        .await
        {
            Err(_) => {
                self.reject(ErrorCode::HandshakeTimeout, "the handshake timed out")?;
                return Ok(());
            }
            Ok(Err(error)) => {
                self.reject(ErrorCode::InvalidMessage, error.to_string())?;
                return Ok(());
            }
            Ok(Ok(None)) => return Ok(()),
            Ok(Ok(Some(message))) => message,
        };

        match hello {
            ClientMessage::Hello {
                protocol_version,
                client,
            } => {
                if protocol_version != PROTOCOL_VERSION {
                    self.reject(
                        ErrorCode::UnsupportedProtocol,
                        format!(
                            "protocol version {protocol_version} is not supported; expected {PROTOCOL_VERSION}"
                        ),
                    )?;
                    return Ok(());
                }
                let engine_state = self.state.engine.lock().await.state();
                self.send(ServerMessage::Welcome {
                    protocol_version: PROTOCOL_VERSION,
                    daemon_version: env!("CARGO_PKG_VERSION").to_owned(),
                    engine_state: daemon_state(engine_state),
                })?;
                debug!(
                    client_id = self.client_id,
                    client = client.as_deref().unwrap_or("unnamed"),
                    event = "client_ready",
                );
            }
            ClientMessage::Request { .. } => {
                self.reject(
                    ErrorCode::HandshakeRequired,
                    "send hello before any request",
                )?;
                return Ok(());
            }
        }

        loop {
            enum Next {
                Message(std::result::Result<Option<ClientMessage>, FrameError>),
                Shutdown,
                Closed,
            }

            let next = tokio::select! {
                message = codec::read::<ClientMessage, _>(&mut self.reader) => {
                    Next::Message(message)
                }
                _ = wait_until_set(&mut self.shutdown) => Next::Shutdown,
                _ = wait_until_set(&mut self.closed) => Next::Closed,
            };

            match next {
                Next::Message(Ok(Some(message))) => self.handle_message(message).await?,
                Next::Message(Ok(None)) => return Ok(()),
                Next::Message(Err(error)) => {
                    self.reject(ErrorCode::InvalidMessage, error.to_string())?;
                    return Ok(());
                }
                Next::Shutdown => {
                    self.send(ServerMessage::Event {
                        event: Event::DaemonStopping,
                    })?;
                    return Ok(());
                }
                Next::Closed => return Ok(()),
            }
        }
    }

    async fn handle_message(&mut self, message: ClientMessage) -> Result<()> {
        match message {
            ClientMessage::Hello { .. } => {
                self.reject(ErrorCode::InvalidRequest, "hello may only be sent once")?;
                Err(anyhow!("duplicate hello"))
            }
            ClientMessage::Request {
                request_id,
                command,
            } => self.handle_request(request_id, command).await,
        }
    }

    async fn handle_request(&mut self, request_id: u64, command: Command) -> Result<()> {
        match command {
            Command::AttachSession { id } => self.attach(request_id, id).await,
            Command::DetachSession { id } => self.detach(request_id, id),
            command => {
                let result = execute(&self.state, command).await;
                self.respond(request_id, result)
            }
        }
    }

    async fn attach(&mut self, request_id: u64, id: String) -> Result<()> {
        let session_id = match SessionId::new(id) {
            Ok(session_id) => session_id,
            Err(error) => return self.respond(request_id, Err(map_session_error(error))),
        };
        if self.attachments.contains_key(&session_id) {
            return self.respond(
                request_id,
                Err(ApiError::new(
                    ErrorCode::AlreadyAttached,
                    format!("session {session_id:?} is already attached"),
                )),
            );
        }

        let handle = match find_session(&self.state, &session_id).await {
            Ok(handle) => handle,
            Err(error) => return self.respond(request_id, Err(error)),
        };

        let output = handle.subscribe_output();
        let snapshot = handle.output_snapshot();
        let status = handle.status_changes();
        let info = handle.info();
        let initial_status = info.status.clone();
        let next_seq = snapshot.next_seq;

        self.respond(
            request_id,
            Ok(ResponseData::Attached(AttachedSession {
                session: protocol_info(&info),
                output: protocol_snapshot(&snapshot),
            })),
        )?;

        let outbound = self
            .outbound
            .as_ref()
            .expect("the connection outbound exists while serving")
            .clone();
        let shutdown = self.state.shutdown.subscribe();
        let session_id_for_pump = session_id.clone();
        let task = tokio::spawn(async move {
            pump_session(
                session_id_for_pump,
                output,
                status,
                initial_status,
                next_seq,
                outbound,
                shutdown,
            )
            .await;
        });
        self.attachments.insert(session_id, task);
        Ok(())
    }

    fn detach(&mut self, request_id: u64, id: String) -> Result<()> {
        let session_id = match SessionId::new(id) {
            Ok(session_id) => session_id,
            Err(error) => return self.respond(request_id, Err(map_session_error(error))),
        };
        match self.attachments.remove(&session_id) {
            Some(task) => {
                task.abort();
                self.respond(request_id, Ok(ResponseData::Acknowledged))
            }
            None => self.respond(
                request_id,
                Err(ApiError::new(
                    ErrorCode::NotAttached,
                    format!("session {session_id:?} is not attached"),
                )),
            ),
        }
    }

    fn respond(
        &self,
        request_id: u64,
        result: std::result::Result<ResponseData, ApiError>,
    ) -> Result<()> {
        self.send(ServerMessage::Response {
            request_id,
            result: match result {
                Ok(data) => ResponseResult::Ok(data),
                Err(error) => ResponseResult::Error(error),
            },
        })
    }

    fn reject(&self, code: ErrorCode, message: impl Into<String>) -> Result<()> {
        self.send(ServerMessage::Rejected {
            error: ApiError::new(code, message),
        })
    }

    fn send(&self, message: ServerMessage) -> Result<()> {
        let outbound = self
            .outbound
            .as_ref()
            .expect("the connection outbound exists while serving");
        outbound.try_send(&message)?;
        Ok(())
    }

    async fn finish(mut self) {
        let tasks: Vec<_> = self.attachments.drain().map(|(_, task)| task).collect();
        for task in &tasks {
            task.abort();
        }
        for task in tasks {
            let _ = task.await;
        }

        self.outbound = None;

        if let Some(writer) = self.writer.as_mut() {
            match timeout(WRITER_DRAIN_TIMEOUT, &mut *writer).await {
                Ok(Ok(())) => {}
                Ok(Err(error)) => {
                    debug!(client_id = self.client_id, error = %error, event = "writer_task_failed");
                }
                Err(_) => {
                    warn!(client_id = self.client_id, event = "writer_drain_timed_out");
                    writer.abort();
                    let _ = writer.await;
                }
            }
        }
    }
}

async fn execute(
    state: &ApiState,
    command: Command,
) -> std::result::Result<ResponseData, ApiError> {
    match command {
        Command::CreateSession(request) => {
            let spec = build_spec(request)?;
            let handle = state
                .engine
                .lock()
                .await
                .spawn_session(spec)
                .map_err(map_engine_error)?;
            Ok(ResponseData::Session(protocol_info(&handle.info())))
        }
        Command::ListSessions => {
            let engine = state.engine.lock().await;
            if engine.state() == EngineState::Stopped {
                return Err(ApiError::new(
                    ErrorCode::EngineStopped,
                    "the engine is stopped",
                ));
            }
            Ok(ResponseData::Sessions(
                engine.sessions().iter().map(protocol_info).collect(),
            ))
        }
        Command::InspectSession { id } => {
            let id = session_id(id)?;
            let handle = find_session(state, &id).await?;
            Ok(ResponseData::Session(protocol_info(&handle.info())))
        }
        Command::StopSession { id } => {
            let id = session_id(id)?;
            let handle = find_session(state, &id).await?;
            let exit = handle.terminate().await.map_err(map_session_error)?;
            Ok(ResponseData::Exit(protocol_exit(&exit)))
        }
        Command::Input { id, data } => {
            if data.len() > director_protocol::api::MAX_INPUT_BYTES {
                return Err(ApiError::invalid_request(format!(
                    "input is {} bytes; the limit is {} bytes",
                    data.len(),
                    director_protocol::api::MAX_INPUT_BYTES,
                )));
            }
            let id = session_id(id)?;
            let handle = find_session(state, &id).await?;
            handle
                .input(data.as_slice())
                .await
                .map_err(map_session_error)?;
            Ok(ResponseData::Acknowledged)
        }
        Command::Resize { id, size } => {
            let id = session_id(id)?;
            let size = engine_size(size)?;
            let handle = find_session(state, &id).await?;
            handle.resize(size).map_err(map_session_error)?;
            Ok(ResponseData::Acknowledged)
        }
        Command::AttachSession { .. } | Command::DetachSession { .. } => {
            Err(ApiError::invalid_request("unexpected streaming command"))
        }
    }
}

async fn find_session(
    state: &ApiState,
    id: &SessionId,
) -> std::result::Result<SessionHandle, ApiError> {
    let engine = state.engine.lock().await;
    if engine.state() == EngineState::Stopped {
        return Err(ApiError::new(
            ErrorCode::EngineStopped,
            "the engine is stopped",
        ));
    }
    engine.session(id).ok_or_else(|| {
        ApiError::new(
            ErrorCode::SessionNotFound,
            format!("session {id:?} was not found"),
        )
    })
}

async fn pump_session(
    session_id: SessionId,
    mut output: broadcast::Receiver<OutputChunk>,
    mut status: watch::Receiver<EngineSessionStatus>,
    initial_status: EngineSessionStatus,
    mut next_seq: u64,
    outbound: Outbound,
    mut shutdown: watch::Receiver<bool>,
) {
    let session_id = session_id.to_string();
    let mut last_status = initial_status;

    loop {
        tokio::select! {
            chunk = output.recv() => {
                match chunk {
                    Ok(chunk) if chunk.seq < next_seq => {}
                    Ok(chunk) if chunk.seq != next_seq => {
                        warn!(
                            session_id = %session_id,
                            expected = next_seq,
                            received = chunk.seq,
                            event = "api_output_gap",
                        );
                        let _ = outbound.try_send(&ServerMessage::Rejected {
                            error: ApiError::new(
                                ErrorCode::SlowClient,
                                "the output stream lost ordering; reconnect and attach again",
                            ),
                        });
                        outbound.close();
                        break;
                    }
                    Ok(chunk) => {
                        next_seq = chunk.seq + 1;
                        let message = ServerMessage::Event {
                            event: Event::Output {
                                session_id: session_id.clone(),
                                seq: chunk.seq,
                                data: Base64Bytes::new(chunk.data().to_vec()),
                            },
                        };
                        if outbound.try_send(&message).is_err() {
                            outbound.close();
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!(
                            session_id = %session_id,
                            skipped,
                            event = "api_output_lagged",
                        );
                        let _ = outbound.try_send(&ServerMessage::Rejected {
                            error: ApiError::new(
                                ErrorCode::SlowClient,
                                "the client fell behind the output stream; reconnect and attach again",
                            ),
                        });
                        outbound.close();
                        break;
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            changed = status.changed() => {
                if changed.is_err() {
                    break;
                }
                let current = status.borrow_and_update().clone();
                if current != last_status {
                    last_status = current.clone();
                    let message = ServerMessage::Event {
                        event: Event::Status {
                            session_id: session_id.clone(),
                            status: protocol_status(&current),
                        },
                    };
                    if outbound.try_send(&message).is_err() {
                        outbound.close();
                        break;
                    }
                }
            }
            _ = wait_until_set(&mut shutdown) => break,
        }
    }
}

async fn wait_until_set(receiver: &mut watch::Receiver<bool>) {
    if *receiver.borrow() {
        return;
    }
    let _ = receiver.changed().await;
}

fn session_id(value: String) -> std::result::Result<SessionId, ApiError> {
    SessionId::new(value).map_err(map_session_error)
}

fn engine_size(size: TerminalSize) -> std::result::Result<EngineTerminalSize, ApiError> {
    if size.rows == 0 || size.cols == 0 {
        return Err(ApiError::new(
            ErrorCode::InvalidTerminalSize,
            "terminal rows and columns must be non-zero",
        ));
    }
    Ok(EngineTerminalSize::new(size.rows, size.cols)
        .with_pixels(size.pixel_width, size.pixel_height))
}

fn build_spec(request: CreateSession) -> std::result::Result<SessionSpec, ApiError> {
    let id = session_id(request.id)?;
    if request.program.is_empty() {
        return Err(ApiError::new(
            ErrorCode::InvalidProgram,
            "a session program is required",
        ));
    }
    if request.cwd.is_empty() {
        return Err(ApiError::new(
            ErrorCode::MissingWorkingDirectory,
            "a working directory is required",
        ));
    }
    reject_nul("program", &request.program)?;
    for argument in &request.args {
        reject_nul("argument", argument)?;
    }
    reject_nul("working directory", &request.cwd)?;
    for (key, value) in &request.env {
        if key.is_empty() || key.contains('=') || key.contains('\0') {
            return Err(ApiError::invalid_request(
                "environment variable names must be non-empty and contain neither '=' nor NUL",
            ));
        }
        reject_nul("environment value", value)?;
    }
    let size = engine_size(request.size)?;

    let mut spec = SessionSpec::new(id, request.program)
        .args(request.args)
        .cwd(request.cwd)
        .size(size);
    for (key, value) in request.env {
        spec = spec.env(key, value);
    }
    Ok(spec)
}

fn reject_nul(label: &str, value: &str) -> std::result::Result<(), ApiError> {
    if value.contains('\0') {
        Err(ApiError::invalid_request(format!(
            "{label} must not contain NUL"
        )))
    } else {
        Ok(())
    }
}

fn protocol_info(info: &EngineSessionInfo) -> SessionInfo {
    SessionInfo {
        id: info.id.as_str().to_owned(),
        pid: info.pid,
        program: info.program.to_string_lossy().into_owned(),
        cwd: info.cwd.to_string_lossy().into_owned(),
        size: protocol_size(info.size),
        status: protocol_status(&info.status),
    }
}

fn protocol_size(size: EngineTerminalSize) -> TerminalSize {
    TerminalSize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: size.pixel_width,
        pixel_height: size.pixel_height,
    }
}

fn protocol_status(status: &EngineSessionStatus) -> SessionStatus {
    match status {
        EngineSessionStatus::Running => SessionStatus::Running,
        EngineSessionStatus::Exited(exit) => SessionStatus::Exited(protocol_exit(exit)),
    }
}

fn protocol_exit(exit: &EngineSessionExit) -> SessionExit {
    SessionExit {
        success: exit.success(),
        code: exit.code(),
        signal: exit.signal().map(str::to_owned),
    }
}

fn protocol_snapshot(snapshot: &EngineOutputSnapshot) -> director_protocol::api::OutputSnapshot {
    director_protocol::api::OutputSnapshot {
        data: Base64Bytes::new(snapshot.bytes.clone()),
        first_seq: snapshot.first_seq,
        next_seq: snapshot.next_seq,
        truncated: snapshot.truncated,
    }
}

fn daemon_state(state: EngineState) -> DaemonState {
    match state {
        EngineState::Running => DaemonState::Running,
        EngineState::Stopped => DaemonState::Stopped,
    }
}

fn map_engine_error(error: EngineError) -> ApiError {
    match error {
        EngineError::Stopped => ApiError::new(ErrorCode::EngineStopped, "the engine is stopped"),
        EngineError::Session(error) => map_session_error(error),
    }
}

fn map_session_error(error: SessionError) -> ApiError {
    let code = match &error {
        SessionError::InvalidSessionId => ErrorCode::InvalidSessionId,
        SessionError::InvalidProgram => ErrorCode::InvalidProgram,
        SessionError::MissingWorkingDirectory => ErrorCode::MissingWorkingDirectory,
        SessionError::InvalidTerminalSize => ErrorCode::InvalidTerminalSize,
        SessionError::DuplicateSessionId(_) => ErrorCode::DuplicateSession,
        SessionError::SessionNotFound(_) => ErrorCode::SessionNotFound,
        SessionError::SessionClosed(_) => ErrorCode::SessionClosed,
        SessionError::SpawnFailed { .. } => ErrorCode::SpawnFailed,
        SessionError::InputFailed { .. } => ErrorCode::InputFailed,
        SessionError::ResizeFailed { .. } => ErrorCode::ResizeFailed,
        SessionError::TerminationFailed { .. } => ErrorCode::TerminationFailed,
        SessionError::TerminationTimedOut(_) => ErrorCode::TerminationTimedOut,
        SessionError::MissingRuntime | SessionError::TaskFailed(_) => ErrorCode::Internal,
    };
    ApiError::new(code, error.to_string())
}

#[cfg(test)]
mod tests {
    use director_protocol::api::{CreateSession, ErrorCode};

    use super::build_spec;

    fn request() -> CreateSession {
        CreateSession {
            id: "one".into(),
            program: "/bin/sh".into(),
            args: vec!["-c".into(), "true".into()],
            cwd: "/tmp".into(),
            env: Default::default(),
            size: Default::default(),
        }
    }

    #[test]
    fn session_specs_are_validated_before_spawning() {
        assert!(build_spec(request()).is_ok());

        let mut empty_program = request();
        empty_program.program.clear();
        assert_eq!(
            build_spec(empty_program).unwrap_err().code,
            ErrorCode::InvalidProgram
        );

        let mut empty_cwd = request();
        empty_cwd.cwd.clear();
        assert_eq!(
            build_spec(empty_cwd).unwrap_err().code,
            ErrorCode::MissingWorkingDirectory
        );

        let mut bad_env = request();
        bad_env.env.insert("A=B".into(), "value".into());
        assert_eq!(
            build_spec(bad_env).unwrap_err().code,
            ErrorCode::InvalidRequest
        );

        let mut zero_size = request();
        zero_size.size.rows = 0;
        assert_eq!(
            build_spec(zero_size).unwrap_err().code,
            ErrorCode::InvalidTerminalSize
        );
    }
}
