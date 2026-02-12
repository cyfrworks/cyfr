#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;
use bindings::cyfr::http::streaming;
use bindings::cyfr::secrets::read;

use serde_json::{json, Value};

const BASE_URL: &str = "https://generativelanguage.googleapis.com/v1beta";

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
    let stream_flag = parsed
        .get("stream")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Read API key — on failure return a structured error
    let api_key = match read::get("GEMINI_API_KEY") {
        Ok(key) => key,
        Err(e) => return Ok(format_error(500, "secret_denied", &format!("Failed to read GEMINI_API_KEY: {e}"))),
    };

    match operation {
        // Model listing / info
        "models.list" => models_list(&api_key, &params),
        "models.get" => {
            let model = require_model(&params)?;
            models_get(&api_key, &model)
        }

        // Content generation (support both plan names and test names)
        "generate" | "content.generate" => {
            let model = require_model(&params)?;
            if stream_flag {
                content_stream(&api_key, &model, &params)
            } else {
                content_generate(&api_key, &model, &params)
            }
        }

        // Streaming generation
        "stream" | "content.stream" => {
            let model = require_model(&params)?;
            content_stream(&api_key, &model, &params)
        }

        // Token counting
        "count_tokens" | "tokens.count" => {
            let model = require_model(&params)?;
            tokens_count(&api_key, &model, &params)
        }

        // Embeddings
        "embed" | "embeddings.create" => {
            let model = require_model(&params)?;
            embeddings_create(&api_key, &model, &params)
        }

        // Batch embeddings
        "batch_embed" | "embeddings.batch" => {
            let model = require_model(&params)?;
            embeddings_batch(&api_key, &model, &params)
        }

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

fn require_model(params: &Value) -> Result<String, String> {
    params
        .get("model")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| "Missing 'model' in params".to_string())
}

/// Build a request body from params, stripping the `model` key (it goes in the URL).
fn build_body(params: &Value) -> Value {
    let mut body = params.clone();
    if let Some(obj) = body.as_object_mut() {
        obj.remove("model");
    }
    body
}

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

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn http_get(url: &str, api_key: &str) -> String {
    let req = json!({
        "method": "GET",
        "url": url,
        "headers": {
            "x-goog-api-key": api_key,
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
            "x-goog-api-key": api_key,
            "Content-Type": "application/json"
        },
        "body": body.to_string()
    });
    fetch::request(&req.to_string())
}

/// Parse the host HTTP response into the catalyst output envelope.
///
/// Host returns: `{"status": 200, "headers": {...}, "body": "..."}` or `{"error": "..."}`.
/// Catalyst returns: `{"status": <int>, "data": <parsed_body>}` or `{"status": <int>, "error": <parsed_body>}`.
fn parse_response(resp_str: &str) -> String {
    let resp: Value = match serde_json::from_str(resp_str) {
        Ok(v) => v,
        Err(e) => {
            return format_error(500, "parse_error", &format!("Failed to parse HTTP response: {e}"));
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
        // Success — parse body as JSON
        let data = serde_json::from_str::<Value>(body_str).unwrap_or(Value::String(body_str.to_string()));
        json!({"status": status, "data": data}).to_string()
    } else {
        // API error — parse body as JSON for structured error info
        let error = serde_json::from_str::<Value>(body_str).unwrap_or_else(|_| {
            json!({"type": "api_error", "message": body_str})
        });
        json!({"status": status, "error": error}).to_string()
    }
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

fn models_list(api_key: &str, params: &Value) -> Result<String, String> {
    let mut url = format!("{BASE_URL}/models");

    let mut query = Vec::new();
    if let Some(ps) = params.get("pageSize").and_then(|v| v.as_i64()) {
        query.push(format!("pageSize={ps}"));
    }
    if let Some(pt) = params.get("pageToken").and_then(|v| v.as_str()) {
        query.push(format!("pageToken={pt}"));
    }
    if !query.is_empty() {
        url = format!("{url}?{}", query.join("&"));
    }

    Ok(parse_response(&http_get(&url, api_key)))
}

fn models_get(api_key: &str, model: &str) -> Result<String, String> {
    let url = format!("{BASE_URL}/models/{model}");
    Ok(parse_response(&http_get(&url, api_key)))
}

fn content_generate(api_key: &str, model: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/models/{model}:generateContent");
    let body = build_body(params);
    Ok(parse_response(&http_post(&url, api_key, &body)))
}

fn tokens_count(api_key: &str, model: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/models/{model}:countTokens");
    let body = build_body(params);
    Ok(parse_response(&http_post(&url, api_key, &body)))
}

fn embeddings_create(api_key: &str, model: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/models/{model}:embedContent");
    let body = build_body(params);
    Ok(parse_response(&http_post(&url, api_key, &body)))
}

fn embeddings_batch(api_key: &str, model: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/models/{model}:batchEmbedContents");
    let mut body = build_body(params);

    // Gemini requires "model": "models/{model}" in each request item
    if let Some(requests) = body.get_mut("requests") {
        if let Some(arr) = requests.as_array_mut() {
            for item in arr.iter_mut() {
                if let Some(obj) = item.as_object_mut() {
                    obj.insert(
                        "model".to_string(),
                        Value::String(format!("models/{model}")),
                    );
                }
            }
        }
    }

    Ok(parse_response(&http_post(&url, api_key, &body)))
}

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

fn content_stream(api_key: &str, model: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/models/{model}:streamGenerateContent?alt=sse");
    let body = build_body(params);

    let req = json!({
        "method": "POST",
        "url": url,
        "headers": {
            "x-goog-api-key": api_key,
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
                    if let Ok(chunk) = serde_json::from_str::<Value>(json_str) {
                        // Extract text from candidates[].content.parts[].text
                        extract_text(&chunk, &mut combined_text);
                        chunks.push(chunk);
                    }
                }
            }
        }

        if done {
            // Process any remaining data in the buffer
            let trimmed = buffer.trim();
            if let Some(json_str) = trimmed.strip_prefix("data: ") {
                if json_str != "[DONE]" {
                    if let Ok(chunk) = serde_json::from_str::<Value>(json_str) {
                        extract_text(&chunk, &mut combined_text);
                        chunks.push(chunk);
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

/// Extract text from a Gemini streaming chunk and append to `combined_text`.
fn extract_text(chunk: &Value, combined_text: &mut String) {
    if let Some(candidates) = chunk.get("candidates").and_then(|v| v.as_array()) {
        for candidate in candidates {
            if let Some(parts) = candidate
                .get("content")
                .and_then(|c| c.get("parts"))
                .and_then(|p| p.as_array())
            {
                for part in parts {
                    if let Some(text) = part.get("text").and_then(|t| t.as_str()) {
                        combined_text.push_str(text);
                    }
                }
            }
        }
    }
}
