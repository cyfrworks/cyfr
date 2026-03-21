pub mod backend;
pub mod boot;
pub mod cli;
pub mod commands;
pub mod config;
pub mod docker;
pub mod error;
pub mod gateway;
pub mod tray;
pub mod update;

/// Compile-time version from Cargo.toml
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Tray menu item handles for status updates
pub struct TrayState {
    pub status_item: tauri::menu::MenuItem<tauri::Wry>,
}
