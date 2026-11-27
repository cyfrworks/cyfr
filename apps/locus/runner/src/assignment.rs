// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The assignment a runner is handed (`Prima.Assignment`), read without
//! the assign key, which only CYFR holds: what it answers authorizes
//! nothing, since CYFR verifies the token when the runner attaches.
//!
//! A token is `base64url(payload) "." base64url(mac)`, both unpadded, the
//! MAC 32 bytes, and re-encodes to itself. Its payload is one JSON object
//! carrying `v` (1), each member of its type and nothing else; an absent
//! optional member is none, never null. `read` refuses `unknown_version`
//! for another integer `v` and `malformed` for anything else it refuses.
//!
//! What this read leaves to CYFR, which refuses each at attach: `actor`
//! and `authority` are held as JSON objects and read no further here (an
//! attempt reads what it needs of the authority, `crate::authority`), and a component's
//! `type` and the canonical form of its `ref` are not checked against the
//! component reference grammar. `tests/fixtures/worker_auth.json`'s
//! `assignment_reads` holds the tokens both sides read alike.
//!
//! Every integer member is at most 2^53 − 1, the greatest integer the
//! control and relay wires hold theirs to; one past it is refused. The
//! payload, its `actor` and its `authority` are cleared when they are
//! dropped, and an assignment's `Debug` names its attempt alone.

use serde_json::{Map, Value};
use zeroize::Zeroizing;

use crate::wire::{
    Integer, Json, MAX_INTEGER, bounded, decode_base64url, encode_base64url_into, integer,
    is_base_url, is_digest, is_id, parse,
};

/// The version an assignment carries as `v`.
pub const VERSION: u64 = 1;

/// The most `intercepted` names and declared needs an assignment carries.
pub const MAX_LIST: usize = 256;

/// The members an assignment carries.
const MEMBERS: [&str; 23] = [
    "v",
    "generation",
    "service",
    "boot",
    "member",
    "host_url",
    "issued_at",
    "claim_by",
    "execution_id",
    "attempt",
    "fence",
    "parent_execution_id",
    "root_execution_id",
    "step",
    "athanor_id",
    "actor",
    "authority",
    "component",
    "input_digest",
    "timeout_ms",
    "deadline",
    "lease_until",
    "intercepted",
];

const COMPONENT_MEMBERS: [&str; 5] = [
    "ref",
    "type",
    "digest",
    "declared_needs",
    "activation_digest",
];

/// The step of a turn that dispatched an assignment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub id: String,
    pub generation: u64,
}

/// The component an assignment runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Component {
    pub reference: String,
    pub kind: String,
    pub digest: String,
    pub declared_needs: Vec<String>,
    pub activation_digest: Option<String>,
}

/// An assignment, as its token carries it. Times are Unix milliseconds.
#[derive(PartialEq)]
pub struct Assignment {
    pub generation: u64,
    pub service: String,
    pub boot: String,
    pub member: String,
    pub host_url: Option<String>,
    pub issued_at: u64,
    pub claim_by: u64,
    pub execution_id: String,
    pub attempt: String,
    pub fence: u64,
    pub parent_execution_id: Option<String>,
    pub root_execution_id: String,
    pub step: Option<Step>,
    pub athanor_id: String,
    pub actor: Json,
    pub authority: Json,
    pub component: Component,
    pub input_digest: String,
    pub timeout_ms: u64,
    pub deadline: u64,
    pub lease_until: u64,
    pub intercepted: Vec<String>,
}

impl std::fmt::Debug for Assignment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Assignment")
            .field("execution_id", &self.execution_id)
            .field("attempt", &self.attempt)
            .finish_non_exhaustive()
    }
}

/// Why a token is no assignment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    Malformed,
    UnknownVersion,
}

/// The assignment `token` carries, its MAC unchecked.
pub fn read(token: &str) -> Result<Assignment, Refusal> {
    let payload = split(token).ok_or(Refusal::Malformed)?;
    let mut json = parse(&payload).ok_or(Refusal::Malformed)?;
    let Value::Object(wire) = json.value() else {
        return Err(Refusal::Malformed);
    };
    match wire.get("v").and_then(integer) {
        Some(Integer::Whole(VERSION)) => {}
        Some(_) => return Err(Refusal::UnknownVersion),
        None => return Err(Refusal::Malformed),
    }
    let mut assignment = decode(wire).ok_or(Refusal::Malformed)?;
    assignment.actor = json.take_member("actor").ok_or(Refusal::Malformed)?;
    assignment.authority = json.take_member("authority").ok_or(Refusal::Malformed)?;
    Ok(assignment)
}

/// The payload of a token of two unpadded base64url parts, the second a
/// 32-byte MAC, that spells its parts one way only.
fn split(token: &str) -> Option<Zeroizing<Vec<u8>>> {
    let (payload64, mac64) = token.split_once('.')?;
    let payload = Zeroizing::new(decode_base64url(payload64)?);
    let mac = Zeroizing::new(decode_base64url(mac64)?);
    let mut canonical = Zeroizing::new(String::with_capacity(token.len()));
    encode_base64url_into(&payload, &mut canonical);
    canonical.push('.');
    encode_base64url_into(&mac, &mut canonical);
    (mac.len() == 32 && canonical.as_str() == token).then_some(payload)
}

fn decode(wire: &Map<String, Value>) -> Option<Assignment> {
    if wire.keys().any(|key| !MEMBERS.contains(&key.as_str())) {
        return None;
    }
    let get = |name: &str| wire.get(name);
    Some(Assignment {
        generation: positive(get("generation")?)?,
        service: id(get("service")?)?,
        boot: id(get("boot")?)?,
        member: id(get("member")?)?,
        host_url: optional(get("host_url"), |value| {
            value
                .as_str()
                .filter(|text| is_base_url(text))
                .map(str::to_owned)
        })?,
        issued_at: time(get("issued_at")?)?,
        claim_by: time(get("claim_by")?)?,
        execution_id: id(get("execution_id")?)?,
        attempt: id(get("attempt")?)?,
        fence: positive(get("fence")?)?,
        parent_execution_id: optional(get("parent_execution_id"), id)?,
        root_execution_id: id(get("root_execution_id")?)?,
        step: optional(get("step"), step)?,
        athanor_id: id(get("athanor_id")?)?,
        // Each an object, taken out of the payload once it reads.
        actor: get("actor")?.as_object().map(|_| Json::default())?,
        authority: get("authority")?.as_object().map(|_| Json::default())?,
        component: component(get("component")?)?,
        input_digest: digest(get("input_digest")?)?,
        timeout_ms: positive(get("timeout_ms")?)?,
        deadline: time(get("deadline")?)?,
        lease_until: time(get("lease_until")?)?,
        intercepted: list(get("intercepted")?, is_tool_action)?,
    })
}

// An optional member: absent is none, present is read (null included,
// which no reader takes).
fn optional<T>(value: Option<&Value>, read: impl Fn(&Value) -> Option<T>) -> Option<Option<T>> {
    match value {
        None => Some(None),
        Some(value) => read(value).map(Some),
    }
}

fn id(value: &Value) -> Option<String> {
    value.as_str().filter(|text| is_id(text)).map(str::to_owned)
}

fn digest(value: &Value) -> Option<String> {
    value
        .as_str()
        .filter(|text| is_digest(text))
        .map(str::to_owned)
}

fn time(value: &Value) -> Option<u64> {
    bounded(value, 0..=MAX_INTEGER).ok()
}

fn positive(value: &Value) -> Option<u64> {
    time(value).filter(|n| *n > 0)
}

fn list(value: &Value, valid: impl Fn(&str) -> bool) -> Option<Vec<String>> {
    let values = value.as_array()?;
    if values.len() > MAX_LIST {
        return None;
    }
    values
        .iter()
        .map(|value| value.as_str().filter(|text| valid(text)).map(str::to_owned))
        .collect()
}

fn step(value: &Value) -> Option<Step> {
    let step = value.as_object()?;
    if step.len() != 2 {
        return None;
    }
    Some(Step {
        id: id(step.get("id")?)?,
        generation: time(step.get("generation")?)?,
    })
}

fn component(value: &Value) -> Option<Component> {
    let component = value.as_object()?;
    if component
        .keys()
        .any(|key| !COMPONENT_MEMBERS.contains(&key.as_str()))
    {
        return None;
    }
    Some(Component {
        reference: id(component.get("ref")?)?,
        kind: component.get("type")?.as_str()?.to_owned(),
        digest: digest(component.get("digest")?)?,
        declared_needs: list(component.get("declared_needs")?, is_need)?,
        activation_digest: optional(component.get("activation_digest"), digest)?,
    })
}

/// A `tool.action` name: 3 to 256 bytes, two runs of lowercase letters,
/// digits, `_` or `-` joined by one dot.
fn is_tool_action(text: &str) -> bool {
    let part = |part: &str| {
        !part.is_empty()
            && part
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
    };
    (3..=256).contains(&text.len())
        && text
            .split_once('.')
            .is_some_and(|(tool, action)| part(tool) && part(action))
}

/// A manifest need's name: a lowercase letter, then up to 31 lowercase
/// letters, digits, `_` or `-`.
fn is_need(text: &str) -> bool {
    let bytes = text.as_bytes();
    (1..=32).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_' || *b == b'-')
}
