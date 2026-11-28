// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// formula-probe: a formula that makes the invoke calls its input lists, in
// order, and answers every answer as it came. It does nothing else: each
// step names one of the eight invoke functions and its argument, which is
// passed as it is when it is a string and as its JSON text otherwise, so a
// test can send a request that is no JSON. The runner crate's tests run it
// (apps/locus/runner/tests/formula.rs).

#[allow(warnings)]
mod bindings;

use bindings::cyfr::formula::invoke;
use bindings::exports::cyfr::formula::run::Guest;

use serde_json::{json, Value};

struct Component;

impl Guest for Component {
    // Input: {"steps": [{"fn": "call", "arg": {...}}, {"fn": "await", "arg": "task_1"}, ...]}.
    // Output: {"answers": [...]}, each answer its JSON value, or its text
    // when it is no JSON.
    fn run(input: String) -> String {
        let parsed: Value = serde_json::from_str(&input).unwrap_or(Value::Null);
        let steps = parsed
            .get("steps")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let answers: Vec<Value> = steps.iter().map(step).collect();
        json!({ "answers": answers }).to_string()
    }
}

bindings::export!(Component with_types_in bindings);

fn step(step: &Value) -> Value {
    let arg = match step.get("arg") {
        Some(Value::String(text)) => text.clone(),
        Some(value) => value.to_string(),
        None => String::new(),
    };
    let answer = match step.get("fn").and_then(Value::as_str).unwrap_or("") {
        "call" => invoke::call(&arg),
        "spawn" => invoke::spawn(&arg),
        "await" => invoke::await_(&arg),
        "await-all" => invoke::await_all(&arg),
        "await-any" => invoke::await_any(&arg),
        "poll" => invoke::poll(&arg),
        "cancel" => invoke::cancel(&arg),
        "emit" => invoke::emit(&arg),
        other => return json!({ "probe_error": format!("unknown fn: {other}") }),
    };
    serde_json::from_str(&answer).unwrap_or(Value::String(answer))
}
