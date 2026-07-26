//! Tauri entry points for Notion sync.
//!
//! These own the workspace mutex and hand a borrowed accessor to the executor.
//! The PAT is read from the database here and never returned to the frontend —
//! `NotionConfigView` carries only `tokenSet` and a four-character hint.

use std::sync::atomic::Ordering;

use tauri::{AppHandle, Emitter};

use crate::error::{AppError, AppResult};
use crate::notion::client::HttpNotionClient;
use crate::notion::store::{self, NotionConflict, NotionConflictDetail};
use crate::notion::sync::{BulkResolve, Executor, WsAccess};
use crate::notion::{
    now_ms, NotionConfigInput, NotionConfigView, NotionConnectionInfo, NotionDbSummary, SyncReport,
};
use crate::state::AppState;
use crate::workspace::Workspace;

/// Bridges the app's `Mutex<Option<Workspace>>` to the executor. The guard is
/// taken and dropped inside `with_ws`, so it never crosses an `.await` — which
/// matters because `rusqlite::Connection` is `!Sync`.
struct StateAccess<'a>(&'a AppState);

impl WsAccess for StateAccess<'_> {
    fn with_ws(&self, f: &mut dyn FnMut(&Workspace) -> AppResult<()>) -> AppResult<()> {
        let guard = self.0.workspace.lock().unwrap();
        let ws = guard
            .as_ref()
            .ok_or_else(|| AppError::Other("no workspace open".into()))?;
        f(ws)
    }
}

fn with_ws<T>(state: &AppState, f: impl FnOnce(&Workspace) -> AppResult<T>) -> AppResult<T> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard
        .as_ref()
        .ok_or_else(|| AppError::Other("no workspace open".into()))?;
    f(ws)
}

fn view(ws: &Workspace) -> AppResult<NotionConfigView> {
    let cfg = store::get_config(ws)?;
    Ok(cfg.to_view(store::count_conflicts(ws)?))
}

fn http(state: &AppState) -> reqwest::Client {
    state
        .http
        .get_or_init(HttpNotionClient::default_http)
        .clone()
}

/// Builds a client from the stored PAT, or from an explicit one when the user
/// is testing a token they haven't saved yet.
fn client(state: &AppState, override_token: Option<String>) -> AppResult<HttpNotionClient> {
    let token = match override_token.map(|t| t.trim().to_string()).filter(|t| !t.is_empty()) {
        Some(t) => t,
        None => with_ws(state, |ws| {
            store::get_config(ws)?
                .token
                .filter(|t| !t.is_empty())
                .ok_or_else(|| AppError::Other("Notion token is not set".into()))
        })?,
    };
    Ok(HttpNotionClient::new(http(state), token))
}

#[tauri::command]
pub async fn notion_get_config(
    state: tauri::State<'_, AppState>,
) -> Result<NotionConfigView, AppError> {
    with_ws(&state, view)
}

#[tauri::command]
pub async fn notion_set_config(
    state: tauri::State<'_, AppState>,
    config: NotionConfigInput,
) -> Result<NotionConfigView, AppError> {
    with_ws(&state, |ws| {
        store::set_config(ws, &config)?;
        view(ws)
    })
}

#[tauri::command]
pub async fn notion_clear_token(
    state: tauri::State<'_, AppState>,
) -> Result<NotionConfigView, AppError> {
    with_ws(&state, |ws| {
        store::clear_token(ws)?;
        view(ws)
    })
}

/// Verifies the token, and the database when one is given. Also persists the
/// discovered title property so a later sync doesn't have to guess.
#[tauri::command]
pub async fn notion_test_connection(
    state: tauri::State<'_, AppState>,
    token: Option<String>,
    database_id: Option<String>,
) -> Result<NotionConnectionInfo, AppError> {
    let api = client(&state, token)?;
    let bot = {
        use crate::notion::client::NotionApi;
        api.me().await?
    };
    let mut info = NotionConnectionInfo {
        bot_name: bot.name,
        workspace_name: bot.workspace_name,
        database_title: None,
        title_prop: None,
        page_count: None,
        property_warnings: Vec::new(),
    };
    let db_id = match database_id.filter(|d| !d.trim().is_empty()) {
        Some(d) => Some(normalize_database_id(&d)),
        None => with_ws(&state, |ws| Ok(store::get_config(ws)?.database_id))?,
    };
    if let Some(db_id) = db_id {
        use crate::notion::client::NotionApi;
        let db = api.retrieve_database(&db_id).await?;
        let first = api.query_database(&db_id, None).await?;
        info.database_title = Some(db.title.clone());
        info.title_prop = Some(db.title_prop.clone());
        info.page_count = Some(first.pages.len() as i64);
        // Tell the user up front what the first sync will do about the
        // timestamp columns, rather than surprising them with a schema change.
        let cfg = with_ws(&state, |ws| store::get_config(ws))?;
        for name in [cfg.created_prop.as_ref(), cfg.updated_prop.as_ref()]
            .into_iter()
            .flatten()
        {
            match db.properties.get(name.as_str()).map(String::as_str) {
                Some("date") => {}
                Some(other) => info.property_warnings.push(format!(
                    "\"{}\" already exists as a {} — timestamps for it will be skipped.",
                    name, other
                )),
                None => info
                    .property_warnings
                    .push(format!("\"{}\" will be created as a date property.", name)),
            }
        }
        with_ws(&state, |ws| store::set_title_prop(ws, &db.title_prop))?;
    }
    Ok(info)
}

#[tauri::command]
pub async fn notion_list_databases(
    state: tauri::State<'_, AppState>,
    token: Option<String>,
) -> Result<Vec<NotionDbSummary>, AppError> {
    use crate::notion::client::NotionApi;
    let api = client(&state, token)?;
    Ok(api
        .search_databases()
        .await?
        .into_iter()
        .map(|d| NotionDbSummary {
            id: d.id,
            title: d.title,
            url: d.url,
        })
        .collect())
}

#[tauri::command]
pub async fn notion_sync(
    app: AppHandle,
    state: tauri::State<'_, AppState>,
    dry_run: Option<bool>,
) -> Result<SyncReport, AppError> {
    // Compare-and-swap: a timer firing while the user is mid-click must not
    // start a second sync over the same database.
    if state
        .notion_running
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return Err(AppError::SyncBusy);
    }
    state.notion_cancel.store(false, Ordering::SeqCst);
    let result = run_sync_inner(&app, &state, dry_run.unwrap_or(false)).await;
    // Clear the cancel flag on the way out too, so a cancellation can't leak
    // into the next run.
    state.notion_cancel.store(false, Ordering::SeqCst);
    state.notion_running.store(false, Ordering::SeqCst);

    let status = match &result {
        Ok(r) if r.cancelled => "cancelled",
        Ok(r) if r.errors > 0 => "partial",
        Ok(_) => "ok",
        Err(_) => "error",
    };
    let _ = with_ws(&state, |ws| store::set_last_sync(ws, now_ms(), status));
    if let Ok(report) = &result {
        if !report.dry_run {
            let _ = app.emit("notion:changed", &report.changed_note_ids);
        }
    }
    result
}

async fn run_sync_inner(
    app: &AppHandle,
    state: &AppState,
    dry_run: bool,
) -> AppResult<SyncReport> {
    let api = client(state, None)?;
    let access = StateAccess(state);
    let handle = app.clone();
    let progress = move |done: usize, total: usize, current: &str| {
        let _ = handle.emit(
            "notion:progress",
            serde_json::json!({"done": done, "total": total, "current": current}),
        );
    };
    let executor = Executor {
        api: &api,
        access: &access,
        cancel: &state.notion_cancel,
        progress: Some(&progress),
        dry_run,
    };
    executor.run().await
}

#[tauri::command]
pub async fn notion_cancel_sync(state: tauri::State<'_, AppState>) -> Result<(), AppError> {
    state.notion_cancel.store(true, Ordering::SeqCst);
    Ok(())
}

#[tauri::command]
pub async fn notion_list_conflicts(
    state: tauri::State<'_, AppState>,
) -> Result<Vec<NotionConflict>, AppError> {
    with_ws(&state, store::list_conflicts)
}

#[tauri::command]
pub async fn notion_get_conflict(
    state: tauri::State<'_, AppState>,
    note_id: String,
) -> Result<Option<NotionConflictDetail>, AppError> {
    with_ws(&state, |ws| store::get_conflict(ws, &note_id))
}

#[tauri::command]
pub async fn notion_resolve_conflict(
    app: AppHandle,
    state: tauri::State<'_, AppState>,
    note_id: String,
    resolution: String,
) -> Result<(), AppError> {
    let api = client(&state, None)?;
    let access = StateAccess(&state);
    // A fresh flag, not `state.notion_cancel`: that one stays latched after a
    // cancelled sync, and reusing it would abort every later resolution.
    let cancel = std::sync::atomic::AtomicBool::new(false);
    let executor = Executor {
        api: &api,
        access: &access,
        cancel: &cancel,
        progress: None,
        dry_run: false,
    };
    let changed = executor.resolve(&note_id, &resolution).await?;
    let _ = app.emit("notion:changed", &changed);
    Ok(())
}

/// Applies one policy to every outstanding conflict.
///
/// `policy` is `local` (Nova's version wins), `remote` (Notion's wins), or
/// `both` (nothing is discarded). Shares the sync lock, since it does the same
/// kind of network work and must not overlap with a running sync.
#[tauri::command]
pub async fn notion_resolve_all(
    app: AppHandle,
    state: tauri::State<'_, AppState>,
    policy: String,
) -> Result<BulkResolve, AppError> {
    if state
        .notion_running
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return Err(AppError::SyncBusy);
    }
    let cancel = std::sync::atomic::AtomicBool::new(false);
    let result = async {
        let api = client(&state, None)?;
        let access = StateAccess(&state);
        let executor = Executor {
            api: &api,
            access: &access,
            cancel: &cancel,
            progress: None,
            dry_run: false,
        };
        executor.resolve_all(&policy).await
    }
    .await;
    state.notion_running.store(false, Ordering::SeqCst);

    if let Ok(out) = &result {
        let _ = app.emit("notion:changed", &out.changed_note_ids);
    }
    result
}

/// Detaches a note from Notion. With `exclude`, the note is also kept out of
/// future syncs (rather than being re-created as a fresh page next time).
#[tauri::command]
pub async fn notion_unlink_note(
    state: tauri::State<'_, AppState>,
    note_id: String,
    exclude: Option<bool>,
) -> Result<(), AppError> {
    with_ws(&state, |ws| {
        store::delete_conflict(ws, &note_id)?;
        if exclude.unwrap_or(false) {
            let mut link = store::get_link(ws, &note_id)?
                .unwrap_or_else(|| store::Link::new(&note_id, None));
            // Keep `page_id`: planning derives the set of already-claimed pages
            // from it, so clearing it would make the next sync treat the page as
            // brand new and import a duplicate note — the opposite of excluding.
            link.state = "excluded".into();
            store::upsert_link(ws, &link)
        } else {
            store::delete_link(ws, &note_id)
        }
    })
}

/// Accepts a raw id, a dashed UUID, or a full Notion URL — users copy whichever
/// is nearest to hand.
fn normalize_database_id(input: &str) -> String {
    let s = input.trim();
    let tail = s.rsplit('/').next().unwrap_or(s);
    let tail = tail.split('?').next().unwrap_or(tail);
    // A database URL looks like `.../My-DB-<32 hex>`; the id is the last
    // dash-separated run of 32 hex characters.
    let candidate = tail
        .rsplit('-')
        .find(|part| part.len() == 32 && part.chars().all(|c| c.is_ascii_hexdigit()))
        .unwrap_or(tail);
    candidate.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn database_id_accepted_in_every_shape() {
        let raw = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
        assert_eq!(normalize_database_id(raw), raw);
        assert_eq!(
            normalize_database_id(&format!("https://www.notion.so/me/My-DB-{}?v=xyz", raw)),
            raw
        );
        // A dashed UUID has no 32-char hex run, so it passes through intact.
        let dashed = "a1b2c3d4-e5f6-0718-293a-4b5c6d7e8f90";
        assert_eq!(normalize_database_id(dashed), dashed);
    }
}
