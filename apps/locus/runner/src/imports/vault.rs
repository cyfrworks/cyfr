// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! `cyfr:vault/read`: a field the run's attach answered, or a refusal.
//!
//! A field of an entry the node's edge binds, which CYFR attaches to its
//! requests and never hands over, is refused as `disclosure_refused`; any
//! other read outside the fields attach answered as outside the
//! projection, `secret_denied`. Either is reported to CYFR as a
//! `record_denial`, which CYFR audits for the attempt; a report is never
//! asked again, and the guest's answer does not wait on its outcome. A
//! name the contract bounds out (`Prima.HostAPI.valid_field_name?/1`) is
//! refused unreported. The name is the guest's, so no log line carries it.

use serde_json::Value;

use super::{Guest, args, catalyst, ended};
use crate::host::Outcome;

/// The longest field name a guest's read may report.
pub const MAX_FIELD_NAME_BYTES: usize = 256;

impl catalyst::cyfr::vault::read::Host for Guest {
    async fn get(&mut self, name: String) -> wasmtime::Result<Result<String, String>> {
        let run = self.run.clone();
        if let Some(value) = run.fields.get(&name) {
            return Ok(Ok(value.as_str().to_owned()));
        }
        let component = &run.component_ref;
        let (reason, sentence) = if run.attached.contains(&name) {
            (
                "disclosure_refused",
                format!(
                    "disclosure_refused: {name} is attached to requests by CYFR and never handed \
                     to {component}"
                ),
            )
        } else {
            (
                "secret_denied",
                format!("access-denied: {name} not granted to {component}"),
            )
        };
        if valid_field_name(&name) {
            eprintln!("cyfr-runner: {component} was refused a vault field ({reason})");
            let outcome = run
                .host
                .call(
                    "record_denial",
                    args([
                        ("message", Value::String(name)),
                        ("type", Value::String(reason.to_owned())),
                    ]),
                )
                .await;
            ended("record_denial", &outcome)?;
            if !matches!(outcome, Outcome::Answered(_)) {
                eprintln!("cyfr-runner: {component}'s denial report was not answered");
            }
        } else {
            eprintln!("cyfr-runner: {component} asked its vault for a name that is no field name");
        }
        Ok(Err(sentence))
    }
}

/// `Prima.HostAPI.valid_field_name?/1`: 1 to 256 bytes of UTF-8 with no
/// control character.
pub fn valid_field_name(name: &str) -> bool {
    (1..=MAX_FIELD_NAME_BYTES).contains(&name.len()) && !name.chars().any(|c| c.is_ascii_control())
}
