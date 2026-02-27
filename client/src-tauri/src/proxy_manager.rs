use crate::error::AppError;

/// Enable the Windows system proxy via registry (HKCU — no admin required).
#[cfg(target_os = "windows")]
pub fn enable_system_proxy(port: u16) -> Result<(), AppError> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

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

    Ok(())
}

/// Disable the Windows system proxy via registry.
#[cfg(target_os = "windows")]
pub fn disable_system_proxy() -> Result<(), AppError> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

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

    Ok(())
}

#[cfg(not(target_os = "windows"))]
pub fn enable_system_proxy(_port: u16) -> Result<(), AppError> {
    Ok(())
}

#[cfg(not(target_os = "windows"))]
pub fn disable_system_proxy() -> Result<(), AppError> {
    Ok(())
}
