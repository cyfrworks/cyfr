//! The `model/chat@1` contract on OpenRouter's Chat Completions API.
//!
//! Three operations share the catalyst envelope: `chat` takes a contract
//! request, streams the answer as contract stream events and answers the
//! whole contract response, `describe` answers what this catalyst can do
//! (and, for a named model, its window from the model listing), and
//! `models` lists what the key can reach. The request and response shapes
//! are the contract's; the provider's are built and read here and never
//! leave this module.

use std::collections::BTreeMap;

use serde_json::{json, Value};

use crate::bindings::cyfr::http::fetch;
use crate::stream::{self, Deltas, Frame, Outcome, Sink};
use crate::BASE_URL;

const PROVIDER: &str = "openrouter";
const DEFAULT_MAX_TOKENS: u64 = 16384;
const PROVIDER_TOOLS: &[&str] = &["web_search"];
const MEDIA_TYPES: &[&str] = &[
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "application/pdf",
];
const TOOL_RESULT_NAME_REQUIRED: bool = false;

pub const CONTRACT: &str = "model/chat@1";

// ---------------------------------------------------------------------------
// The contract request
// ---------------------------------------------------------------------------

pub struct Request {
    pub model: String,
    pub system: Option<String>,
    pub messages: Vec<Message>,
    pub tools: Vec<Tool>,
    pub provider_tools: Vec<String>,
    pub max_tokens: Option<u64>,
    pub temperature: Option<f64>,
}

pub struct Message {
    pub role: Role,
    pub content: Vec<Block>,
}

#[derive(PartialEq, Clone, Copy)]
pub enum Role {
    User,
    Assistant,
    Tool,
}

// A provider maps the fields its API carries; the rest ride along.
#[allow(dead_code)]
pub enum Block {
    Text(String),
    Image {
        media_type: String,
        data: String,
    },
    Document {
        media_type: String,
        data: String,
        filename: Option<String>,
    },
    ToolCall {
        id: String,
        name: String,
        arguments: Value,
        provider_data: Option<Value>,
    },
    ToolResult {
        tool_call_id: String,
        name: String,
        content: String,
        is_error: bool,
    },
}

pub struct Tool {
    pub name: String,
    pub description: String,
    pub parameters: Value,
}

/// Validate a `chat` request. The message names what is wrong for the
/// caller; a request that does not parse never reaches the key.
pub fn parse_request(params: &Value) -> Result<Request, String> {
    let model = str_field(params, "model")?.ok_or("'model' is required")?;
    let system = str_field(params, "system")?;

    let raw_messages = params
        .get("messages")
        .and_then(Value::as_array)
        .ok_or("'messages' must be a non-empty list")?;
    if raw_messages.is_empty() {
        return Err("'messages' must be a non-empty list".into());
    }
    let messages = raw_messages
        .iter()
        .enumerate()
        .map(|(i, m)| parse_message(i, m))
        .collect::<Result<Vec<_>, _>>()?;

    let tools = match params.get("tools") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(list)) => list
            .iter()
            .map(parse_tool)
            .collect::<Result<Vec<_>, _>>()?,
        Some(_) => return Err("'tools' must be a list".into()),
    };

    let provider_tools = match params.get("provider_tools") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(list)) => {
            let mut names = Vec::new();
            for entry in list {
                let name = entry
                    .as_str()
                    .ok_or("'provider_tools' entries must be strings")?;
                if !PROVIDER_TOOLS.contains(&name) {
                    return Err(format!(
                        "provider tool '{name}' is not one this catalyst offers ({})",
                        PROVIDER_TOOLS.join(", ")
                    ));
                }
                names.push(name.to_string());
            }
            names
        }
        Some(_) => return Err("'provider_tools' must be a list".into()),
    };

    let max_tokens = match params.get("max_tokens") {
        None | Some(Value::Null) => None,
        Some(v) => Some(
            v.as_u64()
                .filter(|n| *n > 0)
                .ok_or("'max_tokens' must be a positive integer")?,
        ),
    };

    let temperature = match params.get("temperature") {
        None | Some(Value::Null) => None,
        Some(v) => Some(v.as_f64().ok_or("'temperature' must be a number")?),
    };

    Ok(Request {
        model,
        system,
        messages,
        tools,
        provider_tools,
        max_tokens,
        temperature,
    })
}

fn str_field(params: &Value, key: &str) -> Result<Option<String>, String> {
    match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !s.is_empty() => Ok(Some(s.clone())),
        Some(Value::String(_)) => Err(format!("'{key}' must not be empty")),
        Some(_) => Err(format!("'{key}' must be a string")),
    }
}

fn parse_message(index: usize, raw: &Value) -> Result<Message, String> {
    let role = match raw.get("role").and_then(Value::as_str) {
        Some("user") => Role::User,
        Some("assistant") => Role::Assistant,
        Some("tool") => Role::Tool,
        _ => return Err(format!("messages[{index}].role must be user, assistant or tool")),
    };

    let content = match raw.get("content") {
        Some(Value::String(text)) => vec![Block::Text(text.clone())],
        Some(Value::Array(blocks)) => blocks
            .iter()
            .enumerate()
            .map(|(j, b)| parse_block(index, j, role, b))
            .collect::<Result<Vec<_>, _>>()?,
        _ => {
            return Err(format!(
                "messages[{index}].content must be a string or a list of blocks"
            ))
        }
    };

    if content.is_empty() {
        return Err(format!("messages[{index}].content must not be empty"));
    }

    Ok(Message { role, content })
}

fn parse_block(i: usize, j: usize, role: Role, raw: &Value) -> Result<Block, String> {
    let at = format!("messages[{i}].content[{j}]");
    let kind = raw
        .get("type")
        .and_then(Value::as_str)
        .ok_or(format!("{at}.type is required"))?;

    match (kind, role) {
        ("text", _) => Ok(Block::Text(required_str(raw, "text", &at)?)),
        ("image", Role::User) => Ok(Block::Image {
            media_type: required_str(raw, "media_type", &at)?,
            data: required_str(raw, "data", &at)?,
        }),
        ("document", Role::User) => Ok(Block::Document {
            media_type: required_str(raw, "media_type", &at)?,
            data: required_str(raw, "data", &at)?,
            filename: raw
                .get("filename")
                .and_then(Value::as_str)
                .map(str::to_string),
        }),
        ("tool_call", Role::Assistant) => Ok(Block::ToolCall {
            id: required_str(raw, "id", &at)?,
            name: required_str(raw, "name", &at)?,
            arguments: match raw.get("arguments") {
                None | Some(Value::Null) => json!({}),
                Some(v @ Value::Object(_)) => v.clone(),
                Some(_) => return Err(format!("{at}.arguments must be an object")),
            },
            provider_data: match raw.get("provider_data") {
                None | Some(Value::Null) => None,
                Some(v @ Value::Object(_)) => Some(v.clone()),
                Some(_) => return Err(format!("{at}.provider_data must be an object")),
            },
        }),
        ("tool_result", Role::Tool) => {
            let name = raw
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            if TOOL_RESULT_NAME_REQUIRED && name.is_empty() {
                return Err(format!("{at}.name is required: this provider keys results by tool name"));
            }
            Ok(Block::ToolResult {
                tool_call_id: required_str(raw, "tool_call_id", &at)?,
                name,
                content: result_text(raw.get("content"), &at)?,
                is_error: raw.get("is_error").and_then(Value::as_bool).unwrap_or(false),
            })
        }
        (kind, _) => Err(format!("{at}: a '{kind}' block is not allowed in this role")),
    }
}

fn required_str(raw: &Value, key: &str, at: &str) -> Result<String, String> {
    raw.get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or(format!("{at}.{key} must be a string"))
}

/// A tool result's content: a string, or text blocks joined in order.
fn result_text(content: Option<&Value>, at: &str) -> Result<String, String> {
    match content {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(s)) => Ok(s.clone()),
        Some(Value::Array(blocks)) => {
            let mut text = String::new();
            for block in blocks {
                match block.get("text").and_then(Value::as_str) {
                    Some(t) => text.push_str(t),
                    None => return Err(format!("{at}.content blocks must be text blocks")),
                }
            }
            Ok(text)
        }
        Some(_) => Err(format!("{at}.content must be a string or a list of text blocks")),
    }
}

fn parse_tool(raw: &Value) -> Result<Tool, String> {
    let name = raw
        .get("name")
        .and_then(Value::as_str)
        .filter(|n| !n.is_empty())
        .ok_or("tools[].name is required")?;
    let parameters = match raw.get("parameters") {
        None | Some(Value::Null) => json!({"type": "object", "properties": {}}),
        Some(v @ Value::Object(_)) => v.clone(),
        Some(_) => return Err(format!("tools[{name}].parameters must be an object")),
    };
    Ok(Tool {
        name: name.to_string(),
        description: raw
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        parameters,
    })
}

// ---------------------------------------------------------------------------
// Envelopes
// ---------------------------------------------------------------------------

fn ok(data: Value) -> String {
    json!({"status": 200, "data": data}).to_string()
}

/// A typed refusal.
pub fn refuse(status: i64, kind: &str, message: &str) -> String {
    json!({"status": status, "error": {"type": kind, "message": message}}).to_string()
}

/// The provider's refusal, typed by its status, with the provider's own
/// body kept beside the message.
fn provider_refusal(status: i64, body: &str) -> String {
    let provider: Value = serde_json::from_str(body).unwrap_or(Value::String(body.to_string()));
    let message = match provider.get("error") {
        Some(Value::String(s)) => s.clone(),
        Some(err) => err
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("the provider refused the request")
            .to_string(),
        None => "the provider refused the request".to_string(),
    };
    json!({
        "status": status,
        "error": {"type": error_kind(status), "message": message, "provider": provider}
    })
    .to_string()
}

fn error_kind(status: i64) -> &'static str {
    match status {
        400 | 404 | 413 | 422 => "invalid_request",
        401 | 403 => "authentication",
        429 => "rate_limited",
        503 | 529 => "overloaded",
        _ => "provider_error",
    }
}

/// The host's HTTP answer, as the provider's parsed 2xx body or a refusal
/// envelope ready to return.
fn provider_body(resp_str: &str) -> Result<Value, String> {
    let resp: Value = serde_json::from_str(resp_str)
        .map_err(|e| refuse(502, "provider_error", &format!("unreadable host response: {e}")))?;

    if let Some(err) = resp.get("error") {
        let message = match err {
            Value::String(s) => s.clone(),
            other => other
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the request could not be made")
                .to_string(),
        };
        return Err(refuse(502, "provider_error", &message));
    }

    let status = resp.get("status").and_then(Value::as_i64).unwrap_or(502);
    let body = resp.get("body").and_then(Value::as_str).unwrap_or("");

    if (200..300).contains(&status) {
        serde_json::from_str(body)
            .map_err(|e| refuse(502, "provider_error", &format!("unreadable provider body: {e}")))
    } else {
        Err(provider_refusal(status, body))
    }
}

#[allow(dead_code)]
fn parse_arguments(raw: Option<&Value>) -> Value {
    match raw {
        Some(Value::String(s)) => serde_json::from_str(s).unwrap_or(json!({})),
        Some(v @ Value::Object(_)) => v.clone(),
        _ => json!({}),
    }
}

// ---------------------------------------------------------------------------
// describe
// ---------------------------------------------------------------------------

/// What this catalyst can do.
pub fn describe() -> String {
    ok(capabilities())
}

fn capabilities() -> Value {
    json!({
        "contracts": [CONTRACT],
        "provider": PROVIDER,
        "tools": true,
        "provider_tools": PROVIDER_TOOLS,
        "media_types": MEDIA_TYPES,
        "streaming": true,
        "defaults": {"max_tokens": DEFAULT_MAX_TOKENS}
    })
}

/// What this catalyst can do, with the named model's `context_window` and
/// `max_output_tokens` as the model listing reports them (the latter only
/// where the listing names one). A model the listing does not hold is
/// refused.
pub fn describe_model(api_key: &str, model: &str) -> String {
    let req = json!({
        "method": "GET",
        "url": format!("{BASE_URL}/models"),
        "headers": headers(api_key),
        "body": ""
    });

    described(model, provider_body(&fetch::request(&req.to_string())))
}

fn described(model: &str, answer: Result<Value, String>) -> String {
    let data = match answer {
        Ok(data) => data,
        Err(envelope) => return envelope,
    };
    let listed = normalize_models(&data);
    let Some(found) = listed["models"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|m| m["id"] == model)
    else {
        return refuse(
            404,
            "unknown_model",
            &format!("'{model}' is not a model this provider knows"),
        );
    };

    let mut described = capabilities();
    described["model"] = json!(model);
    for key in ["context_window", "max_output_tokens"] {
        if let Some(value) = found.get(key) {
            described[key] = value.clone();
        }
    }
    ok(described)
}

/// The model listing as the contract's `{"models": [{id, name, ...}]}`,
/// sorted by id.
fn listing(mut models: Vec<Value>) -> Value {
    models.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    json!({"models": models})
}

// ---------------------------------------------------------------------------
// chat — Chat Completions
// ---------------------------------------------------------------------------

fn headers(api_key: &str) -> Value {
    json!({
        "Authorization": format!("Bearer {api_key}"),
        "Content-Type": "application/json"
    })
}

pub fn chat(api_key: &str, request: &Request) -> String {
    let mut body = build_body(request);
    body["stream"] = json!(true);
    body["stream_options"] = json!({"include_usage": true});

    let req = json!({
        "method": "POST",
        "url": format!("{BASE_URL}/chat/completions"),
        "headers": headers(api_key),
        "body": body.to_string()
    });

    let mut deltas = Deltas::new(stream::Host);
    let mut assembly = Assembly::default();
    let outcome = stream::read(&req, &mut deltas, |frame, deltas| {
        assembly.apply(&frame, deltas)
    });
    answer(outcome, assembly, &request.model, &mut deltas)
}

/// The contract answer a stream came to: the response, with its closing
/// events emitted, or the refusal, emitted as the stream's error.
fn answer<S: Sink>(
    outcome: Outcome,
    mut assembly: Assembly,
    requested_model: &str,
    deltas: &mut Deltas<S>,
) -> String {
    let envelope = match outcome {
        Outcome::Completed => match assembly.error.take() {
            Some(error) => stream_refusal(&error),
            None if assembly.chunks == 0 => {
                refuse(502, "provider_error", "the stream ended before any response")
            }
            None => {
                assembly.end_calls(deltas);
                let response = normalize(&assembly.response(), requested_model);
                stream::close(deltas, &response);
                return ok(response);
            }
        },
        Outcome::Refused { status, body } => provider_refusal(status, &body),
        Outcome::Failed(message) => refuse(502, "provider_error", &message),
    };

    stream::error(deltas, &envelope);
    envelope
}

/// One streamed tool call: its id and name from its first fragment, its
/// arguments joined across the rest.
#[derive(Default)]
struct Call {
    id: String,
    name: String,
    arguments: String,
    ended: bool,
}

/// A Chat Completions response rebuilt from its streamed chunks, emitting
/// the contract's stream events as it goes. Tool calls are keyed by the
/// stream's index; a call ends when the next one starts or the choice
/// finishes.
#[derive(Default)]
pub struct Assembly {
    chunks: u64,
    model: Option<Value>,
    text: String,
    calls: BTreeMap<u64, Call>,
    finish_reason: Option<Value>,
    usage: Option<Value>,
    error: Option<Value>,
}

impl Assembly {
    pub fn apply<S: Sink>(&mut self, frame: &Frame, deltas: &mut Deltas<S>) {
        // `[DONE]` closes the stream and is not JSON.
        let Ok(data) = serde_json::from_str::<Value>(&frame.data) else {
            return;
        };
        if let Some(error) = data.get("error") {
            self.error = Some(error.clone());
            return;
        }
        self.chunks += 1;

        if let Some(model) = data.get("model") {
            self.model = Some(model.clone());
        }
        if let Some(usage) = data.get("usage").filter(|u| u.is_object()) {
            self.usage = Some(usage.clone());
        }

        let Some(choice) = data.get("choices").and_then(|c| c.get(0)) else {
            return;
        };
        let delta = &choice["delta"];

        if let Some(text) = delta.get("content").and_then(Value::as_str) {
            self.text.push_str(text);
            deltas.text(text);
        }
        for fragment in delta["tool_calls"].as_array().into_iter().flatten() {
            self.call_fragment(fragment, deltas);
        }

        if let Some(reason) = choice.get("finish_reason").filter(|r| !r.is_null()) {
            self.finish_reason = Some(reason.clone());
            self.end_calls(deltas);
        }
    }

    fn call_fragment<S: Sink>(&mut self, fragment: &Value, deltas: &mut Deltas<S>) {
        let index = fragment["index"].as_u64().unwrap_or(self.calls.len() as u64);
        let function = &fragment["function"];

        if !self.calls.contains_key(&index) {
            self.end_calls(deltas);
            let call = Call {
                id: fragment["id"].as_str().unwrap_or("").to_string(),
                name: function["name"].as_str().unwrap_or("").to_string(),
                ..Call::default()
            };
            deltas.event(stream::tool_call_start(index, &call.id, &call.name));
            self.calls.insert(index, call);
        }

        if let Some(arguments) = function.get("arguments").and_then(Value::as_str) {
            if let Some(call) = self.calls.get_mut(&index) {
                call.arguments.push_str(arguments);
            }
            if !arguments.is_empty() {
                deltas.arguments(index, arguments);
            }
        }
    }

    /// End every call still open, in index order.
    fn end_calls<S: Sink>(&mut self, deltas: &mut Deltas<S>) {
        for (index, call) in self.calls.iter_mut().filter(|(_, c)| !c.ended) {
            call.ended = true;
            deltas.event(stream::tool_call_end(*index));
        }
    }

    /// The whole response, as Chat Completions answers it without a stream.
    pub fn response(&self) -> Value {
        let mut message = json!({"role": "assistant", "content": self.text});
        if !self.calls.is_empty() {
            message["tool_calls"] = self
                .calls
                .values()
                .map(|call| {
                    json!({
                        "id": call.id,
                        "type": "function",
                        "function": {"name": call.name, "arguments": call.arguments}
                    })
                })
                .collect();
        }

        let mut data = json!({
            "choices": [{
                "message": message,
                "finish_reason": self.finish_reason.clone().unwrap_or(Value::Null)
            }]
        });
        if let Some(model) = &self.model {
            data["model"] = model.clone();
        }
        if let Some(usage) = &self.usage {
            data["usage"] = usage.clone();
        }
        data
    }
}

/// An error chunk in the stream, typed like a status refusal. Its code is
/// an HTTP status when it is one.
fn stream_refusal(error: &Value) -> String {
    let status = error
        .get("code")
        .and_then(Value::as_i64)
        .filter(|code| (400..600).contains(code))
        .unwrap_or(502);
    let message = error["message"]
        .as_str()
        .unwrap_or("the provider stopped the stream");
    json!({
        "status": status,
        "error": {"type": error_kind(status), "message": message, "provider": error}
    })
    .to_string()
}

/// The Chat Completions body for a contract request.
pub fn build_body(request: &Request) -> Value {
    let mut messages: Vec<Value> = Vec::new();
    if let Some(system) = &request.system {
        messages.push(json!({"role": "system", "content": system}));
    }
    for message in &request.messages {
        to_messages(message, &mut messages);
    }

    let mut body = json!({"model": request.model, "messages": messages});

    let tools: Vec<Value> = request
        .tools
        .iter()
        .map(|t| {
            json!({
                "type": "function",
                "function": {
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.parameters
                }
            })
        })
        .collect();
    if !tools.is_empty() {
        body["tools"] = json!(tools);
    }
    if request.provider_tools.iter().any(|t| t == "web_search") {
        body["plugins"] = json!([{"id": "web"}]);
    }

    if let Some(max_tokens) = request.max_tokens {
        body["max_tokens"] = json!(max_tokens);
    }
    if let Some(temperature) = request.temperature {
        body["temperature"] = json!(temperature);
    }

    body
}

fn to_messages(message: &Message, messages: &mut Vec<Value>) {
    match message.role {
        Role::User => {
            let parts: Vec<Value> = message
                .content
                .iter()
                .filter_map(|block| match block {
                    Block::Text(text) => Some(json!({"type": "text", "text": text})),
                    Block::Image { media_type, data } => Some(json!({
                        "type": "image_url",
                        "image_url": {"url": format!("data:{media_type};base64,{data}")}
                    })),
                    Block::Document {
                        media_type,
                        data,
                        filename,
                    } => Some(json!({
                        "type": "file",
                        "file": {
                            "filename": filename.as_deref().unwrap_or("attachment"),
                            "file_data": format!("data:{media_type};base64,{data}")
                        }
                    })),
                    _ => None,
                })
                .collect();
            messages.push(json!({"role": "user", "content": parts}));
        }
        Role::Assistant => {
            let text: String = message
                .content
                .iter()
                .filter_map(|block| match block {
                    Block::Text(text) => Some(text.as_str()),
                    _ => None,
                })
                .collect();
            let calls: Vec<Value> = message
                .content
                .iter()
                .filter_map(|block| match block {
                    Block::ToolCall {
                        id,
                        name,
                        arguments,
                        ..
                    } => Some(json!({
                        "id": id,
                        "type": "function",
                        "function": {"name": name, "arguments": arguments.to_string()}
                    })),
                    _ => None,
                })
                .collect();
            let mut entry = json!({"role": "assistant", "content": text});
            if !calls.is_empty() {
                entry["tool_calls"] = json!(calls);
            }
            messages.push(entry);
        }
        Role::Tool => {
            for block in &message.content {
                if let Block::ToolResult {
                    tool_call_id,
                    content,
                    ..
                } = block
                {
                    messages.push(json!({
                        "role": "tool",
                        "tool_call_id": tool_call_id,
                        "content": content
                    }));
                }
            }
        }
    }
}

/// A Chat Completions response as the contract response.
pub fn normalize(data: &Value, requested_model: &str) -> Value {
    let choice = data
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first());
    let message = choice.and_then(|c| c.get("message"));
    let mut content: Vec<Value> = Vec::new();

    if let Some(text) = message
        .and_then(|m| m.get("content"))
        .and_then(Value::as_str)
    {
        if !text.is_empty() {
            content.push(json!({"type": "text", "text": text}));
        }
    }

    let mut tool_calls = 0;
    for call in message
        .and_then(|m| m.get("tool_calls"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        tool_calls += 1;
        let function = call.get("function").cloned().unwrap_or(json!({}));
        content.push(json!({
            "type": "tool_call",
            "id": call.get("id").and_then(Value::as_str).unwrap_or(""),
            "name": function.get("name").and_then(Value::as_str).unwrap_or(""),
            "arguments": parse_arguments(function.get("arguments"))
        }));
    }

    let stop_reason = match choice
        .and_then(|c| c.get("finish_reason"))
        .and_then(Value::as_str)
    {
        Some("tool_calls") => "tool_call",
        Some("stop") if tool_calls > 0 => "tool_call",
        Some("stop") => "end_turn",
        Some("length") => "max_tokens",
        Some("content_filter") => "content_filter",
        _ => "other",
    };

    let usage = data.get("usage").cloned().unwrap_or(json!({}));
    let count = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    let cache_read = usage
        .get("prompt_tokens_details")
        .and_then(|d| d.get("cached_tokens"))
        .and_then(Value::as_u64)
        .unwrap_or(0);

    json!({
        "model": data.get("model").and_then(Value::as_str).unwrap_or(requested_model),
        "content": content,
        "stop_reason": stop_reason,
        "usage": {
            "input_tokens": count("prompt_tokens"),
            "output_tokens": count("completion_tokens"),
            "cache_read_tokens": cache_read,
            "cache_write_tokens": 0
        }
    })
}

// ---------------------------------------------------------------------------
// models
// ---------------------------------------------------------------------------

pub fn models(api_key: &str) -> String {
    let req = json!({
        "method": "GET",
        "url": format!("{BASE_URL}/models"),
        "headers": headers(api_key),
        "body": ""
    });

    match provider_body(&fetch::request(&req.to_string())) {
        Ok(data) => ok(normalize_models(&data)),
        Err(envelope) => envelope,
    }
}

pub fn normalize_models(data: &Value) -> Value {
    listing(
        data.get("data")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|m| {
                let id = m.get("id").and_then(Value::as_str)?;
                let mut entry = json!({
                    "id": id,
                    "name": m.get("name").and_then(Value::as_str).unwrap_or(id)
                });
                if let Some(limit) = m.get("context_length").and_then(Value::as_u64) {
                    entry["context_window"] = json!(limit);
                }
                if let Some(limit) = m
                    .get("top_provider")
                    .and_then(|p| p.get("max_completion_tokens"))
                    .and_then(Value::as_u64)
                {
                    entry["max_output_tokens"] = json!(limit);
                }
                Some(entry)
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn contract_request(extra: Value) -> Value {
        let mut base = json!({
            "model": "model-x",
            "system": "Be brief.",
            "messages": [
                {"role": "user", "content": "hi"},
                {"role": "assistant", "content": [
                    {"type": "text", "text": ""},
                    {"type": "tool_call", "id": "call_1", "name": "files.read",
                     "arguments": {"path": "a.txt"}}
                ]},
                {"role": "tool", "content": [
                    {"type": "tool_result", "tool_call_id": "call_1", "name": "files.read",
                     "content": "contents", "is_error": false}
                ]},
                {"role": "user", "content": [
                    {"type": "text", "text": "and this"},
                    {"type": "image", "media_type": "image/png", "data": "AAAA"},
                    {"type": "document", "media_type": "application/pdf", "data": "BBBB",
                     "filename": "notes.pdf"}
                ]}
            ],
            "tools": [{"name": "files.read", "description": "read", "parameters": {"type": "object"}}],
            "provider_tools": ["web_search"],
            "max_tokens": 512,
            "temperature": 0.2
        });
        if let Some(obj) = extra.as_object() {
            for (k, v) in obj {
                base[k] = v.clone();
            }
        }
        base
    }

    #[test]
    fn a_request_off_the_contract_is_named_before_any_key_is_read() {
        let missing_model = parse_request(&json!({"messages": [{"role": "user", "content": "x"}]}));
        assert_eq!(missing_model.err().unwrap(), "'model' is required");

        let empty = parse_request(&json!({"model": "m", "messages": []}));
        assert!(empty.err().unwrap().contains("non-empty"));

        let bad_role = parse_request(&json!({"model": "m", "messages": [{"role": "system", "content": "x"}]}));
        assert!(bad_role.err().unwrap().contains("messages[0].role"));

        let call_in_user = parse_request(&json!({"model": "m", "messages": [
            {"role": "user", "content": [{"type": "tool_call", "id": "1", "name": "n"}]}
        ]}));
        assert!(call_in_user.err().unwrap().contains("not allowed in this role"));

        let unknown_tool = parse_request(&contract_request(json!({"provider_tools": ["nope"]})));
        assert!(unknown_tool.err().unwrap().contains("nope"));

        let bad_max = parse_request(&contract_request(json!({"max_tokens": 0})));
        assert!(bad_max.err().unwrap().contains("max_tokens"));

        let bad_tools = parse_request(&contract_request(json!({"tools": [{"description": "no name"}]})));
        assert!(bad_tools.err().unwrap().contains("name"));
    }

    #[test]
    fn a_provider_refusal_is_typed_by_its_status() {
        let limited = json!({"status": 429, "headers": {}, "body": "{\"error\":{\"message\":\"slow down\",\"type\":\"rate_limit\"}}"});
        let envelope: Value = serde_json::from_str(&provider_body(&limited.to_string()).unwrap_err()).unwrap();
        assert_eq!(envelope["status"], 429);
        assert_eq!(envelope["error"]["type"], "rate_limited");
        assert_eq!(envelope["error"]["message"], "slow down");
        assert_eq!(envelope["error"]["provider"]["error"]["type"], "rate_limit");

        let denied: Value = serde_json::from_str(&provider_body(&json!({"status": 401, "body": "{\"error\":\"bad key\"}"}).to_string()).unwrap_err()).unwrap();
        assert_eq!(denied["error"]["type"], "authentication");
        assert_eq!(denied["error"]["message"], "bad key");

        let rejected: Value = serde_json::from_str(&provider_body(&json!({"status": 400, "body": "not json"}).to_string()).unwrap_err()).unwrap();
        assert_eq!(rejected["error"]["type"], "invalid_request");
        assert_eq!(rejected["error"]["provider"], "not json");

        let blocked: Value = serde_json::from_str(&provider_body(&json!({"error": "egress denied"}).to_string()).unwrap_err()).unwrap();
        assert_eq!(blocked["status"], 502);
        assert_eq!(blocked["error"]["type"], "provider_error");
        assert_eq!(blocked["error"]["message"], "egress denied");

        let fine = provider_body(&json!({"status": 200, "body": "{\"ok\":true}"}).to_string()).unwrap();
        assert_eq!(fine["ok"], true);
    }

    #[test]
    fn describe_names_the_contract_and_a_models_window_from_the_listing() {
        let capable: Value = serde_json::from_str(&describe()).unwrap();
        assert_eq!(capable["status"], 200);
        assert_eq!(capable["data"]["contracts"][0], CONTRACT);
        assert_eq!(capable["data"]["provider"], PROVIDER);
        assert_eq!(capable["data"]["streaming"], true);
        assert_eq!(capable["data"]["provider_tools"], json!(PROVIDER_TOOLS));

        let listing = json!({"data": [
            {"id": "vendor/model-b", "context_length": 200000,
             "top_provider": {"max_completion_tokens": 8192}},
            {"id": "vendor/model-a", "context_length": 32768,
             "top_provider": {"max_completion_tokens": null}}
        ]});

        let found: Value = serde_json::from_str(&described("vendor/model-b", Ok(listing.clone()))).unwrap();
        assert_eq!(found["data"]["contracts"][0], CONTRACT);
        assert_eq!(found["data"]["context_window"], 200000);
        assert_eq!(found["data"]["max_output_tokens"], 8192);

        let open: Value = serde_json::from_str(&described("vendor/model-a", Ok(listing.clone()))).unwrap();
        assert_eq!(open["data"]["context_window"], 32768);
        assert!(open["data"].get("max_output_tokens").is_none());

        let unknown: Value = serde_json::from_str(&described("vendor/nope", Ok(listing))).unwrap();
        assert_eq!(unknown["status"], 404);
        assert_eq!(unknown["error"]["type"], "unknown_model");

        let denied = provider_body(&json!({"status": 401, "body": "{\"error\":\"bad key\"}"}).to_string());
        let refused: Value = serde_json::from_str(&described("vendor/model-b", denied)).unwrap();
        assert_eq!(refused["error"]["type"], "authentication");
    }

    fn frames(transcript: &str) -> Vec<Frame> {
        let mut sse = stream::Sse::default();
        let mut frames = sse.feed(transcript);
        frames.extend(sse.finish());
        frames
    }

    fn chunk(choice: Value) -> String {
        let data = json!({"id": "gen-1", "model": "vendor/model-x", "choices": [choice]});
        format!("data: {data}\n\n")
    }

    #[test]
    fn a_streamed_answer_emits_its_events_and_assembles_the_same_response() {
        let whole = json!({
            "model": "vendor/model-x",
            "choices": [{
                "finish_reason": "tool_calls",
                "message": {
                    "role": "assistant",
                    "content": "Looking.",
                    "tool_calls": [
                        {"id": "call_9", "type": "function",
                         "function": {"name": "files.read", "arguments": "{\"path\":\"b\"}"}},
                        {"id": "call_10", "type": "function",
                         "function": {"name": "files.list", "arguments": "{}"}}
                    ]
                }
            }],
            "usage": {"prompt_tokens": 40, "completion_tokens": 6,
                      "prompt_tokens_details": {"cached_tokens": 30}}
        });

        let transcript = [
            ": OPENROUTER PROCESSING\n\n".to_string(),
            chunk(json!({"index": 0, "delta": {"role": "assistant", "content": "Look"}, "finish_reason": null})),
            chunk(json!({"index": 0, "delta": {"content": "ing."}, "finish_reason": null})),
            chunk(json!({"index": 0, "delta": {"tool_calls": [
                {"index": 0, "id": "call_9", "type": "function", "function": {"name": "files.read", "arguments": ""}}
            ]}, "finish_reason": null})),
            chunk(json!({"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": "{\"pa"}}]}, "finish_reason": null})),
            chunk(json!({"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": "th\":\"b\"}"}}]}, "finish_reason": null})),
            chunk(json!({"index": 0, "delta": {"tool_calls": [
                {"index": 1, "id": "call_10", "type": "function", "function": {"name": "files.list", "arguments": "{}"}}
            ]}, "finish_reason": null})),
            chunk(json!({"index": 0, "delta": {}, "finish_reason": "tool_calls"})),
            format!("data: {}\n\n", json!({"id": "gen-1", "model": "vendor/model-x", "choices": [],
                "usage": {"prompt_tokens": 40, "completion_tokens": 6, "prompt_tokens_details": {"cached_tokens": 30}}})),
            "data: [DONE]\n\n".to_string(),
        ]
        .concat();

        let mut deltas = Deltas::new(Vec::new());
        let mut assembly = Assembly::default();
        for frame in frames(&transcript) {
            assembly.apply(&frame, &mut deltas);
        }

        let envelope: Value =
            serde_json::from_str(&answer(Outcome::Completed, assembly, "model-x", &mut deltas)).unwrap();
        assert_eq!(envelope["data"], normalize(&whole, "model-x"));

        let events = deltas.into_sink();
        let kinds: Vec<&str> = events.iter().map(|e| e["type"].as_str().unwrap()).collect();
        assert_eq!(
            kinds,
            vec![
                "text.delta", "tool_call.start", "tool_call.delta", "tool_call.end",
                "tool_call.start", "tool_call.delta", "tool_call.end", "usage", "stop"
            ]
        );
        assert_eq!(events[0]["text"], "Looking.");
        assert_eq!(events[1]["id"], "call_9");
        assert_eq!(events[2]["arguments"], "{\"path\":\"b\"}");
        assert_eq!(events[4], json!({"type": "tool_call.start", "index": 1, "id": "call_10", "name": "files.list"}));
        assert_eq!(events[7]["usage"]["cache_read_tokens"], 30);
        assert_eq!(events[8]["stop_reason"], "tool_call");
    }

    #[test]
    fn a_refused_or_broken_stream_answers_a_typed_refusal_and_emits_it() {
        let mut deltas = Deltas::new(Vec::new());
        let limited: Value = serde_json::from_str(&answer(
            Outcome::Refused {
                status: 429,
                body: "{\"error\":{\"message\":\"slow down\"}}".into(),
            },
            Assembly::default(),
            "m",
            &mut deltas,
        ))
        .unwrap();
        assert_eq!(limited["error"]["type"], "rate_limited");
        assert_eq!(limited["error"]["message"], "slow down");

        let mut assembly = Assembly::default();
        let broken = [
            chunk(json!({"index": 0, "delta": {"content": "par"}, "finish_reason": null})),
            format!("data: {}\n\n", json!({"error": {"code": "server_error", "message": "upstream died"},
                "choices": [{"index": 0, "delta": {"content": ""}, "finish_reason": "error"}]})),
        ]
        .concat();
        for frame in frames(&broken) {
            assembly.apply(&frame, &mut deltas);
        }
        let died: Value =
            serde_json::from_str(&answer(Outcome::Completed, assembly, "m", &mut deltas)).unwrap();
        assert_eq!(died["status"], 502);
        assert_eq!(died["error"]["type"], "provider_error");
        assert_eq!(died["error"]["message"], "upstream died");

        let mut assembly = Assembly::default();
        for frame in frames(&format!("data: {}\n\n", json!({"error": {"code": 503, "message": "busy"}}))) {
            assembly.apply(&frame, &mut deltas);
        }
        let overloaded: Value =
            serde_json::from_str(&answer(Outcome::Completed, assembly, "m", &mut deltas)).unwrap();
        assert_eq!(overloaded["error"]["type"], "overloaded");

        let empty: Value = serde_json::from_str(&answer(
            Outcome::Completed,
            Assembly::default(),
            "m",
            &mut deltas,
        ))
        .unwrap();
        assert_eq!(empty["error"]["type"], "provider_error");

        let events = deltas.into_sink();
        let kinds: Vec<&str> = events.iter().map(|e| e["type"].as_str().unwrap()).collect();
        assert_eq!(kinds, vec!["error", "text.delta", "error", "error", "error"]);
    }
    #[test]
    fn a_contract_request_becomes_a_chat_completions_body() {
        let req = parse_request(&contract_request(json!({}))).unwrap();
        let body = build_body(&req);

        assert_eq!(body["model"], "model-x");
        assert_eq!(body["max_tokens"], 512);
        assert_eq!(body["temperature"], 0.2);
        assert_eq!(body["plugins"][0]["id"], "web");

        let messages = body["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 5);
        assert_eq!(messages[0]["role"], "system");
        assert_eq!(messages[1]["role"], "user");
        assert_eq!(messages[1]["content"][0]["text"], "hi");
        assert_eq!(messages[2]["role"], "assistant");
        assert_eq!(messages[2]["content"], "");
        assert_eq!(messages[2]["tool_calls"][0]["id"], "call_1");
        assert_eq!(messages[2]["tool_calls"][0]["function"]["arguments"], "{\"path\":\"a.txt\"}");
        assert_eq!(messages[3]["role"], "tool");
        assert_eq!(messages[3]["tool_call_id"], "call_1");
        assert_eq!(messages[3]["content"], "contents");
        assert_eq!(messages[4]["content"][1]["image_url"]["url"], "data:image/png;base64,AAAA");
        assert_eq!(messages[4]["content"][2]["file"]["filename"], "notes.pdf");

        let tools = body["tools"].as_array().unwrap();
        assert_eq!(tools[0]["type"], "function");
        assert_eq!(tools[0]["function"]["name"], "files.read");
    }

    #[test]
    fn the_defaults_leave_out_what_the_request_leaves_out() {
        let req = parse_request(&json!({
            "model": "m",
            "messages": [{"role": "user", "content": "hi"}]
        }))
        .unwrap();
        let body = build_body(&req);
        assert!(body.get("max_tokens").is_none());
        assert!(body.get("tools").is_none());
        assert!(body.get("plugins").is_none());
        assert_eq!(body["messages"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn a_chat_completions_response_becomes_a_contract_response() {
        let data = json!({
            "model": "vendor/model-x",
            "choices": [{
                "finish_reason": "tool_calls",
                "message": {
                    "role": "assistant",
                    "content": "Looking.",
                    "tool_calls": [{
                        "id": "call_9", "type": "function",
                        "function": {"name": "files.read", "arguments": "{\"path\":\"b\"}"}
                    }]
                }
            }],
            "usage": {"prompt_tokens": 40, "completion_tokens": 6,
                      "prompt_tokens_details": {"cached_tokens": 30}}
        });

        let response = normalize(&data, "model-x");
        assert_eq!(response["model"], "vendor/model-x");
        assert_eq!(response["stop_reason"], "tool_call");
        let content = response["content"].as_array().unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(content[0]["text"], "Looking.");
        assert_eq!(content[1]["id"], "call_9");
        assert_eq!(content[1]["arguments"]["path"], "b");
        assert_eq!(response["usage"]["input_tokens"], 40);
        assert_eq!(response["usage"]["output_tokens"], 6);
        assert_eq!(response["usage"]["cache_read_tokens"], 30);

        let ended = normalize(&json!({"choices": [{"finish_reason": "stop",
            "message": {"content": "done"}}]}), "m");
        assert_eq!(ended["stop_reason"], "end_turn");
        assert_eq!(ended["model"], "m");

        let cut = normalize(&json!({"choices": [{"finish_reason": "length",
            "message": {"content": null}}]}), "m");
        assert_eq!(cut["stop_reason"], "max_tokens");
        assert_eq!(cut["content"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn the_model_listing_is_normalized_and_sorted() {
        let data = json!({"data": [
            {"id": "vendor/model-b", "name": "Model B", "context_length": 200000,
             "top_provider": {"max_completion_tokens": 8192}},
            {"id": "vendor/model-a"},
            {"name": "nameless"}
        ]});
        let models = normalize_models(&data);
        let models = models["models"].as_array().unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0]["id"], "vendor/model-a");
        assert_eq!(models[0]["name"], "vendor/model-a");
        assert_eq!(models[1]["context_window"], 200000);
        assert_eq!(models[1]["max_output_tokens"], 8192);
    }
}
