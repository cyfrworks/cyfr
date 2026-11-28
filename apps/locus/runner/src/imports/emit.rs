// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! `cyfr:emit/events`: each event is one `push_deltas` host call, and CYFR
//! checks, masks, numbers and pushes it on the stream the attempt was
//! opened on, answering the JSON the guest's `emit` returns. An event past
//! the node's `max_request_size` is refused here as a `resource_limit`,
//! before it crosses the wire that would refuse its body; a call CYFR does
//! not answer is a `dispatch_error`. A formula's invoke `emit` is the same
//! call (`emit`).

use serde_json::Value;

use super::formula::Kind;
use super::{Guest, Run, args, catalyst, ended, error_json};
use crate::host::{Outcome, Reading};

impl catalyst::cyfr::emit::events::Host for Guest {
    async fn emit(&mut self, event: String) -> wasmtime::Result<String> {
        emit(&self.run, event).await
    }
}

/// Push `event` for the run `run`, as a catalyst's `emit` and a formula's
/// invoke `emit` do alike.
pub async fn emit(run: &Run, event: String) -> wasmtime::Result<String> {
    if event.len() as u64 > run.limits.max_request_size {
        return Ok(error_json(
            Kind::ResourceLimit.name(),
            "Event exceeds the consented max_request_size for this component.",
        ));
    }
    let host = &run.host;
    let delta = serde_json::json!({
        "attempt": host.attempt(),
        "event": event,
        "execution_id": host.execution_id(),
        "fence": host.fence(),
    });
    let outcome = host
        .call("push_deltas", args([("deltas", Value::Array(vec![delta]))]))
        .await;
    ended("push_deltas", &outcome)?;
    if let Outcome::Answered(Reading::Ok(replies)) = &outcome
        && let Value::Array(replies) = replies.value()
        && let [Value::String(reply)] = replies.as_slice()
    {
        return Ok(reply.clone());
    }
    host.note("an unanswered emit", || {
        format!("{}'s emit was not answered", host.execution_id())
    });
    Ok(error_json(
        Kind::DispatchError.name(),
        "The emit call failed.",
    ))
}
