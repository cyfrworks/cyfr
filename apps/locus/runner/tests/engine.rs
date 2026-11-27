// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The engine and what it reads, held to the vector files Prima's tests
//! read: the refused features and their sentences
//! (`component_features.json`), the authority an assignment carries
//! (`authority_wire.json`), and the validator's version beside the one
//! Prima's admission runs (`scripts/wasm-tools.sh`).

mod support;

use std::collections::BTreeSet;

use serde_json::Value;

use cyfr_runner::authority;
use cyfr_runner::engine::{self, Unadmitted};
use cyfr_runner::wire;

fn cases<'a>(section: &'a Value, name: &str) -> &'a Vec<Value> {
    let cases = section
        .as_array()
        .unwrap_or_else(|| panic!("the vectors have no section {name}"));
    assert!(!cases.is_empty(), "the vectors' section {name} is empty");
    cases
}

fn text(value: &Value) -> &str {
    value
        .as_str()
        .unwrap_or_else(|| panic!("not text: {value}"))
}

fn case_bytes(case: &Value) -> Vec<u8> {
    match (case.get("path"), case.get("hex")) {
        (Some(path), None) => support::bytes(text(path)),
        (None, Some(hex)) => {
            let hex = text(hex);
            (0..hex.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("hex"))
                .collect()
        }
        _ => panic!("a case names a path or hex bytes: {case}"),
    }
}

#[test]
fn the_refused_features_are_the_vectors() {
    let v = support::fixture("component_features.json");
    let refused: Vec<&str> = engine::REFUSED.iter().map(|(name, _)| *name).collect();
    let expected: Vec<&str> = cases(&v["refused"], "refused").iter().map(text).collect();
    assert_eq!(refused, expected);
    let families: BTreeSet<&str> = v["families"]
        .as_object()
        .expect("families")
        .values()
        .flat_map(|family| family.as_array().expect("a family").iter().map(text))
        .collect();
    assert_eq!(families, refused.iter().copied().collect());
}

#[test]
fn every_component_is_classified_as_prima_classifies_it_in_prima_s_sentence() {
    let v = support::fixture("component_features.json");
    let sentence =
        |name: &str, digest: &str| text(&v["sentences"][name]).replace("{digest}", digest);
    for case in cases(&v["cases"], "cases") {
        let why = text(&case["why"]);
        let bytes = case_bytes(case);
        let digest = engine::digest(&bytes);
        let classified = engine::classify(&bytes);
        match text(&case["outcome"]) {
            "admitted" => assert_eq!(classified, Ok(()), "{why}"),
            "component_feature_refused" => {
                assert_eq!(classified, Err(Unadmitted::FeatureRefused), "{why}");
                assert_eq!(
                    engine::unadmitted(Unadmitted::FeatureRefused, &digest),
                    sentence("component_feature_refused", &digest),
                    "{why}"
                );
            }
            "component_invalid" => {
                assert_eq!(classified, Err(Unadmitted::Invalid), "{why}");
                assert_eq!(
                    engine::unadmitted(Unadmitted::Invalid, &digest),
                    sentence("component_invalid", &digest),
                    "{why}"
                );
            }
            other => panic!("no outcome {other}"),
        }
    }
}

#[test]
fn the_validator_the_crate_runs_is_the_one_prima_admits_with() {
    // wasm-tools 1.N is built on wasmparser 0.N: the crate's wasmparser
    // (Cargo.lock) and the wasm-tools Prima's admission runs
    // (scripts/wasm-tools.sh) answer alike only at the same N.
    let lock = String::from_utf8(support::bytes("apps/locus/runner/Cargo.lock")).expect("text");
    let wasmparser = lock
        .split("[[package]]")
        .find(|package| package.contains("name = \"wasmparser\""))
        .and_then(|package| {
            package
                .lines()
                .find_map(|line| line.strip_prefix("version = "))
        })
        .expect("wasmparser in the lock")
        .trim_matches('"')
        .to_owned();
    let script = String::from_utf8(support::bytes("scripts/wasm-tools.sh")).expect("text");
    let pinned = script
        .lines()
        .find_map(|line| line.strip_prefix("VERSION="))
        .expect("the pinned version");
    let minor = |version: &str| version.split('.').nth(1).expect("a minor").to_owned();
    assert_eq!(wasmparser.split('.').next(), Some("0"));
    assert_eq!(
        minor(&wasmparser),
        minor(pinned),
        "wasmparser {wasmparser}, wasm-tools {pinned}"
    );
}

#[test]
fn every_authority_reads_as_prima_reads_it() {
    let v = support::fixture("authority_wire.json");
    for case in cases(&v["read"], "read") {
        let why = text(&case["why"]);
        let read = authority::read(&wire::Json::from_value(case["authority"].clone()))
            .unwrap_or_else(|refused| panic!("{why}: {refused:?}"));
        let limits = &case["limits"];
        let expected = authority::Limits {
            timeout: text(&limits["timeout"]).to_owned(),
            batch_timeout: text(&limits["batch_timeout"]).to_owned(),
            max_memory_bytes: limits["max_memory_bytes"].as_u64().expect("a count"),
            max_request_size: limits["max_request_size"].as_u64().expect("a count"),
            max_response_size: limits["max_response_size"].as_u64().expect("a count"),
            max_concurrent_tasks: limits["max_concurrent_tasks"].as_u64().expect("a count"),
            rate_limit: authority::RateLimit {
                requests: limits["rate_limit"]["requests"].as_u64().expect("a count"),
                window: text(&limits["rate_limit"]["window"]).to_owned(),
            },
        };
        assert_eq!(read.limits, expected, "{why}");
        let attached: BTreeSet<String> = case["attached_fields"]
            .as_array()
            .expect("a list")
            .iter()
            .map(|name| text(name).to_owned())
            .collect();
        assert_eq!(read.attached_fields, attached, "{why}");
    }
    for case in cases(&v["refused"], "refused") {
        let why = text(&case["why"]);
        let read = authority::read(&wire::Json::from_value(case["authority"].clone()));
        assert!(read.is_err(), "{why}: {read:?}");
    }
}

#[test]
fn the_engine_itself_refuses_every_refused_feature() {
    // Each refused feature's guest, compiled straight into the engine the
    // runner configures, with no classifier before it: the configuration,
    // not the classifier, is what refuses it.
    let v = support::fixture("component_features.json");
    let engine = wasmtime::Engine::new(&engine::config()).expect("the engine");
    let mut refused = Vec::new();
    for case in cases(&v["cases"], "cases") {
        let Some(feature) = case.get("feature") else {
            continue;
        };
        let compiled = wasmtime::component::Component::new(&engine, case_bytes(case));
        assert!(compiled.is_err(), "the engine compiled the {feature} guest");
        refused.push(text(feature).to_owned());
    }
    let nine: Vec<String> = engine::REFUSED
        .iter()
        .map(|(name, _)| (*name).to_owned())
        .collect();
    assert_eq!(refused, nine);
}

#[tokio::test(start_paused = true)]
async fn a_kept_compile_leaves_when_its_time_passes_with_no_lookup() {
    let engine = engine::Engine::new().expect("the engine");
    let bytes = support::bytes("apps/locus/test/support/runtime/test_wasm/echo.wasm");
    let digest = engine::digest(&bytes);
    engine.compile(&digest, bytes).await.expect("a compile");
    assert!(engine.kept(&digest).is_some());
    tokio::time::advance(engine::KEPT_FOR - std::time::Duration::from_secs(1)).await;
    tokio::task::yield_now().await;
    assert!(engine.kept(&digest).is_some(), "kept for its 15 minutes");
    // Nothing looks it up in between: its own timer removes it.
    tokio::time::advance(std::time::Duration::from_secs(2)).await;
    tokio::task::yield_now().await;
    assert!(engine.kept(&digest).is_none(), "gone once they pass");
}
