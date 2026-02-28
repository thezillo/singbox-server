use serde::Serialize;

#[derive(Debug, Clone)]
pub enum AppError {
    ConfigUrlNotSet,
    ConfigDownloadFailed(String),
    ConfigParseFailed(String),
    BinaryDownloadFailed(String),
    ProcessSpawnFailed(String),
    IoError(String),
}

impl std::fmt::Display for AppError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ConfigUrlNotSet => write!(f, "Config URL is not set"),
            Self::ConfigDownloadFailed(e) => write!(f, "Failed to download config: {e}"),
            Self::ConfigParseFailed(e) => write!(f, "Failed to parse config: {e}"),
            Self::BinaryDownloadFailed(e) => write!(f, "Failed to download sing-box: {e}"),
            Self::ProcessSpawnFailed(e) => write!(f, "Failed to start sing-box: {e}"),
            Self::IoError(e) => write!(f, "IO error: {e}"),
        }
    }
}

impl Serialize for AppError {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_string())
    }
}

impl From<std::io::Error> for AppError {
    fn from(e: std::io::Error) -> Self {
        Self::IoError(e.to_string())
    }
}

impl From<reqwest::Error> for AppError {
    fn from(e: reqwest::Error) -> Self {
        Self::ConfigDownloadFailed(e.to_string())
    }
}

