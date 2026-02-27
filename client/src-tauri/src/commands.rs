use crate::{
    config_manager, error::AppError, process_manager, proxy_manager, settings::*, stats_reader,
};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_store::StoreExt;

fn app_data_dir(app: &AppHandle) -> Result<std::path::PathBuf, AppError> {
    app.path()
        .app_data_dir()
        .map_err(|e| AppError::IoError(e.to_string()))
}

#[tauri::command]
pub async fn connect(app: AppHandle) -> Result<(), AppError> {
    let state = app.state::<AppState>();

    // Check we're not already connected/connecting
    {
        let status = state.status.lock().unwrap();
        if *status == ConnectionStatus::Connected || *status == ConnectionStatus::Connecting {
            return Ok(());
        }
    }

    // Set connecting
    {
        let mut status = state.status.lock().unwrap();
        *status = ConnectionStatus::Connecting;
    }
    let _ = app.emit("status-change", "Connecting");

    let data_dir = app_data_dir(&app)?;

    // Get config URL
    let config_url = {
        let settings = state.settings.lock().unwrap();
        settings.config_url.clone()
    };

    // On Windows: pick a random free port for the local proxy
    let proxy_port = if cfg!(target_os = "windows") {
        let port = config_manager::find_free_port()?;
        *state.proxy_port.lock().unwrap() = port;
        port
    } else {
        0
    };

    // Download config
    let (config_path, api_port) = match config_manager::download_and_prepare_config(&config_url, &data_dir, proxy_port).await {
        Ok(p) => p,
        Err(e) => {
            let mut status = state.status.lock().unwrap();
            *status = ConnectionStatus::Disconnected;
            let _ = app.emit("status-change", "Disconnected");
            return Err(e);
        }
    };
    *state.api_port.lock().unwrap() = api_port;

    // Update last_update timestamp
    {
        let mut settings = state.settings.lock().unwrap();
        settings.last_update = Some(chrono_now());
    }

    // Ensure sing-box binary exists
    let binary_path = match config_manager::ensure_singbox_binary(&data_dir).await {
        Ok(p) => p,
        Err(e) => {
            let mut status = state.status.lock().unwrap();
            *status = ConnectionStatus::Disconnected;
            let _ = app.emit("status-change", "Disconnected");
            return Err(e);
        }
    };

    // Spawn sing-box (log output to file for debugging)
    let log_path = data_dir.join("singbox.log");
    match process_manager::spawn_singbox(&binary_path, &config_path, &log_path) {
        Ok(pid) => {
            let mut process_id = state.process_id.lock().unwrap();
            *process_id = Some(pid);
        }
        Err(e) => {
            let mut status = state.status.lock().unwrap();
            *status = ConnectionStatus::Disconnected;
            let _ = app.emit("status-change", "Disconnected");
            return Err(e);
        }
    }

    // On Windows: wait for sing-box to bind the proxy port, then set system proxy
    if cfg!(target_os = "windows") {
        if let Err(_) = wait_for_port(proxy_port, 15).await {
            // sing-box failed to start — read log for details, clean up, and abort
            let log_tail = std::fs::read_to_string(&log_path)
                .unwrap_or_default()
                .lines()
                .rev()
                .take(20)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect::<Vec<_>>()
                .join("\n");

            let pid = {
                let mut process_id = state.process_id.lock().unwrap();
                process_id.take()
            };
            if let Some(pid) = pid {
                let _ = process_manager::kill_singbox(pid);
            }
            let mut status = state.status.lock().unwrap();
            *status = ConnectionStatus::Disconnected;
            let _ = app.emit("status-change", "Disconnected");

            let msg = if log_tail.is_empty() {
                format!("sing-box did not start on port {proxy_port} within 15s (no log output)")
            } else {
                format!("sing-box failed to start: {log_tail}")
            };
            return Err(AppError::ProcessSpawnFailed(msg));
        }

        if let Err(e) = proxy_manager::enable_system_proxy(proxy_port) {
            // Proxy is essential — without it traffic bypasses VPN entirely
            let pid = {
                let mut process_id = state.process_id.lock().unwrap();
                process_id.take()
            };
            if let Some(pid) = pid {
                let _ = process_manager::kill_singbox(pid);
            }
            let mut status = state.status.lock().unwrap();
            *status = ConnectionStatus::Disconnected;
            let _ = app.emit("status-change", "Disconnected");
            return Err(AppError::IoError(format!("Failed to set system proxy: {e}")));
        }
    }

    // Set connected
    {
        let mut status = state.status.lock().unwrap();
        *status = ConnectionStatus::Connected;
    }
    let _ = app.emit("status-change", "Connected");

    // Start traffic stats in background
    let app_clone = app.clone();
    tokio::spawn(async move {
        stats_reader::start_traffic_stream(app_clone).await;
    });

    Ok(())
}

#[tauri::command]
pub async fn disconnect(app: AppHandle) -> Result<(), AppError> {
    let state = app.state::<AppState>();

    {
        let mut status = state.status.lock().unwrap();
        *status = ConnectionStatus::Disconnecting;
    }
    let _ = app.emit("status-change", "Disconnecting");

    // Stop stats stream
    stats_reader::stop_traffic_stream(&app);

    // Kill process
    let pid = {
        let mut process_id = state.process_id.lock().unwrap();
        process_id.take()
    };

    let kill_result = if let Some(pid) = pid {
        process_manager::kill_singbox(pid)
    } else {
        Ok(())
    };

    // Always disable system proxy, even if kill failed — otherwise user loses internet
    if cfg!(target_os = "windows") {
        if let Err(e) = proxy_manager::disable_system_proxy() {
            log::error!("Failed to unset system proxy: {e}");
        }
    }

    // Propagate kill error after proxy is disabled
    kill_result?;

    // Reset traffic
    {
        let mut traffic = state.traffic.lock().unwrap();
        *traffic = TrafficData {
            up_speed: 0,
            down_speed: 0,
            up_total: 0,
            down_total: 0,
        };
    }

    {
        let mut status = state.status.lock().unwrap();
        *status = ConnectionStatus::Disconnected;
    }
    let _ = app.emit("status-change", "Disconnected");

    Ok(())
}

#[tauri::command]
pub fn get_status(app: AppHandle) -> ConnectionStatus {
    let state = app.state::<AppState>();
    let status = state.status.lock().unwrap();
    status.clone()
}

#[tauri::command]
pub async fn update_config(app: AppHandle) -> Result<String, AppError> {
    let state = app.state::<AppState>();
    let data_dir = app_data_dir(&app)?;

    let config_url = {
        let settings = state.settings.lock().unwrap();
        settings.config_url.clone()
    };

    let proxy_port = *state.proxy_port.lock().unwrap();
    let (_, api_port) = config_manager::download_and_prepare_config(&config_url, &data_dir, proxy_port).await?;
    *state.api_port.lock().unwrap() = api_port;

    let now = chrono_now();
    {
        let mut settings = state.settings.lock().unwrap();
        settings.last_update = Some(now.clone());
    }

    Ok(now)
}

#[tauri::command]
pub fn get_settings(app: AppHandle) -> AppSettings {
    let state = app.state::<AppState>();
    let settings = state.settings.lock().unwrap();
    settings.clone()
}

#[tauri::command]
pub async fn save_settings(
    app: AppHandle,
    config_url: String,
    refresh_interval_min: u64,
) -> Result<(), AppError> {
    let state = app.state::<AppState>();

    {
        let mut settings = state.settings.lock().unwrap();
        settings.config_url = config_url.clone();
        settings.refresh_interval_min = refresh_interval_min;
    }

    // Persist to tauri-plugin-store
    if let Ok(store) = app.store("settings.json") {
        store.set("config_url", serde_json::json!(config_url));
        store.set("refresh_interval_min", serde_json::json!(refresh_interval_min));
        let _ = store.save();
    }

    Ok(())
}

#[tauri::command]
pub fn get_singbox_path(app: AppHandle) -> Result<String, AppError> {
    let data_dir = app_data_dir(&app)?;
    let path = config_manager::singbox_binary_path(&data_dir);
    Ok(path.to_string_lossy().to_string())
}

/// Wait until a TCP port is accepting connections, or timeout.
async fn wait_for_port(port: u16, timeout_secs: u64) -> Result<(), AppError> {
    use std::net::{SocketAddr, TcpStream};
    use std::time::{Duration, Instant};

    let addr: SocketAddr = ([127, 0, 0, 1], port).into();
    let deadline = Instant::now() + Duration::from_secs(timeout_secs);

    while Instant::now() < deadline {
        if TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_ok() {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }

    Err(AppError::ProcessSpawnFailed(format!(
        "sing-box did not start listening on port {port} within {timeout_secs}s"
    )))
}

/// Simple ISO timestamp without pulling in chrono crate.
fn chrono_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    // Return unix timestamp as string — frontend will format it
    now.to_string()
}
