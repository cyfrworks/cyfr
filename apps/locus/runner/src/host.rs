// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! A runner's host calls (`Prima.HostAPI`): each sealed and signed afresh
//! for each try under its attempt's keys, posted through the relay
//! (`Post`), and its answer opened and read as the call's.
//!
//! What a call makes of what reaches it (`tests/fixtures/host_api.json`'s
//! `answer_outcomes`): a try that meets no answer within the callback's
//! timeout, a `200` that does not open or is no answer at this version, or
//! any other status is lost, and is asked once more unless the callback's
//! class is `never`, when the call is uncertain at once, its effect
//! perhaps done; a second loss is lost. A `413` is final, too large: the
//! same body is refused again. A refusal naming `unknown_version`, plain at
//! any version or sealed, is a host at another version, final and lost.
//! CYFR's own answers, `lost` and `unavailable` among them, are never
//! asked again. A body past the host's bound is too large before it is
//! posted.

use std::future::Future;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use serde_json::{Map, Value};
use zeroize::Zeroizing;

use crate::auth::{AttemptKeys, CallFields, Direction, host_call_header, open_call, seal_call};
use crate::wire::{Answer, BASE64URL, read_answer, request_body};

/// The most bytes a host call's posted body spans: the host's bound.
pub const MAX_BODY_BYTES: usize = 1_048_576;

/// What a client may do when a callback's answer is lost.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Retry {
    /// Asked again freely: the same answer comes back.
    Idempotent,
    /// Asked again: a second close of the same outcome is the first's.
    Outcome,
    /// Asked again as the same batch.
    Batch,
    /// Asked again under the same key.
    Keyed,
    /// Never asked again: its effect may have happened.
    Never,
}

/// Each callback a runner makes, its retry class and the time an answer
/// is waited for.
const CALLBACKS: [(&str, Retry, u64); 16] = [
    ("attach", Retry::Idempotent, 30_000),
    ("renew", Retry::Idempotent, 30_000),
    ("complete", Retry::Outcome, 30_000),
    ("fail", Retry::Outcome, 30_000),
    ("push_deltas", Retry::Batch, 30_000),
    ("oauth_token", Retry::Never, 30_000),
    ("take_rate", Retry::Never, 30_000),
    ("fetch_artifact", Retry::Idempotent, 30_000),
    ("storage", Retry::Never, 30_000),
    ("admit_child", Retry::Keyed, 30_000),
    ("tool_call", Retry::Never, 30_000),
    ("record_denial", Retry::Never, 30_000),
    ("release_child", Retry::Idempotent, 30_000),
    ("egress_pin", Retry::Idempotent, 30_000),
    ("question_ask", Retry::Keyed, 30_000),
    ("question_wait", Retry::Idempotent, 30_000),
];

/// A callback a runner makes (`crate::relay::OPS`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Op(usize);

impl Op {
    /// The callback of `name`, or none for a call no runner makes.
    pub fn named(name: &str) -> Option<Op> {
        CALLBACKS
            .iter()
            .position(|(callback, _, _)| *callback == name)
            .map(Op)
    }

    /// Every callback a runner makes, in the host API's order.
    pub fn all() -> impl Iterator<Item = Op> {
        (0..CALLBACKS.len()).map(Op)
    }

    pub fn name(self) -> &'static str {
        CALLBACKS[self.0].0
    }

    pub fn retry(self) -> Retry {
        CALLBACKS[self.0].1
    }

    /// How long an answer is waited for before the try is lost.
    pub fn timeout(self) -> Duration {
        Duration::from_millis(CALLBACKS[self.0].2)
    }
}

/// What reached the runner for one try: CYFR's status and its answer's
/// bytes. No answer at all is none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reached {
    pub status: u16,
    pub body: Vec<u8>,
}

/// The relay's half of a host call: post the header and sealed body, and
/// answer what reached the service, or none when nothing did.
pub trait Post {
    fn post(
        &mut self,
        op: Op,
        header: String,
        body: Vec<u8>,
    ) -> impl Future<Output = Option<Reached>>;
}

/// Who presents a call: the attempt's keys, the boot and runner it
/// presents from and the member its assignment names.
#[derive(Debug, Clone)]
pub struct Caller {
    pub keys: AttemptKeys,
    pub boot: String,
    pub runner: String,
    pub member: String,
}

/// A call's end.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// CYFR's answer, read at this version.
    Answered(Answer),
    /// No answer, or a host at another version: whether it acted is unknown.
    Lost,
    /// Lost, for a call never asked again: its effect may have happened.
    Uncertain,
    /// The body is past the host's bound, refused before it was read.
    TooLarge,
}

/// One try's end: final, or lost and perhaps asked again.
enum Try {
    Final(Outcome),
    Lost,
}

/// Make the call `op` with `args`, through `post`: once, and once more
/// after a lost answer when its class allows.
pub async fn call(
    post: &mut impl Post,
    caller: &Caller,
    op: Op,
    args: &Map<String, Value>,
) -> Outcome {
    let body = Zeroizing::new(request_body(op.name(), args));
    match attempt(post, caller, op, &body).await {
        Try::Final(outcome) => outcome,
        Try::Lost if op.retry() == Retry::Never => Outcome::Uncertain,
        Try::Lost => match attempt(post, caller, op, &body).await {
            Try::Final(outcome) => outcome,
            Try::Lost => Outcome::Lost,
        },
    }
}

async fn attempt(post: &mut impl Post, caller: &Caller, op: Op, body: &str) -> Try {
    let fields = CallFields {
        attempt: caller.keys.attempt.clone(),
        boot: caller.boot.clone(),
        runner: caller.runner.clone(),
        member: caller.member.clone(),
        ts: now_ms(),
        nonce: nonce(),
    };
    let Ok(sealed) = seal_call(
        &caller.keys.seal,
        Direction::Body,
        &fields,
        body.as_bytes(),
        &random(),
    ) else {
        return Try::Lost;
    };
    if sealed.len() > MAX_BODY_BYTES {
        return Try::Final(Outcome::TooLarge);
    }
    let Ok(header) = host_call_header(&caller.keys.call, &fields, sealed.as_bytes()) else {
        return Try::Lost;
    };
    match tokio::time::timeout(op.timeout(), post.post(op, header, sealed.into_bytes())).await {
        Ok(Some(reached)) => read(caller, &fields, reached),
        Ok(None) | Err(_) => Try::Lost,
    }
}

fn read(caller: &Caller, fields: &CallFields, reached: Reached) -> Try {
    match reached.status {
        200 => {
            let Ok(plain) = open_call(&caller.keys.seal, Direction::Answer, fields, &reached.body)
            else {
                return Try::Lost;
            };
            match serde_json::from_slice::<Value>(&plain)
                .ok()
                .as_ref()
                .and_then(read_answer)
            {
                Some(Answer::Error { name, .. }) if name == "unknown_version" => {
                    Try::Final(Outcome::Lost)
                }
                Some(answer) => Try::Final(Outcome::Answered(answer)),
                None => Try::Lost,
            }
        }
        413 => Try::Final(Outcome::TooLarge),
        // A listener that cannot read the header answers plain, at its own
        // version.
        _status => match serde_json::from_slice::<Value>(&reached.body) {
            Ok(Value::Object(refusal))
                if refusal.get("error").and_then(Value::as_str) == Some("unknown_version") =>
            {
                Try::Final(Outcome::Lost)
            }
            _ => Try::Lost,
        },
    }
}

fn now_ms() -> u64 {
    let since = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    u64::try_from(since.as_millis()).unwrap_or(u64::MAX)
}

/// A fresh nonce: 18 random bytes in unpadded base64url.
fn nonce() -> String {
    BASE64URL.encode(random::<18>())
}

/// `N` bytes from the operating system's random source. A runner that
/// cannot read it cannot seal anything, and ends.
fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).expect("the operating system's random source answers");
    bytes
}
