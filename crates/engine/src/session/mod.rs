//! PTY-backed agent and shell sessions.

use std::{
    collections::{BTreeMap, HashMap},
    ffi::{OsStr, OsString},
    fmt,
    io::{self, ErrorKind, Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, PoisonError},
    time::Duration,
};

use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtyPair, PtySize, native_pty_system};
use thiserror::Error;
use tokio::{
    sync::{broadcast, mpsc, watch},
    task::JoinSet,
};
use tracing::{debug, warn};

mod output;

use output::{DEFAULT_OUTPUT_LIMIT, OutputState};
pub use output::{OutputChunk, OutputSnapshot};

const READ_BUFFER_SIZE: usize = 8 * 1024;
const OUTPUT_CHANNEL_CAPACITY: usize = 64;
const TERMINATION_GRACE: Duration = Duration::from_millis(250);
const TERMINATION_TIMEOUT: Duration = Duration::from_secs(2);

/// A stable, caller-supplied session identifier.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SessionId(String);

impl SessionId {
    pub fn new(value: impl Into<String>) -> Result<Self, SessionError> {
        let value = value.into();
        if value.is_empty() || value.len() > 128 || value.chars().any(char::is_control) {
            return Err(SessionError::InvalidSessionId);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<&str> for SessionId {
    type Error = SessionError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl TryFrom<String> for SessionId {
    type Error = SessionError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl AsRef<str> for SessionId {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Display for SessionId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// A terminal size in character cells. Rows and columns must be non-zero.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalSize {
    pub rows: u16,
    pub cols: u16,
    pub pixel_width: u16,
    pub pixel_height: u16,
}

impl TerminalSize {
    pub const fn new(rows: u16, cols: u16) -> Self {
        Self {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        }
    }

    pub const fn with_pixels(mut self, pixel_width: u16, pixel_height: u16) -> Self {
        self.pixel_width = pixel_width;
        self.pixel_height = pixel_height;
        self
    }

    fn validate(self) -> Result<(), SessionError> {
        if self.rows == 0 || self.cols == 0 {
            return Err(SessionError::InvalidTerminalSize);
        }
        Ok(())
    }

    fn to_pty_size(self) -> PtySize {
        PtySize {
            rows: self.rows,
            cols: self.cols,
            pixel_width: self.pixel_width,
            pixel_height: self.pixel_height,
        }
    }
}

impl Default for TerminalSize {
    fn default() -> Self {
        Self::new(24, 80)
    }
}

/// How a session ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionExit {
    success: bool,
    code: u32,
    signal: Option<String>,
}

impl SessionExit {
    pub fn success(&self) -> bool {
        self.success
    }

    pub fn code(&self) -> u32 {
        self.code
    }

    pub fn signal(&self) -> Option<&str> {
        self.signal.as_deref()
    }
}

impl From<portable_pty::ExitStatus> for SessionExit {
    fn from(status: portable_pty::ExitStatus) -> Self {
        Self {
            success: status.success(),
            code: status.exit_code(),
            signal: status.signal().map(str::to_owned),
        }
    }
}

/// The current state of a session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionStatus {
    Running,
    Exited(SessionExit),
}

impl SessionStatus {
    pub fn is_running(&self) -> bool {
        matches!(self, Self::Running)
    }

    pub fn exit(&self) -> Option<&SessionExit> {
        match self {
            Self::Running => None,
            Self::Exited(exit) => Some(exit),
        }
    }
}

/// A description of a session to spawn.
#[derive(Debug, Clone)]
pub struct SessionSpec {
    id: SessionId,
    program: OsString,
    args: Vec<OsString>,
    cwd: Option<PathBuf>,
    env: BTreeMap<OsString, OsString>,
    size: TerminalSize,
}

impl SessionSpec {
    pub fn new(id: SessionId, program: impl Into<OsString>) -> Self {
        Self {
            id,
            program: program.into(),
            args: Vec::new(),
            cwd: None,
            env: BTreeMap::new(),
            size: TerminalSize::default(),
        }
    }

    pub fn arg(mut self, arg: impl Into<OsString>) -> Self {
        self.args.push(arg.into());
        self
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    pub fn cwd(mut self, cwd: impl Into<PathBuf>) -> Self {
        self.cwd = Some(cwd.into());
        self
    }

    pub fn env(mut self, key: impl Into<OsString>, value: impl Into<OsString>) -> Self {
        self.env.insert(key.into(), value.into());
        self
    }

    pub fn size(mut self, size: TerminalSize) -> Self {
        self.size = size;
        self
    }

    pub fn id(&self) -> &SessionId {
        &self.id
    }

    pub fn program(&self) -> &OsStr {
        &self.program
    }

    pub fn args_ref(&self) -> &[OsString] {
        &self.args
    }

    pub fn working_directory(&self) -> Option<&Path> {
        self.cwd.as_deref()
    }

    pub fn environment(&self) -> &BTreeMap<OsString, OsString> {
        &self.env
    }

    pub fn terminal_size(&self) -> TerminalSize {
        self.size
    }
}

/// A snapshot of session metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionInfo {
    pub id: SessionId,
    pub pid: Option<u32>,
    pub program: OsString,
    /// Arguments after the program, as they were requested at spawn.
    pub args: Vec<OsString>,
    pub cwd: PathBuf,
    /// Environment variables requested at spawn. Inherited variables are not
    /// listed.
    pub env: BTreeMap<OsString, OsString>,
    pub size: TerminalSize,
    pub status: SessionStatus,
}

#[derive(Debug, Error)]
pub enum SessionError {
    #[error("session IDs must be 1 to 128 bytes and contain no control characters")]
    InvalidSessionId,
    #[error("a session program is required")]
    InvalidProgram,
    #[error("a working directory is required")]
    MissingWorkingDirectory,
    #[error("terminal rows and columns must be non-zero")]
    InvalidTerminalSize,
    #[error("session {0:?} already exists")]
    DuplicateSessionId(String),
    #[error("session {0:?} was not found")]
    SessionNotFound(String),
    #[error("session {0:?} has already exited")]
    SessionClosed(String),
    #[error("session {0:?} is still running")]
    SessionRunning(String),
    #[error("session {id:?} failed to spawn: {source}")]
    SpawnFailed {
        id: String,
        #[source]
        source: anyhow::Error,
    },
    #[error("failed to write to session {id:?}: {source}")]
    InputFailed {
        id: String,
        #[source]
        source: io::Error,
    },
    #[error("failed to resize session {id:?}: {source}")]
    ResizeFailed {
        id: String,
        #[source]
        source: anyhow::Error,
    },
    #[error("failed to terminate session {id:?}: {source}")]
    TerminationFailed {
        id: String,
        #[source]
        source: io::Error,
    },
    #[error("session {0:?} did not exit before the termination deadline")]
    TerminationTimedOut(String),
    #[error("session operations require a Tokio runtime")]
    MissingRuntime,
    #[error("session worker task failed: {0}")]
    TaskFailed(String),
}

/// A cloneable handle for interacting with one live or exited session.
#[derive(Clone)]
pub struct SessionHandle {
    inner: Arc<SessionInner>,
}

impl fmt::Debug for SessionHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SessionHandle")
            .field("id", &self.id())
            .field("pid", &self.pid())
            .field("status", &self.status())
            .finish_non_exhaustive()
    }
}

impl SessionHandle {
    pub fn id(&self) -> &SessionId {
        &self.inner.id
    }

    pub fn pid(&self) -> Option<u32> {
        self.inner.pid
    }

    pub fn status(&self) -> SessionStatus {
        self.inner.status.borrow().clone()
    }

    pub fn status_changes(&self) -> watch::Receiver<SessionStatus> {
        self.inner.status.subscribe()
    }

    pub fn subscribe_output(&self) -> broadcast::Receiver<OutputChunk> {
        self.inner.output.subscribe()
    }

    pub fn output_snapshot(&self) -> OutputSnapshot {
        self.inner.output.snapshot()
    }

    pub fn info(&self) -> SessionInfo {
        SessionInfo {
            id: self.inner.id.clone(),
            pid: self.inner.pid,
            program: self.inner.program.clone(),
            args: self.inner.args.clone(),
            cwd: self.inner.cwd.clone(),
            env: self.inner.env.clone(),
            size: *self
                .inner
                .size
                .lock()
                .unwrap_or_else(PoisonError::into_inner),
            status: self.status(),
        }
    }

    /// Writes raw bytes to the session's terminal.
    pub async fn input(&self, bytes: &[u8]) -> Result<(), SessionError> {
        if !self.status().is_running() {
            return Err(SessionError::SessionClosed(self.id().to_string()));
        }
        if bytes.is_empty() {
            return Ok(());
        }

        let inner = Arc::clone(&self.inner);
        let bytes = bytes.to_vec();
        tokio::task::spawn_blocking(move || {
            let mut writer = inner.writer.lock().unwrap_or_else(PoisonError::into_inner);
            writer
                .write_all(&bytes)
                .map_err(|source| SessionError::InputFailed {
                    id: inner.id.to_string(),
                    source,
                })?;
            writer.flush().map_err(|source| SessionError::InputFailed {
                id: inner.id.to_string(),
                source,
            })
        })
        .await
        .map_err(|error| SessionError::TaskFailed(error.to_string()))?
    }

    /// Resizes the terminal and notifies the child process.
    pub fn resize(&self, size: TerminalSize) -> Result<(), SessionError> {
        size.validate()?;
        if !self.status().is_running() {
            return Err(SessionError::SessionClosed(self.id().to_string()));
        }

        let master = self
            .inner
            .master
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        master
            .resize(size.to_pty_size())
            .map_err(|source| SessionError::ResizeFailed {
                id: self.id().to_string(),
                source,
            })?;
        *self
            .inner
            .size
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = size;
        Ok(())
    }

    /// Terminates the process group and waits for the recorded exit.
    ///
    /// Calling this after the session has exited returns the recorded status.
    pub async fn terminate(&self) -> Result<SessionExit, SessionError> {
        if let Some(exit) = self.status().exit().cloned() {
            return Ok(exit);
        }

        self.signal_termination(false)?;
        if let Some(exit) = self.wait_for_exit(TERMINATION_GRACE).await {
            return Ok(exit);
        }

        self.signal_termination(true)?;
        self.wait_for_exit(TERMINATION_TIMEOUT)
            .await
            .ok_or_else(|| SessionError::TerminationTimedOut(self.id().to_string()))
    }

    /// Waits until the child process has exited.
    pub async fn wait(&self) -> SessionExit {
        let mut status = self.inner.status.subscribe();
        if let Some(exit) = status.borrow().exit().cloned() {
            return exit;
        }

        let status = status
            .wait_for(|status| matches!(status, SessionStatus::Exited(_)))
            .await
            .expect("the session handle keeps the status sender alive");
        match &*status {
            SessionStatus::Exited(exit) => exit.clone(),
            SessionStatus::Running => unreachable!("wait_for only returns exited states"),
        }
    }

    async fn wait_for_exit(&self, timeout: Duration) -> Option<SessionExit> {
        let mut status = self.inner.status.subscribe();
        if let Some(exit) = status.borrow().exit().cloned() {
            return Some(exit);
        }

        tokio::time::timeout(
            timeout,
            status.wait_for(|status| matches!(status, SessionStatus::Exited(_))),
        )
        .await
        .ok()
        .and_then(Result::ok)
        .and_then(|status| status.exit().cloned())
    }

    #[cfg(unix)]
    fn signal_termination(&self, force: bool) -> Result<(), SessionError> {
        let signal = if force { libc::SIGKILL } else { libc::SIGTERM };
        let mut delivered = false;
        let mut last_error = None;

        let process_group = {
            let master = self
                .inner
                .master
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            master.process_group_leader()
        };
        if let Some(process_group) = process_group {
            match signal_process(-process_group, signal) {
                Ok(()) => delivered = true,
                Err(error) => last_error = Some(error),
            }
        }

        if let Some(pid) = self.inner.pid {
            match signal_process(pid as libc::pid_t, signal) {
                Ok(()) => delivered = true,
                Err(error) => last_error = Some(error),
            }
        }

        if delivered {
            return Ok(());
        }
        if let Some(source) = last_error {
            return Err(SessionError::TerminationFailed {
                id: self.id().to_string(),
                source,
            });
        }

        let mut killer = self
            .inner
            .killer
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        killer
            .kill()
            .map_err(|source| SessionError::TerminationFailed {
                id: self.id().to_string(),
                source,
            })
    }

    #[cfg(not(unix))]
    fn signal_termination(&self, _force: bool) -> Result<(), SessionError> {
        let mut killer = self
            .inner
            .killer
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        killer
            .kill()
            .map_err(|source| SessionError::TerminationFailed {
                id: self.id().to_string(),
                source,
            })
    }
}

#[cfg(unix)]
fn signal_process(process: libc::pid_t, signal: libc::c_int) -> io::Result<()> {
    // SAFETY: kill is called with a plain integer process or process-group ID.
    // An invalid or already-exited target returns ESRCH, which is treated as
    // successful termination below.
    let result = unsafe { libc::kill(process, signal) };
    if result == 0 {
        return Ok(());
    }

    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(())
    } else {
        Err(error)
    }
}

struct SessionInner {
    id: SessionId,
    pid: Option<u32>,
    program: OsString,
    args: Vec<OsString>,
    cwd: PathBuf,
    env: BTreeMap<OsString, OsString>,
    size: Mutex<TerminalSize>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    status: watch::Sender<SessionStatus>,
    output: Arc<OutputState>,
}

impl Drop for SessionInner {
    fn drop(&mut self) {
        if !self.status.borrow().is_running() {
            return;
        }

        #[cfg(unix)]
        {
            let process_group = self
                .master
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .process_group_leader();
            if let Some(process_group) = process_group {
                // SAFETY: best-effort cleanup of a process group that this
                // session still owns. The child has not been reaped yet.
                let _ = unsafe { libc::kill(-process_group, libc::SIGTERM) };
            }
            if let Some(pid) = self.pid {
                // SAFETY: best-effort cleanup of the still-owned direct child.
                let _ = unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
            }
        }

        #[cfg(not(unix))]
        {
            if let Ok(mut killer) = self.killer.lock() {
                let _ = killer.kill();
            }
        }
    }
}

/// Owns all sessions created by an engine.
#[derive(Debug, Default)]
pub struct SessionManager {
    sessions: HashMap<SessionId, SessionHandle>,
}

impl SessionManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn spawn(&mut self, spec: SessionSpec) -> Result<SessionHandle, SessionError> {
        if self.sessions.contains_key(spec.id()) {
            return Err(SessionError::DuplicateSessionId(spec.id().to_string()));
        }

        let handle = spawn_session(spec)?;
        self.sessions.insert(handle.id().clone(), handle.clone());
        Ok(handle)
    }

    pub fn get(&self, id: &SessionId) -> Option<SessionHandle> {
        self.sessions.get(id).cloned()
    }

    /// Forgets an exited session so its ID can be reused.
    pub fn remove(&mut self, id: &SessionId) -> Result<SessionInfo, SessionError> {
        let Some(handle) = self.sessions.get(id) else {
            return Err(SessionError::SessionNotFound(id.to_string()));
        };
        let info = handle.info();
        if info.status.is_running() {
            return Err(SessionError::SessionRunning(id.to_string()));
        }
        self.sessions.remove(id);
        Ok(info)
    }

    pub fn list(&self) -> Vec<SessionInfo> {
        let mut sessions: Vec<_> = self.sessions.values().map(SessionHandle::info).collect();
        sessions.sort_by(|left, right| left.id.as_str().cmp(right.id.as_str()));
        sessions
    }

    pub fn is_empty(&self) -> bool {
        self.sessions.is_empty()
    }

    pub async fn terminate_all(&mut self) {
        let handles: Vec<_> = self.sessions.drain().map(|(_, handle)| handle).collect();
        let mut tasks = JoinSet::new();
        for handle in handles {
            let id = handle.id().to_string();
            tasks.spawn(async move { (id, handle.terminate().await) });
        }

        while let Some(result) = tasks.join_next().await {
            match result {
                Ok((id, Ok(_))) => {
                    debug!(session_id = %id, event = "session_terminated");
                }
                Ok((id, Err(error))) => {
                    warn!(
                        session_id = %id,
                        error = %error,
                        event = "session_terminate_failed",
                    );
                }
                Err(error) => {
                    warn!(error = %error, event = "session_terminate_task_failed");
                }
            }
        }
    }
}

fn spawn_session(spec: SessionSpec) -> Result<SessionHandle, SessionError> {
    let id = spec.id;
    let id_string = id.to_string();
    let cwd = spec.cwd.ok_or(SessionError::MissingWorkingDirectory)?;
    if spec.program.is_empty() {
        return Err(SessionError::InvalidProgram);
    }
    spec.size.validate()?;
    if tokio::runtime::Handle::try_current().is_err() {
        return Err(SessionError::MissingRuntime);
    }

    let pty_system = native_pty_system();
    let PtyPair { master, slave } =
        pty_system
            .openpty(spec.size.to_pty_size())
            .map_err(|source| SessionError::SpawnFailed {
                id: id_string.clone(),
                source,
            })?;

    let reader = master
        .try_clone_reader()
        .map_err(|source| SessionError::SpawnFailed {
            id: id_string.clone(),
            source,
        })?;
    let writer = master
        .take_writer()
        .map_err(|source| SessionError::SpawnFailed {
            id: id_string.clone(),
            source,
        })?;

    let mut command = CommandBuilder::new(&spec.program);
    command.args(&spec.args);
    command.cwd(&cwd);
    for (key, value) in &spec.env {
        command.env(key, value);
    }
    if command.get_env("TERM").is_none() {
        command.env("TERM", "xterm-256color");
    }

    let mut child = slave
        .spawn_command(command)
        .map_err(|source| SessionError::SpawnFailed {
            id: id_string.clone(),
            source,
        })?;
    drop(slave);

    let pid = child.process_id();
    let killer = child.clone_killer();
    let (status, _) = watch::channel(SessionStatus::Running);
    let (output_sender, output_receiver) = mpsc::channel(OUTPUT_CHANNEL_CAPACITY);
    let output = Arc::new(OutputState::new(DEFAULT_OUTPUT_LIMIT));

    let reader_id = id_string.clone();
    std::mem::drop(tokio::task::spawn_blocking(move || {
        read_output(reader, output_sender, reader_id);
    }));

    let pump_output = Arc::clone(&output);
    std::mem::drop(tokio::spawn(async move {
        pump_output_until_closed(output_receiver, pump_output).await;
    }));

    let exit_status = status.clone();
    let exit_id = id_string.clone();
    std::mem::drop(tokio::spawn(async move {
        match tokio::task::spawn_blocking(move || child.wait()).await {
            Ok(Ok(exit)) => {
                exit_status.send_replace(SessionStatus::Exited(exit.into()));
            }
            Ok(Err(error)) => {
                warn!(session_id = %exit_id, error = %error, event = "session_wait_failed");
            }
            Err(error) => {
                warn!(session_id = %exit_id, error = %error, event = "session_wait_task_failed");
            }
        }
    }));

    Ok(SessionHandle {
        inner: Arc::new(SessionInner {
            id,
            pid,
            program: spec.program,
            args: spec.args,
            cwd,
            env: spec.env,
            size: Mutex::new(spec.size),
            master: Mutex::new(master),
            writer: Mutex::new(writer),
            killer: Mutex::new(killer),
            status,
            output,
        }),
    })
}

fn read_output(
    mut reader: Box<dyn Read + Send>,
    sender: mpsc::Sender<Vec<u8>>,
    session_id: String,
) {
    let mut buffer = [0_u8; READ_BUFFER_SIZE];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                if sender.blocking_send(buffer[..read].to_vec()).is_err() {
                    break;
                }
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(error) if is_end_of_output(&error) => break,
            Err(error) => {
                debug!(session_id = %session_id, error = %error, event = "session_read_failed");
                break;
            }
        }
    }
}

async fn pump_output_until_closed(mut receiver: mpsc::Receiver<Vec<u8>>, output: Arc<OutputState>) {
    while let Some(bytes) = receiver.recv().await {
        output.push(bytes);
    }
}

fn is_end_of_output(error: &io::Error) -> bool {
    if matches!(
        error.kind(),
        ErrorKind::BrokenPipe | ErrorKind::ConnectionReset | ErrorKind::UnexpectedEof
    ) {
        return true;
    }

    #[cfg(unix)]
    {
        error.raw_os_error() == Some(libc::EIO)
    }
    #[cfg(not(unix))]
    {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_ids_are_validated() {
        assert!(SessionId::new("one").is_ok());
        assert!(SessionId::new("").is_err());
        assert!(SessionId::new("bad\nid").is_err());
        assert!(SessionId::new("x".repeat(129)).is_err());
    }

    #[test]
    fn terminal_sizes_require_rows_and_columns() {
        assert!(TerminalSize::new(24, 80).validate().is_ok());
        assert!(TerminalSize::new(0, 80).validate().is_err());
        assert!(TerminalSize::new(24, 0).validate().is_err());
    }

    #[test]
    fn exit_status_is_normalized() {
        let exit = SessionExit::from(portable_pty::ExitStatus::with_exit_code(7));
        assert!(!exit.success());
        assert_eq!(exit.code(), 7);
        assert_eq!(exit.signal(), None);
    }
}
