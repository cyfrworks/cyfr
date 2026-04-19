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
    let cwd = crate::preflight::command_cwd(&args)?;

    let mut full_args = args.clone();

    // Append --json if not already present and command supports it
    if !full_args.contains(&"--json".to_string()) {
        full_args.push("--json".to_string());
    }

    // Append --no-interactive if not already present
    if !full_args.contains(&"--no-interactive".to_string()) {
        full_args.push("--no-interactive".to_string());
    }

    // Always target the same server URL Porta is configured to use.
    if !full_args.contains(&"--url".to_string()) {
        full_args.push("--url".to_string());
        full_args.push(crate::config::cyfr_url());
    }

    let timeout = timeout_for(&args);
    info!("cyfr_command: cyfr {} (timeout {}s)", full_args.join(" "), timeout.as_secs());

    let cmd = crate::cli::cli_command();
    let fut = Command::new(&cmd)
        .args(&full_args)
        .current_dir(&cwd)
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

#[tauri::command]
pub async fn ensure_porta_registered() -> Result<(), String> {
    crate::gateway::ensure_registered().await
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
            ctx.insert("url".to_string(), serde_json::Value::String(crate::config::cyfr_url()));
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

// ===========================================================================
// Mode + API key orchestration (for SetupWizard)
// ===========================================================================

#[derive(Debug, Serialize)]
pub struct PortaModeInfo {
    pub mode: Option<String>,
    /// Active runtime URL — localhost for local modes, the saved remote URL
    /// for remote mode. Computed via `config::cyfr_url()`.
    pub url: String,
    /// Does porta.json have a saved api_key? (We never return the value itself
    /// from this query — use `read_porta_api_key` for that.)
    pub has_api_key: bool,
    /// The user's remembered remote URL (the raw `cyfrUrl` field from
    /// porta.json), preserved across mode switches. The wizard's RemoteForm
    /// uses this to pre-fill the URL input so users don't have to re-type it.
    pub remembered_remote_url: Option<String>,
}

/// Read the current Porta mode and connection info from porta.json.
/// Never returns the API key itself — only whether one is set.
#[tauri::command]
pub async fn get_porta_mode() -> Result<PortaModeInfo, String> {
    let cfg = crate::config::load_config();
    let mode = cfg.mode.map(|m| match m {
        crate::config::RuntimeModeChoice::Remote => "remote".to_string(),
        crate::config::RuntimeModeChoice::LocalAttached => "local-attached".to_string(),
        crate::config::RuntimeModeChoice::LocalManaged => "local-managed".to_string(),
    });
    // Use the trimmed cyfr_url() helper so the JS side never sees a trailing slash.
    let remembered_remote_url = cfg
        .cyfr_url
        .as_deref()
        .map(|u| u.trim_end_matches('/').to_string());
    Ok(PortaModeInfo {
        mode,
        url: crate::config::cyfr_url(),
        has_api_key: cfg.api_key.is_some(),
        remembered_remote_url,
    })
}

/// Read the API key for use by MCP calls. Returns None if no key is set.
#[tauri::command]
pub async fn read_porta_api_key() -> Result<Option<String>, String> {
    Ok(crate::config::load_config().api_key)
}

/// Save mode + (optional) url + (optional) api_key to porta.json atomically.
/// Called by the SetupWizard after the user picks a mode.
///
/// Behavior:
/// - For **Remote** mode: writes the provided url and api_key (if any).
///   These persist as the "remembered remote" credentials.
/// - For **local** modes: only writes the mode field. The previously stored
///   `cyfrUrl` and `apiKey` are LEFT INTACT so the user doesn't have to
///   re-enter them when they next switch back to Remote. The active runtime
///   URL for local modes is computed by `config::cyfr_url()` (which returns
///   localhost regardless of what's stored).
#[tauri::command]
pub async fn save_porta_mode(
    mode: String,
    url: Option<String>,
    api_key: Option<String>,
) -> Result<(), String> {
    let mode_choice = match mode.as_str() {
        "remote" => crate::config::RuntimeModeChoice::Remote,
        "local-attached" => crate::config::RuntimeModeChoice::LocalAttached,
        "local-managed" => crate::config::RuntimeModeChoice::LocalManaged,
        _ => return Err(format!("Invalid mode: {}", mode)),
    };

    let mut cfg = crate::config::load_config();
    cfg.mode = Some(mode_choice);

    // Only WRITE cyfr_url and api_key when switching INTO remote mode (and
    // only when the wizard explicitly passes them). For local modes, leave
    // them alone — they remain as the user's remembered remote credentials
    // for the next time they switch back to Remote.
    if matches!(mode_choice, crate::config::RuntimeModeChoice::Remote) {
        if let Some(u) = url {
            cfg.cyfr_url = Some(u);
        }
        if let Some(k) = api_key {
            cfg.api_key = Some(k);
        }
    }

    crate::config::save_config(&cfg)?;
    info!("Saved porta mode: {}", mode);
    Ok(())
}

/// Test a remote connection by hitting the health endpoint and (if api_key
/// supplied) calling `session.whoami` to confirm the key authenticates.
///
/// Post auth-refactor `session.whoami` returns local identity only
/// (`user_id, email, provider, display_name`) — the registry identity
/// moved to `registry.whoami`. This command only needs local-auth
/// validation so it doesn't call the registry action; callers that want
/// registry state should use the TS `registryWhoami()` helper via the
/// established MCP client. See auth_refactor.md §"Whoami split".
#[tauri::command]
pub async fn test_remote_connection(
    url: String,
    api_key: Option<String>,
) -> Result<serde_json::Value, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {}", e))?;

    // Step 1: health check
    let health_url = format!("{}/api/health", url.trim_end_matches('/'));
    let health_resp = client
        .get(&health_url)
        .send()
        .await
        .map_err(|e| format!("Could not reach {}: {}", health_url, e))?;
    if !health_resp.status().is_success() {
        return Err(format!(
            "Health check returned HTTP {}",
            health_resp.status().as_u16()
        ));
    }

    // Step 2: if api_key supplied, call session.whoami via MCP
    if let Some(key) = api_key {
        let mcp_url = format!("{}/mcp", url.trim_end_matches('/'));
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "session",
                "arguments": { "action": "whoami" }
            }
        });
        let resp = client
            .post(&mcp_url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/event-stream")
            .header("MCP-Protocol-Version", "2025-11-25")
            .header("Authorization", format!("Bearer {}", key))
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("MCP request failed: {}", e))?;

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("Failed to read MCP response: {}", e))?;

        if !status.is_success() {
            return Err(format!("API key rejected (HTTP {}): {}", status.as_u16(), text));
        }

        let parsed: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| format!("Invalid MCP response: {}", e))?;

        if let Some(err) = parsed.get("error") {
            return Err(format!("Server error: {}", err));
        }

        Ok(parsed.get("result").cloned().unwrap_or(serde_json::json!({})))
    } else {
        Ok(serde_json::json!({ "health": "ok" }))
    }
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
