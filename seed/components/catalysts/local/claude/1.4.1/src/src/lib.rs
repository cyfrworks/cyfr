#[allow(warnings)]
mod bindings;
mod chat;
mod ids;
mod stream;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;
use bindings::cyfr::http::streaming;

use serde_json::{json, Value};

pub(crate) const BASE_URL: &str = "https://api.anthropic.com";
pub(crate) const API_VERSION: &str = "2023-06-01";

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

    // What the catalyst can do is answered without a request, and a chat
    // request off the contract, or a model name off the id grammar, is
    // refused before any request is made. A named model's window is the
    // Models API's, asked on the connection.
    let described_model = match operation {
        "describe" => match params.get("model").and_then(Value::as_str) {
            None => return Ok(chat::describe()),
            Some(model) if !chat::model_id(model) => return Ok(chat::unknown_model(model)),
            Some(model) => Some(model.to_string()),
        },
        _ => None,
    };
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
        "describe" => Ok(chat::describe_model(&described_model.expect("named above"))),

        // Messages
        "messages.create" => messages_create(&params),
        "messages.stream" => messages_stream(&params),
        "messages.count_tokens" => messages_count_tokens(&params),

        // Models
        "models.list" => models_list(&params),

        // Batches
        "batches.create" => batches_create(&params),
        "batches.get" => batches_get(&params),
        "batches.list" => batches_list(&params),
        "batches.cancel" => batches_cancel(&params),
        "batches.results" => batches_results(&params),

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

/// `url` with a listing's paging parameters from `params`, each value
/// percent-encoded.
fn paged(url: String, params: &Value) -> String {
    let mut query = Vec::new();
    if let Some(limit) = params.get("limit").and_then(Value::as_i64) {
        query.push(format!("limit={limit}"));
    }
    for key in ["after_id", "before_id"] {
        if let Some(id) = params.get(key).and_then(Value::as_str) {
            query.push(format!("{key}={}", ids::query(id)));
        }
    }
    if query.is_empty() {
        url
    } else {
        format!("{url}?{}", query.join("&"))
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
            "anthropic-version": API_VERSION,
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
// Operations — Messages
// ---------------------------------------------------------------------------

fn messages_create(params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/messages");
    Ok(parse_response(&http_post(&url, params)))
}

fn messages_count_tokens(params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/messages/count_tokens");
    Ok(parse_response(&http_post(&url, params)))
}

// ---------------------------------------------------------------------------
// Operations — Streaming
// ---------------------------------------------------------------------------

fn messages_stream(params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/messages");

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

fn models_list(params: &Value) -> Result<String, String> {
    let url = paged(format!("{BASE_URL}/v1/models"), params);
    Ok(parse_response(&http_get(&url)))
}

// ---------------------------------------------------------------------------
// Operations — Batches
// ---------------------------------------------------------------------------

fn batches_create(params: &Value) -> Result<String, String> {
    let url = format!("{BASE_URL}/v1/messages/batches");
    Ok(parse_response(&http_post(&url, params)))
}

fn batches_get(params: &Value) -> Result<String, String> {
    let batch_id = match path_id(params, "batch_id") {
        Ok(id) => id,
        Err(refusal) => return Ok(refusal),
    };
    let url = format!("{BASE_URL}/v1/messages/batches/{batch_id}");
    Ok(parse_response(&http_get(&url)))
}

fn batches_list(params: &Value) -> Result<String, String> {
    let url = paged(format!("{BASE_URL}/v1/messages/batches"), params);
    Ok(parse_response(&http_get(&url)))
}

fn batches_cancel(params: &Value) -> Result<String, String> {
    let batch_id = match path_id(params, "batch_id") {
        Ok(id) => id,
        Err(refusal) => return Ok(refusal),
    };
    let url = format!("{BASE_URL}/v1/messages/batches/{batch_id}/cancel");
    Ok(parse_response(&http_post(&url, &json!({}))))
}

fn batches_results(params: &Value) -> Result<String, String> {
    let batch_id = match path_id(params, "batch_id") {
        Ok(id) => id,
        Err(refusal) => return Ok(refusal),
    };
    let url = format!("{BASE_URL}/v1/messages/batches/{batch_id}/results");
    Ok(parse_response(&http_get(&url)))
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
        "../messages",
        "..",
        "%2e%2e",
        "%2E%2E%2Fmessages",
        "claude-sonnet-4-6?beta=true",
        "claude-sonnet-4-6#fragment",
        "claude sonnet",
        " claude-sonnet-4-6",
        "claude-sonnet-4-6\n",
    ];

    fn run(operation: &str, params: Value) -> Value {
        let input = json!({"operation": operation, "params": params}).to_string();
        serde_json::from_str(&handle_request(&input).unwrap()).unwrap()
    }

    // Every host import panics off wasm, so each answer below was given
    // without making a request.
    #[test]
    fn a_model_name_off_the_id_grammar_is_refused_before_any_request() {
        for model in HOSTILE {
            let described = run("describe", json!({"model": model}));
            assert_eq!(described["status"], 404, "{model:?}");
            assert_eq!(described["error"]["type"], "unknown_model", "{model:?}");

            let chat = run("chat", json!({"model": model, "messages": [{"role": "user", "content": "hi"}]}));
            assert_eq!(chat["status"], 404, "{model:?}");
            assert_eq!(chat["error"]["type"], "unknown_model", "{model:?}");
        }
    }

    #[test]
    fn a_batch_id_off_the_id_grammar_is_refused_before_any_request() {
        for batch_id in HOSTILE.iter().chain(&["msgbatch_1/cancel", ""]) {
            for operation in [batches_get, batches_cancel, batches_results] {
                let refused: Value =
                    serde_json::from_str(&operation(&json!({"batch_id": batch_id})).unwrap()).unwrap();
                assert_eq!(refused["status"], 400, "{batch_id:?}");
                assert_eq!(refused["error"]["type"], "invalid_request", "{batch_id:?}");
            }
        }
    }

    #[test]
    fn a_request_names_the_connection_and_carries_no_credential() {
        for req in [
            request("GET", "https://x/v1/models", String::new()),
            request("POST", "https://x/v1/messages", "{}".into()),
        ] {
            assert_eq!(req["connection"], CONNECTION);
            for name in req["headers"].as_object().unwrap().keys() {
                assert!(!credential_header(name), "{name}");
            }
        }
    }

    #[test]
    fn paging_values_are_percent_encoded_into_the_query() {
        let url = paged(
            "https://x/v1/models".into(),
            &json!({"limit": 5, "after_id": "a&before_id=b", "before_id": "c d#e"}),
        );
        assert_eq!(url, "https://x/v1/models?limit=5&after_id=a%26before_id%3Db&before_id=c%20d%23e");
        assert_eq!(paged("https://x/v1/models".into(), &json!({})), "https://x/v1/models");
    }
}
