// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! `cyfr:storage/files`: a catalyst's storage operation, which CYFR runs
//! for the attempt (`Prima.HostAPI`'s `storage`). The import bounds the
//! request by the node's limits, reads it and asks CYFR; what the
//! operation may reach (actions, paths, scopes, sizes, quotas) is CYFR's
//! to decide, while the attempt still holds its row.
//!
//! A guest's request is `{"action": a, "path": p}` with `"content"`
//! (base64) for a write or append; `list` and `exists` without a path, or
//! with a null one, name the scope's listing (`""`). Success answers CYFR's members with
//! `"status": "ok"`. A refusal answers the error envelope: CYFR's own;
//! `request_too_large` past the envelope bound; `invalid_json`,
//! `invalid_request` or `unknown_action` for a request that does not read;
//! `storage_error` when the attempt no longer holds its row or CYFR's
//! store cannot answer; and `storage_uncertain` when CYFR may have run the
//! operation and its answer was lost, since a write may be at the path.
//! Every refusal but `storage_uncertain` wrote nothing. Each call is a
//! `storage.call` event.

use std::time::Instant;

use serde_json::{Map, Value};

use super::{Guest, catalyst, ended, error_json};
use crate::control::{Event, Meta};
use crate::host::{Outcome, Reading};
use crate::wire::{Unread, read};
use crate::words::{UNCERTAIN, request_too_deep};

/// The slack above twice the consented `max_request_size` a request's
/// envelope may take (`Locus.Runtime.EdgeGuard.envelope_overhead/0`).
pub const ENVELOPE_OVERHEAD: u64 = 4096;

const ACTIONS: [&str; 6] = ["read", "write", "append", "list", "delete", "exists"];

impl catalyst::cyfr::storage::files::Host for Guest {
    async fn call(&mut self, request: String) -> wasmtime::Result<String> {
        let run = self.run.clone();
        let started = Instant::now();
        let (action, answer, end) = match requested(&request, run.limits.max_request_size) {
            Ok((action, args)) => {
                let outcome = run.host.call("storage", args).await;
                match ended("storage", &outcome) {
                    // CYFR's answer nested too deep ends the run, once its
                    // call's event is sent, as an error.
                    Err(end) => (action, Err(not_current()), Some(end)),
                    Ok(()) => (action, stored(outcome), None),
                }
            }
            Err(refused) => ("unknown".to_owned(), Err(refused), None),
        };
        let status = if answer.is_ok() { "ok" } else { "error" };
        run.host
            .event(Event {
                name: "storage.call",
                measurements: vec![("duration_ms", elapsed_ms(started))],
                metadata: vec![
                    ("component_ref", Meta::text(&run.component_ref)),
                    ("action", Meta::text(&action)),
                    ("status", Meta::text(status)),
                ],
            })
            .await;
        if let Some(end) = end {
            return Err(end);
        }
        Ok(match answer {
            Ok(mut members) => {
                members.insert("status".to_owned(), Value::String("ok".to_owned()));
                Value::Object(members).to_string()
            }
            Err((kind, message)) => error_json(&kind, &message),
        })
    }
}

type Refusal = (String, String);

fn refusal(kind: &str, message: impl Into<String>) -> Refusal {
    (kind.to_owned(), message.into())
}

// The operation's name and the call's args, or the guest's refusal.
fn requested(
    request: &str,
    max_request_size: u64,
) -> Result<(String, Map<String, Value>), Refusal> {
    let envelope = max_request_size
        .saturating_mul(2)
        .saturating_add(ENVELOPE_OVERHEAD);
    if request.len() as u64 > envelope {
        return Err(refusal(
            "request_too_large",
            "Request exceeds the consented max_request_size for this component.",
        ));
    }
    let json = match read(request.as_bytes()) {
        Ok(json) => json,
        Err(Unread::TooDeep) => return Err(refusal("invalid_json", request_too_deep())),
        Err(Unread::Malformed) => return Err(refusal("invalid_json", "Invalid JSON request")),
    };
    let Some(Value::String(action)) = json.value().get("action") else {
        return Err(refusal(
            "invalid_request",
            "Request must include 'action' (string)",
        ));
    };
    if !ACTIONS.contains(&action.as_str()) {
        return Err(refusal(
            "unknown_action",
            format!(
                "Unknown storage action: {action}. Use: read, write, append, list, delete, or \
                 exists"
            ),
        ));
    }
    let path = match json.value().get("path") {
        Some(Value::String(path)) => path.clone(),
        // An omitted path and a null one alike name the scope's listing.
        None | Some(Value::Null) if matches!(action.as_str(), "list" | "exists") => String::new(),
        _ => {
            return Err(refusal(
                "invalid_request",
                format!("Request must include 'path' (string) for action '{action}'"),
            ));
        }
    };
    let mut args = Map::new();
    match json.value().get("content") {
        None | Some(Value::Null) => {}
        Some(Value::String(content)) => {
            args.insert("content".to_owned(), Value::String(content.clone()));
        }
        Some(_) => {
            return Err(refusal(
                "invalid_request",
                "'content' must be a base64 string.",
            ));
        }
    }
    args.insert("action".to_owned(), Value::String(action.clone()));
    args.insert("path".to_owned(), Value::String(path));
    Ok((action.clone(), args))
}

fn stored(outcome: Outcome) -> Result<Map<String, Value>, Refusal> {
    match outcome {
        Outcome::Answered(Reading::Ok(members)) => match members.value() {
            Value::Object(members) => Ok(members.clone()),
            _ => Err(not_current()),
        },
        Outcome::Answered(Reading::GuestError {
            kind,
            message,
            remediation: None,
        }) => Err(refusal(kind.as_str(), message.as_str())),
        Outcome::Answered(Reading::Refused("unavailable")) => Err(refusal(
            "storage_error",
            "Storage refused: the execution store is unavailable.",
        )),
        Outcome::Uncertain => Err(refusal(
            "storage_uncertain",
            format!("{UNCERTAIN} — read the path back before writing it again."),
        )),
        _ => Err(not_current()),
    }
}

fn not_current() -> Refusal {
    refusal(
        "storage_error",
        "Storage refused: the execution attempt is not current.",
    )
}

/// Milliseconds since `started`.
pub fn elapsed_ms(started: Instant) -> u64 {
    u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX)
}
