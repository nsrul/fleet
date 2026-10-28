#![cfg(unix)]

mod support;

use std::{
    collections::{BTreeMap, VecDeque},
    io,
    os::unix::fs::{FileTypeExt, PermissionsExt},
    path::Path,
    time::{Duration, Instant},
};

use director_protocol::{
    PROTOCOL_VERSION,
    api::{
        ApiError, AttachedSession, Base64Bytes, ClientMessage, Command, CreateSession, ErrorCode,
        Event, MAX_FRAME_BYTES, MAX_INPUT_BYTES, OutputSnapshot, ResponseData, ServerMessage,
        SessionExit, SessionInfo, SessionStatus, TerminalSize,
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
                assert_eq!(engine_state, director_protocol::DaemonState::Running);
                assert!(
                    capabilities.iter().any(|capability| capability
                        == director_protocol::api::CAPABILITY_REMOVE_SESSION)
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
                        director_protocol::api::ResponseResult::Ok(data) => Ok(data),
                        director_protocol::api::ResponseResult::Error(error) => Err(error),
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
            Event::Status { .. } => {}
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
            Event::Status { .. } => {}
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
    attach(&mut client, "reuse").await.0;
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
        .prefix("director-api-")
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
