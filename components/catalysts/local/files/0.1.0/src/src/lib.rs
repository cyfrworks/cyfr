#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::storage::files;
use serde_json::{json, Value};

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        match handle_request(&input) {
            Ok(output) => output,
            Err(e) => format_error("internal_error", &e),
        }
    }
}

bindings::export!(Component with_types_in bindings);

fn handle_request(input: &str) -> Result<String, String> {
    let req: Value = serde_json::from_str(input)
        .map_err(|e| format!("Invalid JSON input: {}", e))?;

    let action = req.get("action")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing required field: action".to_string())?;

    let path = req.get("path")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    // Build the storage request based on action
    let storage_request = match action {
        "read" => {
            if path.is_empty() {
                return Err("Missing required field: path".to_string());
            }
            json!({"action": "read", "path": path})
        }
        "write" => {
            if path.is_empty() {
                return Err("Missing required field: path".to_string());
            }
            let content = req.get("content")
                .and_then(|v| v.as_str())
                .ok_or_else(|| "Missing required field: content (base64-encoded)".to_string())?;
            json!({"action": "write", "path": path, "content": content})
        }
        "list" => {
            json!({"action": "list", "path": path})
        }
        "delete" => {
            if path.is_empty() {
                return Err("Missing required field: path".to_string());
            }
            json!({"action": "delete", "path": path})
        }
        "exists" => {
            if path.is_empty() {
                return Err("Missing required field: path".to_string());
            }
            json!({"action": "exists", "path": path})
        }
        _ => {
            return Ok(format_error("invalid_action",
                &format!("Unknown action: {}. Use: read, write, list, delete, or exists", action)));
        }
    };

    let request_json = serde_json::to_string(&storage_request)
        .map_err(|e| format!("Failed to serialize request: {}", e))?;

    // Call the host function
    let response = files::call(&request_json);

    // Pass through the host response directly — it's already in the correct format
    Ok(response)
}

fn format_error(error_type: &str, message: &str) -> String {
    json!({
        "error": {
            "type": error_type,
            "message": message
        }
    }).to_string()
}
