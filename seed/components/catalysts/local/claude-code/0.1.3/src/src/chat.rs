//! The `model/chat@1` contract on Claude Code, driven over the program's
//! pipe (`cyfr:process/pipe`) in the person's kept folder.
//!
//! `chat` opens the session the request names (`--resume` when it carries
//! one, else a new `--session-id`), sets CYFR's tools on it, and sends the
//! newest user message, or, when the request answers a pending ask of the
//! harness's, the ask's allow with CYFR's answer in its input. It streams
//! the reply's text and answers on the first of: an ask to run one of
//! CYFR's tools (a `tool_call` the host runs through its gate; the ask
//! stays pending in the session until the next `chat` answers it), the
//! turn's end, or an error. The harness's asks for its own tools are
//! allowed here (its box bounds them) and shown as a `tool_call.start` and
//! `tool_call.end` pair. A session the harness holds no transcript of is
//! refused `unknown_session`, before anything of the request is sent.
//! `describe` and `models` read the harness's own model listing, from its
//! `initialize` answer.
//!
//! The catalyst holds nothing between runs: the session is the program's,
//! a pending ask's id rides on its `tool_call` (`provider_data`), and the
//! session id on the response, or on the refusal once the session exists
//! (`carried`). Nothing the harness writes but its reply's
//! text and its tool calls reaches the answer: no line, no stderr, no file
//! of its folder, no sign-in text.

use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

use crate::harness::{self, Event, Flags, Start};
use crate::stream::{self, Deltas, Sink};

pub const CONTRACT: &str = "model/chat@1";
const PROVIDER: &str = "claude-code";

/// The `login` need the manifest declares for the program `claude`.
pub const NEED: &str = "claude";

/// The contract's refusal type for a session the brain no longer holds.
const UNKNOWN_SESSION: &str = "unknown_session";

/// The most characters (UTF-16 code units, as the harness counts them) of
/// one tool result the harness takes into its context: a longer result is
/// replaced by a note that it was saved to a file. Measured on Claude Code
/// 2.1.318 through `updatedInput`, for plain and dense text alike: 50,000
/// characters arrive whole, 50,625 do not.
pub const MAX_RESULT_CHARS: usize = 50_000;

/// What the harness cannot list: a model's context window.
const CONTEXT_WINDOW: u64 = 200_000;

/// The effort levels in the harness's own order (`--effort`); a model's
/// listing names the ones it takes.
const EFFORTS: &[&str] = &["low", "medium", "high", "xhigh", "max"];

/// The permission modes a caller may set (`--permission-mode`), which the
/// harness lists nowhere: the ones under which it still asks before it
/// runs one of CYFR's tools. `bypassPermissions`, `dontAsk` and `auto`
/// would run or refuse those calls without an ask, past CYFR's gate.
const PERMISSION_MODES: &[&str] = &["default", "acceptEdits", "plan"];

const MEDIA_TYPES: &[&str] = &["image/jpeg", "image/png", "image/gif", "image/webp", "application/pdf"];

/// How long one read of the pipe waits for a line.
const RECV_WAIT_MS: u32 = 20_000;

/// The most bytes of one tool's JSON as an argument of `cyfr-stub`: the
/// kernel's bound on one argument (`MAX_ARG_STRLEN`, 131,072 bytes with its
/// terminating NUL), which the harness's start of the stub meets.
pub const MAX_TOOL_ARG_BYTES: usize = 131_071;

/// The most bytes of one line to the program (`Prima.LocusBackends`'s
/// `max_line_bytes`): the `mcp_set_servers` request carries the whole tool
/// list in one line.
pub const MAX_LINE_BYTES: usize = 1_048_576;

/// How long `describe` and `models` wait for the harness's listing: a
/// first start fetches the program.
pub const LISTING_BUDGET: Duration = Duration::from_secs(150);

/// How long a `chat` runs before it answers: inside the 30 minutes the
/// manifest consents this catalyst (`caps.limits.timeout`), which is how
/// long the loop waits for a model call (`Aqua.Loop`) and the deadline the
/// worker service enforces, with room to close the session and answer
/// before either stops the run. Past it the session is interrupted
/// (`interrupted`); its partial work stays in its folder and transcript,
/// and the next message resumes it.
pub const CHAT_BUDGET: Duration = Duration::from_secs(29 * 60);

// ---------------------------------------------------------------------------
// The pipe
// ---------------------------------------------------------------------------

/// A session on the program, as `open` answers it.
pub struct Opened {
    pub session: String,
    pub resumed: bool,
}

/// What one read answers: lines with their sequence numbers, how many
/// lines between the read's `after` and its first line the session's buffer
/// no longer held, and whether the program still runs.
pub struct Received {
    pub lines: Vec<(u64, String)>,
    pub dropped: u32,
    pub running: bool,
}

/// The program's pipe: the host's import, or a script in a test. An error
/// is the import's code.
pub trait Pipe {
    fn open(&mut self, need: &str, key: &str, argv: &[String]) -> Result<Opened, String>;
    fn send(&mut self, session: &str, lines: &[String]) -> Result<(), String>;
    fn recv(&mut self, session: &str, after: u64, max_wait_ms: u32) -> Result<Received, String>;
    fn close(&mut self, session: &str) -> Result<(), String>;
}

// ---------------------------------------------------------------------------
// Refusals
// ---------------------------------------------------------------------------

/// A typed refusal of the contract, the pipe's code when the pipe
/// answered it, and the session it carries (`Prima.Model`).
#[derive(Debug, PartialEq)]
pub struct Refusal {
    pub status: i64,
    pub kind: &'static str,
    pub message: String,
    pub code: Option<String>,
    pub session: Option<String>,
}

impl Refusal {
    fn new(status: i64, kind: &'static str, message: impl Into<String>) -> Self {
        Refusal { status, kind, message: message.into(), code: None, session: None }
    }

    pub fn envelope(&self) -> String {
        let mut error = json!({"type": self.kind, "message": self.message});
        if let Some(session) = &self.session {
            error["session"] = json!(session);
        }
        json!({"status": self.status, "error": error}).to_string()
    }
}

pub fn invalid(message: impl Into<String>) -> Refusal {
    Refusal::new(400, "invalid_request", message)
}

/// The contract's refusal for a code the pipe answered. The host's own
/// sentence stays with the host; the code says enough to act on.
pub fn pipe_refusal(code: &str) -> Refusal {
    let refusal = match code {
        // `Prima.Refusal`'s sentence for an account not granted, on which
        // the console offers the grant.
        "denied" => Refusal::new(403, "secret_denied", "This account is not granted to the component; grant it first."),
        "setup_required" => Refusal::new(
            403,
            "secret_denied",
            "The claude program's login entry, its row or its grant no longer serves, or its folder is past its cap; see the Programs page.",
        ),
        "busy" => Refusal::new(529, "overloaded", "The box runs as many programs as it may; try again later."),
        "unavailable" => Refusal::new(503, "overloaded", "The program's box could not answer; try again later."),
        "ended" => Refusal::new(502, "incomplete_stream", "The harness ended before it finished its turn."),
        "invalid_request" | "too_large" => invalid("The program's pipe refused what this turn sent."),
        _ => Refusal::new(
            502,
            "provider_error",
            "The pipe's answer was lost; the harness may have received what this turn sent.",
        ),
    };
    Refusal { code: Some(code.to_string()), ..refusal }
}

/// The refusal for an error the harness ended its turn with. It answers
/// only after this run sent something, so it is never a type the loop
/// retries: the same request made again would send the same message or
/// allow twice. A rate limit or an overload is `provider_error` naming the
/// harness's reason; the turn ended on the harness's side, the session is
/// left as it is, and the next message goes on in it.
fn harness_error(kind: &'static str) -> Refusal {
    let (status, kind, message) = match kind {
        "authentication" => (401, kind, "Claude Code is not signed in, or its account cannot serve this; sign in again from the Programs page."),
        "rate_limited" => (502, "provider_error", "Claude Code's account is past its rate limit, and its turn ended; send the message again later."),
        "overloaded" => (502, "provider_error", "Claude Code's provider is overloaded, and its turn ended; send the message again later."),
        "invalid_request" => (400, kind, "Claude Code refused the request."),
        "unknown_model" => (404, kind, "Claude Code does not know the model."),
        _ => (502, "provider_error", "Claude Code failed to finish its turn."),
    };
    Refusal::new(status, kind, message)
}

fn ended() -> Refusal {
    pipe_refusal("ended")
}

/// The refusal of a session the harness holds no transcript of
/// (`Prima.Model`). The harness says so as it starts and ends, before this
/// run sends it anything of the request, so nothing ran: the host forgets
/// the session and asks again without one, which opens a new session.
fn unknown_session() -> Refusal {
    Refusal::new(
        404,
        UNKNOWN_SESSION,
        "Claude Code no longer holds the session this message continues; the message can be sent again on a new one.",
    )
}

// ---------------------------------------------------------------------------
// The contract request
// ---------------------------------------------------------------------------

pub struct Tool {
    pub name: String,
    pub description: String,
    pub parameters: Value,
}

/// What a `chat` sends the harness.
#[derive(Debug, PartialEq)]
pub enum Input {
    /// The newest user message, as content blocks.
    Message(Vec<Value>),
    /// CYFR's answer to the tool call `id`: the ask `request_id` the
    /// harness holds for it, with the input it was made with.
    Answer {
        request_id: String,
        name: String,
        arguments: Value,
        content: String,
        is_error: bool,
    },
}

pub struct Request {
    pub model: String,
    pub system: Option<String>,
    pub tools: Vec<Tool>,
    /// The harness's session id the request names, and the flags its
    /// process was started with, as the session this catalyst answered
    /// records them.
    pub session: Option<String>,
    pub started: Option<String>,
    pub flags: Flags,
    pub input: Input,
}

/// Validate a `chat` request. The message names what is wrong.
pub fn parse_request(params: &Value) -> Result<Request, String> {
    let model = match params.get("model") {
        Some(Value::String(model)) if model_id(model) => model.clone(),
        _ => return Err("'model' must be a model id".into()),
    };
    if let Err(member) = check_chat_request(params, &chat_options()) {
        return Err(format!("'{member}' is not one this brain takes as it was set"));
    }
    let (session, started) = match params.get("session") {
        None => (None, None),
        Some(Value::String(answered)) => match answered.split_once('.') {
            None if session_id(answered) => (Some(answered.clone()), None),
            Some((id, print)) if session_id(id) && fingerprint_text(print) => (Some(id.into()), Some(print.into())),
            _ => return Err("'session' is not a session this brain answered".into()),
        },
        Some(_) => return Err("'session' is not a session this brain answered".into()),
    };
    let system = match params.get("system") {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) if text.is_empty() => None,
        Some(Value::String(text)) => Some(text.clone()),
        Some(_) => return Err("'system' must be a string".into()),
    };
    match params.get("provider_tools") {
        None | Some(Value::Null) => {}
        Some(Value::Array(list)) if list.is_empty() => {}
        Some(_) => return Err("this brain offers no provider tools".into()),
    }
    let tools = match params.get("tools") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(list)) => list.iter().map(parse_tool).collect::<Result<Vec<_>, _>>()?,
        Some(_) => return Err("'tools' must be a list".into()),
    };
    let messages = match params.get("messages") {
        Some(Value::Array(list)) if !list.is_empty() => list,
        _ => return Err("'messages' must be a non-empty list".into()),
    };
    let options = params.get("options").and_then(Value::as_object);
    let option = |name: &str| options.and_then(|o| o.get(name)).and_then(Value::as_str).map(str::to_string);
    let flags = Flags {
        model: option("model").or_else(|| Some(model.clone())).filter(|m| m != "default"),
        effort: option("effort"),
        permission_mode: option("permission_mode"),
        tools: option("tools"),
    };
    if flags.tools.as_ref().is_some_and(|t| t.len() > 4096 || t.contains('\0')) {
        return Err("'options.tools' is past what the pipe takes".into());
    }
    Ok(Request {
        model,
        system,
        tools,
        session,
        started,
        flags,
        input: input(messages)?,
    })
}

fn parse_tool(raw: &Value) -> Result<Tool, String> {
    let name = raw
        .get("name")
        .and_then(Value::as_str)
        .filter(|n| !n.is_empty() && n.len() <= 128)
        .ok_or("tools[].name must be a name of 1 to 128 characters")?;
    let parameters = match raw.get("parameters") {
        None | Some(Value::Null) => json!({"type": "object", "properties": {}}),
        Some(v @ Value::Object(_)) => v.clone(),
        Some(_) => return Err(format!("tools[{name}].parameters must be an object")),
    };
    Ok(Tool {
        name: name.to_string(),
        description: raw.get("description").and_then(Value::as_str).unwrap_or("").to_string(),
        parameters,
    })
}

/// What the request's last message asks the harness: a user message, or a
/// tool result answering the call the message before it made.
fn input(messages: &[Value]) -> Result<Input, String> {
    let last = messages.last().expect("non-empty");
    match last.get("role").and_then(Value::as_str) {
        Some("user") => Ok(Input::Message(user_content(last)?)),
        Some("tool") => {
            let results: Vec<&Value> = match last.get("content") {
                Some(Value::Array(blocks)) => blocks
                    .iter()
                    .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
                    .collect(),
                _ => Vec::new(),
            };
            let [result] = results[..] else {
                return Err("the last message must answer exactly one tool call".into());
            };
            let id = result
                .get("tool_call_id")
                .and_then(Value::as_str)
                .ok_or("the tool result names no tool_call_id")?;
            let call = messages
                .iter()
                .rev()
                .skip(1)
                .find(|m| m.get("role").and_then(Value::as_str) == Some("assistant"))
                .and_then(|m| m.get("content").and_then(Value::as_array))
                .and_then(|blocks| {
                    blocks.iter().find(|b| {
                        b.get("type").and_then(Value::as_str) == Some("tool_call")
                            && b.get("id").and_then(Value::as_str) == Some(id)
                    })
                })
                .ok_or("the tool result answers no tool call of the message before it")?;
            let request_id = call["provider_data"]
                .get("request_id")
                .and_then(Value::as_str)
                .ok_or("the tool call carries no request_id of this brain's")?;
            Ok(Input::Answer {
                request_id: request_id.to_string(),
                name: call.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
                arguments: match call.get("arguments") {
                    Some(v @ Value::Object(_)) => v.clone(),
                    _ => json!({}),
                },
                content: result_text(result.get("content"))?,
                is_error: result.get("is_error").and_then(Value::as_bool).unwrap_or(false),
            })
        }
        _ => Err("the last message must be the user's or a tool result".into()),
    }
}

/// A user message's content as the harness's blocks.
fn user_content(message: &Value) -> Result<Vec<Value>, String> {
    match message.get("content") {
        Some(Value::String(text)) if !text.is_empty() => Ok(vec![json!({"type": "text", "text": text})]),
        Some(Value::Array(blocks)) if !blocks.is_empty() => blocks
            .iter()
            .map(|block| match block.get("type").and_then(Value::as_str) {
                Some("text") => Ok(json!({"type": "text", "text": block.get("text").and_then(Value::as_str).unwrap_or("")})),
                Some(kind @ ("image" | "document")) => {
                    let media_type = block.get("media_type").and_then(Value::as_str);
                    let data = block.get("data").and_then(Value::as_str);
                    match (media_type, data) {
                        (Some(media_type), Some(data)) if MEDIA_TYPES.contains(&media_type) => Ok(json!({
                            "type": kind,
                            "source": {"type": "base64", "media_type": media_type, "data": data}
                        })),
                        _ => Err(format!("a {kind} block needs a media_type this brain takes and its data")),
                    }
                }
                _ => Err("a user message holds text, image and document blocks".into()),
            })
            .collect(),
        _ => Err("the user message is empty".into()),
    }
}

/// A tool result's content: a string, or text blocks joined in order.
fn result_text(content: Option<&Value>) -> Result<String, String> {
    match content {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(s)) => Ok(s.clone()),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .map(|b| b.get("text").and_then(Value::as_str).ok_or("tool result blocks must be text blocks".to_string()))
            .collect(),
        Some(_) => Err("a tool result's content must be a string or text blocks".into()),
    }
}

/// A model id: what `--model` takes, an alias or a full id.
pub fn model_id(model: &str) -> bool {
    !model.is_empty()
        && model.len() <= 128
        && model.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && model.chars().all(|c| c.is_ascii_alphanumeric() || "._:-[]".contains(c))
}

/// A session id this catalyst answers: a UUID, as `--session-id` takes.
pub fn session_id(id: &str) -> bool {
    id.len() == 36
        && id.char_indices().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit() && !c.is_ascii_uppercase(),
        })
}

/// The flags a session's process was started with, as 16 hex digits
/// (FNV-1a, 64 bits): what the session this catalyst answers records
/// beside its id, so a request whose options differ is seen to.
pub fn fingerprint(flags: &Flags) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for arg in harness::flag_args(flags) {
        for byte in arg.bytes().chain([0]) {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    format!("{hash:016x}")
}

fn fingerprint_text(print: &str) -> bool {
    print.len() == 16 && print.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

/// A UUID (version 4) from `bits`.
pub fn uuid(bits: [u64; 2]) -> String {
    let hi = (bits[0] & 0xffff_ffff_ffff_0fff) | 0x4000;
    let lo = (bits[1] & 0x3fff_ffff_ffff_ffff) | 0x8000_0000_0000_0000;
    format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        hi >> 32,
        (hi >> 16) & 0xffff,
        hi & 0xffff,
        lo >> 48,
        lo & 0xffff_ffff_ffff
    )
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

/// The options a chat request is checked against: the model as any id the
/// harness takes, since its listing is `describe`'s to ask.
fn chat_options() -> Vec<Value> {
    vec![
        json!({"name": "model", "kind": "string"}),
        effort_option(EFFORTS.iter().map(|e| e.to_string()).collect()),
        permission_option(),
        tools_option(),
    ]
}

fn effort_option(levels: Vec<String>) -> Value {
    json!({"name": "effort", "kind": "enum", "values": levels})
}

fn permission_option() -> Value {
    json!({"name": "permission_mode", "kind": "enum", "values": PERMISSION_MODES, "default": "default"})
}

/// The harness's own tools a session may use, as `--tools` takes them: a
/// comma-separated list, empty for none; absent, all of them.
fn tools_option() -> Value {
    json!({"name": "tools", "kind": "string"})
}

/// Whether a `chat` request's `session` and `options` hold to the
/// contract under `declared` (`Prima.Model.check_chat_request/2`), or the
/// member that does not.
pub fn check_chat_request(request: &Value, declared: &[Value]) -> Result<(), String> {
    match request.get("session") {
        None => {}
        Some(Value::String(s)) if !s.is_empty() => {}
        Some(_) => return Err("session".into()),
    }
    let set = match request.get("options") {
        None => return Ok(()),
        Some(Value::Object(set)) => set,
        Some(_) => return Err("options".into()),
    };
    for (name, value) in set {
        let option = declared
            .iter()
            .find(|o| o["name"].as_str() == Some(name))
            .ok_or_else(|| format!("options.{name}"))?;
        if !of_kind(option, value) {
            return Err(format!("options.{name}"));
        }
    }
    Ok(())
}

fn of_kind(option: &Value, value: &Value) -> bool {
    match option["kind"].as_str() {
        Some("enum") => value
            .as_str()
            .is_some_and(|v| option["values"].as_array().is_some_and(|vs| vs.iter().any(|x| x == v))),
        Some("string") => value.is_string(),
        Some("integer") => value.is_i64() || value.is_u64(),
        Some("boolean") => value.is_boolean(),
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// describe and models
// ---------------------------------------------------------------------------

/// The harness's model listing, from its `initialize` answer, in a session
/// of its own that is closed after: each entry `{value, displayName,
/// supportedEffortLevels?, ...}`.
pub fn listing<P: Pipe>(pipe: &mut P, key: &str, deadline: Instant) -> Result<Vec<Value>, Refusal> {
    let argv: Vec<String> = harness::BASE_ARGV.iter().map(|a| a.to_string()).collect();
    let opened = pipe.open(NEED, key, &argv).map_err(|code| pipe_refusal(&code))?;
    let mut reader = Reader::new(&opened.session, 0);
    let answer = pipe
        .send(&opened.session, &[harness::initialize(None)])
        .map_err(|code| pipe_refusal(&code))
        .and_then(|_| reader.answer(pipe, harness::INIT_ID, deadline));
    let _ = pipe.close(&opened.session);
    let response = answer?;
    Ok(response
        .get("models")
        .and_then(Value::as_array)
        .map(|models| {
            models
                .iter()
                .filter(|m| m.get("value").and_then(Value::as_str).is_some_and(|v| !v.is_empty()))
                .cloned()
                .collect()
        })
        .unwrap_or_default())
}

/// What this catalyst can do, with the options the harness lets a caller
/// set: the model and effort from its listing when it could be asked, the
/// permission mode and its own tools always. With a `model`, that model's
/// window, which the harness does not list.
pub fn describe(model: Option<&str>, listing: Option<&[Value]>) -> Value {
    let mut options = Vec::new();
    if let Some(models) = listing.filter(|m| !m.is_empty()) {
        let mut values: Vec<&str> = Vec::new();
        for value in models.iter().filter_map(|m| m["value"].as_str()) {
            if !values.contains(&value) {
                values.push(value);
            }
        }
        options.push(json!({"name": "model", "kind": "enum", "values": values}));
        let levels: Vec<String> = EFFORTS
            .iter()
            .filter(|level| {
                models.iter().any(|m| {
                    m["supportedEffortLevels"]
                        .as_array()
                        .is_some_and(|ls| ls.iter().any(|l| l == **level))
                })
            })
            .map(|level| level.to_string())
            .collect();
        if !levels.is_empty() {
            options.push(effort_option(levels));
        }
    }
    options.push(permission_option());
    options.push(tools_option());
    let mut described = json!({
        "contracts": [CONTRACT],
        "provider": PROVIDER,
        "tools": true,
        "provider_tools": [],
        "media_types": MEDIA_TYPES,
        "streaming": true,
        "defaults": {},
        "options": options,
    });
    if let Some(model) = model {
        described["model"] = json!(model);
        described["context_window"] = json!(CONTEXT_WINDOW);
    }
    described
}

/// `describe`'s envelope, from the harness's listing in a session of its
/// own (keyed `key`). With no login entry bound (the pipe answers
/// `denied`) it answers the options the harness cannot list, deliberately;
/// any other failure to list keeps its contract error.
pub fn describe_answer<P: Pipe>(pipe: &mut P, key: &str, model: Option<&str>, deadline: Instant) -> String {
    let listing = match listing(pipe, key, deadline) {
        Ok(listing) => Some(listing),
        Err(refusal) if refusal.code.as_deref() == Some("denied") => None,
        Err(refusal) => return refusal.envelope(),
    };
    json!({"status": 200, "data": describe(model, listing.as_deref())}).to_string()
}

/// The listing as contract entries.
pub fn models(listing: &[Value]) -> Value {
    json!({
        "models": listing
            .iter()
            .map(|m| json!({"id": m["value"], "name": m.get("displayName").cloned().unwrap_or(m["value"].clone())}))
            .collect::<Vec<_>>()
    })
}

// ---------------------------------------------------------------------------
// Reading the session
// ---------------------------------------------------------------------------

/// The session's lines, read in order past `after`.
///
/// A read names the lines its buffer no longer held between its `after`
/// and its first line (`dropped`). A run's first read starts where no read
/// of its own stood, so the lines an earlier run read past count there too,
/// and it counts no loss. Every later read is past this run's own: a gap
/// there is output the harness wrote and no one read (an ask or the turn's
/// result among it, perhaps), so the turn cannot be answered from what is
/// left. The session is closed, and the next chat starts the program again
/// resuming from the transcript its folder keeps.
struct Reader {
    session: String,
    after: u64,
    first: bool,
}

impl Reader {
    fn new(session: &str, after: u64) -> Self {
        Reader { session: session.to_string(), after, first: true }
    }

    /// The next lines, waiting at most `wait_ms`; `None` once the program
    /// has ended and nothing is left.
    fn next<P: Pipe>(&mut self, pipe: &mut P, wait_ms: u32) -> Result<Option<Vec<String>>, Refusal> {
        let got = pipe
            .recv(&self.session, self.after, wait_ms)
            .map_err(|code| pipe_refusal(&code))?;
        let first = std::mem::replace(&mut self.first, false);
        if let Some((seq, _)) = got.lines.last() {
            self.after = *seq;
        } else if first {
            // The lines an empty first read counts are behind every line
            // the session holds: its place moves past them, or each later
            // read would count them again and take them for a loss.
            self.after += u64::from(got.dropped);
        }
        if got.dropped > 0 && !first {
            return Err(Refusal {
                code: Some("dropped".into()),
                ..Refusal::new(502, "provider_error", format!("{} lines of the harness's output were lost unread.", got.dropped))
            });
        }
        if got.lines.is_empty() && !got.running {
            return Ok(None);
        }
        Ok(Some(got.lines.into_iter().map(|(_, text)| text).collect()))
    }

    /// Read past everything the session holds now, before this run sends
    /// anything: what earlier runs, each answered, left behind. Lines lost
    /// from it are let go with it.
    fn drain<P: Pipe>(&mut self, pipe: &mut P) -> Result<(), Refusal> {
        loop {
            match self.next(pipe, 0) {
                Ok(Some(lines)) if !lines.is_empty() => continue,
                Err(refusal) if refusal.code.as_deref() == Some("dropped") => continue,
                Ok(_) => return Ok(()),
                Err(refusal) => return Err(refusal),
            }
        }
    }

    /// The answer to the control request `id`, refusing any other request
    /// the harness makes meanwhile.
    fn answer<P: Pipe>(&mut self, pipe: &mut P, id: &str, deadline: Instant) -> Result<Value, Refusal> {
        loop {
            let wait = wait_until(deadline).ok_or_else(timed_out)?;
            let lines = self.next(pipe, wait)?.ok_or_else(ended)?;
            for line in lines {
                match harness::read(&line) {
                    Event::Answer { request_id, ok, response } if request_id == id => {
                        return if ok {
                            Ok(response)
                        } else {
                            Err(Refusal::new(502, "provider_error", "Claude Code refused to start this session."))
                        };
                    }
                    Event::Request { request_id, subtype } => {
                        pipe.send(&self.session, &[harness::unanswered(&request_id, &subtype)])
                            .map_err(|code| pipe_refusal(&code))?;
                    }
                    Event::NoConversation => return Err(unknown_session()),
                    _ => {}
                }
            }
        }
    }
}

fn wait_until(deadline: Instant) -> Option<u32> {
    let left = deadline.checked_duration_since(Instant::now())?;
    Some(left.as_millis().min(RECV_WAIT_MS as u128) as u32).filter(|ms| *ms > 0)
}

fn timed_out() -> Refusal {
    Refusal {
        code: Some("deadline".into()),
        ..Refusal::new(504, "incomplete_stream", "The harness was still working when this run's time ran out.")
    }
}

/// What a turn answers when the pipe failed once this run sent anything:
/// whether the harness received it, acted on it or answered it is not
/// known, and sending it again could make the harness act twice. The
/// session is closed; the next message starts the program again resuming
/// it, and the transcript its folder keeps carries what happened, a held
/// ask included (the harness holds an error result for it and asks again).
/// Not a type the loop retries.
fn interrupted() -> Refusal {
    Refusal::new(
        502,
        "provider_error",
        "The session with Claude Code was interrupted mid-turn: its pipe failed, and what reached it is not known. The next message resumes the session from its folder.",
    )
}

// ---------------------------------------------------------------------------
// chat
// ---------------------------------------------------------------------------

/// `content` within `MAX_RESULT_CHARS`, the rest named in a note.
pub fn bounded(content: &str) -> String {
    let total: usize = content.encode_utf16().count();
    if total <= MAX_RESULT_CHARS {
        return content.to_string();
    }
    let note = |cut: usize| {
        format!("\n…[CYFR cut this result at {MAX_RESULT_CHARS} characters, what Claude Code takes from one call; {cut} more were not shown. Ask for a narrower part.]")
    };
    let room = MAX_RESULT_CHARS - note(total).encode_utf16().count();
    let mut kept = String::new();
    let mut used = 0;
    for c in content.chars() {
        if used + c.len_utf16() > room {
            break;
        }
        used += c.len_utf16();
        kept.push(c);
    }
    kept.push_str(&note(total - used));
    kept
}

/// The input of an answered ask: the call's arguments with CYFR's answer.
fn answered_input(arguments: &Value, content: &str, is_error: bool) -> Value {
    let mut input = arguments.as_object().cloned().unwrap_or_default();
    input.remove("result");
    input.remove("error");
    let key = if is_error { "error" } else { "result" };
    input.insert(key.into(), json!(bounded(content)));
    Value::Object(input)
}

/// A tool call's arguments as the model made them: without the members
/// the stub answers from.
fn call_arguments(input: &Value) -> Value {
    let mut arguments: Map<String, Value> = input.as_object().cloned().unwrap_or_default();
    arguments.remove("result");
    arguments.remove("error");
    Value::Object(arguments)
}

/// The request's tools as the stub's arguments, or the refusal of a list
/// the harness cannot be given whole: a tool past one argument's bound, or
/// a list past one line's. Nothing is cut and nothing is opened then.
pub fn carried_tools(tools: &[Tool]) -> Result<Vec<String>, Refusal> {
    let args: Vec<String> = tools
        .iter()
        .map(|t| harness::stub_tool(&t.name, &t.description, &t.parameters))
        .collect();
    if let Some((tool, arg)) = tools.iter().zip(&args).find(|(_, arg)| arg.len() > MAX_TOOL_ARG_BYTES) {
        return Err(invalid(format!(
            "The tool {} is {} bytes as cyfr-stub's argument, past the {MAX_TOOL_ARG_BYTES} one argument carries.",
            tool.name,
            arg.len()
        )));
    }
    let line = harness::set_tools(&args).len();
    if line > MAX_LINE_BYTES {
        return Err(invalid(format!(
            "The tools are {line} bytes as one line to the harness, past the {MAX_LINE_BYTES} one line carries."
        )));
    }
    Ok(args)
}

/// One `chat`: the contract response, or a refusal carrying the session
/// it leaves (`carried`), none when the session is gone. `fresh` names a
/// new session.
pub fn chat<P: Pipe, S: Sink>(
    pipe: &mut P,
    deltas: &mut Deltas<S>,
    request: &Request,
    fresh: String,
    deadline: Instant,
) -> Result<Value, Refusal> {
    let id = request.session.clone().unwrap_or(fresh);
    let mut taken = false;
    run(pipe, deltas, request, &id, deadline, &mut taken).map_err(|refusal| {
        let session = if refusal.kind == UNKNOWN_SESSION { None } else { carried(request, &id, taken) };
        Refusal { session, ..refusal }
    })
}

/// The session a refusal carries, which the host keeps as a response's:
/// once the harness has shown this run's turn (`taken`), the session this
/// run would have answered, so a first chat interrupted at its budget is
/// resumed by the next; before, the one the request named, unchanged. A
/// new session the harness never showed a turn of carries none: it may
/// hold no transcript to resume, and the next message would be refused
/// `unknown_session` before it opened a new one.
fn carried(request: &Request, id: &str, taken: bool) -> Option<String> {
    if taken {
        return Some(format!("{id}.{}", fingerprint(&request.flags)));
    }
    let named = request.session.as_ref()?;
    Some(match &request.started {
        Some(print) => format!("{named}.{print}"),
        None => named.clone(),
    })
}

/// Open the session and converse; `taken` turns true once the harness
/// shows the turn.
fn run<P: Pipe, S: Sink>(
    pipe: &mut P,
    deltas: &mut Deltas<S>,
    request: &Request,
    id: &str,
    deadline: Instant,
    taken: &mut bool,
) -> Result<Value, Refusal> {
    let tools = carried_tools(&request.tools)?;
    let id = id.to_string();
    let start = if request.session.is_some() { Start::Resume(&id) } else { Start::New(&id) };
    let argv = harness::argv(start, &request.flags);
    let mut opened = pipe.open(NEED, &id, &argv).map_err(|code| pipe_refusal(&code))?;
    // A running process keeps the flags it was started with, and the box
    // attaches without applying new ones: when the request's options are
    // not those the session records, the process is closed and started
    // again resuming the session, whose transcript its folder keeps.
    if opened.resumed && request.started.as_deref() != Some(fingerprint(&request.flags).as_str()) {
        let _ = pipe.close(&opened.session);
        opened = pipe.open(NEED, &id, &argv).map_err(|code| pipe_refusal(&code))?;
        if opened.resumed {
            return Err(Refusal::new(502, "provider_error", "Claude Code's session could not be restarted with the new options."));
        }
    }
    let session = opened.session.clone();
    let mut reader = Reader::new(&session, 0);
    // What a running session holds unread is what earlier runs, each
    // answered, left behind: let go before this run sends anything.
    if opened.resumed {
        reader.drain(pipe)?;
    }
    // Once this run sends anything, a failure of the pipe interrupts the
    // session: it is closed, nothing is sent again, and the next message
    // resumes it (`interrupted`).
    match converse(pipe, deltas, &mut reader, request, &id, &tools, opened.resumed, deadline, taken) {
        // The harness that held no transcript has ended: its session on
        // the pipe is let go, and the refusal stands as it is.
        Err(refusal) if refusal.kind == UNKNOWN_SESSION => {
            let _ = pipe.close(&session);
            Err(refusal)
        }
        Err(refusal) if refusal.code.is_some() => {
            let _ = pipe.close(&session);
            Err(interrupted())
        }
        answered => answered,
    }
}

/// Start the program's side of the turn (a new process is initialized),
/// set its tools, send the request's message or the allow of the ask it
/// answers, and read the turn to its first answer.
#[allow(clippy::too_many_arguments)]
fn converse<P: Pipe, S: Sink>(
    pipe: &mut P,
    deltas: &mut Deltas<S>,
    reader: &mut Reader,
    request: &Request,
    id: &str,
    tools: &[String],
    resumed: bool,
    deadline: Instant,
    taken: &mut bool,
) -> Result<Value, Refusal> {
    let session = reader.session.clone();
    let send = |pipe: &mut P, line: String| pipe.send(&session, &[line]).map_err(|code| pipe_refusal(&code));
    if !resumed {
        match send(pipe, harness::initialize(request.system.as_deref())) {
            // A harness started to resume a session it holds no transcript
            // of says so and ends at once, perhaps before this line
            // reached it: what it wrote is read all the same.
            Err(refusal) if refusal.code.as_deref() == Some("ended") => {
                reader.answer(pipe, harness::INIT_ID, deadline)?;
                return Err(refusal);
            }
            sent => sent?,
        }
        reader.answer(pipe, harness::INIT_ID, deadline)?;
    }
    // A turn starts with the request's tools set. The answer to a pending
    // ask continues a turn whose tools are set, and replacing its server
    // while the harness holds the call would end the call it answers.
    let continuing = resumed && matches!(request.input, Input::Answer { .. });
    if !continuing {
        send(pipe, harness::set_tools(tools))?;
        let set = reader.answer(pipe, harness::TOOLS_ID, deadline)?;
        if set["errors"].as_object().is_some_and(|errors| !errors.is_empty()) {
            return Err(Refusal::new(502, "provider_error", "Claude Code could not start CYFR's tools."));
        }
    }
    let line = match &request.input {
        Input::Message(content) => harness::user(content.clone()),
        Input::Answer { request_id, arguments, content, is_error, .. } if resumed => {
            harness::allow(request_id, &answered_input(arguments, content, *is_error))
        }
        // The program that held the ask ended; its resumed session has the
        // call without CYFR's answer, which comes as a message.
        Input::Answer { name, content, is_error, .. } => {
            let what = if *is_error { "refused it" } else { "ran it" };
            harness::user(vec![json!({
                "type": "text",
                "text": format!(
                    "Your session restarted while CYFR held your call to {name}. CYFR {what} and answered:\n{}",
                    bounded(content)
                )
            })])
        }
    };
    send(pipe, line)?;
    turn(pipe, deltas, reader, request, id, deadline, taken)
}

/// Read the turn to its first answer; `taken` turns true at the first line
/// of the turn's own.
fn turn<P: Pipe, S: Sink>(
    pipe: &mut P,
    deltas: &mut Deltas<S>,
    reader: &mut Reader,
    request: &Request,
    id: &str,
    deadline: Instant,
    taken: &mut bool,
) -> Result<Value, Refusal> {
    let mut model = request.flags.model.clone().unwrap_or_else(|| request.model.clone());
    let mut text = String::new();
    let mut streamed = false;
    let mut shown: u64 = 0;
    let mut error: Option<String> = None;
    let response = |text: &str, model: &str, call: Option<Value>, stop: &str, usage: Value| {
        let mut content = Vec::new();
        if !text.is_empty() {
            content.push(json!({"type": "text", "text": text}));
        }
        content.extend(call);
        json!({"model": model, "content": content, "stop_reason": stop, "usage": usage,
               "session": format!("{id}.{}", fingerprint(&request.flags))})
    };

    loop {
        let Some(wait) = wait_until(deadline) else {
            return Err(timed_out());
        };
        let Some(lines) = reader.next(pipe, wait)? else {
            return Err(ended());
        };
        if lines.is_empty() {
            deltas.flush();
            continue;
        }
        for line in lines {
            let event = harness::read(&line);
            if matches!(
                event,
                Event::Init { .. } | Event::TextDelta(_) | Event::Assistant { .. } | Event::Ask { .. } | Event::Result { .. }
            ) {
                *taken = true;
            }
            match event {
                Event::TextDelta(delta) => {
                    deltas.text(&delta);
                    streamed = true;
                }
                // An errored message is the harness's own words about its
                // account or its provider (a sign-in prompt among them):
                // read first, and none of its text, streamed or whole, is
                // passed on.
                Event::Assistant { error: Some(typed), .. } => {
                    deltas.discard();
                    streamed = false;
                    error = Some(typed);
                }
                Event::Assistant { text: whole, error: None } => {
                    if !streamed {
                        deltas.text(&whole);
                    }
                    streamed = false;
                    text.push_str(&whole);
                }
                Event::Init { model: Some(running) } => model = running,
                Event::Ask { request_id, tool, input, tool_use_id } => {
                    if let Some(name) = tool.strip_prefix(harness::TOOL_PREFIX) {
                        let call_id = tool_use_id.unwrap_or_else(|| request_id.clone());
                        let arguments = call_arguments(&input);
                        stream::tool_call(deltas, shown, &call_id, name, Some(&arguments));
                        let call = json!({
                            "type": "tool_call",
                            "id": call_id,
                            "name": name,
                            "arguments": arguments,
                            "provider_data": {"request_id": request_id}
                        });
                        let answer = response(&text, &model, Some(call), "tool_call", harness::usage(&Value::Null));
                        stream::close(deltas, &answer);
                        return Ok(answer);
                    }
                    // The harness's own tool runs in its box (D2): allowed,
                    // and shown by name only, since its input may hold
                    // what its folder holds.
                    pipe.send(&reader.session, &[harness::allow(&request_id, &input)])
                        .map_err(|code| pipe_refusal(&code))?;
                    let call_id = tool_use_id.unwrap_or(request_id);
                    stream::tool_call(deltas, shown, &call_id, &tool, None);
                    shown += 1;
                }
                Event::Request { request_id, subtype } => {
                    pipe.send(&reader.session, &[harness::unanswered(&request_id, &subtype)])
                        .map_err(|code| pipe_refusal(&code))?;
                }
                Event::Result { ok: true, usage, .. } => {
                    let answer = response(&text, &model, None, "end_turn", harness::usage(&usage));
                    stream::close(deltas, &answer);
                    return Ok(answer);
                }
                Event::Result { subtype, usage, .. }
                    if error.is_none() && subtype.starts_with("error_max_") =>
                {
                    let answer = response(&text, &model, None, "other", harness::usage(&usage));
                    stream::close(deltas, &answer);
                    return Ok(answer);
                }
                Event::Result { .. } => {
                    return Err(harness_error(error.as_deref().map_or("provider_error", harness::error_kind)));
                }
                _ => {}
            }
        }
        deltas.flush_due();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    type Respond = Box<dyn FnMut(&str) -> Vec<String>>;

    /// A pipe that answers each line sent with the lines a script gives,
    /// and records every call.
    struct Scripted {
        resumed: bool,
        running: bool,
        log: Vec<String>,
        sent: Vec<String>,
        out: VecDeque<String>,
        seq: u64,
        respond: Respond,
        open_error: Option<String>,
        recv_errors: VecDeque<Option<String>>,
        /// A send whose line holds the text answers this code.
        send_error: Option<(String, String)>,
    }

    impl Scripted {
        fn new(respond: impl FnMut(&str) -> Vec<String> + 'static) -> Self {
            Scripted {
                resumed: false,
                running: true,
                log: Vec::new(),
                sent: Vec::new(),
                out: VecDeque::new(),
                seq: 0,
                respond: Box::new(respond),
                open_error: None,
                recv_errors: VecDeque::new(),
                send_error: None,
            }
        }
    }

    impl Pipe for Scripted {
        fn open(&mut self, need: &str, key: &str, argv: &[String]) -> Result<Opened, String> {
            self.log.push(format!("open {need} {key} {}", argv.join(" ")));
            if let Some(code) = self.open_error.clone() {
                return Err(code);
            }
            Ok(Opened { session: "pipe-1".into(), resumed: self.resumed })
        }
        fn send(&mut self, _session: &str, lines: &[String]) -> Result<(), String> {
            if let Some((needle, code)) = &self.send_error {
                if lines.iter().any(|l| l.contains(needle.as_str())) {
                    let code = code.clone();
                    self.send_error = None;
                    // The lines reached the program; the answer did not.
                    for line in lines {
                        self.sent.push(line.clone());
                        let out = (self.respond)(line);
                        self.out.extend(out);
                    }
                    return Err(code);
                }
            }
            for line in lines {
                self.sent.push(line.clone());
                let out = (self.respond)(line);
                self.out.extend(out);
            }
            Ok(())
        }
        fn recv(&mut self, _session: &str, after: u64, _wait: u32) -> Result<Received, String> {
            assert!(after <= self.seq);
            if let Some(code) = self.recv_errors.pop_front().flatten() {
                return Err(code);
            }
            // As the relay counts it: every line between `after` and the
            // first it holds, read past by an earlier reader or lost.
            let dropped = (self.seq - after) as u32;
            let lines: Vec<(u64, String)> = self
                .out
                .drain(..)
                .map(|text| {
                    self.seq += 1;
                    (self.seq, text)
                })
                .collect();
            Ok(Received { running: self.running || !lines.is_empty(), lines, dropped })
        }
        fn close(&mut self, session: &str) -> Result<(), String> {
            self.log.push(format!("close {session}"));
            self.resumed = false;
            Ok(())
        }
    }

    fn sent_type(line: &str) -> (String, String) {
        let v: Value = serde_json::from_str(line).unwrap();
        let kind = v["type"].as_str().unwrap_or("").to_string();
        let sub = v["request"]["subtype"]
            .as_str()
            .or(v["response"]["response"]["behavior"].as_str())
            .unwrap_or("")
            .to_string();
        (kind, sub)
    }

    /// The fake harness's answers: control requests answered, a user
    /// message answered by `turn`.
    fn harness_answers(turn: Vec<String>) -> impl FnMut(&str) -> Vec<String> {
        let mut turn = Some(turn);
        move |line| {
            let v: Value = serde_json::from_str(line).unwrap();
            match v["type"].as_str() {
                Some("control_request") => vec![json!({
                    "type": "control_response",
                    "response": {"subtype": "success", "request_id": v["request_id"], "response": {
                        "models": [{"value": "default", "displayName": "Default", "supportedEffortLevels": ["low", "high"]},
                                   {"value": "haiku", "displayName": "Haiku", "supportedEffortLevels": ["low", "medium"]},
                                   {"value": "claude-haiku-4-5", "displayName": "Haiku 4.5"}],
                        "added": ["cyfr"], "removed": [], "errors": {}
                    }}
                })
                .to_string()],
                Some("user") => turn.take().unwrap_or_default(),
                _ => Vec::new(),
            }
        }
    }

    fn soon() -> Instant {
        Instant::now() + Duration::from_secs(2)
    }

    fn sent_count(pipe: &Scripted, needle: &str) -> usize {
        pipe.sent.iter().filter(|l| l.contains(needle)).count()
    }

    fn request(params: Value) -> Request {
        parse_request(&params).unwrap()
    }

    fn far() -> Instant {
        Instant::now() + Duration::from_secs(60)
    }

    const ID: &str = "0b5c7c1e-2f3a-4d6e-8a9b-1c2d3e4f5a6b";

    fn init_line() -> String {
        r#"{"type":"system","subtype":"init","session_id":"x","model":"claude-haiku-5-5","tools":["mcp__cyfr__files"]}"#.into()
    }

    fn continuation(session: &str) -> Request {
        request(json!({"model": "default", "session": session, "messages": [
            {"role": "user", "content": "Read a.txt"},
            {"role": "assistant", "content": [{"type": "tool_call", "id": "toolu_1", "name": "files",
              "arguments": {"path": "a.txt"}, "provider_data": {"request_id": "req-7"}}]},
            {"role": "tool", "content": [{"type": "tool_result", "tool_call_id": "toolu_1", "content": "hi"}]}
        ]}))
    }

    /// The pipe after an interruption: closed once, one allow ever sent,
    /// and the next chat starts the program again resuming the session.
    fn resumes_after_interruption(pipe: &mut Scripted, refusal: Refusal, session: &str) {
        assert_eq!(refusal.kind, "provider_error", "{refusal:?}");
        assert!(refusal.message.contains("interrupted") && refusal.message.contains("next message"), "{}", refusal.message);
        assert_eq!(pipe.log.iter().filter(|l| *l == "close pipe-1").count(), 1, "{:?}", pipe.log);
        assert_eq!(sent_count(pipe, "\"behavior\":\"allow\""), 1, "{:?}", pipe.sent);
        assert_eq!(refusal.session.as_deref(), Some(session), "the refusal carries the session it resumes");

        let next = request(json!({"model": "default", "session": session, "messages": [{"role": "user", "content": "go on"}]}));
        let mut deltas = Deltas::new(Vec::new());
        let answer = chat(pipe, &mut deltas, &next, "unused".into(), soon()).unwrap();
        assert!(pipe.log.last().unwrap().contains(&format!("--resume {ID}")), "{:?}", pipe.log);
        assert!(answer["session"].as_str().unwrap().starts_with(&format!("{ID}.")));
        assert_eq!(sent_count(pipe, "\"behavior\":\"allow\""), 1, "never sent again: {:?}", pipe.sent);
    }

    #[test]
    fn a_read_lost_after_the_allow_interrupts_the_session_and_the_next_chat_resumes_it() {
        let mut pipe = Scripted::new(harness_answers(vec![result_line()]));
        pipe.resumed = true;
        // The drain, then the read after the allow: the box could not answer.
        pipe.recv_errors = VecDeque::from([None, Some("unavailable".into())]);
        let session = started(&Flags::default());
        let mut deltas = Deltas::new(Vec::new());
        let refusal = chat(&mut pipe, &mut deltas, &continuation(&session), "unused".into(), soon()).unwrap_err();
        resumes_after_interruption(&mut pipe, refusal, &session);
    }

    #[test]
    fn a_send_lost_with_the_allow_interrupts_the_session_and_the_next_chat_resumes_it() {
        let mut pipe = Scripted::new(harness_answers(vec![result_line()]));
        pipe.resumed = true;
        pipe.send_error = Some(("\"behavior\":\"allow\"".into(), "lost".into()));
        let session = started(&Flags::default());
        let mut deltas = Deltas::new(Vec::new());
        let refusal = chat(&mut pipe, &mut deltas, &continuation(&session), "unused".into(), soon()).unwrap_err();
        resumes_after_interruption(&mut pipe, refusal, &session);
    }

    #[test]
    fn a_rate_limit_the_harness_reports_after_the_allow_is_not_retried_and_nothing_is_sent_twice() {
        let limited = vec![
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"API Error: rate limited"}]},"parent_tool_use_id":null,"error":"rate_limit"}"#.to_string(),
            r#"{"type":"result","subtype":"success","is_error":true,"result":"API Error: rate limited"}"#.into(),
        ];
        let mut limited = Some(limited);
        let mut pipe = Scripted::new(move |line| {
            let v: Value = serde_json::from_str(line).unwrap();
            match v["type"].as_str() {
                Some("control_request") => vec![json!({"type": "control_response", "response": {"subtype": "success",
                    "request_id": v["request_id"], "response": {"errors": {}}}}).to_string()],
                Some("control_response") => limited.take().unwrap_or_default(),
                Some("user") => vec![result_line()],
                _ => Vec::new(),
            }
        });
        pipe.resumed = true;
        let session = started(&Flags::default());
        let mut deltas = Deltas::new(Vec::new());
        let refusal = chat(&mut pipe, &mut deltas, &continuation(&session), "unused".into(), soon()).unwrap_err();
        assert_eq!(refusal.kind, "provider_error", "never a type the loop retries: {refusal:?}");
        assert!(refusal.message.contains("rate limit") && refusal.message.contains("again later"), "{}", refusal.message);
        assert!(!pipe.log.iter().any(|l| l.starts_with("close")), "the session is left as the harness left it: {:?}", pipe.log);
        assert_eq!(refusal.session.as_deref(), Some(session.as_str()), "the refusal carries the session it goes on in");

        let next = request(json!({"model": "default", "session": session, "messages": [{"role": "user", "content": "go on"}]}));
        assert!(chat(&mut pipe, &mut deltas, &next, "unused".into(), soon()).is_ok());
        assert_eq!(sent_count(&pipe, "\"behavior\":\"allow\""), 1, "no allow sent again: {:?}", pipe.sent);
        assert!(!pipe.log.iter().any(|l| l.starts_with("close")));
    }

    /// A harness whose user messages are answered by `turns`, one each.
    fn harness_turns(turns: Vec<Vec<String>>) -> impl FnMut(&str) -> Vec<String> {
        let mut turns = VecDeque::from(turns);
        let mut control = harness_answers(Vec::new());
        move |line| {
            let v: Value = serde_json::from_str(line).unwrap();
            match v["type"].as_str() {
                Some("user") => turns.pop_front().unwrap_or_default(),
                _ => control(line),
            }
        }
    }

    #[test]
    fn a_first_chat_interrupted_at_its_budget_carries_its_session_and_the_next_chat_resumes_it() {
        let working = r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Working"}},"parent_tool_use_id":null}"#;
        let mut pipe = Scripted::new(harness_turns(vec![vec![init_line(), working.into()], vec![result_line()]]));
        let first = request(json!({"model": "default", "messages": [{"role": "user", "content": "a long job"}]}));
        let mut deltas = Deltas::new(Vec::new());
        let refusal = chat(&mut pipe, &mut deltas, &first, ID.into(), Instant::now() + Duration::from_millis(300)).unwrap_err();
        assert!(refusal.message.contains("interrupted") && refusal.message.contains("next message"), "{}", refusal.message);
        assert_eq!(pipe.log.last().unwrap(), "close pipe-1");
        let session = started(&Flags::default());
        assert_eq!(refusal.session.as_deref(), Some(session.as_str()), "the new session rides on the refusal");
        let envelope: Value = serde_json::from_str(&refusal.envelope()).unwrap();
        assert_eq!(envelope["error"]["session"], json!(session));

        // The host keeps it as a response's: the next chat names it and
        // resumes the session.
        let next = request(json!({"model": "default", "session": envelope["error"]["session"],
                                  "messages": [{"role": "user", "content": "go on"}]}));
        let answer = chat(&mut pipe, &mut deltas, &next, "unused".into(), soon()).unwrap();
        assert!(pipe.log.last().unwrap().contains(&format!("--resume {ID}")), "{:?}", pipe.log);
        assert_eq!(answer["session"], json!(session));
    }

    #[test]
    fn a_refusal_before_the_harness_shows_the_turn_carries_the_session_the_request_named_or_none() {
        let mut deltas = Deltas::new(Vec::new());
        let mut pipe = Scripted::new(harness_answers(Vec::new()));
        pipe.open_error = Some("busy".into());
        let first = request(json!({"model": "default", "messages": [{"role": "user", "content": "hi"}]}));
        let refusal = chat(&mut pipe, &mut deltas, &first, ID.into(), soon()).unwrap_err();
        assert_eq!(refusal.session, None, "a new session no turn was sent to holds nothing to resume");
        assert!(!refusal.envelope().contains("session"), "{}", refusal.envelope());

        let session = started(&Flags::default());
        let named = request(json!({"model": "default", "session": session, "messages": [{"role": "user", "content": "hi"}]}));
        let refusal = chat(&mut pipe, &mut deltas, &named, "unused".into(), soon()).unwrap_err();
        assert_eq!(refusal.session.as_deref(), Some(session.as_str()));
    }

    /// What 2.1.318 wrote when started with `--resume` of a session its
    /// folder held no transcript of (`harness::no_conversation`).
    fn no_conversation_line() -> String {
        format!(
            r#"{{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"session_id":"{ID}","errors":["No conversation found with session ID: {ID}"]}}"#
        )
    }

    #[test]
    fn a_session_the_harness_holds_no_transcript_of_is_refused_unknown_session_and_the_next_chat_opens_a_new_one() {
        // The harness answers its start with the result and ends: its
        // `initialize` is never answered.
        let mut pipe = Scripted::new(|line| {
            if line.contains("\"initialize\"") {
                vec![no_conversation_line()]
            } else {
                Vec::new()
            }
        });
        pipe.running = false;
        let session = started(&Flags::default());
        let hi = json!([{"role": "user", "content": "hi"}]);
        let named = request(json!({"model": "default", "session": session, "messages": hi}));
        let mut deltas = Deltas::new(Vec::new());
        let refusal = chat(&mut pipe, &mut deltas, &named, "unused".into(), soon()).unwrap_err();
        assert_eq!(refusal.kind, "unknown_session", "{refusal:?}");
        assert_eq!(refusal.session, None, "the session is gone, so the refusal carries none");
        let envelope: Value = serde_json::from_str(&refusal.envelope()).unwrap();
        assert_eq!(response_session(&envelope["error"]), Ok(None), "{envelope}");
        assert!(pipe.log[0].contains(&format!("--resume {ID}")), "{:?}", pipe.log);
        assert_eq!(pipe.log.last().unwrap(), "close pipe-1");
        let kinds: Vec<_> = pipe.sent.iter().map(|l| sent_type(l)).collect();
        assert_eq!(kinds, [("control_request".into(), "initialize".into())], "nothing of the request was sent");

        // The host asks again without the session: a new one opens.
        let mut pipe = Scripted::new(harness_answers(vec![result_line()]));
        let again = request(json!({"model": "default", "messages": hi}));
        let new = "1c6d8d2f-3a4b-4c7f-9bac-2d3e4f5a6b7c";
        let answer = chat(&mut pipe, &mut deltas, &again, new.into(), soon()).unwrap();
        assert!(pipe.log[0].contains(&format!("--session-id {new}")), "{:?}", pipe.log);
        assert!(answer["session"].as_str().unwrap().starts_with(&format!("{new}.")));
    }

    #[test]
    fn a_harness_that_ended_before_it_was_sent_anything_is_read_for_why() {
        let session = started(&Flags::default());
        let named = request(json!({"model": "default", "session": session, "messages": [{"role": "user", "content": "hi"}]}));
        let mut deltas = Deltas::new(Vec::new());

        // It said it holds no transcript, and was gone before `initialize`
        // reached it.
        let mut pipe = Scripted::new(|_| Vec::new());
        pipe.running = false;
        pipe.out.push_back(no_conversation_line());
        pipe.send_error = Some(("\"initialize\"".into(), "ended".into()));
        let refusal = chat(&mut pipe, &mut deltas, &named, "unused".into(), soon()).unwrap_err();
        assert_eq!(refusal.kind, "unknown_session", "{refusal:?}");
        assert_eq!(refusal.session, None);

        // It ended without those words: an interrupted session, which the
        // next message resumes.
        let mut pipe = Scripted::new(|_| Vec::new());
        pipe.running = false;
        pipe.send_error = Some(("\"initialize\"".into(), "ended".into()));
        let refusal = chat(&mut pipe, &mut deltas, &named, "unused".into(), soon()).unwrap_err();
        assert_eq!(refusal.kind, "provider_error", "{refusal:?}");
        assert_eq!(refusal.session.as_deref(), Some(session.as_str()));
    }

    #[test]
    fn an_empty_first_read_carries_the_sequence_past_lines_read_before() {
        // Seven lines an earlier run read past. The first read is empty and
        // counts them; the next line, the tools' answer at 8, is counted
        // against where the first read left off, and nothing is lost.
        let mut pipe = Scripted::new(harness_answers(vec![result_line()]));
        pipe.resumed = true;
        pipe.seq = 7;
        let session = started(&Flags::default());
        let req = request(json!({"model": "default", "session": session, "messages": [{"role": "user", "content": "hi"}]}));
        let mut deltas = Deltas::new(Vec::new());
        assert_eq!(chat(&mut pipe, &mut deltas, &req, "unused".into(), soon()).unwrap()["stop_reason"], "end_turn");
        assert!(!pipe.log.iter().any(|l| l.starts_with("close")), "{:?}", pipe.log);
    }


    #[test]
    fn a_round_trip_streams_text_and_answers_end_turn_with_its_session() {
        let turn = vec![
            init_line(),
            r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}},"parent_tool_use_id":null}"#.into(),
            r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"there."}},"parent_tool_use_id":null}"#.into(),
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello there."}]},"parent_tool_use_id":null}"#.into(),
            r#"{"type":"result","subtype":"success","is_error":false,"result":"Hello there.","usage":{"input_tokens":5,"output_tokens":3}}"#.into(),
        ];
        let mut pipe = Scripted::new(harness_answers(turn));
        let mut deltas = Deltas::new(Vec::new());
        let req = request(json!({"model": "haiku", "system": "Be brief.", "messages": [{"role": "user", "content": "Hi"}],
                                  "tools": [{"name": "files", "description": "Files", "parameters": {"type": "object"}}],
                                  "options": {"effort": "high"}}));
        let answer = chat(&mut pipe, &mut deltas, &req, ID.into(), far()).unwrap();
        assert_eq!(answer["content"], json!([{"type": "text", "text": "Hello there."}]));
        assert_eq!(answer["stop_reason"], "end_turn");
        assert!(answer["session"].as_str().unwrap().starts_with(&format!("{ID}.")));
        assert_eq!(answer["model"], "claude-haiku-5-5");
        assert_eq!(answer["usage"]["input_tokens"], 5);
        assert!(pipe.log[0].starts_with(&format!("open claude {ID} -p ")));
        assert!(pipe.log[0].ends_with(&format!("--session-id {ID} --model haiku --effort high")));
        let kinds: Vec<_> = pipe.sent.iter().map(|l| sent_type(l)).collect();
        assert_eq!(
            kinds,
            [("control_request".into(), "initialize".into()), ("control_request".into(), "mcp_set_servers".into()), ("user".into(), String::new())]
        );
        let init: Value = serde_json::from_str(&pipe.sent[0]).unwrap();
        assert_eq!(init["request"]["appendSystemPrompt"], "Be brief.");
        let events = deltas.into_sink();
        let text: String = events.iter().filter(|e| e["type"] == "text.delta").map(|e| e["text"].as_str().unwrap()).collect();
        assert_eq!(text, "Hello there.");
        assert_eq!(events.last().unwrap(), &json!({"type": "stop", "stop_reason": "end_turn"}));
    }

    #[test]
    fn an_ask_for_a_cyfr_tool_answers_a_tool_call_and_the_next_chat_allows_it_with_the_result() {
        let ask = r#"{"type":"control_request","request_id":"req-7","request":{"subtype":"can_use_tool","tool_name":"mcp__cyfr__files","input":{"action":"read","path":"a.txt"},"tool_use_id":"toolu_1"}}"#;
        let turn = vec![init_line(), r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Reading."}]},"parent_tool_use_id":null}"#.into(), ask.into()];
        let mut pipe = Scripted::new(harness_answers(turn));
        let mut deltas = Deltas::new(Vec::new());
        let req = request(json!({"model": "default", "messages": [{"role": "user", "content": "Read a.txt"}]}));
        let answer = chat(&mut pipe, &mut deltas, &req, ID.into(), far()).unwrap();
        assert_eq!(answer["stop_reason"], "tool_call");
        let call = &answer["content"][1];
        assert_eq!(call["name"], "files");
        assert_eq!(call["id"], "toolu_1");
        assert_eq!(call["arguments"], json!({"action": "read", "path": "a.txt"}));
        assert_eq!(call["provider_data"], json!({"request_id": "req-7"}));
        assert!(!pipe.log[0].contains("--model"), "the default model sets no flag: {}", pipe.log[0]);

        // The next chat carries the result: the live session's ask is
        // allowed with CYFR's answer in its input.
        let finish = vec![
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"It says hi."}]},"parent_tool_use_id":null}"#.into(),
            r#"{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":9,"output_tokens":4}}"#.into(),
        ];
        let mut finish = Some(finish);
        let mut pipe = Scripted::new(move |line| {
            let v: Value = serde_json::from_str(line).unwrap();
            match (v["type"].as_str(), v["request_id"].as_str()) {
                (Some("control_request"), Some(id)) => vec![json!({"type": "control_response", "response": {"subtype": "success", "request_id": id, "response": {"errors": {}}}}).to_string()],
                (Some("control_response"), _) => finish.take().unwrap_or_default(),
                _ => Vec::new(),
            }
        });
        pipe.resumed = true;
        pipe.out.push_back("left over from the last run".into());
        let mut messages = vec![json!({"role": "user", "content": "Read a.txt"})];
        messages.push(json!({"role": "assistant", "content": answer["content"]}));
        messages.push(json!({"role": "tool", "content": [{"type": "tool_result", "tool_call_id": "toolu_1", "name": "files", "content": "hi"}]}));
        let req = request(json!({"model": "default", "session": answer["session"], "messages": messages}));
        let mut deltas = Deltas::new(Vec::new());
        let answer = chat(&mut pipe, &mut deltas, &req, "unused".into(), far()).unwrap();
        assert_eq!(answer["stop_reason"], "end_turn");
        assert_eq!(answer["content"], json!([{"type": "text", "text": "It says hi."}]));
        assert!(pipe.log[0].contains(&format!("--resume {ID}")));
        let allow: Value = serde_json::from_str(pipe.sent.last().unwrap()).unwrap();
        assert_eq!(allow["response"]["request_id"], "req-7");
        assert_eq!(allow["response"]["response"]["updatedInput"], json!({"action": "read", "path": "a.txt", "result": "hi"}));
        // The running session's turn goes on: the allow is the one line sent,
        // no initialize and no new tools.
        assert_eq!(pipe.sent.len(), 1, "{:?}", pipe.sent);
    }

    #[test]
    fn a_refused_call_reaches_the_stub_as_its_error() {
        let input = answered_input(&json!({"path": "x", "result": "made up"}), "Denied by the person.", true);
        assert_eq!(input, json!({"path": "x", "error": "Denied by the person."}));
    }

    #[test]
    fn a_held_ask_whose_program_ended_comes_back_as_a_message() {
        let mut pipe = Scripted::new(harness_answers(vec![
            r#"{"type":"result","subtype":"success","is_error":false,"usage":{}}"#.into(),
        ]));
        let messages = json!([
            {"role": "user", "content": "go"},
            {"role": "assistant", "content": [{"type": "tool_call", "id": "t1", "name": "files", "arguments": {"path": "a"}, "provider_data": {"request_id": "r1"}}]},
            {"role": "tool", "content": [{"type": "tool_result", "tool_call_id": "t1", "content": "body"}]}
        ]);
        let req = request(json!({"model": "haiku", "session": ID, "messages": messages}));
        let mut deltas = Deltas::new(Vec::new());
        chat(&mut pipe, &mut deltas, &req, "unused".into(), far()).unwrap();
        let last: Value = serde_json::from_str(pipe.sent.last().unwrap()).unwrap();
        assert_eq!(last["type"], "user");
        let text = last["message"]["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("files") && text.ends_with("body"), "{text}");
    }

    #[test]
    fn the_harness_s_own_asks_are_allowed_and_shown_by_name_only() {
        let turn = vec![
            r#"{"type":"control_request","request_id":"b1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"cat secret"},"tool_use_id":"toolu_b"}}"#.into(),
            r#"{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback"}}"#.into(),
            r#"{"type":"result","subtype":"success","is_error":false,"usage":{}}"#.into(),
        ];
        let mut pipe = Scripted::new(harness_answers(turn));
        let mut deltas = Deltas::new(Vec::new());
        let req = request(json!({"model": "haiku", "messages": [{"role": "user", "content": "run it"}]}));
        let answer = chat(&mut pipe, &mut deltas, &req, ID.into(), far()).unwrap();
        assert_eq!(answer["content"], json!([]));
        let allow = pipe.sent.iter().find(|l| l.contains("\"b1\"")).unwrap();
        assert_eq!(sent_type(allow), ("control_response".into(), "allow".into()));
        assert!(pipe.sent.iter().any(|l| l.contains("\"h1\"") && l.contains("\"error\"")));
        let events = deltas.into_sink();
        assert_eq!(events[0], json!({"type": "tool_call.start", "index": 0, "id": "toolu_b", "name": "Bash"}));
        assert_eq!(events[1], json!({"type": "tool_call.end", "index": 0}));
        assert!(!events.iter().any(|e| e.to_string().contains("secret")));
    }

    #[test]
    fn a_typed_harness_error_answers_its_contract_type_and_none_of_its_text() {
        let turn = vec![
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Invalid API key · Please run /login"}]},"parent_tool_use_id":null,"error":"authentication_failed"}"#.into(),
            r#"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}"#.into(),
        ];
        let mut pipe = Scripted::new(harness_answers(turn));
        let mut deltas = Deltas::new(Vec::new());
        let req = request(json!({"model": "haiku", "messages": [{"role": "user", "content": "hi"}]}));
        let refusal = chat(&mut pipe, &mut deltas, &req, ID.into(), far()).unwrap_err();
        assert_eq!(refusal.kind, "authentication");
        assert!(!refusal.message.contains("API key"));
        // The run's stream closes with the refusal, as lib.rs closes it:
        // the errored message's text never reaches it, nor a delta of it.
        stream::error(&mut deltas, refusal.kind, &refusal.message);
        let events = deltas.into_sink();
        assert!(!events.iter().any(|e| e.to_string().contains("API key")), "{events:?}");
        assert!(!events.iter().any(|e| e["type"] == "text.delta"), "{events:?}");
        assert_eq!(events.last().unwrap()["error"]["type"], "authentication");
    }

    #[test]
    fn deltas_streamed_ahead_of_an_errored_message_are_let_go() {
        let turn = vec![
            r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Please run /login"}},"parent_tool_use_id":null}"#.into(),
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Please run /login"}]},"parent_tool_use_id":null,"error":"authentication_failed"}"#.into(),
            r#"{"type":"result","subtype":"success","is_error":true}"#.into(),
        ];
        let mut pipe = Scripted::new(harness_answers(turn));
        let mut deltas = Deltas::new(Vec::new());
        let req = request(json!({"model": "haiku", "messages": [{"role": "user", "content": "hi"}]}));
        let refusal = chat(&mut pipe, &mut deltas, &req, ID.into(), far()).unwrap_err();
        stream::error(&mut deltas, refusal.kind, &refusal.message);
        let events = deltas.into_sink();
        assert!(!events.iter().any(|e| e.to_string().contains("/login")), "{events:?}");
    }

    #[test]
    fn a_run_s_first_read_counts_no_loss_since_an_earlier_run_let_those_lines_go() {
        // On a session already running, the first read starts at 0 and the
        // buffer no longer holds what an earlier run read past: not a loss.
        let turn = vec![r#"{"type":"result","subtype":"success","is_error":false,"usage":{}}"#.into()];
        let mut pipe = Scripted::new(harness_answers(turn));
        pipe.resumed = true;
        // Seven lines an earlier run read past: every read from 0 counts
        // them, the first one empty, and none is a loss.
        pipe.seq = 7;
        let mut deltas = Deltas::new(Vec::new());
        let session = started(&Flags { model: Some("haiku".into()), ..Flags::default() });
        let req = request(json!({"model": "haiku", "session": session, "messages": [{"role": "user", "content": "hi"}]}));
        assert_eq!(chat(&mut pipe, &mut deltas, &req, ID.into(), far()).unwrap()["stop_reason"], "end_turn");
    }

    /// The session this catalyst answers for a process started with `flags`.
    fn started(flags: &Flags) -> String {
        format!("{ID}.{}", fingerprint(flags))
    }

    fn result_line() -> String {
        r#"{"type":"result","subtype":"success","is_error":false,"usage":{}}"#.into()
    }

    #[test]
    fn changed_options_restart_the_session_resuming_it_with_the_new_flags() {
        let hi = json!([{"role": "user", "content": "hi"}]);
        let mut pipe = Scripted::new(harness_answers(vec![result_line()]));
        let mut deltas = Deltas::new(Vec::new());
        let first = request(json!({"model": "haiku", "messages": hi, "options": {"tools": "Bash,Read"}}));
        let session = chat(&mut pipe, &mut deltas, &first, ID.into(), far()).unwrap()["session"].clone();
        assert!(session.as_str().unwrap().starts_with(&format!("{ID}.")), "{session}");

        // The same options again: the running session is used as it is.
        let mut pipe = Scripted::new(harness_answers(vec![result_line()]));
        pipe.resumed = true;
        let same = request(json!({"model": "haiku", "session": session, "messages": hi, "options": {"tools": "Bash,Read"}}));
        let again = chat(&mut pipe, &mut deltas, &same, "unused".into(), far()).unwrap();
        assert_eq!(again["session"], session);
        assert!(!pipe.log.iter().any(|l| l.starts_with("close")), "{:?}", pipe.log);

        // Changed tools and model: the running process is closed and the
        // session started again resuming the same id, with the new flags.
        let mut pipe = Scripted::new(harness_answers(vec![result_line()]));
        pipe.resumed = true;
        let changed = request(json!({"model": "opus", "session": session, "messages": hi, "options": {"tools": ""}}));
        let answer = chat(&mut pipe, &mut deltas, &changed, "unused".into(), far()).unwrap();
        assert_eq!(pipe.log.len(), 3, "{:?}", pipe.log);
        assert_eq!(pipe.log[1], "close pipe-1");
        assert!(pipe.log[2].ends_with(&format!("--resume {ID} --model opus --tools ")), "{}", pipe.log[2]);
        assert!(pipe.sent.iter().any(|l| l.contains("\"initialize\"")), "the new process is initialized");
        let now = answer["session"].as_str().unwrap();
        assert!(now.starts_with(&format!("{ID}.")) && now != session, "{now}");
    }

    #[test]
    fn a_program_that_ends_mid_turn_interrupts_the_session() {
        let mut pipe = Scripted::new(harness_answers(vec![init_line()]));
        pipe.running = false;
        let mut deltas = Deltas::new(Vec::new());
        let req = request(json!({"model": "haiku", "messages": [{"role": "user", "content": "hi"}]}));
        let refusal = chat(&mut pipe, &mut deltas, &req, ID.into(), far()).unwrap_err();
        assert_eq!(refusal.kind, "provider_error");
        assert!(refusal.message.contains("interrupted"), "{}", refusal.message);
        assert_eq!(pipe.log.last().unwrap(), "close pipe-1");
    }

    #[test]
    fn every_pipe_code_maps_to_a_contract_type() {
        let want = [
            ("denied", "secret_denied"),
            ("setup_required", "secret_denied"),
            ("busy", "overloaded"),
            ("unavailable", "overloaded"),
            ("ended", "incomplete_stream"),
            ("invalid_request", "invalid_request"),
            ("too_large", "invalid_request"),
            ("lost", "provider_error"),
        ];
        for (code, kind) in want {
            let mut pipe = Scripted::new(|_| Vec::new());
            pipe.open_error = Some(code.into());
            let mut deltas = Deltas::new(Vec::new());
            let req = request(json!({"model": "haiku", "messages": [{"role": "user", "content": "hi"}]}));
            assert_eq!(chat(&mut pipe, &mut deltas, &req, ID.into(), far()).unwrap_err().kind, kind, "{code}");
        }
    }

    #[test]
    fn describe_takes_the_model_and_effort_from_the_listing() {
        let mut pipe = Scripted::new(harness_answers(Vec::new()));
        let models = listing(&mut pipe, "describe-1", far()).unwrap();
        assert_eq!(pipe.log.last().unwrap(), "close pipe-1");
        assert!(pipe.log[0].ends_with("--permission-prompt-tool stdio"), "no session of the person's: {}", pipe.log[0]);
        let described = describe(Some("haiku"), Some(&models));
        let options = described["options"].as_array().unwrap();
        assert_eq!(options[0], json!({"name": "model", "kind": "enum", "values": ["default", "haiku", "claude-haiku-4-5"]}));
        assert_eq!(options[1], json!({"name": "effort", "kind": "enum", "values": ["low", "medium", "high"]}));
        assert_eq!(options[2]["name"], "permission_mode");
        assert_eq!(options[3], json!({"name": "tools", "kind": "string"}));
        assert_eq!(described["context_window"], CONTEXT_WINDOW);
        assert_eq!(described["streaming"], true);
        assert_eq!(described["provider_tools"], json!([]));
        assert_eq!(models_answer(&models)["models"][1], json!({"id": "haiku", "name": "Haiku"}));
        // Without a listing, the options the harness cannot list stand.
        let bare = describe(None, None);
        let names: Vec<_> = bare["options"].as_array().unwrap().iter().map(|o| o["name"].clone()).collect();
        assert_eq!(names, [json!("permission_mode"), json!("tools")]);
    }

    #[test]
    fn describe_falls_back_only_when_no_login_is_bound() {
        // Nothing bound: the options the harness cannot list, deliberately.
        let mut pipe = Scripted::new(|_| Vec::new());
        pipe.open_error = Some("denied".into());
        let answered: Value = serde_json::from_str(&describe_answer(&mut pipe, "listing-1", None, far())).unwrap();
        assert_eq!(answered["status"], 200);
        let names: Vec<_> = answered["data"]["options"].as_array().unwrap().iter().map(|o| o["name"].clone()).collect();
        assert_eq!(names, [json!("permission_mode"), json!("tools")]);

        // A lost open, or a program that ends before it answers initialize,
        // keeps its contract error.
        for code in ["lost", "unavailable", "setup_required"] {
            let mut pipe = Scripted::new(|_| Vec::new());
            pipe.open_error = Some(code.into());
            let answered: Value = serde_json::from_str(&describe_answer(&mut pipe, "listing-1", None, far())).unwrap();
            assert_eq!(answered["error"]["type"], pipe_refusal(code).kind, "{code}");
        }
        let mut pipe = Scripted::new(|_| Vec::new());
        pipe.running = false;
        let answered: Value = serde_json::from_str(&describe_answer(&mut pipe, "listing-1", Some("opus"), far())).unwrap();
        assert_eq!(answered["error"]["type"], "incomplete_stream");
    }

    fn models_answer(listing: &[Value]) -> Value {
        models(listing)
    }

    #[test]
    fn a_tool_list_the_harness_cannot_be_given_whole_is_refused_before_anything_opens() {
        let tool = |name: &str, bytes: usize| Tool {
            name: name.into(),
            description: "d".repeat(bytes),
            parameters: json!({"type": "object"}),
        };
        assert!(carried_tools(&[tool("files", 1_000)]).is_ok());
        let one = carried_tools(&[tool("files", 1_000), tool("huge", MAX_TOOL_ARG_BYTES)]).unwrap_err();
        assert_eq!(one.kind, "invalid_request");
        assert!(one.message.contains("huge"), "{}", one.message);
        let many: Vec<Tool> = (0..10).map(|i| tool(&format!("t{i}"), 120_000)).collect();
        assert!(carried_tools(&many).unwrap_err().message.contains("one line"));

        let mut pipe = Scripted::new(|_| Vec::new());
        let mut deltas = Deltas::new(Vec::new());
        let mut req = request(json!({"model": "haiku", "messages": [{"role": "user", "content": "hi"}]}));
        req.tools = vec![tool("huge", MAX_TOOL_ARG_BYTES)];
        assert_eq!(chat(&mut pipe, &mut deltas, &req, ID.into(), far()).unwrap_err().kind, "invalid_request");
        assert!(pipe.log.is_empty(), "nothing was opened: {:?}", pipe.log);
    }

    #[test]
    fn a_result_past_the_bound_is_cut_with_a_note_within_it() {
        let short = "x".repeat(MAX_RESULT_CHARS);
        assert_eq!(bounded(&short), short);
        let long = "é".repeat(MAX_RESULT_CHARS + 10);
        let cut = bounded(&long);
        assert!(cut.encode_utf16().count() <= MAX_RESULT_CHARS);
        assert!(cut.contains("more were not shown"));
    }

    #[test]
    fn requests_off_the_contract_are_refused() {
        let base = json!({"model": "haiku", "messages": [{"role": "user", "content": "hi"}]});
        let with = |key: &str, value: Value| {
            let mut v = base.clone();
            v[key] = value;
            v
        };
        assert!(parse_request(&with("session", json!("not-a-uuid"))).is_err());
        assert!(parse_request(&with("provider_tools", json!(["web_search"]))).is_err());
        assert!(parse_request(&with("options", json!({"permission_mode": "bypassPermissions"}))).is_err());
        assert!(parse_request(&with("options", json!({"temperature": 1}))).is_err());
        assert!(parse_request(&with("model", json!("bad model"))).is_err());
        assert!(parse_request(&with("messages", json!([{"role": "assistant", "content": "x"}]))).is_err());
        assert!(parse_request(&with("options", json!({"tools": "Read,Grep", "permission_mode": "plan"}))).is_ok());
    }

    #[test]
    fn fresh_ids_are_session_ids() {
        assert!(session_id(&uuid([u64::MAX, u64::MAX])));
        assert!(session_id(&uuid([0, 0])));
        assert!(session_id(ID));
        assert!(!session_id("0B5C7C1E-2F3A-4D6E-8A9B-1C2D3E4F5A6B"));
    }

    // -----------------------------------------------------------------------
    // The shared vectors (tests/fixtures/model_chat.json)
    // -----------------------------------------------------------------------

    fn vectors() -> Value {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../../../../tests/fixtures/model_chat.json");
        serde_json::from_str(&std::fs::read_to_string(path).expect("the shared vectors")).unwrap()
    }

    /// The options a describe declares, or the member that breaks them, as
    /// `Prima.Model.options/1` reads them.
    fn declared(described: &Value) -> Result<Vec<Value>, String> {
        let kinds = vectors()["option_kinds"].clone();
        let options = match described.get("options") {
            None => return Ok(Vec::new()),
            Some(Value::Array(options)) => options,
            Some(_) => return Err("options".into()),
        };
        let mut names: Vec<&str> = Vec::new();
        for (i, option) in options.iter().enumerate() {
            let at = format!("options[{i}]");
            let Some(fields) = option.as_object() else { return Err(at) };
            let name = match fields.get("name") {
                Some(Value::String(n)) if !n.is_empty() && !names.contains(&n.as_str()) => n.as_str(),
                _ => return Err(format!("{at}.name")),
            };
            names.push(name);
            let kind = match fields.get("kind").and_then(Value::as_str) {
                Some(k) if kinds.as_array().unwrap().iter().any(|x| x == k) => k,
                _ => return Err(format!("{at}.kind")),
            };
            match (kind, fields.get("values")) {
                ("enum", Some(Value::Array(values))) => {
                    let mut seen: Vec<&str> = Vec::new();
                    for value in values {
                        match value.as_str() {
                            Some(v) if !v.is_empty() && !seen.contains(&v) => seen.push(v),
                            _ => return Err(format!("{at}.values")),
                        }
                    }
                    if seen.is_empty() {
                        return Err(format!("{at}.values"));
                    }
                }
                ("enum", _) => return Err(format!("{at}.values")),
                (_, Some(_)) => return Err(format!("{at}.values")),
                (_, None) => {}
            }
            if let Some(default) = fields.get("default") {
                if !of_kind(option, default) {
                    return Err(format!("{at}.default"));
                }
            }
            if let Some(other) = fields.keys().find(|k| !["name", "kind", "values", "default"].contains(&k.as_str())) {
                return Err(format!("{at}.{other}"));
            }
        }
        Ok(options.clone())
    }

    #[test]
    fn the_describe_vectors_read_as_prima_model_reads_them_and_this_describe_is_valid() {
        let v = vectors();
        for case in v["valid_describes"].as_array().unwrap() {
            assert_eq!(declared(&case["describe"]).unwrap(), case["options"].as_array().unwrap().clone(), "{}", case["why"]);
        }
        for case in v["invalid_describes"].as_array().unwrap() {
            assert_eq!(declared(&case["describe"]).unwrap_err(), case["member"].as_str().unwrap(), "{}", case["why"]);
        }
        let listing = vec![json!({"value": "default", "supportedEffortLevels": ["low"]}), json!({"value": "opus"})];
        assert!(declared(&describe(Some("opus"), Some(&listing))).is_ok());
        assert!(declared(&describe(None, None)).is_ok());
        assert!(declared(&json!({"options": chat_options()})).is_ok());
    }

    #[test]
    fn the_chat_vectors_are_checked_as_prima_model_checks_them() {
        let v = vectors();
        for case in v["valid_chat_requests"].as_array().unwrap() {
            let declared = case["declared"].as_array().unwrap();
            assert_eq!(check_chat_request(&case["request"], declared), Ok(()), "{}", case["why"]);
        }
        for case in v["invalid_chat_requests"].as_array().unwrap() {
            let declared = case["declared"].as_array().unwrap();
            assert_eq!(
                check_chat_request(&case["request"], declared).unwrap_err(),
                case["member"].as_str().unwrap(),
                "{}",
                case["why"]
            );
        }
    }

    /// The session a chat answer names, a response's data or a refusal's
    /// error, or the member that is off the contract, as
    /// `Prima.Model.response_session/1` reads it.
    fn response_session(answer: &Value) -> Result<Option<&str>, &'static str> {
        match answer.get("session") {
            None => Ok(None),
            Some(_) if answer["type"] == UNKNOWN_SESSION => Err("session"),
            Some(Value::String(session)) if !session.is_empty() => Ok(Some(session)),
            Some(_) => Err("session"),
        }
    }

    #[test]
    fn this_brain_s_answers_name_a_session_as_the_vectors_read_one() {
        let v = vectors();
        for case in v["valid_chat_responses"].as_array().unwrap() {
            assert_eq!(response_session(&case["response"]), Ok(case["session"].as_str()), "{}", case["why"]);
        }
        for case in v["invalid_chat_responses"].as_array().unwrap() {
            assert_eq!(response_session(&case["response"]), Err(case["member"].as_str().unwrap()), "{}", case["why"]);
        }
        let gone: Value = serde_json::from_str(&unknown_session().envelope()).unwrap();
        assert_eq!(response_session(&gone["error"]), Ok(None), "{gone}");
        assert!(session_id(&uuid([7, 9])));
    }
}
