use std::{
    fs,
    io::{self, ErrorKind},
    os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context, Result, bail};
use tokio::net::{UnixListener, UnixStream};

const STALE_CHECK_TIMEOUT: Duration = Duration::from_secs(1);

/// A user-owned Unix listener with a socket file that is removed on shutdown.
pub struct LocalListener {
    listener: Option<UnixListener>,
    socket: SocketGuard,
}

impl LocalListener {
    pub async fn bind(path: &Path, private_parent: bool) -> Result<Self> {
        prepare_parent(path, private_parent)?;
        remove_if_stale(path).await?;

        let listener = UnixListener::bind(path)
            .with_context(|| format!("bind local socket {}", path.display()))?;
        let metadata = fs::symlink_metadata(path)
            .with_context(|| format!("inspect local socket {}", path.display()))?;
        let socket = SocketGuard::new(path.to_path_buf(), metadata.dev(), metadata.ino());
        if !metadata.file_type().is_socket() {
            bail!("{} is not a socket after binding", path.display());
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .with_context(|| format!("restrict permissions on {}", path.display()))?;

        Ok(Self {
            listener: Some(listener),
            socket,
        })
    }

    pub async fn accept(&self) -> io::Result<UnixStream> {
        let listener = self
            .listener
            .as_ref()
            .expect("the listener is closed before accept is called");
        listener.accept().await.map(|(stream, _)| stream)
    }

    pub fn path(&self) -> &Path {
        self.socket.path()
    }

    pub fn close(&mut self) {
        self.listener = None;
    }

    pub fn remove(&mut self) {
        self.socket.remove();
    }
}

impl Drop for LocalListener {
    fn drop(&mut self) {
        self.socket.remove();
    }
}

pub fn current_uid() -> u32 {
    // SAFETY: getuid has no preconditions and does not mutate global state.
    unsafe { libc::getuid() }
}

fn prepare_parent(path: &Path, private: bool) -> Result<()> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .context("the socket path must include a parent directory")?;

    if !parent.exists() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .with_context(|| format!("create socket directory {}", parent.display()))?;
    }

    let metadata = fs::symlink_metadata(parent)
        .with_context(|| format!("inspect socket directory {}", parent.display()))?;
    if metadata.file_type().is_symlink() {
        bail!(
            "refusing to use symlinked socket directory {}",
            parent.display()
        );
    }
    if !metadata.is_dir() {
        bail!("socket parent {} is not a directory", parent.display());
    }
    if metadata.uid() != current_uid() {
        bail!(
            "socket directory {} is not owned by the current user",
            parent.display()
        );
    }
    if private {
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("restrict permissions on {}", parent.display()))?;
    }

    Ok(())
}

async fn remove_if_stale(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error).with_context(|| format!("inspect socket {}", path.display()));
        }
    };
    if metadata.file_type().is_symlink() {
        bail!("refusing to replace symlink {}", path.display());
    }
    if !metadata.file_type().is_socket() {
        bail!("{} exists and is not a socket", path.display());
    }
    if metadata.uid() != current_uid() {
        bail!("socket {} is owned by another user", path.display());
    }

    match tokio::time::timeout(STALE_CHECK_TIMEOUT, UnixStream::connect(path)).await {
        Ok(Ok(_)) => bail!(
            "another director daemon is already listening at {}",
            path.display()
        ),
        Ok(Err(error))
            if matches!(
                error.kind(),
                ErrorKind::ConnectionRefused | ErrorKind::NotFound
            ) =>
        {
            fs::remove_file(path)
                .with_context(|| format!("remove stale socket {}", path.display()))?;
            Ok(())
        }
        Ok(Err(error)) => {
            Err(error).with_context(|| format!("check existing socket {}", path.display()))
        }
        Err(_) => bail!(
            "timed out checking the existing socket {}; another daemon may be running",
            path.display()
        ),
    }
}

struct SocketGuard {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl SocketGuard {
    fn new(path: PathBuf, device: u64, inode: u64) -> Self {
        Self {
            path,
            device,
            inode,
        }
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn remove(&mut self) {
        let Ok(metadata) = fs::symlink_metadata(&self.path) else {
            return;
        };
        if metadata.dev() == self.device
            && metadata.ino() == self.inode
            && metadata.file_type().is_socket()
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        self.remove();
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};

    use super::LocalListener;

    #[tokio::test]
    async fn binding_creates_a_private_socket_and_removes_it_on_drop() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("run").join("daemon.sock");
        let listener = LocalListener::bind(&path, true).await.unwrap();

        let socket = std::fs::metadata(&path).unwrap();
        assert!(socket.file_type().is_socket());
        assert_eq!(socket.mode() & 0o777, 0o600);
        let parent = std::fs::metadata(path.parent().unwrap()).unwrap();
        assert_eq!(parent.mode() & 0o777, 0o700);

        drop(listener);
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn a_live_listener_is_not_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("daemon.sock");
        let _listener = LocalListener::bind(&path, false).await.unwrap();

        let error = match LocalListener::bind(&path, false).await {
            Ok(_) => panic!("a second listener must not bind the same socket"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("already listening"));
    }

    #[tokio::test]
    async fn a_stale_socket_is_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("daemon.sock");
        let stale = std::os::unix::net::UnixListener::bind(&path).unwrap();
        drop(stale);

        let listener = LocalListener::bind(&path, false).await.unwrap();
        assert_eq!(listener.path(), path);
    }
}
