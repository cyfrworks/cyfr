use std::collections::{HashMap, HashSet};
use serde_json::{json, Value};

use crate::bindings::cyfr::formula::invoke;

const MAX_RESULT_BYTES: usize = 256_000;
const FILES_CATALYST: &str = "catalyst:local.files";
const HTTP_CATALYST: &str = "catalyst:local.http";
const AQUA_FORMULA: &str = "formula:local.aqua";
const EXECUTION_TOOL: &str = "execution";

// ---------------------------------------------------------------------------
// Sub-agent definition — provided by harness via input
// ---------------------------------------------------------------------------

pub struct SubAgentDef {
    pub name: String,
    pub description: String,
    pub prompt: String,
    pub visible_tools: Option<Vec<String>>,
    pub catalyst_ref: Option<String>,
    pub model: Option<String>,
}

impl SubAgentDef {
    pub fn from_value(v: &Value) -> Option<Self> {
        Some(SubAgentDef {
            name: v.get("name")?.as_str()?.to_string(),
            description: v.get("description").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            prompt: v.get("prompt").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            visible_tools: v.get("visible_tools").and_then(|v| v.as_array())
                .map(|arr| arr.iter().filter_map(|s| s.as_str().map(String::from)).collect()),
            catalyst_ref: v.get("catalyst_ref").and_then(|v| v.as_str()).map(String::from),
            model: v.get("model").and_then(|v| v.as_str()).map(String::from),
        })
    }
}

// ---------------------------------------------------------------------------
// External tool name sanitization
// ---------------------------------------------------------------------------
// LLM APIs (Claude, OpenAI, Gemini) require tool names matching ^[a-zA-Z0-9_-]+$
// External tools use `server:tool` format which contains `:`.
// We replace `:` with `__` for the LLM and reverse on dispatch.

fn sanitize_tool_name(name: &str) -> String {
    // Replace all characters not matching [a-zA-Z0-9_-]
    // `:` becomes `__`, everything else becomes `_`
    let mut result = String::with_capacity(name.len());
    for ch in name.chars() {
        match ch {
            ':' => result.push_str("__"),
            'a'..='z' | 'A'..='Z' | '0'..='9' | '_' | '-' => result.push(ch),
            _ => result.push('_'),
        }
    }
    // Gemini requires names start with letter or underscore
    if result.starts_with(|c: char| c.is_ascii_digit() || c == '-') {
        result.insert_str(0, "t_");
    }
    // OpenAI limits tool names to 64 characters
    if result.len() > 64 {
        result.truncate(64);
        // Clean up trailing separators from truncation
        while result.ends_with('_') && result.len() > 1 {
            result.pop();
        }
    }
    result
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
pub fn build_tool_definitions(visible_tools: Option<&[String]>, sub_agents: &[SubAgentDef]) -> Vec<Value> {
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
            // Always sanitize — ensures valid chars, length cap, starts with letter
            let safe_name = sanitize_tool_name(name);
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
            },
            "annotations": {
                "readOnlyHint": false,
                "destructiveHint": true,
                "actions": {
                    "read":   {"kind": "read"},
                    "list":   {"kind": "read"},
                    "write":  {"kind": "write"},
                    "delete": {"kind": "destructive"}
                }
            }
        }));
    }

    // Register sub-agents as virtual tools from harness-provided definitions
    for agent in sub_agents {
        if virtual_tool_allowed(visible_tools, &agent.name) {
            tools.push(json!({
                "name": agent.name,
                "description": agent.description,
                "input_schema": {
                    "type": "object",
                    "required": ["task"],
                    "properties": {
                        "task": {"type": "string", "description": format!("Task for the {} specialist. Be specific and include context.", agent.name)}
                    }
                }
            }));
        }
    }

    // No backward compat: sub-agents are exclusively harness-driven

    if virtual_tool_allowed(visible_tools, "request_setup") {
        tools.push(json!({
            "name": "request_setup",
            "description": "Open the setup form for a component that needs configuration (secrets, policy). The harness shows an inline form where the user fills in credentials securely. Use this after pulling a new component or when you get a setup_required error. Use the component_ref value from search/list results.",
            "input_schema": {
                "type": "object",
                "required": ["component_ref"],
                "properties": {
                    "action": {"type": "string", "enum": ["open"], "default": "open"},
                    "component_ref": {
                        "type": "string",
                        "description": "Component reference from search/list results, format type:publisher.name:version (e.g. catalyst:moonmoon69.airtable:0.1.0)"
                    }
                }
            },
            "annotations": {
                "readOnlyHint": false,
                "destructiveHint": false,
                "actions": {
                    "open": {"kind": "write"}
                }
            }
        }));
    }

    // Virtual `files` tool — multi-action wrapper around catalyst:local.files.
    // Action verbs are aligned with cyfr MCP convention; kinds are annotated
    // for AQUA's risk classification.
    if virtual_tool_allowed(visible_tools, "files") {
        tools.push(json!({
            "name": "files",
            "description": "Workspace file operations. Use action=read to view files (returns line-numbered content), write to create/overwrite, edit for line-based patches, search for glob filename matching, grep for content regex search, tree for directory listing, list as alias for tree, delete to remove a file.",
            "input_schema": {
                "type": "object",
                "required": ["action"],
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["read", "write", "edit", "search", "grep", "tree", "list", "delete"],
                        "description": "Operation to perform"
                    },
                    "path": {"type": "string", "description": "File or directory path (required for read/write/edit/grep/tree/list/delete)"},
                    "content": {"type": "string", "description": "File content (write action)"},
                    "start_line": {"type": "integer", "description": "1-based start line (read action, optional)"},
                    "end_line": {"type": "integer", "description": "Inclusive end line (read action, optional)"},
                    "edits": {
                        "type": "array",
                        "description": "List of edits to apply (edit action)",
                        "items": {
                            "type": "object",
                            "required": ["action", "start", "end", "content"],
                            "properties": {
                                "action": {"type": "string", "enum": ["replace", "insert", "delete"]},
                                "start": {"type": "integer"},
                                "end": {"type": "integer"},
                                "content": {"type": "string"}
                            }
                        }
                    },
                    "base_path": {"type": "string", "description": "Directory to search in (search action)"},
                    "pattern": {"type": "string", "description": "Glob (search) or regex (grep) pattern"},
                    "include": {"type": "string", "description": "File filter glob, e.g. '*.rs' (grep action)"},
                    "depth": {"type": "integer", "description": "Max depth (tree/list action, default 3)"}
                }
            },
            "annotations": {
                "readOnlyHint": false,
                "destructiveHint": true,
                "actions": {
                    "read":   {"kind": "read"},
                    "list":   {"kind": "read"},
                    "search": {"kind": "read"},
                    "grep":   {"kind": "read"},
                    "tree":   {"kind": "read"},
                    "write":  {"kind": "write"},
                    "edit":   {"kind": "write"},
                    "delete": {"kind": "destructive"}
                }
            }
        }));
    }

    // Virtual `http` tool — multi-action wrapper around catalyst:local.http.
    // Action verbs follow HTTP method semantics. The `read` action is a
    // markdown-readability shortcut (formerly `http_read`).
    if virtual_tool_allowed(visible_tools, "http") {
        tools.push(json!({
            "name": "http",
            "description": "Outbound HTTP. Use action=read to read a page as clean markdown (formerly http_read), or get/head/options/post/put/patch/delete for raw HTTP semantics. Works with localhost and external URLs.",
            "input_schema": {
                "type": "object",
                "required": ["action", "url"],
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["read", "get", "head", "options", "post", "put", "patch", "delete"],
                        "description": "HTTP method, or 'read' to fetch + extract markdown"
                    },
                    "url": {"type": "string", "description": "URL to fetch"},
                    "headers": {"type": "object", "description": "Custom HTTP headers"},
                    "body": {"type": "string", "description": "Request body (for post/put/patch)"}
                }
            },
            "annotations": {
                "readOnlyHint": false,
                "destructiveHint": true,
                "actions": {
                    "read":    {"kind": "read"},
                    "get":     {"kind": "read"},
                    "head":    {"kind": "read"},
                    "options": {"kind": "read"},
                    "put":     {"kind": "write"},
                    "patch":   {"kind": "write"},
                    "post":    {"kind": "execute"},
                    "delete":  {"kind": "destructive"}
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

pub fn dispatch_tool(
    tool_name: &str, tool_call_id: &str, args: &Value,
    catalyst_ref: &str, model: &str,
    sub_agents: &[SubAgentDef], _sub_agent_names: &HashSet<String>,
) -> String {
    // Unsanitize external tool names (LLM returns `server__tool`, we need `server:tool`)
    let real_name = unsanitize_tool_name(tool_name);
    let tool_name = real_name.as_str();

    // Check if this is a harness-provided sub-agent
    if let Some(def) = sub_agents.iter().find(|a| a.name == tool_name) {
        return dispatch_specialist_from_def(def, tool_call_id, args, catalyst_ref, model);
    }

    match tool_name {
        "storage" => dispatch_storage(args),
        "request_setup" => dispatch_request_setup(args),
        "files" => dispatch_files(args),
        "http" => dispatch_http(args),
        _ => dispatch_mcp_tool(tool_name, args),
    }
}

// ---------------------------------------------------------------------------
// Virtual tool: files — multi-action wrapper around catalyst:local.files
// ---------------------------------------------------------------------------

fn dispatch_files(args: &Value) -> String {
    let action = args.get("action").and_then(|v| v.as_str()).unwrap_or("");
    let mapped = match action {
        "read" => "read_lines",
        "write" => "write_text",
        "edit" => "edit",
        "search" => "search",
        "grep" => "grep",
        "tree" | "list" => "tree",
        "delete" => "delete",
        "" => return json!({"error": "Missing required 'action' field for tool 'files'"}).to_string(),
        other => return json!({"error": format!("Unknown files action: {}", other)}).to_string(),
    };
    dispatch_file_op(mapped, args)
}

// ---------------------------------------------------------------------------
// Virtual tool: http — multi-action wrapper around catalyst:local.http
// ---------------------------------------------------------------------------

fn dispatch_http(args: &Value) -> String {
    let action = args.get("action").and_then(|v| v.as_str()).unwrap_or("");
    match action {
        // 'read' fetches the URL and extracts clean markdown — same as
        // legacy http_read tool name.
        "read" => dispatch_http_op("read", args),
        // Standard HTTP method verbs: build a fetch request with the right
        // method. The underlying catalyst expects {operation, params}; we pass
        // the action as the method by enriching args before mapping.
        method @ ("get" | "head" | "options" | "post" | "put" | "patch" | "delete") => {
            let mut enriched = args.as_object().cloned().unwrap_or_default();
            enriched.insert("method".to_string(), json!(method.to_uppercase()));
            dispatch_http_op("fetch", &Value::Object(enriched))
        }
        "" => json!({"error": "Missing required 'action' field for tool 'http'"}).to_string(),
        other => json!({"error": format!("Unknown http action: {}", other)}).to_string(),
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
            json!({"action": "write_text", "path": path, "content": content})
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
        "tool": EXECUTION_TOOL,
        "action": "run",
        "args": {
            "reference": FILES_CATALYST,
            "input": files_input
        }
    });

    let response_str = invoke::call(&request.to_string());
    let response: Value = serde_json::from_str(&response_str).unwrap_or(json!({}));

    if let Some(output) = response.get("output") {
        truncate_result_for(&serde_json::to_string_pretty(output).unwrap_or_default())
    } else if let Some(err) = response.get("error") {
        format!("Error: {}", err)
    } else {
        truncate_result_for(&response_str)
    }
}

// ---------------------------------------------------------------------------
// Virtual tools: file operations — wraps catalyst:local.files
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Virtual tool: http_read / http_fetch — wrappers around catalyst:local.http
// ---------------------------------------------------------------------------

fn dispatch_http_op(operation: &str, args: &Value) -> String {
    let input = json!({"operation": operation, "params": args});
    let request = json!({
        "tool": EXECUTION_TOOL,
        "action": "run",
        "args": {"reference": HTTP_CATALYST, "input": input, "type": "catalyst"}
    });
    let response_str = invoke::call(&request.to_string());
    let response: Value = serde_json::from_str(&response_str).unwrap_or(json!({}));

    // Extract result from execution response
    if let Some(err) = response.get("error") {
        return format!("Error: {}", err);
    }

    let output = response.get("output").cloned().unwrap_or(Value::Null);
    let result = output.get("result").cloned().unwrap_or(output);

    // The catalyst returns a JSON string — parse and extract
    match &result {
        Value::String(s) => {
            if let Ok(parsed) = serde_json::from_str::<Value>(s) {
                truncate_result_for(&parsed.to_string())
            } else {
                truncate_result_for(s)
            }
        }
        _ => truncate_result_for(&result.to_string())
    }
}

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
        "tool": EXECUTION_TOOL,
        "action": "run",
        "args": {
            "reference": FILES_CATALYST,
            "input": files_input
        }
    });

    let response_str = invoke::call(&request.to_string());
    let response: Value = serde_json::from_str(&response_str).unwrap_or(json!({}));

    if let Some(output) = response.get("output") {
        truncate_result_for(&serde_json::to_string_pretty(output).unwrap_or_default())
    } else if let Some(err) = response.get("error") {
        format!("Error: {}", err)
    } else {
        truncate_result_for(&response_str)
    }
}

// ---------------------------------------------------------------------------
// Virtual tools: builder / explorer — spawn specialist sub-agents
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Sub-agent dispatch — harness-provided definitions (new path)
// ---------------------------------------------------------------------------

fn dispatch_specialist_from_def(
    def: &SubAgentDef, tool_call_id: &str, args: &Value,
    parent_catalyst: &str, parent_model: &str,
) -> String {
    let task = args.get("task").and_then(|v| v.as_str()).unwrap_or("");
    if task.is_empty() {
        return json!({"error": "Missing required 'task' field"}).to_string();
    }

    // Per-role model or inherit orchestrator's
    let catalyst = def.catalyst_ref.as_deref().unwrap_or(parent_catalyst);
    let model = def.model.as_deref().unwrap_or(parent_model);

    let emit_tag = format!("{}:{}", def.name, tool_call_id);
    let mut input = json!({
        "catalyst_ref": catalyst,
        "model": model,
        "task": task,
        "system": def.prompt,
        "role": def.name,
        "emit_tag": emit_tag
    });

    if let Some(vt) = &def.visible_tools {
        input["visible_tools"] = json!(vt);
    }

    // Sub-agents don't get sub_agents (no recursive nesting)
    let result = invoke::call(&json!({
        "tool": EXECUTION_TOOL,
        "action": "run",
        "args": {
            "reference": AQUA_FORMULA,
            "input": input
        }
    }).to_string());

    extract_specialist_content(&result, &def.name)
}

/// Build a spawn request for a sub-agent execution (parallel path).
/// Same as dispatch_specialist_from_def but returns the request JSON instead of calling it.
fn build_sub_agent_spawn_request(
    name: &str, tool_call_id: &str, args: &Value,
    parent_catalyst: &str, parent_model: &str,
    sub_agents: &[SubAgentDef],
) -> Value {
    let def = match sub_agents.iter().find(|d| d.name == name) {
        Some(d) => d,
        None => return json!({"tool": name, "action": "run", "args": {}}),
    };

    let task = args.get("task").and_then(|v| v.as_str()).unwrap_or("");
    let catalyst = def.catalyst_ref.as_deref().unwrap_or(parent_catalyst);
    let model = def.model.as_deref().unwrap_or(parent_model);
    let emit_tag = format!("{}:{}", def.name, tool_call_id);

    let mut input = json!({
        "catalyst_ref": catalyst,
        "model": model,
        "task": task,
        "system": def.prompt,
        "role": def.name,
        "emit_tag": emit_tag
    });

    if let Some(vt) = &def.visible_tools {
        input["visible_tools"] = json!(vt);
    }

    json!({
        "tool": EXECUTION_TOOL,
        "action": "run",
        "args": {
            "reference": AQUA_FORMULA,
            "input": input
        }
    })
}

/// Extract useful content from a sub-agent execution result.
fn extract_specialist_content(response_str: &str, role: &str) -> String {
    let response: Value = serde_json::from_str(response_str).unwrap_or(json!({}));

    // Check for top-level error
    if let Some(err) = response.get("error") {
        return format!("Error from {}: {}", role, err);
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
        return format!("Error from {}: {}", role, err);
    }

    // Extract the content field from the agent formula output
    if let Some(content) = result.get("content").and_then(|c| c.as_str()) {
        if !content.is_empty() {
            return truncate_result_for(content);
        }
    }

    // Fallback: return the full result
    truncate_result_for(&serde_json::to_string_pretty(&result).unwrap_or_default())
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
        truncate_result_for(&serde_json::to_string_pretty(output).unwrap_or_default())
    } else if let Some(err) = response.get("error") {
        format!("Error: {}", err)
    } else {
        truncate_result_for(&response_str)
    }
}

// ---------------------------------------------------------------------------
// Build a spawn request from tool name and args
// ---------------------------------------------------------------------------

fn build_spawn_request(tool_name: &str, args: &Value) -> Value {
    // File ops and storage: build as execution.run with catalyst:local.files
    match tool_name {
        "files" => {
            let action = args.get("action").and_then(|v| v.as_str()).unwrap_or("");
            let mapped = match action {
                "read" => "read_lines",
                "write" => "write_text",
                "edit" => "edit",
                "search" => "search",
                "grep" => "grep",
                "tree" | "list" => "tree",
                "delete" => "delete",
                _ => action,
            };
            build_files_spawn(mapped, args)
        }
        "storage" => build_storage_spawn(args),
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

/// Build a spawn request for file operations (wraps catalyst:local.files).
fn build_files_spawn(files_action: &str, args: &Value) -> Value {
    let files_input = match files_action {
        "read_lines" => {
            let mut input = json!({"action": "read_lines", "path": args.get("path").and_then(|v| v.as_str()).unwrap_or("")});
            if let Some(start) = args.get("start_line") { input["start_line"] = start.clone(); }
            if let Some(end) = args.get("end_line") { input["end_line"] = end.clone(); }
            input
        }
        "write_text" => json!({
            "action": "write_text",
            "path": args.get("path").and_then(|v| v.as_str()).unwrap_or(""),
            "content": args.get("content").and_then(|v| v.as_str()).unwrap_or("")
        }),
        "edit" => json!({
            "action": "edit",
            "path": args.get("path").and_then(|v| v.as_str()).unwrap_or(""),
            "edits": args.get("edits").cloned().unwrap_or(json!([]))
        }),
        "search" => json!({
            "action": "search",
            "base_path": args.get("base_path").and_then(|v| v.as_str()).unwrap_or("."),
            "pattern": args.get("pattern").and_then(|v| v.as_str()).unwrap_or("*")
        }),
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
            if let Some(depth) = args.get("depth") { input["depth"] = depth.clone(); }
            input
        }
        _ => json!({"action": files_action}),
    };
    json!({
        "tool": EXECUTION_TOOL,
        "action": "run",
        "args": {"reference": FILES_CATALYST, "input": files_input}
    })
}

/// Build a spawn request for storage operations (wraps catalyst:local.files).
fn build_storage_spawn(args: &Value) -> Value {
    let action = args.get("action").and_then(|v| v.as_str()).unwrap_or("");
    let key = args.get("key").and_then(|v| v.as_str()).unwrap_or("");
    let path = format!("data/storage/{}.json", key);

    let files_input = match action {
        "write" => {
            let value = args.get("value").cloned().unwrap_or(json!(null));
            let content = serde_json::to_string_pretty(&value).unwrap_or_default();
            json!({"action": "write_text", "path": path, "content": content})
        }
        "read" => json!({"action": "read_lines", "path": path}),
        "list" => {
            let list_path = if key.is_empty() { "data/storage".to_string() } else { format!("data/storage/{}", key) };
            json!({"action": "tree", "path": list_path, "depth": 2})
        }
        "delete" => json!({"action": "delete", "path": path}),
        _ => return json!({"tool": "storage", "action": "run", "args": args}),
    };
    json!({
        "tool": EXECUTION_TOOL,
        "action": "run",
        "args": {"reference": FILES_CATALYST, "input": files_input}
    })
}

// ---------------------------------------------------------------------------
// Parallel tool execution — all tool types
// ---------------------------------------------------------------------------

pub fn execute_tools_parallel(
    tool_calls: &[(String, String, Value)],
    catalyst_ref: &str,
    model: &str,
    sub_agents: &[SubAgentDef],
    sub_agent_names: &HashSet<String>,
) -> Vec<(String, String, String)> {
    // Single call: dispatch synchronously (avoid spawn overhead)
    if tool_calls.len() == 1 {
        let (id, name, args) = &tool_calls[0];
        let result = dispatch_tool(name, id, args, catalyst_ref, model, sub_agents, sub_agent_names);
        return vec![(id.clone(), name.clone(), result)];
    }

    // Only request_setup (UI event) needs synchronous dispatch.
    // Sub-agents, file ops, storage, MCP tools, and external tools all spawn for parallel execution.
    let mut sync_results: Vec<(usize, String, String, String)> = Vec::new();
    let mut spawn_requests: Vec<(usize, String, String, Value)> = Vec::new();
    let mut sub_agent_indices: HashMap<usize, String> = HashMap::new();

    for (i, (id, name, args)) in tool_calls.iter().enumerate() {
        let real_name = unsanitize_tool_name(name);
        if real_name == "request_setup" {
            // UI event: must be synchronous
            let result = dispatch_tool(name, id, args, catalyst_ref, model, sub_agents, sub_agent_names);
            sync_results.push((i, id.clone(), name.clone(), result));
        } else if sub_agent_names.contains(real_name.as_str()) {
            // Sub-agent: build spawn request for parallel execution
            let request = build_sub_agent_spawn_request(
                &real_name, id, args, catalyst_ref, model, sub_agents,
            );
            spawn_requests.push((i, id.clone(), name.clone(), request));
            sub_agent_indices.insert(i, real_name.clone());
        } else {
            // Regular tool: existing spawn path
            let request = build_spawn_request(&real_name, args);
            spawn_requests.push((i, id.clone(), real_name, request));
        }
    }

    // Spawn all tools (sub-agents + file ops + storage + MCP + external) in parallel
    let mut spawn_task_entries: Vec<(usize, String, String, String)> = Vec::new();

    for (idx, id, name, request) in &spawn_requests {
        let spawn_str = invoke::spawn(&request.to_string());
        let spawn: Value = serde_json::from_str(&spawn_str).unwrap_or(json!({}));
        let task_id = spawn.get("task_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        spawn_task_entries.push((*idx, id.clone(), name.clone(), task_id));
    }

    // Collect valid task IDs for await-all
    let valid_ids: Vec<&str> = spawn_task_entries.iter()
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

    // Add synchronous results (request_setup)
    all_results.extend(sync_results);

    // Add spawned tool results, post-processing sub-agent and external tool results
    for (idx, id, name, task_id) in &spawn_task_entries {
        let raw_result = if task_id.is_empty() {
            "Spawn failed".to_string()
        } else {
            result_map.get(task_id).cloned().unwrap_or("Spawn failed".to_string())
        };

        let result = if let Some(role) = sub_agent_indices.get(idx) {
            // Sub-agent result: extract the specialist content
            extract_specialist_content(&raw_result, role)
        } else if name.contains(':') && raw_result.starts_with("Error: ") {
            // External tool: enrich error with server name
            let server_name = name.split(':').next().unwrap_or(name);
            let error_detail = &raw_result["Error: ".len()..];
            format!("Error from external server '{}': {}", server_name, error_detail)
        } else {
            raw_result
        };

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
    let formatted = if let Some(data) = parsed.get("data") {
        serde_json::to_string_pretty(data).unwrap_or_else(|_| data.to_string())
    } else {
        serde_json::to_string_pretty(&parsed).unwrap_or_else(|_| parsed.to_string())
    };
    truncate_result_for(&formatted)
}

/// Truncate result to the configured limit, appending a truncation notice.
fn truncate_result_for(s: &str) -> String {
    if s.len() <= MAX_RESULT_BYTES {
        s.to_string()
    } else {
        let truncated = crate::truncate_str(s, MAX_RESULT_BYTES);
        format!("{}\n\n[... truncated, showing first {} of {} bytes]", truncated, truncated.len(), s.len())
    }
}
