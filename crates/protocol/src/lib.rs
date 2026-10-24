//! Shared daemon version, lifecycle state, and local API vocabulary.

pub mod api;

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;

/// Stable state names used by daemon lifecycle logs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DaemonState {
    Running,
    Stopped,
}

impl DaemonState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Stopped => "stopped",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{DaemonState, PROTOCOL_VERSION};

    #[test]
    fn state_names_match_logs_and_round_trip_as_json() {
        for (state, name) in [
            (DaemonState::Running, "running"),
            (DaemonState::Stopped, "stopped"),
        ] {
            let json = serde_json::to_value(state).unwrap();
            assert_eq!(json, name);
            assert_eq!(state.as_str(), name);
            assert_eq!(serde_json::from_value::<DaemonState>(json).unwrap(), state);
        }
    }

    #[test]
    fn version_one_rejects_unknown_states() {
        assert_eq!(PROTOCOL_VERSION, 1);
        assert!(serde_json::from_str::<DaemonState>("\"unknown\"").is_err());
    }
}
