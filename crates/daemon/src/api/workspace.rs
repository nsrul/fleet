//! The open-tab arrangement. It is one record for the whole daemon.
//!
//! Sessions stay in memory. This record only stores their ids, so a tab whose
//! session is gone is dropped on load and when that session is removed.

use std::{
    collections::HashSet,
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
    sync::Mutex,
};

use fleet_protocol::api::{ApiError, ErrorCode, SplitAxis, Workspace, WorkspacePane};
use tokio::sync::watch;
use tracing::{debug, warn};

const FILE_VERSION: u32 = 1;
const MAX_ID_BYTES: usize = 128;

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct WorkspaceFile {
    version: u32,
    workspace: Workspace,
}

pub struct WorkspaceBook {
    path: PathBuf,
    inner: Mutex<Workspace>,
    changes: watch::Sender<u64>,
    generation: Mutex<u64>,
}

impl WorkspaceBook {
    /// Loads the record. A missing or malformed file becomes an empty workspace
    /// and does not stop the daemon.
    pub fn open(path: PathBuf, live: &HashSet<String>) -> Self {
        let workspace = load(&path, live);
        let (changes, _) = watch::channel(0);
        Self {
            path,
            inner: Mutex::new(workspace),
            changes,
            generation: Mutex::new(0),
        }
    }

    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    pub fn get(&self) -> Workspace {
        self.inner.lock().expect("workspace lock").clone()
    }

    pub fn put(&self, workspace: Workspace, live: &HashSet<String>) -> Result<Workspace, ApiError> {
        validate(&workspace, live)?;
        let mut guard = self.inner.lock().expect("workspace lock");
        if *guard != workspace {
            *guard = workspace.clone();
            self.persist(&workspace);
            drop(guard);
            self.bump();
        }
        Ok(workspace)
    }

    /// Drops every tab for `session_id` and collapses a pane that becomes empty.
    pub fn forget(&self, session_id: &str) {
        let mut guard = self.inner.lock().expect("workspace lock");
        let next = drop_session(guard.clone(), session_id);
        if next == *guard {
            return;
        }
        *guard = next.clone();
        self.persist(&next);
        drop(guard);
        self.bump();
    }

    fn persist(&self, workspace: &Workspace) {
        if let Err(error) = save(&self.path, workspace) {
            warn!(
                event = "workspace_save_failed",
                path = %self.path.display(),
                error = %error,
            );
        }
    }

    fn bump(&self) {
        let mut generation = self.generation.lock().expect("workspace generation");
        *generation = generation.saturating_add(1);
        let _ = self.changes.send(*generation);
    }
}

fn load(path: &Path, live: &HashSet<String>) -> Workspace {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return Workspace::empty();
        }
        Err(error) => {
            warn!(
                event = "workspace_reset",
                reason = "unreadable",
                path = %path.display(),
                error = %error,
            );
            return Workspace::empty();
        }
    };

    let file = match serde_json::from_slice::<WorkspaceFile>(&bytes) {
        Ok(file) if file.version == FILE_VERSION => file,
        Ok(file) => {
            warn!(
                event = "workspace_reset",
                reason = "version",
                version = file.version,
                path = %path.display(),
            );
            let empty = Workspace::empty();
            let _ = save(path, &empty);
            return empty;
        }
        Err(error) => {
            warn!(
                event = "workspace_reset",
                reason = "malformed",
                path = %path.display(),
                error = %error,
            );
            let empty = Workspace::empty();
            let _ = save(path, &empty);
            return empty;
        }
    };

    let original = file.workspace.clone();
    let pruned = prune(file.workspace, live);
    if pruned != original {
        debug!(event = "workspace_pruned", path = %path.display());
        let _ = save(path, &pruned);
    }
    pruned
}

fn save(path: &Path, workspace: &Workspace) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = WorkspaceFile {
        version: FILE_VERSION,
        workspace: workspace.clone(),
    };
    let bytes = serde_json::to_vec_pretty(&file)
        .map_err(|error| std::io::Error::new(ErrorKind::InvalidData, error))?;
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, &bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    }
    fs::rename(&temporary, path)
}

fn prune(mut workspace: Workspace, live: &HashSet<String>) -> Workspace {
    for pane in &mut workspace.panes {
        pane.tabs.retain(|tab| live.contains(&tab.session_id));
        let active_ok = pane
            .active_tab_id
            .as_ref()
            .is_some_and(|id| pane.tabs.iter().any(|tab| &tab.id == id));
        if !active_ok {
            pane.active_tab_id = pane.tabs.last().map(|tab| tab.id.clone());
        }
    }
    workspace.panes.retain(|pane| !pane.tabs.is_empty());
    if workspace.panes.len() > 2 {
        workspace.panes.truncate(2);
    }
    match workspace.panes.len() {
        0 => Workspace::empty(),
        1 => {
            workspace.split = None;
            if !workspace
                .panes
                .iter()
                .any(|pane| pane.id == workspace.focused_pane_id)
            {
                workspace.focused_pane_id = workspace.panes[0].id.clone();
            }
            workspace
        }
        _ => {
            if workspace.split.is_none() {
                workspace.split = Some(SplitAxis::Horizontal);
            }
            if !workspace
                .panes
                .iter()
                .any(|pane| pane.id == workspace.focused_pane_id)
            {
                workspace.focused_pane_id = workspace.panes[0].id.clone();
            }
            workspace
        }
    }
}

fn drop_session(workspace: Workspace, session_id: &str) -> Workspace {
    let live = workspace
        .panes
        .iter()
        .flat_map(|pane| pane.tabs.iter().map(|tab| tab.session_id.clone()))
        .filter(|id| id != session_id)
        .collect();
    prune(workspace, &live)
}

fn validate(workspace: &Workspace, live: &HashSet<String>) -> Result<(), ApiError> {
    let count = workspace.panes.len();
    if count > 2 {
        return Err(invalid("a workspace has at most two panes"));
    }
    if count == 0 {
        if workspace.split.is_some() || !workspace.focused_pane_id.is_empty() {
            return Err(invalid(
                "an empty workspace has no split and no focused pane",
            ));
        }
        return Ok(());
    }
    if count == 1 && workspace.split.is_some() {
        return Err(invalid("one pane has no split"));
    }
    if count == 2 && workspace.split.is_none() {
        return Err(invalid("two panes need a split"));
    }

    let mut pane_ids = HashSet::new();
    let mut tab_ids = HashSet::new();
    let mut session_ids = HashSet::new();
    for pane in &workspace.panes {
        check_id("pane", &pane.id)?;
        if !pane_ids.insert(pane.id.clone()) {
            return Err(invalid(format!("pane {} is listed twice", pane.id)));
        }
        if pane.tabs.is_empty() {
            return Err(invalid(format!("pane {} has no tabs", pane.id)));
        }
        validate_pane(pane, live, &mut tab_ids, &mut session_ids)?;
    }
    if !pane_ids.contains(&workspace.focused_pane_id) {
        return Err(invalid("focused pane is not in the workspace"));
    }
    Ok(())
}

fn validate_pane(
    pane: &WorkspacePane,
    live: &HashSet<String>,
    tab_ids: &mut HashSet<String>,
    session_ids: &mut HashSet<String>,
) -> Result<(), ApiError> {
    for tab in &pane.tabs {
        check_id("tab", &tab.id)?;
        if !tab_ids.insert(tab.id.clone()) {
            return Err(invalid(format!("tab {} is listed twice", tab.id)));
        }
        if tab.session_id.is_empty() {
            return Err(invalid("a tab needs a session"));
        }
        if !session_ids.insert(tab.session_id.clone()) {
            return Err(ApiError::new(
                ErrorCode::DuplicateWorkspaceTab,
                format!("session {} is already open", tab.session_id),
            ));
        }
        if !live.contains(&tab.session_id) {
            return Err(ApiError::new(
                ErrorCode::SessionNotFound,
                format!("session {} was not found", tab.session_id),
            ));
        }
    }
    let Some(active) = pane.active_tab_id.as_deref() else {
        return Err(invalid(format!("pane {} has no active tab", pane.id)));
    };
    if !pane.tabs.iter().any(|tab| tab.id == active) {
        return Err(invalid(format!(
            "active tab {active} is not in pane {}",
            pane.id
        )));
    }
    Ok(())
}

fn check_id(kind: &str, id: &str) -> Result<(), ApiError> {
    if id.is_empty() || id.len() > MAX_ID_BYTES {
        return Err(invalid(format!("{kind} id is empty or too long")));
    }
    Ok(())
}

fn invalid(message: impl Into<String>) -> ApiError {
    ApiError::new(ErrorCode::InvalidWorkspace, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use fleet_protocol::api::{WorkspacePane, WorkspaceTab};

    fn tab(id: &str, session: &str) -> WorkspaceTab {
        WorkspaceTab {
            id: id.into(),
            session_id: session.into(),
        }
    }

    fn pane(id: &str, tabs: Vec<WorkspaceTab>, active: &str) -> WorkspacePane {
        WorkspacePane {
            id: id.into(),
            tabs,
            active_tab_id: Some(active.into()),
        }
    }

    fn live(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|id| (*id).to_owned()).collect()
    }

    fn sample() -> Workspace {
        Workspace {
            split: Some(SplitAxis::Vertical),
            panes: vec![
                pane("left", vec![tab("t1", "one")], "t1"),
                pane("right", vec![tab("t2", "two")], "t2"),
            ],
            focused_pane_id: "right".into(),
        }
    }

    #[test]
    fn a_missing_file_loads_an_empty_workspace() {
        let dir = tempfile::tempdir().unwrap();
        let book = WorkspaceBook::open(dir.path().join("workspace.json"), &live(&[]));
        assert_eq!(book.get(), Workspace::empty());
    }

    #[test]
    fn a_malformed_file_does_not_stop_loading() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workspace.json");
        fs::write(&path, b"{not json").unwrap();
        let book = WorkspaceBook::open(path, &live(&["one"]));
        assert_eq!(book.get(), Workspace::empty());
    }

    #[test]
    fn tabs_for_removed_sessions_are_dropped() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workspace.json");
        save(&path, &sample()).unwrap();
        let book = WorkspaceBook::open(path, &live(&["two"]));
        let workspace = book.get();
        assert_eq!(workspace.panes.len(), 1);
        assert_eq!(workspace.panes[0].tabs[0].session_id, "two");
        assert!(workspace.split.is_none());
        assert_eq!(workspace.focused_pane_id, "right");
    }

    #[test]
    fn put_rejects_bad_shapes_and_saves_a_valid_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workspace.json");
        let book = WorkspaceBook::open(path.clone(), &live(&["one", "two"]));
        let sessions = live(&["one", "two"]);

        let empty_pane = Workspace {
            split: None,
            panes: vec![WorkspacePane {
                id: "only".into(),
                tabs: vec![],
                active_tab_id: None,
            }],
            focused_pane_id: "only".into(),
        };
        assert_eq!(
            book.put(empty_pane, &sessions).unwrap_err().code,
            ErrorCode::InvalidWorkspace
        );

        let mut three = sample();
        three
            .panes
            .push(pane("third", vec![tab("t3", "three")], "t3"));
        assert_eq!(
            book.put(three, &sessions).unwrap_err().code,
            ErrorCode::InvalidWorkspace
        );

        let mut duplicate = sample();
        duplicate.panes[1].tabs[0].session_id = "one".into();
        assert_eq!(
            book.put(duplicate, &sessions).unwrap_err().code,
            ErrorCode::DuplicateWorkspaceTab
        );

        let mut unknown = sample();
        unknown.panes[1].tabs[0].session_id = "missing".into();
        assert_eq!(
            book.put(unknown, &sessions).unwrap_err().code,
            ErrorCode::SessionNotFound
        );

        let mut dangling = sample();
        dangling.panes[0].active_tab_id = Some("nope".into());
        assert_eq!(
            book.put(dangling, &sessions).unwrap_err().code,
            ErrorCode::InvalidWorkspace
        );

        let stored = book.put(sample(), &sessions).unwrap();
        assert_eq!(stored, sample());
        let reloaded = WorkspaceBook::open(path, &sessions);
        assert_eq!(reloaded.get(), sample());

        book.forget("one");
        assert_eq!(book.get().panes.len(), 1);
        assert_eq!(book.get().panes[0].id, "right");
    }

    #[test]
    fn an_empty_workspace_can_be_stored() {
        let dir = tempfile::tempdir().unwrap();
        let book = WorkspaceBook::open(dir.path().join("workspace.json"), &live(&[]));
        let stored = book.put(Workspace::empty(), &live(&[])).unwrap();
        assert_eq!(stored, Workspace::empty());
    }
}
