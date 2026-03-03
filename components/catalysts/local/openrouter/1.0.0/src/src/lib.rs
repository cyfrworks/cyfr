#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;
use bindings::cyfr::http::streaming;
use bindings::cyfr::secrets::read;

use serde_json::{json, Value};

const BASE_URL: &str = "https://openrouter.ai/api/v1";
const SECRET_NAME: &str = "OPENROUTER_API_KEY";

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

    // Read API key
    let api_key = match read::get(SECRET_NAME) {
        Ok(key) => key,
        Err(e) => {
            return Ok(format_error(
                500,
                "secret_denied",
                &format!("Failed to read {SECRET_NAME}: {e}"),
            ));
        }
    };

    // Extract optional OpenRouter-specific headers
    let referer = params.get("referer").and_then(|v| v.as_str()).map(String::from);
    let title = params.get("title").and_then(|v| v.as_str()).map(String::from);

    match operation {
        // Chat completions (with optional streaming)
        // Alias "messages.create" for agent formula compatibility
        "chat.completions.create" | "messages.create" => {
            if stream_flag {
                chat_completions_stream(&api_key, &params, referer.as_deref(), title.as_deref())
            } else {
                chat_completions_create(&api_key, &params, referer.as_deref(), title.as_deref())
            }
        }

        // Models
        "models.list" => models_list(&api_key),

        // Embeddings
        "embeddings.create" => embeddings_create(&api_key, &params),

        // Account info
        "credits.get" => credits_get(&api_key),
        "key.info" => key_info(&api_key),

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

fn build_headers(api_key: &str, referer: Option<&str>, title: Option<&str>) -> Value {
    let mut headers = json!({
        "Authorization": format!("Bearer {api_key}"),
        "Content-Type": "application/json"
    });
    if let Some(r) = referer {
        headers["HTTP-Referer"] = Value::String(r.to_string());
    }
    if let Some(t) = title {
        headers["X-Title"] = Value::String(t.to_string());
    }
    headers
}

fn http_get(url: &str, api_key: &str) -> String {
    let req = json!({
        "method": "GET",
        "url": url,
        "headers": {
            "Authorization": format!("Bearer {api_key}"),
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
            "Authorization": format!("Bearer {api_key}"),
            "Content-Type": "application/json"
        },
        "body": body.to_string()
    });
    fetch::request(&req.to_string())
}

fn http_post_with_headers(url: &str, headers: &Value, body: &Value) -> String {
    let req = json!({
        "method": "POST",
        "url": url,
        "headers": headers,
        "body": body.to_string()
    });
    fetch::request(&req.to_string())
}

/// Parse the host HTTP response into the catalyst output envelope.
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
        let (err_type, err_msg) = if let Some(obj) = err.as_object() {
            (
                obj.get("type").and_then(|v| v.as_str()).unwrap_or("http_error"),
                obj.get("message").and_then(|v| v.as_str()).unwrap_or("unknown host error"),
            )
        } else {
            ("http_error", err.as_str().unwrap_or("unknown host error"))
        };
        return format_error(500, err_type, err_msg);
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
// Operations — Chat Completions
// ---------------------------------------------------------------------------

fn chat_completions_create(
    api_key: &str,
    params: &Value,
    referer: Option<&str>,
    title: Option<&str>,
) -> Result<String, String> {
    let url = format!("{BASE_URL}/chat/completions");
    let headers = build_headers(api_key, referer, title);
    Ok(parse_response(&http_post_with_headers(&url, &headers, params)))
}

fn chat_completions_stream(
    api_key: &str,
    params: &Value,
    referer: Option<&str>,
    title: Option<&str>,
) -> Result<String, String> {
    let url = format!("{BASE_URL}/chat/completions");

    // Inject stream: true into the request body
    let mut body = params.clone();
    if let Some(obj) = body.as_object_mut() {
        obj.insert("stream".to_string(), Value::Bool(true));
    }

    let headers = build_headers(api_key, referer, title);
    let req = json!({
        "method": "POST",
        "url": url,
        "headers": headers,
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

/// Extract text from an OpenAI-compatible streaming chunk.
fn extract_streaming_text(event: &Value, combined_text: &mut String) {
    if let Some(choices) = event.get("choices").and_then(|v| v.as_array()) {
        for choice in choices {
            if let Some(content) = choice
                .get("delta")
                .and_then(|d| d.get("content"))
                .and_then(|c| c.as_str())
            {
                combined_text.push_str(content);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Operations — Models
// ---------------------------------------------------------------------------

fn models_list(api_key: &str) -> Result<String, String> {
    let url = format!("{BASE_URL}/models");
    Ok(parse_response(&http_get(&url, api_key)))
}

// ---------------------------------------------------------------------------
// Operations — Embeddings
// ---------------------------------------------------------------------------

fn embeddings_create(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/embeddings");
    Ok(parse_response(&http_post(&url, api_key, params)))
}

// ---------------------------------------------------------------------------
// Operations — Account Info
// ---------------------------------------------------------------------------

fn credits_get(api_key: &str) -> Result<String, String> {
    let url = format!("{BASE_URL}/credits");
    Ok(parse_response(&http_get(&url, api_key)))
}

fn key_info(api_key: &str) -> Result<String, String> {
    let url = format!("{BASE_URL}/key");
    Ok(parse_response(&http_get(&url, api_key)))
}
