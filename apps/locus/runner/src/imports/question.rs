// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! `cyfr:question/ask`: each `ask` takes the run's next ask number and is
//! the `question_ask` host call under it. The import loops itself, since
//! the call is asked again only on a lost answer: an ask past its root's
//! allowance waits as long as CYFR says and is sent again, the same
//! arguments signed afresh, and an open question is waited on in
//! `question_wait` calls until it is decided. A request past the host
//! call's bound is `none(invalid)`; anything else CYFR does not answer as
//! an answer, its `lost` among it, is `none(unavailable)`. The run's budget
//! ends the loop with the run.

use std::time::Duration;

use serde_json::Value;

use super::catalyst::cyfr::question::ask::{Answer, Request, Unanswered};
use super::{Guest, args, catalyst, ended};
use crate::host::{Outcome, Reading};

/// The longest a `question_wait` asks CYFR to hold its answer
/// (`Prima.HostAPI.max_question_wait_ms/0`).
pub const MAX_QUESTION_WAIT_MS: u64 = 20_000;

impl catalyst::cyfr::question::ask::Host for Guest {
    async fn ask(&mut self, request: Request) -> wasmtime::Result<Answer> {
        self.asks += 1;
        let ask_no = self.asks;
        let run = self.run.clone();
        let host = &run.host;
        loop {
            let outcome = host
                .call(
                    "question_ask",
                    args([
                        ("action", Value::String(request.action.clone())),
                        ("ask_no", Value::from(ask_no)),
                        ("operation", Value::String(request.operation.clone())),
                        ("summary", Value::String(request.summary.clone())),
                    ]),
                )
                .await;
            ended("question_ask", &outcome)?;
            let Outcome::Answered(Reading::Ok(asked)) = &outcome else {
                return Ok(unanswered(&outcome));
            };
            match asked.value() {
                Value::Object(asked) if asked.len() == 1 => {
                    if let Some(ms) = asked.get("retry_after_ms").and_then(Value::as_u64)
                        && ms > 0
                    {
                        tokio::time::sleep(Duration::from_millis(ms)).await;
                        continue;
                    }
                    if asked.get("pending") == Some(&Value::Bool(true)) {
                        return wait(host, ask_no).await;
                    }
                    if let Some(answer) = asked.get("answer").and_then(answer) {
                        return Ok(answer);
                    }
                    return Ok(Answer::None(Unanswered::Unavailable));
                }
                _ => return Ok(Answer::None(Unanswered::Unavailable)),
            }
        }
    }
}

async fn wait(host: &crate::attempt::Host, ask_no: u64) -> wasmtime::Result<Answer> {
    loop {
        let outcome = host
            .call(
                "question_wait",
                args([
                    ("ask_no", Value::from(ask_no)),
                    ("max_wait_ms", Value::from(MAX_QUESTION_WAIT_MS)),
                ]),
            )
            .await;
        ended("question_wait", &outcome)?;
        let Outcome::Answered(Reading::Ok(waited)) = &outcome else {
            return Ok(unanswered(&outcome));
        };
        match waited.value() {
            Value::Object(waited) if waited.len() == 1 => {
                if waited.get("pending") == Some(&Value::Bool(true)) {
                    continue;
                }
                return Ok(waited
                    .get("answer")
                    .and_then(answer)
                    .unwrap_or(Answer::None(Unanswered::Unavailable)));
            }
            _ => return Ok(Answer::None(Unanswered::Unavailable)),
        }
    }
}

/// An answer as it crosses (`Prima.HostAPI.answer_from_wire/1`).
fn answer(wire: &Value) -> Option<Answer> {
    match wire {
        Value::String(word) if word == "allowed" => Some(Answer::Allowed),
        Value::String(word) if word == "denied" => Some(Answer::Denied),
        Value::Object(none) if none.len() == 1 => match none.get("none")?.as_str()? {
            "unattended" => Some(Answer::None(Unanswered::Unattended)),
            "invalid" => Some(Answer::None(Unanswered::Invalid)),
            "unavailable" => Some(Answer::None(Unanswered::Unavailable)),
            _ => None,
        },
        _ => None,
    }
}

fn unanswered(outcome: &Outcome) -> Answer {
    match outcome {
        Outcome::TooLarge => Answer::None(Unanswered::Invalid),
        _ => Answer::None(Unanswered::Unavailable),
    }
}
