#[allow(warnings)]
mod bindings;
mod context;
mod providers;
mod tools;

use bindings::exports::cyfr::formula::run::Guest;
use bindings::cyfr::formula::invoke;

use providers::detect_provider;
use serde_json::{json, Value};
pub use tools::SubAgentDef;

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

    // Text the host reads beside the task for this one call — a room the
    // person has open next to the thread. It is other people's words, so
    // it is placed as a part of the task's user turn for the model and
    // taken back out before the history is returned: never persisted,
    // never read by a later turn.
    let transient = parsed
        .get("transient")
        .and_then(|v| v.as_str())
        .filter(|t| !t.is_empty());

    let max_turns = DEFAULT_MAX_TURNS;

    let custom_system = parsed.get("system").and_then(|v| v.as_str());

    let max_tokens = parsed
        .get("max_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(DEFAULT_MAX_TOKENS);

    let role = parsed.get("role").and_then(|v| v.as_str()).unwrap_or("");
    let emit_tag = parsed.get("emit_tag").and_then(|v| v.as_str()).unwrap_or("");

    // --- Parse the roster: the roles this run may clone into ---
    let sub_agents: Vec<SubAgentDef> = parsed
        .get("sub_agents")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(SubAgentDef::from_value).collect())
        .unwrap_or_default();

    // --- Per-agent tool allowlist ---
    // `tool_policy`: {"tool.action" | "tool.*" => "ask" | "auto"} — the ONLY
    // tool surface. Each tool's `action` enum is filtered to its "auto"
    // verbs; "ask" actions reach the agent via the approval prelude in the
    // system prompt instead. A role is granted by its name. An absent policy is
    // an empty allowlist: the model sees no tools at all (fail-closed), and
    // the native provider tool appears only when the policy names it.
    let tool_policy: Value = parsed
        .get("tool_policy")
        .filter(|p| p.is_object())
        .cloned()
        .unwrap_or_else(|| json!({}));

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
    let task_index = conversation.len() - 1;
    if let Some(text) = transient {
        put_transient(&mut conversation[task_index], text);
    }

    // --- Build system prompt (passthrough from caller) ---
    let system_prompt = context::build_system_prompt(custom_system);

    // --- Build tool definitions, apply the allowlist, build the dispatch guard ---
    let canonical_tools = tools::build_tool_definitions(&sub_agents);
    let policy_guard = tools::PolicyGuard::new(&tool_policy, &canonical_tools, &sub_agents);
    let canonical_tools = tools::apply_tool_policy(canonical_tools, &tool_policy);
    let native_search = providers::native_search_allowed(&tool_policy);
    let tools_for_llm = provider.format_tools(&canonical_tools, native_search);

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
            native_search,
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
                    // When the model runs a formula itself, inject our own
                    // catalyst_ref and model so the child uses the provider
                    // the user selected — models may hallucinate these.
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

            let results = tools::execute_tools_parallel(&call_tuples, catalyst_ref, model, &sub_agents, &policy_guard);

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

    // What was read beside the task was for this call alone.
    if transient.is_some() {
        strip_transient(&mut conversation[task_index]);
    }

    // Attachments are ephemeral — only the call they arrived with needs the
    // bytes. Strip them from the whole history before it is persisted, so a
    // turn that carried none still cleans up what an earlier one left.
    strip_attachment_data(&mut conversation);

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
    conversation.iter().map(message_byte_size).sum()
}

fn message_byte_size(message: &Value) -> usize {
    serde_json::to_string(message).map(|s| s.len()).unwrap_or(0)
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

/// Compact older tool results to bring the conversation under `target_bytes`.
///
/// Walks messages from oldest to newest, truncating each tool result's
/// content, and stops as soon as the running size is under target. The final
/// turn — the last assistant message and everything after it — is left intact
/// so the model always has full context for its immediate previous action.
fn compact_old_tool_results(conversation: &mut [Value], target_bytes: usize) {
    const PREVIEW_CHARS: usize = 500;

    let protected_from = conversation
        .iter()
        .rposition(|m| m.get("role").and_then(|r| r.as_str()) == Some("assistant"))
        .unwrap_or(conversation.len());
    let mut size = conv_byte_size(conversation);

    for message in conversation[..protected_from].iter_mut() {
        if size <= target_bytes {
            break;
        }
        let before = message_byte_size(message);
        compact_message(message, PREVIEW_CHARS);
        size = size - before + message_byte_size(message);
    }
}

/// Truncate every tool result carried by one history message. Every provider
/// records results in the canonical `{"role":"tool_results","results":[…]}`
/// shape; a `user` message whose content array carries Claude-style
/// `tool_result` blocks (history the harness compacted itself) is handled
/// the same way.
fn compact_message(message: &mut Value, preview_chars: usize) {
    match message.get("role").and_then(|r| r.as_str()) {
        Some("tool_results") => {
            if let Some(results) = message.get_mut("results").and_then(|r| r.as_array_mut()) {
                for result in results {
                    compact_content(result, preview_chars);
                }
            }
        }
        Some("user") => {
            if let Some(blocks) = message.get_mut("content").and_then(|c| c.as_array_mut()) {
                for block in blocks
                    .iter_mut()
                    .filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("tool_result"))
                {
                    compact_content(block, preview_chars);
                }
            }
        }
        _ => {}
    }
}

/// Replace a long `content` (a string, or any JSON value) with its summary.
fn compact_content(holder: &mut Value, preview_chars: usize) {
    let Some(content) = holder.get("content") else { return };
    let text = match content {
        Value::String(s) => s.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    };
    if text.len() > preview_chars + 100 {
        holder["content"] = json!(smart_truncation_summary(&text, preview_chars));
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

/// Put the transient text in front of the task, as the first block of the
/// user turn. `strip_transient` is its exact inverse.
fn put_transient(message: &mut Value, text: &str) {
    let block = json!({"type": "text", "text": text});
    let Some(content) = message.get_mut("content") else { return };
    match content {
        Value::String(task) => {
            let task = std::mem::take(task);
            *content = json!([block, {"type": "text", "text": task}]);
        }
        Value::Array(blocks) => blocks.insert(0, block),
        _ => {}
    }
}

/// Take the transient block back out of the task turn; a turn that was a
/// plain string before is a plain string again.
fn strip_transient(message: &mut Value) {
    let collapse = {
        let Some(blocks) = message.get_mut("content").and_then(|c| c.as_array_mut()) else {
            return;
        };
        if blocks.is_empty() {
            return;
        }
        blocks.remove(0);
        match blocks.as_slice() {
            [only] if only.get("type").and_then(|t| t.as_str()) == Some("text") => {
                only.get("text").and_then(|t| t.as_str()).map(str::to_string)
            }
            _ => None,
        }
    };
    if let Some(task) = collapse {
        message["content"] = Value::String(task);
    }
}

/// Replace every base64 attachment block in the conversation with a text
/// placeholder, so the history kept for follow-up turns stays small.
///
/// Works with the canonical (Claude-like) content blocks used by all providers.
fn strip_attachment_data(conversation: &mut [Value]) {
    for message in conversation.iter_mut() {
        let Some(blocks) = message.get_mut("content").and_then(|c| c.as_array_mut()) else {
            continue;
        };
        for block in blocks.iter_mut() {
            if !matches!(block.get("type").and_then(|t| t.as_str()), Some("image" | "document")) {
                continue;
            }
            let media_type = block
                .get("source")
                .and_then(|s| s.get("media_type"))
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            *block = json!({"type": "text", "text": format!("[Attached file ({media_type})]")});
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_transient_is_read_with_the_task_and_never_kept() {
        let mut plain = json!({"role": "user", "content": "what do they mean?"});
        put_transient(&mut plain, "## Read from the room\n\nBob: ship friday");
        assert_eq!(plain["content"][0]["text"], "## Read from the room\n\nBob: ship friday");
        assert_eq!(plain["content"][1]["text"], "what do they mean?");
        strip_transient(&mut plain);
        assert_eq!(plain, json!({"role": "user", "content": "what do they mean?"}));

        let image = json!({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AAAA"}});
        let mut with_attachment = json!({"role": "user", "content": [{"type": "text", "text": "look"}, image]});
        put_transient(&mut with_attachment, "room");
        assert_eq!(with_attachment["content"].as_array().unwrap().len(), 3);
        strip_transient(&mut with_attachment);
        assert_eq!(with_attachment["content"][0]["text"], "look");
        assert_eq!(with_attachment["content"][1]["type"], "image");
        assert_eq!(with_attachment["content"].as_array().unwrap().len(), 2);
    }

    fn tool_results(id: &str, content: String) -> Value {
        json!({"role": "tool_results", "results": [{"tool_call_id": id, "name": "files", "content": content}]})
    }

    #[test]
    fn compaction_shrinks_canonical_tool_results_and_spares_the_last_turn() {
        let big = "x".repeat(10_000);
        let mut conversation = vec![
            json!({"role": "user", "content": "start"}),
            json!({"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "name": "files", "arguments": {}}]}),
            tool_results("c1", big.clone()),
            json!({"role": "assistant", "content": "", "tool_calls": [{"id": "c2", "name": "files", "arguments": {}}]}),
            tool_results("c2", big.clone()),
            json!({"role": "assistant", "content": "", "tool_calls": [{"id": "c3", "name": "files", "arguments": {}}]}),
            tool_results("c3", big.clone()),
        ];
        let before = conv_byte_size(&conversation);
        assert!(before > 30_000);

        compact_old_tool_results(&mut conversation, 15_000);

        assert!(conv_byte_size(&conversation) < 15_000);
        let content = |i: usize| conversation[i]["results"][0]["content"].as_str().unwrap().to_string();
        assert!(content(2).starts_with("[Result truncated: was 10000 bytes."));
        assert!(content(4).starts_with("[Result truncated: was 10000 bytes."));
        // The final turn keeps its full result.
        assert_eq!(content(6), big);
    }

    #[test]
    fn compaction_stops_once_under_target() {
        let big = "x".repeat(10_000);
        let mut conversation = vec![
            json!({"role": "assistant", "content": "", "tool_calls": []}),
            tool_results("c1", big.clone()),
            json!({"role": "assistant", "content": "", "tool_calls": []}),
            tool_results("c2", big.clone()),
            json!({"role": "assistant", "content": "final"}),
        ];
        compact_old_tool_results(&mut conversation, 15_000);
        assert!(conversation[1]["results"][0]["content"].as_str().unwrap().starts_with("[Result truncated"));
        assert_eq!(conversation[3]["results"][0]["content"], big);
    }

    #[test]
    fn compaction_handles_claude_style_tool_result_blocks() {
        let big = "x".repeat(10_000);
        let mut conversation = vec![
            json!({"role": "user", "content": [{"type": "tool_result", "tool_use_id": "c1", "content": big}]}),
            json!({"role": "assistant", "content": "final"}),
        ];
        compact_old_tool_results(&mut conversation, 1_000);
        assert!(conversation[0]["content"][0]["content"].as_str().unwrap().starts_with("[Result truncated"));
    }

    #[test]
    fn attachments_are_stripped_from_every_message() {
        let image = json!({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AAAA"}});
        let pdf = json!({"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": "BBBB"}});
        let mut conversation = vec![
            json!({"role": "user", "content": [{"type": "text", "text": "first"}, image]}),
            json!({"role": "assistant", "content": "ok"}),
            json!({"role": "user", "content": [{"type": "text", "text": "second"}, pdf]}),
        ];

        strip_attachment_data(&mut conversation);

        assert_eq!(conversation[0]["content"][1], json!({"type": "text", "text": "[Attached file (image/png)]"}));
        assert_eq!(conversation[2]["content"][1], json!({"type": "text", "text": "[Attached file (application/pdf)]"}));
        assert_eq!(conversation[1], json!({"role": "assistant", "content": "ok"}));
        assert!(!serde_json::to_string(&conversation).unwrap().contains("AAAA"));
    }
}

