// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The WASM runner: its wires, each the runner's reading of a contract
//! Prima defines and held to its vector file under `tests/fixtures` by
//! `tests/vectors.rs` (the control channel, `control`; the relay, `relay`;
//! the host calls made over it, `host`, `wire` and `auth`; the assignment a
//! runner is handed, `assignment`; the authority it carries, `authority`),
//! and the engine that runs a subtree on them: the loop over a runner's
//! assignments (`subtree`), one attempt from attach to close (`attempt`),
//! the engine and its bounds (`engine`), what a component imports
//! (`imports`) and the runner's own sentences (`words`).

#![forbid(unsafe_code)]

pub mod assignment;
pub mod attempt;
pub mod auth;
pub mod authority;
pub mod control;
pub mod engine;
pub mod host;
pub mod imports;
pub mod relay;
pub mod subtree;
pub mod wire;
pub mod words;
