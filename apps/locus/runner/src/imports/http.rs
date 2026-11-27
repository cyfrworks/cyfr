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
//!   naming another scheme, host or port than the URL's, a hop's pin on
//!   another origin than its `from`'s, or an answer `Prima.PinnedTarget`
//!   would not read, is refused by the runner as its own. The request goes
//!   through the relay naming the pin, and the relay's service end decides
//!   its method, scheme, headers and size, takes it from the consented rate
//!   and asks CYFR again before it connects.
//! - **An attached request** (one naming a `connection`) asks for no pin:
//!   it is built as `Prima.AttachedRequest` builds one and read back as
//!   CYFR reads it, so a credential header (`credential_header_refused`)
//!   or a header that frames or routes it is refused here by shape. The
//!   relay checks it and CYFR makes it, attaching the credential, so none
//!   enters the runner; CYFR's answer comes back as frames sealed for the
//!   attempt and the request's `call_id`, and its refusal as its own type
//!   and sentence, both read as they arrive (`crate::relay`).
//!
//! A method the relay's frame cannot carry (`crate::relay::METHODS`) is the
//! one refusal the runner makes for the relay, since the frame cannot be
//! written: `method_blocked`, before the pin. The runner records the
//! relay's refusals (`record_denial`), and its own refusals of a method or
//! a size, of the types CYFR records (`RECORDED`). A request that would
//! pass `crate::relay::MAX_FETCHES` open is refused unsent.
//!
//! A fetch's answer is read as it arrives, each piece granted back as
//! credit, to at most the node's `max_response_size`; a fetch abandoned
//! before its end (too large, timed out, the attempt ended) drains in the
//! relay. A redirecting answer (`3xx` with a `Location`) is answered as
//! it is: the guest's next request to where it points, its scheme and host
//! in any case, is the redirect's next hop from this request's pin, and at
//! most `MAX_HOPS` are kept.
//!
//! The guest's URL, headers and body, which may carry its credentials, are
//! held in cleared types from their reading to their sending, refusal or
//! drop; the `String` the generated binding takes for the request is
//! Wasmtime's, freed unwiped beside the guest's own copy.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde_json::{Map, Value};
use zeroize::Zeroizing;

use super::{Guest, Run, args, catalyst, ended, error_json};
use crate::auth::FrameReader;
use crate::authority::Limits;
use crate::control::{Event, Meta};
use crate::host::{Outcome, Reading};
use crate::relay::{
    Ended, Fetch, Header, Headers, MAX_FETCHES, METHODS, Opener, Outgoing, Taken, Unfetched,
};
use crate::wire::{Unread, decode_base64, encode_base64url, read};
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

/// The pin refusals the relay names a fetch's end by, each `pin_` and its
/// reason: CYFR's (`crate::host::PIN_REFUSALS`) and the service's own
/// (`Prima.RunnerRelay.pin_code/1`). Any other `pin_` code is a transport's.
pub const PIN_WHYS: [&str; 10] = [
    "domain",
    "denied",
    "metadata",
    "resolution",
    "redirect_credentials",
    "malformed",
    "unavailable",
    "lost",
    "elsewhere",
    "expired",
];

// ============================================================================
// The types a runner answers its guest
// ============================================================================

/// Every error type the runner answers a guest's HTTP import with, beside
/// CYFR's own, which an attached request's refusal carries as given: each
/// of `tests/fixtures/guest_error.json`'s `fetch_types` for the interfaces
/// it is answered on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    InvalidJson,
    InvalidRequest,
    CredentialHeaderRefused,
    RequestTooLarge,
    ResponseTooLarge,
    DomainBlocked,
    MethodBlocked,
    SchemeBlocked,
    RateLimited,
    PrivateIpBlocked,
    DnsError,
    RedirectCredentials,
    Timeout,
    RequestFailed,
    HttpError,
    StreamLimit,
    InvalidHandle,
    EncodingError,
}

impl Kind {
    /// Every kind, with whether a fetch's and a stream's answer may carry
    /// it: a stream answers a failure after its request was sent as
    /// `request_failed`, never `http_error`, and its own kinds are its
    /// alone.
    pub const ALL: [(Kind, bool, bool); 18] = [
        (Kind::InvalidJson, true, true),
        (Kind::InvalidRequest, true, true),
        (Kind::CredentialHeaderRefused, true, true),
        (Kind::RequestTooLarge, true, true),
        (Kind::ResponseTooLarge, true, true),
        (Kind::DomainBlocked, true, true),
        (Kind::MethodBlocked, true, true),
        (Kind::SchemeBlocked, true, true),
        (Kind::RateLimited, true, true),
        (Kind::PrivateIpBlocked, true, true),
        (Kind::DnsError, true, true),
        (Kind::RedirectCredentials, true, true),
        (Kind::Timeout, true, true),
        (Kind::RequestFailed, true, true),
        (Kind::HttpError, true, false),
        (Kind::StreamLimit, false, true),
        (Kind::InvalidHandle, false, true),
        (Kind::EncodingError, false, true),
    ];

    pub fn name(self) -> &'static str {
        match self {
            Kind::InvalidJson => "invalid_json",
            Kind::InvalidRequest => "invalid_request",
            Kind::CredentialHeaderRefused => "credential_header_refused",
            Kind::RequestTooLarge => "request_too_large",
            Kind::ResponseTooLarge => "response_too_large",
            Kind::DomainBlocked => "domain_blocked",
            Kind::MethodBlocked => "method_blocked",
            Kind::SchemeBlocked => "scheme_blocked",
            Kind::RateLimited => "rate_limited",
            Kind::PrivateIpBlocked => "private_ip_blocked",
            Kind::DnsError => "dns_error",
            Kind::RedirectCredentials => "redirect_credentials",
            Kind::Timeout => "timeout",
            Kind::RequestFailed => "request_failed",
            Kind::HttpError => "http_error",
            Kind::StreamLimit => "stream_limit",
            Kind::InvalidHandle => "invalid_handle",
            Kind::EncodingError => "encoding_error",
        }
    }
}

/// The refusals CYFR records when the runner reports them
/// (`Opus.Host.Storage`'s denials): the relay's, and the runner's own of a
/// method or a size. Every other refusal is the guest's to read and no
/// one's to record.
pub const RECORDED: [Kind; 7] = [
    Kind::DomainBlocked,
    Kind::MethodBlocked,
    Kind::SchemeBlocked,
    Kind::RequestTooLarge,
    Kind::ResponseTooLarge,
    Kind::PrivateIpBlocked,
    Kind::RateLimited,
];

/// A refusal the guest is answered: its type and sentence, and whether
/// CYFR decided it, and so recorded it already.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub kind: String,
    pub message: String,
    pub by_cyfr: bool,
}

impl Refusal {
    /// Whether the runner reports this refusal to CYFR for its record.
    pub fn recorded(&self) -> bool {
        !self.by_cyfr && RECORDED.iter().any(|kind| kind.name() == self.kind)
    }

    /// Whether it is of `kind` and the runner's own.
    pub fn is(&self, kind: Kind) -> bool {
        !self.by_cyfr && self.kind == kind.name()
    }
}

/// The runner's own refusal of `kind`.
pub fn refusal(kind: Kind, message: impl Into<String>) -> Refusal {
    Refusal {
        kind: kind.name().to_owned(),
        message: message.into(),
        by_cyfr: false,
    }
}

// A refusal CYFR decided, and recorded already: of a kind of the runner's
// vocabulary for a pin, or of CYFR's own for an attached request.
fn cyfr(kind: &str, message: impl Into<String>) -> Refusal {
    Refusal {
        kind: kind.to_owned(),
        message: message.into(),
        by_cyfr: true,
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
    /// The URL as `Url::canonical` spells it, by which a redirect's hop is
    /// known.
    pub(super) canonical: Zeroizing<String>,
    /// The path and query the relay's fetch names.
    pub(super) path: Zeroizing<String>,
    pub(super) headers: Headers,
    pub(super) body: Zeroizing<Vec<u8>>,
    pub(super) response_base64: bool,
    pub(super) connection: Option<String>,
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

/// A redirect an attempt received: where it points, as `Url::canonical`
/// spells it, and the pin the redirecting answer came from.
pub type Hop = (Zeroizing<String>, Pin);

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
        return Err(refusal(Kind::RequestTooLarge, words::REQUEST_TOO_LARGE));
    }
    let json = match read(request.as_bytes()) {
        Ok(json) => json,
        Err(Unread::TooDeep) => return Err(refusal(Kind::InvalidJson, words::request_too_deep())),
        Err(Unread::Malformed) => return Err(refusal(Kind::InvalidJson, words::REQUEST_NOT_JSON)),
    };
    let invalid = |message: &str| refusal(Kind::InvalidRequest, message);
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
    let Some(host) = parts.host.as_deref().filter(|host| !host.is_empty()) else {
        return Err(invalid(words::NO_HOSTNAME));
    };
    let host = host.to_owned();
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
    Ok(Asked {
        method: method.to_uppercase(),
        canonical: parts.canonical(),
        path: parts.path_and_query(),
        url,
        host,
        origin,
        headers,
        body,
        response_base64: base64("response_encoding"),
        connection,
    })
}

// Headers are an object of names to values or an array of `[name, value]`
// pairs, a value a string or a scalar read as its text.
fn headers(value: Option<&Value>) -> Result<Headers, Refusal> {
    let invalid = || refusal(Kind::InvalidRequest, words::BAD_HEADERS);
    let mut read = Headers::default();
    let mut pair = |name: &str, value: &Value| {
        if name.is_empty() {
            return Err(invalid());
        }
        let value = match value {
            Value::Array(_) | Value::Object(_) => return Err(invalid()),
            value => text_of(value).ok_or_else(invalid)?,
        };
        read.0.push((name.to_owned(), (*value).clone()));
        Ok(())
    };
    match value {
        None | Some(Value::Null) => {}
        Some(Value::Object(members)) => {
            for (name, value) in members {
                pair(name, value)?;
            }
        }
        Some(Value::Array(pairs)) => {
            for entry in pairs {
                match entry.as_array().map(Vec::as_slice) {
                    Some([Value::String(name), value]) => pair(name, value)?,
                    _ => return Err(invalid()),
                }
            }
        }
        Some(_) => return Err(invalid()),
    }
    Ok(read)
}

// A multipart request's parts encoded as `multipart/form-data`, its
// boundary in the content type that replaces the guest's own.
fn multipart_body(
    parts: &[Value],
    mut headers: Headers,
) -> Result<(Headers, Zeroizing<Vec<u8>>), Refusal> {
    let invalid = |message: String| refusal(Kind::InvalidRequest, message);
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("the operating system's random source answers");
    let boundary = crate::wire::hex(&bytes);
    let mut body = Zeroizing::new(Vec::new());
    for part in parts {
        let Some(part) = part.as_object() else {
            return Err(invalid(words::MULTIPART_PART.to_owned()));
        };
        let Some(name) = part.get("name").and_then(text_of) else {
            return Err(invalid(words::MULTIPART_PART.to_owned()));
        };
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
                    None => Zeroizing::new(String::new()),
                    Some(value) => {
                        text_of(value).unwrap_or_else(|| Zeroizing::new(value.to_string()))
                    }
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
    headers
        .0
        .retain(|(name, _)| !name.eq_ignore_ascii_case("content-type"));
    headers.0.push((
        "content-type".to_owned(),
        format!("multipart/form-data; boundary={boundary}"),
    ));
    Ok((headers, body))
}

// A scalar's text, as Elixir's `to_string/1` writes it, cleared when it is
// dropped.
fn text_of(value: &Value) -> Option<Zeroizing<String>> {
    match value {
        Value::String(text) => Some(Zeroizing::new(text.clone())),
        Value::Number(number) => Some(Zeroizing::new(number.to_string())),
        Value::Bool(value) => Some(Zeroizing::new(value.to_string())),
        Value::Null => Some(Zeroizing::new(String::new())),
        _ => None,
    }
}

fn quoted(text: &str) -> String {
    text.replace('"', "%22")
}

// ============================================================================
// URLs, as Elixir's `URI` reads, writes and merges them
// ============================================================================

/// A part of a URL, which may carry a credential: cleared when dropped.
type Part = Option<Zeroizing<String>>;

fn part(text: Option<&str>) -> Part {
    text.map(|text| Zeroizing::new(text.to_owned()))
}

/// A URL's parts as `URI.parse/1` reads them, with its port.
#[derive(Clone, PartialEq, Eq)]
pub struct Url {
    pub scheme: Option<String>,
    pub userinfo: Part,
    /// Without brackets.
    pub host: Option<String>,
    /// The port the URL names, as text, when it names one.
    pub port: Option<String>,
    pub path: Part,
    pub query: Part,
    pub fragment: Part,
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
            userinfo: part(uri.userinfo),
            host: uri.host.map(str::to_owned),
            port: port.map(str::to_owned),
            path: part(uri.path),
            query: part(uri.query),
            fragment: part(uri.fragment),
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
    pub fn path_and_query(&self) -> Zeroizing<String> {
        let path = self.path.as_deref().map_or("", String::as_str);
        let query = self.query.as_deref().map(String::as_str);
        let mut text = Zeroizing::new(String::with_capacity(
            path.len().max(1) + query.map_or(0, |query| query.len() + 1),
        ));
        text.push_str(if path.is_empty() { "/" } else { path });
        if let Some(query) = query {
            text.push('?');
            text.push_str(query);
        }
        text
    }

    /// Whether this is a URL a guest's request may name
    /// (`Prima.Network.parse_url/1`).
    pub fn admissible(&self) -> bool {
        matches!(self.scheme.as_deref(), Some("http" | "https"))
            && self.host.as_deref().is_some_and(|host| !host.is_empty())
            && self.userinfo.is_none()
    }

    /// The URL as `URI.to_string/1` writes it, its host lowercased, so a
    /// redirect's hop is known however the guest's library spells its
    /// scheme and host: the port only when it is not the scheme's default,
    /// an IPv6 host in brackets.
    pub fn canonical(&self) -> Zeroizing<String> {
        let mut text = Zeroizing::new(String::with_capacity(
            [&self.userinfo, &self.path, &self.query, &self.fragment]
                .iter()
                .map(|part| part.as_deref().map_or(0, String::len) + 1)
                .sum::<usize>()
                + self.host.as_deref().map_or(0, str::len)
                + 24,
        ));
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
            let host = host.to_ascii_lowercase();
            if host.contains(':') {
                text.push('[');
                text.push_str(&host);
                text.push(']');
            } else {
                text.push_str(&host);
            }
            if let Some(port) = self.effective_port()
                && Some(port) != self.default_port()
            {
                text.push(':');
                text.push_str(&port.to_string());
            }
        }
        for (mark, part) in [("", &self.path), ("?", &self.query), ("#", &self.fragment)] {
            if let Some(part) = part {
                text.push_str(mark);
                text.push_str(part);
            }
        }
        text
    }

    /// `reference` resolved against this URL, as `URI.merge/2` resolves it
    /// (RFC 3986, section 5.2).
    pub fn merge(&self, reference: &Url) -> Url {
        let removed = |path: &Part| -> Part {
            path.as_deref()
                .map(|path| Zeroizing::new(remove_dot_segments(path)))
        };
        if reference.scheme.is_some() {
            return Url {
                path: removed(&reference.path),
                ..reference.clone()
            };
        }
        if reference.host.is_some() {
            return Url {
                scheme: self.scheme.clone(),
                path: removed(&reference.path),
                ..reference.clone()
            };
        }
        let (path, query) = match reference.path.as_deref().map(String::as_str) {
            None | Some("") => (
                self.path.clone(),
                reference.query.clone().or_else(|| self.query.clone()),
            ),
            Some(path) if path.starts_with('/') => {
                (removed(&reference.path), reference.query.clone())
            }
            Some(path) => {
                let base = self.path.as_deref().map_or("", String::as_str);
                let merged = Zeroizing::new(match base.rfind('/') {
                    Some(slash) => format!("{}{path}", &base[..=slash]),
                    None if self.host.is_some() => format!("/{path}"),
                    None => path.to_owned(),
                });
                (
                    Some(Zeroizing::new(remove_dot_segments(&merged))),
                    reference.query.clone(),
                )
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

/// RFC 3986, section 5.2.4: `.` and `..` segments removed from `path`, in
/// one pass over it. The input is the rest of `path`, after a `/` the
/// algorithm put back when `lead` is set; each segment the output takes is
/// kept as a unit with its leading `/`, so a `..` removes the last unit.
pub fn remove_dot_segments(path: &str) -> String {
    let mut rest = path;
    let mut lead = false;
    let mut units: Vec<(bool, &str)> = Vec::new();
    loop {
        if !lead {
            if let Some(after) = rest.strip_prefix("../") {
                rest = after;
                continue;
            }
            if let Some(after) = rest.strip_prefix("./") {
                rest = after;
                continue;
            }
            if rest == "." || rest == ".." {
                break;
            }
        }
        let (slash, after) = if lead {
            (true, rest)
        } else if let Some(after) = rest.strip_prefix('/') {
            (true, after)
        } else {
            (false, rest)
        };
        if slash {
            if let Some(next) = after.strip_prefix("./") {
                (rest, lead) = (next, true);
                continue;
            }
            if after == "." {
                (rest, lead) = ("", true);
                continue;
            }
            if let Some(next) = after.strip_prefix("../") {
                (rest, lead) = (next, true);
                units.pop();
                continue;
            }
            if after == ".." {
                (rest, lead) = ("", true);
                units.pop();
                continue;
            }
        } else if after.is_empty() {
            break;
        }
        let end = after.find('/').unwrap_or(after.len());
        units.push((slash, &after[..end]));
        (rest, lead) = (&after[end..], false);
    }
    let mut out = String::with_capacity(path.len() + 1);
    for (slash, segment) in units {
        if slash {
            out.push('/');
        }
        out.push_str(segment);
    }
    out
}

// ============================================================================
// Sending a request
// ============================================================================

/// A request sent: the fetch the guest's import owns, and the pin a pinned
/// one was sent on.
pub struct Sent {
    pub fetch: Fetch,
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
    // A method no frame carries is refused for the relay, before the pin.
    if !METHODS.contains(&asked.method.as_str()) {
        return Ok(Err(refusal(
            Kind::MethodBlocked,
            words::unsupported_method(&asked.method),
        )));
    }
    // A request past the relay's fetches is held back before it is pinned.
    if !host.relay().room().await {
        return Ok(Err(refusal_in_flight(purpose)));
    }
    let (frame, opener, pin) = match &asked.connection {
        Some(connection) => match attached(host.attempt(), asked, connection, purpose) {
            Ok((frame, call_id)) => (
                frame,
                Some(Opener {
                    frames: FrameReader::new(&host.keys().seal, &call_id),
                    keys: host.keys().clone(),
                }),
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
                headers: asked.headers.0.clone(),
                body: (*asked.body).clone(),
            };
            (frame, None, Some(pin))
        }
    };
    match host.relay().fetch(frame, opener).await {
        Ok(fetch) => Ok(Ok(Sent { fetch, pin })),
        Err(Unfetched::Busy) => Ok(Err(refusal_in_flight(purpose))),
        Err(Unfetched::Invalid(_)) => Ok(Err(refusal(Kind::InvalidRequest, words::UNSENDABLE))),
        Err(Unfetched::Closed) => Ok(Err(refusal(
            Kind::HttpError,
            words::http_failed("relay_closed"),
        ))),
    }
}

fn refusal_in_flight(purpose: Purpose) -> Refusal {
    let kind = match purpose {
        Purpose::Fetch => Kind::RequestFailed,
        Purpose::Stream => Kind::StreamLimit,
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
    let from = pinning
        .hops
        .iter()
        .position(|(url, _)| *url == asked.canonical)
        .and_then(|at| pinning.hops.remove(at))
        .map(|(_, from)| from);
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
            None => return Ok(Err(refusal(Kind::DnsError, words::PIN_NOT_CURRENT))),
        },
        Outcome::Answered(Reading::Refused(why)) => return Ok(Err(pin_refusal(why, host))),
        _ => return Ok(Err(pin_refusal("lost", host))),
    };
    if !pin.origin.same(&asked.origin) {
        return Ok(Err(refusal(Kind::DnsError, words::pin_elsewhere(host))));
    }
    if let Some(from) = &from
        && !from.origin.same(&pin.origin)
    {
        return Ok(Err(refusal(
            Kind::RedirectCredentials,
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
        "domain" => cyfr(Kind::DomainBlocked.name(), words::pin_domain(host)),
        "denied" => cyfr(Kind::PrivateIpBlocked.name(), words::pin_denied(host)),
        "metadata" => cyfr(Kind::PrivateIpBlocked.name(), words::pin_metadata(host)),
        "resolution" => cyfr(Kind::DnsError.name(), words::pin_resolution(host)),
        "redirect_credentials" => cyfr(
            Kind::RedirectCredentials.name(),
            words::redirect_refused(host),
        ),
        "malformed" => cyfr(Kind::InvalidRequest.name(), words::BAD_URL),
        "elsewhere" => refusal(Kind::DnsError, words::pin_elsewhere(host)),
        "expired" => refusal(Kind::DnsError, words::pin_expired(host)),
        "unavailable" => refusal(Kind::DnsError, words::pin_unavailable(host)),
        _lost => refusal(Kind::DnsError, words::PIN_NOT_CURRENT),
    }
}

/// A pin as `Prima.PinnedTarget.read/1` reads one: exactly its seven
/// members, an id of 1 to 128 base64url characters, an IP literal and the
/// family that matches it, an `http` or `https` scheme, a port of 1 to
/// 65535, a hostname or bracketed IPv6 literal, and an expiry of 0 to
/// 2^53 − 1; its id and origin. None for anything else.
pub fn read_pin(pin: &Value) -> Option<Pin> {
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
    let family = match pin.get("ip")?.as_str()?.parse::<std::net::IpAddr>().ok()? {
        std::net::IpAddr::V4(_) => 4,
        std::net::IpAddr::V6(_) => 6,
    };
    let family_matches = crate::wire::bounded(pin.get("family")?, 4..=6).ok() == Some(family);
    let scheme = pin.get("scheme")?.as_str()?;
    let port = crate::wire::bounded(pin.get("port")?, 1..=65_535).ok()?;
    let expires = crate::wire::bounded(pin.get("expires_at")?, 0..=crate::wire::MAX_INTEGER);
    let host = pin.get("host")?.as_str()?;
    if !valid_id
        || !family_matches
        || !matches!(scheme, "http" | "https")
        || expires.is_err()
        || !valid_host(host)
    {
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

// A pin's host: an IPv6 literal in brackets, or a hostname of labels of
// letters, digits, `_` and `-`, none starting or ending with `-`, at most
// 63 characters each and 253 in all, with an optional final dot.
fn valid_host(host: &str) -> bool {
    if let Some(inner) = host.strip_prefix('[') {
        return inner
            .strip_suffix(']')
            .is_some_and(|inner| inner.parse::<std::net::Ipv6Addr>().is_ok());
    }
    let label = |label: &str| {
        let bytes = label.as_bytes();
        (1..=63).contains(&bytes.len())
            && bytes
                .iter()
                .all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
            && bytes[0] != b'-'
            && bytes[bytes.len() - 1] != b'-'
    };
    (1..=253).contains(&host.len()) && host.strip_suffix('.').unwrap_or(host).split('.').all(label)
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
    let unread = || refusal(Kind::InvalidRequest, words::ATTACHED_UNREAD);
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
    if !connection_valid || !url_valid {
        return Err(unread());
    }
    let headers = &asked.headers.0;
    let shaped = headers.len() <= crate::relay::MAX_HEADERS
        && headers.iter().all(|(name, value)| {
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
    if headers
        .iter()
        .any(|(name, _)| CREDENTIAL_HEADERS.contains(&name.to_ascii_lowercase().as_str()))
    {
        return Err(refusal(
            Kind::CredentialHeaderRefused,
            words::CREDENTIAL_HEADER,
        ));
    }
    if let Some((name, _)) = headers.iter().find(|(name, _)| framing(name)) {
        return Err(refusal(Kind::InvalidRequest, words::attached_header(name)));
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
        headers: headers.clone(),
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
// How a fetch ends, as its guest is told
// ============================================================================

/// How a fetch the relay ended early with `code` answers a guest's request
/// to `host` (`Prima.RunnerRelay.fetch_end_codes/0`): a pin code of the
/// roster as that refused pin does; any other code the relay names as its
/// rule; and a code it does not name, a `pin_` code off the roster among
/// them, as the transport's failure that code names.
pub fn ended_with(code: &str, host: &str, limits: &Limits) -> Refusal {
    if let Some(why) = code.strip_prefix("pin_")
        && PIN_WHYS.contains(&why)
    {
        return pin_refusal(why, host);
    }
    let timeout = limits.timeout_ms();
    match code {
        "timeout" => refusal(Kind::Timeout, words::request_timeout(timeout)),
        "connect_timeout" => refusal(
            Kind::Timeout,
            words::connect_timeout(CONNECT_TIMEOUT_MS.min(timeout)),
        ),
        "rate_limited" => refusal(Kind::RateLimited, words::RATE_LIMITED),
        "response_too_large" => refusal(
            Kind::ResponseTooLarge,
            words::response_too_large(limits.max_response_size),
        ),
        "request_too_large" => refusal(Kind::RequestTooLarge, words::SERVICE_SIZE),
        "method_blocked" => refusal(Kind::MethodBlocked, words::SERVICE_METHOD),
        "scheme_blocked" => refusal(Kind::SchemeBlocked, words::SERVICE_SCHEME),
        "domain_blocked" => refusal(Kind::DomainBlocked, words::service_domain(host)),
        "invalid_request" => refusal(Kind::InvalidRequest, words::SERVICE_HEADER),
        "private_ip_blocked" => refusal(Kind::PrivateIpBlocked, words::SERVICE_METADATA),
        "lost" | "uncertain" | "http_error" | "bad_frame" | "fetch_failed" | "refused" => {
            refusal(Kind::HttpError, words::HTTP_FAILED)
        }
        code => refusal(Kind::HttpError, words::http_failed(code)),
    }
}

/// How a fetch's `end` answers a guest's request to `host`, a fetch whole
/// answering nothing. An attached answer lost or never reaching its
/// service leaves the relay in doubt, which is what keeps its runner from
/// reuse (`crate::relay::Relay::idle`), whoever reads it.
pub fn ended_as(end: &Ended, host: &str, limits: &Limits) -> Option<Refusal> {
    match end {
        Ended::Whole => None,
        Ended::Code(code) => Some(ended_with(code, host, limits)),
        Ended::Cyfr { kind, message } => Some(cyfr(kind, message.as_str())),
        Ended::Lost | Ended::Unread => Some(refusal(Kind::HttpError, words::HTTP_FAILED)),
        Ended::Closed => Some(refusal(Kind::HttpError, words::http_failed("relay_closed"))),
    }
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
        drop(sent.fetch);
        let fields = EventFields::of(&run, &asked, started);
        fields.send(&run.host, status).await;
        match answer {
            Ok((status, headers, body)) => {
                if let Some(pin) = &sent.pin {
                    redirected(&mut self.hops, &asked, pin, status, &headers.0);
                }
                Ok(response(status, &headers.0, &body, asked.response_base64))
            }
            Err(Collected::TooLarge(size)) => {
                let max = run.limits.max_response_size;
                let refused = refusal(
                    Kind::ResponseTooLarge,
                    words::response_counted(size.max(max + 1), max),
                );
                refused_answer(&run, refused).await
            }
            Err(Collected::TimedOut) => Ok(error_json(
                Kind::Timeout.name(),
                &words::request_timeout(run.limits.timeout_ms()),
            )),
            Err(Collected::Failed(refused)) => refused_answer(&run, refused).await,
        }
    }
}

enum Collected {
    TooLarge(u64),
    TimedOut,
    Failed(Refusal),
}

/// The most of an answer's body one read takes.
const PIECE_BYTES: usize = 1024 * 1024;

// The whole answer of `sent`: its status, headers and body, read to at most
// the node's `max_response_size`, each piece granted back as it is read.
async fn collect(
    run: &Run,
    asked: &Asked,
    sent: &mut Sent,
) -> Result<(u16, Headers, Zeroizing<Vec<u8>>), Collected> {
    let max = run.limits.max_response_size;
    let wait = Duration::from_millis(run.limits.timeout_ms()) + RELAY_GRACE;
    let mut head: Option<(u16, Headers)> = None;
    let mut body: Zeroizing<Vec<u8>> = Zeroizing::new(Vec::new());
    loop {
        let Some(taken) = sent.fetch.next(PIECE_BYTES, wait).await else {
            return Err(Collected::TimedOut);
        };
        match taken {
            Taken::Head { status, headers } => head = Some((status, headers)),
            Taken::Body(piece) => {
                let size = body.len() as u64 + piece.len() as u64;
                if size > max {
                    return Err(Collected::TooLarge(size));
                }
                // Reserved for the whole of what is held, so it moves at
                // most once a doubling: what a move leaves behind unwiped
                // is the upstream's answer to the guest, which it holds too.
                body.extend_from_slice(&piece);
            }
            Taken::End(end) => {
                return match (ended_as(&end, &asked.host, &run.limits), head) {
                    (Some(refused), _) if refused.is(Kind::ResponseTooLarge) => {
                        Err(Collected::TooLarge(body.len() as u64))
                    }
                    (Some(refused), _) => Err(Collected::Failed(refused)),
                    (None, Some((status, headers))) => Ok((status, headers, body)),
                    (None, None) => Err(Collected::Failed(refusal(
                        Kind::HttpError,
                        words::HTTP_FAILED,
                    ))),
                };
            }
        }
    }
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
    if !next.admissible() {
        return;
    }
    let canonical = next.canonical();
    hops.retain(|(url, _)| *url != canonical);
    hops.truncate(MAX_HOPS - 1);
    hops.push_front((canonical, pin.clone()));
}

/// The answer of a whole response: its status, its headers (the last of a
/// repeated name), and its body as text, UTF-8 as it is and anything else
/// read as Latin-1, or as base64 when asked; the members in the order
/// serde_json writes them. The body is written once, straight into the
/// answer, which is reserved whole.
pub fn response(status: u16, headers: &[Header], body: &[u8], base64: bool) -> String {
    // An answer's headers may carry what the guest fetches with (a
    // `Location`'s query, a cookie): their JSON is cleared once written.
    let headers = Zeroizing::new(
        crate::wire::Json::from_value(Value::Object(
            headers
                .iter()
                .map(|(name, value)| (name.clone(), Value::String(value.clone())))
                .collect::<Map<String, Value>>(),
        ))
        .value()
        .to_string(),
    );
    let body_bytes = if base64 {
        body.len().div_ceil(3) * 4
    } else {
        body.len() * 2
    };
    let mut answer = String::with_capacity(body_bytes + headers.len() + 64);
    answer.push_str("{\"body\":\"");
    if base64 {
        crate::wire::encode_base64_into(body, &mut answer);
        answer.push_str("\",\"body_encoding\":\"base64\"");
    } else {
        match std::str::from_utf8(body) {
            Ok(text) => escape_into(text, &mut answer),
            Err(_) => {
                for byte in body {
                    escape_char(char::from(*byte), &mut answer);
                }
            }
        }
        answer.push('"');
    }
    answer.push_str(",\"headers\":");
    answer.push_str(&headers);
    answer.push_str(",\"status\":");
    answer.push_str(&status.to_string());
    answer.push('}');
    answer
}

// `text` escaped as serde_json escapes a string's contents, its runs of
// bytes that need none copied whole.
fn escape_into(text: &str, out: &mut String) {
    let mut run = 0;
    for (at, byte) in text.bytes().enumerate() {
        if byte < 0x20 || byte == b'"' || byte == b'\\' {
            out.push_str(&text[run..at]);
            escape_char(char::from(byte), out);
            run = at + 1;
        }
    }
    out.push_str(&text[run..]);
}

fn escape_char(c: char, out: &mut String) {
    match c {
        '"' => out.push_str("\\\""),
        '\\' => out.push_str("\\\\"),
        '\n' => out.push_str("\\n"),
        '\r' => out.push_str("\\r"),
        '\t' => out.push_str("\\t"),
        '\u{08}' => out.push_str("\\b"),
        '\u{0c}' => out.push_str("\\f"),
        c if (c as u32) < 0x20 => {
            out.push_str("\\u00");
            out.push(char::from(b"0123456789abcdef"[(c as usize) >> 4]));
            out.push(char::from(b"0123456789abcdef"[(c as usize) & 0xf]));
        }
        c => out.push(c),
    }
}

/// The guest's answer to a refusal, which the runner reports to CYFR when
/// it is one CYFR records and did not decide itself.
pub(super) async fn refused_answer(run: &Run, refused: Refusal) -> wasmtime::Result<String> {
    record(&run.host, &refused).await?;
    Ok(error_json(&refused.kind, &refused.message))
}

/// Report `refused` to CYFR for its record, when CYFR records it and did
/// not decide it itself.
pub(super) async fn record(host: &crate::attempt::Host, refused: &Refusal) -> wasmtime::Result<()> {
    if !refused.recorded() {
        return Ok(());
    }
    let outcome = host
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

/// What a request's `http.request` event names, beside its status: its
/// component, method and the host it asked for, and when it began.
#[derive(Clone)]
pub struct EventFields {
    component_ref: String,
    method: String,
    hostname: String,
    started: Instant,
}

impl EventFields {
    pub(super) fn of(run: &Run, asked: &Asked, started: Instant) -> EventFields {
        EventFields {
            component_ref: run.component_ref.clone(),
            method: asked.method.clone(),
            hostname: asked.host.clone(),
            started,
        }
    }

    /// Send the event with `status`, an HTTP status or why it has none; its
    /// `system_time` in microseconds since the epoch, as the roster takes it.
    pub async fn send(&self, host: &crate::attempt::Host, status: Meta) {
        let system_time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| {
                u64::try_from(since.as_micros()).unwrap_or(u64::MAX)
            });
        host.event(Event {
            name: "http.request",
            measurements: vec![
                ("duration_ms", super::storage::elapsed_ms(self.started)),
                ("system_time", system_time),
            ],
            metadata: vec![
                ("component_ref", Meta::text(&self.component_ref)),
                ("method", Meta::text(&self.method)),
                ("hostname", Meta::text(&self.hostname)),
                ("status", status),
            ],
        })
        .await;
    }
}
