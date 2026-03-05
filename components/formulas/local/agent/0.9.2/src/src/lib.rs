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

    let max_turns = parsed
        .get("max_turns")
        .and_then(|v| v.as_u64())
        .unwrap_or(DEFAULT_MAX_TURNS as u64) as usize;

    let custom_system = parsed.get("system").and_then(|v| v.as_str());

    let max_tokens = parsed
        .get("max_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(DEFAULT_MAX_TOKENS);

    // --- Detect provider from catalyst_ref ---
    let provider = detect_provider(catalyst_ref);

    // --- Build initial conversation ---
    let mut conversation = build_initial_messages(&parsed, task)?;

    // --- Build system prompt (passthrough from caller) ---
    let system_prompt = context::build_system_prompt(custom_system);

    // --- Build tool definitions ---
    let tools_for_llm = tools::build_tool_definitions(provider);

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
        let _ = invoke::emit(&json!({"kind": "turn_start", "turn": turns}).to_string());

        // Build provider-specific request
        let catalyst_input = build_provider_request(
            provider,
            catalyst_ref,
            model,
            &conversation,
            &system_prompt,
            max_tokens,
            &tools_for_llm,
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
            result.clone()
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
            let _ = invoke::emit(&json!({
                "kind": "usage",
                "turn": turns,
                "input_tokens": input_tokens,
                "output_tokens": output_tokens
            }).to_string());
        }

        // Accumulate any text from this turn
        let turn_text = provider.extract_text(&data);
        if !turn_text.is_empty() {
            all_text.push_str(&turn_text);
            // Emit text delta event
            let _ = invoke::emit(&json!({
                "kind": "text_delta",
                "content": turn_text,
                "turn": turns
            }).to_string());
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
                let _ = invoke::emit(&json!({
                    "kind": "tool_use",
                    "tool": tc.name,
                    "tool_call_id": tc.id,
                    "input": tc.arguments,
                    "turn": turns
                }).to_string());
            }

            let call_tuples: Vec<(String, String, Value)> = tool_calls
                .iter()
                .map(|tc| (tc.id.clone(), tc.name.clone(), tc.arguments.clone()))
                .collect();

            let results = tools::execute_tools_parallel(&call_tuples);

            // Emit tool_result events
            for (id, name, result) in &results {
                let preview = if result.len() > 500 { &result[..500] } else { result.as_str() };
                let _ = invoke::emit(&json!({
                    "kind": "tool_result",
                    "tool": name,
                    "tool_call_id": id,
                    "preview": preview,
                    "turn": turns
                }).to_string());
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
    let _ = invoke::emit(&json!({
        "kind": "conversation_complete",
        "messages": conversation
    }).to_string());

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
) -> Value {
    match provider {
        Provider::Claude => build_claude_request(model, messages, system, max_tokens, tools),
        Provider::OpenAI => build_openai_request(catalyst_ref, model, messages, system, tools),
        Provider::Gemini => build_gemini_request(model, messages, system, tools),
        Provider::Generic => build_claude_request(model, messages, system, max_tokens, tools),
    }
}

fn build_claude_request(
    model: &str,
    messages: &[Value],
    system: &str,
    max_tokens: u64,
    tools: &Value,
) -> Value {
    let mut params = json!({
        "model": model,
        "max_tokens": max_tokens,
        "messages": messages,
        "system": system,
    });

    // Merge MCP tools with provider built-in tools
    let mut all_tools: Vec<Value> = tools.as_array().cloned().unwrap_or_default();
    all_tools.push(json!({"type": "web_search_20250305", "name": "web_search"}));
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
    if lower_ref.contains("openai") && !lower_ref.contains("openrouter") {
        // Direct OpenAI — add web search via Chat Completions
        all_tools.push(json!({"type": "web_search_preview"}));
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

    // Note: Gemini does not allow combining google_search/url_context with
    // functionDeclarations in the same request, so we only include MCP tools.
    if let Some(arr) = tools.as_array() {
        if !arr.is_empty() {
            params["tools"] = tools.clone();
        }
    }

    json!({
        "operation": "content.generate",
        "params": params,
    })
}
