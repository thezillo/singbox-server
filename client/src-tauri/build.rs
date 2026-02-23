fn main() {
    // On Windows, embed a manifest requesting admin privileges.
    // sing-box TUN requires administrator rights to create network adapters.
    #[cfg(windows)]
    {
        let mut res = winresource::WindowsResource::new();
        res.set_manifest(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
</assembly>"#,
        );
        res.compile().expect("failed to compile Windows resource");
    }

    tauri_build::build()
}
