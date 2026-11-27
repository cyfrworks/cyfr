// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! `cyfr:http/fetch`: a catalyst's request, answered whole; and what it
//! shares with `cyfr:http/streaming` (`super::stream`): reading a guest's
//! request, pinning it, and sending it through the relay.
//!
//! The runner carries none of the edge's egress policy (section 5.4 of
//! the plan, D5 (a)): each refusal is decided once, at the hop that owns
//! it. The runner reads the request as the guest wrote it, under the
//! envelope bound that keeps its own memory (`requested`). Then:
//!
//! - **A pinned request** asks CYFR for its pin (`egress_pin`), which
//!   decides the host against the edge's domains (`domain_blocked`) and
//!   its address (`private_ip_blocked`, `dns_error`), and a redirect's hop
//!   against the pin it came from (`redirect_credentials`), and records
//!   each refusal itself; the runner records none of them again. A pin
//!   naming another scheme, host or port than the URL's, or a hop's pin on
//!   another origin than its `from`, is refused by the runner as its own.
//!   The request goes through the relay naming the pin, and the relay's
//!   service end decides its method, scheme, headers and size, takes it
//!   from the consented rate and asks CYFR again before it connects.
//! - **An attached request** (one naming a `connection`) asks for no pin:
//!   it is built as `Prima.AttachedRequest` builds one and read back as
//!   CYFR reads it, so a credential header (`credential_header_refused`)
//!   or a header that frames or routes it is refused here by shape. The
//!   relay checks it and CYFR makes it, attaching the credential, so none
//!   enters the runner; CYFR's answer comes back as frames sealed for the
//!   attempt and the request's `call_id`, and its refusal as its own type
//!   and sentence.
//!
//! The runner records the relay's refusals (`record_denial`), and its own
//! refusals of a size, of the types CYFR records (`RECORDED`). A request
//! that would pass `crate::relay::MAX_FETCHES` open is refused unsent.
//!
//! A fetch's answer is read as it arrives, each chunk granted back as
//! credit, to at most the node's `max_response_size`; a fetch abandoned
//! before its end (too large, timed out, the attempt ended) drains in the
//! relay. A redirecting answer (`3xx` with a `Location`) is answered as
//! it is: the guest's next request to where it points is the redirect's
//! next hop from this request's pin, and at most `MAX_HOPS` are kept.
//!
//! The guest's headers and body, which may carry its credentials, are
//! held cleared on drop; the `String` the generated binding takes for the
//! request is Wasmtime's, freed unwiped beside the guest's own copy.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde_json::{Map, Value};
use zeroize::{Zeroize as _, Zeroizing};

use super::{Guest, Run, args, catalyst, ended, error_json};
use crate::auth::{AnswerFrame, Direction, FrameReader};
use crate::authority::Limits;
use crate::control::{Event, Meta};
use crate::host::{Outcome, Reading, answered};
use crate::relay::{Fetch, FetchEvent, Header, MAX_FETCHES, Outgoing, Unfetched};
use crate::wire::{Unread, decode_base64, encode_base64, encode_base64url, read};
use crate::words;

/// The slack above twice the consented `max_request_size` a request's
/// envelope may take (`super::storage::ENVELOPE_OVERHEAD`).
use super::storage::ENVELOPE_OVERHEAD;

/// How much longer than the node's timeout a fetch waits for the relay's
/// next word, which the relay bounds by that timeout itself.
pub const RELAY_GRACE: Duration = Duration::from_secs(5);

/// The longest a connection to a pinned address may take
/// (`Prima.Network.connect_timeout_ms/0`).
pub const CONNECT_TIMEOUT_MS: u64 = 5_000;

/// The redirects an attempt keeps before its guest follows them; the
/// oldest is forgotten first.
pub const MAX_HOPS: usize = 8;

/// The headers a guest's request may not set: those that frame or route a
/// request, those that override its method or target or claim a forwarded
/// origin, and every name with an override's prefix
/// (`tests/fixtures/host_api.json`'s `framing_headers`, `override_headers`
/// and `override_prefixes`). An attached request's are refused here, by
/// shape; a pinned request's by the relay.
pub const FRAMING_HEADERS: [&str; 10] = [
    "host",
    "content-length",
    "transfer-encoding",
    "connection",
    "keep-alive",
    "te",
    "trailer",
    "upgrade",
    "proxy-connection",
    "expect",
];
pub const OVERRIDE_HEADERS: [&str; 16] = [
    "x-http-method-override",
    "x-http-method",
    "x-method-override",
    "x-original-url",
    "x-rewrite-url",
    "x-original-host",
    "x-host",
    "x-forwarded-host",
    "x-forwarded-proto",
    "x-forwarded-port",
    "x-forwarded-prefix",
    "x-forwarded-server",
    "forwarded",
    "via",
    "x-real-ip",
    "true-client-ip",
];
pub const OVERRIDE_PREFIXES: [&str; 1] = ["x-forwarded-"];

/// The headers that carry a credential, which an attached request never
/// sets (`tests/fixtures/host_api.json`'s `credential_headers`).
pub const CREDENTIAL_HEADERS: [&str; 7] = [
    "authorization",
    "cookie",
    "proxy-authorization",
    "x-api-key",
    "x-auth-token",
    "x-access-token",
    "x-csrf-token",
];

/// The refusals CYFR records when the runner reports them
/// (`Opus.Host.Storage`'s denials): the relay's, and the runner's own of a
/// size. Every other refusal is the guest's to read and no one's to record.
pub const RECORDED: [&str; 7] = [
    "domain_blocked",
    "method_blocked",
    "scheme_blocked",
    "request_too_large",
    "response_too_large",
    "private_ip_blocked",
    "rate_limited",
];

/// A refusal the guest is answered: its type and sentence, and whether
/// CYFR decided it, and so recorded it already.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub kind: String,
    pub message: String,
    pub by_cyfr: bool,
}

pub(super) fn refusal(kind: &str, message: impl Into<String>) -> Refusal {
    Refusal {
        kind: kind.to_owned(),
        message: message.into(),
        by_cyfr: false,
    }
}

fn cyfr(kind: &str, message: impl Into<String>) -> Refusal {
    Refusal {
        by_cyfr: true,
        ..refusal(kind, message)
    }
}

/// Why a request is made: answered whole, or streamed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Purpose {
    Fetch,
    Stream,
}

impl Purpose {
    fn name(self) -> &'static str {
        match self {
            Purpose::Fetch => "fetch",
            Purpose::Stream => "stream",
        }
    }
}

/// A guest's request, read: what it is sent as. Its URL, headers and body
/// are the guest's and are cleared when it is dropped.
pub struct Asked {
    pub method: String,
    pub url: Zeroizing<String>,
    /// The URL's host as the guest wrote it, which sentences and events
    /// name.
    pub host: String,
    pub(super) origin: Origin,
    /// The path and query the relay's fetch names.
    pub(super) path: Zeroizing<String>,
    pub(super) headers: Vec<Header>,
    pub(super) body: Zeroizing<Vec<u8>>,
    pub(super) response_base64: bool,
    pub(super) connection: Option<String>,
}

impl Drop for Asked {
    fn drop(&mut self) {
        for (name, value) in &mut self.headers {
            name.zeroize();
            value.zeroize();
        }
    }
}

/// A scheme, host and effective port: what a pin names and a redirect
/// keeps to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Origin {
    pub scheme: String,
    /// Lowercase, an IPv6 literal without its brackets.
    pub host: String,
    pub port: u16,
}

impl Origin {
    /// Whether `other` is this origin, an IPv6 literal however it is
    /// spelled (`Prima.Network.same_origin?/2`).
    pub fn same(&self, other: &Origin) -> bool {
        self.scheme == other.scheme
            && self.port == other.port
            && match (
                self.host.parse::<std::net::Ipv6Addr>(),
                other.host.parse::<std::net::Ipv6Addr>(),
            ) {
                (Ok(a), Ok(b)) => a == b,
                _ => self.host == other.host,
            }
    }
}

/// A pin CYFR answered: its id and the origin it names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pin {
    pub id: String,
    pub origin: Origin,
}

/// A redirect an attempt received: where it points, as `canonical` spells
/// it, and the pin the redirecting answer came from.
pub type Hop = (String, Pin);

// ============================================================================
// Reading a guest's request
// ============================================================================

/// The guest's `request` read for `purpose`, under the envelope bound the
/// node's `max_request_size` sets; or its refusal.
pub fn requested(request: &str, limits: &Limits, purpose: Purpose) -> Result<Asked, Refusal> {
    let envelope = limits
        .max_request_size
        .saturating_mul(2)
        .saturating_add(ENVELOPE_OVERHEAD);
    if request.len() as u64 > envelope {
        return Err(refusal("request_too_large", words::REQUEST_TOO_LARGE));
    }
    let json = match read(request.as_bytes()) {
        Ok(json) => json,
        Err(Unread::TooDeep) => return Err(refusal("invalid_json", words::request_too_deep())),
        Err(Unread::Malformed) => return Err(refusal("invalid_json", words::REQUEST_NOT_JSON)),
    };
    let invalid = |message: &str| refusal("invalid_request", message);
    let Some(object) = json.value().as_object() else {
        return Err(invalid(words::NO_METHOD_OR_URL));
    };
    let (Some(method), Some(url)) = (object.get("method"), object.get("url")) else {
        return Err(invalid(words::NO_METHOD_OR_URL));
    };
    let (Value::String(method), Value::String(url)) = (method, url) else {
        return Err(invalid(words::MALFORMED_REQUEST));
    };
    let url = Zeroizing::new(url.clone());
    let parts = Url::parse(&url).ok_or_else(|| invalid(words::BAD_URL))?;
    let Some(host) = parts.host.clone().filter(|host| !host.is_empty()) else {
        return Err(invalid(words::NO_HOSTNAME));
    };
    if parts.userinfo.is_some() {
        return Err(invalid(words::URL_CREDENTIALS));
    }
    let multipart = match object.get("multipart") {
        Some(Value::Array(parts)) => Some(parts),
        _ => None,
    };
    let body = match object.get("body") {
        None | Some(Value::Null) => "",
        Some(Value::String(body)) => body.as_str(),
        Some(_) => return Err(invalid(words::MALFORMED_REQUEST)),
    };
    if multipart.is_some() && !body.is_empty() {
        return Err(invalid(words::BODY_AND_MULTIPART));
    }
    let headers = headers(object.get("headers"))?;
    let connection = match object.get("connection") {
        None => None,
        Some(Value::String(connection)) => Some(connection.clone()),
        Some(_) => return Err(invalid(words::BAD_CONNECTION)),
    };
    if multipart.is_some() && purpose == Purpose::Stream {
        return Err(invalid(words::STREAM_MULTIPART));
    }
    let base64 = |member: &str| object.get(member).and_then(Value::as_str) == Some("base64");
    let (headers, body) = match multipart {
        Some(parts) => multipart_body(parts, headers)?,
        None if base64("body_encoding") && !body.is_empty() => {
            let decoded = decode_base64(body).ok_or_else(|| invalid(words::BAD_BODY_BASE64))?;
            (headers, Zeroizing::new(decoded))
        }
        None => (headers, Zeroizing::new(body.as_bytes().to_vec())),
    };
    let origin = parts.origin().ok_or_else(|| invalid(words::BAD_URL))?;
    let path = Zeroizing::new(parts.path_and_query());
    Ok(Asked {
        method: method.to_uppercase(),
        url,
        host,
        origin,
        path,
        headers,
        body,
        response_base64: base64("response_encoding"),
        connection,
    })
}

// Headers are an object of names to values or an array of `[name, value]`
// pairs, a value a string or a scalar read as its text.
fn headers(value: Option<&Value>) -> Result<Vec<Header>, Refusal> {
    let invalid = || refusal("invalid_request", words::BAD_HEADERS);
    let pair = |name: &str, value: &Value| {
        if name.is_empty() {
            return Err(invalid());
        }
        let value = match value {
            Value::Array(_) | Value::Object(_) => return Err(invalid()),
            value => text_of(value).ok_or_else(invalid)?,
        };
        Ok((name.to_owned(), value))
    };
    match value {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Object(members)) => members
            .iter()
            .map(|(name, value)| pair(name, value))
            .collect(),
        Some(Value::Array(pairs)) => pairs
            .iter()
            .map(|entry| match entry.as_array().map(Vec::as_slice) {
                Some([Value::String(name), value]) => pair(name, value),
                _ => Err(invalid()),
            })
            .collect(),
        Some(_) => Err(invalid()),
    }
}

// A multipart request's parts encoded as `multipart/form-data`, its
// boundary in the content type that replaces the guest's own.
fn multipart_body(
    parts: &[Value],
    mut headers: Vec<Header>,
) -> Result<(Vec<Header>, Zeroizing<Vec<u8>>), Refusal> {
    let invalid = |message: String| refusal("invalid_request", message);
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("the operating system's random source answers");
    let boundary = crate::wire::hex(&bytes);
    let mut body = Zeroizing::new(Vec::new());
    for part in parts {
        let Some(part) = part.as_object() else {
            return Err(invalid(words::MULTIPART_PART.to_owned()));
        };
        let Some(name) = part.get("name").map(text_of) else {
            return Err(invalid(words::MULTIPART_PART.to_owned()));
        };
        let name = name.ok_or_else(|| invalid(words::MULTIPART_PART.to_owned()))?;
        body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
        match (part.get("data"), part.get("value")) {
            (Some(Value::String(data)), _) => {
                let data = Zeroizing::new(
                    decode_base64(data).ok_or_else(|| invalid(words::bad_part_base64(&name)))?,
                );
                let filename = match part.get("filename").and_then(Value::as_str) {
                    Some(filename) => format!("; filename=\"{}\"", quoted(filename)),
                    None => String::new(),
                };
                let content_type = part
                    .get("content_type")
                    .and_then(Value::as_str)
                    .unwrap_or("application/octet-stream");
                body.extend_from_slice(
                    format!(
                        "content-disposition: form-data; name=\"{}\"{filename}\r\ncontent-type: \
                         {content_type}\r\n\r\n",
                        quoted(&name)
                    )
                    .as_bytes(),
                );
                body.extend_from_slice(&data);
            }
            (_, value) => {
                let value = match value {
                    None => String::new(),
                    Some(value) => text_of(value).unwrap_or_else(|| value.to_string()),
                };
                body.extend_from_slice(
                    format!(
                        "content-disposition: form-data; name=\"{}\"\r\n\r\n",
                        quoted(&name)
                    )
                    .as_bytes(),
                );
                body.extend_from_slice(value.as_bytes());
            }
        }
        body.extend_from_slice(b"\r\n");
    }
    body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
    headers.retain(|(name, _)| !name.eq_ignore_ascii_case("content-type"));
    headers.push((
        "content-type".to_owned(),
        format!("multipart/form-data; boundary={boundary}"),
    ));
    Ok((headers, body))
}

// A scalar's text, as Elixir's `to_string/1` writes it.
fn text_of(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        Value::Bool(value) => Some(value.to_string()),
        Value::Null => Some(String::new()),
        _ => None,
    }
}

fn quoted(text: &str) -> String {
    text.replace('"', "%22")
}

// ============================================================================
// URLs, as Elixir's `URI` reads, writes and merges them
// ============================================================================

/// A URL's parts as `URI.parse/1` reads them, with its port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Url {
    pub scheme: Option<String>,
    pub userinfo: Option<String>,
    /// Without brackets.
    pub host: Option<String>,
    /// The port the URL names, as text, when it names one.
    pub port: Option<String>,
    pub path: Option<String>,
    pub query: Option<String>,
    pub fragment: Option<String>,
}

impl Url {
    /// The parts of `text`, or none for a port that is no number.
    pub fn parse(text: &str) -> Option<Url> {
        let uri = crate::wire::parse_uri(text);
        let port = uri.port.filter(|port| !port.is_empty());
        if port.is_some_and(|port| !port.bytes().all(|b| b.is_ascii_digit())) {
            return None;
        }
        Some(Url {
            scheme: uri.scheme,
            userinfo: uri.userinfo.map(str::to_owned),
            host: uri.host.map(str::to_owned),
            port: port.map(str::to_owned),
            path: uri.path.map(str::to_owned),
            query: uri.query.map(str::to_owned),
            fragment: uri.fragment.map(str::to_owned),
        })
    }

    /// The scheme's default port.
    fn default_port(&self) -> Option<u16> {
        match self.scheme.as_deref() {
            Some("http") => Some(80),
            Some("https") => Some(443),
            _ => None,
        }
    }

    /// The effective port: the URL's own, or its scheme's default.
    fn effective_port(&self) -> Option<u16> {
        match &self.port {
            Some(port) => port.parse::<u16>().ok().filter(|port| *port > 0),
            None => self.default_port(),
        }
    }

    /// The origin a pin of this URL names, for an `http` or `https` URL
    /// with a host.
    pub fn origin(&self) -> Option<Origin> {
        let scheme = self.scheme.clone()?;
        Some(Origin {
            port: self.effective_port()?,
            host: self.host.as_deref()?.to_ascii_lowercase(),
            scheme,
        })
    }

    /// The path and query a fetch names: `/` for none.
    pub fn path_and_query(&self) -> String {
        let mut path = match self.path.as_deref() {
            None | Some("") => "/".to_owned(),
            Some(path) => path.to_owned(),
        };
        if let Some(query) = &self.query {
            path.push('?');
            path.push_str(query);
        }
        path
    }

    /// Whether this is a URL a guest's request may name
    /// (`Prima.Network.parse_url/1`).
    pub fn admissible(&self) -> bool {
        matches!(self.scheme.as_deref(), Some("http" | "https"))
            && self.host.as_deref().is_some_and(|host| !host.is_empty())
            && self.userinfo.is_none()
    }

    /// The URL as `URI.to_string/1` writes it: the port only when it is not
    /// the scheme's default, an IPv6 host in brackets.
    pub fn canonical(&self) -> String {
        let mut text = String::new();
        if let Some(scheme) = &self.scheme {
            text.push_str(scheme);
            text.push(':');
        }
        if let Some(host) = &self.host {
            text.push_str("//");
            if let Some(userinfo) = &self.userinfo {
                text.push_str(userinfo);
                text.push('@');
            }
            if host.contains(':') {
                text.push('[');
                text.push_str(host);
                text.push(']');
            } else {
                text.push_str(host);
            }
            if let Some(port) = self.effective_port()
                && Some(port) != self.default_port()
            {
                text.push(':');
                text.push_str(&port.to_string());
            }
        }
        if let Some(path) = &self.path {
            text.push_str(path);
        }
        if let Some(query) = &self.query {
            text.push('?');
            text.push_str(query);
        }
        if let Some(fragment) = &self.fragment {
            text.push('#');
            text.push_str(fragment);
        }
        text
    }

    /// `reference` resolved against this URL, as `URI.merge/2` resolves it
    /// (RFC 3986, section 5.2).
    pub fn merge(&self, reference: &Url) -> Url {
        if reference.scheme.is_some() {
            return Url {
                path: reference.path.as_deref().map(remove_dot_segments),
                ..reference.clone()
            };
        }
        if reference.host.is_some() {
            return Url {
                scheme: self.scheme.clone(),
                path: reference.path.as_deref().map(remove_dot_segments),
                ..reference.clone()
            };
        }
        let (path, query) = match reference.path.as_deref() {
            None | Some("") => (
                self.path.clone(),
                reference.query.clone().or_else(|| self.query.clone()),
            ),
            Some(path) if path.starts_with('/') => {
                (Some(remove_dot_segments(path)), reference.query.clone())
            }
            Some(path) => {
                let base = self.path.as_deref().unwrap_or("");
                let merged = match base.rfind('/') {
                    Some(slash) => format!("{}{path}", &base[..=slash]),
                    None if self.host.is_some() => format!("/{path}"),
                    None => path.to_owned(),
                };
                (Some(remove_dot_segments(&merged)), reference.query.clone())
            }
        };
        Url {
            scheme: self.scheme.clone(),
            userinfo: self.userinfo.clone(),
            host: self.host.clone(),
            port: self.port.clone(),
            path,
            query,
            fragment: reference.fragment.clone(),
        }
    }
}

// RFC 3986, section 5.2.4: `.` and `..` segments removed from `path`.
fn remove_dot_segments(path: &str) -> String {
    let mut input = path.to_owned();
    let mut output = String::new();
    while !input.is_empty() {
        if let Some(rest) = input.strip_prefix("../") {
            input = rest.to_owned();
        } else if let Some(rest) = input.strip_prefix("./") {
            input = rest.to_owned();
        } else if input.starts_with("/./") {
            input.replace_range(..3, "/");
        } else if input == "/." {
            input = "/".to_owned();
        } else if input.starts_with("/../") || input == "/.." {
            let cut = if input == "/.." { 3 } else { 4 };
            input.replace_range(..cut, "/");
            match output.rfind('/') {
                Some(slash) => output.truncate(slash),
                None => output.clear(),
            }
        } else if input == "." || input == ".." {
            input.clear();
        } else {
            let start = usize::from(input.starts_with('/'));
            let end = input[start..]
                .find('/')
                .map_or(input.len(), |at| at + start);
            output.push_str(&input[..end]);
            input.replace_range(..end, "");
        }
    }
    output
}

// ============================================================================
// Sending a request
// ============================================================================

/// A request sent: the fetch the guest's import owns, the reader of an
/// attached request's frames, and the pin a pinned one was sent on.
pub struct Sent {
    pub fetch: Fetch,
    pub frames: Option<FrameReader>,
    pub pin: Option<Pin>,
}

/// The attempt's redirects and the request's purpose, as a request is
/// pinned with them.
pub(super) struct Pinning<'a> {
    pub hops: &'a mut VecDeque<Hop>,
    pub purpose: Purpose,
}

/// Send `asked` for `purpose`: its pin asked, or its attached request
/// built and read, then its fetch through the relay. A refusal is the
/// guest's, already recorded by CYFR when CYFR decided it; an `Err` of the
/// outer result ends the run.
pub(super) async fn send(
    run: &Run,
    asked: &Asked,
    pinning: Pinning<'_>,
) -> wasmtime::Result<Result<Sent, Refusal>> {
    let host = run.host.clone();
    let purpose = pinning.purpose;
    // A request past the relay's fetches is held back before it is pinned.
    if !host.relay().room().await {
        return Ok(Err(refusal_in_flight(purpose)));
    }
    let (frame, frames, pin) = match &asked.connection {
        Some(connection) => match attached(host.attempt(), asked, connection, purpose) {
            Ok((frame, call_id)) => (
                frame,
                Some(FrameReader::new(&host.keys().seal, &call_id)),
                None,
            ),
            Err(refused) => return Ok(Err(refused)),
        },
        None => {
            let pin = match pinned(run, asked, pinning).await? {
                Ok(pin) => pin,
                Err(refused) => return Ok(Err(refused)),
            };
            let frame = Outgoing::PinnedFetch {
                attempt: host.attempt().to_owned(),
                pin: pin.id.clone(),
                method: asked.method.clone(),
                path: (*asked.path).clone(),
                headers: asked.headers.clone(),
                body: (*asked.body).clone(),
            };
            (frame, None, Some(pin))
        }
    };
    match host.relay().fetch(frame).await {
        Ok(fetch) => Ok(Ok(Sent { fetch, frames, pin })),
        Err(Unfetched::Busy) => Ok(Err(refusal_in_flight(purpose))),
        Err(Unfetched::Invalid(_)) => Ok(Err(refusal("invalid_request", words::UNSENDABLE))),
        Err(Unfetched::Closed) => Ok(Err(refusal(
            "http_error",
            words::http_failed("relay_closed"),
        ))),
    }
}

fn refusal_in_flight(purpose: Purpose) -> Refusal {
    let kind = match purpose {
        Purpose::Fetch => "request_failed",
        Purpose::Stream => "stream_limit",
    };
    refusal(kind, words::requests_in_flight(MAX_FETCHES))
}

// CYFR's pin of a pinned request, a redirect's hop from the pin it came
// from; or its refusal. A pin naming another origin than the URL's, or a
// hop's pin on another origin than its `from`'s, is the runner's own.
async fn pinned(
    run: &Run,
    asked: &Asked,
    pinning: Pinning<'_>,
) -> wasmtime::Result<Result<Pin, Refusal>> {
    let canonical = Url::parse(&asked.url).map(|url| url.canonical());
    let from = canonical.and_then(|canonical| {
        let at = pinning.hops.iter().position(|(url, _)| *url == canonical)?;
        pinning.hops.remove(at).map(|(_, from)| from)
    });
    let mut members = vec![("url", Value::String((*asked.url).clone()))];
    match &from {
        Some(from) => {
            members.push(("purpose", Value::String("redirect".to_owned())));
            members.push(("from", Value::String(from.id.clone())));
        }
        None => members.push(("purpose", Value::String(pinning.purpose.name().to_owned()))),
    }
    let outcome = run.host.call("egress_pin", args(members)).await;
    ended("egress_pin", &outcome)?;
    let host = &asked.host;
    let pin = match outcome {
        Outcome::Answered(Reading::Ok(pin)) => match read_pin(pin.value()) {
            Some(pin) => pin,
            None => return Ok(Err(refusal("dns_error", words::PIN_NOT_CURRENT))),
        },
        Outcome::Answered(Reading::Refused(why)) => return Ok(Err(pin_refusal(why, host))),
        _ => return Ok(Err(pin_refusal("lost", host))),
    };
    if !pin.origin.same(&asked.origin) {
        return Ok(Err(refusal("dns_error", words::pin_elsewhere(host))));
    }
    if let Some(from) = &from
        && !from.origin.same(&pin.origin)
    {
        return Ok(Err(refusal(
            "redirect_credentials",
            words::redirect_refused(host),
        )));
    }
    Ok(Ok(pin))
}

/// How a pin that was not granted, for `why`, answers a guest's request to
/// `host`: CYFR's refusals as recorded already, and the runner's own
/// reasons (`unavailable`, `lost`, `elsewhere`, `expired`) as its own.
pub fn pin_refusal(why: &str, host: &str) -> Refusal {
    match why {
        "domain" => cyfr("domain_blocked", words::pin_domain(host)),
        "denied" => cyfr("private_ip_blocked", words::pin_denied(host)),
        "metadata" => cyfr("private_ip_blocked", words::pin_metadata(host)),
        "resolution" => cyfr("dns_error", words::pin_resolution(host)),
        "redirect_credentials" => cyfr("redirect_credentials", words::redirect_refused(host)),
        "malformed" => cyfr("invalid_request", words::BAD_URL),
        "elsewhere" => refusal("dns_error", words::pin_elsewhere(host)),
        "expired" => refusal("dns_error", words::pin_expired(host)),
        "unavailable" => refusal("dns_error", words::pin_unavailable(host)),
        _lost => refusal("dns_error", words::PIN_NOT_CURRENT),
    }
}

// A pin as `Prima.PinnedTarget.read/1` reads one: its id and its origin;
// none for anything else.
fn read_pin(pin: &Value) -> Option<Pin> {
    let pin = pin.as_object()?;
    let members = ["id", "ip", "family", "scheme", "port", "host", "expires_at"];
    if pin.len() != members.len() || !members.iter().all(|member| pin.contains_key(*member)) {
        return None;
    }
    let id = pin.get("id")?.as_str()?;
    let valid_id = (1..=128).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    let scheme = pin.get("scheme")?.as_str()?;
    let port = crate::wire::bounded(pin.get("port")?, 1..=65_535).ok()?;
    let host = pin.get("host")?.as_str()?;
    if !valid_id || !matches!(scheme, "http" | "https") || host.is_empty() {
        return None;
    }
    let host = host
        .strip_prefix('[')
        .and_then(|inner| inner.strip_suffix(']'))
        .unwrap_or(host);
    Some(Pin {
        id: id.to_owned(),
        origin: Origin {
            scheme: scheme.to_owned(),
            host: host.to_ascii_lowercase(),
            port: u16::try_from(port).ok()?,
        },
    })
}

// The attached fetch of `asked`, built as `Prima.AttachedRequest` builds
// one and read back as CYFR reads it (`Prima.AttachedRequest.read/1`), so
// the runner refuses what CYFR would; and its call id.
fn attached(
    attempt: &str,
    asked: &Asked,
    connection: &str,
    purpose: Purpose,
) -> Result<(Outgoing, String), Refusal> {
    let unread = || refusal("invalid_request", words::ATTACHED_UNREAD);
    let connection_valid = {
        let bytes = connection.as_bytes();
        (1..=32).contains(&bytes.len())
            && bytes[0].is_ascii_lowercase()
            && bytes[1..]
                .iter()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_' || *b == b'-')
    };
    let url_valid = asked.url.len() <= crate::relay::MAX_URL_BYTES
        && crate::wire::is_text(&asked.url)
        && Url::parse(&asked.url).is_some_and(|url| url.admissible());
    if !connection_valid || !crate::relay::METHODS.contains(&asked.method.as_str()) || !url_valid {
        return Err(unread());
    }
    let shaped = asked.headers.len() <= crate::relay::MAX_HEADERS
        && asked.headers.iter().all(|(name, value)| {
            name.len() <= crate::relay::MAX_HEADER_NAME_BYTES
                && !name.is_empty()
                && name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
                && value.len() <= crate::relay::MAX_HEADER_VALUE_BYTES
                && !value.chars().any(|c| c.is_ascii_control() && c != '\t')
        });
    if !shaped {
        return Err(unread());
    }
    if asked
        .headers
        .iter()
        .any(|(name, _)| CREDENTIAL_HEADERS.contains(&name.to_ascii_lowercase().as_str()))
    {
        return Err(refusal(
            "credential_header_refused",
            words::CREDENTIAL_HEADER,
        ));
    }
    if let Some((name, _)) = asked.headers.iter().find(|(name, _)| framing(name)) {
        return Err(refusal("invalid_request", words::attached_header(name)));
    }
    if asked.body.len() > crate::host::MAX_BODY_BYTES {
        return Err(unread());
    }
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("the operating system's random source answers");
    let call_id = encode_base64url(&bytes);
    let frame = Outgoing::AttachedFetch {
        attempt: attempt.to_owned(),
        call_id: call_id.clone(),
        connection: connection.to_owned(),
        purpose: purpose.name().to_owned(),
        method: asked.method.clone(),
        url: (*asked.url).clone(),
        headers: asked.headers.clone(),
        body: (*asked.body).clone(),
    };
    Ok((frame, call_id))
}

/// Whether `name` is a header that frames or routes a request, or
/// overrides its method or target (`Prima.Network.framing_or_override_header?/1`).
pub fn framing(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    FRAMING_HEADERS.contains(&name.as_str())
        || OVERRIDE_HEADERS.contains(&name.as_str())
        || OVERRIDE_PREFIXES
            .iter()
            .any(|prefix| name.starts_with(prefix))
}

// ============================================================================
// An answer, as it arrives
// ============================================================================

/// What one event of a fetch came to.
pub enum Read {
    /// The answer's status and headers, and the first of its body.
    Head {
        status: u16,
        headers: Vec<Header>,
        body: Zeroizing<Vec<u8>>,
    },
    /// The next of the answer's body.
    Body(Zeroizing<Vec<u8>>),
    /// The answer ended whole.
    End,
    /// The fetch ended early: the guest's refusal.
    Failed(Refusal),
    /// An attached request's answer was lost, or never reached its
    /// service: what CYFR did is unknown, as a lost host call's is, and the
    /// runner is not reused.
    Lost,
    /// Nothing the guest reads: a frame of no body, granted back.
    Nothing,
}

/// The next event of `sent`, read as the guest reads it, within `wait`;
/// none when nothing arrived. Every byte the relay charged for an event is
/// granted back once it is read, but an attached chunk's body, which the
/// caller grants as it hands it on.
pub async fn next(
    sent: &mut Sent,
    keys: &crate::auth::AttemptKeys,
    host: &str,
    limits: &Limits,
    wait: Duration,
) -> Option<Read> {
    let event = tokio::time::timeout(wait, sent.fetch.next()).await.ok()?;
    Some(match event {
        FetchEvent::Head {
            status,
            headers,
            body,
        } => Read::Head {
            status,
            headers,
            body,
        },
        FetchEvent::Chunk(body) => Read::Body(body),
        FetchEvent::Frame(frame) => {
            let Some(reader) = sent.frames.as_mut() else {
                return Some(Read::Failed(refusal("http_error", words::HTTP_FAILED)));
            };
            match reader.read(&frame) {
                Ok(AnswerFrame::Head { status, headers }) => {
                    sent.fetch.grant(frame.len());
                    Read::Head {
                        status,
                        headers,
                        body: Zeroizing::new(Vec::new()),
                    }
                }
                Ok(AnswerFrame::Chunk(body)) => {
                    sent.fetch.grant(frame.len() - body.len());
                    Read::Body(body)
                }
                Ok(AnswerFrame::End) => {
                    sent.fetch.grant(frame.len());
                    Read::End
                }
                Ok(AnswerFrame::Error { kind, message }) => Read::Failed(cyfr(&kind, message)),
                Err(_unread) => Read::Failed(refusal("http_error", words::HTTP_FAILED)),
            }
        }
        FetchEvent::Refusal { header, body } => {
            match attached_refusal(sent, keys, &header, &body) {
                Refused::Cyfr(refused) => Read::Failed(refused),
                Refused::Lost => Read::Lost,
                Refused::Unread => Read::Failed(refusal("http_error", words::HTTP_FAILED)),
            }
        }
        FetchEvent::End(None) => match &sent.frames {
            // An attached answer ends at its own `end`; a fetch that ends
            // before it is short.
            Some(reader) if !reader.done() => {
                Read::Failed(refusal("http_error", words::HTTP_FAILED))
            }
            Some(_) => Read::Nothing,
            None => Read::End,
        },
        FetchEvent::End(Some(code)) if sent.frames.is_some() && uncertain(&code) => Read::Lost,
        FetchEvent::End(Some(code)) => Read::Failed(ended_with(&code, host, limits)),
        FetchEvent::Closed => {
            Read::Failed(refusal("http_error", words::http_failed("relay_closed")))
        }
    })
}

enum Refused {
    Cyfr(Refusal),
    Lost,
    Unread,
}

// CYFR's refusal of an attached request, taken only as the answer to the
// call this fetch's attempt posted: its header verifies under the attempt's
// call key and names the attempt, its answer opens as that call's, and a
// guest error names the fetch's call id.
fn attached_refusal(
    sent: &Sent,
    keys: &crate::auth::AttemptKeys,
    header: &str,
    body: &[u8],
) -> Refused {
    let Some(reader) = &sent.frames else {
        return Refused::Unread;
    };
    let now = crate::attempt::now_ms();
    let Ok((fields, _hash)) = crate::auth::verify_call_header(&keys.call, header, now) else {
        return Refused::Unread;
    };
    if fields.attempt != keys.attempt {
        return Refused::Unread;
    }
    let Ok(plain) = crate::auth::open_call(&keys.seal, Direction::Answer, &fields, body) else {
        return Refused::Unread;
    };
    let Ok(read) = answered(
        crate::host::Op::named("egress_pin").expect("a callback"),
        &plain,
    ) else {
        return Refused::Unread;
    };
    match read {
        Reading::GuestError { kind, message, .. } => {
            // The call id an attached refusal names is beside its type.
            let named = crate::wire::parse(&plain).and_then(|answer| {
                answer
                    .value()
                    .get("call_id")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            });
            if named.as_deref() == Some(reader.call_id()) {
                Refused::Cyfr(cyfr(&kind, message.as_str()))
            } else {
                Refused::Unread
            }
        }
        Reading::Refused("lost") => Refused::Lost,
        _ => Refused::Unread,
    }
}

/// How a fetch the relay ended early with `code` answers a guest's request
/// to `host` (`Prima.RunnerRelay.fetch_end_codes/0`): a code naming why its
/// own ask for the pin got none as that refused pin does; any other code
/// the relay names as its rule; and a code it does not name as the
/// transport's failure.
pub fn ended_with(code: &str, host: &str, limits: &Limits) -> Refusal {
    if let Some(why) = code.strip_prefix("pin_") {
        return pin_refusal(why, host);
    }
    let timeout = limits.timeout_ms();
    match code {
        "timeout" => refusal("timeout", words::request_timeout(timeout)),
        "connect_timeout" => refusal(
            "timeout",
            words::connect_timeout(CONNECT_TIMEOUT_MS.min(timeout)),
        ),
        "rate_limited" => refusal("rate_limited", words::RATE_LIMITED),
        "response_too_large" => refusal(
            "response_too_large",
            words::response_too_large(limits.max_response_size),
        ),
        "request_too_large" => refusal("request_too_large", words::SERVICE_SIZE),
        "method_blocked" => refusal("method_blocked", words::SERVICE_METHOD),
        "scheme_blocked" => refusal("scheme_blocked", words::SERVICE_SCHEME),
        "domain_blocked" => refusal("domain_blocked", words::SERVICE_DOMAIN),
        "invalid_request" => refusal("invalid_request", words::SERVICE_HEADER),
        "private_ip_blocked" => refusal("private_ip_blocked", words::SERVICE_METADATA),
        "lost" | "uncertain" | "http_error" | "bad_frame" | "fetch_failed" | "refused" => {
            refusal("http_error", words::HTTP_FAILED)
        }
        code => refusal("http_error", words::http_failed(code)),
    }
}

/// Whether the relay's `code` leaves what CYFR did unknown: an attached
/// request's answer lost, or never reaching its service.
pub fn uncertain(code: &str) -> bool {
    matches!(code, "lost" | "uncertain")
}

// ============================================================================
// The import
// ============================================================================

impl catalyst::cyfr::http::fetch::Host for Guest {
    async fn request(&mut self, request: String) -> wasmtime::Result<String> {
        let request = Zeroizing::new(request);
        let run = self.run.clone();
        let asked = match requested(&request, &run.limits, Purpose::Fetch) {
            Ok(asked) => asked,
            Err(refused) => return refused_answer(&run, refused).await,
        };
        drop(request);
        let started = Instant::now();
        let pinning = Pinning {
            hops: &mut self.hops,
            purpose: Purpose::Fetch,
        };
        let mut sent = match send(&run, &asked, pinning).await? {
            Ok(sent) => sent,
            Err(refused) => return refused_answer(&run, refused).await,
        };
        let answer = collect(&run, &asked, &mut sent).await;
        let status = match &answer {
            Ok((status, _, _)) => Meta::Integer(u64::from(*status)),
            Err(Collected::TooLarge(_)) => Meta::text("response_too_large"),
            Err(Collected::TimedOut) => Meta::text("timeout"),
            Err(Collected::Failed(_)) => Meta::text("error"),
        };
        http_event(&run, &asked, status, started).await;
        match answer {
            Ok((status, headers, body)) => {
                if let Some(pin) = &sent.pin {
                    redirected(&mut self.hops, &asked, pin, status, &headers);
                }
                Ok(response(status, &headers, &body, asked.response_base64))
            }
            Err(Collected::TooLarge(size)) => {
                drop(sent);
                let max = run.limits.max_response_size;
                let refused = refusal(
                    "response_too_large",
                    words::response_counted(size.max(max + 1), max),
                );
                refused_answer(&run, refused).await
            }
            Err(Collected::TimedOut) => {
                drop(sent);
                Ok(error_json(
                    "timeout",
                    &words::request_timeout(run.limits.timeout_ms()),
                ))
            }
            Err(Collected::Failed(refused)) => {
                drop(sent);
                refused_answer(&run, refused).await
            }
        }
    }
}

enum Collected {
    TooLarge(u64),
    TimedOut,
    Failed(Refusal),
}

// The whole answer of `sent`: its status, headers and body, read to at most
// the node's `max_response_size`, each piece granted back as it is read.
async fn collect(
    run: &Run,
    asked: &Asked,
    sent: &mut Sent,
) -> Result<(u16, Vec<Header>, Zeroizing<Vec<u8>>), Collected> {
    let keys = run.host.keys();
    let max = run.limits.max_response_size;
    let wait = Duration::from_millis(run.limits.timeout_ms()) + RELAY_GRACE;
    let mut head: Option<(u16, Vec<Header>)> = None;
    let mut body: Zeroizing<Vec<u8>> = Zeroizing::new(Vec::new());
    loop {
        let Some(read) = next(sent, keys, &asked.host, &run.limits, wait).await else {
            return Err(Collected::TimedOut);
        };
        match read {
            Read::Head {
                status,
                headers,
                body: first,
            } => {
                head = Some((status, headers));
                take(sent, &mut body, &first, max)?;
            }
            Read::Body(piece) => take(sent, &mut body, &piece, max)?,
            Read::End => {
                let Some((status, headers)) = head else {
                    return Err(Collected::Failed(refusal("http_error", words::HTTP_FAILED)));
                };
                return Ok((status, headers, body));
            }
            Read::Failed(refused) => {
                if refused.kind == "response_too_large" && !refused.by_cyfr {
                    return Err(Collected::TooLarge(body.len() as u64));
                }
                return Err(Collected::Failed(refused));
            }
            Read::Lost => {
                run.host.unclean();
                return Err(Collected::Failed(refusal("http_error", words::HTTP_FAILED)));
            }
            Read::Nothing => {}
        }
    }
}

// Add `piece` to the answer's `body`, past the bound refused; and grant it
// back.
fn take(
    sent: &Sent,
    body: &mut Zeroizing<Vec<u8>>,
    piece: &[u8],
    max: u64,
) -> Result<(), Collected> {
    let size = body.len() as u64 + piece.len() as u64;
    if size > max {
        return Err(Collected::TooLarge(size));
    }
    // A move as the body grows leaves its old bytes behind unwiped: they
    // are the upstream's answer to the guest, which the guest holds too.
    body.extend_from_slice(piece);
    sent.fetch.grant(piece.len());
    Ok(())
}

// A redirecting answer's next hop, from the pin it came from: where its
// `Location` points, resolved against the request's URL.
fn redirected(hops: &mut VecDeque<Hop>, asked: &Asked, pin: &Pin, status: u16, headers: &[Header]) {
    if !matches!(status, 301 | 302 | 303 | 307 | 308) {
        return;
    }
    let Some((_, location)) = headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("location"))
    else {
        return;
    };
    let (Some(base), Some(reference)) = (Url::parse(&asked.url), Url::parse(location)) else {
        return;
    };
    let next = base.merge(&reference);
    let canonical = next.canonical();
    if !Url::parse(&canonical).is_some_and(|url| url.admissible()) {
        return;
    }
    hops.retain(|(url, _)| *url != canonical);
    hops.truncate(MAX_HOPS - 1);
    hops.push_front((canonical, pin.clone()));
}

/// The answer of a whole response: its status, its headers (the last of a
/// repeated name), and its body as text, or as base64 when asked.
fn response(status: u16, headers: &[Header], body: &[u8], base64: bool) -> String {
    let headers: Map<String, Value> = headers
        .iter()
        .map(|(name, value)| (name.clone(), Value::String(value.clone())))
        .collect();
    let mut answer = Map::new();
    answer.insert("status".to_owned(), Value::from(status));
    answer.insert("headers".to_owned(), Value::Object(headers));
    if base64 {
        answer.insert("body".to_owned(), Value::String(encode_base64(body)));
        answer.insert(
            "body_encoding".to_owned(),
            Value::String("base64".to_owned()),
        );
    } else {
        answer.insert("body".to_owned(), Value::String(text(body)));
    }
    Value::Object(answer).to_string()
}

/// `bytes` as text: UTF-8 as it is, anything else read as Latin-1.
pub fn text(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(text) => text.to_owned(),
        Err(_) => bytes.iter().map(|byte| char::from(*byte)).collect(),
    }
}

/// The guest's answer to a refusal, which the runner reports to CYFR when
/// it is one CYFR records and did not decide itself.
pub(super) async fn refused_answer(run: &Run, refused: Refusal) -> wasmtime::Result<String> {
    record(run, &refused).await?;
    Ok(error_json(&refused.kind, &refused.message))
}

/// Report `refused` to CYFR for its record, when CYFR records it and did
/// not decide it itself.
pub(super) async fn record(run: &Run, refused: &Refusal) -> wasmtime::Result<()> {
    if refused.by_cyfr || !RECORDED.contains(&refused.kind.as_str()) {
        return Ok(());
    }
    let outcome = run
        .host
        .call(
            "record_denial",
            args([
                ("type", Value::String(refused.kind.clone())),
                ("message", Value::String(refused.message.clone())),
            ]),
        )
        .await;
    ended("record_denial", &outcome)
}

/// The `http.request` event of a request made: its method, the host it
/// asked for, and its status, or why it has none; its `system_time` in
/// microseconds since the epoch, as the roster takes it.
pub(super) async fn http_event(run: &Run, asked: &Asked, status: Meta, started: Instant) {
    let system_time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| {
            u64::try_from(since.as_micros()).unwrap_or(u64::MAX)
        });
    run.host
        .event(Event {
            name: "http.request",
            measurements: vec![
                ("duration_ms", super::storage::elapsed_ms(started)),
                ("system_time", system_time),
            ],
            metadata: vec![
                ("component_ref", Meta::text(&run.component_ref)),
                ("method", Meta::text(&asked.method)),
                ("hostname", Meta::text(&asked.host)),
                ("status", status),
            ],
        })
        .await;
}
