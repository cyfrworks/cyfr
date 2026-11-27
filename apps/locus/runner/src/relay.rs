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

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value};

use crate::auth::MAX_CALL_HEADER_BYTES;
use crate::host::Op;
use crate::wire::{
    Integer, MAX_INTEGER, bounded, decode_base64, decode_base64url, encode_base64,
    encode_base64url, integer, is_id, is_url, json_string, parse,
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

/// An answer or request header: its name and value.
pub type Header = (String, String);

/// A frame a runner sends.
#[derive(Debug, Clone, PartialEq, Eq)]
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

    // ========================================================================
    // Encoding
    // ========================================================================

    /// The bytes of `frame` as the next frame the runner sends, its length
    /// first; the channel takes it only when it is sent.
    pub fn encode(&mut self, frame: &Outgoing) -> Result<Vec<u8>, Unsent> {
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
        let json = format!(
            "{{\"v\":{VERSION},\"attempt\":{},\"seq\":{seq},\"kind\":\"{kind}\"{}}}",
            json_string(attempt),
            members
                .iter()
                .map(|(name, value)| format!(",\"{name}\":{value}"))
                .collect::<String>()
        );
        if json.len() > MAX_FRAME_BYTES {
            return Err(Unsent::Invalid(Invalid("frame")));
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
            let header = signed_header(header).then(|| json_string(header));
            (
                attempt,
                "host_call",
                vec![
                    ("op", json_string(op.name())),
                    ("header", header.ok_or(Invalid("header"))?),
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
                    ("pin", json_string(pin)),
                    ("method", json_string(method)),
                    ("path", json_string(path)),
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
                    ("call_id", json_string(call_id)),
                    ("connection", json_string(connection)),
                    ("purpose", json_string(purpose)),
                    ("method", json_string(method)),
                    ("url", json_string(url)),
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
                vec![("re", re.to_string()), ("bytes", bytes.to_string())],
            )
        }
        Outgoing::Close { reason, .. } => {
            check(is_code(reason), "reason")?;
            (attempt, "close", vec![("reason", json_string(reason))])
        }
    })
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

fn body_text(body: &[u8]) -> Result<String, Invalid> {
    if body.len() > MAX_BODY_BYTES {
        return Err(Invalid("body"));
    }
    Ok(json_string(&encode_base64(body)))
}

fn headers_text(headers: &[Header]) -> Result<String, Invalid> {
    check(
        headers.len() <= MAX_HEADERS
            && headers
                .iter()
                .all(|(name, value)| is_header_name(name) && is_header_value(value)),
        "headers",
    )?;
    let pairs: Vec<String> = headers
        .iter()
        .map(|(name, value)| format!("[{},{}]", json_string(name), json_string(value)))
        .collect();
    Ok(format!("[{}]", pairs.join(",")))
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
/// host call of the runner's subtree goes through.
///
/// The relay has no cancel for a call (section 5.5 of the plan): a call
/// whose caller stopped waiting stays outstanding on the channel until its
/// answer arrives, which is then discarded, and the channel is not idle
/// meanwhile. A frame the codec refuses is answered with a `close` naming
/// its code; that, the service's own `close`, the stream's end or a failed
/// write closes the relay: every call still waiting is answered as lost,
/// and `closed` says so, which ends the runner.
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
        let (bytes, outbox) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
        let (write_failed_tx, write_failed) = tokio::sync::oneshot::channel::<()>();
        tokio::spawn(write_frames(writer, outbox, write_failed_tx));
        tokio::spawn(serve(reader, inbox, bytes, write_failed, closed_tx));
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
    mut outbox: tokio::sync::mpsc::UnboundedReceiver<Vec<u8>>,
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

async fn serve<R>(
    mut reader: R,
    mut inbox: tokio::sync::mpsc::UnboundedReceiver<Command>,
    outbox: tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    mut write_failed: tokio::sync::oneshot::Receiver<()>,
    closed: tokio::sync::watch::Sender<bool>,
) where
    R: tokio::io::AsyncRead + Unpin,
{
    use tokio::io::AsyncReadExt as _;
    let mut channel: Option<Channel> = None;
    let mut root = String::new();
    let mut waiting: BTreeMap<u64, tokio::sync::oneshot::Sender<Option<crate::host::Reached>>> =
        BTreeMap::new();
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; READ_BYTES];
    loop {
        tokio::select! {
            command = inbox.recv() => {
                let Some(command) = command else { break };
                match command {
                    Command::Bind { attempt, reply } => {
                        let bound = match channel.as_mut() {
                            None => Channel::new(&attempt)
                                .map(|opened| channel = Some(opened))
                                .map_err(Rebind::Invalid),
                            Some(open) => open.rebind(&attempt),
                        };
                        if bound.is_ok() {
                            root = attempt;
                        }
                        let _ = reply.send(bound);
                    }
                    Command::Idle { reply } => {
                        let _ = reply.send(channel.as_ref().is_none_or(Channel::idle));
                    }
                    Command::Call { attempt, op, header, body, reply } => {
                        let frame = Outgoing::HostCall { attempt, op, header, body };
                        let Some(open) = channel.as_mut() else {
                            let _ = reply.send(None);
                            continue;
                        };
                        let seq = open.sent;
                        match open.encode(&frame) {
                            Ok(bytes) => {
                                waiting.insert(seq, reply);
                                if outbox.send(bytes).is_err() {
                                    break;
                                }
                            }
                            Err(_unsent) => {
                                let _ = reply.send(None);
                            }
                        }
                    }
                }
            }
            read = reader.read(&mut chunk) => {
                let read = match read {
                    Ok(0) | Err(_) => break,
                    Ok(read) => read,
                };
                buffer.extend_from_slice(&chunk[..read]);
                let Some(open) = channel.as_mut() else {
                    // Nothing is sent to a runner before its first
                    // assignment binds the channel.
                    break;
                };
                match open.decode(&buffer) {
                    Ok((frames, used)) => {
                        buffer.drain(..used);
                        let mut ended = false;
                        for frame in frames {
                            match frame {
                                Incoming::HostAnswer { re, status, body, .. } => {
                                    if let Some(reply) = waiting.remove(&re) {
                                        let _ = reply.send(
                                            status.map(|status| crate::host::Reached { status, body }),
                                        );
                                    }
                                }
                                Incoming::Close { .. } => ended = true,
                                // A fetch's frames: no fetch is sent before
                                // a guest's requests are built.
                                _ => {}
                            }
                        }
                        if ended {
                            break;
                        }
                    }
                    Err(refusal) => {
                        let close = Outgoing::Close {
                            attempt: root.clone(),
                            reason: refusal.close_code().to_owned(),
                        };
                        if let Ok(bytes) = open.encode(&close) {
                            let _ = outbox.send(bytes);
                        }
                        break;
                    }
                }
            }
            _ = &mut write_failed => break,
        }
    }
    // Every call still waiting hears that no answer will come.
    for (_seq, reply) in std::mem::take(&mut waiting) {
        let _ = reply.send(None);
    }
    let _ = closed.send(true);
    // Commands sent after the close are answered as the closed relay's.
    inbox.close();
    while let Some(command) = inbox.recv().await {
        match command {
            Command::Bind { reply, .. } => {
                let _ = reply.send(Err(Rebind::Busy));
            }
            Command::Idle { reply } => {
                let _ = reply.send(false);
            }
            Command::Call { reply, .. } => {
                let _ = reply.send(None);
            }
        }
    }
}
