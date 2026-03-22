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

    // Convert conversation messages to Responses API format
    for msg in messages {
        // Check if this is already in Responses API format (function_call_output, etc.)
        if msg.get("type").is_some() {
            // Already a Responses API item — pass through
            input.push(msg.clone());
            continue;
        }

        // Check if this is an array of Responses API items (from build_tool_results_message)
        if msg.is_array() {
            if let Some(items) = msg.as_array() {
                for item in items {
                    input.push(item.clone());
                }
            }
            continue;
        }

        let role = msg.get("role").and_then(|v| v.as_str()).unwrap_or("user");

        match role {
            "user" => {
                // User message — pass through with content
                let content = msg.get("content").cloned().unwrap_or(json!(""));
                input.push(json!({"role": "user", "content": content}));
            }
            "assistant" => {
                // Assistant message — check if it contains output items (from build_assistant_message)
                if let Some(output_items) = msg.get("_grok_output").and_then(|v| v.as_array()) {
                    // Replay the raw output items from a previous response
                    for item in output_items {
                        input.push(item.clone());
                    }
                } else if let Some(content) = msg.get("content").and_then(|v| v.as_str()) {
                    // Plain text assistant message
                    if !content.is_empty() {
                        input.push(json!({"role": "assistant", "content": content}));
                    }
                }
            }
            _ => {
                // Pass through unknown roles
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
            }
        })
        .collect()
}

/// Store the response output items so they can be replayed in conversation.
/// We tag with `_grok_output` so build_request can reconstruct the input array.
pub fn build_assistant_message(data: &Value) -> Value {
    let output = get_output(data);
    json!({
        "role": "assistant",
        "_grok_output": output
    })
}

/// Format tool results as Responses API function_call_output items.
/// Returns an array — caller splices into conversation.
pub fn build_tool_results_message(results: &[(String, String, String)]) -> Value {
    let items: Vec<Value> = results
        .iter()
        .map(|(id, _name, content)| {
            json!({
                "type": "function_call_output",
                "call_id": id,
                "output": content
            })
        })
        .collect();

    json!(items)
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
