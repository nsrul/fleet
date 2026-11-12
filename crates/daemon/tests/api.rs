#![cfg(unix)]

mod support;

use std::{
    collections::{BTreeMap, VecDeque},
    io,
    os::unix::fs::{FileTypeExt, PermissionsExt},
    path::Path,
    time::{Duration, Instant},
};

use fleet_protocol::{
    PROTOCOL_VERSION,
    api::{
        ApiError, AttachedSession, Base64Bytes, ClientMessage, Command, CreateSession, ErrorCode,
        Event, MAX_FRAME_BYTES, MAX_INPUT_BYTES, OutputSnapshot, PlanInfo, PlanState, PlanStepSpec,
        PutPlan, ResponseData, ServerMessage, SessionExit, SessionInfo, SessionStatus,
        SidebarClass, SplitAxis, StepState, TerminalSize, Workspace, WorkspacePane, WorkspaceTab,
    },
};
use support::{Daemon, WAIT_LIMIT};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
};

struct Client {
    stream: UnixStream,
    next_request_id: u64,
    events: VecDeque<Event>,
}

impl Client {
    async fn connect(path: &Path) -> Self {
        let stream = tokio::time::timeout(WAIT_LIMIT, UnixStream::connect(path))
            .await
            .expect("connect before the deadline")
            .expect("connect to the daemon socket");
        Self {
            stream,
            next_request_id: 1,
            events: VecDeque::new(),
        }
    }

    async fn hello(&mut self) {
        self.send(ClientMessage::Hello {
            protocol_version: PROTOCOL_VERSION,
            client: Some("test".into()),
        })
        .await;
        match self.receive().await {
            ServerMessage::Welcome {
                protocol_version,
                engine_state,
                capabilities,
                ..
            } => {
                assert_eq!(protocol_version, PROTOCOL_VERSION);
                assert_eq!(engine_state, fleet_protocol::DaemonState::Running);
                assert!(
                    capabilities
                        .iter()
                        .any(|capability| capability
                            == fleet_protocol::api::CAPABILITY_REMOVE_SESSION)
                );
                assert!(
                    capabilities
                        .iter()
                        .any(|capability| capability == fleet_protocol::api::CAPABILITY_TASKS)
                );
                assert!(
                    capabilities
                        .iter()
                        .any(|capability| capability == fleet_protocol::api::CAPABILITY_WORKSPACE)
                );
            }
            other => panic!("expected a welcome, got {other:?}"),
        }
    }

    async fn send(&mut self, message: ClientMessage) {
        let payload = serde_json::to_vec(&message).unwrap();
        self.write_frame(&payload).await;
    }

    async fn write_frame(&mut self, payload: &[u8]) {
        let length = u32::try_from(payload.len()).unwrap();
        self.stream.write_all(&length.to_be_bytes()).await.unwrap();
        self.stream.write_all(payload).await.unwrap();
    }

    async fn send_length(&mut self, length: u32) {
        self.stream.write_all(&length.to_be_bytes()).await.unwrap();
    }

    async fn try_receive(&mut self) -> io::Result<Option<ServerMessage>> {
        let mut header = [0_u8; 4];
        if self.stream.read(&mut header[..1]).await? == 0 {
            return Ok(None);
        }
        self.stream.read_exact(&mut header[1..]).await?;
        let length = u32::from_be_bytes(header) as usize;
        assert!(length <= 8 * 1024 * 1024, "unexpectedly large test frame");
        let mut payload = vec![0_u8; length];
        self.stream.read_exact(&mut payload).await?;
        Ok(Some(
            serde_json::from_slice(&payload).expect("decode a daemon message"),
        ))
    }

    async fn receive(&mut self) -> ServerMessage {
        tokio::time::timeout(WAIT_LIMIT, self.try_receive())
            .await
            .expect("receive a daemon message before the deadline")
            .expect("read a daemon message")
            .expect("the daemon closed the connection")
    }

    async fn request(&mut self, command: Command) -> Result<ResponseData, ApiError> {
        let request_id = self.next_request_id;
        self.next_request_id += 1;
        self.send(ClientMessage::Request {
            request_id,
            command,
        })
        .await;

        let deadline = Instant::now() + WAIT_LIMIT;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            assert!(!remaining.is_zero(), "timed out waiting for a response");
            let message = tokio::time::timeout(remaining, self.try_receive())
                .await
                .expect("receive a response before the deadline")
                .expect("read a response")
                .expect("the daemon closed before replying");
            match message {
                ServerMessage::Response {
                    request_id: received,
                    result,
                } if received == request_id => {
                    return match result {
                        fleet_protocol::api::ResponseResult::Ok(data) => Ok(data),
                        fleet_protocol::api::ResponseResult::Error(error) => Err(error),
                    };
                }
                ServerMessage::Event { event } => self.events.push_back(event),
                other => panic!("unexpected message while awaiting a response: {other:?}"),
            }
        }
    }

    async fn next_event(&mut self) -> Event {
        if let Some(event) = self.events.pop_front() {
            return event;
        }
        tokio::time::timeout(WAIT_LIMIT, self.try_receive())
            .await
            .expect("receive an event before the deadline")
            .expect("read an event")
            .map(|message| match message {
                ServerMessage::Event { event } => event,
                other => panic!("unexpected message while awaiting an event: {other:?}"),
            })
            .expect("the daemon closed before sending the expected event")
    }

    async fn expect_closed(&mut self) {
        let mut byte = [0_u8; 1];
        let read = tokio::time::timeout(WAIT_LIMIT, self.stream.read(&mut byte))
            .await
            .expect("the daemon did not close the connection");
        assert!(
            matches!(read, Ok(0) | Err(_)),
            "expected a closed connection, got {read:?}"
        );
    }
}

struct Output {
    bytes: Vec<u8>,
    next_seq: u64,
}

impl Output {
    fn from_snapshot(snapshot: &OutputSnapshot) -> Self {
        Self {
            bytes: snapshot.data.as_slice().to_vec(),
            next_seq: snapshot.next_seq,
        }
    }

    fn apply(&mut self, event: &Event) {
        if let Event::Output { seq, data, .. } = event {
            assert_eq!(*seq, self.next_seq, "output sequence gap");
            self.next_seq += 1;
            self.bytes.extend_from_slice(data.as_slice());
        }
    }

    fn text(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }
}

fn create_session(id: &str, script: &str) -> Command {
    Command::CreateSession(CreateSession {
        id: id.into(),
        program: "/bin/sh".into(),
        args: vec!["-c".into(), script.into()],
        cwd: std::env::current_dir()
            .unwrap()
            .to_string_lossy()
            .into_owned(),
        env: BTreeMap::new(),
        size: TerminalSize::new(24, 80),
        parent_id: None,
        brief: None,
    })
}

fn expect_session(data: ResponseData) -> SessionInfo {
    match data {
        ResponseData::Session(info) => info,
        other => panic!("expected a session, got {other:?}"),
    }
}

fn expect_exit(data: ResponseData) -> SessionExit {
    match data {
        ResponseData::Exit(exit) => exit,
        other => panic!("expected an exit, got {other:?}"),
    }
}

async fn attach(client: &mut Client, id: &str) -> (AttachedSession, Output) {
    let data = client
        .request(Command::AttachSession { id: id.into() })
        .await
        .expect("attach to the session");
    let attached = match data {
        ResponseData::Attached(attached) => attached,
        other => panic!("expected an attached session, got {other:?}"),
    };
    let output = Output::from_snapshot(&attached.output);
    (attached, output)
}

async fn collect_until(client: &mut Client, output: &mut Output, needle: &str) -> String {
    let deadline = Instant::now() + WAIT_LIMIT;
    loop {
        let text = output.text();
        if text.contains(needle) {
            return text;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(
            !remaining.is_zero(),
            "timed out waiting for {needle:?}; output was {text:?}",
        );
        let event = tokio::time::timeout(remaining, client.next_event())
            .await
            .expect("timed out waiting for output");
        match event {
            Event::Output { .. } => output.apply(&event),
            Event::Status { .. } | Event::SessionsChanged | Event::WorkspaceChanged { .. } => {}
            Event::DaemonStopping => panic!("the daemon stopped while waiting for {needle:?}"),
        }
    }
}

async fn wait_for_status(
    client: &mut Client,
    output: &mut Output,
    session_id: &str,
) -> SessionStatus {
    let deadline = Instant::now() + WAIT_LIMIT;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "timed out waiting for session status");
        let event = tokio::time::timeout(remaining, client.next_event())
            .await
            .expect("timed out waiting for session status");
        match event {
            Event::Status {
                session_id: id,
                status,
            } if id == session_id => return status,
            Event::Status { .. } | Event::SessionsChanged | Event::WorkspaceChanged { .. } => {}
            Event::Output { .. } => output.apply(&event),
            Event::DaemonStopping => panic!("the daemon stopped while waiting for status"),
        }
    }
}

fn shutdown_daemon(daemon: &mut Daemon) {
    daemon.signal(libc::SIGTERM);
    let deadline = Instant::now() + WAIT_LIMIT;
    let requested = daemon.log(deadline);
    assert_eq!(requested["event"], "shutdown_requested");
    let stopped = daemon.log(deadline);
    assert_eq!(stopped["event"], "stopped");
    assert!(daemon.exited(deadline).success());
    daemon.assert_output_finished();
}

#[tokio::test]
async fn handshake_is_versioned_and_required() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();

    let mut client = Client::connect(daemon.socket_path()).await;
    client
        .send(ClientMessage::Request {
            request_id: 1,
            command: Command::ListSessions,
        })
        .await;
    match client.receive().await {
        ServerMessage::Rejected { error } => assert_eq!(error.code, ErrorCode::HandshakeRequired),
        other => panic!("expected a handshake error, got {other:?}"),
    }
    client.expect_closed().await;

    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;

    let mut client = Client::connect(daemon.socket_path()).await;
    client
        .send(ClientMessage::Hello {
            protocol_version: PROTOCOL_VERSION + 1,
            client: None,
        })
        .await;
    match client.receive().await {
        ServerMessage::Rejected { error } => {
            assert_eq!(error.code, ErrorCode::UnsupportedProtocol)
        }
        other => panic!("expected a protocol error, got {other:?}"),
    }
    client.expect_closed().await;
}

#[tokio::test]
async fn sessions_can_be_created_listed_inspected_and_stopped() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;

    let info = expect_session(
        client
            .request(create_session("one", "sleep 30"))
            .await
            .expect("create a session"),
    );
    assert_eq!(info.id, "one");
    assert!(info.pid.is_some());
    assert_eq!(info.status, SessionStatus::Running);

    let sessions = match client
        .request(Command::ListSessions)
        .await
        .expect("list sessions")
    {
        ResponseData::Sessions(sessions) => sessions,
        other => panic!("expected a session list, got {other:?}"),
    };
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].id, "one");

    let inspected = expect_session(
        client
            .request(Command::InspectSession { id: "one".into() })
            .await
            .expect("inspect a session"),
    );
    assert_eq!(inspected.id, "one");
    assert_eq!(inspected.pid, info.pid);

    let duplicate = client
        .request(create_session("one", "sleep 30"))
        .await
        .unwrap_err();
    assert_eq!(duplicate.code, ErrorCode::DuplicateSession);

    let running = client
        .request(Command::RemoveSession { id: "one".into() })
        .await
        .unwrap_err();
    assert_eq!(running.code, ErrorCode::SessionRunning);

    let exit = expect_exit(
        client
            .request(Command::StopSession { id: "one".into() })
            .await
            .expect("stop a session"),
    );
    let repeated = expect_exit(
        client
            .request(Command::StopSession { id: "one".into() })
            .await
            .expect("stop an exited session"),
    );
    assert_eq!(exit, repeated);

    let inspected = expect_session(
        client
            .request(Command::InspectSession { id: "one".into() })
            .await
            .expect("inspect an exited session"),
    );
    assert_eq!(inspected.status, SessionStatus::Exited(exit));

    let input = client
        .request(Command::Input {
            id: "one".into(),
            data: Base64Bytes::new(b"x".to_vec()),
        })
        .await
        .unwrap_err();
    assert_eq!(input.code, ErrorCode::SessionClosed);
    let resize = client
        .request(Command::Resize {
            id: "one".into(),
            size: TerminalSize::new(24, 80),
        })
        .await
        .unwrap_err();
    assert_eq!(resize.code, ErrorCode::SessionClosed);

    client
        .request(Command::RemoveSession { id: "one".into() })
        .await
        .expect("remove an exited session");
    let sessions = match client
        .request(Command::ListSessions)
        .await
        .expect("list sessions")
    {
        ResponseData::Sessions(sessions) => sessions,
        other => panic!("expected a session list, got {other:?}"),
    };
    assert!(sessions.is_empty());

    let missing = client
        .request(Command::InspectSession {
            id: "missing".into(),
        })
        .await
        .unwrap_err();
    assert_eq!(missing.code, ErrorCode::SessionNotFound);

    let missing = client
        .request(Command::RemoveSession {
            id: "missing".into(),
        })
        .await
        .unwrap_err();
    assert_eq!(missing.code, ErrorCode::SessionNotFound);
}

#[tokio::test]
async fn output_input_and_status_are_ordered() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;

    let script = r#"printf 'ready\n'; IFS= read -r line; printf 'got:%s\n' "$line""#;
    client
        .request(create_session("ordered", script))
        .await
        .expect("create a session");
    let (_, mut output) = attach(&mut client, "ordered").await;

    collect_until(&mut client, &mut output, "ready").await;
    client
        .request(Command::Input {
            id: "ordered".into(),
            data: Base64Bytes::new(b"hello\n".to_vec()),
        })
        .await
        .expect("write input");
    collect_until(&mut client, &mut output, "got:hello").await;

    let status = wait_for_status(&mut client, &mut output, "ordered").await;
    match status {
        SessionStatus::Exited(exit) => assert!(exit.success),
        SessionStatus::Running => panic!("session should have exited"),
    }
}

#[tokio::test]
async fn resize_reaches_the_child() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;

    let script = "trap 'stty size' WINCH; stty size; while :; do sleep 0.05; done";
    client
        .request(create_session("resize", script))
        .await
        .expect("create a session");
    let (_, mut output) = attach(&mut client, "resize").await;
    collect_until(&mut client, &mut output, "24 80").await;

    client
        .request(Command::Resize {
            id: "resize".into(),
            size: TerminalSize::new(30, 100),
        })
        .await
        .expect("resize the session");
    collect_until(&mut client, &mut output, "30 100").await;

    client
        .request(Command::StopSession {
            id: "resize".into(),
        })
        .await
        .expect("stop the session");
}

#[tokio::test]
async fn two_clients_observe_the_same_session() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut first = Client::connect(daemon.socket_path()).await;
    first.hello().await;
    let mut second = Client::connect(daemon.socket_path()).await;
    second.hello().await;

    let script = r#"printf 'ready\n'; IFS= read -r line; printf 'got:%s\n' "$line""#;
    first
        .request(create_session("shared", script))
        .await
        .expect("create a session");
    let (_, mut first_output) = attach(&mut first, "shared").await;
    let (_, mut second_output) = attach(&mut second, "shared").await;
    collect_until(&mut first, &mut first_output, "ready").await;
    collect_until(&mut second, &mut second_output, "ready").await;

    first
        .request(Command::Input {
            id: "shared".into(),
            data: Base64Bytes::new(b"hello\n".to_vec()),
        })
        .await
        .expect("write input");
    collect_until(&mut first, &mut first_output, "got:hello").await;
    collect_until(&mut second, &mut second_output, "got:hello").await;

    let exit = first
        .request(Command::StopSession {
            id: "shared".into(),
        })
        .await
        .expect("stop the session");
    let exit = expect_exit(exit);
    let first_status = wait_for_status(&mut first, &mut first_output, "shared").await;
    let second_status = wait_for_status(&mut second, &mut second_output, "shared").await;
    assert_eq!(first_status, SessionStatus::Exited(exit.clone()));
    assert_eq!(second_status, SessionStatus::Exited(exit));
}

#[tokio::test]
async fn removing_an_exited_session_releases_its_attachment_and_id() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;

    client
        .request(create_session("reuse", r#"printf 'ready\n'; sleep 30"#))
        .await
        .expect("create a session");
    let (_, mut output) = attach(&mut client, "reuse").await;
    collect_until(&mut client, &mut output, "ready").await;

    let exit = client
        .request(Command::StopSession { id: "reuse".into() })
        .await
        .expect("stop the session");
    let exit = expect_exit(exit);
    let status = wait_for_status(&mut client, &mut output, "reuse").await;
    assert_eq!(status, SessionStatus::Exited(exit));

    client
        .request(Command::RemoveSession { id: "reuse".into() })
        .await
        .expect("remove the exited session");

    client
        .request(create_session("reuse", "sleep 30"))
        .await
        .expect("reuse the removed session ID");
    _ = attach(&mut client, "reuse").await;
    client
        .request(Command::StopSession { id: "reuse".into() })
        .await
        .expect("stop the replacement session");
}

#[tokio::test]
async fn attaching_replays_output_produced_before_attach() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;

    client
        .request(create_session("replay", r#"printf 'before\n'; sleep 30"#))
        .await
        .expect("create a session");
    tokio::time::sleep(Duration::from_millis(500)).await;

    let (_, mut output) = attach(&mut client, "replay").await;
    assert!(output.text().contains("before"), "{:?}", output.text());
    collect_until(&mut client, &mut output, "before").await;

    client
        .request(Command::StopSession {
            id: "replay".into(),
        })
        .await
        .expect("stop the session");
}

#[tokio::test]
async fn a_duplicate_attach_is_rejected_and_detaching_resynchronizes() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;

    client
        .request(create_session("dup", r#"printf 'before\n'; sleep 30"#))
        .await
        .expect("create a session");

    let (first, mut output) = attach(&mut client, "dup").await;
    collect_until(&mut client, &mut output, "before").await;

    // One attachment per connection: a second attach must say so instead of
    // silently streaming nothing.
    let error = client
        .request(Command::AttachSession { id: "dup".into() })
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::AlreadyAttached);

    // Detaching and attaching again is the documented recovery, and the new
    // attachment replays a snapshot that covers what the first one saw.
    client
        .request(Command::DetachSession { id: "dup".into() })
        .await
        .expect("detach the session");
    let (second, replay) = attach(&mut client, "dup").await;
    assert!(
        replay.text().contains("before"),
        "expected a replayed snapshot, got {:?}",
        replay.text()
    );
    assert!(
        second.output.next_seq >= first.output.next_seq,
        "the replayed snapshot must not restart behind the first one: {} vs {}",
        second.output.next_seq,
        first.output.next_seq
    );

    client
        .request(Command::StopSession { id: "dup".into() })
        .await
        .expect("stop the session");
}

#[tokio::test]
async fn a_session_reports_its_launch_arguments_and_environment() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;

    let cwd = std::env::current_dir()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let command = Command::CreateSession(CreateSession {
        id: "launch".into(),
        program: "/bin/sh".into(),
        args: vec!["-c".into(), "sleep 30".into()],
        cwd: cwd.clone(),
        env: BTreeMap::from([("FLEET_TEST_ENV".into(), "kept".into())]),
        size: TerminalSize::new(30, 100),
        parent_id: None,
        brief: None,
    });
    let created = expect_session(client.request(command).await.expect("create a session"));

    // Forking rebuilds the command from this metadata, so the daemon has to
    // report the launch unchanged.
    assert_eq!(created.args, ["-c", "sleep 30"]);
    assert_eq!(created.cwd, cwd);
    assert_eq!(
        created.env.get("FLEET_TEST_ENV").map(String::as_str),
        Some("kept")
    );
    assert_eq!(created.env.len(), 1);
    assert_eq!(created.size, TerminalSize::new(30, 100));

    let inspected = expect_session(
        client
            .request(Command::InspectSession {
                id: "launch".into(),
            })
            .await
            .expect("inspect the session"),
    );
    assert_eq!(inspected.args, created.args);
    assert_eq!(inspected.env, created.env);
    assert_eq!(inspected.size, created.size);

    let listed = match client
        .request(Command::ListSessions)
        .await
        .expect("list sessions")
    {
        ResponseData::Sessions(sessions) => sessions,
        other => panic!("expected a session list, got {other:?}"),
    };
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].args, created.args);
    assert_eq!(listed[0].env, created.env);

    client
        .request(Command::StopSession {
            id: "launch".into(),
        })
        .await
        .expect("stop the session");
}

#[tokio::test]
async fn invalid_requests_return_clear_errors() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;

    let invalid_id = client
        .request(Command::InspectSession {
            id: "bad\nid".into(),
        })
        .await
        .unwrap_err();
    assert_eq!(invalid_id.code, ErrorCode::InvalidSessionId);

    let mut missing_program = match create_session("invalid", "true") {
        Command::CreateSession(request) => request,
        _ => unreachable!(),
    };
    missing_program.program.clear();
    let error = client
        .request(Command::CreateSession(missing_program))
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::InvalidProgram);

    let mut missing_cwd = match create_session("invalid", "true") {
        Command::CreateSession(request) => request,
        _ => unreachable!(),
    };
    missing_cwd.cwd.clear();
    let error = client
        .request(Command::CreateSession(missing_cwd))
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::MissingWorkingDirectory);

    let mut bad_env = match create_session("invalid", "true") {
        Command::CreateSession(request) => request,
        _ => unreachable!(),
    };
    bad_env.env.insert("A=B".into(), "value".into());
    let error = client
        .request(Command::CreateSession(bad_env))
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::InvalidRequest);

    let mut zero_size = match create_session("invalid", "true") {
        Command::CreateSession(request) => request,
        _ => unreachable!(),
    };
    zero_size.size.rows = 0;
    let error = client
        .request(Command::CreateSession(zero_size))
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::InvalidTerminalSize);

    let error = client
        .request(Command::Input {
            id: "missing".into(),
            data: Base64Bytes::new(vec![b'x'; MAX_INPUT_BYTES + 1]),
        })
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::InvalidRequest);

    let error = client
        .request(Command::AttachSession {
            id: "missing".into(),
        })
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::SessionNotFound);

    let error = client
        .request(Command::DetachSession {
            id: "missing".into(),
        })
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::NotAttached);

    // The connection remains usable after request-level errors.
    client
        .request(Command::ListSessions)
        .await
        .expect("list sessions after errors");
}

#[tokio::test]
async fn malformed_and_oversized_frames_close_the_client() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();

    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;
    client.write_frame(b"not json").await;
    match client.receive().await {
        ServerMessage::Rejected { error } => assert_eq!(error.code, ErrorCode::InvalidMessage),
        other => panic!("expected an invalid-message error, got {other:?}"),
    }
    client.expect_closed().await;

    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;
    client.write_frame(b"").await;
    match client.receive().await {
        ServerMessage::Rejected { error } => assert_eq!(error.code, ErrorCode::InvalidMessage),
        other => panic!("expected an invalid-message error, got {other:?}"),
    }
    client.expect_closed().await;

    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;
    client.send_length(MAX_FRAME_BYTES as u32).await;
    match client.receive().await {
        ServerMessage::Rejected { error } => assert_eq!(error.code, ErrorCode::InvalidMessage),
        other => panic!("expected an invalid-message error, got {other:?}"),
    }
    client.expect_closed().await;
}

#[tokio::test]
async fn socket_permissions_are_owner_only() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();

    let metadata = std::fs::metadata(daemon.socket_path()).expect("socket metadata");
    assert!(metadata.file_type().is_socket());
    assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
}

#[tokio::test]
async fn live_and_stale_sockets_are_handled() {
    let directory = tempfile::Builder::new()
        .prefix("fleet-api-")
        .tempdir()
        .unwrap();
    let socket = directory.path().join("daemon.sock");

    let mut daemon = Daemon::spawn_at(None, socket.clone());
    daemon.wait_ready();

    let mut second = Daemon::spawn_at(None, socket.clone());
    let deadline = Instant::now() + WAIT_LIMIT;
    let startup = second.log(deadline);
    assert_eq!(startup["event"], "startup");
    let error = second.log(deadline);
    assert_eq!(error["event"], "error");
    assert!(
        error["error"]
            .as_str()
            .unwrap()
            .contains("already listening")
    );
    assert_eq!(second.exited(deadline).code(), Some(1));
    second.assert_output_finished();

    let mut client = Client::connect(&socket).await;
    client.hello().await;
    drop(client);

    shutdown_daemon(&mut daemon);
    assert!(!socket.exists());

    let stale = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    drop(stale);
    let mut replacement = Daemon::spawn_at(None, socket.clone());
    replacement.wait_ready();
    shutdown_daemon(&mut replacement);
    assert!(!socket.exists());
}

#[tokio::test]
async fn shutdown_notifies_attached_clients_and_removes_the_socket() {
    let mut daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;
    client
        .request(create_session("shutdown", "sleep 30"))
        .await
        .expect("create a session");
    let _ = attach(&mut client, "shutdown").await;

    daemon.signal(libc::SIGTERM);

    let deadline = Instant::now() + WAIT_LIMIT;
    let mut saw_stopping = false;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(
            !remaining.is_zero(),
            "timed out waiting for daemon shutdown"
        );
        match tokio::time::timeout(remaining, client.try_receive()).await {
            Ok(Ok(Some(ServerMessage::Event {
                event: Event::DaemonStopping,
            }))) => saw_stopping = true,
            Ok(Ok(Some(ServerMessage::Event { .. }))) => {}
            Ok(Ok(Some(other))) => panic!("unexpected message during shutdown: {other:?}"),
            Ok(Ok(None)) | Ok(Err(_)) => break,
            Err(_) => panic!("timed out waiting for daemon shutdown"),
        }
    }
    assert!(
        saw_stopping,
        "attached clients must be told the daemon is stopping"
    );
    drop(client);

    let shutdown_deadline = Instant::now() + WAIT_LIMIT;
    let requested = daemon.log(shutdown_deadline);
    assert_eq!(requested["event"], "shutdown_requested");
    let stopped = daemon.log(shutdown_deadline);
    assert_eq!(stopped["event"], "stopped");
    assert!(daemon.exited(shutdown_deadline).success());
    assert!(!daemon.socket_path().exists());
    daemon.assert_output_finished();
}

fn step(program: &str) -> PlanStepSpec {
    PlanStepSpec {
        program: program.into(),
        args: Vec::new(),
        cwd: std::env::current_dir()
            .unwrap()
            .to_string_lossy()
            .into_owned(),
        env: BTreeMap::new(),
        brief: None,
    }
}

fn expect_plan(data: ResponseData) -> PlanInfo {
    match data {
        ResponseData::Plan(plan) => plan,
        other => panic!("expected a plan, got {other:?}"),
    }
}

fn expect_tasks(data: ResponseData) -> Vec<fleet_protocol::api::TaskInfo> {
    match data {
        ResponseData::Tasks(tasks) => tasks,
        other => panic!("expected tasks, got {other:?}"),
    }
}

async fn wait_for_plan(client: &mut Client, id: &str) -> PlanInfo {
    let deadline = Instant::now() + WAIT_LIMIT;
    loop {
        let plan = expect_plan(
            client
                .request(Command::GetPlan { id: id.into() })
                .await
                .expect("read the plan"),
        );
        if plan.state != PlanState::Running {
            return plan;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for plan {id} to finish"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn a_plan_runs_the_next_step_after_a_successful_exit() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;
    client
        .request(create_session("parent", "sleep 30"))
        .await
        .expect("create the parent");

    let plan = expect_plan(
        client
            .request(Command::PutPlan(PutPlan {
                parent_id: "parent".into(),
                steps: vec![step("/usr/bin/true"), step("/usr/bin/true")],
            }))
            .await
            .expect("start a two-step plan"),
    );
    let finished = wait_for_plan(&mut client, &plan.id).await;
    assert_eq!(finished.state, PlanState::Done);
    assert_eq!(finished.steps.len(), 2);
    assert!(
        finished
            .steps
            .iter()
            .all(|step| step.state == StepState::Done)
    );
    assert_eq!(
        finished.steps[0].session_id.as_deref(),
        Some(format!("{}-1", plan.id).as_str())
    );
    assert_eq!(
        finished.steps[1].session_id.as_deref(),
        Some(format!("{}-2", plan.id).as_str())
    );
}

#[tokio::test]
async fn a_failed_step_does_not_start_the_rest_of_the_plan() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;
    client
        .request(create_session("parent", "sleep 30"))
        .await
        .expect("create the parent");

    let plan = expect_plan(
        client
            .request(Command::PutPlan(PutPlan {
                parent_id: "parent".into(),
                steps: vec![step("/usr/bin/false"), step("/usr/bin/true")],
            }))
            .await
            .expect("start a plan whose first step fails"),
    );
    let finished = wait_for_plan(&mut client, &plan.id).await;
    assert_eq!(finished.state, PlanState::Failed);
    assert_eq!(finished.steps[0].state, StepState::Failed);
    assert_eq!(finished.steps[1].state, StepState::Waiting);
    assert!(finished.steps[1].session_id.is_none());
}

#[tokio::test]
async fn stopping_a_parent_leaves_its_child_running() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;
    client
        .request(create_session("parent", "sleep 30"))
        .await
        .expect("create the parent");

    let child = CreateSession {
        id: "child".into(),
        program: "/bin/sleep".into(),
        args: vec!["30".into()],
        cwd: std::env::current_dir()
            .unwrap()
            .to_string_lossy()
            .into_owned(),
        env: BTreeMap::new(),
        size: TerminalSize::new(24, 80),
        parent_id: Some("parent".into()),
        brief: Some("watch this".into()),
    };
    client
        .request(Command::CreateSession(child.clone()))
        .await
        .expect("create the child");

    let tasks = expect_tasks(
        client
            .request(Command::ListTasks {
                parent_id: Some("parent".into()),
            })
            .await
            .expect("list the parent's tasks"),
    );
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].session_id, "child");
    assert_eq!(tasks[0].parent_id.as_deref(), Some("parent"));
    assert_eq!(tasks[0].brief.as_deref(), Some("watch this"));

    let _ = expect_exit(
        client
            .request(Command::StopSession {
                id: "parent".into(),
            })
            .await
            .expect("stop the parent"),
    );
    let info = expect_session(
        client
            .request(Command::InspectSession { id: "child".into() })
            .await
            .expect("the child is still there"),
    );
    assert!(matches!(info.status, SessionStatus::Running));
}

#[tokio::test]
async fn presence_and_exit_status_choose_the_sidebar_class() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;
    client
        .request(create_session("parent", "sleep 30"))
        .await
        .expect("create the parent");

    let cwd = std::env::current_dir()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let spawn = |id: &str, program: &str, args: Vec<String>| CreateSession {
        id: id.into(),
        program: program.into(),
        args,
        cwd: cwd.clone(),
        env: BTreeMap::new(),
        size: TerminalSize::new(24, 80),
        parent_id: Some("parent".into()),
        brief: None,
    };
    client
        .request(Command::CreateSession(spawn(
            "quiet",
            "/bin/sleep",
            vec!["30".into()],
        )))
        .await
        .expect("create a quiet session");
    client
        .request(Command::CreateSession(spawn(
            "active",
            "/bin/sleep",
            vec!["30".into()],
        )))
        .await
        .expect("create an active session");
    client
        .request(Command::CreateSession(spawn(
            "bell",
            "/bin/sleep",
            vec!["30".into()],
        )))
        .await
        .expect("create a session that needs attention");
    client
        .request(Command::CreateSession(spawn(
            "ok",
            "/usr/bin/true",
            Vec::new(),
        )))
        .await
        .expect("create a session that exits 0");
    client
        .request(Command::CreateSession(spawn(
            "bad",
            "/usr/bin/false",
            Vec::new(),
        )))
        .await
        .expect("create a session that exits 1");

    for (id, active, needs_attention) in [("active", true, false), ("bell", true, true)] {
        client
            .request(Command::ReportPresence(
                fleet_protocol::api::ReportPresence {
                    id: id.into(),
                    active,
                    needs_attention,
                },
            ))
            .await
            .expect("report presence");
    }

    let deadline = Instant::now() + WAIT_LIMIT;
    let tasks = loop {
        let tasks = expect_tasks(
            client
                .request(Command::ListTasks {
                    parent_id: Some("parent".into()),
                })
                .await
                .expect("list tasks"),
        );
        let settled = tasks
            .iter()
            .any(|task| task.session_id == "ok" && matches!(task.status, SessionStatus::Exited(_)))
            && tasks.iter().any(|task| {
                task.session_id == "bad" && matches!(task.status, SessionStatus::Exited(_))
            });
        if settled {
            break tasks;
        }
        assert!(Instant::now() < deadline, "timed out waiting for exits");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };

    let class = |id: &str| {
        tasks
            .iter()
            .find(|task| task.session_id == id)
            .unwrap_or_else(|| panic!("missing task {id}"))
            .sidebar
    };
    assert_eq!(class("quiet"), SidebarClass::Idle);
    assert_eq!(class("active"), SidebarClass::Running);
    assert_eq!(class("bell"), SidebarClass::NeedsYou);
    assert_eq!(class("ok"), SidebarClass::Idle);
    assert_eq!(class("bad"), SidebarClass::NeedsYou);
}

#[tokio::test]
async fn creating_a_session_tells_a_client_that_has_not_attached() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;
    client
        .request(create_session("fresh", "sleep 5"))
        .await
        .expect("create a session");
    assert!(matches!(client.next_event().await, Event::SessionsChanged));
}

fn expect_workspace(data: ResponseData) -> Workspace {
    match data {
        ResponseData::Workspace(workspace) => workspace,
        other => panic!("expected a workspace, got {other:?}"),
    }
}

fn workspace_tab(id: &str, session: &str) -> WorkspaceTab {
    WorkspaceTab {
        id: id.into(),
        session_id: session.into(),
    }
}

fn workspace_pane(id: &str, tabs: Vec<WorkspaceTab>, active: &str) -> WorkspacePane {
    WorkspacePane {
        id: id.into(),
        tabs,
        active_tab_id: Some(active.into()),
    }
}

#[tokio::test]
async fn workspace_layout_is_validated_shared_and_pruned() {
    let daemon = Daemon::spawn(None);
    daemon.wait_ready();
    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;

    let empty = expect_workspace(
        client
            .request(Command::GetWorkspace)
            .await
            .expect("read the empty workspace"),
    );
    assert_eq!(empty, Workspace::empty());

    client
        .request(create_session("one", "sleep 30"))
        .await
        .expect("create one");
    client
        .request(create_session("two", "sleep 30"))
        .await
        .expect("create two");
    assert!(matches!(client.next_event().await, Event::SessionsChanged));
    assert!(matches!(client.next_event().await, Event::SessionsChanged));

    let layout = Workspace {
        split: Some(SplitAxis::Horizontal),
        panes: vec![
            workspace_pane("pane-a", vec![workspace_tab("tab-a", "one")], "tab-a"),
            workspace_pane("pane-b", vec![workspace_tab("tab-b", "two")], "tab-b"),
        ],
        focused_pane_id: "pane-b".into(),
    };
    let stored = expect_workspace(
        client
            .request(Command::PutWorkspace {
                workspace: layout.clone(),
            })
            .await
            .expect("store the layout"),
    );
    assert_eq!(stored, layout);
    match client.next_event().await {
        Event::WorkspaceChanged { workspace } => assert_eq!(workspace, layout),
        other => panic!("expected a workspace event, got {other:?}"),
    }

    let mut other = Client::connect(daemon.socket_path()).await;
    other.hello().await;
    let seen = expect_workspace(
        other
            .request(Command::GetWorkspace)
            .await
            .expect("the other client reads the same layout"),
    );
    assert_eq!(seen, layout);

    let mut three = layout.clone();
    three.panes.push(workspace_pane(
        "pane-c",
        vec![workspace_tab("tab-c", "two")],
        "tab-c",
    ));
    let rejected = client
        .request(Command::PutWorkspace { workspace: three })
        .await
        .unwrap_err();
    assert_eq!(rejected.code, ErrorCode::InvalidWorkspace);

    let mut duplicate = layout.clone();
    duplicate.panes[1].tabs[0].session_id = "one".into();
    let rejected = client
        .request(Command::PutWorkspace {
            workspace: duplicate,
        })
        .await
        .unwrap_err();
    assert_eq!(rejected.code, ErrorCode::DuplicateWorkspaceTab);

    let mut unknown = layout.clone();
    unknown.panes[1].tabs[0].session_id = "missing".into();
    let rejected = client
        .request(Command::PutWorkspace { workspace: unknown })
        .await
        .unwrap_err();
    assert_eq!(rejected.code, ErrorCode::SessionNotFound);

    let mut dangling = layout.clone();
    dangling.panes[0].active_tab_id = Some("missing-tab".into());
    let rejected = client
        .request(Command::PutWorkspace {
            workspace: dangling,
        })
        .await
        .unwrap_err();
    assert_eq!(rejected.code, ErrorCode::InvalidWorkspace);

    let no_tabs = Workspace {
        split: None,
        panes: vec![WorkspacePane {
            id: "only".into(),
            tabs: vec![],
            active_tab_id: None,
        }],
        focused_pane_id: "only".into(),
    };
    let rejected = client
        .request(Command::PutWorkspace { workspace: no_tabs })
        .await
        .unwrap_err();
    assert_eq!(rejected.code, ErrorCode::InvalidWorkspace);

    client
        .request(Command::StopSession { id: "one".into() })
        .await
        .expect("stop one");
    client
        .request(Command::RemoveSession { id: "one".into() })
        .await
        .expect("remove one");
    let deadline = Instant::now() + WAIT_LIMIT;
    let pruned = loop {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for the pruned layout"
        );
        match client.next_event().await {
            Event::WorkspaceChanged { workspace } => break workspace,
            Event::SessionsChanged | Event::Status { .. } | Event::Output { .. } => {}
            other => panic!("unexpected event while removing a session: {other:?}"),
        }
    };
    assert_eq!(pruned.panes.len(), 1);
    assert_eq!(pruned.panes[0].tabs[0].session_id, "two");
    assert!(pruned.split.is_none());
}

#[tokio::test]
async fn a_malformed_workspace_file_does_not_stop_the_daemon() {
    let directory = tempfile::tempdir().expect("workspace directory");
    std::fs::write(directory.path().join("workspace.json"), b"{not-json").unwrap();
    let daemon = Daemon::spawn_at(None, directory.path().join("daemon.sock"));
    let deadline = Instant::now() + WAIT_LIMIT;
    let startup = daemon.log(deadline);
    assert_eq!(startup["event"], "startup");
    let reset = daemon.log(deadline);
    assert_eq!(reset["event"], "workspace_reset");
    assert_eq!(reset["reason"], "malformed");
    let ready = daemon.log(deadline);
    assert_eq!(ready["event"], "ready");

    let mut client = Client::connect(daemon.socket_path()).await;
    client.hello().await;
    let workspace = expect_workspace(
        client
            .request(Command::GetWorkspace)
            .await
            .expect("an empty workspace after a bad file"),
    );
    assert_eq!(workspace, Workspace::empty());
}
