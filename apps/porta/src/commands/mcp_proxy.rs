use serde::{Deserialize, Serialize};

fn cyfr_url() -> String {
    crate::config::cyfr_url()
}

#[derive(Debug, Deserialize)]
pub struct McpProxyRequest {
    pub method: String, // "POST" or "DELETE"
    pub body: Option<String>,
    pub session_id: Option<String>,
    pub api_key: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct McpProxyResponse {
    pub status: u16,
    pub body: String,
    pub session_id: Option<String>,
}

/// Proxy MCP requests through Rust to avoid CORS preflight issues.
/// The Tauri webview's fetch sends OPTIONS preflight for cross-origin
/// requests with custom headers, and the CYFR server doesn't handle
/// OPTIONS on /mcp. This proxy bypasses that entirely.
#[tauri::command]
pub async fn mcp_proxy(request: McpProxyRequest) -> Result<McpProxyResponse, String> {
    let client = reqwest::Client::new();
    let url = format!("{}/mcp", cyfr_url());

    let mut builder = match request.method.as_str() {
        "DELETE" => client.delete(&url),
        _ => client.post(&url),
    };

    builder = builder
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("MCP-Protocol-Version", "2025-11-25");

    if let Some(ref sid) = request.session_id {
        builder = builder.header("MCP-Session-Id", sid);
    }

    if let Some(ref key) = request.api_key {
        builder = builder.header("Authorization", format!("Bearer {}", key));
    }

    if let Some(ref body) = request.body {
        builder = builder.body(body.clone());
    }

    let resp = builder
        .send()
        .await
        .map_err(|e| format!("MCP proxy request failed: {}", e))?;

    let status = resp.status().as_u16();
    let session_id = resp
        .headers()
        .get("Mcp-Session-Id")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    let body = resp
        .text()
        .await
        .map_err(|e| format!("MCP proxy read failed: {}", e))?;

    Ok(McpProxyResponse {
        status,
        body,
        session_id,
    })
}
