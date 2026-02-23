use crate::error::AppError;
use std::path::Path;
use std::process::Command;

/// Spawn sing-box with platform-specific privilege elevation.
/// Returns the PID of the spawned process.
pub fn spawn_singbox(binary_path: &Path, config_path: &Path) -> Result<u32, AppError> {
    let binary = binary_path.to_string_lossy().to_string();
    let config = config_path.to_string_lossy().to_string();

    #[cfg(target_os = "macos")]
    {
        spawn_macos(&binary, &config)
    }
    #[cfg(target_os = "linux")]
    {
        spawn_linux(&binary, &config)
    }
    #[cfg(target_os = "windows")]
    {
        spawn_windows(&binary, &config)
    }
}

#[cfg(target_os = "macos")]
fn spawn_macos(binary: &str, config: &str) -> Result<u32, AppError> {
    // Use osascript to get admin privileges with native macOS password prompt.
    // The script runs sing-box in background and prints its PID.
    let script = format!(
        r#"do shell script "{binary} run -c {config} & echo $!" with administrator privileges"#,
    );

    let output = Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .output()
        .map_err(|e| AppError::ProcessSpawnFailed(e.to_string()))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AppError::ProcessSpawnFailed(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let pid: u32 = stdout
        .trim()
        .lines()
        .last()
        .unwrap_or("")
        .trim()
        .parse()
        .map_err(|e: std::num::ParseIntError| AppError::ProcessSpawnFailed(e.to_string()))?;

    Ok(pid)
}

#[cfg(target_os = "linux")]
fn spawn_linux(binary: &str, config: &str) -> Result<u32, AppError> {
    // pkexec provides a graphical authentication dialog on Linux
    let child = Command::new("pkexec")
        .arg(binary)
        .arg("run")
        .arg("-c")
        .arg(config)
        .spawn()
        .map_err(|e| AppError::ProcessSpawnFailed(e.to_string()))?;

    Ok(child.id())
}

#[cfg(target_os = "windows")]
fn spawn_windows(binary: &str, config: &str) -> Result<u32, AppError> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let child = Command::new(binary)
        .arg("run")
        .arg("-c")
        .arg(config)
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| AppError::ProcessSpawnFailed(e.to_string()))?;

    Ok(child.id())
}

/// Kill the sing-box process by PID (platform-specific).
pub fn kill_singbox(pid: u32) -> Result<(), AppError> {
    #[cfg(target_os = "macos")]
    {
        // Process was started with admin privileges, need sudo to kill
        let script = format!(r#"do shell script "kill {pid}" with administrator privileges"#);
        let output = Command::new("osascript")
            .arg("-e")
            .arg(&script)
            .output()
            .map_err(|e| AppError::IoError(e.to_string()))?;
        if !output.status.success() {
            // Try regular kill as fallback
            let _ = Command::new("kill")
                .arg(pid.to_string())
                .output();
        }
    }

    #[cfg(target_os = "linux")]
    {
        let output = Command::new("pkexec")
            .arg("kill")
            .arg(pid.to_string())
            .output()
            .map_err(|e| AppError::IoError(e.to_string()))?;
        if !output.status.success() {
            let _ = Command::new("kill")
                .arg(pid.to_string())
                .output();
        }
    }

    #[cfg(target_os = "windows")]
    {
        Command::new("taskkill")
            .args(["/F", "/PID", &pid.to_string()])
            .output()
            .map_err(|e| AppError::IoError(e.to_string()))?;
    }

    Ok(())
}

/// Check if a process with the given PID is still running.
pub fn is_process_running(pid: u32) -> bool {
    #[cfg(unix)]
    {
        // Signal 0 checks existence without actually sending a signal
        unsafe { libc::kill(pid as i32, 0) == 0 }
    }
    #[cfg(windows)]
    {
        Command::new("tasklist")
            .args(["/FI", &format!("PID eq {pid}"), "/NH"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains(&pid.to_string()))
            .unwrap_or(false)
    }
}
