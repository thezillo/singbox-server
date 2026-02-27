use crate::error::AppError;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x08000000;

/// Enable the Windows system proxy via PowerShell: set registry + notify apps.
/// Single PowerShell call for reliability (vs multiple reg.exe invocations).
#[cfg(target_os = "windows")]
pub fn enable_system_proxy(port: u16) -> Result<(), AppError> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    let script = format!(
        r#"
$ErrorActionPreference = 'Stop'
$path = 'HKCU:\Software\Microsoft\Windows\Internet Settings'
Set-ItemProperty -Path $path -Name ProxyEnable -Value 1
Set-ItemProperty -Path $path -Name ProxyServer -Value '127.0.0.1:{port}'
Set-ItemProperty -Path $path -Name ProxyOverride -Value 'localhost;127.*;10.*;192.168.*;<local>'

Add-Type -TypeDefinition '
using System; using System.Runtime.InteropServices;
public class WinInet {{
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);
}}
'
[WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null

$v = Get-ItemProperty -Path $path -Name ProxyEnable
if ($v.ProxyEnable -ne 1) {{ throw 'ProxyEnable was not set' }}
"#
    );

    let output = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| AppError::IoError(format!("Failed to run PowerShell: {e}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AppError::IoError(format!(
            "Failed to enable system proxy: {stderr}"
        )));
    }

    Ok(())
}

/// Disable the Windows system proxy via PowerShell: clear registry + notify apps.
#[cfg(target_os = "windows")]
pub fn disable_system_proxy() -> Result<(), AppError> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    let script = r#"
$ErrorActionPreference = 'Stop'
$path = 'HKCU:\Software\Microsoft\Windows\Internet Settings'
Set-ItemProperty -Path $path -Name ProxyEnable -Value 0

Add-Type -TypeDefinition '
using System; using System.Runtime.InteropServices;
public class WinInet {
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);
}
'
[WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
"#;

    let output = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| AppError::IoError(format!("Failed to run PowerShell: {e}")))?;

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
