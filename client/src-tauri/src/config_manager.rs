use crate::error::AppError;
use std::path::{Path, PathBuf};

const SINGBOX_VERSION: &str = "1.11.4";

/// Build an HTTP client that accepts self-signed certs.
fn http_client() -> Result<reqwest::Client, AppError> {
    reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .build()
        .map_err(|e| AppError::ConfigDownloadFailed(e.to_string()))
}

/// Download config JSON from the server URL, inject clash_api, and save to disk.
pub async fn download_and_prepare_config(
    config_url: &str,
    app_data_dir: &Path,
) -> Result<PathBuf, AppError> {
    if config_url.is_empty() {
        return Err(AppError::ConfigUrlNotSet);
    }

    let client = http_client()?;
    let response = client.get(config_url).send().await?;

    if !response.status().is_success() {
        return Err(AppError::ConfigDownloadFailed(format!(
            "HTTP {}",
            response.status()
        )));
    }

    let body = response.text().await?;
    let mut config: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| AppError::ConfigParseFailed(e.to_string()))?;

    // Inject clash_api configuration for traffic monitoring
    let experimental = config
        .as_object_mut()
        .ok_or_else(|| AppError::ConfigParseFailed("config is not an object".into()))?
        .entry("experimental")
        .or_insert_with(|| serde_json::json!({}));

    let clash_api = experimental
        .as_object_mut()
        .ok_or_else(|| AppError::ConfigParseFailed("experimental is not an object".into()))?
        .entry("clash_api")
        .or_insert_with(|| serde_json::json!({}));

    if let Some(obj) = clash_api.as_object_mut() {
        obj.insert(
            "external_controller".into(),
            serde_json::json!("127.0.0.1:9090"),
        );
    }

    // On Windows: replace TUN inbound with mixed proxy (no admin required)
    if cfg!(target_os = "windows") {
        replace_tun_with_proxy(&mut config);
    }

    let config_path = app_data_dir.join("config.json");
    std::fs::create_dir_all(app_data_dir)?;
    std::fs::write(&config_path, serde_json::to_string_pretty(&config).unwrap())?;

    Ok(config_path)
}

/// Port for the local mixed proxy on Windows.
pub const PROXY_PORT: u16 = 1080;

/// Replace TUN inbound with a mixed (HTTP+SOCKS5) proxy inbound.
/// This allows sing-box to run without administrator privileges on Windows.
fn replace_tun_with_proxy(config: &mut serde_json::Value) {
    // Replace TUN inbound with mixed proxy inbound
    if let Some(inbounds) = config.get_mut("inbounds").and_then(|v| v.as_array_mut()) {
        for inbound in inbounds.iter_mut() {
            if inbound.get("type").and_then(|v| v.as_str()) == Some("tun") {
                *inbound = serde_json::json!({
                    "type": "mixed",
                    "tag": "mixed-in",
                    "listen": "127.0.0.1",
                    "listen_port": PROXY_PORT
                });
            }
        }
    }

    // Remove hijack-dns route rule (only works with TUN, not mixed proxy)
    if let Some(rules) = config
        .pointer_mut("/route/rules")
        .and_then(|v| v.as_array_mut())
    {
        rules.retain(|rule| {
            rule.get("action").and_then(|a| a.as_str()) != Some("hijack-dns")
        });
    }
}

/// Return the expected path of the sing-box binary.
pub fn singbox_binary_path(app_data_dir: &Path) -> PathBuf {
    let bin_name = if cfg!(target_os = "windows") {
        "sing-box.exe"
    } else {
        "sing-box"
    };
    app_data_dir.join("bin").join(bin_name)
}

/// Download sing-box binary from GitHub releases if it doesn't exist.
pub async fn ensure_singbox_binary(app_data_dir: &Path) -> Result<PathBuf, AppError> {
    let bin_path = singbox_binary_path(app_data_dir);
    if bin_path.exists() {
        return Ok(bin_path);
    }

    let (os, arch) = platform_tag();
    let ext = if cfg!(target_os = "windows") {
        "zip"
    } else {
        "tar.gz"
    };
    let folder_name = format!("sing-box-{SINGBOX_VERSION}-{os}-{arch}");
    let url = format!(
        "https://github.com/SagerNet/sing-box/releases/download/v{SINGBOX_VERSION}/{folder_name}.{ext}"
    );

    log::info!("Downloading sing-box from {url}");

    let client = reqwest::Client::new();
    let response = client.get(&url).send().await.map_err(|e| {
        AppError::BinaryDownloadFailed(e.to_string())
    })?;

    if !response.status().is_success() {
        return Err(AppError::BinaryDownloadFailed(format!(
            "HTTP {}",
            response.status()
        )));
    }

    let bytes = response.bytes().await.map_err(|e| {
        AppError::BinaryDownloadFailed(e.to_string())
    })?;

    let bin_dir = app_data_dir.join("bin");
    std::fs::create_dir_all(&bin_dir)?;

    if cfg!(target_os = "windows") {
        extract_zip(&bytes, &folder_name, &bin_path)?;
    } else {
        extract_tar_gz(&bytes, &folder_name, &bin_path)?;
    }

    // Make executable on unix
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&bin_path, std::fs::Permissions::from_mode(0o755))?;
    }

    Ok(bin_path)
}

fn platform_tag() -> (&'static str, &'static str) {
    let os = if cfg!(target_os = "macos") {
        "darwin"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "windows"
    };

    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "amd64"
    };

    (os, arch)
}

fn extract_tar_gz(data: &[u8], folder_name: &str, dest: &Path) -> Result<(), AppError> {
    use flate2::read::GzDecoder;
    use tar::Archive;

    let decoder = GzDecoder::new(data);
    let mut archive = Archive::new(decoder);

    let target_entry = format!("{folder_name}/sing-box");

    for entry in archive.entries().map_err(|e| AppError::BinaryDownloadFailed(e.to_string()))? {
        let mut entry = entry.map_err(|e| AppError::BinaryDownloadFailed(e.to_string()))?;
        let path = entry
            .path()
            .map_err(|e| AppError::BinaryDownloadFailed(e.to_string()))?
            .to_string_lossy()
            .to_string();
        if path == target_entry {
            let mut file = std::fs::File::create(dest)?;
            std::io::copy(&mut entry, &mut file)?;
            return Ok(());
        }
    }

    Err(AppError::BinaryDownloadFailed(
        "sing-box binary not found in archive".into(),
    ))
}

fn extract_zip(data: &[u8], folder_name: &str, dest: &Path) -> Result<(), AppError> {
    use std::io::Read;

    let cursor = std::io::Cursor::new(data);
    let mut archive =
        zip::ZipArchive::new(cursor).map_err(|e| AppError::BinaryDownloadFailed(e.to_string()))?;

    let target_entry = format!("{folder_name}/sing-box.exe");

    for i in 0..archive.len() {
        let mut file = archive
            .by_index(i)
            .map_err(|e| AppError::BinaryDownloadFailed(e.to_string()))?;
        if file.name() == target_entry {
            let mut buf = Vec::new();
            file.read_to_end(&mut buf)
                .map_err(|e| AppError::BinaryDownloadFailed(e.to_string()))?;
            std::fs::write(dest, buf)?;
            return Ok(());
        }
    }

    Err(AppError::BinaryDownloadFailed(
        "sing-box.exe not found in archive".into(),
    ))
}
