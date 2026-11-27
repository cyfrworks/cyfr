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
//! is read. `tests/fixtures/runner_relay.json` holds every frame and
//! refusal.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value};

use crate::auth::MAX_CALL_HEADER_BYTES;
use crate::wire::{MAX_INTEGER, decode_base64, encode_base64, is_id, json_string};

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

/// The host API callbacks a `host_call` names: every one but the two a
/// worker service makes itself.
pub const OPS: [&str; 16] = [
    "attach",
    "renew",
    "complete",
    "fail",
    "push_deltas",
    "oauth_token",
    "take_rate",
    "fetch_artifact",
    "storage",
    "admit_child",
    "tool_call",
    "record_denial",
    "release_child",
    "egress_pin",
    "question_ask",
    "question_wait",
];

/// An answer or request header: its name and value.
pub type Header = (String, String);

/// A frame a runner sends.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outgoing {
    HostCall {
        attempt: String,
        op: &'static str,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Pinned,
    Attached,
}

#[derive(Debug, Clone)]
struct Fetch {
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
    fetches: BTreeMap<u64, Fetch>,
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

    /// Whether nothing is outstanding: no call unanswered, no fetch open.
    pub fn idle(&self) -> bool {
        self.calls.is_empty() && self.fetches.is_empty()
    }

    // ========================================================================
    // Encoding
    // ========================================================================

    /// The bytes of `frame` as the next frame the runner sends, its length
    /// first; the channel takes it only when it is sent.
    pub fn encode(&mut self, frame: &Outgoing) -> Result<Vec<u8>, Unsent> {
        let seq = self.sent;
        let (attempt, kind, members) = written(frame).map_err(Unsent::Invalid)?;
        if !self.attempts.contains(attempt) {
            return Err(Unsent::Refused(Refusal::UnknownAttempt));
        }
        let json = format!(
            "{{\"v\":{VERSION},\"attempt\":{},\"seq\":{seq},\"kind\":\"{kind}\"{}}}",
            json_string(attempt),
            members
                .iter()
                .map(|(name, value)| format!(",\"{name}\":{value}"))
                .collect::<String>()
        );
        if json.len() > MAX_FRAME_BYTES {
            return Err(Unsent::Invalid(Invalid("body")));
        }
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
                let fetch = Fetch {
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
        let length = u32::try_from(json.len()).expect("a frame is under 4 GiB");
        let mut bytes = length.to_be_bytes().to_vec();
        bytes.extend_from_slice(json.as_bytes());
        Ok(bytes)
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
        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(json) else {
            return Err(Refusal::Malformed);
        };
        if !matches!(object.get("v"), Some(Value::Number(n)) if n.as_u64() == Some(VERSION)) {
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
        let read = Reader(&object);
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

    fn open_fetch(&mut self, re: u64, attempt: &str) -> Result<&mut Fetch, Refusal> {
        match self.fetches.get_mut(&re) {
            Some(fetch) if fetch.attempt == attempt => Ok(fetch),
            Some(_other) => Err(Refusal::UnknownAttempt),
            None => Err(Refusal::UnknownReference),
        }
    }
}

fn spend(fetch: &mut Fetch, bytes: usize) -> Result<(), Refusal> {
    let bytes = bytes as u64;
    if bytes > fetch.credit {
        return Err(Refusal::CreditExceeded);
    }
    fetch.credit -= bytes;
    Ok(())
}

/// A frame's members as written: each name and its JSON, in wire order.
type Members = Vec<(&'static str, String)>;

/// A frame's attempt, kind and members as written, in wire order.
fn written(frame: &Outgoing) -> Result<(&str, &'static str, Members), Invalid> {
    Ok(match frame {
        Outgoing::HostCall {
            attempt,
            op,
            header,
            body,
        } => {
            if !OPS.contains(op) {
                return Err(Invalid("op"));
            }
            if header.len() > MAX_SIGNED_HEADER_BYTES || !is_signed_header(header) {
                return Err(Invalid("header"));
            }
            (
                attempt,
                "host_call",
                vec![
                    ("op", json_string(op)),
                    ("header", json_string(header)),
                    ("body", body_text(body)?),
                ],
            )
        }
        Outgoing::PinnedFetch {
            attempt,
            pin,
            method,
            path,
            headers,
            body,
        } => (
            attempt,
            "fetch",
            vec![
                ("pin", json_string(pin)),
                ("method", json_string(method)),
                ("path", json_string(path)),
                ("headers", headers_text(headers)),
                ("body", body_text(body)?),
            ],
        ),
        Outgoing::AttachedFetch {
            attempt,
            call_id,
            connection,
            purpose,
            method,
            url,
            headers,
            body,
        } => (
            attempt,
            "fetch",
            vec![
                ("call_id", json_string(call_id)),
                ("connection", json_string(connection)),
                ("purpose", json_string(purpose)),
                ("method", json_string(method)),
                ("url", json_string(url)),
                ("headers", headers_text(headers)),
                ("body", body_text(body)?),
            ],
        ),
        Outgoing::Credit { attempt, re, bytes } => {
            if *re > MAX_INTEGER {
                return Err(Invalid("re"));
            }
            if *bytes == 0 || *bytes > MAX_BODY_BYTES as u64 {
                return Err(Invalid("bytes"));
            }
            (
                attempt,
                "credit",
                vec![("re", re.to_string()), ("bytes", bytes.to_string())],
            )
        }
        Outgoing::Close { attempt, reason } => {
            if !is_code(reason) {
                return Err(Invalid("reason"));
            }
            (attempt, "close", vec![("reason", json_string(reason))])
        }
    })
}

fn body_text(body: &[u8]) -> Result<String, Invalid> {
    if body.len() > MAX_BODY_BYTES {
        return Err(Invalid("body"));
    }
    Ok(json_string(&encode_base64(body)))
}

fn headers_text(headers: &[Header]) -> String {
    let pairs: Vec<String> = headers
        .iter()
        .map(|(name, value)| format!("[{},{}]", json_string(name), json_string(value)))
        .collect();
    format!("[{}]", pairs.join(","))
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
        match self.member(name)? {
            Value::Number(n) if n.is_u64() || n.is_i64() => match n.as_u64() {
                Some(value) if range.contains(&value) => Ok(value),
                _ => Err(Refusal::InvalidField(name.to_owned())),
            },
            _ => Err(Refusal::WrongType(name.to_owned())),
        }
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
