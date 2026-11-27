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
use zeroize::Zeroizing;

use crate::wire::{MAX_INTEGER, decode_base64url, encode_base64url, hex, is_id};

/// A 32-byte key, cleared when it is dropped.
pub type Key = Zeroizing<[u8; 32]>;

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
