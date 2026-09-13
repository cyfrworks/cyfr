#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::storage::files;
use serde_json::{json, Value};

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        match handle_request(&input) {
            Ok(output) => output,
            Err(e) => format_error("internal_error", &e),
        }
    }
}

bindings::export!(Component with_types_in bindings);

const MAX_RESULT_CHARS: usize = 256000;

fn handle_request(input: &str) -> Result<String, String> {
    let req: Value = serde_json::from_str(input)
        .map_err(|e| format!("Invalid JSON input: {}", e))?;

    let action = req.get("action")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing required field: action".to_string())?;

    let path = req.get("path")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    match action {
        // --- Pass-through actions (delegated to host) ---
        "read" | "write" | "append" | "list" | "delete" | "exists" => {
            handle_passthrough(action, path, &req)
        }
        // --- Enhanced actions (implemented in catalyst) ---
        "read_text" => handle_read_text(path, &req),
        "read_lines" => handle_read_lines(path, &req),
        "write_text" => handle_write_text(path, &req),
        "append_text" => handle_append_text(path, &req),
        "edit" => handle_edit(path, &req),
        "search" => handle_search(&req),
        "grep" => handle_grep(&req),
        "tree" => handle_tree(path, &req),
        _ => {
            Ok(format_error("invalid_action",
                &format!("Unknown action: {}. Use: read, read_text, read_lines, write, write_text, append, append_text, edit, list, delete, exists, search, grep, tree", action)))
        }
    }
}

// ---------------------------------------------------------------------------
// Pass-through actions — delegate directly to host files::call()
// ---------------------------------------------------------------------------

fn handle_passthrough(action: &str, path: &str, req: &Value) -> Result<String, String> {
    let storage_request = match action {
        "read" => {
            if path.is_empty() {
                return Err("Missing required field: path".to_string());
            }
            json!({"action": "read", "path": path})
        }
        "write" => {
            if path.is_empty() {
                return Err("Missing required field: path".to_string());
            }
            let content = req.get("content")
                .and_then(|v| v.as_str())
                .ok_or_else(|| "Missing required field: content (base64-encoded)".to_string())?;

            // Validate UTF-8 for known text file extensions to prevent corruption
            if is_text_file(path) {
                let bytes = base64_decode(content)?;
                if std::str::from_utf8(&bytes).is_err() {
                    return Ok(format_error("invalid_utf8",
                        &format!("Content is not valid UTF-8 for text file: {path}. \
                                  Source files (.rs, .toml, .json, .wit, etc.) must be valid UTF-8.")));
                }
            }

            json!({"action": "write", "path": path, "content": content})
        }
        "append" => {
            if path.is_empty() {
                return Err("Missing required field: path".to_string());
            }
            let content = req.get("content")
                .and_then(|v| v.as_str())
                .ok_or_else(|| "Missing required field: content (base64-encoded)".to_string())?;

            json!({"action": "append", "path": path, "content": content})
        }
        "list" => {
            json!({"action": "list", "path": path})
        }
        "delete" => {
            if path.is_empty() {
                return Err("Missing required field: path".to_string());
            }
            json!({"action": "delete", "path": path})
        }
        "exists" => {
            if path.is_empty() {
                return Err("Missing required field: path".to_string());
            }
            json!({"action": "exists", "path": path})
        }
        _ => unreachable!(),
    };

    let request_json = serde_json::to_string(&storage_request)
        .map_err(|e| format!("Failed to serialize request: {}", e))?;
    Ok(files::call(&request_json))
}

// ---------------------------------------------------------------------------
// read_text — read file as plain text (no base64, no line numbers)
// ---------------------------------------------------------------------------

fn handle_read_text(path: &str, req: &Value) -> Result<String, String> {
    if path.is_empty() {
        return Err("Missing required field: path".to_string());
    }

    let text = files_read_text(path)?;
    let total_size = text.len();

    let offset = req.get("offset").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
    let limit = req.get("limit").and_then(|v| v.as_u64()).map(|v| v as usize);

    let content = if offset > 0 || limit.is_some() {
        let start = offset.min(total_size);
        // Find valid UTF-8 boundary at or after start
        let mut safe_start = start;
        while safe_start < total_size && !text.is_char_boundary(safe_start) {
            safe_start += 1;
        }
        let end = limit
            .map(|l| (safe_start + l).min(total_size))
            .unwrap_or(total_size);
        // Find valid UTF-8 boundary at or before end
        let mut safe_end = end;
        while safe_end > safe_start && !text.is_char_boundary(safe_end) {
            safe_end -= 1;
        }
        if safe_start >= total_size || safe_end <= safe_start {
            ""
        } else {
            &text[safe_start..safe_end]
        }
    } else {
        &text
    };

    Ok(json!({
        "path": path,
        "content": content,
        "size": total_size,
        "offset": offset,
        "length": content.len()
    }).to_string())
}

// ---------------------------------------------------------------------------
// read_lines — read file with line numbering and optional range
// ---------------------------------------------------------------------------

fn handle_read_lines(path: &str, req: &Value) -> Result<String, String> {
    if path.is_empty() {
        return Err("Missing required field: path".to_string());
    }

    let start_line = req.get("start_line").and_then(|v| v.as_u64()).map(|v| v as usize);
    let end_line = req.get("end_line").and_then(|v| v.as_u64()).map(|v| v as usize);

    let text = files_read_text(path)?;
    let all_lines: Vec<&str> = text.lines().collect();
    let total = all_lines.len();

    let start = start_line.unwrap_or(1).max(1);
    let end = end_line.unwrap_or(total).min(total);
    let start_idx = start.saturating_sub(1);

    if start_idx >= total {
        return Ok(json!({"path": path, "content": "", "total_lines": total}).to_string());
    }

    let numbered: Vec<String> = all_lines[start_idx..end]
        .iter()
        .enumerate()
        .map(|(i, line)| format!("{:>4}\t{}", start_idx + i + 1, line))
        .collect();

    Ok(json!({
        "path": path,
        "content": numbered.join("\n"),
        "start": start_idx + 1,
        "end": end,
        "total_lines": total
    }).to_string())
}

// ---------------------------------------------------------------------------
// write_text — write plain text content (no base64 required)
// ---------------------------------------------------------------------------

fn handle_write_text(path: &str, req: &Value) -> Result<String, String> {
    if path.is_empty() {
        return Err("Missing required field: path".to_string());
    }

    let content = req.get("content")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing required field: content".to_string())?;

    // Content is already a Rust &str, so it's guaranteed valid UTF-8.

    let encoded = base64_encode(content.as_bytes());
    files_write(path, &encoded)?;

    Ok(json!({
        "status": "ok",
        "path": path,
        "bytes_written": content.len(),
        "lines": content.lines().count()
    }).to_string())
}

// ---------------------------------------------------------------------------
// append_text — append plain text content (no base64 required)
// ---------------------------------------------------------------------------

fn handle_append_text(path: &str, req: &Value) -> Result<String, String> {
    if path.is_empty() {
        return Err("Missing required field: path".to_string());
    }

    let content = req.get("content")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing required field: content".to_string())?;

    let encoded = base64_encode(content.as_bytes());
    files_append(path, &encoded)?;

    Ok(json!({
        "status": "ok",
        "path": path,
        "bytes_appended": content.len()
    }).to_string())
}

// ---------------------------------------------------------------------------
// edit — structured edits (replace, insert, delete) applied bottom-up
// ---------------------------------------------------------------------------

fn handle_edit(path: &str, req: &Value) -> Result<String, String> {
    if path.is_empty() {
        return Err("Missing required field: path".to_string());
    }

    let edits = match req.get("edits").and_then(|v| v.as_array()) {
        Some(e) => e,
        None => return Ok(json!({"error": "Missing 'edits' array"}).to_string()),
    };

    let text = files_read_text(path)
        .map_err(|e| format!("Failed to read file: {e}"))?;

    let mut lines: Vec<String> = text.lines().map(|l| l.to_string()).collect();
    let had_trailing_newline = text.ends_with('\n');

    // Parse edits and sort by start line descending (apply bottom-up)
    let mut parsed: Vec<(usize, usize, &str, &str)> = Vec::new();
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
    files_write(path, &encoded)?;

    Ok(json!({"status": "ok", "path": path, "edits_applied": applied, "total_lines": lines.len()}).to_string())
}

// ---------------------------------------------------------------------------
// search — recursive glob matching
// ---------------------------------------------------------------------------

fn handle_search(req: &Value) -> Result<String, String> {
    let pattern = req.get("pattern").and_then(|v| v.as_str()).unwrap_or("**/*");
    let base_path = req.get("base_path").and_then(|v| v.as_str())
        .or_else(|| req.get("path").and_then(|v| v.as_str()))
        .unwrap_or("");

    let mut matches = Vec::new();
    walk_and_glob(base_path, base_path, pattern, &mut matches)?;
    matches.sort();

    Ok(truncate_result(&json!({
        "matches": matches,
        "count": matches.len(),
        "pattern": pattern
    }).to_string()))
}

// ---------------------------------------------------------------------------
// grep — recursive content search with context
// ---------------------------------------------------------------------------

fn handle_grep(req: &Value) -> Result<String, String> {
    let pattern = req.get("pattern").and_then(|v| v.as_str()).unwrap_or("");
    let path = req.get("path").and_then(|v| v.as_str()).unwrap_or("");
    let include = req.get("include").and_then(|v| v.as_str());
    let max_results = req.get("max_results").and_then(|v| v.as_u64()).unwrap_or(50) as usize;
    let context_lines = req.get("context_lines").and_then(|v| v.as_u64()).unwrap_or(2) as usize;

    let pattern_lower = pattern.to_lowercase();
    let mut matches = Vec::new();
    walk_and_grep(path, &pattern_lower, include, context_lines, max_results, &mut matches)?;

    Ok(truncate_result(&json!({
        "matches": matches,
        "count": matches.len(),
        "pattern": pattern,
        "truncated": matches.len() >= max_results
    }).to_string()))
}

// ---------------------------------------------------------------------------
// tree — recursive directory listing with tree connectors
// ---------------------------------------------------------------------------

fn handle_tree(path: &str, req: &Value) -> Result<String, String> {
    let max_depth = req.get("depth").and_then(|v| v.as_u64()).unwrap_or(3) as usize;

    let root_display = if path.is_empty() { "." } else { path };
    let mut output = format!("{}\n", root_display);
    let mut count = 0;
    build_tree(path, 0, max_depth, "", &mut output, &mut count)?;

    Ok(truncate_result(&json!({
        "tree": output.trim_end(),
        "count": count,
        "path": path
    }).to_string()))
}

// ---------------------------------------------------------------------------
// Host function helpers
// ---------------------------------------------------------------------------

fn files_call_internal(input: &Value) -> Result<Value, String> {
    let request_json = serde_json::to_string(input)
        .map_err(|e| format!("Failed to serialize: {e}"))?;
    let response_str = files::call(&request_json);
    let response: Value = serde_json::from_str(&response_str)
        .map_err(|e| format!("Failed to parse response: {e}"))?;

    if let Some(err) = response.get("error") {
        return Err(format!("{}", err));
    }
    Ok(response)
}

fn files_read_text(path: &str) -> Result<String, String> {
    let result = files_call_internal(&json!({"action": "read", "path": path}))?;
    let b64 = result.get("content").and_then(|v| v.as_str()).unwrap_or("");
    base64_decode_to_string(b64)
}

fn files_write(path: &str, content_b64: &str) -> Result<Value, String> {
    files_call_internal(&json!({"action": "write", "path": path, "content": content_b64}))
}

fn files_append(path: &str, content_b64: &str) -> Result<Value, String> {
    files_call_internal(&json!({"action": "append", "path": path, "content": content_b64}))
}

fn files_list_entries(path: &str) -> Result<Vec<String>, String> {
    let result = files_call_internal(&json!({"action": "list", "path": path}))?;
    Ok(result
        .get("files")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default())
}

// ---------------------------------------------------------------------------
// Glob — recursive directory walk + pattern matching
// ---------------------------------------------------------------------------

fn walk_and_glob(dir: &str, base: &str, pattern: &str, matches: &mut Vec<String>) -> Result<(), String> {
    let entries = files_list_entries(dir)?;

    for entry in &entries {
        let full_path = join_path(dir, entry);

        if entry.ends_with('/') {
            walk_and_glob(&full_path, base, pattern, matches)?;
        } else {
            // Match against the path relative to the search base
            let rel_path = strip_base(&full_path, base);
            if glob_match(pattern, &rel_path) {
                matches.push(full_path);
            }
        }
    }
    Ok(())
}

fn strip_base<'a>(path: &'a str, base: &str) -> String {
    if base.is_empty() {
        return path.to_string();
    }
    let base_trimmed = base.trim_end_matches('/');
    if let Some(rest) = path.strip_prefix(base_trimmed) {
        rest.trim_start_matches('/').to_string()
    } else {
        path.to_string()
    }
}

fn glob_match(pattern: &str, path: &str) -> bool {
    glob_match_bytes(pattern.as_bytes(), path.as_bytes())
}

fn glob_match_bytes(pat: &[u8], path: &[u8]) -> bool {
    glob_recursive(pat, 0, path, 0)
}

fn glob_recursive(pat: &[u8], pi: usize, path: &[u8], si: usize) -> bool {
    let mut pi = pi;
    let mut si = si;

    while pi < pat.len() {
        // Handle ** (matches zero or more path segments, crossing /)
        if pi + 1 < pat.len() && pat[pi] == b'*' && pat[pi + 1] == b'*' {
            let mut npi = pi + 2;
            if npi < pat.len() && pat[npi] == b'/' {
                npi += 1;
            }
            for pos in si..=path.len() {
                if glob_recursive(pat, npi, path, pos) {
                    return true;
                }
            }
            return false;
        }

        if si >= path.len() {
            break;
        }

        match pat[pi] {
            b'*' => {
                // * matches zero or more non-/ chars
                for pos in si..=path.len() {
                    if pos > si && path[pos - 1] == b'/' {
                        break;
                    }
                    if glob_recursive(pat, pi + 1, path, pos) {
                        return true;
                    }
                }
                return false;
            }
            b'?' if path[si] != b'/' => { pi += 1; si += 1; }
            c if c == path[si] => { pi += 1; si += 1; }
            _ => return false,
        }
    }

    // Consume trailing wildcards (single * covers ** since we advance one at a time)
    while pi < pat.len() && pat[pi] == b'*' {
        pi += 1;
        // Skip trailing slash after ** pattern
        if pi < pat.len() && pat[pi] == b'/' {
            pi += 1;
        }
    }

    pi == pat.len() && si == path.len()
}

// ---------------------------------------------------------------------------
// Grep — recursive walk + read + case-insensitive content search
// ---------------------------------------------------------------------------

fn walk_and_grep(
    dir: &str,
    pattern: &str,
    include: Option<&str>,
    context_lines: usize,
    max_results: usize,
    matches: &mut Vec<Value>,
) -> Result<(), String> {
    if matches.len() >= max_results { return Ok(()); }

    let entries = files_list_entries(dir)?;
    for entry in &entries {
        if matches.len() >= max_results { break; }
        let full_path = join_path(dir, entry);

        if entry.ends_with('/') {
            walk_and_grep(&full_path, pattern, include, context_lines, max_results, matches)?;
        } else {
            if let Some(inc) = include {
                if !glob_match(inc, entry) { continue; }
            }
            if is_likely_binary(entry) { continue; }

            let text = match files_read_text(&full_path) {
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

fn is_text_file(path: &str) -> bool {
    let exts = [
        ".rs", ".toml", ".json", ".wit", ".md", ".txt", ".yaml", ".yml",
        ".html", ".css", ".js", ".ts", ".tsx", ".jsx", ".py", ".rb",
        ".ex", ".exs", ".erl", ".hrl", ".go", ".c", ".h", ".cpp",
        ".java", ".kt", ".swift", ".sh", ".bash", ".zsh", ".fish",
        ".xml", ".svg", ".csv", ".sql", ".graphql", ".proto",
        ".cfg", ".ini", ".env", ".gitignore", ".dockerignore",
    ];
    let lower = path.to_lowercase();
    exts.iter().any(|ext| lower.ends_with(ext))
        || lower.ends_with("makefile")
        || lower.ends_with("dockerfile")
}

// ---------------------------------------------------------------------------
// Tree — recursive directory listing with tree connectors
// ---------------------------------------------------------------------------

fn build_tree(
    dir: &str,
    depth: usize,
    max_depth: usize,
    prefix: &str,
    output: &mut String,
    count: &mut usize,
) -> Result<(), String> {
    if depth >= max_depth { return Ok(()); }

    let entries = match files_list_entries(dir) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };

    let total = entries.len();
    for (i, entry) in entries.iter().enumerate() {
        let is_last = i == total - 1;
        let connector = if is_last { "\u{2514}\u{2500}\u{2500} " } else { "\u{251c}\u{2500}\u{2500} " };
        let child_prefix = if is_last { "    " } else { "\u{2502}   " };
        let display = entry.trim_end_matches('/');

        output.push_str(&format!("{}{}{}\n", prefix, connector, display));
        *count += 1;

        if entry.ends_with('/') {
            let full_path = join_path(dir, entry);
            let new_prefix = format!("{}{}", prefix, child_prefix);
            build_tree(&full_path, depth + 1, max_depth, &new_prefix, output, count)?;
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn join_path(dir: &str, entry: &str) -> String {
    if dir.is_empty() {
        entry.to_string()
    } else {
        let d = dir.trim_end_matches('/');
        format!("{}/{}", d, entry)
    }
}

fn truncate_result(s: &str) -> String {
    if s.len() <= MAX_RESULT_CHARS {
        s.to_string()
    } else {
        // Output is too large — return a valid JSON error instead of chopping mid-JSON
        json!({
            "error": {
                "type": "output_truncated",
                "message": format!("Result too large ({} bytes, max {}). Try narrowing your query.", s.len(), MAX_RESULT_CHARS)
            }
        }).to_string()
    }
}

fn format_error(error_type: &str, message: &str) -> String {
    json!({
        "error": {
            "type": error_type,
            "message": message
        }
    }).to_string()
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
