use std::collections::HashMap;
use serde_json::{json, Value};

use crate::bindings::cyfr::formula::invoke;
use crate::providers::Provider;

const MAX_TOOL_RESULT_CHARS: usize = 32000;

// ---------------------------------------------------------------------------
// Dynamic MCP tool discovery
// ---------------------------------------------------------------------------

/// Discover available MCP tools via tools.list at startup.
/// Returns a vec of tool definitions (name, description, inputSchema).
/// Filters out the "tools" meta-tool since the formula already called it.
fn discover_mcp_tools() -> Vec<Value> {
    let request = json!({"tool": "tools", "action": "list", "args": {}});
    let response_str = invoke::call(&request.to_string());
    let response: Value = serde_json::from_str(&response_str).unwrap_or(json!({}));

    // Extract tools array from response
    // Response format: {"status": "completed", "output": {"tools": [...]}}
    let tools = response
        .get("output")
        .and_then(|o| o.get("tools"))
        .and_then(|t| t.as_array())
        .cloned()
        .unwrap_or_default();

    // Filter out the "tools" meta-tool — the LLM doesn't need it
    tools
        .into_iter()
        .filter(|t| {
            t.get("name").and_then(|v| v.as_str()) != Some("tools")
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Tool definitions — dynamically discovered MCP tools only
// ---------------------------------------------------------------------------

pub fn build_tool_definitions(provider: Provider) -> Value {
    let mut tools: Vec<Value> = Vec::new();

    // Discover MCP tools dynamically
    let mcp_tools = discover_mcp_tools();
    for t in &mcp_tools {
        let name = t.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let description = t.get("description").and_then(|v| v.as_str()).unwrap_or("");
        let schema = t.get("inputSchema").cloned().unwrap_or(json!({"type": "object"}));

        if !name.is_empty() {
            tools.push(json!({
                "name": name,
                "description": description,
                "input_schema": schema
            }));
        }
    }

    // Format tools based on provider
    match provider {
        Provider::OpenAI => {
            let openai_tools: Vec<Value> = tools
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
            json!(openai_tools)
        }
        Provider::Gemini => {
            let declarations: Vec<Value> = tools
                .iter()
                .map(|t| {
                    json!({
                        "name": t["name"],
                        "description": t["description"],
                        "parameters": t["input_schema"]
                    })
                })
                .collect();
            json!([{"functionDeclarations": declarations}])
        }
        _ => {
            json!(tools)
        }
    }
}

// ---------------------------------------------------------------------------
// Tool dispatch — all tools go through MCP
// ---------------------------------------------------------------------------

pub fn dispatch_tool(tool_name: &str, args: &Value) -> String {
    dispatch_mcp_tool(tool_name, args)
}

// ---------------------------------------------------------------------------
// Generic MCP tool dispatch — extract action, call invoke
// ---------------------------------------------------------------------------

fn dispatch_mcp_tool(tool_name: &str, args: &Value) -> String {
    let action = args.get("action").and_then(|v| v.as_str()).unwrap_or("");
    if action.is_empty() {
        return json!({"error": format!("Missing required 'action' field for tool '{}'", tool_name)}).to_string();
    }

    // Build remaining args (filter out "action" key)
    let remaining = if let Some(obj) = args.as_object() {
        let filtered: serde_json::Map<String, Value> = obj
            .iter()
            .filter(|(k, _)| k.as_str() != "action")
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        Value::Object(filtered)
    } else {
        json!({})
    };

    dispatch_mcp(tool_name, action, &remaining)
}

// ---------------------------------------------------------------------------
// MCP dispatch — everything goes through invoke::call()
// ---------------------------------------------------------------------------

fn dispatch_mcp(tool: &str, action: &str, args: &Value) -> String {
    let request = json!({
        "tool": tool,
        "action": action,
        "args": args
    });
    let response_str = invoke::call(&request.to_string());
    // Parse unified response format
    let response: Value = serde_json::from_str(&response_str).unwrap_or(json!({}));
    if let Some(output) = response.get("output") {
        truncate_result(&serde_json::to_string_pretty(output).unwrap_or_default())
    } else if let Some(err) = response.get("error") {
        format!("Error: {}", err)
    } else {
        truncate_result(&response_str)
    }
}

// ---------------------------------------------------------------------------
// Build a spawn request from tool name and args
// ---------------------------------------------------------------------------

fn build_spawn_request(tool_name: &str, args: &Value) -> Value {
    let action = args.get("action").and_then(|v| v.as_str()).unwrap_or("");

    let remaining = if let Some(obj) = args.as_object() {
        let filtered: serde_json::Map<String, Value> = obj
            .iter()
            .filter(|(k, _)| k.as_str() != "action")
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        Value::Object(filtered)
    } else {
        json!({})
    };

    json!({
        "tool": tool_name,
        "action": action,
        "args": remaining
    })
}

// ---------------------------------------------------------------------------
// Parallel tool execution — all tool types
// ---------------------------------------------------------------------------

pub fn execute_tools_parallel(
    tool_calls: &[(String, String, Value)],
) -> Vec<(String, String, String)> {
    // Single call: dispatch synchronously (avoid spawn overhead)
    if tool_calls.len() == 1 {
        let (id, name, args) = &tool_calls[0];
        let result = dispatch_tool(name, args);
        return vec![(id.clone(), name.clone(), result)];
    }

    // Multiple calls: spawn all, await all
    let mut task_entries: Vec<(String, String, String)> = Vec::new(); // (id, name, task_id)

    for (id, name, args) in tool_calls {
        let request = build_spawn_request(name, args);
        let spawn_str = invoke::spawn(&request.to_string());
        let spawn: Value = serde_json::from_str(&spawn_str).unwrap_or(json!({}));
        let task_id = spawn.get("task_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        task_entries.push((id.clone(), name.clone(), task_id));
    }

    // Collect valid task IDs for await-all
    let valid_ids: Vec<&str> = task_entries.iter()
        .filter(|(_, _, tid)| !tid.is_empty())
        .map(|(_, _, tid)| tid.as_str())
        .collect();

    if valid_ids.is_empty() {
        return task_entries.iter()
            .map(|(id, name, _)| (id.clone(), name.clone(), "Spawn failed".to_string()))
            .collect();
    }

    let await_req = json!({"task_ids": valid_ids});
    let await_str = invoke::await_all(&await_req.to_string());
    let await_resp: Value = serde_json::from_str(&await_str).unwrap_or(json!({}));

    // Build task_id → result map
    let result_arr = await_resp.get("results").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let mut result_map: HashMap<String, String> = HashMap::new();
    for r in &result_arr {
        if let Some(tid) = r.get("task_id").and_then(|v| v.as_str()) {
            let status = r.get("status").and_then(|v| v.as_str()).unwrap_or("error");
            let output = if status == "completed" {
                extract_invoke_output_from_result(r)
            } else {
                format!("Error: {}", r.get("error").map(|e| e.to_string()).unwrap_or_default())
            };
            result_map.insert(tid.to_string(), output);
        }
    }

    // Map back to original order
    task_entries.iter()
        .map(|(id, name, task_id)| {
            let result = if task_id.is_empty() {
                "Spawn failed".to_string()
            } else {
                result_map.get(task_id).cloned().unwrap_or("Spawn failed".to_string())
            };
            (id.clone(), name.clone(), result)
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn extract_invoke_output_from_result(result: &Value) -> String {
    let output = result.get("output").cloned().unwrap_or(Value::Null);
    let parsed = if let Some(r) = output.get("result") {
        r.clone()
    } else {
        match &output {
            Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
            _ => output,
        }
    };
    if let Some(err) = parsed.get("error") {
        return format!("Error: {}", err);
    }
    let formatted = if let Some(data) = parsed.get("data") {
        serde_json::to_string_pretty(data).unwrap_or_else(|_| data.to_string())
    } else {
        serde_json::to_string_pretty(&parsed).unwrap_or_else(|_| parsed.to_string())
    };
    truncate_result(&formatted)
}

pub fn truncate_result(s: &str) -> String {
    if s.len() <= MAX_TOOL_RESULT_CHARS {
        s.to_string()
    } else {
        let truncated = &s[..MAX_TOOL_RESULT_CHARS];
        format!("{}\n\n[... truncated, showing first {} chars of {} total]", truncated, MAX_TOOL_RESULT_CHARS, s.len())
    }
}
