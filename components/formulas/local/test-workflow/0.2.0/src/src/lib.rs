#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::formula::run::Guest;
use bindings::cyfr::formula::invoke;
use serde_json::{json, Value};

struct Component;
bindings::export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(input: String) -> String {
        match handle_request(&input) {
            Ok(output) => output,
            Err(e) => json!({"error": e}).to_string(),
        }
    }
}

fn handle_request(input: &str) -> Result<String, String> {
    let parsed: Value = serde_json::from_str(input)
        .map_err(|e| format!("Invalid JSON: {e}"))?;
    // TODO: Implement formula logic using invoke::call
    Ok(json!({"error": "not implemented"}).to_string())
}
