//! Engine lifecycle and PTY-backed sessions, independent of clients, transport,
//! and OS signals.

pub mod session;

use thiserror::Error;

pub use session::{
    OutputChunk, OutputSnapshot, SessionError, SessionExit, SessionHandle, SessionId, SessionInfo,
    SessionManager, SessionSpec, SessionStatus, TerminalSize,
};

/// The lifecycle of the engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineState {
    Running,
    Stopped,
}

#[derive(Debug, Error)]
pub enum EngineError {
    #[error(transparent)]
    Session(#[from] SessionError),
    #[error("the engine is stopped")]
    Stopped,
}

/// Owns the engine lifecycle and its sessions.
pub struct Engine {
    state: EngineState,
    sessions: SessionManager,
}

impl Engine {
    /// Starts an engine without requiring a client or UI.
    pub fn start() -> Self {
        Self {
            state: EngineState::Running,
            sessions: SessionManager::new(),
        }
    }

    pub fn state(&self) -> EngineState {
        self.state
    }

    /// Spawns a PTY-backed session. Requires a Tokio runtime.
    pub fn spawn_session(&mut self, spec: SessionSpec) -> Result<SessionHandle, EngineError> {
        if self.state != EngineState::Running {
            return Err(EngineError::Stopped);
        }
        self.sessions.spawn(spec).map_err(EngineError::from)
    }

    pub fn session(&self, id: &SessionId) -> Option<SessionHandle> {
        self.sessions.get(id)
    }

    pub fn sessions(&self) -> Vec<SessionInfo> {
        self.sessions.list()
    }

    /// Stops the engine and terminates every session. Calling this again is
    /// harmless.
    pub async fn shutdown(&mut self) {
        if self.state == EngineState::Stopped {
            return;
        }
        self.sessions.terminate_all().await;
        self.state = EngineState::Stopped;
    }
}

#[cfg(test)]
mod tests {
    use super::{Engine, EngineState};

    #[tokio::test]
    async fn shutdown_stops_the_engine_and_is_idempotent() {
        let mut engine = Engine::start();
        assert_eq!(engine.state(), EngineState::Running);

        engine.shutdown().await;
        assert_eq!(engine.state(), EngineState::Stopped);

        engine.shutdown().await;
        assert_eq!(engine.state(), EngineState::Stopped);
    }
}
