// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// nested-probe: a minimal formula fixture that drives the cyfr:formula/invoke
// host interface on command. Input selects the operation; every raw host
// response is echoed back verbatim so tests can characterize exactly what the
// host did. See ../README.md for the rebuild procedure.

#[allow(warnings)]
mod bindings;

use bindings::cyfr::formula::invoke;
use bindings::exports::cyfr::formula::run::Guest;

use serde_json::{json, Value};

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        match handle(&input) {
            Ok(v) => v.to_string(),
            Err(e) => json!({ "probe_error": e }).to_string(),
        }
    }
}

bindings::export!(Component with_types_in bindings);

// Must match the ref the test helper publishes the probe under.
const SELF_REF: &str = "formula:local.nested-probe:0.1.0";

fn handle(input: &str) -> Result<Value, String> {
    let parsed: Value = if input.is_empty() {
        json!({})
    } else {
        serde_json::from_str(input).map_err(|e| format!("invalid input: {e}"))?
    };

    let op = parsed.get("op").and_then(|v| v.as_str()).unwrap_or("echo");

    match op {
        // No host calls at all: proves the component executes end to end.
        "echo" => Ok(json!({ "op": "echo", "input": parsed })),

        // One synchronous dispatch of an arbitrary tool.action request.
        "call" => {
            let request = parsed.get("request").ok_or("missing request")?;
            let raw = invoke::call(&request.to_string());
            Ok(json!({ "op": "call", "result_raw": raw }))
        }

        // Spawn one request, then await it.
        "spawn_await" => {
            let request = parsed.get("request").ok_or("missing request")?;
            let task_id = spawn_one(request)?;
            let raw = invoke::await_(&task_id);
            Ok(json!({ "op": "spawn_await", "task_id": task_id, "result_raw": raw }))
        }

        // Spawn several requests, then await-all.
        "spawn_await_all" => {
            let requests = parsed
                .get("requests")
                .and_then(|v| v.as_array())
                .ok_or("missing requests")?;

            let mut task_ids: Vec<String> = Vec::new();
            for request in requests {
                task_ids.push(spawn_one(request)?);
            }

            let raw = invoke::await_all(&json!({ "task_ids": task_ids }).to_string());
            Ok(json!({ "op": "spawn_await_all", "task_ids": task_ids, "result_raw": raw }))
        }

        // Emit an intermediate event.
        "emit" => {
            let payload = parsed
                .get("payload")
                .cloned()
                .unwrap_or_else(|| json!({ "probe": true }));
            let raw = invoke::emit(&payload.to_string());
            Ok(json!({ "op": "emit", "emit_raw": raw }))
        }

        // Self-invoke through execution.run until depth 0, then run the
        // optional leaf request — a real N-deep nested execution.
        "chain" => {
            let depth = parsed.get("depth").and_then(|v| v.as_u64()).unwrap_or(0);
            let leaf = parsed.get("leaf").cloned().unwrap_or(Value::Null);

            if depth == 0 {
                match &leaf {
                    Value::Null => Ok(json!({ "op": "chain", "depth": 0 })),
                    request => {
                        let raw = invoke::call(&request.to_string());
                        Ok(json!({ "op": "chain", "depth": 0, "result_raw": raw }))
                    }
                }
            } else {
                let child_input = json!({ "op": "chain", "depth": depth - 1, "leaf": leaf });
                let request = json!({
                    "tool": "execution",
                    "action": "run",
                    "args": { "reference": SELF_REF, "input": child_input, "type": "formula" }
                });
                let raw = invoke::call(&request.to_string());
                Ok(json!({ "op": "chain", "depth": depth, "result_raw": raw }))
            }
        }

        other => Err(format!("unknown op: {other}")),
    }
}

fn spawn_one(request: &Value) -> Result<String, String> {
    let raw = invoke::spawn(&request.to_string());
    let parsed: Value =
        serde_json::from_str(&raw).map_err(|e| format!("unparseable spawn response: {e}"))?;

    parsed
        .get("task_id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or(format!("spawn failed: {raw}"))
}
