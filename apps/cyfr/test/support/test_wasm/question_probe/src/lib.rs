// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// question-probe: a catalyst that asks its person before each statement it
// is handed (`cyfr:question/ask`), and runs a statement only when the
// answer is `allowed`. Its manifest declares the actions it asks about
// under `asks`; which action a statement is, and the words the person
// reads, are this component's own. It reads a statement only when it is
// exactly one of two shapes, each one action, and declines anything else
// without asking. It does nothing outside itself: a statement allowed is
// counted as done. CYFR's tests run it, and the component guide shows it
// as the worked example of asking.

#[allow(warnings)]
mod bindings;

use bindings::cyfr::question::ask::{ask, Answer, Request, Unanswered};
use bindings::exports::cyfr::catalyst::run::Guest;

use serde_json::{json, Value};

struct Component;

impl Guest for Component {
    // Input: {"operation": "run", "params": {"statements": ["DROP TABLE users", …]}}.
    // Each statement is read, asked about on its own and run, in order.
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

// One statement the probe can tell the action of, and nothing else.
enum Statement<'a> {
    // `DROP TABLE <table>`
    DropTable { table: &'a str },
    // `DELETE FROM <table> WHERE id = <id>`
    DeleteRow { table: &'a str, id: &'a str },
}

// Ask before one statement, and run it only when it is allowed.
fn run_one(statement: &str) -> &'static str {
    // A statement of any other shape (two statements, a clause the probe
    // does not read, a word it does not know) could be an action it would
    // not ask about: it is declined, and nobody is asked.
    let Some(parsed) = parse(statement) else {
        return "declined";
    };

    let request = match parsed {
        Statement::DropTable { table } => Request {
            action: "delete_table".to_string(),
            summary: format!("Drop the table {table}"),
            operation: statement.to_string(),
        },
        Statement::DeleteRow { table, id } => Request {
            action: "delete_rows".to_string(),
            summary: format!("Delete the row {id} from the table {table}"),
            operation: statement.to_string(),
        },
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

// The statement when it is exactly one of the two shapes, its words
// separated by single spaces: anything more, less or else is none.
fn parse(statement: &str) -> Option<Statement<'_>> {
    let words: Vec<&str> = statement.split(' ').collect();
    match words.as_slice() {
        ["DROP", "TABLE", table] if name(table) => Some(Statement::DropTable { table }),
        ["DELETE", "FROM", table, "WHERE", "id", "=", id] if name(table) && number(id) => {
            Some(Statement::DeleteRow { table, id })
        }
        _ => None,
    }
}

// A table's name: a lowercase letter, then lowercase letters, digits and
// underscores, at most 63 characters.
fn name(word: &str) -> bool {
    let mut chars = word.chars();
    matches!(chars.next(), Some('a'..='z'))
        && word.len() <= 63
        && chars.all(|c| matches!(c, 'a'..='z' | '0'..='9' | '_'))
}

// A row's id: one to eighteen decimal digits.
fn number(word: &str) -> bool {
    (1..=18).contains(&word.len()) && word.bytes().all(|b| b.is_ascii_digit())
}
