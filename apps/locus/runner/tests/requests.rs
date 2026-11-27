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
            vec![
                Upstream::Head(200, Vec::new(), b"data: one\n".to_vec()),
                Upstream::Chunk(b"data: two\n".to_vec()),
            ]
        }),
    );
    let (output, _, events) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"data": "data: one\n", "done": false, "status": 200})
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
    // The piece the guest read is granted as it read it, and the one it
    // never read as the stream drains.
    support::eventually(|| credit(&service) == 20);
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
