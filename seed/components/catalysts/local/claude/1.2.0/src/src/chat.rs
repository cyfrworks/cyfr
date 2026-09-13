//! The `model/chat@1` contract on Anthropic's Messages API.
//!
//! Three operations share the catalyst envelope: `chat` takes a contract
//! request and answers a contract response, `describe` answers what this
//! catalyst can do, and `models` lists what the key can reach. The
//! request and response shapes are the contract's; the provider's are
//! built and read here and never leave this module.

use serde_json::{json, Value};

use crate::bindings::cyfr::http::fetch;
use crate::{API_VERSION, BASE_URL};

const PROVIDER: &str = "anthropic";
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

pub fn describe() -> String {
    ok(json!({
        "contracts": [CONTRACT],
        "provider": PROVIDER,
        "tools": true,
        "provider_tools": PROVIDER_TOOLS,
        "media_types": MEDIA_TYPES,
        "streaming": false,
        "defaults": {"max_tokens": DEFAULT_MAX_TOKENS}
    }))
}

/// The model listing as the contract's `{"models": [{id, name, ...}]}`,
/// sorted by id.
fn listing(mut models: Vec<Value>) -> Value {
    models.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    json!({"models": models})
}

// ---------------------------------------------------------------------------
// chat
// ---------------------------------------------------------------------------

fn headers(api_key: &str) -> Value {
    json!({
        "x-api-key": api_key,
        "anthropic-version": API_VERSION,
        "Content-Type": "application/json"
    })
}

pub fn chat(api_key: &str, request: &Request) -> String {
    let req = json!({
        "method": "POST",
        "url": format!("{BASE_URL}/v1/messages"),
        "headers": headers(api_key),
        "body": build_body(request).to_string()
    });

    match provider_body(&fetch::request(&req.to_string())) {
        Ok(data) => ok(normalize(&data, &request.model)),
        Err(envelope) => envelope,
    }
}

/// The Messages API body for a contract request.
pub fn build_body(request: &Request) -> Value {
    let mut body = json!({
        "model": request.model,
        "max_tokens": request.max_tokens.unwrap_or(DEFAULT_MAX_TOKENS),
        "messages": request.messages.iter().map(to_message).collect::<Vec<_>>(),
    });

    // The system block carries the cache mark: tools precede it in the
    // cached prefix, so one mark caches both on every later turn.
    if let Some(system) = &request.system {
        body["system"] = json!([{
            "type": "text",
            "text": system,
            "cache_control": {"type": "ephemeral"}
        }]);
    }

    let mut tools: Vec<Value> = request
        .tools
        .iter()
        .map(|t| {
            json!({
                "name": t.name,
                "description": t.description,
                "input_schema": t.parameters
            })
        })
        .collect();
    if request.provider_tools.iter().any(|t| t == "web_search") {
        tools.push(json!({"type": "web_search_20250305", "name": "web_search"}));
    }
    if !tools.is_empty() {
        body["tools"] = json!(tools);
    }

    if let Some(temperature) = request.temperature {
        body["temperature"] = json!(temperature);
    }

    body
}

fn to_message(message: &Message) -> Value {
    let blocks: Vec<Value> = message
        .content
        .iter()
        .filter_map(|block| match block {
            // The API refuses an empty text block; an empty turn is the
            // tool calls beside it.
            Block::Text(text) if text.is_empty() => None,
            Block::Text(text) => Some(json!({"type": "text", "text": text})),
            Block::Image { media_type, data } => Some(json!({
                "type": "image",
                "source": {"type": "base64", "media_type": media_type, "data": data}
            })),
            Block::Document {
                media_type, data, ..
            } => Some(json!({
                "type": "document",
                "source": {"type": "base64", "media_type": media_type, "data": data}
            })),
            Block::ToolCall {
                id,
                name,
                arguments,
                ..
            } => Some(json!({"type": "tool_use", "id": id, "name": name, "input": arguments})),
            Block::ToolResult {
                tool_call_id,
                content,
                is_error,
                ..
            } => {
                let mut result = json!({
                    "type": "tool_result",
                    "tool_use_id": tool_call_id,
                    "content": content
                });
                if *is_error {
                    result["is_error"] = json!(true);
                }
                Some(result)
            }
        })
        .collect();

    let role = match message.role {
        Role::Assistant => "assistant",
        // Tool results are a user turn on this API.
        Role::User | Role::Tool => "user",
    };

    json!({"role": role, "content": blocks})
}

/// A Messages API response as the contract response.
pub fn normalize(data: &Value, requested_model: &str) -> Value {
    let mut content: Vec<Value> = Vec::new();
    let mut tool_calls = 0;

    for block in data
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        match block.get("type").and_then(Value::as_str) {
            Some("text") => {
                if let Some(text) = block.get("text").and_then(Value::as_str) {
                    content.push(json!({"type": "text", "text": text}));
                }
            }
            Some("tool_use") => {
                tool_calls += 1;
                content.push(json!({
                    "type": "tool_call",
                    "id": block.get("id").and_then(Value::as_str).unwrap_or(""),
                    "name": block.get("name").and_then(Value::as_str).unwrap_or(""),
                    "arguments": block.get("input").cloned().unwrap_or(json!({}))
                }));
            }
            // Server-side tool blocks and thinking are the provider's own
            // working; the answer is the text and calls beside them.
            _ => {}
        }
    }

    let stop_reason = match data.get("stop_reason").and_then(Value::as_str) {
        Some("tool_use") => "tool_call",
        Some("end_turn") | Some("stop_sequence") if tool_calls > 0 => "tool_call",
        Some("end_turn") | Some("stop_sequence") => "end_turn",
        Some("max_tokens") => "max_tokens",
        Some("refusal") => "content_filter",
        _ => "other",
    };

    let usage = data.get("usage").cloned().unwrap_or(json!({}));
    let count = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    let cache_read = count("cache_read_input_tokens");
    let cache_write = count("cache_creation_input_tokens");

    json!({
        "model": data.get("model").and_then(Value::as_str).unwrap_or(requested_model),
        "content": content,
        "stop_reason": stop_reason,
        "usage": {
            "input_tokens": count("input_tokens") + cache_read + cache_write,
            "output_tokens": count("output_tokens"),
            "cache_read_tokens": cache_read,
            "cache_write_tokens": cache_write
        }
    })
}

// ---------------------------------------------------------------------------
// models
// ---------------------------------------------------------------------------

pub fn models(api_key: &str) -> String {
    let req = json!({
        "method": "GET",
        "url": format!("{BASE_URL}/v1/models?limit=1000"),
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
                Some(json!({
                    "id": id,
                    "name": m.get("display_name").and_then(Value::as_str).unwrap_or(id)
                }))
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
    fn describe_names_the_contract() {
        let described: Value = serde_json::from_str(&describe()).unwrap();
        assert_eq!(described["status"], 200);
        assert_eq!(described["data"]["contracts"][0], CONTRACT);
        assert_eq!(described["data"]["provider"], PROVIDER);
        assert_eq!(described["data"]["streaming"], false);
        assert_eq!(described["data"]["provider_tools"], json!(PROVIDER_TOOLS));
    }
    #[test]
    fn a_contract_request_becomes_a_messages_api_body() {
        let req = parse_request(&contract_request(json!({}))).unwrap();
        let body = build_body(&req);

        assert_eq!(body["model"], "model-x");
        assert_eq!(body["max_tokens"], 512);
        assert_eq!(body["temperature"], 0.2);
        assert_eq!(body["system"][0]["text"], "Be brief.");
        assert_eq!(body["system"][0]["cache_control"]["type"], "ephemeral");

        let messages = body["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 4);
        assert_eq!(messages[0]["role"], "user");
        assert_eq!(messages[0]["content"][0]["text"], "hi");
        // The empty text block is dropped; the call rides alone.
        assert_eq!(messages[1]["content"].as_array().unwrap().len(), 1);
        assert_eq!(messages[1]["content"][0]["type"], "tool_use");
        assert_eq!(messages[1]["content"][0]["input"]["path"], "a.txt");
        assert_eq!(messages[2]["role"], "user");
        assert_eq!(messages[2]["content"][0]["type"], "tool_result");
        assert_eq!(messages[2]["content"][0]["tool_use_id"], "call_1");
        assert!(messages[2]["content"][0].get("is_error").is_none());
        assert_eq!(messages[3]["content"][1]["source"]["media_type"], "image/png");
        assert_eq!(messages[3]["content"][2]["type"], "document");

        let tools = body["tools"].as_array().unwrap();
        assert_eq!(tools[0]["name"], "files.read");
        assert_eq!(tools[0]["input_schema"]["type"], "object");
        assert_eq!(tools[1]["type"], "web_search_20250305");
    }

    #[test]
    fn the_defaults_fill_what_the_request_leaves_out() {
        let req = parse_request(&json!({
            "model": "m",
            "messages": [{"role": "user", "content": "hi"}]
        }))
        .unwrap();
        let body = build_body(&req);
        assert_eq!(body["max_tokens"], DEFAULT_MAX_TOKENS);
        assert!(body.get("system").is_none());
        assert!(body.get("tools").is_none());
        assert!(body.get("temperature").is_none());
    }

    #[test]
    fn a_messages_api_response_becomes_a_contract_response() {
        let data = json!({
            "model": "model-x-20260301",
            "stop_reason": "tool_use",
            "content": [
                {"type": "text", "text": "Let me look."},
                {"type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": {}},
                {"type": "tool_use", "id": "toolu_2", "name": "files.read", "input": {"path": "b"}}
            ],
            "usage": {"input_tokens": 10, "output_tokens": 5,
                      "cache_read_input_tokens": 100, "cache_creation_input_tokens": 20}
        });

        let response = normalize(&data, "model-x");
        assert_eq!(response["model"], "model-x-20260301");
        assert_eq!(response["stop_reason"], "tool_call");
        let content = response["content"].as_array().unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(content[0]["text"], "Let me look.");
        assert_eq!(content[1]["type"], "tool_call");
        assert_eq!(content[1]["id"], "toolu_2");
        assert_eq!(content[1]["arguments"]["path"], "b");
        assert_eq!(response["usage"]["input_tokens"], 130);
        assert_eq!(response["usage"]["output_tokens"], 5);
        assert_eq!(response["usage"]["cache_read_tokens"], 100);
        assert_eq!(response["usage"]["cache_write_tokens"], 20);

        let ended = normalize(&json!({"stop_reason": "end_turn", "content": [{"type": "text", "text": "done"}]}), "m");
        assert_eq!(ended["stop_reason"], "end_turn");
        assert_eq!(ended["model"], "m");
        assert_eq!(ended["usage"]["input_tokens"], 0);

        let cut = normalize(&json!({"stop_reason": "max_tokens", "content": []}), "m");
        assert_eq!(cut["stop_reason"], "max_tokens");
        let refused = normalize(&json!({"stop_reason": "refusal", "content": []}), "m");
        assert_eq!(refused["stop_reason"], "content_filter");
    }

    #[test]
    fn the_model_listing_is_normalized_and_sorted() {
        let data = json!({"data": [
            {"id": "model-b", "display_name": "Model B"},
            {"id": "model-a", "display_name": "Model A"},
            {"type": "model"}
        ], "has_more": false});
        let models = normalize_models(&data);
        let models = models["models"].as_array().unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0]["id"], "model-a");
        assert_eq!(models[1]["name"], "Model B");
    }
}
