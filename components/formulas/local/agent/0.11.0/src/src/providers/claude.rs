use serde_json::{json, Value};

use super::{native_tool_allowed, ToolCall};

// ---------------------------------------------------------------------------
// Tool formatting
// ---------------------------------------------------------------------------

pub fn format_tools(tools: &[Value], visible_tools: Option<&[String]>) -> Value {
    let mut all_tools: Vec<Value> = tools.to_vec();
    if native_tool_allowed(visible_tools, "native_search") {
        all_tools.push(json!({"type": "web_search_20250305", "name": "web_search"}));
    }
    json!(all_tools)
}

// ---------------------------------------------------------------------------
// Request building
// ---------------------------------------------------------------------------

pub fn build_request(
    model: &str,
    messages: &[Value],
    system: &str,
    max_tokens: u64,
    tools: &Value,
) -> Value {
    let mut params = json!({
        "model": model,
        "max_tokens": max_tokens,
        "messages": messages,
        "system": system,
    });

    let all_tools = tools.as_array().cloned().unwrap_or_default();
    if !all_tools.is_empty() {
        params["tools"] = json!(all_tools);
    }

    json!({
        "operation": "messages.create",
        "params": params,
    })
}

// ---------------------------------------------------------------------------
// Response parsing
// ---------------------------------------------------------------------------

pub fn has_tool_calls(data: &Value) -> bool {
    data.get("stop_reason")
        .and_then(|v| v.as_str())
        == Some("tool_use")
}

pub fn extract_tool_calls(data: &Value) -> Vec<ToolCall> {
    let content = data
        .get("content")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    content
        .iter()
        .filter(|block| block.get("type").and_then(|v| v.as_str()) == Some("tool_use"))
        .map(|block| ToolCall {
            id: block
                .get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            name: block
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            arguments: block.get("input").cloned().unwrap_or(json!({})),
        })
        .collect()
}

pub fn build_assistant_message(data: &Value) -> Value {
    let content = data
        .get("content")
        .cloned()
        .unwrap_or(json!([]));
    json!({
        "role": "assistant",
        "content": content
    })
}

/// results: Vec of (tool_use_id, tool_name, result_content)
pub fn build_tool_results_message(results: &[(String, String, String)]) -> Value {
    let blocks: Vec<Value> = results
        .iter()
        .map(|(id, _name, content)| {
            json!({
                "type": "tool_result",
                "tool_use_id": id,
                "content": content
            })
        })
        .collect();

    json!({
        "role": "user",
        "content": blocks
    })
}

pub fn extract_text(data: &Value) -> String {
    let content = data
        .get("content")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    let mut text = String::new();
    for block in &content {
        if block.get("type").and_then(|v| v.as_str()) == Some("text") {
            if let Some(t) = block.get("text").and_then(|v| v.as_str()) {
                text.push_str(t);
            }
        }
    }
    text
}

/// Extract token usage from Claude response: data.usage.{input_tokens, output_tokens}
pub fn extract_usage(data: &Value) -> Value {
    if let Some(usage) = data.get("usage") {
        let input = usage.get("input_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        let output = usage.get("output_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        json!({"input_tokens": input, "output_tokens": output})
    } else {
        Value::Null
    }
}
