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

/// Convert a single canonical message to Claude API format.
fn convert_canonical_message(msg: &Value) -> Value {
    let role = msg.get("role").and_then(|v| v.as_str()).unwrap_or("");

    match role {
        "user" => {
            // Pass through as-is (works for both string content and array content)
            msg.clone()
        }
        "assistant" => {
            let text = msg
                .get("content")
                .and_then(|v| v.as_str())
                .unwrap_or("");

            let mut content_blocks: Vec<Value> = Vec::new();

            if !text.is_empty() {
                content_blocks.push(json!({"type": "text", "text": text}));
            }

            if let Some(tool_calls) = msg.get("tool_calls").and_then(|v| v.as_array()) {
                for tc in tool_calls {
                    let id = tc.get("id").and_then(|v| v.as_str()).unwrap_or("");
                    let name = tc.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    let arguments = tc.get("arguments").cloned().unwrap_or(json!({}));
                    content_blocks.push(json!({
                        "type": "tool_use",
                        "id": id,
                        "name": name,
                        "input": arguments
                    }));
                }
            }

            json!({"role": "assistant", "content": content_blocks})
        }
        "tool_results" => {
            let results = msg
                .get("results")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();

            let blocks: Vec<Value> = results
                .iter()
                .map(|r| {
                    let id = r.get("tool_call_id").and_then(|v| v.as_str()).unwrap_or("");
                    let content = r
                        .get("content")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    json!({
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": content
                    })
                })
                .collect();

            json!({"role": "user", "content": blocks})
        }
        _ => msg.clone(),
    }
}

/// Convert an array of canonical messages to Claude API format.
fn convert_canonical_messages(messages: &[Value]) -> Vec<Value> {
    messages.iter().map(convert_canonical_message).collect()
}

pub fn build_request(
    model: &str,
    messages: &[Value],
    system: &str,
    max_tokens: u64,
    tools: &Value,
) -> Value {
    let claude_messages = convert_canonical_messages(messages);

    let mut params = json!({
        "model": model,
        "max_tokens": max_tokens,
        "messages": claude_messages,
        "system": system,
    });

    let all_tools = tools.as_array().cloned().unwrap_or_default();
    if !all_tools.is_empty() {
        params["tools"] = json!(all_tools);
    }

    // Enable prompt caching — system prompt + tools are cached at 90% discount on turns 2+
    params["cache_control"] = json!({"type": "ephemeral"});

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
            thought_signature: None,
        })
        .collect()
}

pub fn build_assistant_message(data: &Value) -> Value {
    let text = extract_text(data);
    let tool_calls = extract_tool_calls(data);
    let mut msg = json!({"role": "assistant", "content": text});
    if !tool_calls.is_empty() {
        msg["tool_calls"] = json!(tool_calls
            .iter()
            .map(|tc| json!({
                "id": tc.id,
                "name": tc.name,
                "arguments": tc.arguments
            }))
            .collect::<Vec<_>>());
    }
    msg
}

/// results: Vec of (tool_use_id, tool_name, result_content)
pub fn build_tool_results_message(results: &[(String, String, String)]) -> Value {
    json!({
        "role": "tool_results",
        "results": results.iter().map(|(id, name, content)| json!({
            "tool_call_id": id,
            "name": name,
            "content": content
        })).collect::<Vec<Value>>()
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
