pub mod bridge;
pub mod handler;
pub mod router;
pub mod types;

use crate::backend::registry::BackendRegistry;
use crate::config;
use axum::{routing::post, Router};
use std::sync::Arc;
use tokio::sync::RwLock;
use axum::http::HeaderValue;
use tower_http::cors::{Any, CorsLayer};
use tracing::info;

pub type SharedRegistry = Arc<RwLock<BackendRegistry>>;

/// Bind the MCP gateway to its port.
/// Returns the listener, or an error if the port is in use.
pub async fn bind(
    bind: &str,
    port: u16,
) -> Result<tokio::net::TcpListener, Box<dyn std::error::Error + Send + Sync>> {
    let addr = format!("{}:{}", bind, port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    info!("MCP gateway bound to {}", addr);
    Ok(listener)
}

/// Start serving on an already-bound listener.
pub async fn serve(
    listener: tokio::net::TcpListener,
    registry: SharedRegistry,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Restrict origins to Tauri webview and local dev/Cyfr — prevents
    // random websites from hitting the MCP gateway on localhost.
    let allowed_origins = [
        "tauri://localhost",
        "http://localhost",
        "http://localhost:1420",
        "http://localhost:4000",
        "http://127.0.0.1",
        "http://127.0.0.1:1420",
        "http://127.0.0.1:4000",
    ];
    let cors = CorsLayer::new()
        .allow_origin(
            allowed_origins
                .iter()
                .filter_map(|o| o.parse::<HeaderValue>().ok())
                .collect::<Vec<_>>(),
        )
        .allow_methods(Any)
        .allow_headers(Any);

    let state = GatewayState { registry };

    let app = Router::new()
        .route("/mcp", post(handler::handle_post))
        .layer(cors)
        .with_state(state);

    axum::serve(listener, app).await?;

    Ok(())
}

#[derive(Clone)]
pub struct GatewayState {
    pub registry: SharedRegistry,
}

/// Determine the URL Cyfr should use to reach Porta's gateway.
/// When Cyfr runs in Docker, it needs `host.docker.internal` (macOS/Docker Desktop)
/// or the bridge gateway IP (Linux Docker Engine).
/// When Cyfr runs on the host (dev mode), `127.0.0.1` works.
async fn porta_url_for_cyfr(gateway_port: u16) -> String {
    let in_docker = tokio::process::Command::new(crate::docker::docker_command())
        .args(["inspect", "--format", "{{.State.Status}}", "cyfr"])
        .output()
        .await
        .map(|o| {
            o.status.success()
                && String::from_utf8_lossy(&o.stdout).trim() == "running"
        })
        .unwrap_or(false);

    let host = if in_docker {
        resolve_docker_host().await
    } else {
        "127.0.0.1".to_string()
    };

    format!("http://{}:{}/mcp", host, gateway_port)
}

/// Resolve the hostname the Docker container should use to reach the host.
/// On macOS (Docker Desktop), `host.docker.internal` is automatically available.
/// On Linux (Docker Engine), it may not resolve — fall back to the network gateway IP.
async fn resolve_docker_host() -> String {
    // On macOS, host.docker.internal always works with Docker Desktop
    if cfg!(target_os = "macos") {
        return "host.docker.internal".to_string();
    }

    // On Linux, try the Compose project network first (cyfr_default), then the
    // default bridge network. Docker Compose creates its own network, so the
    // default bridge gateway IP is not routable from inside the Compose network.
    for network in &["cyfr_default", "bridge"] {
        if let Some(ip) = inspect_network_gateway(network).await {
            return ip;
        }
    }

    "host.docker.internal".to_string()
}

/// Inspect a Docker network and return its gateway IP.
async fn inspect_network_gateway(network: &str) -> Option<String> {
    let output = tokio::process::Command::new(crate::docker::docker_command())
        .args([
            "network", "inspect", network,
            "--format", "{{range .IPAM.Config}}{{.Gateway}}{{end}}",
        ])
        .output()
        .await
        .ok()?;

    if output.status.success() {
        let ip = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !ip.is_empty() { Some(ip) } else { None }
    } else {
        None
    }
}

/// Register Porta as an external MCP server in Cyfr via `cyfr mcp add`.
pub async fn register_with_cyfr(gateway_port: u16) -> Result<(), String> {
    let porta_url = porta_url_for_cyfr(gateway_port).await;
    info!("Registering Porta gateway with Cyfr at {}", porta_url);

    let config_json = serde_json::json!({ "url": porta_url }).to_string();
    let proj_dir = crate::home_dir()?.join("cyfr");

    let output = crate::cli::run_cyfr(
        &["mcp", "add", "porta", &config_json],
        &proj_dir,
    )
    .await?;

    if output.success {
        info!("Registered Porta gateway with Cyfr");
        Ok(())
    } else {
        let msg = if output.stderr.is_empty() {
            output.stdout
        } else {
            output.stderr
        };
        Err(format!("Registration failed: {}", msg.trim()))
    }
}

/// Register with retries. Spawns as a background task.
/// Tries up to `max_attempts` with `delay_secs` between attempts.
pub fn spawn_registration(gateway_port: u16, delay_secs: u64, max_attempts: u32) {
    tauri::async_runtime::spawn(async move {
        if delay_secs > 0 {
            tokio::time::sleep(std::time::Duration::from_secs(delay_secs)).await;
        }

        for attempt in 1..=max_attempts {
            match register_with_cyfr(gateway_port).await {
                Ok(()) => return,
                Err(e) => {
                    if attempt < max_attempts {
                        tracing::warn!(
                            "Cyfr registration attempt {}/{} failed: {} — retrying in 5s",
                            attempt, max_attempts, e
                        );
                        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    } else {
                        tracing::warn!(
                            "Cyfr registration failed after {} attempts: {} — will register on first interaction",
                            max_attempts, e
                        );
                    }
                }
            }
        }
    });
}

/// Ensure Porta is registered with Cyfr. Call from bridge when status is "not_registered".
pub async fn ensure_registered() -> Result<(), String> {
    let gateway_port = config::GATEWAY_PORT;
    register_with_cyfr(gateway_port).await
}
