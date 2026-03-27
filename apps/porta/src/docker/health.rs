use std::time::Duration;
use tauri::Emitter;
use tokio::process::Command;
use tracing::{info, warn};

fn health_url() -> String {
    format!("{}/api/health", crate::config::cyfr_url())
}

fn mcp_url() -> String {
    crate::config::cyfr_mcp_url()
}

/// Check if the Docker container is still running (not exited/crashed).
async fn is_container_running() -> bool {
    let output = Command::new("docker")
        .args(["inspect", "--format", "{{.State.Status}}", "cyfr"])
        .output()
        .await
        .ok();

    if let Some(output) = output {
        let status = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return status == "running";
    }

    false
}

/// Poll the health endpoint until it returns 200.
/// Uses a soft deadline but keeps waiting as long as the container is running.
/// Only fails if:
/// - The container has exited/crashed
/// - The hard deadline (5 minutes) is reached
pub async fn wait_healthy(app: &tauri::AppHandle, soft_deadline_secs: u64) -> Result<(), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let start = tokio::time::Instant::now();
    let soft_deadline = Duration::from_secs(soft_deadline_secs);
    let hard_deadline = Duration::from_secs(300); // 5 minutes absolute max

    loop {
        match client.get(&health_url()).send().await {
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

        let elapsed = start.elapsed();

        // Hard deadline — give up regardless
        if elapsed >= hard_deadline {
            return Err(
                "Server did not become healthy within 5 minutes. Check 'docker logs cyfr' for details."
                    .to_string(),
            );
        }

        // Past soft deadline — check if container is still running
        if elapsed >= soft_deadline {
            if is_container_running().await {
                // Container is alive, just slow — keep waiting
                let elapsed_secs = elapsed.as_secs();
                let _ = app.emit(
                    "boot-state",
                    crate::boot::BootEvent {
                        state: "starting",
                        message: format!(
                            "Server is still starting up... ({}s)",
                            elapsed_secs
                        ),
                        progress: Some(0.85),
                    },
                );
            } else {
                return Err(
                    "Container stopped unexpectedly. Check 'docker logs cyfr' for details."
                        .to_string(),
                );
            }
        } else {
            // Before soft deadline — normal progress display
            let elapsed_secs = elapsed.as_secs();
            let progress = 0.7 + (elapsed_secs as f32 / soft_deadline_secs as f32) * 0.2;
            let _ = app.emit(
                "boot-state",
                crate::boot::BootEvent {
                    state: "starting",
                    message: format!("Waiting for server to be ready... ({}s)", elapsed_secs),
                    progress: Some(progress.min(0.9)),
                },
            );
        }

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

        match client.post(&mcp_url()).json(&body).send().await {
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
        if let Ok(resp) = client.get(&health_url()).send().await {
            return resp.status().is_success();
        }
    }

    false
}
