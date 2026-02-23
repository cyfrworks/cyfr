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
    Provider { key: "claude",  registry_ref: "catalyst:local.claude:0.3.0"  },
    Provider { key: "openai",  registry_ref: "catalyst:local.openai:0.3.0"  },
    Provider { key: "gemini",  registry_ref: "catalyst:local.gemini:0.3.0"  },
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
        // Single provider: use direct invoke::call (no batch overhead)
        return invoke_single(&providers);
    }

    // Multiple providers: use parallel batch invocation
    invoke_batch(&providers)
}

// ---------------------------------------------------------------------------
// Single-provider path (no batch overhead)
// ---------------------------------------------------------------------------

fn invoke_single(providers: &[&Provider]) -> Result<String, String> {
    let provider = providers[0];
    let mut models = json!({});
    let mut errors = json!({});

    match invoke_models_list(provider) {
        Ok(data) => {
            models[provider.key] = data;
        }
        Err(e) => {
            errors[provider.key] = Value::String(e);
        }
    }

    Ok(json!({ "models": models, "errors": errors }).to_string())
}

// ---------------------------------------------------------------------------
// Multi-provider parallel batch invocation
// ---------------------------------------------------------------------------

fn invoke_batch(providers: &[&Provider]) -> Result<String, String> {
    // Build invocations array
    let invocations: Vec<Value> = providers
        .iter()
        .map(|p| {
            json!({
                "reference": { "registry": p.registry_ref },
                "input": { "operation": "models.list", "params": {} },
                "type": "catalyst"
            })
        })
        .collect();

    let batch_request = json!({ "invocations": invocations });
    let batch_response_str = invoke::call_batch(&batch_request.to_string());
    let batch_response: Value = serde_json::from_str(&batch_response_str)
        .map_err(|e| format!("Failed to parse call-batch response: {e}"))?;

    if let Some(err) = batch_response.get("error") {
        return Err(format!("Batch invocation error: {err}"));
    }

    let batch_handle = batch_response
        .get("batch")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing batch handle in call-batch response".to_string())?
        .to_string();

    // Poll until all done
    let poll_request = json!({ "batch": &batch_handle });
    let mut results: Value;
    loop {
        let poll_response_str = invoke::poll_all(&poll_request.to_string());
        let poll_response: Value = serde_json::from_str(&poll_response_str)
            .map_err(|e| format!("Failed to parse poll-all response: {e}"))?;

        let all_done = poll_response
            .get("all_done")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        if all_done {
            results = poll_response
                .get("results")
                .cloned()
                .unwrap_or(json!([]));
            break;
        }
    }

    // Close the batch
    let close_request = json!({ "batch": &batch_handle });
    let _ = invoke::close(&close_request.to_string());

    // Map results back to provider keys
    let mut models = json!({});
    let mut errors = json!({});

    let results_arr = results.as_array().cloned().unwrap_or_default();
    for (i, provider) in providers.iter().enumerate() {
        let result = results_arr.get(i).cloned().unwrap_or(json!({"status": "error", "error": "Missing result"}));
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

    Ok(json!({ "models": models, "errors": errors }).to_string())
}

// ---------------------------------------------------------------------------
// Parse catalyst output from an invoke result
// ---------------------------------------------------------------------------

fn parse_catalyst_output(result: &Value) -> Result<Value, String> {
    let output = result.get("output").cloned().unwrap_or(Value::Null);

    let catalyst_result = match &output {
        Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
        _ => output,
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
        "reference": { "registry": provider.registry_ref },
        "input": { "operation": "models.list", "params": {} },
        "type": "catalyst"
    });

    let response_str = invoke::call(&request.to_string());

    let response: Value = serde_json::from_str(&response_str)
        .map_err(|e| format!("Failed to parse invoke response: {e}"))?;

    parse_catalyst_output(&response)
}
