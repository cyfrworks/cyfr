use serde_json::{json, Value};

use super::ToolCall;

pub fn has_tool_calls(data: &Value) -> bool {
    let parts = data
        .get("candidates")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("content"))
        .and_then(|c| c.get("parts"))
        .and_then(|v| v.as_array());

    if let Some(parts) = parts {
        parts.iter().any(|p| p.get("functionCall").is_some())
    } else {
        false
    }
}

pub fn extract_tool_calls(data: &Value) -> Vec<ToolCall> {
    let parts = data
        .get("candidates")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("content"))
        .and_then(|c| c.get("parts"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    let mut calls = Vec::new();
    for (i, part) in parts.iter().enumerate() {
        if let Some(fc) = part.get("functionCall") {
            let name = fc
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let args = fc.get("args").cloned().unwrap_or(json!({}));

            calls.push(ToolCall {
                id: format!("gemini_call_{}", i),
                name,
                arguments: args,
            });
        }
    }
    calls
}

pub fn build_assistant_message(data: &Value) -> Value {
    let content = data
        .get("candidates")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("content"))
        .cloned()
        .unwrap_or(json!({"parts": [], "role": "model"}));

    json!({
        "role": "model",
        "parts": content.get("parts").cloned().unwrap_or(json!([]))
    })
}

/// results: Vec of (call_id, tool_name, result_content)
pub fn build_tool_results_message(results: &[(String, String, String)]) -> Value {
    let parts: Vec<Value> = results
        .iter()
        .map(|(_id, name, content)| {
            json!({
                "functionResponse": {
                    "name": name,
                    "response": {
                        "content": content
                    }
                }
            })
        })
        .collect();

    json!({
        "role": "user",
        "parts": parts
    })
}

pub fn extract_text(data: &Value) -> String {
    // Check for combined_text from streaming
    if let Some(text) = data.get("combined_text").and_then(|v| v.as_str()) {
        return text.to_string();
    }

    data.get("candidates")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("content"))
        .and_then(|c| c.get("parts"))
        .and_then(|v| v.as_array())
        .and_then(|parts| parts.first())
        .and_then(|p| p.get("text"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

/// Extract token usage from Gemini response: data.usageMetadata.{promptTokenCount, candidatesTokenCount}
pub fn extract_usage(data: &Value) -> Value {
    if let Some(usage) = data.get("usageMetadata") {
        let input = usage.get("promptTokenCount").and_then(|v| v.as_u64()).unwrap_or(0);
        let output = usage.get("candidatesTokenCount").and_then(|v| v.as_u64()).unwrap_or(0);
        json!({"input_tokens": input, "output_tokens": output})
    } else {
        Value::Null
    }
}
