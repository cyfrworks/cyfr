#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::formula::run::Guest;
use bindings::cyfr::formula::invoke;

use serde_json::{json, Value};

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        match handle_request(&input) {
            Ok(output) => output,
            Err(e) => json!({
                "models": {},
                "refs": {},
                "errors": {"formula": e}
            }).to_string(),
        }
    }
}

bindings::export!(Component with_types_in bindings);

// ---------------------------------------------------------------------------
// Provider configuration
// ---------------------------------------------------------------------------

struct Provider {
    key: &'static str,
    registry_ref: &'static str,
}

const ALL_PROVIDERS: &[Provider] = &[
    Provider { key: "claude",     registry_ref: "catalyst:moonmoon69.claude:1.0.0"     },
    Provider { key: "openai",     registry_ref: "catalyst:moonmoon69.openai:1.0.0"     },
    Provider { key: "gemini",     registry_ref: "catalyst:moonmoon69.gemini:1.0.0"     },
    Provider { key: "grok",       registry_ref: "catalyst:moonmoon69.grok:1.0.0"       },
    Provider { key: "openrouter", registry_ref: "catalyst:moonmoon69.openrouter:1.0.0" },
];

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

fn handle_request(input: &str) -> Result<String, String> {
    let parsed: Value = if input.is_empty() {
        json!({})
    } else {
        serde_json::from_str(input).map_err(|e| format!("Invalid JSON input: {e}"))?
    };

    // Determine which providers to query
    let filter: Option<Vec<String>> = parsed
        .get("providers")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        });

    let providers: Vec<&Provider> = match &filter {
        Some(names) => ALL_PROVIDERS
            .iter()
            .filter(|p| names.iter().any(|n| n == p.key))
            .collect(),
        None => ALL_PROVIDERS.iter().collect(),
    };

    if providers.len() == 1 {
        // Single provider: use direct invoke::call (no async overhead)
        return invoke_single(&providers);
    }

    // Multiple providers: spawn all, then await-all
    invoke_parallel(&providers)
}

// ---------------------------------------------------------------------------
// Single-provider path (no async overhead)
// ---------------------------------------------------------------------------

fn invoke_single(providers: &[&Provider]) -> Result<String, String> {
    let provider = providers[0];
    let mut models = json!({});
    let mut errors = json!({});
    let mut refs = json!({});

    refs[provider.key] = Value::String(provider.registry_ref.to_string());

    match invoke_models_list(provider) {
        Ok(data) => {
            models[provider.key] = data;
        }
        Err(e) => {
            errors[provider.key] = Value::String(e);
        }
    }

    Ok(json!({ "models": models, "refs": refs, "errors": errors }).to_string())
}

// ---------------------------------------------------------------------------
// Multi-provider parallel invocation via spawn + await-all
// ---------------------------------------------------------------------------

fn invoke_parallel(providers: &[&Provider]) -> Result<String, String> {
    // Spawn all invocations
    let mut task_ids: Vec<String> = Vec::new();

    for provider in providers {
        let request = json!({
            "tool": "execution",
            "action": "run",
            "args": {
                "reference": provider.registry_ref,
                "input": { "operation": "models.list", "params": {} },
                "type": "catalyst"
            }
        });

        let spawn_response_str = invoke::spawn(&request.to_string());
        let spawn_response: Value = serde_json::from_str(&spawn_response_str)
            .map_err(|e| format!("Failed to parse spawn response: {e}"))?;

        if let Some(err) = spawn_response.get("error") {
            return Err(format!("Spawn error: {err}"));
        }

        let task_id = spawn_response
            .get("task_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "Spawn response missing task_id".to_string())?
            .to_string();

        task_ids.push(task_id);
    }

    // Await all tasks
    let await_request = json!({ "task_ids": task_ids });
    let response_str = invoke::await_all(&await_request.to_string());
    let response: Value = serde_json::from_str(&response_str)
        .map_err(|e| format!("Failed to parse await-all response: {e}"))?;

    if let Some(err) = response.get("error") {
        return Err(format!("Await-all error: {err}"));
    }

    let results = response
        .get("results")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    // Map results back to provider keys (results are in spawn order)
    let mut models = json!({});
    let mut errors = json!({});
    let mut refs = json!({});

    for (i, provider) in providers.iter().enumerate() {
        refs[provider.key] = Value::String(provider.registry_ref.to_string());
        let result = results.get(i).cloned().unwrap_or(json!({"status": "error", "error": {"message": "Missing result"}}));
        let status = result.get("status").and_then(|v| v.as_str()).unwrap_or("error");

        if status == "completed" {
            match parse_catalyst_output(&result) {
                Ok(data) => {
                    models[provider.key] = data;
                }
                Err(e) => {
                    errors[provider.key] = Value::String(e);
                }
            }
        } else {
            let err_msg = result.get("error").map(|e| e.to_string()).unwrap_or_else(|| format!("status: {status}"));
            errors[provider.key] = Value::String(err_msg);
        }
    }

    Ok(json!({ "models": models, "refs": refs, "errors": errors }).to_string())
}

// ---------------------------------------------------------------------------
// Parse catalyst output from an invoke result
// ---------------------------------------------------------------------------

fn parse_catalyst_output(result: &Value) -> Result<Value, String> {
    let output = result.get("output").cloned().unwrap_or(Value::Null);

    // MCP execution.run wraps result — check for inner result field
    let catalyst_result = if let Some(inner) = output.get("result") {
        inner.clone()
    } else {
        match &output {
            Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
            _ => output,
        }
    };

    if let Some(err) = catalyst_result.get("error") {
        return Err(err.to_string());
    }

    Ok(catalyst_result.get("data").cloned().unwrap_or(catalyst_result))
}

// ---------------------------------------------------------------------------
// Invoke a catalyst's models.list (single, synchronous)
// ---------------------------------------------------------------------------

fn invoke_models_list(provider: &Provider) -> Result<Value, String> {
    let request = json!({
        "tool": "execution",
        "action": "run",
        "args": {
            "reference": provider.registry_ref,
            "input": { "operation": "models.list", "params": {} },
            "type": "catalyst"
        }
    });

    let response_str = invoke::call(&request.to_string());

    let response: Value = serde_json::from_str(&response_str)
        .map_err(|e| format!("Failed to parse invoke response: {e}"))?;

    // Check for invoke/executor-level errors first
    if let Some(err) = response.get("error") {
        return Err(format!("Invoke error: {err}"));
    }

    parse_catalyst_output(&response)
}
