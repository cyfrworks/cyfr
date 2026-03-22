use std::collections::HashMap;
use serde_json::{json, Value};

use crate::bindings::cyfr::formula::invoke;

// ---------------------------------------------------------------------------
// Adaptive tool result limits
// ---------------------------------------------------------------------------

fn max_result_chars(_tool_name: &str) -> usize {
    256000
}

// ---------------------------------------------------------------------------
// External tool name sanitization
// ---------------------------------------------------------------------------
// LLM APIs (Claude, OpenAI, Gemini) require tool names matching ^[a-zA-Z0-9_-]+$
// External tools use `server:tool` format which contains `:`.
// We replace `:` with `__` for the LLM and reverse on dispatch.

fn sanitize_tool_name(name: &str) -> String {
    name.replace(':', "__")
}

fn unsanitize_tool_name(name: &str) -> String {
    // Only convert first `__` back to `:` — matches the server:tool pattern
    if let Some(pos) = name.find("__") {
        format!("{}:{}", &name[..pos], &name[pos + 2..])
    } else {
        name.to_string()
    }
}

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
// Tool definitions — MCP tools + virtual tools
// ---------------------------------------------------------------------------

/// Build canonical tool definitions (name, description, input_schema).
/// Returns a Vec — provider-specific formatting is done by Provider::format_tools().
pub fn build_tool_definitions(visible_tools: Option<&[String]>) -> Vec<Value> {
    let mut tools: Vec<Value> = Vec::new();

    // Discover MCP tools dynamically, optionally filtered by visible_tools
    let mcp_tools = discover_mcp_tools();
    let mcp_tools: Vec<Value> = if let Some(visible) = visible_tools {
        mcp_tools
            .into_iter()
            .filter(|t| {
                let name = t.get("name").and_then(|v| v.as_str()).unwrap_or("");
                // External tools (server:tool format) always pass through —
                // access control is server-side via enable/disable
                name.contains(':') || visible.iter().any(|v| name == v)
            })
            .collect()
    } else {
        mcp_tools
    };

    for t in &mcp_tools {
        let name = t.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let description = t.get("description").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let schema = t.get("inputSchema").cloned().unwrap_or(json!({"type": "object"}));

        if !name.is_empty() {
            // Sanitize external tool names (`:` not allowed by LLM APIs)
            let safe_name = if name.contains(':') { sanitize_tool_name(name) } else { name.to_string() };
            tools.push(json!({
                "name": safe_name,
                "description": description,
                "input_schema": schema
            }));
        }
    }

    // Add virtual tools (only if not filtered out by visible_tools)
    if virtual_tool_allowed(visible_tools, "storage") {
        tools.push(json!({
            "name": "storage",
            "description": "Persistent key-value storage. Keys are slash-separated paths. Values are JSON. Stored under data/storage/.",
            "input_schema": {
                "type": "object",
                "required": ["action"],
                "properties": {
                    "action": {"type": "string", "enum": ["read", "write", "list", "delete"]},
                    "key": {"type": "string", "description": "Storage key (e.g. 'research/notion', 'notes/meeting')"},
                    "value": {"description": "JSON value to store (write action)"}
                }
            }
        }));
    }

    if virtual_tool_allowed(visible_tools, "builder") {
        tools.push(json!({
            "name": "builder",
            "description": "Spawn a Builder specialist to create, fix, or improve WASM components. Handles Rust/WASM development, compilation, manifest work. Returns the builder's response.",
            "input_schema": {
                "type": "object",
                "required": ["task"],
                "properties": {
                    "task": {"type": "string", "description": "Detailed task with all relevant context. The builder has no conversation memory."}
                }
            }
        }));
    }

    if virtual_tool_allowed(visible_tools, "explorer") {
        tools.push(json!({
            "name": "explorer",
            "description": "Spawn an Explorer specialist for deep web research. Use for fact-finding requiring multiple searches, documentation lookup, external research. Returns synthesized findings.",
            "input_schema": {
                "type": "object",
                "required": ["task"],
                "properties": {
                    "task": {"type": "string", "description": "Research question. Be specific. Include what you already know."}
                }
            }
        }));
    }

    if virtual_tool_allowed(visible_tools, "request_setup") {
        tools.push(json!({
            "name": "request_setup",
            "description": "Open the setup form for a component that needs configuration (secrets, policy). The harness shows an inline form where the user fills in credentials securely. Use this when a component needs setup before it can be used.",
            "input_schema": {
                "type": "object",
                "required": ["component_ref"],
                "properties": {
                    "component_ref": {
                        "type": "string",
                        "description": "Component reference (e.g. catalyst:local.notion:0.2.0)"
                    }
                }
            }
        }));
    }

    // Virtual file tools — simple wrappers around catalyst:local.files
    if virtual_tool_allowed(visible_tools, "files") {
        tools.push(json!({
            "name": "read_file",
            "description": "Read file contents. Returns the file text with line numbers.",
            "input_schema": {
                "type": "object",
                "required": ["path"],
                "properties": {
                    "path": {"type": "string", "description": "File path to read"},
                    "start_line": {"type": "integer", "description": "Start line (1-based, optional)"},
                    "end_line": {"type": "integer", "description": "End line (inclusive, optional)"}
                }
            }
        }));

        tools.push(json!({
            "name": "write_file",
            "description": "Write or create a file with the given content. Overwrites existing files.",
            "input_schema": {
                "type": "object",
                "required": ["path", "content"],
                "properties": {
                    "path": {"type": "string", "description": "File path to write"},
                    "content": {"type": "string", "description": "File content to write"}
                }
            }
        }));

        tools.push(json!({
            "name": "edit_file",
            "description": "Edit a file with line-based replacements. Always read_file first to get current line numbers.",
            "input_schema": {
                "type": "object",
                "required": ["path", "edits"],
                "properties": {
                    "path": {"type": "string", "description": "File path to edit"},
                    "edits": {
                        "type": "array",
                        "description": "List of edits to apply",
                        "items": {
                            "type": "object",
                            "required": ["action", "start", "end", "content"],
                            "properties": {
                                "action": {"type": "string", "enum": ["replace", "insert", "delete"]},
                                "start": {"type": "integer", "description": "Start line (1-based)"},
                                "end": {"type": "integer", "description": "End line (inclusive)"},
                                "content": {"type": "string", "description": "Replacement content"}
                            }
                        }
                    }
                }
            }
        }));

        tools.push(json!({
            "name": "search_files",
            "description": "Search for files matching a glob pattern.",
            "input_schema": {
                "type": "object",
                "required": ["base_path", "pattern"],
                "properties": {
                    "base_path": {"type": "string", "description": "Directory to search in"},
                    "pattern": {"type": "string", "description": "Glob pattern (e.g. '**/*.rs', '*.json')"}
                }
            }
        }));

        tools.push(json!({
            "name": "grep",
            "description": "Search file contents for a regex pattern.",
            "input_schema": {
                "type": "object",
                "required": ["path", "pattern"],
                "properties": {
                    "path": {"type": "string", "description": "File or directory to search"},
                    "pattern": {"type": "string", "description": "Regex pattern to search for"},
                    "include": {"type": "string", "description": "File filter glob (e.g. '*.rs')"}
                }
            }
        }));

        tools.push(json!({
            "name": "tree",
            "description": "Show directory tree structure.",
            "input_schema": {
                "type": "object",
                "required": ["path"],
                "properties": {
                    "path": {"type": "string", "description": "Directory path"},
                    "depth": {"type": "integer", "description": "Max depth (default 3)"}
                }
            }
        }));
    }

    tools
}

/// Check if a virtual tool should be included based on visible_tools.
/// Virtual tools are always included when visible_tools is None (all tools allowed).
/// When visible_tools is Some, the tool name must appear in the list.
fn virtual_tool_allowed(visible_tools: Option<&[String]>, name: &str) -> bool {
    match visible_tools {
        None => true,
        Some(visible) => visible.iter().any(|v| v == name),
    }
}

// ---------------------------------------------------------------------------
// Tool dispatch — virtual tools + MCP passthrough
// ---------------------------------------------------------------------------

pub fn dispatch_tool(tool_name: &str, tool_call_id: &str, args: &Value, catalyst_ref: &str, model: &str) -> String {
    // Unsanitize external tool names (LLM returns `server__tool`, we need `server:tool`)
    let real_name = unsanitize_tool_name(tool_name);
    let tool_name = real_name.as_str();
    match tool_name {
        "storage" => dispatch_storage(args),
        "request_setup" => dispatch_request_setup(args),
        "builder" | "explorer" => dispatch_specialist(tool_name, tool_call_id, args, catalyst_ref, model),
        "read_file" => dispatch_file_op("read_lines", args),
        "write_file" => dispatch_file_op("write_text", args),
        "edit_file" => dispatch_file_op("edit", args),
        "search_files" => dispatch_file_op("search", args),
        "grep" => dispatch_file_op("grep", args),
        "tree" => dispatch_file_op("tree", args),
        _ => dispatch_mcp_tool(tool_name, args),
    }
}

// ---------------------------------------------------------------------------
// Virtual tool: request_setup — emit setup event for harness UI
// ---------------------------------------------------------------------------

fn dispatch_request_setup(args: &Value) -> String {
    let component_ref = args.get("component_ref").and_then(|v| v.as_str()).unwrap_or("");
    if component_ref.is_empty() {
        return json!({"error": "Missing required 'component_ref' field"}).to_string();
    }

    // Validate the component exists by calling setup_plan
    let plan_result = invoke::call(&json!({
        "tool": "component",
        "action": "setup_plan",
        "args": {"reference": component_ref}
    }).to_string());
    let plan: Value = serde_json::from_str(&plan_result).unwrap_or(json!({}));

    // Check for errors (component not found, etc.)
    if let Some(err) = plan.get("error") {
        return format!("Error: component '{}' not found or setup_plan failed: {}", component_ref, err);
    }

    // Emit request_setup event — the harness (AgentLive) shows the inline setup form
    let _ = invoke::emit(&json!({
        "kind": "request_setup",
        "component_ref": component_ref
    }).to_string());

    format!("Setup form opened for {}. The user will fill in credentials and configuration there. Your task will be automatically re-sent once setup is complete.", component_ref)
}

// ---------------------------------------------------------------------------
// Virtual tool: storage — wraps files catalyst for data/storage/
// ---------------------------------------------------------------------------

fn dispatch_storage(args: &Value) -> String {
    let action = args.get("action").and_then(|v| v.as_str()).unwrap_or("");
    let key = args.get("key").and_then(|v| v.as_str()).unwrap_or("");
    let path = format!("data/storage/{}.json", key);

    let files_input = match action {
        "write" => {
            let value = args.get("value").cloned().unwrap_or(json!(null));
            let content = serde_json::to_string_pretty(&value).unwrap_or_default();
            json!({"action": "write", "path": path, "content": content})
        }
        "read" => json!({"action": "read_lines", "path": path}),
        "list" => {
            let list_path = if key.is_empty() { "data/storage".to_string() } else { format!("data/storage/{}", key) };
            json!({"action": "tree", "path": list_path, "depth": 2})
        }
        "delete" => json!({"action": "delete", "path": path}),
        _ => return json!({"error": format!("Unknown storage action: {}", action)}).to_string(),
    };

    let request = json!({
        "tool": "execution",
        "action": "run",
        "args": {
            "reference": "catalyst:local.files",
            "input": files_input
        }
    });

    let response_str = invoke::call(&request.to_string());
    let response: Value = serde_json::from_str(&response_str).unwrap_or(json!({}));

    if let Some(output) = response.get("output") {
        truncate_result_for("storage", &serde_json::to_string_pretty(output).unwrap_or_default())
    } else if let Some(err) = response.get("error") {
        format!("Error: {}", err)
    } else {
        truncate_result_for("storage", &response_str)
    }
}

// ---------------------------------------------------------------------------
// Virtual tools: file operations — wraps catalyst:local.files
// ---------------------------------------------------------------------------

fn dispatch_file_op(files_action: &str, args: &Value) -> String {
    let files_input = match files_action {
        "read_lines" => {
            let mut input = json!({"action": "read_lines", "path": args.get("path").and_then(|v| v.as_str()).unwrap_or("")});
            if let Some(start) = args.get("start_line") {
                input["start_line"] = start.clone();
            }
            if let Some(end) = args.get("end_line") {
                input["end_line"] = end.clone();
            }
            input
        }
        "write_text" => {
            json!({
                "action": "write_text",
                "path": args.get("path").and_then(|v| v.as_str()).unwrap_or(""),
                "content": args.get("content").and_then(|v| v.as_str()).unwrap_or("")
            })
        }
        "edit" => {
            json!({
                "action": "edit",
                "path": args.get("path").and_then(|v| v.as_str()).unwrap_or(""),
                "edits": args.get("edits").cloned().unwrap_or(json!([]))
            })
        }
        "search" => {
            json!({
                "action": "search",
                "base_path": args.get("base_path").and_then(|v| v.as_str()).unwrap_or("."),
                "pattern": args.get("pattern").and_then(|v| v.as_str()).unwrap_or("*")
            })
        }
        "grep" => {
            let mut input = json!({
                "action": "grep",
                "path": args.get("path").and_then(|v| v.as_str()).unwrap_or("."),
                "pattern": args.get("pattern").and_then(|v| v.as_str()).unwrap_or("")
            });
            if let Some(include) = args.get("include").and_then(|v| v.as_str()) {
                input["include"] = json!(include);
            }
            input
        }
        "tree" => {
            let mut input = json!({
                "action": "tree",
                "path": args.get("path").and_then(|v| v.as_str()).unwrap_or(".")
            });
            if let Some(depth) = args.get("depth") {
                input["depth"] = depth.clone();
            }
            input
        }
        _ => return json!({"error": format!("Unknown file action: {}", files_action)}).to_string(),
    };

    let request = json!({
        "tool": "execution",
        "action": "run",
        "args": {
            "reference": "catalyst:local.files",
            "input": files_input
        }
    });

    let response_str = invoke::call(&request.to_string());
    let response: Value = serde_json::from_str(&response_str).unwrap_or(json!({}));

    if let Some(output) = response.get("output") {
        truncate_result_for(files_action, &serde_json::to_string_pretty(output).unwrap_or_default())
    } else if let Some(err) = response.get("error") {
        format!("Error: {}", err)
    } else {
        truncate_result_for(files_action, &response_str)
    }
}

// ---------------------------------------------------------------------------
// Virtual tools: builder / explorer — spawn specialist sub-agents
// ---------------------------------------------------------------------------

fn dispatch_specialist(role: &str, tool_call_id: &str, args: &Value, catalyst_ref: &str, model: &str) -> String {
    let task = args.get("task").and_then(|v| v.as_str()).unwrap_or("");
    if task.is_empty() {
        return json!({"error": "Missing required 'task' field"}).to_string();
    }

    // 1. Fetch specialist prompt
    let guide_result = invoke::call(&json!({
        "tool": "guide", "action": "get", "args": {"name": role}
    }).to_string());
    let guide: Value = serde_json::from_str(&guide_result).unwrap_or_default();
    let prompt = extract_guide_content(&guide);

    if prompt.is_empty() {
        return json!({"error": format!("Failed to fetch {} prompt", role)}).to_string();
    }

    // 2. Determine visible_tools per role
    let visible_tools = match role {
        "builder" => json!(["component", "build", "execution", "guide", "secret", "policy", "system", "files"]),
        "explorer" => json!(["native_search", "execution", "component", "guide", "system", "storage", "files"]),
        _ => json!(null),
    };

    // 3. Spawn sub-agent with role + emit_tag for UI grouping
    let emit_tag = format!("{}:{}", role, tool_call_id);
    let mut input = json!({
        "catalyst_ref": catalyst_ref,
        "model": model,
        "task": task,
        "system": prompt,
        "role": role,
        "emit_tag": emit_tag
    });
    if !visible_tools.is_null() {
        input["visible_tools"] = visible_tools;
    }

    let result = invoke::call(&json!({
        "tool": "execution",
        "action": "run",
        "args": {
            "reference": "formula:local.agent",
            "input": input
        }
    }).to_string());

    // 4. Extract content from sub-agent result
    extract_specialist_content(&result, role)
}

/// Extract the guide markdown content from the guide(get) response.
fn extract_guide_content(response: &Value) -> String {
    // Response format: {"status": "completed", "output": {"content": "..."}}
    response
        .get("output")
        .and_then(|o| o.get("content"))
        .and_then(|c| c.as_str())
        .unwrap_or("")
        .to_string()
}

/// Extract useful content from a sub-agent execution result.
fn extract_specialist_content(response_str: &str, role: &str) -> String {
    let response: Value = serde_json::from_str(response_str).unwrap_or(json!({}));

    // Check for top-level error
    if let Some(err) = response.get("error") {
        return format!("[{} error] {}", role, err);
    }

    let output = response.get("output").cloned().unwrap_or(Value::Null);

    // Navigate: output -> result (may be string or object)
    let result = if let Some(r) = output.get("result") {
        match r {
            Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(r.clone()),
            _ => r.clone(),
        }
    } else {
        match &output {
            Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
            _ => output,
        }
    };

    if let Some(err) = result.get("error") {
        return format!("[{} error] {}", role, err);
    }

    // Extract the content field from the agent formula output
    if let Some(content) = result.get("content").and_then(|c| c.as_str()) {
        if !content.is_empty() {
            return truncate_result_for(role, content);
        }
    }

    // Fallback: return the full result
    truncate_result_for(role, &serde_json::to_string_pretty(&result).unwrap_or_default())
}

// ---------------------------------------------------------------------------
// Generic MCP tool dispatch — extract action, call invoke
// ---------------------------------------------------------------------------

fn dispatch_mcp_tool(tool_name: &str, args: &Value) -> String {
    // External tools (server:tool format) use synthetic "call" action —
    // the Elixir try_handle strips action before forwarding to the remote server
    if tool_name.contains(':') {
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
        let result = dispatch_mcp(tool_name, "call", &remaining);
        // Enrich error messages with server name for external tools
        if result.starts_with("Error: ") {
            let server_name = tool_name.split(':').next().unwrap_or(tool_name);
            let error_detail = &result["Error: ".len()..];
            return format!("Error from external server '{}': {}", server_name, error_detail);
        }
        return result;
    }

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
        truncate_result_for(tool, &serde_json::to_string_pretty(output).unwrap_or_default())
    } else if let Some(err) = response.get("error") {
        format!("Error: {}", err)
    } else {
        truncate_result_for(tool, &response_str)
    }
}

// ---------------------------------------------------------------------------
// Build a spawn request from tool name and args
// ---------------------------------------------------------------------------

fn build_spawn_request(tool_name: &str, args: &Value) -> Value {
    // Virtual tools don't use the MCP action pattern — handle them specially
    match tool_name {
        "storage" | "request_setup" | "builder" | "explorer"
        | "read_file" | "write_file" | "edit_file"
        | "search_files" | "grep" | "tree" => {
            // These are dispatched directly, not through MCP spawn.
            // This path shouldn't be reached for virtual tools in parallel execution,
            // but return a safe no-op just in case.
            json!({"tool": tool_name, "action": "run", "args": args})
        }
        _ => {
            // External tools (server:tool) use synthetic "call" action
            let (action, remaining) = if tool_name.contains(':') {
                let rem = if let Some(obj) = args.as_object() {
                    let filtered: serde_json::Map<String, Value> = obj
                        .iter()
                        .filter(|(k, _)| k.as_str() != "action")
                        .map(|(k, v)| (k.clone(), v.clone()))
                        .collect();
                    Value::Object(filtered)
                } else {
                    json!({})
                };
                ("call", rem)
            } else {
                let act = args.get("action").and_then(|v| v.as_str()).unwrap_or("");
                let rem = if let Some(obj) = args.as_object() {
                    let filtered: serde_json::Map<String, Value> = obj
                        .iter()
                        .filter(|(k, _)| k.as_str() != "action")
                        .map(|(k, v)| (k.clone(), v.clone()))
                        .collect();
                    Value::Object(filtered)
                } else {
                    json!({})
                };
                (act, rem)
            };
            json!({"tool": tool_name, "action": action, "args": remaining})
        }
    }
}

// ---------------------------------------------------------------------------
// Parallel tool execution — all tool types
// ---------------------------------------------------------------------------

pub fn execute_tools_parallel(
    tool_calls: &[(String, String, Value)],
    catalyst_ref: &str,
    model: &str,
) -> Vec<(String, String, String)> {
    // Single call: dispatch synchronously (avoid spawn overhead)
    if tool_calls.len() == 1 {
        let (id, name, args) = &tool_calls[0];
        let result = dispatch_tool(name, id, args, catalyst_ref, model);
        return vec![(id.clone(), name.clone(), result)];
    }

    // Separate virtual tools from MCP tools — virtual tools must be dispatched
    // synchronously since they do their own invoke::call internally
    let mut virtual_results: Vec<(usize, String, String, String)> = Vec::new();
    let mut mcp_entries: Vec<(usize, String, String, Value)> = Vec::new();

    for (i, (id, name, args)) in tool_calls.iter().enumerate() {
        // Unsanitize external tool names from LLM (e.g., `server__tool` -> `server:tool`)
        let real_name = unsanitize_tool_name(name);
        match real_name.as_str() {
            "storage" | "builder" | "explorer"
            | "read_file" | "write_file" | "edit_file"
            | "search_files" | "grep" | "tree" => {
                let result = dispatch_tool(name, id, args, catalyst_ref, model);
                virtual_results.push((i, id.clone(), name.clone(), result));
            }
            _ => {
                mcp_entries.push((i, id.clone(), real_name, args.clone()));
            }
        }
    }

    // Spawn MCP tool calls in parallel
    let mut mcp_task_entries: Vec<(usize, String, String, String)> = Vec::new(); // (idx, id, name, task_id)

    for (idx, id, name, args) in &mcp_entries {
        let request = build_spawn_request(name, args);
        let spawn_str = invoke::spawn(&request.to_string());
        let spawn: Value = serde_json::from_str(&spawn_str).unwrap_or(json!({}));
        let task_id = spawn.get("task_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        mcp_task_entries.push((*idx, id.clone(), name.clone(), task_id));
    }

    // Collect valid task IDs for await-all
    let valid_ids: Vec<&str> = mcp_task_entries.iter()
        .filter(|(_, _, _, tid)| !tid.is_empty())
        .map(|(_, _, _, tid)| tid.as_str())
        .collect();

    let mut result_map: HashMap<String, String> = HashMap::new();
    if !valid_ids.is_empty() {
        let await_req = json!({"task_ids": valid_ids});
        let await_str = invoke::await_all(&await_req.to_string());
        let await_resp: Value = serde_json::from_str(&await_str).unwrap_or(json!({}));

        let result_arr = await_resp.get("results").and_then(|v| v.as_array()).cloned().unwrap_or_default();
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
    }

    // Combine all results in original order
    let mut all_results: Vec<(usize, String, String, String)> = Vec::new();

    // Add virtual tool results
    all_results.extend(virtual_results);

    // Add MCP tool results, enriching errors for external tools
    for (idx, id, name, task_id) in &mcp_task_entries {
        let mut result = if task_id.is_empty() {
            "Spawn failed".to_string()
        } else {
            result_map.get(task_id).cloned().unwrap_or("Spawn failed".to_string())
        };
        // Enrich error messages with server name for external tools
        if name.contains(':') && result.starts_with("Error: ") {
            let server_name = name.split(':').next().unwrap_or(name);
            let error_detail = &result["Error: ".len()..];
            result = format!("Error from external server '{}': {}", server_name, error_detail);
        }
        all_results.push((*idx, id.clone(), name.clone(), result));
    }

    // Sort by original index to maintain order
    all_results.sort_by_key(|(idx, _, _, _)| *idx);

    all_results.into_iter()
        .map(|(_, id, name, result)| (id, name, result))
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
    let tool_name = result.get("tool").and_then(|v| v.as_str()).unwrap_or("");
    let formatted = if let Some(data) = parsed.get("data") {
        serde_json::to_string_pretty(data).unwrap_or_else(|_| data.to_string())
    } else {
        serde_json::to_string_pretty(&parsed).unwrap_or_else(|_| parsed.to_string())
    };
    truncate_result_for(tool_name, &formatted)
}

/// Truncate result using adaptive limit based on tool name.
fn truncate_result_for(tool_name: &str, s: &str) -> String {
    let max = max_result_chars(tool_name);
    if s.len() <= max {
        s.to_string()
    } else {
        let truncated = truncate_str_at(s, max);
        format!("{}\n\n[... truncated, showing first {} of {} bytes]", truncated, truncated.len(), s.len())
    }
}

/// Truncate a string at a UTF-8 safe boundary, never exceeding `max_bytes`.
fn truncate_str_at(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        s
    } else {
        // Find the last valid UTF-8 char boundary at or before max_bytes
        let mut end = max_bytes;
        while end > 0 && !s.is_char_boundary(end) {
            end -= 1;
        }
        &s[..end]
    }
}
