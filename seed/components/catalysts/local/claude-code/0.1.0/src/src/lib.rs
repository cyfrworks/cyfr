//! Claude Code as a `model/chat@1` brain: the harness runs as itself in
//! the person's kept folder, on their own sign-in, and this catalyst
//! drives it over the program's pipe. See `chat.rs` for the contract and
//! `harness.rs` for the harness's protocol.

#[allow(warnings)]
mod bindings;
mod chat;
mod harness;
mod stream;

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::time::Instant;

use bindings::cyfr::emit::events;
use bindings::cyfr::process::pipe;
use bindings::exports::cyfr::catalyst::run::Guest;
use serde_json::{json, Value};

use chat::{Opened, Pipe, Received};
use stream::{Deltas, Sink};

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        handle(&input)
    }
}

bindings::export!(Component with_types_in bindings);

fn handle(input: &str) -> String {
    let Ok(parsed) = serde_json::from_str::<Value>(input) else {
        return chat::invalid("The input is not JSON.").envelope();
    };
    let params = parsed.get("params").cloned().unwrap_or(json!({}));
    let ok = |data: Value| json!({"status": 200, "data": data}).to_string();
    match parsed.get("operation").and_then(Value::as_str) {
        Some("chat") => {
            let request = match chat::parse_request(&params) {
                Ok(request) => request,
                Err(message) => return chat::invalid(message).envelope(),
            };
            let mut deltas = Deltas::new(Host);
            let deadline = Instant::now() + chat::CHAT_BUDGET;
            match chat::chat(&mut HostPipe, &mut deltas, &request, fresh_id(), deadline) {
                Ok(response) => ok(response),
                Err(refusal) => {
                    stream::error(&mut deltas, refusal.kind, &refusal.message);
                    refusal.envelope()
                }
            }
        }
        Some("describe") => {
            let model = match params.get("model") {
                None | Some(Value::Null) => None,
                Some(Value::String(model)) if chat::model_id(model) => Some(model.as_str()),
                Some(_) => {
                    return json!({"status": 404, "error": {"type": "unknown_model", "message": "Claude Code takes no such model id."}})
                        .to_string()
                }
            };
            let listing = chat::listing(&mut HostPipe, &listing_key(), Instant::now() + chat::LISTING_BUDGET).ok();
            ok(chat::describe(model, listing.as_deref()))
        }
        Some("models") => match chat::listing(&mut HostPipe, &listing_key(), Instant::now() + chat::LISTING_BUDGET) {
            Ok(listing) => ok(chat::models(&listing)),
            Err(refusal) => refusal.envelope(),
        },
        _ => json!({"status": 400, "error": {"type": "unknown_operation", "message": "This catalyst answers chat, describe and models."}})
            .to_string(),
    }
}

/// A new session's id: a UUID from the host's randomness.
fn fresh_id() -> String {
    let bits = |salt: u64| {
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_u64(salt);
        hasher.finish()
    };
    chat::uuid([bits(1), bits(2)])
}

/// The key of a listing's own session, never a chat's.
fn listing_key() -> String {
    format!("listing-{}", fresh_id())
}

/// The host's emit. A refused event is dropped: the answer still returns.
struct Host;

impl Sink for Host {
    fn emit(&mut self, event: Value) {
        let _ = events::emit(&event.to_string());
    }
}

/// The host's pipe import.
struct HostPipe;

impl Pipe for HostPipe {
    fn open(&mut self, need: &str, key: &str, argv: &[String]) -> Result<Opened, String> {
        pipe::open(need, key, argv).map(|opened| Opened {
            session: opened.session,
            resumed: opened.resumed,
        })
    }

    fn send(&mut self, session: &str, lines: &[String]) -> Result<(), String> {
        pipe::send(session, lines)
    }

    fn recv(&mut self, session: &str, after: u64, max_wait_ms: u32) -> Result<Received, String> {
        pipe::recv(session, after, max_wait_ms).map(|got| Received {
            lines: got.lines.into_iter().map(|line| (line.seq, line.text)).collect(),
            running: got.running,
        })
    }

    fn close(&mut self, session: &str) -> Result<(), String> {
        pipe::close(session)
    }
}
