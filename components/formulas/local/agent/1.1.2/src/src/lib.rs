#[allow(warnings)]
mod bindings;
mod context;
mod providers;
mod tools;

use bindings::exports::cyfr::formula::run::Guest;
use bindings::cyfr::formula::invoke;

use providers::detect_provider;
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

    // --- Parse attachments ---
    let attachments: Vec<Value> = parsed
        .get("attachments")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    // --- Build initial conversation ---
    let mut conversation = build_initial_messages(&parsed, task, &attachments)?;

    // --- Build system prompt (passthrough from caller) ---
    let system_prompt = context::build_system_prompt(custom_system);

    // --- Build tool definitions ---
    let canonical_tools = tools::build_tool_definitions(visible_tools.as_deref());
    let tools_for_llm = provider.format_tools(&canonical_tools, visible_tools.as_deref());

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
        if conv_byte_size(&conversation) > MAX_CONV_BYTES {
            compact_old_tool_results(&mut conversation, MAX_CONV_BYTES);
        }

        // Build provider-specific request
        let catalyst_input = provider.build_request(
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

            // Build tool results message (canonical format — single message)
            let tool_results_msg = provider.build_tool_results_message(&results);
            conversation.push(tool_results_msg);

            continue; // next turn
        }

        // No tool calls — this is the final response
        // Add assistant message to conversation for continuity
        let assistant_msg = provider.build_assistant_message(&data);
        conversation.push(assistant_msg);
        break;
    }

    // Strip base64 attachment data from conversation before persisting
    // (attachments are ephemeral — only needed for the initial LLM call)
    if !attachments.is_empty() {
        strip_attachment_data(&mut conversation);
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

/// Estimate conversation size in bytes by summing JSON-serialized message lengths.
fn conv_byte_size(conversation: &[Value]) -> usize {
    conversation
        .iter()
        .map(|m| serde_json::to_string(m).map(|s| s.len()).unwrap_or(0))
        .sum()
}

/// Truncate a string at a UTF-8 safe boundary, returning a borrowed slice.
pub(crate) fn truncate_str(s: &str, max_bytes: usize) -> &str {
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

        // --- Grok Responses API format: type "function_call_output" with output string ---
        let item_type = conversation[i]
            .get("type")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string();
        if item_type == "function_call_output" {
            let summary = {
                let text = conversation[i].get("output").and_then(|c| c.as_str());
                text.and_then(|t| {
                    if t.len() > PREVIEW_CHARS + 100 {
                        Some(smart_truncation_summary(t, PREVIEW_CHARS))
                    } else {
                        None
                    }
                })
            };
            if let Some(s) = summary {
                conversation[i]["output"] = json!(s);
            }
        }

        // Check if we're under target now
        if conv_byte_size(conversation) <= target_bytes {
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

fn build_initial_messages(
    parsed: &Value,
    task: &str,
    attachments: &[Value],
) -> Result<Vec<Value>, String> {
    let user_msg = build_user_message_with_attachments(task, attachments);

    // If conversation history provided, filter to canonical roles and append new user message
    if let Some(msgs) = parsed.get("messages").and_then(|v| v.as_array()) {
        if !msgs.is_empty() {
            let mut conversation: Vec<Value> = msgs
                .iter()
                .filter(|m| {
                    let role = m.get("role").and_then(|r| r.as_str()).unwrap_or("");
                    matches!(role, "user" | "assistant" | "tool_results")
                })
                .cloned()
                .collect();
            conversation.push(user_msg);
            return Ok(conversation);
        }
    }

    // Fresh conversation
    Ok(vec![user_msg])
}

/// Build a user message that includes text and optional attachment content blocks.
///
/// Always uses canonical (Claude-like) format regardless of provider.
/// Each provider's `build_request()` converts from canonical to API-specific format.
fn build_user_message_with_attachments(task: &str, attachments: &[Value]) -> Value {
    if attachments.is_empty() {
        // No attachments — plain string content
        return json!({"role": "user", "content": task});
    }

    // Always canonical (Claude) format — each build_request() converts
    let mut blocks = vec![json!({"type": "text", "text": task})];
    blocks.extend(providers::attachments::convert_for_claude(attachments));
    json!({"role": "user", "content": blocks})
}

/// Strip base64 attachment data from the first user message in the conversation,
/// replacing it with text placeholders. This keeps history small for follow-up turns.
///
/// Works with the canonical (Claude-like) format used by all providers.
fn strip_attachment_data(conversation: &mut [Value]) {
    // Only the first user message can have attachments
    if conversation.is_empty() {
        return;
    }

    let msg = &mut conversation[0];
    if msg.get("role").and_then(|r| r.as_str()) != Some("user") {
        return;
    }

    // Handle "content" array (canonical format)
    if let Some(content) = msg.get("content").and_then(|c| c.as_array()).cloned() {
        let new_content: Vec<Value> = content
            .into_iter()
            .map(|block| {
                let block_type = block.get("type").and_then(|t| t.as_str()).unwrap_or("");
                match block_type {
                    "image" | "document" => {
                        let mt = block
                            .get("source")
                            .and_then(|s| s.get("media_type"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown");
                        json!({"type": "text", "text": format!("[Attached file ({})]", mt)})
                    }
                    _ => block,
                }
            })
            .collect();
        msg["content"] = json!(new_content);
    }
}

