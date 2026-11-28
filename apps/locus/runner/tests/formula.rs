// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! A formula's invoke, its children and the runner's reuse, against the
//! real binary and a scripted service end (`support`). The formula is
//! `formula_probe`, which makes the invoke calls its input lists and
//! answers every answer; its children are the suite's guests.

mod support;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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
            Some(child) => Reply::Ok(job.of(&call.attempt).admitted(&child)),
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

/// What `found` finds within `within`, polled; none when it finds nothing
/// in that time.
fn waited<T>(within: Duration, mut found: impl FnMut() -> Option<T>) -> Option<T> {
    let until = Instant::now() + within;
    loop {
        if let Some(found) = found() {
            return Some(found);
        }
        if Instant::now() >= until {
            return None;
        }
        std::thread::sleep(Duration::from_millis(20)); // sleep-ok: polls what the runner reaches, bounded by `within`
    }
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
    // CYFR confirmed the child given back: nothing of it is left.
    assert_eq!(ended.last["clean"], json!(true), "{name}: {}", ended.last);
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
    service.send_line(&job.cancel(&fetcher));
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
    assert_eq!(service.exit(SOON).code(), Some(1));
    let said: Vec<Value> = service
        .rest(Duration::from_secs(5))
        .into_iter()
        .filter(|line| line["type"] != "event")
        .collect();
    assert_eq!(
        said,
        [json!({"v": 1, "type": "exit", "runner": support::RUNNER, "open": []})],
        "the runner refused the next subtree in its exit"
    );
    assert!(calls(&service, "attach", &next).is_empty());
    assert!(
        service
            .errors()
            .contains("after a subtree completed not clean")
    );
}

#[test]
fn a_cancel_naming_the_root_or_no_child_of_the_subtree_is_ignored_and_it_completes_clean() {
    let mut service = Service::start();
    let root = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), r#"{"n":1}"#);
    let go = Arc::new(Mutex::new(false));
    let held = go.clone();
    service.assign(
        &root,
        Box::new(move |call, job| match call.op.as_str() {
            // The root's bytes are held until both cancels are sent: the
            // subtree runs as they arrive.
            "fetch_artifact" => {
                let held = held.clone();
                Reply::When(
                    Box::new(move || *held.lock().expect("go")),
                    Value::String(cyfr_runner::wire::encode_base64(&job.component)),
                )
            }
            _ => standard(call, job),
        }),
    );
    support::eventually(|| !service.calls_of("fetch_artifact").is_empty());
    let elsewhere = "exec_test-elsewhere";
    for execution_id in [elsewhere, root.execution_id.as_str()] {
        let cancel = control::Message::CancelChild {
            execution_id: execution_id.to_owned(),
        };
        service.send_line(&control::encode(&cancel).expect("a cancel_child frame"));
    }
    *go.lock().expect("go") = true;
    assert_eq!(
        service.frame(SOON),
        json!({"v": 1, "type": "complete", "execution_id": root.execution_id, "clean": true})
    );
    assert_eq!(
        calls(&service, "complete", &root)[0].args["outcome"]["output"],
        json!({"n": 1})
    );
    assert_eq!(service.exit_after_close(SOON).code(), Some(0));
    // The root's cancel was read while the subtree ran, so the one before
    // it on the channel was too.
    let log = service.errors();
    assert!(
        log.contains(&format!(
            "cancel_child names the subtree's root {}; ignored",
            root.execution_id
        )),
        "{log}"
    );
    assert!(
        log.contains(&format!(
            "cancel_child names no child here ({elsewhere}); ignored"
        )),
        "{log}"
    );
}

#[test]
fn a_formula_stopped_while_its_child_runs_stops_the_child_which_closes_abandoned() {
    let mut service = Service::start();
    let mut job = formula(&[("call", run("run", "reagent:local.spin:0.1.0", json!({})))]);
    // Long enough for the formula's compile on a loaded host, which its
    // budget counts.
    job.timeout_ms = 8_000;
    let child = spin(&job, 120_000);
    service.assign(&job, admitting(vec![child.clone()]));
    let stopped = waited(Duration::from_secs(40), || {
        calls(&service, "fail", &child).first().cloned()
    });
    assert!(
        stopped.is_some(),
        "the child ran on past its formula: {:?}",
        service.ops()
    );
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
    let child = spin(&job, 120_000);
    service.assign(&job, admitting(vec![child.clone()]));
    let stopped = waited(Duration::from_secs(40), || {
        calls(&service, "fail", &child).first().cloned()
    });
    assert!(
        stopped.is_some(),
        "the task ran on past its formula: {:?}",
        service.ops()
    );
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
fn each_call_spawn_and_cancel_is_an_event_naming_the_formula_and_its_action_or_task() {
    let mut service = Service::start();
    let tool = |action: &str| json!({"tool": "component", "action": action});
    let job = formula(&[
        (
            "call",
            run("run", "reagent:local.echo:0.1.0", json!({"n": 1})),
        ),
        (
            "call",
            run("run", "reagent:local.echo:0.1.0", json!({"n": 2})),
        ),
        ("call", tool("search")),
        ("call", tool("denied")),
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        ("cancel", json!("task_1")),
    ]);
    // CYFR refuses the second admission.
    let mut admissions = VecDeque::from([
        Some(echo(&job, r#"{"n":1}"#)),
        None,
        Some(spin(&job, 60_000)),
    ]);
    service.assign(
        &job,
        Box::new(move |call, job| match call.op.as_str() {
            "admit_child" => match admissions.pop_front().flatten() {
                Some(child) => Reply::Ok(job.admitted(&child)),
                None => Reply::Error(
                    "guest_error",
                    json!({"type": "tool_denied", "message": "Denied by edge_only"}),
                ),
            },
            "tool_call" => match call.args["args"]["action"].as_str() {
                Some("search") => Reply::Ok(json!({"hits": []})),
                _ => Reply::Error(
                    "guest_error",
                    json!({"type": "tool_denied", "message": "Not granted"}),
                ),
            },
            _ => standard(call, job),
        }),
    );
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    assert_eq!(
        answers(&service, &job),
        [
            json!({"status": "completed", "output": {"n": 1}}),
            error("tool_denied", "Denied by edge_only"),
            json!({"status": "completed", "output": {"hits": []}}),
            error("tool_denied", "Not granted"),
            json!({"task_id": "task_1"}),
            json!({"cancelled": true, "task_id": "task_1"}),
        ]
    );
    let named: Vec<(Value, Value)> = ended
        .events
        .iter()
        .filter(|event| {
            ["mcp_tool.call", "formula.spawn", "formula.cancel"]
                .contains(&event["name"].as_str().unwrap_or(""))
        })
        .map(|event| (event["name"].clone(), event["metadata"].clone()))
        .collect();
    let id = &job.execution_id;
    let called = |action: &str, status: &str| {
        (
            json!("mcp_tool.call"),
            json!({"execution_id": id, "tool_action": action, "status": status}),
        )
    };
    // The cancelled task's child never answers: its call is no event.
    assert_eq!(
        named,
        [
            called("execution.run", "ok"),
            called("execution.run", "error"),
            called("component.search", "ok"),
            called("component.denied", "error"),
            (
                json!("formula.spawn"),
                json!({"parent_execution_id": id, "task_id": "task_1",
                       "component_ref": "execution.run"})
            ),
            (
                json!("formula.cancel"),
                json!({"parent_execution_id": id, "task_id": "task_1"})
            ),
        ]
    );
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
fn a_formula_allowed_no_tasks_is_refused_every_spawn_and_asks_nothing() {
    let mut service = Service::start();
    let job = formula(&[
        ("spawn", json!({"tool": "component", "action": "search"})),
        ("spawn", run("run", "reagent:local.echo:0.1.0", json!({}))),
    ])
    .bound(json!({"max_concurrent_tasks": 0}));
    service.assign(&job, Box::new(standard));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["clean"], json!(true), "{}", ended.last);
    let refused = error("resource_limit", words::TASKS_EXCEEDED);
    assert_eq!(answers(&service, &job), [refused.clone(), refused]);
    // Neither is a tool call nor an admission.
    assert_eq!(service.ops(), ["attach", "fetch_artifact", "complete"]);
    assert!(
        ended
            .events
            .iter()
            .all(|event| event["name"] != "formula.spawn"),
        "{:?}",
        ended.events
    );
}

#[test]
fn an_await_all_past_its_deadline_answers_a_running_task_timed_out_and_the_ended_as_they_ended() {
    let mut service = Service::start();
    let tool = |action: &str| json!({"tool": "component", "action": action});
    let mut job = formula(&[
        ("spawn", tool("search")),
        ("spawn", tool("denied")),
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        // Answered once both spawned calls have their results: the
        // await-all finds them ended and the child still running.
        ("call", tool("wait")),
        (
            "await-all",
            json!({"task_ids": ["task_1", "task_2", "task_3"]}),
        ),
    ]);
    job = job.bound(json!({"max_concurrent_tasks": 4, "batch_timeout": "500ms"}));
    job.intercepted = vec!["execution.run".to_owned()];
    let spinner = spin(&job, 60_000);
    let ended_both = Arc::new(Mutex::new(false));
    let seen = ended_both.clone();
    let mut admitted = admitting(vec![spinner.clone()]);
    service.assign(
        &job,
        Box::new(move |call, job| {
            if call.op != "tool_call" {
                return admitted(call, job);
            }
            match call.args["args"]["action"].as_str() {
                Some("search") => Reply::Ok(json!({"hits": []})),
                Some("denied") => Reply::Error(
                    "guest_error",
                    json!({"type": "tool_denied", "message": "Not granted"}),
                ),
                _ => {
                    let seen = seen.clone();
                    Reply::When(Box::new(move || *seen.lock().expect("seen")), json!(true))
                }
            }
        }),
    );
    // Each spawned call queues its event in the same step that hands its
    // result on.
    let mut spawned_calls = 0;
    while spawned_calls < 2 {
        if service.line(SOON)["name"] == "mcp_tool.call" {
            spawned_calls += 1;
        }
    }
    *ended_both.lock().expect("seen") = true;
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    assert_eq!(ended.last["clean"], json!(false), "{}", ended.last);
    assert_eq!(
        answers(&service, &job),
        [
            json!({"task_id": "task_1"}),
            json!({"task_id": "task_2"}),
            json!({"task_id": "task_3"}),
            json!({"status": "completed", "output": true}),
            json!({"results": [
                {"status": "completed", "output": {"hits": []}, "task_id": "task_1"},
                {"status": "error", "error": {"type": "tool_denied", "message": "Not granted"},
                 "task_id": "task_2"},
                {"status": "error", "error": {"type": "timeout", "message": words::TASK_TIMED_OUT},
                 "task_id": "task_3"}],
                   "count": 3}),
        ]
    );
    let awaited: Vec<&Value> = ended
        .events
        .iter()
        .filter(|event| event["name"] == "formula.await_all")
        .map(|event| &event["metadata"])
        .collect();
    assert_eq!(
        awaited,
        [&json!({"parent_execution_id": job.execution_id, "count": 3, "timed_out": 1})]
    );
    // The task it gave up on is stopped: its child closes abandoned.
    let fail = calls(&service, "fail", &spinner);
    assert_eq!(fail.len(), 1, "{:?}", service.ops());
    assert_eq!(fail[0].args["outcome"]["abandoned"], json!(true));
    assert_eq!(fail[0].args["outcome"]["error"], words::CANCELLED);
}

#[test]
fn an_await_any_over_several_tasks_answers_the_one_that_ended_and_names_the_others_pending() {
    let mut service = Service::start();
    let job = formula(&[
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        (
            "spawn",
            run("run", "reagent:local.echo:0.1.0", json!({"n": 2})),
        ),
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        (
            "await-any",
            json!({"task_ids": ["task_1", "task_2", "task_3"]}),
        ),
    ]);
    let children = vec![
        spin(&job, 60_000),
        echo(&job, r#"{"n":2}"#),
        spin(&job, 60_000),
    ];
    service.assign(&job, admitting(children));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    // The first listed is still running: the one that ended answers, the
    // others in the guest's order.
    assert_eq!(
        answers(&service, &job)[3],
        json!({"result": {"status": "completed", "output": {"n": 2}, "task_id": "task_2"},
               "task_id": "task_2", "pending": ["task_1", "task_3"]})
    );
    let any: Vec<&Value> = ended
        .events
        .iter()
        .filter(|event| event["name"] == "formula.await_any")
        .map(|event| &event["metadata"])
        .collect();
    assert_eq!(
        any,
        [&json!({"parent_execution_id": job.execution_id, "winner_task_id": "task_2"})]
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

// ============================================================================
// The mend of the first review round: authority, what a subtree holds,
// what keeps a runner from reuse, and its time.
// ============================================================================

/// A child whose keys name its attempt with `field` changed to `value`.
fn keys_naming(formula: &Job, field: &str, value: Value) -> Job {
    let mut child = echo(formula, "{}");
    let mut named = serde_json::to_value(json!({
        "athanor_id": child.athanor, "execution_id": child.execution_id,
        "attempt": child.attempt, "fence": 2, "generation": 7, "service": child.service,
    }))
    .expect("an attempt");
    named[field] = value;
    child.keys_attempt = Some(cyfr_runner::auth::Attempt {
        athanor_id: named["athanor_id"].as_str().expect("a string").to_owned(),
        execution_id: named["execution_id"].as_str().expect("a string").to_owned(),
        attempt: named["attempt"].as_str().expect("a string").to_owned(),
        fence: named["fence"].as_u64().expect("a fence"),
        generation: named["generation"].as_u64().expect("a generation"),
        service: named["service"].as_str().expect("a string").to_owned(),
    });
    child
}

#[test]
fn an_admission_whose_keys_name_another_fence_is_given_back() {
    let formula = formula(&[]);
    refused_admission(
        "fence",
        keys_naming(&formula, "fence", json!(3)),
        |_, _, _| {},
    );
}

#[test]
fn an_admission_whose_keys_name_another_generation_is_given_back() {
    let formula = formula(&[]);
    let child = keys_naming(&formula, "generation", json!(8));
    refused_admission("generation", child, |_, _, _| {});
}

#[test]
fn an_admission_whose_keys_name_another_athanor_is_given_back() {
    let formula = formula(&[]);
    let child = keys_naming(&formula, "athanor_id", json!("ath_test-keys"));
    refused_admission("keys' athanor", child, |_, _, _| {});
}

#[test]
fn an_admission_whose_keys_name_another_execution_is_given_back() {
    let formula = formula(&[]);
    let child = keys_naming(&formula, "execution_id", json!("exec_test-keys"));
    refused_admission("keys' execution", child, |_, _, _| {});
}

#[test]
fn an_admission_whose_keys_name_another_service_is_given_back() {
    let formula = formula(&[]);
    let child = keys_naming(&formula, "service", json!("wrk_keysservice"));
    refused_admission("keys' service", child, |_, _, _| {});
}

#[test]
fn an_admission_without_its_projection_is_given_back() {
    let parent = formula(&[]);
    refused_admission("projection", echo(&parent, "{}"), |answer, _, _| {
        answer.as_object_mut().expect("an answer").remove("secrets");
    });
}

#[test]
fn a_release_cyfr_does_not_confirm_leaves_the_runner_not_clean() {
    let mut service = Service::start();
    let parent = formula(&[("call", run("run", "reagent:local.echo:0.1.0", json!({})))]);
    let child = echo(&parent, "{}");
    service.assign(
        &parent,
        Box::new(move |call, job| match call.op.as_str() {
            "admit_child" => {
                let mut answer = job.admitted(&child);
                answer["input"] = json!("null");
                Reply::Ok(answer)
            }
            "release_child" => Reply::Error("unavailable", json!({})),
            _ => standard(call, job),
        }),
    );
    let frames = ended(&service, SOON);
    assert_eq!(calls(&service, "release_child", &parent).len(), 1);
    assert_eq!(frames.last["clean"], json!(false), "{}", frames.last);
}

#[test]
fn an_admission_whose_assignment_does_not_read_leaves_the_runner_not_clean() {
    let mut service = Service::start();
    let parent = formula(&[("call", run("run", "reagent:local.echo:0.1.0", json!({})))]);
    let child = echo(&parent, "{}");
    service.assign(
        &parent,
        Box::new(move |call, job| match call.op.as_str() {
            "admit_child" => {
                let mut answer = job.admitted(&child);
                answer["assignment"] = json!("not.a token");
                Reply::Ok(answer)
            }
            _ => standard(call, job),
        }),
    );
    let frames = ended(&service, SOON);
    assert_eq!(
        answers(&service, &parent),
        [error("dispatch_error", words::CALL_FAILED)]
    );
    // It names no child to give back, and so leaves the runner in doubt.
    assert!(calls(&service, "release_child", &parent).is_empty());
    assert_eq!(frames.last["clean"], json!(false), "{}", frames.last);
}

#[test]
fn a_batch_await_hands_on_a_services_refusal_as_it_was_sent() {
    let mut service = Service::start();
    let parent = formula(&[
        ("spawn", json!({"tool": "example", "action": "read"})),
        ("await-all", json!({"task_ids": ["task_1"]})),
    ]);
    service.assign(
        &parent,
        Box::new(|call, job| match call.op.as_str() {
            "tool_call" => Reply::Error(
                "guest_error",
                json!({"type": "dispatch_error", "message": "Unexpected result format"}),
            ),
            _ => standard(call, job),
        }),
    );
    ended(&service, SOON);
    assert_eq!(
        answers(&service, &parent)[1]["results"][0]["error"],
        json!({"type": "dispatch_error", "message": "Unexpected result format"})
    );
}

#[test]
fn a_cancelled_tool_call_whose_answer_comes_late_leaves_the_runner_not_clean() {
    let mut service = Service::start();
    let tool = |name| json!({"tool": "example", "action": name});
    let parent = formula(&[
        ("spawn", tool("work")),
        ("call", tool("entered")),
        ("cancel", json!("task_1")),
        ("call", tool("finished")),
    ]);
    service.assign(
        &parent,
        Box::new(|call, job| match call.op.as_str() {
            "tool_call" => match call.args["args"]["action"].as_str().expect("an action") {
                "work" => Reply::Later(Duration::from_secs(2), json!(true)),
                "entered" => Reply::Later(Duration::from_millis(250), json!(true)),
                _ => Reply::Later(Duration::from_secs(4), json!(true)),
            },
            _ => standard(call, job),
        }),
    );
    let frames = ended(&service, SOON);
    assert_eq!(answers(&service, &parent)[2]["cancelled"], json!(true));
    let posted = service.calls.lock().expect("the calls").clone();
    let at = |op: &str, action: &str| {
        posted
            .iter()
            .position(|call| call.op == op && call.args["args"]["action"] == action)
            .expect("a call")
    };
    // The cancelled call was out, and its answer came after the cancel.
    assert!(at("tool_call", "work") < at("answered:tool_call", "entered"));
    assert!(at("tool_call", "finished") < at("answered:tool_call", "work"));
    assert_eq!(frames.last["clean"], json!(false), "{}", frames.last);
}

#[tokio::test]
async fn a_child_whose_frame_is_not_written_runs_nothing_and_is_given_back() {
    use cyfr_runner::control::{Environment, Lines, Writer};
    use cyfr_runner::subtree::{RelayAt, serve};
    use tokio::io::AsyncWriteExt as _;

    // A control channel that takes every line but a child's.
    struct RejectChild;
    impl tokio::io::AsyncWrite for RejectChild {
        fn poll_write(
            self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
            bytes: &[u8],
        ) -> std::task::Poll<std::io::Result<usize>> {
            let line: Value = serde_json::from_slice(bytes).expect("a line");
            std::task::Poll::Ready(if line["type"] == "child" {
                Err(std::io::ErrorKind::BrokenPipe.into())
            } else {
                Ok(bytes.len())
            })
        }
        fn poll_flush(
            self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }
        fn poll_shutdown(
            self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }
    }

    let parent = formula(&[("call", run("run", "reagent:local.echo:0.1.0", json!({})))]);
    let child = echo(&parent, "{}");
    let script = admitting(vec![child.clone()]);
    let (up, down) = std::os::unix::net::UnixStream::pair().expect("a pair");
    down.set_nonblocking(true).expect("nonblocking");
    let relay = RelayAt::Stream(tokio::net::UnixStream::from_std(down).expect("a stream"));
    let calls = Arc::new(Mutex::new(Vec::new()));
    let recorded = calls.clone();
    let job = parent.clone();
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(move || support::relay(up, job, script, recorded))
        .expect("the service end");
    let (mut lines, read) = tokio::io::duplex(1 << 20);
    lines
        .write_all(&control::encode(&parent.assign()).expect("an assign"))
        .await
        .expect("written");
    drop(lines);
    let environment = Environment {
        runner_id: support::RUNNER.to_owned(),
        service_id: support::SERVICE.to_owned(),
        boot: support::BOOT.to_owned(),
        control_fd: 0,
        relay: control::Relay::Fd(4),
    };
    let status = serve(
        environment,
        cyfr_runner::engine::Engine::new().expect("an engine"),
        Lines::new(read),
        Writer::start(RejectChild),
        Some(relay),
    )
    .await;
    assert_eq!(status, 1);
    let calls = calls.lock().expect("the calls").clone();
    let of_child: Vec<&str> = calls
        .iter()
        .filter(|call| call.attempt == child.attempt)
        .map(|call| call.op.as_str())
        .collect();
    assert!(of_child.is_empty(), "the child ran: {of_child:?}");
    let released: Vec<&support::Call> = calls
        .iter()
        .filter(|call| call.op == "release_child")
        .collect();
    assert_eq!(released.len(), 1, "{calls:?}");
    assert_eq!(
        released[0].args,
        json!({"execution_id": child.execution_id})
    );
}

#[test]
fn a_childs_recorded_failure_is_printed_by_no_debug() {
    let marker = "review-only-recorded-message";
    let answer = cyfr_runner::attempt::Answer::Failed(zeroize::Zeroizing::new(marker.to_owned()));
    assert!(!format!("{answer:?}").contains(marker));
}

#[test]
fn a_child_reads_its_own_vault_fields_and_not_its_formulas() {
    let mut service = Service::start();
    let job = formula(&[
        (
            "call",
            run("run", "catalyst:local.vault-probe:0.1.0", json!({})),
        ),
        (
            "call",
            run("run", "catalyst:local.vault-probe:0.1.0", json!({})),
        ),
    ]);
    let mut given = job.child("catalyst", &format!("{HOSTILE}/vault_probe.wasm"), "{}");
    given.secrets = json!({"PROBE_KEY": "the-childs-value"});
    let bare = job.child("catalyst", &format!("{HOSTILE}/vault_probe.wasm"), "{}");
    let mut admitted = admitting(vec![given, bare]);
    service.assign(
        &job,
        Box::new(move |call, job| match call.op.as_str() {
            // The formula's own fields, which no child is handed.
            "attach" => Reply::Ok(json!({"PROBE_KEY": "the-formulas", "PROBE_HIDDEN": "too"})),
            _ => admitted(call, job),
        }),
    );
    ended(&service, SOON);
    let read = |answer: &Value| answer["output"]["data"]["read"].clone();
    let answers = answers(&service, &job);
    assert_eq!(read(&answers[0]), json!("OEEE"), "{answers:?}");
    assert_eq!(read(&answers[1]), json!("EEEE"), "{answers:?}");
}

#[test]
fn the_runners_log_never_carries_a_vault_value_or_a_name_the_contract_bounds_out() {
    let mut service = Service::start();
    let job = formula(&[(
        "call",
        run("run", "catalyst:local.vault-probe:0.1.0", json!({})),
    )]);
    let value = "sk-probe-7c1d0e";
    let mut child = job.child("catalyst", &format!("{HOSTILE}/vault_probe.wasm"), "{}");
    child.secrets = json!({ "PROBE_KEY": value });
    service.assign(&job, admitting(vec![child]));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["clean"], json!(true), "{}", ended.last);
    // The value was handed over; the other three names were refused.
    assert_eq!(
        answers(&service, &job)[0]["output"]["data"]["read"],
        json!("OEEE")
    );
    assert_eq!(service.exit_after_close(SOON).code(), Some(0));
    let log = service.errors();
    // Each refusal is logged by its reason.
    assert!(
        log.contains("was refused a vault field (secret_denied)"),
        "{log}"
    );
    assert!(
        log.contains("asked its vault for a name that is no field name"),
        "{log}"
    );
    // The over-long name is 257 `N`s, and the control-byte name carries a
    // newline, written as it is or escaped.
    let long = "N".repeat(32);
    for kept_out in [value, long.as_str(), "PROBE\nKEY", r"PROBE\nKEY"] {
        assert!(!log.contains(kept_out), "{kept_out:?} is in the log: {log}");
    }
}

#[test]
fn a_finished_result_not_yet_awaited_counts_against_the_tasks_a_formula_holds() {
    let mut service = Service::start();
    let mut job = formula(&[
        ("spawn", run("run", "reagent:local.echo:0.1.0", json!({}))),
        // The formula's call is answered only once the first task has its
        // child's answer, so its result is in, unawaited.
        ("call", json!({"tool": "component", "action": "wait"})),
        ("poll", json!("task_1")),
        ("spawn", run("run", "reagent:local.echo:0.1.0", json!({}))),
    ]);
    job = job.bound(json!({"max_concurrent_tasks": 1}));
    job.intercepted = vec!["execution.run".to_owned()];
    let child = echo(&job, "{}");
    let seen = Arc::new(Mutex::new(false));
    let saw = seen.clone();
    let mut admitted = admitting(vec![child.clone()]);
    service.assign(
        &job,
        Box::new(move |call, job| {
            if call.op == "tool_call" {
                let seen = saw.clone();
                return Reply::When(Box::new(move || *seen.lock().expect("seen")), json!(true));
            }
            admitted(call, job)
        }),
    );
    // The task queues its event in the same step that hands its result on.
    loop {
        let line = service.line(SOON);
        if line["name"] == "mcp_tool.call" && line["metadata"]["tool_action"] == "execution.run" {
            break;
        }
    }
    *seen.lock().expect("seen") = true;
    ended(&service, SOON);
    let answers = answers(&service, &job);
    assert_eq!(answers[2]["status"], "completed", "{answers:?}");
    assert_eq!(
        answers[3],
        error("resource_limit", words::TASKS_EXCEEDED),
        "{answers:?}"
    );
    assert_eq!(calls(&service, "admit_child", &job).len(), 1);
}

#[test]
fn a_cancel_that_races_a_childs_close_leaves_the_runner_not_clean() {
    let mut service = Service::start();
    let job = formula(&[("call", run("run", "reagent:local.echo:0.1.0", json!({})))]);
    let child = echo(&job, "{}");
    let closing = child.attempt.clone();
    let (complete_tx, complete_seen) = std::sync::mpsc::channel::<()>();
    let complete_tx = Mutex::new(complete_tx);
    let mut admitted = admitting(vec![child.clone()]);
    service.assign(
        &job,
        Box::new(move |call, job| {
            if call.op == "complete" && call.attempt == closing {
                let _ = complete_tx.lock().expect("the signal").send(());
                // The child's close is in flight while the cancel arrives.
                return Reply::Later(
                    Duration::from_secs(1),
                    call.args["outcome"]["output"].clone(),
                );
            }
            admitted(call, job)
        }),
    );
    complete_seen.recv_timeout(SOON).expect("the child's close");
    // Not `job.cancel`: CYFR still takes this close, which raced the cancel.
    service.send_line(
        &control::encode(&control::Message::CancelChild {
            execution_id: child.execution_id.clone(),
        })
        .expect("a frame"),
    );
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    assert_eq!(
        answers(&service, &job),
        [json!({"status": "completed", "output": {}})]
    );
    // The child closed as it ran; only the cancel keeps the runner from
    // reuse.
    assert_eq!(ended.last["clean"], json!(false), "{}", ended.last);
}

#[test]
fn a_cancelled_childs_close_cyfr_refuses_ends_nothing() {
    let mut service = Service::start();
    let job = formula(&[
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        ("await", json!("task_1")),
    ]);
    let child = spin(&job, 60_000);
    service.assign(&job, admitting(vec![child.clone()]));
    support::eventually(|| !calls(&service, "fetch_artifact", &child).is_empty());
    service.send_line(&job.cancel(&child));
    let ended = ended(&service, SOON);
    // The cancel fenced it: its refused close is the service's to report.
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    assert_eq!(ended.last["clean"], json!(false));
    assert_eq!(calls(&service, "fail", &child).len(), 1);
    assert_eq!(
        answers(&service, &job)[1]["error"],
        json!({"type": "uncertain", "message": words::CANCELLED})
    );
}

#[test]
fn a_child_admitted_again_while_it_runs_changes_nothing_of_it() {
    let mut service = Service::start();
    let job = formula(&[
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        ("call", run("run", "reagent:local.spin:0.1.0", json!({}))),
        ("cancel", json!("task_1")),
    ]);
    let child = spin(&job, 60_000);
    let twice = child.clone();
    service.assign(
        &job,
        Box::new(move |call, job| match call.op.as_str() {
            // CYFR answers the second admission with the child it admitted
            // first.
            "admit_child" => Reply::Ok(job.admitted(&twice)),
            "release_child" => Reply::Ok(json!(true)),
            _ => standard(call, job),
        }),
    );
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    assert_eq!(ended.last["clean"], json!(false));
    assert_eq!(ended.children.len(), 1, "{:?}", ended.children);
    assert_eq!(
        answers(&service, &job)[1],
        error("dispatch_error", words::CALL_FAILED)
    );
    // The running child is not given back nor failed for the second
    // answer: it closes once, at its own cancel.
    assert!(calls(&service, "release_child", &job).is_empty());
    let fail = calls(&service, "fail", &child);
    assert_eq!(fail.len(), 1, "{:?}", service.ops());
    assert_eq!(fail[0].args["outcome"]["error"], words::CANCELLED);
}

#[test]
fn a_subtree_of_many_children_one_after_another_holds_what_one_holds() {
    let mut service = Service::start();
    let steps: Vec<(&str, Value)> = (0..60)
        .map(|_| ("call", run("run", "reagent:local.echo:0.1.0", json!({}))))
        .collect();
    let job = formula(&steps);
    let children: Vec<Job> = (0..60).map(|_| echo(&job, "{}")).collect();
    service.assign(&job, admitting(children));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["clean"], json!(true), "{}", ended.last);
    assert_eq!(ended.children.len(), 60);
    assert_eq!(service.exit_after_close(SOON).code(), Some(0));
    let errors = service.errors();
    let line = format!(
        "{} completed, holding 0 attempt records, its relay carrying 1 attempts",
        job.execution_id
    );
    assert!(errors.contains(&line), "{errors}");
}

#[test]
fn children_of_one_new_digest_fetch_and_compile_it_once() {
    let mut service = Service::start();
    let job = formula(&[
        ("spawn", run("run", "reagent:local.echo:0.1.0", json!({}))),
        ("spawn", run("run", "reagent:local.echo:0.1.0", json!({}))),
        ("spawn", run("run", "reagent:local.echo:0.1.0", json!({}))),
        ("spawn", run("run", "reagent:local.echo:0.1.0", json!({}))),
        (
            "await-all",
            json!({"task_ids": ["task_1", "task_2", "task_3", "task_4"]}),
        ),
    ]);
    let children: Vec<Job> = (0..4).map(|_| echo(&job, "{}")).collect();
    service.assign(&job, admitting(children.clone()));
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["clean"], json!(true), "{}", ended.last);
    assert_eq!(answers(&service, &job)[4]["count"], json!(4));
    let fetched: usize = children
        .iter()
        .map(|child| calls(&service, "fetch_artifact", child).len())
        .sum();
    assert_eq!(fetched, 1, "{:?}", service.ops());
}

/// The time from the first to the last of `calls` tool calls a formula
/// makes beside `spinners` computing children, its runner held to one
/// processor: each answered at once.
fn tool_calls_beside(spinners: usize, calls: usize) -> Duration {
    let mut service = Service::start_held(1);
    let mut steps: Vec<(&str, Value)> = Vec::new();
    for _ in 0..spinners {
        steps.push(("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))));
    }
    for _ in 0..calls {
        steps.push(("call", json!({"tool": "component", "action": "search"})));
    }
    let mut job = formula(&steps);
    job.timeout_ms = 120_000;
    let children: Vec<Job> = (0..spinners).map(|_| spin(&job, 120_000)).collect();
    let times = Arc::new(Mutex::new(Vec::<Instant>::new()));
    let seen = times.clone();
    let mut admitted = admitting(children);
    service.assign(
        &job,
        Box::new(move |call, job| {
            if call.op == "tool_call" {
                seen.lock().expect("the times").push(Instant::now());
            }
            admitted(call, job)
        }),
    );
    let all = waited(Duration::from_secs(60), || {
        let times = times.lock().expect("the times");
        (times.len() == calls).then(|| times[calls - 1] - times[0])
    });
    all.unwrap_or_else(|| panic!("the {calls} calls did not all come within a minute"))
}

#[test]
fn a_formulas_calls_keep_their_pace_beside_a_computing_sibling_on_one_processor() {
    // A worker serving its timers and I/O only every 61st poll took 17.5 s
    // here for these 40 calls (about 0.6 s a call); serving them at every
    // poll, about 0.6 s for all 40.
    let took = tool_calls_beside(1, 40);
    eprintln!("40 tool calls beside one computing sibling, on one processor: {took:?}");
    assert!(
        took < Duration::from_secs(8),
        "40 calls took {took:?} beside a computing sibling"
    );
}

#[test]
fn a_childs_budget_keeps_its_time_beside_a_computing_sibling_on_one_processor() {
    let mut service = Service::start_held(1);
    let mut job = formula(&[
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        ("await", json!("task_1")),
    ]);
    job.timeout_ms = 60_000;
    // The first child has a budget of one second; the other computes on.
    let timed = spin(&job, 1_000);
    let other = spin(&job, 60_000);
    let at = Arc::new(Mutex::new((None::<Instant>, None::<Instant>)));
    let seen = at.clone();
    let watched = timed.attempt.clone();
    let mut admitted = admitting(vec![timed.clone(), other]);
    service.assign(
        &job,
        Box::new(move |call, job| {
            if call.attempt == watched {
                let mut at = seen.lock().expect("the times");
                match call.op.as_str() {
                    "fetch_artifact" => at.0 = Some(Instant::now()),
                    "fail" => at.1 = Some(Instant::now()),
                    _ => {}
                }
            }
            admitted(call, job)
        }),
    );
    let closed = waited(Duration::from_secs(30), || {
        let at = at.lock().expect("the times");
        match *at {
            (Some(fetched), Some(failed)) => Some(failed - fetched),
            _ => None,
        }
    })
    .expect("the timed child closed within 30 s");
    eprintln!(
        "a 1000 ms budget beside a computing sibling, on one processor: closed {closed:?} after its fetch"
    );
    // Its budget counts from before its fetch: the close comes within a
    // few ticks of it, not 0.5 s late as when timers waited 61 polls.
    assert!(
        closed < Duration::from_millis(1_400),
        "a 1000 ms budget closed {closed:?} after its fetch"
    );
}

/// A formula child of `parent` that spawns `count` tool calls and awaits
/// them all.
fn flooding(parent: &Job, count: usize) -> Job {
    let mut steps: Vec<Value> = (0..count)
        .map(|_| json!({"fn": "spawn", "arg": {"tool": "component", "action": "hold"}}))
        .collect();
    let ids: Vec<String> = (1..=count).map(|n| format!("task_{n}")).collect();
    steps.push(json!({"fn": "await-all", "arg": {"task_ids": ids}}));
    let mut flooder = parent
        .child("formula", PROBE, &json!({ "steps": steps }).to_string())
        .bound(json!({"max_concurrent_tasks": count, "batch_timeout": "170s", "timeout": "175s"}));
    flooder.intercepted = vec!["execution.run".to_owned()];
    flooder.timeout_ms = 175_000;
    flooder
}

#[test]
fn guests_held_calls_never_keep_a_siblings_close_from_the_relay() {
    let mut service = Service::start();
    let mut job = formula(&[
        ("spawn", run("run", "reagent:local.spin:0.1.0", json!({}))),
        ("spawn", run("run", "formula:local.flood:0.1.0", json!({}))),
        ("spawn", run("run", "formula:local.flood:0.1.0", json!({}))),
        ("await", json!("task_1")),
    ])
    .bound(json!({"max_concurrent_tasks": 4, "batch_timeout": "170s", "timeout": "180s"}));
    job.intercepted = vec!["execution.run".to_owned()];
    job.timeout_ms = 180_000;
    let spinner = spin(&job, 3_000);
    let (a, b) = (flooding(&job, 50), flooding(&job, 50));
    let held = Arc::new(Mutex::new(0usize));
    let counted = held.clone();
    let failed = Arc::new(Mutex::new(None::<Instant>));
    let closed = failed.clone();
    let spinning = spinner.attempt.clone();
    let mut admitted = admitting(vec![spinner.clone(), a, b]);
    let started = Instant::now();
    service.assign(
        &job,
        Box::new(move |call, job| {
            if call.op == "tool_call" {
                *counted.lock().expect("held") += 1;
                return Reply::Silent;
            }
            if call.op == "fail" && call.attempt == spinning {
                *closed.lock().expect("closed") = Some(Instant::now());
            }
            admitted(call, job)
        }),
    );
    let at = waited(Duration::from_secs(40), || *failed.lock().expect("closed"));
    let held = *held.lock().expect("held");
    let at =
        at.unwrap_or_else(|| panic!("the sibling's close never came beside {held} held calls"));
    eprintln!(
        "{held} guests' calls held: the sibling's close came {:?} after the assign",
        at - started
    );
    // Its 3 s budget, its compile and the formulas' starts: far short of
    // the 60 s two lost tries of its close would take.
    assert!(
        at - started < Duration::from_secs(25),
        "the sibling's close came {:?} after the assign",
        at - started
    );
    assert_eq!(held, cyfr_runner::relay::MAX_GUEST_CALLS, "the calls held");
}

/// The most the runner may peak at for four 300 KB results held, each
/// held as its bytes: about 72 MiB here, a formula's own runner included.
/// Each held as a parsed tree, as the runner did before, holds about 11 MiB
/// more apiece.
const RESULTS_PEAK_KIB: u64 = 96 * 1024;

#[test]
fn a_formulas_unawaited_results_are_held_as_bytes() {
    let mut service = Service::start();
    // Four tool calls each answered with 300 KB of small numbers, their
    // results held unawaited until the formula returns.
    let numbers: Value =
        serde_json::from_str(&format!("{{\"a\":[{}0]}}", "0,".repeat(150_000))).expect("JSON");
    let tool = |action: &str| json!({"tool": "component", "action": action});
    let mut steps: Vec<(&str, Value)> = (0..4).map(|_| ("spawn", tool("big"))).collect();
    steps.push(("call", tool("wait")));
    let job = formula(&steps);
    let held = Arc::new(Mutex::new(false));
    let all_held = held.clone();
    service.assign(
        &job,
        Box::new(
            move |call, job| match call.args["args"]["action"].as_str() {
                Some("big") if call.op == "tool_call" => Reply::Ok(numbers.clone()),
                // Answered once the runner has each of the four results, so
                // they are its, held unawaited, as the formula returns.
                Some("wait") if call.op == "tool_call" => {
                    let held = all_held.clone();
                    Reply::When(Box::new(move || *held.lock().expect("held")), json!(true))
                }
                _ => standard(call, job),
            },
        ),
    );
    // Each spawned call queues its event in the same step that hands its
    // result on, after the host has taken its outcome.
    let mut events = 0;
    while events < 4 {
        let line = service.line(SOON);
        if line["name"] == "mcp_tool.call" && line["metadata"]["tool_action"] == "component.big" {
            events += 1;
        }
    }
    *held.lock().expect("held") = true;
    let ended = ended(&service, SOON);
    let (resident, peak) = (
        support::resident_kib(service.pid()),
        support::peak_kib(service.pid()),
    );
    assert_eq!(service.exit_after_close(SOON).code(), Some(0));
    eprintln!("four unawaited 300 KB results: resident {resident} KiB, peak {peak} KiB");
    assert_eq!(
        ended.last["clean"],
        json!(true),
        "{}: {}",
        ended.last,
        service.errors()
    );
    assert!(
        peak < RESULTS_PEAK_KIB,
        "the runner peaked at {peak} KiB, past {RESULTS_PEAK_KIB}"
    );
}

#[test]
fn a_release_answered_past_the_depth_bound_leaves_the_runner_not_clean() {
    let mut service = Service::start();
    let parent = formula(&[("call", run("run", "reagent:local.echo:0.1.0", json!({})))]);
    let child = echo(&parent, "{}");
    let deep = format!(
        r#"{{"v":3,"ok":{}}}"#,
        support::nested(cyfr_runner::wire::MAX_DEPTH)
    );
    service.assign(
        &parent,
        Box::new(move |call, job| match call.op.as_str() {
            "admit_child" => {
                let mut answer = job.admitted(&child);
                answer["input"] = json!("null");
                Reply::Ok(answer)
            }
            "release_child" => Reply::Plain(deep.clone().into_bytes()),
            _ => standard(call, job),
        }),
    );
    let frames = ended(&service, SOON);
    assert_eq!(calls(&service, "release_child", &parent).len(), 1);
    assert_eq!(frames.last["clean"], json!(false), "{}", frames.last);
}

#[test]
fn a_call_answered_past_the_depth_bound_leaves_the_runner_not_clean() {
    let mut service = Service::start();
    let parent = formula(&[("call", json!({"tool": "component", "action": "deep"}))]);
    let deep = format!(
        r#"{{"v":3,"ok":{}}}"#,
        support::nested(cyfr_runner::wire::MAX_DEPTH)
    );
    service.assign(
        &parent,
        Box::new(move |call, job| match call.op.as_str() {
            "tool_call" => Reply::Plain(deep.clone().into_bytes()),
            _ => standard(call, job),
        }),
    );
    let frames = ended(&service, SOON);
    // The formula's run ends at the answer it cannot read, in its words;
    // what CYFR did for the call is not known.
    assert_eq!(
        calls(&service, "fail", &parent)[0].args["outcome"]["error"],
        words::answer_too_deep("tool_call")
    );
    assert_eq!(frames.last["clean"], json!(false), "{}", frames.last);
}

// The guest error vectors' setup refusals (tests/fixtures/guest_error.json's
// `setup_required`): CYFR refuses a formula's call with the case's message
// and remediation, and the formula is answered the case's envelope, the
// remediation handed on as CYFR gave it.
#[test]
fn a_call_refused_with_a_setup_remediation_answers_every_vector_cases_envelope() {
    let vectors = support::fixture("guest_error.json");
    let cases = vectors["setup_required"]
        .as_array()
        .expect("setup_required");
    assert!(!cases.is_empty());
    let refusals: Vec<Value> = cases
        .iter()
        .map(|case| {
            json!({"type": "setup_required", "message": case["message"],
                   "remediation": case["remediation"]})
        })
        .collect();
    let steps: Vec<(&str, Value)> = (0..cases.len())
        .map(|n| {
            (
                "call",
                json!({"tool": "component", "action": format!("setup_{n}"), "args": {}}),
            )
        })
        .collect();
    let mut service = Service::start();
    let job = formula(&steps);
    service.assign(
        &job,
        Box::new(move |call: &support::Call, job: &Job| {
            let action = call.args["args"]["action"].as_str().unwrap_or("");
            match action
                .strip_prefix("setup_")
                .and_then(|n| n.parse::<usize>().ok())
            {
                Some(n) if call.op == "tool_call" => {
                    Reply::Error("guest_error", refusals[n].clone())
                }
                _ => standard(call, job),
            }
        }),
    );
    let ended = ended(&service, SOON);
    assert_eq!(ended.last["type"], "complete", "{}", ended.last);
    let expected: Vec<Value> = cases.iter().map(|case| case["answer"].clone()).collect();
    assert_eq!(answers(&service, &job), expected);
}
