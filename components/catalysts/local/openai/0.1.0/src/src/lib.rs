#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;
use bindings::cyfr::http::streaming;
use bindings::cyfr::secrets::read;

use serde_json::{json, Value};

const BASE_URL: &str = "https://api.openai.com";

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

    // Read API key — if not set/granted, use empty string so OpenAI returns 401
    let api_key = read::get("OPENAI_API_KEY").unwrap_or_default();

    match operation {
        // Chat completions (with optional streaming)
        "chat.completions.create" => {
            if stream_flag {
                chat_completions_stream(&api_key, &params)
            } else {
                chat_completions_create(&api_key, &params)
            }
        }

        // Models
        "models.list" => models_list(&api_key, &params),
        "models.get" => models_get(&api_key, &params),

        // Embeddings
        "embeddings.create" => embeddings_create(&api_key, &params),

        // Moderations
        "moderations.create" => moderations_create(&api_key, &params),

        // Images
        "images.generate" => images_generate(&api_key, &params),

        // Audio
        "audio.speech" => audio_speech(&api_key, &params),
        "audio.transcriptions" => audio_transcriptions(&api_key, &params),
        "audio.translations" => audio_translations(&api_key, &params),

        // Responses
        "responses.create" => responses_create(&api_key, &params),

        // Files
        "files.list" => files_list(&api_key, &params),
        "files.get" => files_get(&api_key, &params),
        "files.delete" => files_delete(&api_key, &params),

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

fn http_delete(url: &str, api_key: &str) -> String {
    let req = json!({
        "method": "DELETE",
        "url": url,
        "headers": {
            "Authorization": format!("Bearer {api_key}"),
            "Content-Type": "application/json"
        },
        "body": ""
    });
    fetch::request(&req.to_string())
}

fn http_post_multipart(url: &str, api_key: &str, parts: &Value) -> String {
    let req = json!({
        "method": "POST",
        "url": url,
        "headers": {
            "Authorization": format!("Bearer {api_key}")
        },
        "multipart": parts
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

/// Parse a binary HTTP response, encoding the body as base64.
fn parse_binary_response(resp_str: &str) -> String {
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

    if let Some(err) = resp.get("error") {
        let msg = err.as_str().unwrap_or("unknown host error");
        return format_error(500, "http_error", msg);
    }

    let status = resp.get("status").and_then(|v| v.as_i64()).unwrap_or(500);
    let body_str = resp.get("body").and_then(|v| v.as_str()).unwrap_or("");

    if status >= 200 && status < 300 {
        json!({
            "status": status,
            "data": {
                "audio_base64": body_str,
                "response_encoding": "base64"
            }
        })
        .to_string()
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

fn chat_completions_create(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/chat/completions");
    Ok(parse_response(&http_post(&url, api_key, params)))
}

fn chat_completions_stream(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/chat/completions");

    // Inject stream: true into the request body
    let mut body = params.clone();
    if let Some(obj) = body.as_object_mut() {
        obj.insert("stream".to_string(), Value::Bool(true));
    }

    let req = json!({
        "method": "POST",
        "url": url,
        "headers": {
            "Authorization": format!("Bearer {api_key}"),
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

/// Extract text from an OpenAI streaming chunk and append to `combined_text`.
///
/// OpenAI streaming events have: `choices[].delta.content`
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

fn models_list(api_key: &str, _params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/models");
    Ok(parse_response(&http_get(&url, api_key)))
}

fn models_get(api_key: &str, params: &Value) -> Result<String, String> {
    let model_id = require_param(params, "model_id")?;
    let url = format!("{BASE_URL}/v1/models/{model_id}");
    Ok(parse_response(&http_get(&url, api_key)))
}

// ---------------------------------------------------------------------------
// Operations — Embeddings
// ---------------------------------------------------------------------------

fn embeddings_create(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/embeddings");
    Ok(parse_response(&http_post(&url, api_key, params)))
}

// ---------------------------------------------------------------------------
// Operations — Moderations
// ---------------------------------------------------------------------------

fn moderations_create(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/moderations");
    Ok(parse_response(&http_post(&url, api_key, params)))
}

// ---------------------------------------------------------------------------
// Operations — Images
// ---------------------------------------------------------------------------

fn images_generate(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/images/generations");
    Ok(parse_response(&http_post(&url, api_key, params)))
}

// ---------------------------------------------------------------------------
// Operations — Audio
// ---------------------------------------------------------------------------

fn audio_speech(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/audio/speech");
    Ok(parse_binary_response(&http_post(&url, api_key, params)))
}

fn audio_transcriptions(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/audio/transcriptions");

    if let Some(parts) = params.get("multipart") {
        Ok(parse_response(&http_post_multipart(&url, api_key, parts)))
    } else {
        Ok(parse_response(&http_post(&url, api_key, params)))
    }
}

fn audio_translations(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/audio/translations");

    if let Some(parts) = params.get("multipart") {
        Ok(parse_response(&http_post_multipart(&url, api_key, parts)))
    } else {
        Ok(parse_response(&http_post(&url, api_key, params)))
    }
}

// ---------------------------------------------------------------------------
// Operations — Responses
// ---------------------------------------------------------------------------

fn responses_create(api_key: &str, params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/responses");
    Ok(parse_response(&http_post(&url, api_key, params)))
}

// ---------------------------------------------------------------------------
// Operations — Files
// ---------------------------------------------------------------------------

fn files_list(api_key: &str, params: &Value) -> Result<String, String> {
    let mut url = format!("{BASE_URL}/v1/files");

    if let Some(purpose) = params.get("purpose").and_then(|v| v.as_str()) {
        url = format!("{url}?purpose={purpose}");
    }

    Ok(parse_response(&http_get(&url, api_key)))
}

fn files_get(api_key: &str, params: &Value) -> Result<String, String> {
    let file_id = require_param(params, "file_id")?;
    let url = format!("{BASE_URL}/v1/files/{file_id}");
    Ok(parse_response(&http_get(&url, api_key)))
}

fn files_delete(api_key: &str, params: &Value) -> Result<String, String> {
    let file_id = require_param(params, "file_id")?;
    let url = format!("{BASE_URL}/v1/files/{file_id}");
    Ok(parse_response(&http_delete(&url, api_key)))
}
