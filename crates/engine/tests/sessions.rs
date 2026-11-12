#![cfg(unix)]

use std::time::{Duration, Instant};

use fleet_engine::{
    Engine, EngineError, EngineState, SessionError, SessionExit, SessionHandle, SessionId,
    SessionSpec, SessionStatus, TerminalSize,
};

const WAIT_LIMIT: Duration = Duration::from_secs(10);

fn id(value: &str) -> SessionId {
    SessionId::new(value).unwrap()
}

fn command(session_id: &str, script: &str) -> SessionSpec {
    SessionSpec::new(id(session_id), "/bin/sh")
        .arg("-c")
        .arg(script)
        .cwd(std::env::current_dir().unwrap())
}

async fn wait_for_output(handle: &SessionHandle, needle: &str) -> String {
    let deadline = Instant::now() + WAIT_LIMIT;
    loop {
        let output = String::from_utf8_lossy(&handle.output_snapshot().bytes).into_owned();
        if output.contains(needle) {
            return output;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {needle:?}; output was {output:?}",
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn wait_for_exit(handle: &SessionHandle) -> SessionExit {
    tokio::time::timeout(WAIT_LIMIT, handle.wait())
        .await
        .expect("session did not exit before the deadline")
}

fn parse_pid(output: &str, prefix: &str) -> u32 {
    output
        .lines()
        .find_map(|line| line.trim().strip_prefix(prefix))
        .and_then(|value| value.trim().parse().ok())
        .unwrap_or_else(|| panic!("missing {prefix:?} in output: {output:?}"))
}

fn process_exists(pid: u32) -> bool {
    // SAFETY: signal 0 only checks whether the process exists.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

async fn wait_for_process_gone(pid: u32) {
    let deadline = Instant::now() + WAIT_LIMIT;
    while process_exists(pid) {
        assert!(
            Instant::now() < deadline,
            "process {pid} was still alive after the deadline",
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn spawn_reports_a_running_session_and_rejects_duplicate_ids() {
    let mut engine = Engine::start();
    let handle = engine.spawn_session(command("spawn", "sleep 30")).unwrap();

    assert_eq!(handle.id(), &id("spawn"));
    assert!(handle.pid().is_some());
    assert!(matches!(handle.status(), SessionStatus::Running));

    let sessions = engine.sessions();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].id, id("spawn"));
    assert_eq!(sessions[0].pid, handle.pid());

    let duplicate = engine
        .spawn_session(command("spawn", "sleep 30"))
        .unwrap_err();
    assert!(matches!(
        duplicate,
        EngineError::Session(SessionError::DuplicateSessionId(_))
    ));

    handle.terminate().await.unwrap();
    assert!(matches!(handle.status(), SessionStatus::Exited(_)));
    engine.shutdown().await;
}

#[tokio::test]
async fn a_failed_spawn_does_not_reserve_the_id() {
    let mut engine = Engine::start();
    let missing = SessionSpec::new(id("reuse"), "/fleet-missing-program")
        .cwd(std::env::current_dir().unwrap());

    let error = engine.spawn_session(missing).unwrap_err();
    assert!(matches!(
        error,
        EngineError::Session(SessionError::SpawnFailed { .. })
    ));

    let handle = engine.spawn_session(command("reuse", "exit 0")).unwrap();
    assert!(wait_for_exit(&handle).await.success());
    engine.shutdown().await;
}

#[tokio::test]
async fn sessions_inherit_the_environment_and_use_the_requested_cwd() {
    let mut engine = Engine::start();
    let directory = tempfile::tempdir().unwrap();
    let expected_cwd = std::fs::canonicalize(directory.path()).unwrap();
    let expected_home = std::env::var_os("HOME")
        .expect("HOME must be set for this test")
        .to_string_lossy()
        .into_owned();
    let script = concat!(
        "printf 'cwd=%s\\n' \"$(pwd -P)\"; ",
        "printf 'home=%s\\n' \"$HOME\"; ",
        "printf 'override=%s\\n' \"$FLEET_TEST_OVERRIDE\"",
    );

    let spec = SessionSpec::new(id("environment"), "/bin/sh")
        .arg("-c")
        .arg(script)
        .cwd(directory.path())
        .env("FLEET_TEST_OVERRIDE", "present");
    let handle = engine.spawn_session(spec).unwrap();
    let output = wait_for_output(&handle, "override=present").await;

    assert!(
        output.contains(&format!("cwd={}", expected_cwd.display())),
        "{output:?}"
    );
    assert!(
        output.contains(&format!("home={expected_home}")),
        "{output:?}"
    );
    assert!(wait_for_exit(&handle).await.success());
    engine.shutdown().await;
}

#[tokio::test]
async fn session_info_reports_the_requested_launch() {
    use std::ffi::OsString;

    let mut engine = Engine::start();
    let spec = SessionSpec::new(id("launch"), "/bin/sh")
        .arg("-c")
        .arg("sleep 30")
        .cwd(std::env::current_dir().unwrap())
        .env("FLEET_TEST_LAUNCH", "yes")
        .size(TerminalSize::new(30, 100));
    let handle = engine.spawn_session(spec).unwrap();

    // A fork rebuilds its command from this, so it has to keep the exact
    // arguments, the requested environment, and the size.
    let info = handle.info();
    assert_eq!(info.program, OsString::from("/bin/sh"));
    assert_eq!(info.args, ["-c", "sleep 30"].map(OsString::from).to_vec());
    assert_eq!(
        info.env.get(&OsString::from("FLEET_TEST_LAUNCH")),
        Some(&OsString::from("yes"))
    );
    assert_eq!(info.env.len(), 1);
    assert_eq!(info.size, TerminalSize::new(30, 100));

    handle.terminate().await.unwrap();
    engine.shutdown().await;
}

#[tokio::test]
async fn input_produces_output() {
    let mut engine = Engine::start();
    let script = concat!(
        "printf 'ready\\n'; ",
        "IFS= read -r line; ",
        "printf 'got:%s\\n' \"$line\"",
    );
    let handle = engine.spawn_session(command("input", script)).unwrap();

    wait_for_output(&handle, "ready").await;
    handle.input(b"hello\n").await.unwrap();

    wait_for_output(&handle, "got:hello").await;
    assert!(wait_for_exit(&handle).await.success());
    engine.shutdown().await;
}

#[tokio::test]
async fn resize_is_visible_to_the_child() {
    let mut engine = Engine::start();
    let script = "trap 'stty size' WINCH; stty size; while :; do sleep 0.05; done";
    let spec = command("resize", script).size(TerminalSize::new(24, 80));
    let handle = engine.spawn_session(spec).unwrap();

    wait_for_output(&handle, "24 80").await;
    handle.resize(TerminalSize::new(30, 100)).unwrap();
    wait_for_output(&handle, "30 100").await;

    handle.terminate().await.unwrap();
    engine.shutdown().await;
}

#[tokio::test]
async fn normal_exit_codes_are_recorded() {
    let mut engine = Engine::start();
    let handle = engine
        .spawn_session(command("exit-code", "exit 7"))
        .unwrap();

    let exit = wait_for_exit(&handle).await;
    assert!(!exit.success());
    assert_eq!(exit.code(), 7);
    assert_eq!(exit.signal(), None);
    engine.shutdown().await;
}

#[tokio::test]
async fn signal_exits_are_recorded() {
    let mut engine = Engine::start();
    let handle = engine
        .spawn_session(command("signal-exit", "kill -TERM $$"))
        .unwrap();

    let exit = wait_for_exit(&handle).await;
    assert!(!exit.success());
    assert!(exit.signal().is_some(), "expected a signal, got {exit:?}");
    engine.shutdown().await;
}

#[tokio::test]
async fn terminate_is_idempotent_and_stops_the_process_group() {
    let mut engine = Engine::start();
    let script = concat!(
        "printf 'parent=%s\\n' \"$$\"; ",
        "sleep 30 & printf 'child=%s\\n' \"$!\"; ",
        "wait",
    );
    let handle = engine.spawn_session(command("terminate", script)).unwrap();
    let output = wait_for_output(&handle, "child=").await;
    let parent = parse_pid(&output, "parent=");
    let child = parse_pid(&output, "child=");

    let exit = handle.terminate().await.unwrap();
    assert!(!exit.success());
    assert!(matches!(handle.status(), SessionStatus::Exited(_)));
    assert_eq!(handle.terminate().await.unwrap(), exit);
    assert!(handle.input(b"x").await.is_err());
    assert!(handle.resize(TerminalSize::new(24, 80)).is_err());

    wait_for_process_gone(parent).await;
    wait_for_process_gone(child).await;
    engine.shutdown().await;
}

#[tokio::test]
async fn two_sessions_run_independently() {
    let mut engine = Engine::start();
    let directory_a = tempfile::tempdir().unwrap();
    let directory_b = tempfile::tempdir().unwrap();
    let expected_a = std::fs::canonicalize(directory_a.path()).unwrap();
    let expected_b = std::fs::canonicalize(directory_b.path()).unwrap();
    let script = |label: &str| {
        format!(
            concat!(
                "printf 'ready:{label}:%s:%s\\n' \"$(pwd -P)\" \"$FLEET_TEST\"; ",
                "IFS= read -r line; ",
                "printf '{label}-got:%s\\n' \"$line\"",
            ),
            label = label
        )
    };

    let spec_a = SessionSpec::new(id("session-a"), "/bin/sh")
        .arg("-c")
        .arg(script("A"))
        .cwd(directory_a.path())
        .env("FLEET_TEST", "value-a")
        .size(TerminalSize::new(24, 80));
    let spec_b = SessionSpec::new(id("session-b"), "/bin/sh")
        .arg("-c")
        .arg(script("B"))
        .cwd(directory_b.path())
        .env("FLEET_TEST", "value-b")
        .size(TerminalSize::new(30, 100));
    let session_a = engine.spawn_session(spec_a).unwrap();
    let session_b = engine.spawn_session(spec_b).unwrap();

    let output_a = wait_for_output(&session_a, "ready:A").await;
    let output_b = wait_for_output(&session_b, "ready:B").await;
    assert!(
        output_a.contains(&format!("ready:A:{}:value-a", expected_a.display())),
        "{output_a:?}"
    );
    assert!(
        output_b.contains(&format!("ready:B:{}:value-b", expected_b.display())),
        "{output_b:?}"
    );
    assert_eq!(engine.sessions().len(), 2);

    session_a.input(b"one\n").await.unwrap();
    wait_for_output(&session_a, "A-got:one").await;
    let output_b = String::from_utf8_lossy(&session_b.output_snapshot().bytes).into_owned();
    assert!(!output_b.contains("A-got"), "{output_b:?}");
    assert!(!output_b.contains("ready:A"), "{output_b:?}");

    session_a.terminate().await.unwrap();
    assert!(matches!(session_b.status(), SessionStatus::Running));

    session_b.input(b"two\n").await.unwrap();
    wait_for_output(&session_b, "B-got:two").await;
    session_b.terminate().await.unwrap();
    engine.shutdown().await;
}

#[tokio::test]
async fn engine_shutdown_terminates_every_session() {
    let mut engine = Engine::start();
    let session_a = engine
        .spawn_session(command("shutdown-a", "sleep 30"))
        .unwrap();
    let session_b = engine
        .spawn_session(command("shutdown-b", "sleep 30"))
        .unwrap();
    assert_eq!(engine.sessions().len(), 2);

    engine.shutdown().await;

    assert_eq!(engine.state(), EngineState::Stopped);
    assert!(engine.sessions().is_empty());
    assert!(matches!(session_a.status(), SessionStatus::Exited(_)));
    assert!(matches!(session_b.status(), SessionStatus::Exited(_)));

    engine.shutdown().await;
    let error = engine
        .spawn_session(command("after-shutdown", "exit 0"))
        .unwrap_err();
    assert!(matches!(error, EngineError::Stopped));
}

#[tokio::test]
async fn exited_sessions_can_be_removed_and_their_ids_reused() {
    let mut engine = Engine::start();
    let handle = engine.spawn_session(command("remove", "exit 0")).unwrap();
    assert!(wait_for_exit(&handle).await.success());
    assert_eq!(engine.sessions().len(), 1);

    let removed = engine.remove_session(&id("remove")).unwrap();
    assert_eq!(removed.id, id("remove"));
    assert!(engine.sessions().is_empty());

    let missing = engine.remove_session(&id("remove")).unwrap_err();
    assert!(matches!(
        missing,
        EngineError::Session(SessionError::SessionNotFound(_))
    ));

    let replacement = engine.spawn_session(command("remove", "sleep 30")).unwrap();
    assert!(matches!(replacement.status(), SessionStatus::Running));
    replacement.terminate().await.unwrap();
    engine.shutdown().await;
}

#[tokio::test]
async fn running_sessions_cannot_be_removed() {
    let mut engine = Engine::start();
    let handle = engine
        .spawn_session(command("running", "sleep 30"))
        .unwrap();

    let error = engine.remove_session(&id("running")).unwrap_err();
    assert!(matches!(
        error,
        EngineError::Session(SessionError::SessionRunning(_))
    ));
    assert_eq!(engine.sessions().len(), 1);

    handle.terminate().await.unwrap();
    engine.shutdown().await;
}
