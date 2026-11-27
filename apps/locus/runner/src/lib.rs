// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The WASM runner's wires: the control channel (`control`), the relay
//! (`relay`), the host calls made over it (`host`, `wire`, `auth`) and the
//! assignment a runner is handed (`assignment`). Each is the runner's
//! reading of a contract Prima defines, held to its vector file under
//! `tests/fixtures` by `tests/vectors.rs`. Nothing here runs a component
//! yet: the engine comes on top of these.

#![forbid(unsafe_code)]

pub mod assignment;
pub mod auth;
pub mod control;
pub mod host;
pub mod relay;
pub mod wire;
