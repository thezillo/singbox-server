use crate::error::AppError;

/// Disable the Windows system proxy via registry (cleanup for when sing-box crashes).
/// Normal proxy enable/disable is handled by sing-box itself via `set_system_proxy: true`.
#[cfg(target_os = "windows")]
pub fn disable_system_proxy() -> Result<(), AppError> {
    use winreg::enums::*;
    use winreg::RegKey;

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let settings = hkcu
        .open_subkey_with_flags(
            r"Software\Microsoft\Windows\Internet Settings",
            KEY_WRITE,
        )
        .map_err(|e| AppError::IoError(format!("Failed to open registry key: {e}")))?;

    settings
        .set_value("ProxyEnable", &0u32)
        .map_err(|e| AppError::IoError(format!("Failed to set ProxyEnable: {e}")))?;

    settings
        .set_value("ProxyServer", &"")
        .map_err(|e| AppError::IoError(format!("Failed to clear ProxyServer: {e}")))?;

    Ok(())
}

#[cfg(not(target_os = "windows"))]
pub fn disable_system_proxy() -> Result<(), AppError> {
    Ok(())
}
