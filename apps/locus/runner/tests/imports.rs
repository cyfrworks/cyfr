// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! Each import a catalyst sees, called as the engine calls it, over a real
//! relay whose far end is the scripted service (`support`): what it
//! answers its guest for each answer CYFR gives, and the host calls it
//! makes.

mod support;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use tokio::io::AsyncBufReadExt as _;
use zeroize::Zeroizing;

use cyfr_runner::attempt::Host;
use cyfr_runner::authority::Limits;
use cyfr_runner::control::Writer;
use cyfr_runner::imports::catalyst::cyfr::emit::events::Host as _;
use cyfr_runner::imports::catalyst::cyfr::oauth::token::Host as _;
use cyfr_runner::imports::catalyst::cyfr::question::ask::{Answer, Host as _, Request, Unanswered};
use cyfr_runner::imports::catalyst::cyfr::storage::files::Host as _;
use cyfr_runner::imports::catalyst::cyfr::vault::read::Host as _;
use cyfr_runner::imports::{Ended, Guest, Run};
use cyfr_runner::relay::Relay;
use cyfr_runner::wire::MAX_DEPTH;

use support::{Call, Job, Reply, Script, TEST_WASM};

/// A guest of a run whose host calls the script answers, the calls the
/// script was sent, and the control lines the run's events were written to.
struct Under {
    guest: Guest,
    calls: Arc<Mutex<Vec<Call>>>,
    events: tokio::io::Lines<tokio::io::BufReader<tokio::io::DuplexStream>>,
}

async fn under(
    script: Script,
    limits: Limits,
    fields: &[(&str, &str)],
    attached: &[&str],
) -> Under {
    let job = Job::new("catalyst", &format!("{TEST_WASM}/echo.wasm"), "{}");
    let (ours, theirs) = std::os::unix::net::UnixStream::pair().expect("a socket pair");
    let calls = Arc::new(Mutex::new(Vec::new()));
    let recorded = calls.clone();
    let served = job.clone();
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(move || support::relay(theirs, served, script, recorded))
        .expect("the service end");
    ours.set_nonblocking(true).expect("a nonblocking socket");
    let (reader, writer) = tokio::net::UnixStream::from_std(ours)
        .expect("a socket")
        .into_split();
    let relay = Relay::start(reader, writer);
    relay
        .bind(&job.attempt)
        .await
        .expect("the relay carries the attempt");
    let (lines, written) = tokio::io::duplex(1 << 20);
    let control = Writer::start(written);
    let host = Arc::new(Host::new(
        support::caller(&job),
        relay.clone(),
        control.clone(),
    ));
    let runner = cyfr_runner::attempt::Runner {
        engine: cyfr_runner::engine::Engine::new().expect("an engine"),
        relay,
        control,
        runner_id: support::RUNNER.to_owned(),
        boot: support::BOOT.to_owned(),
        tree: cyfr_runner::subtree::Tree::unserved(support::ATHANOR, &job.execution_id),
    };
    let run = Run {
        host,
        component_ref: job.reference.clone(),
        limits,
        fields: fields
            .iter()
            .map(|(name, value)| ((*name).to_owned(), Zeroizing::new((*value).to_owned())))
            .collect::<BTreeMap<_, _>>(),
        attached: attached
            .iter()
            .map(|name| (*name).to_owned())
            .collect::<BTreeSet<_>>(),
        runner,
        intercepted: Vec::new(),
    };
    Under {
        guest: Guest::new(Arc::new(run)),
        calls,
        events: tokio::io::BufReader::new(lines).lines(),
    }
}

impl Under {
    fn calls(&self) -> Vec<Call> {
        self.calls.lock().expect("the calls").clone()
    }

    async fn event(&mut self) -> Value {
        let line =
            tokio::time::timeout(std::time::Duration::from_secs(10), self.events.next_line())
                .await
                .expect("an event within 10 s")
                .expect("a line")
                .expect("an event");
        serde_json::from_str(&line).expect("a JSON line")
    }
}

/// Run `test` on a current-thread runtime on the stack the runner's own
/// runtime has, which a document read at the depth bound needs.
fn run<F: std::future::Future<Output = ()> + 'static>(test: impl FnOnce() -> F + Send + 'static) {
    std::thread::Builder::new()
        .stack_size(cyfr_runner::wire::STACK_BYTES)
        .spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("a runtime")
                .block_on(test());
        })
        .expect("a test thread")
        .join()
        .expect("the test passes");
}

fn answering(reply: impl Fn(&Call) -> Reply + Send + 'static) -> Script {
    Box::new(move |call, _job| reply(call))
}

fn error(kind: &str, message: &str) -> String {
    json!({"error": {"type": kind, "message": message}}).to_string()
}

// ============================================================================
// cyfr:storage/files
// ============================================================================

#[test]
fn storage_runs_the_guests_operation_and_answers_cyfrs_members() {
    run(|| async {
        let mut under = under(
            answering(|_call| Reply::Ok(json!({"path": "a.txt", "content": "aGk=", "size": 2}))),
            Limits::zero(),
            &[],
            &[],
        )
        .await;
        let answer = under
            .guest
            .call(r#"{"action":"read","path":"a.txt"}"#.to_owned())
            .await
            .expect("an answer");
        assert_eq!(
            serde_json::from_str::<Value>(&answer).expect("JSON"),
            json!({"status": "ok", "path": "a.txt", "content": "aGk=", "size": 2})
        );
        assert_eq!(
            under.calls()[0].args,
            json!({"action": "read", "path": "a.txt"})
        );
        let event = under.event().await;
        assert_eq!(event["name"], "storage.call");
        assert_eq!(event["metadata"]["action"], "read");
        assert_eq!(event["metadata"]["status"], "ok");
    });
}

#[test]
fn storage_refuses_what_does_not_read_before_any_call() {
    run(|| async {
        let mut under = under(
            answering(|_call| Reply::Ok(json!({}))),
            Limits::zero(),
            &[],
            &[],
        )
        .await;
        let deep = format!(
            r#"{{"action":"read","path":{}}}"#,
            support::nested(MAX_DEPTH)
        );
        let bound = Limits::zero().max_request_size as usize;
        for (request, answer) in [
            (
                "x".repeat(bound * 2 + 4096 + 1),
                error(
                    "request_too_large",
                    "Request exceeds the consented max_request_size for this component.",
                ),
            ),
            (
                "{".to_owned(),
                error("invalid_json", "Invalid JSON request"),
            ),
            (
                deep,
                error(
                    "invalid_json",
                    &format!("Request is nested deeper than {MAX_DEPTH} levels"),
                ),
            ),
            (
                "[]".to_owned(),
                error("invalid_request", "Request must include 'action' (string)"),
            ),
            (
                r#"{"action":"move"}"#.to_owned(),
                error(
                    "unknown_action",
                    "Unknown storage action: move. Use: read, write, append, list, delete, or exists",
                ),
            ),
            (
                r#"{"action":"read"}"#.to_owned(),
                error(
                    "invalid_request",
                    "Request must include 'path' (string) for action 'read'",
                ),
            ),
            (
                r#"{"action":"write","path":"a","content":1}"#.to_owned(),
                error("invalid_request", "'content' must be a base64 string."),
            ),
        ] {
            let answered = under.guest.call(request.clone()).await.expect("an answer");
            assert_eq!(answered, answer, "{}", &request[..request.len().min(60)]);
            assert_eq!(under.event().await["metadata"]["status"], "error");
        }
        assert!(under.calls().is_empty());
    });
}

#[test]
fn storage_reads_a_request_at_the_depth_bound() {
    run(|| async {
        let under_bound = format!(
            r#"{{"action":"list","x":{}}}"#,
            support::nested(MAX_DEPTH - 1)
        );
        let mut under = under(
            answering(|_call| Reply::Ok(json!({"files": []}))),
            Limits::zero(),
            &[],
            &[],
        )
        .await;
        let answer = under.guest.call(under_bound).await.expect("an answer");
        assert_eq!(
            serde_json::from_str::<Value>(&answer).expect("JSON"),
            json!({"files": [], "status": "ok"})
        );
        assert_eq!(under.calls()[0].args, json!({"action": "list", "path": ""}));
    });
}

#[test]
fn storage_answers_each_refusal_cyfr_gives_in_its_own_words() {
    run(|| async {
        for (reply, answer) in [
            (
                Reply::Error(
                    "guest_error",
                    json!({"type": "storage_path_denied", "message": "No."}),
                ),
                error("storage_path_denied", "No."),
            ),
            (
                Reply::Error("unavailable", json!({})),
                error(
                    "storage_error",
                    "Storage refused: the execution store is unavailable.",
                ),
            ),
            (
                Reply::Error("lost", json!({})),
                error(
                    "storage_error",
                    "Storage refused: the execution attempt is not current.",
                ),
            ),
            (
                Reply::Dropped,
                error(
                    "storage_uncertain",
                    "The call's answer was lost and its effect is unknown — read the path back before writing it again.",
                ),
            ),
        ] {
            let reply = Mutex::new(Some(reply));
            let mut under = under(
                answering(move |_call| {
                    reply
                        .lock()
                        .expect("a reply")
                        .take()
                        .unwrap_or(Reply::Silent)
                }),
                Limits::zero(),
                &[],
                &[],
            )
            .await;
            let answered = under
                .guest
                .call(r#"{"action":"write","path":"a","content":"aGk="}"#.to_owned())
                .await
                .expect("an answer");
            assert_eq!(answered, answer);
            // storage is never asked again.
            assert_eq!(under.calls().len(), 1);
        }
    });
}

#[test]
fn an_answer_nested_past_the_depth_bound_ends_the_run() {
    run(|| async {
        let deep = format!(r#"{{"v":3,"ok":{}}}"#, support::nested(MAX_DEPTH));
        let mut under = under(
            Box::new(move |_call, _job| Reply::Plain(deep.clone().into_bytes())),
            Limits::zero(),
            &[],
            &[],
        )
        .await;
        let ended = under
            .guest
            .call(r#"{"action":"list"}"#.to_owned())
            .await
            .expect_err("the run ends");
        assert_eq!(
            ended.downcast_ref::<Ended>().map(|ended| ended.0.as_str()),
            Some(format!("Execution error: CYFR's answer to storage is nested deeper than {MAX_DEPTH} levels").as_str())
        );
        assert_eq!(under.calls().len(), 1, "never asked again");
        // Its call's event is sent all the same, an error.
        let event = under.event().await;
        assert_eq!(event["name"], "storage.call");
        assert_eq!(event["metadata"]["status"], "error");
    });
}

// ============================================================================
// cyfr:emit/events, cyfr:oauth/token, cyfr:vault/read
// ============================================================================

#[test]
fn emit_pushes_one_delta_and_answers_cyfrs_reply() {
    run(|| async {
        let mut under = under(
            answering(|_call| Reply::Ok(json!([r#"{"ok":true,"sequence":"3.0"}"#]))),
            Limits::zero(),
            &[],
            &[],
        )
        .await;
        let reply = under
            .guest
            .emit(r#"{"type":"progress"}"#.to_owned())
            .await
            .expect("an answer");
        assert_eq!(reply, r#"{"ok":true,"sequence":"3.0"}"#);
        let call = &under.calls()[0];
        assert_eq!(call.op, "push_deltas");
        assert_eq!(call.args["deltas"][0]["event"], r#"{"type":"progress"}"#);
        assert_eq!(call.args["deltas"][0]["fence"], 2);
    });
}

#[test]
fn emit_refuses_an_event_past_the_request_bound_and_answers_a_lost_call_as_a_dispatch_error() {
    run(|| async {
        let mut limits = Limits::zero();
        limits.max_request_size = 8;
        let mut under = under(
            answering(|_call| Reply::Error("lost", json!({}))),
            limits,
            &[],
            &[],
        )
        .await;
        assert_eq!(
            under
                .guest
                .emit(r#"{"n":12345}"#.to_owned())
                .await
                .expect("an answer"),
            error(
                "resource_limit",
                "Event exceeds the consented max_request_size for this component."
            )
        );
        assert!(under.calls().is_empty());
        assert_eq!(
            under.guest.emit("{}".to_owned()).await.expect("an answer"),
            error("dispatch_error", "The emit call failed.")
        );
    });
}

#[test]
fn oauth_answers_a_token_or_a_sentence_never_the_material() {
    run(|| async {
        for (reply, answer) in [
            (Reply::Ok(json!("gho_token")), Ok("gho_token".to_owned())),
            (
                Reply::Error(
                    "guest_error",
                    json!({"type": "authorization_required", "message": "Consent first."}),
                ),
                Err("Consent first.".to_owned()),
            ),
            (
                Reply::Dropped,
                Err("The call's answer was lost and its effect is unknown".to_owned()),
            ),
            (
                Reply::Error("unavailable", json!({})),
                Err("the credential store is unavailable".to_owned()),
            ),
        ] {
            let reply = Mutex::new(Some(reply));
            let mut under = under(
                answering(move |_call| {
                    reply
                        .lock()
                        .expect("a reply")
                        .take()
                        .unwrap_or(Reply::Silent)
                }),
                Limits::zero(),
                &[],
                &[],
            )
            .await;
            assert_eq!(
                under
                    .guest
                    .get_access_token("github".to_owned())
                    .await
                    .expect("an answer"),
                answer
            );
            assert_eq!(under.calls()[0].args, json!({"provider": "github"}));
        }
    });
}

#[test]
fn vault_hands_over_what_attach_answered_and_reports_what_it_refuses() {
    run(|| async {
        let mut under = under(
            answering(|_call| Reply::Ok(json!(true))),
            Limits::zero(),
            &[("KEY", "the-value")],
            &["ATTACHED"],
        )
        .await;
        assert_eq!(
            under.guest.get("KEY".to_owned()).await.expect("an answer"),
            Ok("the-value".to_owned())
        );
        let reference = "catalyst:local.test:0.1.0";
        assert_eq!(
            under
                .guest
                .get("ATTACHED".to_owned())
                .await
                .expect("an answer"),
            Err(format!(
                "disclosure_refused: ATTACHED is attached to requests by CYFR and never handed to {reference}"
            ))
        );
        assert_eq!(
            under
                .guest
                .get("OTHER".to_owned())
                .await
                .expect("an answer"),
            Err(format!("access-denied: OTHER not granted to {reference}"))
        );
        let reports: Vec<Value> = under.calls().into_iter().map(|call| call.args).collect();
        assert_eq!(
            reports,
            [
                json!({"message": "ATTACHED", "type": "disclosure_refused"}),
                json!({"message": "OTHER", "type": "secret_denied"}),
            ]
        );
    });
}

// ============================================================================
// cyfr:question/ask
// ============================================================================

/// An answer as the guest is handed it.
fn said(answer: &Answer) -> String {
    format!("{answer:?}")
}

fn request() -> Request {
    Request {
        action: "delete_table".to_owned(),
        summary: "drop the table users".to_owned(),
        operation: "DROP TABLE users;".to_owned(),
    }
}

#[test]
fn an_ask_waits_out_its_allowance_and_then_its_open_question() {
    run(|| async {
        let mut asked = 0;
        let mut waited = 0;
        let mut under = under(
            Box::new(move |call, _job| match call.op.as_str() {
                "question_ask" => {
                    asked += 1;
                    if asked == 1 {
                        Reply::Ok(json!({"retry_after_ms": 5}))
                    } else {
                        Reply::Ok(json!({"pending": true}))
                    }
                }
                _ => {
                    waited += 1;
                    if waited == 1 {
                        Reply::Ok(json!({"pending": true}))
                    } else {
                        Reply::Ok(json!({"answer": "allowed"}))
                    }
                }
            }),
            Limits::zero(),
            &[],
            &[],
        )
        .await;
        assert_eq!(
            said(&under.guest.ask(request()).await.expect("an answer")),
            said(&Answer::Allowed)
        );
        let calls = under.calls();
        let ops: Vec<&str> = calls.iter().map(|call| call.op.as_str()).collect();
        assert_eq!(
            ops,
            [
                "question_ask",
                "question_ask",
                "question_wait",
                "question_wait"
            ]
        );
        assert_eq!(
            calls[0].args,
            json!({"action": "delete_table", "ask_no": 1, "operation": "DROP TABLE users;",
                   "summary": "drop the table users"})
        );
        assert_eq!(calls[2].args, json!({"ask_no": 1, "max_wait_ms": 20000}));
        // The next ask takes the next number.
        let _ = under.guest.ask(request()).await;
        assert_eq!(under.calls()[4].args["ask_no"], 2);
    });
}

#[test]
fn an_ask_nobody_answers_is_unavailable_and_one_past_the_bound_invalid() {
    run(|| async {
        let mut lost = under(
            answering(|_call| Reply::Error("lost", json!({}))),
            Limits::zero(),
            &[],
            &[],
        )
        .await;
        assert_eq!(
            said(&lost.guest.ask(request()).await.expect("an answer")),
            said(&Answer::None(Unanswered::Unavailable))
        );
        let mut unattended = under(
            answering(|_call| Reply::Ok(json!({"answer": {"none": "unattended"}}))),
            Limits::zero(),
            &[],
            &[],
        )
        .await;
        assert_eq!(
            said(&unattended.guest.ask(request()).await.expect("an answer")),
            said(&Answer::None(Unanswered::Unattended))
        );
        let mut big = request();
        big.operation = "x".repeat(cyfr_runner::host::MAX_BODY_BYTES);
        let mut too_large = under(
            answering(|_call| Reply::Ok(json!({}))),
            Limits::zero(),
            &[],
            &[],
        )
        .await;
        assert_eq!(
            said(&too_large.guest.ask(big).await.expect("an answer")),
            said(&Answer::None(Unanswered::Invalid))
        );
        assert!(
            too_large.calls().is_empty(),
            "too large before it is posted"
        );
    });
}

#[test]
fn storage_lists_and_checks_the_scope_for_a_null_path_as_for_an_omitted_one() {
    run(|| async {
        let mut under = under(
            answering(|_call| Reply::Ok(json!({"files": []}))),
            Limits::zero(),
            &[],
            &[],
        )
        .await;
        for request in [
            r#"{"action":"list","path":null}"#,
            r#"{"action":"exists","path":null}"#,
        ] {
            under
                .guest
                .call(request.to_owned())
                .await
                .expect("an answer");
        }
        let paths: Vec<Value> = under.calls().into_iter().map(|call| call.args).collect();
        assert_eq!(
            paths,
            [
                json!({"action": "list", "path": ""}),
                json!({"action": "exists", "path": ""})
            ]
        );
    });
}

#[test]
fn storage_bounds_a_request_under_any_limit_without_overflow() {
    // The envelope bound is twice the limit and its slack, which saturates:
    // under the largest limit every request is within it.
    run(|| async {
        let mut limits = Limits::zero();
        limits.max_request_size = u64::MAX;
        let mut under = under(
            answering(|_call| Reply::Ok(json!({"files": []}))),
            limits,
            &[],
            &[],
        )
        .await;
        let answer = under
            .guest
            .call(r#"{"action":"list"}"#.to_owned())
            .await
            .expect("an answer");
        assert_eq!(
            serde_json::from_str::<Value>(&answer).expect("JSON"),
            json!({"files": [], "status": "ok"})
        );
    });
}
