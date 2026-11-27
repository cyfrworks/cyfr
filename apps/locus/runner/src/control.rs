// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The control channel between a runner and its worker service
//! (`Prima.RunnerControl`), on the runner's descriptor 3, and the
//! environment a runner starts with.
//!
//! A frame is one JSON object on one line, ending in a newline, of at most
//! `MAX_LINE_BYTES` before it: `v` (1), `type`, then the type's fields in
//! order, always all of them and nothing else. The service sends `assign`
//! and `cancel_child`; the runner sends `child`, `complete` and `exit`.
//! `decode` answers the message or the first refusal, in this order: the
//! line's length, one JSON object, the version, the type, an unknown
//! member (the first by name), then each field in order, missing, of
//! another JSON type, outside its shape or over its bound. A member of an
//! object is named by its path (`keys.attempt.fence`). JSON is read as
//! `crate::wire::parse` reads it, and the line's strings, the token and the
//! keys' hex among them, are cleared once it is read.
//! `tests/fixtures/runner_control.json` holds every frame and refusal.

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
const TYPES: [(&str, &[&str]); 5] = [
    ("assign", &["assignment", "input", "keys"]),
    ("cancel_child", &["execution_id"]),
    ("child", &["execution_id", "attempt"]),
    ("complete", &["execution_id", "clean"]),
    ("exit", &["runner", "open"]),
];

impl Message {
    fn type_name(&self) -> &'static str {
        match self {
            Message::Assign { .. } => "assign",
            Message::CancelChild { .. } => "cancel_child",
            Message::Child { .. } => "child",
            Message::Complete { .. } => "complete",
            Message::Exit { .. } => "exit",
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
    }
    let mut line = format!("{{{}}}", members.join(",")).into_bytes();
    line.push(b'\n');
    Ok(line)
}

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
        _exit => Ok(Message::Exit {
            runner: reader.id("runner")?,
            open: reader.ids("open")?,
        }),
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
