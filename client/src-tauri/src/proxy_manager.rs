use crate::error::AppError;

/// Enable the Windows system proxy via registry (HKCU — no admin required).
#[cfg(target_os = "windows")]
pub fn enable_system_proxy(port: u16) -> Result<(), AppError> {
    use std::process::Command;

    let proxy_server = format!("127.0.0.1:{port}");
    let bypass = "localhost;127.*;10.*;192.168.*;<local>";

    for (name, reg_type, value) in [
        ("ProxyEnable", "REG_DWORD", "1"),
        ("ProxyServer", "REG_SZ", proxy_server.as_str()),
        ("ProxyOverride", "REG_SZ", bypass),
    ] {
        Command::new("reg")
            .args([
                "add",
                r"HKCU\Software\Microsoft\Windows\Internet Settings",
                "/v", name,
                "/t", reg_type,
                "/d", value,
                "/f",
            ])
            .output()
            .map_err(|e| AppError::IoError(e.to_string()))?;
    }

    Ok(())
}

/// Disable the Windows system proxy via registry.
#[cfg(target_os = "windows")]
pub fn disable_system_proxy() -> Result<(), AppError> {
    use std::process::Command;

    Command::new("reg")
        .args([
            "add",
            r"HKCU\Software\Microsoft\Windows\Internet Settings",
            "/v", "ProxyEnable",
            "/t", "REG_DWORD",
            "/d", "0",
            "/f",
        ])
        .output()
        .map_err(|e| AppError::IoError(e.to_string()))?;

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
