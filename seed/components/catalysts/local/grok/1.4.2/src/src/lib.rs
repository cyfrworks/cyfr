#[allow(warnings)]
mod bindings;
mod chat;
mod ids;
mod stream;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;
use bindings::cyfr::http::streaming;

use serde_json::{json, Value};

pub(crate) const BASE_URL: &str = "https://api.x.ai/v1";

/// The need every request names as its connection. CYFR attaches the key
/// bound to it, so the catalyst never holds the key and no request it
/// builds carries one.
pub(crate) const CONNECTION: &str = "api_key";

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

    // What the catalyst can do is answered without a request, and a chat
    // request off the contract, or a model name off the id grammar, is
    // refused before any request is made.
    if operation == "describe" {
        return Ok(chat::describe(&params));
    }
    let chat_request = match operation {
        "chat" => match chat::parse_request(&params) {
            Ok(request) if !chat::model_id(&request.model) => {
                return Ok(chat::unknown_model(&request.model))
            }
            Ok(request) => Some(request),
            Err(message) => return Ok(chat::refuse(400, "invalid_request", &message)),
        },
        _ => None,
    };

    match operation {
        // model/chat@1
        "chat" => Ok(chat::chat(&chat_request.expect("parsed above"))),
        "models" => Ok(chat::models()),

        // Chat completions (with optional streaming)
        // Alias "messages.create" for agent formula compatibility
        "chat.completions.create" | "messages.create" => {
            if stream_flag {
                chat_completions_stream(&params)
            } else {
                chat_completions_create(&params)
            }
        }

        // Models
        "models.list" => models_list(),

        // Embeddings
        "embeddings.create" => embeddings_create(&params),

        // Images
        "images.generate" => images_generate(&params),
        "images.edit" => images_edit(&params),

        // Responses (chat-with-files via /v1/responses)
        "responses.create" => responses_create(&params),

        // Files
        "files.list" => files_list(&params),
        "files.get" => files_get(&params),
        "files.delete" => files_delete(&params),

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

/// The identifier `params[key]` names, as the URL path segment it becomes,
/// or the refusal of one that is missing or strays from the id grammar.
fn path_id(params: &Value, key: &str) -> Result<String, String> {
    match params.get(key).and_then(Value::as_str) {
        Some(id) if ids::valid(id, &[]) => Ok(ids::segment(id)),
        Some(_) => Err(format_error(
            400,
            "invalid_request",
            &format!("'{key}' is not a valid identifier"),
        )),
        None => Err(format_error(
            400,
            "invalid_request",
            &format!("Missing '{key}' in params"),
        )),
    }
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

/// A request in the host's fetch shape, named on the connection: CYFR
/// attaches the key, and the request carries none.
fn request(method: &str, url: &str, body: String) -> Value {
    json!({
        "method": method,
        "url": url,
        "headers": {
            "Content-Type": "application/json"
        },
        "body": body,
        "connection": CONNECTION
    })
}

fn http_get(url: &str) -> String {
    fetch::request(&request("GET", url, String::new()).to_string())
}

fn http_post(url: &str, body: &Value) -> String {
    fetch::request(&request("POST", url, body.to_string()).to_string())
}

fn http_delete(url: &str) -> String {
    fetch::request(&request("DELETE", url, String::new()).to_string())
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

fn chat_completions_create(params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/chat/completions");
    Ok(parse_response(&http_post(&url, params)))
}

fn chat_completions_stream(params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/chat/completions");

    // Inject stream: true into the request body
    let mut body = params.clone();
    if let Some(obj) = body.as_object_mut() {
        obj.insert("stream".to_string(), Value::Bool(true));
    }

    let req = request("POST", &url, body.to_string());

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

fn models_list() -> Result<String, String> {
    let url = format!("{BASE_URL}/models");
    Ok(parse_response(&http_get(&url)))
}

// ---------------------------------------------------------------------------
// Operations — Embeddings
// ---------------------------------------------------------------------------

fn embeddings_create(params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/embeddings");
    Ok(parse_response(&http_post(&url, params)))
}

// ---------------------------------------------------------------------------
// Operations — Images
// ---------------------------------------------------------------------------

fn images_generate(params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/images/generations");
    Ok(parse_response(&http_post(&url, params)))
}

fn images_edit(params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/images/edits");
    Ok(parse_response(&http_post(&url, params)))
}

// ---------------------------------------------------------------------------
// Operations — Responses (chat-with-files)
// ---------------------------------------------------------------------------

fn responses_create(params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/responses");
    Ok(parse_response(&http_post(&url, params)))
}

// ---------------------------------------------------------------------------
// Operations — Files
// ---------------------------------------------------------------------------

fn files_list(params: &Value) -> Result<String, String> {
    let mut url = format!("{BASE_URL}/files");

    if let Some(purpose) = params.get("purpose").and_then(|v| v.as_str()) {
        url = format!("{url}?purpose={}", ids::query(purpose));
    }

    Ok(parse_response(&http_get(&url)))
}

fn files_get(params: &Value) -> Result<String, String> {
    let file_id = match path_id(params, "file_id") {
        Ok(id) => id,
        Err(refusal) => return Ok(refusal),
    };
    let url = format!("{BASE_URL}/files/{file_id}");
    Ok(parse_response(&http_get(&url)))
}

fn files_delete(params: &Value) -> Result<String, String> {
    let file_id = match path_id(params, "file_id") {
        Ok(id) => id,
        Err(refusal) => return Ok(refusal),
    };
    let url = format!("{BASE_URL}/files/{file_id}");
    Ok(parse_response(&http_delete(&url)))
}

/// Whether a header name carries a credential, as the host reads one: a
/// request that names a connection and carries such a header is refused by
/// its shape, since CYFR attaches the key.
#[cfg(test)]
pub(crate) fn credential_header(name: &str) -> bool {
    const NAMES: &[&str] = &[
        "authorization",
        "cookie",
        "proxy-authorization",
        "x-api-key",
        "x-auth-token",
        "x-access-token",
        "x-csrf-token",
    ];
    let name = name.to_ascii_lowercase();
    NAMES.contains(&name.as_str()) || ["-token", "-key", "-secret"].iter().any(|s| name.ends_with(s))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Names that would leave, or reshape, the URL they are placed in.
    const HOSTILE: &[&str] = &[
        "../files",
        "..",
        "%2e%2e",
        "%2E%2E%2Ffiles",
        "grok-4.3?limit=1",
        "grok-4.3#fragment",
        "grok 4.3",
        " grok-4.3",
        "grok-4.3\n",
        "grok-4.3/../files",
    ];

    fn run(operation: &str, params: Value) -> Value {
        let input = json!({"operation": operation, "params": params}).to_string();
        serde_json::from_str(&handle_request(&input).unwrap()).unwrap()
    }

    // Every host import panics off wasm, so each answer below was given
    // without making a request.
    #[test]
    fn a_name_off_the_id_grammar_is_refused_before_any_request() {
        for name in HOSTILE {
            let described = run("describe", json!({"model": name}));
            assert_eq!(described["error"]["type"], "unknown_model", "{name:?}");

            let chat = run("chat", json!({"model": name, "messages": [{"role": "user", "content": "hi"}]}));
            assert_eq!(chat["status"], 404, "{name:?}");
            assert_eq!(chat["error"]["type"], "unknown_model", "{name:?}");

            for operation in [files_get, files_delete] {
                let file: Value =
                    serde_json::from_str(&operation(&json!({"file_id": name})).unwrap()).unwrap();
                assert_eq!(file["status"], 400, "{name:?}");
                assert_eq!(file["error"]["type"], "invalid_request", "{name:?}");
            }
        }

        assert_eq!(path_id(&json!({"file_id": "file_abc-1"}), "file_id"), Ok("file_abc-1".to_string()));
    }

    #[test]
    fn a_request_names_the_connection_and_carries_no_credential() {
        for req in [
            request("GET", "https://x/v1/files", String::new()),
            request("POST", "https://x/v1/responses", "{}".into()),
            request("DELETE", "https://x/v1/files/f", String::new()),
        ] {
            assert_eq!(req["connection"], CONNECTION);
            for name in req["headers"].as_object().unwrap().keys() {
                assert!(!credential_header(name), "{name}");
            }
        }
    }
}
