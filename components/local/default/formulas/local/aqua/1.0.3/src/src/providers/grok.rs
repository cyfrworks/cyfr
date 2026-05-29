use serde_json::{json, Value};

use super::{native_tool_allowed, ToolCall};

// ---------------------------------------------------------------------------
// Tool formatting — Responses API
// ---------------------------------------------------------------------------

/// Build base Responses API tools: flat format with {"type": "function", ...}
fn format_tools_base(tools: &[Value]) -> Vec<Value> {
    tools
        .iter()
        .map(|t| {
            json!({
                "type": "function",
                "name": t["name"],
                "description": t["description"],
                "parameters": t["input_schema"]
            })
        })
        .collect()
}

/// Grok: web_search + x_search native tools
pub fn format_tools(tools: &[Value], visible_tools: Option<&[String]>) -> Value {
    let mut all_tools = format_tools_base(tools);
    if native_tool_allowed(visible_tools, "native_search") {
        all_tools.push(json!({"type": "web_search"}));
        all_tools.push(json!({"type": "x_search"}));
    }
    json!(all_tools)
}

/// OpenAI: web_search only (no x_search)
pub fn format_tools_openai(tools: &[Value], visible_tools: Option<&[String]>) -> Value {
    let mut all_tools = format_tools_base(tools);
    if native_tool_allowed(visible_tools, "native_search") {
        all_tools.push(json!({"type": "web_search"}));
    }
    json!(all_tools)
}

// ---------------------------------------------------------------------------
// Request building — xAI Responses API
// ---------------------------------------------------------------------------

/// Build a request for xAI's Responses API (/v1/responses).
///
/// Differences from Chat Completions:
/// - Uses `input` instead of `messages`
/// - System role is `developer` instead of `system`
/// - Tool results are `function_call_output` items (not `{"role": "tool"}` messages)
/// - Tool calls in conversation are `function_call` items
pub fn build_request(
    model: &str,
    messages: &[Value],
    system: &str,
    tools: &Value,
) -> Value {
    let mut input: Vec<Value> = Vec::new();

    // System prompt as developer role
    input.push(json!({"role": "developer", "content": system}));

    // Convert canonical messages to Responses API format
    for msg in messages {
        let role = msg.get("role").and_then(|v| v.as_str()).unwrap_or("user");

        match role {
            "user" => {
                let content = msg.get("content").cloned().unwrap_or(json!(""));
                let converted = convert_content_for_responses_api(&content);
                input.push(json!({"role": "user", "content": converted}));
            }
            "assistant" => {
                // Emit text content if present
                if let Some(content) = msg.get("content").and_then(|v| v.as_str()) {
                    if !content.is_empty() {
                        input.push(json!({"role": "assistant", "content": content}));
                    }
                }
                // Emit tool calls as function_call items
                if let Some(tool_calls) = msg.get("tool_calls").and_then(|v| v.as_array()) {
                    for tc in tool_calls {
                        let arguments = if tc.get("arguments").map_or(false, |v| v.is_string()) {
                            tc["arguments"].as_str().unwrap_or("{}").to_string()
                        } else {
                            serde_json::to_string(&tc["arguments"]).unwrap_or_else(|_| "{}".to_string())
                        };
                        input.push(json!({
                            "type": "function_call",
                            "call_id": tc["id"],
                            "name": tc["name"],
                            "arguments": arguments
                        }));
                    }
                }
            }
            "tool_results" => {
                if let Some(results) = msg.get("results").and_then(|v| v.as_array()) {
                    for result in results {
                        input.push(json!({
                            "type": "function_call_output",
                            "call_id": result["tool_call_id"],
                            "output": result["content"]
                        }));
                    }
                }
            }
            _ => {
                input.push(msg.clone());
            }
        }
    }

    let mut params = json!({
        "model": model,
        "input": input,
    });

    let all_tools = tools.as_array().cloned().unwrap_or_default();
    if !all_tools.is_empty() {
        params["tools"] = json!(all_tools);
    }

    json!({
        "operation": "responses.create",
        "params": params,
    })
}

// ---------------------------------------------------------------------------
// Content type conversion — canonical (Claude-like) → Responses API
// ---------------------------------------------------------------------------

/// Convert content block types from canonical format to Responses API format.
///
/// Canonical format uses Claude-like type names (text, image, document).
/// The Responses API requires: input_text, input_image, input_file.
/// String content passes through unchanged.
fn convert_content_for_responses_api(content: &Value) -> Value {
    match content.as_array() {
        None => content.clone(), // String content — pass through
        Some(blocks) => {
            let converted: Vec<Value> = blocks
                .iter()
                .map(|block| {
                    let t = block.get("type").and_then(|t| t.as_str()).unwrap_or("");
                    match t {
                        "text" => {
                            json!({
                                "type": "input_text",
                                "text": block.get("text").cloned().unwrap_or(json!(""))
                            })
                        }
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
                                "type": "input_image",
                                "image_url": format!("data:{};base64,{}", mt, data)
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
                                "type": "input_file",
                                "file_data": format!("data:{};base64,{}", mt, data),
                                "filename": "attachment"
                            })
                        }
                        // Already-correct types (input_text, etc.) or unknown — pass through
                        _ => block.clone(),
                    }
                })
                .collect();
            json!(converted)
        }
    }
}

// ---------------------------------------------------------------------------
// Response parsing — xAI Responses API
// ---------------------------------------------------------------------------

/// Get the output array from the response data
fn get_output(data: &Value) -> Vec<Value> {
    data.get("output")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
}

pub fn has_tool_calls(data: &Value) -> bool {
    get_output(data)
        .iter()
        .any(|item| item.get("type").and_then(|v| v.as_str()) == Some("function_call"))
}

pub fn extract_tool_calls(data: &Value) -> Vec<ToolCall> {
    get_output(data)
        .iter()
        .filter(|item| item.get("type").and_then(|v| v.as_str()) == Some("function_call"))
        .map(|item| {
            let id = item
                .get("call_id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let name = item
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let args_str = item
                .get("arguments")
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
    // Check for combined_text from streaming
    if let Some(text) = data.get("combined_text").and_then(|v| v.as_str()) {
        return text.to_string();
    }

    let mut text = String::new();
    for item in get_output(data) {
        let item_type = item.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if item_type == "message" {
            // Message items have content array: [{type: "output_text", text: "..."}]
            if let Some(content) = item.get("content").and_then(|v| v.as_array()) {
                for block in content {
                    if let Some(t) = block.get("text").and_then(|v| v.as_str()) {
                        text.push_str(t);
                    }
                }
            }
        }
    }
    text
}

/// Extract token usage from Responses API: data.usage.{input_tokens, output_tokens}
pub fn extract_usage(data: &Value) -> Value {
    if let Some(usage) = data.get("usage") {
        let input = usage.get("input_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        let output = usage.get("output_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        json!({"input_tokens": input, "output_tokens": output})
    } else {
        Value::Null
    }
}
