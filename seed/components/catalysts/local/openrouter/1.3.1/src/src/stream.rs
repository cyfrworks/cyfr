//! A provider's answer as it streams: the server-sent events it arrives
//! in, the `model/chat@1` stream events emitted while it is assembled,
//! and the read loop over the host's streaming HTTP.
//!
//! Stream events: `text.delta {text}`, `tool_call.start {index, id,
//! name}`, `tool_call.delta {index, arguments}`, `tool_call.end {index}`,
//! `usage {...}`, `stop {stop_reason}` and `error {error}`. Deltas are
//! batched: a batch goes out when it fills, when it has been held
//! `FLUSH_AFTER`, when a read finds nothing new, and before any other
//! event.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::bindings::cyfr::emit::events;
use crate::bindings::cyfr::http::streaming;

const BATCH_BYTES: usize = 256;
const FLUSH_AFTER: Duration = Duration::from_millis(50);

// ---------------------------------------------------------------------------
// Server-sent events
// ---------------------------------------------------------------------------

/// One server-sent event: its `event:` name, when it has one, and its
/// `data:` lines joined.
#[derive(Debug, PartialEq)]
pub struct Frame {
    pub event: Option<String>,
    pub data: String,
}

/// Server-sent events decoded across chunk boundaries.
#[derive(Default)]
pub struct Sse {
    pending: String,
    event: Option<String>,
    data: Vec<String>,
}

impl Sse {
    /// The events `chunk` completes.
    pub fn feed(&mut self, chunk: &str) -> Vec<Frame> {
        self.pending.push_str(chunk);
        let mut frames = Vec::new();

        while let Some(end) = self.pending.find('\n') {
            let line: String = self.pending.drain(..=end).collect();
            let line = line.trim_end_matches('\n').trim_end_matches('\r');

            if line.is_empty() {
                if !self.data.is_empty() {
                    frames.push(Frame {
                        event: self.event.take(),
                        data: self.data.join("\n"),
                    });
                    self.data.clear();
                }
                self.event = None;
            } else if let Some(rest) = line.strip_prefix("data:") {
                self.data.push(rest.strip_prefix(' ').unwrap_or(rest).to_string());
            } else if let Some(rest) = line.strip_prefix("event:") {
                self.event = Some(rest.trim().to_string());
            }
            // Comments (`:`) and fields this reader does not use are skipped.
        }

        frames
    }

    /// The event a stream that ends without a closing blank line leaves.
    pub fn finish(&mut self) -> Vec<Frame> {
        let tail = if self.pending.is_empty() { "\n" } else { "\n\n" };
        self.feed(tail)
    }
}

// ---------------------------------------------------------------------------
// Emitted events
// ---------------------------------------------------------------------------

/// Where stream events go: the host, or a list in a test.
pub trait Sink {
    fn emit(&mut self, event: Value);
}

/// The host's emit. A refused event is dropped: the answer still returns.
pub struct Host;

impl Sink for Host {
    fn emit(&mut self, event: Value) {
        let _ = events::emit(&event.to_string());
    }
}

impl Sink for Vec<Value> {
    fn emit(&mut self, event: Value) {
        self.push(event);
    }
}

/// Text and argument deltas held back into batches.
pub struct Deltas<S: Sink> {
    sink: S,
    text: String,
    arguments: BTreeMap<u64, String>,
    held_since: Option<Instant>,
}

impl<S: Sink> Deltas<S> {
    pub fn new(sink: S) -> Self {
        Deltas {
            sink,
            text: String::new(),
            arguments: BTreeMap::new(),
            held_since: None,
        }
    }

    pub fn text(&mut self, text: &str) {
        self.held_since.get_or_insert_with(Instant::now);
        self.text.push_str(text);
        if self.text.len() >= BATCH_BYTES {
            self.flush_text();
        }
    }

    pub fn arguments(&mut self, index: u64, fragment: &str) {
        self.held_since.get_or_insert_with(Instant::now);
        let pending = self.arguments.entry(index).or_default();
        pending.push_str(fragment);
        if pending.len() >= BATCH_BYTES {
            let arguments = std::mem::take(pending);
            self.sink
                .emit(json!({"type": "tool_call.delta", "index": index, "arguments": arguments}));
        }
    }

    /// An event other than a delta, after every batch still held.
    pub fn event(&mut self, event: Value) {
        self.flush();
        self.sink.emit(event);
    }

    /// Flush the batches once they have been held `FLUSH_AFTER`.
    pub fn flush_due(&mut self) {
        if self.held_since.is_some_and(|since| since.elapsed() >= FLUSH_AFTER) {
            self.flush();
        }
    }

    pub fn flush(&mut self) {
        self.held_since = None;
        self.flush_text();
        for (index, arguments) in std::mem::take(&mut self.arguments) {
            if !arguments.is_empty() {
                self.sink
                    .emit(json!({"type": "tool_call.delta", "index": index, "arguments": arguments}));
            }
        }
    }

    fn flush_text(&mut self) {
        if !self.text.is_empty() {
            let text = std::mem::take(&mut self.text);
            self.sink.emit(json!({"type": "text.delta", "text": text}));
        }
    }

    #[cfg(test)]
    pub fn into_sink(mut self) -> S {
        self.flush();
        self.sink
    }
}

pub fn tool_call_start(index: u64, id: &str, name: &str) -> Value {
    json!({"type": "tool_call.start", "index": index, "id": id, "name": name})
}

pub fn tool_call_end(index: u64) -> Value {
    json!({"type": "tool_call.end", "index": index})
}

/// The closing events of a contract response: its usage, then its stop.
pub fn close<S: Sink>(deltas: &mut Deltas<S>, response: &Value) {
    deltas.event(json!({"type": "usage", "usage": response["usage"]}));
    deltas.event(json!({"type": "stop", "stop_reason": response["stop_reason"]}));
}

/// A refusal envelope as the stream's `error` event.
pub fn error<S: Sink>(deltas: &mut Deltas<S>, envelope: &str) {
    let error = serde_json::from_str::<Value>(envelope)
        .ok()
        .and_then(|v| v.get("error").cloned())
        .unwrap_or(json!({"type": "provider_error"}));
    deltas.event(json!({"type": "error", "error": {"type": error["type"], "message": error["message"]}}));
}

// ---------------------------------------------------------------------------
// The read loop
// ---------------------------------------------------------------------------

/// How a stream ended.
pub enum Outcome {
    /// A 2xx stream, read to its end.
    Completed,
    /// A non-2xx status, with the body the provider sent.
    Refused { status: i64, body: String },
    /// No answer could be read.
    Failed(String),
}

/// Open `request` (the fetch shape) as a stream and read it to its end,
/// handing each event to `frame`. A read that finds nothing new, or one
/// after the batches have been held `FLUSH_AFTER`, flushes them, so deltas
/// go out as they arrive rather than all at the end.
pub fn read<S: Sink>(
    request: &Value,
    deltas: &mut Deltas<S>,
    mut frame: impl FnMut(Frame, &mut Deltas<S>),
) -> Outcome {
    let opened: Value = match serde_json::from_str(&streaming::request(&request.to_string())) {
        Ok(v) => v,
        Err(e) => return Outcome::Failed(format!("unreadable stream handle: {e}")),
    };
    if let Some(err) = opened.get("error") {
        return Outcome::Failed(message(err));
    }
    let Some(handle) = opened.get("handle").and_then(Value::as_str).map(str::to_string) else {
        return Outcome::Failed("the host opened no stream".into());
    };

    let mut sse = Sse::default();
    let mut status: Option<i64> = None;
    let mut body = String::new();

    let outcome = loop {
        let read: Value = match serde_json::from_str(&streaming::read(&handle)) {
            Ok(v) => v,
            Err(e) => break Outcome::Failed(format!("unreadable stream chunk: {e}")),
        };
        if let Some(err) = read.get("error") {
            break Outcome::Failed(message(err));
        }

        if status.is_none() {
            status = read.get("status").and_then(Value::as_i64);
        }
        let data = read.get("data").and_then(Value::as_str).unwrap_or("");
        let done = read.get("done").and_then(Value::as_bool).unwrap_or(false);

        match status {
            Some(s) if !(200..300).contains(&s) => body.push_str(data),
            _ if data.is_empty() => deltas.flush(),
            _ => {
                for f in sse.feed(data) {
                    frame(f, deltas);
                }
                deltas.flush_due();
            }
        }

        if done {
            break match status {
                Some(s) if !(200..300).contains(&s) => Outcome::Refused { status: s, body },
                None => Outcome::Failed("the provider answered nothing".into()),
                Some(_) => {
                    for f in sse.finish() {
                        frame(f, deltas);
                    }
                    deltas.flush();
                    Outcome::Completed
                }
            };
        }
    };

    let _ = streaming::close(&handle);
    outcome
}

fn message(err: &Value) -> String {
    match err {
        Value::String(s) => s.clone(),
        other => other
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("the stream failed")
            .to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_are_decoded_across_chunk_boundaries() {
        let mut sse = Sse::default();
        assert!(sse.feed("event: message_start\r\ndata: {\"a\"").is_empty());
        assert!(sse.feed(":1}\r\n").is_empty());

        let frames = sse.feed("\r\n: keep-alive\n\ndata: one\ndata: two\n\ndata: [DONE]");
        assert_eq!(
            frames,
            vec![
                Frame {
                    event: Some("message_start".into()),
                    data: "{\"a\":1}".into()
                },
                Frame {
                    event: None,
                    data: "one\ntwo".into()
                }
            ]
        );

        assert_eq!(
            sse.finish(),
            vec![Frame {
                event: None,
                data: "[DONE]".into()
            }]
        );
    }

    #[test]
    fn deltas_are_batched_and_flushed_before_any_other_event() {
        let mut deltas = Deltas::new(Vec::new());
        deltas.text("Hel");
        deltas.text("lo");
        deltas.arguments(0, "{\"pa");
        deltas.event(tool_call_end(0));
        deltas.text(&"x".repeat(BATCH_BYTES));
        deltas.text("y");

        let events = deltas.into_sink();
        assert_eq!(events[0], json!({"type": "text.delta", "text": "Hello"}));
        assert_eq!(events[1], json!({"type": "tool_call.delta", "index": 0, "arguments": "{\"pa"}));
        assert_eq!(events[2], json!({"type": "tool_call.end", "index": 0}));
        assert_eq!(events[3]["text"].as_str().unwrap().len(), BATCH_BYTES);
        assert_eq!(events[4], json!({"type": "text.delta", "text": "y"}));
    }

    #[test]
    fn a_held_batch_goes_out_once_it_is_due() {
        let mut deltas = Deltas::new(Vec::new());
        deltas.text("Hel");
        deltas.flush_due();
        assert!(deltas.sink.is_empty());

        std::thread::sleep(FLUSH_AFTER);
        deltas.text("lo");
        deltas.flush_due();
        assert_eq!(deltas.sink, vec![json!({"type": "text.delta", "text": "Hello"})]);

        deltas.text("!");
        deltas.flush_due();
        assert_eq!(deltas.sink.len(), 1);
    }
}
