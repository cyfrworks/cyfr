// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! What a runner reads of the authority its assignment carries
//! (`Prima.Authority.from_wire/1`): the limits of the node its cursor
//! stands on (`Prima.Authority.limits/1`), and the fields its edge's vault
//! entries project but CYFR attaches to requests rather than disclose
//! (`Prima.Authority.attached_fields/1`). Nothing here grants anything:
//! CYFR decides every host call under the authority it holds, and verified
//! this one's token when the runner attached.
//!
//! The read refuses what Prima refuses in what it reads: a cursor that is
//! neither `"unbound"` nor `{"bound": ref}`, a bound cursor with no policy
//! or naming no node of it, a node's limits missing a field or holding one
//! of another type, and a vault projection whose fields are not an object.
//! The rest of the authority is CYFR's, and is not read.
//! `tests/fixtures/authority_wire.json` holds what both sides read alike.

use std::collections::BTreeSet;

use serde_json::{Map, Value};

use crate::wire::{Integer, Json, MAX_INTEGER, integer};

/// A node's limits, as `Prima.Limits.to_map/1` writes them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Limits {
    pub timeout: String,
    pub batch_timeout: String,
    pub max_memory_bytes: u64,
    pub max_request_size: u64,
    pub max_response_size: u64,
    pub max_concurrent_tasks: u64,
    pub rate_limit: RateLimit,
}

/// A node's rate limit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RateLimit {
    pub requests: u64,
    pub window: String,
}

impl Limits {
    /// The limits of an unbound authority (`Prima.Authority`'s zero
    /// limits).
    pub fn zero() -> Limits {
        Limits {
            timeout: "30s".to_owned(),
            batch_timeout: "30s".to_owned(),
            max_memory_bytes: 67_108_864,
            max_request_size: 1_048_576,
            max_response_size: 5_242_880,
            max_concurrent_tasks: 1,
            rate_limit: RateLimit {
                requests: 100,
                window: "1m".to_owned(),
            },
        }
    }
}

/// What the runner reads of an authority.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Authority {
    pub limits: Limits,
    pub attached_fields: BTreeSet<String>,
}

/// Why an authority is not read: the member it fails at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refused(pub &'static str);

/// What `authority`, an assignment's, gives the runner.
pub fn read(authority: &Json) -> Result<Authority, Refused> {
    let Value::Object(wire) = authority.value() else {
        return Err(Refused("authority"));
    };
    let limits = match wire.get("cursor") {
        Some(Value::String(cursor)) if cursor == "unbound" => Limits::zero(),
        Some(Value::Object(cursor)) => {
            let node = match (cursor.len(), cursor.get("bound")) {
                (1, Some(Value::String(node))) if !node.is_empty() => node,
                _ => return Err(Refused("cursor")),
            };
            let node = wire
                .get("policy")
                .and_then(|policy| policy.get("nodes"))
                .and_then(|nodes| nodes.get(node))
                .ok_or(Refused("cursor"))?;
            limits(node.get("limits").ok_or(Refused("limits"))?)?
        }
        _ => return Err(Refused("cursor")),
    };
    let attached_fields = match wire.get("resources") {
        None | Some(Value::Null) => BTreeSet::new(),
        Some(Value::Object(edge)) => attached(edge)?,
        Some(_) => return Err(Refused("resources")),
    };
    Ok(Authority {
        limits,
        attached_fields,
    })
}

fn limits(limits: &Value) -> Result<Limits, Refused> {
    let Value::Object(limits) = limits else {
        return Err(Refused("limits"));
    };
    let count = |name: &'static str| match limits.get(name).and_then(integer) {
        Some(Integer::Whole(n)) if n <= MAX_INTEGER => Ok(n),
        _ => Err(Refused(name)),
    };
    let text = |name: &'static str| match limits.get(name) {
        Some(Value::String(text)) => Ok(text.clone()),
        _ => Err(Refused(name)),
    };
    let rate_limit = match limits.get("rate_limit") {
        Some(Value::Object(rate)) => RateLimit {
            requests: match rate.get("requests").and_then(integer) {
                Some(Integer::Whole(n)) if n <= MAX_INTEGER => n,
                _ => return Err(Refused("rate_limit")),
            },
            window: match rate.get("window") {
                Some(Value::String(window)) => window.clone(),
                _ => return Err(Refused("rate_limit")),
            },
        },
        _ => return Err(Refused("rate_limit")),
    };
    Ok(Limits {
        timeout: text("timeout")?,
        batch_timeout: text("batch_timeout")?,
        max_memory_bytes: count("max_memory_bytes")?,
        max_request_size: count("max_request_size")?,
        max_response_size: count("max_response_size")?,
        max_concurrent_tasks: count("max_concurrent_tasks")?,
        rate_limit,
    })
}

// The fields the edge's vault projects from each entry it binds, by the
// names the component reads them under: the default binding's and each
// named account's. A vault given `via` a label or `provided` by its
// publisher binds no entry and projects none.
fn attached(edge: &Map<String, Value>) -> Result<BTreeSet<String>, Refused> {
    let mut fields = BTreeSet::new();
    let Some(vault) = edge.get("vault") else {
        return Ok(fields);
    };
    let Value::Object(vault) = vault else {
        return Err(Refused("vault"));
    };
    if !vault.contains_key("entry_id") {
        return Ok(fields);
    }
    projected(vault, &mut fields)?;
    match vault.get("named") {
        None => {}
        Some(Value::Object(named)) => {
            for account in named.values() {
                match account {
                    Value::Object(account) if account.contains_key("entry_id") => {
                        projected(account, &mut fields)?;
                    }
                    Value::Object(_other_form) => {}
                    _ => return Err(Refused("named")),
                }
            }
        }
        Some(_) => return Err(Refused("named")),
    }
    Ok(fields)
}

fn projected(vault: &Map<String, Value>, fields: &mut BTreeSet<String>) -> Result<(), Refused> {
    match vault
        .get("projection")
        .and_then(|projection| projection.get("fields"))
    {
        Some(Value::Object(projected)) => {
            fields.extend(projected.keys().cloned());
            Ok(())
        }
        _ => Err(Refused("projection")),
    }
}
