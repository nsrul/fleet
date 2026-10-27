#![allow(dead_code)]

use std::{
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
    sync::mpsc::{self, Receiver},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use serde_json::Value;

// Leave startup ample time on loaded CI hosts. Every wait is bounded.
pub const WAIT_LIMIT: Duration = Duration::from_secs(30);

pub struct Daemon {
    child: Child,
    lines: Receiver<Result<String, std::io::Error>>,
    reader: Option<JoinHandle<()>>,
    socket: PathBuf,
    _socket_dir: Option<tempfile::TempDir>,
}

impl Daemon {
    pub fn spawn(filter: Option<&str>) -> Self {
        let directory = tempfile::Builder::new()
            .prefix("director-api-")
            .tempdir()
            .expect("create a temporary socket directory");
        let socket = directory.path().join("daemon.sock");
        Self::launch(filter, socket, Some(directory))
    }

    pub fn spawn_at(filter: Option<&str>, socket: PathBuf) -> Self {
        Self::launch(filter, socket, None)
    }

    fn launch(filter: Option<&str>, socket: PathBuf, directory: Option<tempfile::TempDir>) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_director-daemon"));
        command.arg("--socket").arg(&socket);
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
            socket,
            _socket_dir: directory,
        }
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket
    }

    pub fn child_id(&self) -> u32 {
        self.child.id()
    }

    pub fn is_running(&mut self) -> bool {
        self.child.try_wait().expect("poll daemon exit").is_none()
    }

    pub fn has_no_pending_logs(&self) -> bool {
        matches!(self.lines.try_recv(), Err(mpsc::TryRecvError::Empty))
    }

    pub fn wait_ready(&self) -> Value {
        let deadline = Instant::now() + WAIT_LIMIT;
        let startup = self.log(deadline);
        assert_eq!(startup["event"], "startup");
        let ready = self.log(deadline);
        assert_eq!(ready["event"], "ready");
        assert_eq!(ready["level"], "INFO");
        assert_eq!(ready["version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(ready["socket"], self.socket.to_string_lossy().as_ref());
        ready
    }

    pub fn log(&self, deadline: Instant) -> Value {
        let line = self
            .lines
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .expect("daemon must emit the expected event before the deadline")
            .expect("read daemon stderr");
        serde_json::from_str(&line).expect("each stderr line must be JSON")
    }

    pub fn signal(&self, signal: i32) {
        // SAFETY: the owned child has not been reaped, so its PID cannot be reused.
        let result = unsafe { libc::kill(self.child.id() as libc::pid_t, signal) };
        assert_eq!(
            result,
            0,
            "send signal: {}",
            std::io::Error::last_os_error()
        );
    }

    pub fn exited(&mut self, deadline: Instant) -> ExitStatus {
        loop {
            if let Some(status) = self.child.try_wait().expect("poll daemon exit") {
                return status;
            }
            assert!(Instant::now() < deadline, "daemon failed to exit in time");
            thread::sleep(Duration::from_millis(20));
        }
    }

    pub fn assert_output_finished(&mut self) {
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
