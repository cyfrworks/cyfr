use serde_json::{json, Value};

use super::{native_tool_allowed, ToolCall};

// ---------------------------------------------------------------------------
// Tool formatting
// ---------------------------------------------------------------------------

/// Gemini uses a subset of JSON Schema — strip unsupported fields.
pub fn format_tools(tools: &[Value], visible_tools: Option<&[String]>) -> Value {
    let declarations: Vec<Value> = tools
        .iter()
        .map(|t| {
            let clean_params = strip_unsupported_schema_keys(&t["input_schema"]);
            json!({
                "name": t["name"],
                "description": t["description"],
                "parameters": clean_params
            })
        })
        .collect();

    let mut tool_entries = vec![json!({"functionDeclarations": declarations})];
    if native_tool_allowed(visible_tools, "native_search") {
        tool_entries.push(json!({"google_search": {}}));
        tool_entries.push(json!({"url_context": {}}));
    }
    json!(tool_entries)
}

/// Recursively strip JSON Schema keys that Gemini doesn't support.
/// Gemini accepts: type, description, properties, required, enum, items, format, nullable
fn strip_unsupported_schema_keys(schema: &Value) -> Value {
    match schema {
        Value::Object(map) => {
            let allowed = [
                "type",
                "description",
                "properties",
                "required",
                "enum",
                "items",
                "format",
                "nullable",
            ];

            let mut clean = serde_json::Map::new();
            for (key, value) in map {
                if !allowed.contains(&key.as_str()) {
                    continue;
                }
                if key == "properties" {
                    // Recurse into each property
                    if let Value::Object(props) = value {
                        let mut clean_props = serde_json::Map::new();
                        for (prop_name, prop_schema) in props {
                            clean_props
                                .insert(prop_name.clone(), strip_unsupported_schema_keys(prop_schema));
                        }
                        clean.insert(key.clone(), Value::Object(clean_props));
                    } else {
                        clean.insert(key.clone(), value.clone());
                    }
                } else if key == "items" {
                    // Recurse into items schema
                    clean.insert(key.clone(), strip_unsupported_schema_keys(value));
                } else {
                    clean.insert(key.clone(), value.clone());
                }
            }
            Value::Object(clean)
        }
        other => other.clone(),
    }
}

// ---------------------------------------------------------------------------
// Request building
// ---------------------------------------------------------------------------

pub fn build_request(
    model: &str,
    messages: &[Value],
    system: &str,
    tools: &Value,
) -> Value {
    // Convert messages to Gemini contents format
    let contents: Vec<Value> = messages
        .iter()
        .map(|msg| {
            let role = msg
                .get("role")
                .and_then(|v| v.as_str())
                .unwrap_or("user");

            // If message has parts already (Gemini format), pass through
            if let Some(parts) = msg.get("parts") {
                return json!({
                    "role": if role == "assistant" { "model" } else { role },
                    "parts": parts
                });
            }

            // Convert from text content
            let text = msg
                .get("content")
                .and_then(|v| v.as_str())
                .unwrap_or("");

            json!({
                "role": if role == "assistant" { "model" } else { role },
                "parts": [{"text": text}]
            })
        })
        .collect();

    let mut params = json!({
        "model": model,
        "contents": contents,
        "systemInstruction": {"parts": [{"text": system}]},
    });

    let has_tools = tools.as_array().map_or(false, |arr| !arr.is_empty());
    if has_tools {
        params["tools"] = tools.clone();
        // Required for google_search / url_context alongside function calling
        params["toolConfig"] = json!({
            "includeServerSideToolInvocations": true
        });
    }

    json!({
        "operation": "content.generate",
        "params": params,
    })
}

// ---------------------------------------------------------------------------
// Response parsing
// ---------------------------------------------------------------------------

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

    // Iterate all parts and collect text (some parts may be functionCall, not text)
    let parts = data
        .get("candidates")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("content"))
        .and_then(|c| c.get("parts"))
        .and_then(|v| v.as_array());

    let mut text = String::new();
    if let Some(parts) = parts {
        for part in parts {
            if let Some(t) = part.get("text").and_then(|v| v.as_str()) {
                text.push_str(t);
            }
        }
    }
    text
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
