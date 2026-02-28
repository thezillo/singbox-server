use crate::settings::{AppState, TrafficData};
use futures_util::StreamExt;
use tauri::{AppHandle, Emitter, Manager};

/// Start reading traffic stats from sing-box's clash API via WebSocket.
/// Runs until the connection drops or `stats_running` is set to false.
pub async fn start_traffic_stream(app_handle: AppHandle) {
    let state = app_handle.state::<AppState>();

    // Mark stats as running
    {
        let mut running = state.stats_running.lock().unwrap();
        *running = true;
    }

    // Brief delay to let sing-box start up and open the clash API port
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;

    let api_port = *state.api_port.lock().unwrap();
    let url = format!("ws://127.0.0.1:{api_port}/traffic");

    // Retry connection a few times (sing-box may still be starting)
    let mut ws_stream = None;
    for attempt in 0..10 {
        match tokio_tungstenite::connect_async(&url).await {
            Ok((stream, _)) => {
                ws_stream = Some(stream);
                break;
            }
            Err(e) => {
                log::warn!("WS connect attempt {attempt}: {e}");
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }

        // Check if we should stop
        let running = state.stats_running.lock().unwrap();
        if !*running {
            return;
        }
    }

    let Some(ws_stream) = ws_stream else {
        log::error!("Failed to connect to sing-box traffic WebSocket");
        return;
    };

    let (_, mut read) = ws_stream.split();

    while let Some(msg) = read.next().await {
        // Check if we should stop
        {
            let running = state.stats_running.lock().unwrap();
            if !*running {
                break;
            }
        }

        let Ok(msg) = msg else { break };

        if let tokio_tungstenite::tungstenite::Message::Text(text) = msg {
            // sing-box sends: {"up": <bytes/s>, "down": <bytes/s>}
            if let Ok(data) = serde_json::from_str::<serde_json::Value>(&text) {
                let up_speed = data["up"].as_u64().unwrap_or(0);
                let down_speed = data["down"].as_u64().unwrap_or(0);

                let traffic = {
                    let mut traffic = state.traffic.lock().unwrap();
                    traffic.up_speed = up_speed;
                    traffic.down_speed = down_speed;
                    traffic.up_total += up_speed;
                    traffic.down_total += down_speed;
                    traffic.clone()
                };

                let _ = app_handle.emit("traffic-update", &traffic);
            }
        }
    }

    // Reset traffic on disconnect
    {
        let mut traffic = state.traffic.lock().unwrap();
        *traffic = TrafficData {
            up_speed: 0,
            down_speed: 0,
            up_total: 0,
            down_total: 0,
        };
        let mut running = state.stats_running.lock().unwrap();
        *running = false;
    }
}

/// Signal the stats reader to stop.
pub fn stop_traffic_stream(app_handle: &AppHandle) {
    let state = app_handle.state::<AppState>();
    let mut running = state.stats_running.lock().unwrap();
    *running = false;
}
