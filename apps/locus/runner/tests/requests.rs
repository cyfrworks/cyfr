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
/// complete, and every event it sent before. Each line is awaited a minute,
/// or the attempt's budget when that is longer.
fn completed(service: &Service, job: &Job) -> (Value, Value, Vec<Value>) {
    let wait = SOON.max(Duration::from_millis(job.timeout_ms));
    let mut events = Vec::new();
    let complete = loop {
        let line = service.line(wait);
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

/// The sentence CYFR answers an attached request it refuses as `kind`
/// (`tests/fixtures/host_api.json`'s `attached_fetch` refusals), with
/// `{host}` where the request's host stands: the words the runner's own
/// refusal of the same request, and of a pin for the same reason, speak.
fn cyfrs_sentence(kind: &str) -> String {
    let v = support::fixture("host_api.json");
    let call = v["calls"]
        .as_array()
        .expect("the calls")
        .iter()
        .find(|call| call["callback"] == "attached_fetch")
        .expect("an attached_fetch call");
    let body: Value = serde_json::from_str(call["body"].as_str().expect("a body")).expect("JSON");
    let url = body["args"]["url"].as_str().expect("a url");
    let host = cyfr_runner::imports::http::Url::parse(url)
        .and_then(|url| url.host)
        .expect("a host");
    call["refusals"]
        .as_array()
        .expect("the refusals")
        .iter()
        .map(|refusal| {
            serde_json::from_str::<Value>(refusal["answer"].as_str().expect("an answer"))
                .expect("JSON")
        })
        .find(|answer| answer["type"] == kind)
        .and_then(|answer| {
            answer["message"]
                .as_str()
                .map(|message| message.replace(&host, "{host}"))
        })
        .unwrap_or_else(|| panic!("host_api.json refuses no attached request {kind}"))
}

#[test]
fn a_credential_header_or_a_framing_header_beside_a_connection_is_refused_by_shape_unsent() {
    for (headers, kind, message) in [
        (
            json!({"Authorization": "Bearer guest-supplied"}),
            "credential_header_refused",
            cyfrs_sentence("credential_header_refused"),
        ),
        (
            json!({"COOKIE": "a=b"}),
            "credential_header_refused",
            cyfrs_sentence("credential_header_refused"),
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
fn an_attached_answer_that_ends_before_its_own_end_hands_the_guest_nothing_of_it() {
    // Its head and a chunk, then the service's end with no code: CYFR's
    // answer is short of its `end` frame, so none of it is the guest's.
    let mut service = Service::start();
    let job = attaching(json!({}));
    service.assign_fetching(
        &job,
        Box::new(standard),
        Box::new(|fetch, job| {
            let call_id = fetch["call_id"].as_str().expect("a call id");
            let head = json!({"status": 200, "headers": []}).to_string();
            vec![
                Upstream::Frame(support::seal_frame(
                    job,
                    call_id,
                    0,
                    "head",
                    head.as_bytes(),
                )),
                Upstream::Frame(support::seal_frame(job, call_id, 1, "chunk", b"part")),
                Upstream::End(None),
            ]
        }),
    );
    let (output, complete, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"error": {"type": "http_error", "message": "HTTP request failed"}})
    );
    // CYFR answered what it was asked: the runner is reused.
    assert_eq!(complete["clean"], json!(true), "{complete}");
    assert!(denials(&service).is_empty());
}

#[test]
fn cyfrs_lost_refusal_of_an_attached_request_leaves_the_runner_unclean_and_its_unavailable_or_one_naming_no_call_id_reads_as_no_answer()
 {
    // CYFR's `lost`: what it did is unknown, as of a lost host call. Its
    // `unavailable` (a member that does not hold the control plane) did
    // nothing, and a guest error naming no call id is no answer to this
    // call: the guest reads either as a failed request, and the runner is
    // reused.
    for (answer, clean) in [
        (json!({"v": 3, "error": "lost"}), false),
        (json!({"v": 3, "error": "unavailable"}), true),
        (
            json!({"v": 3, "error": "guest_error", "type": "connection_not_granted",
                   "message": "No."}),
            true,
        ),
    ] {
        let mut service = Service::start();
        let job = attaching(json!({}));
        let refused = answer.clone();
        service.assign_fetching(
            &job,
            Box::new(standard),
            Box::new(move |_fetch, job| {
                vec![
                    support::answered_refusal(job, &refused, &support::Signed::default()),
                    Upstream::End(Some("refused")),
                ]
            }),
        );
        let (output, complete, _) = completed(&service, &job);
        assert_eq!(
            output,
            json!({"error": {"type": "http_error", "message": "HTTP request failed"}}),
            "{answer}"
        );
        assert_eq!(complete["clean"], json!(clean), "{answer}: {complete}");
        assert!(denials(&service).is_empty(), "{answer}");
    }
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
    // microseconds on the runner's one thread, beside the guest's reads:
    // this host's attempt takes some 12 s, a hosted runner's at most 25 s,
    // and the budget, which `completed` waits too, is seven times that.
    let job = Job {
        timeout_ms: 180_000,
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
async fn guests_calls_take_no_more_than_their_share_and_the_runners_own_still_find_a_place() {
    use cyfr_runner::host::{Op, Post as _};
    use cyfr_runner::relay::{MAX_CALLS, MAX_GUEST_CALLS, Relay};
    let attempt = "att_shares";
    let (_ours, theirs) = tokio::io::duplex(1 << 20);
    let (reader, writer) = tokio::io::split(theirs);
    let relay = Relay::start(reader, writer);
    relay.bind(attempt).await.expect("bound");
    let tool = Op::named("tool_call").expect("a callback");
    let fail = Op::named("fail").expect("a callback");
    assert!(tool.guest() && !fail.guest());
    let mut held = Vec::new();
    for _ in 0..MAX_GUEST_CALLS {
        held.push(relay.poster(attempt).place(tool).await.expect("a place"));
    }
    // A guest's next call waits for its share; the runner's own calls take
    // every place past it.
    let mut guest = relay.poster(attempt);
    let waiting = tokio::time::timeout(Duration::from_millis(200), guest.place(tool)).await;
    assert!(waiting.is_err(), "a guest's place past {MAX_GUEST_CALLS}");
    for _ in MAX_GUEST_CALLS..MAX_CALLS {
        let place = tokio::time::timeout(SOON, relay.poster(attempt).place(fail)).await;
        held.push(
            place
                .expect("the runner's call has a place")
                .expect("a place"),
        );
    }
    drop(held);
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
        let place = poster.place(op).await.expect("a place");
        answers.push(tokio::spawn(async move {
            poster
                .post(op, "v1 header".to_owned(), b"body".to_vec(), place)
                .await
        }));
    }
    // The one past them has no place: nothing of it is signed or sent.
    let mut late = relay.poster(attempt);
    let waiting = tokio::time::timeout(Duration::from_millis(200), late.place(op)).await;
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
        let _ = late.place(op).await;
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
    // Each bound stands at least five times its figure on a hosted
    // runner, whose test build is some 2.4 times slower than this host's
    // (here: about 0.9 s, 1.3 s, 0.2 s and 28 ms), and far under what a
    // quadratic reading or writing takes (the quadratic dot removal took
    // 1,957 ms). The body gives the release binary's figures.
    assert!(read_ms < 15_000, "request read: {read_ms} ms");
    assert!(text_ms < 20_000, "text answer: {text_ms} ms");
    assert!(base64_ms < 3_000, "base64 answer: {base64_ms} ms");
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
fn a_redirects_location_query_is_left_at_most_once_after_its_attempt_closes() {
    // After the attempt closes, a scan of the runner's writable memory finds
    // each needle at most once; before the answer's headers were held
    // cleared it found the `Location`'s query twice. A scan shows what is
    // found and attributes it to nothing, and freed memory is often reused,
    // so it shows no copy absent: the copies the runner makes are held
    // cleared by reading.
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
    let message = "HTTP egress refused by the worker service's check: api.example.test is not in \
                   the egress domains";
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

#[test]
fn streams_closed_while_they_drain_keep_no_buffer() {
    // Item 2: sixteen streams each given one byte and closed, each still
    // the relay's until its end, against one whole fetch.
    let mut service = Service::start();
    let job = fetching(&json!({"method": "GET", "url": "https://api.example.test/x"}));
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![vec![
            Upstream::Head(200, Vec::new(), b"x".to_vec()),
            Upstream::End(None),
        ]]),
    );
    let pid = service.pid();
    let (alone, _) = peak_while(pid, || completed(&service, &job));
    let mut service = Service::start();
    let job = streaming(
        "stream_flood",
        &json!({"method": "GET", "url": "https://api.example.test/events"}),
    );
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        Box::new(|_fetch, _job| vec![Upstream::Head(200, Vec::new(), b"x".to_vec())]),
    );
    let pid = service.pid();
    let (flood, (output, _, _)) = peak_while(pid, || completed(&service, &job));
    assert_eq!(output["error"]["type"], "stream_limit");
    let after = support::resident_kib(pid);
    eprintln!("draining: one fetch {alone} KiB; sixteen draining {flood} KiB, {after} KiB after");
    assert!(
        flood <= alone + 6 * 1024 && after <= alone + 6 * 1024,
        "sixteen draining streams held {flood} KiB ({after} KiB after) against {alone} KiB"
    );
}

#[test]
fn an_attempt_waits_for_a_watchers_report_before_it_completes() {
    // Item 3: the relay's refusal of the first stream arrives at once, and
    // CYFR answers its report two seconds later, after the guest has
    // returned: the attempt completes only once the report is answered.
    let mut service = Service::start();
    let job = streaming(
        "stream_aside",
        &json!({"method": "GET", "url": "https://api.example.test/events"}),
    );
    let mut pins = 0;
    service.assign_fetching(
        &job,
        Box::new(move |call, job| match call.op.as_str() {
            "egress_pin" => {
                pins += 1;
                pin(&format!("pin_{pins}"), "https", "api.example.test")
            }
            "record_denial" => Reply::Later(Duration::from_secs(2), json!(true)),
            _ => standard(call, job),
        }),
        in_turn(vec![
            vec![Upstream::End(Some("method_blocked"))],
            vec![
                Upstream::Head(200, Vec::new(), b"b".to_vec()),
                Upstream::End(None),
            ],
        ]),
    );
    let _ = completed(&service, &job);
    let ops = service.ops();
    let answered = ops.iter().position(|op| op == "answered:record_denial");
    let complete = ops.iter().position(|op| op == "complete");
    assert!(
        answered.is_some() && answered < complete,
        "the attempt completed before its report was answered: {ops:?}"
    );
}

#[test]
fn a_streams_valid_text_is_read_before_the_invalid_byte_after_it() {
    // Item 6: a whole event and an invalid byte arrive together.
    let mut service = Service::start();
    let job = streaming(
        "stream_once",
        &json!({"method": "GET", "url": "https://api.example.test/e"}),
    );
    let mut data = b"data: ready\n\n".to_vec();
    data.push(0xff);
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![vec![
            Upstream::Head(200, Vec::new(), Vec::new()),
            Upstream::Chunk(data),
        ]]),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"data": "data: ready\n\n", "done": false, "status": 200})
    );
}

#[test]
fn an_answer_is_written_into_a_reservation_counted_to_the_byte() {
    // Item 8: control characters, which escape to six bytes each, quotes,
    // text outside ASCII, Latin-1, and repeated headers.
    use cyfr_runner::imports::http::response;
    use std::time::Instant;
    let headers = vec![
        ("x-a".to_owned(), "1\u{1}\"".to_owned()),
        ("x-a".to_owned(), "two".to_owned()),
        ("x-b".to_owned(), "\u{e9}t\u{e9}".to_owned()),
    ];
    let mut text = vec![0x01u8; 1024];
    text.extend_from_slice("\"\\\n\u{e9}".as_bytes());
    for (body, base64) in [
        (text.clone(), false),
        (vec![0xe9u8, 0x01, b'"'], false),
        (text.clone(), true),
        (Vec::new(), false),
    ] {
        let answer = response(200, &headers, &body, base64);
        assert_eq!(answer.capacity(), answer.len(), "{body:?}");
        let read: Value = serde_json::from_str(&answer).expect("an answer");
        assert_eq!(
            read["headers"],
            json!({"x-a": "two", "x-b": "\u{e9}t\u{e9}"})
        );
        assert_eq!(read["status"], json!(200));
    }
    // The largest answer of control characters the ceiling allows, 50 MiB
    // escaped to 300 MiB, timed.
    let body = vec![0x01u8; 50 * 1024 * 1024];
    let started = Instant::now();
    let answer = response(200, &[], &body, false);
    let ms = started.elapsed().as_millis();
    eprintln!(
        "an answer of 50 MiB of control characters: {} bytes in {ms} ms",
        answer.len()
    );
    // The proof is the reservation; the time is printed, and the body
    // gives the release binary's.
    assert_eq!(answer.capacity(), answer.len());
}

#[tokio::test]
async fn a_host_call_is_signed_only_once_it_has_its_place() {
    // Item 9: the header's time is the place's, not the call's start.
    use cyfr_runner::host::{self, Op, Place, Post, Reached};
    struct Slow {
        placed_at: u64,
        signed_at: Option<u64>,
    }
    impl Post for Slow {
        async fn place(&mut self, _op: cyfr_runner::host::Op) -> Option<Place> {
            tokio::time::sleep(Duration::from_millis(300)).await;
            self.placed_at = support::now_ms();
            Some(Place::free())
        }

        async fn post(
            &mut self,
            _op: Op,
            header: String,
            _body: Vec<u8>,
            _place: Place,
        ) -> Option<Reached> {
            self.signed_at = Some(support::call_fields(&header).ts);
            None
        }
    }
    let job = Job::new("catalyst", &format!("{HOSTILE}/vault_probe.wasm"), "{}");
    let caller = support::caller(&job);
    let mut post = Slow {
        placed_at: 0,
        signed_at: None,
    };
    let started = support::now_ms();
    let op = Op::named("release_child").expect("a callback");
    let _ = host::call(&mut post, &caller, op, &serde_json::Map::new()).await;
    let signed = post.signed_at.expect("posted");
    assert!(
        signed >= post.placed_at && signed >= started + 300,
        "signed {signed}, placed {}",
        post.placed_at
    );
}

#[test]
fn a_streams_event_is_read_whole_before_whatever_tail_follows_it() {
    // A: an invalid byte, a stray continuation byte, and the first byte of
    // a character the stream then ends without. The first read takes the
    // whole event, the next answers the tail's error.
    let event = b"data: ready\n\n".to_vec();
    for (tail, ended) in [(0xffu8, false), (0x80, false), (0xc3, true)] {
        let mut chunk = event.clone();
        chunk.push(tail);
        let upstream = move || {
            let mut sent = vec![
                Upstream::Head(200, Vec::new(), Vec::new()),
                Upstream::Chunk(chunk.clone()),
            ];
            if ended {
                sent.push(Upstream::End(None));
            }
            sent
        };
        for (guest, expected) in [
            (
                "stream_once",
                json!({"data": "data: ready\n\n", "done": false, "status": 200}),
            ),
            ("stream_twice", not_encoded()),
        ] {
            let mut service = Service::start();
            let job = streaming(
                guest,
                &json!({"method": "GET", "url": "https://api.example.test/e"}),
            );
            service.assign_fetching(&job, pinning("api.example.test"), in_turn(vec![upstream()]));
            let (output, _, _) = completed(&service, &job);
            assert_eq!(output, expected, "{tail:#x}, {guest}");
        }
    }
}

#[test]
fn a_character_whose_bytes_arrive_apart_is_read_whole() {
    // A: the first byte of `é`, then its second after a pause.
    let mut service = Service::start();
    let job = streaming(
        "stream_until",
        &json!({"method": "GET", "url": "https://api.example.test/e"}),
    );
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![vec![
            Upstream::Head(200, Vec::new(), Vec::new()),
            Upstream::Chunk(vec![0xc3]),
            Upstream::Pause(Duration::from_millis(400)),
            Upstream::Chunk(vec![0xa9]),
        ]]),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"data": "\u{e9}", "done": false, "status": 200})
    );
}

#[test]
fn an_invalid_byte_at_a_streams_front_is_taken_alone_and_the_text_after_it_kept() {
    // A: the invalid byte answers the first read, the event the next.
    let mut chunk = vec![0xffu8];
    chunk.extend_from_slice(b"data: next\n\n");
    for (guest, expected) in [
        ("stream_once", not_encoded()),
        (
            "stream_twice",
            json!({"data": "data: next\n\n", "done": false, "status": 200}),
        ),
    ] {
        let mut service = Service::start();
        let job = streaming(
            guest,
            &json!({"method": "GET", "url": "https://api.example.test/e"}),
        );
        let chunk = chunk.clone();
        service.assign_fetching(
            &job,
            pinning("api.example.test"),
            in_turn(vec![vec![
                Upstream::Head(200, Vec::new(), Vec::new()),
                Upstream::Chunk(chunk),
            ]]),
        );
        let (output, _, _) = completed(&service, &job);
        assert_eq!(output, expected, "{guest}");
    }
}

// ============================================================================
// A guest's imports called in this process
// ============================================================================

/// A run's guest in this process, its HTTP imports called as the engine
/// calls them, over a real relay whose far end is the scripted service end
/// (`support::relay_fetching`): the calls CYFR was sent, and every frame of
/// the relay's, are the service end's record.
struct InProcess {
    guest: cyfr_runner::imports::Guest,
    calls: std::sync::Arc<std::sync::Mutex<Vec<support::Call>>>,
    frames: std::sync::Arc<std::sync::Mutex<Vec<Value>>>,
    /// The run's relay.
    relay: cyfr_runner::relay::Relay,
    /// The control channel the run's events are written to, held open.
    _events: tokio::io::DuplexStream,
}

/// A guest on a node of `limits` whose host calls `script` answers and
/// whose fetches `fetches` answers.
async fn in_process(
    script: support::Script,
    fetches: support::Fetches,
    limits: cyfr_runner::authority::Limits,
) -> InProcess {
    use std::sync::{Arc, Mutex};
    let job = Job::new(
        "catalyst",
        &format!("{HOSTILE}/attached_header_probe.wasm"),
        "{}",
    );
    let (ours, theirs) = std::os::unix::net::UnixStream::pair().expect("a socket pair");
    let calls = Arc::new(Mutex::new(Vec::new()));
    let frames = Arc::new(Mutex::new(Vec::new()));
    let (recorded, seen, served) = (calls.clone(), frames.clone(), job.clone());
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(move || support::relay_fetching(theirs, served, script, fetches, recorded, seen))
        .expect("the service end");
    ours.set_nonblocking(true).expect("a nonblocking socket");
    let (reader, writer) = tokio::net::UnixStream::from_std(ours)
        .expect("a socket")
        .into_split();
    let relay = cyfr_runner::relay::Relay::start(reader, writer);
    relay
        .bind(&job.attempt)
        .await
        .expect("the relay carries the attempt");
    let (events, written) = tokio::io::duplex(1 << 20);
    let control = cyfr_runner::control::Writer::start(written);
    let host = Arc::new(cyfr_runner::attempt::Host::new(
        support::caller(&job),
        relay.clone(),
        control.clone(),
    ));
    let runner = cyfr_runner::attempt::Runner {
        engine: cyfr_runner::engine::Engine::new().expect("an engine"),
        relay: relay.clone(),
        control,
        runner_id: support::RUNNER.to_owned(),
        boot: support::BOOT.to_owned(),
        tree: cyfr_runner::subtree::Tree::unserved(support::ATHANOR, &job.execution_id),
    };
    let run = cyfr_runner::imports::Run {
        host,
        component_ref: job.reference.clone(),
        limits,
        fields: std::collections::BTreeMap::new(),
        attached: std::collections::BTreeSet::new(),
        runner,
        intercepted: Vec::new(),
    };
    InProcess {
        guest: cyfr_runner::imports::Guest::new(Arc::new(run)),
        calls,
        frames,
        relay,
        _events: events,
    }
}

impl InProcess {
    /// The fetch import's answer to `request`.
    async fn fetch(&mut self, request: &Value) -> Value {
        use cyfr_runner::imports::catalyst::cyfr::http::fetch::Host as _;
        let answer = self
            .guest
            .request(request.to_string())
            .await
            .expect("the import answers");
        serde_json::from_str(&answer).expect("a JSON answer")
    }

    /// The streaming import's answer to `request`.
    async fn open(&mut self, request: &Value) -> Value {
        use cyfr_runner::imports::catalyst::cyfr::http::streaming::Host as _;
        let answer = self
            .guest
            .request(request.to_string())
            .await
            .expect("the import answers");
        serde_json::from_str(&answer).expect("a JSON answer")
    }

    async fn read(&mut self, handle: &str) -> Value {
        use cyfr_runner::imports::catalyst::cyfr::http::streaming::Host as _;
        let answer = self
            .guest
            .read(handle.to_owned())
            .await
            .expect("the import answers");
        serde_json::from_str(&answer).expect("a JSON answer")
    }

    async fn close(&mut self, handle: &str) -> Value {
        use cyfr_runner::imports::catalyst::cyfr::http::streaming::Host as _;
        let answer = self
            .guest
            .close(handle.to_owned())
            .await
            .expect("the import answers");
        serde_json::from_str(&answer).expect("a JSON answer")
    }

    /// The ops of the calls CYFR was sent so far, in order.
    fn ops(&self) -> Vec<String> {
        self.calls
            .lock()
            .expect("the calls")
            .iter()
            .map(|call| call.op.clone())
            .collect()
    }

    /// The args of the calls of `op` CYFR was sent so far.
    fn calls_of(&self, op: &str) -> Vec<Value> {
        self.calls
            .lock()
            .expect("the calls")
            .iter()
            .filter(|call| call.op == op)
            .map(|call| call.args.clone())
            .collect()
    }

    /// The relay's frames of `kind` the runner sent so far.
    fn frames_of(&self, kind: &str) -> Vec<Value> {
        self.frames
            .lock()
            .expect("the frames")
            .iter()
            .filter(|frame| frame["kind"] == kind)
            .cloned()
            .collect()
    }
}

/// Run `test` on a current-thread runtime on the stack the runner's own
/// runtime has.
fn in_a_runtime<F: std::future::Future<Output = ()> + 'static>(
    test: impl FnOnce() -> F + Send + 'static,
) {
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

/// The error envelope a guest is answered with.
fn refusal(kind: &str, message: &str) -> Value {
    json!({"error": {"type": kind, "message": message}})
}

/// What a guest is answered for a value no answer can encode
/// (`tests/fixtures/guest_error.json`'s `fallback`).
fn not_encoded() -> Value {
    support::fixture("guest_error.json")["fallback"]["answer"].clone()
}

/// An upstream's whole answer, `ok` with status 200, and what the guest
/// reads of it.
fn ok() -> Vec<Upstream> {
    vec![
        Upstream::Head(200, Vec::new(), b"ok".to_vec()),
        Upstream::End(None),
    ]
}

fn ok_answer() -> Value {
    json!({"status": 200, "headers": {}, "body": "ok"})
}

/// The same answer to the attached `fetch`, as CYFR seals it for its call
/// id.
fn attached_ok(fetch: &Value, job: &Job) -> Vec<Upstream> {
    let call_id = fetch["call_id"].as_str().expect("a call id");
    let head = json!({"status": 200, "headers": []}).to_string();
    vec![
        Upstream::Frame(support::seal_frame(
            job,
            call_id,
            0,
            "head",
            head.as_bytes(),
        )),
        Upstream::Frame(support::seal_frame(job, call_id, 1, "chunk", b"ok")),
        Upstream::Frame(support::seal_frame(job, call_id, 2, "end", b"")),
        Upstream::End(None),
    ]
}

/// CYFR's answers, each `egress_pin` answered a pin of the host its URL
/// names, `pin_1`, `pin_2` and on.
fn pinning_each() -> support::Script {
    let mut pins = 0;
    Box::new(move |call, job| match call.op.as_str() {
        "egress_pin" => {
            pins += 1;
            let url = call.args["url"].as_str().expect("a url");
            let host = cyfr_runner::imports::http::Url::parse(url)
                .and_then(|url| url.host)
                .expect("a host");
            pin(&format!("pin_{pins}"), "https", &host)
        }
        _ => standard(call, job),
    })
}

// ============================================================================
// What the runner's own reading refuses
// ============================================================================

#[test]
fn a_request_whose_method_or_url_does_not_read_is_refused_in_the_runners_words_and_asks_nothing() {
    // The guest writes the request, so no member's type is to be trusted:
    // each answers a typed refusal, and the guest goes on.
    in_a_runtime(|| async move {
        let mut guest = in_process(Box::new(standard), support::silent_fetches(), zero()).await;
        let charges = "https://api.example.test/v1/charges";
        for (request, message) in [
            (
                json!({"method": 1, "url": charges}),
                words::MALFORMED_REQUEST,
            ),
            (
                json!({"method": null, "url": charges}),
                words::MALFORMED_REQUEST,
            ),
            (json!({"method": "GET", "url": 2}), words::MALFORMED_REQUEST),
            (
                json!({"method": "GET", "url": {"href": "https://x.test"}}),
                words::MALFORMED_REQUEST,
            ),
            (
                json!({"method": "GET", "url": "not-a-url"}),
                words::NO_HOSTNAME,
            ),
            (
                json!({"method": "GET", "url": "http:///path"}),
                words::NO_HOSTNAME,
            ),
            // The sentence names none of a URL's credentials.
            (
                json!({"method": "GET", "url": "http://user:secret@api.example.test/x"}),
                words::URL_CREDENTIALS,
            ),
            (
                json!({"method": "GET", "url": "http://user@api.example.test/x"}),
                words::URL_CREDENTIALS,
            ),
            (
                json!({"method": "GET", "url": "http://:@api.example.test/x"}),
                words::URL_CREDENTIALS,
            ),
        ] {
            assert_eq!(
                guest.fetch(&request).await,
                refusal("invalid_request", message),
                "{request}"
            );
        }
        // Refused before any pin: nothing is asked of CYFR or sent.
        assert_eq!(guest.ops(), Vec::<String>::new());
        assert!(guest.frames_of("fetch").is_empty());
    });
}

#[test]
fn a_request_with_an_integer_past_cyfrs_bound_is_no_json_and_asks_nothing() {
    // CYFR reads an integer of at most `max_integer_chars` characters
    // (`tests/fixtures/wire_json.json`), and so does the runner a guest's
    // request: one longer is no JSON, as the request was to the reader
    // before.
    in_a_runtime(|| async move {
        let longest = cyfr_runner::wire::MAX_INTEGER_CHARS;
        let request = |digits: usize| -> Value {
            serde_json::from_str(&format!(
                r#"{{"method":"GET","url":"https://api.example.test/v1","n":{}}}"#,
                "9".repeat(digits)
            ))
            .expect("JSON")
        };
        let mut guest = in_process(Box::new(standard), support::silent_fetches(), zero()).await;
        let refused = refusal("invalid_json", words::REQUEST_NOT_JSON);
        assert_eq!(guest.fetch(&request(longest + 1)).await, refused);
        assert_eq!(guest.open(&request(longest + 1)).await, refused);
        assert_eq!(guest.ops(), Vec::<String>::new());
        // One within the bound reads, and asks for its pin.
        let _ = guest.fetch(&request(longest)).await;
        assert_eq!(guest.ops(), ["egress_pin"]);
    });
}

#[test]
fn a_url_of_a_scheme_no_edge_admits_is_refused_scheme_blocked_and_recorded_unpinned() {
    // A guest's URL names http or https: any other scheme is outside every
    // edge's egress schemes, refused as the scheme it is and recorded as a
    // scheme refusal, before any pin is asked.
    in_a_runtime(|| async move {
        let mut guest = in_process(Box::new(standard), support::silent_fetches(), zero()).await;
        for (url, scheme) in [
            ("ftp://api.example.test/file", Some("ftp")),
            ("FTP://api.example.test:21/file", Some("ftp")),
            ("ws://api.example.test/socket", Some("ws")),
            // A host and no scheme.
            ("//api.example.test/file", None),
        ] {
            let only = "and only http and https URLs are fetched";
            let sentence = match scheme {
                Some(scheme) => {
                    format!("HTTP egress refused: the URL's scheme is {scheme}, {only}")
                }
                None => format!("HTTP egress refused: the URL has no scheme, {only}"),
            };
            let request = json!({"method": "GET", "url": url});
            assert_eq!(
                guest.fetch(&request).await,
                refusal("scheme_blocked", &sentence),
                "{url}"
            );
            assert_eq!(
                guest.open(&request).await,
                refusal("scheme_blocked", &sentence),
                "{url}"
            );
            let recorded = json!({"message": sentence, "type": "scheme_blocked"});
            assert_eq!(
                guest.calls_of("record_denial")[..],
                [recorded.clone(), recorded],
                "{url}"
            );
            guest.calls.lock().expect("the calls").clear();
        }
        assert!(guest.frames_of("fetch").is_empty());
    });
}

#[test]
fn a_fetch_the_runner_refuses_in_its_own_words_is_answered_the_guest_error_vectors_sentence() {
    // `tests/fixtures/guest_error.json`'s `fetch_refusals`: each sentence
    // names what the guest's author changes.
    let vector = support::fixture("guest_error.json");
    let cases = vector["fetch_refusals"]
        .as_array()
        .expect("the fetch refusals")
        .clone();
    assert!(!cases.is_empty());
    in_a_runtime(move || async move {
        let mut guest = in_process(Box::new(standard), support::silent_fetches(), zero()).await;
        for case in &cases {
            let kind = case["type"].as_str().expect("a type");
            let message = case["message"].as_str().expect("a message");
            assert_eq!(
                guest.fetch(&case["request"]).await,
                refusal(kind, message),
                "{}",
                case["why"]
            );
        }
        assert!(guest.frames_of("fetch").is_empty());
    });
}

#[test]
fn a_stream_request_whose_members_are_of_no_shape_a_request_takes_is_a_stream_error() {
    // A request whose method or URL is no text, or whose body is neither
    // text nor null, is one no request is made of: a fetch is answered
    // invalid_request, and a stream the stream's own error, in the words
    // `tests/fixtures/guest_error.json` holds, a body's naming the body.
    let vector = support::fixture("guest_error.json");
    let streamed = vector["encode_error"]
        .as_array()
        .expect("the encode cases")
        .iter()
        .find(|case| case["type"] == "stream_error")
        .expect("a stream_error case")["answer"]
        .clone();
    in_a_runtime(move || async move {
        let mut guest = in_process(Box::new(standard), support::silent_fetches(), zero()).await;
        let url = "https://api.example.test/v1/stream";
        for request in [
            json!({"method": 1, "url": url}),
            json!({"method": null, "url": url}),
            json!({"method": "GET", "url": 2}),
        ] {
            assert_eq!(guest.open(&request).await, streamed, "{request}");
            assert_eq!(
                guest.fetch(&request).await,
                refusal("invalid_request", words::MALFORMED_REQUEST),
                "{request}"
            );
        }
        let body = "Invalid body: a string, or null for none";
        for value in [json!(5), json!(false), json!(true), json!({}), json!([])] {
            let request = json!({"method": "POST", "url": url, "body": value});
            assert_eq!(
                guest.open(&request).await,
                refusal("stream_error", body),
                "{request}"
            );
            assert_eq!(
                guest.fetch(&request).await,
                refusal("invalid_request", body),
                "{request}"
            );
        }
        assert_eq!(guest.ops(), Vec::<String>::new());
    });
}

#[test]
fn a_body_or_multipart_that_does_not_read_is_refused_in_the_runners_words_and_asks_nothing() {
    in_a_runtime(|| async move {
        let mut guest = in_process(Box::new(standard), support::silent_fetches(), zero()).await;
        let speech = "https://api.example.test/v1/audio/speech";
        let transcriptions = "https://api.example.test/v1/audio/transcriptions";
        for (request, message) in [
            (
                json!({"method": "POST", "url": speech, "body": "not-valid-base64!!!",
                       "body_encoding": "base64"}),
                words::BAD_BODY_BASE64.to_owned(),
            ),
            (
                json!({"method": "POST", "url": transcriptions, "body": "some body",
                       "multipart": [{"name": "model", "value": "whisper-1"}]}),
                words::BODY_AND_MULTIPART.to_owned(),
            ),
            (
                json!({"method": "POST", "url": transcriptions, "multipart": [
                    {"name": "file", "filename": "audio.mp3", "content_type": "audio/mpeg",
                     "data": "not-valid!!!"},
                    {"name": "model", "value": "whisper-1"}]}),
                words::bad_part_base64("file"),
            ),
            (
                json!({"method": "POST", "url": transcriptions,
                       "multipart": [{"value": "whisper-1"}]}),
                words::MULTIPART_PART.to_owned(),
            ),
        ] {
            assert_eq!(
                guest.fetch(&request).await,
                refusal("invalid_request", &message),
                "{request}"
            );
        }
        assert_eq!(guest.ops(), Vec::<String>::new());
        assert!(guest.frames_of("fetch").is_empty());
    });
}

#[test]
fn headers_read_as_an_object_or_as_pairs_and_any_other_shape_is_refused_before_the_pin() {
    in_a_runtime(|| async move {
        let mut guest = in_process(
            pinning("api.example.test"),
            Box::new(|_fetch, _job| ok()),
            zero(),
        )
        .await;
        let url = "https://api.example.test/x";
        // Pairs in order, a scalar value as its text; `null` as none.
        for headers in [
            json!([["Accept", "a"], ["X-Count", 2], ["accept", "b"]]),
            Value::Null,
        ] {
            let request = json!({"method": "GET", "url": url, "headers": headers});
            assert_eq!(guest.fetch(&request).await, ok_answer(), "{headers}");
        }
        let sent: Vec<Value> = guest
            .frames_of("fetch")
            .iter()
            .map(|fetch| fetch["headers"].clone())
            .collect();
        assert_eq!(
            sent,
            [
                json!([["Accept", "a"], ["X-Count", "2"], ["accept", "b"]]),
                json!([])
            ]
        );
        for headers in [
            json!([["Authorization"]]),
            json!([["Authorization", "Bearer a", "extra"]]),
            json!([{"Authorization": "Bearer a"}]),
            json!(["Authorization: Bearer a"]),
            json!([[1, "a"]]),
            json!([["", "a"]]),
            json!([["X-Nested", ["a"]]]),
            json!({"X-Nested": {"a": "b"}}),
            // Neither an object nor an array: never read as no headers.
            json!("Authorization: Bearer t"),
            json!(42),
            json!(true),
        ] {
            let request = json!({"method": "GET", "url": url, "headers": headers});
            assert_eq!(
                guest.fetch(&request).await,
                refusal("invalid_request", words::BAD_HEADERS),
                "{headers}"
            );
        }
        // CYFR was asked a pin for the two that read, and nothing else.
        assert_eq!(guest.ops(), ["egress_pin", "egress_pin"]);
        assert_eq!(guest.frames_of("fetch").len(), 2);
    });
}

#[test]
fn a_connection_that_is_no_text_or_names_no_need_is_refused_unsent_and_unreported() {
    // Neither is a refusal CYFR records (`Opus.Host.Storage`'s denials take
    // no `invalid_request`): nothing is reported.
    in_a_runtime(|| async move {
        let mut guest = in_process(Box::new(standard), support::silent_fetches(), zero()).await;
        let url = "https://api.example.test/x";
        assert_eq!(
            guest
                .fetch(&json!({"method": "GET", "url": url, "connection": 7}))
                .await,
            refusal("invalid_request", words::BAD_CONNECTION)
        );
        let long = "a".repeat(40);
        for connection in ["Not A Need", "API KEY", "", "1key", long.as_str()] {
            let request = json!({"method": "GET", "url": url, "connection": connection});
            assert_eq!(
                guest.fetch(&request).await,
                refusal("invalid_request", words::ATTACHED_UNREAD),
                "{connection}"
            );
        }
        assert_eq!(guest.ops(), Vec::<String>::new());
        assert!(guest.frames_of("fetch").is_empty());
    });
}

#[test]
fn a_stream_with_multipart_is_refused_before_its_pin() {
    in_a_runtime(|| async move {
        let mut guest = in_process(
            pinning("api.example.test"),
            support::silent_fetches(),
            zero(),
        )
        .await;
        let request = json!({"method": "POST",
            "url": "https://api.example.test/v1/audio/transcriptions", "headers": {}, "body": "",
            "multipart": [{"name": "model", "value": "whisper-1"}]});
        assert_eq!(
            guest.open(&request).await,
            refusal("invalid_request", words::STREAM_MULTIPART)
        );
        assert_eq!(guest.ops(), Vec::<String>::new());
        assert!(guest.frames_of("fetch").is_empty());
    });
}

#[test]
fn a_request_past_its_envelope_is_too_large_before_it_is_parsed() {
    // No JSON, and nested past the depth a document is read to: read first,
    // it would answer invalid_json.
    use cyfr_runner::imports::http::{Purpose, requested};
    let read = |request: &str, max_request_size: u64, purpose: Purpose| {
        let limits = cyfr_runner::authority::Limits {
            max_request_size,
            ..zero()
        };
        requested(request, &limits, purpose)
            .err()
            .map(|refused| (refused.kind, refused.message))
    };
    let past = "{".repeat(32_768);
    for (max, purpose) in [
        (16, Purpose::Fetch),
        (64, Purpose::Fetch),
        (16, Purpose::Stream),
    ] {
        assert_eq!(
            read(&past, max, purpose),
            Some((
                "request_too_large".to_owned(),
                words::REQUEST_TOO_LARGE.to_owned()
            )),
            "{max}, {purpose:?}"
        );
    }
    // Within its envelope, the same text is read, and is no JSON.
    assert_eq!(
        read(&"{".repeat(100), 16, Purpose::Fetch),
        Some((
            "invalid_json".to_owned(),
            words::REQUEST_NOT_JSON.to_owned()
        ))
    );
}

// ============================================================================
// What a request is sent as
// ============================================================================

#[test]
fn a_base64_body_is_sent_decoded_a_multipart_one_as_form_data_and_each_attached_request_has_its_own_call_id()
 {
    use cyfr_runner::wire::{decode_base64, decode_base64url, encode_base64};
    in_a_runtime(|| async move {
        let mut guest = in_process(
            pinning("api.example.test"),
            Box::new(|fetch, job| match fetch.get("call_id") {
                Some(_) => attached_ok(fetch, job),
                None => ok(),
            }),
            zero(),
        )
        .await;
        let url = "https://api.example.test/v1/x";
        let pinned = json!({"method": "POST", "url": url,
                            "body": encode_base64(b"raw bytes"), "body_encoding": "base64"});
        let mut attached = pinned.clone();
        attached["connection"] = json!("api_key");
        let multipart = json!({"method": "POST", "url": url, "connection": "api_key",
            "multipart": [{"name": "model", "value": "whisper-1"},
                          {"name": "file", "filename": "a.txt", "data": encode_base64(b"abc")}]});
        for request in [&pinned, &attached, &multipart] {
            assert_eq!(guest.fetch(request).await, ok_answer(), "{request}");
        }
        let sent = guest.frames_of("fetch");
        assert_eq!(sent.len(), 3);
        let body = |fetch: &Value| {
            decode_base64(fetch["body"].as_str().expect("a body")).expect("a base64 body")
        };
        assert_eq!(body(&sent[0]), b"raw bytes");
        assert_eq!(body(&sent[1]), b"raw bytes");
        // The parts encoded as `multipart/form-data`, the boundary in the
        // one content type.
        let headers = sent[2]["headers"].as_array().expect("headers");
        assert_eq!(headers.len(), 1, "{headers:?}");
        assert_eq!(headers[0][0], "content-type");
        let boundary = headers[0][1]
            .as_str()
            .and_then(|value| value.strip_prefix("multipart/form-data; boundary="))
            .expect("a multipart content type");
        assert_eq!(
            String::from_utf8(body(&sent[2])).expect("a text body"),
            format!(
                "--{boundary}\r\ncontent-disposition: form-data; name=\"model\"\r\n\r\n\
                 whisper-1\r\n--{boundary}\r\ncontent-disposition: form-data; name=\"file\"; \
                 filename=\"a.txt\"\r\ncontent-type: application/octet-stream\r\n\r\nabc\r\n\
                 --{boundary}--\r\n"
            )
        );
        // Each attached request carries a call id of its own, sixteen bytes
        // in base64url as CYFR reads one.
        let ids: Vec<&str> = sent[1..]
            .iter()
            .map(|fetch| fetch["call_id"].as_str().expect("a call id"))
            .collect();
        assert_ne!(ids[0], ids[1]);
        for id in &ids {
            assert_eq!(
                (id.len(), decode_base64url(id).map(|bytes| bytes.len())),
                (22, Some(16)),
                "{id}"
            );
        }
        // An attached request asks no pin.
        assert_eq!(guest.ops(), ["egress_pin"]);
    });
}

#[test]
fn an_answer_asked_in_base64_is_answered_with_its_body_encoding() {
    let mut service = Service::start();
    let job = fetching(
        &json!({"method": "GET", "url": "https://api.example.test/v1/speech",
                               "response_encoding": "base64"}),
    );
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![vec![
            Upstream::Head(
                200,
                vec![("content-type", "audio/mpeg".to_owned())],
                b"binary audio data".to_vec(),
            ),
            Upstream::End(None),
        ]]),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"status": 200, "headers": {"content-type": "audio/mpeg"},
               "body": cyfr_runner::wire::encode_base64(b"binary audio data"),
               "body_encoding": "base64"})
    );
}

// ============================================================================
// How a request ends
// ============================================================================

#[test]
fn a_connect_names_the_shorter_of_its_limits_and_a_wait_for_the_answer_the_requests() {
    in_a_runtime(|| async move {
        for (timeout, code, message) in [
            ("1s", "connect_timeout", words::connect_timeout(1_000)),
            ("30s", "timeout", words::request_timeout(30_000)),
        ] {
            let limits = cyfr_runner::authority::Limits {
                timeout: timeout.to_owned(),
                ..zero()
            };
            let mut guest = in_process(
                pinning("api.example.test"),
                in_turn(vec![vec![Upstream::End(Some(code))]]),
                limits,
            )
            .await;
            let request = json!({"method": "GET", "url": "https://api.example.test/x"});
            assert_eq!(
                guest.fetch(&request).await,
                refusal("timeout", &message),
                "{code}"
            );
            // A timeout is no refusal CYFR records.
            assert_eq!(guest.ops(), ["egress_pin"], "{code}");
        }
    });
}

#[test]
fn the_relays_metadata_refusal_answers_private_ip_blocked_for_a_fetch_and_a_hop_and_is_reported_once()
 {
    // The relay's connection, not the runner, refuses a metadata address
    // however CYFR pinned it, and ends the fetch the runner sent with its
    // code.
    let refused = refusal("private_ip_blocked", words::SERVICE_METADATA);
    let mut service = Service::start();
    let job = fetching(&json!({"method": "GET", "url": "https://meta.example.test/latest"}));
    service.assign_fetching(
        &job,
        pinning("meta.example.test"),
        in_turn(vec![vec![Upstream::End(Some("private_ip_blocked"))]]),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(output, refused);
    assert_eq!(denials(&service), [refused["error"].clone()]);

    // A redirect's hop, pinned from the pin it came from.
    let url = "https://api.example.test/latest";
    let mut service = Service::start();
    let job = Job::new(
        "catalyst",
        &format!("{HOSTILE}/fetch_twice.wasm"),
        &json!({"method": "GET", "url": url}).to_string(),
    );
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![
            vec![
                Upstream::Head(302, vec![("location", "/latest".to_owned())], Vec::new()),
                Upstream::End(None),
            ],
            vec![Upstream::End(Some("private_ip_blocked"))],
        ]),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(output, refused);
    assert_eq!(
        service.calls_of("egress_pin")[1].args,
        json!({"url": url, "purpose": "redirect", "from": "pin_1"})
    );
    assert_eq!(denials(&service), [refused["error"].clone()]);
}

#[test]
fn each_pin_code_the_relay_ends_a_fetch_with_answers_as_that_refused_pin_and_reports_nothing() {
    // CYFR decides the send again at the relay's own ask. Its refusal there
    // is the guest's and recorded by CYFR already; a pin the service could
    // not take (`unavailable`, `lost`, `elsewhere`, `expired`) is the
    // runner's own refusal, of a type CYFR records none of.
    let host = "api.example.test";
    let cases = [
        (
            "pin_domain",
            "domain_blocked",
            cyfrs_sentence("domain_blocked").replace("{host}", host),
        ),
        ("pin_denied", "private_ip_blocked", words::pin_denied(host)),
        (
            "pin_metadata",
            "private_ip_blocked",
            words::pin_metadata(host),
        ),
        ("pin_resolution", "dns_error", words::pin_resolution(host)),
        (
            "pin_redirect_credentials",
            "redirect_credentials",
            words::redirect_refused(host),
        ),
        (
            "pin_malformed",
            "invalid_request",
            words::BAD_URL.to_owned(),
        ),
        ("pin_unavailable", "dns_error", words::pin_unavailable(host)),
        ("pin_lost", "dns_error", words::PIN_NOT_CURRENT.to_owned()),
        ("pin_elsewhere", "dns_error", words::pin_elsewhere(host)),
        ("pin_expired", "dns_error", words::pin_expired(host)),
    ];
    in_a_runtime(move || async move {
        let ends = cases
            .iter()
            .map(|(code, _, _)| vec![Upstream::End(Some(*code))])
            .collect();
        let mut guest = in_process(pinning(host), in_turn(ends), zero()).await;
        let request = json!({"method": "GET", "url": "https://api.example.test/x"});
        for (code, kind, message) in &cases {
            assert_eq!(
                guest.fetch(&request).await,
                refusal(kind, message),
                "{code}"
            );
        }
        assert_eq!(guest.ops(), vec!["egress_pin"; cases.len()]);
        assert_eq!(guest.frames_of("fetch").len(), cases.len());
    });
}

#[test]
fn a_stream_whose_request_fails_before_its_head_reads_request_failed() {
    for (code, message) in [
        ("econnrefused", words::http_failed("econnrefused")),
        ("http_error", words::HTTP_FAILED.to_owned()),
    ] {
        let mut service = Service::start();
        let job = streaming(
            "stream_until",
            &json!({"method": "GET", "url": "https://api.example.test/refused"}),
        );
        service.assign_fetching(
            &job,
            pinning("api.example.test"),
            in_turn(vec![vec![Upstream::End(Some(code))]]),
        );
        let (output, _, _) = completed(&service, &job);
        assert_eq!(output, refusal("request_failed", &message), "{code}");
        assert!(denials(&service).is_empty(), "{code}");
    }
}

#[test]
fn a_frame_that_does_not_read_hands_a_fetch_nothing_of_its_answer_and_a_stream_nothing_from_it_on()
{
    in_a_runtime(|| async move {
        let mut guest = in_process(
            Box::new(standard),
            Box::new(|fetch, job| {
                let call_id = fetch["call_id"].as_str().expect("a call id");
                let sealed = |seq, kind, plain: &[u8]| {
                    Upstream::Frame(support::seal_frame(job, call_id, seq, kind, plain))
                };
                let head = json!({"status": 200, "headers": []}).to_string();
                vec![
                    sealed(0, "head", head.as_bytes()),
                    sealed(1, "chunk", b"data: a\n\n"),
                    // A chunk's kind byte before what is no sealed frame:
                    // the answer ends here, and nothing after it is read.
                    Upstream::Frame(b"cforged".to_vec()),
                    sealed(2, "chunk", b"data: b\n\n"),
                    sealed(3, "end", b""),
                    Upstream::End(None),
                ]
            }),
            zero(),
        )
        .await;
        let request = json!({"method": "POST", "url": "https://api.example.test/v1/chat",
                             "connection": "api_key", "body": "{}"});
        assert_eq!(
            guest.fetch(&request).await,
            refusal("http_error", words::HTTP_FAILED)
        );
        let opened = guest.open(&request).await;
        let handle = opened["handle"].as_str().expect("a handle").to_owned();
        let mut data = String::new();
        let mut error = None;
        for _ in 0..100 {
            let read = guest.read(&handle).await;
            if let Some(refused) = read.get("error") {
                error = Some(refused.clone());
                break;
            }
            assert_eq!(read["done"], json!(false), "{read}");
            data.push_str(read["data"].as_str().expect("data"));
        }
        assert_eq!(data, "data: a\n\n");
        assert_eq!(
            error,
            Some(json!({"type": "request_failed", "message": words::HTTP_FAILED}))
        );
        assert!(guest.calls_of("record_denial").is_empty());
    });
}

// ============================================================================
// A redirect the guest follows
// ============================================================================

#[test]
fn a_same_origin_hop_carries_the_requests_credentials() {
    let url = "https://api.example.test/landing";
    let credentials = json!({"Authorization": "Bearer sk_test", "Cookie": "session=1",
                             "x-trace": "t"});
    let mut service = Service::start();
    let job = Job::new(
        "catalyst",
        &format!("{HOSTILE}/fetch_twice.wasm"),
        &json!({"method": "GET", "url": url, "headers": credentials}).to_string(),
    );
    service.assign_fetching(
        &job,
        pinning("api.example.test"),
        in_turn(vec![
            vec![
                Upstream::Head(302, vec![("location", "/landing".to_owned())], Vec::new()),
                Upstream::End(None),
            ],
            vec![
                Upstream::Head(200, Vec::new(), b"landed".to_vec()),
                Upstream::End(None),
            ],
        ]),
    );
    let (output, _, _) = completed(&service, &job);
    assert_eq!(
        output,
        json!({"status": 200, "headers": {}, "body": "landed"})
    );
    let pins: Vec<Value> = service
        .calls_of("egress_pin")
        .into_iter()
        .map(|call| call.args)
        .collect();
    assert_eq!(
        pins,
        [
            json!({"url": url, "purpose": "fetch"}),
            json!({"url": url, "purpose": "redirect", "from": "pin_1"}),
        ]
    );
    let sent: Vec<(Value, Value)> = service
        .frames_of("fetch")
        .iter()
        .map(|fetch| (fetch["pin"].clone(), fetch["headers"].clone()))
        .collect();
    let headers = json!([
        ["Authorization", "Bearer sk_test"],
        ["Cookie", "session=1"],
        ["x-trace", "t"]
    ]);
    assert_eq!(
        sent,
        [(json!("pin_1"), headers.clone()), (json!("pin_2"), headers)]
    );
}

#[test]
fn a_hop_cyfr_pins_on_another_origin_than_its_pin_is_refused_unsent_and_the_next_request_there_is_the_guests_own()
 {
    in_a_runtime(|| async move {
        let elsewhere = "https://other.example.test/elsewhere";
        let mut guest = in_process(
            pinning_each(),
            in_turn(vec![
                vec![
                    Upstream::Head(302, vec![("location", elsewhere.to_owned())], Vec::new()),
                    Upstream::End(None),
                ],
                vec![
                    Upstream::Head(200, Vec::new(), b"reached".to_vec()),
                    Upstream::End(None),
                ],
            ]),
            zero(),
        )
        .await;
        let start = "https://api.example.test/redirect";
        let credentials = json!({"Authorization": "Bearer sk_test"});
        let hop = json!({"method": "GET", "url": elsewhere, "headers": credentials});
        assert_eq!(
            guest
                .fetch(&json!({"method": "GET", "url": start, "headers": credentials}))
                .await,
            json!({"status": 302, "headers": {"location": elsewhere}, "body": ""})
        );
        // CYFR pins the hop on its own origin, which is not its pin's.
        assert_eq!(
            guest.fetch(&hop).await,
            refusal(
                "redirect_credentials",
                &words::redirect_refused("other.example.test")
            )
        );
        assert_eq!(guest.frames_of("fetch").len(), 1);
        // The hop was the redirect's alone: the guest's next request there
        // is its own, and carries what it sends.
        assert_eq!(
            guest.fetch(&hop).await,
            json!({"status": 200, "headers": {}, "body": "reached"})
        );
        assert_eq!(
            guest.calls_of("egress_pin"),
            [
                json!({"url": start, "purpose": "fetch"}),
                json!({"url": elsewhere, "purpose": "redirect", "from": "pin_1"}),
                json!({"url": elsewhere, "purpose": "fetch"}),
            ]
        );
        let sent = guest.frames_of("fetch");
        assert_eq!(
            (&sent[1]["pin"], &sent[1]["headers"]),
            (
                &json!("pin_3"),
                &json!([["Authorization", "Bearer sk_test"]])
            )
        );
        // No refusal CYFR records (`Opus.Host.Storage`'s denials take no
        // `redirect_credentials`): nothing is reported.
        assert_eq!(guest.ops(), ["egress_pin"; 3]);
    });
}

#[test]
fn cyfrs_refusal_of_a_hop_is_redirect_credentials_naming_its_host_unsent_and_unreported() {
    in_a_runtime(|| async move {
        let mut pins = 0;
        let mut guest = in_process(
            Box::new(move |call, job| match call.op.as_str() {
                "egress_pin" => {
                    pins += 1;
                    if pins == 1 {
                        pin("pin_1", "https", "api.example.test")
                    } else {
                        Reply::Error("redirect_credentials", json!({}))
                    }
                }
                _ => standard(call, job),
            }),
            in_turn(vec![vec![
                Upstream::Head(
                    302,
                    vec![("location", "https://login.other.test/session".to_owned())],
                    Vec::new(),
                ),
                Upstream::End(None),
            ]]),
            zero(),
        )
        .await;
        let credentials = json!({"Authorization": "Bearer sk_test", "Cookie": "session=1"});
        let start = json!({"method": "GET", "url": "https://api.example.test/redirect",
                           "headers": credentials});
        assert_eq!(guest.fetch(&start).await["status"], json!(302));
        let hop = json!({"method": "GET", "url": "https://login.other.test/session",
                         "headers": credentials});
        assert_eq!(
            guest.fetch(&hop).await,
            refusal(
                "redirect_credentials",
                &words::redirect_refused("login.other.test")
            )
        );
        assert_eq!(
            guest.calls_of("egress_pin")[1],
            json!({"url": "https://login.other.test/session", "purpose": "redirect",
                   "from": "pin_1"})
        );
        assert_eq!(guest.frames_of("fetch").len(), 1);
        assert_eq!(guest.ops(), ["egress_pin", "egress_pin"]);
    });
}

/// A pin CYFR answers, `id`, of `scheme`, `host` and `port`: an IPv6 host
/// in brackets beside its address.
fn pin_of(id: &str, scheme: &str, host: &str, port: u16) -> Reply {
    let (ip, family) = match host.strip_prefix('[').and_then(|h| h.strip_suffix(']')) {
        Some(address) => (address.to_owned(), 6),
        None => ("203.0.113.10".to_owned(), 4),
    };
    let pin = json!({"id": id, "ip": ip, "family": family, "scheme": scheme, "port": port,
                     "host": host, "expires_at": support::now_ms() + 30_000});
    Reply::Ok(pin)
}

#[test]
fn a_hops_pin_on_another_port_scheme_or_ipv6_host_than_its_pins_is_refused_unsent_and_the_same_origin_spelled_otherwise_is_sent()
 {
    // The guest's request, the pin CYFR answers it, where its redirect
    // points, the hop's pin (on the hop's own origin) and the host the
    // refusal names, or none for a hop on its pin's origin.
    type Case = (
        &'static str,
        (&'static str, &'static str, u16),
        &'static str,
        (&'static str, &'static str, u16),
        Option<&'static str>,
    );
    let cases: [Case; 5] = [
        (
            "https://api.example.test/a",
            ("https", "api.example.test", 443),
            "https://api.example.test:8443/b",
            ("https", "api.example.test", 8443),
            Some("api.example.test"),
        ),
        (
            "https://api.example.test:8080/a",
            ("https", "api.example.test", 8080),
            "http://api.example.test:8080/b",
            ("http", "api.example.test", 8080),
            Some("api.example.test"),
        ),
        (
            "https://[2001:db8::1]/a",
            ("https", "[2001:db8::1]", 443),
            "https://[2001:db8::2]/b",
            ("https", "[2001:db8::2]", 443),
            Some("2001:db8::2"),
        ),
        (
            "https://api.example.test/a",
            ("https", "api.example.test", 443),
            "https://API.example.test:443/c",
            ("https", "api.example.test", 443),
            None,
        ),
        (
            "https://[2001:db8::1]/a",
            ("https", "[2001:db8::1]", 443),
            "https://[2001:DB8:0::1]:443/c",
            ("https", "[2001:db8::1]", 443),
            None,
        ),
    ];
    in_a_runtime(move || async move {
        for (start, from, hop, pinned, refused) in cases {
            let mut pins = 0;
            let mut guest = in_process(
                Box::new(move |call, job| match call.op.as_str() {
                    "egress_pin" => {
                        pins += 1;
                        let (scheme, host, port) = if pins == 1 { from } else { pinned };
                        pin_of(&format!("pin_{pins}"), scheme, host, port)
                    }
                    _ => standard(call, job),
                }),
                in_turn(vec![
                    vec![
                        Upstream::Head(302, vec![("location", hop.to_owned())], Vec::new()),
                        Upstream::End(None),
                    ],
                    ok(),
                ]),
                zero(),
            )
            .await;
            let credentials = json!({"Authorization": "Bearer sk_test"});
            let first = guest
                .fetch(&json!({"method": "GET", "url": start, "headers": credentials}))
                .await;
            assert_eq!(first["status"], json!(302), "{hop}: {first}");
            let followed = guest
                .fetch(&json!({"method": "GET", "url": hop, "headers": credentials}))
                .await;
            assert_eq!(
                guest.calls_of("egress_pin")[1],
                json!({"url": hop, "purpose": "redirect", "from": "pin_1"}),
                "{hop}"
            );
            let sent = guest.frames_of("fetch");
            match refused {
                Some(host) => {
                    assert_eq!(
                        followed,
                        refusal("redirect_credentials", &words::redirect_refused(host)),
                        "{hop}"
                    );
                    assert_eq!(sent.len(), 1, "{hop}");
                }
                None => {
                    assert_eq!(followed, ok_answer(), "{hop}");
                    assert_eq!(
                        (&sent[1]["pin"], &sent[1]["headers"]),
                        (
                            &json!("pin_2"),
                            &json!([["Authorization", "Bearer sk_test"]])
                        ),
                        "{hop}"
                    );
                }
            }
            assert_eq!(guest.ops(), ["egress_pin", "egress_pin"], "{hop}");
        }
    });
}

// ============================================================================
// A stream's handles and its pin
// ============================================================================

#[test]
fn a_read_of_a_handle_that_does_not_exist_is_invalid_handle_and_its_close_is_ok() {
    in_a_runtime(|| async move {
        let mut guest = in_process(Box::new(standard), support::silent_fetches(), zero()).await;
        assert_eq!(
            guest.read("nonexistent-handle").await,
            refusal(
                "invalid_handle",
                &words::unknown_handle("nonexistent-handle")
            )
        );
        for _ in 0..2 {
            assert_eq!(guest.close("nonexistent-handle").await, json!({"ok": true}));
        }
        assert_eq!(guest.ops(), Vec::<String>::new());
    });
}

#[test]
fn a_stream_that_outlives_its_pin_reads_on_to_its_end() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};
    in_a_runtime(|| async move {
        let expires = Arc::new(AtomicU64::new(0));
        let pinned = expires.clone();
        let script: support::Script = Box::new(move |call, job| match call.op.as_str() {
            "egress_pin" => {
                let expires_at = support::now_ms() + 1_000;
                pinned.store(expires_at, Ordering::SeqCst);
                Reply::Ok(json!({"id": "pin_1", "ip": "203.0.113.10", "family": 4,
                                 "scheme": "https", "port": 443, "host": "api.example.test",
                                 "expires_at": expires_at}))
            }
            _ => standard(call, job),
        });
        // The rest of the answer comes half a second past the pin's expiry.
        let fetches = in_turn(vec![vec![
            Upstream::Head(200, Vec::new(), b"first ".to_vec()),
            Upstream::Pause(Duration::from_millis(1_500)),
            Upstream::Chunk(b"last".to_vec()),
            Upstream::End(None),
        ]]);
        let mut guest = in_process(script, fetches, zero()).await;
        let url = "https://api.example.test/long";
        let opened = guest.open(&json!({"method": "GET", "url": url})).await;
        let handle = opened["handle"].as_str().expect("a handle").to_owned();
        let mut data = String::new();
        let mut ended_at = None;
        for _ in 0..200 {
            let read = guest.read(&handle).await;
            assert!(read.get("error").is_none(), "{read}");
            data.push_str(read["data"].as_str().expect("data"));
            if read["done"] == json!(true) {
                ended_at = Some(support::now_ms());
                break;
            }
        }
        assert_eq!(data, "first last");
        let ended_at = ended_at.expect("the stream ended");
        let expired = expires.load(Ordering::SeqCst);
        assert!(
            ended_at > expired,
            "ended {ended_at}, its pin expired {expired}"
        );
        // The one pin the runner asks for a stream, when it opens.
        assert_eq!(
            guest.calls_of("egress_pin"),
            [json!({"url": url, "purpose": "stream"})]
        );
    });
}

// ============================================================================
// The envelope, the answer's bound and the relay's credit
// ============================================================================

/// A fetch request of exactly `bytes` bytes, its padding in a member the
/// request does not read.
fn padded_request(bytes: usize) -> String {
    let (head, tail) = (
        r#"{"method":"GET","url":"https://api.example.test/x","pad":""#,
        r#""}"#,
    );
    format!(
        "{head}{}{tail}",
        "a".repeat(bytes - head.len() - tail.len())
    )
}

#[test]
fn a_request_of_exactly_twice_its_limit_and_4096_bytes_is_read_and_one_byte_more_refused() {
    use cyfr_runner::imports::http::{Purpose, requested};
    // The node's limit, a zero limit, whose envelope holds the framing
    // alone, and a small one.
    for max in [zero().max_request_size, 0, 3_000] {
        let limits = cyfr_runner::authority::Limits {
            max_request_size: max,
            ..zero()
        };
        let envelope = usize::try_from(2 * max + 4096).expect("a size");
        for purpose in [Purpose::Fetch, Purpose::Stream] {
            assert!(
                requested(&padded_request(envelope), &limits, purpose).is_ok(),
                "{max}: {envelope} bytes"
            );
            let refused = requested(&padded_request(envelope + 1), &limits, purpose).err();
            assert_eq!(
                refused.map(|refused| (refused.kind, refused.message)),
                Some((
                    "request_too_large".to_owned(),
                    "Request exceeds the consented max_request_size for this component.".to_owned()
                )),
                "{max}: {} bytes",
                envelope + 1
            );
        }
    }
}

#[test]
fn an_answer_of_exactly_max_response_size_is_answered_one_byte_more_refused_and_none_answered() {
    in_a_runtime(|| async move {
        let limits = cyfr_runner::authority::Limits {
            max_response_size: 100,
            ..zero()
        };
        let answer = |bytes: usize| {
            vec![
                Upstream::Head(200, Vec::new(), vec![b'a'; bytes]),
                Upstream::End(None),
            ]
        };
        let mut guest = in_process(
            pinning("api.example.test"),
            in_turn(vec![answer(100), answer(101), answer(0)]),
            limits,
        )
        .await;
        let request = json!({"method": "GET", "url": "https://api.example.test/x"});
        assert_eq!(
            guest.fetch(&request).await,
            json!({"status": 200, "headers": {}, "body": "a".repeat(100)})
        );
        let refused = refusal(
            "response_too_large",
            "Response body (101 bytes) exceeds limit (100 bytes)",
        );
        assert_eq!(guest.fetch(&request).await, refused);
        assert_eq!(
            guest.fetch(&request).await,
            json!({"status": 200, "headers": {}, "body": ""})
        );
        assert_eq!(guest.calls_of("record_denial"), [refused["error"].clone()]);
    });
}

/// An attached answer of `body` for `fetch`, sealed for its call id in
/// chunks of `piece` bytes, each frame sent only once the runner's credit
/// covers it, as the service sends one, and its end once every byte sent
/// was granted back; and the bytes of its frames in all.
fn attached_answer(fetch: &Value, job: &Job, body: &[u8], piece: usize) -> (Vec<Upstream>, u64) {
    let call_id = fetch["call_id"].as_str().expect("a call id");
    let head = json!({"status": 200, "headers": []}).to_string();
    let mut frames = vec![support::seal_frame(
        job,
        call_id,
        0,
        "head",
        head.as_bytes(),
    )];
    for (seq, chunk) in body.chunks(piece).enumerate() {
        frames.push(support::seal_frame(
            job,
            call_id,
            seq as u64 + 1,
            "chunk",
            chunk,
        ));
    }
    let seq = frames.len() as u64;
    frames.push(support::seal_frame(job, call_id, seq, "end", b""));
    credited(frames)
}

/// Wait on the runtime until `holds` holds, within a minute: what it looks
/// for is the runner's relay's, which runs on the same runtime.
async fn until(mut holds: impl AsyncFnMut() -> bool) {
    let until = std::time::Instant::now() + Duration::from_secs(60);
    while !holds().await {
        assert!(
            std::time::Instant::now() < until,
            "the condition did not hold within a minute"
        );
        tokio::time::sleep(Duration::from_millis(20)).await; // sleep-ok: polls the relay, bounded by a minute
    }
}

/// `frames`, each sent only once the runner's credit covers it, then the
/// fetch's end once every byte sent was granted back; and the bytes sent.
fn credited(frames: Vec<Vec<u8>>) -> (Vec<Upstream>, u64) {
    let window = cyfr_runner::relay::INITIAL_CREDIT;
    let mut answer = Vec::new();
    let mut sent = 0u64;
    for frame in frames {
        sent += frame.len() as u64;
        if sent > window {
            answer.push(Upstream::AfterCredit(sent - window));
        }
        answer.push(Upstream::Frame(frame));
    }
    answer.push(Upstream::AfterCredit(sent));
    answer.push(Upstream::End(None));
    (answer, sent)
}

#[test]
fn an_attached_answer_past_one_credit_window_completes_granted_back_by_its_frames_bytes() {
    use std::sync::{Arc, Mutex};
    in_a_runtime(|| async move {
        let window = usize::try_from(cyfr_runner::relay::INITIAL_CREDIT).expect("a size");
        // Seven tenths of a window more than a window, in frames under the
        // attached frame's bound.
        let body: Vec<u8> = (0..window + window * 7 / 10)
            .map(|at| b'a' + u8::try_from(at % 26).expect("a letter"))
            .collect();
        let expected = String::from_utf8(body.clone()).expect("text");
        let sent = Arc::new(Mutex::new(0u64));
        let total = sent.clone();
        let limits = cyfr_runner::authority::Limits {
            max_response_size: 3 * window as u64,
            ..zero()
        };
        let mut guest = in_process(
            Box::new(standard),
            Box::new(move |fetch, job| {
                let (answer, bytes) = attached_answer(fetch, job, &body, 32 * 1024);
                *total.lock().expect("the total") = bytes;
                answer
            }),
            limits,
        )
        .await;
        let request = json!({"method": "GET", "url": "https://api.example.test/v1/big",
                             "connection": "api_key"});
        let answer = guest.fetch(&request).await;
        assert_eq!(
            answer["status"],
            json!(200),
            "{}",
            &answer.to_string()[..200]
        );
        assert!(
            answer["body"] == expected.as_str(),
            "the body arrived whole"
        );
        let sent = *sent.lock().expect("the total");
        assert!(sent > window as u64, "{sent}");
        // Every frame's bytes were granted back, so the service ended the
        // fetch: nothing is outstanding on the channel.
        let re = guest.frames_of("fetch")[0]["seq"].as_u64().expect("a seq");
        until(async || support::granted(&guest.frames, re) == sent).await;
        until(async || guest.relay.idle().await).await;
        assert_eq!(support::granted(&guest.frames, re), sent);
    });
}

#[test]
fn after_an_attached_frame_that_does_not_read_the_runner_grants_back_the_rest_and_its_channel_goes_idle()
 {
    // The service ends the fetch only once every byte it sent was granted
    // back: a runner that held any back would hold the fetch open.
    use std::sync::{Arc, Mutex};
    in_a_runtime(|| async move {
        let sent = Arc::new(Mutex::new(0u64));
        let total = sent.clone();
        let mut guest = in_process(
            Box::new(standard),
            Box::new(move |fetch, job| {
                let call_id = fetch["call_id"].as_str().expect("a call id");
                let head = json!({"status": 200, "headers": []}).to_string();
                let (answer, bytes) = credited(vec![
                    support::seal_frame(job, call_id, 0, "head", head.as_bytes()),
                    support::seal_frame(job, call_id, 1, "chunk", b"part"),
                    b"cforged".to_vec(),
                    support::seal_frame(job, call_id, 2, "chunk", &[b'b'; 40_000]),
                    support::seal_frame(job, call_id, 3, "end", b""),
                ]);
                *total.lock().expect("the total") = bytes;
                answer
            }),
            zero(),
        )
        .await;
        let request = json!({"method": "POST", "url": "https://api.example.test/v1/chat",
                             "connection": "api_key", "body": "{}"});
        assert_eq!(
            guest.fetch(&request).await,
            refusal("http_error", "HTTP request failed")
        );
        let sent = *sent.lock().expect("the total");
        let re = guest.frames_of("fetch")[0]["seq"].as_u64().expect("a seq");
        until(async || guest.relay.idle().await).await;
        assert_eq!(support::granted(&guest.frames, re), sent);
        assert!(guest.calls_of("record_denial").is_empty());
    });
}

#[test]
fn an_open_stream_its_guest_has_not_read_is_granted_nothing_and_a_read_exactly_what_it_took() {
    in_a_runtime(|| async move {
        let window = usize::try_from(cyfr_runner::relay::INITIAL_CREDIT).expect("a size");
        // The stream's whole window, then two fetches whose answers come
        // after it on the relay: each read only once the runner read what
        // came before it.
        let stream = std::iter::once(Upstream::Head(200, Vec::new(), Vec::new()))
            .chain((0..5).map(|_| Upstream::Chunk(vec![b'a'; window / 5])))
            .collect();
        let mut guest = in_process(pinning_each(), in_turn(vec![stream, ok(), ok()]), zero()).await;
        let opened = guest
            .open(&json!({"method": "GET", "url": "https://api.example.test/events"}))
            .await;
        let handle = opened["handle"].as_str().expect("a handle").to_owned();
        let barrier = json!({"method": "GET", "url": "https://api.example.test/barrier"});
        assert_eq!(guest.fetch(&barrier).await, ok_answer());
        // The service end records each frame before it answers it, and the
        // barrier's answer came after the stream's fetch on the relay: the
        // stream's frame is recorded now, not yet when `open` answered.
        let re = guest.frames_of("fetch")[0]["seq"].as_u64().expect("a seq");
        assert_eq!(support::granted(&guest.frames, re), 0, "nothing was read");
        let read = guest.read(&handle).await;
        let took = read["data"].as_str().expect("data").len() as u64;
        assert!(took > 0, "{read}");
        assert_eq!(guest.fetch(&barrier).await, ok_answer());
        assert_eq!(support::granted(&guest.frames, re), took);
    });
}

/// The limits of an unbound authority.
fn zero() -> cyfr_runner::authority::Limits {
    cyfr_runner::authority::Limits::zero()
}
