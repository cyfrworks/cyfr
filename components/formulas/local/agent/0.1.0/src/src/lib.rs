#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::formula::run::Guest;
use bindings::cyfr::formula::invoke;
use bindings::cyfr::mcp::tools;

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

const MAX_TURNS: usize = 10;
const MAX_TOOL_RESULT_CHARS: usize = 8000;

// ---------------------------------------------------------------------------
// Request handling — agentic loop
// ---------------------------------------------------------------------------

fn handle_request(input: &str) -> Result<String, String> {
    let parsed: Value =
        serde_json::from_str(input).map_err(|e| format!("Invalid JSON input: {e}"))?;

    let provider = parsed
        .get("provider")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing required 'provider' field".to_string())?;

    let model = parsed
        .get("model")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing required 'model' field".to_string())?;

    let system = parsed.get("system").and_then(|v| v.as_str());

    let extra_params = parsed.get("params").cloned().unwrap_or(json!({}));

    let user_tools = parsed.get("tools").and_then(|v| v.as_array()).cloned();

    let max_tokens = extra_params
        .get("max_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(8096);

    // Build initial messages from either "messages" array or "prompt" string
    let mut conversation = build_messages(&parsed)?;

    // Discover the LLM provider catalyst only
    let (component_ref, catalyst_name) = discover_provider_catalyst(provider)?;
    let lower_name = catalyst_name.to_lowercase();

    // Build tools: meta-tools + user-provided tools
    let mut tools_array: Vec<Value> = serde_json::from_value(build_meta_tools()).unwrap();
    if let Some(ut) = &user_tools {
        tools_array.extend(ut.iter().cloned());
    }
    let tools_for_llm = Some(Value::Array(tools_array));

    // --- Agentic loop ---
    let mut turns = 0;
    let mut all_text = String::new();

    loop {
        turns += 1;
        if turns > MAX_TURNS {
            // Return what we have so far
            break;
        }

        // Always use non-streaming in the loop so we get structured responses
        // (stop_reason, tool_use blocks, etc.)
        let catalyst_input = build_provider_request(
            &catalyst_name,
            model,
            &conversation,
            system,
            false, // non-streaming for structured response
            &extra_params,
            max_tokens,
            &tools_for_llm,
        );

        let invoke_request = json!({
            "reference": { "registry": &component_ref },
            "input": catalyst_input,
            "type": "catalyst"
        });

        let response_str = invoke::call(&invoke_request.to_string());

        let response: Value = serde_json::from_str(&response_str)
            .map_err(|e| format!("Failed to parse invoke response: {e}"))?;

        if let Some(err) = response.get("error") {
            return Err(format!("Invoke error: {err}"));
        }

        let output = response.get("output").cloned().unwrap_or(Value::Null);
        let catalyst_result = match &output {
            Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
            _ => output,
        };

        if let Some(err) = catalyst_result.get("error") {
            return Err(format!("Catalyst error: {err}"));
        }

        let data = catalyst_result.get("data").cloned().unwrap_or(Value::Null);

        // Check if the model wants to use tools (Claude-specific for now)
        if lower_name.contains("claude") {
            let stop_reason = data
                .get("stop_reason")
                .and_then(|v| v.as_str())
                .unwrap_or("end_turn");

            let content_blocks = data
                .get("content")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();

            if stop_reason == "tool_use" {
                // Add assistant message to conversation
                conversation.push(json!({
                    "role": "assistant",
                    "content": content_blocks
                }));

                // Execute each tool call and collect results
                let mut tool_results: Vec<Value> = Vec::new();

                for block in &content_blocks {
                    if block.get("type").and_then(|v| v.as_str()) == Some("tool_use") {
                        let tool_id = block.get("id").and_then(|v| v.as_str()).unwrap_or("");
                        let tool_name =
                            block.get("name").and_then(|v| v.as_str()).unwrap_or("");
                        let tool_input = block.get("input").cloned().unwrap_or(json!({}));

                        let result = execute_tool(tool_name, &tool_input);

                        tool_results.push(json!({
                            "type": "tool_result",
                            "tool_use_id": tool_id,
                            "content": result
                        }));
                    }
                }

                // Add tool results as user message
                conversation.push(json!({
                    "role": "user",
                    "content": tool_results
                }));

                // Also accumulate any text from this turn
                for block in &content_blocks {
                    if block.get("type").and_then(|v| v.as_str()) == Some("text") {
                        if let Some(t) = block.get("text").and_then(|v| v.as_str()) {
                            all_text.push_str(t);
                        }
                    }
                }

                continue; // next turn
            }

            // End turn — extract final text
            for block in &content_blocks {
                if block.get("type").and_then(|v| v.as_str()) == Some("text") {
                    if let Some(t) = block.get("text").and_then(|v| v.as_str()) {
                        all_text.push_str(t);
                    }
                }
            }
            break;
        } else {
            // Non-Claude: single turn, extract text and done
            all_text = extract_content(&catalyst_result, &catalyst_name);
            break;
        }
    }

    Ok(json!({
        "provider": provider,
        "model": model,
        "content": all_text,
        "turns": turns,
        "component_ref": component_ref
    })
    .to_string())
}

// ---------------------------------------------------------------------------
// Provider catalyst discovery via MCP
// ---------------------------------------------------------------------------

fn discover_provider_catalyst(provider: &str) -> Result<(String, String), String> {
    let search_request = json!({
        "tool": "component",
        "action": "search",
        "args": {
            "query": provider,
            "type": "catalyst"
        }
    });

    let search_response_str = tools::call(&search_request.to_string());

    let search_response: Value = serde_json::from_str(&search_response_str)
        .map_err(|e| format!("Failed to parse MCP search response: {e}"))?;

    if let Some(err) = search_response.get("error") {
        return Err(format!("MCP search error: {err}"));
    }

    let result = search_response
        .get("result")
        .ok_or_else(|| "MCP search returned no result".to_string())?;

    let components = result
        .get("components")
        .and_then(|v| v.as_array())
        .ok_or_else(|| "MCP search result missing 'components' array".to_string())?;

    let catalyst = components
        .iter()
        .find(|c| {
            c.get("name")
                .and_then(|v| v.as_str())
                .map(|n| n.eq_ignore_ascii_case(provider))
                .unwrap_or(false)
        })
        .ok_or_else(|| format!("No catalyst found for provider '{provider}'"))?;

    let name = catalyst
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string();
    let version = catalyst
        .get("version")
        .and_then(|v| v.as_str())
        .unwrap_or("0.1.0")
        .to_string();
    let publisher = catalyst
        .get("publisher")
        .and_then(|v| v.as_str())
        .unwrap_or("local")
        .to_string();

    let component_ref = format!("catalyst:{publisher}.{name}:{version}");
    Ok((component_ref, name))
}

// ---------------------------------------------------------------------------
// Meta-tools — LLM-driven discovery and invocation
// ---------------------------------------------------------------------------

fn build_meta_tools() -> Value {
    json!([
        {
            "name": "component_search",
            "description": "Search the CYFR component registry for available catalysts, reagents, and formulas. Returns name, version, publisher, description for each match.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query (matches name and description)"
                    },
                    "type": {
                        "type": "string",
                        "enum": ["catalyst", "reagent", "formula"],
                        "description": "Filter by component type"
                    }
                }
            }
        },
        {
            "name": "component_inspect",
            "description": "Get full details of a component including its manifest with operation schemas and usage examples. Use this to learn how to use a component before invoking it.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "reference": {
                        "type": "string",
                        "description": "Component reference (e.g. 'catalyst:local.web:0.1.0')"
                    }
                },
                "required": ["reference"]
            }
        },
        {
            "name": "invoke_catalyst",
            "description": "Invoke a catalyst component. Use component_inspect first to learn the expected input format (operations and parameters).",
            "input_schema": {
                "type": "object",
                "properties": {
                    "reference": {
                        "type": "string",
                        "description": "Catalyst registry reference (e.g. 'catalyst:local.web:0.1.0')"
                    },
                    "input": {
                        "type": "object",
                        "description": "Catalyst input — typically {\"operation\": \"...\", \"params\": {...}}"
                    }
                },
                "required": ["reference", "input"]
            }
        }
    ])
}

// ---------------------------------------------------------------------------
// Tool execution — meta-tools + MCP fallback
// ---------------------------------------------------------------------------

fn execute_tool(tool_name: &str, tool_input: &Value) -> String {
    match tool_name {
        "component_search" => {
            let request = json!({
                "tool": "component",
                "action": "search",
                "args": tool_input
            });
            let response = tools::call(&request.to_string());
            truncate_result(&response)
        }
        "component_inspect" => {
            let reference = tool_input.get("reference").and_then(|v| v.as_str()).unwrap_or("");
            let request = json!({
                "tool": "component",
                "action": "inspect",
                "args": { "reference": reference }
            });
            let response = tools::call(&request.to_string());
            truncate_result(&response)
        }
        "invoke_catalyst" => {
            let reference = tool_input.get("reference").and_then(|v| v.as_str()).unwrap_or("");
            let input = tool_input.get("input").cloned().unwrap_or(json!({}));
            let request = json!({
                "reference": { "registry": reference },
                "input": input,
                "type": "catalyst"
            });
            let response_str = invoke::call(&request.to_string());
            extract_invoke_result(&response_str)
        }
        _ => {
            // Fallback: try MCP tools.call
            let request = json!({ "tool": tool_name, "action": "execute", "args": tool_input });
            let response = tools::call(&request.to_string());
            truncate_result(&response)
        }
    }
}

fn extract_invoke_result(response_str: &str) -> String {
    let result = match serde_json::from_str::<Value>(response_str) {
        Ok(response) => {
            if let Some(err) = response.get("error") {
                return format!("Catalyst invocation error: {err}");
            }

            let output = response.get("output").cloned().unwrap_or(Value::Null);
            let catalyst_result = match &output {
                Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
                _ => output,
            };

            if let Some(data) = catalyst_result.get("data") {
                serde_json::to_string_pretty(data)
                    .unwrap_or_else(|_| data.to_string())
            } else {
                serde_json::to_string_pretty(&catalyst_result)
                    .unwrap_or_else(|_| catalyst_result.to_string())
            }
        }
        Err(e) => format!("Failed to parse catalyst response: {e}"),
    };

    truncate_result(&result)
}

fn truncate_result(s: &str) -> String {
    if s.len() <= MAX_TOOL_RESULT_CHARS {
        s.to_string()
    } else {
        let truncated = &s[..MAX_TOOL_RESULT_CHARS];
        format!("{truncated}\n\n[... truncated, showing first {MAX_TOOL_RESULT_CHARS} chars of {} total]", s.len())
    }
}

// ---------------------------------------------------------------------------
// Message building
// ---------------------------------------------------------------------------

fn build_messages(parsed: &Value) -> Result<Vec<Value>, String> {
    if let Some(msgs) = parsed.get("messages").and_then(|v| v.as_array()) {
        if msgs.is_empty() {
            return Err("'messages' array is empty".to_string());
        }
        return Ok(msgs.clone());
    }

    if let Some(prompt) = parsed.get("prompt").and_then(|v| v.as_str()) {
        return Ok(vec![json!({"role": "user", "content": prompt})]);
    }

    Err("Either 'prompt' or 'messages' must be provided".to_string())
}

// ---------------------------------------------------------------------------
// Provider-specific request building
// ---------------------------------------------------------------------------

fn build_provider_request(
    catalyst_name: &str,
    model: &str,
    messages: &[Value],
    system: Option<&str>,
    stream: bool,
    extra_params: &Value,
    max_tokens: u64,
    tools: &Option<Value>,
) -> Value {
    let lower = catalyst_name.to_lowercase();

    let mut request = if lower.contains("claude") {
        build_claude_request(model, messages, system, stream, max_tokens, tools)
    } else if lower.contains("openai") {
        build_openai_request(model, messages, system, stream)
    } else if lower.contains("gemini") {
        build_gemini_request(model, messages, system, stream)
    } else {
        build_generic_request(model, messages, system, stream)
    };

    // Merge any extra params that weren't already set
    if let (Some(req_obj), Some(extra_obj)) = (
        request
            .get_mut("params")
            .and_then(|v| v.as_object_mut()),
        extra_params.as_object(),
    ) {
        for (k, v) in extra_obj {
            // Don't override max_tokens since we handle it explicitly
            if k != "max_tokens" && !req_obj.contains_key(k) {
                req_obj.insert(k.clone(), v.clone());
            }
        }
    }

    request
}

fn build_claude_request(
    model: &str,
    messages: &[Value],
    system: Option<&str>,
    stream: bool,
    max_tokens: u64,
    tools: &Option<Value>,
) -> Value {
    let operation = if stream {
        "messages.stream"
    } else {
        "messages.create"
    };

    let mut params = json!({
        "model": model,
        "max_tokens": max_tokens,
        "messages": messages,
    });

    if let Some(sys) = system {
        params["system"] = json!(sys);
    }

    if let Some(t) = tools {
        params["tools"] = t.clone();
    }

    json!({
        "operation": operation,
        "params": params,
    })
}

fn build_openai_request(
    model: &str,
    messages: &[Value],
    system: Option<&str>,
    stream: bool,
) -> Value {
    let mut all_messages = Vec::new();
    if let Some(sys) = system {
        all_messages.push(json!({"role": "system", "content": sys}));
    }
    all_messages.extend_from_slice(messages);

    json!({
        "operation": "chat.completions.create",
        "stream": stream,
        "params": {
            "model": model,
            "messages": all_messages,
        },
    })
}

fn build_gemini_request(
    model: &str,
    messages: &[Value],
    system: Option<&str>,
    stream: bool,
) -> Value {
    let operation = if stream {
        "content.stream"
    } else {
        "content.generate"
    };

    let contents: Vec<Value> = messages
        .iter()
        .map(|msg| {
            let role = msg
                .get("role")
                .and_then(|v| v.as_str())
                .unwrap_or("user");
            let text = msg
                .get("content")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            json!({
                "role": role,
                "parts": [{"text": text}]
            })
        })
        .collect();

    let mut params = json!({
        "model": model,
        "contents": contents,
    });

    if let Some(sys) = system {
        params["systemInstruction"] = json!({"parts": [{"text": sys}]});
    }

    json!({
        "operation": operation,
        "params": params,
    })
}

fn build_generic_request(
    model: &str,
    messages: &[Value],
    system: Option<&str>,
    stream: bool,
) -> Value {
    let mut params = json!({
        "model": model,
        "messages": messages,
    });

    if let Some(sys) = system {
        params["system"] = json!(sys);
    }

    json!({
        "operation": "chat.create",
        "stream": stream,
        "params": params,
    })
}

// ---------------------------------------------------------------------------
// Response text extraction (non-streaming, non-Claude)
// ---------------------------------------------------------------------------

fn extract_content(catalyst_result: &Value, catalyst_name: &str) -> String {
    let data = match catalyst_result.get("data") {
        Some(d) => d,
        None => return String::new(),
    };

    // Streaming combined_text
    if let Some(text) = data.get("combined_text").and_then(|v| v.as_str()) {
        return text.to_string();
    }

    let lower = catalyst_name.to_lowercase();

    if lower.contains("openai") {
        if let Some(text) = data
            .get("choices")
            .and_then(|v| v.as_array())
            .and_then(|arr| arr.first())
            .and_then(|choice| choice.get("message"))
            .and_then(|msg| msg.get("content"))
            .and_then(|v| v.as_str())
        {
            return text.to_string();
        }
    } else if lower.contains("gemini") {
        if let Some(text) = data
            .get("candidates")
            .and_then(|v| v.as_array())
            .and_then(|arr| arr.first())
            .and_then(|candidate| candidate.get("content"))
            .and_then(|content| content.get("parts"))
            .and_then(|v| v.as_array())
            .and_then(|parts| parts.first())
            .and_then(|part| part.get("text"))
            .and_then(|v| v.as_str())
        {
            return text.to_string();
        }
    }

    String::new()
}
