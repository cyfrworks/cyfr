#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;
use bindings::cyfr::http::streaming;
use bindings::cyfr::secrets::read;

use serde_json::{json, Value};

const BASE_URL: &str = "https://api.anthropic.com";
const API_VERSION: &str = "2023-06-01";

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        match handle_request(&input) {
            Ok(output) => output,
            Err(e) => format_error(500, "internal_error", &e),
        }
    }
}

bindings::export!(Component with_types_in bindings);

// ---------------------------------------------------------------------------
// Request routing
// ---------------------------------------------------------------------------

fn handle_request(input: &str) -> Result<String, String> {
    let parsed: Value =
        serde_json::from_str(input).map_err(|e| format!("Invalid JSON input: {e}"))?;

    let operation = parsed
        .get("operation")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing 'operation' field".to_string())?;

    let params = parsed.get("params").cloned().unwrap_or(json!({}));

    // Read API key — on failure return a structured error
    let api_key = match read::get("ANTHROPIC_API_KEY") {
        Ok(key) => key,
        Err(e) => {
            return Ok(format_error(
                500,
                "secret_denied",
                &format!("Failed to read ANTHROPIC_API_KEY: {e}"),
            ));
        }
    };

    match operation {
        // Messages
        "messages.create" => messages_create(&api_key, &params),
        "messages.stream" => messages_stream(&api_key, &params),
        "messages.count_tokens" => messages_count_tokens(&api_key, &params),

        // Models
        "models.list" => models_list(&api_key, &params),

        // Batches
        "batches.create" => batches_create(&api_key, &params),
        "batches.get" => batches_get(&api_key, &params),
        "batches.list" => batches_list(&api_key, &params),
        "batches.cancel" => batches_cancel(&api_key, &params),
        "batches.results" => batches_results(&api_key, &params),

        _ => Ok(format_error(
            400,
            "unknown_operation",
            &format!("Unknown operation: {operation}"),
        )),
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn format_error(status: i64, error_type: &str, message: &str) -> String {
    json!({
        "status": status,
        "error": {
            "type": error_type,
            "message": message,
        }
    })
    .to_string()
}

fn require_param(params: &Value, key: &str) -> Result<String, String> {
    params
        .get(key)
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| format!("Missing '{key}' in params"))
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn http_get(url: &str, api_key: &str) -> String {
    let req = json!({
        "method": "GET",
        "url": url,
        "headers": {
            "x-api-key": api_key,
            "anthropic-version": API_VERSION,
            "Content-Type": "application/json"
        },
        "body": ""
    });
    fetch::request(&req.to_string())
}

fn http_post(url: &str, api_key: &str, body: &Value) -> String {
    let req = json!({
        "method": "POST",
        "url": url,
        "headers": {
            "x-api-key": api_key,
            "anthropic-version": API_VERSION,
            "Content-Type": "application/json"
        },
        "body": body.to_string()
    });
    fetch::request(&req.to_string())
}

/// Parse the host HTTP response into the catalyst output envelope.
///
/// Host returns: `{"status": 200, "headers": {...}, "body": "..."}` or `{"error": "..."}`.
/// Catalyst returns: `{"status": N, "data": <parsed>}` or `{"status": N, "error": <parsed>}`.
fn parse_response(resp_str: &str) -> String {
    let resp: Value = match serde_json::from_str(resp_str) {
        Ok(v) => v,
        Err(e) => {
            return format_error(
                500,
                "parse_error",
                &format!("Failed to parse HTTP response: {e}"),
            );
        }
    };

    // Host-level error (e.g. domain blocked)
    if let Some(err) = resp.get("error") {
        let msg = err.as_str().unwrap_or("unknown host error");
        return format_error(500, "http_error", msg);
    }

    let status = resp.get("status").and_then(|v| v.as_i64()).unwrap_or(500);
    let body_str = resp.get("body").and_then(|v| v.as_str()).unwrap_or("");

    if status >= 200 && status < 300 {
        let data = serde_json::from_str::<Value>(body_str)
            .unwrap_or(Value::String(body_str.to_string()));
        json!({"status": status, "data": data}).to_string()
    } else {
        let error = serde_json::from_str::<Value>(body_str).unwrap_or_else(|_| {
            json!({"type": "api_error", "message": body_str})
        });
        json!({"status": status, "error": error}).to_string()
    }
}

// ---------------------------------------------------------------------------
// Operations — Messages
// ---------------------------------------------------------------------------

fn messages_create(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/messages");
    Ok(parse_response(&http_post(&url, api_key, params)))
}

fn messages_count_tokens(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/messages/count_tokens");
    Ok(parse_response(&http_post(&url, api_key, params)))
}

// ---------------------------------------------------------------------------
// Operations — Streaming
// ---------------------------------------------------------------------------

fn messages_stream(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/messages");

    // Inject stream: true into the request body
    let mut body = params.clone();
    if let Some(obj) = body.as_object_mut() {
        obj.insert("stream".to_string(), Value::Bool(true));
    }

    let req = json!({
        "method": "POST",
        "url": url,
        "headers": {
            "x-api-key": api_key,
            "anthropic-version": API_VERSION,
            "Content-Type": "application/json"
        },
        "body": body.to_string()
    });

    // Open the stream
    let handle_resp = streaming::request(&req.to_string());
    let handle_val: Value = serde_json::from_str(&handle_resp)
        .map_err(|e| format!("Failed to parse stream handle response: {e}"))?;

    if let Some(err) = handle_val.get("error") {
        let msg = err.as_str().unwrap_or("stream request failed");
        return Ok(format_error(500, "stream_error", msg));
    }

    let handle = handle_val
        .get("handle")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "No 'handle' in stream response".to_string())?;

    // Collect SSE chunks
    let mut chunks: Vec<Value> = Vec::new();
    let mut combined_text = String::new();
    let mut buffer = String::new();

    loop {
        let chunk_resp = streaming::read(handle);
        let chunk_val: Value = serde_json::from_str(&chunk_resp)
            .map_err(|e| format!("Failed to parse stream chunk: {e}"))?;

        let done = chunk_val
            .get("done")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let data = chunk_val
            .get("data")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        if !data.is_empty() {
            buffer.push_str(data);

            // Process complete lines from the buffer
            while let Some(newline_pos) = buffer.find('\n') {
                let line = buffer[..newline_pos].to_string();
                buffer = buffer[newline_pos + 1..].to_string();

                let trimmed = line.trim();
                if let Some(json_str) = trimmed.strip_prefix("data: ") {
                    if json_str == "[DONE]" {
                        continue;
                    }
                    if let Ok(event) = serde_json::from_str::<Value>(json_str) {
                        extract_streaming_text(&event, &mut combined_text);
                        chunks.push(event);
                    }
                }
            }
        }

        if done {
            // Process any remaining data in the buffer
            let trimmed = buffer.trim();
            if let Some(json_str) = trimmed.strip_prefix("data: ") {
                if json_str != "[DONE]" {
                    if let Ok(event) = serde_json::from_str::<Value>(json_str) {
                        extract_streaming_text(&event, &mut combined_text);
                        chunks.push(event);
                    }
                }
            }
            break;
        }
    }

    // Close the stream
    let _ = streaming::close(handle);

    Ok(json!({
        "status": 200,
        "data": {
            "chunks": chunks,
            "combined_text": combined_text
        }
    })
    .to_string())
}

/// Extract text from a Claude SSE event and append to `combined_text`.
///
/// Claude streaming events:
///   - `content_block_delta` with `delta.type == "text_delta"` → `delta.text`
///   - `content_block_delta` with `delta.type == "thinking_delta"` → (ignored for combined_text)
///   - `content_block_delta` with `delta.type == "input_json_delta"` → (ignored for combined_text)
fn extract_streaming_text(event: &Value, combined_text: &mut String) {
    let event_type = event.get("type").and_then(|v| v.as_str()).unwrap_or("");

    if event_type == "content_block_delta" {
        if let Some(delta) = event.get("delta") {
            let delta_type = delta.get("type").and_then(|v| v.as_str()).unwrap_or("");
            if delta_type == "text_delta" {
                if let Some(text) = delta.get("text").and_then(|t| t.as_str()) {
                    combined_text.push_str(text);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Operations — Models
// ---------------------------------------------------------------------------

fn models_list(api_key: &str, params: &Value) -> Result<String, String> {
    let mut url = format!("{BASE_URL}/v1/models");

    let mut query = Vec::new();
    if let Some(limit) = params.get("limit").and_then(|v| v.as_i64()) {
        query.push(format!("limit={limit}"));
    }
    if let Some(after_id) = params.get("after_id").and_then(|v| v.as_str()) {
        query.push(format!("after_id={after_id}"));
    }
    if let Some(before_id) = params.get("before_id").and_then(|v| v.as_str()) {
        query.push(format!("before_id={before_id}"));
    }
    if !query.is_empty() {
        url = format!("{url}?{}", query.join("&"));
    }

    Ok(parse_response(&http_get(&url, api_key)))
}

// ---------------------------------------------------------------------------
// Operations — Batches
// ---------------------------------------------------------------------------

fn batches_create(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/messages/batches");
    Ok(parse_response(&http_post(&url, api_key, params)))
}

fn batches_get(api_key: &str, params: &Value) -> Result<String, String> {
    let batch_id = require_param(params, "batch_id")?;
    let url = format!("{BASE_URL}/v1/messages/batches/{batch_id}");
    Ok(parse_response(&http_get(&url, api_key)))
}

fn batches_list(api_key: &str, params: &Value) -> Result<String, String> {
    let mut url = format!("{BASE_URL}/v1/messages/batches");

    let mut query = Vec::new();
    if let Some(limit) = params.get("limit").and_then(|v| v.as_i64()) {
        query.push(format!("limit={limit}"));
    }
    if let Some(after_id) = params.get("after_id").and_then(|v| v.as_str()) {
        query.push(format!("after_id={after_id}"));
    }
    if let Some(before_id) = params.get("before_id").and_then(|v| v.as_str()) {
        query.push(format!("before_id={before_id}"));
    }
    if !query.is_empty() {
        url = format!("{url}?{}", query.join("&"));
    }

    Ok(parse_response(&http_get(&url, api_key)))
}

fn batches_cancel(api_key: &str, params: &Value) -> Result<String, String> {
    let batch_id = require_param(params, "batch_id")?;
    let url = format!("{BASE_URL}/v1/messages/batches/{batch_id}/cancel");
    Ok(parse_response(&http_post(&url, api_key, &json!({}))))
}

fn batches_results(api_key: &str, params: &Value) -> Result<String, String> {
    let batch_id = require_param(params, "batch_id")?;
    let url = format!("{BASE_URL}/v1/messages/batches/{batch_id}/results");
    Ok(parse_response(&http_get(&url, api_key)))
}
