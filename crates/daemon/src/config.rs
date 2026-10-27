use std::{
    env,
    ffi::OsString,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};

/// Maximum portable Unix socket path length. macOS allows 104 bytes including
/// the trailing NUL, so leave a small margin.
const MAX_SOCKET_PATH_BYTES: usize = 100;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub socket_path: PathBuf,
    /// Whether the daemon created the socket's directory and should keep it
    /// private. Explicit paths leave an existing parent directory untouched.
    pub private_parent: bool,
}

impl Config {
    pub fn load() -> Result<Self> {
        Self::from_sources(env::args_os().skip(1), env::var_os("DIRECTOR_SOCKET"))
    }

    fn from_sources<I>(args: I, env_socket: Option<OsString>) -> Result<Self>
    where
        I: IntoIterator<Item = OsString>,
    {
        let mut explicit = None;
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            if arg == "--socket" {
                if explicit.is_some() {
                    bail!("--socket may only be provided once");
                }
                explicit = Some(args.next().context("--socket requires a path")?);
            } else if let Some(value) = arg.to_str().and_then(|arg| arg.strip_prefix("--socket=")) {
                if explicit.is_some() {
                    bail!("--socket may only be provided once");
                }
                explicit = Some(OsString::from(value));
            } else {
                bail!("unknown argument {arg:?}; supported: --socket <path>");
            }
        }

        let (socket, private_parent) = match explicit {
            Some(socket) => (socket, false),
            None => match env_socket {
                Some(socket) => {
                    if socket.is_empty() {
                        bail!("DIRECTOR_SOCKET must not be empty");
                    }
                    (socket, false)
                }
                None => (default_socket_path().into_os_string(), true),
            },
        };

        if socket.is_empty() {
            bail!("the socket path must not be empty");
        }
        let socket = PathBuf::from(socket);
        let socket_path = if socket.is_absolute() {
            socket
        } else {
            env::current_dir()
                .context("resolve the current directory for a relative socket path")?
                .join(socket)
        };
        if socket_path.as_os_str().as_encoded_bytes().len() > MAX_SOCKET_PATH_BYTES {
            bail!(
                "socket path is {} bytes; Unix socket paths must be at most {MAX_SOCKET_PATH_BYTES} bytes",
                socket_path.as_os_str().as_encoded_bytes().len(),
            );
        }
        if socket_path.parent().is_none_or(Path::is_empty) {
            bail!("the socket path must include a parent directory");
        }

        Ok(Self {
            socket_path,
            private_parent,
        })
    }
}

fn default_socket_path() -> PathBuf {
    if let Some(runtime_dir) = env::var_os("XDG_RUNTIME_DIR").filter(|dir| !dir.is_empty()) {
        return PathBuf::from(runtime_dir)
            .join("director")
            .join("daemon.sock");
    }

    // SAFETY: getuid has no preconditions and does not mutate global state.
    let uid = unsafe { libc::getuid() };
    env::temp_dir()
        .join(format!("director-{uid}"))
        .join("daemon.sock")
}

#[cfg(test)]
mod tests {
    use std::{env, ffi::OsString, path::PathBuf};

    use super::Config;

    fn args(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    #[test]
    fn explicit_socket_wins_over_the_environment() {
        let config = Config::from_sources(
            args(&["--socket", "/tmp/one.sock"]),
            Some("/tmp/two.sock".into()),
        )
        .unwrap();
        assert_eq!(config.socket_path, PathBuf::from("/tmp/one.sock"));
        assert!(!config.private_parent);
    }

    #[test]
    fn environment_socket_is_used_when_no_flag_is_present() {
        let config = Config::from_sources(args(&[]), Some("/tmp/two.sock".into())).unwrap();
        assert_eq!(config.socket_path, PathBuf::from("/tmp/two.sock"));
        assert!(!config.private_parent);
    }

    #[test]
    fn the_socket_equals_form_is_accepted() {
        let config = Config::from_sources(args(&["--socket=/tmp/one.sock"]), None).unwrap();
        assert_eq!(config.socket_path, PathBuf::from("/tmp/one.sock"));
    }

    #[test]
    fn relative_sockets_are_resolved_against_the_working_directory() {
        let config = Config::from_sources(args(&["--socket", "run/daemon.sock"]), None).unwrap();
        assert_eq!(
            config.socket_path,
            env::current_dir().unwrap().join("run/daemon.sock")
        );
    }

    #[test]
    fn invalid_arguments_and_empty_paths_are_rejected() {
        assert!(Config::from_sources(args(&["--other"]), None).is_err());
        assert!(Config::from_sources(args(&["--socket"]), None).is_err());
        assert!(Config::from_sources(args(&["--socket", "one", "--socket", "two"]), None).is_err());
        assert!(Config::from_sources(args(&[]), Some(OsString::new())).is_err());
        assert!(Config::from_sources(args(&["--socket", &"x".repeat(200)]), None).is_err());
    }
}
