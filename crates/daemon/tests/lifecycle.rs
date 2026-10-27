#![cfg(unix)]

mod support;

use std::{
    thread,
    time::{Duration, Instant},
};

use director_protocol::{DaemonState, PROTOCOL_VERSION};
use support::{Daemon, WAIT_LIMIT};

fn clean_signal_shutdown(signal: i32, reason: &str, filter: Option<&str>) {
    let mut daemon = Daemon::spawn(filter);
    let ready = daemon.wait_ready();
    assert_eq!(ready["protocol_version"], PROTOCOL_VERSION);
    assert_eq!(ready["pid"], daemon.child_id());
    assert_eq!(
        serde_json::from_value::<DaemonState>(ready["state"].clone()).unwrap(),
        DaemonState::Running
    );

    // No UI, client, or stdin is attached. Readiness must not mean early exit.
    thread::sleep(Duration::from_millis(150));
    assert!(daemon.is_running());
    assert!(daemon.has_no_pending_logs());

    daemon.signal(signal);
    let shutdown_deadline = Instant::now() + WAIT_LIMIT;
    let requested = daemon.log(shutdown_deadline);
    assert_eq!(requested["event"], "shutdown_requested");
    assert_eq!(requested["reason"], reason);
    let stopped = daemon.log(shutdown_deadline);
    assert_eq!(stopped["event"], "stopped");
    assert_eq!(
        serde_json::from_value::<DaemonState>(stopped["state"].clone()).unwrap(),
        DaemonState::Stopped
    );
    assert!(!daemon.socket_path().exists());
    assert!(daemon.exited(shutdown_deadline).success());
    daemon.assert_output_finished();
}

#[test]
fn sigint_shuts_down_without_a_ui() {
    clean_signal_shutdown(libc::SIGINT, "SIGINT", None);
}

#[test]
fn sigterm_shuts_down_with_a_rust_log_override() {
    clean_signal_shutdown(libc::SIGTERM, "SIGTERM", Some("director_daemon=debug"));
}

#[test]
fn invalid_rust_log_fails_with_a_json_error() {
    let mut daemon = Daemon::spawn(Some("director_daemon=invalid-level"));
    let deadline = Instant::now() + WAIT_LIMIT;
    let error = daemon.log(deadline);
    assert_eq!(error["event"], "error");
    assert_eq!(error["level"], "ERROR");
    assert!(
        error["error"]
            .as_str()
            .unwrap()
            .contains("invalid RUST_LOG")
    );
    assert_eq!(daemon.exited(deadline).code(), Some(1));
    daemon.assert_output_finished();
}
