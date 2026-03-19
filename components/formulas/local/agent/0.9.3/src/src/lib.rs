#[allow(warnings)]
mod bindings;
mod context;
mod providers;
mod tools;

use bindings::exports::cyfr::formula::run::Guest;
use bindings::cyfr::formula::invoke;

use providers::{detect_provider, Provider};
use serde_json::{json, Value};

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        match handle_request(&input) {
            Ok(output) => output,
            Err(e) => json!({
                "error": {
                    "type": "formula_error",
                    "message": e
                }
            })
            .to_string(),
        }
    }
}

bindings::export!(Component with_types_in bindings);

const DEFAULT_MAX_TURNS: usize = 30;
const DEFAULT_MAX_TOKENS: u64 = 16384;
const MAX_CONV_BYTES: usize = 3_500_000; // 3.5MB soft limit — leaves room for system prompt + overhead

// ---------------------------------------------------------------------------
// Request handling — multi-provider agentic loop
// ---------------------------------------------------------------------------

fn handle_request(input: &str) -> Result<String, String> {
    let parsed: Value =
        serde_json::from_str(input).map_err(|e| format!("Invalid JSON input: {e}"))?;

    // --- Parse input fields ---

    let catalyst_ref = parsed
        .get("catalyst_ref")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing required 'catalyst_ref' field".to_string())?;

    let model = parsed
        .get("model")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing required 'model' field".to_string())?;

    let task = parsed
        .get("task")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing required 'task' field".to_string())?;

    let max_turns = DEFAULT_MAX_TURNS;

    let custom_system = parsed.get("system").and_then(|v| v.as_str());

    let max_tokens = parsed
        .get("max_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(DEFAULT_MAX_TOKENS);

    let visible_tools: Option<Vec<String>> = parsed
        .get("visible_tools")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        });

    let role = parsed.get("role").and_then(|v| v.as_str()).unwrap_or("");
    let emit_tag = parsed.get("emit_tag").and_then(|v| v.as_str()).unwrap_or("");

    // --- Detect provider from catalyst_ref ---
    let provider = detect_provider(catalyst_ref);

    // --- Build initial conversation ---
    let mut conversation = build_initial_messages(&parsed, task)?;

    // --- Build system prompt (passthrough from caller) ---
    let system_prompt = context::build_system_prompt(custom_system);

    // --- Build tool definitions ---
    let tools_for_llm = tools::build_tool_definitions(provider, visible_tools.as_deref());

    // --- Agentic loop ---
    let mut turns = 0;
    let mut all_text = String::new();
    let mut total_input_tokens: u64 = 0;
    let mut total_output_tokens: u64 = 0;

    loop {
        turns += 1;
        if turns > max_turns {
            all_text.push_str("\n\n[Agent reached maximum turn limit]");
            break;
        }

        // Emit turn start event
        let _ = invoke::emit(&emit_event(json!({"kind": "turn_start", "turn": turns}), role, emit_tag));

        // Pre-flight: compact conversation if it's getting too large
        let conv_size: usize = conversation
            .iter()
            .map(|m| serde_json::to_string(m).map(|s| s.len()).unwrap_or(0))
            .sum();

        if conv_size > MAX_CONV_BYTES {
            compact_old_tool_results(&mut conversation, MAX_CONV_BYTES);
        }

        // Build provider-specific request
        let catalyst_input = build_provider_request(
            provider,
            catalyst_ref,
            model,
            &conversation,
            &system_prompt,
            max_tokens,
            &tools_for_llm,
            visible_tools.as_deref(),
        );

        // Invoke the LLM catalyst via MCP execution.run
        let invoke_request = json!({
            "tool": "execution",
            "action": "run",
            "args": {
                "reference": catalyst_ref,
                "input": catalyst_input,
                "type": "catalyst"
            }
        });

        let response_str = invoke::call(&invoke_request.to_string());
        let response: Value = serde_json::from_str(&response_str)
            .map_err(|e| format!("Failed to parse invoke response: {e}"))?;

        if let Some(err) = response.get("error") {
            return Err(format!("Invoke error: {err}"));
        }

        let output = response.get("output").cloned().unwrap_or(Value::Null);

        // MCP execution.run wraps result — extract inner result
        let catalyst_result = if let Some(result) = output.get("result") {
            // Result may be a parsed object or a JSON string — handle both
            match result {
                Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(result.clone()),
                _ => result.clone(),
            }
        } else {
            match &output {
                Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
                _ => output,
            }
        };

        if let Some(err) = catalyst_result.get("error") {
            return Err(format!("Catalyst error: {err}"));
        }

        let data = catalyst_result
            .get("data")
            .cloned()
            .unwrap_or(Value::Null);

        // Extract and emit token usage
        let usage = provider.extract_usage(&data);
        if !usage.is_null() {
            let input_tokens = usage["input_tokens"].as_u64().unwrap_or(0);
            let output_tokens = usage["output_tokens"].as_u64().unwrap_or(0);
            total_input_tokens += input_tokens;
            total_output_tokens += output_tokens;
            let _ = invoke::emit(&emit_event(json!({
                "kind": "usage",
                "turn": turns,
                "input_tokens": input_tokens,
                "output_tokens": output_tokens
            }), role, emit_tag));
        }

        // Accumulate any text from this turn
        let turn_text = provider.extract_text(&data);
        if !turn_text.is_empty() {
            all_text.push_str(&turn_text);
            // Emit text delta event
            let _ = invoke::emit(&emit_event(json!({
                "kind": "text_delta",
                "content": turn_text,
                "turn": turns
            }), role, emit_tag));
        }

        // Check if the model wants to use tools
        if provider.has_tool_calls(&data) {
            // Add assistant message to conversation
            let assistant_msg = provider.build_assistant_message(&data);
            conversation.push(assistant_msg);

            // Extract and execute tool calls
            let tool_calls = provider.extract_tool_calls(&data);

            // Emit tool_use events (including input arguments)
            for tc in &tool_calls {
                let _ = invoke::emit(&emit_event(json!({
                    "kind": "tool_use",
                    "tool": tc.name,
                    "tool_call_id": tc.id,
                    "input": tc.arguments,
                    "turn": turns
                }), role, emit_tag));
            }

            let call_tuples: Vec<(String, String, Value)> = tool_calls
                .iter()
                .map(|tc| {
                    let mut args = tc.arguments.clone();
                    // When delegating to a sub-agent formula, inject our own
                    // catalyst_ref and model so the sub-agent uses the same
                    // provider the user selected — models may hallucinate these.
                    if tc.name == "execution" {
                        let is_formula = args.get("reference")
                            .and_then(|v| v.as_str())
                            .map_or(false, |r| r.starts_with("formula:"));

                        if is_formula {
                            if let Some(input) = args.get_mut("input") {
                                if let Some(obj) = input.as_object_mut() {
                                    obj.entry("catalyst_ref")
                                        .or_insert(json!(catalyst_ref));
                                    obj.entry("model")
                                        .or_insert(json!(model));
                                }
                            }
                        }
                    }
                    (tc.id.clone(), tc.name.clone(), args)
                })
                .collect();

            let results = tools::execute_tools_parallel(&call_tuples, catalyst_ref, model);

            // Emit tool_result events
            for (id, name, result) in &results {
                let preview = truncate_str(result, 500);
                let _ = invoke::emit(&emit_event(json!({
                    "kind": "tool_result",
                    "tool": name,
                    "tool_call_id": id,
                    "preview": preview,
                    "turn": turns
                }), role, emit_tag));
            }

            // Build tool results message
            let tool_results_msg = provider.build_tool_results_message(&results);

            // For OpenAI, tool results come as an array of separate messages
            if provider == Provider::OpenAI {
                if let Some(msgs) = tool_results_msg.as_array() {
                    for msg in msgs {
                        conversation.push(msg.clone());
                    }
                } else {
                    conversation.push(tool_results_msg);
                }
            } else {
                conversation.push(tool_results_msg);
            }

            continue; // next turn
        }

        // No tool calls — this is the final response
        // Add assistant message to conversation for continuity
        let assistant_msg = provider.build_assistant_message(&data);
        conversation.push(assistant_msg);
        break;
    }

    // Emit conversation history so the LiveView can capture it for follow-up messages
    let _ = invoke::emit(&emit_event(json!({
        "kind": "conversation_complete",
        "messages": conversation
    }), role, emit_tag));

    Ok(json!({
        "provider": provider.name(),
        "model": model,
        "content": all_text,
        "turns": turns,
        "messages": conversation,
        "component_ref": catalyst_ref,
        "usage": {
            "input_tokens": total_input_tokens,
            "output_tokens": total_output_tokens
        }
    })
    .to_string())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build an emit event payload, injecting role/emit_tag when non-empty.
fn emit_event(mut event: Value, role: &str, emit_tag: &str) -> String {
    if !role.is_empty() {
        event["role"] = json!(role);
    }
    if !emit_tag.is_empty() {
        event["emit_tag"] = json!(emit_tag);
    }
    event.to_string()
}

/// Check if a native tool name is allowed by visible_tools.
/// Returns true if visible_tools is None (all tools allowed) or contains the name.
fn native_tool_allowed(visible_tools: Option<&[String]>, name: &str) -> bool {
    match visible_tools {
        None => true,
        Some(visible) => visible.iter().any(|v| v == name),
    }
}

/// Truncate a string at a UTF-8 safe boundary, returning a borrowed slice.
fn truncate_str(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        s
    } else {
        let mut end = max_bytes;
        while end > 0 && !s.is_char_boundary(end) {
            end -= 1;
        }
        &s[..end]
    }
}

/// Compact older tool-result messages to bring conversation under `target_bytes`.
///
/// Walks messages from oldest to newest, truncating tool_result content blocks.
/// Skips the most recent assistant+tool_result pair (the last turn) so the LLM
/// always has full context for its immediate previous action.
fn compact_old_tool_results(conversation: &mut [Value], target_bytes: usize) {
    const PREVIEW_CHARS: usize = 500;

    // Find the index of the last assistant message so we can protect the final turn
    let last_assistant_idx = conversation
        .iter()
        .rposition(|m| m.get("role").and_then(|r| r.as_str()) == Some("assistant"));

    for i in 0..conversation.len() {
        // Don't compact messages at or after the last assistant message (protect final turn)
        if let Some(lai) = last_assistant_idx {
            if i >= lai {
                break;
            }
        }

        // Extract role as owned String so we don't hold a borrow on conversation[i]
        let role = conversation[i]
            .get("role")
            .and_then(|r| r.as_str())
            .unwrap_or("")
            .to_string();

        // --- Claude format: role "user" with content array containing tool_result blocks ---
        if role == "user" {
            if let Some(content) = conversation[i].get("content").and_then(|c| c.as_array()).cloned() {
                let mut changed = false;
                let mut new_content = content;
                for block in new_content.iter_mut() {
                    if block.get("type").and_then(|t| t.as_str()) == Some("tool_result") {
                        if let Some(inner) = block.get("content").cloned() {
                            let text = match &inner {
                                Value::String(s) => s.clone(),
                                _ => serde_json::to_string(&inner).unwrap_or_default(),
                            };
                            if text.len() > PREVIEW_CHARS + 100 {
                                let summary = smart_truncation_summary(&text, PREVIEW_CHARS);
                                block["content"] = json!(summary);
                                changed = true;
                            }
                        }
                    }
                }
                if changed {
                    conversation[i]["content"] = json!(new_content);
                }
            }
        }

        // --- OpenAI format: role "tool" with content string ---
        if role == "tool" {
            let summary = {
                let text = conversation[i].get("content").and_then(|c| c.as_str());
                text.and_then(|t| {
                    if t.len() > PREVIEW_CHARS + 100 {
                        Some(smart_truncation_summary(t, PREVIEW_CHARS))
                    } else {
                        None
                    }
                })
            };
            if let Some(s) = summary {
                conversation[i]["content"] = json!(s);
            }
        }

        // --- Gemini format: role "user" with parts containing functionResponse ---
        if role == "user" {
            if let Some(parts) = conversation[i].get("parts").and_then(|p| p.as_array()).cloned() {
                let mut changed = false;
                let mut new_parts = parts;
                for part in new_parts.iter_mut() {
                    if let Some(resp) = part.get_mut("functionResponse") {
                        if let Some(response) = resp.get("response").cloned() {
                            let text = serde_json::to_string(&response).unwrap_or_default();
                            if text.len() > PREVIEW_CHARS + 100 {
                                let summary = smart_truncation_summary(&text, PREVIEW_CHARS);
                                resp["response"] = json!({"result": summary});
                                changed = true;
                            }
                        }
                    }
                }
                if changed {
                    conversation[i]["parts"] = json!(new_parts);
                }
            }
        }

        // Check if we're under target now
        let current_size: usize = conversation
            .iter()
            .map(|m| serde_json::to_string(m).map(|s| s.len()).unwrap_or(0))
            .sum();
        if current_size <= target_bytes {
            break;
        }
    }
}

/// Produce a smart truncation summary that preserves structure hints.
/// - JSON arrays: "[Array with N items, first {limit} chars: ...]"
/// - File content (lines with numbers): "[File: ~N lines, first {limit} chars: ...]"
/// - Errors: preserve error message in full when possible
/// - Default: "[Result truncated: was {len} bytes. First {limit} chars: ...]"
fn smart_truncation_summary(text: &str, limit: usize) -> String {
    let trimmed = text.trim();

    // Preserve short error messages in full
    if trimmed.starts_with("{\"error") || trimmed.starts_with("Error:") {
        if trimmed.len() <= limit * 2 {
            return trimmed.to_string();
        }
    }

    let preview = truncate_str(text, limit).to_string();

    // Detect JSON arrays
    if trimmed.starts_with('[') {
        if let Ok(arr) = serde_json::from_str::<Vec<Value>>(trimmed) {
            return format!(
                "[Array with {} items, first {} chars: {}]",
                arr.len(),
                limit,
                preview
            );
        }
    }

    // Detect file content (lines starting with digits or line-numbered output)
    let line_count = text.lines().count();
    if line_count > 5 {
        return format!(
            "[Content: ~{} lines, first {} chars: {}]",
            line_count,
            limit,
            preview
        );
    }

    format!(
        "[Result truncated: was {} bytes. First {} chars: {}]",
        text.len(),
        limit,
        preview
    )
}

// ---------------------------------------------------------------------------
// Initial message building
// ---------------------------------------------------------------------------

fn build_initial_messages(parsed: &Value, task: &str) -> Result<Vec<Value>, String> {
    // If conversation history provided, append the new task as a user message
    if let Some(msgs) = parsed.get("messages").and_then(|v| v.as_array()) {
        if !msgs.is_empty() {
            let mut conversation = msgs.clone();
            conversation.push(json!({"role": "user", "content": task}));
            return Ok(conversation);
        }
    }

    // Fresh conversation — start with the task as a user message
    Ok(vec![json!({"role": "user", "content": task})])
}

// ---------------------------------------------------------------------------
// Provider-specific request building
// ---------------------------------------------------------------------------

fn build_provider_request(
    provider: Provider,
    catalyst_ref: &str,
    model: &str,
    messages: &[Value],
    system: &str,
    max_tokens: u64,
    tools: &Value,
    visible_tools: Option<&[String]>,
) -> Value {
    match provider {
        Provider::Claude => build_claude_request(model, messages, system, max_tokens, tools, visible_tools),
        Provider::OpenAI => build_openai_request(catalyst_ref, model, messages, system, tools, visible_tools),
        Provider::Gemini => build_gemini_request(model, messages, system, tools, visible_tools),
        Provider::Generic => build_claude_request(model, messages, system, max_tokens, tools, visible_tools),
    }
}

fn build_claude_request(
    model: &str,
    messages: &[Value],
    system: &str,
    max_tokens: u64,
    tools: &Value,
    visible_tools: Option<&[String]>,
) -> Value {
    let mut params = json!({
        "model": model,
        "max_tokens": max_tokens,
        "messages": messages,
        "system": system,
    });

    // Merge MCP tools with provider built-in tools
    let mut all_tools: Vec<Value> = tools.as_array().cloned().unwrap_or_default();
    if native_tool_allowed(visible_tools, "native_search") {
        all_tools.push(json!({"type": "web_search_20250305", "name": "web_search"}));
    }
    if !all_tools.is_empty() {
        params["tools"] = json!(all_tools);
    }

    json!({
        "operation": "messages.create",
        "params": params,
    })
}

fn build_openai_request(
    catalyst_ref: &str,
    model: &str,
    messages: &[Value],
    system: &str,
    tools: &Value,
    visible_tools: Option<&[String]>,
) -> Value {
    let mut all_messages = vec![json!({"role": "system", "content": system})];
    all_messages.extend_from_slice(messages);

    let mut params = json!({
        "model": model,
        "messages": all_messages,
    });

    // Merge MCP tools with provider built-in tools
    let mut all_tools: Vec<Value> = tools.as_array().cloned().unwrap_or_default();
    let lower_ref = catalyst_ref.to_lowercase();
    if lower_ref.contains("grok") {
        // Grok — native web search and X/Twitter search
        if native_tool_allowed(visible_tools, "native_search") {
            all_tools.push(json!({"type": "web_search"}));
            all_tools.push(json!({"type": "x_search"}));
        }
    } else if lower_ref.contains("openai") && !lower_ref.contains("openrouter") {
        // Direct OpenAI — web search via Chat Completions
        if native_tool_allowed(visible_tools, "native_search") {
            all_tools.push(json!({"type": "web_search_preview"}));
        }
    }
    if !all_tools.is_empty() {
        params["tools"] = json!(all_tools);
    }

    json!({
        "operation": "chat.completions.create",
        "params": params,
    })
}

fn build_gemini_request(
    model: &str,
    messages: &[Value],
    system: &str,
    tools: &Value,
    visible_tools: Option<&[String]>,
) -> Value {
    // Convert messages to Gemini contents format
    let contents: Vec<Value> = messages
        .iter()
        .map(|msg| {
            let role = msg
                .get("role")
                .and_then(|v| v.as_str())
                .unwrap_or("user");

            // If message has parts already (Gemini format), pass through
            if let Some(parts) = msg.get("parts") {
                return json!({
                    "role": if role == "assistant" { "model" } else { role },
                    "parts": parts
                });
            }

            // Convert from text content
            let text = msg
                .get("content")
                .and_then(|v| v.as_str())
                .unwrap_or("");

            json!({
                "role": if role == "assistant" { "model" } else { role },
                "parts": [{"text": text}]
            })
        })
        .collect();

    let mut params = json!({
        "model": model,
        "contents": contents,
        "systemInstruction": {"parts": [{"text": system}]},
    });

    // Build Gemini tools array — functionDeclarations + native search tools
    let has_mcp_tools = tools.as_array().map_or(false, |arr| !arr.is_empty());
    let wants_search = native_tool_allowed(visible_tools, "native_search");

    if has_mcp_tools && wants_search {
        // Include both functionDeclarations and google_search
        let mut tool_entries = tools.as_array().cloned().unwrap_or_default();
        tool_entries.push(json!({"google_search": {}}));
        tool_entries.push(json!({"url_context": {}}));
        params["tools"] = json!(tool_entries);
    } else if has_mcp_tools {
        params["tools"] = tools.clone();
    } else if wants_search {
        params["tools"] = json!([
            {"google_search": {}},
            {"url_context": {}}
        ]);
    }

    json!({
        "operation": "content.generate",
        "params": params,
    })
}
