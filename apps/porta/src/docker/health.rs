use std::time::Duration;
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
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        Command::new(super::docker_command())
            .args(["inspect", "--format", "{{.State.Status}}", "cyfr"])
            .output(),
    )
    .await;

    if let Ok(Ok(output)) = result {
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
///
/// Progress is reported via `on_progress(message, progress_fraction)` so callers
/// can emit the appropriate event type (boot-state vs upgrade-progress).
///
/// `progress_start` / `progress_end` define the progress range this function
/// reports within, so callers can place it at the right position in their
/// overall progress bar without regressions.
pub async fn wait_healthy<F>(
    on_progress: F,
    soft_deadline_secs: u64,
    progress_start: f32,
    progress_end: f32,
) -> Result<(), String>
where
    F: Fn(&str, f32),
{
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let start = tokio::time::Instant::now();
    let soft_deadline = Duration::from_secs(soft_deadline_secs);
    let hard_deadline = Duration::from_secs(300); // 5 minutes absolute max

    // Split the progress range: 80% before soft deadline, 20% after (slow-start extension).
    let soft_progress = progress_start + (progress_end - progress_start) * 0.8;

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
                // Container is alive, just slow — keep waiting.
                // Scale progress from soft_progress to progress_end between soft and hard deadlines.
                let elapsed_secs = elapsed.as_secs();
                let beyond_soft = (elapsed - soft_deadline).as_secs_f32();
                let soft_to_hard = (hard_deadline - soft_deadline).as_secs_f32();
                let progress = (soft_progress + (beyond_soft / soft_to_hard) * (progress_end - soft_progress)).min(progress_end);
                on_progress(
                    &format!("Server is still starting up... ({}s)", elapsed_secs),
                    progress,
                );
            } else {
                return Err(
                    "Container stopped unexpectedly. Check 'docker logs cyfr' for details."
                        .to_string(),
                );
            }
        } else {
            // Before soft deadline — scale progress from progress_start to soft_progress
            let elapsed_secs = elapsed.as_secs();
            let fraction = elapsed_secs as f32 / soft_deadline_secs as f32;
            let progress = progress_start + fraction * (soft_progress - progress_start);
            on_progress(
                &format!("Waiting for server to be ready... ({}s)", elapsed_secs),
                progress.min(soft_progress),
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
                "protocolVersion": "2025-11-25",
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
