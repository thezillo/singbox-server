mod commands;
mod config_manager;
mod error;
mod process_manager;
mod proxy_manager;
mod settings;
mod stats_reader;

use settings::AppState;
use tauri::Manager;
use tauri_plugin_store::StoreExt;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_store::Builder::default().build())
        .manage(AppState::default())
        .setup(|app| {
            // Load persisted settings from store
            let state = app.state::<AppState>();

            if let Ok(store) = app.store("settings.json") {
                let mut settings = state.settings.lock().unwrap();

                if let Some(url) = store.get("config_url").and_then(|v| v.as_str().map(String::from)) {
                    settings.config_url = url;
                }
                if let Some(interval) = store.get("refresh_interval_min").and_then(|v| v.as_u64()) {
                    settings.refresh_interval_min = interval;
                }
                if let Some(last) = store.get("last_update").and_then(|v| v.as_str().map(String::from)) {
                    settings.last_update = Some(last);
                }
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::connect,
            commands::disconnect,
            commands::get_status,
            commands::update_config,
            commands::get_settings,
            commands::save_settings,
            commands::get_singbox_path,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
