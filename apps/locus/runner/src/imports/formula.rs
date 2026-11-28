// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! `cyfr:formula/invoke`: what a formula reaches, each its attempt's host
//! calls, decided by CYFR under the authority it holds for that attempt.
//!
//! **A request** (`call`, `spawn`) is a JSON object naming `tool` and
//! `action`, both strings, with `args` an object (`{}` when absent), within
//! the envelope the node's `max_request_size` allows and the depth a
//! document is read to. An action the assignment names as intercepted is
//! a child the host runs: `execution.run` is admitted by CYFR
//! (`admit_child`) and run as an attempt of this runner's subtree
//! (`crate::subtree::Tree`), and `execution.run_stream` likewise with
//! nothing waiting for it, answered at once with its id and its event
//! stream's URL; any other intercepted action has no arm here. Every other
//! action is a catalog tool call (`tool_call`).
//!
//! **A child's admission is authority.** CYFR answers it with the child's
//! assignment, its attempt's keys sealed under the formula's attempt's
//! seal key, the input its digest binds and its vault fields. The child
//! runs only when its keys open, they and its assignment name the same
//! attempt, its assignment names this runner's service and boot, the
//! formula's member and the subtree's athanor, its input is the digest's
//! and a JSON object, and the relay carries its attempt. An admission whose
//! assignment reads but that fails any of these, or that the subtree does
//! not start, is given back (`release_child`) exactly once, and its guest
//! answered as a call that failed; one whose assignment does not read
//! names no child to give back. Either leaves the runner not clean when
//! nothing confirms the child was given back. A lost admission is asked
//! again under the same `child_key`, so CYFR admits one child however its
//! answer is lost.
//!
//! **Tasks** (`spawn`, then `await`, `await-all`, `await-any`, `poll`,
//! `cancel`) are a formula's own, numbered `task_1` on, at most the node's
//! `max_concurrent_tasks` held at once, a finished task's result counted
//! until it is awaited. A task is a spawned child, admitted before it takes
//! a task, or a spawned tool call. Awaits wait at most the node's
//! `batch_timeout`; a task an await gives up on, and a task cancelled, is
//! stopped. When the formula's store is dropped (its run ended, however),
//! every task still running is stopped. A stopped child closes
//! `abandoned`; a stopped tool call may have reached CYFR, so its runner is
//! not reused; and the formula's attempt closes only once each stopped task
//! has ended (`Host::settle_tasks`). A called child is stopped likewise
//! when its call is dropped.
//!
//! **What a formula makes the runner hold**: a task's result is its
//! envelope's JSON as cleared bytes, never a parsed tree, at most a host
//! answer's bound (`crate::relay::MAX_BODY_BYTES`, 5 MiB) each, and at most
//! `max_concurrent_tasks` of them at once, running and unawaited together.
//!
//! Every answer is a JSON object: a success, or the error envelope of
//! `tests/fixtures/guest_error.json` with one of its `invoke_types`, the
//! runner's own (`Kind`) or, for a refusal CYFR renders for the guest (a
//! setup refusal with its `remediation`), CYFR's, handed on as it is.

use std::collections::BTreeMap;
use std::future::Future as _;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::formula_world::cyfr::formula::invoke;
use super::storage::{ENVELOPE_OVERHEAD, elapsed_ms};
use super::{Guest, Run, args, ended};
use crate::attempt::{Answer, Fields, Host, Start};
use crate::authority::duration_ms;
use crate::control::{Event, Meta};
use crate::host::{Outcome, Reading};
use crate::subtree::{Stop, StopOnDrop, Unstarted};
use crate::wire::{Json, Unread, read, to_bytes};
use crate::words;

/// Every error type the runner itself answers a formula's invoke with,
/// held to `tests/fixtures/guest_error.json`'s `invoke_types`: every error
/// the runner makes is made of one (`error`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    InvalidJson,
    InvalidRequest,
    RequestTooLarge,
    ResourceLimit,
    DispatchError,
    Uncertain,
    Timeout,
    TaskFailed,
    Unknown,
}

impl Kind {
    pub const ALL: [Kind; 9] = [
        Kind::InvalidJson,
        Kind::InvalidRequest,
        Kind::RequestTooLarge,
        Kind::ResourceLimit,
        Kind::DispatchError,
        Kind::Uncertain,
        Kind::Timeout,
        Kind::TaskFailed,
        Kind::Unknown,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Kind::InvalidJson => "invalid_json",
            Kind::InvalidRequest => "invalid_request",
            Kind::RequestTooLarge => "request_too_large",
            Kind::ResourceLimit => "resource_limit",
            Kind::DispatchError => "dispatch_error",
            Kind::Uncertain => "uncertain",
            Kind::Timeout => "timeout",
            Kind::TaskFailed => "task_failed",
            Kind::Unknown => "unknown",
        }
    }
}

/// The intercepted actions the host runs, and how.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Arm {
    /// A child its call waits for.
    Call,
    /// A child nothing waits for.
    Stream,
}

fn arm(name: &str) -> Option<Arm> {
    match name {
        "execution.run" => Some(Arm::Call),
        "execution.run_stream" => Some(Arm::Stream),
        _ => None,
    }
}

/// A refusal of the guest's: its type and message.
type Refusal = (Kind, String);

/// The runner's error of `kind` and `message`, as a JSON value.
fn error(kind: Kind, message: &str) -> Value {
    json!({"error": {"type": kind.name(), "message": message}})
}

fn refused((kind, message): Refusal) -> Value {
    error(kind, &message)
}

/// What the guest is answered, as text: the value is cleared as it goes.
fn text(answer: Value) -> String {
    let answer = Json::from_value(answer);
    serde_json::to_string(answer.value()).expect("a JSON value is written")
}

/// An envelope's bytes as the guest's answer.
fn text_of(mut bytes: Zeroizing<Vec<u8>>) -> String {
    String::from_utf8(std::mem::take(&mut *bytes)).expect("JSON is UTF-8")
}

/// A request's tool, action and args.
struct Request {
    tool: String,
    action: String,
    args: Map<String, Value>,
}

impl Request {
    fn name(&self) -> String {
        format!("{}.{}", self.tool, self.action)
    }
}

// The bound a request's text is held to before it is read.
fn within_envelope(request: &str, max_request_size: u64) -> Result<(), Refusal> {
    let envelope = max_request_size
        .saturating_mul(2)
        .saturating_add(ENVELOPE_OVERHEAD);
    if request.len() as u64 > envelope {
        return Err((Kind::RequestTooLarge, words::INVOKE_TOO_LARGE.to_owned()));
    }
    Ok(())
}

// A document of the guest's, depth-counted before it is parsed.
fn document(request: &str) -> Result<Json, Refusal> {
    match read(request.as_bytes()) {
        Ok(json) => Ok(json),
        Err(Unread::TooDeep) => Err((Kind::InvalidJson, words::request_too_deep())),
        Err(Unread::Malformed) => Err((Kind::InvalidJson, words::REQUEST_NOT_JSON.to_owned())),
    }
}

fn requested(request: &str, max_request_size: u64) -> Result<Request, Refusal> {
    within_envelope(request, max_request_size)?;
    let mut json = document(request)?;
    let Value::Object(members) = json.value() else {
        return Err((Kind::InvalidRequest, words::NO_TOOL_OR_ACTION.to_owned()));
    };
    let (Some(Value::String(tool)), Some(Value::String(action))) =
        (members.get("tool"), members.get("action"))
    else {
        return Err((Kind::InvalidRequest, words::NO_TOOL_OR_ACTION.to_owned()));
    };
    let (tool, action) = (tool.clone(), action.clone());
    let args = match json.take_member("args") {
        None => Map::new(),
        Some(mut args) => match args.take_value() {
            Value::Object(args) => args,
            _ => return Err((Kind::InvalidRequest, words::ARGS_NOT_MAP.to_owned())),
        },
    };
    Ok(Request { tool, action, args })
}

/// A child's request: what the child is to run, as the guest asked it.
struct ChildRequest {
    reference: String,
    need: Value,
    connection: Option<String>,
    input: Map<String, Value>,
}

// The guest's lineage keys never reach CYFR: the child's parent and root
// are the formula's attempt's, and its input only what the request's own
// `input` carried.
fn child_request(name: &str, mut args: Map<String, Value>) -> Result<ChildRequest, Refusal> {
    let reference = match args.get("reference") {
        Some(Value::String(reference)) if !reference.is_empty() => reference.clone(),
        _ => return Err((Kind::InvalidRequest, words::no_reference(name))),
    };
    let connection = match args.remove("connection") {
        None | Some(Value::Null) => None,
        Some(Value::String(connection)) => Some(connection),
        Some(_) => return Err((Kind::InvalidRequest, words::connection_not_name(name))),
    };
    let input = match args.remove("input") {
        // Absent, null or false reads as no input, as the runner before.
        None | Some(Value::Null) | Some(Value::Bool(false)) => Map::new(),
        Some(Value::Object(input)) => input,
        Some(_) => return Err((Kind::InvalidRequest, words::input_not_object(name))),
    };
    Ok(ChildRequest {
        reference,
        need: args.remove("need").unwrap_or(Value::Null),
        connection,
        input,
    })
}

/// Why a child is not admitted: the guest's answer, or the run's end.
enum Unadmitted {
    Refused(Value),
    Ended(wasmtime::Error),
}

// A refusal of a host call, as the guest is answered it.
fn host_refusal(host: &Host, op: &str, outcome: Outcome) -> Value {
    match outcome {
        // CYFR's own words for the guest, handed on as they are.
        Outcome::Answered(Reading::GuestError {
            kind,
            message,
            remediation,
        }) => match remediation {
            Some(mut remediation) => json!({"error": {"type": kind.as_str(),
                "message": message.as_str(), "remediation": remediation.take_value()}}),
            None => json!({"error": {"type": kind.as_str(), "message": message.as_str()}}),
        },
        Outcome::Uncertain => error(Kind::Uncertain, words::UNCERTAIN),
        _ => {
            host.note("a host call refused in no words of its own", || {
                format!("{}'s {op} was refused or not answered", host.execution_id())
            });
            error(Kind::DispatchError, words::CALL_FAILED)
        }
    }
}

fn call_failed() -> Value {
    error(Kind::DispatchError, words::CALL_FAILED)
}

// A member of CYFR's answer, taken out of it.
fn member(answer: &mut Json, name: &str) -> Option<Value> {
    answer.take_member(name).map(|mut json| json.take_value())
}

// Ask CYFR to admit the child `request` names, made with `guest_fn`, and
// check what it answers.
async fn admit(run: &Run, request: ChildRequest, guest_fn: &str) -> Result<Start, Unadmitted> {
    let host = &run.host;
    let mut members = vec![
        ("child_key", Value::String(child_key())),
        ("guest_fn", Value::String(guest_fn.to_owned())),
        ("input", Value::Object(request.input)),
        ("need", request.need),
        ("reference", Value::String(request.reference)),
    ];
    if let Some(connection) = request.connection {
        members.push(("connection", Value::String(connection)));
    }
    let outcome = host.call("admit_child", args(members)).await;
    ended("admit_child", &outcome).map_err(Unadmitted::Ended)?;
    let mut answer = match outcome {
        Outcome::Answered(Reading::Ok(answer)) => answer,
        other => {
            return Err(Unadmitted::Refused(host_refusal(
                host,
                "admit_child",
                other,
            )));
        }
    };
    // The child is identified by its assignment first: one that does not
    // read names nothing to give back, and leaves the runner in doubt.
    let token = match member(&mut answer, "assignment") {
        Some(Value::String(token)) => Zeroizing::new(token),
        _ => {
            run.runner.tree.doubt();
            return Err(Unadmitted::Refused(call_failed()));
        }
    };
    let Ok(assignment) = crate::assignment::read(&token) else {
        run.runner.tree.doubt();
        return Err(Unadmitted::Refused(call_failed()));
    };
    let projected = (
        member(&mut answer, "attempt_keys"),
        member(&mut answer, "input"),
        member(&mut answer, "secrets"),
    );
    let (Some(Value::String(sealed)), Some(Value::String(input)), Some(Value::Object(secrets))) =
        projected
    else {
        return Err(given_back(run, &assignment.execution_id, "its admission is incomplete").await);
    };
    let (sealed, input) = (Zeroizing::new(sealed), Zeroizing::new(input));
    let secrets = Json::from_value(Value::Object(secrets));
    // Admitted for this runner but not startable by it: given back at
    // once, rather than left to its lease.
    let Some((keys, input)) = checked(run, &assignment, &sealed, &input).await else {
        return Err(given_back(run, &assignment.execution_id, "it does not run here").await);
    };
    let Value::Object(secrets) = secrets.value() else {
        unreachable!("an object")
    };
    let admitted: Fields = secrets
        .iter()
        .filter_map(|(name, value)| {
            value
                .as_str()
                .map(|value| (name.clone(), Zeroizing::new(value.to_owned())))
        })
        .collect();
    Ok(Start {
        token,
        assignment,
        input,
        keys,
        admitted: Some(admitted),
    })
}

// Give the child `execution_id` back, for `why`: the guest's answer, or the
// run's end.
async fn given_back(run: &Run, execution_id: &str, why: &str) -> Unadmitted {
    match release(run, execution_id, why).await {
        Ok(()) => Unadmitted::Refused(call_failed()),
        Err(ended) => Unadmitted::Ended(ended),
    }
}

// Give the child `execution_id` back, once: a release CYFR does not
// confirm leaves the runner in doubt.
async fn release(run: &Run, execution_id: &str, why: &str) -> wasmtime::Result<()> {
    let host = &run.host;
    host.note("a child admitted that does not run here", || {
        format!(
            "the child {execution_id} admitted for {} is given back: {why}",
            host.execution_id()
        )
    });
    let released = host
        .call(
            "release_child",
            args([("execution_id", Value::String(execution_id.to_owned()))]),
        )
        .await;
    ended("release_child", &released)?;
    let confirmed = matches!(&released, Outcome::Answered(Reading::Ok(ok))
        if ok.value() == &Value::Bool(true));
    if !confirmed {
        host.note("a release CYFR did not confirm", || {
            format!(
                "{}'s release of {execution_id} was not confirmed",
                host.execution_id()
            )
        });
        run.runner.tree.doubt();
    }
    Ok(())
}

// The child's keys and input, when what CYFR answered for it is a child
// this runner runs for this formula.
async fn checked(
    run: &Run,
    assignment: &crate::assignment::Assignment,
    sealed: &str,
    input: &str,
) -> Option<(crate::auth::AttemptKeys, Json)> {
    let host = &run.host;
    let caller = host.caller();
    let keys = crate::auth::open_attempt_keys(&caller.keys.seal, sealed).ok()?;
    let attempt = &keys.attempt;
    let named = assignment.athanor_id == attempt.athanor_id
        && assignment.execution_id == attempt.execution_id
        && assignment.attempt == attempt.attempt
        && assignment.fence == attempt.fence
        && assignment.generation == attempt.generation
        && assignment.service == attempt.service;
    let ours = assignment.service == caller.keys.attempt.service
        && assignment.boot == caller.boot
        && assignment.member == caller.member
        && assignment.athanor_id == run.runner.tree.athanor_id();
    if !named || !ours {
        return None;
    }
    if crate::engine::digest(input.as_bytes()) != assignment.input_digest {
        return None;
    }
    let input = read(input.as_bytes())
        .ok()
        .filter(|input| input.value().is_object())?;
    run.runner
        .relay
        .admit(&assignment.attempt)
        .await
        .then_some((keys, input))
}

/// A fresh child key: 18 random bytes in unpadded base64url.
fn child_key() -> String {
    let mut bytes = [0u8; 18];
    getrandom::fill(&mut bytes).expect("the operating system's random source answers");
    crate::wire::encode_base64url(&bytes)
}

// A child CYFR admitted that the subtree did not start: nothing of it ran.
// One the subtree runs already is that running child, which is left as it
// is and the runner is not reused; any other is given back.
async fn unstarted(run: &Run, start: &Start, why: Unstarted) -> wasmtime::Result<Value> {
    let execution_id = &start.assignment.execution_id;
    if why == Unstarted::Known {
        run.host.note("a child admitted twice", || {
            format!("the child {execution_id} was admitted again while it runs")
        });
        run.runner.tree.doubt();
        return Ok(call_failed());
    }
    run.runner.relay.retire(&start.assignment.attempt);
    let reason = match why {
        Unstarted::Full => "its subtree runs as many attempts as an exit can name",
        Unstarted::Unannounced => "its child frame was not written",
        _ => "its subtree is ending",
    };
    release(run, execution_id, reason).await?;
    if why == Unstarted::Unannounced {
        run.runner.tree.doubt();
    }
    Ok(call_failed())
}

/// A task's result: the envelope its call came to, as JSON bytes.
type Result_ = Zeroizing<Vec<u8>>;

/// A formula's tasks.
pub struct Tasks {
    next: u64,
    tasks: BTreeMap<String, Task>,
    host: Arc<Host>,
}

enum Task {
    Running {
        result: tokio::sync::oneshot::Receiver<Result_>,
        task: tokio::task::JoinHandle<()>,
        /// What stopping it means: a spawned child's stop, or a spawned
        /// tool call's word that CYFR has answered it.
        held: Held,
    },
    Done(Result<Result_, Failed>),
}

/// What a running task holds that its stop must account for.
enum Held {
    /// A child, which a stop tells to close abandoned.
    Child(Stop),
    /// A tool call, true once an answer to its call has reached the
    /// runner: stopped before that, what it did is not known.
    Call(Arc<std::sync::atomic::AtomicBool>),
}

/// Why a task gave no result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Failed {
    Timeout,
    Cancelled,
    /// It ended with no result: it was stopped.
    Killed,
}

impl Failed {
    fn sentence(self) -> &'static str {
        match self {
            Failed::Timeout => words::TASK_TIMED_OUT,
            Failed::Cancelled => words::TASK_CANCELLED,
            Failed::Killed => "task was killed",
        }
    }
}

impl Tasks {
    pub fn new(host: Arc<Host>) -> Tasks {
        Tasks {
            next: 1,
            tasks: BTreeMap::new(),
            host,
        }
    }

    // Record each running task whose result has arrived: it sends its
    // result last, and nothing of it acts after.
    fn refresh(&mut self) {
        for task in self.tasks.values_mut() {
            if let Task::Running { result, .. } = task {
                match result.try_recv() {
                    Ok(value) => *task = Task::Done(Ok(value)),
                    Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                        *task = Task::Done(Err(Failed::Killed));
                    }
                    Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {}
                }
            }
        }
    }

    // Whether a task may be added under `most`: running tasks and results
    // not yet awaited count alike, and 0 is a formula that may not spawn.
    fn room(&self, most: u64) -> bool {
        (self.tasks.len() as u64) < most
    }

    fn id(&mut self) -> String {
        let id = format!("task_{}", self.next);
        self.next += 1;
        id
    }

    fn add(
        &mut self,
        result: tokio::sync::oneshot::Receiver<Result_>,
        task: tokio::task::JoinHandle<()>,
        held: Held,
    ) -> String {
        let id = self.id();
        self.tasks
            .insert(id.clone(), Task::Running { result, task, held });
        id
    }

    fn done(&mut self, result: Result<Result_, Failed>) -> String {
        let id = self.id();
        self.tasks.insert(id.clone(), Task::Done(result));
        id
    }

    // Stop `task` if it runs: its work is aborted, and kept until it has
    // ended, which its attempt waits for before it closes. A child is told
    // to stop, and closes abandoned; a tool call may have reached CYFR, so
    // the runner is not reused.
    fn halt(&self, task: Task) {
        if let Task::Running { task, held, .. } = task {
            task.abort();
            match held {
                Held::Child(child) => child.stop(),
                Held::Call(answered) => {
                    if !answered.load(std::sync::atomic::Ordering::Acquire) {
                        self.host.doubt();
                    }
                }
            }
            self.host.stopping(task);
        }
    }

    // Wait for the task `id` until `deadline`: its result, stopping it if
    // the deadline passes; none for a task it does not hold. The task is
    // forgotten either way.
    async fn take(
        &mut self,
        id: &str,
        deadline: tokio::time::Instant,
    ) -> Option<Result<Result_, Failed>> {
        let task = self.tasks.get_mut(id)?;
        let result = match task {
            Task::Done(result) => std::mem::replace(result, Err(Failed::Killed)),
            Task::Running { result, .. } => match tokio::time::timeout_at(deadline, result).await {
                Ok(Ok(value)) => Ok(value),
                Ok(Err(_)) => Err(Failed::Killed),
                Err(_) => Err(Failed::Timeout),
            },
        };
        let task = self.tasks.remove(id).expect("the task");
        if result == Err(Failed::Timeout) {
            self.halt(task);
        }
        Some(result)
    }
}

impl Drop for Tasks {
    // Nothing of a formula's tasks outlives its store.
    fn drop(&mut self) {
        for (_id, task) in std::mem::take(&mut self.tasks) {
            self.halt(task);
        }
    }
}

/// A task's result, as an await reads it.
enum Classified {
    Completed(Value),
    Errored(Value),
    /// Not a result the runner knows the shape of.
    Unexpected,
}

fn classify(result: &[u8]) -> Classified {
    let Ok(mut json) = read(result) else {
        return Classified::Unexpected;
    };
    let completed = json.value().get("status") == Some(&Value::from("completed"))
        && json.value().get("output").is_some();
    if completed {
        return member(&mut json, "output").map_or(Classified::Unexpected, Classified::Completed);
    }
    member(&mut json, "error").map_or(Classified::Unexpected, Classified::Errored)
}

// A task's result as an await and a poll answer it, under `task_id`; a
// result of no shape the runner knows reads `fallback`.
fn awaited(task_id: &Value, result: &[u8], fallback: &str) -> Value {
    let mut answer = match classify(result) {
        Classified::Completed(output) => json!({"status": "completed", "output": output}),
        Classified::Errored(error) => json!({"status": "error", "error": error}),
        Classified::Unexpected => json!({"status": "error", "error":
            {"type": Kind::Unknown.name(), "message": fallback}}),
    };
    answer["task_id"] = task_id.clone();
    answer
}

// A task's end as await-all and await-any list it.
fn listed(task_id: &Value, result: Result<Result_, Failed>) -> Value {
    match result {
        Ok(result) => awaited(task_id, &result, words::UNEXPECTED_RESULT),
        Err(Failed::Timeout) => json!({"status": "error", "error": {"type": Kind::Timeout.name(),
            "message": words::TASK_TIMED_OUT}, "task_id": task_id}),
        Err(failed) => json!({"status": "error", "error": {"type": Kind::TaskFailed.name(),
            "message": failed.sentence()}, "task_id": task_id}),
    }
}

fn system_time() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| {
            u64::try_from(since.as_micros()).unwrap_or(u64::MAX)
        })
}

// The event of one tool or child call of the formula's.
async fn called(host: &Host, tool_action: &str, ok: bool, started: Instant) {
    host.event(Event {
        name: "mcp_tool.call",
        measurements: vec![("duration_ms", elapsed_ms(started))],
        metadata: vec![
            ("execution_id", Meta::text(host.execution_id())),
            ("tool_action", Meta::text(tool_action)),
            ("status", Meta::text(if ok { "ok" } else { "error" })),
        ],
    })
    .await;
}

fn tool_action(tool: &str, action: &str) -> String {
    if tool.contains(':') {
        "external.call".to_owned()
    } else {
        format!("{tool}.{action}")
    }
}

/// A success's envelope for `output`, already JSON, as bytes of their
/// exact length.
fn success_bytes(output: &[u8]) -> Result_ {
    const HEAD: &[u8] = b"{\"status\":\"completed\",\"output\":";
    let mut bytes = Zeroizing::new(Vec::with_capacity(HEAD.len() + output.len() + 1));
    bytes.extend_from_slice(HEAD);
    bytes.extend_from_slice(output);
    bytes.push(b'}');
    bytes
}

// What a child's answer is to its caller, and whether it succeeded.
fn answered(answer: Option<Answer>) -> (Result_, bool) {
    match answer {
        Some(Answer::Output(output)) => (success_bytes(&output), true),
        Some(Answer::Uncertain(message)) => (to_bytes(&error(Kind::Uncertain, &message)), false),
        Some(Answer::Failed(message)) => (to_bytes(&error(Kind::DispatchError, &message)), false),
        None => (to_bytes(&error(Kind::DispatchError, words::ENDED)), false),
    }
}

// A catalog tool call: its result's envelope, or the guest's refusal; and
// whether it succeeded.
async fn tool_call(
    host: &Host,
    request: Request,
    guest_fn: &str,
    answered: Option<Arc<std::sync::atomic::AtomicBool>>,
) -> wasmtime::Result<(Result_, bool)> {
    let Request {
        tool,
        action,
        mut args,
    } = request;
    args.insert("action".to_owned(), Value::String(action));
    let outcome = host
        .call_watched(
            "tool_call",
            super::args([
                ("args", Value::Object(args)),
                ("guest_fn", Value::String(guest_fn.to_owned())),
                ("name", Value::String(tool)),
            ]),
            answered,
        )
        .await;
    ended("tool_call", &outcome)?;
    Ok(match outcome {
        Outcome::Answered(Reading::Ok(result)) => (success_bytes(&to_bytes(result.value())), true),
        other => (to_bytes(&host_refusal(host, "tool_call", other)), false),
    })
}

impl Guest {
    fn batch_timeout(&self) -> Duration {
        let ms = duration_ms(&self.run.limits.batch_timeout).unwrap_or(0);
        Duration::from_millis(u64::try_from(ms).unwrap_or(0))
    }

    fn intercepted(&self, name: &str) -> bool {
        self.run
            .intercepted
            .iter()
            .any(|intercepted| intercepted == name)
    }

    // A called or streamed child's answer, and whether it succeeded.
    async fn call_child(
        &mut self,
        name: &str,
        arm: Arm,
        args: Map<String, Value>,
    ) -> wasmtime::Result<(String, bool)> {
        let run = self.run.clone();
        let request = match child_request(name, args) {
            Ok(request) => request,
            Err(refusal) => return Ok((text(refused(refusal)), false)),
        };
        let guest_fn = if arm == Arm::Call { "call" } else { "spawn" };
        let start = match admit(&run, request, guest_fn).await {
            Ok(start) => start,
            Err(Unadmitted::Refused(answer)) => return Ok((text(answer), false)),
            Err(Unadmitted::Ended(ended)) => return Err(ended),
        };
        let execution_id = start.assignment.execution_id.clone();
        let stop = Stop::new();
        let tree = run.runner.tree.clone();
        match arm {
            Arm::Call => {
                let (waiter, answer) = tokio::sync::oneshot::channel();
                // The child is stopped if this call is dropped before its
                // answer: its formula stopped, or its store dropped.
                let guard = StopOnDrop::new(stop.clone());
                if let Err((why, start)) = tree
                    .start_child(start, run.runner.clone(), stop, Some(waiter))
                    .await
                {
                    guard.disarm();
                    return Ok((text(unstarted(&run, &start, why).await?), false));
                }
                let answer = answer.await.ok();
                guard.disarm();
                let (bytes, ok) = answered(answer);
                Ok((text_of(bytes), ok))
            }
            Arm::Stream => {
                if let Err((why, start)) = tree
                    .start_child(start, run.runner.clone(), stop, None)
                    .await
                {
                    return Ok((text(unstarted(&run, &start, why).await?), false));
                }
                let streamed = json!({"execution_id": execution_id,
                    "stream_url": format!("/api/executions/{execution_id}/events")});
                Ok((
                    text(json!({"status": "completed", "output": streamed})),
                    true,
                ))
            }
        }
    }

    async fn spawn_child(
        &mut self,
        name: &str,
        args: Map<String, Value>,
    ) -> wasmtime::Result<Value> {
        let run = self.run.clone();
        let request = match child_request(name, args) {
            Ok(request) => request,
            Err(refusal) => return Ok(refused(refusal)),
        };
        self.tasks.refresh();
        if !self.tasks.room(run.limits.max_concurrent_tasks) {
            return Ok(error(Kind::ResourceLimit, words::TASKS_EXCEEDED));
        }
        let start = match admit(&run, request, "spawn").await {
            Ok(start) => start,
            Err(Unadmitted::Refused(answer)) => return Ok(answer),
            Err(Unadmitted::Ended(ended)) => return Err(ended),
        };
        let stop = Stop::new();
        let (waiter, answer) = tokio::sync::oneshot::channel();
        let tree = run.runner.tree.clone();
        let started = tree
            .start_child(start, run.runner.clone(), stop.clone(), Some(waiter))
            .await;
        let task_id = match started {
            Err((why, start)) => {
                let refused = unstarted(&run, &start, why).await?;
                self.tasks.done(Ok(to_bytes(&refused)))
            }
            Ok(()) => {
                let (result, received) = tokio::sync::oneshot::channel();
                let host = run.host.clone();
                let started = Instant::now();
                let task = tokio::spawn(async move {
                    let (answer, ok) = answered(answer.await.ok());
                    called(&host, "execution.run", ok, started).await;
                    let _ = result.send(answer);
                });
                self.tasks.add(received, task, Held::Child(stop))
            }
        };
        spawned(&run.host, &task_id, "execution.run").await;
        Ok(json!({"task_id": task_id}))
    }

    async fn spawn_tool(&mut self, request: Request) -> wasmtime::Result<Value> {
        let run = self.run.clone();
        self.tasks.refresh();
        if !self.tasks.room(run.limits.max_concurrent_tasks) {
            return Ok(error(Kind::ResourceLimit, words::TASKS_EXCEEDED));
        }
        let action = tool_action(&request.tool, &request.action);
        let (result, received) = tokio::sync::oneshot::channel();
        let host = run.host.clone();
        let reported = action.clone();
        let answered = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let came_back = answered.clone();
        let task = tokio::spawn(async move {
            let started = Instant::now();
            let (answer, ok) = match tool_call(&host, request, "spawn", Some(came_back)).await {
                Ok(answered) => answered,
                // CYFR's answer nested past the bound: a task cannot end
                // its formula's run, so it answers as a call that failed.
                Err(_) => (to_bytes(&call_failed()), false),
            };
            called(&host, &reported, ok, started).await;
            let _ = result.send(answer);
        });
        let task_id = self.tasks.add(received, task, Held::Call(answered));
        spawned(&run.host, &task_id, &action).await;
        Ok(json!({"task_id": task_id}))
    }

    // The task ids of an await-all or await-any `request`, each once in
    // the guest's order, or its refusal.
    fn task_ids(&self, request: &str, empty: Option<&'static str>) -> Result<Vec<Value>, Refusal> {
        within_envelope(request, self.run.limits.max_request_size)?;
        let json = document(request)?;
        let Some(Value::Array(ids)) = json.value().get("task_ids") else {
            return Err((Kind::InvalidRequest, words::NO_TASK_IDS.to_owned()));
        };
        let most = self.run.limits.max_concurrent_tasks;
        if ids.len() as u64 > most {
            return Err((Kind::InvalidRequest, words::too_many_task_ids(most)));
        }
        if ids.is_empty()
            && let Some(empty) = empty
        {
            return Err((Kind::InvalidRequest, empty.to_owned()));
        }
        let mut unique: Vec<Value> = Vec::with_capacity(ids.len());
        for id in ids {
            if !unique.contains(id) {
                unique.push(id.clone());
            }
        }
        Ok(unique)
    }
}

async fn spawned(host: &Host, task_id: &str, component_ref: &str) {
    host.event(Event {
        name: "formula.spawn",
        measurements: vec![("system_time", system_time())],
        metadata: vec![
            ("parent_execution_id", Meta::text(host.execution_id())),
            ("task_id", Meta::text(task_id)),
            ("component_ref", Meta::text(component_ref)),
        ],
    })
    .await;
}

fn id_text(id: &Value) -> &str {
    id.as_str().unwrap_or("")
}

impl invoke::Host for Guest {
    async fn call(&mut self, request: String) -> wasmtime::Result<String> {
        let run = self.run.clone();
        let host = run.host.clone();
        let started = Instant::now();
        let request = match requested(&request, run.limits.max_request_size) {
            Ok(request) => request,
            Err(refusal) => {
                called(&host, "unknown", false, started).await;
                return Ok(text(refused(refusal)));
            }
        };
        let name = request.name();
        if self.intercepted(&name) {
            let (answer, ok) = match arm(&name) {
                Some(arm) => self.call_child(&name, arm, request.args).await?,
                None => (
                    text(error(Kind::InvalidRequest, &words::no_dispatch(&name))),
                    false,
                ),
            };
            called(&host, &name, ok, started).await;
            return Ok(answer);
        }
        let action = tool_action(&request.tool, &request.action);
        let (answer, ok) = tool_call(&host, request, "call", None).await?;
        called(&host, &action, ok, started).await;
        Ok(text_of(answer))
    }

    async fn spawn(&mut self, request: String) -> wasmtime::Result<String> {
        let request = match requested(&request, self.run.limits.max_request_size) {
            Ok(request) => request,
            Err(refusal) => return Ok(text(refused(refusal))),
        };
        let name = request.name();
        let answer = if !self.intercepted(&name) {
            self.spawn_tool(request).await?
        } else if name == "execution.run" {
            self.spawn_child(&name, request.args).await?
        } else if name == "execution.run_stream" {
            // A spawn promises a task id, and a streamed child answers at
            // once: there is no async shape for it.
            error(Kind::InvalidRequest, words::RUN_STREAM_SPAWNED)
        } else {
            error(Kind::InvalidRequest, &words::not_spawnable(&name))
        };
        Ok(text(answer))
    }

    async fn await_(&mut self, task_id: String) -> wasmtime::Result<String> {
        let host = self.run.host.clone();
        let started = Instant::now();
        let deadline = tokio::time::Instant::now() + self.batch_timeout();
        self.tasks.refresh();
        let Some(result) = self.tasks.take(&task_id, deadline).await else {
            return Ok(text(error(
                Kind::InvalidRequest,
                &words::unknown_task(&task_id),
            )));
        };
        let duration_ms = elapsed_ms(started);
        let id = Value::String(task_id.clone());
        let (status, answer) = match result {
            Ok(result) => ("completed", awaited(&id, &result, words::UNEXPECTED_FORMAT)),
            Err(Failed::Timeout) => (
                "timeout",
                json!({"status": "error", "error":
                {"type": Kind::Timeout.name(), "message": words::TASK_TIMED_OUT},
                "task_id": task_id, "duration_ms": duration_ms}),
            ),
            Err(failed) => (
                "error",
                json!({"status": "error", "error":
                {"type": Kind::TaskFailed.name(), "message": failed.sentence()},
                "task_id": task_id, "duration_ms": duration_ms}),
            ),
        };
        host.event(Event {
            name: "formula.await",
            measurements: vec![("duration_ms", duration_ms)],
            metadata: vec![
                ("task_id", Meta::text(&task_id)),
                ("status", Meta::text(status)),
            ],
        })
        .await;
        Ok(text(answer))
    }

    async fn await_all(&mut self, request: String) -> wasmtime::Result<String> {
        let ids = match self.task_ids(&request, None) {
            Ok(ids) => ids,
            Err(refusal) => return Ok(text(refused(refusal))),
        };
        if ids.is_empty() {
            return Ok(text(json!({"results": [], "count": 0})));
        }
        let host = self.run.host.clone();
        let started = Instant::now();
        let deadline = tokio::time::Instant::now() + self.batch_timeout();
        self.tasks.refresh();
        let mut results = Vec::with_capacity(ids.len());
        let mut timed_out = 0u64;
        for id in &ids {
            let result = match id.as_str() {
                Some(task_id) => self.tasks.take(task_id, deadline).await,
                None => None,
            };
            let listed = match result {
                Some(result) => {
                    if result == Err(Failed::Timeout) {
                        timed_out += 1;
                    }
                    listed(id, result)
                }
                None => json!({"status": "error", "error": {"type": Kind::TaskFailed.name(),
                    "message": words::UNKNOWN_REASON}, "task_id": id}),
            };
            results.push(listed);
        }
        host.event(Event {
            name: "formula.await_all",
            measurements: vec![("duration_ms", elapsed_ms(started))],
            metadata: vec![
                ("parent_execution_id", Meta::text(host.execution_id())),
                ("count", Meta::Integer(ids.len() as u64)),
                ("timed_out", Meta::Integer(timed_out)),
            ],
        })
        .await;
        Ok(text(json!({"results": results, "count": ids.len()})))
    }

    async fn await_any(&mut self, request: String) -> wasmtime::Result<String> {
        let ids = match self.task_ids(&request, Some(words::EMPTY_TASK_IDS)) {
            Ok(ids) => ids,
            Err(refusal) => return Ok(text(refused(refusal))),
        };
        let host = self.run.host.clone();
        let started = Instant::now();
        let deadline = tokio::time::Instant::now() + self.batch_timeout();
        self.tasks.refresh();
        // The first finished, in the guest's order; else the first of the
        // running to finish before the deadline. The others stay.
        let finished = ids
            .iter()
            .find(|id| matches!(self.tasks.tasks.get(id_text(id)), Some(Task::Done(_))));
        let winner = match finished {
            Some(id) => Some(id.clone()),
            None => {
                let tasks = &mut self.tasks.tasks;
                let mut running: Vec<(&Value, &mut tokio::sync::oneshot::Receiver<Result_>)> =
                    Vec::new();
                for (task_id, task) in tasks.iter_mut() {
                    if let Task::Running { result, .. } = task
                        && let Some(id) = ids.iter().find(|id| id_text(id) == task_id)
                    {
                        running.push((id, result));
                    }
                }
                // The guest's order among those running.
                running.sort_by_key(|(id, _)| ids.iter().position(|other| other == *id));
                if running.is_empty() {
                    None
                } else {
                    let first = std::future::poll_fn(|context| {
                        for (index, (_id, result)) in running.iter_mut().enumerate() {
                            if let std::task::Poll::Ready(value) =
                                std::pin::Pin::new(&mut **result).poll(context)
                            {
                                return std::task::Poll::Ready((index, value.ok()));
                            }
                        }
                        std::task::Poll::Pending
                    });
                    match tokio::time::timeout_at(deadline, first).await {
                        Ok((index, value)) => {
                            let id = running[index].0.clone();
                            drop(running);
                            let done = match value {
                                Some(value) => Ok(value),
                                None => Err(Failed::Killed),
                            };
                            // Its task sent its result last: nothing of it
                            // acts after.
                            tasks.insert(id_text(&id).to_owned(), Task::Done(done));
                            Some(id)
                        }
                        Err(_) => None,
                    }
                }
            }
        };
        let duration_ms = elapsed_ms(started);
        let Some(winner) = winner else {
            host.event(Event {
                name: "formula.await_any",
                measurements: vec![("duration_ms", duration_ms)],
                metadata: vec![
                    ("parent_execution_id", Meta::text(host.execution_id())),
                    ("winner_task_id", Meta::Null),
                ],
            })
            .await;
            return Ok(text(
                json!({"status": "error", "error": {"type": Kind::Timeout.name(),
                "message": words::ALL_TIMED_OUT}, "pending": ids}),
            ));
        };
        let result = self
            .tasks
            .take(id_text(&winner), deadline)
            .await
            .unwrap_or(Err(Failed::Killed));
        let pending: Vec<Value> = ids.iter().filter(|id| **id != winner).cloned().collect();
        host.event(Event {
            name: "formula.await_any",
            measurements: vec![("duration_ms", duration_ms)],
            metadata: vec![
                ("parent_execution_id", Meta::text(host.execution_id())),
                ("winner_task_id", Meta::text(id_text(&winner))),
            ],
        })
        .await;
        Ok(text(
            json!({"result": listed(&winner, result), "task_id": winner,
            "pending": pending}),
        ))
    }

    async fn poll(&mut self, task_id: String) -> wasmtime::Result<String> {
        self.tasks.refresh();
        let id = Value::String(task_id.clone());
        let answer = match self.tasks.tasks.get(&task_id) {
            None => error(Kind::InvalidRequest, &words::unknown_task(&task_id)),
            Some(Task::Running { .. }) => json!({"status": "pending"}),
            Some(Task::Done(Ok(result))) => awaited(&id, result, words::UNEXPECTED_FORMAT),
            Some(Task::Done(Err(failed))) => json!({"status": "error", "error":
                {"type": Kind::TaskFailed.name(), "message": failed.sentence()},
                "task_id": task_id}),
        };
        Ok(text(answer))
    }

    async fn cancel(&mut self, task_id: String) -> wasmtime::Result<String> {
        self.tasks.refresh();
        let answer = match self.tasks.tasks.get(&task_id) {
            None => error(Kind::InvalidRequest, &words::unknown_task(&task_id)),
            Some(Task::Done(_)) => error(Kind::InvalidRequest, &words::already_completed(&task_id)),
            Some(Task::Running { .. }) => {
                let task = self
                    .tasks
                    .tasks
                    .insert(task_id.clone(), Task::Done(Err(Failed::Cancelled)))
                    .expect("the task");
                self.tasks.halt(task);
                let host = self.run.host.clone();
                host.event(Event {
                    name: "formula.cancel",
                    measurements: vec![("system_time", system_time())],
                    metadata: vec![
                        ("parent_execution_id", Meta::text(host.execution_id())),
                        ("task_id", Meta::text(&task_id)),
                    ],
                })
                .await;
                json!({"cancelled": true, "task_id": task_id})
            }
        };
        Ok(text(answer))
    }

    async fn emit(&mut self, event: String) -> wasmtime::Result<String> {
        super::emit::emit(&self.run, event).await
    }
}
