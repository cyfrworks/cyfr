use super::types::{JsonRpcRequest, JsonRpcResponse};
use super::GatewayState;
use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use crate::VERSION;
use tracing::{info, warn};

/// Handle JSON-RPC POST requests on /mcp
pub async fn handle_post(
    State(state): State<GatewayState>,
    Json(request): Json<JsonRpcRequest>,
) -> Result<Json<JsonRpcResponse>, StatusCode> {
    info!("MCP request: method={}", request.method);

    match request.method.as_str() {
        "initialize" => Ok(Json(handle_initialize(request))),

        "notifications/initialized" => {
            // Notification — no response needed, but we return 200 with empty result
            Ok(Json(JsonRpcResponse::success(
                request.id,
                serde_json::json!({}),
            )))
        }

        "tools/list" => {
            let registry = state.registry.read().await;
            let tools = registry.list_all_tools().await;

            Ok(Json(JsonRpcResponse::success(
                request.id,
                serde_json::json!({ "tools": tools }),
            )))
        }

        "tools/call" => {
            let params = request.params.unwrap_or(serde_json::json!({}));
            let tool_name = params
                .get("name")
                .and_then(|n| n.as_str())
                .unwrap_or("");
            let arguments = params
                .get("arguments")
                .cloned()
                .unwrap_or(serde_json::json!({}));

            match super::router::route_tool_call(&state.registry, tool_name, arguments).await {
                Ok(result) => Ok(Json(JsonRpcResponse::success(
                    request.id,
                    serde_json::to_value(result).unwrap_or(serde_json::json!({})),
                ))),
                Err(e) => Ok(Json(JsonRpcResponse::error(
                    request.id,
                    -32602,
                    e.to_string(),
                ))),
            }
        }

        other => {
            warn!("Unknown method: {}", other);
            Ok(Json(JsonRpcResponse::error(
                request.id,
                -32601,
                format!("Method not found: {}", other),
            )))
        }
    }
}

fn handle_initialize(request: JsonRpcRequest) -> JsonRpcResponse {
    JsonRpcResponse::success(
        request.id,
        serde_json::json!({
            "protocolVersion": "2025-03-26",
            "capabilities": {
                "tools": {}
            },
            "serverInfo": {
                "name": "aqua",
                "version": VERSION
            }
        }),
    )
}
