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
    Emitter, Manager, RunEvent,
};
use tauri_plugin_deep_link::DeepLinkExt;
use tauri_plugin_store::StoreExt;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder = tauri::Builder::default();

    // single-instance MUST come before deep-link on desktop
    #[cfg(desktop)]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|_app, _argv, _cwd| {
            log::info!("single-instance: second launch blocked");
        }));
    }

    let app = builder
        .plugin(tauri_plugin_deep_link::init())
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

            // On startup: clear stale proxy if sing-box isn't running
            if cfg!(target_os = "windows") {
                let _ = proxy_manager::disable_system_proxy();
            }

            // Deep link: handle URL that launched this instance
            if let Ok(Some(urls)) = app.deep_link().get_current() {
                for url in &urls {
                    log::info!("App launched via deep link: {url}");
                    handle_deep_link(app.handle(), url.as_str());
                }
            }

            // Deep link: handle URLs arriving while app is running
            let app_handle = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                for url in event.urls() {
                    log::info!("Deep link received: {url}");
                    handle_deep_link(&app_handle, url.as_str());
                }
            });

            // Register protocol in dev mode (installer does it in production)
            #[cfg(debug_assertions)]
            app.deep_link().register("sing-box").ok();

            // Build system tray
            let show_item = MenuItem::with_id(app, "show", "Show Window", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show_item, &quit_item])?;

            let icon = app.default_window_icon()
                .ok_or("no default window icon configured")?
                .clone();

            let _tray = TrayIconBuilder::new()
                .icon(icon)
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
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app, event| {
        if let RunEvent::Exit = event {
            cleanup_before_exit(app);
        }
    });
}

/// Parse a sing-box:// deep link and save the profile URL, then trigger connect.
///
/// Format: sing-box://import-remote-profile?url=<encoded-url>#<label>
fn handle_deep_link(app: &tauri::AppHandle, raw_url: &str) {
    // Show window
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
        let _ = window.unminimize();
    }

    let parsed = match url::Url::parse(raw_url) {
        Ok(u) => u,
        Err(e) => {
            log::warn!("Deep link parse error: {e}");
            return;
        }
    };

    if parsed.host_str() != Some("import-remote-profile") {
        log::warn!("Unknown deep link action: {raw_url}");
        return;
    }

    let profile_url = match parsed.query_pairs().find(|(k, _)| k == "url").map(|(_, v)| v.into_owned()) {
        Some(url) if !url.is_empty() => url,
        _ => {
            log::warn!("Deep link missing url parameter");
            return;
        }
    };

    log::info!("Importing profile: {profile_url}");

    // Save the config URL
    let state = app.state::<AppState>();
    {
        let mut settings = state.settings.lock().unwrap();
        settings.config_url = profile_url.clone();
    }

    // Persist to store
    if let Ok(store) = app.store("settings.json") {
        store.set("config_url", serde_json::json!(profile_url));
        let _ = store.save();
    }

    // Emit event to frontend to update UI and auto-connect
    let _ = app.emit("deep-link-import", serde_json::json!({ "url": profile_url }));
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
        if let Err(e) = process_manager::kill_singbox(pid) {
            log::error!("Failed to kill sing-box (PID {pid}) during cleanup: {e}");
        }
    }

    // Disable system proxy on Windows
    if cfg!(target_os = "windows") {
        if let Err(e) = proxy_manager::disable_system_proxy() {
            log::error!("Failed to disable system proxy during cleanup: {e}");
        }
    }
}
