// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The runner's wires held to the vector files Prima's own tests read
//! (`tests/fixtures`): each bound the crate holds is the vector's, and
//! every case of each section the crate reads runs through the crate's
//! public entry points.
//!
//! - `runner_control.json`: every frame encodes to its line and decodes
//!   back, every refusal is refused with its reason, and every
//!   environment reads as its runner or is refused naming its variable.
//! - `runner_relay.json`: the runner's half of the exchange, each frame it
//!   sends encoded to exactly its bytes and each the service sends decoded,
//!   and every refusal the runner receives.
//! - `worker_auth.json`: a host call's canonical string, header and sealed
//!   body and answer, and every assignment read.
//! - `host_api.json`: the callbacks' retry classes and timeouts, every
//!   call a runner makes as it crosses, and every answer outcome.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use cyfr_runner::assignment::{self, Assignment};
use cyfr_runner::auth::{self, Attempt, AttemptKeys, CallFields, Direction};
use cyfr_runner::control::{self, Environment, EnvironmentRefusal, Message, Relay};
use cyfr_runner::host::{self, Caller, Op, Outcome, Post, Reached, Reading, Retry};
use cyfr_runner::relay::{self, Channel, Incoming, Outgoing};
use cyfr_runner::wire;

fn fixture(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../tests/fixtures")
        .join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}

/// The cases of the section `name`, which a renamed or emptied section
/// fails.
fn cases<'a>(section: &'a Value, name: &str) -> &'a Vec<Value> {
    let cases = section
        .as_array()
        .unwrap_or_else(|| panic!("the vectors have no section {name}"));
    assert!(!cases.is_empty(), "the vectors' section {name} is empty");
    cases
}

fn s(value: &Value) -> &str {
    value
        .as_str()
        .unwrap_or_else(|| panic!("not text: {value}"))
}

fn n(value: &Value) -> u64 {
    value
        .as_u64()
        .unwrap_or_else(|| panic!("not a count: {value}"))
}

fn key(hex: &Value) -> Zeroizing<[u8; 32]> {
    Zeroizing::new(wire::hex_key(s(hex)).expect("a 64-digit key"))
}

/// The bytes of a vector's hex text.
fn unhex(hex: &Value) -> Vec<u8> {
    let text = s(hex);
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
        .collect()
}

/// A vector's IV, as its hex text spells it.
fn iv(hex: &Value) -> [u8; 12] {
    unhex(hex).try_into().expect("a 12-byte IV")
}

fn attempt(value: &Value) -> Attempt {
    Attempt {
        athanor_id: s(&value["athanor_id"]).to_owned(),
        execution_id: s(&value["execution_id"]).to_owned(),
        attempt: s(&value["attempt"]).to_owned(),
        fence: n(&value["fence"]),
        generation: n(&value["generation"]),
        service: s(&value["service"]).to_owned(),
    }
}

// ============================================================================
// runner_control.json
// ============================================================================

/// A message as the vectors write one: its type and fields, `input` as
/// text and each key in hex.
fn message_json(message: &Message) -> Value {
    let mut object = Map::new();
    let mut put = |name: &str, value: Value| {
        object.insert(name.to_owned(), value);
    };
    match message {
        Message::Assign {
            assignment,
            input,
            keys,
        } => {
            put("type", "assign".into());
            put("assignment", assignment.as_str().into());
            put(
                "input",
                String::from_utf8(input.to_vec())
                    .expect("text input")
                    .into(),
            );
            let a = &keys.attempt;
            let attempt = serde_json::json!({
                "athanor_id": a.athanor_id, "execution_id": a.execution_id, "attempt": a.attempt,
                "fence": a.fence, "generation": a.generation, "service": a.service,
            });
            put(
                "keys",
                serde_json::json!({
                    "attempt": attempt,
                    "call": wire::hex(keys.call.as_ref()),
                    "seal": wire::hex(keys.seal.as_ref()),
                }),
            );
        }
        Message::CancelChild { execution_id } => {
            put("type", "cancel_child".into());
            put("execution_id", execution_id.as_str().into());
        }
        Message::Child {
            execution_id,
            attempt,
        } => {
            put("type", "child".into());
            put("execution_id", execution_id.as_str().into());
            put("attempt", attempt.as_str().into());
        }
        Message::Complete {
            execution_id,
            clean,
        } => {
            put("type", "complete".into());
            put("execution_id", execution_id.as_str().into());
            put("clean", (*clean).into());
        }
        Message::Exit { runner, open } => {
            put("type", "exit".into());
            put("runner", runner.as_str().into());
            put(
                "open",
                open.iter().map(|a| Value::from(a.as_str())).collect(),
            );
        }
    }
    Value::Object(object)
}

fn message_from(json: &Value) -> Message {
    match s(&json["type"]) {
        "assign" => Message::Assign {
            assignment: Zeroizing::new(s(&json["assignment"]).to_owned()),
            input: Zeroizing::new(s(&json["input"]).as_bytes().to_vec()),
            keys: AttemptKeys {
                attempt: attempt(&json["keys"]["attempt"]),
                call: key(&json["keys"]["call"]),
                seal: key(&json["keys"]["seal"]),
            },
        },
        "cancel_child" => Message::CancelChild {
            execution_id: s(&json["execution_id"]).to_owned(),
        },
        "child" => Message::Child {
            execution_id: s(&json["execution_id"]).to_owned(),
            attempt: s(&json["attempt"]).to_owned(),
        },
        "complete" => Message::Complete {
            execution_id: s(&json["execution_id"]).to_owned(),
            clean: json["clean"].as_bool().expect("a boolean"),
        },
        "exit" => Message::Exit {
            runner: s(&json["runner"]).to_owned(),
            open: json["open"]
                .as_array()
                .expect("a list")
                .iter()
                .map(|a| s(a).to_owned())
                .collect(),
        },
        other => panic!("no message type {other}"),
    }
}

fn control_line(case: &Value) -> Vec<u8> {
    if let Some(line) = case.get("line") {
        return s(line).as_bytes().to_vec();
    }
    let fill = &case["repeated_line"];
    let line = format!(
        "{}{}{}",
        s(&fill["prefix"]),
        s(&fill["repeat"]).repeat(n(&fill["times"]) as usize),
        s(&fill["suffix"])
    );
    if let Some(bytes) = case.get("line_bytes") {
        assert_eq!(line.len() as u64, n(bytes), "{}", s(&case["why"]));
    }
    line.into_bytes()
}

fn control_refusal(case: &Value) -> control::Refusal {
    let field = || s(&case["field"]).to_owned();
    match s(&case["reason"]) {
        "oversize_line" => control::Refusal::OversizeLine,
        "malformed" => control::Refusal::Malformed,
        "bad_version" => control::Refusal::BadVersion,
        "unknown_type" => control::Refusal::UnknownType,
        "unknown_field" => control::Refusal::UnknownField(field()),
        "missing_field" => control::Refusal::MissingField(field()),
        "wrong_type" => control::Refusal::WrongType(field()),
        "invalid_field" => control::Refusal::InvalidField(field()),
        "oversize" => control::Refusal::Oversize(field()),
        other => panic!("no control refusal {other}"),
    }
}

#[test]
fn control_bounds_are_the_vectors() {
    let v = fixture("runner_control.json");
    assert_eq!(control::VERSION, n(&v["version"]));
    assert_eq!(control::MAX_LINE_BYTES as u64, n(&v["max_line_bytes"]));
    assert_eq!(control::MAX_INPUT_BYTES as u64, n(&v["max_input_bytes"]));
    assert_eq!(control::MAX_OPEN as u64, n(&v["max_open"]));
}

#[test]
fn control_every_valid_frame_encodes_to_its_line_and_decodes_back() {
    let v = fixture("runner_control.json");
    let valid = cases(&v["valid"], "valid");
    assert!(valid.len() >= 6, "{} valid frames", valid.len());
    for case in valid {
        let why = s(&case["why"]);
        let line = s(&case["line"]);
        let message = message_from(&case["message"]);
        let mut expected = line.as_bytes().to_vec();
        expected.push(b'\n');
        let encoded = control::encode(&message).expect(why);
        assert_eq!(
            String::from_utf8_lossy(&encoded),
            String::from_utf8_lossy(&expected),
            "{why}"
        );
        for bytes in [line.as_bytes().to_vec(), expected.clone()] {
            let decoded =
                control::decode(&bytes).unwrap_or_else(|refusal| panic!("{why}: {refusal:?}"));
            assert_eq!(message_json(&decoded), case["message"], "{why}");
        }
    }
}

#[test]
fn control_every_invalid_line_is_refused_with_its_reason() {
    let v = fixture("runner_control.json");
    let invalid = cases(&v["invalid"], "invalid");
    assert!(invalid.len() >= 64, "{} invalid frames", invalid.len());
    for case in invalid {
        let why = s(&case["why"]);
        assert_eq!(
            control::decode(&control_line(case)).err(),
            Some(control_refusal(case)),
            "{why}"
        );
    }
}

#[test]
fn control_every_decode_only_line_decodes_to_its_message() {
    let v = fixture("runner_control.json");
    for case in cases(&v["decode_only"], "decode_only") {
        let why = s(&case["why"]);
        let line = control_line(case);
        let decoded = control::decode(&line).unwrap_or_else(|refusal| panic!("{why}: {refusal:?}"));
        assert_eq!(message_json(&decoded), case["message"], "{why}");
        let encoded = control::encode(&message_from(&case["message"])).expect(why);
        assert_ne!(
            encoded[..encoded.len() - 1],
            line[..],
            "{why}: the encoder writes it so"
        );
    }
}

fn environment(value: &Value) -> Vec<(OsString, OsString)> {
    value
        .as_object()
        .expect("an environment")
        .iter()
        .map(|(k, v)| (OsString::from(k), OsString::from(s(v))))
        .collect()
}

fn runner_json(read: &Environment) -> Value {
    let relay = match &read.relay {
        Relay::Fd(fd) => serde_json::json!({ "fd": fd }),
        Relay::Socket(path) => serde_json::json!({ "socket": path }),
    };
    serde_json::json!({
        "runner_id": read.runner_id, "service_id": read.service_id, "boot": read.boot,
        "control_fd": read.control_fd, "relay": relay,
    })
}

#[test]
fn control_every_environment_reads_as_its_runner_or_is_refused_naming_its_variable() {
    let v = fixture("runner_control.json");
    let env = &v["environment"];
    let names = [
        control::SERVICE_KEY,
        control::RUNNER_ID,
        control::SERVICE_ID,
        control::BOOT_ID,
    ];

    // What the service writes starts the runner it names.
    let written = &env["written"];
    let read =
        Environment::read(environment(&written["environment"])).expect("the written environment");
    let settings = &written["settings"];
    assert_eq!(read.runner_id, s(&settings["runner_id"]));
    assert_eq!(read.service_id, s(&settings["service_id"]));
    assert_eq!(read.boot, s(&settings["boot"]));
    assert_eq!(
        (read.control_fd, &read.relay),
        (control::DEFAULT_CONTROL_FD, &Relay::Fd(control::RELAY_FD))
    );

    for case in cases(&env["valid"], "valid") {
        let why = s(&case["why"]);
        let read = Environment::read(environment(&case["environment"]))
            .unwrap_or_else(|r| panic!("{why}: {r}"));
        assert_eq!(runner_json(&read), case["runner"], "{why}");
    }

    let invalid = cases(&env["invalid"], "invalid");
    assert!(
        invalid.len() >= 22,
        "{} invalid environments",
        invalid.len()
    );
    for case in invalid {
        let why = s(&case["why"]);
        let name = s(&case["name"]);
        assert!(
            names.contains(&name) || [control::CONTROL_FD, control::RELAY_SOCKET].contains(&name),
            "{why}: {name}"
        );
        let refused = match Environment::read(environment(&case["environment"])) {
            Err(EnvironmentRefusal::Refused(variable)) => ("refused", variable),
            Err(EnvironmentRefusal::Missing(variable)) => ("missing", variable),
            Err(EnvironmentRefusal::Malformed(variable)) => ("malformed", variable),
            Ok(read) => panic!("{why}: read as {read:?}"),
        };
        assert_eq!(refused, (s(&case["reason"]), name), "{why}");
    }
}

// ============================================================================
// runner_relay.json
// ============================================================================

fn relay_json(case: &Value) -> String {
    if let Some(json) = case.get("json") {
        return s(json).to_owned();
    }
    let fill = &case["json_fill"];
    format!(
        "{}{}{}",
        s(&fill["prefix"]),
        s(&fill["repeat"]).repeat(n(&fill["times"]) as usize),
        s(&fill["suffix"])
    )
}

fn relay_bytes(case: &Value) -> Vec<u8> {
    if let Some(hex) = case.get("encoded_hex") {
        let hex = s(hex);
        return (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("hex"))
            .collect();
    }
    let json = relay_json(case);
    let mut bytes = (json.len() as u32).to_be_bytes().to_vec();
    bytes.extend_from_slice(json.as_bytes());
    bytes
}

fn body(value: &Value) -> Vec<u8> {
    wire::decode_base64(s(value)).expect("base64")
}

fn headers(value: &Value) -> Vec<relay::Header> {
    value
        .as_array()
        .expect("headers")
        .iter()
        .map(|pair| (s(&pair[0]).to_owned(), s(&pair[1]).to_owned()))
        .collect()
}

fn status(value: &Value) -> Option<u16> {
    value
        .as_u64()
        .map(|status| u16::try_from(status).expect("a status"))
}

/// The frame a runner sends, as a vector's JSON spells it.
fn outgoing(frame: &Value) -> Outgoing {
    let attempt = s(&frame["attempt"]).to_owned();
    match s(&frame["kind"]) {
        "host_call" => Outgoing::HostCall {
            attempt,
            op: Op::named(s(&frame["op"])).expect("a runner's op"),
            header: s(&frame["header"]).to_owned(),
            body: body(&frame["body"]),
        },
        "fetch" if frame.get("pin").is_some() => Outgoing::PinnedFetch {
            attempt,
            pin: s(&frame["pin"]).to_owned(),
            method: s(&frame["method"]).to_owned(),
            path: s(&frame["path"]).to_owned(),
            headers: headers(&frame["headers"]),
            body: body(&frame["body"]),
        },
        "fetch" => Outgoing::AttachedFetch {
            attempt,
            call_id: s(&frame["call_id"]).to_owned(),
            connection: s(&frame["connection"]).to_owned(),
            purpose: s(&frame["purpose"]).to_owned(),
            method: s(&frame["method"]).to_owned(),
            url: s(&frame["url"]).to_owned(),
            headers: headers(&frame["headers"]),
            body: body(&frame["body"]),
        },
        "credit" => Outgoing::Credit {
            attempt,
            re: n(&frame["re"]),
            bytes: n(&frame["bytes"]),
        },
        "close" => Outgoing::Close {
            attempt,
            reason: s(&frame["reason"]).to_owned(),
        },
        other => panic!("a runner sends no {other}"),
    }
}

/// The frame a runner receives, as a vector's JSON spells it.
fn incoming(frame: &Value) -> Incoming {
    let attempt = s(&frame["attempt"]).to_owned();
    let seq = n(&frame["seq"]);
    match s(&frame["kind"]) {
        "host_answer" => Incoming::HostAnswer {
            attempt,
            seq,
            re: n(&frame["re"]),
            status: status(&frame["status"]),
            body: body(&frame["body"]),
        },
        "fetch_chunk" => Incoming::FetchChunk {
            attempt,
            seq,
            re: n(&frame["re"]),
            status: status(&frame["status"]),
            headers: (!frame["headers"].is_null()).then(|| headers(&frame["headers"])),
            body: body(&frame["body"]),
        },
        "fetch_end" => Incoming::FetchEnd {
            attempt,
            seq,
            re: n(&frame["re"]),
            error: frame["error"].as_str().map(str::to_owned),
        },
        "attached_frame" => Incoming::AttachedFrame {
            attempt,
            seq,
            re: n(&frame["re"]),
            frame: body(&frame["frame"]),
        },
        "attached_refusal" => Incoming::AttachedRefusal {
            attempt,
            seq,
            re: n(&frame["re"]),
            header: s(&frame["header"]).to_owned(),
            body: body(&frame["body"]),
        },
        "close" => Incoming::Close {
            attempt,
            seq,
            reason: s(&frame["reason"]).to_owned(),
        },
        other => panic!("a runner receives no {other}"),
    }
}

fn relay_refusal(case: &Value) -> relay::Refusal {
    let field = || s(&case["field"]).to_owned();
    match s(&case["reason"]) {
        "frame_too_large" => relay::Refusal::FrameTooLarge,
        "malformed" => relay::Refusal::Malformed,
        "bad_version" => relay::Refusal::BadVersion,
        "unknown_kind" => relay::Refusal::UnknownKind,
        "wrong_direction" => relay::Refusal::WrongDirection,
        "unknown_field" => relay::Refusal::UnknownField(field()),
        "missing_field" => relay::Refusal::MissingField(field()),
        "wrong_type" => relay::Refusal::WrongType(field()),
        "invalid_field" => relay::Refusal::InvalidField(field()),
        "body_too_large" => relay::Refusal::BodyTooLarge,
        "out_of_order" => relay::Refusal::OutOfOrder,
        "unknown_attempt" => relay::Refusal::UnknownAttempt,
        "unknown_reference" => relay::Refusal::UnknownReference,
        "wrong_answer" => relay::Refusal::WrongAnswer,
        "credit_exceeded" => relay::Refusal::CreditExceeded,
        other => panic!("no relay refusal {other}"),
    }
}

/// The runner's channel after the exchange's first `count` frames: each it
/// sends encoded to exactly the vector's bytes, each it receives decoded
/// to the vector's frame.
fn play(v: &Value, count: usize) -> Channel {
    let mut channel = Channel::new(s(&v["attempt"])).expect("the vectors' attempt");
    for case in cases(&v["exchange"], "exchange").iter().take(count) {
        let why = s(&case["why"]);
        let bytes = relay_bytes(case);
        if let Some(digest) = case.get("encoded_sha256") {
            assert_eq!(wire::hex(&Sha256::digest(&bytes)), s(digest), "{why}");
        }
        let frame: Value = serde_json::from_str(&relay_json(case)).expect("JSON");
        match s(&case["from"]) {
            "runner" => {
                // The length, then the JSON as text, so a difference reads.
                let encoded = channel.encode(&outgoing(&frame)).expect(why);
                let spelled = |bytes: &[u8]| {
                    (
                        bytes[..4].to_vec(),
                        String::from_utf8_lossy(&bytes[4..]).into_owned(),
                    )
                };
                assert_eq!(spelled(&encoded), spelled(&bytes), "{why}");
            }
            _service => {
                let (frames, used) = channel
                    .decode(&bytes)
                    .unwrap_or_else(|r| panic!("{why}: {r:?}"));
                assert_eq!(
                    (frames, used),
                    (vec![incoming(&frame)], bytes.len()),
                    "{why}"
                );
            }
        }
    }
    channel
}

#[test]
fn relay_bounds_are_the_vectors() {
    let v = fixture("runner_relay.json");
    assert_eq!(relay::VERSION, n(&v["version"]));
    assert_eq!(relay::MAX_BODY_BYTES as u64, n(&v["max_body_bytes"]));
    assert_eq!(relay::MAX_FRAME_BYTES as u64, n(&v["max_frame_bytes"]));
    assert_eq!(relay::INITIAL_CREDIT, n(&v["initial_credit"]));
    assert_eq!(relay::MAX_HEADERS as u64, n(&v["max_headers"]));
    assert_eq!(
        relay::MAX_HEADER_NAME_BYTES as u64,
        n(&v["max_header_name_bytes"])
    );
    assert_eq!(
        relay::MAX_HEADER_VALUE_BYTES as u64,
        n(&v["max_header_value_bytes"])
    );
    assert_eq!(
        relay::MAX_SIGNED_HEADER_BYTES as u64,
        n(&v["max_signed_header_bytes"])
    );
    assert_eq!(
        relay::MAX_ATTACHED_FRAME_BYTES as u64,
        n(&v["max_attached_frame_bytes"])
    );
    let names = |section: &Value, name: &str| -> Vec<String> {
        cases(section, name)
            .iter()
            .map(|n| s(n).to_owned())
            .collect()
    };
    let ops = names(&v["ops"], "ops");
    assert_eq!(Op::all().map(Op::name).collect::<Vec<_>>(), ops);
    assert_eq!(relay::METHODS.to_vec(), names(&v["methods"], "methods"));
    assert_eq!(relay::PURPOSES.to_vec(), names(&v["purposes"], "purposes"));
    assert_eq!(relay::MAX_PATH_BYTES as u64, n(&v["max_path_bytes"]));
    assert_eq!(relay::MAX_URL_BYTES as u64, n(&v["max_url_bytes"]));
}

#[test]
fn relay_every_frame_the_encoder_refuses_is_not_sent_and_changes_nothing() {
    let v = fixture("runner_relay.json");
    let exchange = cases(&v["exchange"], "exchange");
    for case in cases(&v["encode_refusals"], "encode_refusals") {
        let why = s(&case["why"]);
        let after = n(&case["after"]) as usize;
        let mut channel = play(&v, after);
        // A call a runner does not make is no `Op`: the type refuses it.
        if let Some(op) = case["frame"].get("op")
            && Op::named(s(op)).is_none()
        {
            assert_eq!(case.get("member").map(s), Some("op"), "{why}");
            continue;
        }
        let refused = channel.encode(&outgoing(&case["frame"])).err();
        let expected = match (case.get("member"), case.get("reason")) {
            (Some(member), None) => relay::Unsent::Invalid(relay::Invalid(leak(s(member)))),
            (None, Some(_)) => relay::Unsent::Refused(relay_refusal(case)),
            _ => panic!("{why}: a refusal names a member or a reason"),
        };
        assert_eq!(refused, Some(expected), "{why}");
        // The channel numbers the exchange's next runner frame as the
        // vector does: the refused frame took no seq and opened nothing.
        let next = exchange[after..]
            .iter()
            .find(|frame| frame["from"] == "runner")
            .expect(why);
        let frame: Value = serde_json::from_str(&relay_json(next)).expect("JSON");
        let state_free = channel.encode(&outgoing(&frame)).expect(why);
        assert_eq!(state_free, relay_bytes(next), "{why}");
    }
}

/// A member's name as the crate spells it, `'static`.
fn leak(name: &str) -> &'static str {
    Box::leak(name.to_owned().into_boxed_str())
}

#[test]
fn relay_a_pinned_fetchs_path_and_an_attached_fetchs_url_are_taken_at_their_bounds() {
    let v = fixture("runner_relay.json");
    let exchange = cases(&v["exchange"], "exchange");
    let frame = |index: usize| -> Value {
        serde_json::from_str(&relay_json(&exchange[index])).expect("JSON")
    };
    let mut pinned = frame(2);
    pinned["path"] = format!("/{}", "a".repeat(n(&v["max_path_bytes"]) as usize - 1)).into();
    assert!(play(&v, 2).encode(&outgoing(&pinned)).is_ok());
    let mut attached = frame(8);
    let url = "https://api.example.com/";
    attached["url"] = format!(
        "{url}{}",
        "a".repeat(n(&v["max_url_bytes"]) as usize - url.len())
    )
    .into();
    assert!(play(&v, 8).encode(&outgoing(&attached)).is_ok());
}

#[test]
fn relay_the_runner_plays_its_half_of_the_exchange() {
    let v = fixture("runner_relay.json");
    let count = v["exchange"].as_array().expect("exchange").len();
    let channel = play(&v, count);
    assert!(channel.idle(), "every call answered and every fetch ended");
}

#[test]
fn relay_service_frames_decode_split_anywhere() {
    // The service's frames before the first runner grant, as one stream
    // handed over in two pieces at every split of its first frames.
    let v = fixture("runner_relay.json");
    let exchange = v["exchange"].as_array().expect("exchange");
    let call = play(&v, 1);
    let answer = relay_bytes(&exchange[1]);
    for split in 0..=answer.len() {
        let mut channel = call.clone();
        let (first, used) = channel.decode(&answer[..split]).expect("a prefix waits");
        let rest = [&answer[used..split], &answer[split..]].concat();
        let (second, _used) = channel.decode(&rest).expect("the rest");
        assert_eq!([first, second].concat().len(), 1, "split at {split}");
    }
}

#[test]
fn relay_every_refusal_the_runner_receives_closes_with_its_reason() {
    let v = fixture("runner_relay.json");
    let runner: Vec<&Value> = cases(&v["refusals"], "refusals")
        .iter()
        .filter(|case| case["receiver"] == "runner")
        .collect();
    assert!(
        runner.len() >= 44,
        "{} refusals the runner receives",
        runner.len()
    );
    for case in runner {
        let why = s(&case["why"]);
        let mut channel = play(&v, n(&case["after"]) as usize);
        let refusal = relay_refusal(case);
        assert_eq!(
            channel.decode(&relay_bytes(case)).err(),
            Some(refusal.clone()),
            "{why}"
        );
        let code = if case.get("field").is_some() {
            "malformed"
        } else {
            s(&case["reason"])
        };
        assert_eq!(refusal.close_code(), code, "{why}");
    }
}

// ============================================================================
// worker_auth.json
// ============================================================================

fn call_fields(v: &Value, call: &Value) -> CallFields {
    CallFields {
        attempt: attempt(&v["attempt"]),
        boot: s(&v["boot"]).to_owned(),
        runner: s(&call["runner"]).to_owned(),
        member: s(&v["member"]).to_owned(),
        ts: n(&call["ts"]),
        nonce: s(&call["nonce"]).to_owned(),
    }
}

#[test]
fn auth_a_host_calls_canonical_string_and_header_are_the_vectors() {
    let v = fixture("worker_auth.json");
    let call = &v["call"];
    let fields = call_fields(&v, call);
    let body = s(&call["body"]).as_bytes();
    assert_eq!(
        auth::canonical(&fields, body).expect("valid fields"),
        s(&call["canonical"])
    );
    let header = auth::host_call_header(&key(&v["keys"]["attempt_call_hex"]), &fields, body)
        .expect("valid fields");
    assert_eq!(header, s(&call["header"]));
    assert!(header.starts_with(&format!("v1 kind={} ", auth::CALL_KIND)));
    assert!(s(&call["canonical"]).starts_with(&format!(
        "{}/{}\n",
        auth::RUNTIME_LABEL,
        auth::CALL_KIND
    )));
}

#[test]
fn auth_a_sealed_body_and_answer_reproduce_and_open_only_as_themselves() {
    let v = fixture("worker_auth.json");
    let sealed = &v["sealed_call"];
    let fields = call_fields(&v, &v["call"]);
    let seal = key(&v["keys"]["attempt_seal_hex"]);
    let body = s(&v["call"]["body"]);
    let answer = s(&sealed["answer"]);

    let sealed_body = auth::seal_call(
        &seal,
        Direction::Body,
        &fields,
        body.as_bytes(),
        &iv(&sealed["body_iv_hex"]),
    );
    assert_eq!(sealed_body.expect("sealed"), s(&sealed["body_sealed"]));
    let sealed_answer = auth::seal_call(
        &seal,
        Direction::Answer,
        &fields,
        answer.as_bytes(),
        &iv(&sealed["answer_iv_hex"]),
    );
    assert_eq!(sealed_answer.expect("sealed"), s(&sealed["answer_sealed"]));

    let open = |direction, text: &Value| {
        auth::open_call(&seal, direction, &fields, s(text).as_bytes()).map(|p| p.to_vec())
    };
    assert_eq!(
        open(Direction::Body, &sealed["body_sealed"]),
        Ok(body.as_bytes().to_vec())
    );
    assert_eq!(
        open(Direction::Answer, &sealed["answer_sealed"]),
        Ok(answer.as_bytes().to_vec())
    );
    // Each opens only as its own direction and call.
    assert_eq!(
        open(Direction::Answer, &sealed["body_sealed"]),
        Err(auth::Unsealable)
    );
    let other = CallFields {
        nonce: "n_other".to_owned(),
        ..fields.clone()
    };
    assert!(
        auth::open_call(
            &seal,
            Direction::Body,
            &other,
            s(&sealed["body_sealed"]).as_bytes()
        )
        .is_err()
    );
}

/// A read assignment as its payload spells it: every member it carries,
/// none for an absent optional one.
fn assignment_json(read: &Assignment) -> Value {
    let mut object = serde_json::json!({
        "v": assignment::VERSION,
        "generation": read.generation, "service": read.service, "boot": read.boot, "member": read.member,
        "issued_at": read.issued_at, "claim_by": read.claim_by, "execution_id": read.execution_id,
        "attempt": read.attempt, "fence": read.fence, "root_execution_id": read.root_execution_id,
        "athanor_id": read.athanor_id, "actor": read.actor.value(), "authority": read.authority.value(),
        "input_digest": read.input_digest, "timeout_ms": read.timeout_ms, "deadline": read.deadline,
        "lease_until": read.lease_until, "intercepted": read.intercepted,
        "component": {
            "ref": read.component.reference, "type": read.component.kind, "digest": read.component.digest,
            "declared_needs": read.component.declared_needs,
        },
    });
    let map = object.as_object_mut().expect("an object");
    if let Some(url) = &read.host_url {
        map.insert("host_url".to_owned(), url.as_str().into());
    }
    if let Some(parent) = &read.parent_execution_id {
        map.insert("parent_execution_id".to_owned(), parent.as_str().into());
    }
    if let Some(step) = &read.step {
        map.insert(
            "step".to_owned(),
            serde_json::json!({ "id": step.id, "generation": step.generation }),
        );
    }
    if let Some(digest) = &read.component.activation_digest {
        map["component"]
            .as_object_mut()
            .expect("component")
            .insert("activation_digest".to_owned(), digest.as_str().into());
    }
    object
}

#[test]
fn auth_every_assignment_read_reads_as_its_payload_or_is_refused_with_its_reason() {
    let v = fixture("worker_auth.json");
    let signed = &v["assignment"];
    let read = assignment::read(s(&signed["token"])).expect("the signed assignment");
    assert_eq!(
        assignment_json(&read),
        serde_json::from_str::<Value>(s(&signed["payload"])).expect("JSON")
    );
    assert_eq!(read.host_url.as_deref(), Some(s(&v["host_url"])));
    assert_eq!(read.member, s(&v["member"]));

    let reads = &v["assignment_reads"];
    for case in cases(&reads["valid"], "valid") {
        let why = s(&case["why"]);
        let read = assignment::read(s(&case["token"])).unwrap_or_else(|r| panic!("{why}: {r:?}"));
        assert_eq!(assignment_json(&read), case["payload"], "{why}");
    }
    // Each list is taken at its bound, and refused one past it.
    let at_bound = cases(&reads["valid"], "valid").iter().any(|case| {
        case["payload"]["intercepted"].as_array().map(Vec::len) == Some(assignment::MAX_LIST)
            && case["payload"]["component"]["declared_needs"]
                .as_array()
                .map(Vec::len)
                == Some(assignment::MAX_LIST)
    });
    assert!(at_bound, "no valid assignment holds lists at MAX_LIST");
    let invalid = cases(&reads["invalid"], "invalid");
    assert!(invalid.len() >= 50, "{} invalid assignments", invalid.len());
    for case in invalid {
        let why = s(&case["why"]);
        let reason = match s(&case["reason"]) {
            "malformed" => assignment::Refusal::Malformed,
            "unknown_version" => assignment::Refusal::UnknownVersion,
            other => panic!("no assignment refusal {other}"),
        };
        assert_eq!(
            assignment::read(s(&case["token"])).err(),
            Some(reason),
            "{why}"
        );
    }
}

// ============================================================================
// host_api.json
// ============================================================================

#[test]
fn host_each_callbacks_class_and_timeout_are_the_vectors() {
    let v = fixture("host_api.json");
    assert_eq!(wire::VERSION, n(&v["version"]));
    assert_eq!(host::MAX_BODY_BYTES as u64, n(&v["max_body_bytes"]));
    for op in Op::all() {
        let class = match op.retry() {
            Retry::Idempotent => "idempotent",
            Retry::Outcome => "outcome",
            Retry::Batch => "batch",
            Retry::Keyed => "keyed",
            Retry::Never => "never",
        };
        assert_eq!(class, s(&v["retries"][op.name()]), "{}", op.name());
        assert_eq!(
            op.timeout(),
            Duration::from_millis(n(&v["timeouts_ms"][op.name()])),
            "{}",
            op.name()
        );
    }
    // The callbacks a runner does not make are the service's alone.
    let theirs: Vec<&String> = v["retries"]
        .as_object()
        .expect("retries")
        .keys()
        .filter(|name| Op::named(name).is_none())
        .collect();
    assert_eq!(theirs, ["attached_fetch", "runner_exited"]);
}

fn host_fields(fields: &Value) -> CallFields {
    CallFields {
        attempt: attempt(fields),
        boot: s(&fields["boot"]).to_owned(),
        runner: s(&fields["runner"]).to_owned(),
        member: s(&fields["member"]).to_owned(),
        ts: n(&fields["ts"]),
        nonce: s(&fields["nonce"]).to_owned(),
    }
}

/// A reading as the vectors write one.
fn reading_json(reading: &Reading) -> Value {
    match reading {
        Reading::Ok(value) => serde_json::json!({ "ok": value.value() }),
        Reading::Refused(name) => serde_json::json!({ "refused": name }),
        Reading::GuestError {
            kind,
            message,
            remediation,
        } => {
            let mut error =
                serde_json::json!({ "type": kind.as_str(), "message": message.as_str() });
            if let Some(remediation) = remediation {
                error["remediation"] = remediation.value().clone();
            }
            serde_json::json!({ "guest_error": error })
        }
        Reading::SetupRequired(payload) => serde_json::json!({ "setup_required": payload.value() }),
        Reading::Failed(message) => serde_json::json!({ "failed": message.as_str() }),
    }
}

/// An answer's wire form, as the reading of it says it: what a whole
/// refusal carries, and nothing else.
fn answer_of(reading: &Value) -> Value {
    let (kind, value) = reading
        .as_object()
        .and_then(|o| o.iter().next())
        .expect("a reading");
    let mut answer = serde_json::json!({ "v": wire::VERSION });
    match kind.as_str() {
        "ok" => answer["ok"] = value.clone(),
        "refused" => answer["error"] = value.clone(),
        "guest_error" => {
            answer["error"] = "guest_error".into();
            for (member, field) in value.as_object().expect("an error") {
                answer[member.as_str()] = field.clone();
            }
        }
        "setup_required" => {
            answer["error"] = "setup_required".into();
            answer["payload"] = value.clone();
        }
        "failed" => {
            answer["error"] = "failed".into();
            answer["message"] = value.clone();
        }
        other => panic!("no reading {other}"),
    }
    answer
}

#[test]
fn host_every_call_a_runner_makes_crosses_as_the_vectors_write_it() {
    let v = fixture("host_api.json");
    let call_key = key(&v["keys"]["attempt_call_hex"]);
    let seal_key = key(&v["keys"]["attempt_seal_hex"]);
    let mut made = Vec::new();
    for case in cases(&v["calls"], "calls") {
        let callback = s(&case["callback"]);
        let Some(op) = Op::named(callback) else {
            // Only the service makes attached_fetch: its answer is frames.
            assert_eq!(callback, "attached_fetch");
            continue;
        };
        made.push(callback);
        let fields = host_fields(&case["fields"]);
        let body = s(&case["body"]);
        let parsed: Value = serde_json::from_str(body).expect("JSON");
        let written = wire::request_body(op.name(), parsed["args"].as_object().expect("args"));
        assert_eq!(written.as_str(), body, "{callback}");

        let sealed = auth::seal_call(
            &seal_key,
            Direction::Body,
            &fields,
            body.as_bytes(),
            &iv(&case["body_iv_hex"]),
        );
        assert_eq!(
            sealed.expect("sealed"),
            s(&case["body_sealed"]),
            "{callback}"
        );
        let header = auth::host_call_header(&call_key, &fields, s(&case["body_sealed"]).as_bytes());
        assert_eq!(header.expect("signed"), s(&case["header"]), "{callback}");

        let opened = auth::open_call(
            &seal_key,
            Direction::Answer,
            &fields,
            s(&case["answer_sealed"]).as_bytes(),
        );
        let opened = opened.expect("opened");
        assert_eq!(&opened[..], s(&case["answer"]).as_bytes(), "{callback}");
        let answer: Value = serde_json::from_str(s(&case["answer"])).expect("JSON");
        let reading =
            host::answered(op, &opened).unwrap_or_else(|why| panic!("{callback}: {why:?}"));
        assert_eq!(
            reading_json(&reading),
            serde_json::json!({ "ok": answer["ok"] }),
            "{callback}"
        );

        // Each refusal reads as exactly what it carries; another version's
        // is no answer at all.
        for refusal in cases(&case["refusals"], "refusals") {
            let text = s(&refusal["answer"]);
            let refused: Value = serde_json::from_str(text).expect("JSON");
            match host::answered(op, text.as_bytes()) {
                Ok(reading) => assert_eq!(
                    answer_of(&reading_json(&reading)),
                    refused,
                    "{callback}: {text}"
                ),
                Err(host::Unanswered::OtherVersion) => {
                    assert_eq!(refused["error"], "unknown_version")
                }
                Err(host::Unanswered::Lost) => panic!("{callback}: {text} read as no answer"),
            }
        }
    }
    let all: Vec<&str> = Op::all().map(Op::name).collect();
    assert_eq!(made, all, "every callback a runner makes has its call");
}

/// A host reached through a scripted relay: each try meets the next answer
/// of the case, its answer sealed to the try's own header.
struct Scripted {
    answers: Vec<Value>,
    seal: Zeroizing<[u8; 32]>,
    iv: [u8; 12],
    posted: Vec<(String, Vec<u8>)>,
}

impl Scripted {
    fn new(v: &Value, caller: &Caller, answers: Vec<Value>) -> Self {
        let iv = iv(&v["calls"][0]["answer_iv_hex"]);
        Scripted {
            answers,
            seal: caller.keys.seal.clone(),
            iv,
            posted: Vec::new(),
        }
    }
}

/// The call fields a header names.
fn header_fields(header: &str) -> CallFields {
    let pairs: BTreeMap<&str, &str> = header
        .split(' ')
        .skip(1)
        .map(|token| token.split_once('=').expect("name=value"))
        .collect();
    CallFields {
        attempt: Attempt {
            athanor_id: pairs["athanor_id"].to_owned(),
            execution_id: pairs["execution_id"].to_owned(),
            attempt: pairs["attempt"].to_owned(),
            fence: pairs["fence"].parse().expect("fence"),
            generation: pairs["generation"].parse().expect("generation"),
            service: pairs["service"].to_owned(),
        },
        boot: pairs["boot"].to_owned(),
        runner: pairs["runner"].to_owned(),
        member: pairs["member"].to_owned(),
        ts: pairs["ts"].parse().expect("ts"),
        nonce: pairs["nonce"].to_owned(),
    }
}

impl Post for Scripted {
    async fn post(&mut self, _op: Op, header: String, body: Vec<u8>) -> Option<Reached> {
        // A try past the case's answers meets none: the case's count of
        // posts then names the extra one.
        let answer = self.answers.get(self.posted.len()).cloned();
        let fields = header_fields(&header);
        self.posted.push((header, body));
        let answer = answer?;
        let status = status(&answer["status"])?;
        let body = match (answer.get("answer"), answer.get("plain")) {
            (Some(json), _) => auth::seal_call(
                &self.seal,
                Direction::Answer,
                &fields,
                s(json).as_bytes(),
                &self.iv,
            )
            .expect("sealed")
            .into_bytes(),
            (None, Some(plain)) => s(plain).as_bytes().to_vec(),
            (None, None) => panic!("an answer with neither a sealed answer nor a plain body"),
        };
        Some(Reached { status, body })
    }
}

fn caller(v: &Value) -> Caller {
    let fields = &v["calls"][0]["fields"];
    Caller {
        keys: AttemptKeys {
            attempt: attempt(fields),
            call: key(&v["keys"]["attempt_call_hex"]),
            seal: key(&v["keys"]["attempt_seal_hex"]),
        },
        boot: s(&fields["boot"]).to_owned(),
        runner: s(&fields["runner"]).to_owned(),
        member: s(&fields["member"]).to_owned(),
    }
}

// The cases nest an answer 2,000 arrays deep: read whole, as Prima reads
// it, on a stack deep enough for it (the crate's `wire` description says
// what a shallower one meets).
#[test]
fn host_every_answer_outcome_is_the_calls() {
    let outcomes = std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(|| {
            tokio::runtime::Builder::new_current_thread()
                .enable_time()
                .build()
                .expect("a runtime")
                .block_on(every_answer_outcome())
        })
        .expect("a thread");
    if let Err(panic) = outcomes.join() {
        std::panic::resume_unwind(panic);
    }
}

async fn every_answer_outcome() {
    let v = fixture("host_api.json");
    let caller = caller(&v);
    let outcomes = cases(&v["answer_outcomes"], "answer_outcomes");
    assert!(outcomes.len() >= 45, "{} answer outcomes", outcomes.len());
    for case in outcomes {
        let why = s(&case["why"]);
        let op = Op::named(s(&case["callback"])).expect("a runner's callback");
        let mut post = Scripted::new(&v, &caller, cases(&case["answers"], "answers").clone());
        let outcome = host::call(&mut post, &caller, op, &Map::new()).await;
        // The outcome, and an answer's reading, as the vectors write them.
        let (name, reading) = match &outcome {
            Outcome::Answered(reading) => ("answer", reading_json(reading)),
            Outcome::Lost => ("lost", Value::Null),
            Outcome::Uncertain => ("uncertain", Value::Null),
            Outcome::TooLarge => ("too_large", Value::Null),
        };
        // A value nested past what this file's reader takes is its JSON
        // text, read as the crate reads it.
        let expected = match case.get("reading") {
            Some(reading) if reading.get("ok_json").is_some() => {
                let mut reader = serde_json::Deserializer::from_str(s(&reading["ok_json"]));
                reader.disable_recursion_limit();
                let ok: Value = serde::Deserialize::deserialize(&mut reader).expect("JSON");
                serde_json::json!({ "ok": ok })
            }
            reading => reading.cloned().unwrap_or(Value::Null),
        };
        assert_eq!((name, reading), (s(&case["outcome"]), expected), "{why}");
        assert_eq!(post.posted.len() as u64, n(&case["posted"]), "{why}");

        // A try asked again is the same body under a fresh header.
        if let [(first_header, first), (second_header, second)] = post.posted.as_slice() {
            assert_ne!(first_header, second_header, "{why}");
            let open = |header: &str, body: &[u8]| {
                auth::open_call(
                    &caller.keys.seal,
                    Direction::Body,
                    &header_fields(header),
                    body,
                )
                .expect("opens")
                .to_vec()
            };
            assert_eq!(
                open(first_header, first),
                open(second_header, second),
                "{why}"
            );
        }
    }
}

/// A relay whose answers never come.
struct Silent(usize);

impl Post for Silent {
    async fn post(&mut self, _op: Op, _header: String, _body: Vec<u8>) -> Option<Reached> {
        self.0 += 1;
        std::future::pending().await
    }
}

#[tokio::test(start_paused = true)]
async fn host_an_answer_later_than_the_callbacks_timeout_is_lost() {
    let v = fixture("host_api.json");
    let caller = caller(&v);
    for (name, outcome, tries) in [
        ("renew", Outcome::Lost, 2),
        ("take_rate", Outcome::Uncertain, 1),
    ] {
        let op = Op::named(name).expect("a callback");
        let timeout = Duration::from_millis(n(&v["timeouts_ms"][name]));
        let mut post = Silent(0);
        let started = tokio::time::Instant::now();
        assert_eq!(
            host::call(&mut post, &caller, op, &Map::new()).await,
            outcome,
            "{name}"
        );
        assert_eq!(
            (post.0, started.elapsed()),
            (tries, timeout * tries as u32),
            "{name}"
        );
    }
}

#[tokio::test]
async fn host_a_body_past_the_hosts_bound_is_too_large_and_never_posted() {
    let v = fixture("host_api.json");
    let caller = caller(&v);
    let bound = n(&v["max_body_bytes"]) as usize;
    let mut args = Map::new();
    args.insert("deltas".to_owned(), "x".repeat(bound).into());
    let mut post = Scripted::new(&v, &caller, Vec::new());
    let op = Op::named("push_deltas").expect("a callback");
    assert_eq!(
        host::call(&mut post, &caller, op, &args).await,
        Outcome::TooLarge
    );
    assert!(post.posted.is_empty());
}

// ============================================================================
// What a runner holds (the plan's §5.7)
// ============================================================================

/// A marker for a secret, which no public `Debug` or error may print.
const MARKER: &str = "MARKERq7v2";

fn no_marker(why: &str, printed: String) {
    assert!(
        !printed.contains(MARKER),
        "{why} prints the secret: {printed}"
    );
}

#[test]
fn holding_no_debug_or_error_form_prints_a_token_an_input_a_key_or_a_disclosed_field() {
    let control_v = fixture("runner_control.json");
    let assign = &cases(&control_v["valid"], "valid")[0];
    let line = s(&assign["line"]);
    let key_hex = s(&assign["message"]["keys"]["call"]);
    let marked = line
        .replacen(
            "\"assignment\":\"",
            &format!("\"assignment\":\"{MARKER}"),
            1,
        )
        .replacen(
            "\"input\":\"eyJxdWVyeSI6InNlbGVjdCAxIn0=\"",
            &format!("\"input\":\"{}\"", wire::encode_base64(MARKER.as_bytes())),
            1,
        );
    assert!(
        marked.contains(&wire::encode_base64(MARKER.as_bytes())),
        "the input carries the marker"
    );
    // An assign, decoded: its token, its input and its keys.
    let message = control::decode(marked.as_bytes()).expect("the marked assign");
    no_marker("an assign", format!("{message:?}"));
    assert!(
        !format!("{message:?}").contains(key_hex),
        "an assign prints its key"
    );
    // An assign refused: the reason names a member, never a value.
    let refused = control::decode(marked.replacen("\"keys\":", "\"keyz\":", 1).as_bytes());
    no_marker("a refused assign", format!("{refused:?}"));

    // A disclosed field in each reading of an answer.
    let op = Op::named("oauth_token").expect("a callback");
    for answer in [
        format!(r#"{{"v":3,"ok":{{"access_token":"{MARKER}"}}}}"#),
        format!(
            r#"{{"v":3,"error":"guest_error","type":"{MARKER}","message":"{MARKER}","remediation":{{"m":"{MARKER}"}}}}"#
        ),
        format!(r#"{{"v":3,"error":"setup_required","payload":{{"m":"{MARKER}"}}}}"#),
        format!(r#"{{"v":3,"error":"failed","message":"{MARKER}"}}"#),
    ] {
        let reading = host::answered(op, answer.as_bytes()).expect("an answer");
        no_marker(&answer, format!("{:?}", Outcome::Answered(reading)));
    }
    no_marker(
        "a parsed value",
        format!("{:?}", wire::parse(format!("\"{MARKER}\"").as_bytes())),
    );
    // An answer read before its refusal is checked: its name and fields.
    for answer in [
        format!(r#"{{"v":3,"error":"{MARKER}"}}"#),
        format!(r#"{{"v":3,"error":"lost","detail":"{MARKER}"}}"#),
        format!(r#"{{"v":3,"ok":"{MARKER}"}}"#),
    ] {
        let read = wire::parse(answer.as_bytes()).and_then(wire::read_answer);
        assert!(read.is_some(), "{answer} reads as an answer");
        no_marker(&answer, format!("{read:?}"));
    }

    // An assignment read: its authority and actor.
    let auth_v = fixture("worker_auth.json");
    let mut payload: Value =
        serde_json::from_str(s(&auth_v["assignment"]["payload"])).expect("JSON");
    payload["authority"]["marker"] = MARKER.into();
    payload["actor"]["request_id"] = MARKER.into();
    let mac = wire::encode_base64url(&unhex(&auth_v["keys"]["assign_hex"]));
    let token = format!(
        "{}.{mac}",
        wire::encode_base64url(payload.to_string().as_bytes())
    );
    let read = assignment::read(&token).expect("the marked assignment");
    assert_eq!(
        read.authority.value()["marker"],
        MARKER,
        "the read holds the field it hides"
    );
    no_marker("an assignment", format!("{read:?}"));
}

#[test]
fn wire_a_member_named_as_the_parser_names_a_number_is_refused_and_an_integer_is_kept() {
    let private = "$serde_json::private::Number";
    for document in [
        format!(r#"{{"{private}":"5"}}"#),
        format!(r#"{{"v":3,"ok":{{"{private}":"18446744073709551617"}}}}"#),
        format!(r#"[{{"a":1,"{private}":"5"}}]"#),
        // Escaped, the name is the same name.
        r#"{"\u0024serde_json::private::Number":"5"}"#.to_owned(),
    ] {
        assert!(
            wire::parse(document.as_bytes()).is_none(),
            "{document} is read"
        );
    }
    let whole =
        wire::parse(br#"{"n":18446744073709551617,"m":-18446744073709551617}"#).expect("JSON");
    assert_eq!(whole.value()["n"].to_string(), "18446744073709551617");
    assert_eq!(whole.value()["m"].to_string(), "-18446744073709551617");
}

#[test]
fn wire_a_host_answers_numbers_keep_their_digits_and_only_an_exponent_is_respelled() {
    // The crate hands a number on as its text, its digits kept exactly: it
    // does not re-read a decimal as a double, and it takes an integer of
    // any length. Jason, the Elixir runner's reader, rounds
    // 1.00000000000000001 to 1.0, reads 1e-400 as 0.0 and refuses an
    // integer past 1,024 digits; it goes with that runner (R5). Only an
    // exponent is respelled, and the value read back is the value written.
    let long = "9".repeat(1_025);
    let op = Op::named("tool_call").expect("a callback");
    for (written, handed_on) in [
        ("1.00000000000000001", "1.00000000000000001"),
        ("1e-400", "1e-400"),
        (long.as_str(), long.as_str()),
        ("-12345678901234567890123", "-12345678901234567890123"),
        ("1.50", "1.50"),
        ("-0.0", "-0.0"),
        // CYFR's host encoder writes this one (Opus.Host).
        ("1.0e20", "1.0e+20"),
        ("1.0E20", "1.0e+20"),
        ("1E+20", "1e+20"),
        ("2.5E-3", "2.5e-3"),
        ("1.0e020", "1.0e+020"),
        ("0e0", "0e+0"),
    ] {
        let answer = format!(r#"{{"v":3,"ok":{written}}}"#);
        let reading = host::answered(op, answer.as_bytes()).expect("an answer");
        let out = reading_json(&reading)["ok"].to_string();
        assert_eq!(out, handed_on, "{written}");
        assert_eq!(exact(&out), exact(written), "{written}: the value changed");
    }
}

/// A JSON number's exact value: its sign, its digits without leading or
/// trailing zeros, and the power of ten they are scaled by; zero is one.
fn exact(number: &str) -> (bool, String, i64) {
    let (negative, unsigned) = match number.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, number),
    };
    let (mantissa, exponent) = match unsigned.split_once(['e', 'E']) {
        Some((mantissa, exponent)) => (
            mantissa,
            exponent
                .trim_start_matches('+')
                .parse::<i64>()
                .expect("an exponent"),
        ),
        None => (unsigned, 0),
    };
    let (whole, fraction) = mantissa.split_once('.').unwrap_or((mantissa, ""));
    let digits = format!("{whole}{fraction}");
    let significant = digits.trim_start_matches('0');
    if significant.is_empty() {
        return (false, "0".to_owned(), 0);
    }
    let trimmed = significant.trim_end_matches('0');
    let scale = exponent - fraction.len() as i64 + (significant.len() - trimmed.len()) as i64;
    (negative, trimmed.to_owned(), scale)
}
