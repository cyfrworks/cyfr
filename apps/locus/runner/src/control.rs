// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The control channel between a runner and its worker service
//! (`Prima.RunnerControl`), on the runner's descriptor 3, and the
//! environment a runner starts with.
//!
//! A frame is one JSON object on one line, ending in a newline, of at most
//! `MAX_LINE_BYTES` before it: `v` (1), `type`, then the type's fields in
//! order, always all of them and nothing else. The service sends `assign`
//! and `cancel_child`; the runner sends `child`, `complete`, `exit` and
//! `event`, one of its operator events (`EVENTS`), whose line is at most
//! `MAX_EVENT_LINE_BYTES` and whose strings the encoder cuts to
//! `MAX_EVENT_STRING_BYTES` on a character boundary.
//! `decode` answers the message or the first refusal, in this order: the
//! line's length, one JSON object, the version, the type, an unknown
//! member (the first by name), then each field in order, missing, of
//! another JSON type, outside its shape or over its bound. A member of an
//! object is named by its path (`keys.attempt.fence`). JSON is read as
//! `crate::wire::parse` reads it, and the line's strings, the token and the
//! keys' hex among them, are cleared once it is read.
//! `tests/fixtures/runner_control.json` holds every frame and refusal.
//!
//! The runner's two ends of the channel (`Lines`, `Writer`) read and write
//! its lines over the stream they are given, beside these codecs, which do
//! no I/O.

use std::collections::BTreeMap;
use std::ffi::OsString;

use serde_json::{Map, Value};
use zeroize::Zeroizing;

use crate::auth::{Attempt, AttemptKeys, Key};
use crate::wire::{
    Integer, MAX_INTEGER, bounded, decode_base64, encode_base64, hex, hex_key, integer, is_id,
    is_text, json_string, parse,
};

/// The protocol version every frame carries as `v`.
pub const VERSION: u64 = 1;

/// The most bytes a frame's line spans, its newline excluded.
pub const MAX_LINE_BYTES: usize = 16 * 1024 * 1024;

/// The most input bytes an `assign` carries, decoded: the platform
/// ceiling on an execution's input.
pub const MAX_INPUT_BYTES: usize = 10_485_760;

/// The most attempts an `exit` lists as open.
pub const MAX_OPEN: usize = 1024;

/// A message on the channel. An `assign`'s token, input and keys are
/// cleared when it is dropped, and its `Debug` prints none of them.
#[derive(Clone)]
pub enum Message {
    /// Run this subtree: its signed assignment, its input and the attempt's
    /// opened keys.
    Assign {
        assignment: Zeroizing<String>,
        input: Zeroizing<Vec<u8>>,
        keys: AttemptKeys,
    },
    /// End the child `execution_id` of the runner's subtree.
    CancelChild { execution_id: String },
    /// The runner started the child `execution_id`, whose attempt is `attempt`.
    Child {
        execution_id: String,
        attempt: String,
    },
    /// The subtree rooted at `execution_id` is closed; `clean` says every
    /// component call returned on its own.
    Complete { execution_id: String, clean: bool },
    /// The runner ends, still holding the attempts in `open`.
    Exit { runner: String, open: Vec<String> },
    /// One of the runner's operator events, which its service forwards to
    /// CYFR.
    Event(Event),
}

/// An operator event a runner sends (`Prima.RunnerControl`'s roster): its
/// name, the suffix of `[:cyfr, :locus, :runtime, ...]` joined with dots,
/// and its measurements and metadata, each member in the roster's order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub name: &'static str,
    pub measurements: Vec<(&'static str, u64)>,
    pub metadata: Vec<(&'static str, Meta)>,
}

/// A metadata value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Meta {
    Text(String),
    Integer(u64),
    Null,
}

impl Meta {
    pub fn text(text: &str) -> Meta {
        Meta::Text(text.to_owned())
    }
}

/// The most bytes an `event` line spans, its newline excluded.
pub const MAX_EVENT_LINE_BYTES: usize = 4096;

/// The most bytes an event's metadata string carries: a longer one is cut
/// to this many on a character boundary as it is sent.
pub const MAX_EVENT_STRING_BYTES: usize = 256;

/// `text` cut to at most `MAX_EVENT_STRING_BYTES` bytes, never inside a
/// character.
pub fn cut(text: &str) -> &str {
    if text.len() <= MAX_EVENT_STRING_BYTES {
        return text;
    }
    let mut end = MAX_EVENT_STRING_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

impl std::fmt::Debug for Message {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Message::Assign { keys, .. } => f
                .debug_struct("Assign")
                .field("keys", keys)
                .finish_non_exhaustive(),
            Message::CancelChild { execution_id } => f
                .debug_struct("CancelChild")
                .field("execution_id", execution_id)
                .finish(),
            Message::Child {
                execution_id,
                attempt,
            } => f
                .debug_struct("Child")
                .field("execution_id", execution_id)
                .field("attempt", attempt)
                .finish(),
            Message::Complete {
                execution_id,
                clean,
            } => f
                .debug_struct("Complete")
                .field("execution_id", execution_id)
                .field("clean", clean)
                .finish(),
            Message::Exit { runner, open } => f
                .debug_struct("Exit")
                .field("runner", runner)
                .field("open", open)
                .finish(),
            Message::Event(event) => f.debug_tuple("Event").field(&event.name).finish(),
        }
    }
}

/// Why a line is not a frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    OversizeLine,
    Malformed,
    BadVersion,
    UnknownType,
    UnknownField(String),
    MissingField(String),
    WrongType(String),
    InvalidField(String),
    Oversize(String),
}

/// A message that holds a value no line carries: the member's path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invalid(pub &'static str);

/// The fields of the attempt an attempt's keys are bound to, in order.
const ATTEMPT_FIELDS: [&str; 6] = [
    "athanor_id",
    "execution_id",
    "attempt",
    "fence",
    "generation",
    "service",
];

/// Every type's wire name and its fields, in wire order.
const TYPES: [(&str, &[&str]); 6] = [
    ("assign", &["assignment", "input", "keys"]),
    ("cancel_child", &["execution_id"]),
    ("child", &["execution_id", "attempt"]),
    ("complete", &["execution_id", "clean"]),
    ("exit", &["runner", "open"]),
    ("event", &["name", "measurements", "metadata"]),
];

impl Message {
    fn type_name(&self) -> &'static str {
        match self {
            Message::Assign { .. } => "assign",
            Message::CancelChild { .. } => "cancel_child",
            Message::Child { .. } => "child",
            Message::Complete { .. } => "complete",
            Message::Exit { .. } => "exit",
            Message::Event(_) => "event",
        }
    }
}

/// The line for `message`, its newline included. A value `decode` would
/// refuse is `Invalid`, naming its member.
pub fn encode(message: &Message) -> Result<Vec<u8>, Invalid> {
    let mut members = vec![
        format!("\"v\":{VERSION}"),
        format!("\"type\":{}", json_string(message.type_name())),
    ];
    match message {
        Message::Assign {
            assignment,
            input,
            keys,
        } => {
            text(assignment, "assignment")?;
            if input.len() > MAX_INPUT_BYTES {
                return Err(Invalid("input"));
            }
            let a = &keys.attempt;
            for (value, name) in [
                (&a.athanor_id, "keys.attempt.athanor_id"),
                (&a.execution_id, "keys.attempt.execution_id"),
                (&a.attempt, "keys.attempt.attempt"),
                (&a.service, "keys.attempt.service"),
            ] {
                id(value, name)?;
            }
            within_integer(a.fence, "keys.attempt.fence")?;
            within_integer(a.generation, "keys.attempt.generation")?;
            members.push(format!("\"assignment\":{}", json_string(assignment)));
            members.push(format!("\"input\":{}", json_string(&encode_base64(input))));
            members.push(format!(
                "\"keys\":{{\"attempt\":{{\"athanor_id\":{},\"execution_id\":{},\"attempt\":{},\"fence\":{},\"generation\":{},\"service\":{}}},\"call\":\"{}\",\"seal\":\"{}\"}}",
                json_string(&a.athanor_id),
                json_string(&a.execution_id),
                json_string(&a.attempt),
                a.fence,
                a.generation,
                json_string(&a.service),
                hex(keys.call.as_ref()),
                hex(keys.seal.as_ref()),
            ));
        }
        Message::CancelChild { execution_id } => {
            id(execution_id, "execution_id")?;
            members.push(format!("\"execution_id\":{}", json_string(execution_id)));
        }
        Message::Child {
            execution_id,
            attempt,
        } => {
            id(execution_id, "execution_id")?;
            id(attempt, "attempt")?;
            members.push(format!("\"execution_id\":{}", json_string(execution_id)));
            members.push(format!("\"attempt\":{}", json_string(attempt)));
        }
        Message::Complete {
            execution_id,
            clean,
        } => {
            id(execution_id, "execution_id")?;
            members.push(format!("\"execution_id\":{}", json_string(execution_id)));
            members.push(format!("\"clean\":{clean}"));
        }
        Message::Exit { runner, open } => {
            id(runner, "runner")?;
            if open.len() > MAX_OPEN || !open.iter().all(|attempt| is_id(attempt)) {
                return Err(Invalid("open"));
            }
            let open: Vec<String> = open.iter().map(|attempt| json_string(attempt)).collect();
            members.push(format!("\"runner\":{}", json_string(runner)));
            members.push(format!("\"open\":[{}]", open.join(",")));
        }
        Message::Event(event) => {
            members.extend(event_members(event)?);
        }
    }
    let mut line = format!("{{{}}}", members.join(",")).into_bytes();
    if matches!(message, Message::Event(_)) && line.len() > MAX_EVENT_LINE_BYTES {
        return Err(Invalid("event"));
    }
    line.push(b'\n');
    Ok(line)
}

// An event's members as written: its name, then its measurements and its
// metadata in the roster's order, each string cut to its bound. An event
// off the roster, or one that does not carry exactly its roster's members
// and types, is no frame.
fn event_members(event: &Event) -> Result<Vec<String>, Invalid> {
    let (_name, measured, described) = EVENTS
        .iter()
        .find(|(name, _, _)| *name == event.name)
        .ok_or(Invalid("name"))?;
    if event.measurements.len() != measured.len() || event.metadata.len() != described.len() {
        return Err(Invalid("event"));
    }
    let mut measurements = Vec::new();
    for name in *measured {
        let (_, value) = event
            .measurements
            .iter()
            .find(|(given, _)| given == name)
            .ok_or(Invalid("measurements"))?;
        within_integer(*value, "measurements")?;
        measurements.push(format!("{}:{value}", json_string(name)));
    }
    let mut metadata = Vec::new();
    for (name, field) in *described {
        let (_, value) = event
            .metadata
            .iter()
            .find(|(given, _)| given == name)
            .ok_or(Invalid("metadata"))?;
        let written = match (field, value) {
            (Field::Text | Field::TextOrNull, Meta::Text(text)) => json_string(cut(text)),
            (Field::TextOrNull, Meta::Null) => "null".to_owned(),
            (Field::Integer, Meta::Integer(integer)) if *integer <= MAX_INTEGER => {
                integer.to_string()
            }
            (Field::Words(words) | Field::StatusOrWords(words), Meta::Text(word))
                if words.contains(&word.as_str()) =>
            {
                json_string(word)
            }
            (Field::StatusOrWords(_), Meta::Integer(status)) if (100..=599).contains(status) => {
                status.to_string()
            }
            _ => return Err(Invalid("metadata")),
        };
        metadata.push(format!("{}:{written}", json_string(name)));
    }
    Ok(vec![
        format!("\"name\":{}", json_string(event.name)),
        format!("\"measurements\":{{{}}}", measurements.join(",")),
        format!("\"metadata\":{{{}}}", metadata.join(",")),
    ])
}

/// What a metadata member of an event holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Field {
    /// A string of at most `MAX_EVENT_STRING_BYTES`.
    Text,
    /// Such a string, or null.
    TextOrNull,
    /// An integer of the protocol's domain.
    Integer,
    /// One of these words.
    Words(&'static [&'static str]),
    /// An HTTP status, 100 to 599, or one of these words.
    StatusOrWords(&'static [&'static str]),
}

const OK_ERROR: &[&str] = &["ok", "error"];

/// One event of the roster: its name, its measurements and its metadata.
pub type Roster = (
    &'static str,
    &'static [&'static str],
    &'static [(&'static str, Field)],
);

/// The operator events a runner sends (`Prima.RunnerControl`'s roster):
/// each name, its measurements (integers, each `duration_ms` in
/// milliseconds and each `system_time` in microseconds since the epoch on
/// the runner's clock) and its metadata, in the roster's order.
pub const EVENTS: [Roster; 9] = [
    (
        "engine.authority_entered",
        &[],
        &[("execution_id", Field::Text), ("reference", Field::Text)],
    ),
    (
        "http.request",
        &["duration_ms", "system_time"],
        &[
            ("component_ref", Field::Text),
            ("method", Field::Text),
            ("hostname", Field::Text),
            (
                "status",
                Field::StatusOrWords(&["response_too_large", "timeout", "error"]),
            ),
        ],
    ),
    (
        "storage.call",
        &["duration_ms"],
        &[
            ("component_ref", Field::Text),
            ("action", Field::Text),
            ("status", Field::Words(OK_ERROR)),
        ],
    ),
    (
        "mcp_tool.call",
        &["duration_ms"],
        &[
            ("execution_id", Field::Text),
            ("tool_action", Field::Text),
            ("status", Field::Words(OK_ERROR)),
        ],
    ),
    (
        "formula.spawn",
        &["system_time"],
        &[
            ("parent_execution_id", Field::Text),
            ("task_id", Field::Text),
            ("component_ref", Field::Text),
        ],
    ),
    (
        "formula.await",
        &["duration_ms"],
        &[
            ("task_id", Field::Text),
            ("status", Field::Words(&["completed", "timeout", "error"])),
        ],
    ),
    (
        "formula.await_all",
        &["duration_ms"],
        &[
            ("parent_execution_id", Field::Text),
            ("count", Field::Integer),
            ("timed_out", Field::Integer),
        ],
    ),
    (
        "formula.cancel",
        &["system_time"],
        &[
            ("parent_execution_id", Field::Text),
            ("task_id", Field::Text),
        ],
    ),
    (
        "formula.await_any",
        &["duration_ms"],
        &[
            ("parent_execution_id", Field::Text),
            ("winner_task_id", Field::TextOrNull),
        ],
    ),
];

fn id(value: &str, name: &'static str) -> Result<(), Invalid> {
    if is_id(value) {
        Ok(())
    } else {
        Err(Invalid(name))
    }
}

fn text(value: &str, name: &'static str) -> Result<(), Invalid> {
    if is_text(value) {
        Ok(())
    } else {
        Err(Invalid(name))
    }
}

fn within_integer(value: u64, name: &'static str) -> Result<(), Invalid> {
    if value <= MAX_INTEGER {
        Ok(())
    } else {
        Err(Invalid(name))
    }
}

/// The message one line carries, with or without the newline that ends
/// it, or the first reason it is not a frame.
pub fn decode(line: &[u8]) -> Result<Message, Refusal> {
    let line = line.strip_suffix(b"\n").unwrap_or(line);
    if line.len() > MAX_LINE_BYTES {
        return Err(Refusal::OversizeLine);
    }
    // The parsed line's strings, the token and the keys' hex among them,
    // are cleared when it is dropped.
    let json = parse(line).ok_or(Refusal::Malformed)?;
    let Value::Object(object) = json.value() else {
        return Err(Refusal::Malformed);
    };
    if object.get("v").and_then(integer) != Some(Integer::Whole(VERSION)) {
        return Err(Refusal::BadVersion);
    }
    let Some((name, fields)) = object
        .get("type")
        .and_then(Value::as_str)
        .and_then(|name| TYPES.iter().find(|(known, _)| *known == name))
    else {
        return Err(Refusal::UnknownType);
    };
    if *name == "event" && line.len() > MAX_EVENT_LINE_BYTES {
        return Err(Refusal::OversizeLine);
    }
    let reader = Reader {
        object,
        path: String::new(),
    };
    reader.no_unknown(&[&["v", "type"], *fields].concat())?;
    match *name {
        "assign" => {
            let assignment = Zeroizing::new(reader.text("assignment")?);
            let input = reader.input("input")?;
            let keys = reader.keys("keys")?;
            Ok(Message::Assign {
                assignment,
                input,
                keys,
            })
        }
        "cancel_child" => Ok(Message::CancelChild {
            execution_id: reader.id("execution_id")?,
        }),
        "child" => Ok(Message::Child {
            execution_id: reader.id("execution_id")?,
            attempt: reader.id("attempt")?,
        }),
        "complete" => Ok(Message::Complete {
            execution_id: reader.id("execution_id")?,
            clean: reader.boolean("clean")?,
        }),
        "exit" => Ok(Message::Exit {
            runner: reader.id("runner")?,
            open: reader.ids("open")?,
        }),
        _event => reader.event().map(Message::Event),
    }
}

/// One object's members, read field by field, each refusal naming its
/// member by `path`.
struct Reader<'a> {
    object: &'a Map<String, Value>,
    path: String,
}

impl Reader<'_> {
    fn name(&self, field: &str) -> String {
        format!("{}{field}", self.path)
    }

    // The first member the fields do not declare, by name: the object's
    // keys are held sorted.
    fn no_unknown(&self, fields: &[&str]) -> Result<(), Refusal> {
        match self
            .object
            .keys()
            .find(|key| !fields.contains(&key.as_str()))
        {
            Some(unknown) => Err(Refusal::UnknownField(self.name(unknown))),
            None => Ok(()),
        }
    }

    fn member(&self, field: &str) -> Result<&Value, Refusal> {
        self.object
            .get(field)
            .ok_or_else(|| Refusal::MissingField(self.name(field)))
    }

    fn string(&self, field: &str) -> Result<&str, Refusal> {
        self.member(field)?
            .as_str()
            .ok_or_else(|| Refusal::WrongType(self.name(field)))
    }

    fn id(&self, field: &str) -> Result<String, Refusal> {
        let value = self.string(field)?;
        if is_id(value) {
            Ok(value.to_owned())
        } else {
            Err(Refusal::InvalidField(self.name(field)))
        }
    }

    fn text(&self, field: &str) -> Result<String, Refusal> {
        let value = self.string(field)?;
        if is_text(value) {
            Ok(value.to_owned())
        } else {
            Err(Refusal::InvalidField(self.name(field)))
        }
    }

    fn boolean(&self, field: &str) -> Result<bool, Refusal> {
        self.member(field)?
            .as_bool()
            .ok_or_else(|| Refusal::WrongType(self.name(field)))
    }

    fn integer(&self, field: &str) -> Result<u64, Refusal> {
        bounded(self.member(field)?, 0..=MAX_INTEGER).map_err(|integer| {
            if integer {
                Refusal::InvalidField(self.name(field))
            } else {
                Refusal::WrongType(self.name(field))
            }
        })
    }

    fn key(&self, field: &str) -> Result<Key, Refusal> {
        let value = self.string(field)?;
        hex_key(value)
            .map(Zeroizing::new)
            .ok_or_else(|| Refusal::InvalidField(self.name(field)))
    }

    // Base64 grows bytes by a third, so a text longer than the largest
    // input's is refused before it is decoded.
    fn input(&self, field: &str) -> Result<Zeroizing<Vec<u8>>, Refusal> {
        let value = self.string(field)?;
        if value.len() > MAX_INPUT_BYTES.div_ceil(3) * 4 {
            return Err(Refusal::Oversize(self.name(field)));
        }
        // Held for wiping from the moment it is decoded, refused or not.
        let bytes = Zeroizing::new(
            decode_base64(value).ok_or_else(|| Refusal::InvalidField(self.name(field)))?,
        );
        if bytes.len() > MAX_INPUT_BYTES {
            return Err(Refusal::Oversize(self.name(field)));
        }
        Ok(bytes)
    }

    fn ids(&self, field: &str) -> Result<Vec<String>, Refusal> {
        let Value::Array(values) = self.member(field)? else {
            return Err(Refusal::WrongType(self.name(field)));
        };
        if values.len() > MAX_OPEN {
            return Err(Refusal::Oversize(self.name(field)));
        }
        values
            .iter()
            .map(|value| match value.as_str() {
                Some(attempt) if is_id(attempt) => Ok(attempt.to_owned()),
                _ => Err(Refusal::InvalidField(self.name(field))),
            })
            .collect()
    }

    fn object(&self, field: &str) -> Result<Reader<'_>, Refusal> {
        match self.member(field)? {
            Value::Object(object) => Ok(Reader {
                object,
                path: format!("{}.", self.name(field)),
            }),
            _ => Err(Refusal::WrongType(self.name(field))),
        }
    }

    // An event: its name on the roster, then its measurements and its
    // metadata, each object's unknown members first, then each member in
    // the roster's order.
    fn event(&self) -> Result<Event, Refusal> {
        let named = self.string("name")?;
        let Some((name, measured, described)) = EVENTS.iter().find(|(name, _, _)| *name == named)
        else {
            return Err(Refusal::InvalidField(self.name("name")));
        };
        let measurements_of = self.object("measurements")?;
        measurements_of.no_unknown(measured)?;
        let mut measurements = Vec::new();
        for field in *measured {
            measurements.push((*field, measurements_of.integer(field)?));
        }
        let metadata_of = self.object("metadata")?;
        let names: Vec<&str> = described.iter().map(|(name, _)| *name).collect();
        metadata_of.no_unknown(&names)?;
        let mut metadata = Vec::new();
        for (field, kind) in *described {
            metadata.push((*field, metadata_of.meta(field, *kind)?));
        }
        Ok(Event {
            name,
            measurements,
            metadata,
        })
    }

    fn meta(&self, field: &str, kind: Field) -> Result<Meta, Refusal> {
        let value = self.member(field)?;
        let wrong = || Refusal::WrongType(self.name(field));
        let invalid = || Refusal::InvalidField(self.name(field));
        let text = |text: &str| {
            if text.len() > MAX_EVENT_STRING_BYTES {
                Err(Refusal::Oversize(self.name(field)))
            } else {
                Ok(Meta::Text(text.to_owned()))
            }
        };
        match (kind, value) {
            (Field::Text | Field::TextOrNull, Value::String(given)) => text(given),
            (Field::TextOrNull, Value::Null) => Ok(Meta::Null),
            (Field::Integer, _) => self.integer(field).map(Meta::Integer),
            (Field::Words(words) | Field::StatusOrWords(words), Value::String(word)) => {
                if words.contains(&word.as_str()) {
                    Ok(Meta::Text(word.clone()))
                } else {
                    Err(invalid())
                }
            }
            (Field::StatusOrWords(_), Value::Number(_)) => match integer(value) {
                Some(Integer::Whole(status)) if (100..=599).contains(&status) => {
                    Ok(Meta::Integer(status))
                }
                Some(_) => Err(invalid()),
                None => Err(wrong()),
            },
            _ => Err(wrong()),
        }
    }

    fn keys(&self, field: &str) -> Result<AttemptKeys, Refusal> {
        let keys = self.object(field)?;
        keys.no_unknown(&["attempt", "call", "seal"])?;
        let attempt = keys.object("attempt")?;
        attempt.no_unknown(&ATTEMPT_FIELDS)?;
        let attempt = Attempt {
            athanor_id: attempt.id("athanor_id")?,
            execution_id: attempt.id("execution_id")?,
            attempt: attempt.id("attempt")?,
            fence: attempt.integer("fence")?,
            generation: attempt.integer("generation")?,
            service: attempt.id("service")?,
        };
        Ok(AttemptKeys {
            attempt,
            call: keys.key("call")?,
            seal: keys.key("seal")?,
        })
    }
}

// ============================================================================
// The environment
// ============================================================================

/// The service's own key, which a runner never holds: seeing it, a runner
/// refuses to start.
pub const SERVICE_KEY: &str = "LOCUS_RUNTIME_KEY";
/// The id the runner presents in its host calls.
pub const RUNNER_ID: &str = "RUNTIME_RUNNER_ID";
/// The worker service it presents from.
pub const SERVICE_ID: &str = "RUNTIME_SERVICE_ID";
/// The boot of that worker service.
pub const BOOT_ID: &str = "RUNTIME_BOOT_ID";
/// The descriptor of the control channel: 3 when unset, 0 for standard
/// input and output.
pub const CONTROL_FD: &str = "RUNTIME_CONTROL_FD";
/// The unix socket the test build's direct launcher names for the relay,
/// in place of descriptor 4.
pub const RELAY_SOCKET: &str = "RUNTIME_RELAY_SOCKET";

/// The control descriptor when its variable is unset.
pub const DEFAULT_CONTROL_FD: u32 = 3;
/// The relay's descriptor when no socket is named.
pub const RELAY_FD: u32 = 4;

/// Where a runner's relay is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Relay {
    Fd(u32),
    Socket(String),
}

/// What a runner reads from its environment: who it is and where its two
/// channels are.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Environment {
    pub runner_id: String,
    pub service_id: String,
    pub boot: String,
    pub control_fd: u32,
    pub relay: Relay,
}

/// Why an environment does not start a runner, and the variable it names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnvironmentRefusal {
    Refused(&'static str),
    Missing(&'static str),
    Malformed(&'static str),
}

impl std::fmt::Display for EnvironmentRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EnvironmentRefusal::Refused(name) => {
                write!(
                    f,
                    "a runner must not see {name}: the service's key never leaves the service"
                )
            }
            EnvironmentRefusal::Missing(name) => write!(f, "{name} is not set"),
            EnvironmentRefusal::Malformed(name) => write!(f, "{name} is malformed"),
        }
    }
}

impl Environment {
    /// The runner an environment names, or the first refusal: the
    /// service's key, then the runner id, the service, the boot, the
    /// control descriptor and the relay socket. A name it does not read is
    /// ignored; a value that is no text is malformed.
    pub fn read(
        variables: impl IntoIterator<Item = (OsString, OsString)>,
    ) -> Result<Self, EnvironmentRefusal> {
        let variables: BTreeMap<OsString, OsString> = variables.into_iter().collect();
        if variables.contains_key(&OsString::from(SERVICE_KEY)) {
            return Err(EnvironmentRefusal::Refused(SERVICE_KEY));
        }
        let get = |name: &'static str| match variables.get(&OsString::from(name)) {
            None => Ok(None),
            Some(value) => value
                .to_str()
                .map(Some)
                .ok_or(EnvironmentRefusal::Malformed(name)),
        };
        let required = |name: &'static str| get(name)?.ok_or(EnvironmentRefusal::Missing(name));
        let identifier = |name: &'static str| {
            let value = required(name)?;
            if is_id(value) {
                Ok(value.to_owned())
            } else {
                Err(EnvironmentRefusal::Malformed(name))
            }
        };
        let runner_id = identifier(RUNNER_ID)?;
        let service_id = identifier(SERVICE_ID)?;
        if !is_service_id(&service_id) {
            return Err(EnvironmentRefusal::Malformed(SERVICE_ID));
        }
        let boot = identifier(BOOT_ID)?;
        let control_fd = match get(CONTROL_FD)? {
            None => DEFAULT_CONTROL_FD,
            // A decimal with its sign, `-0` among them, that is no
            // descriptor below zero.
            Some(value) => value
                .parse::<i64>()
                .ok()
                .and_then(|fd| u32::try_from(fd).ok())
                .ok_or(EnvironmentRefusal::Malformed(CONTROL_FD))?,
        };
        let relay = match get(RELAY_SOCKET)? {
            None => Relay::Fd(RELAY_FD),
            Some(path) if is_normal_absolute(path) => Relay::Socket(path.to_owned()),
            Some(_path) => return Err(EnvironmentRefusal::Malformed(RELAY_SOCKET)),
        };
        Ok(Environment {
            runner_id,
            service_id,
            boot,
            control_fd,
            relay,
        })
    }
}

/// A worker service's id: `wrk_` and 1 to 64 letters, digits, `_` or `-`.
fn is_service_id(text: &str) -> bool {
    text.strip_prefix("wrk_").is_some_and(|rest| {
        (1..=64).contains(&rest.len())
            && rest
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    })
}

/// An absolute path that names itself: no empty, `.` or `..` step, and no
/// trailing slash but the root's.
fn is_normal_absolute(path: &str) -> bool {
    match path.strip_prefix('/') {
        Some("") => true,
        Some(rest) => rest
            .split('/')
            .all(|step| !step.is_empty() && step != "." && step != ".."),
        None => false,
    }
}

// ============================================================================
// The runner's end
// ============================================================================

/// What the runner reads from its control channel next.
#[derive(Debug)]
pub enum Received {
    /// A frame.
    Message(Message),
    /// A line that is not a frame, and why: ignored, and logged by its
    /// refusal alone.
    Refused(Refusal),
    /// A line past `MAX_LINE_BYTES` before its newline: the runner ends.
    Oversize,
    /// The channel's end.
    Closed,
}

/// The runner's reading end of its control channel: lines from `reader`,
/// each decoded as it ends. `next` keeps what it has read between calls,
/// so a caller may stop waiting on it and call it again.
pub struct Lines<R> {
    reader: R,
    buffer: Vec<u8>,
    closed: bool,
}

impl<R: tokio::io::AsyncRead + Unpin> Lines<R> {
    pub fn new(reader: R) -> Self {
        Lines {
            reader,
            buffer: Vec::new(),
            closed: false,
        }
    }

    /// The next line's message, refusal, overflow or the channel's end.
    pub async fn next(&mut self) -> Received {
        use tokio::io::AsyncReadExt as _;
        let mut chunk = vec![0u8; 64 * 1024];
        loop {
            if let Some(end) = self.buffer.iter().position(|byte| *byte == b'\n') {
                let line: Zeroizing<Vec<u8>> = Zeroizing::new(self.buffer.drain(..=end).collect());
                return match decode(&line) {
                    Ok(message) => Received::Message(message),
                    Err(refusal) => Received::Refused(refusal),
                };
            }
            if self.buffer.len() > MAX_LINE_BYTES {
                return Received::Oversize;
            }
            if self.closed {
                return Received::Closed;
            }
            match self.reader.read(&mut chunk).await {
                Ok(0) | Err(_) => self.closed = true,
                Ok(read) => self.buffer.extend_from_slice(&chunk[..read]),
            }
        }
    }
}

/// The runner's writing end of its control channel: one task writes every
/// line in the order sent; `send_flushed` waits until its line is written.
#[derive(Clone)]
pub struct Writer {
    lines: tokio::sync::mpsc::UnboundedSender<(Vec<u8>, Option<tokio::sync::oneshot::Sender<()>>)>,
}

impl Writer {
    /// Start the writing task on `writer`, on the current Tokio runtime.
    pub fn start<W>(mut writer: W) -> Writer
    where
        W: tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        use tokio::io::AsyncWriteExt as _;
        let (lines, mut queue) = tokio::sync::mpsc::unbounded_channel::<(
            Vec<u8>,
            Option<tokio::sync::oneshot::Sender<()>>,
        )>();
        tokio::spawn(async move {
            while let Some((line, written)) = queue.recv().await {
                // A channel the service no longer reads takes nothing more;
                // its end reaches the runner on the reading side.
                if writer.write_all(&line).await.is_err() || writer.flush().await.is_err() {
                    return;
                }
                if let Some(written) = written {
                    let _ = written.send(());
                }
            }
        });
        Writer { lines }
    }

    /// Send `message`; a message no line carries is not sent, and its
    /// member is answered.
    pub fn send(&self, message: &Message) -> Result<(), Invalid> {
        let line = encode(message)?;
        let _ = self.lines.send((line, None));
        Ok(())
    }

    /// Send `message` and wait until its line is written, or the writer has
    /// stopped.
    pub async fn send_flushed(&self, message: &Message) -> Result<(), Invalid> {
        let line = encode(message)?;
        let (written, done) = tokio::sync::oneshot::channel();
        if self.lines.send((line, Some(written))).is_ok() {
            let _ = done.await;
        }
        Ok(())
    }
}
