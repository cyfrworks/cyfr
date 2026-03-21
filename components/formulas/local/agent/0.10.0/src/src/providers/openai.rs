use serde_json::{json, Value};

use super::ToolCall;

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
    // OpenAI uses separate messages for each tool result
    // We return an array that the caller should splice into the conversation
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

    // Return as array — caller handles OpenAI's multi-message format
    json!(msgs)
}

pub fn extract_text(data: &Value) -> String {
    // Check for combined_text from streaming
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

/// Extract token usage from OpenAI-compatible response: data.usage.{prompt_tokens, completion_tokens}
/// Covers OpenAI, Grok, and OpenRouter (all use the same format)
pub fn extract_usage(data: &Value) -> Value {
    if let Some(usage) = data.get("usage") {
        let input = usage.get("prompt_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        let output = usage.get("completion_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        json!({"input_tokens": input, "output_tokens": output})
    } else {
        Value::Null
    }
}
