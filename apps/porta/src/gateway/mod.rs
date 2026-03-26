pub mod handler;
pub mod router;
pub mod types;

use crate::backend::registry::BackendRegistry;
use crate::VERSION;
use axum::{routing::post, Router};
use std::sync::Arc;
use tokio::sync::RwLock;
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
    let cors = CorsLayer::new()
        .allow_origin(Any)
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

/// Register Porta as an external MCP server in Cyfr
pub async fn register_with_cyfr(gateway_port: u16) -> Result<(), String> {
    let client = reqwest::Client::new();

    // Initialize handshake with Cyfr's MCP endpoint
    let init_req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {
                "name": "aqua",
                "version": VERSION
            }
        }
    });

    client
        .post("http://localhost:4000/mcp")
        .json(&init_req)
        .send()
        .await
        .map_err(|e| format!("Failed to connect to Cyfr: {}", e))?;

    // Send initialized notification
    let notif = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "notifications/initialized"
    });

    client
        .post("http://localhost:4000/mcp")
        .json(&notif)
        .send()
        .await
        .map_err(|e| format!("Failed to send initialized notification: {}", e))?;

    // Register via mcp_servers tool
    let register_req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
            "name": "mcp_servers",
            "arguments": {
                "action": "add",
                "name": "porta",
                "config": {
                    "url": format!("http://host.docker.internal:{}/mcp", gateway_port)
                }
            }
        }
    });

    let resp = client
        .post("http://localhost:4000/mcp")
        .json(&register_req)
        .send()
        .await
        .map_err(|e| format!("Failed to register with Cyfr: {}", e))?;

    if resp.status().is_success() {
        info!("Registered Porta gateway with Cyfr");
        Ok(())
    } else {
        Err(format!("Registration failed with status {}", resp.status()))
    }
}
