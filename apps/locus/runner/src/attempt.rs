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
//! A formula's child is an attempt too (`crate::subtree::Tree`), started
//! from what its admission answered: claimed for this runner as CYFR
//! admitted it, it does not attach, and its vault fields are the
//! admission's. A child is stopped as a budget stops a call, closing
//! `abandoned` with its own sentence, when its waiter goes or its service
//! cancels it, and answers its waiter what its close recorded (`Answer`).
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
use crate::wire::{Json, MAX_OUTPUT_DEPTH, Unread, decode_base64, read, scan};
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
    /// A child's vault fields, as its admission answered them; none for a
    /// root, which attaches.
    pub admitted: Option<Fields>,
}

/// An attempt's vault fields by name, cleared when they are dropped.
pub type Fields = std::collections::BTreeMap<String, Zeroizing<String>>;

/// What an attempt's runner gives it.
#[derive(Clone)]
pub struct Runner {
    pub engine: Arc<Engine>,
    pub relay: Relay,
    pub control: Writer,
    /// The runner's id, and the boot of the service it presents from.
    pub runner_id: String,
    pub boot: String,
    /// The subtree the attempt is of, which its formula's children join.
    pub tree: Arc<crate::subtree::Tree>,
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

/// What an attempt's waiter is answered, as its close was recorded (a
/// formula's call of a child, or its task): the output as its JSON text,
/// the failure, or for a run the runner stopped, a failure whose effect is
/// not known. Each is a peer's, held cleared and printed by no `Debug`.
#[derive(PartialEq)]
pub enum Answer {
    Output(Zeroizing<Vec<u8>>),
    Failed(Zeroizing<String>),
    Uncertain(Zeroizing<String>),
}

impl Answer {
    fn failed(sentence: &str) -> Answer {
        Answer::Failed(Zeroizing::new(sentence.to_owned()))
    }
}

impl std::fmt::Debug for Answer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Answer::Output(_) => f.write_str("Output(..)"),
            Answer::Failed(_) => f.write_str("Failed(..)"),
            Answer::Uncertain(_) => f.write_str("Uncertain(..)"),
        }
    }
}

/// The attempt's side of its host calls, which its imports make too.
pub struct Host {
    caller: Caller,
    relay: Relay,
    control: Writer,
    lost: std::sync::atomic::AtomicBool,
    notes: std::sync::Mutex<std::collections::BTreeMap<&'static str, u64>>,
    /// The attempt's streams whose answers are still to be recorded.
    watchers: std::sync::Mutex<Vec<Arc<crate::imports::stream::Watcher>>>,
    /// The formula's tasks that were stopped, until each has ended.
    stopping: std::sync::Mutex<Vec<tokio::task::JoinHandle<()>>>,
}

impl Host {
    pub fn new(caller: Caller, relay: Relay, control: Writer) -> Host {
        Host {
            caller,
            relay,
            control,
            lost: std::sync::atomic::AtomicBool::new(false),
            notes: std::sync::Mutex::new(std::collections::BTreeMap::new()),
            watchers: std::sync::Mutex::new(Vec::new()),
            stopping: std::sync::Mutex::new(Vec::new()),
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
    /// Record that something of the attempt may have acted unseen (a task
    /// stopped while its call was out): its runner is not reused.
    pub fn doubt(&self) {
        self.lost.store(true, std::sync::atomic::Ordering::Relaxed);
    }

    /// Keep `task`, which was told to stop, until it has: the attempt does
    /// not close before it.
    pub fn stopping(&self, task: tokio::task::JoinHandle<()>) {
        let mut stopping = self.stopping.lock().expect("the attempt's tasks");
        stopping.retain(|task| !task.is_finished());
        stopping.push(task);
    }

    /// Wait until every task of the attempt's that was told to stop has
    /// ended, before the attempt closes.
    pub async fn settle_tasks(&self) {
        let tasks = std::mem::take(&mut *self.stopping.lock().expect("the attempt's tasks"));
        for task in tasks {
            let _ = task.await;
        }
    }

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
        // An answer nested past the bound reached the runner unread: what
        // CYFR did is as unknown as for a lost one.
        let ended = match outcome {
            Outcome::Lost | Outcome::Answered(Reading::Refused("lost")) => Some("lost"),
            Outcome::Uncertain => Some("uncertain"),
            Outcome::TooDeep => Some("unread, nested too deep"),
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

    /// Keep `watcher` among the attempt's streams to record, forgetting
    /// those already recorded whole.
    pub fn watch(&self, watcher: Arc<crate::imports::stream::Watcher>) {
        let mut watchers = self.watchers.lock().expect("the attempt's watchers");
        watchers.retain(|watcher| !watcher.settled());
        watchers.push(watcher);
    }

    /// Record what has arrived of each of the attempt's streams and is not
    /// yet recorded, before the attempt closes: a stream's answer that
    /// arrived while its guest ran is the attempt's, read or not.
    pub async fn settle_streams(&self) {
        let watchers = self
            .watchers
            .lock()
            .expect("the attempt's watchers")
            .clone();
        for watcher in watchers {
            watcher.settle(self).await;
        }
    }

    /// Who presents the attempt's calls.
    pub fn caller(&self) -> &Caller {
        &self.caller
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

/// Run the attempt `start` on `runner`, to its end, unless `stop` stops it
/// first: how it ended, and what its waiter is answered.
pub async fn run(start: Start, runner: Runner, stop: crate::subtree::Stop) -> (Ended, Answer) {
    let host = Arc::new(Host::new(
        caller(&start, &runner),
        runner.relay.clone(),
        runner.control.clone(),
    ));
    let ended = attempt(&start, &runner, &host, &stop).await;
    host.noted();
    ended
}

// Who presents `start`'s calls on `runner`.
fn caller(start: &Start, runner: &Runner) -> Caller {
    Caller {
        keys: start.keys.clone(),
        boot: runner.boot.clone(),
        runner: runner.runner_id.clone(),
        member: start.assignment.member.clone(),
    }
}

async fn attempt(
    start: &Start,
    runner: &Runner,
    host: &Arc<Host>,
    stop: &crate::subtree::Stop,
) -> (Ended, Answer) {
    let assignment = &start.assignment;
    let fields = match &start.admitted {
        Some(fields) => fields.clone(),
        None => match attached(start, host).await {
            Ok(fields) => fields,
            Err(ended) => return ended,
        },
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
        runner: runner.clone(),
        intercepted: assignment.intercepted.clone(),
    });
    // The component's work runs on a worker thread; its budget, lease and
    // stop are watched here, on the runner's thread, and whichever ends
    // first ends it: the work is aborted, its store dropped with it, on
    // every way out of this attempt, its own abort included.
    let work = tokio::spawn(execute(
        runner.engine.clone(),
        host.clone(),
        assignment.component.digest.clone(),
        kind,
        imports,
        // The guest's input may carry what it fetches with: held cleared.
        Zeroizing::new(
            serde_json::to_string(start.input.value()).expect("a JSON value is written"),
        ),
    ));
    let mut work = Work(work);
    let mut poster = runner.relay.poster(host.attempt());
    let renewing = watch(
        &mut poster,
        &host.caller,
        host.attempt(),
        assignment.lease_until,
    );
    let mut finished = false;
    let outcome = tokio::select! {
        outcome = work.ended() => {
            finished = true;
            outcome
        }
        () = tokio::time::sleep(Duration::from_millis(budget_ms)) => {
            Run_::Stopped(words::timeout(budget_ms))
        }
        () = renewing => Run_::Stopped(words::LEASE_LOST.to_owned()),
        () = stop.stopped() => Run_::Stopped(words::CANCELLED.to_owned()),
    };
    // A stopped call's store is gone before its attempt closes: nothing of
    // the guest runs on past its close.
    if !finished {
        work.stop().await;
    }
    close(host, outcome).await
}

/// An attempt's component work on a worker thread, aborted when it is
/// dropped.
struct Work(tokio::task::JoinHandle<Run_>);

impl Work {
    async fn ended(&mut self) -> Run_ {
        match (&mut self.0).await {
            Ok(outcome) => outcome,
            // Panics abort the runner: a work that ended unjoined was
            // aborted, which only its attempt does.
            Err(_) => Run_::Stopped(words::CANCELLED.to_owned()),
        }
    }
}

impl Work {
    /// Abort the work and wait until it is dropped, its store with it: at
    /// once when it is not running, else at its guest's next yield (an
    /// epoch tick) or its next host call.
    async fn stop(&mut self) {
        self.0.abort();
        let _ = (&mut self.0).await;
    }
}

impl Drop for Work {
    fn drop(&mut self) {
        self.0.abort();
    }
}

// A root's attach: the run's vault fields, or how the attempt ended there.
async fn attached(start: &Start, host: &Host) -> Result<Fields, (Ended, Answer)> {
    let assignment = &start.assignment;
    let attached = host
        .call(
            "attach",
            args([("assignment", Value::String(start.token.as_str().to_owned()))]),
        )
        .await;
    match attached {
        Outcome::Answered(Reading::Ok(fields)) => match fields.value() {
            Value::Object(fields) => Ok(fields
                .iter()
                .filter_map(|(name, value)| {
                    value
                        .as_str()
                        .map(|value| (name.clone(), Zeroizing::new(value.to_owned())))
                })
                .collect()),
            _ => Err(left_open(assignment, "its attach answered no fields")),
        },
        // CYFR closed the attempt as it refused it.
        Outcome::Answered(Reading::SetupRequired(_) | Reading::Failed(_)) => Err((
            Ended {
                closed: true,
                unclean: host.lost(),
            },
            Answer::failed(words::ENDED),
        )),
        _ => Err(left_open(
            assignment,
            "its attach was refused or not answered",
        )),
    }
}

fn left_open(assignment: &Assignment, why: &str) -> (Ended, Answer) {
    eprintln!(
        "cyfr-runner: {} is left open: {why}",
        assignment.execution_id
    );
    (
        Ended {
            closed: false,
            unclean: false,
        },
        Answer::failed(words::ENDED),
    )
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
    engine: Arc<Engine>,
    host: Arc<Host>,
    digest: String,
    kind: Kind,
    imports: Arc<Run>,
    input: Zeroizing<String>,
) -> Run_ {
    // A node that consents no memory at all runs nothing: its store could
    // hold no memory, and nothing of the component is fetched for it.
    if imports.limits.max_memory_bytes == 0 {
        return Run_::Failed(words::NO_MEMORY.to_owned());
    }
    let digest = &digest;
    let turn = engine.turn(digest).await;
    let component = match engine.kept(digest) {
        Some(component) => component,
        None => {
            let bytes = match fetch(&host, digest).await {
                Ok(bytes) => bytes,
                Err(sentence) => return Run_::Failed(sentence),
            };
            match engine.compile(digest, bytes).await {
                Ok(component) => component,
                Err(sentence) => return Run_::Failed(sentence),
            }
        }
    };
    drop(turn);
    match engine.run(kind, &component, imports, &input).await {
        Ok(output) if scan(output.as_bytes()).depth > MAX_OUTPUT_DEPTH => {
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

// The reader's reason a guest's output is no JSON: what it met and where,
// never the output's bytes.
fn not_json(output: &str) -> String {
    match crate::wire::malformed(output.as_bytes()) {
        Some(reason) => format!("{}: {reason}", words::OUTPUT_NOT_JSON),
        None => words::OUTPUT_NOT_JSON.to_owned(),
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

async fn close(host: &Host, outcome: Run_) -> (Ended, Answer) {
    host.settle_tasks().await;
    host.settle_streams().await;
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
    // What the runner itself knows of the run, should CYFR not record it.
    let unrecorded = match (stopped, &fields[1]) {
        (true, ("error", Value::String(sentence))) => {
            Answer::Uncertain(Zeroizing::new(sentence.clone()))
        }
        _ => Answer::failed(words::ENDED),
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
    // failure it recorded instead; a fail with the failure as recorded. A
    // run the runner stopped is answered as one whose effect is not known.
    let recorded = match (op, answer) {
        ("complete", Outcome::Answered(Reading::Ok(output))) => {
            Some(Answer::Output(crate::wire::to_bytes(output.value())))
        }
        ("complete", Outcome::Answered(Reading::Failed(message))) => Some(Answer::Failed(message)),
        ("fail", Outcome::Answered(Reading::Ok(recorded))) => match recorded.value() {
            Value::String(message) if stopped => {
                Some(Answer::Uncertain(Zeroizing::new(message.clone())))
            }
            Value::String(message) => Some(Answer::Failed(Zeroizing::new(message.clone()))),
            _ => None,
        },
        _ => None,
    };
    if recorded.is_none() {
        eprintln!(
            "cyfr-runner: {}'s {op} was refused or not answered",
            host.execution_id()
        );
    }
    let ended = Ended {
        closed: recorded.is_some(),
        unclean: stopped || host.lost(),
    };
    (ended, recorded.unwrap_or(unrecorded))
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
