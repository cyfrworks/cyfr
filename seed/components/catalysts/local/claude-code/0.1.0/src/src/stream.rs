//! The `model/chat@1` stream events a turn emits while it runs: `text.delta
//! {text}`, `tool_call.start {index, id, name}`, `tool_call.delta {index,
//! arguments}`, `tool_call.end {index}`, `usage {usage}`, `stop
//! {stop_reason}` and `error {error}`. Text is batched: a batch goes out
//! when it fills, when it has been held `FLUSH_AFTER`, when a read finds
//! nothing new, and before any other event.

use std::time::{Duration, Instant};

use serde_json::{json, Value};

const BATCH_BYTES: usize = 256;
const FLUSH_AFTER: Duration = Duration::from_millis(50);

/// Where stream events go: the host, or a list in a test.
pub trait Sink {
    fn emit(&mut self, event: Value);
}

impl Sink for Vec<Value> {
    fn emit(&mut self, event: Value) {
        self.push(event);
    }
}

/// Text deltas held back into batches.
pub struct Deltas<S: Sink> {
    sink: S,
    text: String,
    held_since: Option<Instant>,
}

impl<S: Sink> Deltas<S> {
    pub fn new(sink: S) -> Self {
        Deltas {
            sink,
            text: String::new(),
            held_since: None,
        }
    }

    pub fn text(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        self.held_since.get_or_insert_with(Instant::now);
        self.text.push_str(text);
        if self.text.len() >= BATCH_BYTES {
            self.flush();
        }
    }

    /// An event other than a delta, after the batch still held.
    pub fn event(&mut self, event: Value) {
        self.flush();
        self.sink.emit(event);
    }

    /// Flush the batch once it has been held `FLUSH_AFTER`.
    pub fn flush_due(&mut self) {
        if self.held_since.is_some_and(|since| since.elapsed() >= FLUSH_AFTER) {
            self.flush();
        }
    }

    /// Let go of the text held and not yet sent.
    pub fn discard(&mut self) {
        self.held_since = None;
        self.text.clear();
    }

    pub fn flush(&mut self) {
        self.held_since = None;
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

/// A tool call, as its three events: its start, its arguments whole, and
/// its end. `arguments` is `None` for a call shown for display only.
pub fn tool_call<S: Sink>(deltas: &mut Deltas<S>, index: u64, id: &str, name: &str, arguments: Option<&Value>) {
    deltas.event(json!({"type": "tool_call.start", "index": index, "id": id, "name": name}));
    if let Some(arguments) = arguments {
        deltas.event(json!({"type": "tool_call.delta", "index": index, "arguments": arguments.to_string()}));
    }
    deltas.event(json!({"type": "tool_call.end", "index": index}));
}

/// The closing events of a contract response: its usage, then its stop.
pub fn close<S: Sink>(deltas: &mut Deltas<S>, response: &Value) {
    deltas.event(json!({"type": "usage", "usage": response["usage"]}));
    deltas.event(json!({"type": "stop", "stop_reason": response["stop_reason"]}));
}

/// A refusal as the stream's `error` event.
pub fn error<S: Sink>(deltas: &mut Deltas<S>, kind: &str, message: &str) {
    deltas.event(json!({"type": "error", "error": {"type": kind, "message": message}}));
}
