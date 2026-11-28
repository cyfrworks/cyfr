// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! `cyfr:http/streaming`: a catalyst's request whose answer it reads as it
//! arrives, as `super::http` reads, pins and sends a fetch's.
//!
//! - `request(json)` answers `{"handle": h}` once the request is sent, or
//!   its refusal: a fetch's, but `stream_error` for a request whose method
//!   or URL is no text, or whose body is neither text nor null, which a
//!   fetch answers `invalid_request`. At most `MAX_STREAMS` are open at
//!   once, and none past the relay's `crate::relay::MAX_FETCHES`, which
//!   counts a stream closed until its answer has drained (`stream_limit`
//!   for either). A stream's request takes no `multipart`.
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
//! that reads slowly holds the service's connection waiting, and the
//! runner holds at most one credit of it. A stream closed early, by its
//! guest or by its attempt's end, drains in the relay (`crate::relay::Fetch`),
//! and its guest goes on as it chooses.
//!
//! What a stream's answer means for its attempt is recorded when it
//! arrives, whether or not its guest reads it (`Watcher`): its
//! `http.request` event when its head arrives (or with `error` when it
//! ends with none), and the relay's refusal reported to CYFR; an attached
//! answer lost or uncertain leaves the relay in doubt, so its runner is not
//! reused (`crate::relay`). A read answers the guest and records nothing of
//! that again.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use serde_json::{Map, Value};

use super::http::{
    self, EventFields, Kind, Pinning, Purpose, Refusal, Sent, refusal, refused_answer,
};
use super::{Guest, catalyst, error_json};
use crate::attempt::Host;
use crate::authority::Limits;
use crate::control::Meta;
use crate::relay::{Ended, Taken, Watch};
use crate::words;

/// The most streams an execution holds open at once.
pub const MAX_STREAMS: usize = 3;

/// How long a read waits for a piece before it answers none.
pub const READ_WAIT: Duration = Duration::from_millis(100);

/// The most of an answer one read hands its guest.
pub const PIECE_BYTES: usize = 256 * 1024;

/// The answer of a piece that is no text (`tests/fixtures/guest_error.json`'s
/// `fallback`).
const NOT_TEXT: &str =
    r#"{"error":{"type":"encoding_error","message":"Failed to encode response"}}"#;

/// One open stream: its fetch, and what its reads answer from. The request
/// it was sent for is not kept.
pub struct Stream {
    sent: Sent,
    host: String,
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
            return Ok(error_json(Kind::StreamLimit.name(), words::STREAM_LIMIT));
        }
        let run = self.run.clone();
        let asked = match http::requested(&request, &run.limits, Purpose::Stream) {
            Ok(asked) => asked,
            Err(refused) => return refused_answer(&run, refused).await,
        };
        drop(request);
        let started = Instant::now();
        let pinning = Pinning {
            hops: &mut self.hops,
            purpose: Purpose::Stream,
        };
        let sent = match http::send(&run, &asked, pinning).await? {
            Ok(sent) => sent,
            Err(refused) => return refused_answer(&run, refused).await,
        };
        Watcher::start(
            &run,
            &sent,
            EventFields::of(&run, &asked, started),
            &asked.host,
        );
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).expect("the operating system's random source answers");
        let handle = crate::wire::encode_base64url(&bytes);
        self.streams.insert(
            handle.clone(),
            Stream {
                sent,
                host: asked.host.clone(),
                started,
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
                Kind::InvalidHandle.name(),
                &words::unknown_handle(&handle),
            ));
        };
        if stream.started.elapsed() > Duration::from_millis(stream.timeout_ms) {
            self.streams.remove(&handle);
            let seconds = run.limits.timeout_ms() / 1000;
            return Ok(error_json(
                Kind::Timeout.name(),
                &words::stream_timed_out(seconds),
            ));
        }
        match next_piece(stream, &run.limits).await {
            Piece::Data(data) => {
                let max = run.limits.max_response_size;
                let size = stream.read_bytes + data.len() as u64;
                if size > max {
                    self.streams.remove(&handle);
                    let refused = refusal(Kind::ResponseTooLarge, words::stream_counted(size, max));
                    return refused_answer(&run, refused).await;
                }
                stream.read_bytes = size;
                let Ok(data) = std::str::from_utf8(&data) else {
                    return Ok(NOT_TEXT.to_owned());
                };
                Ok(answer(data, false, stream.status))
            }
            Piece::None => Ok(answer("", stream.done, stream.status)),
            // Recorded as it arrived: the guest is answered alone.
            Piece::Failed(refused) => {
                self.streams.remove(&handle);
                Ok(error_json(&refused.kind, &refused.message))
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
    Failed(Refusal),
}

// The next piece of `stream`'s answer, waiting at most `READ_WAIT` for one.
async fn next_piece(stream: &mut Stream, limits: &Limits) -> Piece {
    if stream.done {
        return Piece::None;
    }
    let until = Instant::now() + READ_WAIT;
    loop {
        let wait = until.saturating_duration_since(Instant::now());
        let Some(taken) = stream.sent.fetch.next(PIECE_BYTES, true, wait).await else {
            return Piece::None;
        };
        match taken {
            Taken::Head { status, .. } => stream.status = Some(status),
            Taken::Body(body) => return Piece::Data(body),
            Taken::End(Ended::Whole) => {
                stream.done = true;
                return Piece::None;
            }
            Taken::End(end) => {
                let refused = stream_end(&end, &stream.host, limits);
                return Piece::Failed(refused.expect("an end other than whole refuses"));
            }
        }
    }
}

/// How a stream's `end` answers its guest's request to `host`: as a
/// fetch's (`http::ended_as`), but a pinned stream that stopped arriving
/// answers the idle timeout, one past its size the stream's sentence, and a
/// failure after its request was sent `request_failed`; CYFR's own type,
/// `http_error` for an attached answer's upstream among them, as given.
pub fn stream_end(end: &Ended, host: &str, limits: &Limits) -> Option<Refusal> {
    http::ended_as(end, host, limits).map(|refused| match end {
        Ended::Code(code) if code == "timeout" => refusal(
            Kind::Timeout,
            words::stream_idle(limits.timeout_ms() / 1000),
        ),
        Ended::Code(code) if code == "response_too_large" => refusal(
            Kind::ResponseTooLarge,
            words::stream_too_large(limits.max_response_size),
        ),
        _ if refused.is(Kind::HttpError) => Refusal {
            kind: Kind::RequestFailed.name().to_owned(),
            ..refused
        },
        _ => refused,
    })
}

/// What a stream's answer means for its attempt, recorded once each as it
/// arrives: the attempt's event and report (the module's description). The watcher holds its attempt's host weakly: once the
/// attempt is gone there is nothing to record for it.
pub struct Watcher {
    settling: tokio::sync::Mutex<()>,
    evented: AtomicBool,
    settled: AtomicBool,
    fields: EventFields,
    host: String,
    limits: Limits,
    watch: Watch,
}

impl Watcher {
    /// Watch `sent`'s answer for its attempt, `run`, from now until its
    /// end, beside its guest's reads.
    fn start(run: &super::Run, sent: &Sent, fields: EventFields, host: &str) {
        let watcher = Arc::new(Watcher {
            settling: tokio::sync::Mutex::new(()),
            evented: AtomicBool::new(false),
            settled: AtomicBool::new(false),
            fields,
            host: host.to_owned(),
            limits: run.limits.clone(),
            watch: sent.fetch.watch(),
        });
        run.host.watch(watcher.clone());
        let attempt = Arc::downgrade(&run.host);
        let mut changed = sent.fetch.watch();
        tokio::spawn(async move {
            loop {
                let Some(host) = Weak::upgrade(&attempt) else {
                    return;
                };
                if watcher.settle(&host).await {
                    return;
                }
                drop(host);
                changed.changed().await;
            }
        });
    }

    /// Record what has arrived and is not yet recorded, once; whether the
    /// stream has ended and everything of it is recorded. One settling at
    /// a time: a caller waits for one already under way, its event sent
    /// and its report answered or failed, so the attempt that settles its
    /// streams before it closes waits for what its watchers are reporting.
    pub async fn settle(&self, host: &Host) -> bool {
        let _settling = self.settling.lock().await;
        let (status, end) = self.watch.now();
        if let Some(status) = status
            && !self.evented.swap(true, Ordering::SeqCst)
        {
            self.fields
                .send(host, Meta::Integer(u64::from(status)))
                .await;
        }
        let Some(end) = end else {
            return false;
        };
        if self.settled.load(Ordering::SeqCst) {
            return true;
        }
        let refused = stream_end(&end, &self.host, &self.limits);
        if !self.evented.swap(true, Ordering::SeqCst) {
            self.fields.send(host, Meta::text("error")).await;
        }
        if let Some(refused) = refused {
            // A report whose answer is too deep ends nothing here: the
            // attempt's own calls meet the same answer.
            let _ = http::record(host, &refused).await;
        }
        // Settled once everything of it is recorded, not when it began.
        self.settled.store(true, Ordering::SeqCst);
        true
    }

    /// Whether everything of the stream is recorded.
    pub fn settled(&self) -> bool {
        self.settled.load(Ordering::SeqCst)
    }
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
