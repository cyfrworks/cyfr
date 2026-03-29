use serde::Serialize;
use tracing::{info, warn};

#[derive(Debug, Clone, Serialize)]
pub struct CyfrPortaStatus {
    pub status: String,
    pub tool_count: usize,
    pub error: Option<String>,
}

fn command_cwd() -> Result<std::path::PathBuf, String> {
    crate::preflight::home_cwd()
}

/// Notify Cyfr that Porta's tools have changed, then return Cyfr's view.
/// Auto-registers if porta is not yet known to Cyfr.
pub async fn refresh_and_get_status() -> Result<CyfrPortaStatus, String> {
    let cyfr_url = crate::config::cyfr_url();
    // Refresh porta on Cyfr side
    let output = crate::cli::run_cyfr(
        &[
            "mcp",
            "refresh",
            "porta",
            "--json",
            "--no-interactive",
            "--url",
            &cyfr_url,
        ],
        &command_cwd()?,
    )
    .await;

    match output {
        Ok(o) if o.success => {}
        Ok(o) => {
            let msg = if o.stderr.is_empty() { &o.stdout } else { &o.stderr };
            // If not found, auto-register and retry
            if msg.contains("not found") {
                info!("Porta not registered with Cyfr — auto-registering");
                super::ensure_registered().await?;
                let _ = crate::cli::run_cyfr(
                    &[
                        "mcp",
                        "refresh",
                        "porta",
                        "--json",
                        "--no-interactive",
                        "--url",
                        &cyfr_url,
                    ],
                    &command_cwd()?,
                )
                .await;
            } else {
                warn!("Cyfr refresh failed: {}", msg.trim());
            }
        }
        Err(e) => {
            warn!("Cyfr refresh failed: {}", e);
        }
    }

    // Get current status
    get_cyfr_porta_status().await
}

/// Get Cyfr's current view of "porta" without triggering a refresh.
/// If porta is not registered, auto-registers and retries.
pub async fn get_cyfr_porta_status() -> Result<CyfrPortaStatus, String> {
    let status = fetch_porta_status().await?;

    if status.status == "not_registered" {
        info!("Porta not registered with Cyfr — auto-registering");
        if let Err(e) = super::ensure_registered().await {
            warn!("Auto-registration failed: {}", e);
            return Ok(status);
        }
        return fetch_porta_status().await;
    }

    Ok(status)
}

/// Fire-and-forget: notify Cyfr that Porta's tools changed.
pub fn notify_cyfr_tools_changed() {
    tokio::spawn(async {
        let cyfr_url = crate::config::cyfr_url();
        let Ok(cwd) = command_cwd() else {
            warn!("Failed to resolve working directory for Cyfr refresh");
            return;
        };

        let output = crate::cli::run_cyfr(
            &[
                "mcp",
                "refresh",
                "porta",
                "--json",
                "--no-interactive",
                "--url",
                &cyfr_url,
            ],
            &cwd,
        )
        .await;

        match output {
            Ok(o) if o.success => info!("Notified Cyfr to refresh porta tools"),
            Ok(o) => {
                let msg = if o.stderr.is_empty() { o.stdout } else { o.stderr };
                if msg.contains("not found") {
                    // Not registered yet — register, then refresh
                    if super::ensure_registered().await.is_ok() {
                        let _ = crate::cli::run_cyfr(
                            &[
                                "mcp",
                                "refresh",
                                "porta",
                                "--json",
                                "--no-interactive",
                                "--url",
                                &cyfr_url,
                            ],
                            &cwd,
                        )
                        .await;
                    }
                } else {
                    warn!("Cyfr refresh failed: {}", msg.trim());
                }
            }
            Err(e) => warn!("Failed to notify Cyfr: {}", e),
        }
    });
}

async fn fetch_porta_status() -> Result<CyfrPortaStatus, String> {
    let cyfr_url = crate::config::cyfr_url();
    let output = crate::cli::run_cyfr(
        &[
            "mcp",
            "get",
            "porta",
            "--json",
            "--no-interactive",
            "--url",
            &cyfr_url,
        ],
        &command_cwd()?,
    )
    .await
    .map_err(|e| format!("Failed to get porta status: {}", e))?;

    if !output.success {
        let msg = if output.stderr.is_empty() {
            &output.stdout
        } else {
            &output.stderr
        };

        if msg.contains("not found") {
            return Ok(CyfrPortaStatus {
                status: "not_registered".to_string(),
                tool_count: 0,
                error: Some("Porta not registered with CYFR".to_string()),
            });
        }

        if msg.contains("Authentication required") {
            return Err("CYFR authentication required — run 'cyfr login'".to_string());
        }

        return Err(format!("cyfr mcp get failed: {}", msg.trim()));
    }

    parse_cli_output(&output.stdout)
}

fn parse_cli_output(stdout: &str) -> Result<CyfrPortaStatus, String> {
    // Try JSON parse first (--json flag)
    if let Ok(data) = serde_json::from_str::<serde_json::Value>(stdout) {
        let status = data
            .get("status")
            .and_then(|s| s.as_str())
            .unwrap_or("unknown")
            .to_string();

        let tool_count = data
            .get("tools")
            .and_then(|t| t.as_array())
            .map(|a| a.len())
            .or_else(|| {
                data.get("tool_count")
                    .and_then(|c| c.as_u64())
                    .map(|c| c as usize)
            })
            .unwrap_or(0);

        let error = data
            .get("error")
            .and_then(|e| e.as_str())
            .map(|s| s.to_string());

        return Ok(CyfrPortaStatus {
            status,
            tool_count,
            error,
        });
    }

    // Fallback: parse text output (e.g., "porta  ready  enabled  29 tools")
    for line in stdout.lines() {
        let line = line.trim();
        if line.contains("porta") {
            let parts: Vec<&str> = line.split_whitespace().collect();
            // Format: name  status  enabled  N tools
            let status = parts.get(1).unwrap_or(&"unknown").to_string();
            let tool_count = parts
                .iter()
                .position(|&p| p == "tools" || p == "tool")
                .and_then(|i| i.checked_sub(1))
                .and_then(|i| parts.get(i))
                .and_then(|n| n.parse::<usize>().ok())
                .unwrap_or(0);

            return Ok(CyfrPortaStatus {
                status,
                tool_count,
                error: None,
            });
        }
    }

    Ok(CyfrPortaStatus {
        status: "unknown".to_string(),
        tool_count: 0,
        error: Some("Could not parse cyfr output".to_string()),
    })
}
