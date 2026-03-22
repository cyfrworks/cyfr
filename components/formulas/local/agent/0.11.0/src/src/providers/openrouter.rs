use serde_json::{json, Value};

use super::{native_tool_allowed, ToolCall};

// ---------------------------------------------------------------------------
// Tool formatting — OpenRouter Chat Completions
// ---------------------------------------------------------------------------

pub fn format_tools(tools: &[Value], _visible_tools: Option<&[String]>) -> Value {
    // OpenRouter Chat Completions wraps each tool in {"type": "function", "function": {...}}
    // Native search is handled via plugins array in build_request, not in tools
    let or_tools: Vec<Value> = tools
        .iter()
        .map(|t| {
            json!({
                "type": "function",
                "function": {
                    "name": t["name"],
                    "description": t["description"],
                    "parameters": t["input_schema"]
                }
            })
        })
        .collect();
    json!(or_tools)
}

// ---------------------------------------------------------------------------
// Request building — OpenRouter Chat Completions
// ---------------------------------------------------------------------------

pub fn build_request(
    model: &str,
    messages: &[Value],
    system: &str,
    tools: &Value,
    visible_tools: Option<&[String]>,
) -> Value {
    let mut all_messages = vec![json!({"role": "system", "content": system})];
    all_messages.extend_from_slice(messages);

    let mut params = json!({
        "model": model,
        "messages": all_messages,
    });

    let all_tools = tools.as_array().cloned().unwrap_or_default();
    if !all_tools.is_empty() {
        params["tools"] = json!(all_tools);
    }

    // OpenRouter web search via plugins array
    if native_tool_allowed(visible_tools, "native_search") {
        params["plugins"] = json!([{"id": "web"}]);
    }

    json!({
        "operation": "chat.completions.create",
        "params": params,
    })
}

// ---------------------------------------------------------------------------
// Response parsing — OpenRouter Chat Completions
// ---------------------------------------------------------------------------

pub fn has_tool_calls(data: &Value) -> bool {
    let finish_reason = data
        .get("choices")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("finish_reason"))
        .and_then(|v| v.as_str());

    finish_reason == Some("tool_calls")
}

pub fn extract_tool_calls(data: &Value) -> Vec<ToolCall> {
    let tool_calls = data
        .get("choices")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("tool_calls"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    tool_calls
        .iter()
        .map(|tc| {
            let id = tc
                .get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let name = tc
                .get("function")
                .and_then(|f| f.get("name"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let args_str = tc
                .get("function")
                .and_then(|f| f.get("arguments"))
                .and_then(|v| v.as_str())
                .unwrap_or("{}");
            let arguments = serde_json::from_str(args_str).unwrap_or(json!({}));

            ToolCall {
                id,
                name,
                arguments,
            }
        })
        .collect()
}

pub fn build_assistant_message(data: &Value) -> Value {
    data.get("choices")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("message"))
        .cloned()
        .unwrap_or(json!({"role": "assistant", "content": ""}))
}

/// results: Vec of (tool_call_id, tool_name, result_content)
pub fn build_tool_results_message(results: &[(String, String, String)]) -> Value {
    let msgs: Vec<Value> = results
        .iter()
        .map(|(id, _name, content)| {
            json!({
                "role": "tool",
                "tool_call_id": id,
                "content": content
            })
        })
        .collect();

    json!(msgs)
}

pub fn extract_text(data: &Value) -> String {
    if let Some(text) = data.get("combined_text").and_then(|v| v.as_str()) {
        return text.to_string();
    }

    data.get("choices")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

/// Extract token usage: data.usage.{prompt_tokens, completion_tokens}
pub fn extract_usage(data: &Value) -> Value {
    if let Some(usage) = data.get("usage") {
        let input = usage.get("prompt_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        let output = usage.get("completion_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        json!({"input_tokens": input, "output_tokens": output})
    } else {
        Value::Null
    }
}
