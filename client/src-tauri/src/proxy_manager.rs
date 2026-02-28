use crate::error::AppError;

/// Disable the Windows system proxy via registry and notify the system.
/// Called on disconnect and on startup cleanup (in case sing-box crashed without cleaning up).
///
/// sing-box's `set_system_proxy: true` enables the proxy via WinAPI, writing to:
///   HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings
/// We must write to the same key AND call InternetSetOptionW to notify running apps.
#[cfg(target_os = "windows")]
pub fn disable_system_proxy() -> Result<(), AppError> {
    use winreg::enums::*;
    use winreg::RegKey;

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let settings = hkcu
        .open_subkey_with_flags(
            r"Software\Microsoft\Windows\CurrentVersion\Internet Settings",
            KEY_WRITE,
        )
        .map_err(|e| AppError::IoError(format!("Failed to open registry key: {e}")))?;

    settings
        .set_value("ProxyEnable", &0u32)
        .map_err(|e| AppError::IoError(format!("Failed to set ProxyEnable: {e}")))?;

    settings
        .set_value("ProxyServer", &"")
        .map_err(|e| AppError::IoError(format!("Failed to clear ProxyServer: {e}")))?;

    // Broadcast the change so running browsers/apps pick it up immediately
    notify_proxy_changed();

    Ok(())
}

/// Call WinAPI InternetSetOptionW to notify all running applications
/// that the system proxy settings have changed.
#[cfg(target_os = "windows")]
fn notify_proxy_changed() {
    use std::ffi::c_void;

    const INTERNET_OPTION_SETTINGS_CHANGED: u32 = 39;
    const INTERNET_OPTION_REFRESH: u32 = 37;

    #[link(name = "wininet")]
    extern "system" {
        fn InternetSetOptionW(
            hInternet: *mut c_void,
            dwOption: u32,
            lpBuffer: *mut c_void,
            dwBufferLength: u32,
        ) -> i32;
    }

    unsafe {
        InternetSetOptionW(
            std::ptr::null_mut(),
            INTERNET_OPTION_SETTINGS_CHANGED,
            std::ptr::null_mut(),
            0,
        );
        InternetSetOptionW(
            std::ptr::null_mut(),
            INTERNET_OPTION_REFRESH,
            std::ptr::null_mut(),
            0,
        );
    }
}

#[cfg(not(target_os = "windows"))]
pub fn disable_system_proxy() -> Result<(), AppError> {
    Ok(())
}
