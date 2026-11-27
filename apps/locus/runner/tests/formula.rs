// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! A formula's invoke, its children and the runner's reuse, against the
//! real binary and a scripted service end (`support`). The formula is
//! `formula_probe`, which makes the invoke calls its input lists and
//! answers every answer; its children are the suite's guests.

mod support;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use cyfr_runner::control;
use cyfr_runner::words;
use support::{HOSTILE, Job, Reply, Service, TEST_WASM, Upstream, standard};

const SOON: Duration = Duration::from_secs(60);

const PROBE: &str = "apps/locus/test/support/runtime/test_wasm/formula_probe/formula_probe.wasm";

/// A formula whose input is `steps`, each `[fn, arg]`, its host
/// intercepting both child actions.
fn formula(steps: &[(&str, Value)]) -> Job {
    let steps: Vec<Value> = steps
        .iter()
        .map(|(name, arg)| json!({"fn": name, "arg": arg}))
        .collect();
    let mut job = Job::new("formula", PROBE, &json!({ "steps": steps }).to_string())
        .bound(json!({"max_concurrent_tasks": 4, "batch_timeout": "30s"}));
    job.intercepted = vec![
        "execution.run".to_owned(),
        "execution.run_stream".to_owned(),
    ];
    job
}

/// A request to run `reference` as a child on `input`.
fn run(action: &str, reference: &str, input: Value) -> Value {
    json!({"tool": "execution", "action": action,
           "args": {"reference": reference, "input": input}})
}

fn echo(formula: &Job, input: &str) -> Job {
    formula.child("reagent", &format!("{TEST_WASM}/echo.wasm"), input)
}

fn spin(formula: &Job, timeout_ms: u64) -> Job {
    let mut child = formula.child("reagent", &format!("{TEST_WASM}/spin.wasm"), "{}");
    child.timeout_ms = timeout_ms;
    child
}

/// CYFR's answers, each `admit_child` answered with the next of `children`
/// admitted, and `egress_pin` with a pin of `api.example.test`.
fn admitting(children: Vec<Job>) -> support::Script {
    let children = Arc::new(Mutex::new(VecDeque::from(children)));
    Box::new(move |call, job| match call.op.as_str() {
        "admit_child" => match children.lock().expect("the children").pop_front() {
            Some(child) => Reply::Ok(job.admitted(&child)),
            None => Reply::Error(
                "guest_error",
                json!({"type": "dispatch_error",
                                                       "message": "no child scripted"}),
            ),
        },
        "egress_pin" => support::pin("pin_1", "https", "api.example.test"),
        "release_child" | "tool_call" => Reply::Ok(json!(true)),
        _ => standard(call, job),
    })
}

/// What a subtree came to: its last frame (`complete` or `exit`), the
/// `child` frames before it and the events.
struct Ended {
    last: Value,
    children: Vec<Value>,
    events: Vec<Value>,
}

fn ended(service: &Service, within: Duration) -> Ended {
    let (mut children, mut events) = (Vec::new(), Vec::new());
    loop {
        let line = service.line(within);
        match line["type"].as_str() {
            Some("event") => events.push(line),
            Some("child") => children.push(line),
            _ => {
                return Ended {
                    last: line,
                    children,
                    events,
                };
            }
        }
    }
}

/// The calls of `op` the attempt `job` made.
fn calls(service: &Service, op: &str, job: &Job) -> Vec<support::Call> {
    service
        .calls_of(op)
        .into_iter()
        .filter(|call| call.attempt == job.attempt)
        .collect()
}

/// The formula's answers, as its close recorded them.
fn answers(service: &Service, formula: &Job) -> Vec<Value> {
    let close = calls(service, "complete", formula);
    assert_eq!(
        close.len(),
        1,
        "one close of the formula: {:?}",
        service.ops()
    );
    close[0].args["outcome"]["output"]["answers"]
        .as_array()
        .expect("the probe's answers")
        .clone()
}

fn error(kind: &str, message: &str) -> Value {
    json!({"error": {"type": kind, "message": message}})
}

#[test]
fn a_called_child_runs_in_its_formulas_runner_announced_before_it_runs() {
    let mut service = Service::start();
    let mut job = formula(&[(
        "call",
        run("run", "reagent:local.echo:0.1.0", json!({"n": 1})),
    )]);
    job.timeout_ms = 60_000;
    let child = echo(&job, r#"{"n":1}"#);
    service.assign(&job, admitting(vec![child.clone()]));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    assert_eq!(ended.last["clean"], json!(true), "{}", ended.last);
    assert_eq!(
        ended.children,
        [
            json!({"v": 1, "type": "child", "execution_id": child.execution_id,
                "attempt": child.attempt})
        ]
    );
    assert_eq!(
        answers(&service, &job),
        [json!({"status": "completed", "output": {"n": 1}})]
    );
    // The child is claimed at its admission: it does not attach, fetches its
    // own component under its own keys and closes under them.
    assert!(calls(&service, "attach", &child).is_empty());
    assert_eq!(calls(&service, "fetch_artifact", &child).len(), 1);
    assert_eq!(calls(&service, "complete", &child).len(), 1);
    let admit = calls(&service, "admit_child", &job);
    assert_eq!(admit[0].args["guest_fn"], "call");
    assert_eq!(admit[0].args["reference"], "reagent:local.echo:0.1.0");
    assert_eq!(admit[0].args["input"], json!({"n": 1}));
    let called: Vec<&Value> = ended
        .events
        .iter()
        .filter(|event| event["name"] == "mcp_tool.call")
        .collect();
    assert_eq!(called.len(), 1, "{:?}", ended.events);
    assert_eq!(called[0]["metadata"]["tool_action"], "execution.run");
    assert_eq!(called[0]["metadata"]["status"], "ok");
}

#[test]
fn an_admission_whose_answer_is_lost_is_asked_again_under_its_key_and_yields_one_child() {
    let mut service = Service::start();
    let job = formula(&[("call", run("run", "reagent:local.echo:0.1.0", json!({})))]);
    let child = echo(&job, "{}");
    let mut admitted = admitting(vec![child.clone()]);
    let mut asked = 0;
    service.assign(
        &job,
        Box::new(move |call, job| {
            if call.op == "admit_child" {
                asked += 1;
                if asked == 1 {
                    // CYFR admitted it; its answer is lost on the way.
                    let _ = admitted(call, job);
                    return Reply::Dropped;
                }
                return Reply::Ok(job.admitted(&child_of(job)));
            }
            admitted(call, job)
        }),
    );
    fn child_of(job: &Job) -> Job {
        job.family.lock().expect("the family")[0].clone()
    }
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    let admits = calls(&service, "admit_child", &job);
    assert_eq!(admits.len(), 2, "{:?}", service.ops());
    assert_eq!(
        admits[0].args, admits[1].args,
        "the same child key both times"
    );
    assert_eq!(ended.children.len(), 1, "{:?}", ended.children);
    assert_eq!(ended.children[0]["execution_id"], json!(child.execution_id));
    assert_eq!(
        answers(&service, &job),
        [json!({"status": "completed", "output": {}})]
    );
}

/// An admission whose answer `spoil` changes for `child`: the guest is
/// answered as a call that failed, the child is given back once, and
/// nothing of it runs.
fn refused_admission(name: &str, child: Job, spoil: fn(&mut Value, &Job, &Job)) {
    let mut service = Service::start();
    let job = formula(&[("call", run("run", "reagent:local.echo:0.1.0", json!({})))]);
    let given = child.clone();
    service.assign(
        &job,
        Box::new(move |call, job| match call.op.as_str() {
            "admit_child" => {
                let mut answer = job.admitted(&given);
                spoil(&mut answer, job, &given);
                Reply::Ok(answer)
            }
            "release_child" => Reply::Ok(json!(true)),
            _ => standard(call, job),
        }),
    );
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{name}: {}", ended.last);
    assert_eq!(
        answers(&service, &job),
        [error("dispatch_error", words::CALL_FAILED)],
        "{name}"
    );
    let released = calls(&service, "release_child", &job);
    assert_eq!(released.len(), 1, "{name}: {:?}", service.ops());
    assert_eq!(
        released[0].args,
        json!({"execution_id": child.execution_id}),
        "{name}"
    );
    assert!(ended.children.is_empty(), "{name}: {:?}", ended.children);
    assert!(
        service
            .calls
            .lock()
            .expect("the calls")
            .iter()
            .all(|call| call.attempt != child.attempt),
        "{name}: nothing of the child runs"
    );
}

#[test]
fn an_admission_whose_keys_do_not_open_is_given_back() {
    let formula = formula(&[]);
    refused_admission("keys", echo(&formula, "{}"), |answer, _job, child| {
        // Sealed under a key that is not the formula's.
        answer["attempt_keys"] = json!(support::sealed_attempt_keys(
            &support::random_key(),
            &child.keys()
        ));
    });
}

#[test]
fn an_admission_whose_keys_name_another_attempt_is_given_back() {
    let formula = formula(&[]);
    let mut child = echo(&formula, "{}");
    let mut other = child.attempt();
    other.attempt = "att_test-another".to_owned();
    child.keys_attempt = Some(other);
    refused_admission("attempt", child, |_answer, _job, _child| {});
}

#[test]
fn an_admission_naming_another_service_is_given_back() {
    let formula = formula(&[]);
    let mut child = echo(&formula, "{}");
    child.service = "wrk_anotherservice".to_owned();
    refused_admission("service", child, |_answer, _job, _child| {});
}

#[test]
fn an_admission_naming_another_boot_is_given_back() {
    let formula = formula(&[]);
    let mut child = echo(&formula, "{}");
    child.boot = "boot_test-another".to_owned();
    refused_admission("boot", child, |_answer, _job, _child| {});
}

#[test]
fn an_admission_naming_another_member_is_given_back() {
    let formula = formula(&[]);
    let mut child = echo(&formula, "{}");
    child.member = "cyfr@127.0.0.2#boot_test-member".to_owned();
    refused_admission("member", child, |_answer, _job, _child| {});
}

#[test]
fn an_admission_naming_another_athanor_is_given_back() {
    let formula = formula(&[]);
    let mut child = echo(&formula, "{}");
    child.athanor = "ath_test-another".to_owned();
    refused_admission("athanor", child, |_answer, _job, _child| {});
}

#[test]
fn an_admission_whose_input_is_not_its_digests_is_given_back() {
    let formula = formula(&[]);
    refused_admission("digest", echo(&formula, "{}"), |answer, _job, _child| {
        answer["input"] = json!(r#"{"other":true}"#);
    });
}

#[test]
fn an_admission_whose_input_is_no_object_is_given_back() {
    let formula = formula(&[]);
    // Its digest is the input's own: only its shape is refused.
    refused_admission("object", echo(&formula, "[1]"), |_answer, _job, _child| {});
}

#[test]
fn a_cancelled_child_with_a_fetch_outstanding_closes_abandoned_and_its_sibling_completes() {
    let mut service = Service::start();
    let job = formula(&[
        (
            "spawn",
            run("run", "catalyst:local.fetcher:0.1.0", json!({})),
        ),
        (
            "spawn",
            run("run", "reagent:local.echo:0.1.0", json!({"sibling": true})),
        ),
        ("await", json!("task_2")),
        ("await", json!("task_1")),
    ]);
    let request = json!({"method": "GET", "url": "https://api.example.test/slow"});
    let fetcher = job.child(
        "catalyst",
        &format!("{HOSTILE}/attached_header_probe.wasm"),
        &request.to_string(),
    );
    let sibling = echo(&job, r#"{"sibling":true}"#);
    let piece = 64 * 1024;
    let (fetched_tx, fetched) = std::sync::mpsc::channel::<()>();
    let fetched_tx = Mutex::new(fetched_tx);
    service.assign_fetching(
        &job,
        admitting(vec![fetcher.clone(), sibling.clone()]),
        Box::new(move |_fetch, _job| {
            let _ = fetched_tx.lock().expect("the signal").send(());
            // Part of the answer, and its end never: the fetch stays open.
            vec![Upstream::Head(200, Vec::new(), vec![b'a'; piece])]
        }),
    );
    fetched.recv_timeout(SOON).expect("the child's fetch");
    // A cancel naming the root is ignored; one naming the child stops it.
    let root = control::encode(&control::Message::CancelChild {
        execution_id: job.execution_id.clone(),
    })
    .expect("a frame");
    service.send_line(&root);
    let cancel = control::encode(&control::Message::CancelChild {
        execution_id: fetcher.execution_id.clone(),
    })
    .expect("a frame");
    service.send_line(&cancel);
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    assert_eq!(ended.last["execution_id"], json!(job.execution_id));
    assert_eq!(ended.last["clean"], json!(false), "{}", ended.last);
    let fail = calls(&service, "fail", &fetcher);
    assert_eq!(fail.len(), 1, "{:?}", service.ops());
    assert_eq!(fail[0].args["outcome"]["abandoned"], json!(true));
    assert_eq!(fail[0].args["outcome"]["error"], words::CANCELLED);
    let answers = answers(&service, &job);
    assert_eq!(
        answers[2],
        json!({"status": "completed", "output": {"sibling": true},
                                   "task_id": "task_2"})
    );
    assert_eq!(
        answers[3],
        json!({"status": "error",
        "error": {"type": "uncertain", "message": words::CANCELLED}, "task_id": "task_1"})
    );
    // The fetch is the relay's until its end, and what it received is
    // granted back as the runner drains it.
    support::eventually(|| {
        service
            .frames_of("credit")
            .iter()
            .map(|frame| frame["bytes"].as_u64().expect("bytes"))
            .sum::<u64>()
            == piece as u64
    });
    // Nothing of the subtree is used again: its runner takes no other.
    let next = echo(&job, "{}");
    job.family.lock().expect("the family").push(next.clone());
    service.send_line(&control::encode(&next.assign()).expect("an assign"));
    let exit = service.frame(SOON);
    assert_eq!(
        exit,
        json!({"v": 1, "type": "exit", "runner": support::RUNNER, "open": []})
    );
    assert_eq!(service.exit(SOON).code(), Some(1));
    assert!(calls(&service, "attach", &next).is_empty());
    assert!(
        service
            .errors()
            .contains("after a subtree completed not clean")
    );
}

#[test]
fn a_formula_stopped_while_its_child_runs_stops_the_child_which_closes_abandoned() {
    let mut service = Service::start();
    let mut job = formula(&[("call", run("run", "reagent:local.spin:0.1.0", json!({})))]);
    // Long enough for the formula's compile on a loaded host, which its
    // budget counts.
    job.timeout_ms = 8_000;
    let child = spin(&job, 60_000);
    service.assign(&job, admitting(vec![child.clone()]));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    assert_eq!(ended.last["clean"], json!(false));
    let formula_fail = calls(&service, "fail", &job);
    assert_eq!(
        formula_fail[0].args["outcome"]["error"],
        words::timeout(8_000)
    );
    let child_fail = calls(&service, "fail", &child);
    assert_eq!(child_fail.len(), 1, "{:?}", service.ops());
    assert_eq!(child_fail[0].args["outcome"]["abandoned"], json!(true));
    assert_eq!(child_fail[0].args["outcome"]["error"], words::CANCELLED);
}

#[test]
fn a_task_its_formula_left_running_is_stopped_with_its_store() {
    let mut service = Service::start();
    let job = formula(&[("spawn", run("run", "reagent:local.spin:0.1.0", json!({})))]);
    let child = spin(&job, 60_000);
    service.assign(&job, admitting(vec![child.clone()]));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    assert_eq!(ended.last["clean"], json!(false));
    assert_eq!(answers(&service, &job), [json!({"task_id": "task_1"})]);
    let child_fail = calls(&service, "fail", &child);
    assert_eq!(child_fail.len(), 1, "{:?}", service.ops());
    assert_eq!(child_fail[0].args["outcome"]["error"], words::CANCELLED);
}

#[test]
fn a_streamed_child_runs_on_after_its_formula_and_the_subtree_completes_at_its_close() {
    let mut service = Service::start();
    let job = formula(&[(
        "call",
        run("run_stream", "reagent:local.spin:0.1.0", json!({})),
    )]);
    let child = spin(&job, 1_500);
    service.assign(&job, admitting(vec![child.clone()]));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    // Nothing waited for it: it ran to its own budget.
    assert_eq!(ended.last["clean"], json!(false));
    let id = &child.execution_id;
    assert_eq!(
        answers(&service, &job),
        [json!({"status": "completed", "output": {"execution_id": id,
                "stream_url": format!("/api/executions/{id}/events")}})]
    );
    assert_eq!(
        calls(&service, "admit_child", &job)[0].args["guest_fn"],
        "spawn"
    );
    let ops: Vec<(String, String)> = service
        .calls
        .lock()
        .expect("the calls")
        .iter()
        .map(|call| (call.op.clone(), call.attempt.clone()))
        .collect();
    let formula_closed = ops
        .iter()
        .position(|(op, attempt)| op == "complete" && *attempt == job.attempt)
        .expect("the formula closed");
    let child_closed = ops
        .iter()
        .position(|(op, attempt)| op == "fail" && *attempt == child.attempt)
        .expect("the child closed");
    assert!(formula_closed < child_closed, "{ops:?}");
    let fail = calls(&service, "fail", &child);
    assert_eq!(fail[0].args["outcome"]["error"], words::timeout(1_500));
}

#[test]
fn a_child_left_open_ends_the_subtree_with_an_exit_naming_every_open_attempt() {
    let mut service = Service::start();
    let job = formula(&[
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        ("call", run("run", "reagent:local.echo:0.1.0", json!({}))),
    ]);
    let spinner = spin(&job, 60_000);
    let refused = echo(&job, "{}");
    let mut admitted = admitting(vec![spinner.clone(), refused.clone()]);
    let refused_attempt = refused.attempt.clone();
    service.assign(
        &job,
        Box::new(move |call, job| {
            if call.op == "complete" && call.attempt == refused_attempt {
                return Reply::Error("lost", json!({}));
            }
            admitted(call, job)
        }),
    );
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "exit", "{}", ended.last);
    let mut open: Vec<String> = ended.last["open"]
        .as_array()
        .expect("open")
        .iter()
        .map(|attempt| attempt.as_str().expect("an attempt").to_owned())
        .collect();
    open.sort();
    let mut expected = vec![
        job.attempt.clone(),
        spinner.attempt.clone(),
        refused.attempt.clone(),
    ];
    expected.sort();
    assert_eq!(open, expected);
    assert_eq!(service.exit(SOON).code(), Some(1));
}

#[test]
fn a_second_subtree_for_the_same_athanor_reuses_the_runner_and_its_compile() {
    let mut service = Service::start();
    let first = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), r#"{"n":1}"#);
    service.assign(&first, Box::new(standard));
    let complete = service.frame(SOON);
    assert_eq!(
        complete,
        json!({"v": 1, "type": "complete",
                                "execution_id": first.execution_id, "clean": true})
    );
    let second = first.child("reagent", &format!("{TEST_WASM}/echo.wasm"), r#"{"n":2}"#);
    first
        .family
        .lock()
        .expect("the family")
        .push(second.clone());
    service.send_line(&control::encode(&second.assign()).expect("an assign"));
    let complete = service.frame(SOON);
    assert_eq!(
        complete,
        json!({"v": 1, "type": "complete",
                                "execution_id": second.execution_id, "clean": true})
    );
    assert_eq!(calls(&service, "attach", &second).len(), 1);
    assert_eq!(
        calls(&service, "complete", &second)[0].args["outcome"]["output"],
        json!({"n": 2})
    );
    // The compile of the first subtree's component is the second's.
    assert_eq!(
        service.calls_of("fetch_artifact").len(),
        1,
        "{:?}",
        service.ops()
    );
}

#[test]
fn an_assign_for_another_athanor_than_the_runners_first_runs_nothing() {
    let mut service = Service::start();
    let first = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    service.assign(&first, Box::new(standard));
    assert_eq!(service.frame(SOON)["clean"], json!(true));
    let mut other = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    other.athanor = "ath_test-another".to_owned();
    first.family.lock().expect("the family").push(other.clone());
    service.send_line(&control::encode(&other.assign()).expect("an assign"));
    let exit = service.frame(SOON);
    assert_eq!(
        exit,
        json!({"v": 1, "type": "exit", "runner": support::RUNNER, "open": []})
    );
    assert_eq!(service.exit(SOON).code(), Some(1));
    assert!(calls(&service, "attach", &other).is_empty());
    assert!(
        service
            .errors()
            .contains("for another athanor than its first subtree's")
    );
}

#[test]
fn an_assign_after_a_subtree_completed_not_clean_runs_nothing() {
    let mut service = Service::start();
    let mut first = Job::new("reagent", &format!("{TEST_WASM}/spin.wasm"), "{}");
    first.timeout_ms = 300;
    service.assign(&first, Box::new(standard));
    assert_eq!(service.frame(SOON)["clean"], json!(false));
    let next = first.child("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    first.family.lock().expect("the family").push(next.clone());
    service.send_line(&control::encode(&next.assign()).expect("an assign"));
    let exit = service.frame(SOON);
    assert_eq!(
        exit,
        json!({"v": 1, "type": "exit", "runner": support::RUNNER, "open": []})
    );
    assert_eq!(service.exit(SOON).code(), Some(1));
    assert!(calls(&service, "attach", &next).is_empty());
}

/// The answers with each `duration_ms` taken out, which varies.
fn timeless(mut answers: Vec<Value>) -> Vec<Value> {
    for answer in &mut answers {
        if let Some(answer) = answer.as_object_mut() {
            answer.remove("duration_ms");
        }
    }
    answers
}

#[test]
fn a_request_that_does_not_read_is_answered_its_refusal_and_reaches_nobody() {
    let mut service = Service::start();
    let deep = support::nested(cyfr_runner::wire::MAX_DEPTH + 1);
    let mut job = formula(&[
        ("call", json!("not json")),
        ("call", json!({"tool": "component"})),
        (
            "call",
            json!({"tool": "component", "action": "search", "args": [1]}),
        ),
        ("call", json!(deep)),
        ("call", json!("x".repeat(10_200))),
        ("spawn", json!("not json")),
        ("spawn", json!({"action": "search"})),
        ("await-all", json!("not json")),
        ("await-all", json!({"ids": []})),
        ("await-all", json!({"task_ids": []})),
        ("await-any", json!({"task_ids": []})),
        ("await-all", json!({"task_ids": ["a", "b", "c", "d", "e"]})),
        ("await", json!("task_9")),
        ("poll", json!("task_9")),
        ("cancel", json!("task_9")),
        ("call", run("run", "", json!({}))),
        ("call", run("run", "reagent:local.echo:0.1.0", json!([1]))),
        (
            "call",
            json!({"tool": "execution", "action": "run",
                        "args": {"reference": "reagent:local.echo:0.1.0", "connection": 7}}),
        ),
    ]);
    // An envelope of 3,000 * 2 + 4,096 bytes: past the depth bound's
    // document, short of 10,200 bytes.
    job = job.bound(json!({"max_concurrent_tasks": 4, "max_request_size": 3_000}));
    job.intercepted = vec!["execution.run".to_owned()];
    service.assign(&job, Box::new(standard));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["clean"], json!(true), "{}", ended.last);
    let no_tool = error("invalid_request", words::NO_TOOL_OR_ACTION);
    let not_json = error("invalid_json", words::REQUEST_NOT_JSON);
    assert_eq!(
        answers(&service, &job),
        [
            not_json.clone(),
            no_tool.clone(),
            error("invalid_request", words::ARGS_NOT_MAP),
            error("invalid_json", &words::request_too_deep()),
            error("request_too_large", words::INVOKE_TOO_LARGE),
            not_json.clone(),
            no_tool,
            not_json,
            error("invalid_request", words::NO_TASK_IDS),
            json!({"results": [], "count": 0}),
            error("invalid_request", words::EMPTY_TASK_IDS),
            error("invalid_request", &words::too_many_task_ids(4)),
            error("invalid_request", &words::unknown_task("task_9")),
            error("invalid_request", &words::unknown_task("task_9")),
            error("invalid_request", &words::unknown_task("task_9")),
            error("invalid_request", &words::no_reference("execution.run")),
            error("invalid_request", &words::input_not_object("execution.run")),
            error(
                "invalid_request",
                &words::connection_not_name("execution.run")
            ),
        ]
    );
    assert_eq!(service.ops(), ["attach", "fetch_artifact", "complete"]);
}

#[test]
fn an_action_is_a_child_only_when_its_assignment_intercepts_it() {
    let mut service = Service::start();
    let mut job = formula(&[
        ("call", run("run", "reagent:local.echo:0.1.0", json!({}))),
        ("call", json!({"tool": "component", "action": "special"})),
    ]);
    job.intercepted = vec!["component.special".to_owned()];
    service.assign(&job, admitting(Vec::new()));
    ended(&service, SOON);
    assert_eq!(
        answers(&service, &job),
        [
            json!({"status": "completed", "output": true}),
            error("invalid_request", &words::no_dispatch("component.special")),
        ]
    );
    assert!(calls(&service, "admit_child", &job).is_empty());
    let tool = calls(&service, "tool_call", &job);
    assert_eq!(tool.len(), 1, "{:?}", service.ops());
    assert_eq!(
        tool[0].args,
        json!({"name": "execution", "guest_fn": "call",
               "args": {"action": "run", "reference": "reagent:local.echo:0.1.0", "input": {}}})
    );
}

/// CYFR's answers to the tool calls of `catalog_and_children`, by the
/// call's action, and its refusal of a child that names an account.
fn catalog(call: &support::Call, job: &Job) -> Reply {
    match call.op.as_str() {
        "tool_call" => match call.args["args"]["action"].as_str() {
            Some("search") => Reply::Ok(json!({"hits": []})),
            Some("setup") => Reply::Error(
                "guest_error",
                json!({"type": "setup_required",
                "message": "This app needs a vault entry", "remediation": {"need": "api_key"}}),
            ),
            Some("denied") => Reply::Error(
                "guest_error",
                json!({"type": "tool_denied",
                "message": "Not granted"}),
            ),
            Some("busy") => Reply::Error("unavailable", json!({})),
            Some("lost") => Reply::Dropped,
            _ => Reply::Error("not_found", json!({})),
        },
        "admit_child" => Reply::Error(
            "guest_error",
            json!({"type": "connection_not_granted",
            "message": "The edge does not bind Work"}),
        ),
        _ => standard(call, job),
    }
}

#[test]
fn tool_calls_and_tasks_answer_cyfrs_results_and_refusals_as_they_are() {
    let mut service = Service::start();
    let tool = |action: &str| json!({"tool": "component", "action": action, "args": {"q": 1}});
    let named = json!({"tool": "execution", "action": "run", "args":
        {"reference": "reagent:local.echo:0.1.0", "connection": "Work"}});
    let streamed = json!({"tool": "execution", "action": "run_stream", "args":
        {"reference": "reagent:local.echo:0.1.0", "connection": "Work"}});
    let mut job = formula(&[
        ("call", tool("search")),
        ("call", tool("setup")),
        ("call", tool("busy")),
        ("call", tool("lost")),
        ("spawn", tool("denied")),
        ("await", json!("task_1")),
        ("call", streamed),
        ("spawn", named.clone()),
        (
            "spawn",
            run("run_stream", "reagent:local.echo:0.1.0", json!({})),
        ),
        ("spawn", tool("search")),
        ("spawn", named),
        ("await-any", json!({"task_ids": ["task_2"]})),
        ("emit", json!({"type": "progress"})),
    ]);
    job = job.bound(json!({"max_concurrent_tasks": 1}));
    job.intercepted = vec![
        "execution.run".to_owned(),
        "execution.run_stream".to_owned(),
    ];
    service.assign(&job, Box::new(catalog));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    let answers = answers(&service, &job);
    assert_eq!(
        answers[..12],
        [
            json!({"status": "completed", "output": {"hits": []}}),
            json!({"error": {"type": "setup_required", "message": "This app needs a vault entry",
                             "remediation": {"need": "api_key"}}}),
            error("dispatch_error", words::CALL_FAILED),
            error("uncertain", words::UNCERTAIN),
            json!({"task_id": "task_1"}),
            json!({"status": "error", "error": {"type": "tool_denied", "message": "Not granted"},
                   "task_id": "task_1"}),
            error("connection_not_granted", "The edge does not bind Work"),
            // A refused child takes no task: the next task is task_2.
            error("connection_not_granted", "The edge does not bind Work"),
            error("invalid_request", words::RUN_STREAM_SPAWNED),
            json!({"task_id": "task_2"}),
            // The tracker is full: nothing is asked of CYFR.
            error("resource_limit", words::TASKS_EXCEEDED),
            json!({"result": {"status": "completed", "output": {"hits": []}, "task_id": "task_2"},
                   "task_id": "task_2", "pending": []}),
        ]
    );
    // The emit is the formula's push_deltas; the standard script has none.
    assert_eq!(
        answers[12],
        error("dispatch_error", "The emit call failed.")
    );
    let admits = calls(&service, "admit_child", &job);
    assert_eq!(admits.len(), 2, "{:?}", service.ops());
    assert_eq!(
        admits[0].args["guest_fn"], "spawn",
        "run_stream is admitted spawn-shaped"
    );
    assert_eq!(admits[0].args["connection"], "Work");
    assert_eq!(admits[1].args["guest_fn"], "spawn");
    let spawned: Vec<&Value> = ended
        .events
        .iter()
        .filter(|event| event["name"] == "formula.spawn")
        .collect();
    assert_eq!(spawned.len(), 2, "{:?}", ended.events);
    assert_eq!(spawned[0]["metadata"]["component_ref"], "component.denied");
}

#[test]
fn a_task_is_awaited_polled_and_cancelled_and_one_given_up_on_is_stopped() {
    let mut service = Service::start();
    let mut job = formula(&[
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        (
            "spawn",
            run("run", "reagent:local.echo:0.1.0", json!({"n": 3})),
        ),
        ("await-any", json!({"task_ids": ["task_1"]})),
        ("poll", json!("task_1")),
        ("cancel", json!("task_1")),
        ("poll", json!("task_1")),
        ("cancel", json!("task_1")),
        ("await", json!("task_1")),
        ("await", json!("task_2")),
        (
            "await-all",
            json!({"task_ids": ["task_3", "task_3", "task_7", 7]}),
        ),
    ]);
    job = job.bound(json!({"max_concurrent_tasks": 4, "batch_timeout": "500ms"}));
    job.intercepted = vec!["execution.run".to_owned()];
    let first = spin(&job, 60_000);
    let second = spin(&job, 60_000);
    let third = echo(&job, r#"{"n":3}"#);
    service.assign(
        &job,
        admitting(vec![first.clone(), second.clone(), third.clone()]),
    );
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    assert_eq!(ended.last["clean"], json!(false));
    let cancelled = json!({"type": "task_failed", "message": words::TASK_CANCELLED});
    assert_eq!(
        timeless(answers(&service, &job)),
        [
            json!({"task_id": "task_1"}),
            json!({"task_id": "task_2"}),
            json!({"task_id": "task_3"}),
            json!({"status": "error", "error": {"type": "timeout",
                   "message": words::ALL_TIMED_OUT}, "pending": ["task_1"]}),
            json!({"status": "pending"}),
            json!({"cancelled": true, "task_id": "task_1"}),
            json!({"status": "error", "error": cancelled, "task_id": "task_1"}),
            error("invalid_request", &words::already_completed("task_1")),
            json!({"status": "error", "error": cancelled, "task_id": "task_1"}),
            json!({"status": "error", "error": {"type": "timeout",
                   "message": words::TASK_TIMED_OUT}, "task_id": "task_2"}),
            json!({"results": [
                {"status": "completed", "output": {"n": 3}, "task_id": "task_3"},
                {"status": "error", "error": {"type": "task_failed",
                 "message": words::UNKNOWN_REASON}, "task_id": "task_7"},
                {"status": "error", "error": {"type": "task_failed",
                 "message": words::UNKNOWN_REASON}, "task_id": 7}],
                   "count": 3}),
        ]
    );
    // The cancelled task and the one given up on are stopped: each closes
    // abandoned.
    for child in [&first, &second] {
        let fail = calls(&service, "fail", child);
        assert_eq!(fail.len(), 1, "{:?}", service.ops());
        assert_eq!(fail[0].args["outcome"]["abandoned"], json!(true));
        assert_eq!(fail[0].args["outcome"]["error"], words::CANCELLED);
    }
    let names: Vec<&str> = ended
        .events
        .iter()
        .filter_map(|event| event["name"].as_str())
        .filter(|name| name.starts_with("formula."))
        .collect();
    assert_eq!(
        names,
        [
            "formula.spawn",
            "formula.spawn",
            "formula.spawn",
            "formula.await_any",
            "formula.cancel",
            "formula.await",
            "formula.await",
            "formula.await_all"
        ]
    );
}

#[test]
fn nothing_of_a_childs_token_or_keys_is_left_in_the_runners_memory_after_its_subtree() {
    // On descriptor 3, as the keeper hands it: standard input is read
    // through a buffer of Tokio's own, which keeps the root's assign, and
    // every token's first bytes are alike.
    let mut service = Service::start_on(support::Control::Descriptor3, &[]);
    let job = formula(&[("call", run("run", "reagent:local.echo:0.1.0", json!({})))]);
    let child = echo(&job, "{}");
    let token = Arc::new(Mutex::new(String::new()));
    let kept = token.clone();
    let mut admitted = admitting(vec![child.clone()]);
    service.assign(
        &job,
        Box::new(move |call, job| {
            let reply = admitted(call, job);
            if call.op == "admit_child"
                && let Reply::Ok(answer) = &reply
            {
                *kept.lock().expect("the token") =
                    answer["assignment"].as_str().expect("a token").to_owned();
            }
            reply
        }),
    );
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["clean"], json!(true), "{}", ended.last);
    let token = token.lock().expect("the token").clone();
    let call_hex = cyfr_runner::wire::hex(&child.call_key);
    let seal_hex = cyfr_runner::wire::hex(&child.seal_key);
    let needles: [&[u8]; 6] = [
        support::RUNNER.as_bytes(),
        &token.as_bytes()[..64],
        call_hex.as_bytes(),
        seal_hex.as_bytes(),
        &child.call_key,
        &child.seal_key,
    ];
    let found = support::scan(service.pid(), &needles);
    // The scan finds what is there: the runner's own id.
    assert!(found[0] > 0, "the scan read the runner's memory: {found:?}");
    assert_eq!(
        &found[1..],
        &[0, 0, 0, 0, 0],
        "token, keys' hex, keys' bytes"
    );
}
