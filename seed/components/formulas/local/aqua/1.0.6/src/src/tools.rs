use std::collections::{HashMap, HashSet};
use serde_json::{json, Value};

use crate::bindings::cyfr::formula::invoke;

const MAX_RESULT_BYTES: usize = 256_000;
const FILES_CATALYST: &str = "catalyst:local.files";
const HTTP_CATALYST: &str = "catalyst:local.http";
const AQUA_FORMULA: &str = "formula:local.aqua";
const EXECUTION_TOOL: &str = "execution";

const FILES_TOOL: &str = "files";
const STORAGE_TOOL: &str = "storage";
const HTTP_TOOL: &str = "http";
const REQUEST_SETUP_TOOL: &str = "request_setup";

// ---------------------------------------------------------------------------
// Role definition — provided by the harness via input
// ---------------------------------------------------------------------------

/// A role the soul can clone into. The harness sends one per role in the
/// roster (the `sub_agents` input); each becomes a virtual tool named after
/// the role that takes a single `task`.
pub struct SubAgentDef {
    pub name: String,
    pub description: String,
    pub prompt: String,
    /// The role's own tool allowlist (same shape as the soul's `tool_policy`):
    /// `{"tool.action" | "tool.*" => "ask" | "auto"}`. Passed straight through
    /// when the formula re-invokes itself as this role, so the role's tool
    /// surface is filtered identically. Absent means an empty allowlist — the
    /// role gets no tools.
    pub tool_policy: Option<Value>,
    pub catalyst_ref: Option<String>,
    pub model: Option<String>,
}

impl SubAgentDef {
    pub fn from_value(v: &Value) -> Option<Self> {
        Some(SubAgentDef {
            name: v.get("name")?.as_str()?.to_string(),
            description: v.get("description").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            prompt: v.get("prompt").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            tool_policy: v.get("tool_policy").filter(|p| p.is_object()).cloned(),
            catalyst_ref: v.get("catalyst_ref").and_then(|v| v.as_str()).map(String::from),
            model: v.get("model").and_then(|v| v.as_str()).map(String::from),
        })
    }
}

// ---------------------------------------------------------------------------
// Tool allowlist (`tool_policy`) — auto = directly callable, anything else = approval
// ---------------------------------------------------------------------------
//
// `tool_policy` is a JSON object the harness passes in: keys are `"tool.action"`
// or `"tool.*"` (glob over all of a tool's actions), values are `"ask"` or
// `"auto"`. A role — a tool with no actions, named after the role — is keyed
// by its bare name or `"name.*"`.
//
//   - not in the allowlist  -> the model never sees this action
//   - value == "auto"       -> directly callable
//   - anything else         -> withheld from the model's schema; the soul must
//                              request it via `ui.request_approval`
//
// Only the literal `"auto"` grants a direct call: a read is no exception, and
// an unrecognised value is treated as `"ask"`. `"deny"` is the host's
// composition of a person's standing "never": kept as an exact key so no
// `tool.*` glob can answer for the pair, and reported as unavailable — never
// as something to request approval for. External tools (`server:tool`) are
// never directly callable. `tool_policy` is the only tool surface: an absent
// policy means an empty allowlist, so the model sees no tools at all.

/// Look up the policy value for `tool.action` — the bare `tool` when the tool
/// has no actions — falling back to a `tool.*` glob.
fn policy_value<'a>(policy: &'a Value, tool: &str, action: &str) -> Option<&'a str> {
    let obj = policy.as_object()?;
    let exact = if action.is_empty() { tool.to_string() } else { format!("{tool}.{action}") };
    obj.get(&exact)
        .or_else(|| obj.get(&format!("{tool}.*")))
        .and_then(|v| v.as_str())
}

/// Whether the model may call `tool.action` directly under `policy`.
fn directly_callable(policy: &Value, tool: &str, action: &str) -> bool {
    !tool.contains(':') && policy_value(policy, tool, action) == Some("auto")
}

/// Return a copy of `input_schema` whose `properties.action.enum` is filtered
/// to the directly-callable actions under `policy`, or `None` when no action is
/// directly callable (the whole tool is then withheld from the model). A schema
/// with no `action` enum — a role's — is kept iff the policy grants the tool
/// itself.
fn filter_schema_by_policy(tool: &str, input_schema: &Value, policy: &Value) -> Option<Value> {
    let verbs = input_schema
        .get("properties")
        .and_then(|p| p.get("action"))
        .and_then(|a| a.get("enum"))
        .and_then(|e| e.as_array());

    let Some(verbs) = verbs else {
        return directly_callable(policy, tool, "").then(|| input_schema.clone());
    };

    let kept: Vec<Value> = verbs
        .iter()
        .filter(|v| v.as_str().map_or(false, |verb| directly_callable(policy, tool, verb)))
        .cloned()
        .collect();

    if kept.is_empty() {
        return None;
    }

    let mut schema = input_schema.clone();
    if let Some(action_prop) = schema
        .get_mut("properties")
        .and_then(|p| p.get_mut("action"))
        .and_then(|a| a.as_object_mut())
    {
        action_prop.insert("enum".to_string(), Value::Array(kept));
    }
    Some(schema)
}

// ---------------------------------------------------------------------------
// Tool name sanitization
// ---------------------------------------------------------------------------
// LLM APIs (Claude, OpenAI, Gemini) require tool names matching ^[a-zA-Z0-9_-]+$
// External tools use `server:tool` format which contains `:`. The model sees
// the sanitized name; `PolicyGuard` maps it back on dispatch.

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

    // Response format: {"status": "completed", "output": {"tools": [...]}}
    let tools = response
        .get("output")
        .and_then(|o| o.get("tools"))
        .and_then(|t| t.as_array())
        .cloned()
        .unwrap_or_default();

    tools
        .into_iter()
        .filter(|t| t.get("name").and_then(|v| v.as_str()) != Some("tools"))
        .collect()
}

// ---------------------------------------------------------------------------
// Tool definitions — MCP tools + virtual tools
// ---------------------------------------------------------------------------

/// Build canonical tool definitions (name, description, input_schema) under
/// the names the host knows. No filtering happens here: `apply_tool_policy`
/// is the single place the tool surface narrows, so nothing can bypass the
/// allowlist.
pub fn build_tool_definitions(sub_agents: &[SubAgentDef]) -> Vec<Value> {
    let mut tools: Vec<Value> = discover_mcp_tools()
        .iter()
        .filter_map(|t| {
            let name = t.get("name").and_then(|v| v.as_str()).unwrap_or("");
            if name.is_empty() {
                return None;
            }
            Some(json!({
                "name": name,
                "description": t.get("description").and_then(|v| v.as_str()).unwrap_or(""),
                "input_schema": t.get("inputSchema").cloned().unwrap_or(json!({"type": "object"}))
            }))
        })
        .collect();
    tools.extend(virtual_tool_definitions(sub_agents));
    tools
}

/// The virtual tools this formula answers itself: `storage`, `files` and
/// `http` (wrappers around the local catalysts), `request_setup` (a UI
/// event) and one tool per role in the roster.
fn virtual_tool_definitions(sub_agents: &[SubAgentDef]) -> Vec<Value> {
    let mut tools: Vec<Value> = Vec::new();

    tools.push(json!({
        "name": STORAGE_TOOL,
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

    // One virtual tool per role: the soul clones into it with a single task.
    for role in sub_agents {
        tools.push(json!({
            "name": role.name,
            "description": role.description,
            "input_schema": {
                "type": "object",
                "required": ["task"],
                "properties": {
                    "task": {"type": "string", "description": format!("Task for the {} role. Be specific and include context.", role.name)}
                }
            }
        }));
    }

    tools.push(json!({
        "name": REQUEST_SETUP_TOOL,
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
        }
    }));

    // Multi-action wrapper around catalyst:local.files. Action verbs are
    // aligned with the cyfr MCP convention.
    tools.push(json!({
        "name": FILES_TOOL,
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
        }
    }));

    // Multi-action wrapper around catalyst:local.http. `read`, `links` and
    // `metadata` extract from a fetched page; `head` asks for a URL's headers
    // alone; the other verbs follow HTTP method semantics.
    tools.push(json!({
        "name": HTTP_TOOL,
        "description": "Outbound HTTP. Use action=read to read a page as clean markdown, links to list the links on a page, metadata for a page's title, description and metadata, head for a URL's content type and size without its body, or get/options/post/put/patch/delete for raw HTTP semantics. Works with localhost and external URLs.",
        "input_schema": {
            "type": "object",
            "required": ["action", "url"],
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["read", "links", "metadata", "get", "head", "options", "post", "put", "patch", "delete"],
                    "description": "'read' fetches a page as markdown, 'links' the links on a page, 'metadata' a page's title, description and metadata; the rest are HTTP methods"
                },
                "url": {"type": "string", "description": "URL to fetch"},
                "headers": {"type": "object", "description": "Custom HTTP headers"},
                "body": {"type": "string", "description": "Request body (for post/put/patch)"},
                "max": {"type": "integer", "description": "Most links to return (links action, default 500)"}
            }
        }
    }));

    tools
}

/// Apply a `tool_policy` allowlist to the canonical tool definitions and
/// produce the model-facing surface.
///
/// Each tool's `action` enum is filtered to its `"auto"` verbs; a tool left
/// with no callable action is dropped from the model's surface entirely (the
/// soul reaches its `ask` actions via the approval prelude instead). Roles and
/// `request_setup` go through the same filter — a role stays only when the
/// policy grants its name. External tools are always dropped. Names are
/// sanitized for the provider APIs here, at the model boundary.
pub fn apply_tool_policy(tools: Vec<Value>, policy: &Value) -> Vec<Value> {
    tools
        .into_iter()
        .filter_map(|t| {
            let name = t.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let input_schema = t.get("input_schema").cloned().unwrap_or(json!({"type": "object"}));
            filter_schema_by_policy(name, &input_schema, policy).map(|schema| {
                json!({
                    "name": sanitize_tool_name(name),
                    "description": t.get("description").cloned().unwrap_or(json!("")),
                    "input_schema": schema
                })
            })
        })
        .collect()
}

/// The per-call gate on the dispatch path. Resolves the name the model used
/// back to the tool the host knows, then re-checks that the call is directly
/// callable under the policy. The model's `action` enum is already filtered,
/// so this normally passes everything — it defends against a model that
/// ignores the schema.
pub struct PolicyGuard {
    policy: Value,
    /// Sanitized name -> real name, for every tool whose name had to be
    /// rewritten for the provider APIs (external `server:tool` names). Any
    /// other name is used verbatim, so a role or virtual tool whose name
    /// happens to contain `__` is never mistaken for an external tool.
    names: HashMap<String, String>,
    /// The roles in this run's roster.
    roles: HashSet<String>,
}

impl PolicyGuard {
    /// Build from the policy map, the pre-policy tool definitions (their
    /// names are the real ones) and the roster. `policy` must be a JSON object.
    pub fn new(policy: &Value, tools: &[Value], sub_agents: &[SubAgentDef]) -> Self {
        let names = tools
            .iter()
            .filter_map(|t| t.get("name").and_then(|v| v.as_str()))
            .filter_map(|real| {
                let sanitized = sanitize_tool_name(real);
                (sanitized != real).then(|| (sanitized, real.to_string()))
            })
            .collect();
        let roles = sub_agents.iter().map(|d| d.name.clone()).collect();
        PolicyGuard { policy: policy.clone(), names, roles }
    }

    /// The tool the host knows by the name the model used.
    pub fn real_name(&self, model_name: &str) -> String {
        self.names
            .get(model_name)
            .cloned()
            .unwrap_or_else(|| model_name.to_string())
    }

    /// Whether the model may dispatch this call directly: `Ok(())`, or
    /// `Err(reason)` — a message to feed back to the model. A role carries
    /// no action; the policy must grant its name.
    pub fn admit(&self, real_tool: &str, args: &Value) -> Result<(), String> {
        if self.roles.contains(real_tool) {
            return self.check(real_tool, "");
        }
        let action = requested_action(real_tool, args);
        // An empty action never reaches the host: the dispatch table reports
        // it as a missing field, which is the more useful message.
        if action.is_empty() {
            return Ok(());
        }
        // Wrappers are aliases: the policy is asked about the canonical
        // operation, whichever tool spelled it. An `execution.run` of a
        // wrapped catalyst is the virtual action its input denotes; the
        // assistant itself is never a tool the model may run; a `files`
        // call inside `data/storage/` is the storage operation.
        if real_tool == EXECUTION_TOOL && (action == "run" || action == "run_stream") {
            let reference = str_arg(args, "reference", "");
            if is_self_reference(reference) {
                return Err("the assistant itself is not a tool you can run — clone a role instead".to_string());
            }
            let input = args.get("input").cloned().unwrap_or(json!({}));
            match canonical_virtual(reference, &input) {
                Canonical::NotVirtual => {}
                Canonical::Unknown => {
                    return Err(format!(
                        "execution of {reference} names no operation you have — call the files, storage or http tool itself"
                    ))
                }
                Canonical::Ops(candidates) => return self.check_all(&candidates),
            }
        }
        if real_tool == FILES_TOOL {
            match canonical_files(&action, args) {
                Ok(Some((tool, op))) => return self.check(&tool, &op),
                Ok(None) => {}
                Err(reason) => return Err(reason),
            }
        }
        self.check(real_tool, &action)
    }

    /// Every operation a request could be must be directly callable — a
    /// `tree` request is `files.tree` and `files.list` alike, and a policy
    /// that answers them differently has not granted the request.
    fn check_all(&self, candidates: &[(String, String)]) -> Result<(), String> {
        for (tool, action) in candidates {
            self.check(tool, action)?;
        }
        Ok(())
    }

    fn check(&self, real_tool: &str, action: &str) -> Result<(), String> {
        if directly_callable(&self.policy, real_tool, action) {
            return Ok(());
        }
        let call = if action.is_empty() { real_tool.to_string() } else { format!("{real_tool}.{action}") };
        let value = policy_value(&self.policy, real_tool, action);
        if value == Some("deny") {
            return Err(format!("'{call}' is unavailable — a person declined it; do not request approval for it."));
        }
        // A role cannot be proposed for approval — it is granted or it is not.
        let askable = !self.roles.contains(real_tool)
            && (value.is_some() || real_tool.contains(':'));
        if askable {
            Err(format!(
                "'{call}' requires approval — do not call it directly. End your reply with a `ui.request_approval` block whose `proposal` is {{\"tool\":\"{real_tool}\",\"action\":\"{action}\",\"args\":{{...}}}}; the user's decision arrives as the next turn."
            ))
        } else {
            Err(format!("'{call}' is not in your tool allowlist; you cannot perform it."))
        }
    }
}

// ---------------------------------------------------------------------------
// Canonical operations — what a request IS, whichever tool spelled it
// ---------------------------------------------------------------------------
//
// The host keeps the same table (`Aqua.VirtualTools`); `virtual_tools.json`
// beside this file is the fixture both sides run.

const STORAGE_ROOT: &str = "data/storage";
const STORAGE_PREFIX: &str = "data/storage/";

/// A component reference at name level — `type:ns.name`, the version dropped.
fn name_level(reference: &str) -> String {
    reference.splitn(3, ':').take(2).collect::<Vec<_>>().join(":")
}

fn is_self_reference(reference: &str) -> bool {
    !reference.is_empty() && name_level(reference) == AQUA_FORMULA
}

fn is_storage_path(path: &str) -> bool {
    path == STORAGE_ROOT || path.starts_with(STORAGE_PREFIX)
}

pub enum Canonical {
    /// Not a wrapped catalyst at all.
    NotVirtual,
    /// A wrapped catalyst, but an input no virtual action builds.
    Unknown,
    /// The virtual `(tool, action)`s the request could be, canonical first.
    Ops(Vec<(String, String)>),
}

/// The canonical virtual operations an `execution.run` of `reference` with
/// `input` denotes.
pub fn canonical_virtual(reference: &str, input: &Value) -> Canonical {
    let name = name_level(reference);
    if name == FILES_CATALYST {
        canonical_files_input(input)
    } else if name == HTTP_CATALYST {
        canonical_http_input(input)
    } else {
        Canonical::NotVirtual
    }
}

fn op(tool: &str, action: &str) -> (String, String) {
    (tool.to_string(), action.to_string())
}

fn canonical_files_input(input: &Value) -> Canonical {
    let action = str_arg(input, "action", "");
    let path = str_arg(input, if action == "search" { "base_path" } else { "path" }, "");
    if is_storage_path(path) {
        return match action {
            "read_lines" => Canonical::Ops(vec![op(STORAGE_TOOL, "read")]),
            "write_text" => Canonical::Ops(vec![op(STORAGE_TOOL, "write")]),
            "tree" => Canonical::Ops(vec![op(STORAGE_TOOL, "list")]),
            "delete" => Canonical::Ops(vec![op(STORAGE_TOOL, "delete")]),
            _ => Canonical::Unknown,
        };
    }
    match action {
        "read_lines" => Canonical::Ops(vec![op(FILES_TOOL, "read")]),
        "write_text" => Canonical::Ops(vec![op(FILES_TOOL, "write")]),
        "edit" => Canonical::Ops(vec![op(FILES_TOOL, "edit")]),
        "search" => Canonical::Ops(vec![op(FILES_TOOL, "search")]),
        "grep" => Canonical::Ops(vec![op(FILES_TOOL, "grep")]),
        "tree" => Canonical::Ops(vec![op(FILES_TOOL, "tree"), op(FILES_TOOL, "list")]),
        "delete" => Canonical::Ops(vec![op(FILES_TOOL, "delete")]),
        _ => Canonical::Unknown,
    }
}

fn canonical_http_input(input: &Value) -> Canonical {
    let operation = str_arg(input, "operation", "");
    match operation {
        "read" | "links" | "metadata" | "head" => Canonical::Ops(vec![op(HTTP_TOOL, operation)]),
        "fetch" => {
            let method = input
                .get("params")
                .and_then(|p| p.get("method"))
                .and_then(|m| m.as_str())
                .unwrap_or("get")
                .to_ascii_lowercase();
            match method.as_str() {
                "get" | "options" | "post" | "put" | "patch" | "delete" => {
                    Canonical::Ops(vec![op(HTTP_TOOL, &method)])
                }
                _ => Canonical::Unknown,
            }
        }
        _ => Canonical::Unknown,
    }
}

/// The canonical operation of a direct `files` call: `Some((storage, op))`
/// when its path lands in the storage boundary, `None` for a files
/// operation outside it, `Err` for one the boundary has no equivalent of.
fn canonical_files(action: &str, args: &Value) -> Result<Option<(String, String)>, String> {
    let path = str_arg(args, if action == "search" { "base_path" } else { "path" }, "");
    if !is_storage_path(path) {
        return Ok(None);
    }
    match action {
        "read" => Ok(Some(op(STORAGE_TOOL, "read"))),
        "write" => Ok(Some(op(STORAGE_TOOL, "write"))),
        "delete" => Ok(Some(op(STORAGE_TOOL, "delete"))),
        "tree" | "list" => Ok(Some(op(STORAGE_TOOL, "list"))),
        other => Err(format!(
            "files.{other} inside data/storage/ is not a storage operation — use the storage tool"
        )),
    }
}

// ---------------------------------------------------------------------------
// The dispatch table — one request builder for the sync and spawn paths
// ---------------------------------------------------------------------------

/// The action a call names, as the policy and the dispatch table see it:
/// external tools always take the synthetic `call`, `request_setup` has only
/// `open` (its schema default), everything else says which of its actions it
/// wants. Roles carry no action.
fn requested_action(tool: &str, args: &Value) -> String {
    if tool.contains(':') {
        return "call".to_string();
    }
    match args.get("action").and_then(|v| v.as_str()) {
        Some(action) if !action.is_empty() => action.to_string(),
        _ if tool == REQUEST_SETUP_TOOL => "open".to_string(),
        _ => String::new(),
    }
}

/// `args` with the `action` key removed — what an MCP tool receives.
fn args_without_action(args: &Value) -> Value {
    match args.as_object() {
        Some(obj) => Value::Object(
            obj.iter()
                .filter(|(k, _)| k.as_str() != "action")
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
        ),
        None => json!({}),
    }
}

fn str_arg<'a>(args: &'a Value, key: &str, default: &'a str) -> &'a str {
    args.get(key).and_then(|v| v.as_str()).unwrap_or(default)
}

/// Copy `args[key]` into `input` when the model supplied it.
fn copy_arg(input: &mut Value, args: &Value, key: &str) {
    if let Some(v) = args.get(key) {
        input[key] = v.clone();
    }
}

/// Catalyst input for one `files` action.
fn files_input(action: &str, args: &Value) -> Result<Value, String> {
    let input = match action {
        "read" => {
            let mut input = json!({"action": "read_lines", "path": str_arg(args, "path", "")});
            copy_arg(&mut input, args, "start_line");
            copy_arg(&mut input, args, "end_line");
            input
        }
        "write" => json!({
            "action": "write_text",
            "path": str_arg(args, "path", ""),
            "content": str_arg(args, "content", "")
        }),
        "edit" => json!({
            "action": "edit",
            "path": str_arg(args, "path", ""),
            "edits": args.get("edits").cloned().unwrap_or(json!([]))
        }),
        "search" => json!({
            "action": "search",
            "base_path": str_arg(args, "base_path", "."),
            "pattern": str_arg(args, "pattern", "*")
        }),
        "grep" => {
            let mut input = json!({
                "action": "grep",
                "path": str_arg(args, "path", "."),
                "pattern": str_arg(args, "pattern", "")
            });
            if let Some(include) = args.get("include").and_then(|v| v.as_str()) {
                input["include"] = json!(include);
            }
            input
        }
        "tree" | "list" => {
            let mut input = json!({"action": "tree", "path": str_arg(args, "path", ".")});
            copy_arg(&mut input, args, "depth");
            input
        }
        "delete" => json!({"action": "delete", "path": str_arg(args, "path", "")}),
        other => return Err(format!("Unknown files action: {other}")),
    };
    Ok(input)
}

/// Catalyst input for one `storage` action — a key is a JSON file under
/// `data/storage/`.
fn storage_input(action: &str, args: &Value) -> Result<Value, String> {
    let key = str_arg(args, "key", "");
    let path = format!("data/storage/{key}.json");
    let input = match action {
        "write" => {
            let value = args.get("value").cloned().unwrap_or(Value::Null);
            let content = serde_json::to_string_pretty(&value).unwrap_or_default();
            json!({"action": "write_text", "path": path, "content": content})
        }
        "read" => json!({"action": "read_lines", "path": path}),
        "list" => {
            let list_path = if key.is_empty() { "data/storage".to_string() } else { format!("data/storage/{key}") };
            json!({"action": "tree", "path": list_path, "depth": 2})
        }
        "delete" => json!({"action": "delete", "path": path}),
        other => return Err(format!("Unknown storage action: {other}")),
    };
    Ok(input)
}

/// Catalyst input for one `http` action: `read`, `links`, `metadata` and
/// `head` are the catalyst's own operations of those names; any other
/// method verb becomes a `fetch` with that method.
fn http_input(action: &str, args: &Value) -> Result<Value, String> {
    // The model's `action` is the wrapper's, not the catalyst's: the params
    // carry everything else the model said.
    let params = args_without_action(args);
    match action {
        "read" | "links" | "metadata" | "head" => Ok(json!({"operation": action, "params": params})),
        "get" | "options" | "post" | "put" | "patch" | "delete" => {
            let mut params = params.as_object().cloned().unwrap_or_default();
            params.insert("method".to_string(), json!(action.to_uppercase()));
            Ok(json!({"operation": "fetch", "params": Value::Object(params)}))
        }
        other => Err(format!("Unknown http action: {other}")),
    }
}

/// An `execution.run` of a local catalyst.
fn catalyst_run(reference: &str, input: Value) -> Value {
    json!({
        "tool": EXECUTION_TOOL,
        "action": "run",
        "args": {"reference": reference, "input": input, "type": "catalyst"}
    })
}

/// The host request for one tool call — the same table whether the loop
/// runs the call on its own or spawns it beside others. Roles have their own
/// builder (`role_request`) and `request_setup` is a UI event, not a request.
fn tool_request(tool: &str, args: &Value) -> Result<Value, String> {
    let action = requested_action(tool, args);
    if tool.contains(':') {
        // An external `server:tool` is never directly callable
        // (`directly_callable`), so this request is built only for a call
        // the guard admitted by mistake — kept as the one shape the host
        // would accept, with the synthetic `call` it strips before
        // forwarding, rather than a second error vocabulary.
        return Ok(json!({"tool": tool, "action": action, "args": args_without_action(args)}));
    }
    if action.is_empty() {
        return Err(format!("Missing required 'action' field for tool '{tool}'"));
    }
    let request = match tool {
        FILES_TOOL => catalyst_run(FILES_CATALYST, files_input(&action, args)?),
        STORAGE_TOOL => catalyst_run(FILES_CATALYST, storage_input(&action, args)?),
        HTTP_TOOL => catalyst_run(HTTP_CATALYST, http_input(&action, args)?),
        _ => json!({"tool": tool, "action": action, "args": args_without_action(args)}),
    };
    Ok(request)
}

/// The host request that clones the soul into `def` for one task.
fn role_request(
    def: &SubAgentDef, tool_call_id: &str, args: &Value,
    parent_catalyst: &str, parent_model: &str,
) -> Result<Value, String> {
    let task = str_arg(args, "task", "");
    if task.is_empty() {
        return Err("Missing required 'task' field".to_string());
    }

    // The role's own model, or the soul's.
    let catalyst = def.catalyst_ref.as_deref().unwrap_or(parent_catalyst);
    let model = def.model.as_deref().unwrap_or(parent_model);

    let input = json!({
        "catalyst_ref": catalyst,
        "model": model,
        "task": task,
        "system": def.prompt,
        "role": def.name,
        "emit_tag": format!("{}:{}", def.name, tool_call_id),
        // Always attach the policy: absent means an empty allowlist, and an
        // explicit {} keeps the role fail-closed instead of falling back.
        "tool_policy": def.tool_policy.clone().unwrap_or_else(|| json!({}))
    });

    // A role gets no roster of its own — cloning does not nest.
    Ok(json!({
        "tool": EXECUTION_TOOL,
        "action": "run",
        "args": {"reference": AQUA_FORMULA, "input": input}
    }))
}

// ---------------------------------------------------------------------------
// Response rendering — what the model reads back
// ---------------------------------------------------------------------------

/// The component's own result inside an `execution.run` response — parsed
/// when the component returned a JSON string. `Err` carries the host's or
/// the component's error.
fn execution_result(response: &Value) -> Result<Value, Value> {
    if let Some(err) = response.get("error") {
        return Err(err.clone());
    }
    if let Some(status) = response.get("status").and_then(|s| s.as_str()) {
        if status != "completed" {
            return Err(json!(format!("task {status}")));
        }
    }
    let output = response.get("output").cloned().unwrap_or(Value::Null);
    let result = output.get("result").cloned().unwrap_or(output);
    let result = match result {
        Value::String(s) => serde_json::from_str(&s).unwrap_or(Value::String(s)),
        other => other,
    };
    match result.get("error") {
        Some(err) => Err(err.clone()),
        None => Ok(result),
    }
}

/// Render a host response — an `invoke::call` reply or one `await_all`
/// entry; both carry `{status, output}` or `{status: "error", error}` — for
/// a tool other than a role.
fn render_response(tool: &str, response: &Value) -> String {
    let text = match tool {
        FILES_TOOL | STORAGE_TOOL | HTTP_TOOL => catalyst_output(response),
        _ => mcp_output(response),
    };
    with_server_name(tool, text)
}

/// A local catalyst's result, unwrapped from the `execution.run` envelope:
/// its `data` when it has one, a bare string as is, anything else as JSON.
fn catalyst_output(response: &Value) -> String {
    match execution_result(response) {
        Err(err) => format!("Error: {err}"),
        Ok(result) => {
            let shown = result.get("data").unwrap_or(&result);
            let text = match shown {
                Value::String(s) => s.clone(),
                other => serde_json::to_string_pretty(other).unwrap_or_default(),
            };
            truncate_result_for(&text)
        }
    }
}

/// A plain MCP tool's output, in full.
fn mcp_output(response: &Value) -> String {
    if let Some(err) = response.get("error") {
        return format!("Error: {err}");
    }
    match response.get("output") {
        Some(output) => truncate_result_for(&serde_json::to_string_pretty(output).unwrap_or_default()),
        None => truncate_result_for(&response.to_string()),
    }
}

/// Prefix an external tool's error with the server it came from.
fn with_server_name(tool: &str, result: String) -> String {
    if !tool.contains(':') {
        return result;
    }
    match result.strip_prefix("Error: ") {
        Some(detail) => {
            let server = tool.split(':').next().unwrap_or(tool);
            format!("Error from external server '{server}': {detail}")
        }
        None => result,
    }
}

/// What a role reports back: its final text, or the full result when it
/// produced none.
fn role_content(response: &Value, role: &str) -> String {
    match execution_result(response) {
        Err(err) => format!("Error from {role}: {err}"),
        Ok(result) => match result.get("content").and_then(|c| c.as_str()) {
            Some(content) if !content.is_empty() => truncate_result_for(content),
            _ => truncate_result_for(&serde_json::to_string_pretty(&result).unwrap_or_default()),
        },
    }
}

// ---------------------------------------------------------------------------
// Virtual tool: request_setup — emit setup event for harness UI
// ---------------------------------------------------------------------------

fn dispatch_request_setup(action: &str, args: &Value) -> String {
    if action != "open" {
        return json!({"error": format!("Unknown request_setup action: {action}")}).to_string();
    }
    let component_ref = str_arg(args, "component_ref", "");
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

    if let Some(err) = plan.get("error") {
        return format!("Error: component '{}' not found or setup_plan failed: {}", component_ref, err);
    }

    // The harness shows the inline setup form on this event.
    let _ = invoke::emit(&json!({
        "kind": "request_setup",
        "component_ref": component_ref
    }).to_string());

    format!("Setup form opened for {}. The user will fill in credentials and configuration there. Your task will be automatically re-sent once setup is complete.", component_ref)
}

// ---------------------------------------------------------------------------
// Tool execution — one call on this thread, several spawned side by side
// ---------------------------------------------------------------------------

/// Run one admitted call to completion on the calling thread.
fn dispatch_tool(
    real_name: &str, tool_call_id: &str, args: &Value,
    catalyst_ref: &str, model: &str, sub_agents: &[SubAgentDef],
) -> String {
    if let Some(def) = sub_agents.iter().find(|d| d.name == real_name) {
        return match role_request(def, tool_call_id, args, catalyst_ref, model) {
            Ok(request) => role_content(&call_host(&request), &def.name),
            Err(reason) => json!({"error": reason}).to_string(),
        };
    }
    if real_name == REQUEST_SETUP_TOOL {
        return dispatch_request_setup(&requested_action(real_name, args), args);
    }
    match tool_request(real_name, args) {
        Ok(request) => render_response(real_name, &call_host(&request)),
        Err(reason) => json!({"error": reason}).to_string(),
    }
}

fn call_host(request: &Value) -> Value {
    serde_json::from_str(&invoke::call(&request.to_string())).unwrap_or(json!({}))
}

/// Execute the model's tool calls. Each is `(tool_call_id, name as the
/// model issued it, args)`; the results keep the same ids and names, in
/// the model's own order — a refusal sits where its call was, since a
/// provider that pairs results by position (Gemini) would otherwise read
/// one call's answer as another's.
pub fn execute_tools_parallel(
    tool_calls: &[(String, String, Value)],
    catalyst_ref: &str,
    model: &str,
    sub_agents: &[SubAgentDef],
    guard: &PolicyGuard,
) -> Vec<(String, String, String)> {
    let mut results: Vec<Option<String>> = vec![None; tool_calls.len()];
    let mut allowed: Vec<(usize, String, String, String, Value)> = Vec::new();
    for (i, (id, name, args)) in tool_calls.iter().enumerate() {
        let real = guard.real_name(name);
        match guard.admit(&real, args) {
            Ok(()) => allowed.push((i, id.clone(), name.clone(), real, args.clone())),
            Err(reason) => results[i] = Some(json!({"error": reason}).to_string()),
        }
    }

    let ran: Vec<(usize, String)> = match allowed.as_slice() {
        [] => Vec::new(),
        // A lone call runs here — no spawn overhead.
        [(i, id, _name, real, args)] => vec![(*i, dispatch_tool(real, id, args, catalyst_ref, model, sub_agents))],
        _ => {
            let calls: Vec<(String, String, String, Value)> =
                allowed.iter().map(|(_, id, name, real, args)| (id.clone(), name.clone(), real.clone(), args.clone())).collect();
            spawn_tools(&calls, catalyst_ref, model, sub_agents)
                .into_iter()
                .zip(allowed.iter())
                .map(|((_, _, result), (i, _, _, _, _))| (*i, result))
                .collect()
        }
    };
    for (i, result) in ran {
        results[i] = Some(result);
    }

    tool_calls
        .iter()
        .zip(results)
        .map(|((id, name, _), result)| (id.clone(), name.clone(), result.unwrap_or_else(|| "Spawn failed".to_string())))
        .collect()
}

/// Run several admitted calls side by side: every request the table can
/// build is spawned, then awaited together; `request_setup` (a UI event)
/// and calls the table refuses are answered in place.
fn spawn_tools(
    calls: &[(String, String, String, Value)],
    catalyst_ref: &str,
    model: &str,
    sub_agents: &[SubAgentDef],
) -> Vec<(String, String, String)> {
    let mut results: Vec<Option<String>> = vec![None; calls.len()];
    let mut spawned: Vec<(usize, String)> = Vec::new();

    for (i, (id, _, real, args)) in calls.iter().enumerate() {
        let request = match sub_agents.iter().find(|d| d.name == *real) {
            Some(def) => role_request(def, id, args, catalyst_ref, model),
            None if real == REQUEST_SETUP_TOOL => {
                results[i] = Some(dispatch_request_setup(&requested_action(real, args), args));
                continue;
            }
            None => tool_request(real, args),
        };
        match request {
            Ok(request) => {
                let spawn: Value = serde_json::from_str(&invoke::spawn(&request.to_string())).unwrap_or(json!({}));
                match spawn.get("task_id").and_then(|v| v.as_str()) {
                    Some(task_id) if !task_id.is_empty() => spawned.push((i, task_id.to_string())),
                    _ => results[i] = Some(spawn_failure(&spawn)),
                }
            }
            Err(reason) => results[i] = Some(json!({"error": reason}).to_string()),
        }
    }

    let mut by_task: HashMap<String, Value> = HashMap::new();
    if !spawned.is_empty() {
        let task_ids: Vec<&str> = spawned.iter().map(|(_, t)| t.as_str()).collect();
        let awaited: Value = serde_json::from_str(&invoke::await_all(&json!({"task_ids": task_ids}).to_string()))
            .unwrap_or(json!({}));
        for r in awaited.get("results").and_then(|v| v.as_array()).into_iter().flatten() {
            if let Some(task_id) = r.get("task_id").and_then(|v| v.as_str()) {
                by_task.insert(task_id.to_string(), r.clone());
            }
        }
    }

    for (i, task_id) in &spawned {
        let real = &calls[*i].2;
        results[*i] = Some(match by_task.get(task_id) {
            Some(response) if sub_agents.iter().any(|d| d.name == *real) => role_content(response, real),
            Some(response) => render_response(real, response),
            None => "Spawn failed".to_string(),
        });
    }

    calls
        .iter()
        .zip(results)
        .map(|((id, name, _, _), result)| (id.clone(), name.clone(), result.unwrap_or_else(|| "Spawn failed".to_string())))
        .collect()
}

fn spawn_failure(spawn: &Value) -> String {
    match spawn.get("error") {
        Some(err) => format!("Error: {err}"),
        None => "Spawn failed".to_string(),
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Truncate result to the configured limit, appending a truncation notice.
fn truncate_result_for(s: &str) -> String {
    if s.len() <= MAX_RESULT_BYTES {
        s.to_string()
    } else {
        let truncated = crate::truncate_str(s, MAX_RESULT_BYTES);
        format!("{}\n\n[... truncated, showing first {} of {} bytes]", truncated, truncated.len(), s.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn role(name: &str) -> SubAgentDef {
        SubAgentDef::from_value(&json!({"name": name, "description": "d", "prompt": "p"})).unwrap()
    }

    /// The `action` enum a virtual tool offers the model.
    fn schema_actions(tool: &str) -> HashSet<String> {
        virtual_tool_definitions(&[])
            .iter()
            .find(|t| t["name"] == tool)
            .and_then(|t| t["input_schema"]["properties"]["action"]["enum"].as_array().cloned())
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect()
    }

    /// The actions the dispatch table turns into a host request.
    fn accepted_actions(tool: &str) -> HashSet<String> {
        let candidates = [
            "read", "write", "edit", "search", "grep", "tree", "list", "delete", "get", "head",
            "options", "post", "put", "patch", "links", "metadata", "read_lines", "write_text",
            "fetch", "run", "call", "open", "bogus",
        ];
        candidates
            .iter()
            .filter(|a| tool_request(tool, &json!({"action": a, "path": "p", "key": "k", "url": "u"})).is_ok())
            .map(|a| a.to_string())
            .collect()
    }

    #[test]
    fn dispatch_table_accepts_exactly_the_actions_the_model_is_offered() {
        // One table serves both the lone-call and the spawned path, so this
        // is the parity that matters: what the model may call is what runs.
        for tool in [FILES_TOOL, STORAGE_TOOL, HTTP_TOOL] {
            assert_eq!(accepted_actions(tool), schema_actions(tool), "{tool}");
        }
    }

    #[test]
    fn files_delete_carries_its_path() {
        let request = tool_request(FILES_TOOL, &json!({"action": "delete", "path": "notes/a.md"})).unwrap();
        assert_eq!(request["tool"], EXECUTION_TOOL);
        assert_eq!(request["args"]["reference"], FILES_CATALYST);
        assert_eq!(request["args"]["input"], json!({"action": "delete", "path": "notes/a.md"}));
    }

    #[test]
    fn http_runs_the_http_catalyst() {
        let request = tool_request(HTTP_TOOL, &json!({"action": "get", "url": "http://x"})).unwrap();
        assert_eq!(request["args"]["reference"], HTTP_CATALYST);
        assert_eq!(request["args"]["input"]["operation"], "fetch");
        assert_eq!(request["args"]["input"]["params"]["method"], "GET");
        assert_eq!(request["args"]["input"]["params"]["url"], "http://x");

        let read = tool_request(HTTP_TOOL, &json!({"action": "read", "url": "http://x"})).unwrap();
        assert_eq!(read["args"]["input"]["operation"], "read");
    }

    #[test]
    fn http_page_verbs_are_the_catalysts_own_operations() {
        // `links`, `metadata` and `head` each have an operation of their own
        // on the catalyst; routed through `fetch` they would lose the
        // extraction — or, for `head`, the top-level content type and size.
        for verb in ["links", "metadata", "head"] {
            let request = tool_request(HTTP_TOOL, &json!({"action": verb, "url": "http://x", "max": 3})).unwrap();
            assert_eq!(request["args"]["reference"], HTTP_CATALYST, "{verb}");
            assert_eq!(request["args"]["input"]["operation"], verb, "{verb}");
            assert_eq!(request["args"]["input"]["params"]["url"], "http://x", "{verb}");
            assert_eq!(request["args"]["input"]["params"]["max"], 3, "{verb}");
            assert!(request["args"]["input"]["params"].get("method").is_none(), "{verb}");
        }
    }

    #[test]
    fn unknown_and_missing_actions_are_typed_errors() {
        assert_eq!(tool_request(FILES_TOOL, &json!({"action": "bogus"})).unwrap_err(), "Unknown files action: bogus");
        assert_eq!(tool_request(STORAGE_TOOL, &json!({"action": "run"})).unwrap_err(), "Unknown storage action: run");
        assert_eq!(tool_request(HTTP_TOOL, &json!({"action": "fetch"})).unwrap_err(), "Unknown http action: fetch");
        assert_eq!(
            tool_request("component", &json!({"reference": "x"})).unwrap_err(),
            "Missing required 'action' field for tool 'component'"
        );
    }

    #[test]
    fn external_tools_take_the_synthetic_call() {
        let request = tool_request("srv:tool", &json!({"action": "ignored", "q": 1})).unwrap();
        assert_eq!(request, json!({"tool": "srv:tool", "action": "call", "args": {"q": 1}}));
    }

    #[test]
    fn mcp_tools_pass_their_arguments_through() {
        let request = tool_request("component", &json!({"action": "search", "query": "x"})).unwrap();
        assert_eq!(request, json!({"tool": "component", "action": "search", "args": {"query": "x"}}));
    }

    #[test]
    fn role_request_requires_a_task() {
        let def = role("aqua_explorer");
        assert_eq!(role_request(&def, "c1", &json!({}), "cat", "m").unwrap_err(), "Missing required 'task' field");
        assert_eq!(role_request(&def, "c1", &json!({"task": ""}), "cat", "m").unwrap_err(), "Missing required 'task' field");

        let request = role_request(&def, "c1", &json!({"task": "look"}), "cat", "m").unwrap();
        assert_eq!(request["args"]["reference"], AQUA_FORMULA);
        assert_eq!(request["args"]["input"]["task"], "look");
        assert_eq!(request["args"]["input"]["role"], "aqua_explorer");
        assert_eq!(request["args"]["input"]["emit_tag"], "aqua_explorer:c1");
        assert_eq!(request["args"]["input"]["tool_policy"], json!({}));
    }

    #[test]
    fn only_auto_is_directly_callable() {
        let policy = json!({
            "files.read": "ask", "files.grep": "never", "files.tree": "junk",
            "files.list": "auto", "notes.*": "auto", "srv:tool.*": "auto"
        });
        assert!(!directly_callable(&policy, "files", "read"));
        assert!(!directly_callable(&policy, "files", "grep"));
        assert!(!directly_callable(&policy, "files", "tree"));
        assert!(!directly_callable(&policy, "files", "search"));
        assert!(directly_callable(&policy, "files", "list"));
        assert!(directly_callable(&policy, "notes", "read"));
        assert!(!directly_callable(&policy, "srv:tool", "call"));
    }

    #[test]
    fn a_role_is_refused_unless_the_policy_grants_its_name() {
        let roster = [role("aqua_explorer"), role("aqua_planner"), role("aqua_web")];
        let policy = json!({"aqua_explorer.*": "auto", "aqua_web": "auto", "aqua_planner.*": "ask"});
        let guard = PolicyGuard::new(&policy, &virtual_tool_definitions(&roster), &roster);

        assert!(guard.admit("aqua_explorer", &json!({"task": "t"})).is_ok());
        assert!(guard.admit("aqua_web", &json!({"task": "t"})).is_ok());
        assert_eq!(
            guard.admit("aqua_planner", &json!({"task": "t"})).unwrap_err(),
            "'aqua_planner' is not in your tool allowlist; you cannot perform it."
        );

        let none = PolicyGuard::new(&json!({}), &virtual_tool_definitions(&roster), &roster);
        assert_eq!(
            none.admit("aqua_explorer", &json!({"task": "t"})).unwrap_err(),
            "'aqua_explorer' is not in your tool allowlist; you cannot perform it."
        );
    }

    #[test]
    fn guard_distinguishes_ask_from_absent() {
        let guard = PolicyGuard::new(&json!({"files.write": "ask"}), &virtual_tool_definitions(&[]), &[]);
        assert!(guard.admit("files", &json!({"action": "write"})).unwrap_err().contains("requires approval"));
        assert!(guard.admit("files", &json!({"action": "read"})).unwrap_err().contains("not in your tool allowlist"));
        assert!(guard.admit("srv:tool", &json!({})).unwrap_err().contains("requires approval"));
        // An empty action is left for the dispatch table to report.
        assert!(guard.admit("files", &json!({})).is_ok());
    }

    #[test]
    fn a_denied_pair_is_unavailable_never_askable() {
        // The host keeps a standing "never" as an exact `"deny"` so the glob
        // cannot answer for it; the guest neither offers the action nor
        // tells the model to ask for it.
        let policy = json!({"component.*": "auto", "component.pull": "deny"});
        let guard = PolicyGuard::new(&policy, &virtual_tool_definitions(&[]), &[]);
        assert!(!directly_callable(&policy, "component", "pull"));
        assert!(directly_callable(&policy, "component", "search"));
        let err = guard.admit("component", &json!({"action": "pull"})).unwrap_err();
        assert!(err.contains("unavailable"), "{err}");
        assert!(!err.contains("request_approval"), "{err}");

        let tools = vec![json!({
            "name": "component", "description": "",
            "input_schema": {"properties": {"action": {"enum": ["search", "pull"]}}}
        })];
        let component = apply_tool_policy(tools, &policy).remove(0);
        assert_eq!(component["input_schema"]["properties"]["action"]["enum"], json!(["search"]));
    }

    #[test]
    fn execution_of_a_wrapped_catalyst_is_judged_as_the_virtual_action() {
        let policy = json!({"execution.run": "auto", "files.delete": "ask", "files.read": "auto",
                            "files.tree": "auto", "files.list": "ask", "storage.delete": "deny"});
        let guard = PolicyGuard::new(&policy, &virtual_tool_definitions(&[]), &[]);
        let run = |reference: &str, input: Value| {
            guard.admit(EXECUTION_TOOL, &json!({"action": "run", "reference": reference, "input": input}))
        };
        // A delete spelled as execution.run is files.delete, at ask.
        let err = run(FILES_CATALYST, json!({"action": "delete", "path": "a.md"})).unwrap_err();
        assert!(err.contains("'files.delete' requires approval"), "{err}");
        // Versioned reference, storage boundary: storage.delete, denied.
        let err = run("catalyst:local.files:0.5.1", json!({"action": "delete", "path": "data/storage/k.json"})).unwrap_err();
        assert!(err.contains("'storage.delete' is unavailable"), "{err}");
        // A read the policy grants passes.
        assert!(run(FILES_CATALYST, json!({"action": "read_lines", "path": "a.md"})).is_ok());
        // An ambiguous request must be granted as every action it could be.
        let err = run(FILES_CATALYST, json!({"action": "tree", "path": "src"})).unwrap_err();
        assert!(err.contains("'files.list' requires approval"), "{err}");
        // An operation no virtual action builds is refused outright.
        let err = run(FILES_CATALYST, json!({"action": "bogus"})).unwrap_err();
        assert!(err.contains("names no operation"), "{err}");
        // Any other reference is the generic execution.run the policy grants.
        assert!(run("formula:local.other", json!({})).is_ok());
        // The assistant itself is never a tool.
        let err = run("formula:local.aqua:1.0.6", json!({"tool_policy": {"files.delete": "auto"}})).unwrap_err();
        assert!(err.contains("clone a role"), "{err}");
    }

    #[test]
    fn a_files_call_inside_the_storage_boundary_is_the_storage_operation() {
        let policy = json!({"files.*": "auto", "storage.read": "auto"});
        let guard = PolicyGuard::new(&policy, &virtual_tool_definitions(&[]), &[]);
        assert!(guard.admit(FILES_TOOL, &json!({"action": "read", "path": "data/storage/k.json"})).is_ok());
        let err = guard.admit(FILES_TOOL, &json!({"action": "delete", "path": "data/storage/k.json"})).unwrap_err();
        assert!(err.contains("'storage.delete' is not in your tool allowlist"), "{err}");
        let err = guard.admit(FILES_TOOL, &json!({"action": "grep", "path": "data/storage", "pattern": "x"})).unwrap_err();
        assert!(err.contains("not a storage operation"), "{err}");
        assert!(guard.admit(FILES_TOOL, &json!({"action": "delete", "path": "a.md"})).is_ok());
    }

    #[test]
    fn the_shared_fixture_holds_on_both_directions() {
        let fixture: Vec<Value> = serde_json::from_str(include_str!("virtual_tools.json")).unwrap();
        assert!(fixture.len() > 20);
        for case in &fixture {
            let canonical: Vec<String> = case["canonical"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
            let catalyst = case["catalyst"].as_str().unwrap();
            // Reverse: the catalyst input names exactly these virtual actions.
            let got: Vec<String> = match canonical_virtual(catalyst, &case["input"]) {
                Canonical::Ops(ops) => ops.iter().map(|(t, a)| format!("{t}.{a}")).collect(),
                _ => Vec::new(),
            };
            assert_eq!(got, canonical, "reverse of {}", case["input"]);
            if case["reverse_only"].as_bool().unwrap_or(false) {
                continue;
            }
            // Forward: the virtual call builds this catalyst request.
            let tool = case["tool"].as_str().unwrap();
            let mut args = case["args"].clone();
            args["action"] = json!(case["action"]);
            let request = tool_request(tool, &args).unwrap();
            assert_eq!(request["args"]["reference"], json!(catalyst), "{tool}.{}", case["action"]);
            assert_eq!(request["args"]["input"], case["input"], "{tool}.{}", case["action"]);
        }
    }

    #[test]
    fn results_keep_the_models_order_with_refusals_in_place() {
        let guard = PolicyGuard::new(&json!({}), &virtual_tool_definitions(&[]), &[]);
        let calls = vec![
            ("c1".to_string(), "files".to_string(), json!({"action": "read", "path": "a"})),
            ("c2".to_string(), "files".to_string(), json!({"action": "read", "path": "b"})),
        ];
        let out = execute_tools_parallel(&calls, "cat", "m", &[], &guard);
        assert_eq!(out.iter().map(|(id, _, _)| id.as_str()).collect::<Vec<_>>(), vec!["c1", "c2"]);
        assert!(out[0].2.contains("not in your tool allowlist"));
    }

    #[test]
    fn request_setup_defaults_to_open() {
        assert_eq!(requested_action(REQUEST_SETUP_TOOL, &json!({"component_ref": "x"})), "open");
        let guard = PolicyGuard::new(&json!({}), &virtual_tool_definitions(&[]), &[]);
        assert!(guard.admit(REQUEST_SETUP_TOOL, &json!({"component_ref": "x"})).is_err());
        let granted = PolicyGuard::new(&json!({"request_setup.open": "auto"}), &virtual_tool_definitions(&[]), &[]);
        assert!(granted.admit(REQUEST_SETUP_TOOL, &json!({"component_ref": "x"})).is_ok());
    }

    #[test]
    fn only_sanitized_external_names_map_back() {
        let roster = [role("x__y")];
        let mut tools = virtual_tool_definitions(&roster);
        tools.push(json!({"name": "srv:tool", "description": "", "input_schema": {}}));
        let guard = PolicyGuard::new(&json!({}), &tools, &roster);

        assert_eq!(guard.real_name("srv__tool"), "srv:tool");
        assert_eq!(guard.real_name("x__y"), "x__y");
        assert_eq!(guard.real_name("files"), "files");
        assert_eq!(guard.real_name("never__seen"), "never__seen");
    }

    #[test]
    fn apply_tool_policy_narrows_and_sanitizes() {
        let roster = [role("aqua_explorer"), role("aqua_planner")];
        let mut tools = virtual_tool_definitions(&roster);
        tools.push(json!({
            "name": "srv:tool", "description": "", "input_schema": {"type": "object"}
        }));
        tools.push(json!({
            "name": "component", "description": "",
            "input_schema": {"properties": {"action": {"enum": ["search", "pull"]}}}
        }));
        let policy = json!({
            "files.read": "auto", "files.write": "ask", "component.*": "ask",
            "component.search": "auto", "aqua_explorer.*": "auto", "srv:tool.*": "auto"
        });

        let surface = apply_tool_policy(tools, &policy);
        let names: Vec<&str> = surface.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, vec!["aqua_explorer", "files", "component"]);

        let files = surface.iter().find(|t| t["name"] == "files").unwrap();
        assert_eq!(files["input_schema"]["properties"]["action"]["enum"], json!(["read"]));
        let component = surface.iter().find(|t| t["name"] == "component").unwrap();
        assert_eq!(component["input_schema"]["properties"]["action"]["enum"], json!(["search"]));
    }

    #[test]
    fn catalyst_and_role_results_unwrap_the_execution_envelope() {
        let response = json!({"status": "completed", "output": {
            "execution_id": "e1", "result": "{\"data\": {\"lines\": [\"a\"]}}"
        }});
        assert_eq!(catalyst_output(&response), "{\n  \"lines\": [\n    \"a\"\n  ]\n}");

        let role_response = json!({"status": "completed", "output": {"result": {"content": "found it"}}});
        assert_eq!(role_content(&role_response, "aqua_explorer"), "found it");

        let failed = json!({"status": "error", "error": {"type": "timeout"}, "task_id": "t"});
        assert_eq!(role_content(&failed, "aqua_explorer"), "Error from aqua_explorer: {\"type\":\"timeout\"}");
        assert_eq!(
            with_server_name("srv:tool", mcp_output(&failed)),
            "Error from external server 'srv': {\"type\":\"timeout\"}"
        );
    }
}
