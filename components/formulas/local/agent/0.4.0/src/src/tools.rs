use serde_json::{json, Value};

use crate::bindings::cyfr::formula::invoke;
use crate::bindings::cyfr::mcp::tools;
use crate::providers::Provider;

const MAX_TOOL_RESULT_CHARS: usize = 32000;

// ---------------------------------------------------------------------------
// Tool definitions — exposed to the LLM
// ---------------------------------------------------------------------------

pub fn build_tool_definitions(provider: Provider) -> Value {
    let tools = vec![
        json!({
            "name": "read_file",
            "description": "Read the contents of a file. Returns text content with line numbers. For large files, use start_line/end_line to read specific sections.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "File path relative to project root" },
                    "start_line": { "type": "integer", "description": "Start line (1-indexed). Omit to read from beginning." },
                    "end_line": { "type": "integer", "description": "End line (1-indexed, inclusive). Omit to read to end." }
                },
                "required": ["path"]
            }
        }),
        json!({
            "name": "write_file",
            "description": "Create or overwrite a file with the given content.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "File path relative to project root" },
                    "content": { "type": "string", "description": "Full file content to write" }
                },
                "required": ["path", "content"]
            }
        }),
        json!({
            "name": "edit_file",
            "description": "Apply structured edits to a file. Each edit specifies an action (replace, insert, delete) and line range. Edits are applied in reverse order to preserve line numbers.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "File path relative to project root" },
                    "edits": {
                        "type": "array",
                        "description": "Array of edit operations",
                        "items": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "enum": ["replace", "insert", "delete"], "description": "Edit action" },
                                "start": { "type": "integer", "description": "Start line (1-indexed)" },
                                "end": { "type": "integer", "description": "End line (1-indexed, inclusive). For replace/delete." },
                                "content": { "type": "string", "description": "New content for replace/insert" }
                            },
                            "required": ["action", "start"]
                        }
                    }
                },
                "required": ["path", "edits"]
            }
        }),
        json!({
            "name": "search_files",
            "description": "Find files matching a glob pattern (e.g. '**/*.rs', 'src/*.toml'). Returns a list of matching file paths.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "pattern": { "type": "string", "description": "Glob pattern (supports *, **, ?)" },
                    "base_path": { "type": "string", "description": "Directory to search from (default: project root)" }
                },
                "required": ["pattern"]
            }
        }),
        json!({
            "name": "search_code",
            "description": "Search file contents for a text pattern. Returns matching lines with file paths and line numbers.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "pattern": { "type": "string", "description": "Text pattern to search for (case-insensitive)" },
                    "path": { "type": "string", "description": "Directory to search in (default: project root)" },
                    "include": { "type": "string", "description": "File glob filter (e.g. '*.rs', '*.ex')" },
                    "max_results": { "type": "integer", "description": "Maximum matches to return (default: 50)" },
                    "context_lines": { "type": "integer", "description": "Lines of context around each match (default: 2)" }
                },
                "required": ["pattern"]
            }
        }),
        json!({
            "name": "list_directory",
            "description": "Show a tree view of a directory's contents with configurable depth.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Directory path (default: project root)" },
                    "depth": { "type": "integer", "description": "Maximum depth to recurse (default: 3)" }
                }
            }
        }),
        json!({
            "name": "component_search",
            "description": "Search the CYFR component registry for available catalysts, reagents, and formulas.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "Search query" },
                    "type": { "type": "string", "enum": ["catalyst", "reagent", "formula"], "description": "Filter by component type" }
                }
            }
        }),
        json!({
            "name": "component_inspect",
            "description": "Get full details of a CYFR component including its manifest, schema, and usage examples.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "reference": { "type": "string", "description": "Component reference (e.g. 'catalyst:local.web:0.1.0')" }
                },
                "required": ["reference"]
            }
        }),
        json!({
            "name": "invoke_catalyst",
            "description": "Invoke a CYFR catalyst component directly. Use component_inspect first to learn the expected input format.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "reference": { "type": "string", "description": "Catalyst reference (e.g. 'catalyst:local.web:0.1.0')" },
                    "input": { "type": "object", "description": "Catalyst input" }
                },
                "required": ["reference", "input"]
            }
        }),
    ];

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
// Tool dispatch — maps LLM tool calls to files catalyst or MCP
// ---------------------------------------------------------------------------

pub fn dispatch_tool(
    tool_name: &str,
    args: &Value,
    files_ref: &str,
    project_path: &str,
) -> String {
    match tool_name {
        "read_file" => tool_read_file(args, files_ref, project_path),
        "write_file" => tool_write_file(args, files_ref, project_path),
        "edit_file" => tool_edit_file(args, files_ref, project_path),
        "search_files" => tool_search_files(args, files_ref, project_path),
        "search_code" => tool_search_code(args, files_ref, project_path),
        "list_directory" => tool_list_directory(args, files_ref, project_path),
        "component_search" => dispatch_mcp("component", "search", args),
        "component_inspect" => dispatch_mcp("component", "inspect", args),
        "invoke_catalyst" => dispatch_invoke(args),
        _ => format!("Unknown tool: {}", tool_name),
    }
}

// ---------------------------------------------------------------------------
// Files catalyst helpers
// ---------------------------------------------------------------------------

/// Invoke the files catalyst with the given action and return parsed response.
fn files_call(files_ref: &str, input: &Value) -> Result<Value, String> {
    let request = json!({
        "reference": files_ref,
        "input": input,
        "type": "catalyst"
    });
    let response_str = invoke::call(&request.to_string());
    let response: Value = serde_json::from_str(&response_str)
        .map_err(|e| format!("Failed to parse invoke response: {e}"))?;

    if let Some(err) = response.get("error") {
        return Err(format!("Invoke error: {err}"));
    }

    let output = response.get("output").cloned().unwrap_or(Value::Null);
    let result = match &output {
        Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
        _ => output,
    };

    if let Some(err) = result.get("error") {
        return Err(format!("{}", err));
    }

    Ok(result)
}

fn files_read(files_ref: &str, path: &str) -> Result<Value, String> {
    files_call(files_ref, &json!({"action": "read", "path": path}))
}

fn files_write(files_ref: &str, path: &str, content_b64: &str) -> Result<Value, String> {
    files_call(files_ref, &json!({"action": "write", "path": path, "content": content_b64}))
}

fn files_list(files_ref: &str, path: &str) -> Result<Vec<String>, String> {
    let result = files_call(files_ref, &json!({"action": "list", "path": path}))?;
    Ok(result
        .get("files")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default())
}

/// Read file content as decoded text.
fn files_read_text(files_ref: &str, path: &str) -> Result<String, String> {
    let result = files_read(files_ref, path)?;
    let b64 = result.get("content").and_then(|v| v.as_str()).unwrap_or("");
    base64_decode_to_string(b64)
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

fn tool_read_file(args: &Value, files_ref: &str, project_path: &str) -> String {
    let path = resolve_path(args.get("path").and_then(|v| v.as_str()).unwrap_or(""), project_path);
    let start_line = args.get("start_line").and_then(|v| v.as_u64()).map(|v| v as usize);
    let end_line = args.get("end_line").and_then(|v| v.as_u64()).map(|v| v as usize);

    match files_read_text(files_ref, &path) {
        Ok(text) => {
            let all_lines: Vec<&str> = text.lines().collect();
            let total = all_lines.len();

            let start = start_line.unwrap_or(1).max(1);
            let end = end_line.unwrap_or(total).min(total);
            let start_idx = start.saturating_sub(1);

            if start_idx >= total {
                return json!({"path": path, "content": "", "total_lines": total}).to_string();
            }

            let numbered: Vec<String> = all_lines[start_idx..end]
                .iter()
                .enumerate()
                .map(|(i, line)| format!("{:>4}\t{}", start_idx + i + 1, line))
                .collect();

            truncate_result(&json!({
                "path": path,
                "content": numbered.join("\n"),
                "start": start_idx + 1,
                "end": end,
                "total_lines": total
            }).to_string())
        }
        Err(e) => json!({"error": e}).to_string(),
    }
}

fn tool_write_file(args: &Value, files_ref: &str, project_path: &str) -> String {
    let path = resolve_path(args.get("path").and_then(|v| v.as_str()).unwrap_or(""), project_path);
    let content = args.get("content").and_then(|v| v.as_str()).unwrap_or("");
    let encoded = base64_encode(content.as_bytes());

    match files_write(files_ref, &path, &encoded) {
        Ok(_) => json!({"status": "ok", "path": path, "size": content.len()}).to_string(),
        Err(e) => json!({"error": e}).to_string(),
    }
}

fn tool_edit_file(args: &Value, files_ref: &str, project_path: &str) -> String {
    let path = resolve_path(args.get("path").and_then(|v| v.as_str()).unwrap_or(""), project_path);
    let edits = match args.get("edits").and_then(|v| v.as_array()) {
        Some(e) => e,
        None => return json!({"error": "Missing 'edits' array"}).to_string(),
    };

    // Read current content
    let text = match files_read_text(files_ref, &path) {
        Ok(t) => t,
        Err(e) => return json!({"error": format!("Failed to read file: {e}")}).to_string(),
    };

    let mut lines: Vec<String> = text.lines().map(|l| l.to_string()).collect();
    let had_trailing_newline = text.ends_with('\n');

    // Parse edits and sort by start line descending (apply bottom-up)
    let mut parsed: Vec<(usize, usize, &str, &str)> = Vec::new(); // (start, end, action, content)
    for edit in edits {
        let action = edit.get("action").and_then(|v| v.as_str()).unwrap_or("replace");
        let start = edit.get("start").and_then(|v| v.as_u64()).unwrap_or(1) as usize;
        let end = edit.get("end").and_then(|v| v.as_u64()).unwrap_or(start as u64) as usize;
        let content = edit.get("content").and_then(|v| v.as_str()).unwrap_or("");
        parsed.push((start, end, action, content));
    }
    parsed.sort_by(|a, b| b.0.cmp(&a.0));

    let mut applied = 0;
    for (start, end, action, content) in &parsed {
        match *action {
            "replace" => {
                let s = start.saturating_sub(1);
                let e = (*end).min(lines.len());
                if s < lines.len() {
                    let new_lines: Vec<String> = content.lines().map(|l| l.to_string()).collect();
                    let drain_end = e.min(lines.len());
                    if s < drain_end {
                        lines.drain(s..drain_end);
                    }
                    for (j, nl) in new_lines.iter().enumerate() {
                        lines.insert(s + j, nl.clone());
                    }
                    applied += 1;
                }
            }
            "insert" => {
                let at = (*start).min(lines.len());
                let new_lines: Vec<String> = content.lines().map(|l| l.to_string()).collect();
                for (j, nl) in new_lines.iter().enumerate() {
                    lines.insert(at + j, nl.clone());
                }
                applied += 1;
            }
            "delete" => {
                let s = start.saturating_sub(1);
                let e = (*end).min(lines.len());
                if s < e {
                    lines.drain(s..e);
                    applied += 1;
                }
            }
            _ => {}
        }
    }

    // Write back
    let mut new_content = lines.join("\n");
    if had_trailing_newline && !new_content.ends_with('\n') {
        new_content.push('\n');
    }
    let encoded = base64_encode(new_content.as_bytes());

    match files_write(files_ref, &path, &encoded) {
        Ok(_) => json!({"status": "ok", "path": path, "edits_applied": applied, "total_lines": lines.len()}).to_string(),
        Err(e) => json!({"error": format!("Failed to write: {e}")}).to_string(),
    }
}

fn tool_search_files(args: &Value, files_ref: &str, project_path: &str) -> String {
    let pattern = args.get("pattern").and_then(|v| v.as_str()).unwrap_or("**/*");
    let base = args.get("base_path").and_then(|v| v.as_str());
    let base_path = resolve_path(base.unwrap_or(""), project_path);

    let mut matches = Vec::new();
    if let Err(e) = walk_and_glob(files_ref, &base_path, pattern, &mut matches) {
        return json!({"error": e}).to_string();
    }
    matches.sort();

    truncate_result(&json!({
        "matches": matches,
        "count": matches.len(),
        "pattern": pattern
    }).to_string())
}

fn tool_search_code(args: &Value, files_ref: &str, project_path: &str) -> String {
    let pattern = args.get("pattern").and_then(|v| v.as_str()).unwrap_or("");
    let path = resolve_path(args.get("path").and_then(|v| v.as_str()).unwrap_or(""), project_path);
    let include = args.get("include").and_then(|v| v.as_str());
    let max_results = args.get("max_results").and_then(|v| v.as_u64()).unwrap_or(50) as usize;
    let context_lines = args.get("context_lines").and_then(|v| v.as_u64()).unwrap_or(2) as usize;

    let pattern_lower = pattern.to_lowercase();
    let mut matches = Vec::new();
    if let Err(e) = walk_and_grep(files_ref, &path, &pattern_lower, include, context_lines, max_results, &mut matches) {
        return json!({"error": e}).to_string();
    }

    truncate_result(&json!({
        "matches": matches,
        "count": matches.len(),
        "pattern": pattern,
        "truncated": matches.len() >= max_results
    }).to_string())
}

fn tool_list_directory(args: &Value, files_ref: &str, project_path: &str) -> String {
    let path = resolve_path(args.get("path").and_then(|v| v.as_str()).unwrap_or(""), project_path);
    let max_depth = args.get("depth").and_then(|v| v.as_u64()).unwrap_or(3) as usize;

    let root_display = if path.is_empty() { "." } else { &path };
    let mut output = format!("{}\n", root_display);
    let mut count = 0;
    if let Err(e) = build_tree(files_ref, &path, 0, max_depth, "", &mut output, &mut count) {
        return json!({"error": e}).to_string();
    }

    truncate_result(&json!({
        "tree": output.trim_end(),
        "count": count,
        "path": path
    }).to_string())
}

// ---------------------------------------------------------------------------
// Glob — recursive directory walk + pattern matching via files catalyst
// ---------------------------------------------------------------------------

fn walk_and_glob(files_ref: &str, dir: &str, pattern: &str, matches: &mut Vec<String>) -> Result<(), String> {
    let entries = files_list(files_ref, dir)?;

    for entry in &entries {
        let full_path = join_path(dir, entry);

        if entry.ends_with('/') {
            walk_and_glob(files_ref, &full_path, pattern, matches)?;
        } else if glob_match(pattern, &full_path) {
            matches.push(full_path);
        }
    }
    Ok(())
}

fn glob_match(pattern: &str, path: &str) -> bool {
    glob_match_bytes(pattern.as_bytes(), path.as_bytes())
}

fn glob_match_bytes(pattern: &[u8], path: &[u8]) -> bool {
    let mut pi = 0;
    let mut si = 0;
    let mut star_pi = usize::MAX;
    let mut star_si = usize::MAX;

    while si < path.len() {
        if pi + 1 < pattern.len() && pattern[pi] == b'*' && pattern[pi + 1] == b'*' {
            star_pi = pi;
            star_si = si;
            pi += 2;
            if pi < pattern.len() && pattern[pi] == b'/' {
                pi += 1;
            }
            continue;
        }
        if pi < pattern.len() {
            match pattern[pi] {
                b'*' => { star_pi = pi; star_si = si; pi += 1; continue; }
                b'?' if path[si] != b'/' => { pi += 1; si += 1; continue; }
                c if c == path[si] => { pi += 1; si += 1; continue; }
                _ => {}
            }
        }
        if star_pi != usize::MAX {
            pi = star_pi;
            star_si += 1;
            si = star_si;
            if pi < pattern.len() && pattern[pi] == b'*' && (pi + 1 >= pattern.len() || pattern[pi + 1] != b'*') {
                if si > 0 && path[si - 1] == b'/' { return false; }
            }
            continue;
        }
        return false;
    }
    while pi < pattern.len() {
        if pattern[pi] == b'*' { pi += 1; }
        else if pi + 1 < pattern.len() && pattern[pi] == b'*' && pattern[pi + 1] == b'*' {
            pi += 2;
            if pi < pattern.len() && pattern[pi] == b'/' { pi += 1; }
        } else { break; }
    }
    pi == pattern.len()
}

// ---------------------------------------------------------------------------
// Grep — recursive walk + read + search via files catalyst
// ---------------------------------------------------------------------------

fn walk_and_grep(
    files_ref: &str,
    dir: &str,
    pattern: &str,
    include: Option<&str>,
    context_lines: usize,
    max_results: usize,
    matches: &mut Vec<Value>,
) -> Result<(), String> {
    if matches.len() >= max_results { return Ok(()); }

    let entries = files_list(files_ref, dir)?;
    for entry in &entries {
        if matches.len() >= max_results { break; }
        let full_path = join_path(dir, entry);

        if entry.ends_with('/') {
            walk_and_grep(files_ref, &full_path, pattern, include, context_lines, max_results, matches)?;
        } else {
            if let Some(inc) = include {
                if !glob_match(inc, entry) { continue; }
            }
            if is_likely_binary(entry) { continue; }

            let text = match files_read_text(files_ref, &full_path) {
                Ok(t) => t,
                Err(_) => continue,
            };
            grep_content(&full_path, &text, pattern, context_lines, max_results, matches);
        }
    }
    Ok(())
}

fn grep_content(
    file_path: &str,
    content: &str,
    pattern: &str,
    context_lines: usize,
    max_results: usize,
    matches: &mut Vec<Value>,
) {
    let lines: Vec<&str> = content.lines().collect();
    for (i, line) in lines.iter().enumerate() {
        if matches.len() >= max_results { break; }
        if line.to_lowercase().contains(pattern) {
            let mut ctx = Vec::new();
            if context_lines > 0 {
                let start = i.saturating_sub(context_lines);
                let end = (i + context_lines + 1).min(lines.len());
                for j in start..end {
                    if j != i {
                        ctx.push(json!({"line": j + 1, "content": lines[j]}));
                    }
                }
            }
            let mut m = json!({"file": file_path, "line": i + 1, "content": line.trim()});
            if !ctx.is_empty() { m["context"] = json!(ctx); }
            matches.push(m);
        }
    }
}

fn is_likely_binary(filename: &str) -> bool {
    let exts = [
        ".wasm", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf",
        ".zip", ".tar", ".gz", ".bz2", ".7z", ".exe", ".dll",
        ".so", ".dylib", ".o", ".a", ".class", ".pyc",
    ];
    let lower = filename.to_lowercase();
    exts.iter().any(|ext| lower.ends_with(ext))
}

// ---------------------------------------------------------------------------
// Tree — recursive directory listing via files catalyst
// ---------------------------------------------------------------------------

fn build_tree(
    files_ref: &str,
    dir: &str,
    depth: usize,
    max_depth: usize,
    prefix: &str,
    output: &mut String,
    count: &mut usize,
) -> Result<(), String> {
    if depth >= max_depth { return Ok(()); }

    let entries = match files_list(files_ref, dir) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };

    let total = entries.len();
    for (i, entry) in entries.iter().enumerate() {
        let is_last = i == total - 1;
        let connector = if is_last { "└── " } else { "├── " };
        let child_prefix = if is_last { "    " } else { "│   " };
        let display = entry.trim_end_matches('/');

        output.push_str(&format!("{}{}{}\n", prefix, connector, display));
        *count += 1;

        if entry.ends_with('/') {
            let full_path = join_path(dir, entry);
            let new_prefix = format!("{}{}", prefix, child_prefix);
            build_tree(files_ref, &full_path, depth + 1, max_depth, &new_prefix, output, count)?;
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// MCP + catalyst dispatch (unchanged)
// ---------------------------------------------------------------------------

fn dispatch_mcp(tool: &str, action: &str, args: &Value) -> String {
    let request = json!({ "tool": tool, "action": action, "args": args });
    let response = tools::call(&request.to_string());
    truncate_result(&response)
}

fn dispatch_invoke(args: &Value) -> String {
    let reference = args.get("reference").and_then(|v| v.as_str()).unwrap_or("");
    let input = args.get("input").cloned().unwrap_or(json!({}));
    let request = json!({ "reference": reference, "input": input, "type": "catalyst" });
    let response_str = invoke::call(&request.to_string());
    extract_invoke_output(&response_str)
}

// ---------------------------------------------------------------------------
// Parallel tool execution
// ---------------------------------------------------------------------------

pub fn execute_tools_parallel(
    tool_calls: &[(String, String, Value)],
    files_ref: &str,
    project_path: &str,
) -> Vec<(String, String, String)> {
    let mut catalyst_calls: Vec<(usize, &str, &Value)> = Vec::new();
    let mut other_calls: Vec<(usize, &str, &str, &Value)> = Vec::new();

    for (i, (id, name, args)) in tool_calls.iter().enumerate() {
        if name == "invoke_catalyst" {
            catalyst_calls.push((i, id, args));
        } else {
            other_calls.push((i, id, name, args));
        }
    }

    let mut results: Vec<(usize, String, String, String)> = Vec::with_capacity(tool_calls.len());

    for (i, id, name, args) in &other_calls {
        let result = dispatch_tool(name, args, files_ref, project_path);
        results.push((*i, id.to_string(), name.to_string(), result));
    }

    if catalyst_calls.len() == 1 {
        let (i, id, args) = catalyst_calls[0];
        let result = dispatch_invoke(args);
        results.push((i, id.to_string(), "invoke_catalyst".to_string(), result));
    } else if catalyst_calls.len() > 1 {
        let mut task_ids: Vec<(usize, String, String)> = Vec::new();
        for (i, id, args) in &catalyst_calls {
            let reference = args.get("reference").and_then(|v| v.as_str()).unwrap_or("");
            let input = args.get("input").cloned().unwrap_or(json!({}));
            let request = json!({ "reference": reference, "input": input, "type": "catalyst" });
            let spawn_str = invoke::spawn(&request.to_string());
            let spawn: Value = serde_json::from_str(&spawn_str).unwrap_or(json!({}));
            let task_id = spawn.get("task_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
            task_ids.push((*i, id.to_string(), task_id));
        }

        let valid_ids: Vec<&str> = task_ids.iter()
            .filter(|(_, _, tid)| !tid.is_empty())
            .map(|(_, _, tid)| tid.as_str())
            .collect();

        if !valid_ids.is_empty() {
            let await_req = json!({"task_ids": valid_ids});
            let await_str = invoke::await_all(&await_req.to_string());
            let await_resp: Value = serde_json::from_str(&await_str).unwrap_or(json!({}));
            let result_arr = await_resp.get("results").and_then(|v| v.as_array()).cloned().unwrap_or_default();

            let mut result_map: std::collections::HashMap<String, String> = std::collections::HashMap::new();
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

            for (i, id, task_id) in &task_ids {
                let result = result_map.get(task_id).cloned().unwrap_or_else(|| "Spawn failed".to_string());
                results.push((*i, id.clone(), "invoke_catalyst".to_string(), result));
            }
        } else {
            for (i, id, _) in &task_ids {
                results.push((*i, id.clone(), "invoke_catalyst".to_string(), "Spawn failed".to_string()));
            }
        }
    }

    results.sort_by_key(|(i, _, _, _)| *i);
    results.into_iter().map(|(_, id, name, result)| (id, name, result)).collect()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn resolve_path(path: &str, project_path: &str) -> String {
    if path.is_empty() {
        project_path.to_string()
    } else if project_path.is_empty() || path.starts_with(project_path) {
        path.to_string()
    } else {
        let pp = project_path.trim_end_matches('/');
        let p = path.trim_start_matches('/');
        format!("{}/{}", pp, p)
    }
}

fn join_path(dir: &str, entry: &str) -> String {
    if dir.is_empty() {
        entry.to_string()
    } else {
        let d = dir.trim_end_matches('/');
        format!("{}/{}", d, entry)
    }
}

fn extract_invoke_output(response_str: &str) -> String {
    let response: Value = match serde_json::from_str(response_str) {
        Ok(v) => v,
        Err(e) => return format!("Failed to parse response: {}", e),
    };
    if let Some(err) = response.get("error") {
        return format!("Error: {}", err);
    }
    let output = response.get("output").cloned().unwrap_or(Value::Null);
    let result = match &output {
        Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
        _ => output,
    };
    if let Some(err) = result.get("error") {
        return format!("Error: {}", err);
    }
    let formatted = if let Some(data) = result.get("data") {
        serde_json::to_string_pretty(data).unwrap_or_else(|_| data.to_string())
    } else {
        serde_json::to_string_pretty(&result).unwrap_or_else(|_| result.to_string())
    };
    truncate_result(&formatted)
}

fn extract_invoke_output_from_result(result: &Value) -> String {
    let output = result.get("output").cloned().unwrap_or(Value::Null);
    let parsed = match &output {
        Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
        _ => output,
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

// ---------------------------------------------------------------------------
// Base64 — minimal implementation for WASM (no external crate needed)
// ---------------------------------------------------------------------------

const B64_CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64_encode(data: &[u8]) -> String {
    let mut result = String::new();
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        result.push(B64_CHARS[((triple >> 18) & 0x3F) as usize] as char);
        result.push(B64_CHARS[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 { result.push(B64_CHARS[((triple >> 6) & 0x3F) as usize] as char); }
        else { result.push('='); }
        if chunk.len() > 2 { result.push(B64_CHARS[(triple & 0x3F) as usize] as char); }
        else { result.push('='); }
    }
    result
}

fn base64_decode_to_string(input: &str) -> Result<String, String> {
    let input = input.trim();
    if input.is_empty() { return Ok(String::new()); }
    let bytes = base64_decode(input)?;
    String::from_utf8(bytes).map_err(|e| format!("UTF-8 decode error: {e}"))
}

fn base64_decode(input: &str) -> Result<Vec<u8>, String> {
    let chars: Vec<u8> = input.bytes().filter(|&b| b != b'\n' && b != b'\r').collect();
    if chars.len() % 4 != 0 { return Err("Invalid base64 length".to_string()); }

    let mut result = Vec::new();
    for chunk in chars.chunks(4) {
        let mut vals = [0u32; 4];
        let mut pad_count = 0;
        for (i, &byte) in chunk.iter().enumerate() {
            vals[i] = match byte {
                b'A'..=b'Z' => (byte - b'A') as u32,
                b'a'..=b'z' => (byte - b'a' + 26) as u32,
                b'0'..=b'9' => (byte - b'0' + 52) as u32,
                b'+' => 62, b'/' => 63,
                b'=' => { pad_count += 1; 0 }
                _ => return Err(format!("Invalid base64 character: {}", byte as char)),
            };
        }
        let triple = (vals[0] << 18) | (vals[1] << 12) | (vals[2] << 6) | vals[3];
        result.push(((triple >> 16) & 0xFF) as u8);
        if pad_count < 2 { result.push(((triple >> 8) & 0xFF) as u8); }
        if pad_count < 1 { result.push((triple & 0xFF) as u8); }
    }
    Ok(result)
}
