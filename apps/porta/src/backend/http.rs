use super::{BackendStatus, McpBackend};
use crate::gateway::types::{Tool, ToolCallResult};
use crate::VERSION;
use async_trait::async_trait;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;
use tracing::{error, info, warn};

pub struct HttpBackend {
    name: String,
    url: String,
    headers: HashMap<String, String>,
    client: reqwest::Client,
    status: BackendStatus,
    tools: Vec<Tool>,
    next_id: AtomicI64,
    session_id: Option<String>,
}

impl HttpBackend {
    pub fn new(name: String, url: String, headers: HashMap<String, String>) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("failed to build HTTP client");

        Self {
            name,
            url,
            headers,
            client,
            status: BackendStatus::Disconnected,
            tools: Vec::new(),
            next_id: AtomicI64::new(1),
            session_id: None,
        }
    }

    /// Send a JSON-RPC request supporting both plain JSON and SSE (Streamable HTTP) responses
    async fn send_request(&self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);

        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        });

        let mut req_builder = self.client
            .post(&self.url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/event-stream")
            .json(&request);

        // Add session header if we have one
        if let Some(ref sid) = self.session_id {
            req_builder = req_builder.header("Mcp-Session-Id", sid);
        }

        for (key, value) in &self.headers {
            req_builder = req_builder.header(key, value);
        }

        let resp = req_builder
            .send()
            .await
            .map_err(|e| format!("HTTP request failed: {}", e))?;

        if !resp.status().is_success() {
            return Err(format!("HTTP {}: {}", resp.status(), self.url));
        }

        let content_type = resp.headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();

        if content_type.contains("text/event-stream") {
            // SSE response — parse event stream for JSON-RPC messages
            self.parse_sse_response(resp, id).await
        } else {
            // Plain JSON response
            let body: Value = resp
                .json()
                .await
                .map_err(|e| format!("Failed to parse response: {}", e))?;

            if let Some(error) = body.get("error") {
                let message = error
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("Unknown error");
                return Err(message.to_string());
            }

            Ok(body.get("result").cloned().unwrap_or(Value::Null))
        }
    }

    /// Parse an SSE response stream, extracting the JSON-RPC result matching our request ID
    async fn parse_sse_response(&self, resp: reqwest::Response, request_id: i64) -> Result<Value, String> {
        let text = resp.text().await
            .map_err(|e| format!("Failed to read SSE response: {}", e))?;

        // Parse SSE format: lines starting with "data: " contain JSON-RPC messages
        for line in text.lines() {
            let data = if let Some(d) = line.strip_prefix("data: ") {
                d.trim()
            } else if let Some(d) = line.strip_prefix("data:") {
                d.trim()
            } else {
                continue;
            };

            if data.is_empty() || data == "[DONE]" {
                continue;
            }

            match serde_json::from_str::<Value>(data) {
                Ok(msg) => {
                    // Check if this is our response (matching ID)
                    if let Some(msg_id) = msg.get("id").and_then(|i| i.as_i64()) {
                        if msg_id == request_id {
                            if let Some(error) = msg.get("error") {
                                let message = error
                                    .get("message")
                                    .and_then(|m| m.as_str())
                                    .unwrap_or("Unknown error");
                                return Err(message.to_string());
                            }
                            return Ok(msg.get("result").cloned().unwrap_or(Value::Null));
                        }
                    }
                }
                Err(e) => {
                    warn!("[{}] Failed to parse SSE data line: {}", self.name, e);
                }
            }
        }

        Err("No matching response found in SSE stream".to_string())
    }

    async fn send_notification(&self, method: &str) -> Result<(), String> {
        let notification = serde_json::json!({
            "jsonrpc": "2.0",
            "method": method
        });

        let mut req_builder = self.client
            .post(&self.url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/event-stream")
            .json(&notification);

        if let Some(ref sid) = self.session_id {
            req_builder = req_builder.header("Mcp-Session-Id", sid);
        }

        for (key, value) in &self.headers {
            req_builder = req_builder.header(key, value);
        }

        let _ = req_builder
            .send()
            .await
            .map_err(|e| format!("Failed to send notification: {}", e))?;

        Ok(())
    }
}

#[async_trait]
impl McpBackend for HttpBackend {
    fn name(&self) -> &str {
        &self.name
    }

    fn backend_type(&self) -> &str {
        "http"
    }

    async fn initialize(&mut self) -> Result<(), String> {
        self.status = BackendStatus::Starting;

        info!("[{}] Connecting to {}", self.name, self.url);

        // MCP handshake: initialize
        let init_result = self
            .send_request(
                "initialize",
                serde_json::json!({
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {
                        "name": "aqua",
                        "version": VERSION
                    }
                }),
            )
            .await
            .map_err(|e| {
                self.status = BackendStatus::Error(e.clone());
                e
            })?;

        info!("[{}] Initialize response: {:?}", self.name, init_result);

        // Send initialized notification
        self.send_notification("notifications/initialized").await?;

        // Discover tools
        let tools_result = self
            .send_request("tools/list", serde_json::json!({}))
            .await?;

        let tools: Vec<Tool> = if let Some(tools_arr) = tools_result.get("tools") {
            serde_json::from_value(tools_arr.clone()).unwrap_or_default()
        } else {
            Vec::new()
        };

        info!("[{}] Discovered {} tools", self.name, tools.len());
        self.tools = tools;
        self.status = BackendStatus::Ready;

        Ok(())
    }

    async fn tools(&self) -> &[Tool] {
        &self.tools
    }

    async fn call_tool(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> Result<ToolCallResult, String> {
        if self.status != BackendStatus::Ready {
            return Err(format!("Backend '{}' is not ready", self.name));
        }

        let result = self
            .send_request(
                "tools/call",
                serde_json::json!({
                    "name": name,
                    "arguments": arguments
                }),
            )
            .await?;

        serde_json::from_value(result.clone()).map_err(|e| {
            error!("[{}] Failed to parse tool result: {}", self.name, e);
            format!("Invalid tool result: {}", e)
        })
    }

    async fn shutdown(&mut self) -> Result<(), String> {
        self.status = BackendStatus::Disconnected;
        info!("[{}] Shutdown complete", self.name);
        Ok(())
    }

    fn status(&self) -> BackendStatus {
        self.status.clone()
    }
}
