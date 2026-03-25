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
// Content type conversion — canonical (Claude-like) → Chat Completions
// ---------------------------------------------------------------------------

/// Convert canonical content blocks to Chat Completions format.
///
/// Canonical: {"type":"text","text":"..."} → Chat Completions: same (pass through)
/// Canonical: {"type":"image","source":{...}} → Chat Completions: {"type":"image_url","image_url":{"url":"data:..."}}
/// Canonical: {"type":"document","source":{...}} → Chat Completions: {"type":"file","file":{"file_data":"data:...","filename":"..."}}
fn convert_content_for_chat_completions(content: &Value) -> Value {
    match content.as_array() {
        None => content.clone(), // String — pass through
        Some(blocks) => {
            let converted: Vec<Value> = blocks
                .iter()
                .map(|block| {
                    let t = block.get("type").and_then(|t| t.as_str()).unwrap_or("");
                    match t {
                        "text" => block.clone(), // Already correct for Chat Completions
                        "image" => {
                            let mt = block
                                .get("source")
                                .and_then(|s| s.get("media_type"))
                                .and_then(|v| v.as_str())
                                .unwrap_or("image/jpeg");
                            let data = block
                                .get("source")
                                .and_then(|s| s.get("data"))
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            json!({
                                "type": "image_url",
                                "image_url": {"url": format!("data:{};base64,{}", mt, data)}
                            })
                        }
                        "document" => {
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
                            json!({
                                "type": "file",
                                "file": {
                                    "file_data": format!("data:{};base64,{}", mt, data),
                                    "filename": "attachment"
                                }
                            })
                        }
                        _ => block.clone(),
                    }
                })
                .collect();
            json!(converted)
        }
    }
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

    // Convert canonical messages to Chat Completions format
    for msg in messages {
        let role = msg.get("role").and_then(|v| v.as_str()).unwrap_or("user");

        match role {
            "user" => {
                let content = msg.get("content").cloned().unwrap_or(json!(""));
                let converted = convert_content_for_chat_completions(&content);
                all_messages.push(json!({"role": "user", "content": converted}));
            }
            "assistant" => {
                let content = msg.get("content").cloned().unwrap_or(json!(""));
                if let Some(tool_calls) = msg.get("tool_calls").and_then(|v| v.as_array()) {
                    // Assistant message with tool calls
                    let cc_tool_calls: Vec<Value> = tool_calls.iter().map(|tc| {
                        let arguments = if tc.get("arguments").map_or(false, |v| v.is_string()) {
                            tc["arguments"].as_str().unwrap_or("{}").to_string()
                        } else {
                            serde_json::to_string(&tc["arguments"]).unwrap_or_else(|_| "{}".to_string())
                        };
                        json!({
                            "id": tc["id"],
                            "type": "function",
                            "function": {
                                "name": tc["name"],
                                "arguments": arguments
                            }
                        })
                    }).collect();
                    all_messages.push(json!({
                        "role": "assistant",
                        "content": content,
                        "tool_calls": cc_tool_calls
                    }));
                } else {
                    all_messages.push(json!({"role": "assistant", "content": content}));
                }
            }
            "tool_results" => {
                // Expand to separate tool messages
                if let Some(results) = msg.get("results").and_then(|v| v.as_array()) {
                    for result in results {
                        all_messages.push(json!({
                            "role": "tool",
                            "tool_call_id": result["tool_call_id"],
                            "content": result["content"]
                        }));
                    }
                }
            }
            _ => {
                all_messages.push(msg.clone());
            }
        }
    }

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
                thought_signature: None,
            }
        })
        .collect()
}

/// Build canonical assistant message from response data.
pub fn build_assistant_message(data: &Value) -> Value {
    let text = extract_text(data);
    let tool_calls = extract_tool_calls(data);
    let mut msg = json!({"role": "assistant", "content": text});
    if !tool_calls.is_empty() {
        msg["tool_calls"] = json!(tool_calls.iter().map(|tc| json!({
            "id": tc.id,
            "name": tc.name,
            "arguments": tc.arguments
        })).collect::<Vec<_>>());
    }
    msg
}

/// Build canonical tool results message.
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
