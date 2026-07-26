//! The merge state machine and its executor.
//!
//! [`classify`] is deliberately pure — no clock, no network, no database — so
//! every branch of the merge table can be asserted directly. [`Executor`] is
//! the only part that touches the world, and it does so under a strict rule:
//! the workspace mutex is taken and released inside [`Executor::ws`], never
//! held across an `.await`. (`rusqlite::Connection` is `!Sync`, so violating
//! that isn't a subtle bug — it doesn't compile.)

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::Value;

use crate::error::{AppError, AppResult};
use crate::notion::blocks_to_md::{render_page, Rendered, READONLY_MARKER};
use crate::notion::client::{self, list_children_deep, NotionApi};
use crate::notion::md_to_blocks::{parse_body, Desired};
use crate::notion::model::{iso8601_to_ms, strip_read_only, PageMeta};
use crate::notion::store::{self, CachedBlock, Link};
use crate::notion::{now_ms, sha256_hex, SyncReport, SyncReportItem};
use crate::workspace::{self, Workspace};

/// How deep to follow `has_children` when reading a page. Three levels is what
/// markdown list nesting can express; anything deeper is preserved as a
/// placeholder instead.
const FETCH_DEPTH: usize = 3;

// ---------------------------------------------------------------------------
// pure classification
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalState {
    pub hash: String,
    pub trashed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteState {
    pub last_edited: String,
    pub archived: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Baseline {
    pub local_hash: String,
    pub remote_edited: String,
    /// `ok` | `conflict` | `error` | `excluded`
    pub state: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictKind {
    BothChanged,
    RemoteDeleted,
    LocalDeleted,
}

impl ConflictKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ConflictKind::BothChanged => "both-changed",
            ConflictKind::RemoteDeleted => "remote-deleted",
            ConflictKind::LocalDeleted => "local-deleted",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Skip,
    Pull,
    Push,
    /// The remote timestamp moved, which only proves the page *might* have
    /// changed. Fetch its blocks and re-decide with [`classify_stage2`].
    MaybePull,
    CreateRemote,
    CreateLocal,
    ArchiveRemote,
    TrashLocal,
    Conflict(ConflictKind),
    /// A page carries a Nova id matching a local note that has no link — the
    /// mapping was lost (fresh install, deleted workspace.db) but the identity
    /// survived in Notion. Re-attach instead of importing a duplicate.
    Adopt,
    /// Content is in sync, but the page's Nova-owned columns (created /
    /// updated / id) don't hold the right values yet — typically right after
    /// the user turns one of them on.
    UpdateProps,
    /// Both sides are gone; the mapping is dead weight.
    DropLink,
}

/// Stage one. Cheap: compares a local content hash against the baseline, and a
/// remote timestamp against the baseline.
pub fn classify(
    local: Option<&LocalState>,
    remote: Option<&RemoteState>,
    base: Option<&Baseline>,
) -> Action {
    // A note the user has excluded, or one waiting on a conflict decision, is
    // frozen: touching either side would destroy the very thing being compared.
    if let Some(b) = base {
        if b.state == "excluded" || b.state == "conflict" {
            return Action::Skip;
        }
    }

    let local_live = local.filter(|l| !l.trashed);
    let remote_live = remote.filter(|r| !r.archived);

    let Some(base) = base else {
        return match (local_live, remote_live) {
            (Some(_), _) => Action::CreateRemote,
            (None, Some(_)) => Action::CreateLocal,
            // A trashed note that was never linked has no business on Notion.
            (None, None) => Action::Skip,
        };
    };

    let local_changed = local_live.is_some_and(|l| l.hash != base.local_hash);

    match (local_live, remote_live) {
        (None, None) => Action::DropLink,
        (Some(_), None) => {
            if local_changed {
                Action::Conflict(ConflictKind::RemoteDeleted)
            } else {
                Action::TrashLocal
            }
        }
        (None, Some(r)) => {
            if r.last_edited != base.remote_edited {
                Action::Conflict(ConflictKind::LocalDeleted)
            } else {
                Action::ArchiveRemote
            }
        }
        (Some(_), Some(r)) => {
            if r.last_edited != base.remote_edited {
                // Covers both "only remote moved" and "both moved" — the
                // timestamp can't tell them apart, so stage two settles it.
                Action::MaybePull
            } else if local_changed {
                Action::Push
            } else {
                Action::Skip
            }
        }
    }
}

/// Stage two, once the remote blocks have been rendered to markdown and hashed.
/// `remote_changed == false` with a moved timestamp is the common case: it's
/// the echo of our own push, or a metadata-only edit.
pub fn classify_stage2(local_changed: bool, remote_changed: bool) -> Action {
    match (local_changed, remote_changed) {
        (false, false) => Action::Skip,
        (true, false) => Action::Push,
        (false, true) => Action::Pull,
        (true, true) => Action::Conflict(ConflictKind::BothChanged),
    }
}

// ---------------------------------------------------------------------------
// executor
// ---------------------------------------------------------------------------

/// Borrowed access to the workspace. Implemented over the app's mutex in
/// `commands::notion`; tests supply a plain owned workspace.
pub trait WsAccess: Send + Sync {
    fn with_ws(&self, f: &mut dyn FnMut(&Workspace) -> AppResult<()>) -> AppResult<()>;
}

pub type ProgressFn<'a> = &'a (dyn Fn(usize, usize, &str) + Send + Sync);

pub struct Executor<'a> {
    pub api: &'a dyn NotionApi,
    pub access: &'a dyn WsAccess,
    pub cancel: &'a AtomicBool,
    pub progress: Option<ProgressFn<'a>>,
    pub dry_run: bool,
}

/// Why a note's file couldn't be read. `not_found` is worth distinguishing:
/// a vanished file is a stale row to clean up, not a sync failure.
struct ReadFailure {
    not_found: bool,
    detail: String,
}

/// One unit of work produced by planning.
struct Task {
    note_id: Option<String>,
    page_id: Option<String>,
    title: String,
    action: Action,
    /// Present when the note was read during planning (i.e. its mtime moved).
    local_content: Option<String>,
}

impl<'a> Executor<'a> {
    /// Runs `f` with the workspace locked, then releases. Never call across an
    /// `.await` — the whole point is that the guard dies inside this frame.
    fn ws<T>(&self, mut f: impl FnMut(&Workspace) -> AppResult<T>) -> AppResult<T> {
        let mut slot: Option<T> = None;
        self.access.with_ws(&mut |w| {
            slot = Some(f(w)?);
            Ok(())
        })?;
        slot.ok_or_else(|| AppError::Other("workspace closed mid-sync".into()))
    }

    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    fn report_progress(&self, done: usize, total: usize, current: &str) {
        if let Some(p) = self.progress {
            p(done, total, current);
        }
    }

    pub async fn run(&self) -> AppResult<SyncReport> {
        let mut report = SyncReport {
            dry_run: self.dry_run,
            ..Default::default()
        };
        let cfg = self.ws(store::get_config)?;
        let (_, database_id) = cfg.credentials()?;

        // Read the title property back rather than trusting the default:
        // writing to a renamed title property fails silently.
        let db = self.api.retrieve_database(&database_id).await?;
        let title_prop = db.title_prop.clone();
        let db_title = db.title.clone();
        self.ws(|w| {
            store::set_title_prop(w, &title_prop)?;
            let mut c = store::get_config(w)?;
            c.database_title = Some(db_title.clone());
            store::write_config(w, &c)
        })?;

        let props = self.resolve_props(&db, &cfg, &mut report).await?;

        // Cancelling during the index fetch is a normal outcome, not a failure
        // — the caller gets an empty-but-cancelled report either way.
        let remote = match self.fetch_remote_index(&database_id).await {
            Ok(r) => r,
            Err(AppError::SyncCancelled) => {
                report.cancelled = true;
                return Ok(report);
            }
            Err(e) => return Err(e),
        };
        let tasks = self.plan(&remote, &props, &mut report)?;
        let total = tasks.len();

        for (i, task) in tasks.into_iter().enumerate() {
            if self.cancelled() {
                report.cancelled = true;
                break;
            }
            self.report_progress(i, total, &task.title);
            let title = task.title.clone();
            let note_id = task.note_id.clone();
            let page_id = task.page_id.clone();
            if let Err(e) = self
                .execute(&task, &remote, &props, &database_id, &mut report)
                .await
            {
                if matches!(e, AppError::SyncCancelled) {
                    report.cancelled = true;
                    break;
                }
                let msg = e.to_string();
                if let Some(id) = &note_id {
                    let _ = self.ws(|w| store::set_link_state(w, id, "error", Some(&msg)));
                }
                report.push_item(SyncReportItem {
                    note_id,
                    page_id,
                    title,
                    kind: "error".into(),
                    severity: "error".into(),
                    message: Some(msg),
                });
            }
        }
        self.report_progress(total, total, "");
        Ok(report)
    }

    /// Works out which columns this run may write.
    ///
    /// A configured timestamp column that doesn't exist yet is created (a
    /// `date` property); one that exists with some other type is left alone and
    /// reported, because silently repurposing a user's column would be worse
    /// than not syncing the timestamp.
    async fn resolve_props(
        &self,
        db: &crate::notion::model::DbInfo,
        cfg: &store::NotionConfig,
        report: &mut SyncReport,
    ) -> AppResult<Props> {
        let mut props = Props {
            title: db.title_prop.clone(),
            ..Default::default()
        };
        let wanted = [
            (cfg.created_prop.clone(), "date"),
            (cfg.updated_prop.clone(), "date"),
            (cfg.id_prop.clone(), "rich_text"),
        ];
        let mut schema = db.properties.clone();
        let mut to_create = serde_json::Map::new();

        for (name, want_ty) in wanted.iter().filter(|(n, _)| n.is_some()) {
            let name = name.as_ref().unwrap();
            match schema.get(name.as_str()).map(String::as_str) {
                Some(ty) if ty == *want_ty => {}
                None => {}
                Some(other) => {
                    report.push_item(SyncReportItem {
                        note_id: None,
                        page_id: None,
                        title: name.clone(),
                        kind: "blocked".into(),
                        severity: "warn".into(),
                        message: Some(format!(
                            "The Notion property \"{}\" is a {}, not a {} — \
                             Nova left it alone and skipped writing to it.",
                            name, other, want_ty
                        )),
                    });
                    continue;
                }
            }
            if !schema.contains_key(name.as_str()) && !to_create.contains_key(name.as_str()) {
                to_create.insert(name.clone(), serde_json::json!({ *want_ty: {} }));
            }
        }

        if !to_create.is_empty() && !self.dry_run {
            let created: Vec<String> = to_create.keys().cloned().collect();
            let updated = self
                .api
                .add_database_properties(&db.id, Value::Object(to_create))
                .await?;
            schema = updated.properties;
            report.push_item(SyncReportItem {
                note_id: None,
                page_id: None,
                title: created.join(", "),
                kind: "info".into(),
                severity: "info".into(),
                message: Some(format!(
                    "Added propert{} {} to the Notion database.",
                    if created.len() == 1 { "y" } else { "ies" },
                    created.join(", ")
                )),
            });
        }

        let usable = |name: &Option<String>, want_ty: &str| -> Option<String> {
            let n = name.as_ref()?;
            match schema.get(n.as_str()).map(String::as_str) {
                Some(ty) if ty == want_ty => Some(n.clone()),
                // In a dry run the column was never actually created.
                None if self.dry_run => Some(n.clone()),
                _ => None,
            }
        };
        props.created = usable(&cfg.created_prop, "date");
        props.updated = usable(&cfg.updated_prop, "date");
        props.id = usable(&cfg.id_prop, "rich_text");
        Ok(props)
    }

    /// `(created_ms, updated_ms)` for a note, straight from the notes table.
    fn note_times(&self, note_id: &str) -> AppResult<(i64, i64)> {
        let id = note_id.to_string();
        self.ws(move |w| {
            let n = workspace::get_note(w, &id)?;
            Ok((n.created_ms, n.mtime_ms))
        })
    }

    fn created_ms(&self, note_id: &str) -> AppResult<i64> {
        Ok(self.note_times(note_id)?.0)
    }

    async fn fetch_remote_index(&self, database_id: &str) -> AppResult<HashMap<String, PageMeta>> {
        let mut out = HashMap::new();
        let mut cursor = None;
        loop {
            if self.cancelled() {
                return Err(AppError::SyncCancelled);
            }
            let list = self.api.query_database(database_id, cursor).await?;
            for p in list.pages {
                out.insert(p.id.clone(), p);
            }
            match list.next_cursor {
                Some(c) => cursor = Some(c),
                None => break,
            }
        }
        Ok(out)
    }

    /// Snapshots local state, runs [`classify`] over every note and page, and
    /// orders the result so remote-to-local work lands first (the user sees
    /// incoming changes sooner) and deletions last (least recoverable).
    fn plan(
        &self,
        remote: &HashMap<String, PageMeta>,
        props: &Props,
        report: &mut SyncReport,
    ) -> AppResult<Vec<Task>> {
        struct Snapshot {
            notes: Vec<store::NoteRow>,
            links: Vec<Link>,
            contents: HashMap<String, String>,
            hashes: HashMap<String, String>,
            /// note id -> why it couldn't be read
            unreadable: HashMap<String, ReadFailure>,
        }

        let snap = self.ws(|w| {
            let notes = store::list_note_rows(w)?;
            let links = store::list_links(w)?;
            let by_note: HashMap<&str, &Link> =
                links.iter().map(|l| (l.note_id.as_str(), l)).collect();
            let mut contents = HashMap::new();
            let mut hashes = HashMap::new();
            let mut unreadable = HashMap::new();
            for n in &notes {
                if n.trashed {
                    continue;
                }
                // Fast path: an untouched mtime means the baseline hash still
                // describes the file, so we can skip reading it entirely. The
                // existence check keeps a file that vanished from underneath us
                // from being reported as "unchanged" forever.
                if let Some(l) = by_note.get(n.id.as_str()) {
                    if l.base_local_mtime_ms == n.mtime_ms
                        && !l.base_local_hash.is_empty()
                        && w.note_path(&n.id).exists()
                    {
                        hashes.insert(n.id.clone(), l.base_local_hash.clone());
                        continue;
                    }
                }
                match std::fs::read_to_string(w.note_path(&n.id)) {
                    Ok(content) => {
                        hashes.insert(n.id.clone(), sha256_hex(&content));
                        contents.insert(n.id.clone(), content);
                    }
                    // Never fall back to empty content: that hashes as "the
                    // user cleared this note" and would push a blank page.
                    // Leave it out entirely so it's skipped, not destroyed.
                    Err(e) => {
                        unreadable.insert(
                            n.id.clone(),
                            ReadFailure {
                                not_found: e.kind() == std::io::ErrorKind::NotFound,
                                detail: e.to_string(),
                            },
                        );
                    }
                }
            }
            Ok(Snapshot {
                notes,
                links,
                contents,
                hashes,
                unreadable,
            })
        })?;

        let note_by_id: HashMap<&str, &store::NoteRow> =
            snap.notes.iter().map(|n| (n.id.as_str(), n)).collect();
        let mut linked_notes = std::collections::HashSet::new();
        let mut linked_pages = std::collections::HashSet::new();
        let mut tasks = Vec::new();

        // A note we couldn't read can't be compared or pushed safely; report it
        // and leave both sides alone.
        //
        // A *missing* file is the common case and isn't a sync failure — it's a
        // note row whose file went away (deleted outside Nova, lost to an
        // interrupted write). Calling that an error makes an otherwise clean
        // sync look broken, so it's a warning with an explanation instead.
        for (id, why) in &snap.unreadable {
            let gone = why.not_found;
            report.push_item(SyncReportItem {
                note_id: Some(id.clone()),
                page_id: None,
                title: note_by_id.get(id.as_str()).map_or("Untitled", |n| &n.title).to_string(),
                kind: if gone { "blocked" } else { "error" }.into(),
                severity: if gone { "warn" } else { "error" }.into(),
                message: Some(if gone {
                    "Skipped — this note's file is missing from the workspace \
                     folder, so there's nothing to sync. Delete the note to \
                     clear the warning."
                        .to_string()
                } else {
                    format!("Skipped — couldn't read the note's file: {}", why.detail)
                }),
            });
        }

        for link in &snap.links {
            linked_notes.insert(link.note_id.clone());
            if let Some(p) = &link.page_id {
                linked_pages.insert(p.clone());
            }
            if snap.unreadable.contains_key(&link.note_id) {
                continue;
            }
            let note = note_by_id.get(link.note_id.as_str());
            let local = note.map(|n| LocalState {
                hash: snap.hashes.get(&n.id).cloned().unwrap_or_default(),
                trashed: n.trashed,
            });
            let remote_state = link.page_id.as_ref().and_then(|p| remote.get(p)).map(|p| {
                RemoteState {
                    last_edited: p.last_edited_time.clone(),
                    archived: p.archived,
                }
            });
            let base = Baseline {
                local_hash: link.base_local_hash.clone(),
                remote_edited: link.base_remote_edited.clone(),
                state: link.state.clone(),
            };
            let mut action = classify(local.as_ref(), remote_state.as_ref(), Some(&base));
            if action == Action::Skip {
                // Content agrees, but the Nova-owned columns might not — this
                // is what backfills them when the user first turns them on,
                // instead of waiting for the note to be edited again.
                let stale = props.any_configured()
                    && match (note, link.page_id.as_ref().and_then(|p| remote.get(p))) {
                        (Some(n), Some(page)) if !n.trashed => {
                            !props.matches(page, n.created_ms, n.mtime_ms, &n.id)
                        }
                        _ => false,
                    };
                if !stale {
                    continue;
                }
                action = Action::UpdateProps;
            }
            let title = note
                .map(|n| n.title.clone())
                .or_else(|| {
                    link.page_id
                        .as_ref()
                        .and_then(|p| remote.get(p))
                        .map(|p| p.title.clone())
                })
                .unwrap_or_else(|| "Untitled".to_string());
            tasks.push(Task {
                note_id: Some(link.note_id.clone()),
                page_id: link.page_id.clone(),
                title,
                action,
                local_content: snap.contents.get(&link.note_id).cloned(),
            });
        }

        // Re-link first. An unlinked page that names a local note in its id
        // column belongs to that note; queuing the note for CreateRemote first
        // would publish a second page for it.
        let mut adopted_pages: std::collections::HashSet<String> = Default::default();
        if let Some(id_prop) = &props.id {
            for (page_id, page) in remote {
                if linked_pages.contains(page_id) || page.archived {
                    continue;
                }
                let Some(note_id) =
                    crate::notion::model::page_property_plain(&page.properties, id_prop)
                else {
                    continue;
                };
                if linked_notes.contains(&note_id) || snap.unreadable.contains_key(&note_id) {
                    continue;
                }
                let Some(n) = note_by_id.get(note_id.as_str()) else {
                    continue;
                };
                if n.trashed {
                    continue;
                }
                linked_notes.insert(note_id.clone());
                adopted_pages.insert(page_id.clone());
                tasks.push(Task {
                    note_id: Some(note_id.clone()),
                    page_id: Some(page_id.clone()),
                    title: n.title.clone(),
                    action: Action::Adopt,
                    local_content: snap.contents.get(&note_id).cloned(),
                });
            }
        }

        for n in &snap.notes {
            if linked_notes.contains(&n.id) || n.trashed || snap.unreadable.contains_key(&n.id) {
                continue;
            }
            tasks.push(Task {
                note_id: Some(n.id.clone()),
                page_id: None,
                title: n.title.clone(),
                action: Action::CreateRemote,
                local_content: snap.contents.get(&n.id).cloned(),
            });
        }

        for (id, page) in remote {
            if linked_pages.contains(id) || adopted_pages.contains(id) || page.archived {
                continue;
            }
            tasks.push(Task {
                note_id: None,
                page_id: Some(id.clone()),
                title: page.title.clone(),
                action: Action::CreateLocal,
                local_content: None,
            });
        }

        tasks.sort_by_key(|t| match t.action {
            Action::Adopt => 0,
            Action::Pull | Action::MaybePull | Action::CreateLocal => 1,
            Action::Push | Action::CreateRemote => 2,
            Action::Conflict(_) => 3,
            Action::UpdateProps => 4,
            _ => 5,
        });
        Ok(tasks)
    }

    async fn execute(
        &self,
        task: &Task,
        remote: &HashMap<String, PageMeta>,
        props: &Props,
        database_id: &str,
        report: &mut SyncReport,
    ) -> AppResult<()> {
        match &task.action {
            Action::Skip => Ok(()),
            Action::MaybePull => self.maybe_pull(task, remote, props, report).await,
            Action::Pull => {
                let page = self.page_of(task, remote)?;
                let expected = self.local_hash(task, task.note_id.as_deref().unwrap_or(""))?;
                let fetched = self.fetch_rendered(&page).await?;
                if !self.apply_pull(task, &page, &fetched, Some(&expected), report)? {
                    // Saved locally while we were fetching — both sides moved.
                    self.record_conflict(
                        task,
                        ConflictKind::BothChanged,
                        Some(&fetched.content),
                        report,
                    )?;
                }
                Ok(())
            }
            Action::Push => {
                let page = self.page_of(task, remote)?;
                self.push(task, &page, props, report).await
            }
            Action::CreateRemote => self.create_remote(task, props, database_id, report).await,
            Action::CreateLocal => {
                let page = self.page_of(task, remote)?;
                let fetched = self.fetch_rendered(&page).await?;
                self.create_local(&page, &fetched, report)
            }
            Action::ArchiveRemote => {
                let page_id = task.page_id.clone().unwrap_or_default();
                if !self.dry_run {
                    self.api.update_page(&page_id, None, Some(true)).await?;
                    if let Some(id) = &task.note_id {
                        self.ws(|w| store::delete_link(w, id))?;
                    }
                }
                report.push_item(self.item(task, "archived-remote", "info", None));
                Ok(())
            }
            Action::TrashLocal => {
                if !self.dry_run {
                    if let Some(id) = &task.note_id {
                        self.ws(|w| {
                            workspace::trash_note(w, id, now_ms())?;
                            store::delete_link(w, id)
                        })?;
                    }
                }
                report.push_item(self.item(task, "trashed-local", "info", None));
                Ok(())
            }
            Action::Adopt => {
                let page = self.page_of(task, remote)?;
                let note_id = task
                    .note_id
                    .clone()
                    .ok_or_else(|| AppError::Other("adopt without a note".into()))?;
                if self.dry_run {
                    report.push_item(self.item(task, "pulled", "info", Some(
                        "Would re-link this note to its existing Notion page.".into(),
                    )));
                    return Ok(());
                }
                let fetched = self.fetch_rendered(&page).await?;
                let local_hash = sha256_hex(&self.read_local(&note_id)?);
                self.ws(|w| store::upsert_link(w, &Link::new(&note_id, Some(&page.id))))?;
                if local_hash != fetched.hash {
                    // Both sides drifted while unlinked; neither wins by
                    // default.
                    return self.record_conflict(
                        task,
                        ConflictKind::BothChanged,
                        Some(&fetched.content),
                        report,
                    );
                }
                let blocks = fetched.unsupported.clone();
                let remote_hash = fetched.hash.clone();
                let page_owned = page.clone();
                let id = note_id.clone();
                self.ws(move |w| {
                    store::replace_blocks(w, &id, &blocks)?;
                    let mtime = std::fs::metadata(w.note_path(&id))
                        .map(|m| crate::fs_util::mtime_ms(&m))
                        .unwrap_or(0);
                    let mut link = Link::new(&id, Some(&page_owned.id));
                    link.base_local_hash = local_hash.clone();
                    link.base_local_mtime_ms = mtime;
                    link.base_remote_hash = remote_hash.clone();
                    link.base_remote_edited = page_owned.last_edited_time.clone();
                    link.last_synced_ms = now_ms();
                    link.push_mode = fetched_push_mode(blocks.iter());
                    store::upsert_link(w, &link)
                })?;
                report.push_item(self.item(
                    task,
                    "pulled",
                    "info",
                    Some("Re-linked to its existing Notion page.".into()),
                ));
                Ok(())
            }
            Action::UpdateProps => {
                let page = self.page_of(task, remote)?;
                let note_id = task
                    .note_id
                    .clone()
                    .ok_or_else(|| AppError::Other("property update without a note".into()))?;
                if !self.dry_run {
                    let (created_ms, updated_ms) = self.note_times(&note_id)?;
                    let title = crate::commands::workspace::first_line_title(
                        &self.read_local(&note_id)?,
                        "Untitled",
                    );
                    let updated = self
                        .api
                        .update_page(
                            &page.id,
                            Some(props.payload(&title, created_ms, updated_ms, &note_id)),
                            None,
                        )
                        .await?;
                    // Writing properties bumps `last_edited_time`; re-baseline
                    // it here so the next sync doesn't refetch the blocks just
                    // to discover nothing changed.
                    self.ws(|w| {
                        if let Some(mut link) = store::get_link(w, &note_id)? {
                            link.base_remote_edited = updated.last_edited_time.clone();
                            link.last_synced_ms = now_ms();
                            store::upsert_link(w, &link)?;
                        }
                        Ok(())
                    })?;
                }
                Ok(())
            }
            Action::DropLink => {
                if let Some(id) = &task.note_id {
                    self.ws(|w| store::delete_link(w, id))?;
                }
                Ok(())
            }
            Action::Conflict(kind) => {
                let kind = *kind;
                let remote_content = match kind {
                    ConflictKind::RemoteDeleted => None,
                    _ => {
                        let page = self.page_of(task, remote)?;
                        Some(self.fetch_rendered(&page).await?.content)
                    }
                };
                self.record_conflict(task, kind, remote_content.as_deref(), report)
            }
        }
    }

    fn page_of(&self, task: &Task, remote: &HashMap<String, PageMeta>) -> AppResult<PageMeta> {
        task.page_id
            .as_ref()
            .and_then(|p| remote.get(p))
            .cloned()
            .ok_or_else(|| AppError::Other("page vanished mid-sync".into()))
    }

    fn item(&self, task: &Task, kind: &str, severity: &str, message: Option<String>) -> SyncReportItem {
        SyncReportItem {
            note_id: task.note_id.clone(),
            page_id: task.page_id.clone(),
            title: task.title.clone(),
            kind: kind.into(),
            severity: severity.into(),
            message,
        }
    }

    // -- remote reading -----------------------------------------------------

    async fn fetch_rendered(&self, page: &PageMeta) -> AppResult<FetchedPage> {
        if self.cancelled() {
            return Err(AppError::SyncCancelled);
        }
        let blocks = list_children_deep(self.api, &page.id, FETCH_DEPTH).await?;
        Ok(FetchedPage::new(render_page(&page.title, &blocks)))
    }

    async fn maybe_pull(
        &self,
        task: &Task,
        remote: &HashMap<String, PageMeta>,
        props: &Props,
        report: &mut SyncReport,
    ) -> AppResult<()> {
        let page = self.page_of(task, remote)?;
        let note_id = task
            .note_id
            .clone()
            .ok_or_else(|| AppError::Other("maybe-pull without a note".into()))?;
        let link = self
            .ws(|w| store::get_link(w, &note_id))?
            .ok_or_else(|| AppError::Other("link vanished mid-sync".into()))?;
        let fetched = self.fetch_rendered(&page).await?;

        let local_hash = self.local_hash(task, &note_id)?;
        let local_changed = local_hash != link.base_local_hash;
        let remote_changed = fetched.hash != link.base_remote_hash;

        match classify_stage2(local_changed, remote_changed) {
            // The timestamp moved but the content didn't — our own push echoing
            // back, or a property edit. Re-baseline the timestamp so the next
            // sync short-circuits at stage one.
            Action::Skip => {
                let mut l = link;
                l.base_remote_edited = page.last_edited_time.clone();
                l.last_synced_ms = now_ms();
                self.ws(|w| store::upsert_link(w, &l))
            }
            Action::Pull => {
                if self.apply_pull(task, &page, &fetched, Some(&local_hash), report)? {
                    Ok(())
                } else {
                    self.record_conflict(
                        task,
                        ConflictKind::BothChanged,
                        Some(&fetched.content),
                        report,
                    )
                }
            }
            Action::Push => self.push(task, &page, props, report).await,
            _ => self.record_conflict(
                task,
                ConflictKind::BothChanged,
                Some(&fetched.content),
                report,
            ),
        }
    }

    fn local_hash(&self, task: &Task, note_id: &str) -> AppResult<String> {
        if let Some(c) = &task.local_content {
            return Ok(sha256_hex(c));
        }
        // Planning skipped the read because the mtime hadn't moved.
        Ok(sha256_hex(&self.read_local(note_id)?))
    }

    /// Reads a note from disk. Deliberately *not* lenient: treating an
    /// unreadable file as empty would hash as "the user deleted everything"
    /// and push a blank body over their Notion page.
    fn read_local(&self, note_id: &str) -> AppResult<String> {
        let id = note_id.to_string();
        self.ws(move |w| {
            let path = w.note_path(&id);
            std::fs::read_to_string(&path).map_err(|e| {
                AppError::Other(format!("could not read {}: {}", path.display(), e))
            })
        })
    }

    // -- actions ------------------------------------------------------------

    /// Writes the remote version over the local file.
    ///
    /// `expect_local` is the content hash the merge decision was based on.
    /// Fetching a page takes seconds, and the user may have saved in the
    /// meantime — writing anyway would destroy an edit the engine never
    /// compared against anything. On a mismatch this applies nothing and
    /// returns `false`, so the caller can raise a conflict instead.
    fn apply_pull(
        &self,
        task: &Task,
        page: &PageMeta,
        fetched: &FetchedPage,
        expect_local: Option<&str>,
        report: &mut SyncReport,
    ) -> AppResult<bool> {
        let note_id = task
            .note_id
            .clone()
            .ok_or_else(|| AppError::Other("pull without a note".into()))?;
        if !self.dry_run {
            let content = fetched.content.clone();
            let title = fetched.title();
            let blocks = fetched.unsupported.clone();
            let page = page.clone();
            let id = note_id.clone();
            let expect_local = expect_local.map(str::to_string);
            let applied = self.ws(move |w| {
                if let Some(expected) = &expect_local {
                    let disk = std::fs::read_to_string(w.note_path(&id)).unwrap_or_default();
                    if &sha256_hex(&disk) != expected {
                        return Ok(false);
                    }
                }
                store::replace_blocks(w, &id, &blocks)?;
                let (mtime, _) = workspace::apply_remote_content(w, &id, &content, &title)?;
                let mut link = store::get_link(w, &id)?.unwrap_or_else(|| Link::new(&id, None));
                link.page_id = Some(page.id.clone());
                // Local and remote now render to the same markdown, which is
                // exactly what a baseline means.
                link.base_local_hash = sha256_hex(&content);
                link.base_local_mtime_ms = mtime;
                link.base_remote_hash = sha256_hex(&content);
                link.base_remote_edited = page.last_edited_time.clone();
                link.last_synced_ms = now_ms();
                link.push_mode = fetched_push_mode(blocks.iter());
                link.state = "ok".into();
                link.last_error = None;
                store::upsert_link(w, &link)?;
                Ok(true)
            })?;
            if !applied {
                return Ok(false);
            }
        }
        report.changed_note_ids.push(note_id);
        report.push_item(self.item(task, "pulled", "info", None));
        Ok(true)
    }

    fn create_local(
        &self,
        page: &PageMeta,
        fetched: &FetchedPage,
        report: &mut SyncReport,
    ) -> AppResult<()> {
        let note_id = uuid::Uuid::new_v4().to_string();
        let mut task = Task {
            note_id: Some(note_id.clone()),
            page_id: Some(page.id.clone()),
            title: fetched.title(),
            action: Action::CreateLocal,
            local_content: None,
        };
        if !self.dry_run {
            let content = fetched.content.clone();
            let title = fetched.title();
            let blocks = fetched.unsupported.clone();
            let page = page.clone();
            let id = note_id.clone();
            let created = iso8601_to_ms(&page.created_time).unwrap_or_else(now_ms);
            self.ws(move |w| {
                // Same ordering as `create_note`: the row has to exist before
                // `note_path` can resolve the slug-based filename.
                let note = workspace::Note {
                    id: id.clone(),
                    title: title.clone(),
                    created_ms: created,
                    mtime_ms: created,
                    size: content.len() as i64,
                };
                workspace::insert_note(w, &note, &content)?;
                store::replace_blocks(w, &id, &blocks)?;
                let (mtime, _) = workspace::apply_remote_content(w, &id, &content, &title)?;
                let mut link = Link::new(&id, Some(&page.id));
                link.base_local_hash = sha256_hex(&content);
                link.base_local_mtime_ms = mtime;
                link.base_remote_hash = sha256_hex(&content);
                link.base_remote_edited = page.last_edited_time.clone();
                link.last_synced_ms = now_ms();
                link.push_mode = fetched_push_mode(blocks.iter());
                store::upsert_link(w, &link)
            })?;
        }
        task.title = fetched.title();
        report.changed_note_ids.push(note_id);
        report.push_item(self.item(&task, "created-local", "info", None));
        Ok(())
    }

    async fn push(
        &self,
        task: &Task,
        page: &PageMeta,
        props: &Props,
        report: &mut SyncReport,
    ) -> AppResult<()> {
        let note_id = task
            .note_id
            .clone()
            .ok_or_else(|| AppError::Other("push without a note".into()))?;
        let link = self
            .ws(|w| store::get_link(w, &note_id))?
            .ok_or_else(|| AppError::Other("link vanished mid-sync".into()))?;

        if link.is_blocked() {
            // Rebuilding would destroy a block we can't recreate, so the local
            // edit stays local. The baseline is intentionally left untouched so
            // the warning keeps reappearing until the user resolves it.
            report.push_item(self.item(
                task,
                "blocked",
                "warn",
                Some(
                    "This page contains a block Nova can't recreate (synced block, \
                     sub-page, or Notion-hosted file), so local edits can't be \
                     pushed. Adopt the Notion version to unblock it."
                        .into(),
                ),
            ));
            return Ok(());
        }

        let content = match &task.local_content {
            Some(c) => c.clone(),
            None => self.read_local(&note_id)?,
        };
        if self.dry_run {
            report.push_item(self.item(task, "pushed", "info", None));
            return Ok(());
        }
        let outcome = self
            .rebuild_page(&note_id, &page.id, &content, props)
            .await?;
        // Placeholder ids changed, so any open tab is showing stale text and
        // its next save would trip the mtime check.
        if outcome.file_rewritten {
            report.changed_note_ids.push(note_id);
        }
        report.push_item(self.item(task, "pushed", "info", None));
        if outcome.orphaned > 0 {
            report.push_item(self.item(
                task,
                "blocked",
                "warn",
                Some(format!(
                    "Couldn't remove {} old block(s) from the Notion page; \
                     you may see the previous version below the new one.",
                    outcome.orphaned
                )),
            ));
        }
        Ok(())
    }

    async fn create_remote(
        &self,
        task: &Task,
        props: &Props,
        database_id: &str,
        report: &mut SyncReport,
    ) -> AppResult<()> {
        let note_id = task
            .note_id
            .clone()
            .ok_or_else(|| AppError::Other("create without a note".into()))?;
        let content = match &task.local_content {
            Some(c) => c.clone(),
            None => self.read_local(&note_id)?,
        };
        if self.dry_run {
            report.push_item(self.item(task, "created-remote", "info", None));
            return Ok(());
        }
        let title = crate::commands::workspace::first_line_title(&content, "Untitled");
        // Created empty, then filled by the same rebuild path as a push, so the
        // block-id bookkeeping has exactly one implementation.
        let page = self
            .api
            .create_page(
                database_id,
                props.payload(&title, self.created_ms(&note_id)?, now_ms(), &note_id),
                Vec::new(),
            )
            .await?;
        self.ws(|w| store::upsert_link(w, &Link::new(&note_id, Some(&page.id))))?;
        let outcome = self
            .rebuild_page(&note_id, &page.id, &content, props)
            .await?;
        if outcome.file_rewritten {
            report.changed_note_ids.push(note_id);
        }
        let mut done = self.item(task, "created-remote", "info", None);
        done.page_id = Some(page.id);
        report.push_item(done);
        Ok(())
    }

    /// Replaces a page's body with the local markdown, replaying cached blocks
    /// for every placeholder, then re-reads the page to set a fresh baseline.
    ///
    /// Notion has no move API and `append_children` can't insert at the front,
    /// so replacing a body means writing all of it and removing all of the old.
    /// The order is deliberate: **append first, delete second.** Appending onto
    /// a live page is recoverable (worst case the user sees the new copy below
    /// the old one); deleting first and then failing to append would leave them
    /// with an empty page and nothing but Notion's 30-day trash. Deleted blocks
    /// still land in that trash either way.
    async fn rebuild_page(
        &self,
        note_id: &str,
        page_id: &str,
        content: &str,
        props: &Props,
    ) -> AppResult<RebuildOutcome> {
        // The entire file — heading included — becomes the page body. The
        // title property is a derived label; keeping the heading out of the
        // body would silently truncate any note whose first line is longer
        // than the label cap.
        let title = crate::commands::workspace::first_line_title(content, "Untitled");
        let desired = parse_body(content);
        let cached = self.ws(|w| store::list_blocks(w, note_id))?;
        let cache_by_id: HashMap<String, CachedBlock> =
            cached.into_iter().map(|b| (b.block_id.clone(), b)).collect();

        // Entries are 1:1 with the payload we send, so `append_children`'s
        // ordered response lets us map new ids back onto the placeholders.
        let mut payload: Vec<Value> = Vec::new();
        let mut restored_old_ids: Vec<Option<String>> = Vec::new();
        for d in &desired {
            match d {
                Desired::Block(v) => {
                    payload.push(v.clone());
                    restored_old_ids.push(None);
                }
                Desired::Restore(old_id) => {
                    // A placeholder with no cache entry refers to a block that
                    // no longer exists (copied in from another note, say).
                    // Dropping it is the only honest option.
                    if let Some(b) = cache_by_id.get(old_id) {
                        if let Ok(raw) = serde_json::from_str::<Value>(&b.raw_json) {
                            payload.push(strip_read_only(&raw));
                            restored_old_ids.push(Some(old_id.clone()));
                        }
                    }
                }
            }
        }

        // Snapshot the current children before touching anything, so we know
        // exactly what to remove afterwards and what to roll back to on failure.
        let existing: Vec<String> = self
            .api
            .list_children(page_id)
            .await?
            .iter()
            .filter_map(|b| b.get("id").and_then(Value::as_str).map(str::to_string))
            .collect();

        let created = if payload.is_empty() {
            Vec::new()
        } else {
            match self.api.append_children(page_id, payload).await {
                Ok(c) => c,
                Err(e) => {
                    // A multi-chunk append can fail partway. Remove whatever
                    // landed so the page is left exactly as we found it, then
                    // report the original error.
                    self.discard_blocks_not_in(page_id, &existing).await;
                    return Err(e);
                }
            }
        };
        // Now the old copy can go. A failure here is not data loss — the new
        // content is already on the page — so keep going and let the freshly
        // read baseline below describe whatever actually survived. That keeps
        // the next sync from mistaking leftovers for a remote edit.
        let mut orphaned = 0usize;
        for id in &existing {
            if self.api.delete_block(id).await.is_err() {
                orphaned += 1;
            }
        }

        // Placeholders now point at freed block ids; rewrite them in the file
        // before hashing, or the next sync sees a phantom local change.
        let mut id_map: HashMap<String, String> = HashMap::new();
        for (i, old) in restored_old_ids.iter().enumerate() {
            if let (Some(old), Some(new)) = (
                old,
                created.get(i).and_then(|v| v.get("id")).and_then(Value::as_str),
            ) {
                if old != new {
                    id_map.insert(old.clone(), new.to_string());
                }
            }
        }
        // What we actually put on Notion, expressed as local markdown. This —
        // not whatever is on disk right now — is the state the remote matches,
        // so it is what the local baseline has to describe.
        let pushed = rewrite_placeholder_ids(content, &id_map);
        let pushed_hash = sha256_hex(&pushed);

        let note_id_owned = note_id.to_string();
        let content = content.to_string();
        // Settle the local file BEFORE publishing properties: the "Updated"
        // column has to describe the mtime the push actually leaves behind, or
        // every following sync would see a stale value and re-write it forever.
        let (file_rewritten, local_mtime, raced) =
            self.write_back(&note_id_owned, &content, &pushed, &id_map)?;

        let (created_ms, _) = self.note_times(note_id)?;
        self.api
            .update_page(
                page_id,
                Some(props.payload(&title, created_ms, local_mtime, note_id)),
                None,
            )
            .await?;

        let page = self.api.retrieve_page(page_id).await?;
        let fetched = self.fetch_rendered(&page).await?;

        let note_id = note_id_owned;
        let unsupported = fetched.unsupported.clone();
        let remote_hash = fetched.hash.clone();
        self.ws(move |w| {
            store::replace_blocks(w, &note_id, &unsupported)?;
            let mut link =
                store::get_link(w, &note_id)?.unwrap_or_else(|| Link::new(&note_id, Some(page_id)));
            link.page_id = Some(page.id.clone());
            link.base_local_hash = pushed_hash.clone();
            // Zeroing the mtime defeats the planner's "file untouched" fast
            // path, forcing it to re-read and notice the racing edit.
            link.base_local_mtime_ms = if raced { 0 } else { local_mtime };
            link.base_remote_hash = remote_hash.clone();
            link.base_remote_edited = page.last_edited_time.clone();
            link.last_synced_ms = now_ms();
            link.push_mode = fetched_push_mode(unsupported.iter());
            link.state = "ok".into();
            link.last_error = None;
            store::upsert_link(w, &link)
        })?;

        Ok(RebuildOutcome {
            file_rewritten,
            orphaned,
        })
    }

    /// Writes the pushed markdown back to disk, rewriting placeholder ids.
    ///
    /// Returns `(file_rewritten, mtime, raced)`. `raced` means the file changed
    /// while the push was in flight: the user's newer text is kept, but the
    /// baseline must still describe what went to Notion so the edit stays
    /// queued.
    fn write_back(
        &self,
        note_id: &str,
        pushed_from: &str,
        pushed: &str,
        id_map: &HashMap<String, String>,
    ) -> AppResult<(bool, i64, bool)> {
        let note_id = note_id.to_string();
        let pushed_from = pushed_from.to_string();
        let pushed = pushed.to_string();
        let id_map = id_map.clone();
        self.ws(move |w| {
            let path = w.note_path(&note_id);
            let disk = std::fs::read_to_string(&path).unwrap_or_default();
            let raced = disk != pushed_from;
            let to_write = if raced {
                rewrite_placeholder_ids(&disk, &id_map)
            } else {
                pushed.clone()
            };
            if to_write != disk {
                let title = crate::commands::workspace::first_line_title(&to_write, "Untitled");
                let (mtime, _) = workspace::apply_remote_content(w, &note_id, &to_write, &title)?;
                return Ok((true, mtime, raced));
            }
            let mtime = std::fs::metadata(&path)
                .map(|m| crate::fs_util::mtime_ms(&m))
                .unwrap_or(0);
            Ok((false, mtime, raced))
        })
    }

    /// Best-effort removal of blocks that appeared on a page since `keep` was
    /// captured. Used to undo a partially-applied append.
    async fn discard_blocks_not_in(&self, page_id: &str, keep: &[String]) {
        let Ok(now) = self.api.list_children(page_id).await else {
            return;
        };
        for b in now {
            let Some(id) = b.get("id").and_then(Value::as_str) else {
                continue;
            };
            if !keep.iter().any(|k| k == id) {
                let _ = self.api.delete_block(id).await;
            }
        }
    }

    fn record_conflict(
        &self,
        task: &Task,
        kind: ConflictKind,
        remote_content: Option<&str>,
        report: &mut SyncReport,
    ) -> AppResult<()> {
        let note_id = task
            .note_id
            .clone()
            .ok_or_else(|| AppError::Other("conflict without a note".into()))?;
        if !self.dry_run {
            let local_content = match kind {
                ConflictKind::LocalDeleted => None,
                _ => Some(match &task.local_content {
                    Some(c) => c.clone(),
                    None => self.read_local(&note_id)?,
                }),
            };
            let remote_owned = remote_content.map(str::to_string);
            let page_id = task.page_id.clone();
            let local_title = local_content
                .as_deref()
                .map(|c| crate::commands::workspace::first_line_title(c, "Untitled"));
            let remote_title = remote_owned
                .as_deref()
                .map(|c| crate::commands::workspace::first_line_title(c, "Untitled"));
            let id = note_id.clone();
            self.ws(move |w| {
                store::upsert_conflict(
                    w,
                    &id,
                    page_id.as_deref(),
                    kind.as_str(),
                    local_content.as_deref(),
                    remote_owned.as_deref(),
                    local_title.as_deref(),
                    remote_title.as_deref(),
                    now_ms(),
                )?;
                // Freezing the link is what stops later syncs from stomping on
                // either side while the user decides.
                store::set_link_state(w, &id, "conflict", None)
            })?;
        }
        report.push_item(self.item(
            task,
            "conflict",
            "warn",
            Some(match kind {
                ConflictKind::BothChanged => "Edited in both Nova and Notion.".into(),
                ConflictKind::RemoteDeleted => {
                    "Deleted in Notion but edited in Nova.".to_string()
                }
                ConflictKind::LocalDeleted => "Deleted in Nova but edited in Notion.".to_string(),
            }),
        ));
        Ok(())
    }

    // -- conflict resolution ------------------------------------------------

    /// Applies the user's choice to a single note. Runs the same primitives as
    /// a full sync rather than re-planning everything, so resolving is fast and
    /// can't cascade into unrelated notes.
    pub async fn resolve(&self, note_id: &str, resolution: &str) -> AppResult<Vec<String>> {
        let (props, database_id) = self.resolve_context().await?;
        self.resolve_with(note_id, resolution, &props, &database_id)
            .await
    }

    /// The database schema this resolution will write against. Read once and
    /// shared, so resolving twenty conflicts doesn't fetch it twenty times.
    async fn resolve_context(&self) -> AppResult<(Props, String)> {
        let cfg = self.ws(store::get_config)?;
        let (_, database_id) = cfg.credentials()?;
        // Re-read the schema: the extra columns may have been configured (or
        // renamed in Notion) since the last full sync.
        let db = self.api.retrieve_database(&database_id).await?;
        let mut discard = SyncReport::default();
        let props = self.resolve_props(&db, &cfg, &mut discard).await?;
        Ok((props, database_id))
    }

    /// Applies one policy to every outstanding conflict.
    ///
    /// Each conflict is resolved independently: a failure is recorded and the
    /// rest still go through, because a half-applied bulk action the user can
    /// retry beats an all-or-nothing one that strands them.
    pub async fn resolve_all(&self, policy: &str) -> AppResult<BulkResolve> {
        let conflicts = self.ws(store::list_conflicts)?;
        let (props, database_id) = self.resolve_context().await?;
        let mut out = BulkResolve::default();
        for c in conflicts {
            if self.cancelled() {
                out.cancelled = true;
                break;
            }
            let resolution = resolution_for(&c.kind, policy)?;
            let title = c
                .local_title
                .clone()
                .or_else(|| c.remote_title.clone())
                .unwrap_or_else(|| "Untitled".to_string());
            match self
                .resolve_with(&c.note_id, resolution, &props, &database_id)
                .await
            {
                Ok(ids) => {
                    out.resolved += 1;
                    out.changed_note_ids.extend(ids);
                }
                Err(e) => {
                    out.failed += 1;
                    out.errors.push(SyncReportItem {
                        note_id: Some(c.note_id.clone()),
                        page_id: c.page_id.clone(),
                        title,
                        kind: "error".into(),
                        severity: "error".into(),
                        message: Some(e.to_string()),
                    });
                }
            }
        }
        Ok(out)
    }

    async fn resolve_with(
        &self,
        note_id: &str,
        resolution: &str,
        props: &Props,
        database_id: &str,
    ) -> AppResult<Vec<String>> {
        let detail = self
            .ws(|w| store::get_conflict(w, note_id))?
            .ok_or_else(|| AppError::Other("no such conflict".into()))?;
        let database_id = database_id.to_string();
        let page_id = detail.summary.page_id.clone();
        let mut changed = Vec::new();

        // Every branch below finishes its work *before* clearing the conflict.
        // Deleting the row first would mean a mid-flight failure loses both the
        // conflict and its snapshot of the remote side, leaving nothing applied
        // and nothing to retry from.
        match resolution {
            "keepLocal" | "keepBoth" => {
                self.ensure_pushable(note_id)?;
                if resolution == "keepBoth" {
                    if let Some(remote) = &detail.remote_content {
                        changed.push(self.fork_remote_copy(remote)?);
                    }
                }
                let content = self.read_local(note_id)?;
                let outcome = match page_id {
                    Some(p) => self.rebuild_page(note_id, &p, &content, &props).await?,
                    None => {
                        let title =
                            crate::commands::workspace::first_line_title(&content, "Untitled");
                        let page = self
                            .api
                            .create_page(
                                &database_id,
                                props.payload(&title, self.created_ms(note_id)?, now_ms(), note_id),
                                Vec::new(),
                            )
                            .await?;
                        self.ws(|w| store::upsert_link(w, &Link::new(note_id, Some(&page.id))))?;
                        self.rebuild_page(note_id, &page.id, &content, &props)
                            .await?
                    }
                };
                if outcome.file_rewritten {
                    changed.push(note_id.to_string());
                }
                self.clear_conflict(note_id)?;
            }
            "keepRemote" => {
                let page_id = page_id
                    .ok_or_else(|| AppError::Other("the Notion page no longer exists".into()))?;
                let page = self.api.retrieve_page(&page_id).await?;
                let fetched = self.fetch_rendered(&page).await?;
                let task = Task {
                    note_id: Some(note_id.to_string()),
                    page_id: Some(page_id),
                    title: fetched.title(),
                    action: Action::Pull,
                    local_content: None,
                };
                let mut report = SyncReport::default();
                // No expected-hash guard: the user looked at both sides and
                // chose this one, so a newer local save loses on purpose.
                self.apply_pull(&task, &page, &fetched, None, &mut report)?;
                self.clear_conflict(note_id)?;
                changed.push(note_id.to_string());
            }
            "recreateRemote" => {
                self.ensure_pushable(note_id)?;
                let content = self.read_local(note_id)?;
                let title = crate::commands::workspace::first_line_title(&content, "Untitled");
                let page = self
                    .api
                    .create_page(
                        &database_id,
                        props.payload(&title, self.created_ms(note_id)?, now_ms(), note_id),
                        Vec::new(),
                    )
                    .await?;
                self.ws(|w| store::upsert_link(w, &Link::new(note_id, Some(&page.id))))?;
                let outcome = self
                    .rebuild_page(note_id, &page.id, &content, &props)
                    .await?;
                if outcome.file_rewritten {
                    changed.push(note_id.to_string());
                }
                self.clear_conflict(note_id)?;
            }
            "restoreLocal" => {
                let page_id = page_id
                    .ok_or_else(|| AppError::Other("the Notion page no longer exists".into()))?;
                let id = note_id.to_string();
                self.ws(move |w| workspace::restore_note(w, &id, now_ms()))?;
                let page = self.api.retrieve_page(&page_id).await?;
                let fetched = self.fetch_rendered(&page).await?;
                let task = Task {
                    note_id: Some(note_id.to_string()),
                    page_id: Some(page_id),
                    title: fetched.title(),
                    action: Action::Pull,
                    local_content: None,
                };
                let mut report = SyncReport::default();
                self.apply_pull(&task, &page, &fetched, None, &mut report)?;
                self.clear_conflict(note_id)?;
                changed.push(note_id.to_string());
            }
            "acceptRemoteDelete" => {
                let id = note_id.to_string();
                self.ws(move |w| {
                    store::delete_conflict(w, &id)?;
                    workspace::trash_note(w, &id, now_ms())?;
                    store::delete_link(w, &id)
                })?;
                changed.push(note_id.to_string());
            }
            "acceptLocalDelete" => {
                if let Some(p) = page_id {
                    self.api.update_page(&p, None, Some(true)).await?;
                }
                let id = note_id.to_string();
                self.ws(move |w| {
                    store::delete_conflict(w, &id)?;
                    store::delete_link(w, &id)
                })?;
            }
            other => {
                return Err(AppError::Other(format!("unknown resolution '{}'", other)));
            }
        }
        Ok(changed)
    }

    /// Rejects resolutions that would rebuild a page holding a block we can't
    /// recreate. `push` already refuses these; without the same guard here the
    /// conflict resolver would be a way to destroy them anyway.
    fn ensure_pushable(&self, note_id: &str) -> AppResult<()> {
        let blocked = self
            .ws(|w| store::get_link(w, note_id))?
            .is_some_and(|l| l.is_blocked());
        if blocked {
            return Err(AppError::Other(
                "This page contains a block Nova can't recreate (synced block, \
                 sub-page, or Notion-hosted file), so the Nova version can't be \
                 written back. Use the Notion version instead."
                    .into(),
            ));
        }
        Ok(())
    }

    fn clear_conflict(&self, note_id: &str) -> AppResult<()> {
        let id = note_id.to_string();
        self.ws(move |w| {
            store::delete_conflict(w, &id)?;
            store::set_link_state(w, &id, "ok", None)
        })
    }

    /// "Keep both": the Notion side becomes a brand-new, unlinked note, which
    /// the next sync will publish as its own page.
    fn fork_remote_copy(&self, remote_content: &str) -> AppResult<String> {
        let id = uuid::Uuid::new_v4().to_string();
        let title = crate::commands::workspace::first_line_title(remote_content, "Untitled");
        let forked_title = format!("{} (Notion)", title);
        // Replace only the heading line; the rest of the note carries over
        // verbatim so nothing is lost to the fork.
        let rest: String = remote_content
            .split_once('\n')
            .map(|(_, tail)| tail.to_string())
            .unwrap_or_default();
        let content = format!("# {}\n{}", forked_title, rest);
        let new_id = id.clone();
        self.ws(move |w| {
            let note = workspace::Note {
                id: id.clone(),
                title: forked_title.clone(),
                created_ms: now_ms(),
                mtime_ms: now_ms(),
                size: content.len() as i64,
            };
            workspace::insert_note(w, &note, &content)?;
            workspace::apply_remote_content(w, &id, &content, &forked_title)?;
            Ok(())
        })?;
        Ok(new_id)
    }
}

/// The database columns this sync will write, resolved once per run against
/// the live schema. The timestamp columns are `None` when the user hasn't
/// configured them, or when they exist with an incompatible type.
#[derive(Debug, Clone, Default)]
pub struct Props {
    pub title: String,
    pub created: Option<String>,
    pub updated: Option<String>,
    /// Holds the note's uuid, giving a page an identity independent of its
    /// title — two notes can share a title, but never an id.
    pub id: Option<String>,
}

impl Props {
    /// Builds the Notion properties payload for one note.
    pub fn payload(&self, title: &str, created_ms: i64, updated_ms: i64, note_id: &str) -> Value {
        let mut parts = vec![client::title_property(&self.title, title)];
        if let Some(p) = &self.created {
            parts.push(client::date_property(p, created_ms));
        }
        if let Some(p) = &self.updated {
            parts.push(client::date_property(p, updated_ms));
        }
        if let Some(p) = &self.id {
            parts.push(client::text_property(p, note_id));
        }
        client::merge_properties(parts)
    }

    pub fn any_configured(&self) -> bool {
        self.created.is_some() || self.updated.is_some() || self.id.is_some()
    }

    /// True when the page's stored values already match what we'd write.
    /// Lets an untouched note skip a pointless `update_page` round-trip.
    pub fn matches(&self, page: &PageMeta, created_ms: i64, updated_ms: i64, note_id: &str) -> bool {
        let date_ok = |name: &Option<String>, ms: i64| match name {
            None => true,
            Some(n) => page
                .properties
                .get(n)
                .and_then(|p| p.pointer("/date/start"))
                .and_then(Value::as_str)
                .is_some_and(|got| {
                    // Notion echoes back the instant it stored, which may be
                    // normalised (offset, dropped millis) — compare by value.
                    crate::notion::model::iso8601_to_ms(got) == Some(ms)
                }),
        };
        date_ok(&self.created, created_ms)
            && date_ok(&self.updated, updated_ms)
            && match &self.id {
                None => true,
                Some(n) => {
                    crate::notion::model::page_property_plain(&page.properties, n).as_deref()
                        == Some(note_id)
                }
            }
    }
}

/// Outcome of applying one policy to every outstanding conflict.
#[derive(Debug, Clone, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BulkResolve {
    pub resolved: i64,
    pub failed: i64,
    pub cancelled: bool,
    pub changed_note_ids: Vec<String>,
    pub errors: Vec<SyncReportItem>,
}

/// Maps a bulk policy onto the concrete resolution for one conflict kind.
///
/// The three policies are the only ones that mean the same thing across every
/// kind: "Nova wins", "Notion wins", and "lose nothing". A deletion has no
/// "keep both", so `keepBoth` falls back to the non-destructive side.
pub fn resolution_for(kind: &str, policy: &str) -> AppResult<&'static str> {
    Ok(match (policy, kind) {
        ("local", "both-changed") => "keepLocal",
        ("local", "remote-deleted") => "recreateRemote",
        ("local", "local-deleted") => "restoreLocal",
        ("remote", "both-changed") => "keepRemote",
        ("remote", "remote-deleted") => "acceptRemoteDelete",
        ("remote", "local-deleted") => "acceptLocalDelete",
        ("both", "both-changed") => "keepBoth",
        ("both", "remote-deleted") => "recreateRemote",
        ("both", "local-deleted") => "restoreLocal",
        _ => {
            return Err(AppError::Other(format!(
                "unknown bulk policy '{}' for a '{}' conflict",
                policy, kind
            )))
        }
    })
}

/// What a rebuild did, beyond succeeding.
pub struct RebuildOutcome {
    /// The note file on disk was rewritten (placeholder ids changed), so an
    /// open tab showing it is now stale.
    pub file_rewritten: bool,
    /// Old blocks we failed to delete after appending the new ones. Not data
    /// loss — the page just shows the previous copy underneath.
    pub orphaned: usize,
}

/// A page fetched and rendered, with the marker line already folded in so the
/// hash describes exactly what lands on disk.
pub struct FetchedPage {
    pub content: String,
    pub hash: String,
    pub unsupported: Vec<CachedBlock>,
}

impl FetchedPage {
    fn new(r: Rendered) -> Self {
        let content = if r.has_unrecreatable {
            insert_readonly_marker(&r.markdown)
        } else {
            r.markdown
        };
        Self {
            hash: sha256_hex(&content),
            content,
            unsupported: r.unsupported,
        }
    }

    fn title(&self) -> String {
        crate::commands::workspace::first_line_title(&self.content, "Untitled")
    }
}

fn fetched_push_mode<'a>(blocks: impl Iterator<Item = &'a CachedBlock>) -> String {
    if blocks.into_iter().any(|b| !b.recreatable) {
        "blocked".into()
    } else {
        "rebuild".into()
    }
}

/// Puts the read-only notice directly under the title so the user sees it in
/// the first screenful.
fn insert_readonly_marker(md: &str) -> String {
    let mut lines = md.lines();
    let Some(first) = lines.next() else {
        return md.to_string();
    };
    let rest: Vec<&str> = lines.skip_while(|l| l.trim().is_empty()).collect();
    let mut out = format!("{}\n\n{}\n", first, READONLY_MARKER);
    if !rest.is_empty() {
        out.push('\n');
        out.push_str(&rest.join("\n"));
        out.push('\n');
    }
    out
}

fn rewrite_placeholder_ids(content: &str, id_map: &HashMap<String, String>) -> String {
    if id_map.is_empty() {
        return content.to_string();
    }
    let trailing_newline = content.ends_with('\n');
    let mut out: Vec<String> = Vec::new();
    for line in content.lines() {
        match crate::notion::blocks_to_md::parse_placeholder(line) {
            Some((ty, id)) => match id_map.get(&id) {
                Some(new_id) => out.push(crate::notion::blocks_to_md::placeholder_line(&ty, new_id)),
                None => out.push(line.to_string()),
            },
            None => out.push(line.to_string()),
        }
    }
    let mut s = out.join("\n");
    if trailing_newline {
        s.push('\n');
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local(hash: &str) -> LocalState {
        LocalState {
            hash: hash.into(),
            trashed: false,
        }
    }
    fn trashed() -> LocalState {
        LocalState {
            hash: "x".into(),
            trashed: true,
        }
    }
    fn remote(edited: &str) -> RemoteState {
        RemoteState {
            last_edited: edited.into(),
            archived: false,
        }
    }
    fn archived() -> RemoteState {
        RemoteState {
            last_edited: "t9".into(),
            archived: true,
        }
    }
    fn base(local_hash: &str, edited: &str) -> Baseline {
        Baseline {
            local_hash: local_hash.into(),
            remote_edited: edited.into(),
            state: "ok".into(),
        }
    }

    // The full stage-one table from the design, one assertion per row.
    #[test]
    fn stage_one_table() {
        let b = base("h1", "t1");
        // unchanged / local only / remote moved
        assert_eq!(classify(Some(&local("h1")), Some(&remote("t1")), Some(&b)), Action::Skip);
        assert_eq!(classify(Some(&local("h2")), Some(&remote("t1")), Some(&b)), Action::Push);
        assert_eq!(
            classify(Some(&local("h1")), Some(&remote("t2")), Some(&b)),
            Action::MaybePull
        );
        // both moved still routes through stage two — a timestamp can't tell
        // "they edited it" from "we did".
        assert_eq!(
            classify(Some(&local("h2")), Some(&remote("t2")), Some(&b)),
            Action::MaybePull
        );
        // remote gone
        assert_eq!(classify(Some(&local("h1")), None, Some(&b)), Action::TrashLocal);
        assert_eq!(
            classify(Some(&local("h1")), Some(&archived()), Some(&b)),
            Action::TrashLocal
        );
        assert_eq!(
            classify(Some(&local("h2")), None, Some(&b)),
            Action::Conflict(ConflictKind::RemoteDeleted)
        );
        // local gone
        assert_eq!(
            classify(Some(&trashed()), Some(&remote("t1")), Some(&b)),
            Action::ArchiveRemote
        );
        assert_eq!(classify(None, Some(&remote("t1")), Some(&b)), Action::ArchiveRemote);
        assert_eq!(
            classify(Some(&trashed()), Some(&remote("t2")), Some(&b)),
            Action::Conflict(ConflictKind::LocalDeleted)
        );
        // both gone
        assert_eq!(classify(None, None, Some(&b)), Action::DropLink);
        assert_eq!(classify(Some(&trashed()), Some(&archived()), Some(&b)), Action::DropLink);
    }

    #[test]
    fn unlinked_sides_are_created() {
        assert_eq!(classify(Some(&local("h")), None, None), Action::CreateRemote);
        assert_eq!(classify(None, Some(&remote("t")), None), Action::CreateLocal);
        // A note in the trash that was never synced stays out of Notion.
        assert_eq!(classify(Some(&trashed()), None, None), Action::Skip);
    }

    #[test]
    fn conflicted_and_excluded_links_are_frozen() {
        for state in ["conflict", "excluded"] {
            let b = Baseline {
                local_hash: "h1".into(),
                remote_edited: "t1".into(),
                state: state.into(),
            };
            // Every input that would otherwise act must still do nothing.
            assert_eq!(classify(Some(&local("h9")), Some(&remote("t9")), Some(&b)), Action::Skip);
            assert_eq!(classify(None, None, Some(&b)), Action::Skip);
        }
    }

    #[test]
    fn stage_two_resolves_the_echo_of_our_own_push() {
        assert_eq!(classify_stage2(false, false), Action::Skip);
        assert_eq!(classify_stage2(true, false), Action::Push);
        assert_eq!(classify_stage2(false, true), Action::Pull);
        assert_eq!(
            classify_stage2(true, true),
            Action::Conflict(ConflictKind::BothChanged)
        );
    }

    #[test]
    fn readonly_marker_lands_under_the_title() {
        assert_eq!(
            insert_readonly_marker("# T\n\nbody\n"),
            "# T\n\n<!-- notion:readonly-body -->\n\nbody\n"
        );
        assert_eq!(
            insert_readonly_marker("# T\n"),
            "# T\n\n<!-- notion:readonly-body -->\n"
        );
    }

    #[test]
    fn placeholder_ids_are_rewritten_in_place_and_unmapped_ones_survive() {
        use crate::notion::blocks_to_md::placeholder_line;
        let before = format!("# T\n\n{}\n\ntail\n", placeholder_line("callout", "old"));
        let mut map = HashMap::new();
        map.insert("old".to_string(), "new".to_string());
        let after = rewrite_placeholder_ids(&before, &map);
        assert!(after.contains("id=new"));
        assert!(!after.contains("id=old"));
        assert!(after.ends_with("tail\n"));
        // An unmapped id is left alone rather than dropped.
        assert_eq!(rewrite_placeholder_ids(&before, &HashMap::new()), before);
    }

    // -- executor, against an in-memory Notion -----------------------------

    mod executor {
        use super::*;
        use crate::notion::fake::FakeNotion;
        use crate::notion::NotionConfigInput;
        use serde_json::json;

        struct TestWs(std::sync::Mutex<Workspace>);

        impl WsAccess for TestWs {
            fn with_ws(&self, f: &mut dyn FnMut(&Workspace) -> AppResult<()>) -> AppResult<()> {
                let guard = self.0.lock().unwrap();
                f(&guard)
            }
        }

        struct Harness {
            _dir: tempfile::TempDir,
            ws: TestWs,
            api: FakeNotion,
            cancel: AtomicBool,
        }

        impl Harness {
            fn new() -> Self {
                let dir = tempfile::tempdir().unwrap();
                let ws = Workspace::open(dir.path()).unwrap();
                store::set_config(
                    &ws,
                    &NotionConfigInput {
                        token: Some("secret_test".into()),
                        database_id: Some("db1".into()),
                        enabled: Some(true),
                        ..Default::default()
                    },
                )
                .unwrap();
                Self {
                    _dir: dir,
                    ws: TestWs(std::sync::Mutex::new(ws)),
                    api: FakeNotion::new("db1"),
                    cancel: AtomicBool::new(false),
                }
            }

            fn exec(&self) -> Executor<'_> {
                Executor {
                    api: &self.api,
                    access: &self.ws,
                    cancel: &self.cancel,
                    progress: None,
                    dry_run: false,
                }
            }

            fn with<T>(&self, f: impl FnOnce(&Workspace) -> T) -> T {
                let g = self.ws.0.lock().unwrap();
                f(&g)
            }

            fn create_note(&self, content: &str) -> String {
                let id = uuid::Uuid::new_v4().to_string();
                let title = crate::commands::workspace::first_line_title(content, "Untitled");
                self.with(|w| {
                    workspace::insert_note(
                        w,
                        &workspace::Note {
                            id: id.clone(),
                            title: title.clone(),
                            created_ms: now_ms(),
                            mtime_ms: now_ms(),
                            size: content.len() as i64,
                        },
                        content,
                    )
                    .unwrap();
                    workspace::apply_remote_content(w, &id, content, &title).unwrap();
                });
                id
            }

            /// Writes as the editor would. The sleep guarantees a distinct
            /// mtime, which is what the planner's "unchanged file" fast path
            /// keys on — without it the edit could be invisible.
            fn edit_note(&self, id: &str, content: &str) {
                std::thread::sleep(std::time::Duration::from_millis(5));
                let title = crate::commands::workspace::first_line_title(content, "Untitled");
                self.with(|w| workspace::apply_remote_content(w, id, content, &title).unwrap());
            }

            fn read_note(&self, id: &str) -> String {
                self.with(|w| std::fs::read_to_string(w.note_path(id)).unwrap_or_default())
            }

            fn note_path(&self, id: &str) -> std::path::PathBuf {
                self.with(|w| w.note_path(id))
            }

            fn set_id_prop(&self, name: Option<&str>) {
                self.with(|w| {
                    store::set_config(
                        w,
                        &NotionConfigInput {
                            id_prop: Some(name.unwrap_or("").to_string()),
                            ..Default::default()
                        },
                    )
                    .unwrap();
                });
            }

            fn set_timestamp_props(&self, created: Option<&str>, updated: Option<&str>) {
                self.with(|w| {
                    store::set_config(
                        w,
                        &NotionConfigInput {
                            created_prop: Some(created.unwrap_or("").to_string()),
                            updated_prop: Some(updated.unwrap_or("").to_string()),
                            ..Default::default()
                        },
                    )
                    .unwrap();
                });
            }

            fn links(&self) -> Vec<Link> {
                self.with(|w| store::list_links(w).unwrap())
            }

            fn only_link(&self) -> Link {
                let l = self.links();
                assert_eq!(l.len(), 1, "expected exactly one link, got {:?}", l);
                l.into_iter().next().unwrap()
            }
        }

        fn para(s: &str) -> serde_json::Value {
            json!({"object": "block", "type": "paragraph",
                   "paragraph": {"rich_text": [{"type": "text", "text": {"content": s},
                                                "plain_text": s}]}})
        }

        fn callout(s: &str) -> serde_json::Value {
            json!({"object": "block", "type": "callout",
                   "callout": {"icon": {"emoji": "💡"},
                               "rich_text": [{"type": "text", "text": {"content": s},
                                              "plain_text": s}]}})
        }

        fn synced() -> serde_json::Value {
            json!({"object": "block", "type": "synced_block",
                   "synced_block": {"synced_from": null, "children": []}})
        }

        /// The regression this whole design exists to prevent: a push bumps the
        /// remote timestamp, and the very next sync must NOT read that as a
        /// remote edit.
        #[tokio::test]
        async fn push_does_not_echo_back_as_a_remote_change() {
            let h = Harness::new();
            h.create_note("# Hello\n\nworld\n");

            let first = h.exec().run().await.unwrap();
            assert_eq!(first.created_remote, 1, "{:?}", first.items);
            let page = h.api.page_ids().into_iter().next().unwrap();
            assert_eq!(h.api.page_title(&page).as_deref(), Some("Hello"));
            // The title heading is part of the body, not stripped into the
            // property — the property is only a label.
            assert_eq!(h.api.block_types(&page), vec!["heading_1", "paragraph"]);

            let second = h.exec().run().await.unwrap();
            assert!(
                second.items.is_empty(),
                "second sync should be a no-op, got {:?}",
                second.items
            );
        }

        /// A timestamp bump with no content change (property edit, Notion
        /// bookkeeping) re-baselines instead of pulling.
        #[tokio::test]
        async fn timestamp_only_bump_is_absorbed() {
            let h = Harness::new();
            h.api.seed_page("p1", "Remote", vec![para("hi")]);
            h.exec().run().await.unwrap();

            h.api.touch_only("p1");
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.pulled, 0);
            assert!(r.items.is_empty(), "{:?}", r.items);
            // …and the baseline caught up, so nothing is pending next time.
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        #[tokio::test]
        async fn remote_page_becomes_a_local_note_then_pulls_edits() {
            let h = Harness::new();
            h.api.seed_page("p1", "Remote", vec![para("first")]);

            let r = h.exec().run().await.unwrap();
            assert_eq!(r.created_local, 1, "{:?}", r.items);
            let note_id = h.only_link().note_id;
            assert_eq!(h.read_note(&note_id), "# Remote\n\nfirst\n");

            h.api.edit_page("p1", vec![para("second")]);
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.pulled, 1, "{:?}", r.items);
            assert_eq!(h.read_note(&note_id), "# Remote\n\nsecond\n");
            assert_eq!(r.changed_note_ids, vec![note_id]);
        }

        #[tokio::test]
        async fn local_edit_pushes_and_replaces_the_remote_body() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("old")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            h.edit_note(&note_id, "# Doc\n\nbrand new\n\n- item\n");
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.pushed, 1, "{:?}", r.items);
            assert_eq!(
                h.api.block_types("p1"),
                vec!["heading_1", "paragraph", "bulleted_list_item"]
            );
            // And it settles — no perpetual push loop.
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        #[tokio::test]
        async fn edits_on_both_sides_raise_a_conflict_and_freeze_the_note() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("base")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            h.edit_note(&note_id, "# Doc\n\nlocal version\n");
            h.api.edit_page("p1", vec![para("remote version")]);

            let r = h.exec().run().await.unwrap();
            assert_eq!(r.conflicts, 1, "{:?}", r.items);

            let detail = h.with(|w| store::get_conflict(w, &note_id).unwrap()).unwrap();
            assert_eq!(detail.summary.kind, "both-changed");
            assert!(detail.local_content.unwrap().contains("local version"));
            assert!(detail.remote_content.unwrap().contains("remote version"));

            // Neither side was touched, and further syncs leave it frozen.
            assert!(h.read_note(&note_id).contains("local version"));
            assert_eq!(h.api.block_types("p1"), vec!["paragraph"]);
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        #[tokio::test]
        async fn keep_remote_resolution_adopts_the_notion_version() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("base")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;
            h.edit_note(&note_id, "# Doc\n\nlocal version\n");
            h.api.edit_page("p1", vec![para("remote version")]);
            h.exec().run().await.unwrap();

            let changed = h.exec().resolve(&note_id, "keepRemote").await.unwrap();
            assert_eq!(changed, vec![note_id.clone()]);
            assert_eq!(h.read_note(&note_id), "# Doc\n\nremote version\n");
            assert_eq!(h.with(|w| store::count_conflicts(w).unwrap()), 0);
            assert_eq!(h.only_link().state, "ok");
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        #[tokio::test]
        async fn keep_local_resolution_overwrites_notion() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("base")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;
            h.edit_note(&note_id, "# Doc\n\nlocal version\n");
            h.api.edit_page("p1", vec![para("remote version")]);
            h.exec().run().await.unwrap();

            h.exec().resolve(&note_id, "keepLocal").await.unwrap();
            assert!(h.read_note(&note_id).contains("local version"));
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        #[tokio::test]
        async fn keep_both_forks_the_remote_side_into_a_new_note() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("base")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;
            h.edit_note(&note_id, "# Doc\n\nlocal version\n");
            h.api.edit_page("p1", vec![para("remote version")]);
            h.exec().run().await.unwrap();

            let changed = h.exec().resolve(&note_id, "keepBoth").await.unwrap();
            assert_eq!(changed.len(), 1);
            let forked = &changed[0];
            assert!(h.read_note(forked).starts_with("# Doc (Notion)"));
            assert!(h.read_note(forked).contains("remote version"));
            assert!(h.read_note(&note_id).contains("local version"));

            // The fork is unlinked, so the next sync publishes it as its own page.
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.created_remote, 1, "{:?}", r.items);
            assert_eq!(h.api.page_ids().len(), 2);
        }

        #[tokio::test]
        async fn deleting_locally_archives_the_page_and_vice_versa() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("body")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            h.with(|w| workspace::trash_note(w, &note_id, now_ms()).unwrap());
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.archived_remote, 1, "{:?}", r.items);
            assert!(h.api.is_archived("p1"));
            assert!(h.links().is_empty());
        }

        #[tokio::test]
        async fn archiving_in_notion_trashes_the_local_note() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("body")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            h.api.update_page_archived("p1");
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.trashed_local, 1, "{:?}", r.items);
            let trashed = h.with(|w| store::list_note_rows(w).unwrap());
            assert!(trashed.iter().find(|n| n.id == note_id).unwrap().trashed);
        }

        /// The hard case: a block Nova can't render must survive a full
        /// round-trip through the editor, and its placeholder must be rewritten
        /// to the id the rebuild produced.
        #[tokio::test]
        async fn unsupported_blocks_survive_a_push() {
            let h = Harness::new();
            h.api
                .seed_page("p1", "Doc", vec![para("before"), callout("tip"), para("after")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            let pulled = h.read_note(&note_id);
            let old_ids = h.api.block_ids("p1");
            assert!(pulled.contains(&format!("id={}", old_ids[1])));
            assert!(!h.only_link().is_blocked());

            h.edit_note(&note_id, &pulled.replace("before", "BEFORE"));
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.pushed, 1, "{:?}", r.items);

            // Rebuilt in order, with the callout intact.
            assert_eq!(
                h.api.block_types("p1"),
                vec!["heading_1", "paragraph", "callout", "paragraph"]
            );
            let new_ids = h.api.block_ids("p1");
            assert_ne!(new_ids[2], old_ids[1], "rebuild assigns fresh ids");
            let after = h.read_note(&note_id);
            assert!(after.contains(&format!("id={}", new_ids[2])));
            assert!(after.contains("BEFORE"));
            // Baseline is consistent again.
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        /// Deleting the placeholder line is how a user deletes the block.
        #[tokio::test]
        async fn removing_a_placeholder_deletes_the_block() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("keep"), callout("drop me")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            h.edit_note(&note_id, "# Doc\n\nkeep\n");
            h.exec().run().await.unwrap();
            assert_eq!(h.api.block_types("p1"), vec!["heading_1", "paragraph"]);
        }

        #[tokio::test]
        async fn unrecreatable_blocks_put_the_note_in_pull_only_mode() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("body"), synced()]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;
            assert!(h.only_link().is_blocked());
            assert!(h.read_note(&note_id).contains(READONLY_MARKER));

            let before = h.api.block_ids("p1");
            h.edit_note(&note_id, &h.read_note(&note_id).replace("body", "edited"));
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.blocked, 1, "{:?}", r.items);
            assert_eq!(r.pushed, 0);
            // Notion is untouched — the synced block is still there.
            assert_eq!(h.api.block_ids("p1"), before);
            // And the warning keeps reappearing until it's resolved.
            assert_eq!(h.exec().run().await.unwrap().blocked, 1);
        }

        #[tokio::test]
        async fn dry_run_reports_without_touching_either_side() {
            let h = Harness::new();
            h.create_note("# Local\n\nbody\n");
            h.api.seed_page("p1", "Remote", vec![para("hi")]);

            let mut ex = h.exec();
            ex.dry_run = true;
            let r = ex.run().await.unwrap();
            assert_eq!(r.created_remote, 1);
            assert_eq!(r.created_local, 1);
            assert!(r.dry_run);
            assert_eq!(h.api.page_ids(), vec!["p1".to_string()]);
            assert!(h.links().is_empty());
        }

        #[tokio::test]
        async fn cancelling_stops_between_tasks() {
            let h = Harness::new();
            h.api.seed_page("p1", "A", vec![para("a")]);
            h.api.seed_page("p2", "B", vec![para("b")]);
            h.cancel.store(true, Ordering::SeqCst);

            let r = h.exec().run().await.unwrap();
            assert!(r.cancelled);
            assert!(h.links().is_empty());
        }

        #[tokio::test]
        async fn excluded_notes_are_never_synced() {
            let h = Harness::new();
            let note_id = h.create_note("# Private\n\nsecret\n");
            h.with(|w| {
                let mut l = Link::new(&note_id, None);
                l.state = "excluded".into();
                store::upsert_link(w, &l).unwrap();
            });
            let r = h.exec().run().await.unwrap();
            assert!(r.items.is_empty(), "{:?}", r.items);
            assert!(h.api.page_ids().is_empty());
        }

        // -- races and partial failures ------------------------------------
        //
        // A sync takes seconds of wall-clock (rate limiting, pagination) and
        // any request can fail halfway. These are the cases where the engine
        // could destroy work rather than merely fail.

        /// The user saves while the engine is fetching the remote page. Their
        /// text is not on Notion yet, so a pull must not overwrite it.
        #[tokio::test]
        async fn a_save_during_the_fetch_is_not_overwritten() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("base")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            h.api.edit_page("p1", vec![para("remote v2")]);
            let path = h.note_path(&note_id);
            h.api.once_during_fetch(move || {
                std::fs::write(&path, "# Doc\n\nlocal racing edit\n").unwrap();
            });

            let r = h.exec().run().await.unwrap();
            assert_eq!(r.pulled, 0, "must not pull over the racing edit: {:?}", r.items);
            assert_eq!(r.conflicts, 1, "{:?}", r.items);
            assert!(h.read_note(&note_id).contains("local racing edit"));
            let detail = h.with(|w| store::get_conflict(w, &note_id).unwrap()).unwrap();
            assert!(detail.local_content.unwrap().contains("local racing edit"));
            assert!(detail.remote_content.unwrap().contains("remote v2"));
        }

        /// Same race on the write itself: `apply_pull` re-checks the file it is
        /// about to clobber against the hash the decision was made from.
        #[tokio::test]
        async fn apply_pull_refuses_when_the_file_moved_under_it() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("base")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            let page = h.api.retrieve_page("p1").await.unwrap();
            let ex = h.exec();
            let fetched = ex.fetch_rendered(&page).await.unwrap();
            let task = Task {
                note_id: Some(note_id.clone()),
                page_id: Some("p1".into()),
                title: "Doc".into(),
                action: Action::Pull,
                local_content: None,
            };
            let mut report = SyncReport::default();
            let before = h.read_note(&note_id);
            let applied = ex
                .apply_pull(&task, &page, &fetched, Some("a-stale-hash"), &mut report)
                .unwrap();
            assert!(!applied);
            assert_eq!(h.read_note(&note_id), before, "file must be untouched");
            assert!(report.items.is_empty());
        }

        /// A push that fails partway must leave the Notion page exactly as it
        /// was — never empty, never half-written.
        #[tokio::test]
        async fn a_failed_append_leaves_the_page_intact() {
            let h = Harness::new();
            h.api
                .seed_page("p1", "Doc", vec![para("keep one"), para("keep two")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;
            let before_ids = h.api.block_ids("p1");

            h.edit_note(&note_id, "# Doc\n\nreplacement\n");
            h.api.fail_append_at(1);

            let r = h.exec().run().await.unwrap();
            assert_eq!(r.errors, 1, "{:?}", r.items);
            assert_eq!(r.pushed, 0);
            assert_eq!(
                h.api.block_texts("p1"),
                vec!["keep one".to_string(), "keep two".to_string()],
                "the original page content must survive a failed push"
            );
            assert_eq!(h.api.block_ids("p1"), before_ids, "no orphan blocks left behind");
            // The local edit is untouched and still pending.
            assert!(h.read_note(&note_id).contains("replacement"));
            let r2 = h.exec().run().await.unwrap();
            assert_eq!(r2.pushed, 1, "retry succeeds: {:?}", r2.items);
            assert_eq!(
                h.api.block_texts("p1"),
                vec!["Doc".to_string(), "replacement".to_string()]
            );
        }

        /// The user keeps typing while a push is in flight. Their newer text
        /// isn't on Notion, so it must survive locally *and* still be pending.
        #[tokio::test]
        async fn a_save_during_a_push_survives_and_stays_pending() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("base")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            h.edit_note(&note_id, "# Doc\n\nfirst edit\n");
            let path = h.note_path(&note_id);
            h.api.once_during_fetch(move || {
                std::fs::write(&path, "# Doc\n\nfirst edit\nsecond edit\n").unwrap();
            });

            let r = h.exec().run().await.unwrap();
            assert_eq!(r.pushed, 1, "{:?}", r.items);
            // Nothing was clobbered…
            assert!(h.read_note(&note_id).contains("second edit"));
            // …and the newer text is still queued rather than silently dropped.
            let r2 = h.exec().run().await.unwrap();
            assert_eq!(r2.pushed, 1, "the racing edit must still push: {:?}", r2.items);
            assert_eq!(
                h.api.block_texts("p1"),
                vec!["Doc".to_string(), "first edit\nsecond edit".to_string()]
            );
        }

        /// An unreadable note must be skipped, never treated as empty — that
        /// would hash as "cleared" and push a blank page.
        #[tokio::test]
        async fn an_unreadable_note_is_skipped_not_emptied() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("valuable")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            std::fs::remove_file(h.note_path(&note_id)).unwrap();
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.pushed, 0);
            assert_eq!(h.api.block_texts("p1"), vec!["valuable".to_string()]);
            // (seeded straight into Notion, so it has no title heading)
            // A vanished file is a stale row, not a sync failure — warn, and
            // don't make an otherwise clean sync report as broken.
            assert_eq!(r.errors, 0, "{:?}", r.items);
            assert_eq!(r.blocked, 1, "{:?}", r.items);
            assert!(r.items[0].message.as_deref().unwrap().contains("missing"));
        }

        /// A failing resolution must leave the conflict (and its snapshot of
        /// the remote side) in place so the user can try again.
        #[tokio::test]
        async fn a_failed_resolution_keeps_the_conflict() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("base")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;
            h.edit_note(&note_id, "# Doc\n\nlocal\n");
            h.api.edit_page("p1", vec![para("remote")]);
            h.exec().run().await.unwrap();
            assert_eq!(h.with(|w| store::count_conflicts(w).unwrap()), 1);

            h.cancel.store(true, Ordering::SeqCst);
            assert!(h.exec().resolve(&note_id, "keepRemote").await.is_err());

            assert_eq!(
                h.with(|w| store::count_conflicts(w).unwrap()),
                1,
                "conflict must survive a failed resolution"
            );
            let detail = h.with(|w| store::get_conflict(w, &note_id).unwrap()).unwrap();
            assert!(detail.remote_content.unwrap().contains("remote"));
            // And it still works once the blocker is gone.
            h.cancel.store(false, Ordering::SeqCst);
            h.exec().resolve(&note_id, "keepRemote").await.unwrap();
            assert_eq!(h.with(|w| store::count_conflicts(w).unwrap()), 0);
        }

        /// Resolving in favour of Nova would rebuild the page, which is exactly
        /// what `push` refuses to do for unrecreatable blocks.
        #[tokio::test]
        async fn resolution_cannot_bypass_the_pull_only_guard() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("base"), synced()]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;
            let before = h.api.block_ids("p1");

            h.edit_note(&note_id, &h.read_note(&note_id).replace("base", "local"));
            h.api.edit_page("p1", vec![para("remote"), synced()]);
            h.exec().run().await.unwrap();

            let err = h.exec().resolve(&note_id, "keepLocal").await.unwrap_err();
            assert!(err.to_string().contains("can't recreate"), "{}", err);
            assert_eq!(h.api.block_ids("p1").len(), before.len());
            assert_eq!(h.with(|w| store::count_conflicts(w).unwrap()), 1);
        }

        /// Placeholder ids change on every rebuild, so an open tab is stale and
        /// its next save would fail the mtime check unless it's reloaded.
        #[tokio::test]
        async fn a_push_that_rewrites_the_file_reports_the_note_as_changed() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("body"), callout("tip")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            h.edit_note(&note_id, &h.read_note(&note_id).replace("body", "edited"));
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.pushed, 1, "{:?}", r.items);
            assert!(
                r.changed_note_ids.contains(&note_id),
                "placeholder ids were rewritten, so the tab must be reloaded"
            );
        }

        /// Excluding a note keeps its page claimed; forgetting to would make
        /// the next sync import the page again as a duplicate note.
        #[tokio::test]
        async fn an_excluded_note_does_not_reimport_its_page() {
            let h = Harness::new();
            h.api.seed_page("p1", "Doc", vec![para("body")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            h.with(|w| {
                let mut l = store::get_link(w, &note_id).unwrap().unwrap();
                l.state = "excluded".into();
                store::upsert_link(w, &l).unwrap();
            });

            let r = h.exec().run().await.unwrap();
            assert!(r.items.is_empty(), "{:?}", r.items);
            let notes = h.with(|w| store::list_note_rows(w).unwrap());
            assert_eq!(notes.len(), 1, "no duplicate note: {:?}", notes);
        }

        /// Cached blocks are replayed verbatim; over-eager field stripping used
        /// to delete the `id` a mention needs, which Notion rejects with a 400.
        #[tokio::test]
        async fn a_cached_block_containing_a_mention_can_be_replayed() {
            let h = Harness::new();
            let mentioning = json!({
                "object": "block", "id": "c1", "type": "callout",
                "created_time": "2024-01-01T00:00:00.000Z",
                "callout": {"icon": {"emoji": "💡"}, "rich_text": [
                    {"type": "mention", "plain_text": "Roadmap",
                     "mention": {"type": "page", "page": {"id": "page-abc"}}}
                ]}
            });
            h.api.seed_page("p1", "Doc", vec![para("body"), mentioning]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;

            h.edit_note(&note_id, &h.read_note(&note_id).replace("body", "edited"));
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.errors, 0, "{:?}", r.items);
            assert_eq!(r.pushed, 1, "{:?}", r.items);
            assert_eq!(h.api.block_types("p1"), vec!["heading_1", "paragraph", "callout"]);
            let ids = h.api.block_ids("p1");
            let restored = h.with(|w| store::list_blocks(w, &note_id).unwrap());
            assert_eq!(restored.len(), 1);
            assert_eq!(restored[0].block_id, ids[2]);
        }

        // -- timestamp properties ------------------------------------------

        #[tokio::test]
        async fn timestamp_columns_are_off_until_configured() {
            let h = Harness::new();
            h.create_note("# Note\n\nbody\n");
            h.exec().run().await.unwrap();
            let page = h.api.page_ids().into_iter().next().unwrap();
            assert_eq!(h.api.page_date(&page, "Created"), None);
            assert_eq!(h.api.page_date(&page, "Updated"), None);
            // And nothing was added to the user's database schema.
            assert_eq!(h.api.schema().len(), 1);
        }

        #[tokio::test]
        async fn missing_date_columns_are_created_and_filled() {
            let h = Harness::new();
            h.set_timestamp_props(Some("Created"), Some("Updated"));
            let note_id = h.create_note("# Note\n\nbody\n");
            let (created_ms, mtime_ms) = h.with(|w| {
                let n = workspace::get_note(w, &note_id).unwrap();
                (n.created_ms, n.mtime_ms)
            });

            let r = h.exec().run().await.unwrap();
            assert_eq!(r.errors, 0, "{:?}", r.items);
            assert_eq!(h.api.schema().get("Created").map(String::as_str), Some("date"));
            assert_eq!(h.api.schema().get("Updated").map(String::as_str), Some("date"));

            let page = h.api.page_ids().into_iter().next().unwrap();
            assert_eq!(
                h.api.page_date(&page, "Created"),
                Some(crate::notion::model::ms_to_iso8601(created_ms))
            );
            assert_eq!(
                h.api.page_date(&page, "Updated"),
                Some(crate::notion::model::ms_to_iso8601(mtime_ms))
            );
        }

        #[tokio::test]
        async fn an_existing_date_column_is_reused_not_recreated() {
            let h = Harness::new();
            h.api.add_property("생성일", "date");
            h.set_timestamp_props(Some("생성일"), None);
            h.create_note("# Note\n\nbody\n");

            let r = h.exec().run().await.unwrap();
            assert!(
                !r.items.iter().any(|i| i.kind == "info"),
                "no schema change should be reported: {:?}", r.items
            );
            let page = h.api.page_ids().into_iter().next().unwrap();
            assert!(h.api.page_date(&page, "생성일").is_some());
        }

        /// Repurposing a column the user already uses for something else would
        /// destroy data, so it's reported and skipped instead.
        #[tokio::test]
        async fn a_wrong_typed_column_is_skipped_with_a_warning() {
            let h = Harness::new();
            h.api.add_property("Updated", "rich_text");
            h.set_timestamp_props(None, Some("Updated"));
            h.create_note("# Note\n\nbody\n");

            let r = h.exec().run().await.unwrap();
            // The push still lands…
            assert_eq!(r.created_remote, 1, "{:?}", r.items);
            assert_eq!(r.errors, 0, "{:?}", r.items);
            // …the column keeps its type, and the user is told why.
            assert_eq!(h.api.schema().get("Updated").map(String::as_str), Some("rich_text"));
            let page = h.api.page_ids().into_iter().next().unwrap();
            assert_eq!(h.api.page_date(&page, "Updated"), None);
            assert!(r
                .items
                .iter()
                .any(|i| i.severity == "warn" && i.message.as_deref().unwrap_or("").contains("not a date")));
        }

        #[tokio::test]
        async fn created_stays_put_while_updated_tracks_edits() {
            let h = Harness::new();
            h.set_timestamp_props(Some("Created"), Some("Updated"));
            let note_id = h.create_note("# Note\n\nfirst\n");
            h.exec().run().await.unwrap();
            let page = h.api.page_ids().into_iter().next().unwrap();
            let created = h.api.page_date(&page, "Created").unwrap();
            let updated = h.api.page_date(&page, "Updated").unwrap();

            h.edit_note(&note_id, "# Note\n\nsecond\n");
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.pushed, 1, "{:?}", r.items);
            assert_eq!(h.api.page_date(&page, "Created"), Some(created));
            assert_ne!(h.api.page_date(&page, "Updated"), Some(updated));
        }

        /// Writing properties bumps `last_edited_time`, so this is the echo
        /// test again with the timestamp columns turned on.
        #[tokio::test]
        async fn timestamp_writes_do_not_cause_a_sync_loop() {
            let h = Harness::new();
            h.set_timestamp_props(Some("Created"), Some("Updated"));
            h.create_note("# Note\n\nbody\n");
            h.exec().run().await.unwrap();
            let second = h.exec().run().await.unwrap();
            assert!(second.items.is_empty(), "{:?}", second.items);
        }

        #[tokio::test]
        async fn a_dry_run_never_touches_the_schema() {
            let h = Harness::new();
            h.set_timestamp_props(Some("Created"), Some("Updated"));
            h.create_note("# Note\n\nbody\n");
            let mut ex = h.exec();
            ex.dry_run = true;
            ex.run().await.unwrap();
            assert_eq!(h.api.schema().len(), 1, "{:?}", h.api.schema());
        }

        // -- bulk resolution -----------------------------------------------

        /// Seeds three conflicts, one of each kind, so a bulk policy has to
        /// map every one of them.
        async fn three_conflicts(h: &Harness) -> (String, String, String) {
            h.api.seed_page("p1", "Both", vec![para("base")]);
            h.api.seed_page("p2", "RemoteGone", vec![para("base")]);
            h.api.seed_page("p3", "LocalGone", vec![para("base")]);
            h.exec().run().await.unwrap();
            let id_of = |page: &str| {
                h.links()
                    .into_iter()
                    .find(|l| l.page_id.as_deref() == Some(page))
                    .unwrap()
                    .note_id
            };
            let (a, b, c) = (id_of("p1"), id_of("p2"), id_of("p3"));

            // both-changed
            h.edit_note(&a, "# Both\n\nlocal\n");
            h.api.edit_page("p1", vec![para("remote")]);
            // remote-deleted, with a local edit so it conflicts
            h.edit_note(&b, "# RemoteGone\n\nlocal\n");
            h.api.update_page_archived("p2");
            // local-deleted, with a remote edit so it conflicts
            h.with(|w| workspace::trash_note(w, &c, now_ms()).unwrap());
            h.api.edit_page("p3", vec![para("remote")]);

            let r = h.exec().run().await.unwrap();
            assert_eq!(r.conflicts, 3, "{:?}", r.items);
            (a, b, c)
        }

        #[tokio::test]
        async fn bulk_local_policy_keeps_every_nova_version() {
            let h = Harness::new();
            let (a, b, c) = three_conflicts(&h).await;

            let out = h.exec().resolve_all("local").await.unwrap();
            assert_eq!(out.resolved, 3, "{:?}", out.errors);
            assert_eq!(out.failed, 0);
            assert_eq!(h.with(|w| store::count_conflicts(w).unwrap()), 0);

            assert!(h.read_note(&a).contains("local"));
            // The page deleted in Notion came back.
            assert!(h.read_note(&b).contains("local"));
            assert_eq!(h.links().iter().filter(|l| l.note_id == b).count(), 1);
            // The note deleted in Nova came back.
            let rows = h.with(|w| store::list_note_rows(w).unwrap());
            assert!(!rows.iter().find(|n| n.id == c).unwrap().trashed);

            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        #[tokio::test]
        async fn bulk_remote_policy_takes_every_notion_version() {
            let h = Harness::new();
            let (a, b, c) = three_conflicts(&h).await;

            let out = h.exec().resolve_all("remote").await.unwrap();
            assert_eq!(out.resolved, 3, "{:?}", out.errors);
            assert_eq!(h.with(|w| store::count_conflicts(w).unwrap()), 0);

            assert!(h.read_note(&a).contains("remote"));
            // Deleted in Notion -> deleted here too.
            let rows = h.with(|w| store::list_note_rows(w).unwrap());
            assert!(rows.iter().find(|n| n.id == b).unwrap().trashed);
            // Deleted in Nova -> archived there too, and the note stays gone.
            assert!(h.api.is_archived("p3"));
            assert!(rows.iter().find(|n| n.id == c).unwrap().trashed);

            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        /// "Keep both" must never discard anything, including for the deletion
        /// kinds where there is no second copy to make.
        #[tokio::test]
        async fn bulk_both_policy_discards_nothing() {
            let h = Harness::new();
            let (a, b, c) = three_conflicts(&h).await;
            let before = h.with(|w| store::list_note_rows(w).unwrap()).len();

            let out = h.exec().resolve_all("both").await.unwrap();
            assert_eq!(out.resolved, 3, "{:?}", out.errors);

            let rows = h.with(|w| store::list_note_rows(w).unwrap());
            // The both-changed note forked, so there's one more note than before.
            assert_eq!(rows.len(), before + 1);
            assert!(h.read_note(&a).contains("local"));
            assert!(rows.iter().any(|n| n.title.ends_with("(Notion)")));
            // Neither deletion was accepted.
            assert!(!rows.iter().find(|n| n.id == b).unwrap().trashed);
            assert!(!rows.iter().find(|n| n.id == c).unwrap().trashed);
        }

        /// One bad conflict must not strand the rest.
        #[tokio::test]
        async fn a_failure_mid_bulk_still_resolves_the_others() {
            let h = Harness::new();
            let (a, _b, _c) = three_conflicts(&h).await;
            // Make one note unreadable so its resolution errors out.
            std::fs::remove_file(h.note_path(&a)).unwrap();

            let out = h.exec().resolve_all("local").await.unwrap();
            assert_eq!(out.failed, 1, "{:?}", out.errors);
            assert_eq!(out.resolved, 2);
            assert_eq!(out.errors[0].note_id.as_deref(), Some(a.as_str()));
            // The failed one keeps its conflict so it can be retried.
            assert_eq!(h.with(|w| store::count_conflicts(w).unwrap()), 1);
        }

        #[tokio::test]
        async fn an_unknown_bulk_policy_is_rejected() {
            let h = Harness::new();
            three_conflicts(&h).await;
            assert!(h.exec().resolve_all("whatever").await.is_err());
            assert_eq!(h.with(|w| store::count_conflicts(w).unwrap()), 3);
        }

        // -- the title lives in the body -----------------------------------

        /// The bug this arrangement exists to prevent: a note whose first line
        /// is longer than the 120-character title cap used to have that line
        /// stripped into a truncated title property, losing the rest outright.
        #[tokio::test]
        async fn a_long_first_line_is_not_truncated_on_the_way_to_notion() {
            let h = Harness::new();
            let long = format!("# {}", "가".repeat(400));
            let note_id = h.create_note(&format!("{}\n\nbody\n", long));

            let r = h.exec().run().await.unwrap();
            assert_eq!(r.created_remote, 1, "{:?}", r.items);
            let page = h.api.page_ids().into_iter().next().unwrap();

            // The full line is a heading block…
            let texts = h.api.block_texts(&page);
            assert_eq!(texts[0].chars().count(), 400);
            // …while the title property is just a label, capped as before.
            assert_eq!(h.api.page_title(&page).unwrap().chars().count(), 120);

            // And it round-trips: pulling it back reproduces the file exactly.
            h.api.touch_only(&page);
            h.exec().run().await.unwrap();
            assert_eq!(h.read_note(&note_id), format!("{}\n\nbody\n", long));
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        /// A page authored in Notion has its title only in the property, so the
        /// heading has to be synthesised — otherwise the title would be lost
        /// the moment the note came down.
        #[tokio::test]
        async fn a_notion_authored_page_gains_a_title_heading() {
            let h = Harness::new();
            h.api.seed_page("p1", "Remote title", vec![para("just a paragraph")]);
            h.exec().run().await.unwrap();
            let note_id = h.only_link().note_id;
            assert_eq!(h.read_note(&note_id), "# Remote title\n\njust a paragraph\n");

            // Pushing it back puts the heading in the body, and the page keeps
            // its name rather than being renamed after the first paragraph.
            h.edit_note(&note_id, "# Remote title\n\nedited\n");
            h.exec().run().await.unwrap();
            assert_eq!(h.api.page_title("p1").as_deref(), Some("Remote title"));
            assert_eq!(h.api.block_types("p1"), vec!["heading_1", "paragraph"]);
            // Now that both agree, nothing further changes.
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        /// Renaming happens by editing the heading — the title is always
        /// re-derived from the body, never stored separately.
        #[tokio::test]
        async fn editing_the_heading_renames_the_page() {
            let h = Harness::new();
            let note_id = h.create_note("# Before\n\nbody\n");
            h.exec().run().await.unwrap();
            let page = h.api.page_ids().into_iter().next().unwrap();
            assert_eq!(h.api.page_title(&page).as_deref(), Some("Before"));

            h.edit_note(&note_id, "# After\n\nbody\n");
            h.exec().run().await.unwrap();
            assert_eq!(h.api.page_title(&page).as_deref(), Some("After"));
            assert_eq!(h.api.block_texts(&page)[0], "After");
        }

        /// Turning a column on must backfill pages that are already in sync —
        /// otherwise the value only ever appears on notes you happen to edit
        /// afterwards, which looks like the feature is broken.
        #[tokio::test]
        async fn enabling_a_column_backfills_already_synced_pages() {
            let h = Harness::new();
            let note_id = h.create_note("# Note\n\nbody\n");
            h.exec().run().await.unwrap();
            let page = h.api.page_ids().into_iter().next().unwrap();
            assert_eq!(h.api.page_date(&page, "Created"), None);

            h.set_timestamp_props(Some("Created"), Some("Updated"));
            let r = h.exec().run().await.unwrap();
            assert_eq!(r.errors, 0, "{:?}", r.items);
            assert!(h.api.page_date(&page, "Created").is_some());
            assert!(h.api.page_date(&page, "Updated").is_some());
            assert_eq!(
                h.api.page_date(&page, "Updated"),
                Some(crate::notion::model::ms_to_iso8601(
                    h.with(|w| workspace::get_note(w, &note_id).unwrap().mtime_ms)
                ))
            );
            // Backfilling bumps last_edited_time; it must settle immediately.
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        #[tokio::test]
        async fn the_id_column_carries_the_note_uuid() {
            let h = Harness::new();
            h.set_id_prop(Some("Nova ID"));
            let note_id = h.create_note("# Note\n\nbody\n");
            h.exec().run().await.unwrap();
            let page = h.api.page_ids().into_iter().next().unwrap();
            assert_eq!(h.api.schema().get("Nova ID").map(String::as_str), Some("rich_text"));
            assert_eq!(h.api.page_text(&page, "Nova ID").as_deref(), Some(note_id.as_str()));
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        /// The payoff: losing the local mapping (fresh install, deleted
        /// workspace.db) must not re-import every page as a duplicate.
        #[tokio::test]
        async fn a_lost_mapping_is_rebuilt_from_the_id_column() {
            let h = Harness::new();
            h.set_id_prop(Some("Nova ID"));
            let note_id = h.create_note("# Note\n\nbody\n");
            h.exec().run().await.unwrap();
            let page = h.api.page_ids().into_iter().next().unwrap();

            // Simulate the mapping being lost while both sides stay put.
            h.with(|w| store::clear_all_links(w).unwrap());

            let r = h.exec().run().await.unwrap();
            assert_eq!(
                r.created_local + r.created_remote,
                0,
                "nothing should be duplicated: {:?}",
                r.items
            );
            assert_eq!(h.api.page_ids().len(), 1);
            assert_eq!(h.with(|w| store::list_note_rows(w).unwrap()).len(), 1);
            let link = h.only_link();
            assert_eq!(link.note_id, note_id);
            assert_eq!(link.page_id.as_deref(), Some(page.as_str()));
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }

        /// Same, but the two sides drifted apart while unlinked — re-linking
        /// must not silently pick a winner.
        #[tokio::test]
        async fn re_linking_diverged_sides_raises_a_conflict() {
            let h = Harness::new();
            h.set_id_prop(Some("Nova ID"));
            let note_id = h.create_note("# Note\n\nbody\n");
            h.exec().run().await.unwrap();
            h.with(|w| store::clear_all_links(w).unwrap());
            h.edit_note(&note_id, "# Note\n\nlocal drift\n");

            let r = h.exec().run().await.unwrap();
            assert_eq!(r.conflicts, 1, "{:?}", r.items);
            assert_eq!(h.api.page_ids().len(), 1, "no duplicate page");
            assert!(h.read_note(&note_id).contains("local drift"));
        }

        /// Without the id column there is nothing to match on, so the old
        /// duplicate-on-import behaviour still applies — worth pinning so the
        /// value of turning it on is visible.
        #[tokio::test]
        async fn without_the_id_column_a_lost_mapping_duplicates() {
            let h = Harness::new();
            h.create_note("# Note\n\nbody\n");
            h.exec().run().await.unwrap();
            h.with(|w| store::clear_all_links(w).unwrap());

            let r = h.exec().run().await.unwrap();
            assert!(r.created_local + r.created_remote > 0, "{:?}", r.items);
        }

        #[tokio::test]
        async fn korean_content_and_formatting_round_trip() {
            let h = Harness::new();
            let note_id = h.create_note("# 회의록\n\n**중요** 항목 *하나*\n\n- 첫째\n- 둘째\n");
            h.exec().run().await.unwrap();
            let page = h.api.page_ids().into_iter().next().unwrap();

            // Pull it back through a fresh render and confirm nothing drifted.
            h.api.touch_only(&page);
            h.exec().run().await.unwrap();
            assert_eq!(
                h.read_note(&note_id),
                "# 회의록\n\n**중요** 항목 *하나*\n\n- 첫째\n- 둘째\n"
            );
            assert!(h.exec().run().await.unwrap().items.is_empty());
        }
    }
}
