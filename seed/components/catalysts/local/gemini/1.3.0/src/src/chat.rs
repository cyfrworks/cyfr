//! The `model/chat@1` contract on the Gemini API.
//!
//! Three operations share the catalyst envelope: `chat` takes a contract
//! request, streams the answer as contract stream events and answers the
//! whole contract response, `describe` answers what this catalyst can do
//! (and, for a named model, its window from the Models API), and `models`
//! lists what the key can reach. The request and response shapes are the
//! contract's; the provider's are built and read here and never leave this
//! module.

use serde_json::{json, Map, Value};

use crate::bindings::cyfr::http::fetch;
use crate::stream::{self, Deltas, Frame, Outcome, Sink};
use crate::BASE_URL;

const PROVIDER: &str = "google";
const DEFAULT_MAX_TOKENS: u64 = 16384;
const PROVIDER_TOOLS: &[&str] = &["web_search"];
const MEDIA_TYPES: &[&str] = &[
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "application/pdf",
    "text/plain",
];
// A function response is keyed by the function's name on this API.
const TOOL_RESULT_NAME_REQUIRED: bool = true;

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
/// `max_output_tokens` as the Models API reports them. A model the API
/// does not know is refused.
pub fn describe_model(api_key: &str, model: &str) -> String {
    let req = json!({
        "method": "GET",
        "url": format!("{BASE_URL}/models/{model}"),
        "headers": headers(api_key),
        "body": ""
    });

    described(model, provider_body(&fetch::request(&req.to_string())))
}

fn described(model: &str, answer: Result<Value, String>) -> String {
    match answer {
        Ok(found) => {
            let mut data = capabilities();
            data["model"] = json!(model);
            data["context_window"] = found["inputTokenLimit"].clone();
            data["max_output_tokens"] = found["outputTokenLimit"].clone();
            ok(data)
        }
        Err(envelope) => {
            let refused: Value = serde_json::from_str(&envelope).unwrap_or(json!({}));
            if refused["status"] == 404 {
                refuse(
                    404,
                    "unknown_model",
                    &format!("'{model}' is not a model this provider knows"),
                )
            } else {
                envelope
            }
        }
    }
}

/// The model listing as the contract's `{"models": [{id, name, ...}]}`,
/// sorted by id.
fn listing(mut models: Vec<Value>) -> Value {
    models.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    json!({"models": models})
}

// ---------------------------------------------------------------------------
// chat — generateContent
// ---------------------------------------------------------------------------

fn headers(api_key: &str) -> Value {
    json!({"x-goog-api-key": api_key, "Content-Type": "application/json"})
}

pub fn chat(api_key: &str, request: &Request) -> String {
    let req = json!({
        "method": "POST",
        "url": format!("{BASE_URL}/models/{}:streamGenerateContent?alt=sse", request.model),
        "headers": headers(api_key),
        "body": build_body(request).to_string()
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
    assembly: Assembly,
    requested_model: &str,
    deltas: &mut Deltas<S>,
) -> String {
    let envelope = match outcome {
        Outcome::Completed => match assembly.error {
            Some(error) => stream_refusal(&error),
            None if assembly.chunks == 0 => {
                refuse(502, "provider_error", "the stream ended before any response")
            }
            None => {
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

/// A generateContent response rebuilt from its streamed chunks, emitting
/// the contract's stream events as it goes. Text arrives in pieces and is
/// joined per run of answer or thought text; a function call arrives whole.
#[derive(Default)]
pub struct Assembly {
    chunks: u64,
    parts: Vec<Value>,
    calls: u64,
    finish_reason: Option<Value>,
    usage: Option<Value>,
    model_version: Option<Value>,
    prompt_feedback: Option<Value>,
    error: Option<Value>,
}

impl Assembly {
    pub fn apply<S: Sink>(&mut self, frame: &Frame, deltas: &mut Deltas<S>) {
        let Ok(data) = serde_json::from_str::<Value>(&frame.data) else {
            return;
        };
        if let Some(error) = data.get("error") {
            self.error = Some(error.clone());
            return;
        }
        self.chunks += 1;

        for (key, slot) in [
            ("usageMetadata", &mut self.usage),
            ("modelVersion", &mut self.model_version),
            ("promptFeedback", &mut self.prompt_feedback),
        ] {
            if let Some(value) = data.get(key) {
                *slot = Some(value.clone());
            }
        }

        let Some(candidate) = data.get("candidates").and_then(|c| c.get(0)) else {
            return;
        };
        if let Some(reason) = candidate.get("finishReason") {
            self.finish_reason = Some(reason.clone());
        }
        for part in candidate["content"]["parts"].as_array().into_iter().flatten() {
            self.part(part, deltas);
        }
    }

    fn part<S: Sink>(&mut self, part: &Value, deltas: &mut Deltas<S>) {
        if let Some(call) = part.get("functionCall") {
            let index = self.calls;
            self.calls += 1;
            deltas.event(stream::tool_call_start(
                index,
                &format!("call_{}", self.calls),
                call["name"].as_str().unwrap_or(""),
            ));
            deltas.arguments(
                index,
                &call.get("args").cloned().unwrap_or(json!({})).to_string(),
            );
            deltas.event(stream::tool_call_end(index));
            self.parts.push(part.clone());
            return;
        }

        let Some(text) = part.get("text").and_then(Value::as_str) else {
            self.parts.push(part.clone());
            return;
        };
        let thought = is_thought(part);
        if !thought {
            deltas.text(text);
        }

        match self.parts.last_mut() {
            Some(last)
                if last.get("functionCall").is_none()
                    && last.get("text").is_some()
                    && is_thought(last) == thought =>
            {
                let joined = format!("{}{text}", last["text"].as_str().unwrap_or(""));
                last["text"] = json!(joined);
                if let Some(signature) = part.get("thoughtSignature") {
                    last["thoughtSignature"] = signature.clone();
                }
            }
            _ => self.parts.push(part.clone()),
        }
    }

    /// The whole response, as generateContent answers it without a stream.
    pub fn response(&self) -> Value {
        let mut candidate = json!({"content": {"role": "model", "parts": self.parts}});
        if let Some(reason) = &self.finish_reason {
            candidate["finishReason"] = reason.clone();
        }
        let mut data = json!({"candidates": [candidate]});
        for (key, slot) in [
            ("usageMetadata", &self.usage),
            ("modelVersion", &self.model_version),
            ("promptFeedback", &self.prompt_feedback),
        ] {
            if let Some(value) = slot {
                data[key] = value.clone();
            }
        }
        data
    }
}

fn is_thought(part: &Value) -> bool {
    part.get("thought").and_then(Value::as_bool) == Some(true)
}

/// An error chunk in the stream, typed like a status refusal.
fn stream_refusal(error: &Value) -> String {
    let status = error.get("code").and_then(Value::as_i64).unwrap_or(502);
    let message = error["message"]
        .as_str()
        .unwrap_or("the provider stopped the stream");
    json!({
        "status": status,
        "error": {"type": error_kind(status), "message": message, "provider": error}
    })
    .to_string()
}

/// The generateContent body for a contract request. The model is in the
/// URL, not the body.
pub fn build_body(request: &Request) -> Value {
    let mut body = json!({
        "contents": request.messages.iter().map(to_content).collect::<Vec<_>>()
    });

    if let Some(system) = &request.system {
        body["systemInstruction"] = json!({"parts": [{"text": system}]});
    }

    let declarations: Vec<Value> = request
        .tools
        .iter()
        .map(|t| {
            json!({
                "name": t.name,
                "description": t.description,
                "parameters": strip_schema(&t.parameters)
            })
        })
        .collect();
    let mut tools: Vec<Value> = Vec::new();
    // An empty functionDeclarations entry is refused; omit it entirely.
    if !declarations.is_empty() {
        tools.push(json!({"functionDeclarations": declarations}));
    }
    if request.provider_tools.iter().any(|t| t == "web_search") {
        tools.push(json!({"google_search": {}}));
        tools.push(json!({"url_context": {}}));
    }
    if !tools.is_empty() {
        body["tools"] = json!(tools);
        body["toolConfig"] = json!({"includeServerSideToolInvocations": true});
    }

    let mut generation = Map::new();
    if let Some(max_tokens) = request.max_tokens {
        generation.insert("maxOutputTokens".into(), json!(max_tokens));
    }
    if let Some(temperature) = request.temperature {
        generation.insert("temperature".into(), json!(temperature));
    }
    if !generation.is_empty() {
        body["generationConfig"] = Value::Object(generation);
    }

    body
}

/// The JSON Schema subset this API accepts, recursively.
fn strip_schema(schema: &Value) -> Value {
    const ALLOWED: &[&str] = &[
        "type",
        "description",
        "properties",
        "required",
        "enum",
        "items",
        "format",
        "nullable",
    ];
    match schema {
        Value::Object(map) => {
            let mut clean = Map::new();
            for (key, value) in map {
                if !ALLOWED.contains(&key.as_str()) {
                    continue;
                }
                let value = match (key.as_str(), value) {
                    ("properties", Value::Object(props)) => Value::Object(
                        props
                            .iter()
                            .map(|(name, prop)| (name.clone(), strip_schema(prop)))
                            .collect(),
                    ),
                    ("items", items) => strip_schema(items),
                    (_, other) => other.clone(),
                };
                clean.insert(key.clone(), value);
            }
            if clean.is_empty() {
                json!({"type": "object"})
            } else {
                Value::Object(clean)
            }
        }
        _ => json!({"type": "object"}),
    }
}

fn to_content(message: &Message) -> Value {
    let parts: Vec<Value> = message
        .content
        .iter()
        .filter_map(|block| match block {
            Block::Text(text) if text.is_empty() => None,
            Block::Text(text) => Some(json!({"text": text})),
            Block::Image { media_type, data }
            | Block::Document {
                media_type, data, ..
            } => Some(json!({"inlineData": {"mimeType": media_type, "data": data}})),
            Block::ToolCall {
                name,
                arguments,
                provider_data,
                ..
            } => {
                let mut part = json!({"functionCall": {"name": name, "args": arguments}});
                // The thought signature a call came with goes back with it.
                if let Some(signature) = provider_data
                    .as_ref()
                    .and_then(|d| d.get("thought_signature"))
                {
                    part["thoughtSignature"] = signature.clone();
                }
                Some(part)
            }
            Block::ToolResult { name, content, .. } => Some(json!({
                "functionResponse": {"name": name, "response": {"content": content}}
            })),
        })
        .collect();

    let role = match message.role {
        Role::Assistant => "model",
        Role::User | Role::Tool => "user",
    };

    json!({"role": role, "parts": parts})
}

/// A generateContent response as the contract response.
pub fn normalize(data: &Value, requested_model: &str) -> Value {
    let candidate = data
        .get("candidates")
        .and_then(Value::as_array)
        .and_then(|c| c.first());
    let mut content: Vec<Value> = Vec::new();
    let mut tool_calls = 0;

    for part in candidate
        .and_then(|c| c.get("content"))
        .and_then(|c| c.get("parts"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        // Thought parts are the model's working, not its answer.
        if part.get("thought").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        if let Some(text) = part.get("text").and_then(Value::as_str) {
            content.push(json!({"type": "text", "text": text}));
        }
        if let Some(call) = part.get("functionCall") {
            tool_calls += 1;
            // This API names calls but does not id them; the id is the
            // call's position, which is what a result is matched by.
            let mut block = json!({
                "type": "tool_call",
                "id": format!("call_{tool_calls}"),
                "name": call.get("name").and_then(Value::as_str).unwrap_or(""),
                "arguments": call.get("args").cloned().unwrap_or(json!({}))
            });
            if let Some(signature) = part.get("thoughtSignature") {
                block["provider_data"] = json!({"thought_signature": signature});
            }
            content.push(block);
        }
    }

    let blocked = data
        .get("promptFeedback")
        .and_then(|f| f.get("blockReason"))
        .is_some();
    let stop_reason = match candidate
        .and_then(|c| c.get("finishReason"))
        .and_then(Value::as_str)
    {
        _ if blocked && candidate.is_none() => "content_filter",
        Some("STOP") if tool_calls > 0 => "tool_call",
        Some("STOP") => "end_turn",
        Some("MAX_TOKENS") => "max_tokens",
        Some("SAFETY") | Some("RECITATION") | Some("BLOCKLIST") | Some("PROHIBITED_CONTENT")
        | Some("SPII") | Some("IMAGE_SAFETY") => "content_filter",
        _ => "other",
    };

    let usage = data.get("usageMetadata").cloned().unwrap_or(json!({}));
    let count = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);

    json!({
        "model": data.get("modelVersion").and_then(Value::as_str).unwrap_or(requested_model),
        "content": content,
        "stop_reason": stop_reason,
        "usage": {
            "input_tokens": count("promptTokenCount"),
            "output_tokens": count("candidatesTokenCount") + count("thoughtsTokenCount"),
            "cache_read_tokens": count("cachedContentTokenCount"),
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
        "url": format!("{BASE_URL}/models?pageSize=1000"),
        "headers": headers(api_key),
        "body": ""
    });

    match provider_body(&fetch::request(&req.to_string())) {
        Ok(data) => ok(normalize_models(&data)),
        Err(envelope) => envelope,
    }
}

/// The models that generate content, named without the `models/` prefix.
pub fn normalize_models(data: &Value) -> Value {
    listing(
        data.get("models")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|m| {
                m.get("supportedGenerationMethods")
                    .and_then(Value::as_array)
                    .map(|methods| methods.iter().any(|x| x.as_str() == Some("generateContent")))
                    .unwrap_or(false)
            })
            .filter_map(|m| {
                let name = m.get("name").and_then(Value::as_str)?;
                let id = name.strip_prefix("models/").unwrap_or(name);
                let mut entry = json!({
                    "id": id,
                    "name": m.get("displayName").and_then(Value::as_str).unwrap_or(id)
                });
                if let Some(limit) = m.get("inputTokenLimit").and_then(Value::as_u64) {
                    entry["context_window"] = json!(limit);
                }
                if let Some(limit) = m.get("outputTokenLimit").and_then(Value::as_u64) {
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
    fn describe_names_the_contract_and_a_models_window_from_the_models_api() {
        let capable: Value = serde_json::from_str(&describe()).unwrap();
        assert_eq!(capable["status"], 200);
        assert_eq!(capable["data"]["contracts"][0], CONTRACT);
        assert_eq!(capable["data"]["provider"], PROVIDER);
        assert_eq!(capable["data"]["streaming"], true);
        assert_eq!(capable["data"]["provider_tools"], json!(PROVIDER_TOOLS));

        let found: Value = serde_json::from_str(&described(
            "gemini-pro-latest",
            Ok(json!({"name": "models/gemini-pro-latest", "inputTokenLimit": 1048576, "outputTokenLimit": 65536})),
        ))
        .unwrap();
        assert_eq!(found["data"]["contracts"][0], CONTRACT);
        assert_eq!(found["data"]["context_window"], 1048576);
        assert_eq!(found["data"]["max_output_tokens"], 65536);

        let missing = provider_body(&json!({"status": 404, "body": "{\"error\":{\"code\":404,\"message\":\"not found\"}}"}).to_string());
        let unknown: Value = serde_json::from_str(&described("gemini-nope", missing)).unwrap();
        assert_eq!(unknown["status"], 404);
        assert_eq!(unknown["error"]["type"], "unknown_model");

        let denied = provider_body(&json!({"status": 403, "body": "{\"error\":{\"message\":\"bad key\"}}"}).to_string());
        let refused: Value = serde_json::from_str(&described("gemini-pro-latest", denied)).unwrap();
        assert_eq!(refused["error"]["type"], "authentication");
    }

    fn frames(transcript: &str) -> Vec<Frame> {
        let mut sse = stream::Sse::default();
        let mut frames = sse.feed(transcript);
        frames.extend(sse.finish());
        frames
    }

    fn chunk(data: Value) -> String {
        format!("data: {data}\r\n\r\n")
    }

    #[test]
    fn a_streamed_answer_emits_its_events_and_assembles_the_same_response() {
        let whole = json!({
            "modelVersion": "gemini-pro-2026",
            "candidates": [{
                "finishReason": "STOP",
                "content": {"role": "model", "parts": [
                    {"text": "thinking", "thought": true},
                    {"text": "Let me look."},
                    {"functionCall": {"name": "files.read", "args": {"path": "b"}}, "thoughtSignature": "sig"}
                ]}
            }],
            "usageMetadata": {"promptTokenCount": 130, "candidatesTokenCount": 5, "thoughtsTokenCount": 2}
        });

        let transcript = [
            chunk(json!({"candidates": [{"content": {"role": "model", "parts": [{"text": "think", "thought": true}]}}]})),
            chunk(json!({"candidates": [{"content": {"role": "model", "parts": [{"text": "ing", "thought": true}]}}]})),
            chunk(json!({"candidates": [{"content": {"role": "model", "parts": [{"text": "Let me "}]}}]})),
            chunk(json!({"candidates": [{"content": {"role": "model", "parts": [{"text": "look."}]}}]})),
            chunk(json!({
                "candidates": [{"finishReason": "STOP", "content": {"role": "model", "parts": [
                    {"functionCall": {"name": "files.read", "args": {"path": "b"}}, "thoughtSignature": "sig"}
                ]}}],
                "usageMetadata": {"promptTokenCount": 130, "candidatesTokenCount": 5, "thoughtsTokenCount": 2},
                "modelVersion": "gemini-pro-2026"
            })),
        ]
        .concat();

        let mut deltas = Deltas::new(Vec::new());
        let mut assembly = Assembly::default();
        for frame in frames(&transcript) {
            assembly.apply(&frame, &mut deltas);
        }

        let envelope: Value =
            serde_json::from_str(&answer(Outcome::Completed, assembly, "m", &mut deltas)).unwrap();
        assert_eq!(envelope["data"], normalize(&whole, "m"));
        assert_eq!(envelope["data"]["content"][1]["provider_data"]["thought_signature"], "sig");

        let events = deltas.into_sink();
        let kinds: Vec<&str> = events.iter().map(|e| e["type"].as_str().unwrap()).collect();
        assert_eq!(
            kinds,
            vec!["text.delta", "tool_call.start", "tool_call.delta", "tool_call.end", "usage", "stop"]
        );
        assert_eq!(events[0]["text"], "Let me look.");
        assert_eq!(events[1]["id"], "call_1");
        assert_eq!(events[1]["name"], "files.read");
        assert_eq!(events[2]["arguments"], "{\"path\":\"b\"}");
        assert_eq!(events[4]["usage"]["output_tokens"], 7);
        assert_eq!(events[5]["stop_reason"], "tool_call");
    }

    #[test]
    fn a_refused_or_broken_stream_answers_a_typed_refusal_and_emits_it() {
        let mut deltas = Deltas::new(Vec::new());
        let limited: Value = serde_json::from_str(&answer(
            Outcome::Refused {
                status: 429,
                body: "{\"error\":{\"code\":429,\"message\":\"slow down\"}}".into(),
            },
            Assembly::default(),
            "m",
            &mut deltas,
        ))
        .unwrap();
        assert_eq!(limited["error"]["type"], "rate_limited");
        assert_eq!(limited["error"]["message"], "slow down");

        let mut assembly = Assembly::default();
        for frame in frames(&chunk(json!({"error": {"code": 503, "message": "busy"}}))) {
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

        let failed: Value = serde_json::from_str(&answer(
            Outcome::Failed("connection reset".into()),
            Assembly::default(),
            "m",
            &mut deltas,
        ))
        .unwrap();
        assert_eq!(failed["error"]["message"], "connection reset");

        let events = deltas.into_sink();
        assert_eq!(events.len(), 4);
        assert!(events.iter().all(|e| e["type"] == "error"));
    }
    #[test]
    fn a_contract_request_becomes_a_generate_content_body() {
        let req = parse_request(&contract_request(json!({}))).unwrap();
        let body = build_body(&req);

        assert!(body.get("model").is_none());
        assert_eq!(body["systemInstruction"]["parts"][0]["text"], "Be brief.");
        assert_eq!(body["generationConfig"]["maxOutputTokens"], 512);
        assert_eq!(body["generationConfig"]["temperature"], 0.2);

        let contents = body["contents"].as_array().unwrap();
        assert_eq!(contents.len(), 4);
        assert_eq!(contents[0]["role"], "user");
        assert_eq!(contents[0]["parts"][0]["text"], "hi");
        assert_eq!(contents[1]["role"], "model");
        // The empty text is dropped; the call is the one part.
        assert_eq!(contents[1]["parts"].as_array().unwrap().len(), 1);
        assert_eq!(contents[1]["parts"][0]["functionCall"]["name"], "files.read");
        assert_eq!(contents[1]["parts"][0]["functionCall"]["args"]["path"], "a.txt");
        assert_eq!(contents[2]["role"], "user");
        assert_eq!(contents[2]["parts"][0]["functionResponse"]["name"], "files.read");
        assert_eq!(contents[2]["parts"][0]["functionResponse"]["response"]["content"], "contents");
        assert_eq!(contents[3]["parts"][1]["inlineData"]["mimeType"], "image/png");
        assert_eq!(contents[3]["parts"][2]["inlineData"]["mimeType"], "application/pdf");

        let tools = body["tools"].as_array().unwrap();
        assert_eq!(tools[0]["functionDeclarations"][0]["name"], "files.read");
        assert!(tools[1].get("google_search").is_some());
        assert!(tools[2].get("url_context").is_some());
        assert_eq!(body["toolConfig"]["includeServerSideToolInvocations"], true);
    }

    #[test]
    fn a_thought_signature_rides_back_with_its_call() {
        let req = parse_request(&json!({
            "model": "m",
            "messages": [
                {"role": "user", "content": "go"},
                {"role": "assistant", "content": [
                    {"type": "tool_call", "id": "call_1", "name": "f", "arguments": {},
                     "provider_data": {"thought_signature": "sig=="}}
                ]},
                {"role": "tool", "content": [
                    {"type": "tool_result", "tool_call_id": "call_1", "name": "f", "content": "r"}
                ]}
            ]
        }))
        .unwrap();
        let body = build_body(&req);
        assert_eq!(body["contents"][1]["parts"][0]["thoughtSignature"], "sig==");
        assert!(body.get("tools").is_none());
        assert!(body.get("generationConfig").is_none());
    }

    #[test]
    fn a_tool_result_without_a_name_is_refused() {
        let err = parse_request(&json!({
            "model": "m",
            "messages": [
                {"role": "tool", "content": [
                    {"type": "tool_result", "tool_call_id": "call_1", "content": "r"}
                ]}
            ]
        }))
        .err()
        .unwrap();
        assert!(err.contains("name is required"));
    }

    #[test]
    fn the_schema_is_reduced_to_what_the_api_accepts() {
        let stripped = strip_schema(&json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string", "minLength": 1, "description": "p"},
                "list": {"type": "array", "items": {"type": "string", "pattern": "x"}}
            },
            "required": ["path"]
        }));
        assert!(stripped.get("additionalProperties").is_none());
        assert!(stripped["properties"]["path"].get("minLength").is_none());
        assert_eq!(stripped["properties"]["path"]["description"], "p");
        assert!(stripped["properties"]["list"]["items"].get("pattern").is_none());
        assert_eq!(stripped["required"][0], "path");
        assert_eq!(strip_schema(&json!({})), json!({"type": "object"}));
    }

    #[test]
    fn a_generate_content_response_becomes_a_contract_response() {
        let data = json!({
            "modelVersion": "model-x-001",
            "candidates": [{
                "finishReason": "STOP",
                "content": {"role": "model", "parts": [
                    {"text": "thinking...", "thought": true},
                    {"text": "Looking."},
                    {"functionCall": {"name": "files.read", "args": {"path": "b"}},
                     "thoughtSignature": "sig=="}
                ]}
            }],
            "usageMetadata": {"promptTokenCount": 40, "candidatesTokenCount": 6,
                              "thoughtsTokenCount": 4, "cachedContentTokenCount": 10}
        });

        let response = normalize(&data, "model-x");
        assert_eq!(response["model"], "model-x-001");
        assert_eq!(response["stop_reason"], "tool_call");
        let content = response["content"].as_array().unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(content[0]["text"], "Looking.");
        assert_eq!(content[1]["id"], "call_1");
        assert_eq!(content[1]["arguments"]["path"], "b");
        assert_eq!(content[1]["provider_data"]["thought_signature"], "sig==");
        assert_eq!(response["usage"]["input_tokens"], 40);
        assert_eq!(response["usage"]["output_tokens"], 10);
        assert_eq!(response["usage"]["cache_read_tokens"], 10);

        let ended = normalize(&json!({"candidates": [{"finishReason": "STOP",
            "content": {"parts": [{"text": "done"}]}}]}), "m");
        assert_eq!(ended["stop_reason"], "end_turn");
        assert_eq!(ended["model"], "m");

        let cut = normalize(&json!({"candidates": [{"finishReason": "MAX_TOKENS",
            "content": {"parts": []}}]}), "m");
        assert_eq!(cut["stop_reason"], "max_tokens");

        let blocked = normalize(&json!({"promptFeedback": {"blockReason": "SAFETY"}}), "m");
        assert_eq!(blocked["stop_reason"], "content_filter");
        assert_eq!(blocked["content"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn the_model_listing_keeps_what_generates_content() {
        let data = json!({"models": [
            {"name": "models/model-b", "displayName": "Model B",
             "supportedGenerationMethods": ["generateContent"],
             "inputTokenLimit": 1000000, "outputTokenLimit": 65536},
            {"name": "models/embedding-1", "displayName": "Embedding",
             "supportedGenerationMethods": ["embedContent"]},
            {"name": "models/model-a", "supportedGenerationMethods": ["generateContent", "countTokens"]}
        ]});
        let models = normalize_models(&data);
        let models = models["models"].as_array().unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0]["id"], "model-a");
        assert_eq!(models[0]["name"], "model-a");
        assert_eq!(models[1]["id"], "model-b");
        assert_eq!(models[1]["context_window"], 1000000);
        assert_eq!(models[1]["max_output_tokens"], 65536);
    }
}
