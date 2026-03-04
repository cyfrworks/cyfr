#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;

struct Component;
bindings::export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(input: String) -> String {
        let request: serde_json::Value = match serde_json::from_str(&input) {
            Ok(v) => v,
            Err(e) => return serde_json::json!({"error": e.to_string()}).to_string(),
        };
        // TODO: Implement catalyst logic
        serde_json::json!({"error": "not implemented"}).to_string()
    }
}
