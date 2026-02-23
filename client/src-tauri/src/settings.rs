use serde::{Deserialize, Serialize};
use std::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AppSettings {
    pub config_url: String,
    pub refresh_interval_min: u64,
    pub last_update: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum ConnectionStatus {
    Disconnected,
    Connecting,
    Connected,
    Disconnecting,
}

#[derive(Debug, Serialize, Clone)]
pub struct TrafficData {
    pub up_speed: u64,
    pub down_speed: u64,
    pub up_total: u64,
    pub down_total: u64,
}

pub struct AppState {
    pub status: Mutex<ConnectionStatus>,
    pub process_id: Mutex<Option<u32>>,
    pub settings: Mutex<AppSettings>,
    pub traffic: Mutex<TrafficData>,
    pub stats_running: Mutex<bool>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            status: Mutex::new(ConnectionStatus::Disconnected),
            process_id: Mutex::new(None),
            settings: Mutex::new(AppSettings {
                config_url: String::new(),
                refresh_interval_min: 30,
                last_update: None,
            }),
            traffic: Mutex::new(TrafficData {
                up_speed: 0,
                down_speed: 0,
                up_total: 0,
                down_total: 0,
            }),
            stats_running: Mutex::new(false),
        }
    }
}
