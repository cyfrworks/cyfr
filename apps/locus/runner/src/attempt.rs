// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! One execution attempt, from its attach to its close.
//!
//! In order, an attempt:
//!
//! 1. attaches with its assignment's token, which CYFR verifies, and is
//!    answered the run's vault fields. An attach CYFR answers with a
//!    required setup or a failure closed the attempt there; any other
//!    refusal, or no answer, leaves it open, to CYFR;
//! 2. reads the authority the assignment carries (`crate::authority`) and
//!    its component's type, and sends `engine.authority_entered`;
//! 3. runs its component under its budget, the assignment's `timeout_ms`
//!    and no more than what is left of its subtree's `deadline`: the
//!    component's bytes are fetched by digest only when no compile of that
//!    digest is kept (`crate::engine`), and are run only if they hash to
//!    it. While it runs, its lease is renewed every minute (`watch`);
//! 4. closes the attempt: `complete` with the guest's output, or `fail`
//!    with a sentence (`crate::words`), marked `abandoned` when the runner
//!    stopped the component's call, at its budget or a lost lease.
//!
//! Stopping a call drops it: its store goes with it, and nothing of the
//! guest runs on. The runner still counts the stop against its reuse
//! (`Ended::unclean`). Whatever an attempt had outstanding on the relay
//! when it was stopped stays there until answered, and is discarded.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value};
use zeroize::Zeroizing;

use crate::assignment::Assignment;
use crate::auth::AttemptKeys;
use crate::authority;
use crate::control::{Event, Message, Meta, Writer};
use crate::engine::{Engine, Failure, Kind};
use crate::host::{self, Caller, Op, Outcome, Post, Reading};
use crate::imports::Run;
use crate::relay::Relay;
use crate::wire::{Json, MAX_OUTPUT_DEPTH, Unread, decode_base64, depth, read};
use crate::words;

/// How often a running attempt renews its lease.
pub const LEASE_TICK: Duration = Duration::from_secs(60);

/// What an attempt starts with: its assignment's token and what it reads
/// as, the input its digest binds (a JSON object), and the attempt's keys
/// as its service opened them.
pub struct Start {
    pub token: Zeroizing<String>,
    pub assignment: Assignment,
    pub input: Json,
    pub keys: AttemptKeys,
}

/// What an attempt's runner gives it.
#[derive(Clone)]
pub struct Runner {
    pub engine: Arc<Engine>,
    pub relay: Relay,
    pub control: Writer,
    /// The runner's id, and the boot of the service it presents from.
    pub runner_id: String,
    pub boot: String,
}

/// How an attempt ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ended {
    /// CYFR recorded the attempt's close (or closed it at its attach).
    pub closed: bool,
    /// The runner stopped the component's call, or one of the attempt's
    /// calls ended lost or uncertain: the runner is not reused.
    pub unclean: bool,
}

/// The attempt's side of its host calls, which its imports make too.
pub struct Host {
    caller: Caller,
    relay: Relay,
    control: Writer,
    lost: std::sync::atomic::AtomicBool,
    notes: std::sync::Mutex<std::collections::BTreeMap<&'static str, u64>>,
}

impl Host {
    pub fn new(caller: Caller, relay: Relay, control: Writer) -> Host {
        Host {
            caller,
            relay,
            control,
            lost: std::sync::atomic::AtomicBool::new(false),
            notes: std::sync::Mutex::new(std::collections::BTreeMap::new()),
        }
    }

    /// Log a line of `kind` that a guest's call can cause: the first of
    /// each kind of the attempt is written, the rest counted, and
    /// `noted` writes the counts at the attempt's end, so no guest writes
    /// the runner's log at its own pace.
    pub fn note(&self, kind: &'static str, line: impl FnOnce() -> String) {
        let mut notes = self.notes.lock().expect("the attempt's notes");
        let count = notes.entry(kind).or_insert(0);
        *count += 1;
        if *count == 1 {
            eprintln!("cyfr-runner: {}", line());
        }
    }

    /// Write how many more lines of each kind `note` held back.
    pub fn noted(&self) {
        let notes = std::mem::take(&mut *self.notes.lock().expect("the attempt's notes"));
        for (kind, count) in notes {
            if count > 1 {
                eprintln!(
                    "cyfr-runner: {} logged {kind} {} more times",
                    self.execution_id(),
                    count - 1
                );
            }
        }
    }

    /// Whether a call of the attempt ended lost or uncertain: what it did
    /// is unknown, and so is what its guest holds, so its runner is not
    /// reused.
    pub fn lost(&self) -> bool {
        self.lost.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Make the host call `op` with `args`, whose strings (a token, a
    /// guest's output or content) are cleared once the call has ended.
    pub async fn call(&self, op: &'static str, args: Map<String, Value>) -> Outcome {
        let op = Op::named(op).expect("a callback of the host API");
        let mut poster = self.relay.poster(&self.caller.keys.attempt.attempt);
        let args = Json::from_value(Value::Object(args));
        let Value::Object(members) = args.value() else {
            unreachable!("an object")
        };
        let outcome = host::call(&mut poster, &self.caller, op, members).await;
        let ended = match outcome {
            Outcome::Lost | Outcome::Answered(Reading::Refused("lost")) => Some("lost"),
            Outcome::Uncertain => Some("uncertain"),
            _ => None,
        };
        if let Some(ended) = ended {
            self.note("a call that ended lost or uncertain", || {
                format!(
                    "{}'s {} ended {ended}",
                    self.caller.keys.attempt.execution_id,
                    op.name()
                )
            });
            self.lost.store(true, std::sync::atomic::Ordering::Relaxed);
        }
        outcome
    }

    /// Send one operator event once the control channel's queue has room,
    /// so a guest whose calls cause events is paced by the service's
    /// reading of them. One no line carries is dropped and noted by its
    /// name; one the channel no longer takes is dropped.
    pub async fn event(&self, event: Event) {
        let name = event.name;
        if let Err(crate::control::Unwritten::Invalid(_)) =
            self.control.send(&Message::Event(event)).await
        {
            self.note("an event no line carries", || {
                format!("the event {name} carries no line, and is not sent")
            });
        }
    }

    /// The runner is not reused after this attempt: what one of its
    /// operations did is unknown.
    pub fn unclean(&self) {
        self.lost.store(true, std::sync::atomic::Ordering::Relaxed);
    }

    /// The relay the attempt's calls and fetches go through.
    pub fn relay(&self) -> &Relay {
        &self.relay
    }

    /// The attempt's keys, which open its attached answers' frames.
    pub fn keys(&self) -> &AttemptKeys {
        &self.caller.keys
    }

    pub fn attempt(&self) -> &str {
        &self.caller.keys.attempt.attempt
    }

    pub fn execution_id(&self) -> &str {
        &self.caller.keys.attempt.execution_id
    }

    pub fn fence(&self) -> u64 {
        self.caller.keys.attempt.fence
    }
}

/// What a run of the component came to.
enum Run_ {
    Output(Json),
    Failed(String),
    Stopped(String),
}

/// Run the attempt `start` on `runner`, to its end.
pub async fn run(start: Start, runner: Runner) -> Ended {
    let assignment = &start.assignment;
    let caller = Caller {
        keys: start.keys.clone(),
        boot: runner.boot.clone(),
        runner: runner.runner_id.clone(),
        member: assignment.member.clone(),
    };
    let host = Arc::new(Host::new(
        caller,
        runner.relay.clone(),
        runner.control.clone(),
    ));
    let ended = attempt(&start, &runner, &host).await;
    host.noted();
    ended
}

async fn attempt(start: &Start, runner: &Runner, host: &Arc<Host>) -> Ended {
    let assignment = &start.assignment;
    let attached = host
        .call(
            "attach",
            args([("assignment", Value::String(start.token.as_str().to_owned()))]),
        )
        .await;
    let fields = match attached {
        Outcome::Answered(Reading::Ok(fields)) => match fields.value() {
            Value::Object(fields) => fields
                .iter()
                .filter_map(|(name, value)| {
                    value
                        .as_str()
                        .map(|value| (name.clone(), Zeroizing::new(value.to_owned())))
                })
                .collect(),
            _ => return left_open(assignment, "its attach answered no fields"),
        },
        // CYFR closed the attempt as it refused it.
        Outcome::Answered(Reading::SetupRequired(_) | Reading::Failed(_)) => {
            return Ended {
                closed: true,
                unclean: host.lost(),
            };
        }
        _ => return left_open(assignment, "its attach was refused or not answered"),
    };
    let reference = &assignment.component.reference;
    let (authority, kind) = match (
        authority::read(&assignment.authority),
        Kind::named(&assignment.component.kind),
    ) {
        (Ok(authority), Some(kind)) => (authority, kind),
        _ => {
            eprintln!(
                "cyfr-runner: {} cannot run its assignment",
                assignment.execution_id
            );
            return close(host, Run_::Failed(words::UNRUNNABLE.to_owned())).await;
        }
    };
    host.event(Event {
        name: "engine.authority_entered",
        measurements: vec![],
        metadata: vec![
            ("execution_id", Meta::text(&assignment.execution_id)),
            ("reference", Meta::text(reference)),
        ],
    })
    .await;
    let budget_ms = budget_ms(assignment, now_ms());
    let imports = Arc::new(Run {
        host: host.clone(),
        component_ref: reference.clone(),
        limits: authority.limits,
        fields,
        attached: authority.attached_fields,
    });
    let work = execute(
        &runner.engine,
        host,
        assignment,
        kind,
        imports,
        &start.input,
    );
    let mut poster = runner.relay.poster(host.attempt());
    let renewing = watch(
        &mut poster,
        &host.caller,
        host.attempt(),
        assignment.lease_until,
    );
    let outcome = tokio::select! {
        outcome = work => outcome,
        () = tokio::time::sleep(Duration::from_millis(budget_ms)) => {
            Run_::Stopped(words::timeout(budget_ms))
        }
        () = renewing => Run_::Stopped(words::LEASE_LOST.to_owned()),
    };
    close(host, outcome).await
}

fn left_open(assignment: &Assignment, why: &str) -> Ended {
    eprintln!(
        "cyfr-runner: {} is left open: {why}",
        assignment.execution_id
    );
    Ended {
        closed: false,
        unclean: false,
    }
}

/// The run's budget from `now`: its timeout, and no more than what is left
/// of its subtree's deadline, so a queued or retried start cannot extend
/// the subtree.
pub fn budget_ms(assignment: &Assignment, now: u64) -> u64 {
    assignment
        .timeout_ms
        .min(assignment.deadline.saturating_sub(now))
}

async fn execute(
    engine: &Engine,
    host: &Host,
    assignment: &Assignment,
    kind: Kind,
    imports: Arc<Run>,
    input: &Json,
) -> Run_ {
    // A node that consents no memory at all runs nothing: its store could
    // hold no memory, and nothing of the component is fetched for it.
    if imports.limits.max_memory_bytes == 0 {
        return Run_::Failed(words::NO_MEMORY.to_owned());
    }
    let digest = &assignment.component.digest;
    let component = match engine.kept(digest) {
        Some(component) => component,
        None => {
            let bytes = match fetch(host, digest).await {
                Ok(bytes) => bytes,
                Err(sentence) => return Run_::Failed(sentence),
            };
            match engine.compile(digest, bytes).await {
                Ok(component) => component,
                Err(sentence) => return Run_::Failed(sentence),
            }
        }
    };
    let input = serde_json::to_string(input.value()).expect("a JSON value is written");
    match engine.run(kind, &component, imports, &input).await {
        Ok(output) if depth(output.as_bytes()) > MAX_OUTPUT_DEPTH => {
            Run_::Failed(words::output_too_deep())
        }
        Ok(output) => match read(output.as_bytes()) {
            Ok(json) => Run_::Output(json),
            Err(Unread::TooDeep) => Run_::Failed(words::output_too_deep()),
            Err(Unread::Malformed) => Run_::Failed(not_json(&output)),
        },
        Err(Failure::Ended(sentence)) => Run_::Failed(sentence),
        Err(Failure::Refused(sentence)) => Run_::Failed(sentence),
    }
}

// The parser's reason a guest's output is no JSON: a position, never the
// output's bytes.
fn not_json(output: &str) -> String {
    match serde_json::from_str::<serde::de::IgnoredAny>(output) {
        Err(reason) => format!("{}: {reason}", words::OUTPUT_NOT_JSON),
        Ok(_) => words::OUTPUT_NOT_JSON.to_owned(),
    }
}

// The component's bytes, by its digest, only when they hash to it.
async fn fetch(host: &Host, digest: &str) -> Result<Vec<u8>, String> {
    let outcome = host
        .call(
            "fetch_artifact",
            args([("digest", Value::String(digest.to_owned()))]),
        )
        .await;
    let bytes = match outcome {
        Outcome::Answered(Reading::Ok(encoded)) => encoded.value().as_str().and_then(decode_base64),
        Outcome::TooDeep => return Err(words::answer_too_deep("fetch_artifact")),
        _ => None,
    };
    let Some(bytes) = bytes else {
        eprintln!("cyfr-runner: the artifact {digest} was not fetched");
        return Err(words::NOT_FETCHED.to_owned());
    };
    if crate::engine::digest(&bytes) != digest {
        return Err(words::NOT_DIGEST.to_owned());
    }
    Ok(bytes)
}

async fn close(host: &Host, outcome: Run_) -> Ended {
    let (op, fields, stopped) = match outcome {
        Run_::Output(mut output) => (
            "complete",
            vec![
                ("output", output.take_value()),
                ("status", Value::String("completed".to_owned())),
            ],
            false,
        ),
        Run_::Failed(sentence) => ("fail", failed(sentence, false), false),
        Run_::Stopped(sentence) => ("fail", failed(sentence, true), true),
    };
    let mut outcome = args([
        ("attempt", Value::String(host.attempt().to_owned())),
        (
            "execution_id",
            Value::String(host.execution_id().to_owned()),
        ),
        ("fence", Value::from(host.fence())),
    ]);
    outcome.extend(
        fields
            .into_iter()
            .map(|(name, value)| (name.to_owned(), value)),
    );
    let answer = host
        .call(op, args([("outcome", Value::Object(outcome))]))
        .await;
    // A complete CYFR answers with the output as recorded, or with a
    // failure it recorded instead; a fail with the failure as recorded.
    let closed = match (op, &answer) {
        ("complete", Outcome::Answered(Reading::Ok(_) | Reading::Failed(_))) => true,
        ("fail", Outcome::Answered(Reading::Ok(recorded))) => recorded.value().is_string(),
        _ => false,
    };
    if !closed {
        eprintln!(
            "cyfr-runner: {}'s {op} was refused or not answered",
            host.execution_id()
        );
    }
    Ended {
        closed,
        unclean: stopped || host.lost(),
    }
}

fn failed(sentence: String, abandoned: bool) -> Vec<(&'static str, Value)> {
    vec![
        ("abandoned", Value::Bool(abandoned)),
        ("error", Value::String(sentence)),
        ("status", Value::String("failed".to_owned())),
    ]
}

/// The JSON object `members` as host call args.
fn args(members: impl IntoIterator<Item = (&'static str, Value)>) -> Map<String, Value> {
    crate::imports::args(members)
}

/// What a renewal leaves of a lease held until `until`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Renewal {
    /// CYFR renewed it to this instant.
    Renewed(u64),
    /// CYFR's store could not answer, and the lease last held still holds.
    Held,
    /// The lease is no longer this attempt's: CYFR said so, gave no
    /// answer, or could not answer once it had run out.
    Lapsed,
}

/// Renew `attempt`'s lease, held until `until`, at `now`.
pub async fn renew(
    post: &mut impl Post,
    caller: &Caller,
    attempt: &str,
    until: u64,
    now: u64,
) -> Renewal {
    let op = Op::named("renew").expect("a callback of the host API");
    let renewal = host::call(
        post,
        caller,
        op,
        &args([(
            "attempts",
            Value::Array(vec![Value::String(attempt.to_owned())]),
        )]),
    )
    .await;
    match renewal {
        Outcome::Answered(Reading::Ok(renewals)) => match renewals
            .value()
            .get(attempt)
            .and_then(|renewal| renewal.get("lease_until"))
            .and_then(Value::as_u64)
        {
            Some(until) => Renewal::Renewed(until),
            None => Renewal::Lapsed,
        },
        Outcome::Answered(Reading::Refused("unavailable")) if now < until => Renewal::Held,
        _ => Renewal::Lapsed,
    }
}

/// Renew `attempt`'s lease, held until `until`, every `LEASE_TICK`; ends
/// when it lapses.
pub async fn watch(post: &mut impl Post, caller: &Caller, attempt: &str, mut until: u64) {
    loop {
        tokio::time::sleep(LEASE_TICK).await;
        match renew(post, caller, attempt, until, now_ms()).await {
            Renewal::Renewed(renewed) => until = renewed,
            Renewal::Held => {}
            Renewal::Lapsed => return,
        }
    }
}

/// The time, in Unix milliseconds.
pub fn now_ms() -> u64 {
    let since = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    u64::try_from(since.as_millis()).unwrap_or(u64::MAX)
}
