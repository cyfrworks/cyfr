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
    local_path: &'static str,
}

const ALL_PROVIDERS: &[Provider] = &[
    Provider { key: "claude",  local_path: "components/catalysts/local/claude/0.1.0/catalyst.wasm"  },
    Provider { key: "openai",  local_path: "components/catalysts/local/openai/0.1.0/catalyst.wasm"  },
    Provider { key: "gemini",  local_path: "components/catalysts/local/gemini/0.1.0/catalyst.wasm"  },
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

    let mut models = json!({});
    let mut errors = json!({});

    for provider in &providers {
        match invoke_models_list(provider) {
            Ok(data) => {
                models[provider.key] = data;
            }
            Err(e) => {
                errors[provider.key] = Value::String(e);
            }
        }
    }

    Ok(json!({ "models": models, "errors": errors }).to_string())
}

// ---------------------------------------------------------------------------
// Invoke a catalyst's models.list
// ---------------------------------------------------------------------------

fn invoke_models_list(provider: &Provider) -> Result<Value, String> {
    let request = json!({
        "reference": { "local": provider.local_path },
        "input": { "operation": "models.list", "params": {} },
        "type": "catalyst"
    });

    let response_str = invoke::call(&request.to_string());

    let response: Value = serde_json::from_str(&response_str)
        .map_err(|e| format!("Failed to parse invoke response: {e}"))?;

    // Check for host-level invoke error
    if let Some(err) = response.get("error") {
        return Err(err.to_string());
    }

    // Extract the catalyst output from the invoke envelope
    let output = response
        .get("output")
        .cloned()
        .unwrap_or(Value::Null);

    // The catalyst returns JSON-as-string in output; parse it
    let catalyst_result = match &output {
        Value::String(s) => serde_json::from_str::<Value>(s)
            .unwrap_or(output.clone()),
        _ => output,
    };

    // Check for catalyst-level error
    if let Some(err) = catalyst_result.get("error") {
        return Err(err.to_string());
    }

    // Return the data payload
    Ok(catalyst_result.get("data").cloned().unwrap_or(catalyst_result))
}
