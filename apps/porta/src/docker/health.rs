use std::time::Duration;
use tauri::Emitter;
use tracing::{info, warn};

const HEALTH_URL: &str = "http://localhost:4000/api/health";
const MCP_URL: &str = "http://localhost:4000/mcp";

/// Poll the health endpoint until it returns 200 or deadline is reached.
/// Emits progress updates via boot-state events.
pub async fn wait_healthy(app: &tauri::AppHandle, deadline_secs: u64) -> Result<(), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let start = tokio::time::Instant::now();
    let deadline = start + Duration::from_secs(deadline_secs);

    loop {
        match client.get(HEALTH_URL).send().await {
            Ok(resp) if resp.status().is_success() => {
                info!("Health check passed");
                return Ok(());
            }
            Ok(resp) => {
                warn!("Health check returned status {}", resp.status());
            }
            Err(e) => {
                warn!("Health check failed: {}", e);
            }
        }

        if tokio::time::Instant::now() >= deadline {
            return Err(format!(
                "Server did not become healthy within {}s. Check 'docker logs cyfr' for details.",
                deadline_secs
            ));
        }

        // Emit progress so user sees elapsed time
        let elapsed = start.elapsed().as_secs();
        let progress = 0.7 + (elapsed as f32 / deadline_secs as f32) * 0.2; // 0.7 → 0.9
        let _ = app.emit(
            "boot-state",
            crate::boot::BootEvent {
                state: "starting",
                message: format!("Waiting for server to be ready... ({}s)", elapsed),
                progress: Some(progress.min(0.9)),
            },
        );

        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

/// Check that the MCP endpoint is accepting connections (what login actually needs).
pub async fn check_mcp_ready() -> bool {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()
        .ok();

    if let Some(client) = client {
        // Send a minimal JSON-RPC initialize to verify MCP is up
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": { "name": "porta-healthcheck", "version": "0.1.0" }
            }
        });

        match client.post(MCP_URL).json(&body).send().await {
            Ok(resp) if resp.status().is_success() || resp.status().as_u16() == 401 => {
                // 200 = MCP ready, 401 = MCP ready but needs auth (still means server is up)
                info!("MCP endpoint is ready");
                return true;
            }
            Ok(resp) => {
                warn!("MCP readiness check returned status {}", resp.status());
            }
            Err(e) => {
                warn!("MCP readiness check failed: {}", e);
            }
        }
    }

    false
}

/// Single health check (non-blocking)
pub async fn check_health() -> bool {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .ok();

    if let Some(client) = client {
        if let Ok(resp) = client.get(HEALTH_URL).send().await {
            return resp.status().is_success();
        }
    }

    false
}
