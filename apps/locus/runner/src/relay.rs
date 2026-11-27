// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The runner's end of its relay to its worker service
//! (`Prima.RunnerRelay`), on the runner's descriptor 4: its one path to
//! CYFR's host API and to the addresses CYFR pins for its guests.
//!
//! A frame is a 4-byte big-endian length and that many bytes of one JSON
//! object, at most `MAX_FRAME_BYTES`: `v` (1), `attempt`, `seq` (its place
//! among the frames its sender sent, from 0 each way) and `kind`, then the
//! kind's members, always all of them, in order. A runner sends
//! `host_call`, `fetch` (pinned or attached) and `credit`; its service
//! sends `host_answer`, `fetch_chunk`, `fetch_end`, `attached_frame` and
//! `attached_refusal`; either sends `close`. Bodies travel in standard
//! base64 with padding, at most `MAX_BODY_BYTES` decoded.
//!
//! The channel (`Channel`) is the runner's view: the attempts it carries,
//! the calls still unanswered, the fetches still open and each fetch's
//! credit. `decode` answers the frames at a buffer's head or the first
//! reason the channel closes, in this order: the length; one JSON object;
//! the version; the kind; the direction; an unknown member, the first by
//! name; each member in order (`attempt`, `seq`, then the kind's), missing,
//! of another JSON type, outside its grammar or past its bound; `seq` out
//! of order; then what the channel's state takes. Nothing after a refusal
//! is read. `encode` refuses a frame the same way before it numbers it or
//! records anything: its attempt, then each member in the kind's order,
//! then what the channel's state takes. JSON is read as `crate::wire::parse`
//! reads it. `tests/fixtures/runner_relay.json` holds every frame and
//! refusal.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use serde_json::{Map, Value};
use zeroize::{Zeroize as _, Zeroizing};

use crate::auth::MAX_CALL_HEADER_BYTES;
use crate::host::Op;
use crate::wire::{
    Integer, MAX_INTEGER, bounded, decode_base64, decode_base64url, encode_base64url, integer,
    is_id, is_url, json_string, parse,
};

/// The protocol version every frame carries as `v`.
pub const VERSION: u64 = 1;

/// The most bytes a body carries, decoded: the host answer bound.
pub const MAX_BODY_BYTES: usize = 5_242_880;

/// The most bytes a frame's JSON spans, its length prefix excluded.
pub const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

/// The credit a fetch starts with: one body of `MAX_BODY_BYTES`.
pub const INITIAL_CREDIT: u64 = MAX_BODY_BYTES as u64;

/// The most headers a fetch's answer carries, and the bounds of each.
pub const MAX_HEADERS: usize = 128;
pub const MAX_HEADER_NAME_BYTES: usize = 256;
pub const MAX_HEADER_VALUE_BYTES: usize = 8192;

/// The most bytes a signed header spans: a host call's longest.
pub const MAX_SIGNED_HEADER_BYTES: usize = MAX_CALL_HEADER_BYTES;

/// The most bytes an attached answer's frame carries, its kind byte and
/// sealed value.
pub const MAX_ATTACHED_FRAME_BYTES: usize = 65_536;

/// The methods a fetch names (`Prima.Destination.methods/0`).
pub const METHODS: [&str; 7] = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"];

/// The purposes an attached fetch names.
pub const PURPOSES: [&str; 2] = ["fetch", "stream"];

/// The most bytes a pinned fetch's path and an attached fetch's URL span.
pub const MAX_PATH_BYTES: usize = 8192;
pub const MAX_URL_BYTES: usize = 8192;

/// The most host calls a service carries of a runner unanswered, and the
/// most fetches open, each until its `fetch_end` whether or not it is still
/// read: the service closes the channel for the one past either, so the
/// runner never sends it (`Prima.RunnerRelay.max_calls/0`, `max_fetches/0`).
pub const MAX_CALLS: usize = 64;
pub const MAX_FETCHES: usize = 16;

/// The codes a service ends a fetch with, each with what it means
/// (`Prima.RunnerRelay.fetch_end_codes/0`); a `fetch_end` naming any other
/// code ends it for the transport's own failure, which that code names.
pub const FETCH_END_CODES: [&str; 26] = [
    "timeout",
    "connect_timeout",
    "rate_limited",
    "method_blocked",
    "scheme_blocked",
    "domain_blocked",
    "invalid_request",
    "request_too_large",
    "response_too_large",
    "private_ip_blocked",
    "http_error",
    "fetch_failed",
    "refused",
    "bad_frame",
    "lost",
    "uncertain",
    "pin_domain",
    "pin_denied",
    "pin_metadata",
    "pin_resolution",
    "pin_redirect_credentials",
    "pin_malformed",
    "pin_unavailable",
    "pin_lost",
    "pin_elsewhere",
    "pin_expired",
];

/// An answer or request header: its name and value.
pub type Header = (String, String);

/// A frame a runner sends. A fetch's headers and body are a guest's, which
/// may carry its credentials: they are cleared when the frame is dropped,
/// and no `Debug` form prints them.
#[derive(Clone, PartialEq, Eq)]
pub enum Outgoing {
    HostCall {
        attempt: String,
        op: Op,
        header: String,
        body: Vec<u8>,
    },
    PinnedFetch {
        attempt: String,
        pin: String,
        method: String,
        path: String,
        headers: Vec<Header>,
        body: Vec<u8>,
    },
    AttachedFetch {
        attempt: String,
        call_id: String,
        connection: String,
        purpose: String,
        method: String,
        url: String,
        headers: Vec<Header>,
        body: Vec<u8>,
    },
    Credit {
        attempt: String,
        re: u64,
        bytes: u64,
    },
    Close {
        attempt: String,
        reason: String,
    },
}

impl Drop for Outgoing {
    fn drop(&mut self) {
        match self {
            Outgoing::PinnedFetch {
                path,
                headers,
                body,
                ..
            } => {
                path.zeroize();
                clear_headers(headers);
                body.zeroize();
            }
            Outgoing::AttachedFetch {
                url, headers, body, ..
            } => {
                url.zeroize();
                clear_headers(headers);
                body.zeroize();
            }
            Outgoing::HostCall { .. } | Outgoing::Credit { .. } | Outgoing::Close { .. } => {}
        }
    }
}

impl std::fmt::Debug for Outgoing {
    // A frame's kind and attempt only: a fetch's path, headers and body,
    // and a call's sealed body, never reach a log.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (kind, attempt) = match self {
            Outgoing::HostCall { attempt, .. } => ("host_call", attempt),
            Outgoing::PinnedFetch { attempt, .. } => ("pinned fetch", attempt),
            Outgoing::AttachedFetch { attempt, .. } => ("attached fetch", attempt),
            Outgoing::Credit { attempt, .. } => ("credit", attempt),
            Outgoing::Close { attempt, .. } => ("close", attempt),
        };
        write!(f, "Outgoing({kind}, {attempt})")
    }
}

fn clear_headers(headers: &mut [Header]) {
    for (name, value) in headers.iter_mut() {
        name.zeroize();
        value.zeroize();
    }
}

/// A frame a runner receives, with its `seq`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Incoming {
    HostAnswer {
        attempt: String,
        seq: u64,
        re: u64,
        status: Option<u16>,
        body: Vec<u8>,
    },
    FetchChunk {
        attempt: String,
        seq: u64,
        re: u64,
        status: Option<u16>,
        headers: Option<Vec<Header>>,
        body: Vec<u8>,
    },
    FetchEnd {
        attempt: String,
        seq: u64,
        re: u64,
        error: Option<String>,
    },
    AttachedFrame {
        attempt: String,
        seq: u64,
        re: u64,
        frame: Vec<u8>,
    },
    AttachedRefusal {
        attempt: String,
        seq: u64,
        re: u64,
        header: String,
        body: Vec<u8>,
    },
    Close {
        attempt: String,
        seq: u64,
        reason: String,
    },
}

/// Why a channel closes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    FrameTooLarge,
    Malformed,
    BadVersion,
    UnknownKind,
    WrongDirection,
    UnknownField(String),
    MissingField(String),
    WrongType(String),
    InvalidField(String),
    BodyTooLarge,
    OutOfOrder,
    UnknownAttempt,
    UnknownReference,
    WrongAnswer,
    CreditExceeded,
}

impl Refusal {
    /// The code a `close` frame carries for this refusal: its own name, or
    /// `malformed` for one naming a member.
    pub fn close_code(&self) -> &'static str {
        match self {
            Refusal::FrameTooLarge => "frame_too_large",
            Refusal::Malformed
            | Refusal::UnknownField(_)
            | Refusal::MissingField(_)
            | Refusal::WrongType(_)
            | Refusal::InvalidField(_) => "malformed",
            Refusal::BadVersion => "bad_version",
            Refusal::UnknownKind => "unknown_kind",
            Refusal::WrongDirection => "wrong_direction",
            Refusal::BodyTooLarge => "body_too_large",
            Refusal::OutOfOrder => "out_of_order",
            Refusal::UnknownAttempt => "unknown_attempt",
            Refusal::UnknownReference => "unknown_reference",
            Refusal::WrongAnswer => "wrong_answer",
            Refusal::CreditExceeded => "credit_exceeded",
        }
    }
}

/// A frame the runner itself holds wrong: the member it names. It is the
/// runner's own data, never the peer's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invalid(pub &'static str);

/// Why a frame the runner would send is not sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unsent {
    /// The channel's state refuses it: an attempt it does not carry, or a
    /// credit for no open fetch.
    Refused(Refusal),
    /// A member no frame carries.
    Invalid(Invalid),
}

/// Why a channel is not bound to the next subtree's attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rebind {
    /// A call or fetch of the last subtree is still outstanding.
    Busy,
    /// An attempt no frame carries.
    Invalid(Invalid),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Pinned,
    Attached,
}

#[derive(Debug, Clone)]
struct Open {
    attempt: String,
    mode: Mode,
    credit: u64,
    headed: bool,
    refused: bool,
}

/// The runner's view of its relay.
#[derive(Debug, Clone)]
pub struct Channel {
    attempts: BTreeSet<String>,
    sent: u64,
    received: u64,
    calls: BTreeMap<u64, String>,
    fetches: BTreeMap<u64, Open>,
}

/// The kinds a runner receives, and their members after `attempt` and
/// `seq`, in wire order; and the kinds it sends, which it never receives.
const RECEIVED: [(&str, &[&str]); 6] = [
    ("host_answer", &["re", "status", "body"]),
    ("fetch_chunk", &["re", "status", "headers", "body"]),
    ("fetch_end", &["re", "error"]),
    ("close", &["reason"]),
    ("attached_frame", &["re", "frame"]),
    ("attached_refusal", &["re", "header", "body"]),
];
const SENT_ONLY: [&str; 3] = ["host_call", "fetch", "credit"];

impl Channel {
    /// The channel as the runner opens it, carrying its assigned `attempt`.
    pub fn new(attempt: &str) -> Result<Self, Invalid> {
        if !is_id(attempt) {
            return Err(Invalid("attempt"));
        }
        Ok(Channel {
            attempts: BTreeSet::from([attempt.to_owned()]),
            sent: 0,
            received: 0,
            calls: BTreeMap::new(),
            fetches: BTreeMap::new(),
        })
    }

    /// The channel carrying `attempt` too: another attempt of the subtree.
    pub fn admit(&mut self, attempt: &str) -> Result<(), Invalid> {
        if !is_id(attempt) {
            return Err(Invalid("attempt"));
        }
        self.attempts.insert(attempt.to_owned());
        Ok(())
    }

    /// The channel carrying `attempt` alone, for the next subtree its
    /// runner is assigned: its numbering goes on, and it is refused while
    /// anything of the last subtree is outstanding.
    pub fn rebind(&mut self, attempt: &str) -> Result<(), Rebind> {
        if !is_id(attempt) {
            return Err(Rebind::Invalid(Invalid("attempt")));
        }
        if !self.idle() {
            return Err(Rebind::Busy);
        }
        self.attempts = BTreeSet::from([attempt.to_owned()]);
        Ok(())
    }

    /// Whether nothing is outstanding: no call unanswered, no fetch open.
    pub fn idle(&self) -> bool {
        self.calls.is_empty() && self.fetches.is_empty()
    }

    /// How many host calls are unanswered.
    pub fn open_calls(&self) -> usize {
        self.calls.len()
    }

    /// How many fetches are open, each until its `fetch_end`.
    pub fn open_fetches(&self) -> usize {
        self.fetches.len()
    }

    /// The attempt the open fetch `re` acts for.
    pub fn fetch_attempt(&self, re: u64) -> Option<&str> {
        self.fetches.get(&re).map(|fetch| fetch.attempt.as_str())
    }

    // ========================================================================
    // Encoding
    // ========================================================================

    /// The bytes of `frame` as the next frame the runner sends, its length
    /// first; the channel takes it only when it is sent. Every copy of a
    /// member made on the way is cleared, and so are the bytes when they
    /// are dropped: a fetch's carry a guest's headers and body.
    pub fn encode(&mut self, frame: &Outgoing) -> Result<Zeroizing<Vec<u8>>, Unsent> {
        // Every member is checked, then what the channel's state takes,
        // before anything changes.
        let seq = self.sent;
        let (attempt, kind, members) = written(frame).map_err(Unsent::Invalid)?;
        if !self.attempts.contains(attempt) {
            return Err(Unsent::Refused(Refusal::UnknownAttempt));
        }
        if let Outgoing::Credit { re, .. } = frame {
            self.open_fetch(*re, attempt).map_err(Unsent::Refused)?;
        }
        // Reserved whole, so the frame is written in place and never moved.
        let head = format!(
            "{{\"v\":{VERSION},\"attempt\":{},\"seq\":{seq},\"kind\":\"{kind}\"",
            json_string(attempt)
        );
        let length = head.len()
            + 1
            + members
                .iter()
                .map(|(name, value)| name.len() + value.len() + 4)
                .sum::<usize>();
        if length > MAX_FRAME_BYTES {
            return Err(Unsent::Invalid(Invalid("frame")));
        }
        let mut json: Zeroizing<Vec<u8>> = Zeroizing::new(Vec::with_capacity(4 + length));
        json.extend_from_slice(
            &u32::try_from(length)
                .expect("a frame is under 4 GiB")
                .to_be_bytes(),
        );
        json.extend_from_slice(head.as_bytes());
        for (name, value) in &members {
            json.extend_from_slice(b",\"");
            json.extend_from_slice(name.as_bytes());
            json.extend_from_slice(b"\":");
            json.extend_from_slice(value.as_bytes());
        }
        json.push(b'}');
        debug_assert_eq!(json.len(), 4 + length);
        match frame {
            Outgoing::HostCall { .. } => {
                self.calls.insert(seq, attempt.to_owned());
            }
            Outgoing::PinnedFetch { .. } | Outgoing::AttachedFetch { .. } => {
                let mode = if matches!(frame, Outgoing::PinnedFetch { .. }) {
                    Mode::Pinned
                } else {
                    Mode::Attached
                };
                let fetch = Open {
                    attempt: attempt.to_owned(),
                    mode,
                    credit: INITIAL_CREDIT,
                    headed: false,
                    refused: false,
                };
                self.fetches.insert(seq, fetch);
            }
            Outgoing::Credit { re, bytes, .. } => {
                let fetch = self.open_fetch(*re, attempt).map_err(Unsent::Refused)?;
                fetch.credit = fetch.credit.saturating_add(*bytes).min(MAX_INTEGER);
            }
            Outgoing::Close { .. } => {}
        }
        self.sent += 1;
        Ok(json)
    }

    // ========================================================================
    // Decoding
    // ========================================================================

    /// The complete frames at the head of `buffer`, in order, and how many
    /// bytes they spanned; the bytes after them wait for more. Or the first
    /// reason the channel closes.
    pub fn decode(&mut self, buffer: &[u8]) -> Result<(Vec<Incoming>, usize), Refusal> {
        let mut frames = Vec::new();
        let mut at = 0;
        while let Some(prefix) = buffer.get(at..at + 4) {
            let length = u32::from_be_bytes(prefix.try_into().expect("four bytes")) as usize;
            if length > MAX_FRAME_BYTES {
                return Err(Refusal::FrameTooLarge);
            }
            let Some(json) = buffer.get(at + 4..at + 4 + length) else {
                break;
            };
            let frame = self.read_frame(json)?;
            self.step(&frame)?;
            self.received += 1;
            frames.push(frame);
            at += 4 + length;
        }
        Ok((frames, at))
    }

    fn read_frame(&self, json: &[u8]) -> Result<Incoming, Refusal> {
        let json = parse(json).ok_or(Refusal::Malformed)?;
        let Value::Object(object) = json.value() else {
            return Err(Refusal::Malformed);
        };
        if object.get("v").and_then(integer) != Some(Integer::Whole(VERSION)) {
            return Err(Refusal::BadVersion);
        }
        let kind = object
            .get("kind")
            .and_then(Value::as_str)
            .ok_or(Refusal::UnknownKind)?;
        let Some((kind, members)) = RECEIVED.iter().find(|(name, _)| *name == kind) else {
            return Err(if SENT_ONLY.contains(&kind) {
                Refusal::WrongDirection
            } else {
                Refusal::UnknownKind
            });
        };
        let read = Reader(object);
        if let Some(unknown) = object.keys().find(|key| {
            !matches!(key.as_str(), "v" | "kind" | "attempt" | "seq")
                && !members.contains(&key.as_str())
        }) {
            return Err(Refusal::UnknownField(unknown.clone()));
        }
        let attempt = read.id("attempt")?;
        let seq = read.seq("seq")?;
        // Each kind's members, in order.
        let frame = match *kind {
            "host_answer" => Incoming::HostAnswer {
                attempt,
                seq,
                re: read.seq("re")?,
                status: read.nullable("status", |r, n| r.status(n))?,
                body: read.body("body")?,
            },
            "fetch_chunk" => Incoming::FetchChunk {
                attempt,
                seq,
                re: read.seq("re")?,
                status: read.nullable("status", |r, n| r.status(n))?,
                headers: read.nullable("headers", |r, n| r.headers(n))?,
                body: read.body("body")?,
            },
            "fetch_end" => Incoming::FetchEnd {
                attempt,
                seq,
                re: read.seq("re")?,
                error: read.nullable("error", |r, n| r.code(n))?,
            },
            "close" => Incoming::Close {
                attempt,
                seq,
                reason: read.code("reason")?,
            },
            "attached_frame" => Incoming::AttachedFrame {
                attempt,
                seq,
                re: read.seq("re")?,
                frame: read.frame("frame")?,
            },
            _attached_refusal => Incoming::AttachedRefusal {
                attempt,
                seq,
                re: read.seq("re")?,
                header: read.signed_header("header")?,
                body: read.body("body")?,
            },
        };
        if seq != self.received {
            return Err(Refusal::OutOfOrder);
        }
        Ok(frame)
    }

    // One received frame's effect on the channel: an answer closes the call
    // it names, a chunk or frame spends its fetch's credit, an end closes it.
    fn step(&mut self, frame: &Incoming) -> Result<(), Refusal> {
        let attempt = match frame {
            Incoming::HostAnswer { attempt, .. }
            | Incoming::FetchChunk { attempt, .. }
            | Incoming::FetchEnd { attempt, .. }
            | Incoming::AttachedFrame { attempt, .. }
            | Incoming::AttachedRefusal { attempt, .. }
            | Incoming::Close { attempt, .. } => attempt,
        };
        if !self.attempts.contains(attempt) {
            return Err(Refusal::UnknownAttempt);
        }
        match frame {
            Incoming::HostAnswer { re, attempt, .. } => match self.calls.get(re) {
                Some(caller) if caller == attempt => {
                    self.calls.remove(re);
                    Ok(())
                }
                Some(_other) => Err(Refusal::UnknownAttempt),
                None => Err(Refusal::UnknownReference),
            },
            Incoming::FetchChunk {
                re,
                attempt,
                status,
                headers,
                body,
                ..
            } => {
                let fetch = self.open_fetch(*re, attempt)?;
                if fetch.mode != Mode::Pinned {
                    return Err(Refusal::WrongAnswer);
                }
                // The first chunk carries the answer's status and headers,
                // and no later one does.
                let head = status.is_some() && headers.is_some();
                let none = status.is_none() && headers.is_none();
                if (fetch.headed && !none) || (!fetch.headed && !head) {
                    return Err(Refusal::InvalidField("status".to_owned()));
                }
                spend(fetch, body.len())?;
                fetch.headed = true;
                Ok(())
            }
            Incoming::FetchEnd { re, attempt, .. } => {
                self.open_fetch(*re, attempt)?;
                self.fetches.remove(re);
                Ok(())
            }
            Incoming::AttachedFrame {
                re, attempt, frame, ..
            } => {
                let fetch = self.open_fetch(*re, attempt)?;
                if fetch.mode != Mode::Attached || fetch.refused {
                    return Err(Refusal::WrongAnswer);
                }
                spend(fetch, frame.len())?;
                fetch.headed = true;
                Ok(())
            }
            Incoming::AttachedRefusal { re, attempt, .. } => {
                let fetch = self.open_fetch(*re, attempt)?;
                if fetch.mode != Mode::Attached || fetch.refused || fetch.headed {
                    return Err(Refusal::WrongAnswer);
                }
                fetch.refused = true;
                Ok(())
            }
            Incoming::Close { .. } => Ok(()),
        }
    }

    fn open_fetch(&mut self, re: u64, attempt: &str) -> Result<&mut Open, Refusal> {
        match self.fetches.get_mut(&re) {
            Some(fetch) if fetch.attempt == attempt => Ok(fetch),
            Some(_other) => Err(Refusal::UnknownAttempt),
            None => Err(Refusal::UnknownReference),
        }
    }
}

fn spend(fetch: &mut Open, bytes: usize) -> Result<(), Refusal> {
    let bytes = bytes as u64;
    if bytes > fetch.credit {
        return Err(Refusal::CreditExceeded);
    }
    fetch.credit -= bytes;
    Ok(())
}

/// A frame's members as written: each name and its JSON, in wire order,
/// cleared when dropped.
type Members = Vec<(&'static str, Zeroizing<String>)>;

/// A frame's attempt, kind and members as written, in wire order.
fn written(frame: &Outgoing) -> Result<(&str, &'static str, Members), Invalid> {
    let attempt = match frame {
        Outgoing::HostCall { attempt, .. }
        | Outgoing::PinnedFetch { attempt, .. }
        | Outgoing::AttachedFetch { attempt, .. }
        | Outgoing::Credit { attempt, .. }
        | Outgoing::Close { attempt, .. } => attempt,
    };
    check(is_id(attempt), "attempt")?;
    Ok(match frame {
        Outgoing::HostCall {
            op, header, body, ..
        } => {
            check(signed_header(header), "header")?;
            (
                attempt,
                "host_call",
                vec![
                    ("op", text(op.name())),
                    ("header", text(header)),
                    ("body", body_text(body)?),
                ],
            )
        }
        Outgoing::PinnedFetch {
            pin,
            method,
            path,
            headers,
            body,
            ..
        } => {
            check(is_pin(pin), "pin")?;
            check(METHODS.contains(&method.as_str()), "method")?;
            check(is_path(path), "path")?;
            (
                attempt,
                "fetch",
                vec![
                    ("pin", text(pin)),
                    ("method", text(method)),
                    ("path", text(path)),
                    ("headers", headers_text(headers)?),
                    ("body", body_text(body)?),
                ],
            )
        }
        Outgoing::AttachedFetch {
            call_id,
            connection,
            purpose,
            method,
            url,
            headers,
            body,
            ..
        } => {
            check(is_call_id(call_id), "call_id")?;
            check(is_connection(connection), "connection")?;
            check(PURPOSES.contains(&purpose.as_str()), "purpose")?;
            check(METHODS.contains(&method.as_str()), "method")?;
            check(
                url.len() <= MAX_URL_BYTES && crate::wire::is_text(url) && is_url(url),
                "url",
            )?;
            (
                attempt,
                "fetch",
                vec![
                    ("call_id", text(call_id)),
                    ("connection", text(connection)),
                    ("purpose", text(purpose)),
                    ("method", text(method)),
                    ("url", text(url)),
                    ("headers", headers_text(headers)?),
                    ("body", body_text(body)?),
                ],
            )
        }
        Outgoing::Credit { re, bytes, .. } => {
            check(*re <= MAX_INTEGER, "re")?;
            check((1..=MAX_BODY_BYTES as u64).contains(bytes), "bytes")?;
            (
                attempt,
                "credit",
                vec![
                    ("re", Zeroizing::new(re.to_string())),
                    ("bytes", Zeroizing::new(bytes.to_string())),
                ],
            )
        }
        Outgoing::Close { reason, .. } => {
            check(is_code(reason), "reason")?;
            (attempt, "close", vec![("reason", text(reason))])
        }
    })
}

/// `value` as a JSON string, written in place as `crate::wire::json_string`
/// writes it, and cleared when dropped.
fn text(value: &str) -> Zeroizing<String> {
    let mut written = Zeroizing::new(String::with_capacity(json_length(value)));
    escape_into(value, &mut written);
    written
}

// How long `value` is as a JSON string.
fn json_length(value: &str) -> usize {
    2 + value
        .chars()
        .map(|c| match c {
            '"' | '\\' | '\u{08}' | '\t' | '\n' | '\u{0c}' | '\r' => 2,
            c if (c as u32) < 0x20 => 6,
            c => c.len_utf8(),
        })
        .sum::<usize>()
}

// `value` as a JSON string, escaped as serde_json escapes one.
fn escape_into(value: &str, out: &mut String) {
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{0c}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => {
                out.push_str("\\u00");
                out.push(char::from(b"0123456789abcdef"[(c as usize) >> 4]));
                out.push(char::from(b"0123456789abcdef"[(c as usize) & 0xf]));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn check(valid: bool, member: &'static str) -> Result<(), Invalid> {
    if valid { Ok(()) } else { Err(Invalid(member)) }
}

/// A pin's id: 1 to 128 letters, digits, `_` or `-`.
fn is_pin(text: &str) -> bool {
    (1..=128).contains(&text.len())
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// A path and query, from `/`, of printable ASCII without spaces.
fn is_path(text: &str) -> bool {
    text.len() <= MAX_PATH_BYTES
        && text
            .strip_prefix('/')
            .is_some_and(|rest| rest.bytes().all(|b| (0x21..=0x7e).contains(&b)))
}

/// A call id: 16 bytes as unpadded base64url, spelled as encoding them
/// spells them.
fn is_call_id(text: &str) -> bool {
    text.len() == 22
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        && decode_base64url(text)
            .is_some_and(|bytes| bytes.len() == 16 && encode_base64url(&bytes) == text)
}

/// The need an attached fetch is made on: a lowercase letter, then up to
/// 31 lowercase letters, digits, `_` or `-`.
fn is_connection(text: &str) -> bool {
    let bytes = text.as_bytes();
    (1..=32).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_' || *b == b'-')
}

fn signed_header(text: &str) -> bool {
    text.len() <= MAX_SIGNED_HEADER_BYTES && is_signed_header(text)
}

fn body_text(body: &[u8]) -> Result<Zeroizing<String>, Invalid> {
    if body.len() > MAX_BODY_BYTES {
        return Err(Invalid("body"));
    }
    // Base64 needs no escaping: it is quoted as it is written.
    let mut written = Zeroizing::new(String::with_capacity(body.len().div_ceil(3) * 4 + 2));
    written.push('"');
    crate::wire::encode_base64_into(body, &mut written);
    written.push('"');
    Ok(written)
}

fn headers_text(headers: &[Header]) -> Result<Zeroizing<String>, Invalid> {
    check(
        headers.len() <= MAX_HEADERS
            && headers
                .iter()
                .all(|(name, value)| is_header_name(name) && is_header_value(value)),
        "headers",
    )?;
    let length = 2 + headers
        .iter()
        .map(|(name, value)| json_length(name) + json_length(value) + 4)
        .sum::<usize>();
    let mut written = Zeroizing::new(String::with_capacity(length));
    written.push('[');
    for (index, (name, value)) in headers.iter().enumerate() {
        if index > 0 {
            written.push(',');
        }
        written.push('[');
        escape_into(name, &mut written);
        written.push(',');
        escape_into(value, &mut written);
        written.push(']');
    }
    written.push(']');
    Ok(written)
}

/// A code: a lowercase letter, then up to 63 lowercase letters, digits or `_`.
pub fn is_code(text: &str) -> bool {
    let bytes = text.as_bytes();
    (1..=64).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_')
}

/// A signed header's text: printable ASCII, spaces included.
fn is_signed_header(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| (0x20..=0x7e).contains(&b))
}

/// A header name: an HTTP token.
fn is_header_name(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= MAX_HEADER_NAME_BYTES
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
}

/// A header value: no control character but a tab.
fn is_header_value(text: &str) -> bool {
    text.len() <= MAX_HEADER_VALUE_BYTES && !text.chars().any(|c| c.is_ascii_control() && c != '\t')
}

/// A received frame's members, each refusal naming its member.
struct Reader<'a>(&'a Map<String, Value>);

impl Reader<'_> {
    fn member(&self, name: &str) -> Result<&Value, Refusal> {
        self.0
            .get(name)
            .ok_or_else(|| Refusal::MissingField(name.to_owned()))
    }

    fn nullable<T>(
        &self,
        name: &str,
        read: impl Fn(&Self, &str) -> Result<T, Refusal>,
    ) -> Result<Option<T>, Refusal> {
        if self.member(name)?.is_null() {
            Ok(None)
        } else {
            read(self, name).map(Some)
        }
    }

    fn string(&self, name: &str) -> Result<&str, Refusal> {
        self.member(name)?
            .as_str()
            .ok_or_else(|| Refusal::WrongType(name.to_owned()))
    }

    fn matching(&self, name: &str, valid: impl Fn(&str) -> bool) -> Result<String, Refusal> {
        let value = self.string(name)?;
        if valid(value) {
            Ok(value.to_owned())
        } else {
            Err(Refusal::InvalidField(name.to_owned()))
        }
    }

    fn id(&self, name: &str) -> Result<String, Refusal> {
        self.matching(name, is_id)
    }

    fn code(&self, name: &str) -> Result<String, Refusal> {
        self.matching(name, is_code)
    }

    fn signed_header(&self, name: &str) -> Result<String, Refusal> {
        self.matching(name, |text| {
            text.len() <= MAX_SIGNED_HEADER_BYTES && is_signed_header(text)
        })
    }

    fn integer(&self, name: &str, range: std::ops::RangeInclusive<u64>) -> Result<u64, Refusal> {
        bounded(self.member(name)?, range).map_err(|integer| {
            if integer {
                Refusal::InvalidField(name.to_owned())
            } else {
                Refusal::WrongType(name.to_owned())
            }
        })
    }

    fn seq(&self, name: &str) -> Result<u64, Refusal> {
        self.integer(name, 0..=MAX_INTEGER)
    }

    fn status(&self, name: &str) -> Result<u16, Refusal> {
        self.integer(name, 100..=599)
            .map(|status| u16::try_from(status).expect("a status is under 600"))
    }

    // A text longer than the largest body's base64 is too large before it
    // is decoded.
    fn body(&self, name: &str) -> Result<Vec<u8>, Refusal> {
        let text = self.string(name)?;
        if text.len() > MAX_BODY_BYTES.div_ceil(3) * 4 {
            return Err(Refusal::BodyTooLarge);
        }
        let bytes = decode_base64(text).ok_or_else(|| Refusal::InvalidField(name.to_owned()))?;
        if bytes.len() > MAX_BODY_BYTES {
            return Err(Refusal::BodyTooLarge);
        }
        Ok(bytes)
    }

    // A kind byte and a sealed value: at least two bytes.
    fn frame(&self, name: &str) -> Result<Vec<u8>, Refusal> {
        let text = self.string(name)?;
        let invalid = || Refusal::InvalidField(name.to_owned());
        if text.len() > MAX_ATTACHED_FRAME_BYTES.div_ceil(3) * 4 {
            return Err(invalid());
        }
        match decode_base64(text) {
            Some(bytes) if (2..=MAX_ATTACHED_FRAME_BYTES).contains(&bytes.len()) => Ok(bytes),
            _ => Err(invalid()),
        }
    }

    fn headers(&self, name: &str) -> Result<Vec<Header>, Refusal> {
        let Value::Array(values) = self.member(name)? else {
            return Err(Refusal::WrongType(name.to_owned()));
        };
        let invalid = || Refusal::InvalidField(name.to_owned());
        if values.len() > MAX_HEADERS {
            return Err(invalid());
        }
        values
            .iter()
            .map(|pair| match pair.as_array().map(Vec::as_slice) {
                Some([Value::String(header), Value::String(value)])
                    if is_header_name(header) && is_header_value(value) =>
                {
                    Ok((header.clone(), value.clone()))
                }
                _ => Err(invalid()),
            })
            .collect()
    }
}

// ============================================================================
// The runner's end
// ============================================================================

/// The runner's end of its relay, over the stream its keeper (descriptor 4)
/// or the test build's direct launcher (a unix socket) gives it: one task
/// that owns the `Channel` and reads, one that writes, and a handle every
/// host call and fetch of the runner's subtree goes through.
///
/// The relay has no cancel for a call or a fetch (section 5.5 of the plan):
/// a call whose caller stopped waiting stays outstanding on the channel
/// until its answer arrives, which is then discarded; a fetch whose owner
/// dropped it (`Fetch`) drains: it is granted back what it received and
/// was not granted, then each chunk or frame as it arrives, until its
/// `fetch_end`. The channel is not idle meanwhile. A host call past
/// `MAX_CALLS` unanswered waits for an answer to free its room, and a fetch
/// past `MAX_FETCHES` open is refused (`Unfetched::Busy`): the service
/// closes the channel for either. A frame the codec refuses is answered
/// with a `close` naming its code; that, the service's own `close`, the
/// stream's end or a failed write closes the relay: every call still
/// waiting is answered as lost, every fetch still open hears that it
/// ended (`FetchEvent::Closed`), and `closed` says so, which ends the
/// runner.
#[derive(Clone)]
pub struct Relay {
    commands: tokio::sync::mpsc::UnboundedSender<Command>,
    closed: tokio::sync::watch::Receiver<bool>,
}

enum Command {
    Bind {
        attempt: String,
        reply: tokio::sync::oneshot::Sender<Result<(), Rebind>>,
    },
    Call {
        attempt: String,
        op: Op,
        header: String,
        body: Vec<u8>,
        reply: tokio::sync::oneshot::Sender<Option<crate::host::Reached>>,
    },
    Idle {
        reply: tokio::sync::oneshot::Sender<bool>,
    },
    Fetch {
        frame: Outgoing,
        reply: tokio::sync::oneshot::Sender<Result<Fetch, Unfetched>>,
    },
    Room {
        reply: tokio::sync::oneshot::Sender<bool>,
    },
    Credit {
        re: u64,
        bytes: u64,
    },
    Abandon {
        re: u64,
    },
}

/// What the owner of a fetch hears of it, in order: its answer, then its
/// end.
pub enum FetchEvent {
    /// A pinned fetch's first chunk: the answer's status and headers, and
    /// the first of its body.
    Head {
        status: u16,
        headers: Vec<Header>,
        body: Zeroizing<Vec<u8>>,
    },
    /// The next bytes of a pinned fetch's answer body.
    Chunk(Zeroizing<Vec<u8>>),
    /// One of an attached fetch's sealed answer frames, its kind byte and
    /// sealed value.
    Frame(Zeroizing<Vec<u8>>),
    /// CYFR's refusal of an attached fetch: the call's signed header and
    /// its sealed answer.
    Refusal { header: String, body: Vec<u8> },
    /// The fetch's end: none for an answer delivered whole, or the code
    /// the service ended it with.
    End(Option<String>),
    /// The relay closed before the fetch's end.
    Closed,
}

/// Why a fetch was not sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unfetched {
    /// `MAX_FETCHES` are open.
    Busy,
    /// A member no frame carries.
    Invalid(Invalid),
    /// The relay is closed, or carries no attempt yet.
    Closed,
}

/// A fetch the runner sent: what its owner hears of it, and the credit it
/// grants back as it reads. Dropped before its end, the fetch drains.
pub struct Fetch {
    re: u64,
    events: tokio::sync::mpsc::UnboundedReceiver<FetchEvent>,
    commands: tokio::sync::mpsc::UnboundedSender<Command>,
    ended: bool,
}

impl Fetch {
    /// The next event of the fetch: `Closed` once the relay has closed.
    pub async fn next(&mut self) -> FetchEvent {
        let event = self.events.recv().await.unwrap_or(FetchEvent::Closed);
        self.ended |= matches!(event, FetchEvent::End(_) | FetchEvent::Closed);
        event
    }

    /// Grant the service `bytes` more of the answer: the bytes the owner
    /// has read. The relay grants no more than the fetch has received.
    pub fn grant(&self, bytes: usize) {
        if bytes > 0 {
            let _ = self.commands.send(Command::Credit {
                re: self.re,
                bytes: bytes as u64,
            });
        }
    }
}

impl Drop for Fetch {
    fn drop(&mut self) {
        if !self.ended {
            let _ = self.commands.send(Command::Abandon { re: self.re });
        }
    }
}

/// The most bytes one read takes from the stream.
const READ_BYTES: usize = 64 * 1024;

impl Relay {
    /// Start the runner's end on `reader` and `writer`, the stream's two
    /// halves, on the current Tokio runtime.
    pub fn start<R, W>(reader: R, writer: W) -> Relay
    where
        R: tokio::io::AsyncRead + Unpin + Send + 'static,
        W: tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        let (commands, inbox) = tokio::sync::mpsc::unbounded_channel();
        let (closed_tx, closed) = tokio::sync::watch::channel(false);
        let (bytes, outbox) = tokio::sync::mpsc::unbounded_channel::<Zeroizing<Vec<u8>>>();
        let (write_failed_tx, write_failed) = tokio::sync::oneshot::channel::<()>();
        tokio::spawn(write_frames(writer, outbox, write_failed_tx));
        tokio::spawn(serve(
            reader,
            inbox,
            commands.clone(),
            bytes,
            write_failed,
            closed_tx,
        ));
        Relay { commands, closed }
    }

    /// Carry `attempt` alone, for the subtree it roots; refused while the
    /// last subtree's work is outstanding.
    pub async fn bind(&self, attempt: &str) -> Result<(), Rebind> {
        let (reply, answer) = tokio::sync::oneshot::channel();
        let command = Command::Bind {
            attempt: attempt.to_owned(),
            reply,
        };
        if self.commands.send(command).is_err() {
            return Err(Rebind::Busy);
        }
        answer.await.unwrap_or(Err(Rebind::Busy))
    }

    /// Whether nothing is outstanding on the channel.
    pub async fn idle(&self) -> bool {
        let (reply, answer) = tokio::sync::oneshot::channel();
        if self.commands.send(Command::Idle { reply }).is_err() {
            return false;
        }
        answer.await.unwrap_or(false)
    }

    /// Whether another fetch may be sent now: fewer than `MAX_FETCHES` are
    /// open on an open relay.
    pub async fn room(&self) -> bool {
        let (reply, answer) = tokio::sync::oneshot::channel();
        if self.commands.send(Command::Room { reply }).is_err() {
            return false;
        }
        answer.await.unwrap_or(false)
    }

    /// Send `frame`, a pinned or an attached fetch, and own it.
    pub async fn fetch(&self, frame: Outgoing) -> Result<Fetch, Unfetched> {
        debug_assert!(matches!(
            frame,
            Outgoing::PinnedFetch { .. } | Outgoing::AttachedFetch { .. }
        ));
        let (reply, answer) = tokio::sync::oneshot::channel();
        if self.commands.send(Command::Fetch { frame, reply }).is_err() {
            return Err(Unfetched::Closed);
        }
        answer.await.unwrap_or(Err(Unfetched::Closed))
    }

    /// Wait until the relay is closed.
    pub async fn closed(&self) {
        let mut closed = self.closed.clone();
        let _ = closed.wait_for(|closed| *closed).await;
    }

    /// The poster of `attempt`'s host calls through this relay.
    pub fn poster(&self, attempt: &str) -> Poster {
        Poster {
            relay: self.clone(),
            attempt: attempt.to_owned(),
        }
    }
}

/// One attempt's host calls, posted through the relay (`crate::host::Post`).
pub struct Poster {
    relay: Relay,
    attempt: String,
}

impl crate::host::Post for Poster {
    fn post(
        &mut self,
        op: Op,
        header: String,
        body: Vec<u8>,
    ) -> impl std::future::Future<Output = Option<crate::host::Reached>> {
        let (reply, answer) = tokio::sync::oneshot::channel();
        let sent = self
            .relay
            .commands
            .send(Command::Call {
                attempt: self.attempt.clone(),
                op,
                header,
                body,
                reply,
            })
            .is_ok();
        async move {
            if sent {
                answer.await.ok().flatten()
            } else {
                None
            }
        }
    }
}

async fn write_frames<W>(
    mut writer: W,
    mut outbox: tokio::sync::mpsc::UnboundedReceiver<Zeroizing<Vec<u8>>>,
    failed: tokio::sync::oneshot::Sender<()>,
) where
    W: tokio::io::AsyncWrite + Unpin,
{
    use tokio::io::AsyncWriteExt as _;
    while let Some(bytes) = outbox.recv().await {
        if writer.write_all(&bytes).await.is_err() || writer.flush().await.is_err() {
            let _ = failed.send(());
            return;
        }
    }
}

/// A fetch as its owner holds it in the relay: where its events go (none
/// once its owner dropped it, and it drains), and how much of its answer it
/// received and was granted back.
struct Owned {
    events: Option<tokio::sync::mpsc::UnboundedSender<FetchEvent>>,
    received: u64,
    granted: u64,
}

/// What the relay's task holds.
struct Serving {
    channel: Option<Channel>,
    root: String,
    waiting: BTreeMap<u64, tokio::sync::oneshot::Sender<Option<crate::host::Reached>>>,
    /// Calls past `MAX_CALLS` unanswered, in the order made.
    queued: VecDeque<Command>,
    owned: BTreeMap<u64, Owned>,
    commands: tokio::sync::mpsc::UnboundedSender<Command>,
    outbox: tokio::sync::mpsc::UnboundedSender<Zeroizing<Vec<u8>>>,
}

/// Why the relay closes.
struct Ends;

impl Serving {
    fn send(&mut self, bytes: Zeroizing<Vec<u8>>) -> Result<(), Ends> {
        self.outbox.send(bytes).map_err(|_| Ends)
    }

    fn call(
        &mut self,
        attempt: String,
        op: Op,
        header: String,
        body: Vec<u8>,
        reply: tokio::sync::oneshot::Sender<Option<crate::host::Reached>>,
    ) -> Result<(), Ends> {
        let Some(open) = self.channel.as_mut() else {
            let _ = reply.send(None);
            return Ok(());
        };
        if open.open_calls() >= MAX_CALLS {
            self.queued.push_back(Command::Call {
                attempt,
                op,
                header,
                body,
                reply,
            });
            return Ok(());
        }
        let seq = open.sent;
        let frame = Outgoing::HostCall {
            attempt,
            op,
            header,
            body,
        };
        match open.encode(&frame) {
            Ok(bytes) => {
                self.waiting.insert(seq, reply);
                self.send(bytes)
            }
            Err(_unsent) => {
                let _ = reply.send(None);
                Ok(())
            }
        }
    }

    fn fetch(
        &mut self,
        frame: Outgoing,
        reply: tokio::sync::oneshot::Sender<Result<Fetch, Unfetched>>,
    ) -> Result<(), Ends> {
        let Some(open) = self.channel.as_mut() else {
            let _ = reply.send(Err(Unfetched::Closed));
            return Ok(());
        };
        if open.open_fetches() >= MAX_FETCHES {
            let _ = reply.send(Err(Unfetched::Busy));
            return Ok(());
        }
        let re = open.sent;
        let bytes = match open.encode(&frame) {
            Ok(bytes) => bytes,
            Err(Unsent::Invalid(invalid)) => {
                let _ = reply.send(Err(Unfetched::Invalid(invalid)));
                return Ok(());
            }
            Err(Unsent::Refused(_)) => {
                let _ = reply.send(Err(Unfetched::Closed));
                return Ok(());
            }
        };
        drop(frame);
        let (events, receiver) = tokio::sync::mpsc::unbounded_channel();
        let fetch = Fetch {
            re,
            events: receiver,
            commands: self.commands.clone(),
            ended: false,
        };
        self.owned.insert(
            re,
            Owned {
                events: Some(events),
                received: 0,
                granted: 0,
            },
        );
        // An owner gone before it heard of its fetch drains it.
        if let Err(unsent) = reply.send(Ok(fetch)) {
            drop(unsent);
        }
        self.send(bytes)
    }

    // Grant back up to `bytes` of what the fetch `re` received and was not
    // granted, in credits of at most `MAX_BODY_BYTES`.
    fn grant(&mut self, re: u64, bytes: u64) -> Result<(), Ends> {
        let (Some(open), Some(owned)) = (self.channel.as_mut(), self.owned.get_mut(&re)) else {
            return Ok(());
        };
        let Some(attempt) = open.fetch_attempt(re).map(str::to_owned) else {
            return Ok(());
        };
        let mut left = bytes.min(owned.received - owned.granted);
        while left > 0 {
            let piece = left.min(MAX_BODY_BYTES as u64);
            let credit = Outgoing::Credit {
                attempt: attempt.clone(),
                re,
                bytes: piece,
            };
            let Ok(frame) = open.encode(&credit) else {
                return Ok(());
            };
            owned.granted += piece;
            left -= piece;
            self.outbox.send(frame).map_err(|_| Ends)?;
        }
        Ok(())
    }

    // The owner of `re` dropped it: it drains.
    fn abandon(&mut self, re: u64) -> Result<(), Ends> {
        if let Some(owned) = self.owned.get_mut(&re) {
            owned.events = None;
            let outstanding = owned.received - owned.granted;
            return self.grant(re, outstanding);
        }
        Ok(())
    }

    // A frame of the fetch `re`, `bytes` of its credit: handed to its owner,
    // or granted back at once when it drains.
    fn deliver(&mut self, re: u64, bytes: usize, event: FetchEvent) -> Result<(), Ends> {
        let Some(owned) = self.owned.get_mut(&re) else {
            return Ok(());
        };
        owned.received += bytes as u64;
        let handed = owned
            .events
            .as_ref()
            .is_some_and(|events| events.send(event).is_ok());
        if !handed {
            return self.abandon(re);
        }
        Ok(())
    }

    // The frames decoded from the service, in order; whether the service
    // closed the channel.
    fn received(&mut self, frames: Vec<Incoming>) -> Result<bool, Ends> {
        for frame in frames {
            match frame {
                Incoming::HostAnswer {
                    re, status, body, ..
                } => {
                    if let Some(reply) = self.waiting.remove(&re) {
                        let _ =
                            reply.send(status.map(|status| crate::host::Reached { status, body }));
                    }
                }
                Incoming::FetchChunk {
                    re,
                    status,
                    headers,
                    body,
                    ..
                } => {
                    let bytes = body.len();
                    let body = Zeroizing::new(body);
                    let event = match (status, headers) {
                        (Some(status), Some(headers)) => FetchEvent::Head {
                            status,
                            headers,
                            body,
                        },
                        _ => FetchEvent::Chunk(body),
                    };
                    self.deliver(re, bytes, event)?;
                }
                Incoming::AttachedFrame { re, frame, .. } => {
                    let bytes = frame.len();
                    self.deliver(re, bytes, FetchEvent::Frame(Zeroizing::new(frame)))?;
                }
                Incoming::AttachedRefusal {
                    re, header, body, ..
                } => {
                    self.deliver(re, 0, FetchEvent::Refusal { header, body })?;
                }
                Incoming::FetchEnd { re, error, .. } => {
                    if let Some(owned) = self.owned.remove(&re)
                        && let Some(events) = owned.events
                    {
                        let _ = events.send(FetchEvent::End(error));
                    }
                }
                Incoming::Close { .. } => return Ok(true),
            }
        }
        // An answer frees room for the calls that wait for it.
        while self
            .channel
            .as_ref()
            .is_some_and(|open| open.open_calls() < MAX_CALLS)
        {
            let Some(Command::Call {
                attempt,
                op,
                header,
                body,
                reply,
            }) = self.queued.pop_front()
            else {
                break;
            };
            self.call(attempt, op, header, body, reply)?;
        }
        Ok(false)
    }
}

async fn serve<R>(
    mut reader: R,
    mut inbox: tokio::sync::mpsc::UnboundedReceiver<Command>,
    commands: tokio::sync::mpsc::UnboundedSender<Command>,
    outbox: tokio::sync::mpsc::UnboundedSender<Zeroizing<Vec<u8>>>,
    mut write_failed: tokio::sync::oneshot::Receiver<()>,
    closed: tokio::sync::watch::Sender<bool>,
) where
    R: tokio::io::AsyncRead + Unpin,
{
    use tokio::io::AsyncReadExt as _;
    let mut serving = Serving {
        channel: None,
        root: String::new(),
        waiting: BTreeMap::new(),
        queued: VecDeque::new(),
        owned: BTreeMap::new(),
        commands,
        outbox,
    };
    // What arrives is a fetch's answer as well as CYFR's sealed ones: the
    // buffer is reserved once for the largest frame and a read beside it,
    // so it never moves, and the room a decoded frame leaves is cleared.
    let mut buffer = Reading::new();
    loop {
        tokio::select! {
            command = inbox.recv() => {
                let Some(command) = command else { break };
                let done = match command {
                    Command::Bind { attempt, reply } => {
                        let bound = match serving.channel.as_mut() {
                            None => Channel::new(&attempt)
                                .map(|opened| serving.channel = Some(opened))
                                .map_err(Rebind::Invalid),
                            Some(open) => open.rebind(&attempt),
                        };
                        if bound.is_ok() {
                            serving.root = attempt;
                        }
                        let _ = reply.send(bound);
                        Ok(())
                    }
                    Command::Idle { reply } => {
                        let _ = reply.send(serving.channel.as_ref().is_none_or(Channel::idle));
                        Ok(())
                    }
                    Command::Room { reply } => {
                        let room = serving
                            .channel
                            .as_ref()
                            .is_some_and(|open| open.open_fetches() < MAX_FETCHES);
                        let _ = reply.send(room);
                        Ok(())
                    }
                    Command::Call { attempt, op, header, body, reply } => {
                        serving.call(attempt, op, header, body, reply)
                    }
                    Command::Fetch { frame, reply } => serving.fetch(frame, reply),
                    Command::Credit { re, bytes } => serving.grant(re, bytes),
                    Command::Abandon { re } => serving.abandon(re),
                };
                if done.is_err() {
                    break;
                }
            }
            read = reader.read(buffer.room()) => {
                let read = match read {
                    Ok(0) | Err(_) => break,
                    Ok(read) => read,
                };
                buffer.took(read);
                let Some(open) = serving.channel.as_mut() else {
                    // Nothing is sent to a runner before its first
                    // assignment binds the channel.
                    break;
                };
                match open.decode(buffer.held()) {
                    Ok((frames, used)) => {
                        buffer.consume(used);
                        match serving.received(frames) {
                            Ok(false) => {}
                            Ok(true) | Err(Ends) => break,
                        }
                    }
                    Err(refusal) => {
                        let close = Outgoing::Close {
                            attempt: serving.root.clone(),
                            reason: refusal.close_code().to_owned(),
                        };
                        if let Ok(bytes) = open.encode(&close) {
                            let _ = serving.outbox.send(bytes);
                        }
                        break;
                    }
                }
            }
            _ = &mut write_failed => break,
        }
    }
    // Every call still waiting hears that no answer will come, and every
    // fetch still open that it has ended.
    for (_seq, reply) in std::mem::take(&mut serving.waiting) {
        let _ = reply.send(None);
    }
    for queued in std::mem::take(&mut serving.queued) {
        if let Command::Call { reply, .. } = queued {
            let _ = reply.send(None);
        }
    }
    serving.owned.clear();
    drop(buffer);
    let _ = closed.send(true);
    // Commands sent after the close are answered as the closed relay's.
    inbox.close();
    while let Some(command) = inbox.recv().await {
        match command {
            Command::Bind { reply, .. } => {
                let _ = reply.send(Err(Rebind::Busy));
            }
            Command::Idle { reply } | Command::Room { reply } => {
                let _ = reply.send(false);
            }
            Command::Call { reply, .. } => {
                let _ = reply.send(None);
            }
            Command::Fetch { reply, .. } => {
                let _ = reply.send(Err(Unfetched::Closed));
            }
            Command::Credit { .. } | Command::Abandon { .. } => {}
        }
    }
}

/// The relay's read buffer: reserved once for the largest frame and one
/// read beside it, so it never moves; a decoded frame's room is cleared as
/// the bytes after it move down, and what is still written is cleared when
/// it is dropped.
struct Reading {
    bytes: Vec<u8>,
    /// How many bytes at its head hold what was read and not yet decoded.
    held: usize,
}

impl Reading {
    fn new() -> Reading {
        Reading {
            bytes: Vec::with_capacity(4 + MAX_FRAME_BYTES + READ_BYTES),
            held: 0,
        }
    }

    // Room for one read after what is held, written in place.
    fn room(&mut self) -> &mut [u8] {
        let end = self.held + READ_BYTES;
        if self.bytes.len() < end {
            self.bytes.resize(end, 0);
        }
        &mut self.bytes[self.held..end]
    }

    fn took(&mut self, read: usize) {
        self.held += read;
    }

    fn held(&self) -> &[u8] {
        &self.bytes[..self.held]
    }

    // The first `used` held bytes are decoded: the rest move down, and the
    // places they leave are cleared.
    fn consume(&mut self, used: usize) {
        self.bytes.copy_within(used..self.held, 0);
        let left = self.held - used;
        self.bytes[left..self.held].zeroize();
        self.held = left;
    }
}

impl Drop for Reading {
    fn drop(&mut self) {
        self.bytes.as_mut_slice().zeroize();
    }
}
