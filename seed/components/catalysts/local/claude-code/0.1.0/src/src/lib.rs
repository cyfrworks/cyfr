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
            chat::describe_answer(&mut HostPipe, &listing_key(), model, Instant::now() + chat::LISTING_BUDGET)
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

/// A read as the host's import answers it, every member kept.
fn received(got: pipe::RecvResult) -> Received {
    Received {
        lines: got.lines.into_iter().map(|line| (line.seq, line.text)).collect(),
        dropped: got.dropped,
        running: got.running,
    }
}

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
        pipe::recv(session, after, max_wait_ms).map(received)
    }

    fn close(&mut self, session: &str) -> Result<(), String> {
        pipe::close(session)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::time::{Duration, Instant};

    use super::*;

    /// A pipe whose reads come as the host's import answers them, through
    /// the adapter (`received`).
    struct Wire {
        reads: VecDeque<pipe::RecvResult>,
        closed: Vec<String>,
    }

    impl Pipe for Wire {
        fn open(&mut self, _need: &str, _key: &str, _argv: &[String]) -> Result<Opened, String> {
            Ok(Opened { session: "pipe-1".into(), resumed: false })
        }
        fn send(&mut self, _session: &str, _lines: &[String]) -> Result<(), String> {
            Ok(())
        }
        fn recv(&mut self, _session: &str, _after: u64, _wait: u32) -> Result<Received, String> {
            let empty = pipe::RecvResult { lines: Vec::new(), dropped: 0, running: false };
            Ok(received(self.reads.pop_front().unwrap_or(empty)))
        }
        fn close(&mut self, session: &str) -> Result<(), String> {
            self.closed.push(session.into());
            Ok(())
        }
    }

    fn read(seq: u64, text: &str, dropped: u32) -> pipe::RecvResult {
        pipe::RecvResult { lines: vec![pipe::Line { seq, text: text.into() }], dropped, running: true }
    }

    #[test]
    fn lines_the_buffer_dropped_mid_turn_interrupt_the_session_and_close_it() {
        let answered = |id: &str| {
            format!(r#"{{"type":"control_response","response":{{"subtype":"success","request_id":"{id}","response":{{"errors":{{}}}}}}}}"#)
        };
        let mut wire = Wire {
            reads: VecDeque::from([
                read(1, &answered("cyfr-initialize"), 0),
                read(2, &answered("cyfr-tools"), 0),
                // One line between 2 and 4 is gone: it may have been an ask.
                read(4, r#"{"type":"result","subtype":"success","is_error":false,"usage":{}}"#, 1),
            ]),
            closed: Vec::new(),
        };
        let request = chat::parse_request(&json!({"model": "haiku", "messages": [{"role": "user", "content": "hi"}]})).unwrap();
        let mut deltas = Deltas::new(Vec::<Value>::new());
        let deadline = Instant::now() + Duration::from_secs(30);
        let refusal = chat::chat(&mut wire, &mut deltas, &request, fresh_id(), deadline).unwrap_err();
        assert_eq!(refusal.kind, "provider_error");
        assert!(refusal.message.contains("interrupted"), "{}", refusal.message);
        assert_eq!(wire.closed, ["pipe-1"], "the session closes, so the next chat resumes from the folder");
    }
}
