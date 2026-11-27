// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! `cyfr:emit/events`: each event is one `push_deltas` host call, and CYFR
//! checks, masks, numbers and pushes it on the stream the attempt was
//! opened on, answering the JSON the guest's `emit` returns. An event past
//! the node's `max_request_size` is refused here as a `resource_limit`,
//! before it crosses the wire that would refuse its body; a call CYFR does
//! not answer is a `dispatch_error`.

use serde_json::Value;

use super::{Guest, args, catalyst, ended, error_json};
use crate::host::{Outcome, Reading};

impl catalyst::cyfr::emit::events::Host for Guest {
    async fn emit(&mut self, event: String) -> wasmtime::Result<String> {
        let run = self.run.clone();
        if event.len() as u64 > run.limits.max_request_size {
            return Ok(error_json(
                "resource_limit",
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
        Ok(error_json("dispatch_error", "The emit call failed."))
    }
}
