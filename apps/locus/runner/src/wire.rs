// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The worker protocol as it crosses to CYFR (`Prima.WorkerWire`): a host
//! call's body, its answer, the base URL an assignment names, and the
//! grammars and encodings every wire of the protocol shares.
//!
//! A request body is `{"v": 3, "op": <callback>, "args": {...}}`, its
//! members in that order. An answer is `{"v": 3, "ok": value}` and
//! nothing else, or `{"v": 3, "error": <name>, ...}` with a string name
//! and no `ok`; anything else, at another version included, is no answer
//! (`read_answer`). `tests/fixtures/host_api.json` holds both.

use base64::Engine as _;
use base64::alphabet;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use serde_json::{Map, Value};

/// The wire's version, which every request body and answer carries as `v`.
pub const VERSION: u64 = 3;

/// The largest integer every JSON reader holds exactly, 2^53 − 1: the
/// domain of every integer field of the protocol.
pub const MAX_INTEGER: u64 = 9_007_199_254_740_991;

/// Standard base64 with its padding, as every body and input crosses.
/// Decoding refuses a missing or extra pad and bits past the last byte, so
/// one text spells one value.
pub const BASE64: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::RequireCanonical),
);

/// Unpadded base64url, as MACs, sealed values and tokens are written.
pub const BASE64URL: GeneralPurpose = GeneralPurpose::new(
    &alphabet::URL_SAFE,
    GeneralPurposeConfig::new()
        .with_encode_padding(false)
        .with_decode_padding_mode(DecodePaddingMode::RequireNone),
);

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

/// The bytes 64 lowercase hexadecimal digits spell, or none.
pub fn hex_key(text: &str) -> Option<[u8; 32]> {
    if text.len() != 64 || !text.bytes().all(is_lower_hex) {
        return None;
    }
    let mut key = [0u8; 32];
    for (index, pair) in text.as_bytes().chunks(2).enumerate() {
        let digit = |b: u8| {
            if b.is_ascii_digit() {
                b - b'0'
            } else {
                b - b'a' + 10
            }
        };
        key[index] = (digit(pair[0]) << 4) | digit(pair[1]);
    }
    Some(key)
}

/// `text` as a JSON string, quoted and escaped.
pub fn json_string(text: &str) -> String {
    Value::String(text.to_owned()).to_string()
}

/// The request body for `op` with `args` (a JSON object), before it is
/// sealed: `v`, then `op`, then `args`.
pub fn request_body(op: &str, args: &Map<String, Value>) -> String {
    format!(
        "{{\"v\":{VERSION},\"op\":{},\"args\":{}}}",
        json_string(op),
        Value::Object(args.clone())
    )
}

/// What an answer at this wire's version says.
#[derive(Debug, Clone, PartialEq)]
pub enum Answer {
    /// `{"v": 3, "ok": value}`.
    Ok(Value),
    /// `{"v": 3, "error": name, ...}`: the refusal and its other members.
    Error {
        name: String,
        fields: Map<String, Value>,
    },
}

/// What a decoded answer says, or none when it is no answer at this
/// version: whether the call acted is then unknown.
pub fn read_answer(answer: &Value) -> Option<Answer> {
    let object = answer.as_object()?;
    if object.get("v").and_then(Value::as_u64) != Some(VERSION) {
        return None;
    }
    if let Some(value) = object.get("ok") {
        return (object.len() == 2).then(|| Answer::Ok(value.clone()));
    }
    let name = object.get("error")?.as_str()?.to_owned();
    let fields = object
        .iter()
        .filter(|(key, _)| *key != "v" && *key != "error")
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    Some(Answer::Error { name, fields })
}

/// Whether `text` is a base URL a route is appended to as it is: an `http`
/// or `https` URL with a host, and nothing after its authority (no path,
/// query, fragment or user information).
pub fn is_base_url(text: &str) -> bool {
    let Some((scheme, authority)) = text.split_once("://") else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case("http") && !scheme.eq_ignore_ascii_case("https") {
        return false;
    }
    if authority.contains(['/', '?', '#', '@']) {
        return false;
    }
    // A port follows the host's last colon, outside an IPv6 literal's
    // brackets.
    let host = match authority.rfind(':') {
        Some(colon) if !authority[colon..].contains(']') => &authority[..colon],
        _ => authority,
    };
    let host = host
        .strip_prefix('[')
        .and_then(|literal| literal.strip_suffix(']'))
        .unwrap_or(host);
    !host.is_empty()
}

/// Bytes decoded from standard base64 with its padding, or none.
pub fn decode_base64(text: &str) -> Option<Vec<u8>> {
    BASE64.decode(text).ok()
}

/// `bytes` in standard base64 with its padding.
pub fn encode_base64(bytes: &[u8]) -> String {
    BASE64.encode(bytes)
}
