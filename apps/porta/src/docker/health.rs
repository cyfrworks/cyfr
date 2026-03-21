use std::time::Duration;
use tracing::{info, warn};

const HEALTH_URL: &str = "http://localhost:4000/api/health";

/// Poll the health endpoint until it returns 200 or deadline is reached
pub async fn wait_healthy(deadline_secs: u64) -> Result<(), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(deadline_secs);

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
                "Server did not become healthy within {}s. Check 'docker logs cyfr'.",
                deadline_secs
            ));
        }

        tokio::time::sleep(Duration::from_secs(1)).await;
    }
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
