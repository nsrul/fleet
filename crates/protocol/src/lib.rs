//! Shared daemon version, lifecycle state, and local API vocabulary.

pub mod api;

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;

/// FNV-1a 64-bit fingerprint, as 16 lowercase hex digits.
///
/// The daemon hashes its executable once at startup and sends the result on
/// welcome. The Mac app hashes the binary it would launch and replaces the
/// listening process when the two differ. A later read of an overwritten
/// path would hide that the process is still the previous build.
pub fn fnv1a64(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{hash:016x}")
}

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
    use super::{DaemonState, PROTOCOL_VERSION, fnv1a64};

    #[test]
    fn fnv1a64_matches_the_macos_client() {
        assert_eq!(fnv1a64(b""), "cbf29ce484222325");
        assert_eq!(fnv1a64(b"fleet"), "f775f8a97470ae4f");
    }

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
