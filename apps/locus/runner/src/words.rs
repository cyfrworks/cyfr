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

/// An attempt whose lease CYFR no longer holds for it.
pub const LEASE_LOST: &str = "Execution lease lost: the row is no longer this attempt's to finish";

/// An assignment whose authority or component type the runner cannot read.
pub const UNRUNNABLE: &str = "Execution error: the assignment could not be run";

/// A run whose node consents no memory at all, refused before its
/// component is fetched, as the engine before this one refused it.
pub const NO_MEMORY: &str = "Execution error: the engine raised an internal error";

/// A component whose bytes CYFR did not answer.
pub const NOT_FETCHED: &str = "Execution error: the component's bytes could not be fetched";

/// A component whose bytes are not the digest's.
pub const NOT_DIGEST: &str = "Execution error: the component's bytes do not match its digest";

/// An attempt the runner stopped for its waiter or its service's cancel.
pub const CANCELLED: &str = "Execution cancelled before it completed";

/// What a waiter is answered of an attempt left open, or of a child the
/// runner could not run to its close.
pub const ENDED: &str = "Execution attempt ended before it closed";

/// A child CYFR admitted that the runner does not start, closed failed.
pub const CHILD_UNSTARTED: &str = "Execution refused: its runner could not start";

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

// ============================================================================
// A guest's requests (`cyfr:http/fetch`, `cyfr:http/streaming`)
// ============================================================================
//
// A sentence names the host the guest asked for, never its URL, whose path
// and query can carry a credential; nor a header's value.

/// A request past its envelope bound, or past the consented size when the
/// worker service's check refused it.
pub const REQUEST_TOO_LARGE: &str =
    "Request exceeds the consented max_request_size for this component.";

/// A request that is no JSON.
pub const REQUEST_NOT_JSON: &str = "Invalid JSON request";

/// A request that does not read as one.
pub const MALFORMED_REQUEST: &str = "Malformed HTTP request.";
pub const NO_METHOD_OR_URL: &str = "Invalid request: must include 'method' and 'url'";
pub const NO_HOSTNAME: &str = "Invalid URL: missing hostname";
pub const URL_CREDENTIALS: &str = "Invalid URL: URL credentials are refused";
pub const BAD_URL: &str = "Invalid URL";
pub const BODY_AND_MULTIPART: &str = "Request cannot have both 'body' and 'multipart'";
pub const BAD_HEADERS: &str =
    "Invalid headers: an object of names to values, or an array of [name, value] pairs";
pub const BAD_CONNECTION: &str = "Invalid connection: the name of a need, as a string";
pub const BAD_BODY_BASE64: &str = "Invalid base64 in request body";
pub const MULTIPART_PART: &str = "Multipart part must include 'name' and either 'data' or 'value'";
pub const STREAM_MULTIPART: &str = "Streaming requests do not support 'multipart'";
pub const UNSENDABLE: &str = "The request cannot be sent: its path or headers are malformed";

/// A multipart part whose data is no base64, by the part's name.
pub fn bad_part_base64(name: &str) -> String {
    format!("Invalid base64 in multipart part '{name}'")
}

/// An attached request carrying a credential header of its own
/// (`Prima.Refusal`'s `credential_header_refused`).
pub const CREDENTIAL_HEADER: &str =
    "A request that names a connection carries no credential header.";

/// An attached request setting a header only the client making it sets.
pub fn attached_header(name: &str) -> String {
    format!("An attached request cannot set the {name} header.")
}

/// An attached request that does not read as CYFR reads one.
pub const ATTACHED_UNREAD: &str = "The attached request does not read.";

/// A request the runner holds back: its execution has as many requests in
/// flight as its relay carries.
pub fn requests_in_flight(most: usize) -> String {
    format!(
        "The request was not sent: the execution has {most} requests in flight, the most its \
         relay carries"
    )
}

/// A stream past the three an execution holds open.
pub const STREAM_LIMIT: &str = "Maximum concurrent streams (3) exceeded";

/// A pin CYFR refused, and why, for a request to `host`.
pub fn pin_domain(host: &str) -> String {
    format!("HTTP egress refused: {host} is not in the egress domains")
}
pub fn pin_denied(host: &str) -> String {
    format!("Address of {host} blocked: the egress policy refuses it")
}
pub fn pin_metadata(host: &str) -> String {
    format!("metadata IP blocked (resolved from {host})")
}
pub fn pin_resolution(host: &str) -> String {
    format!("DNS resolution failed for {host}")
}
pub fn redirect_refused(host: &str) -> String {
    format!("Redirect to {host} refused: the request's credentials may not follow it")
}

/// A pin the runner itself could not take, and why, for a request to
/// `host`.
pub fn pin_elsewhere(host: &str) -> String {
    format!("HTTP egress refused: {host} was pinned elsewhere")
}
pub fn pin_expired(host: &str) -> String {
    format!("HTTP egress refused: the pin for {host} expired before its request was sent")
}
pub fn pin_unavailable(host: &str) -> String {
    format!("HTTP egress refused: the address of {host} could not be pinned")
}
pub const PIN_NOT_CURRENT: &str = "HTTP egress refused: the execution attempt is not current";

/// The worker service's check of a request, as its code says which rule
/// refused it.
pub const SERVICE_METHOD: &str =
    "HTTP egress refused by the worker service's check: the method is not in the egress methods";
pub const SERVICE_SCHEME: &str =
    "HTTP egress refused by the worker service's check: the scheme is not in the egress schemes";
pub const SERVICE_HEADER: &str = "HTTP egress refused by the worker service's check: the request \
                                  sets a header only the client making it sets";
pub const SERVICE_SIZE: &str = "HTTP egress refused by the worker service's check: the request's \
                                body, URL and headers exceed the consented max_request_size";
pub const SERVICE_METADATA: &str = "metadata IP blocked";

/// The worker service's check of a request to `host`, outside the egress
/// domains: the host the guest asked for, an attached request's too.
pub fn service_domain(host: &str) -> String {
    format!(
        "HTTP egress refused by the worker service's check: {host} is not in the egress domains"
    )
}

/// A method the relay's frame cannot carry, in today's runner's words.
pub fn unsupported_method(method: &str) -> String {
    format!("Unsupported HTTP method: {method}")
}
pub const RATE_LIMITED: &str = "HTTP egress refused: the consented rate limit is exhausted";

/// A request that timed out, or whose connection did, after `ms`.
pub fn request_timeout(ms: u64) -> String {
    format!("HTTP request timed out after {ms}ms")
}
pub fn connect_timeout(ms: u64) -> String {
    format!("HTTP request could not connect within {ms}ms")
}

/// An answer past the node's `max_response_size`, `size` bytes when they
/// were counted.
pub fn response_too_large(max: u64) -> String {
    format!("Response body exceeds limit ({max} bytes)")
}
pub fn response_counted(size: u64, max: u64) -> String {
    format!("Response body ({size} bytes) exceeds limit ({max} bytes)")
}

/// A request that failed after it was sent: its transport's code, or none.
pub const HTTP_FAILED: &str = "HTTP request failed";
pub fn http_failed(code: &str) -> String {
    format!("HTTP request failed: {code}")
}

/// A stream's ends.
pub fn unknown_handle(handle: &str) -> String {
    format!("Unknown stream handle: {handle}")
}
pub fn stream_timed_out(seconds: u64) -> String {
    format!("Stream timed out after {seconds}s")
}
pub fn stream_idle(seconds: u64) -> String {
    format!("No stream data for {seconds}s")
}
pub fn stream_too_large(max: u64) -> String {
    format!("Stream response exceeds limit ({max} bytes)")
}
pub fn stream_counted(size: u64, max: u64) -> String {
    format!("Stream response ({size} bytes) exceeds limit ({max} bytes)")
}

// ============================================================================
// A formula's invoke (`cyfr:formula/invoke`)
// ============================================================================

/// A host call CYFR did not answer as one, or refused in no words of its own.
pub const CALL_FAILED: &str = "The call failed.";

/// A request past the envelope its node's `max_request_size` allows.
pub const INVOKE_TOO_LARGE: &str =
    "Request exceeds the consented max_request_size for this component.";

pub const NO_TOOL_OR_ACTION: &str = "Request must include 'tool' (string) and 'action' (string)";
pub const ARGS_NOT_MAP: &str = "args must be a map";
pub const NO_TASK_IDS: &str = "Request must include 'task_ids' array";
pub const EMPTY_TASK_IDS: &str = "task_ids array must be non-empty";
pub const TASKS_EXCEEDED: &str = "Maximum concurrent tasks exceeded";
pub const TASK_TIMED_OUT: &str = "Task timed out";
pub const ALL_TIMED_OUT: &str = "All tasks timed out";
pub const RUN_STREAM_SPAWNED: &str =
    "run_stream cannot be spawned — spawn execution.run, or call run_stream directly";
pub const UNEXPECTED_RESULT: &str = "Unexpected result";
pub const UNEXPECTED_FORMAT: &str = "Unexpected result format";

/// The sentence a task's end renders as, for a task the formula cancelled
/// (`Prima.Refusal`'s `:cancelled`).
pub const TASK_CANCELLED: &str = "The call was cancelled";

/// A task id a formula's tracker does not hold, as `Prima.GuestError`
/// renders a reason it does not know.
pub const UNKNOWN_REASON: &str = "the call failed";

pub fn no_reference(name: &str) -> String {
    format!("{name} requires a 'reference'")
}
pub fn input_not_object(name: &str) -> String {
    format!("{name} requires 'input' to be an object")
}
pub fn connection_not_name(name: &str) -> String {
    format!("{name} requires 'connection' to be an account's name")
}
pub fn no_dispatch(name: &str) -> String {
    format!("{name} has no host dispatch")
}
pub fn not_spawnable(name: &str) -> String {
    format!("{name} cannot be spawned")
}
pub fn too_many_task_ids(most: u64) -> String {
    format!("task_ids exceeds the concurrent-task limit ({most})")
}
pub fn unknown_task(task_id: &str) -> String {
    format!("Unknown task_id: {task_id}")
}
pub fn already_completed(task_id: &str) -> String {
    format!("Task {task_id} already completed")
}
