use crate::error::AppError;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x08000000;

/// PowerShell snippet that calls InternetSetOption to notify apps of proxy change.
/// Without this, browsers won't pick up new proxy settings until restart.
#[cfg(target_os = "windows")]
const REFRESH_SCRIPT: &str = r#"
Add-Type -TypeDefinition '
using System; using System.Runtime.InteropServices;
public class WinInet {
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);
}
';
[WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null;
[WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
"#;

/// Enable the Windows system proxy via registry + notify running apps.
#[cfg(target_os = "windows")]
pub fn enable_system_proxy(port: u16) -> Result<(), AppError> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    let proxy_server = format!("127.0.0.1:{port}");
    let bypass = "localhost;127.*;10.*;192.168.*;<local>";

    for (name, reg_type, value) in [
        ("ProxyEnable", "REG_DWORD", "1"),
        ("ProxyServer", "REG_SZ", proxy_server.as_str()),
        ("ProxyOverride", "REG_SZ", bypass),
    ] {
        let output = Command::new("reg")
            .args([
                "add",
                r"HKCU\Software\Microsoft\Windows\Internet Settings",
                "/v", name,
                "/t", reg_type,
                "/d", value,
                "/f",
            ])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map_err(|e| AppError::IoError(e.to_string()))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(AppError::IoError(format!(
                "Failed to set registry value {name}: {stderr}"
            )));
        }
    }

    // Notify running applications (browsers) that proxy settings changed
    notify_proxy_change();

    Ok(())
}

/// Disable the Windows system proxy via registry + notify running apps.
#[cfg(target_os = "windows")]
pub fn disable_system_proxy() -> Result<(), AppError> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    let output = Command::new("reg")
        .args([
            "add",
            r"HKCU\Software\Microsoft\Windows\Internet Settings",
            "/v", "ProxyEnable",
            "/t", "REG_DWORD",
            "/d", "0",
            "/f",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| AppError::IoError(e.to_string()))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AppError::IoError(format!(
            "Failed to disable system proxy: {stderr}"
        )));
    }

    notify_proxy_change();

    Ok(())
}

/// Call InternetSetOption via PowerShell to broadcast proxy settings change.
#[cfg(target_os = "windows")]
fn notify_proxy_change() {
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    let _ = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", REFRESH_SCRIPT])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
}

#[cfg(not(target_os = "windows"))]
pub fn enable_system_proxy(_port: u16) -> Result<(), AppError> {
    Ok(())
}

#[cfg(not(target_os = "windows"))]
pub fn disable_system_proxy() -> Result<(), AppError> {
    Ok(())
}
