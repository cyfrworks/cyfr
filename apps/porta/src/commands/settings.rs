use crate::config;
use crate::backend::registry::BackendInfo;
use crate::gateway::SharedRegistry;

/// Return raw JSON config string for the editor
#[tauri::command]
pub async fn get_config_json() -> Result<String, String> {
    Ok(config::load_config_json())
}

/// Save raw JSON config string, validate, and restart backends
#[tauri::command]
pub async fn save_config_json(
    registry: tauri::State<'_, SharedRegistry>,
    json: String,
) -> Result<(), String> {
    // Validate and save
    config::save_config_json(&json)?;

    // Reload config and restart all backends
    let cfg = config::load_config();
    let mut reg = registry.write().await;

    // Stop all current backends
    let names: Vec<String> = reg.statuses().iter().map(|i| i.name.clone()).collect();
    for name in names {
        let _ = reg.stop_backend(&name).await;
    }

    // Start backends from new config
    for (name, server_cfg) in &cfg.mcp_servers {
        if !server_cfg.enabled {
            continue;
        }
        let backend_cfg = crate::config::types::to_backend_config(name, server_cfg);
        if let Err(e) = reg.start_backend(&backend_cfg).await {
            tracing::warn!("Failed to start backend '{}': {}", name, e);
        }
    }

    Ok(())
}

/// List all backends with their status
#[tauri::command]
pub async fn list_backends(
    registry: tauri::State<'_, SharedRegistry>,
) -> Result<Vec<BackendInfo>, String> {
    let reg = registry.read().await;
    Ok(reg.statuses_with_tools().await)
}
