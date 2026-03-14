#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::reagent::compute::Guest;

struct Component;
bindings::export!(Component with_types_in bindings);

impl Guest for Component {
    fn compute(input: String) -> String {
        let data: serde_json::Value = match serde_json::from_str(&input) {
            Ok(v) => v,
            Err(e) => return serde_json::json!({"error": e.to_string()}).to_string(),
        };
        // Pure computation here
        serde_json::to_string(&data).unwrap_or_else(|e|
            serde_json::json!({"error": e.to_string()}).to_string()
        )
    }
}
