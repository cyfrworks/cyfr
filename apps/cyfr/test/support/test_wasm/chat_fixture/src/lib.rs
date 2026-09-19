// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// chat-fixture: a `model/chat@1` catalyst whose `chat` plays the script its
// request carries and answers what it was given. It decides nothing: the
// events, the answer, a refusal, a trap and a wait are all the script's.
// Nothing is dialled. See ../README.md for the script and the rebuild.

#[allow(warnings)]
mod bindings;

use bindings::cyfr::emit::events;
use bindings::cyfr::vault::read;
use bindings::exports::cyfr::catalyst::run::Guest;

use serde_json::{json, Map, Value};

const CONTRACT: &str = "model/chat@1";
const KEY_FIELD: &str = "FIXTURE_API_KEY";
const CONTEXT_WINDOW: u64 = 1_000_000;
const MAX_OUTPUT_TOKENS: u64 = 4096;
const FENCE_OPEN: &str = "```chat-fixture";
const FENCE_CLOSE: &str = "```";
const KEY_OPEN: &str = "{{key";
const KEY_CLOSE: &str = "}}";

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        let parsed: Value = serde_json::from_str(&input).unwrap_or(Value::Null);
        let params = parsed.get("params").cloned().unwrap_or(json!({}));

        match parsed.get("operation").and_then(Value::as_str) {
            Some("describe") => describe(&params),
            Some("chat") => chat(params),
            Some("models") => ok(json!({"models": [{"id": "chat-fixture", "name": "Chat fixture"}]})),
            _ => refuse(400, "unknown_operation", "the fixture answers describe, models and chat"),
        }
    }
}

bindings::export!(Component with_types_in bindings);

fn describe(params: &Value) -> String {
    let mut data = json!({
        "contracts": [CONTRACT],
        "provider": "chat-fixture",
        "tools": true,
        "provider_tools": [],
        "media_types": [],
        "streaming": true,
        "defaults": {"max_tokens": 1024}
    });

    if let Some(model) = params.get("model").and_then(Value::as_str) {
        data["model"] = json!(model);
        data["context_window"] = json!(CONTEXT_WINDOW);
        data["max_output_tokens"] = json!(MAX_OUTPUT_TOKENS);
    }

    ok(data)
}

fn chat(params: Value) -> String {
    let key = match read::get(KEY_FIELD) {
        Ok(key) => key,
        Err(e) => return refuse(500, "secret_denied", &format!("Failed to read {KEY_FIELD}: {e}")),
    };

    let (index, step) = match step(&params) {
        Ok(found) => found,
        Err(message) => return refuse(400, "invalid_request", &message),
    };

    let mut emitted = Vec::new();

    for item in step.get("emit").and_then(Value::as_array).cloned().unwrap_or_default() {
        emitted.push(play(&item, &key));
    }

    if let Some(ms) = step.get("sleep_ms").and_then(Value::as_u64) {
        std::thread::sleep(std::time::Duration::from_millis(ms));
    }

    if step.get("then").and_then(Value::as_str) == Some("trap") {
        core::arch::wasm32::unreachable();
    }

    if let Some(refusal) = step.get("refuse") {
        return expand(refusal, &key).to_string();
    }

    let mut data = match expand(step.get("answer").unwrap_or(&Value::Null), &key) {
        Value::Object(data) => data,
        _ => Map::new(),
    };

    data.insert(
        "fixture".to_string(),
        json!({"step": index, "received": params, "emitted": emitted}),
    );

    ok(Value::Object(data))
}

// The step this call plays: the script is the fenced block of the last user
// message that carries one, and the step is chosen by how many assistant
// messages follow that message, so every `chat` of a turn plays the next
// step with nothing kept between calls. A request with no script plays the
// greeting.
fn step(params: &Value) -> Result<(usize, Value), String> {
    let messages = params.get("messages").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut found: Option<(usize, String)> = None;

    for (at, message) in messages.iter().enumerate() {
        if message.get("role").and_then(Value::as_str) == Some("user") {
            if let Some(script) = fenced(&text_of(message.get("content"))) {
                found = Some((at, script));
            }
        }
    }

    let Some((at, script)) = found else {
        return Ok((0, greeting()));
    };

    let script: Value =
        serde_json::from_str(&script).map_err(|e| format!("the script is not JSON: {e}"))?;

    let index = messages[at + 1..]
        .iter()
        .filter(|m| m.get("role").and_then(Value::as_str) == Some("assistant"))
        .count();

    script
        .get("steps")
        .and_then(Value::as_array)
        .and_then(|steps| steps.get(index))
        .cloned()
        .map(|step| (index, step))
        .ok_or_else(|| format!("the script has no step {index}"))
}

fn greeting() -> Value {
    let usage = json!({"input_tokens": 1, "output_tokens": 2});

    json!({
        "emit": [
            {"type": "text.delta", "text": "The fixture "},
            {"type": "text.delta", "text": "answers."},
            {"type": "usage", "usage": usage},
            {"type": "stop", "stop_reason": "end_turn"}
        ],
        "answer": {
            "model": "chat-fixture",
            "content": [{"type": "text", "text": "The fixture answers."}],
            "stop_reason": "end_turn",
            "usage": usage
        }
    })
}

fn text_of(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn fenced(text: &str) -> Option<String> {
    let open = text.find(FENCE_OPEN)? + FENCE_OPEN.len();
    let close = text[open..].find(FENCE_CLOSE)? + open;
    Some(text[open..close].to_string())
}

// One item of a step's `emit`: an event, emitted as it stands and reported
// with the host's reply; or `{"$repeat": n, "event": {...}}`, the event
// emitted n times and reported as counts with the first refusal.
fn play(item: &Value, key: &str) -> Value {
    let Some(times) = item.get("$repeat").and_then(Value::as_u64) else {
        return emit(&expand(item, key));
    };

    let event = expand(item.get("event").unwrap_or(&Value::Null), key);
    let (mut accepted, mut refused, mut first_refusal) = (0u64, 0u64, Value::Null);

    for _ in 0..times {
        let reply = emit(&event);

        if reply.get("error").is_some() {
            refused += 1;
            if first_refusal.is_null() {
                first_refusal = reply;
            }
        } else {
            accepted += 1;
        }
    }

    json!({"repeat": times, "accepted": accepted, "refused": refused, "first_refusal": first_refusal})
}

fn emit(event: &Value) -> Value {
    let reply = events::emit(&event.to_string());
    serde_json::from_str(&reply).unwrap_or(Value::String(reply))
}

// A script value as it is played: `{{key}}` in a string is the bound key and
// `{{key:a:b}}` its bytes a..b (either bound may be left out), so a script
// names the key without holding it; `{"$fill": text, "bytes": n}` is `text`
// repeated to n bytes.
fn expand(value: &Value, key: &str) -> Value {
    match value {
        Value::String(text) => Value::String(expand_text(text, key)),
        Value::Array(items) => Value::Array(items.iter().map(|v| expand(v, key)).collect()),
        Value::Object(fields) => match (fields.get("$fill"), fields.get("bytes")) {
            (Some(Value::String(text)), Some(Value::Number(bytes))) if !text.is_empty() => {
                let bytes = bytes.as_u64().unwrap_or(0) as usize;
                let mut filled = text.repeat(bytes / text.len() + 1);
                let mut cut = bytes.min(filled.len());

                while !filled.is_char_boundary(cut) {
                    cut -= 1;
                }

                filled.truncate(cut);
                Value::String(filled)
            }
            _ => Value::Object(fields.iter().map(|(k, v)| (k.clone(), expand(v, key))).collect()),
        },
        other => other.clone(),
    }
}

fn expand_text(text: &str, key: &str) -> String {
    let mut out = String::new();
    let mut rest = text;

    while let Some(start) = rest.find(KEY_OPEN) {
        let after = &rest[start + KEY_OPEN.len()..];

        let Some(end) = after.find(KEY_CLOSE) else { break };
        out.push_str(&rest[..start]);
        out.push_str(slice(key, &after[..end]));
        rest = &after[end + KEY_CLOSE.len()..];
    }

    out.push_str(rest);
    out
}

fn slice<'a>(key: &'a str, range: &str) -> &'a str {
    let mut bounds = range.split(':').skip(1).map(|bound| bound.parse::<usize>().ok());
    let from = bounds.next().flatten().unwrap_or(0).min(key.len());
    let to = bounds.next().flatten().unwrap_or(key.len()).min(key.len());
    key.get(from..to).unwrap_or("")
}

fn ok(data: Value) -> String {
    json!({"status": 200, "data": data}).to_string()
}

fn refuse(status: i64, kind: &str, message: &str) -> String {
    json!({"status": status, "error": {"type": kind, "message": message}}).to_string()
}
