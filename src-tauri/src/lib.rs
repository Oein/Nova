pub mod commands;
pub mod error;
pub mod fs_util;
pub mod jamo;
pub mod line_index;
pub mod state;
pub mod workspace;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let state = state::AppState::new();
    tauri::Builder::default()
        .manage(state)
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_store::Builder::new().build())
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
            commands::workspace::list_trashed_notes,
            commands::workspace::restore_note,
            commands::workspace::purge_trashed_note,
            commands::workspace::search_notes,
            commands::workspace::get_session,
            commands::workspace::save_session,
            commands::workspace::save_tab_state,
            commands::workspace::set_active_tab,
            commands::workspace::remove_tab_state,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
