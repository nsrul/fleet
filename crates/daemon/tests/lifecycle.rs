#![cfg(unix)]

use std::{
    io::{BufRead, BufReader, Read},
    process::{Child, Command, ExitStatus, Stdio},
    sync::mpsc::{self, Receiver},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use director_protocol::{DaemonState, PROTOCOL_VERSION};
use serde_json::Value;

// Leave startup ample time on loaded CI hosts. Every wait is bounded.
const WAIT_LIMIT: Duration = Duration::from_secs(30);

struct Daemon {
    child: Child,
    lines: Receiver<Result<String, std::io::Error>>,
    reader: Option<JoinHandle<()>>,
}

impl Daemon {
    fn spawn(filter: Option<&str>) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_director-daemon"));
        if let Some(filter) = filter {
            command.env("RUST_LOG", filter);
        } else {
            command.env_remove("RUST_LOG");
        }
        let mut child = command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("launch standalone daemon");
        let stderr = child.stderr.take().unwrap();
        let (sender, lines) = mpsc::channel();
        let reader = thread::spawn(move || {
            for line in BufReader::new(stderr).lines() {
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        Self {
            child,
            lines,
            reader: Some(reader),
        }
    }

    fn log(&self, deadline: Instant) -> Value {
        let line = self
            .lines
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .expect("daemon must emit the expected event before the deadline")
            .expect("read daemon stderr");
        serde_json::from_str(&line).expect("each stderr line must be JSON")
    }

    fn signal(&self, signal: i32) {
        // SAFETY: the owned child has not been reaped, so its PID cannot be reused.
        let result = unsafe { libc::kill(self.child.id() as libc::pid_t, signal) };
        assert_eq!(
            result,
            0,
            "send signal: {}",
            std::io::Error::last_os_error()
        );
    }

    fn exited(&mut self, deadline: Instant) -> ExitStatus {
        loop {
            if let Some(status) = self.child.try_wait().expect("poll daemon exit") {
                return status;
            }
            assert!(Instant::now() < deadline, "daemon failed to exit in time");
            thread::sleep(Duration::from_millis(20));
        }
    }

    fn assert_output_finished(&mut self) {
        self.reader.take().unwrap().join().expect("stderr reader");
        assert!(self.lines.try_iter().collect::<Vec<_>>().is_empty());
        let mut stdout = String::new();
        self.child
            .stdout
            .take()
            .unwrap()
            .read_to_string(&mut stdout)
            .expect("read stdout after exit");
        assert!(stdout.is_empty(), "logs belong on stderr: {stdout}");
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // Also runs on assertion failure/timeout: terminate and reap the child
        // before joining its pipe reader, so tests cannot leave a daemon behind.
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

fn clean_signal_shutdown(signal: i32, reason: &str, filter: Option<&str>) {
    let mut daemon = Daemon::spawn(filter);
    let startup_deadline = Instant::now() + WAIT_LIMIT;
    let startup = daemon.log(startup_deadline);
    assert_eq!(startup["event"], "startup");
    let ready = daemon.log(startup_deadline);
    assert_eq!(ready["event"], "ready");
    assert_eq!(ready["level"], "INFO");
    assert_eq!(ready["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(ready["protocol_version"], PROTOCOL_VERSION);
    assert_eq!(ready["pid"], daemon.child.id());
    assert_eq!(
        serde_json::from_value::<DaemonState>(ready["state"].clone()).unwrap(),
        DaemonState::Running
    );

    // No UI, client, or stdin is attached. Readiness must not mean early exit.
    thread::sleep(Duration::from_millis(150));
    assert!(daemon.child.try_wait().unwrap().is_none());
    assert!(matches!(
        daemon.lines.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));

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
