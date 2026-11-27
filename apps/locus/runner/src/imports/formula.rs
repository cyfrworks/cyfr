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
//! and a JSON object, and the relay carries its attempt. An admission
//! failing any of these is given back (`release_child`, once) and its
//! guest answered as a call that failed; one that does not read at all
//! names no child to give back. A lost admission is asked again under the
//! same `child_key`, so CYFR admits one child however its answer is lost.
//!
//! **Tasks** (`spawn`, then `await`, `await-all`, `await-any`, `poll`,
//! `cancel`) are a formula's own, numbered `task_1` on, at most the node's
//! `max_concurrent_tasks` held at once, a finished task's result counted
//! until it is awaited. A task is a spawned child, admitted before it takes
//! a task, or a spawned tool call. Awaits wait at most the node's
//! `batch_timeout`; a task an await gives up on, and a task cancelled, is
//! stopped. When the formula's store is dropped (its run ended, however),
//! every task still running is stopped: a child closes `abandoned`, and a
//! tool call is dropped, its answer discarded by the relay when it comes.
//! A called child is stopped likewise when its call is dropped.
//!
//! Every answer is a JSON object: a success, or the error envelope of
//! `tests/fixtures/guest_error.json` with one of its `invoke_types`; a
//! refusal CYFR renders for the guest (a setup refusal with its
//! `remediation`) is handed on as it is.

use std::collections::BTreeMap;
use std::future::Future as _;
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
use crate::wire::{Json, Unread, read};
use crate::words;

/// Every error type the runner itself answers a formula's invoke with,
/// held to `tests/fixtures/guest_error.json`'s `invoke_types`; a refusal
/// CYFR renders for the guest carries CYFR's own.
pub const TYPES: [&str; 9] = [
    "invalid_json",
    "invalid_request",
    "request_too_large",
    "resource_limit",
    "dispatch_error",
    "uncertain",
    "timeout",
    "task_failed",
    "unknown",
];

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
type Refusal = (&'static str, String);

/// The error envelope of `kind` and `message`, as a JSON value.
fn error(kind: &str, message: &str) -> Value {
    json!({"error": {"type": kind, "message": message}})
}

fn refused((kind, message): Refusal) -> Value {
    error(kind, &message)
}

fn success(output: Value) -> Value {
    json!({"status": "completed", "output": output})
}

// What a guest is answered, as text.
fn text(answer: Value) -> String {
    answer.to_string()
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
        return Err(("request_too_large", words::INVOKE_TOO_LARGE.to_owned()));
    }
    Ok(())
}

// A document of the guest's, depth-counted before it is parsed.
fn document(request: &str) -> Result<Json, Refusal> {
    match read(request.as_bytes()) {
        Ok(json) => Ok(json),
        Err(Unread::TooDeep) => Err(("invalid_json", words::request_too_deep())),
        Err(Unread::Malformed) => Err(("invalid_json", words::REQUEST_NOT_JSON.to_owned())),
    }
}

fn requested(request: &str, max_request_size: u64) -> Result<Request, Refusal> {
    within_envelope(request, max_request_size)?;
    let mut json = document(request)?;
    let Value::Object(members) = json.value() else {
        return Err(("invalid_request", words::NO_TOOL_OR_ACTION.to_owned()));
    };
    let (Some(Value::String(tool)), Some(Value::String(action))) =
        (members.get("tool"), members.get("action"))
    else {
        return Err(("invalid_request", words::NO_TOOL_OR_ACTION.to_owned()));
    };
    let (tool, action) = (tool.clone(), action.clone());
    let args = match json.take_member("args") {
        None => Map::new(),
        Some(mut args) => match args.take_value() {
            Value::Object(args) => args,
            _ => return Err(("invalid_request", words::ARGS_NOT_MAP.to_owned())),
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
        _ => return Err(("invalid_request", words::no_reference(name))),
    };
    let connection = match args.remove("connection") {
        None | Some(Value::Null) => None,
        Some(Value::String(connection)) => Some(connection),
        Some(_) => return Err(("invalid_request", words::connection_not_name(name))),
    };
    let input = match args.remove("input") {
        // Absent, null or false reads as no input, as the runner before.
        None | Some(Value::Null) | Some(Value::Bool(false)) => Map::new(),
        Some(Value::Object(input)) => input,
        Some(_) => return Err(("invalid_request", words::input_not_object(name))),
    };
    Ok(ChildRequest {
        reference,
        need: args.remove("need").unwrap_or(Value::Null),
        connection,
        input,
    })
}

/// A child CYFR admitted, read and checked, ready to start.
struct Admitted {
    start: Start,
}

/// Why a child is not admitted: the guest's answer, or the run's end.
enum Unadmitted {
    Refused(Value),
    Ended(wasmtime::Error),
}

// A refusal of a host call, as the guest is answered it.
fn host_refusal(host: &Host, op: &str, outcome: Outcome) -> Value {
    match outcome {
        Outcome::Answered(Reading::GuestError {
            kind,
            message,
            remediation,
        }) => match remediation {
            Some(mut remediation) => json!({"error": {"type": kind.as_str(),
                "message": message.as_str(), "remediation": remediation.take_value()}}),
            None => error(&kind, &message),
        },
        Outcome::Uncertain => error("uncertain", words::UNCERTAIN),
        _ => {
            host.note("a host call refused in no words of its own", || {
                format!("{}'s {op} was refused or not answered", host.execution_id())
            });
            error("dispatch_error", words::CALL_FAILED)
        }
    }
}

// Ask CYFR to admit the child `request` names, made with `guest_fn`, and
// check what it answers.
async fn admit(run: &Run, request: ChildRequest, guest_fn: &str) -> Result<Admitted, Unadmitted> {
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
        other => return Err(Unadmitted::Refused(host_refusal(host, "admit_child", other))),
    };
    let lost = || Unadmitted::Refused(error("dispatch_error", words::CALL_FAILED));
    let token = match answer.take_member("assignment").map(|mut json| json.take_value()) {
        Some(Value::String(token)) => Zeroizing::new(token),
        _ => return Err(lost()),
    };
    let sealed = match answer.take_member("attempt_keys").map(|mut json| json.take_value()) {
        Some(Value::String(sealed)) => Zeroizing::new(sealed),
        _ => return Err(lost()),
    };
    let input = match answer.take_member("input").map(|mut json| json.take_value()) {
        Some(Value::String(input)) => Zeroizing::new(input),
        _ => return Err(lost()),
    };
    let secrets = match answer.take_member("secrets").map(|mut json| json.take_value()) {
        Some(Value::Object(secrets)) => Json::from_value(Value::Object(secrets)),
        _ => return Err(lost()),
    };
    let Ok(assignment) = crate::assignment::read(&token) else {
        return Err(lost());
    };
    // Admitted for this runner but not startable by it: given back at
    // once, rather than left to its lease.
    let checked = checked(run, &assignment, &sealed, &input).await;
    let Some((keys, input)) = checked else {
        host.note("a child admitted that does not run here", || {
            format!(
                "the child {} admitted for {} does not run here; given back",
                assignment.execution_id,
                host.execution_id()
            )
        });
        let released = host
            .call(
                "release_child",
                args([("execution_id", Value::String(assignment.execution_id.clone()))]),
            )
            .await;
        ended("release_child", &released).map_err(Unadmitted::Ended)?;
        return Err(lost());
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
    Ok(Admitted {
        start: Start {
            token,
            assignment,
            input,
            keys,
            admitted: Some(admitted),
        },
    })
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
    let input = read(input.as_bytes()).ok().filter(|input| input.value().is_object())?;
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

// A child CYFR admitted that the runner does not start: its attempt is
// closed failed under its own keys, which gives back what it holds; the
// sentence CYFR recorded, or what the runner knows.
async fn unstarted(run: &Run, start: &Start, why: Unstarted) -> String {
    if why == Unstarted::Ending {
        return words::ENDED.to_owned();
    }
    run.host.note("a child not started", || {
        format!(
            "the child {} was not started: its execution is one this subtree runs",
            start.assignment.execution_id
        )
    });
    let recorded = crate::attempt::refuse(start, &run.runner, words::CHILD_UNSTARTED).await;
    recorded.unwrap_or_else(|| {
        run.runner.tree.doubt();
        words::ENDED.to_owned()
    })
}

/// A formula's tasks.
pub struct Tasks {
    next: u64,
    tasks: BTreeMap<String, Task>,
}

enum Task {
    Running {
        result: tokio::sync::oneshot::Receiver<Value>,
        abort: tokio::task::AbortHandle,
        child: Option<Stop>,
    },
    Done(Result<Value, Failed>),
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

impl Task {
    fn stop(&self) {
        if let Task::Running { abort, child, .. } = self {
            abort.abort();
            if let Some(child) = child {
                child.stop();
            }
        }
    }
}

impl Tasks {
    pub fn new() -> Tasks {
        Tasks {
            next: 1,
            tasks: BTreeMap::new(),
        }
    }

    // Record each running task whose result has arrived.
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

    fn add(&mut self, result: tokio::sync::oneshot::Receiver<Value>, abort: tokio::task::AbortHandle, child: Option<Stop>) -> String {
        let id = format!("task_{}", self.next);
        self.next += 1;
        self.tasks
            .insert(id.clone(), Task::Running { result, abort, child });
        id
    }

    fn done(&mut self, result: Result<Value, Failed>) -> String {
        let id = format!("task_{}", self.next);
        self.next += 1;
        self.tasks.insert(id.clone(), Task::Done(result));
        id
    }

    // Wait for the task `id` until `deadline`: its result, stopping it if
    // the deadline passes; none for a task it does not hold. The task is
    // forgotten either way.
    async fn take(&mut self, id: &str, deadline: tokio::time::Instant) -> Option<Result<Value, Failed>> {
        let task = self.tasks.get_mut(id)?;
        let result = match task {
            Task::Done(result) => std::mem::replace(result, Err(Failed::Killed)),
            Task::Running { result, .. } => match tokio::time::timeout_at(deadline, result).await {
                Ok(Ok(value)) => Ok(value),
                Ok(Err(_)) => Err(Failed::Killed),
                Err(_) => {
                    task.stop();
                    Err(Failed::Timeout)
                }
            },
        };
        self.tasks.remove(id);
        Some(result)
    }
}

impl Default for Tasks {
    fn default() -> Tasks {
        Tasks::new()
    }
}

impl Drop for Tasks {
    // Nothing of a formula's tasks outlives its store.
    fn drop(&mut self) {
        for task in self.tasks.values() {
            task.stop();
        }
    }
}

// A task's result as an await answers it, under `task_id`.
fn awaited(task_id: &Value, result: Value) -> Value {
    let mut answer = match result {
        Value::Object(mut result) => {
            let completed = result.get("status") == Some(&Value::from("completed"))
                && result.contains_key("output");
            match (completed, result.remove("output"), result.remove("error")) {
                (true, Some(output), _) => json!({"status": "completed", "output": output}),
                (false, _, Some(error)) => json!({"status": "error", "error": error}),
                _ => json!({"status": "error", "error": {"type": "unknown",
                    "message": words::UNEXPECTED_FORMAT}}),
            }
        }
        _ => json!({"status": "error", "error": {"type": "unknown",
            "message": words::UNEXPECTED_FORMAT}}),
    };
    answer["task_id"] = task_id.clone();
    answer
}

// A task's result as await-all and await-any list it.
fn listed(task_id: &Value, result: Result<Value, Failed>) -> Value {
    match result {
        Ok(result) => {
            let mut answer = awaited(task_id, result);
            if answer["error"]["message"] == words::UNEXPECTED_FORMAT {
                answer["error"]["message"] = Value::from(words::UNEXPECTED_RESULT);
            }
            answer
        }
        Err(Failed::Timeout) => json!({"status": "error", "error": {"type": "timeout",
            "message": words::TASK_TIMED_OUT}, "task_id": task_id}),
        Err(failed) => json!({"status": "error", "error": {"type": "task_failed",
            "message": failed.sentence()}, "task_id": task_id}),
    }
}

fn system_time() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_micros()).unwrap_or(u64::MAX))
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

// What a child's answer is to its caller.
fn answered(answer: Option<Answer>) -> Value {
    match answer {
        Some(Answer::Output(mut output)) => success(output.take_value()),
        Some(Answer::Uncertain(message)) => error("uncertain", &message),
        Some(Answer::Failed(message)) => error("dispatch_error", &message),
        None => error("dispatch_error", words::ENDED),
    }
}

// A catalog tool call: its result, or the guest's refusal; and whether it
// succeeded.
async fn tool_call(host: &Host, request: Request, guest_fn: &str) -> wasmtime::Result<(Value, bool)> {
    let Request { tool, action, mut args } = request;
    args.insert("action".to_owned(), Value::String(action));
    let outcome = host
        .call(
            "tool_call",
            super::args([
                ("args", Value::Object(args)),
                ("guest_fn", Value::String(guest_fn.to_owned())),
                ("name", Value::String(tool)),
            ]),
        )
        .await;
    ended("tool_call", &outcome)?;
    Ok(match outcome {
        Outcome::Answered(Reading::Ok(mut result)) => (success(result.take_value()), true),
        other => (host_refusal(host, "tool_call", other), false),
    })
}

impl Guest {
    fn batch_timeout(&self) -> Duration {
        let ms = duration_ms(&self.run.limits.batch_timeout).unwrap_or(0);
        Duration::from_millis(u64::try_from(ms).unwrap_or(0))
    }

    fn intercepted(&self, name: &str) -> bool {
        self.run.intercepted.iter().any(|intercepted| intercepted == name)
    }

    async fn call_child(&mut self, name: &str, arm: Arm, args: Map<String, Value>) -> wasmtime::Result<Value> {
        let run = self.run.clone();
        let request = match child_request(name, args) {
            Ok(request) => request,
            Err(refusal) => return Ok(refused(refusal)),
        };
        let guest_fn = if arm == Arm::Call { "call" } else { "spawn" };
        let admitted = match admit(&run, request, guest_fn).await {
            Ok(admitted) => admitted,
            Err(Unadmitted::Refused(answer)) => return Ok(answer),
            Err(Unadmitted::Ended(ended)) => return Err(ended),
        };
        let execution_id = admitted.start.assignment.execution_id.clone();
        let stop = Stop::new();
        match arm {
            Arm::Call => {
                let (waiter, answer) = tokio::sync::oneshot::channel();
                // The child is stopped if this call is dropped before its
                // answer: its formula stopped, or its store dropped.
                let guard = StopOnDrop::new(stop.clone());
                let tree = run.runner.tree.clone();
                if let Err((why, start)) =
                    tree.start_child(admitted.start, run.runner.clone(), stop, Some(waiter)).await
                {
                    guard.disarm();
                    let message = unstarted(&run, &start, why).await;
                    return Ok(error("dispatch_error", &message));
                }
                let answer = answer.await.ok();
                guard.disarm();
                Ok(answered(answer))
            }
            Arm::Stream => {
                let tree = run.runner.tree.clone();
                if let Err((why, start)) =
                    tree.start_child(admitted.start, run.runner.clone(), stop, None).await
                {
                    let message = unstarted(&run, &start, why).await;
                    return Ok(error("dispatch_error", &message));
                }
                Ok(success(json!({"execution_id": execution_id,
                    "stream_url": format!("/api/executions/{execution_id}/events")})))
            }
        }
    }

    async fn spawn_child(&mut self, name: &str, args: Map<String, Value>) -> wasmtime::Result<Value> {
        let run = self.run.clone();
        let request = match child_request(name, args) {
            Ok(request) => request,
            Err(refusal) => return Ok(refused(refusal)),
        };
        self.tasks.refresh();
        if !self.tasks.room(run.limits.max_concurrent_tasks) {
            return Ok(error("resource_limit", words::TASKS_EXCEEDED));
        }
        let admitted = match admit(&run, request, "spawn").await {
            Ok(admitted) => admitted,
            Err(Unadmitted::Refused(answer)) => return Ok(answer),
            Err(Unadmitted::Ended(ended)) => return Err(ended),
        };
        let stop = Stop::new();
        let (waiter, answer) = tokio::sync::oneshot::channel();
        let tree = run.runner.tree.clone();
        let started = tree
            .start_child(admitted.start, run.runner.clone(), stop.clone(), Some(waiter))
            .await;
        let task_id = match started {
            Err((why, start)) => {
                let message = unstarted(&run, &start, why).await;
                self.tasks.done(Ok(error("dispatch_error", &message)))
            }
            Ok(()) => {
                let (result, received) = tokio::sync::oneshot::channel();
                let host = run.host.clone();
                let started = Instant::now();
                let task = tokio::spawn(async move {
                    let answer = answered(answer.await.ok());
                    called(&host, "execution.run", answer.get("error").is_none(), started).await;
                    let _ = result.send(answer);
                });
                self.tasks.add(received, task.abort_handle(), Some(stop))
            }
        };
        spawned(&run.host, &task_id, "execution.run").await;
        Ok(json!({"task_id": task_id}))
    }

    async fn spawn_tool(&mut self, request: Request) -> wasmtime::Result<Value> {
        let run = self.run.clone();
        self.tasks.refresh();
        if !self.tasks.room(run.limits.max_concurrent_tasks) {
            return Ok(error("resource_limit", words::TASKS_EXCEEDED));
        }
        let action = tool_action(&request.tool, &request.action);
        let (result, received) = tokio::sync::oneshot::channel();
        let host = run.host.clone();
        let reported = action.clone();
        let task = tokio::spawn(async move {
            let started = Instant::now();
            let (answer, ok) = match tool_call(&host, request, "spawn").await {
                Ok(answered) => answered,
                // CYFR's answer nested past the bound: a task cannot end
                // its formula's run, so it answers as a call that failed.
                Err(_) => (error("dispatch_error", words::CALL_FAILED), false),
            };
            called(&host, &reported, ok, started).await;
            let _ = result.send(answer);
        });
        let task_id = self.tasks.add(received, task.abort_handle(), None);
        spawned(&run.host, &task_id, &action).await;
        Ok(json!({"task_id": task_id}))
    }

    // The task ids of an await-all or await-any `request`, each once in
    // the guest's order, or its refusal.
    fn task_ids(&self, request: &str, empty: Option<&'static str>) -> Result<Vec<Value>, Refusal> {
        within_envelope(request, self.run.limits.max_request_size)?;
        let json = document(request)?;
        let Some(Value::Array(ids)) = json.value().get("task_ids") else {
            return Err(("invalid_request", words::NO_TASK_IDS.to_owned()));
        };
        let most = self.run.limits.max_concurrent_tasks;
        if ids.len() as u64 > most {
            return Err(("invalid_request", words::too_many_task_ids(most)));
        }
        if ids.is_empty()
            && let Some(empty) = empty
        {
            return Err(("invalid_request", empty.to_owned()));
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
            let answer = match arm(&name) {
                Some(arm) => self.call_child(&name, arm, request.args).await?,
                None => error("invalid_request", &words::no_dispatch(&name)),
            };
            called(&host, &name, answer.get("error").is_none(), started).await;
            return Ok(text(answer));
        }
        let action = tool_action(&request.tool, &request.action);
        let (answer, ok) = tool_call(&host, request, "call").await?;
        called(&host, &action, ok, started).await;
        Ok(text(answer))
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
            error("invalid_request", words::RUN_STREAM_SPAWNED)
        } else {
            error("invalid_request", &words::not_spawnable(&name))
        };
        Ok(text(answer))
    }

    async fn await_(&mut self, task_id: String) -> wasmtime::Result<String> {
        let host = self.run.host.clone();
        let started = Instant::now();
        let deadline = tokio::time::Instant::now() + self.batch_timeout();
        self.tasks.refresh();
        let Some(result) = self.tasks.take(&task_id, deadline).await else {
            return Ok(text(error("invalid_request", &words::unknown_task(&task_id))));
        };
        let duration_ms = elapsed_ms(started);
        let id = Value::String(task_id.clone());
        let (status, answer) = match result {
            Ok(result) => ("completed", awaited(&id, result)),
            Err(Failed::Timeout) => ("timeout", json!({"status": "error", "error":
                {"type": "timeout", "message": words::TASK_TIMED_OUT},
                "task_id": task_id, "duration_ms": duration_ms})),
            Err(failed) => ("error", json!({"status": "error", "error":
                {"type": "task_failed", "message": failed.sentence()},
                "task_id": task_id, "duration_ms": duration_ms})),
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
                None => json!({"status": "error", "error": {"type": "task_failed",
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
        let finished = ids.iter().find(|id| {
            matches!(self.tasks.tasks.get(id_text(id)), Some(Task::Done(_)))
        });
        let winner = match finished {
            Some(id) => Some(id.clone()),
            None => {
                let tasks = &mut self.tasks.tasks;
                let mut running: Vec<(&Value, &mut tokio::sync::oneshot::Receiver<Value>)> =
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
            return Ok(text(json!({"status": "error", "error": {"type": "timeout",
                "message": words::ALL_TIMED_OUT}, "pending": ids})));
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
        Ok(text(json!({"result": listed(&winner, result), "task_id": winner,
            "pending": pending})))
    }

    async fn poll(&mut self, task_id: String) -> wasmtime::Result<String> {
        self.tasks.refresh();
        let id = Value::String(task_id.clone());
        let answer = match self.tasks.tasks.get(&task_id) {
            None => error("invalid_request", &words::unknown_task(&task_id)),
            Some(Task::Running { .. }) => json!({"status": "pending"}),
            Some(Task::Done(Ok(result))) => awaited(&id, result.clone()),
            Some(Task::Done(Err(failed))) => json!({"status": "error", "error":
                {"type": "task_failed", "message": failed.sentence()}, "task_id": task_id}),
        };
        Ok(text(answer))
    }

    async fn cancel(&mut self, task_id: String) -> wasmtime::Result<String> {
        self.tasks.refresh();
        let answer = match self.tasks.tasks.get_mut(&task_id) {
            None => error("invalid_request", &words::unknown_task(&task_id)),
            Some(Task::Done(_)) => error("invalid_request", &words::already_completed(&task_id)),
            Some(task) => {
                task.stop();
                *task = Task::Done(Err(Failed::Cancelled));
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
