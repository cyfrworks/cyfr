#[allow(warnings)]
mod bindings;
mod chat;
mod headers;
mod ids;
mod stream;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;
use bindings::cyfr::http::streaming;

use serde_json::{json, Value};

pub(crate) const BASE_URL: &str = "https://openrouter.ai/api/v1";

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
    // refused before any request is made. A named model's window is the
    // model listing's, asked on the connection.
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

    // The attribution headers a chat completion carries (`referer` as
    // HTTP-Referer, `title` as X-Title) reach the request verbatim, so a
    // value off its rules is refused before any request is built. No other
    // operation sends them.
    let (referer, title) = match operation {
        "chat.completions.create" | "messages.create" => {
            match (headers::referer(&params), headers::title(&params)) {
                (Ok(referer), Ok(title)) => (referer, title),
                (Err(message), _) | (_, Err(message)) => {
                    return Ok(format_error(400, "invalid_request", &message))
                }
            }
        }
        _ => (None, None),
    };

    match operation {
        // model/chat@1
        "chat" => Ok(chat::chat(&chat_request.expect("parsed above"))),
        "models" => Ok(chat::models()),
        "describe" => Ok(chat::describe_model(&described_model.expect("named above"))),

        // Chat completions (with optional streaming)
        // Alias "messages.create" for agent formula compatibility
        "chat.completions.create" | "messages.create" => {
            if stream_flag {
                chat_completions_stream(&params, referer.as_deref(), title.as_deref())
            } else {
                chat_completions_create(&params, referer.as_deref(), title.as_deref())
            }
        }

        // Models
        "models.list" => models_list(),

        // Embeddings
        "embeddings.create" => embeddings_create(&params),

        // Account info
        "credits.get" => credits_get(),
        "key.info" => key_info(),

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

/// The host's own error (a refused request, a stream that broke) as the
/// catalyst's error envelope, its type and message kept.
fn host_error(err: &Value) -> String {
    let (err_type, err_msg) = if let Some(obj) = err.as_object() {
        (
            obj.get("type").and_then(|v| v.as_str()).unwrap_or("http_error"),
            obj.get("message").and_then(|v| v.as_str()).unwrap_or("unknown host error"),
        )
    } else {
        ("http_error", err.as_str().unwrap_or("unknown host error"))
    };
    format_error(500, err_type, err_msg)
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn build_headers(referer: Option<&str>, title: Option<&str>) -> Value {
    let mut headers = json!({
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

/// A request in the host's fetch shape, named on the connection: CYFR
/// attaches the key, and the request carries none.
fn request(method: &str, url: &str, headers: Value, body: String) -> Value {
    json!({
        "method": method,
        "url": url,
        "headers": headers,
        "body": body,
        "connection": CONNECTION
    })
}

fn http_get(url: &str) -> String {
    let req = request("GET", url, build_headers(None, None), String::new());
    fetch::request(&req.to_string())
}

fn http_post(url: &str, body: &Value) -> String {
    let req = request("POST", url, build_headers(None, None), body.to_string());
    fetch::request(&req.to_string())
}

fn http_post_with_headers(url: &str, headers: &Value, body: &Value) -> String {
    fetch::request(&request("POST", url, headers.clone(), body.to_string()).to_string())
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
        return host_error(err);
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
    params: &Value,
    referer: Option<&str>,
    title: Option<&str>,
) -> Result<String, String> {
    let url = format!("{BASE_URL}/chat/completions");
    let headers = build_headers(referer, title);
    Ok(parse_response(&http_post_with_headers(&url, &headers, params)))
}

fn chat_completions_stream(
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

    let headers = build_headers(referer, title);
    let req = request("POST", &url, headers, body.to_string());

    raw_stream(&streaming::request(&req.to_string()), streaming::read, |handle| {
        let _ = streaming::close(handle);
    })
}

/// Read a raw stream to its end and answer its chunks and their text:
/// `opened` is the host's answer to the stream's request, `read` and
/// `close` the host's read and close of its handle. A refused request, and
/// a read that answers an error, answer the host's error. A read's error
/// ends the stream: the host has let the handle go by then, and every
/// later read would answer `invalid_handle`, never `done`.
fn raw_stream(
    opened: &str,
    mut read: impl FnMut(&str) -> String,
    close: impl FnOnce(&str),
) -> Result<String, String> {
    let handle_val: Value = serde_json::from_str(opened)
        .map_err(|e| format!("Failed to parse stream handle response: {e}"))?;

    if let Some(err) = handle_val.get("error") {
        return Ok(host_error(err));
    }

    let handle = handle_val
        .get("handle")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "No 'handle' in stream response".to_string())?;

    let answer = collect(handle, &mut read);
    close(handle);
    answer
}

/// The stream's SSE chunks, read until `done` or an error.
fn collect(handle: &str, read: &mut impl FnMut(&str) -> String) -> Result<String, String> {
    let mut chunks: Vec<Value> = Vec::new();
    let mut combined_text = String::new();
    let mut buffer = String::new();

    loop {
        let chunk_val: Value = serde_json::from_str(&read(handle))
            .map_err(|e| format!("Failed to parse stream chunk: {e}"))?;

        if let Some(err) = chunk_val.get("error") {
            return Ok(host_error(err));
        }

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
// Operations — Account Info
// ---------------------------------------------------------------------------

fn credits_get() -> Result<String, String> {
    let url = format!("{BASE_URL}/credits");
    Ok(parse_response(&http_get(&url)))
}

fn key_info() -> Result<String, String> {
    let url = format!("{BASE_URL}/key");
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

    /// The host's reads of a stream, in order; past them every read
    /// answers as the host does once it has let the handle go.
    fn reads(answers: &[Value]) -> (impl FnMut(&str) -> String, std::rc::Rc<std::cell::Cell<usize>>) {
        let count = std::rc::Rc::new(std::cell::Cell::new(0));
        let seen = count.clone();
        let answers: Vec<String> = answers.iter().map(Value::to_string).collect();
        let read = move |handle: &str| {
            let n = seen.get();
            seen.set(n + 1);
            assert!(n < 100, "the stream is read on after its error");
            answers.get(n).cloned().unwrap_or_else(|| {
                json!({"error": {"type": "invalid_handle", "message": format!("Unknown stream handle: {handle}")}})
                    .to_string()
            })
        };
        (read, count)
    }

    #[test]
    fn a_raw_stream_ends_at_a_read_that_answers_an_error_and_closes_its_handle() {
        let (read, count) = reads(&[
            json!({"data": "data: {\"n\": 1}\n", "done": false, "status": 200}),
            json!({"error": {"type": "stream_error", "message": "The provider's stream broke."}}),
        ]);
        let mut closed = Vec::new();
        let answer = raw_stream(r#"{"handle": "h1"}"#, read, |h| closed.push(h.to_string())).unwrap();
        let answer: Value = serde_json::from_str(&answer).unwrap();
        assert_eq!(
            answer,
            json!({"status": 500, "error": {"type": "stream_error", "message": "The provider's stream broke."}})
        );
        assert_eq!(count.get(), 2);
        assert_eq!(closed, ["h1"]);
    }

    #[test]
    fn a_refused_raw_stream_answers_the_host_s_refusal() {
        let (read, count) = reads(&[]);
        let refusal = json!({"error": {"type": "flow_blocked", "message": "No flow reaches this destination."}});
        let answer = raw_stream(&refusal.to_string(), read, |_| panic!("no handle was opened")).unwrap();
        let answer: Value = serde_json::from_str(&answer).unwrap();
        assert_eq!(
            answer,
            json!({"status": 500, "error": {"type": "flow_blocked", "message": "No flow reaches this destination."}})
        );
        assert_eq!(count.get(), 0);
    }

    #[test]
    fn a_raw_stream_read_to_done_answers_its_chunks_and_closes_its_handle() {
        let (read, count) = reads(&[
            json!({"data": "data: {\"n\": 1}\ndata: {\"n\"", "done": false, "status": 200}),
            json!({"data": "", "done": false, "status": 200}),
            json!({"data": ": 2}\ndata: [DONE]\n", "done": true, "status": 200}),
        ]);
        let mut closed = Vec::new();
        let answer = raw_stream(r#"{"handle": "h1"}"#, read, |h| closed.push(h.to_string())).unwrap();
        let answer: Value = serde_json::from_str(&answer).unwrap();
        assert_eq!(answer, json!({"status": 200, "data": {"chunks": [{"n": 1}, {"n": 2}], "combined_text": ""}}));
        assert_eq!(count.get(), 3);
        assert_eq!(closed, ["h1"]);
    }

    fn run(operation: &str, params: Value) -> Value {
        let input = json!({"operation": operation, "params": params}).to_string();
        serde_json::from_str(&handle_request(&input).unwrap()).unwrap()
    }

    // Every host import panics off wasm, so each answer below was given
    // without making a request.
    #[test]
    fn a_model_name_off_the_id_grammar_is_refused_before_any_request() {
        for model in [
            "../models",
            "openai/../../credits",
            "%2e%2e",
            "openai%2Fgpt-6-astra",
            "openai/gpt-6-astra?x=1",
            "openai/gpt-6-astra#fragment",
            "openai/gpt 6",
            " openai/gpt-6-astra",
            "openai/gpt-6-astra\n",
        ] {
            let described = run("describe", json!({"model": model}));
            assert_eq!(described["status"], 404, "{model:?}");
            assert_eq!(described["error"]["type"], "unknown_model", "{model:?}");

            let chat = run("chat", json!({"model": model, "messages": [{"role": "user", "content": "hi"}]}));
            assert_eq!(chat["status"], 404, "{model:?}");
            assert_eq!(chat["error"]["type"], "unknown_model", "{model:?}");
        }
    }

    // Each refusal below was given before any request was built, on both
    // operations that send the headers and on the streaming path.
    #[test]
    fn an_attribution_header_off_its_rules_is_refused_before_any_request_is_built() {
        let completion = json!({
            "model": "openai/gpt-6-astra",
            "messages": [{"role": "user", "content": "hi"}]
        });
        let with = |key: &str, value: Value| {
            let mut params = completion.clone();
            params[key] = value;
            params
        };
        let cases = [
            (
                with("referer", json!("https://example.com\r\nX-Injected: 1")),
                "'referer' must not contain CR, LF or any other control byte",
            ),
            (
                with("referer", json!("https://example.com/\u{0}")),
                "'referer' must not contain CR, LF or any other control byte",
            ),
            (
                with("referer", json!("ftp://example.com/file")),
                "'referer' must be an absolute http:// or https:// URL",
            ),
            (
                with("referer", json!("example.com")),
                "'referer' must be an absolute http:// or https:// URL",
            ),
            (
                with("referer", json!(format!("https://example.com/{}", "a".repeat(2048)))),
                "'referer' must be at most 2048 bytes",
            ),
            (with("referer", json!(7)), "'referer' must be a string"),
            (
                with("title", json!("Mine\nX-Injected: 1")),
                "'title' must not contain CR, LF or any other control byte",
            ),
            (
                with("title", json!("Mine\tApp")),
                "'title' must not contain CR, LF or any other control byte",
            ),
            (with("title", json!("t".repeat(257))), "'title' must be at most 256 bytes"),
            (with("title", json!(["Mine"])), "'title' must be a string"),
        ];

        for (params, rule) in &cases {
            for operation in ["chat.completions.create", "messages.create"] {
                let refused = run(operation, params.clone());
                assert_eq!(refused["status"], 400, "{operation} {params}");
                assert_eq!(refused["error"]["type"], "invalid_request", "{operation} {params}");
                assert_eq!(refused["error"]["message"], *rule, "{operation} {params}");
            }
        }

        let (params, rule) = &cases[0];
        let streamed = json!({"operation": "chat.completions.create", "params": params, "stream": true});
        let refused: Value = serde_json::from_str(&handle_request(&streamed.to_string()).unwrap()).unwrap();
        assert_eq!(refused["status"], 400);
        assert_eq!(refused["error"]["type"], "invalid_request");
        assert_eq!(refused["error"]["message"], *rule);
    }

    #[test]
    fn a_request_names_the_connection_and_carries_no_credential() {
        let attributed = build_headers(Some("https://example.com"), Some("Mine"));

        for req in [
            request("GET", "https://x/api/v1/models", build_headers(None, None), String::new()),
            request("POST", "https://x/api/v1/chat/completions", attributed.clone(), "{}".into()),
        ] {
            assert_eq!(req["connection"], CONNECTION);
            for name in req["headers"].as_object().unwrap().keys() {
                assert!(!credential_header(name), "{name}");
            }
        }

        assert_eq!(attributed["HTTP-Referer"], "https://example.com");
        assert_eq!(attributed["X-Title"], "Mine");
    }
}
