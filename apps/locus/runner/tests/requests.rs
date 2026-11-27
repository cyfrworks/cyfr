// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! A guest's requests against the real binary and a scripted service end
//! (`support`): its fetches and streams, pinned by CYFR and attached by
//! CYFR, their redirects and drains, and each refusal decided once, at the
//! hop that owns it (D5 (a)), and recorded once.

mod support;

use std::time::Duration;

use serde_json::{Value, json};

use cyfr_runner::relay::MAX_FETCHES;
use cyfr_runner::words;
use support::{HOSTILE, Job, Reply, Service, Upstream, pin, standard};

const SOON: Duration = Duration::from_secs(60);

/// A catalyst that sends its input as its one request and answers its
/// answer.
fn fetching(request: &Value) -> Job {
    Job::new(
        "catalyst",
        &format!("{HOSTILE}/attached_header_probe.wasm"),
        &request.to_string(),
    )
}

/// CYFR's answers, each `egress_pin` answered a pin of `host` named
/// `pin_1`, `pin_2` and on.
fn pinning(host: &'static str) -> support::Script {
    let mut pins = 0;
    Box::new(move |call, job| match call.op.as_str() {
        "egress_pin" => {
            pins += 1;
            pin(&format!("pin_{pins}"), "https", host)
        }
        _ => standard(call, job),
    })
}

/// The run's output and its close, once the runner reports the subtree
/// complete, and every event it sent before.
fn completed(service: &Service, job: &Job) -> (Value, Value, Vec<Value>) {
    let mut events = Vec::new();
    let complete = loop {
        let line = service.line(SOON);
        if line["type"] == "event" {
            events.push(line);
        } else {
            break line;
        }
    };
    assert_eq!(complete["type"], "complete", "{complete}");
    let close = service.calls_of("complete");
    assert_eq!(
        close.len(),
        1,
        "{:?}; stderr: {}",
        service.ops(),
        service.errors()
    );
    let outcome = close[0].args["outcome"].clone();
    assert_eq!(outcome["execution_id"], json!(job.execution_id));
    (outcome["output"].clone(), complete, events)
}

fn denials(service: &Service) -> Vec<Value> {
    service
        .calls_of("record_denial")
        .into_iter()
        .map(|call| call.args)
        .collect()
}

fn credit(service: &Service) -> u64 {
    service
        .frames_of("credit")
        .iter()
        .map(|frame| frame["bytes"].as_u64().expect("bytes"))
        .sum()
}

#[test]
fn a_pinned_fetch_is_pinned_by_cyfr_sent_naming_the_pin_and_answered_whole() {
    let mut service = Service::start();
    let job = fetching(
        &json!({"method": "get", "url": "https://api.example.test/v1/items?page=2",
                               "headers": {"accept": "application/json"}}),
    );
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        Box::new(|_fetch, _job| {
            vec![
                Upstream::Head(
                    200,
                    vec![("content-type", "application/json".to_owned())],
                    b"{\"ok\"".to_vec(),
                ),
                Upstream::Chunk(b":true}".to_vec()),
                Upstream::End(None),
            ]
        }),
    );
    let (output, complete, events) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"status": 200, "headers": {"content-type": "application/json"},
               "body": "{\"ok\":true}"})
    );
    assert_eq!(complete["clean"], json!(true), "{complete}");
    assert_eq!(
        service.calls_of("egress_pin")[0].args,
        json!({"url": "https://api.example.test/v1/items?page=2", "purpose": "fetch"})
    );
    let fetch = &service.frames_of("fetch")[0];
    assert_eq!(
        (
            &fetch["pin"],
            &fetch["method"],
            &fetch["path"],
            &fetch["headers"]
        ),
        (
            &json!("pin_1"),
            &json!("GET"),
            &json!("/v1/items?page=2"),
            &json!([["accept", "application/json"]])
        )
    );
    let http: Vec<&Value> = events
        .iter()
        .filter(|event| event["name"] == "http.request")
        .collect();
    assert_eq!(http.len(), 1);
    assert_eq!(
        http[0]["metadata"],
        json!({"component_ref": job.reference, "method": "GET",
               "hostname": "api.example.test", "status": 200})
    );
}

#[test]
fn a_host_outside_the_domains_is_refused_by_cyfrs_pin_for_its_domain_and_recorded_there_alone() {
    // A request forbidden for its method and for its host alike: the
    // runner checks neither, CYFR's pin refuses the host, and CYFR has
    // recorded the refusal, so the runner reports nothing.
    let mut service = Service::start();
    let job =
        fetching(&json!({"method": "DELETE", "url": "https://outside.example.org/v1?k=sk-1"}));
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "egress_pin" => Reply::Error("domain", json!({})),
            _ => standard(call, job),
        }),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "domain_blocked",
                         "message": "HTTP egress refused: outside.example.org is not in the egress domains"}})
    );
    assert_eq!(
        service.ops(),
        ["attach", "fetch_artifact", "egress_pin", "complete"]
    );
    assert!(service.frames_of("fetch").is_empty());
}

#[test]
fn each_pin_cyfr_refuses_answers_the_guest_naming_the_host_and_is_recorded_by_cyfr_alone() {
    for (why, kind, message) in [
        (
            "denied",
            "private_ip_blocked",
            words::pin_denied("api.example.test"),
        ),
        (
            "metadata",
            "private_ip_blocked",
            words::pin_metadata("api.example.test"),
        ),
        (
            "resolution",
            "dns_error",
            words::pin_resolution("api.example.test"),
        ),
        ("malformed", "invalid_request", words::BAD_URL.to_owned()),
        (
            "unavailable",
            "dns_error",
            words::pin_unavailable("api.example.test"),
        ),
        ("lost", "dns_error", words::PIN_NOT_CURRENT.to_owned()),
    ] {
        let mut service = Service::start();
        let job = fetching(&json!({"method": "GET", "url": "https://api.example.test/x"}));
        service.assign(
            &job,
            Box::new(move |call, job| match call.op.as_str() {
                "egress_pin" => Reply::Error(why, json!({})),
                _ => standard(call, job),
            }),
        );
        let (output, _, _) = completed(&service, &job);
        assert_eq!(
            output,
            json!({"error": {"type": kind, "message": message}}),
            "{why}"
        );
        assert!(denials(&service).is_empty(), "{why}");
        assert!(service.frames_of("fetch").is_empty(), "{why}");
    }
}

#[test]
fn a_pin_naming_another_origin_than_the_urls_is_refused_unsent() {
    let mut service = Service::start();
    let job = fetching(&json!({"method": "GET", "url": "https://api.example.test/x"}));
    service.assign(&job, pinning("other.example.test"));
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "dns_error", "message": words::pin_elsewhere("api.example.test")}})
    );
    assert!(service.frames_of("fetch").is_empty());
}

#[test]
fn the_relays_refusal_of_a_pinned_request_is_the_guests_and_reported_once() {
    for (code, kind, message, recorded) in [
        (
            "method_blocked",
            "method_blocked",
            words::SERVICE_METHOD,
            true,
        ),
        (
            "scheme_blocked",
            "scheme_blocked",
            words::SERVICE_SCHEME,
            true,
        ),
        (
            "request_too_large",
            "request_too_large",
            words::SERVICE_SIZE,
            true,
        ),
        ("rate_limited", "rate_limited", words::RATE_LIMITED, true),
        (
            "invalid_request",
            "invalid_request",
            words::SERVICE_HEADER,
            false,
        ),
    ] {
        let mut service = Service::start();
        let job = fetching(&json!({"method": "GET", "url": "https://api.example.test/x"}));
        service.assign_fetching(
            &job,
            pinning("api.example.test"),
            Box::new(move |_fetch, _job| vec![Upstream::End(Some(code))]),
        );
        let (output, _, _) = completed(&service, &job);
        assert_eq!(
            output,
            json!({"error": {"type": kind, "message": message}}),
            "{code}"
        );
        let expected: Vec<Value> = if recorded {
            vec![json!({"type": kind, "message": message})]
        } else {
            Vec::new()
        };
        assert_eq!(denials(&service), expected, "{code}");
    }
}

#[test]
fn a_request_that_does_not_read_is_refused_and_asks_nothing() {
    let mut service = Service::start();
    let job = fetching(&json!({"note": "no request"}));
    service.assign(&job, Box::new(standard));
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "invalid_request", "message": words::NO_METHOD_OR_URL}})
    );
    assert_eq!(service.ops(), ["attach", "fetch_artifact", "complete"]);
}

#[test]
fn an_answer_past_max_response_size_is_refused_reported_and_drained() {
    let mut service = Service::start();
    let job = fetching(&json!({"method": "GET", "url": "https://api.example.test/big"}));
    let piece = 4 * 1024 * 1024;
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        Box::new(move |_fetch, _job| {
            vec![
                Upstream::Head(200, Vec::new(), vec![b'a'; piece]),
                Upstream::Chunk(vec![b'b'; 2 * 1024 * 1024]),
                // Past the guest's abandonment, granted back as it comes.
                Upstream::Chunk(vec![b'c'; 1024]),
            ]
        }),
    );
    let (output, complete, _) = completed(&service, &job);
    let max = 5_242_880;
    let message = words::response_counted(6 * 1024 * 1024, max);
    assert_eq!(
        output,
        json!({"error": {"type": "response_too_large", "message": message}})
    );
    assert_eq!(
        denials(&service),
        [json!({"type": "response_too_large", "message": message})]
    );
    // The fetch is still the relay's until its end: the runner is not
    // reused, and what it received is granted back.
    assert_eq!(complete["clean"], json!(false), "{complete}");
    let sent = (piece + 2 * 1024 * 1024 + 1024) as u64;
    support::eventually(|| credit(&service) == sent);
}

#[test]
fn a_redirect_is_the_guests_next_request_pinned_from_the_pin_it_came_from() {
    // The redirect points back at the URL asked, so the guest's second
    // request is its hop.
    let mut service = Service::start();
    let job = Job::new(
        "catalyst",
        &format!("{HOSTILE}/fetch_twice.wasm"),
        &json!({"method": "GET", "url": "https://API.example.test:443/a/b?q=1"}).to_string(),
    );
    let mut answered = 0;
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        Box::new(move |_fetch, _job| {
            answered += 1;
            if answered == 1 {
                vec![
                    Upstream::Head(
                        302,
                        vec![("Location", "../a/./b?q=1".to_owned())],
                        Vec::new(),
                    ),
                    Upstream::End(None),
                ]
            } else {
                vec![
                    Upstream::Head(200, Vec::new(), b"there".to_vec()),
                    Upstream::End(None),
                ]
            }
        }),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"status": 200, "headers": {}, "body": "there"})
    );
    let pins: Vec<Value> = service
        .calls_of("egress_pin")
        .into_iter()
        .map(|call| call.args)
        .collect();
    assert_eq!(
        pins,
        [
            json!({"url": "https://API.example.test:443/a/b?q=1", "purpose": "fetch"}),
            json!({"url": "https://API.example.test:443/a/b?q=1", "purpose": "redirect",
                   "from": "pin_1"}),
        ]
    );
}

#[test]
fn a_redirects_hop_pinned_on_another_origin_than_its_pin_is_refused_unsent() {
    let mut service = Service::start();
    let job = Job::new(
        "catalyst",
        &format!("{HOSTILE}/fetch_twice.wasm"),
        &json!({"method": "GET", "url": "https://api.example.test/a"}).to_string(),
    );
    let mut pins = 0;
    service.assign_fetching(
        &job,
        Box::new(move |call, job| match call.op.as_str() {
            // The hop's pin names the URL's host, on another port than
            // the pin it came from: the runner refuses it as its own.
            "egress_pin" => {
                pins += 1;
                if pins == 1 {
                    pin("pin_1", "https", "api.example.test")
                } else {
                    Reply::Ok(json!({"id": "pin_2", "ip": "203.0.113.10", "family": 4,
                                     "scheme": "http", "port": 80, "host": "api.example.test",
                                     "expires_at": support::now_ms() + 30_000}))
                }
            }
            _ => standard(call, job),
        }),
        Box::new(|_fetch, _job| {
            vec![
                Upstream::Head(301, vec![("location", "/a".to_owned())], Vec::new()),
                Upstream::End(None),
            ]
        }),
    );
    let (output, _, _) = completed(&service, &job);
    // The hop's own URL is https: a pin of http names another origin.
    assert_eq!(
        output,
        json!({"error": {"type": "dns_error", "message": words::pin_elsewhere("api.example.test")}})
    );
    assert_eq!(service.frames_of("fetch").len(), 1);
}

/// A catalyst whose one request names the connection `api_key`.
fn attaching(extra: Value) -> Job {
    let mut request = json!({"method": "POST", "url": "https://api.example.test/v1/charge",
                             "connection": "api_key", "body": "{\"amount\":1}"});
    request
        .as_object_mut()
        .expect("an object")
        .extend(extra.as_object().expect("an object").clone());
    fetching(&request)
}

#[test]
fn an_attached_request_is_cyfrs_to_make_and_its_answer_opens_for_its_call_id_alone() {
    let mut service = Service::start();
    let job = attaching(json!({"headers": {"content-type": "application/json"}}));
    service.assign_fetching(
        &job,
        Box::new(standard),
        Box::new(|fetch, job| {
            let call_id = fetch["call_id"].as_str().expect("a call id");
            let head = json!({"status": 201, "headers": [["content-type", "application/json"]]});
            vec![
                Upstream::Frame(support::seal_frame(
                    job,
                    call_id,
                    0,
                    "head",
                    head.to_string().as_bytes(),
                )),
                Upstream::Frame(support::seal_frame(job, call_id, 1, "chunk", b"{\"id\":7}")),
                Upstream::Frame(support::seal_frame(job, call_id, 2, "end", b"")),
                Upstream::End(None),
            ]
        }),
    );
    let (output, complete, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"status": 201, "headers": {"content-type": "application/json"}, "body": "{\"id\":7}"})
    );
    assert_eq!(complete["clean"], json!(true), "{complete}");
    // No pin is asked: CYFR pins the request it makes.
    assert!(service.calls_of("egress_pin").is_empty());
    let fetch = &service.frames_of("fetch")[0];
    assert_eq!(
        (
            &fetch["connection"],
            &fetch["purpose"],
            &fetch["method"],
            &fetch["url"]
        ),
        (
            &json!("api_key"),
            &json!("fetch"),
            &json!("POST"),
            &json!("https://api.example.test/v1/charge")
        )
    );
    assert_eq!(
        fetch["body"],
        json!(cyfr_runner::wire::encode_base64(b"{\"amount\":1}"))
    );
}

#[test]
fn an_attached_answer_sealed_for_another_call_reads_as_no_answer() {
    let mut service = Service::start();
    let job = attaching(json!({}));
    service.assign_fetching(
        &job,
        Box::new(standard),
        Box::new(|_fetch, job| {
            let head = json!({"status": 200, "headers": []});
            vec![Upstream::Frame(support::seal_frame(
                job,
                "ICEiIyQlJicoKSorLC0uLw",
                0,
                "head",
                head.to_string().as_bytes(),
            ))]
        }),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "http_error", "message": words::HTTP_FAILED}})
    );
}

#[test]
fn cyfrs_refusal_of_an_attached_request_is_its_own_type_and_sentence_and_recorded_by_cyfr_alone() {
    let mut service = Service::start();
    let job = attaching(json!({}));
    service.assign_fetching(
        &job,
        Box::new(standard),
        Box::new(|fetch, job| {
            let call_id = fetch["call_id"].as_str().expect("a call id");
            vec![
                support::attached_refusal(
                    job,
                    call_id,
                    "connection_not_granted",
                    "The connection is not granted.",
                ),
                Upstream::End(Some("refused")),
            ]
        }),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "connection_not_granted",
                         "message": "The connection is not granted."}})
    );
    assert!(denials(&service).is_empty());
}

#[test]
fn a_credential_header_or_a_framing_header_beside_a_connection_is_refused_by_shape_unsent() {
    for (headers, kind, message) in [
        (
            json!({"Authorization": "Bearer guest-supplied"}),
            "credential_header_refused",
            words::CREDENTIAL_HEADER.to_owned(),
        ),
        (
            json!({"COOKIE": "a=b"}),
            "credential_header_refused",
            words::CREDENTIAL_HEADER.to_owned(),
        ),
        (
            json!({"Host": "other.test"}),
            "invalid_request",
            words::attached_header("Host"),
        ),
    ] {
        let mut service = Service::start();
        let job = attaching(json!({"headers": headers}));
        service.assign(&job, Box::new(standard));
        let (output, _, _) = completed(&service, &job);
        assert_eq!(
            output,
            json!({"error": {"type": kind, "message": message}}),
            "{headers}"
        );
        assert!(service.frames_of("fetch").is_empty(), "{headers}");
        // Neither is a policy decision of CYFR's: nothing is reported.
        assert!(denials(&service).is_empty(), "{headers}");
    }
}

#[test]
fn an_attached_request_the_relay_refuses_is_refused_as_its_rule_says_and_reported() {
    let mut service = Service::start();
    let job = attaching(json!({}));
    service.assign_fetching(
        &job,
        Box::new(standard),
        Box::new(|_fetch, _job| vec![Upstream::End(Some("method_blocked"))]),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "method_blocked", "message": words::SERVICE_METHOD}})
    );
    assert_eq!(
        denials(&service),
        [json!({"type": "method_blocked", "message": words::SERVICE_METHOD})]
    );
}

#[test]
fn an_attached_answer_lost_on_its_way_leaves_the_runner_unclean() {
    let mut service = Service::start();
    let job = attaching(json!({}));
    service.assign_fetching(
        &job,
        Box::new(standard),
        Box::new(|_fetch, _job| vec![Upstream::End(Some("uncertain"))]),
    );
    let (output, complete, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "http_error", "message": words::HTTP_FAILED}})
    );
    assert_eq!(complete["clean"], json!(false), "{complete}");
}

#[test]
fn a_guest_that_reads_part_of_a_stream_and_closes_it_completes_normally() {
    let mut service = Service::start();
    let job = Job::new(
        "catalyst",
        &format!("{HOSTILE}/stream_once.wasm"),
        &json!({"method": "POST", "url": "https://api.example.test/v1/chat",
                "body": "{\"stream\":true}"})
        .to_string(),
    );
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        Box::new(|_fetch, _job| {
            // More than one read takes: the guest reads part of it.
            vec![
                Upstream::Head(200, Vec::new(), Vec::new()),
                Upstream::Chunk(b"data: one\n".repeat(30_000)),
            ]
        }),
    );
    let (output, _, events) = completed(&service, &job);
    let read = output["data"].as_str().expect("the read's data");
    assert_eq!(read.len(), cyfr_runner::imports::stream::PIECE_BYTES);
    assert!(read.starts_with("data: one\n"));
    assert_eq!(
        (&output["done"], &output["status"]),
        (&json!(false), &json!(200))
    );
    assert_eq!(
        service.calls_of("complete")[0].args["outcome"]["status"],
        "completed"
    );
    assert_eq!(
        service.calls_of("egress_pin")[0].args,
        json!({"url": "https://api.example.test/v1/chat", "purpose": "stream"})
    );
    assert!(
        events
            .iter()
            .any(|event| event["name"] == "http.request"
                && event["metadata"]["status"] == json!(200))
    );
    // The piece the guest read is granted as it read it, and the rest that
    // arrived with it and was never read as the stream drains.
    support::eventually(|| credit(&service) == 300_000);
}

#[test]
fn a_guest_opening_and_closing_streams_against_a_slow_upstream_is_refused_the_one_past_the_relays_fetches_and_goes_on()
 {
    let mut service = Service::start();
    let job = Job::new(
        "catalyst",
        &format!("{HOSTILE}/stream_flood.wasm"),
        &json!({"method": "GET", "url": "https://api.example.test/events"}).to_string(),
    );
    // Each stream's upstream answers its head and never ends.
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        Box::new(|_fetch, _job| vec![Upstream::Head(200, Vec::new(), b"x".to_vec())]),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "stream_limit", "message": words::requests_in_flight(MAX_FETCHES)}})
    );
    // The relay carried exactly its most, and was not closed: the attempt
    // went on to its close.
    assert_eq!(service.frames_of("fetch").len(), MAX_FETCHES);
    assert!(service.frames_of("close").is_empty());
    assert_eq!(
        service.calls_of("complete")[0].args["outcome"]["status"],
        "completed"
    );
    // The one past them was refused before it was pinned.
    assert_eq!(service.calls_of("egress_pin").len(), MAX_FETCHES);
}

#[test]
fn a_request_that_is_no_json_answers_invalid_json_and_one_past_its_envelope_is_too_large() {
    use cyfr_runner::authority::Limits;
    use cyfr_runner::imports::http::{Purpose, requested};
    let limits = Limits::zero();
    let refused = requested("{\"method\": ", &limits, Purpose::Fetch).err();
    assert_eq!(
        refused.map(|refused| (refused.kind, refused.message)),
        Some((
            "invalid_json".to_owned(),
            words::REQUEST_NOT_JSON.to_owned()
        ))
    );
    let envelope = 2 * limits.max_request_size as usize + 4096;
    let over = format!("{{\"pad\":\"{}\"}}", "a".repeat(envelope));
    let refused = requested(&over, &limits, Purpose::Fetch).err();
    assert_eq!(
        refused.map(|refused| refused.kind),
        Some("request_too_large".to_owned())
    );
}

// ============================================================================
// The review's cases (R3's first round)
// ============================================================================

/// A stream guest of `name` sending `request` for each of its streams.
fn streaming(name: &str, request: &Value) -> Job {
    Job::new(
        "catalyst",
        &format!("{HOSTILE}/{name}.wasm"),
        &request.to_string(),
    )
}

/// The upstream's answers to the fetches in the order they come: the
/// first fetch's, the second's, and nothing for any after.
fn in_turn(answers: Vec<Vec<Upstream>>) -> support::Fetches {
    let mut answers = answers.into_iter();
    Box::new(move |_fetch, _job| answers.next().unwrap_or_default())
}

fn http_events(events: &[Value]) -> Vec<Value> {
    events
        .iter()
        .filter(|event| event["name"] == "http.request")
        .map(|event| event["metadata"]["status"].clone())
        .collect()
}

/// The runner's peak resident memory while `run` runs, sampled every 20 ms.
fn peak_while<T>(pid: u32, run: impl FnOnce() -> T) -> (u64, T) {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    let running = Arc::new(AtomicBool::new(true));
    let peak = Arc::new(AtomicU64::new(0));
    let sampler = {
        let (running, peak) = (running.clone(), peak.clone());
        std::thread::spawn(move || {
            while running.load(Ordering::Relaxed) {
                peak.fetch_max(support::resident_kib(pid), Ordering::Relaxed);
                std::thread::sleep(Duration::from_millis(20)); // sleep-ok: samples a process's memory while it works, until told to stop
            }
        })
    };
    let out = run();
    running.store(false, Ordering::Relaxed);
    sampler.join().expect("the sampler");
    (peak.load(Ordering::Relaxed), out)
}

/// One stream's answer of `bytes` cut into `chunks`, held unread while its
/// guest reads another for six seconds: the runner's peak in KiB.
fn held_unread(bytes: usize, chunks: usize) -> (u64, Duration) {
    let mut service = Service::start();
    let job = streaming(
        "stream_hold",
        &json!({"method": "GET", "url": "https://api.example.test/events"}),
    );
    // A slow runner's test build decodes a frame in some tens of
    // microseconds on the runner's one thread, beside the guest's reads.
    let job = Job {
        timeout_ms: 120_000,
        ..job
    };
    let piece = bytes / chunks;
    let mut first = vec![Upstream::Head(200, Vec::new(), Vec::new())];
    first.extend((0..chunks).map(|_| Upstream::Chunk(vec![b'a'; piece])));
    let started = std::time::Instant::now();
    service.assign_fetching(&job, pinning("api.example.test"), in_turn(vec![first]));
    let pid = service.pid();
    let (peak, (output, _, _)) = peak_while(pid, || completed(&service, &job));
    assert_eq!(output, json!({"data": "", "done": false}));
    (peak, started.elapsed())
}

/// How many one-byte chunks the unread stream is fed: enough that a frame
/// held as its own allocation stands well clear of the bytes held whole,
/// few enough that a slow runner's test build feeds them well inside the
/// attempt's budget (the body gives the measured margin).
const HELD_CHUNKS: usize = 300_000;

#[test]
fn a_stream_held_unread_holds_its_body_as_bytes_however_the_upstream_cuts_it() {
    // Item 1: the same bytes whole, and as one-byte chunks, each frame
    // some 90 bytes on the wire.
    let chunks: usize = std::env::var("CYFR_HELD_CHUNKS")
        .ok()
        .and_then(|chunks| chunks.parse().ok())
        .unwrap_or(HELD_CHUNKS);
    let (whole, _) = held_unread(chunks, 1);
    let (pieces, took) = held_unread(chunks, chunks);
    eprintln!(
        "held unread: one chunk {whole} KiB, {chunks} chunks {pieces} KiB, the attempt {} ms",
        took.as_millis()
    );
    assert!(
        pieces <= whole + 3 * 1024,
        "{chunks} one-byte chunks held {pieces} KiB against {whole} KiB whole"
    );
}

#[test]
fn a_stream_closed_unread_still_reports_the_relays_refusal_and_sends_its_event() {
    // Item 2: the first stream is closed before its answer arrives.
    for (first, denials_expected, events_expected) in [
        (
            vec![Upstream::End(Some("method_blocked"))],
            vec![json!({"type": "method_blocked", "message": words::SERVICE_METHOD})],
            vec![json!("error"), json!(200)],
        ),
        (
            vec![
                Upstream::Head(201, Vec::new(), b"ok".to_vec()),
                Upstream::End(None),
            ],
            Vec::new(),
            vec![json!(201), json!(200)],
        ),
    ] {
        let mut service = Service::start();
        let job = streaming(
            "stream_closed",
            &json!({"method": "GET", "url": "https://api.example.test/events"}),
        );
        let second = vec![
            Upstream::Head(200, Vec::new(), b"b".to_vec()),
            Upstream::End(None),
        ];
        service.assign_fetching(
            &job,
            pinning("api.example.test"),
            in_turn(vec![first, second]),
        );
        let (output, complete, events) = completed(&service, &job);
        assert_eq!(output, json!({"data": "b", "done": false, "status": 200}));
        assert_eq!(denials(&service), denials_expected);
        let mut statuses = http_events(&events);
        statuses.sort_by_key(Value::to_string);
        let mut expected = events_expected;
        expected.sort_by_key(Value::to_string);
        assert_eq!(statuses, expected);
        assert_eq!(complete["clean"], json!(true), "{complete}");
    }
}

#[test]
fn a_stream_dropped_with_its_store_still_reports_and_an_attached_one_lost_leaves_the_runner_unclean()
 {
    // Item 2: the first stream is left open and unread when its run ends.
    let mut service = Service::start();
    let job = streaming(
        "stream_aside",
        &json!({"method": "GET", "url": "https://api.example.test/events"}),
    );
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![
            vec![Upstream::End(Some("rate_limited"))],
            vec![
                Upstream::Head(200, Vec::new(), b"b".to_vec()),
                Upstream::End(None),
            ],
        ]),
    );
    let (_, complete, events) = completed(&service, &job);
    assert_eq!(
        denials(&service),
        [json!({"type": "rate_limited", "message": words::RATE_LIMITED})]
    );
    assert!(http_events(&events).contains(&json!("error")), "{events:?}");
    assert_eq!(complete["clean"], json!(true), "{complete}");

    // An attached stream whose answer ended uncertain, dropped unread: what
    // CYFR did is unknown, so the runner is not reused, though nothing of
    // the relay is outstanding. Ended `refused` instead, it is.
    for (code, clean) in [
        ("uncertain", false),
        ("lost", false),
        ("method_blocked", true),
    ] {
        let mut service = Service::start();
        let job = streaming(
            "stream_aside",
            &json!({"method": "GET", "url": "https://api.example.test/events",
                    "connection": "api_key"}),
        );
        service.assign_fetching(
            &job,
            Box::new(standard),
            in_turn(vec![
                vec![Upstream::End(Some(code))],
                vec![Upstream::End(Some("bad_frame"))],
            ]),
        );
        let (_, complete, _) = completed(&service, &job);
        assert_eq!(complete["clean"], json!(clean), "{code}: {complete}");
    }
}

#[tokio::test]
async fn a_host_call_past_the_relays_places_waits_unsigned_and_one_whose_caller_left_is_never_sent()
{
    // Item 3, at the relay's end: a service that answers nothing.
    use cyfr_runner::host::{Op, Post as _};
    use cyfr_runner::relay::{MAX_CALLS, Relay};
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    let attempt = "att_places";
    let (ours, theirs) = tokio::io::duplex(1 << 20);
    let (reader, writer) = tokio::io::split(theirs);
    let relay = Relay::start(reader, writer);
    relay.bind(attempt).await.expect("bound");
    let (mut service_reads, mut service_writes) = tokio::io::split(ours);
    let op = Op::named("renew").expect("a callback");
    let mut answers = Vec::new();
    for _ in 0..MAX_CALLS {
        let mut poster = relay.poster(attempt);
        let place = poster.place().await.expect("a place");
        answers.push(tokio::spawn(async move {
            poster
                .post(op, "v1 header".to_owned(), b"body".to_vec(), place)
                .await
        }));
    }
    // The one past them has no place: nothing of it is signed or sent.
    let mut late = relay.poster(attempt);
    let waiting = tokio::time::timeout(Duration::from_millis(200), late.place()).await;
    assert!(waiting.is_err(), "a place past {MAX_CALLS}");
    let frames = |bytes: &[u8]| {
        let mut at = 0;
        let mut kinds = Vec::new();
        while at + 4 <= bytes.len() {
            let length = u32::from_be_bytes(bytes[at..at + 4].try_into().expect("four")) as usize;
            let frame: Value =
                serde_json::from_slice(&bytes[at + 4..at + 4 + length]).expect("a frame");
            kinds.push(frame["kind"].as_str().expect("a kind").to_owned());
            at += 4 + length;
        }
        kinds
    };
    let mut wire = vec![0u8; 1 << 20];
    let mut read = 0;
    while frames(&wire[..read]).len() < MAX_CALLS {
        read += service_reads
            .read(&mut wire[read..])
            .await
            .expect("the wire");
    }
    assert_eq!(frames(&wire[..read]), vec!["host_call"; MAX_CALLS]);
    // A caller that stops waiting for its place, and an answer that frees
    // one: nothing more is sent.
    let gone = tokio::spawn(async move {
        let mut late = late;
        let _ = late.place().await;
        unreachable!("the waiter is stopped before a place opens");
    });
    tokio::task::yield_now().await;
    gone.abort();
    let answer = json!({"v": 1, "attempt": attempt, "seq": 0, "kind": "host_answer", "re": 0,
                        "status": 200, "body": ""})
    .to_string();
    let mut bytes = u32::try_from(answer.len())
        .expect("small")
        .to_be_bytes()
        .to_vec();
    bytes.extend_from_slice(answer.as_bytes());
    service_writes.write_all(&bytes).await.expect("the answer");
    assert!(answers.remove(0).await.expect("the call").is_some());
    let more = tokio::time::timeout(
        Duration::from_millis(300),
        service_reads.read(&mut wire[read..]),
    )
    .await;
    assert!(more.is_err(), "a call was sent for a caller that left");
}

#[test]
fn the_largest_request_and_answer_the_limits_allow_hold_the_thread_within_a_bound() {
    // Item 4: the platform's ceilings, 10 MiB a request and 50 MiB an
    // answer (`Prima.Limits.Ceiling`), each read or written in one go on
    // the runner's thread.
    use cyfr_runner::authority::Limits;
    use cyfr_runner::imports::http::{Purpose, remove_dot_segments, requested, response};
    use std::time::Instant;
    let limits = Limits {
        max_request_size: 10 * 1024 * 1024,
        max_response_size: 50 * 1024 * 1024,
        ..Limits::zero()
    };
    let envelope = (2 * limits.max_request_size + 4096) as usize;
    // A multipart request of small parts, the costliest to read and encode.
    let part = json!({"name": "p", "data": cyfr_runner::wire::encode_base64(&[7u8; 600])});
    let count = envelope / (part.to_string().len() + 1) - 8;
    let request = json!({"method": "POST", "url": "https://api.example.test/x",
                         "multipart": vec![part; count]})
    .to_string();
    assert!(request.len() <= envelope);
    let started = Instant::now();
    assert!(requested(&request, &limits, Purpose::Fetch).is_ok());
    let read_ms = started.elapsed().as_millis();
    // An answer of the largest body, no UTF-8, read as Latin-1, and then
    // as base64.
    let body = vec![0xe9u8; limits.max_response_size as usize];
    let started = Instant::now();
    let text = response(200, &[], &body, false);
    let text_ms = started.elapsed().as_millis();
    let started = Instant::now();
    let base64 = response(200, &[], &body, true);
    let base64_ms = started.elapsed().as_millis();
    // Each answer is the JSON a reader reads back to its body.
    let read: Value = serde_json::from_str(&text).expect("an answer");
    assert_eq!(read["body"].as_str().map(str::len), Some(body.len() * 2));
    let read: Value = serde_json::from_str(&base64).expect("an answer");
    assert_eq!(
        read["body"]
            .as_str()
            .and_then(cyfr_runner::wire::decode_base64),
        Some(body.clone())
    );
    // A redirect's path of 400,000 segments, half of them dots: one pass.
    let path = "/a/..".repeat(200_000);
    let started = Instant::now();
    assert_eq!(remove_dot_segments(&path), "/");
    let dots_ms = started.elapsed().as_millis();
    eprintln!(
        "request read {read_ms} ms, text answer {text_ms} ms, base64 answer {base64_ms} ms, \
         dots {dots_ms} ms"
    );
    // The test build is unoptimized; the release binary is several times
    // faster (the body says by how much). Each stays within the bound.
    for (what, ms) in [
        ("request", read_ms),
        ("text", text_ms),
        ("base64", base64_ms),
    ] {
        assert!(ms < 3_000, "{what}: {ms} ms");
    }
    assert!(dots_ms < 500, "dots: {dots_ms} ms");
}

#[test]
fn dot_segments_are_removed_as_rfc_3986_removes_them() {
    use cyfr_runner::imports::http::remove_dot_segments;
    for (path, removed) in [
        ("/a/b/c/./../../g", "/a/g"),
        ("mid/content=5/../6", "mid/6"),
        ("/./a/b/", "/a/b/"),
        ("/a/b/..", "/a/"),
        ("/a/b/.", "/a/b/"),
        ("/../a", "/a"),
        ("../a/./b", "a/b"),
        ("/", "/"),
        ("", ""),
    ] {
        assert_eq!(remove_dot_segments(path), removed, "{path}");
    }
}

#[test]
fn a_pinned_requests_url_and_header_leave_the_runner_with_at_most_the_bindings_copy() {
    // Item 5: after the attempt closes, the runner's writable memory holds
    // a needle at most once: the request the generated binding took, which
    // Wasmtime frees unwiped (a stated limit). Every copy of the runner's
    // own is cleared.
    let path = "PPNEEDLEPATHtok-0123456789abcdefPP";
    let query = "QQNEEDLEQUERYsk-live-0123456789abcdefQQ";
    let header = "HHNEEDLEHEADERBearer-0123456789abcdefHH";
    let mut service = Service::start();
    let job = fetching(&json!({"method": "POST",
        "url": format!("https://api.example.test/v1/{path}/items?api_key={query}"),
        "headers": {"authorization": header}, "body": "{}"}));
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![vec![
            Upstream::Head(
                302,
                vec![("location", format!("/next?code={query}"))],
                Vec::new(),
            ),
            Upstream::End(None),
        ]]),
    );
    let _ = completed(&service, &job);
    let needles: [&[u8]; 4] = [
        support::RUNNER.as_bytes(),
        path.as_bytes(),
        query.as_bytes(),
        header.as_bytes(),
    ];
    let found = support::scan(service.pid(), &needles);
    assert!(found[0] > 0, "the scan read the runner's memory: {found:?}");
    for (needle, count) in ["path", "query", "header"].iter().zip(&found[1..]) {
        assert!(*count <= 1, "the {needle} is left {count} times: {found:?}");
    }
}

#[test]
fn an_attached_refusal_is_verified_as_it_arrives_however_late_it_is_read() {
    // Item 6: the refusal is 25 s old when it arrives and read some six
    // seconds later, past the header's 30 s window.
    let mut service = Service::start();
    let job = streaming(
        "stream_late",
        &json!({"method": "GET", "url": "https://api.example.test/events",
                "connection": "api_key"}),
    );
    let mut fetches = 0;
    service.assign_fetching(
        &job,
        Box::new(standard),
        Box::new(move |fetch, job| {
            fetches += 1;
            if fetches > 1 {
                return Vec::new();
            }
            let call_id = fetch["call_id"].as_str().expect("a call id");
            let signed = support::Signed {
                age_ms: 25_000,
                ..Default::default()
            };
            vec![
                support::refusal_as(
                    job,
                    call_id,
                    "connection_not_granted",
                    "Not granted.",
                    &signed,
                ),
                Upstream::End(Some("refused")),
            ]
        }),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "connection_not_granted", "message": "Not granted."}})
    );
}

#[test]
fn an_attached_refusal_that_is_not_its_calls_reads_as_no_answer() {
    // Item 13: another key's header, another attempt's, another call id's.
    let other = Job::new(
        "catalyst",
        &format!("{HOSTILE}/attached_header_probe.wasm"),
        "{}",
    );
    for case in ["another key", "another attempt", "another call id"] {
        let mut service = Service::start();
        let job = attaching(json!({}));
        let other = other.clone();
        service.assign_fetching(
            &job,
            Box::new(standard),
            Box::new(move |fetch, job| {
                let call_id = fetch["call_id"].as_str().expect("a call id");
                let (call_id, signed) = match case {
                    "another key" => (
                        call_id.to_owned(),
                        support::Signed {
                            call_key: Some(other.call_key),
                            ..Default::default()
                        },
                    ),
                    "another attempt" => (
                        call_id.to_owned(),
                        support::Signed {
                            attempt: Some(other.attempt()),
                            ..Default::default()
                        },
                    ),
                    _ => (
                        "ICEiIyQlJicoKSorLC0uLw".to_owned(),
                        support::Signed::default(),
                    ),
                };
                vec![
                    support::refusal_as(job, &call_id, "connection_not_granted", "No.", &signed),
                    Upstream::End(Some("refused")),
                ]
            }),
        );
        let (output, _, _) = completed(&service, &job);
        assert_eq!(
            output,
            json!({"error": {"type": "http_error", "message": words::HTTP_FAILED}}),
            "{case}"
        );
        assert!(denials(&service).is_empty(), "{case}");
    }
}

#[test]
fn an_attached_streams_upstream_failure_keeps_cyfrs_type_and_a_connect_timeout_its_own_words() {
    // Item 7: CYFR's signed `http_error` passes as given.
    let mut service = Service::start();
    let job = streaming(
        "stream_once",
        &json!({"method": "GET", "url": "https://api.example.test/events",
                "connection": "api_key"}),
    );
    service.assign_fetching(
        &job,
        Box::new(standard),
        Box::new(|fetch, job| {
            let call_id = fetch["call_id"].as_str().expect("a call id");
            let error =
                json!({"type": "http_error", "message": "The upstream reset the connection."});
            vec![
                Upstream::Frame(support::seal_frame(
                    job,
                    call_id,
                    0,
                    "error",
                    error.to_string().as_bytes(),
                )),
                Upstream::End(None),
            ]
        }),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "http_error", "message": "The upstream reset the connection."}})
    );
    // A pinned stream whose connection timed out says so.
    let mut service = Service::start();
    let job = streaming(
        "stream_once",
        &json!({"method": "GET", "url": "https://api.example.test/e"}),
    );
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![vec![Upstream::End(Some("connect_timeout"))]]),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "timeout", "message": words::connect_timeout(5_000)}})
    );
}

#[test]
fn an_attached_requests_domain_refusal_by_the_relay_names_the_host_it_asked_for() {
    // Item 7: D5 (a) keeps the asked host in the guest's words and the
    // report, for an attached request too.
    let mut service = Service::start();
    let job = attaching(json!({}));
    service.assign_fetching(
        &job,
        Box::new(standard),
        in_turn(vec![vec![Upstream::End(Some("domain_blocked"))]]),
    );
    let (output, _, _) = completed(&service, &job);
    let message = words::service_domain("api.example.test");
    assert_eq!(
        output,
        json!({"error": {"type": "domain_blocked", "message": message}})
    );
    assert_eq!(
        denials(&service),
        [json!({"type": "domain_blocked", "message": message})]
    );
}

#[test]
fn a_method_no_frame_carries_is_refused_for_the_relay_before_its_pin_and_reported() {
    // Item 7: the one refusal the runner makes for the relay.
    for method in ["TRACE", "CONNECT", "PROPFIND"] {
        let mut service = Service::start();
        let job = fetching(&json!({"method": method, "url": "https://api.example.test/x"}));
        service.assign(&job, pinning("api.example.test"));
        let (output, _, _) = completed(&service, &job);
        let message = words::unsupported_method(method);
        assert_eq!(
            output,
            json!({"error": {"type": "method_blocked", "message": message}})
        );
        assert_eq!(
            denials(&service),
            [json!({"type": "method_blocked", "message": message})]
        );
        assert!(service.calls_of("egress_pin").is_empty(), "{method}");
        assert!(service.frames_of("fetch").is_empty(), "{method}");
    }
}

#[test]
fn a_pin_code_off_the_roster_is_the_transports_failure_it_names() {
    // Item 7.
    let mut service = Service::start();
    let job = fetching(&json!({"method": "GET", "url": "https://api.example.test/x"}));
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![vec![Upstream::End(Some("pin_future"))]]),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "http_error", "message": words::http_failed("pin_future")}})
    );
}

#[test]
fn a_pin_answer_prima_would_not_read_is_a_failed_pin_and_sends_nothing() {
    // Item 8: an IPv4 address beside family 6, as reviewer A's case.
    let mut service = Service::start();
    let job = fetching(&json!({"method": "GET", "url": "https://api.example.test/x"}));
    service.assign(
        &job,
        Box::new(|call, job| match call.op.as_str() {
            "egress_pin" => Reply::Ok(json!({"id": "pin_1", "ip": "203.0.113.10", "family": 6,
                "scheme": "https", "port": 443, "host": "api.example.test",
                "expires_at": support::now_ms() + 30_000})),
            _ => standard(call, job),
        }),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "dns_error", "message": words::PIN_NOT_CURRENT}})
    );
    assert!(service.frames_of("fetch").is_empty());
    assert!(service.frames_of("close").is_empty());
}

#[test]
fn a_positive_duration_of_any_size_stays_positive() {
    // Item 9.
    use cyfr_runner::authority::duration_ms;
    let horizon = i64::try_from(cyfr_runner::wire::MAX_INTEGER).expect("under 2^63");
    for (text, ms) in [
        ("30s", Some(30_000)),
        ("500ms", Some(500)),
        ("5m", Some(300_000)),
        ("1h", Some(3_600_000)),
        ("90", Some(90_000)),
        ("+2s", Some(2_000)),
        ("-2s", Some(-2_000)),
        ("0ms", Some(0)),
        ("000", Some(0)),
        ("18446744073709551616ms", Some(horizon)),
        ("99999999999999999999999h", Some(horizon)),
        ("9999999999999h", Some(horizon)),
        ("5mm", None),
        ("", None),
        ("1.5s", None),
    ] {
        assert_eq!(duration_ms(text), ms, "{text}");
    }
    let limits = cyfr_runner::authority::Limits {
        timeout: "18446744073709551616ms".to_owned(),
        ..cyfr_runner::authority::Limits::zero()
    };
    assert_eq!(limits.timeout_ms(), cyfr_runner::wire::MAX_INTEGER);
}

#[test]
fn a_redirects_hop_is_known_by_its_host_in_any_case() {
    // Item 10: a library that lowercases the Location's host asks the hop
    // as the redirect's, and CYFR decides it against its pin.
    let mut service = Service::start();
    let job = Job::new(
        "catalyst",
        &format!("{HOSTILE}/fetch_twice.wasm"),
        &json!({"method": "GET", "url": "https://api.example.test/a"}).to_string(),
    );
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![
            vec![
                Upstream::Head(
                    302,
                    vec![("Location", "HTTPS://API.Example.TEST/a".to_owned())],
                    Vec::new(),
                ),
                Upstream::End(None),
            ],
            vec![
                Upstream::Head(200, Vec::new(), b"there".to_vec()),
                Upstream::End(None),
            ],
        ]),
    );
    let _ = completed(&service, &job);
    assert_eq!(
        service.calls_of("egress_pin")[1].args,
        json!({"url": "https://api.example.test/a", "purpose": "redirect", "from": "pin_1"})
    );
}

#[test]
fn a_request_that_is_no_json_answers_invalid_json_through_the_import_and_reports_nothing() {
    // Item 12, the row of pull request 644.
    let mut service = Service::start();
    let job = Job::new("catalyst", &format!("{HOSTILE}/fetch_garbage.wasm"), "{}");
    service.assign(&job, Box::new(standard));
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "invalid_json", "message": words::REQUEST_NOT_JSON}})
    );
    assert_eq!(service.ops(), ["attach", "fetch_artifact", "complete"]);
}

#[test]
fn the_service_ending_the_relay_in_the_middle_of_a_fetch_ends_the_runner_naming_the_attempt() {
    // Item 13.
    let mut service = Service::start();
    let job = fetching(&json!({"method": "GET", "url": "https://api.example.test/x"}));
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![vec![
            Upstream::Head(200, Vec::new(), b"part".to_vec()),
            Upstream::Close,
        ]]),
    );
    let exit = service.frame(SOON);
    assert_eq!(
        exit,
        json!({"v": 1, "type": "exit", "runner": support::RUNNER, "open": [job.attempt]})
    );
    assert_eq!(service.exit(SOON).code(), Some(1));
}

#[test]
fn a_stream_past_its_timeout_or_its_size_is_refused_once() {
    // Item 13: a node whose timeout is one second; the first stream is
    // read six seconds after it opened.
    let mut service = Service::start();
    let job = streaming(
        "stream_late",
        &json!({"method": "GET", "url": "https://api.example.test/events"}),
    )
    .bound(json!({"timeout": "1s"}));
    service.assign_fetching(&job, pinning("api.example.test"), support::silent_fetches());
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "timeout", "message": words::stream_timed_out(1)}})
    );
    // A node whose answers are at most 100 bytes.
    let mut service = Service::start();
    let job = streaming(
        "stream_once",
        &json!({"method": "GET", "url": "https://api.example.test/e"}),
    )
    .bound(json!({"max_response_size": 100}));
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![vec![Upstream::Head(200, Vec::new(), vec![b'a'; 150])]]),
    );
    let (output, _, _) = completed(&service, &job);
    let message = words::stream_counted(150, 100);
    assert_eq!(
        output,
        json!({"error": {"type": "response_too_large", "message": message}})
    );
    assert_eq!(
        denials(&service),
        [json!({"type": "response_too_large", "message": message})]
    );
}

#[test]
fn a_fourth_open_stream_is_refused() {
    // Item 13.
    let mut service = Service::start();
    let job = streaming(
        "stream_pile",
        &json!({"method": "GET", "url": "https://api.example.test/e"}),
    );
    service.assign_fetching(&job, pinning("api.example.test"), support::silent_fetches());
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "stream_limit", "message": words::STREAM_LIMIT}})
    );
    assert_eq!(service.frames_of("fetch").len(), 3);
}

#[test]
fn a_request_the_relays_frame_cannot_carry_is_refused_unsent() {
    // Item 13: a header value with a control byte, which no frame carries.
    let mut service = Service::start();
    let job = fetching(
        &json!({"method": "GET", "url": "https://api.example.test/x",
                               "headers": {"x-note": "a\u{1}b"}}),
    );
    service.assign(&job, pinning("api.example.test"));
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "invalid_request", "message": words::UNSENDABLE}})
    );
    assert!(service.frames_of("fetch").is_empty());
}
