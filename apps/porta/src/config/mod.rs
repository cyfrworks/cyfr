pub mod types;

pub use types::*;

use std::path::PathBuf;
use tracing::info;

/// Returns the Cyfr home directory (~/.cyfr/)
pub fn cyfr_home() -> PathBuf {
    dirs::home_dir()
        .expect("could not determine home directory")
        .join(".cyfr")
}

/// Returns the path to aqua.json
pub fn config_path() -> PathBuf {
    cyfr_home().join("aqua.json")
}

/// Load config from ~/.cyfr/aqua.json, or return defaults
pub fn load_config() -> AquaConfig {
    let path = config_path();
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
    AquaConfig::default()
}

/// Load config as raw JSON string (for the editor UI)
pub fn load_config_json() -> String {
    let path = config_path();
    if path.exists() {
        if let Ok(contents) = std::fs::read_to_string(&path) {
            return contents;
        }
    }
    // Return default template
    serde_json::to_string_pretty(&AquaConfig::default()).unwrap_or_else(|_| "{}".to_string())
}

/// Save raw JSON string to config file (validates first)
pub fn save_config_json(json: &str) -> Result<(), String> {
    // Validate JSON parses correctly
    let _: AquaConfig = serde_json::from_str(json)
        .map_err(|e| format!("Invalid JSON: {}", e))?;

    let path = config_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create config dir: {}", e))?;
    }

    std::fs::write(&path, json)
        .map_err(|e| format!("Failed to write config: {}", e))?;

    info!("Saved config to {}", path.display());
    Ok(())
}

/// Save config struct to file
pub fn save_config(cfg: &AquaConfig) -> Result<(), String> {
    let json = serde_json::to_string_pretty(cfg)
        .map_err(|e| format!("Failed to serialize config: {}", e))?;
    save_config_json(&json)
}
