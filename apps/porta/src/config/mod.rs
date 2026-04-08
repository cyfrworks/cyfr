pub mod types;

pub use types::*;

use std::path::PathBuf;
use tracing::info;

/// Returns the Cyfr home directory (~/.cyfr/)
fn cyfr_home() -> Result<PathBuf, String> {
    Ok(crate::home_dir()?.join(".cyfr"))
}

/// Returns the path to porta.json
fn config_path() -> Result<PathBuf, String> {
    Ok(cyfr_home()?.join("porta.json"))
}

/// Load config from ~/.cyfr/porta.json, or return defaults
pub fn load_config() -> PortaConfig {
    let path = match config_path() {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!("Cannot determine config path: {}", e);
            return PortaConfig::default();
        }
    };
    if path.exists() {
        match std::fs::read_to_string(&path) {
            Ok(contents) => match serde_json::from_str(&contents) {
                Ok(cfg) => {
                    info!("Loaded config from {}", path.display());
                    return cfg;
                }
                Err(e) => {
                    tracing::warn!("Failed to parse {}: {}", path.display(), e);
                }
            },
            Err(e) => {
                tracing::warn!("Failed to read {}: {}", path.display(), e);
            }
        }
    }

    info!("Using default config");
    PortaConfig::default()
}

/// Load config as raw JSON string (for the editor UI)
pub fn load_config_json() -> String {
    let path = match config_path() {
        Ok(p) => p,
        Err(_) => {
            return serde_json::to_string_pretty(&PortaConfig::default())
                .unwrap_or_else(|_| "{}".to_string());
        }
    };
    if path.exists() {
        if let Ok(contents) = std::fs::read_to_string(&path) {
            return contents;
        }
    }
    // Return default template
    serde_json::to_string_pretty(&PortaConfig::default()).unwrap_or_else(|_| "{}".to_string())
}

/// Save raw JSON string to config file (validates first)
pub fn save_config_json(json: &str) -> Result<(), String> {
    // Validate JSON parses correctly
    let _: PortaConfig = serde_json::from_str(json)
        .map_err(|e| format!("Invalid JSON: {}", e))?;

    let path = config_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create config dir: {}", e))?;
    }

    // Atomic write: write to temp file, then rename
    let tmp_path = path.with_extension("tmp");
    std::fs::write(&tmp_path, json)
        .map_err(|e| format!("Failed to write config: {}", e))?;
    std::fs::rename(&tmp_path, &path)
        .map_err(|e| {
            let _ = std::fs::remove_file(&tmp_path);
            format!("Failed to finalize config: {}", e)
        })?;

    info!("Saved config to {}", path.display());
    Ok(())
}

/// Return the configured Cyfr base URL (e.g. "http://127.0.0.1:4000").
/// Reads from porta.json `cyfrUrl`, falls back to the default.
/// Always strips a trailing slash so callers can safely concatenate paths
/// like `format!("{}/mcp", cyfr_url())` without producing `//mcp`.
pub fn cyfr_url() -> String {
    let raw = load_config()
        .cyfr_url
        .unwrap_or_else(|| types::DEFAULT_CYFR_URL.to_string());
    raw.trim_end_matches('/').to_string()
}

/// Return the Cyfr MCP endpoint URL.
pub fn cyfr_mcp_url() -> String {
    format!("{}/mcp", cyfr_url())
}

/// Save config struct to file
pub fn save_config(cfg: &PortaConfig) -> Result<(), String> {
    let json = serde_json::to_string_pretty(cfg)
        .map_err(|e| format!("Failed to serialize config: {}", e))?;
    save_config_json(&json)
}
