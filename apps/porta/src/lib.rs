pub mod backend;
pub mod boot;
pub mod cli;
pub mod commands;
pub mod config;
pub mod docker;
pub mod error;
pub mod gateway;
pub mod preflight;
pub mod tray;
pub mod update;

/// Compile-time version from Cargo.toml
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Get the user's home directory, returning a descriptive error instead of panicking.
pub fn home_dir() -> Result<std::path::PathBuf, String> {
    dirs::home_dir().ok_or_else(|| {
        "Could not determine home directory. Ensure the HOME environment variable is set."
            .to_string()
    })
}

/// Tray menu item handles for status updates
pub struct TrayState {
    pub status_item: tauri::menu::MenuItem<tauri::Wry>,
}
