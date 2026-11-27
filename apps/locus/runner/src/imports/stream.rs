// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! `cyfr:http/streaming`: a catalyst's request whose answer it reads as it
//! arrives, as `super::http` reads, pins and sends a fetch's.
//!
//! - `request(json)` answers `{"handle": h}` once the request is sent, or
//!   its refusal. At most `MAX_STREAMS` are open at once, and none past
//!   the relay's `crate::relay::MAX_FETCHES` (`stream_limit`). A stream's
//!   request takes no `multipart`.
//! - `read(h)` answers the next piece of the answer as `{"data", "done"}`,
//!   with `"status"` once the answer has begun, waiting at most
//!   `READ_WAIT` for one and answering `"data": ""` when none arrived; an
//!   answer that ended whole answers `"done": true` from then on. A
//!   stream that failed, timed out, or would pass the node's
//!   `max_response_size` answers its error once and is closed.
//! - `close(h)` closes the stream, whatever it was reading, and answers
//!   `{"ok": true}`, for a handle it does not know too.
//!
//! The relay sends the answer only against the credit the guest's reads
//! grant: each piece a read hands the guest is granted back, so a guest
//! that reads slowly holds the service's connection waiting, never the
//! runner's memory past one credit. A stream closed early, by its guest or
//! by its attempt's end, drains in the relay (`crate::relay::Fetch`), and
//! its guest goes on as it chooses.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use serde_json::{Map, Value};

use super::http::{self, Asked, Pinning, Purpose, Read, Sent, refusal, refused_answer};
use super::{Guest, catalyst, error_json};
use crate::control::Meta;
use crate::words;

/// The most streams an execution holds open at once.
pub const MAX_STREAMS: usize = 3;

/// How long a read waits for a piece before it answers none.
pub const READ_WAIT: Duration = Duration::from_millis(100);

/// The answer of a piece that is no text (`tests/fixtures/guest_error.json`'s
/// `fallback`).
const NOT_TEXT: &str =
    r#"{"error":{"type":"encoding_error","message":"Failed to encode response"}}"#;

/// One open stream.
pub struct Stream {
    sent: Sent,
    asked: Asked,
    started: Instant,
    timeout_ms: u64,
    status: Option<u16>,
    read_bytes: u64,
    /// The answer ended whole.
    done: bool,
}

/// An execution's open streams, by handle.
pub type Streams = BTreeMap<String, Stream>;

impl catalyst::cyfr::http::streaming::Host for Guest {
    async fn request(&mut self, request: String) -> wasmtime::Result<String> {
        let request = zeroize::Zeroizing::new(request);
        if self.streams.len() >= MAX_STREAMS {
            return Ok(error_json("stream_limit", words::STREAM_LIMIT));
        }
        let run = self.run.clone();
        let asked = match http::requested(&request, &run.limits, Purpose::Stream) {
            Ok(asked) => asked,
            Err(refused) => return refused_answer(&run, refused).await,
        };
        drop(request);
        let pinning = Pinning {
            hops: &mut self.hops,
            purpose: Purpose::Stream,
        };
        let sent = match http::send(&run, &asked, pinning).await? {
            Ok(sent) => sent,
            Err(refused) => return refused_answer(&run, refused).await,
        };
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).expect("the operating system's random source answers");
        let handle = crate::wire::encode_base64url(&bytes);
        self.streams.insert(
            handle.clone(),
            Stream {
                sent,
                asked,
                started: Instant::now(),
                timeout_ms: run.limits.timeout_ms(),
                status: None,
                read_bytes: 0,
                done: false,
            },
        );
        Ok(serde_json::json!({ "handle": handle }).to_string())
    }

    async fn read(&mut self, handle: String) -> wasmtime::Result<String> {
        let run = self.run.clone();
        let Some(stream) = self.streams.get_mut(&handle) else {
            return Ok(error_json(
                "invalid_handle",
                &words::unknown_handle(&handle),
            ));
        };
        if stream.started.elapsed() > Duration::from_millis(stream.timeout_ms) {
            self.streams.remove(&handle);
            let seconds = run.limits.timeout_ms() / 1000;
            return Ok(error_json("timeout", &words::stream_timed_out(seconds)));
        }
        match next_piece(&run, stream).await {
            Piece::Data(data) => {
                let max = run.limits.max_response_size;
                let size = stream.read_bytes + data.len() as u64;
                if size > max {
                    self.streams.remove(&handle);
                    let refused = refusal("response_too_large", words::stream_counted(size, max));
                    return refused_answer(&run, refused).await;
                }
                stream.read_bytes = size;
                stream.sent.fetch.grant(data.len());
                let Ok(data) = std::str::from_utf8(&data) else {
                    return Ok(NOT_TEXT.to_owned());
                };
                Ok(answer(data, false, stream.status))
            }
            Piece::None => Ok(answer("", stream.done, stream.status)),
            Piece::Failed(refused) => {
                self.streams.remove(&handle);
                refused_answer(&run, refused).await
            }
        }
    }

    async fn close(&mut self, handle: String) -> wasmtime::Result<String> {
        // Its fetch, dropped before its end, drains in the relay.
        self.streams.remove(&handle);
        Ok(serde_json::json!({"ok": true}).to_string())
    }
}

enum Piece {
    Data(zeroize::Zeroizing<Vec<u8>>),
    None,
    Failed(http::Refusal),
}

// The next piece of `stream`'s answer, waiting at most `READ_WAIT` for one.
async fn next_piece(run: &super::Run, stream: &mut Stream) -> Piece {
    if stream.done {
        return Piece::None;
    }
    let until = Instant::now() + READ_WAIT;
    loop {
        let wait = until.saturating_duration_since(Instant::now());
        let keys = run.host.keys();
        let Some(read) = http::next(
            &mut stream.sent,
            keys,
            &stream.asked.host,
            &run.limits,
            wait,
        )
        .await
        else {
            return Piece::None;
        };
        match read {
            Read::Head { status, body, .. } => {
                stream.status = Some(status);
                // A stream's event is its answer's beginning.
                http::http_event(
                    run,
                    &stream.asked,
                    Meta::Integer(u64::from(status)),
                    stream.started,
                )
                .await;
                if !body.is_empty() {
                    return Piece::Data(body);
                }
            }
            Read::Body(body) => return Piece::Data(body),
            Read::End => {
                stream.done = true;
                return Piece::None;
            }
            Read::Nothing => {}
            Read::Lost => {
                run.host.unclean();
                return failed(run, stream, refusal("request_failed", words::HTTP_FAILED)).await;
            }
            Read::Failed(refused) => {
                let refused = match refused.kind.as_str() {
                    "response_too_large" if !refused.by_cyfr => refusal(
                        "response_too_large",
                        words::stream_too_large(run.limits.max_response_size),
                    ),
                    "timeout" if !refused.by_cyfr => refusal(
                        "timeout",
                        words::stream_idle(run.limits.timeout_ms() / 1000),
                    ),
                    // A request that failed after it was sent failed as a
                    // stream's request.
                    "http_error" => http::Refusal {
                        kind: "request_failed".to_owned(),
                        ..refused
                    },
                    _ => refused,
                };
                return failed(run, stream, refused).await;
            }
        }
    }
}

// A stream that ended early: its event when its answer never began.
async fn failed(run: &super::Run, stream: &Stream, refused: http::Refusal) -> Piece {
    if stream.status.is_none() {
        http::http_event(run, &stream.asked, Meta::text("error"), stream.started).await;
    }
    Piece::Failed(refused)
}

// A read's answer: its data and whether the answer ended, and its status
// once it began.
fn answer(data: &str, done: bool, status: Option<u16>) -> String {
    let mut answer = Map::new();
    answer.insert("data".to_owned(), Value::String(data.to_owned()));
    answer.insert("done".to_owned(), Value::Bool(done));
    if let Some(status) = status {
        answer.insert("status".to_owned(), Value::from(status));
    }
    Value::Object(answer).to_string()
}
