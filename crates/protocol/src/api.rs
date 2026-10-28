//! Versioned vocabulary for the local session API.
//!
//! This module defines messages only. Framing and transport belong to the
//! daemon. All binary payloads are base64-encoded strings so frames remain
//! valid UTF-8 JSON.

use std::collections::BTreeMap;
use std::fmt;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::DaemonState;

/// Largest accepted or emitted frame, including the four-byte length prefix.
pub const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;

/// Largest input payload accepted in a single request.
pub const MAX_INPUT_BYTES: usize = 1024 * 1024;

/// Capabilities a daemon can advertise in its welcome message.
pub const CAPABILITY_REMOVE_SESSION: &str = "remove_session";

/// Opaque bytes encoded as a base64 string on the wire.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Base64Bytes(Vec<u8>);

impl Base64Bytes {
    pub fn new(bytes: impl Into<Vec<u8>>) -> Self {
        Self(bytes.into())
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.0
    }

    pub fn into_vec(self) -> Vec<u8> {
        self.0
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl From<Vec<u8>> for Base64Bytes {
    fn from(bytes: Vec<u8>) -> Self {
        Self(bytes)
    }
}

impl Serialize for Base64Bytes {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&STANDARD.encode(&self.0))
    }
}

impl<'de> Deserialize<'de> for Base64Bytes {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        STANDARD
            .decode(encoded.as_bytes())
            .map(Self)
            .map_err(serde::de::Error::custom)
    }
}

/// A terminal size in character cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalSize {
    pub rows: u16,
    pub cols: u16,
    #[serde(default)]
    pub pixel_width: u16,
    #[serde(default)]
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
}

impl Default for TerminalSize {
    fn default() -> Self {
        Self::new(24, 80)
    }
}

/// Parameters for creating a PTY-backed session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateSession {
    pub id: String,
    pub program: String,
    #[serde(default)]
    pub args: Vec<String>,
    pub cwd: String,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub size: TerminalSize,
}

/// A command sent by a client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "command", content = "params", rename_all = "snake_case")]
pub enum Command {
    CreateSession(CreateSession),
    ListSessions,
    InspectSession { id: String },
    StopSession { id: String },
    RemoveSession { id: String },
    Input { id: String, data: Base64Bytes },
    Resize { id: String, size: TerminalSize },
    AttachSession { id: String },
    DetachSession { id: String },
}

/// A message sent from a client to the daemon.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello {
        protocol_version: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        client: Option<String>,
    },
    Request {
        request_id: u64,
        command: Command,
    },
}

/// How a session ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionExit {
    pub success: bool,
    pub code: u32,
    pub signal: Option<String>,
}

/// The current state of a session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Running,
    Exited(SessionExit),
}

/// A snapshot of session metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub pid: Option<u32>,
    pub program: String,
    pub cwd: String,
    pub size: TerminalSize,
    pub status: SessionStatus,
}

/// A point-in-time view of retained output.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputSnapshot {
    pub data: Base64Bytes,
    pub first_seq: Option<u64>,
    pub next_seq: u64,
    pub truncated: bool,
}

/// Session metadata plus the output retained when the client attached.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachedSession {
    pub session: SessionInfo,
    pub output: OutputSnapshot,
}

/// The success payload for a request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum ResponseData {
    Session(SessionInfo),
    Sessions(Vec<SessionInfo>),
    Exit(SessionExit),
    Attached(AttachedSession),
    Acknowledged,
}

/// A request outcome.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", content = "data", rename_all = "snake_case")]
pub enum ResponseResult {
    Ok(ResponseData),
    Error(ApiError),
}

/// Stable machine-readable error categories.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    UnsupportedProtocol,
    HandshakeRequired,
    HandshakeTimeout,
    InvalidMessage,
    InvalidRequest,
    InvalidSessionId,
    DuplicateSession,
    SessionNotFound,
    SessionClosed,
    SessionRunning,
    AlreadyAttached,
    NotAttached,
    InvalidProgram,
    MissingWorkingDirectory,
    InvalidTerminalSize,
    SpawnFailed,
    InputFailed,
    ResizeFailed,
    TerminationFailed,
    TerminationTimedOut,
    EngineStopped,
    SlowClient,
    Internal,
}

/// A clear error returned to a client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiError {
    pub code: ErrorCode,
    pub message: String,
}

impl ApiError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn invalid_request(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::InvalidRequest, message)
    }
}

impl fmt::Display for ApiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:?}: {}", self.code, self.message)
    }
}

impl std::error::Error for ApiError {}

/// An event streamed after a client attaches to a session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    Output {
        session_id: String,
        seq: u64,
        data: Base64Bytes,
    },
    Status {
        session_id: String,
        status: SessionStatus,
    },
    DaemonStopping,
}

/// A message sent from the daemon to a client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Welcome {
        protocol_version: u32,
        daemon_version: String,
        engine_state: DaemonState,
        #[serde(default)]
        capabilities: Vec<String>,
    },
    Rejected {
        error: ApiError,
    },
    Response {
        request_id: u64,
        result: ResponseResult,
    },
    Event {
        event: Event,
    },
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        Base64Bytes, CAPABILITY_REMOVE_SESSION, ClientMessage, Command, CreateSession, ErrorCode,
        Event, ResponseData, ResponseResult, ServerMessage, SessionExit, SessionInfo,
        SessionStatus, TerminalSize,
    };
    use crate::{DaemonState, PROTOCOL_VERSION};

    #[test]
    fn hello_and_requests_round_trip() {
        let hello = ClientMessage::Hello {
            protocol_version: PROTOCOL_VERSION,
            client: Some("test".into()),
        };
        assert_eq!(
            serde_json::to_value(&hello).unwrap(),
            json!({"type": "hello", "protocol_version": 1, "client": "test"})
        );
        assert_eq!(
            serde_json::from_value::<ClientMessage>(serde_json::to_value(&hello).unwrap()).unwrap(),
            hello
        );

        let request = ClientMessage::Request {
            request_id: 7,
            command: Command::CreateSession(CreateSession {
                id: "one".into(),
                program: "/bin/sh".into(),
                args: vec!["-c".into(), "true".into()],
                cwd: "/tmp".into(),
                env: Default::default(),
                size: TerminalSize::new(24, 80),
            }),
        };
        let encoded = serde_json::to_value(&request).unwrap();
        assert_eq!(encoded["type"], "request");
        assert_eq!(encoded["request_id"], 7);
        assert_eq!(encoded["command"]["command"], "create_session");
        assert_eq!(encoded["command"]["params"]["id"], "one");
        assert_eq!(
            serde_json::from_value::<ClientMessage>(encoded).unwrap(),
            request
        );
    }

    #[test]
    fn unit_commands_have_a_stable_shape() {
        assert_eq!(
            serde_json::to_value(Command::ListSessions).unwrap(),
            json!({"command": "list_sessions"})
        );
        assert_eq!(
            serde_json::to_value(Command::InspectSession { id: "one".into() }).unwrap(),
            json!({"command": "inspect_session", "params": {"id": "one"}})
        );
        assert_eq!(
            serde_json::to_value(Command::RemoveSession { id: "one".into() }).unwrap(),
            json!({"command": "remove_session", "params": {"id": "one"}})
        );
    }

    #[test]
    fn output_and_status_events_round_trip() {
        let event = Event::Output {
            session_id: "one".into(),
            seq: 3,
            data: Base64Bytes::new(b"hello".to_vec()),
        };
        assert_eq!(
            serde_json::to_value(&event).unwrap(),
            json!({
                "event": "output",
                "session_id": "one",
                "seq": 3,
                "data": "aGVsbG8=",
            })
        );

        let status = Event::Status {
            session_id: "one".into(),
            status: SessionStatus::Exited(SessionExit {
                success: true,
                code: 0,
                signal: None,
            }),
        };
        assert_eq!(
            serde_json::to_value(&status).unwrap(),
            json!({
                "event": "status",
                "session_id": "one",
                "status": {"exited": {"success": true, "code": 0, "signal": null}},
            })
        );
    }

    #[test]
    fn responses_and_errors_round_trip() {
        let response = ServerMessage::Response {
            request_id: 9,
            result: ResponseResult::Ok(ResponseData::Session(SessionInfo {
                id: "one".into(),
                pid: Some(42),
                program: "/bin/sh".into(),
                cwd: "/tmp".into(),
                size: TerminalSize::new(24, 80),
                status: SessionStatus::Running,
            })),
        };
        let encoded = serde_json::to_value(&response).unwrap();
        assert_eq!(encoded["type"], "response");
        assert_eq!(encoded["result"]["status"], "ok");
        assert_eq!(encoded["result"]["data"]["kind"], "session");
        assert_eq!(
            serde_json::from_value::<ServerMessage>(encoded).unwrap(),
            response
        );

        let rejected = ServerMessage::Rejected {
            error: super::ApiError::new(ErrorCode::UnsupportedProtocol, "protocol mismatch"),
        };
        assert_eq!(
            serde_json::to_value(&rejected).unwrap(),
            json!({
                "type": "rejected",
                "error": {"code": "unsupported_protocol", "message": "protocol mismatch"},
            })
        );
    }

    #[test]
    fn welcome_reports_engine_state() {
        let welcome = ServerMessage::Welcome {
            protocol_version: PROTOCOL_VERSION,
            daemon_version: "0.1.0".into(),
            engine_state: DaemonState::Running,
            capabilities: vec![CAPABILITY_REMOVE_SESSION.into()],
        };
        assert_eq!(
            serde_json::to_value(&welcome).unwrap(),
            json!({
                "type": "welcome",
                "protocol_version": 1,
                "daemon_version": "0.1.0",
                "engine_state": "running",
                "capabilities": ["remove_session"],
            })
        );
    }

    #[test]
    fn invalid_base64_is_rejected() {
        let encoded = json!({
            "event": "output",
            "session_id": "one",
            "seq": 0,
            "data": "not base64!",
        });
        assert!(serde_json::from_value::<Event>(encoded).is_err());
    }
}
