// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The runner's own sentences: what an attempt's close records, and what a
//! guest is answered when the runner refuses it. Each names ids, kinds,
//! counts and the engine's words, never a guest's input, a field's value
//! or a guest's own names (backtraces are off, `engine`). The behaviour
//! checks that read a sentence are listed in `docs/plans/native-locus.md`
//! (section 6); a sentence Prima owns (a feature's refusal) is held to
//! `tests/fixtures/component_features.json` by the engine's test.

use crate::wire::{MAX_DEPTH, MAX_OUTPUT_DEPTH};

/// An attempt that ended before CYFR recorded its close.
pub const ENDED: &str = "Execution attempt ended before it closed";

/// An attempt the runner was told to stop.
pub const CANCELLED: &str = "Execution cancelled before it completed";

/// An attempt whose lease CYFR no longer holds for it.
pub const LEASE_LOST: &str = "Execution lease lost: the row is no longer this attempt's to finish";

/// An assignment whose authority or component type the runner cannot read.
pub const UNRUNNABLE: &str = "Execution error: the assignment could not be run";

/// A component whose bytes CYFR did not answer.
pub const NOT_FETCHED: &str = "Execution error: the component's bytes could not be fetched";

/// A component whose bytes are not the digest's.
pub const NOT_DIGEST: &str = "Execution error: the component's bytes do not match its digest";

/// The uncertain end of a call never asked again.
pub const UNCERTAIN: &str = "The call's answer was lost and its effect is unknown";

/// A run past its budget.
pub fn timeout(budget_ms: u64) -> String {
    format!("Execution timeout after {budget_ms}ms")
}

/// A component the engine did not compile: its words.
pub fn not_compiled(words: &str) -> String {
    format!(
        "Component compilation failed: {words}. Ensure the component is compiled as a WASI P2 \
         Component Model binary."
    )
}

/// A component the engine did not instantiate, the store's refusals among
/// them: its words.
pub fn not_instantiated(words: &str) -> String {
    format!("Component instantiation failed: {words}")
}

/// A call of `export` that failed as it ran: a trap's own text, which
/// begins `wasm trap: `, or the engine's words.
pub fn call_failed(export: &str, words: &str) -> String {
    format!("Component call failed for {export}: {words}")
}

/// A guest's output that is no JSON value as Prima reads one.
pub const OUTPUT_NOT_JSON: &str = "Component returned invalid JSON output";

/// A guest's output nested past the depth it is read to.
pub fn output_too_deep() -> String {
    format!(
        "Component returned invalid JSON output: it is nested deeper than {MAX_OUTPUT_DEPTH} levels"
    )
}

/// CYFR's answer to `op` nested past the depth a document is read to: the
/// attempt ends, whatever its guest makes of it.
pub fn answer_too_deep(op: &str) -> String {
    format!("Execution error: CYFR's answer to {op} is nested deeper than {MAX_DEPTH} levels")
}

/// A guest's request nested past the depth a document is read to.
pub fn request_too_deep() -> String {
    format!("Request is nested deeper than {MAX_DEPTH} levels")
}
