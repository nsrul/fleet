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

/// Task links, plans, and sidebar presence. Absent on a daemon that predates them.
pub const CAPABILITY_TASKS: &str = "tasks";

/// Daemon-owned tab and split layout. Absent on a daemon that predates it.
pub const CAPABILITY_WORKSPACE: &str = "workspace";

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
    /// Session that started this one. Recorded by the daemon, not the engine.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    /// Task text stored for the parent. It is not written to the terminal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief: Option<String>,
}

/// One resolved step of a plan. The caller has already turned a preset into a program.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanStepSpec {
    pub program: String,
    #[serde(default)]
    pub args: Vec<String>,
    pub cwd: String,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief: Option<String>,
}

/// A plan submitted by a parent session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PutPlan {
    pub parent_id: String,
    pub steps: Vec<PlanStepSpec>,
}

/// Latest sidebar inputs for one session. The app reports these. The daemon does not parse output.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReportPresence {
    pub id: String,
    pub active: bool,
    pub needs_attention: bool,
}

/// The sidebar class for a session. The rules match `AppModel.matches`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SidebarClass {
    Running,
    Idle,
    NeedsYou,
}

/// Where a plan step is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StepState {
    Waiting,
    Running,
    Done,
    Failed,
}

/// Where a plan is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanState {
    Running,
    Done,
    Failed,
}

/// A session the plugin started, joined with daemon status and the sidebar class.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskInfo {
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief: Option<String>,
    pub status: SessionStatus,
    pub sidebar: SidebarClass,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step_index: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step_state: Option<StepState>,
}

/// One step as stored on a plan.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanStepInfo {
    pub index: u32,
    pub state: StepState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief: Option<String>,
}

/// A plan and the steps spawned so far.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanInfo {
    pub id: String,
    pub parent_id: String,
    pub state: PlanState,
    pub steps: Vec<PlanStepInfo>,
}

/// Needs you wins. Otherwise a live session with recent output is Running, and everything else is Idle.
pub fn sidebar_class(status: &SessionStatus, active: bool, needs_attention: bool) -> SidebarClass {
    let failed = matches!(status, SessionStatus::Exited(exit) if !exit.success);
    if needs_attention || failed {
        return SidebarClass::NeedsYou;
    }
    if matches!(status, SessionStatus::Running) && active {
        return SidebarClass::Running;
    }
    SidebarClass::Idle
}

/// Side-by-side panes, or panes stacked on top of each other.
///
/// `Horizontal` places panes in a row. `Vertical` places them in a column.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitAxis {
    Horizontal,
    Vertical,
}

/// One open session inside a pane. A session appears in at most one tab.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceTab {
    pub id: String,
    pub session_id: String,
}

/// Tabs owned by one pane. A pane always has at least one tab once stored.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspacePane {
    pub id: String,
    pub tabs: Vec<WorkspaceTab>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_tab_id: Option<String>,
}

/// The arrangement of open sessions. Terminals are not part of this record.
///
/// Zero panes means nothing is open. One pane has no split. Two panes name a
/// [`SplitAxis`]. The daemon rejects any other shape.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Workspace {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub split: Option<SplitAxis>,
    pub panes: Vec<WorkspacePane>,
    pub focused_pane_id: String,
}

impl Workspace {
    pub fn empty() -> Self {
        Self {
            split: None,
            panes: Vec::new(),
            focused_pane_id: String::new(),
        }
    }
}

/// A command sent by a client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "command", content = "params", rename_all = "snake_case")]
pub enum Command {
    CreateSession(CreateSession),
    ListSessions,
    InspectSession {
        id: String,
    },
    StopSession {
        id: String,
    },
    RemoveSession {
        id: String,
    },
    Input {
        id: String,
        data: Base64Bytes,
    },
    Resize {
        id: String,
        size: TerminalSize,
    },
    AttachSession {
        id: String,
    },
    DetachSession {
        id: String,
    },
    ReportPresence(ReportPresence),
    ListTasks {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        parent_id: Option<String>,
    },
    PutPlan(PutPlan),
    GetPlan {
        id: String,
    },
    GetWorkspace,
    PutWorkspace {
        workspace: Workspace,
    },
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
    Tasks(Vec<TaskInfo>),
    Plan(PlanInfo),
    Workspace(Workspace),
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
    InvalidWorkspace,
    DuplicateWorkspaceTab,
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
    SessionsChanged,
    WorkspaceChanged {
        workspace: Workspace,
    },
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
        SessionStatus, SidebarClass, SplitAxis, TerminalSize, Workspace, WorkspacePane,
        WorkspaceTab, sidebar_class,
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
                parent_id: None,
                brief: None,
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

        let without_task_fields = json!({
            "type": "request",
            "request_id": 7,
            "command": {
                "command": "create_session",
                "params": {
                    "id": "one",
                    "program": "/bin/sh",
                    "args": ["-c", "true"],
                    "cwd": "/tmp"
                }
            }
        });
        let decoded = serde_json::from_value::<ClientMessage>(without_task_fields).unwrap();
        assert_eq!(decoded, request);
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
    fn sidebar_class_matches_the_app_rows() {
        let running = SessionStatus::Running;
        let ok = SessionStatus::Exited(SessionExit {
            success: true,
            code: 0,
            signal: None,
        });
        let failed = SessionStatus::Exited(SessionExit {
            success: false,
            code: 1,
            signal: None,
        });
        assert_eq!(sidebar_class(&running, true, false), SidebarClass::Running);
        assert_eq!(sidebar_class(&running, false, false), SidebarClass::Idle);
        assert_eq!(sidebar_class(&running, true, true), SidebarClass::NeedsYou);
        assert_eq!(sidebar_class(&ok, false, false), SidebarClass::Idle);
        assert_eq!(sidebar_class(&failed, false, false), SidebarClass::NeedsYou);
    }

    #[test]
    fn workspace_messages_round_trip() {
        let workspace = Workspace {
            split: Some(SplitAxis::Horizontal),
            panes: vec![
                WorkspacePane {
                    id: "pane-a".into(),
                    tabs: vec![WorkspaceTab {
                        id: "tab-a".into(),
                        session_id: "one".into(),
                    }],
                    active_tab_id: Some("tab-a".into()),
                },
                WorkspacePane {
                    id: "pane-b".into(),
                    tabs: vec![WorkspaceTab {
                        id: "tab-b".into(),
                        session_id: "two".into(),
                    }],
                    active_tab_id: Some("tab-b".into()),
                },
            ],
            focused_pane_id: "pane-b".into(),
        };
        let command = Command::PutWorkspace {
            workspace: workspace.clone(),
        };
        let encoded = serde_json::to_value(&command).unwrap();
        assert_eq!(encoded["command"], "put_workspace");
        assert_eq!(encoded["params"]["workspace"]["split"], "horizontal");
        assert_eq!(encoded["params"]["workspace"]["focused_pane_id"], "pane-b");
        assert_eq!(serde_json::from_value::<Command>(encoded).unwrap(), command);
        assert_eq!(
            serde_json::to_value(Command::GetWorkspace).unwrap(),
            json!({"command": "get_workspace"})
        );

        let event = Event::WorkspaceChanged {
            workspace: workspace.clone(),
        };
        let encoded = serde_json::to_value(&event).unwrap();
        assert_eq!(encoded["event"], "workspace_changed");
        assert_eq!(serde_json::from_value::<Event>(encoded).unwrap(), event);

        let response = ResponseData::Workspace(Workspace::empty());
        assert_eq!(
            serde_json::to_value(&response).unwrap(),
            json!({"kind": "workspace", "value": {"panes": [], "focused_pane_id": ""}})
        );
        assert_eq!(
            serde_json::to_value(ErrorCode::InvalidWorkspace).unwrap(),
            json!("invalid_workspace")
        );
        assert_eq!(
            serde_json::to_value(ErrorCode::DuplicateWorkspaceTab).unwrap(),
            json!("duplicate_workspace_tab")
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
