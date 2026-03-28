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
            let params = if clean_params.is_null() || !clean_params.is_object() {
                json!({"type": "object"})
            } else {
                clean_params
            };
            json!({
                "name": t["name"],
                "description": t["description"],
                "parameters": params
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
// Content type conversion — canonical (Claude-like) → Gemini parts
// ---------------------------------------------------------------------------

/// Convert canonical content blocks to Gemini parts format.
///
/// Canonical: {"type":"text","text":"..."} → Gemini: {"text":"..."}
/// Canonical: {"type":"image","source":{"media_type":"...","data":"..."}} → Gemini: {"inlineData":{"mimeType":"...","data":"..."}}
fn convert_content_for_gemini(blocks: &[Value]) -> Vec<Value> {
    blocks
        .iter()
        .map(|block| {
            let t = block.get("type").and_then(|t| t.as_str()).unwrap_or("");
            match t {
                "text" => {
                    json!({"text": block.get("text").cloned().unwrap_or(json!(""))})
                }
                "image" | "document" => {
                    let mt = block
                        .get("source")
                        .and_then(|s| s.get("media_type"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("application/octet-stream");
                    let data = block
                        .get("source")
                        .and_then(|s| s.get("data"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    json!({"inlineData": {"mimeType": mt, "data": data}})
                }
                _ => {
                    // Blocks without "type" (e.g. already Gemini {"text":"..."}) — pass through
                    block.clone()
                }
            }
        })
        .collect()
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
    // Convert canonical messages to Gemini contents format
    let contents: Vec<Value> = messages
        .iter()
        .map(|msg| {
            let role = msg
                .get("role")
                .and_then(|v| v.as_str())
                .unwrap_or("user");

            match role {
                "user" => {
                    let content = msg.get("content");
                    let parts = match content {
                        Some(Value::Array(arr)) => {
                            // Convert canonical content blocks to Gemini parts
                            convert_content_for_gemini(arr)
                        }
                        Some(Value::String(s)) => {
                            vec![json!({"text": s})]
                        }
                        _ => {
                            vec![json!({"text": ""})]
                        }
                    };
                    json!({"role": "user", "parts": parts})
                }
                "assistant" => {
                    let text = msg
                        .get("content")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    let mut parts: Vec<Value> = vec![json!({"text": text})];

                    // Convert canonical tool_calls to Gemini functionCall parts
                    // Include thoughtSignature if present (required by Gemini 3+)
                    if let Some(tool_calls) = msg.get("tool_calls").and_then(|v| v.as_array()) {
                        for tc in tool_calls {
                            let name = tc.get("name").and_then(|v| v.as_str()).unwrap_or("");
                            let args = tc.get("arguments").cloned().unwrap_or(json!({}));
                            let mut part = json!({"functionCall": {"name": name, "args": args}});
                            if let Some(sig) = tc.get("thought_signature") {
                                part["thoughtSignature"] = sig.clone();
                            }
                            parts.push(part);
                        }
                    }
                    json!({"role": "model", "parts": parts})
                }
                "tool_results" => {
                    let mut parts: Vec<Value> = Vec::new();
                    if let Some(results) = msg.get("results").and_then(|v| v.as_array()) {
                        for r in results {
                            let name = r.get("name").and_then(|v| v.as_str()).unwrap_or("");
                            let content = r.get("content").and_then(|v| v.as_str()).unwrap_or("");
                            parts.push(json!({
                                "functionResponse": {
                                    "name": name,
                                    "response": {"content": content}
                                }
                            }));
                        }
                    }
                    json!({"role": "user", "parts": parts})
                }
                _ => {
                    // Fallback: treat as user message
                    let text = msg
                        .get("content")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    json!({"role": "user", "parts": [{"text": text}]})
                }
            }
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

            // Gemini 3+ models include thoughtSignature on functionCall parts —
            // must be passed back in subsequent turns or the API returns 400
            let thought_sig = part.get("thoughtSignature").cloned();

            calls.push(ToolCall {
                id: format!("gemini_call_{}", i),
                name,
                arguments: args,
                thought_signature: thought_sig,
            });
        }
    }
    calls
}

pub fn build_assistant_message(data: &Value) -> Value {
    let text = extract_text(data);
    let tool_calls = extract_tool_calls(data);
    let mut msg = json!({"role": "assistant", "content": text});
    if !tool_calls.is_empty() {
        msg["tool_calls"] = json!(tool_calls.iter().map(|tc| {
            let mut entry = json!({
                "id": tc.id,
                "name": tc.name,
                "arguments": tc.arguments
            });
            // Preserve Gemini thought signatures for replay in subsequent turns
            if let Some(sig) = &tc.thought_signature {
                entry["thought_signature"] = sig.clone();
            }
            entry
        }).collect::<Vec<_>>());
    }
    msg
}

/// results: Vec of (call_id, tool_name, result_content)
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
