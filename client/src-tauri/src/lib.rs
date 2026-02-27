mod commands;
mod config_manager;
mod error;
mod process_manager;
mod proxy_manager;
mod settings;
mod stats_reader;

use settings::{AppState, ConnectionStatus};
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager,
};
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

            // Build system tray
            let show_item = MenuItem::with_id(app, "show", "Show Window", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show_item, &quit_item])?;

            let _tray = TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(move |app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "quit" => {
                        cleanup_before_exit(app);
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::DoubleClick { .. } = event {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                })
                .build(app)?;

            Ok(())
        })
        .on_window_event(|window, event| {
            // Close button hides the window instead of exiting
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
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

/// Gracefully disconnect sing-box and disable system proxy before exit.
fn cleanup_before_exit(app: &tauri::AppHandle) {
    let state = app.state::<AppState>();

    let is_connected = {
        let status = state.status.lock().unwrap();
        *status == ConnectionStatus::Connected
    };

    if !is_connected {
        return;
    }

    // Stop traffic stats stream
    stats_reader::stop_traffic_stream(app);

    // Kill sing-box process
    let pid = {
        let mut process_id = state.process_id.lock().unwrap();
        process_id.take()
    };
    if let Some(pid) = pid {
        let _ = process_manager::kill_singbox(pid);
    }

    // Disable system proxy on Windows
    if cfg!(target_os = "windows") {
        let _ = proxy_manager::disable_system_proxy();
    }
}
