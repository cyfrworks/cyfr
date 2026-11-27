// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! How a runner signs and seals its host calls (`Prima.MacEnvelope`,
//! `Prima.WorkerAuth`), under the two keys of the attempt it runs, which
//! its service opened and handed it on the control channel. A runner holds
//! no other key: it derives nothing, and verifies nothing CYFR signed.
//!
//! - A host call's header is `v1 kind=call`, then each field of the call
//!   as `name=value` in the envelope's order, the body's hex SHA-256 as
//!   `body=` and the MAC as `mac=`: the unpadded base64url HMAC-SHA256,
//!   under the attempt's call key, of the canonical string, which is
//!   `cyfr-locus/v1/runtime/call`, each field's value and the body's hex
//!   SHA-256, one per line.
//! - A sealed value is `base64url(iv ‖ tag ‖ ciphertext)`, unpadded, under
//!   AES-256-GCM with the attempt's seal key, its additional data a label
//!   and the call's field values, one per line: the body under
//!   `cyfr-locus/v1/runtime/call-body`, the answer under
//!   `cyfr-locus/v1/runtime/call-answer`, so each opens only as the
//!   direction and the call it was sealed for.
//!
//! Every field value is 1 to 256 bytes of printable ASCII without spaces,
//! and every integer 0 to 2^53 − 1 in decimal, so no canonical string or
//! label splits two ways. `tests/fixtures/worker_auth.json` and
//! `tests/fixtures/host_api.json` hold every header and sealed value.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize as _, Zeroizing};

use crate::wire::{MAX_INTEGER, decode_base64url, encode_base64url, hex, is_id};

/// A 32-byte key, cleared when it is dropped. It is held behind one
/// allocation, so moving a key moves a pointer and leaves no copy of its
/// bytes behind; a clone is a second allocation, cleared as it drops.
pub struct Key(Box<[u8; 32]>);

impl Key {
    /// A key of zeroes, to be written in place (`bytes_mut`).
    pub fn zeroed() -> Key {
        Key(Box::new([0u8; 32]))
    }

    /// The key's bytes, to write in place.
    pub fn bytes_mut(&mut self) -> &mut [u8; 32] {
        &mut self.0
    }
}

impl std::ops::Deref for Key {
    type Target = [u8; 32];

    fn deref(&self) -> &[u8; 32] {
        &self.0
    }
}

impl Clone for Key {
    fn clone(&self) -> Key {
        let mut key = Key::zeroed();
        key.bytes_mut().copy_from_slice(&self.0[..]);
        key
    }
}

impl Drop for Key {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl From<[u8; 32]> for Key {
    /// A key of `bytes`, which the caller's own copy still holds.
    fn from(bytes: [u8; 32]) -> Key {
        let mut key = Key::zeroed();
        *key.bytes_mut() = bytes;
        key
    }
}

/// The label a runtime key or signature is under: the island's domain and
/// the runtime's name.
pub const RUNTIME_LABEL: &str = "cyfr-locus/v1/runtime";

/// The kind a host call's header names.
pub const CALL_KIND: &str = "call";

/// The additional data's label of a host call's body.
pub const BODY_LABEL: &str = "cyfr-locus/v1/runtime/call-body";

/// The additional data's label of a host call's answer.
pub const ANSWER_LABEL: &str = "cyfr-locus/v1/runtime/call-answer";

/// The bytes a sealed value adds to its plaintext: its IV and its tag.
const IV_BYTES: usize = 12;
const TAG_BYTES: usize = 16;

/// A host call header's fields in the envelope's order, each a string or
/// an integer.
const CALL_FIELDS: [(&str, FieldType); 11] = [
    ("athanor_id", FieldType::String),
    ("execution_id", FieldType::String),
    ("attempt", FieldType::String),
    ("fence", FieldType::Integer),
    ("generation", FieldType::Integer),
    ("service", FieldType::String),
    ("boot", FieldType::String),
    ("runner", FieldType::String),
    ("member", FieldType::String),
    ("ts", FieldType::Integer),
    ("nonce", FieldType::String),
];

#[derive(Clone, Copy)]
enum FieldType {
    String,
    Integer,
}

/// The longest a host call's header is: its version and kind, each field
/// at its longest (a string of 256 bytes, an integer of 16 digits), the
/// 64 digits of the body's hash and the 43 characters of a MAC.
pub const MAX_CALL_HEADER_BYTES: usize = {
    let mut bytes = "v1 kind=call".len() + " body=".len() + 64 + " mac=".len() + 43;
    let mut index = 0;
    while index < CALL_FIELDS.len() {
        let (name, kind) = CALL_FIELDS[index];
        bytes += 2
            + name.len()
            + match kind {
                FieldType::String => 256,
                FieldType::Integer => 16,
            };
        index += 1;
    }
    bytes
};

/// The attempt an attempt's keys are bound to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attempt {
    pub athanor_id: String,
    pub execution_id: String,
    pub attempt: String,
    pub fence: u64,
    pub generation: u64,
    pub service: String,
}

/// An attempt and the two keys its runner signs and seals with.
#[derive(Clone)]
pub struct AttemptKeys {
    pub attempt: Attempt,
    pub call: Key,
    pub seal: Key,
}

impl std::fmt::Debug for AttemptKeys {
    // The keys never reach a log.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AttemptKeys")
            .field("attempt", &self.attempt)
            .finish_non_exhaustive()
    }
}

/// A host call's header fields: its attempt's, the boot and the runner
/// presenting it, the member it is addressed to, `ts` in Unix ms and a
/// nonce.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CallFields {
    pub attempt: Attempt,
    pub boot: String,
    pub runner: String,
    pub member: String,
    pub ts: u64,
    pub nonce: String,
}

/// A field of a call that no header can carry: its name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidField(pub &'static str);

/// A sealed value that does not open under the key, label and fields given.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Unsealable;

/// Which half of a host call a sealed value is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Body,
    Answer,
}

impl Direction {
    fn label(self) -> &'static str {
        match self {
            Direction::Body => BODY_LABEL,
            Direction::Answer => ANSWER_LABEL,
        }
    }
}

impl CallFields {
    /// Each field's value as the header and the canonical string write it,
    /// in the envelope's order.
    fn values(&self) -> Result<[String; 11], InvalidField> {
        let a = &self.attempt;
        let strings = [
            (0, &a.athanor_id),
            (1, &a.execution_id),
            (2, &a.attempt),
            (5, &a.service),
            (6, &self.boot),
            (7, &self.runner),
            (8, &self.member),
            (10, &self.nonce),
        ];
        let integers = [(3, a.fence), (4, a.generation), (9, self.ts)];
        let mut values: [String; 11] = Default::default();
        for (index, value) in strings {
            if !is_id(value) {
                return Err(InvalidField(CALL_FIELDS[index].0));
            }
            values[index].clone_from(value);
        }
        for (index, value) in integers {
            if value > MAX_INTEGER {
                return Err(InvalidField(CALL_FIELDS[index].0));
            }
            values[index] = value.to_string();
        }
        Ok(values)
    }
}

/// The canonical string a host call's signature covers, over `body`.
pub fn canonical(fields: &CallFields, body: &[u8]) -> Result<String, InvalidField> {
    let values = fields.values()?;
    let mut lines = vec![format!("{RUNTIME_LABEL}/{CALL_KIND}")];
    lines.extend(values);
    lines.push(sha256_hex(body));
    Ok(lines.join("\n"))
}

/// The header a runner presents a host call of `fields` and `body` under,
/// signed with the attempt's call key.
pub fn host_call_header(
    call_key: &[u8; 32],
    fields: &CallFields,
    body: &[u8],
) -> Result<String, InvalidField> {
    let canonical = canonical(fields, body)?;
    let values = fields.values()?;
    let mut tokens = vec![format!("v1 kind={CALL_KIND}")];
    for ((name, _kind), value) in CALL_FIELDS.iter().zip(values.iter()) {
        tokens.push(format!("{name}={value}"));
    }
    tokens.push(format!("body={}", sha256_hex(body)));
    tokens.push(format!(
        "mac={}",
        encode_base64url(&hmac_sha256(call_key, canonical.as_bytes()))
    ));
    Ok(tokens.join(" "))
}

/// `plaintext` sealed with the attempt's seal key as `direction` of the
/// call `fields` names, under the 12-byte `iv`.
pub fn seal_call(
    seal_key: &[u8; 32],
    direction: Direction,
    fields: &CallFields,
    plaintext: &[u8],
    iv: &[u8; IV_BYTES],
) -> Result<String, InvalidField> {
    let aad = additional_data(direction, fields)?;
    let cipher = Aes256Gcm::new(seal_key.into());
    let sealed = cipher
        .encrypt(
            &Nonce::from(*iv),
            Payload {
                msg: plaintext,
                aad: aad.as_bytes(),
            },
        )
        .expect("AES-GCM seals any message a host call carries");
    // The cipher writes the ciphertext and then its tag; the wire carries
    // the IV, the tag and then the ciphertext.
    let (ciphertext, tag) = sealed.split_at(sealed.len() - TAG_BYTES);
    let mut bytes = Vec::with_capacity(IV_BYTES + sealed.len());
    bytes.extend_from_slice(iv);
    bytes.extend_from_slice(tag);
    bytes.extend_from_slice(ciphertext);
    Ok(encode_base64url(&bytes))
}

/// The plaintext `sealed` holds as `direction` of the call `fields` names,
/// opened with the attempt's seal key; anything else is `Unsealable`.
pub fn open_call(
    seal_key: &[u8; 32],
    direction: Direction,
    fields: &CallFields,
    sealed: &[u8],
) -> Result<Zeroizing<Vec<u8>>, Unsealable> {
    let aad = additional_data(direction, fields).map_err(|_| Unsealable)?;
    let bytes = decode_base64url(sealed).ok_or(Unsealable)?;
    if bytes.len() < IV_BYTES + TAG_BYTES {
        return Err(Unsealable);
    }
    let (iv, rest) = bytes.split_at(IV_BYTES);
    let (tag, ciphertext) = rest.split_at(TAG_BYTES);
    let mut message = Vec::with_capacity(rest.len());
    message.extend_from_slice(ciphertext);
    message.extend_from_slice(tag);
    let iv: [u8; IV_BYTES] = iv.try_into().map_err(|_| Unsealable)?;
    Aes256Gcm::new(seal_key.into())
        .decrypt(
            &Nonce::from(iv),
            Payload {
                msg: &message,
                aad: aad.as_bytes(),
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| Unsealable)
}

fn additional_data(direction: Direction, fields: &CallFields) -> Result<String, InvalidField> {
    let mut lines = vec![direction.label().to_owned()];
    lines.extend(fields.values()?);
    Ok(lines.join("\n"))
}

/// The window a host call's header's `ts` is honoured within, either way of
/// now, in milliseconds (`Prima.WorkerAuth.window_ms/0`).
pub const WINDOW_MS: u64 = 30_000;

/// Why a header CYFR's listener answered does not verify under the call key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Unverified;

/// The fields and the body hash of a host call's `header`, verified under
/// the attempt's call key at `now` (Unix ms) as `Prima.WorkerAuth`
/// verifies one: exactly its version, kind, fields in the envelope's order,
/// body hash and MAC, its `ts` within `WINDOW_MS` of now, and its MAC the
/// call key's over its canonical string.
pub fn verify_call_header(
    call_key: &[u8; 32],
    header: &str,
    now: u64,
) -> Result<(CallFields, String), Unverified> {
    let mut tokens = header.split(' ');
    if tokens.next() != Some("v1") || tokens.next() != Some(&format!("kind={CALL_KIND}")) {
        return Err(Unverified);
    }
    let mut values: Vec<&str> = Vec::with_capacity(CALL_FIELDS.len());
    for (name, _kind) in CALL_FIELDS {
        let value = tokens
            .next()
            .and_then(|token| token.strip_prefix(name))
            .and_then(|token| token.strip_prefix('='))
            .ok_or(Unverified)?;
        values.push(value);
    }
    let body_hash = tokens
        .next()
        .and_then(|token| token.strip_prefix("body="))
        .filter(|hash| hash.len() == 64 && hash.bytes().all(crate::wire::is_lower_hex))
        .ok_or(Unverified)?;
    let mac = tokens
        .next()
        .and_then(|token| token.strip_prefix("mac="))
        .ok_or(Unverified)?;
    if tokens.next().is_some() {
        return Err(Unverified);
    }
    let integer = |text: &str| {
        (!text.is_empty()
            && text.len() <= 16
            && text.bytes().all(|b| b.is_ascii_digit())
            && (text == "0" || !text.starts_with('0')))
        .then(|| text.parse::<u64>().ok())
        .flatten()
        .filter(|value| *value <= MAX_INTEGER)
        .ok_or(Unverified)
    };
    let fields = CallFields {
        attempt: Attempt {
            athanor_id: values[0].to_owned(),
            execution_id: values[1].to_owned(),
            attempt: values[2].to_owned(),
            fence: integer(values[3])?,
            generation: integer(values[4])?,
            service: values[5].to_owned(),
        },
        boot: values[6].to_owned(),
        runner: values[7].to_owned(),
        member: values[8].to_owned(),
        ts: integer(values[9])?,
        nonce: values[10].to_owned(),
    };
    if fields.ts.abs_diff(now) > WINDOW_MS {
        return Err(Unverified);
    }
    let mut lines = vec![format!("{RUNTIME_LABEL}/{CALL_KIND}")];
    lines.extend(fields.values().map_err(|_| Unverified)?);
    lines.push(body_hash.to_owned());
    let expected = encode_base64url(&hmac_sha256(call_key, lines.join("\n").as_bytes()));
    if !constant_time_equal(expected.as_bytes(), mac.as_bytes()) {
        return Err(Unverified);
    }
    Ok((fields, body_hash.to_owned()))
}

fn constant_time_equal(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |diff, (x, y)| diff | (x ^ y)) == 0
}

// ============================================================================
// An attached request's answer frames
// ============================================================================

/// The additional data's label of an attached request's answer frame.
pub const FRAME_LABEL: &str = "cyfr-locus/v1/runtime/frame-answer";

/// The most bytes one answer frame spans after its length prefix, its kind
/// byte and sealed value (`Prima.WorkerAuth.max_frame_bytes/0`).
pub const MAX_ANSWER_FRAME_BYTES: usize = 65_536;

/// The most body bytes one `chunk` frame carries.
pub const MAX_CHUNK_BYTES: usize = 32_768;

/// The most bytes an `error` frame's sentence spans.
pub const MAX_FRAME_MESSAGE_BYTES: usize = 512;

/// One answer frame, read.
#[derive(PartialEq, Eq)]
pub enum AnswerFrame {
    Head {
        status: u16,
        headers: Vec<(String, String)>,
    },
    Chunk(Zeroizing<Vec<u8>>),
    End,
    Error {
        kind: String,
        message: String,
    },
}

impl std::fmt::Debug for AnswerFrame {
    // A chunk's bytes never reach a log.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AnswerFrame::Head { status, .. } => write!(f, "Head({status})"),
            AnswerFrame::Chunk(body) => write!(f, "Chunk({} bytes)", body.len()),
            AnswerFrame::End => f.write_str("End"),
            AnswerFrame::Error { kind, .. } => write!(f, "Error({kind})"),
        }
    }
}

/// Why an answer ends as an error (`Prima.WorkerAuth.read_frame/2`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameRefusal {
    FrameTooLarge,
    Malformed,
    UnknownKind,
    OutOfSequence,
    Unsealable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Place {
    Head,
    Body,
    Done,
}

/// A reader of one attached request's answer frames, for the call id the
/// runner chose, under the attempt's seal key.
pub struct FrameReader {
    seal_key: Key,
    call_id: String,
    seq: u64,
    place: Place,
}

impl FrameReader {
    pub fn new(seal_key: &Key, call_id: &str) -> FrameReader {
        FrameReader {
            seal_key: seal_key.clone(),
            call_id: call_id.to_owned(),
            seq: 0,
            place: Place::Head,
        }
    }

    /// The call id the frames are sealed for.
    pub fn call_id(&self) -> &str {
        &self.call_id
    }

    /// Whether the answer read whole: its `end` or `error` read.
    pub fn done(&self) -> bool {
        self.place == Place::Done
    }

    /// One frame, its kind byte and sealed value, opened and read as the
    /// next frame of the call, in `Prima.WorkerAuth.read_frame/2`'s order:
    /// the frame's form, its kind, its place in the answer's order, its
    /// seal, then what its kind carries.
    pub fn read(&mut self, frame: &[u8]) -> Result<AnswerFrame, FrameRefusal> {
        let [byte, sealed @ ..] = frame else {
            return Err(FrameRefusal::Malformed);
        };
        if sealed.is_empty() {
            return Err(FrameRefusal::Malformed);
        }
        if frame.len() > MAX_ANSWER_FRAME_BYTES {
            return Err(FrameRefusal::FrameTooLarge);
        }
        let kind = match byte {
            b'h' => "head",
            b'c' => "chunk",
            b'e' => "end",
            b'x' => "error",
            _ => return Err(FrameRefusal::UnknownKind),
        };
        let in_place = match self.place {
            Place::Head => matches!(kind, "head" | "error"),
            Place::Body => matches!(kind, "chunk" | "end" | "error"),
            Place::Done => false,
        };
        if !in_place {
            return Err(FrameRefusal::OutOfSequence);
        }
        let aad = format!("{FRAME_LABEL}\n{}\n{}\n{kind}", self.call_id, self.seq);
        let plaintext =
            open_sealed(&self.seal_key, &aad, sealed).ok_or(FrameRefusal::Unsealable)?;
        let read = match kind {
            "head" => read_head(&plaintext)?,
            "chunk" if plaintext.len() > MAX_CHUNK_BYTES => {
                return Err(FrameRefusal::FrameTooLarge);
            }
            "chunk" => AnswerFrame::Chunk(plaintext),
            "end" if plaintext.is_empty() => AnswerFrame::End,
            "end" => return Err(FrameRefusal::Malformed),
            _error => read_error(&plaintext)?,
        };
        self.seq += 1;
        self.place = match kind {
            "head" | "chunk" => Place::Body,
            _ => Place::Done,
        };
        Ok(read)
    }
}

fn read_head(plaintext: &[u8]) -> Result<AnswerFrame, FrameRefusal> {
    let json = crate::wire::parse(plaintext).ok_or(FrameRefusal::Malformed)?;
    let Some(head) = json.value().as_object().filter(|head| head.len() == 2) else {
        return Err(FrameRefusal::Malformed);
    };
    let status = head
        .get("status")
        .and_then(|status| crate::wire::bounded(status, 100..=599).ok())
        .ok_or(FrameRefusal::Malformed)?;
    let Some(serde_json::Value::Array(pairs)) = head.get("headers") else {
        return Err(FrameRefusal::Malformed);
    };
    let headers = pairs
        .iter()
        .map(|pair| match pair.as_array().map(Vec::as_slice) {
            Some(
                [
                    serde_json::Value::String(name),
                    serde_json::Value::String(value),
                ],
            ) => Ok((name.clone(), value.clone())),
            _ => Err(FrameRefusal::Malformed),
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(AnswerFrame::Head {
        status: u16::try_from(status).expect("a status is under 600"),
        headers,
    })
}

fn read_error(plaintext: &[u8]) -> Result<AnswerFrame, FrameRefusal> {
    let json = crate::wire::parse(plaintext).ok_or(FrameRefusal::Malformed)?;
    let error = json
        .value()
        .as_object()
        .filter(|error| error.len() == 2)
        .ok_or(FrameRefusal::Malformed)?;
    match (error.get("type"), error.get("message")) {
        (Some(serde_json::Value::String(kind)), Some(serde_json::Value::String(message)))
            if !kind.is_empty() && message.len() <= MAX_FRAME_MESSAGE_BYTES =>
        {
            Ok(AnswerFrame::Error {
                kind: kind.clone(),
                message: message.clone(),
            })
        }
        _ => Err(FrameRefusal::Malformed),
    }
}

// A sealed value, `base64url(iv ‖ tag ‖ ciphertext)`, opened under `key`
// with `aad`.
fn open_sealed(key: &[u8; 32], aad: &str, sealed: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let bytes = Zeroizing::new(decode_base64url(sealed)?);
    if bytes.len() < IV_BYTES + TAG_BYTES {
        return None;
    }
    let (iv, rest) = bytes.split_at(IV_BYTES);
    let (tag, ciphertext) = rest.split_at(TAG_BYTES);
    let mut message = Zeroizing::new(Vec::with_capacity(rest.len()));
    message.extend_from_slice(ciphertext);
    message.extend_from_slice(tag);
    let iv: [u8; IV_BYTES] = iv.try_into().ok()?;
    Aes256Gcm::new(key.into())
        .decrypt(
            &Nonce::from(iv),
            Payload {
                msg: &message,
                aad: aad.as_bytes(),
            },
        )
        .ok()
        .map(Zeroizing::new)
}

/// The hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

fn hmac_sha256(key: &[u8; 32], message: &[u8]) -> Vec<u8> {
    let mut mac =
        <Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("HMAC takes a key of any length");
    mac.update(message);
    mac.finalize().into_bytes().to_vec()
}
