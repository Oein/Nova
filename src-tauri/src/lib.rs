pub mod commands;
pub mod error;
pub mod fs_util;
pub mod jamo;
pub mod line_index;
pub mod state;
pub mod workspace;

use tauri::menu::{MenuBuilder, MenuItemBuilder, PredefinedMenuItem, SubmenuBuilder};
use tauri::{Emitter, Manager};

const APP_NAME: &str = "Nova";

// Build the application menu. Accelerators are surfaced here so the macOS
// menu bar *shows* the shortcuts (⌘B, ⌘K, ...) rather than making users
// guess. On macOS the OS intercepts menu accelerators before they reach the
// webview, so each custom item fires a `menu:action` event; the frontend
// routes the string id to the appropriate handler (see src/lib/menu.ts).
fn build_menu<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
) -> tauri::Result<tauri::menu::Menu<R>> {
    // Application submenu (macOS convention: first slot, named after the app).
    let app_submenu = SubmenuBuilder::new(app, APP_NAME)
        .item(&PredefinedMenuItem::about(app, Some(APP_NAME), None)?)
        .separator()
        .item(
            &MenuItemBuilder::with_id("app:settings", "Settings…")
                .accelerator("CmdOrCtrl+,")
                .build(app)?,
        )
        .separator()
        .item(&PredefinedMenuItem::services(app, None)?)
        .separator()
        .item(&PredefinedMenuItem::hide(app, None)?)
        .item(&PredefinedMenuItem::hide_others(app, None)?)
        .item(&PredefinedMenuItem::show_all(app, None)?)
        .separator()
        .item(&PredefinedMenuItem::quit(app, None)?)
        .build()?;

    let file_submenu = SubmenuBuilder::new(app, "File")
        .item(
            &MenuItemBuilder::with_id("file:new-note", "New Note")
                .accelerator("CmdOrCtrl+N")
                .build(app)?,
        )
        .separator()
        .item(
            &MenuItemBuilder::with_id("file:save", "Save")
                .accelerator("CmdOrCtrl+S")
                .build(app)?,
        )
        .separator()
        .item(
            &MenuItemBuilder::with_id("file:close-tab", "Close Tab")
                .accelerator("CmdOrCtrl+W")
                .build(app)?,
        )
        .build()?;

    // Cut/Copy/Paste use the native predefined items — on macOS these dispatch
    // clipboard events into the focused element, which the editor already
    // handles via onCut/onCopy/onPaste. Undo/Redo/Select-All are custom
    // because Nova's buffer has its own undo stack (not the textarea's).
    let edit_submenu = SubmenuBuilder::new(app, "Edit")
        .item(
            &MenuItemBuilder::with_id("edit:undo", "Undo")
                .accelerator("CmdOrCtrl+Z")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("edit:redo", "Redo")
                .accelerator("CmdOrCtrl+Shift+Z")
                .build(app)?,
        )
        .separator()
        .item(&PredefinedMenuItem::cut(app, None)?)
        .item(&PredefinedMenuItem::copy(app, None)?)
        .item(&PredefinedMenuItem::paste(app, None)?)
        .separator()
        .item(
            &MenuItemBuilder::with_id("edit:select-all", "Select All")
                .accelerator("CmdOrCtrl+A")
                .build(app)?,
        )
        .separator()
        // Cmd+F is intercepted by macOS before the webview sees it, so it MUST
        // live on the native menu — webview-level keydown handlers won't fire.
        .item(
            &MenuItemBuilder::with_id("edit:find", "Find…")
                .accelerator("CmdOrCtrl+F")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("edit:replace", "Find and Replace…")
                .accelerator("CmdOrCtrl+Alt+F")
                .build(app)?,
        )
        .build()?;

    let view_submenu = SubmenuBuilder::new(app, "View")
        .item(
            &MenuItemBuilder::with_id("view:toggle-sidebar", "Toggle Sidebar")
                .accelerator("CmdOrCtrl+B")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("view:spotlight", "Command Palette…")
                .accelerator("CmdOrCtrl+K")
                .build(app)?,
        )
        .separator()
        .item(
            &MenuItemBuilder::with_id("view:zoom-in", "Zoom In")
                .accelerator("CmdOrCtrl+=")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("view:zoom-out", "Zoom Out")
                .accelerator("CmdOrCtrl+-")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("view:zoom-reset", "Actual Size")
                .accelerator("CmdOrCtrl+0")
                .build(app)?,
        )
        .separator()
        // macOS convention: ⌃⌘F toggles full screen. (The "fn" key is a
        // hardware/OS modifier that browsers/webviews don't expose, so we
        // can't bind Fn+F directly.)
        .item(
            &MenuItemBuilder::with_id("view:toggle-fullscreen", "Toggle Full Screen")
                .accelerator("Ctrl+Cmd+F")
                .build(app)?,
        )
        .separator()
        .item(
            &MenuItemBuilder::with_id("tab:next", "Next Tab")
                .accelerator("Ctrl+Tab")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("tab:prev", "Previous Tab")
                .accelerator("Ctrl+Shift+Tab")
                .build(app)?,
        )
        .build()?;

    let window_submenu = SubmenuBuilder::new(app, "Window")
        .item(&PredefinedMenuItem::minimize(app, None)?)
        .item(&PredefinedMenuItem::close_window(app, None)?)
        .build()?;

    MenuBuilder::new(app)
        .items(&[
            &app_submenu,
            &file_submenu,
            &edit_submenu,
            &view_submenu,
            &window_submenu,
        ])
        .build()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let state = state::AppState::new();
    tauri::Builder::default()
        .manage(state)
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_store::Builder::new().build())
        .menu(|handle| build_menu(handle))
        .on_menu_event(|app, event| {
            let id = event.id().as_ref().to_string();
            // Full-screen toggle is a window-level operation — handle it in
            // Rust rather than round-tripping through the webview.
            if id == "view:toggle-fullscreen" {
                if let Some(win) = app.get_webview_window("main") {
                    let current = win.is_fullscreen().unwrap_or(false);
                    let _ = win.set_fullscreen(!current);
                }
                return;
            }
            // Forward only our custom ids; predefined items (cut/copy/paste/…)
            // handle themselves via the OS.
            if id.contains(':') {
                let _ = app.emit("menu:action", id);
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::folder::open_folder,
            commands::folder::get_metadata,
            commands::folder::pick_folder,
            commands::file_small::read_file,
            commands::file_small::write_file,
            commands::file_large::open_large_file,
            commands::file_large::read_line_range,
            commands::file_large::read_byte_range,
            commands::file_large::close_large_file,
            commands::watcher::start_watching,
            commands::watcher::stop_watching,
            commands::workspace::open_workspace,
            commands::workspace::pick_workspace,
            commands::workspace::list_notes,
            commands::workspace::create_note,
            commands::workspace::read_note,
            commands::workspace::write_note,
            commands::workspace::delete_note,
            commands::workspace::hard_delete_note,
            commands::workspace::list_trashed_notes,
            commands::workspace::restore_note,
            commands::workspace::purge_trashed_note,
            commands::workspace::search_notes,
            commands::workspace::get_session,
            commands::workspace::save_session,
            commands::workspace::save_tab_state,
            commands::workspace::set_active_tab,
            commands::workspace::remove_tab_state,
            commands::workspace::reveal_note,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
