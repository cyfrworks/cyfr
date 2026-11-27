// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The runner's program. This build reads its environment and runs
//! nothing: it has no engine yet, so it ends with 69 (unavailable), or 78
//! (a configuration error) when its environment names no runner. Nothing
//! starts it.

#![forbid(unsafe_code)]

use std::process::ExitCode;

use cyfr_runner::control::Environment;

fn main() -> ExitCode {
    match Environment::read(std::env::vars_os()) {
        Ok(environment) => {
            eprintln!(
                "cyfr-runner: runner {} has no engine yet, and runs nothing",
                environment.runner_id
            );
            ExitCode::from(69)
        }
        Err(refusal) => {
            eprintln!("cyfr-runner: {refusal}");
            ExitCode::from(78)
        }
    }
}
