//! Engine lifecycle, independent of clients, transport, and OS signals.

/// The lifecycle of the currently empty engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineState {
    Running,
    Stopped,
}

/// Owns the engine lifecycle. Agent sessions are not implemented yet.
pub struct Engine {
    state: EngineState,
}

impl Engine {
    /// Starts an empty engine without requiring a client or UI.
    pub fn start() -> Self {
        Self {
            state: EngineState::Running,
        }
    }

    pub fn state(&self) -> EngineState {
        self.state
    }

    /// Stops the engine. Calling this again is harmless.
    pub async fn shutdown(&mut self) {
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
