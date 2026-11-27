// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The real binary against a scripted service end (`support`): a reagent
//! and a catalyst from `assign` to `complete`, the runner's identity taken
//! from its environment, and each way a runner's subtree or the runner
//! itself ends.

mod support;

use std::time::Duration;

use serde_json::{Value, json};

use cyfr_runner::control::Message;
use support::{HOSTILE, Job, Reply, Service, TEST_WASM, standard};

const SOON: Duration = Duration::from_secs(60);

#[test]
fn a_reagent_runs_from_assign_to_complete() {
    let mut service = Service::start();
    let job = Job::new(
        "reagent",
        &format!("{TEST_WASM}/echo.wasm"),
        r#"{"a":1,"b":[2,3]}"#,
    );
    service.assign(&job, Box::new(standard));
    let complete = service.frame(SOON);
    assert_eq!(
        complete,
        json!({"v": 1, "type": "complete", "execution_id": job.execution_id, "clean": true})
    );
    assert_eq!(service.ops(), ["attach", "fetch_artifact", "complete"]);
    let complete = &service.calls_of("complete")[0];
    assert_eq!(
        complete.args,
        json!({"outcome": {"attempt": job.attempt, "execution_id": job.execution_id, "fence": 2,
                           "output": {"a": 1, "b": [2, 3]}, "status": "completed"}})
    );
    // Every call presents the runner and the boot its environment names.
    assert_eq!(complete.attempt, job.attempt);
    service.close_control();
    assert_eq!(service.exit(SOON).code(), Some(0));
}

#[test]
fn a_catalyst_reads_its_vault_and_reports_each_refusal_once() {
    let mut service = Service::start();
    let job = Job::new("catalyst", &format!("{HOSTILE}/vault_probe.wasm"), "{}");
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "attach" => Reply::Ok(json!({"PROBE_KEY": "the-value"})),
            _ => standard(call, job),
        }),
    );
    let complete = service.frame(SOON);
    assert_eq!(complete["clean"], Value::Bool(true), "{complete}");
    let output = &service.calls_of("complete")[0].args["outcome"]["output"];
    assert_eq!(output, &json!({"status": 200, "data": {"read": "OEEE"}}));
    // The ungranted name is reported; the overlong and the control-byte
    // names are refused unreported.
    let denials: Vec<Value> = service
        .calls_of("record_denial")
        .into_iter()
        .map(|call| call.args)
        .collect();
    assert_eq!(
        denials,
        [json!({"message": "PROBE_HIDDEN", "type": "secret_denied"})]
    );
}

/// Run `job` to its close under `script`, answering the `fail` CYFR was
/// asked to record, or none for a completed run.
fn failed(job: &Job) -> (Service, Value, Option<Value>) {
    let mut service = Service::start();
    service.assign(job, Box::new(standard));
    let frame = service.frame(SOON);
    let fail = service
        .calls_of("fail")
        .first()
        .map(|call| call.args["outcome"].clone());
    (service, frame, fail)
}

#[test]
fn a_trap_closes_the_attempt_in_the_traps_own_words() {
    let job = Job::new(
        "reagent",
        &format!("{HOSTILE}/trapper.wasm"),
        r#"{"trap":true}"#,
    );
    let (_service, frame, fail) = failed(&job);
    assert_eq!(frame["clean"], true);
    let fail = fail.expect("a fail");
    assert_eq!(
        fail["error"],
        "Component call failed for cyfr:reagent/compute@0.1.0: wasm trap: wasm `unreachable` \
         instruction executed"
    );
    assert_eq!(fail["abandoned"], false);
}

#[test]
fn a_run_past_its_budget_is_stopped_and_its_runner_is_not_clean() {
    let mut job = Job::new("reagent", &format!("{TEST_WASM}/spin.wasm"), "{}");
    job.timeout_ms = 1_000;
    let (_service, frame, fail) = failed(&job);
    assert_eq!(
        frame,
        json!({"v": 1, "type": "complete", "execution_id": job.execution_id, "clean": false})
    );
    let fail = fail.expect("a fail");
    assert_eq!(fail["error"], "Execution timeout after 1000ms");
    assert_eq!(fail["abandoned"], true);
}

#[test]
fn the_store_refuses_a_second_memory_and_a_table_past_its_bound_in_the_engines_words() {
    // D4 (b): the store's first crossing, in the engine's words, which name
    // the count or size crossed and nothing of the guest's.
    for (guest, words) in [
        (
            "extra_memory",
            "resource limit exceeded: memory count too high at 2",
        ),
        (
            "wide_table",
            "table minimum size of 20001 elements exceeds table limits",
        ),
    ] {
        let job = Job::new("reagent", &format!("{HOSTILE}/{guest}.wasm"), "{}");
        let (_service, frame, fail) = failed(&job);
        assert_eq!(frame["clean"], true, "{guest}");
        assert_eq!(
            fail.expect("a fail")["error"],
            format!("Component instantiation failed: {words}"),
            "{guest}"
        );
    }
    // A refused growth answers the guest -1: it reaches the bounds exactly.
    let job = Job::new("reagent", &format!("{HOSTILE}/grower.wasm"), "{}");
    let (service, _frame, _fail) = failed(&job);
    let output = &service.calls_of("complete")[0].args["outcome"]["output"];
    assert_eq!(output, &json!({"pages": 1024, "table": 20000}));
}

#[test]
fn a_components_bytes_run_only_when_they_are_its_digest() {
    let mut service = Service::start();
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "fetch_artifact" => Reply::Ok(Value::String(cyfr_runner::wire::encode_base64(
                &support::bytes(&format!("{TEST_WASM}/spin.wasm")),
            ))),
            _ => standard(call, job),
        }),
    );
    service.frame(SOON);
    assert_eq!(
        service.calls_of("fail")[0].args["outcome"]["error"],
        "Execution error: the component's bytes do not match its digest"
    );
}

#[test]
fn a_component_whose_bytes_are_not_answered_fails_to_fetch() {
    let mut service = Service::start();
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "fetch_artifact" => Reply::Error("not_found", json!({})),
            _ => standard(call, job),
        }),
    );
    service.frame(SOON);
    assert_eq!(
        service.calls_of("fail")[0].args["outcome"]["error"],
        "Execution error: the component's bytes could not be fetched"
    );
}

#[test]
fn a_close_cyfr_refuses_ends_the_runner_with_an_exit_naming_the_attempt() {
    let mut service = Service::start();
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "complete" => Reply::Error("lost", json!({})),
            _ => standard(call, job),
        }),
    );
    let exit = service.frame(SOON);
    assert_eq!(
        exit,
        json!({"v": 1, "type": "exit", "runner": support::RUNNER, "open": [job.attempt]})
    );
    assert_eq!(service.exit(SOON).code(), Some(1));
}

#[test]
fn an_attach_cyfr_refuses_leaves_the_attempt_open_and_ends_the_runner() {
    let mut service = Service::start();
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "attach" => Reply::Error("claim_expired", json!({})),
            _ => standard(call, job),
        }),
    );
    let exit = service.frame(SOON);
    assert_eq!(exit["type"], "exit");
    assert_eq!(exit["open"], json!([job.attempt]));
    assert_eq!(service.ops(), ["attach"]);
    assert_eq!(service.exit(SOON).code(), Some(1));
}

#[test]
fn an_attach_cyfr_answers_with_a_required_setup_has_closed_the_attempt() {
    let mut service = Service::start();
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "attach" => Reply::Error("setup_required", json!({"payload": {"kind": "consent"}})),
            _ => standard(call, job),
        }),
    );
    let complete = service.frame(SOON);
    assert_eq!(complete["type"], "complete");
    assert_eq!(complete["clean"], true);
    assert_eq!(service.ops(), ["attach"]);
}

#[test]
fn the_relays_end_ends_the_runner_with_an_exit_naming_what_it_held() {
    let mut service = Service::start();
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "fetch_artifact" => Reply::Close,
            _ => standard(call, job),
        }),
    );
    let exit = service.frame(SOON);
    assert_eq!(
        exit,
        json!({"v": 1, "type": "exit", "runner": support::RUNNER, "open": [job.attempt]})
    );
    assert_eq!(service.exit(SOON).code(), Some(1));
}

#[test]
fn the_relays_end_while_a_guest_runs_ends_the_runner_at_once() {
    // The guest spins and makes no call: only the relay's end tells the
    // runner it can reach nothing, well before the run's budget.
    let mut service = Service::start();
    let job = Job::new("reagent", &format!("{TEST_WASM}/spin.wasm"), "{}");
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "fetch_artifact" => Reply::OkThenEnd(Value::String(cyfr_runner::wire::encode_base64(
                &job.component,
            ))),
            _ => standard(call, job),
        }),
    );
    let exit = service.frame(Duration::from_secs(10));
    assert_eq!(
        exit,
        json!({"v": 1, "type": "exit", "runner": support::RUNNER, "open": [job.attempt]})
    );
    assert_eq!(service.exit(SOON).code(), Some(1));
}

#[test]
fn an_assignment_for_another_service_ends_the_runner_unread() {
    let mut service = Service::start_with(&[("RUNTIME_SERVICE_ID", "wrk_another")]);
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    service.assign(&job, Box::new(standard));
    assert_eq!(service.exit(SOON).code(), Some(1));
    assert!(service.rest(Duration::from_millis(200)).is_empty());
    assert!(service.ops().is_empty());
}

#[test]
fn the_channels_end_while_a_subtree_runs_ends_the_runner_once_it_completes() {
    let mut service = Service::start();
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    service.assign(&job, Box::new(standard));
    service.close_control();
    let complete = service.frame(SOON);
    assert_eq!(complete["type"], "complete");
    assert_eq!(service.exit(SOON).code(), Some(0));
}

#[test]
fn the_runner_sends_its_engine_event_and_its_storage_events_on_its_control_channel() {
    let mut service = Service::start();
    let mut job = Job::new("catalyst", &format!("{HOSTILE}/storage_flood.wasm"), "{}");
    job.timeout_ms = 300;
    service.assign(&job, Box::new(standard));
    let event = service.line(SOON);
    assert_eq!(
        event,
        json!({"v": 1, "type": "event", "name": "engine.authority_entered", "measurements": {},
               "metadata": {"execution_id": job.execution_id, "reference": job.reference}})
    );
    let mut storage = service.line(SOON);
    let duration = storage["measurements"]["duration_ms"].take();
    assert!(duration.is_u64(), "{duration}");
    assert_eq!(
        storage,
        json!({"v": 1, "type": "event", "name": "storage.call", "measurements": {"duration_ms": null},
               "metadata": {"component_ref": job.reference, "action": "unknown", "status": "error"}})
    );
}

#[test]
fn a_denial_report_whose_answer_is_lost_is_sent_once_and_the_run_goes_on() {
    // record_denial is never asked again: its lost answer leaves it
    // uncertain, and the guest is told it was refused all the same.
    let mut service = Service::start();
    let job = Job::new("catalyst", &format!("{HOSTILE}/vault_probe.wasm"), "{}");
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "attach" => Reply::Ok(json!({"PROBE_KEY": "the-value"})),
            "record_denial" => Reply::Dropped,
            _ => standard(call, job),
        }),
    );
    let complete = service.frame(SOON);
    // What the report did is unknown, so the runner is not reused.
    assert_eq!(
        complete,
        json!({"v": 1, "type": "complete", "execution_id": job.execution_id, "clean": false})
    );
    assert_eq!(service.calls_of("record_denial").len(), 1);
    let output = &service.calls_of("complete")[0].args["outcome"]["output"];
    assert_eq!(output, &json!({"status": 200, "data": {"read": "OEEE"}}));
    // Uncertain, never asked again: not lost after a second try.
    service.close_control();
    let _ = service.exit(SOON);
    assert!(
        service.errors().contains(&format!(
            "{}'s record_denial ended uncertain",
            job.execution_id
        )),
        "{}",
        service.errors()
    );
}

#[test]
fn a_renewal_whose_answer_is_lost_is_sent_again_and_the_run_goes_on() {
    // The one case that waits a whole lease tick (60 s): no setting exists
    // to shorten it.
    let mut service = Service::start();
    let mut job = Job::new("reagent", &format!("{TEST_WASM}/spin.wasm"), "{}");
    job.timeout_ms = 62_000;
    let mut renewals = 0;
    service.assign(
        &job,
        Box::new(move |call, job| match call.op.as_str() {
            "renew" => {
                renewals += 1;
                if renewals == 1 {
                    Reply::Dropped
                } else {
                    standard(call, job)
                }
            }
            _ => standard(call, job),
        }),
    );
    let complete = service.frame(Duration::from_secs(120));
    assert_eq!(complete["clean"], false);
    let renewals = service.calls_of("renew");
    assert_eq!(renewals.len(), 2);
    // Asked again under a fresh header: another nonce and signature, the
    // same body.
    assert_ne!(renewals[0].header, renewals[1].header);
    assert_eq!(renewals[0].args, renewals[1].args);
    let fail = &service.calls_of("fail")[0].args["outcome"];
    assert_eq!(fail["error"], "Execution timeout after 62000ms");
}

// ============================================================================
// A document nested past the depth it is read to
// ============================================================================

use cyfr_runner::wire::{MAX_DEPTH, MAX_OUTPUT_DEPTH};

#[test]
fn a_guests_output_at_the_depth_bound_is_read_and_one_past_it_is_refused() {
    // The test reads the output as CYFR does, at any depth, so it runs on a
    // stack of its own.
    support::deep_stack(guests_output_at_the_bound);
}

fn guests_output_at_the_bound() {
    // nested_output answers its input's length in nested arrays.
    let input = |depth: usize| format!(r#"{{"p":"{}"}}"#, "x".repeat(depth - 8));
    // A guest's output is read one level under the bound, so CYFR's answer
    // recording it reads too.
    let job = Job::new(
        "reagent",
        &format!("{HOSTILE}/nested_output.wasm"),
        &input(MAX_OUTPUT_DEPTH),
    );
    let (service, frame, fail) = failed(&job);
    assert_eq!(
        frame["type"],
        "complete",
        "{}; {:?}",
        service.errors(),
        service.ops()
    );
    assert!(fail.is_none(), "{fail:?}");
    let output = &service.calls_of("complete")[0].args["outcome"]["output"];
    assert_eq!(output.to_string(), support::nested(MAX_OUTPUT_DEPTH));

    let job = Job::new(
        "reagent",
        &format!("{HOSTILE}/nested_output.wasm"),
        &input(MAX_OUTPUT_DEPTH + 1),
    );
    let (_service, frame, fail) = failed(&job);
    assert_eq!(frame["type"], "complete");
    assert_eq!(
        fail.expect("a fail")["error"],
        format!(
            "Component returned invalid JSON output: it is nested deeper than {MAX_OUTPUT_DEPTH} levels"
        )
    );
}

#[test]
fn a_host_answer_at_the_depth_bound_is_read_and_one_past_it_ends_the_attempt() {
    // An answer nested past the bound ends its attempt in a sentence, and
    // the runner goes on: its fetch's answer here, `{"v":3,"ok":[...]}`.
    for (depth, error) in [
        (
            MAX_DEPTH,
            "Execution error: the component's bytes could not be fetched".to_owned(),
        ),
        (
            MAX_DEPTH + 1,
            format!(
                "Execution error: CYFR's answer to fetch_artifact is nested deeper than {MAX_DEPTH} levels"
            ),
        ),
    ] {
        let mut service = Service::start();
        let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
        let answer = format!(r#"{{"v":3,"ok":{}}}"#, support::nested(depth - 1));
        service.assign(
            &job,
            Box::new(move |call, job| match call.op.as_str() {
                "fetch_artifact" => Reply::Plain(answer.clone().into_bytes()),
                _ => standard(call, job),
            }),
        );
        let frame = service.frame(SOON);
        assert_eq!(frame["type"], "complete", "{depth}");
        assert_eq!(
            service.calls_of("fetch_artifact").len(),
            1,
            "never asked again"
        );
        assert_eq!(
            service.calls_of("fail")[0].args["outcome"]["error"],
            error,
            "{depth}"
        );
        service.close_control();
        assert_eq!(service.exit(SOON).code(), Some(0), "{depth}");
    }
}

#[test]
fn a_control_line_nested_past_the_depth_bound_is_refused_and_the_runner_goes_on() {
    let mut service = Service::start();
    // Read at the bound (and refused for its missing version), refused
    // unread one past it; neither ends the runner.
    for depth in [MAX_DEPTH, MAX_DEPTH + 1] {
        let line = format!(r#"{{"x":{}}}"#, support::nested(depth - 1));
        service.send_line(format!("{line}\n").as_bytes());
    }
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    service.assign(&job, Box::new(standard));
    assert_eq!(service.frame(SOON)["type"], "complete");
    service.close_control();
    assert_eq!(service.exit(SOON).code(), Some(0));
    let errors = service.errors();
    assert!(errors.contains("not a frame: BadVersion"), "{errors}");
    assert!(errors.contains("not a frame: Malformed"), "{errors}");
}

#[test]
fn a_relay_frame_nested_past_the_depth_bound_closes_the_relay_and_ends_the_runner_in_order() {
    let mut service = Service::start();
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    let frame = format!(r#"{{"v":1,"x":{}}}"#, support::nested(MAX_DEPTH));
    service.assign(
        &job,
        Box::new(move |call, job| match call.op.as_str() {
            "fetch_artifact" => Reply::Frame(frame.clone().into_bytes()),
            _ => standard(call, job),
        }),
    );
    let exit = service.frame(SOON);
    assert_eq!(
        exit,
        json!({"v": 1, "type": "exit", "runner": support::RUNNER, "open": [job.attempt]})
    );
    assert_eq!(service.exit(SOON).code(), Some(1));
}

#[test]
fn the_relays_reader_refuses_a_frame_past_the_depth_bound_unread() {
    // Read at the bound on the stack every reader of the runner has.
    support::deep_stack(relay_frames_at_the_bound);
}

fn relay_frames_at_the_bound() {
    use cyfr_runner::relay::{Channel, Refusal};
    for (depth, refusal) in [
        (MAX_DEPTH, Refusal::BadVersion),
        (MAX_DEPTH + 1, Refusal::Malformed),
    ] {
        let json = format!(r#"{{"x":{}}}"#, support::nested(depth - 1));
        let mut frame = u32::try_from(json.len())
            .expect("a frame")
            .to_be_bytes()
            .to_vec();
        frame.extend_from_slice(json.as_bytes());
        let mut channel = Channel::new("att_test").expect("a channel");
        assert_eq!(channel.decode(&frame), Err(refusal), "{depth}");
    }
}

// ============================================================================
// The lease watch
// ============================================================================

use cyfr_runner::attempt::{Renewal, renew, watch};
use support::Scripted;

fn scripted(script: support::Script) -> Scripted {
    Scripted {
        job: Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}"),
        script,
        calls: Vec::new(),
    }
}

#[tokio::test(start_paused = true)]
async fn a_renewal_pushes_the_watch_out_to_the_lease_cyfr_answered() {
    let mut post = scripted(Box::new(|call, _job| {
        Reply::Ok(json!({ call.attempt.clone(): {"lease_until": 5_000} }))
    }));
    let caller = support::caller(&post.job);
    let attempt = post.job.attempt.clone();
    assert_eq!(
        renew(&mut post, &caller, &attempt, 1_000, 500).await,
        Renewal::Renewed(5_000)
    );
    assert_eq!(post.calls[0].args, json!({"attempts": [attempt]}));
}

#[tokio::test(start_paused = true)]
async fn a_renewal_cyfr_refuses_lapses_the_watch_at_once_inside_the_lease_last_held() {
    let mut post = scripted(Box::new(|call, _job| {
        Reply::Ok(json!({ call.attempt.clone(): "lost" }))
    }));
    let caller = support::caller(&post.job);
    let attempt = post.job.attempt.clone();
    assert_eq!(
        renew(&mut post, &caller, &attempt, 10_000, 500).await,
        Renewal::Lapsed
    );
    // The same job's keys, answered with CYFR's own refusal.
    let mut post = Scripted {
        job: post.job.clone(),
        script: Box::new(|_call, _job| Reply::Error("lost", json!({}))),
        calls: Vec::new(),
    };
    assert_eq!(
        renew(&mut post, &caller, &attempt, 10_000, 500).await,
        Renewal::Lapsed
    );
}

#[tokio::test(start_paused = true)]
async fn a_store_that_cannot_answer_is_tolerated_only_while_the_lease_last_held_holds() {
    let mut post = scripted(Box::new(|_call, _job| {
        Reply::Error("unavailable", json!({}))
    }));
    let caller = support::caller(&post.job);
    let attempt = post.job.attempt.clone();
    assert_eq!(
        renew(&mut post, &caller, &attempt, 1_000, 999).await,
        Renewal::Held
    );
    assert_eq!(
        renew(&mut post, &caller, &attempt, 1_000, 1_000).await,
        Renewal::Lapsed
    );
}

#[tokio::test(start_paused = true)]
async fn a_host_that_does_not_answer_lapses_the_watch_whatever_the_lease_last_held() {
    let mut post = scripted(Box::new(|_call, _job| Reply::Dropped));
    let caller = support::caller(&post.job);
    let attempt = post.job.attempt.clone();
    assert_eq!(
        renew(&mut post, &caller, &attempt, u64::MAX, 0).await,
        Renewal::Lapsed
    );
    // renew is asked once more after a lost answer, then lost.
    assert_eq!(post.calls.len(), 2);
}

#[tokio::test(start_paused = true)]
async fn the_watch_renews_every_minute_until_its_lease_lapses() {
    let mut renewals = 0;
    let mut post = scripted(Box::new(move |call, _job| {
        renewals += 1;
        if renewals < 3 {
            Reply::Ok(json!({ call.attempt.clone(): {"lease_until": u64::MAX >> 12} }))
        } else {
            Reply::Error("lost", json!({}))
        }
    }));
    let caller = support::caller(&post.job);
    let attempt = post.job.attempt.clone();
    let started = tokio::time::Instant::now();
    watch(&mut post, &caller, &attempt, 0).await;
    assert_eq!(started.elapsed(), Duration::from_secs(180));
    assert_eq!(post.calls.len(), 3);
}

// ============================================================================
// The classifier, through the binary
// ============================================================================

#[test]
fn a_component_is_refused_for_a_feature_for_invalid_bytes_or_by_the_engines_compile() {
    let v = support::fixture("component_features.json");
    let sentence = |name: &str, digest: &str| {
        v["sentences"][name]
            .as_str()
            .expect("a sentence")
            .replace("{digest}", digest)
    };
    // Policy-refused: valid only with component-model async.
    let job = Job::new("reagent", &format!("{HOSTILE}/async_lift.wasm"), "{}");
    let (_service, _frame, fail) = failed(&job);
    assert_eq!(
        fail.expect("a fail")["error"],
        sentence("component_feature_refused", &job.digest())
    );
    // Invalid: no WebAssembly with any feature.
    let mut job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    job.component = b"not wasm".to_vec();
    let (_service, _frame, fail) = failed(&job);
    assert_eq!(
        fail.expect("a fail")["error"],
        sentence("component_invalid", &job.digest())
    );
    // Admitted, and not compiled: a core module is valid WebAssembly.
    let job = Job::new("reagent", &format!("{TEST_WASM}/math.wasm"), "{}");
    let (_service, _frame, fail) = failed(&job);
    let error = fail.expect("a fail")["error"]
        .as_str()
        .expect("a sentence")
        .to_owned();
    assert!(
        error.starts_with("Component compilation failed: "),
        "{error}"
    );
    assert!(
        error.ends_with(". Ensure the component is compiled as a WASI P2 Component Model binary."),
        "{error}"
    );
}

#[test]
fn a_shipped_catalyst_runs_its_describe() {
    let job = Job::new(
        "catalyst",
        "seed/components/catalysts/local/claude/1.4.4/catalyst.wasm",
        r#"{"operation":"describe","params":{}}"#,
    );
    let (service, frame, fail) = failed(&job);
    assert_eq!(frame["clean"], true);
    assert!(fail.is_none(), "{fail:?}");
    let output = &service.calls_of("complete")[0].args["outcome"]["output"];
    assert_eq!(output["data"]["contracts"], json!(["model/chat@1"]));
}

// ============================================================================
// What a guest can make the runner hold or write
// ============================================================================

/// The most resident memory a runner (built for its tests) holds while a
/// guest floods it with events: what it holds running an ordinary
/// catalyst, and room besides.
const FLOOD_RESIDENT_KIB: u64 = 192 * 1024;

#[test]
fn a_guest_flooding_its_events_is_paced_and_its_close_follows_its_fail() {
    let mut service = Service::start();
    let mut job = Job::new("catalyst", &format!("{HOSTILE}/storage_flood.wasm"), "{}");
    job.timeout_ms = 3_000;
    service.assign(&job, Box::new(standard));
    let pid = service.pid();
    let mut highest = 0;
    let mut events = 0u64;
    let mut failed_at = None;
    let frame = loop {
        highest = highest.max(support::resident_kib(pid));
        if failed_at.is_none() && !service.calls_of("fail").is_empty() {
            failed_at = Some(std::time::Instant::now());
        }
        let line = service.line(SOON);
        if line["type"] != "event" {
            break line;
        }
        events += 1;
    };
    let closed = failed_at.map(|at| at.elapsed()).unwrap_or_default();
    eprintln!(
        "flood: {events} events, at most {highest} KiB resident, complete {closed:?} after fail"
    );
    assert_eq!(frame["type"], "complete", "{frame}");
    assert!(events > 1, "the guest's events reached the service");
    assert!(
        highest < FLOOD_RESIDENT_KIB,
        "the runner held {highest} KiB, past {FLOOD_RESIDENT_KIB}"
    );
    // The close waits behind at most the queue's lines.
    assert!(
        closed < Duration::from_secs(2),
        "complete came {closed:?} after fail"
    );
    assert_eq!(
        service.calls_of("fail")[0].args["outcome"]["error"],
        "Execution timeout after 3000ms"
    );
}

#[test]
fn a_guest_causing_one_log_line_after_another_is_logged_once_with_a_count() {
    let mut service = Service::start();
    let mut job = Job::new("catalyst", &format!("{HOSTILE}/vault_log_flood.wasm"), "{}");
    job.timeout_ms = 1_000;
    service.assign(&job, Box::new(standard));
    assert_eq!(service.frame(SOON)["type"], "complete");
    service.close_control();
    assert_eq!(service.exit(SOON).code(), Some(0));
    let errors = service.errors();
    let named: Vec<&str> = errors
        .lines()
        .filter(|line| line.contains("no field name"))
        .collect();
    assert_eq!(named.len(), 2, "{errors}");
    assert!(
        named[0].contains("asked its vault for a name that is no field name"),
        "{errors}"
    );
    assert!(
        named[1].starts_with(&format!(
            "cyfr-runner: {} logged a name that is no field name ",
            job.execution_id
        )) && named[1].ends_with(" more times"),
        "{errors}"
    );
    assert!(errors.len() < 4096, "{} bytes of log", errors.len());
}

// ============================================================================
// Compiles, budgets and the engine's own refusals
// ============================================================================

#[test]
fn a_budget_ends_its_attempt_whatever_the_compile_thread_is_doing() {
    // slow_validate takes seconds to validate and compile; nothing of that
    // runs on the runner's own thread, so the budget ends the run on time
    // and the runner is not reused.
    let mut service = Service::start();
    let mut job = Job::new("reagent", &format!("{HOSTILE}/slow_validate.wasm"), "{}");
    job.timeout_ms = 300;
    let started = std::time::Instant::now();
    service.assign(&job, Box::new(standard));
    let complete = service.frame(SOON);
    let took = started.elapsed();
    eprintln!("slow_validate: closed {took:?} after its assign under a 300 ms budget");
    assert_eq!(
        complete,
        json!({"v": 1, "type": "complete", "execution_id": job.execution_id, "clean": false})
    );
    assert_eq!(
        service.calls_of("fail")[0].args["outcome"]["error"],
        "Execution timeout after 300ms"
    );
    assert!(
        took < Duration::from_secs(3),
        "the close came after {took:?}"
    );
}

#[test]
fn a_node_consenting_no_memory_runs_nothing_and_fetches_nothing() {
    let v = support::fixture("authority_wire.json");
    let zero = v["read"]
        .as_array()
        .expect("read")
        .iter()
        .find(|case| case["limits"]["max_memory_bytes"] == 0)
        .expect("a case consenting no memory");
    let mut job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    job.authority = zero["authority"].clone();
    let (service, frame, fail) = failed(&job);
    assert_eq!(frame["type"], "complete");
    assert_eq!(service.ops(), ["attach", "fail"]);
    assert_eq!(
        fail.expect("a fail")["error"],
        "Execution error: the engine raised an internal error"
    );
}

#[test]
fn sockets_are_refused_to_every_guest() {
    let job = Job::new("reagent", &format!("{HOSTILE}/socket_probe.wasm"), "{}");
    let (service, frame, _fail) = failed(&job);
    assert_eq!(frame["type"], "complete");
    let output = &service.calls_of("complete")[0].args["outcome"]["output"];
    // "01" is wasi:sockets/network's access-denied.
    assert_eq!(output, &json!({"tcp": "01", "udp": "01"}));
}

// ============================================================================
// The runner's descriptors
// ============================================================================

#[test]
fn a_control_descriptor_equal_to_the_relays_is_refused_before_either_is_adopted() {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_cyfr-runner"))
        .env_clear()
        .env("RUNTIME_RUNNER_ID", support::RUNNER)
        .env("RUNTIME_SERVICE_ID", support::SERVICE)
        .env("RUNTIME_BOOT_ID", support::BOOT)
        .env("RUNTIME_CONTROL_FD", "4")
        .output()
        .expect("the runner runs");
    assert_eq!(output.status.code(), Some(78));
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        "cyfr-runner: the control descriptor 4 is the relay's\n"
    );
}

#[test]
fn the_runner_adopts_descriptor_3_as_its_control_channel() {
    let mut service = Service::start_on(support::Control::Descriptor3, &[]);
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), r#"{"a":1}"#);
    service.assign(&job, Box::new(standard));
    assert_eq!(service.frame(SOON)["clean"], true);
    service.close_control();
    assert_eq!(service.exit(SOON).code(), Some(0));
}

#[test]
fn nothing_of_the_token_or_the_keys_is_left_in_the_runners_memory_after_its_close() {
    let mut service = Service::start_on(support::Control::Descriptor3, &[]);
    // The input carries what a guest might fetch with.
    let input = "INPUTNEEDLEsk-live-0123456789abcdef";
    let job = Job::new(
        "catalyst",
        &format!("{HOSTILE}/vault_probe.wasm"),
        &json!({"note": input}).to_string(),
    );
    let token = job.token();
    let sent = Message::Assign {
        assignment: zeroize::Zeroizing::new(token.clone()),
        input: zeroize::Zeroizing::new(job.input.clone()),
        keys: job.keys(),
    };
    let line = cyfr_runner::control::encode(&sent).expect("an assign line");
    service.send_line(&line);
    service.serve(
        job.clone(),
        Box::new(|call, job| match call.op.as_str() {
            "attach" => Reply::Ok(json!({"PROBE_KEY": "the-value"})),
            _ => standard(call, job),
        }),
    );
    assert_eq!(service.frame(SOON)["clean"], true);
    let call_hex = cyfr_runner::wire::hex(&job.call_key);
    let seal_hex = cyfr_runner::wire::hex(&job.seal_key);
    let needles: [&[u8]; 7] = [
        support::RUNNER.as_bytes(),
        &token.as_bytes()[..64],
        call_hex.as_bytes(),
        seal_hex.as_bytes(),
        &job.call_key,
        &job.seal_key,
        input.as_bytes(),
    ];
    let found = support::scan(service.pid(), &needles);
    // The scan finds what is there: the runner's own id.
    assert!(found[0] > 0, "the scan read the runner's memory: {found:?}");
    assert_eq!(
        &found[1..],
        &[0, 0, 0, 0, 0, 0],
        "token, keys' hex, keys' bytes, input"
    );
}

// ============================================================================
// One over-long control line, however it arrives
// ============================================================================

#[test]
fn a_control_line_past_its_bound_ends_the_runner_however_it_arrives() {
    use cyfr_runner::control::MAX_LINE_BYTES;
    // One byte past the bound, whose newline arrives in the read that
    // crosses it; and one far past it, whose newline arrives later.
    for length in [MAX_LINE_BYTES + 1, MAX_LINE_BYTES + 512 * 1024] {
        let mut service = Service::start();
        let mut line = vec![b'x'; length];
        line.push(b'\n');
        // The runner may end before it has read the whole line.
        let _ = service.try_send_line(&line);
        assert_eq!(service.exit(SOON).code(), Some(1), "{length}");
        assert!(
            service.errors().contains("past the protocol's bound"),
            "{length}: {}",
            service.errors()
        );
    }
}

// ============================================================================
// A control write that fails
// ============================================================================

/// A control channel that takes every line but `complete`, whose write
/// fails: the service went away as the runner closed its subtree.
struct BrokenPipe;

impl tokio::io::AsyncWrite for BrokenPipe {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        bytes: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        if bytes
            .windows(17)
            .any(|window| window == b"\"type\":\"complete\"")
        {
            std::task::Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into()))
        } else {
            std::task::Poll::Ready(Ok(bytes.len()))
        }
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
}

#[tokio::test]
async fn a_complete_the_control_channel_does_not_take_ends_the_runner_unsent() {
    use cyfr_runner::control::{Environment, Lines, Writer};
    use cyfr_runner::subtree::{RelayAt, serve};
    let dir = std::env::temp_dir().join(format!("cyfr-runner-broken-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a test folder");
    let socket = dir.join("relay.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).expect("the relay socket");
    let job = Job::new("reagent", &format!("{TEST_WASM}/echo.wasm"), "{}");
    let calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let (served, recorded) = (job.clone(), calls.clone());
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().expect("the relay");
        support::relay(stream, served, Box::new(standard), recorded);
    });
    let (mut service_end, runner_end) = tokio::io::duplex(1 << 20);
    let line = cyfr_runner::control::encode(&job.assign()).expect("an assign line");
    tokio::io::AsyncWriteExt::write_all(&mut service_end, &line)
        .await
        .expect("the line is written");
    // The channel ends after the assign: a runner whose complete was
    // written ends with 0 once it completes, one whose complete was not
    // with 1.
    drop(service_end);
    let environment = Environment {
        runner_id: support::RUNNER.to_owned(),
        service_id: support::SERVICE.to_owned(),
        boot: support::BOOT.to_owned(),
        control_fd: 0,
        relay: cyfr_runner::control::Relay::Socket(socket.display().to_string()),
    };
    let engine = cyfr_runner::engine::Engine::new().expect("the engine");
    let status = serve(
        environment,
        engine,
        Lines::new(runner_end),
        Writer::start(BrokenPipe),
        Some(RelayAt::Socket(socket.display().to_string())),
    )
    .await;
    // The attempt closed with CYFR; its complete reached no service, so
    // the runner ends with 1, not with the 0 of a complete that was sent.
    assert_eq!(status, 1);
    let ops: Vec<String> = calls
        .lock()
        .expect("calls")
        .iter()
        .map(|call| call.op.clone())
        .collect();
    assert_eq!(ops, ["attach", "fetch_artifact", "complete"]);
    let _ = std::fs::remove_dir_all(&dir);
}
