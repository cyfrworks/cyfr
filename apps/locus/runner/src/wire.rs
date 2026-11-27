// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The worker protocol as it crosses to CYFR (`Prima.WorkerWire`): a host
//! call's body, its answer, the base URL an assignment names, and the JSON,
//! URL, base64 and text forms every wire of the protocol shares.
//!
//! A request body is `{"v": 3, "op": <callback>, "args": {...}}`, its
//! members in that order. An answer is `{"v": 3, "ok": value}` and
//! nothing else, or `{"v": 3, "error": <name>, ...}` with a string name
//! and no `ok`; anything else, at another version included, is no answer
//! (`read_answer`). `tests/fixtures/host_api.json` holds both.
//!
//! JSON a peer sends is read as Prima's reader reads it (`parse`): a
//! member given twice is its first, an integer of any size is an integer
//! and kept whole, and a number past a double's range is no JSON. What is
//! read is held as `Json`, whose strings are cleared when it is dropped and
//! whose `Debug` prints none of it. Two things are not cleared: the
//! parser's own scratch buffers, which it frees itself, and the text of
//! each number. A refused document's parts are freed as the parser leaves
//! them.
//!
//! Two kinds of document Prima reads are refused here. One nested deeper
//! than `MAX_DEPTH` arrays and objects: the parser recurses once a level,
//! so the depth is counted before it reads anything (`read` answers
//! `Unread::TooDeep`), and every thread that parses has the stack for that
//! depth (`STACK_BYTES`), the guest's fiber among them. And one with a
//! member named `$serde_json::private::Number`, the name under which the
//! parser hands this reader a number, which is never read as one.
//!
//! Two stated differences from the Elixir runner, whose readers go with it
//! (R5). A number in a host answer's data is carried as the text CYFR
//! wrote, its digits kept exactly: an integer of any length whole, a
//! decimal never re-read as a double. Only an exponent may be respelled,
//! its letter lowercased and a positive exponent given its `+` (`1.0E20` is
//! handed on as `1.0e+20`), which changes no value. Jason rounds
//! `1.00000000000000001` to `1.0`, reads `1e-400` as `0.0` and refuses an
//! integer past 1,024 digits. And `crate::control::encode` of an `assign`,
//! the service's direction, which a runner never encodes, writes plain
//! copies of the token and of the keys' hex.

use std::io::Write as _;

use base64::Engine as _;
use base64::alphabet;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use serde::Deserialize as _;
use serde::de::{self, Deserializer, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Number, Value};
use zeroize::{Zeroize, Zeroizing};

/// The wire's version, which every request body and answer carries as `v`.
pub const VERSION: u64 = 3;

/// The largest integer every JSON reader holds exactly, 2^53 − 1: the
/// domain of every integer field of the protocol.
pub const MAX_INTEGER: u64 = 9_007_199_254_740_991;

/// Standard base64 with its padding, as every body and input crosses. It
/// reads what Prima's decoder reads: the padding is required, and bits
/// past the last byte are ignored.
const BASE64: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new()
        .with_decode_padding_mode(DecodePaddingMode::RequireCanonical)
        .with_decode_allow_trailing_bits(true),
);

/// Unpadded base64url, as MACs, sealed values and tokens are written. It
/// reads them without their padding or with exactly the padding they
/// would carry, ignoring bits past the last byte, as Prima's decoder does.
const BASE64URL: GeneralPurpose = GeneralPurpose::new(
    &alphabet::URL_SAFE,
    GeneralPurposeConfig::new()
        .with_encode_padding(false)
        .with_decode_padding_mode(DecodePaddingMode::RequireNone)
        .with_decode_allow_trailing_bits(true),
);
const BASE64URL_PADDED: GeneralPurpose = GeneralPurpose::new(
    &alphabet::URL_SAFE,
    GeneralPurposeConfig::new()
        .with_decode_padding_mode(DecodePaddingMode::RequireCanonical)
        .with_decode_allow_trailing_bits(true),
);

/// Bytes decoded from standard base64 with its padding, or none.
pub fn decode_base64(text: &str) -> Option<Vec<u8>> {
    BASE64.decode(text).ok()
}

/// `bytes` in standard base64 with its padding.
pub fn encode_base64(bytes: &[u8]) -> String {
    BASE64.encode(bytes)
}

/// Bytes decoded from base64url, unpadded or with its padding, or none.
pub fn decode_base64url(text: impl AsRef<[u8]>) -> Option<Vec<u8>> {
    let text = text.as_ref();
    BASE64URL
        .decode(text)
        .or_else(|_| BASE64URL_PADDED.decode(text))
        .ok()
}

/// `bytes` in standard base64 with its padding, written at the end of
/// `text`.
pub fn encode_base64_into(bytes: &[u8], text: &mut String) {
    BASE64.encode_string(bytes, text);
}

/// `bytes` in unpadded base64url.
pub fn encode_base64url(bytes: &[u8]) -> String {
    BASE64URL.encode(bytes)
}

/// `bytes` in unpadded base64url, written at the end of `text`.
pub fn encode_base64url_into(bytes: &[u8], text: &mut String) {
    BASE64URL.encode_string(bytes, text);
}

/// An identifier: 1 to 256 bytes of printable ASCII without spaces.
pub fn is_id(text: &str) -> bool {
    (1..=256).contains(&text.len()) && is_text(text)
}

/// Text of printable ASCII without spaces, of any length but none.
pub fn is_text(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| (0x21..=0x7e).contains(&b))
}

/// A digest: `sha256:` and 64 lowercase hexadecimal digits.
pub fn is_digest(text: &str) -> bool {
    text.strip_prefix("sha256:")
        .is_some_and(|hex| hex.len() == 64 && hex.bytes().all(is_lower_hex))
}

/// A lowercase hexadecimal digit.
pub fn is_lower_hex(byte: u8) -> bool {
    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
}

/// `bytes` as lowercase hexadecimal.
pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(char::from(DIGITS[usize::from(byte >> 4)]));
        text.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    text
}

/// The key 64 lowercase hexadecimal digits spell, or none, written in place
/// in the one allocation that holds it (`crate::auth::Key`).
pub fn hex_key(text: &str) -> Option<crate::auth::Key> {
    if text.len() != 64 || !text.bytes().all(is_lower_hex) {
        return None;
    }
    let mut key = crate::auth::Key::zeroed();
    let bytes = key.bytes_mut();
    for (index, pair) in text.as_bytes().chunks(2).enumerate() {
        let digit = |b: u8| {
            if b.is_ascii_digit() {
                b - b'0'
            } else {
                b - b'a' + 10
            }
        };
        bytes[index] = (digit(pair[0]) << 4) | digit(pair[1]);
    }
    Some(key)
}

/// `text` as a JSON string, quoted and escaped.
pub fn json_string(text: &str) -> String {
    Value::String(text.to_owned()).to_string()
}

// ============================================================================
// JSON as a peer sends it
// ============================================================================

/// A JSON value a peer sent, its strings cleared when it is dropped.
#[derive(Default, PartialEq)]
pub struct Json(Value);

impl Json {
    /// The value, to read.
    pub fn value(&self) -> &Value {
        &self.0
    }

    /// The value of member `name` of an object, taken out of it, or none.
    pub fn take_member(&mut self, name: &str) -> Option<Json> {
        self.0.as_object_mut()?.remove(name).map(Json)
    }

    /// The value, taken out to be sent on: what is taken is no longer
    /// cleared when this is dropped.
    pub fn take_value(&mut self) -> Value {
        std::mem::take(&mut self.0)
    }

    /// A value made here, held as one a peer sent.
    pub fn from_value(value: Value) -> Json {
        Json(value)
    }
}

impl std::fmt::Debug for Json {
    // What a peer sent never reaches a log.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Json(..)")
    }
}

impl Drop for Json {
    fn drop(&mut self) {
        wipe(std::mem::take(&mut self.0));
    }
}

/// Clear every string of `value`, keys included, without recursing.
fn wipe(value: Value) {
    let mut values = vec![value];
    while let Some(value) = values.pop() {
        match value {
            Value::String(mut text) => text.zeroize(),
            Value::Array(items) => values.extend(items),
            Value::Object(members) => {
                for (mut key, member) in members {
                    key.zeroize();
                    values.push(member);
                }
            }
            Value::Null | Value::Bool(_) | Value::Number(_) => {}
        }
    }
}

/// The deepest nesting of arrays and objects a document is read to. Prima
/// reads any depth, and no document of the protocol comes near this one;
/// a deeper one is refused before the parser, which recurses once a level,
/// reads it.
pub const MAX_DEPTH: usize = 4096;

/// The deepest a guest's output is read to: one level under `MAX_DEPTH`,
/// so CYFR's answer recording it (`{"v": 3, "ok": output}`) reads too.
pub const MAX_OUTPUT_DEPTH: usize = MAX_DEPTH - 1;

/// The stack every thread that parses runs on: the runner's runtime and a
/// guest's fiber. The parser takes about 0.55 KiB a level built for
/// release and 1.7 KiB built for its tests (measured at Rust 1.100), so
/// `MAX_DEPTH` levels take at most 7 MiB of it.
pub const STACK_BYTES: usize = 16 * 1024 * 1024;

/// Why a document is not read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unread {
    /// Nested deeper than `MAX_DEPTH`.
    TooDeep,
    /// Not one JSON value as Prima reads one.
    Malformed,
}

/// The one JSON value `bytes` spell, read as Prima's reader reads it, or
/// none: a document nested past `MAX_DEPTH` among them.
pub fn parse(bytes: &[u8]) -> Option<Json> {
    read(bytes).ok()
}

/// The one JSON value `bytes` spell, or why it is not read.
pub fn read(bytes: &[u8]) -> Result<Json, Unread> {
    if depth(bytes) > MAX_DEPTH {
        return Err(Unread::TooDeep);
    }
    read_within(bytes).ok_or(Unread::Malformed)
}

/// The deepest nesting of arrays and objects in `bytes` outside strings,
/// counted without recursion. A string runs from an unescaped quote to the
/// next, as the parser reads one, so every level the parser enters is
/// counted; bytes that are no JSON are refused by the parser after.
pub fn depth(bytes: &[u8]) -> usize {
    let (mut level, mut deepest) = (0usize, 0usize);
    let (mut string, mut escaped) = (false, false);
    for &byte in bytes {
        if string {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                string = false;
            }
            continue;
        }
        match byte {
            b'"' => string = true,
            b'[' | b'{' => {
                level += 1;
                deepest = deepest.max(level);
            }
            b']' | b'}' => level = level.saturating_sub(1),
            _ => {}
        }
    }
    deepest
}

fn read_within(bytes: &[u8]) -> Option<Json> {
    let mut reader = serde_json::Deserializer::from_slice(bytes);
    reader.disable_recursion_limit();
    let FirstMember(value) = FirstMember::deserialize(&mut reader).ok()?;
    let json = Json(value);
    reader.end().ok()?;
    Some(json)
}

/// The name under which the parser, keeping each number's text, hands a
/// number to a reader as a one-member map.
const NUMBER: &str = "$serde_json::private::Number";

/// A value whose objects keep the first of a member given twice.
struct FirstMember(Value);

impl<'de> serde::Deserialize<'de> for FirstMember {
    fn deserialize<D: Deserializer<'de>>(reader: D) -> Result<Self, D::Error> {
        reader.deserialize_any(FirstMemberVisitor)
    }
}

struct FirstMemberVisitor;

impl<'de> Visitor<'de> for FirstMemberVisitor {
    type Value = FirstMember;

    fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("a JSON value")
    }

    fn visit_bool<E>(self, value: bool) -> Result<FirstMember, E> {
        Ok(FirstMember(Value::Bool(value)))
    }

    fn visit_i64<E>(self, value: i64) -> Result<FirstMember, E> {
        Ok(FirstMember(Value::from(value)))
    }

    fn visit_u64<E>(self, value: u64) -> Result<FirstMember, E> {
        Ok(FirstMember(Value::from(value)))
    }

    fn visit_f64<E: de::Error>(self, value: f64) -> Result<FirstMember, E> {
        Number::from_f64(value)
            .map(|n| FirstMember(Value::Number(n)))
            .ok_or_else(|| E::custom("a number past a double's range"))
    }

    fn visit_str<E>(self, value: &str) -> Result<FirstMember, E> {
        Ok(FirstMember(Value::String(value.to_owned())))
    }

    fn visit_string<E>(self, value: String) -> Result<FirstMember, E> {
        Ok(FirstMember(Value::String(value)))
    }

    fn visit_unit<E>(self) -> Result<FirstMember, E> {
        Ok(FirstMember(Value::Null))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut items: A) -> Result<FirstMember, A::Error> {
        let mut values = Json(Value::Array(Vec::new()));
        while let Some(FirstMember(item)) = items.next_element()? {
            if let Value::Array(list) = &mut values.0 {
                list.push(item);
            }
        }
        Ok(FirstMember(std::mem::take(&mut values.0)))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut members: A) -> Result<FirstMember, A::Error> {
        let mut object = Json(Value::Object(Map::new()));
        while let Some(key) = members.next_key_seed(KeySeed)? {
            let mut key = match key {
                Key::Number => {
                    return members
                        .next_value::<String>()
                        .and_then(|text| number(&text))
                        .map(FirstMember);
                }
                Key::Name(name) => name,
            };
            let FirstMember(member) = members.next_value()?;
            let Value::Object(map) = &mut object.0 else {
                unreachable!("an object")
            };
            if map.contains_key(&key) {
                key.zeroize();
                wipe(member);
            } else {
                map.insert(key, member);
            }
        }
        Ok(FirstMember(std::mem::take(&mut object.0)))
    }
}

/// A member's name, or the parser's own name for a number it hands over.
enum Key {
    Number,
    Name(String),
}

/// A member's name, read as bytes: the parser spells a real member's name
/// so, and the name it hands a number under as text, which tells the two
/// apart. A real member of that name is refused.
struct KeySeed;

impl<'de> de::DeserializeSeed<'de> for KeySeed {
    type Value = Key;

    fn deserialize<D: Deserializer<'de>>(self, reader: D) -> Result<Key, D::Error> {
        reader.deserialize_bytes(KeySeed)
    }
}

impl<'de> Visitor<'de> for KeySeed {
    type Value = Key;

    fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("a member's name")
    }

    fn visit_str<E: de::Error>(self, name: &str) -> Result<Key, E> {
        if name == NUMBER {
            Ok(Key::Number)
        } else {
            Err(E::custom("a member's name the parser did not spell"))
        }
    }

    fn visit_bytes<E: de::Error>(self, name: &[u8]) -> Result<Key, E> {
        match std::str::from_utf8(name) {
            Ok(NUMBER) => Err(E::custom("a member named as the parser names a number")),
            Ok(name) => Ok(Key::Name(name.to_owned())),
            Err(_) => Err(E::custom("a member's name that is no text")),
        }
    }
}

/// The number `text` spells, kept whole; a float past a double's range is
/// refused, as Prima's reader refuses it.
fn number<E: de::Error>(text: &str) -> Result<Value, E> {
    let float = text.contains(['.', 'e', 'E']);
    if float && !text.parse::<f64>().is_ok_and(f64::is_finite) {
        return Err(E::custom("a number past a double's range"));
    }
    serde_json::from_str::<Number>(text)
        .map(Value::Number)
        .map_err(|_| E::custom("no number"))
}

/// What an integer of the protocol reads as.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Integer {
    /// Below zero.
    Negative,
    /// Zero or above; an integer past 2^64 − 1 is held as 2^64 − 1.
    Whole(u64),
}

/// The integer a JSON value is, or none for any other value, a float
/// included.
pub fn integer(value: &Value) -> Option<Integer> {
    let Value::Number(number) = value else {
        return None;
    };
    if number.is_f64() {
        return None;
    }
    if let Some(whole) = number.as_u64() {
        return Some(Integer::Whole(whole));
    }
    match number.as_i64() {
        Some(0) => Some(Integer::Whole(0)),
        Some(_) => Some(Integer::Negative),
        None if number.to_string().starts_with('-') => Some(Integer::Negative),
        None => Some(Integer::Whole(u64::MAX)),
    }
}

/// The non-negative integer a JSON value is, at most `max`; a value past
/// `max` or below zero is `Err(true)`, and any other value `Err(false)`.
pub fn bounded(value: &Value, range: std::ops::RangeInclusive<u64>) -> Result<u64, bool> {
    match integer(value) {
        Some(Integer::Whole(n)) if range.contains(&n) => Ok(n),
        Some(_) => Err(true),
        None => Err(false),
    }
}

// ============================================================================
// Host calls
// ============================================================================

/// The request body for `op` with `args` (a JSON object), before it is
/// sealed: `v`, then `op`, then `args`, written into one buffer of its
/// exact length, which is cleared when it is dropped.
pub fn request_body(op: &str, args: &Map<String, Value>) -> Zeroizing<String> {
    struct Count(usize);
    impl std::io::Write for Count {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0 += bytes.len();
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let head = format!("{{\"v\":{VERSION},\"op\":{},\"args\":", json_string(op));
    let mut count = Count(0);
    serde_json::to_writer(&mut count, args).expect("a JSON object is written");
    let mut bytes = Zeroizing::new(Vec::with_capacity(head.len() + count.0 + 1));
    bytes.extend_from_slice(head.as_bytes());
    serde_json::to_writer(&mut *bytes, args).expect("a JSON object is written");
    bytes.write_all(b"}").expect("a buffer takes a byte");
    Zeroizing::new(String::from_utf8(std::mem::take(&mut *bytes)).expect("JSON is UTF-8"))
}

/// What an answer at this wire's version says. Its `Debug` prints nothing
/// the answer carries, the refusal's name included.
#[derive(PartialEq)]
pub enum Answer {
    /// `{"v": 3, "ok": value}`.
    Ok(Json),
    /// `{"v": 3, "error": name, ...}`: the refusal and its other members.
    Error {
        name: Zeroizing<String>,
        fields: Json,
    },
}

impl std::fmt::Debug for Answer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Answer::Ok(_) => f.write_str("Ok(..)"),
            Answer::Error { .. } => f.write_str("Error(..)"),
        }
    }
}

/// What a decoded answer says, or none when it is no answer at this
/// version: whether the call acted is then unknown.
pub fn read_answer(mut answer: Json) -> Option<Answer> {
    let object = answer.0.as_object()?;
    if integer(object.get("v")?) != Some(Integer::Whole(VERSION)) {
        return None;
    }
    if object.contains_key("ok") {
        if object.len() != 2 {
            return None;
        }
        return answer.take_member("ok").map(Answer::Ok);
    }
    let name = Zeroizing::new(object.get("error")?.as_str()?.to_owned());
    drop(answer.take_member("v"));
    drop(answer.take_member("error"));
    Some(Answer::Error {
        name,
        fields: answer,
    })
}

// ============================================================================
// URLs
// ============================================================================

/// A URL's parts as Elixir's `URI.parse/1` reads them (RFC 3986's
/// appendix B): the scheme lowercased, and each part none when absent. A
/// host loses the brackets around it, and none is an authority without one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Uri<'a> {
    pub scheme: Option<String>,
    pub userinfo: Option<&'a str>,
    pub host: Option<&'a str>,
    /// The text after the host's colon, when the authority names one.
    pub port: Option<&'a str>,
    pub path: Option<&'a str>,
    pub query: Option<&'a str>,
    pub fragment: Option<&'a str>,
}

/// The parts of `text`.
pub fn parse_uri(text: &str) -> Uri<'_> {
    // A scheme is a letter, then letters, digits, `+`, `-` or `.`, and `:`.
    let run = text
        .find(|c: char| !(c.is_ascii_alphanumeric() || "+-.".contains(c)))
        .unwrap_or(text.len());
    let (scheme, rest) = match text.as_bytes().get(run) {
        Some(b':') if text.as_bytes().first().is_some_and(u8::is_ascii_alphabetic) => {
            (Some(text[..run].to_ascii_lowercase()), &text[run + 1..])
        }
        _ => (None, text),
    };
    let (authority, rest) = match rest.strip_prefix("//") {
        Some(after) => {
            let end = after.find(['/', '?', '#']).unwrap_or(after.len());
            (Some(&after[..end]), &after[end..])
        }
        None => (None, rest),
    };
    let end = rest.find(['?', '#']).unwrap_or(rest.len());
    let (path, rest) = (&rest[..end], &rest[end..]);
    let (query, fragment) = match rest.strip_prefix('?') {
        Some(after) => match after.split_once('#') {
            Some((query, fragment)) => (Some(query), Some(fragment)),
            None => (Some(after), None),
        },
        None => (None, rest.strip_prefix('#')),
    };
    let (userinfo, host, port) = match authority {
        None => (None, None, None),
        Some(authority) => split_authority(authority),
    };
    Uri {
        scheme,
        userinfo,
        host,
        port,
        path: (!path.is_empty()).then_some(path),
        query,
        fragment,
    }
}

// An authority's user information, everything before its last `@` with no
// line feed before it; its host: a bracketed address of letters, digits,
// `:` and `.`, or everything up to a colon, then its brackets trimmed; and
// what follows the host's colon.
fn split_authority(authority: &str) -> (Option<&str>, Option<&str>, Option<&str>) {
    let line = authority.find('\n').unwrap_or(authority.len());
    let (userinfo, rest) = match authority[..line].rfind('@') {
        Some(at) => (&authority[..at], &authority[at + 1..]),
        None => ("", authority),
    };
    let bracketed = rest.strip_prefix('[').and_then(|inner| {
        let close = inner.find(|c: char| !(c.is_ascii_alphanumeric() || c == ':' || c == '.'))?;
        (inner.as_bytes()[close] == b']').then(|| &rest[..close + 2])
    });
    let host = bracketed.unwrap_or_else(|| &rest[..rest.find(':').unwrap_or(rest.len())]);
    let port = rest[host.len()..].strip_prefix(':');
    let host = (!host.is_empty()).then(|| host.trim_start_matches('[').trim_end_matches(']'));
    ((!userinfo.is_empty()).then_some(userinfo), host, port)
}

/// Whether `text` is a base URL a route is appended to as it is
/// (`Prima.WorkerWire.base_url/1`): an `http` or `https` URL with a host,
/// and nothing after its authority.
pub fn is_base_url(text: &str) -> bool {
    let uri = parse_uri(text);
    matches!(uri.scheme.as_deref(), Some("http" | "https"))
        && uri.host.is_some_and(|host| !host.is_empty())
        && matches!(uri.path, None | Some("/"))
        && uri.query.is_none()
        && uri.fragment.is_none()
        && uri.userinfo.is_none()
        && !text.ends_with('/')
}

/// Whether `text` is a URL a guest's request may name
/// (`Prima.Network.parse_url/1`): an `http` or `https` URL with a host and
/// no user information.
pub fn is_url(text: &str) -> bool {
    let uri = parse_uri(text);
    matches!(uri.scheme.as_deref(), Some("http" | "https"))
        && uri.host.is_some_and(|host| !host.is_empty())
        && uri.userinfo.is_none()
}
