// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// step-stub: a `model/chat@1` catalyst that answers at once. `describe`
// answers its capabilities (and a window for any named model); `chat` emits
// a few `text.delta` events, `usage` and `stop` through `cyfr:emit/events`,
// and answers one text block. It reads no credential. A `chat` whose last
// user message's text is a JSON object naming `bench_fetch`, whole or after
// a display name, first makes that one request through `cyfr:http/fetch`,
// before its first delta, and refuses unless it is answered 200; any other
// `chat` dials nothing.
// See ../README.md for the rebuild procedure.

#[allow(warnings)]
mod bindings;

use bindings::cyfr::emit::events;
use bindings::cyfr::http::fetch;
use bindings::exports::cyfr::catalyst::run::Guest;

use serde_json::{json, Value};

const CONTRACT: &str = "model/chat@1";
const CONTEXT_WINDOW: u64 = 1_000_000;
const DELTAS: [&str; 4] = ["The stub ", "answers ", "at ", "once."];

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        let parsed: Value = serde_json::from_str(&input).unwrap_or(Value::Null);
        let params = parsed.get("params").cloned().unwrap_or(json!({}));

        match parsed.get("operation").and_then(Value::as_str) {
            Some("describe") => describe(&params),
            Some("chat") => chat(&params),
            Some("models") => ok(json!({"models": [{"id": "step-stub"}]})),
            _ => refuse(400, "invalid_request", "the stub answers describe, models and chat"),
        }
    }
}

bindings::export!(Component with_types_in bindings);

fn describe(params: &Value) -> String {
    let mut data = json!({
        "contracts": [CONTRACT],
        "provider": "step-stub",
        "tools": true,
        "provider_tools": [],
        "media_types": [],
        "streaming": true,
        "defaults": {"max_tokens": 1024}
    });

    if let Some(model) = params.get("model").and_then(Value::as_str) {
        data["model"] = json!(model);
        data["context_window"] = json!(CONTEXT_WINDOW);
        data["max_output_tokens"] = json!(1024);
    }

    ok(data)
}

fn chat(params: &Value) -> String {
    if let Some(request) = bench_fetch(params) {
        if let Err(refusal) = fetched(&request) {
            return refusal;
        }
    }

    for text in DELTAS {
        emit(json!({"type": "text.delta", "text": text}));
    }

    let usage = json!({"input_tokens": 1, "output_tokens": DELTAS.len()});
    emit(json!({"type": "usage", "usage": usage}));
    emit(json!({"type": "stop", "stop_reason": "end_turn"}));

    ok(json!({
        "content": [{"type": "text", "text": DELTAS.concat()}],
        "stop_reason": "end_turn",
        "usage": usage
    }))
}

// The bench's request: `bench_fetch` of the last user message, when that
// message's text is a JSON object naming it, either whole or after the
// display name and ": " the turn loop writes before a line where several
// people talk (split at the first ": ", since a display name holds none).
// A person's words, or a chat with no messages, name none.
fn bench_fetch(params: &Value) -> Option<Value> {
    let messages = params.get("messages").and_then(Value::as_array)?;
    let last = messages
        .iter()
        .rev()
        .find(|m| m.get("role").and_then(Value::as_str) == Some("user"))?;
    let text = text_of(last.get("content"));

    named_fetch(&text).or_else(|| text.split_once(": ").and_then(|(_name, line)| named_fetch(line)))
}

fn named_fetch(text: &str) -> Option<Value> {
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(fields)) => fields.get("bench_fetch").cloned(),
        _ => None,
    }
}

// Makes the request as it came; anything but a 200 answer is the chat's
// refusal, so a bench step never measures a fetch that did not happen.
fn fetched(request: &Value) -> Result<(), String> {
    let answer = fetch::request(&request.to_string());
    let answer: Value = serde_json::from_str(&answer).unwrap_or(Value::Null);

    match (answer.get("status").and_then(Value::as_i64), answer.get("error")) {
        (Some(200), None) => Ok(()),
        (_, Some(error)) => {
            let kind = error.get("type").and_then(Value::as_str).unwrap_or("http_error");
            let message = error.get("message").and_then(Value::as_str).unwrap_or("the request failed");
            Err(refuse(502, kind, message))
        }
        _ => Err(refuse(502, "http_error", "the bench request was not answered 200")),
    }
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

// A refused event is dropped: the answer still returns.
fn emit(event: Value) {
    let _ = events::emit(&event.to_string());
}

fn ok(data: Value) -> String {
    json!({"status": 200, "data": data}).to_string()
}

fn refuse(status: i64, kind: &str, message: &str) -> String {
    json!({"status": status, "error": {"type": kind, "message": message}}).to_string()
}
