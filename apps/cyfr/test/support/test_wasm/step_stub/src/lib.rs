// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// step-stub: a `model/chat@1` catalyst that answers at once. `describe`
// answers its capabilities (and a window for any named model); `chat` reads
// its key through `cyfr:vault/read`, emits a few `text.delta` events, `usage`
// and `stop` through `cyfr:emit/events`, and answers one text block. Nothing
// is dialled. See ../README.md for the rebuild procedure.

#[allow(warnings)]
mod bindings;

use bindings::cyfr::emit::events;
use bindings::cyfr::vault::read;
use bindings::exports::cyfr::catalyst::run::Guest;

use serde_json::{json, Value};

const CONTRACT: &str = "model/chat@1";
const KEY_FIELD: &str = "STUB_API_KEY";
const CONTEXT_WINDOW: u64 = 1_000_000;
const DELTAS: [&str; 4] = ["The stub ", "answers ", "at ", "once."];

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        let parsed: Value = serde_json::from_str(&input).unwrap_or(Value::Null);
        let params = parsed.get("params").cloned().unwrap_or(json!({}));

        match parsed.get("operation").and_then(Value::as_str) {
            Some("describe") => describe(&params),
            Some("chat") => chat(),
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

fn chat() -> String {
    if let Err(e) = read::get(KEY_FIELD) {
        return refuse(500, "secret_denied", &format!("Failed to read {KEY_FIELD}: {e}"));
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
