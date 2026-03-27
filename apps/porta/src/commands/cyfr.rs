use serde::Serialize;
use std::time::Duration;
use tokio::process::Command;
use std::process::Stdio;
use tracing::info;

/// Max size for stdout/stderr returned to frontend (1 MB).
const MAX_OUTPUT_SIZE: usize = 1_048_576;

#[derive(Debug, Serialize)]
pub struct CyfrResult {
    pub stdout: String,
    pub stderr: String,
    pub success: bool,
    pub code: i32,
}

/// Determine the appropriate timeout for a CLI command.
fn timeout_for(args: &[String]) -> Duration {
    match args.first().map(|s| s.as_str()) {
        Some("up" | "down" | "upgrade" | "update" | "register") => Duration::from_secs(300),
        Some("run") => Duration::from_secs(120),
        _ => Duration::from_secs(60),
    }
}

/// Truncate a string to max bytes, appending "... (truncated)" if needed.
fn truncate(s: String, max: usize) -> String {
    if s.len() <= max {
        return s;
    }
    let mut truncated = s;
    truncated.truncate(max);
    truncated.push_str("\n... (output truncated)");
    truncated
}

/// Run any `cyfr` CLI command with --json --no-interactive flags.
/// The frontend calls this as: invoke("cyfr_command", { args: ["whoami"] })
#[tauri::command]
pub async fn cyfr_command(_app: tauri::AppHandle, args: Vec<String>) -> Result<CyfrResult, String> {
    let home = dirs::home_dir().expect("could not determine home directory");
    let proj_dir = home.join("cyfr");
    // Use project dir if it exists, otherwise home (for commands like whoami/login that don't need a project)
    let cwd = if proj_dir.exists() { &proj_dir } else { &home };

    let mut full_args = args.clone();

    // Append --json if not already present and command supports it
    if !full_args.contains(&"--json".to_string()) {
        full_args.push("--json".to_string());
    }

    // Append --no-interactive if not already present
    if !full_args.contains(&"--no-interactive".to_string()) {
        full_args.push("--no-interactive".to_string());
    }

    let timeout = timeout_for(&args);
    info!("cyfr_command: cyfr {} (timeout {}s)", full_args.join(" "), timeout.as_secs());

    let cmd = crate::cli::cli_command();
    let fut = Command::new(&cmd)
        .args(&full_args)
        .current_dir(cwd)
        .env("COMPOSE_PROJECT_NAME", "cyfr")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();

    let output = tokio::time::timeout(timeout, fut)
        .await
        .map_err(|_| format!("Command timed out after {}s: cyfr {}", timeout.as_secs(), args.join(" ")))?
        .map_err(|e| format!("Failed to run cyfr: {}", e))?;

    let stdout = truncate(String::from_utf8_lossy(&output.stdout).to_string(), MAX_OUTPUT_SIZE);
    let stderr = truncate(String::from_utf8_lossy(&output.stderr).to_string(), MAX_OUTPUT_SIZE);
    let code = output.status.code().unwrap_or(-1);

    if !stdout.is_empty() {
        info!("cyfr stdout: {}", stdout.trim_end());
    }
    if !stderr.is_empty() && !output.status.success() {
        info!("cyfr stderr: {}", stderr.trim_end());
    }

    Ok(CyfrResult {
        stdout,
        stderr,
        success: output.status.success(),
        code,
    })
}

/// Atomically write a file: write to temp, then rename.
fn atomic_write(path: &std::path::Path, content: &str) -> Result<(), String> {
    let parent = path.parent().ok_or("Invalid path")?;
    std::fs::create_dir_all(parent)
        .map_err(|e| format!("Failed to create directory {}: {}", parent.display(), e))?;

    let tmp_path = path.with_extension("tmp");
    std::fs::write(&tmp_path, content)
        .map_err(|e| format!("Failed to write temp file: {}", e))?;
    std::fs::rename(&tmp_path, path)
        .map_err(|e| {
            let _ = std::fs::remove_file(&tmp_path);
            format!("Failed to rename temp file: {}", e)
        })?;
    Ok(())
}

/// Write session_id into ~/.cyfr/config.json so the CLI picks it up.
/// Called after device flow login completes.
#[tauri::command]
pub async fn save_cli_session(session_id: String) -> Result<(), String> {
    let config_path = dirs::home_dir()
        .expect("could not determine home directory")
        .join(".cyfr")
        .join("config.json");

    // Read existing config or create default
    let mut config: serde_json::Value = if config_path.exists() {
        let content = std::fs::read_to_string(&config_path)
            .map_err(|e| format!("Failed to read config: {}", e))?;
        serde_json::from_str(&content)
            .unwrap_or_else(|_| default_config())
    } else {
        default_config()
    };

    // Get current context name
    let current = config
        .get("current_context")
        .and_then(|v| v.as_str())
        .unwrap_or("local")
        .to_string();

    // Set session_id on the current context
    if let Some(contexts) = config.get_mut("contexts").and_then(|c| c.as_object_mut()) {
        if let Some(ctx) = contexts.get_mut(&current).and_then(|c| c.as_object_mut()) {
            ctx.insert("session_id".to_string(), serde_json::Value::String(session_id));
        } else {
            // Context doesn't exist, create it
            let mut ctx = serde_json::Map::new();
            ctx.insert("url".to_string(), serde_json::Value::String(crate::config::cyfr_url()));
            ctx.insert("session_id".to_string(), serde_json::Value::String(session_id));
            contexts.insert(current, serde_json::Value::Object(ctx));
        }
    }

    // Write back atomically
    let json = serde_json::to_string_pretty(&config)
        .map_err(|e| format!("Failed to serialize config: {}", e))?;
    atomic_write(&config_path, &json)?;

    info!("Saved session to CLI config");
    Ok(())
}

/// Read session_id from ~/.cyfr/config.json (the CLI's config).
#[tauri::command]
pub async fn read_cli_session() -> Result<Option<String>, String> {
    let config_path = dirs::home_dir()
        .expect("could not determine home directory")
        .join(".cyfr")
        .join("config.json");

    if !config_path.exists() {
        return Ok(None);
    }

    let content = std::fs::read_to_string(&config_path)
        .map_err(|e| format!("Failed to read config: {}", e))?;

    let config: serde_json::Value = serde_json::from_str(&content)
        .map_err(|e| format!("Failed to parse config: {}", e))?;

    let current = config
        .get("current_context")
        .and_then(|v| v.as_str())
        .unwrap_or("local");

    let session_id = config
        .get("contexts")
        .and_then(|c| c.get(current))
        .and_then(|c| c.get("session_id"))
        .and_then(|s| s.as_str())
        .filter(|s| !s.is_empty()) // Don't return empty string as valid session
        .map(|s| s.to_string());

    Ok(session_id)
}

fn prefs_path() -> std::path::PathBuf {
    dirs::home_dir()
        .expect("could not determine home directory")
        .join(".cyfr")
        .join("porta_prefs.json")
}

/// Save model preferences to ~/.cyfr/porta_prefs.json
#[tauri::command]
pub async fn save_prefs(provider: String, model: String, catalyst_ref: String) -> Result<(), String> {
    let path = prefs_path();
    let prefs = serde_json::json!({
        "provider": provider,
        "model": model,
        "catalyst_ref": catalyst_ref,
    });
    let json = serde_json::to_string_pretty(&prefs)
        .map_err(|e| format!("Failed to serialize prefs: {}", e))?;
    atomic_write(&path, &json)?;
    Ok(())
}

/// Load model preferences from ~/.cyfr/porta_prefs.json
#[tauri::command]
pub async fn load_prefs() -> Result<Option<serde_json::Value>, String> {
    let path = prefs_path();
    match std::fs::read_to_string(&path) {
        Ok(content) => {
            let prefs: serde_json::Value = serde_json::from_str(&content)
                .map_err(|e| format!("Failed to parse prefs: {}", e))?;
            Ok(Some(prefs))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("Failed to read prefs: {}", e)),
    }
}

fn default_config() -> serde_json::Value {
    serde_json::json!({
        "current_context": "local",
        "contexts": {
            "local": {
                "url": crate::config::cyfr_url()
            }
        }
    })
}
