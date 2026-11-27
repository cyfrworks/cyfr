// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! What a component sees (section 5.3 of the plan): the bindings
//! `bindgen!` generates from `wit/`, the store's data a run's imports
//! answer from, and each import. A catalyst gets every import of its world
//! and a reagent none of CYFR's; both get WASI p2 with no standard input
//! or output, arguments, environment, preopened directory, socket or name
//! lookup (`engine`).
//!
//! Each import is the attempt's host calls, as `crate::attempt::Host` makes
//! them. An import answers its guest in the world's shape, a refusal
//! included; one that cannot (CYFR's answer to one of its calls nested
//! past `crate::wire::MAX_DEPTH`) ends the run with an `Ended`, which the
//! attempt closes with its sentence.
//!
//! One limit on what is wiped: a vault value or an OAuth token crosses to
//! the guest as the plain `String` the generated binding takes, which
//! Wasmtime lowers into the guest's memory and then frees unwiped, beside
//! the guest's own copy. The runner's own copies are cleared as they are
//! dropped (`Run::fields`, `crate::wire::Json`).

pub mod emit;
pub mod oauth;
pub mod question;
pub mod storage;
pub mod vault;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use serde_json::Value;
use wasmtime::component::ResourceTable;
use wasmtime::{StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};
use zeroize::Zeroizing;

use crate::attempt::Host;
use crate::authority::Limits;
use crate::host::Outcome;

/// The catalyst world's bindings, every import async and able to end the
/// run.
pub mod catalyst {
    wasmtime::component::bindgen!({
        path: "../../../wit/catalyst",
        world: "catalyst",
        imports: { default: async | trappable },
        exports: { default: async },
    });
}

/// The reagent world's bindings: an export and no import of CYFR's.
pub mod reagent {
    wasmtime::component::bindgen!({
        path: "../../../wit/reagent",
        world: "reagent",
        exports: { default: async },
    });
}

/// The most tables, elements a table, and instances a run's store holds
/// beside its one linear memory. Every shipped component instantiates
/// three core modules with two funcref tables, the larger of 159
/// elements; these leave room for other toolchains while every table a
/// run can make holds at most 200,000 elements in all.
pub const MAX_TABLES: usize = 10;
pub const MAX_TABLE_ELEMENTS: usize = 20_000;
pub const MAX_INSTANCES: usize = 10;

/// A run's end that its imports decided: the attempt closes failed with
/// this sentence.
#[derive(Debug)]
pub struct Ended(pub String);

impl std::fmt::Display for Ended {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Ended {}

/// What a run's imports answer from: the attempt's host and what it was
/// handed when it attached.
pub struct Run {
    pub host: Arc<Host>,
    /// The component's reference, which its events and sentences name.
    pub component_ref: String,
    /// The limits of the node the run stands on.
    pub limits: Limits,
    /// The vault fields attach answered, cleared when the run is dropped.
    pub fields: BTreeMap<String, Zeroizing<String>>,
    /// The fields the edge projects that CYFR attaches and never hands over.
    pub attached: BTreeSet<String>,
}

/// A run's store data.
pub struct Guest {
    wasi: WasiCtx,
    table: ResourceTable,
    limits: StoreLimits,
    pub(crate) run: Arc<Run>,
    /// The number of the run's last ask (`cyfr:question/ask`).
    pub(crate) asks: u64,
}

impl Guest {
    /// The store data of a run under `run`: one linear memory of at most
    /// the node's `max_memory_bytes`, and the bounds above.
    pub fn new(run: Arc<Run>) -> Guest {
        let memory = usize::try_from(run.limits.max_memory_bytes).unwrap_or(usize::MAX);
        let limits = StoreLimitsBuilder::new()
            .memory_size(memory)
            .memories(1)
            .tables(MAX_TABLES)
            .table_elements(MAX_TABLE_ELEMENTS)
            .instances(MAX_INSTANCES)
            .build();
        // No standard input or output, arguments, environment or
        // preopened directory is given; sockets and name lookup are off.
        let wasi = WasiCtxBuilder::new()
            .allow_tcp(false)
            .allow_udp(false)
            .allow_ip_name_lookup(false)
            .build();
        Guest {
            wasi,
            table: ResourceTable::new(),
            limits,
            run,
            asks: 0,
        }
    }

    /// The store's limiter.
    pub fn limiter(&mut self) -> &mut StoreLimits {
        &mut self.limits
    }
}

impl WasiView for Guest {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.wasi,
            table: &mut self.table,
        }
    }
}

/// The error envelope an import answers its guest with
/// (`tests/fixtures/guest_error.json`).
pub fn error_json(kind: &str, message: &str) -> String {
    serde_json::json!({"error": {"type": kind, "message": message}}).to_string()
}

/// An outcome the run cannot go on from: CYFR's answer nested too deep.
pub fn ended(op: &str, outcome: &Outcome) -> wasmtime::Result<()> {
    if matches!(outcome, Outcome::TooDeep) {
        Err(wasmtime::Error::new(Ended(crate::words::answer_too_deep(
            op,
        ))))
    } else {
        Ok(())
    }
}

/// The JSON object `members` as host call args.
pub fn args(
    members: impl IntoIterator<Item = (&'static str, Value)>,
) -> serde_json::Map<String, Value> {
    members
        .into_iter()
        .map(|(name, value)| (name.to_owned(), value))
        .collect()
}

/// A guest's requests over HTTP: this runner does not make them, and
/// answers each `request_failed`.
const NO_REQUESTS: &str = "HTTP requests are not available in this runner";

impl catalyst::cyfr::http::fetch::Host for Guest {
    async fn request(&mut self, _request: String) -> wasmtime::Result<String> {
        Ok(error_json("request_failed", NO_REQUESTS))
    }
}

impl catalyst::cyfr::http::streaming::Host for Guest {
    async fn request(&mut self, _request: String) -> wasmtime::Result<String> {
        Ok(error_json("request_failed", NO_REQUESTS))
    }

    async fn read(&mut self, _handle: String) -> wasmtime::Result<String> {
        Ok(error_json("request_failed", NO_REQUESTS))
    }

    async fn close(&mut self, _handle: String) -> wasmtime::Result<String> {
        Ok(error_json("request_failed", NO_REQUESTS))
    }
}
