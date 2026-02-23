use crate::{
    config_manager, error::AppError, process_manager, settings::*, stats_reader,
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

    // Download config
    let config_path = match config_manager::download_and_prepare_config(&config_url, &data_dir).await {
        Ok(p) => p,
        Err(e) => {
            let mut status = state.status.lock().unwrap();
            *status = ConnectionStatus::Disconnected;
            let _ = app.emit("status-change", "Disconnected");
            return Err(e);
        }
    };

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

    // Spawn sing-box
    match process_manager::spawn_singbox(&binary_path, &config_path) {
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

    if let Some(pid) = pid {
        process_manager::kill_singbox(pid)?;
    }

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

    config_manager::download_and_prepare_config(&config_url, &data_dir).await?;

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

/// Simple ISO timestamp without pulling in chrono crate.
fn chrono_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    // Return unix timestamp as string — frontend will format it
    now.to_string()
}
