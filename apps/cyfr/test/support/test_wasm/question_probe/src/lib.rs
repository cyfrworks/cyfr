// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// question-probe: a catalyst that asks its person before each operation it
// is handed (`cyfr:question/ask`), and does an operation only when the
// answer is `allowed`. Its manifest declares the actions it asks about
// under `asks`; which action an operation is, and the words the person
// reads, are this component's own. It does nothing outside itself: an
// operation allowed is counted as done. CYFR's tests run it, and the
// component guide shows it as the worked example of asking.

#[allow(warnings)]
mod bindings;

use bindings::cyfr::question::ask::{ask, Answer, Request, Unanswered};
use bindings::exports::cyfr::catalyst::run::Guest;

use serde_json::{json, Value};

struct Component;

impl Guest for Component {
    // Input: {"operation": "run", "params": {"statements": ["DROP TABLE users", …]}}.
    // Each statement is asked about on its own, in order, before it runs.
    fn run(input: String) -> String {
        let parsed: Value = serde_json::from_str(&input).unwrap_or(Value::Null);
        let statements = parsed
            .pointer("/params/statements")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();

        let mut results = Vec::new();
        for statement in statements.iter().filter_map(Value::as_str) {
            results.push(json!({"statement": statement, "answer": run_one(statement)}));
        }

        json!({"status": 200, "data": {"results": results}}).to_string()
    }
}

bindings::export!(Component with_types_in bindings);

// Ask before one statement, and run it only when it is allowed.
fn run_one(statement: &str) -> &'static str {
    let request = Request {
        action: action_of(statement).to_string(),
        summary: summary_of(statement),
        operation: statement.to_string(),
    };

    match ask(&request) {
        // Only here may the statement run. This probe touches nothing, so
        // running it is reporting that it was allowed.
        Answer::Allowed => "allowed",
        // Denied, by the person or by a permission of theirs: do nothing.
        Answer::Denied => "denied",
        // Nobody could be asked, the request or its action was wrong, or
        // CYFR could not ask just now: do nothing, and say why.
        Answer::None(Unanswered::Unattended) => "unattended",
        Answer::None(Unanswered::Invalid) => "invalid",
        Answer::None(Unanswered::Unavailable) => "unavailable",
    }
}

// Which declared action a statement is, read from the statement alone.
// A statement it cannot tell is asked under the harsher action.
fn action_of(statement: &str) -> &'static str {
    let upper = statement.trim_start().to_ascii_uppercase();
    if upper.starts_with("DELETE") {
        "delete_rows"
    } else if upper.starts_with("UNDECLARED") {
        // A name the manifest does not declare: CYFR answers invalid.
        "undeclared_action"
    } else {
        "delete_table"
    }
}

// One line naming the thing and where it is, as the person will read it.
fn summary_of(statement: &str) -> String {
    let words: Vec<&str> = statement.split_whitespace().collect();
    match words.as_slice() {
        [verb, kind, name, ..] if verb.eq_ignore_ascii_case("drop") => {
            format!("Drop the {} {}", kind.to_ascii_lowercase(), name.trim_end_matches(';'))
        }
        _ => {
            let line: String = statement.lines().next().unwrap_or("").chars().take(120).collect();
            format!("Run {line}")
        }
    }
}
