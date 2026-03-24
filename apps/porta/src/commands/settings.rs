use crate::config;
use crate::backend::registry::BackendInfo;
use crate::gateway::SharedRegistry;

/// Return raw JSON config string for the editor
#[tauri::command]
pub async fn get_config_json() -> Result<String, String> {
    Ok(config::load_config_json())
}

/// Launch Chrome with remote debugging enabled for Chrome DevTools MCP.
/// Spawns Chrome in the background and returns immediately.
#[tauri::command]
pub async fn launch_chrome() -> Result<String, String> {
    let exe = find_chrome()?;
    let user_data_dir = std::env::temp_dir().join("chrome-debug");

    std::process::Command::new(&exe)
        .arg("--remote-debugging-port=9222")
        .arg(format!("--user-data-dir={}", user_data_dir.display()))
        .spawn()
        .map_err(|e| format!("Failed to launch Chrome: {}", e))?;

    Ok("Chrome launched with debugging on port 9222".to_string())
}

/// Detect Chrome executable path based on platform.
fn find_chrome() -> Result<String, String> {
    #[cfg(target_os = "macos")]
    {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ];
        for path in &candidates {
            if std::path::Path::new(path).exists() {
                return Ok(path.to_string());
            }
        }
        Err("Chrome not found. Install Google Chrome from https://www.google.com/chrome/".to_string())
    }

    #[cfg(target_os = "windows")]
    {
        let candidates = [
            r"C:\Program Files\Google\Chrome\Application\chrome.exe",
            r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        ];
        for path in &candidates {
            if std::path::Path::new(path).exists() {
                return Ok(path.to_string());
            }
        }
        if let Ok(output) = std::process::Command::new("where").arg("chrome.exe").output() {
            if output.status.success() {
                let p = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if let Some(first) = p.lines().next() {
                    if !first.is_empty() {
                        return Ok(first.to_string());
                    }
                }
            }
        }
        Err("Chrome not found. Install Google Chrome from https://www.google.com/chrome/".to_string())
    }

    #[cfg(target_os = "linux")]
    {
        for name in &["google-chrome", "google-chrome-stable", "chromium-browser", "chromium"] {
            if let Ok(output) = std::process::Command::new("which").arg(name).output() {
                if output.status.success() {
                    let p = String::from_utf8_lossy(&output.stdout).trim().to_string();
                    if !p.is_empty() {
                        return Ok(p);
                    }
                }
            }
        }
        Err("Chrome not found. Install Google Chrome or Chromium.".to_string())
    }
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

/// Check if Chrome's remote debugging endpoint on port 9222 is alive.
/// Does an HTTP GET to /json/version and checks for a Chrome DevTools response.
#[tauri::command]
pub async fn check_debug_port() -> bool {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let result = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        let mut stream = tokio::net::TcpStream::connect("127.0.0.1:9222").await?;
        stream
            .write_all(b"GET /json/version HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nConnection: close\r\n\r\n")
            .await?;
        let mut buf = vec![0u8; 1024];
        let n = stream.read(&mut buf).await?;
        let body = String::from_utf8_lossy(&buf[..n]);
        // Chrome DevTools responds with JSON containing "Browser" or "webSocketDebuggerUrl"
        Ok::<bool, std::io::Error>(body.contains("webSocketDebuggerUrl") || body.contains("Browser"))
    })
    .await;

    matches!(result, Ok(Ok(true)))
}
