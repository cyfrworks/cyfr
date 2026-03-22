use super::types::ToolCallResult;
use super::SharedRegistry;
use tracing::info;

/// Route a tool call to the correct backend.
/// Tool names are prefixed as `backend_name__tool_name`.
pub async fn route_tool_call(
    registry: &SharedRegistry,
    qualified_name: &str,
    arguments: serde_json::Value,
) -> Result<ToolCallResult, String> {
    let (backend_name, tool_name) = match qualified_name.split_once("__") {
        Some((b, t)) => (b, t),
        None => {
            return Err(format!(
                "Invalid tool name '{}': expected 'backend__tool' format",
                qualified_name
            ))
        }
    };

    info!(
        "Routing tool call: backend={}, tool={}",
        backend_name, tool_name
    );

    let reg = registry.read().await;

    let backend = reg
        .get(backend_name)
        .ok_or_else(|| format!("Unknown backend: '{}'", backend_name))?;

    backend.call_tool(tool_name, arguments).await
}
