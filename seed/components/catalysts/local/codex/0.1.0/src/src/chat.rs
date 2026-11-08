//! The `model/chat@1` contract on Codex's app-server, driven over the
//! program's pipe (`cyfr:process/pipe`) in the person's kept home.
//!
//! `chat` opens the session the request names (`<key>.<thread>`: the
//! pipe's key and Codex's thread), or a new one. A program started for
//! the open is initialized, its sign-in read (`account/read`), and the
//! thread started with CYFR's tools as its dynamic tools, or resumed from
//! the kept home. The newest user message starts a turn; a request that
//! answers the tool calls Codex holds answers them. The reply's text
//! streams, and the turn answers on the first of: calls of CYFR's tools
//! (`tool_call`s the host runs through its gate; Codex holds each
//! `item/tool/call` until the next `chat` answers it), the turn's end, or
//! an error. Codex's own tools (commands, patches) run inside the box
//! asking nothing, and are shown by name only. `describe` and `models`
//! read Codex's own model listing (`model/list`).
//!
//! The catalyst holds nothing between runs: the session is the program's,
//! a held call's request id and turn ride on its `tool_call`
//! (`provider_data`), and the session on the response. Nothing Codex
//! writes but its reply's text and its tool calls reaches the answer: no
//! line, no error text, no file of its home, no sign-in text.

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::server::{self, Counts, Event};
use crate::stream::{self, Deltas, Sink};

pub const CONTRACT: &str = "model/chat@1";
const PROVIDER: &str = "codex";

/// The `login` need the manifest declares for the program `codex`.
pub const NEED: &str = "codex";

/// What Codex's app-server does not list: a model's context window, as
/// the catalog Codex 0.167.0 ships (`codex-rs/models-manager/models.json`,
/// each entry's `context_window`) gives it for every model it holds. A
/// version bump reads them again.
const CONTEXT_WINDOWS: &[(&str, u64)] = &[
    ("gpt-6-astra", 272_000),
    ("gpt-6.1-sol", 272_000),
    ("gpt-6.1-terra", 500_000),
    ("gpt-6-sol", 272_000),
    ("gpt-6-luna", 272_000),
    ("gpt-5.6-sol", 272_000),
    ("gpt-5.6-terra", 272_000),
    ("gpt-5.6-luna", 272_000),
    ("gpt-daybreak-blue-latest", 272_000),
    ("gpt-daybreak-red-latest", 372_000),
    ("gpt-5.5", 272_000),
    ("codex-auto-review", 272_000),
];

/// The window of a model the catalog does not hold (a model an account's
/// own listing names): the smallest the catalog gives any model.
const FALLBACK_CONTEXT_WINDOW: u64 = 272_000;

/// The model option's value for the one Codex marks its default: no model
/// is sent, and Codex runs its own.
const DEFAULT_MODEL: &str = "default";

/// The images Codex takes as input (`UserInput::Image` by data URL).
const MEDIA_TYPES: &[&str] = &["image/jpeg", "image/png", "image/gif", "image/webp"];

/// How long one read of the pipe waits for a line.
const RECV_WAIT_MS: u32 = 20_000;

/// Once a turn holds a call of CYFR's, how long a read waits for the
/// further calls Codex runs in parallel with it before the turn answers.
const SETTLE_MS: u32 = 250;

/// The most bytes of one line to the program (`Prima.LocusBackends`'s
/// `max_line_bytes`): `thread/start` carries the whole tool list in one.
pub const MAX_LINE_BYTES: usize = 1_048_576;

/// The most bytes of one tool result as it is written into its answer's
/// line (escaped as JSON), leaving the line room within `MAX_LINE_BYTES`.
pub const MAX_RESULT_BYTES: usize = 524_288;

/// The most pages of Codex's model listing read.
const LISTING_PAGES: usize = 10;

/// How long `describe` and `models` wait for Codex's listing: a first
/// start fetches the program.
pub const LISTING_BUDGET: Duration = Duration::from_secs(150);

/// How long a `chat` runs before it answers: inside the 30 minutes the
/// manifest consents this catalyst (`caps.limits.timeout`), which is how
/// long the loop waits for a model call (`Aqua.Loop`) and the deadline the
/// worker service enforces, with room to close the session and answer
/// before either stops the run. Past it the session is interrupted
/// (`interrupted`); its partial work stays in its home and thread, and the
/// next message resumes it.
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

/// A typed refusal of the contract, and the pipe's code when the pipe
/// answered it.
#[derive(Debug, PartialEq)]
pub struct Refusal {
    pub status: i64,
    pub kind: &'static str,
    pub message: String,
    pub code: Option<String>,
}

impl Refusal {
    fn new(status: i64, kind: &'static str, message: impl Into<String>) -> Self {
        Refusal { status, kind, message: message.into(), code: None }
    }

    pub fn envelope(&self) -> String {
        json!({"status": self.status, "error": {"type": self.kind, "message": self.message}}).to_string()
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
            "The codex program's login entry, its row or its grant no longer serves, or its folder is past its cap; see the Programs page.",
        ),
        "busy" => Refusal::new(529, "overloaded", "The box runs as many programs as it may; try again later."),
        "unavailable" => Refusal::new(503, "overloaded", "The program's box could not answer; try again later."),
        "ended" => Refusal::new(502, "incomplete_stream", "Codex ended before it finished its turn."),
        "invalid_request" | "too_large" => invalid("The program's pipe refused what this turn sent."),
        _ => Refusal::new(
            502,
            "provider_error",
            "The pipe's answer was lost; Codex may have received what this turn sent.",
        ),
    };
    Refusal { code: Some(code.to_string()), ..refusal }
}

/// The refusal for the error a turn failed with. It answers only after
/// this run sent something, so it is never a type the loop retries: the
/// same request made again would start the same turn or answer the same
/// calls twice. A rate limit or an overload is `provider_error` naming
/// Codex's reason; the turn ended on Codex's side, the session is left as
/// it is, and the next message goes on in it.
fn turn_error(kind: &'static str) -> Refusal {
    let (status, kind, message) = match kind {
        "authentication" => (401, kind, "Codex is not signed in, or its account cannot serve this; sign in again from the Programs page."),
        "rate_limited" => (502, "provider_error", "Codex's account is past its usage or rate limit, and its turn ended; send the message again later."),
        "overloaded" => (502, "provider_error", "Codex's provider is overloaded, and its turn ended; send the message again later."),
        "invalid_request" => (400, kind, "Codex refused the request."),
        "unknown_model" => (404, kind, "Codex does not know the model."),
        _ => (502, "provider_error", "Codex failed to finish its turn."),
    };
    Refusal::new(status, kind, message)
}

/// The refusal of a program whose sign-in Codex holds none of: read before
/// anything is sent to a thread.
fn not_signed_in() -> Refusal {
    Refusal::new(401, "authentication", "Codex is not signed in; sign in from the Programs page.")
}

fn ended() -> Refusal {
    pipe_refusal("ended")
}

// ---------------------------------------------------------------------------
// The contract request
// ---------------------------------------------------------------------------

pub struct Tool {
    pub name: String,
    pub description: String,
    pub parameters: Value,
}

/// CYFR's answer to one call Codex holds: its request (the id Codex gave
/// its `item/tool/call`), the turn that made it, and what CYFR answered.
#[derive(Debug, PartialEq)]
pub struct Answer {
    pub request: Value,
    pub turn: String,
    pub name: String,
    pub content: String,
    pub is_error: bool,
}

/// What a `chat` sends Codex.
#[derive(Debug, PartialEq)]
pub enum Input {
    /// The newest user message, as Codex's input items, and whether the
    /// newest assistant message before it ended on calls of this brain's,
    /// which the thread may still hold.
    Message { items: Vec<Value>, held: bool },
    /// CYFR's answers to the calls the last assistant message made.
    Answers(Vec<Answer>),
}

/// A session this catalyst answered: the pipe's key, Codex's thread, and
/// the thread's token usage as the run that answered last read it, which
/// the next run counts its usage from.
#[derive(Debug, PartialEq)]
pub struct Session {
    pub key: String,
    pub thread: String,
    pub total: Option<Counts>,
}

impl Session {
    /// `<key>.<thread>`, and `.<input>-<output>-<cached>-<cache writes>`
    /// once the thread's usage is known.
    fn name(key: &str, thread: &str, total: Option<&Counts>) -> String {
        match total {
            Some([i, o, c, w]) => format!("{key}.{thread}.{i}-{o}-{c}-{w}"),
            None => format!("{key}.{thread}"),
        }
    }

    fn parse(answered: &str) -> Option<Session> {
        let mut parts = answered.split('.');
        let (key, thread) = (parts.next()?, parts.next()?);
        let total = match parts.next() {
            None => None,
            Some(counts) => {
                let counts: Vec<u64> = counts.split('-').map(|n| n.parse().ok()).collect::<Option<_>>()?;
                Some(<Counts>::try_from(counts).ok()?)
            }
        };
        (parts.next().is_none() && session_id(key) && session_id(thread))
            .then(|| Session { key: key.into(), thread: thread.into(), total })
    }
}

pub struct Request {
    pub model: String,
    pub system: Option<String>,
    pub tools: Vec<Tool>,
    pub session: Option<Session>,
    /// The model and effort the turn runs with; `None` is Codex's own.
    pub run_model: Option<String>,
    pub effort: Option<String>,
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
    let session = match params.get("session") {
        None => None,
        Some(Value::String(answered)) => match Session::parse(answered) {
            Some(session) => Some(session),
            None => return Err("'session' is not a session this brain answered".into()),
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
    Ok(Request {
        run_model: option("model").or_else(|| Some(model.clone())).filter(|m| m != DEFAULT_MODEL),
        effort: option("effort"),
        model,
        system,
        tools,
        session,
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

fn role(message: &Value) -> Option<&str> {
    message.get("role").and_then(Value::as_str)
}

/// The tool calls of an assistant message that carry this brain's request.
fn held_calls(message: &Value) -> Vec<&Value> {
    message
        .get("content")
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks
                .iter()
                .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_call"))
                .filter(|b| b["provider_data"].get("request_id").is_some())
                .collect()
        })
        .unwrap_or_default()
}

/// What the request's last message asks Codex: a user message, or tool
/// results answering the calls the message before it made.
fn input(messages: &[Value]) -> Result<Input, String> {
    let last = messages.last().expect("non-empty");
    let before = messages.iter().rev().skip(1);
    match role(last) {
        Some("user") => {
            let newest = before.clone().find(|m| role(m) == Some("assistant"));
            Ok(Input::Message {
                items: user_input(last)?,
                held: newest.is_some_and(|m| !held_calls(m).is_empty()),
            })
        }
        Some("tool") => {
            let results: Vec<&Value> = match last.get("content") {
                Some(Value::Array(blocks)) => blocks
                    .iter()
                    .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
                    .collect(),
                _ => Vec::new(),
            };
            if results.is_empty() {
                return Err("the last message must answer the tool calls before it".into());
            }
            let calls = before
                .clone()
                .find(|m| role(m) == Some("assistant"))
                .map(held_calls)
                .unwrap_or_default();
            let answers = results
                .iter()
                .map(|result| {
                    let id = result
                        .get("tool_call_id")
                        .and_then(Value::as_str)
                        .ok_or("the tool result names no tool_call_id")?;
                    let call = calls
                        .iter()
                        .find(|c| c.get("id").and_then(Value::as_str) == Some(id))
                        .ok_or("the tool result answers no tool call of this brain's in the message before it")?;
                    let data = &call["provider_data"];
                    Ok(Answer {
                        request: data["request_id"].clone(),
                        turn: data
                            .get("turn_id")
                            .and_then(Value::as_str)
                            .ok_or("the tool call carries no turn_id of this brain's")?
                            .to_string(),
                        name: call.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
                        content: result_text(result.get("content"))?,
                        is_error: result.get("is_error").and_then(Value::as_bool).unwrap_or(false),
                    })
                })
                .collect::<Result<Vec<_>, String>>()?;
            Ok(Input::Answers(answers))
        }
        _ => Err("the last message must be the user's or tool results".into()),
    }
}

/// A user message's content as Codex's input items.
fn user_input(message: &Value) -> Result<Vec<Value>, String> {
    let text = |text: &str| json!({"type": "text", "text": text, "textElements": []});
    match message.get("content") {
        Some(Value::String(s)) if !s.is_empty() => Ok(vec![text(s)]),
        Some(Value::Array(blocks)) if !blocks.is_empty() => blocks
            .iter()
            .map(|block| match block.get("type").and_then(Value::as_str) {
                Some("text") => Ok(text(block.get("text").and_then(Value::as_str).unwrap_or(""))),
                Some("image") => {
                    let media_type = block.get("media_type").and_then(Value::as_str);
                    let data = block.get("data").and_then(Value::as_str);
                    match (media_type, data) {
                        (Some(media_type), Some(data)) if MEDIA_TYPES.contains(&media_type) => {
                            Ok(json!({"type": "image", "url": format!("data:{media_type};base64,{data}")}))
                        }
                        _ => Err("an image block needs a media_type this brain takes and its data".to_string()),
                    }
                }
                _ => Err("a user message holds text and image blocks".into()),
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

/// A model id: one of Codex's listing's, or `default`.
pub fn model_id(model: &str) -> bool {
    !model.is_empty()
        && model.len() <= 128
        && model.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && model.chars().all(|c| c.is_ascii_alphanumeric() || "._:-[]".contains(c))
}

/// A key this catalyst chose, or a thread Codex named: a lowercase UUID.
pub fn session_id(id: &str) -> bool {
    id.len() == 36
        && id.char_indices().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit() && !c.is_ascii_uppercase(),
        })
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

/// A dynamic tool's name as Codex takes one (`validate_dynamic_tools`,
/// 0.167.0): `^[a-zA-Z0-9_-]+$`, at most 128 characters, never `mcp` or
/// `mcp__…`, which Codex reserves.
fn dynamic_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        && name != "mcp"
        && !name.starts_with("mcp__")
}

/// The request's tools as a new thread's dynamic tools, or the refusal of
/// a list Codex cannot be given whole: a name Codex does not take, a name
/// given twice, or a list past one line. Nothing is cut and nothing is
/// opened then.
pub fn dynamic_tools(tools: &[Tool]) -> Result<Vec<Value>, Refusal> {
    let mut names: Vec<&str> = Vec::new();
    for tool in tools {
        if !dynamic_name(&tool.name) {
            return Err(invalid(format!(
                "The tool {} has a name Codex does not take: letters, digits, _ and - only, never mcp.",
                tool.name
            )));
        }
        if names.contains(&tool.name.as_str()) {
            return Err(invalid(format!("The tool {} is named twice.", tool.name)));
        }
        names.push(&tool.name);
    }
    let specs: Vec<Value> = tools
        .iter()
        .map(|t| server::dynamic_tool(&t.name, &t.description, &t.parameters))
        .collect();
    let line = json!(specs).to_string().len();
    if line + 1024 > MAX_LINE_BYTES {
        return Err(invalid(format!(
            "The tools are {line} bytes as one line to Codex, past the {MAX_LINE_BYTES} one line carries."
        )));
    }
    Ok(specs)
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

/// The options a chat request is checked against: the model and effort as
/// any value Codex takes, since its listing is `describe`'s to ask.
fn chat_options() -> Vec<Value> {
    vec![json!({"name": "model", "kind": "string"}), json!({"name": "effort", "kind": "string"})]
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

/// Codex's model listing (`model/list`, every page), in a session of its
/// own that is closed after: each entry `{id, displayName,
/// supportedReasoningEfforts, isDefault, ...}`.
pub fn listing<P: Pipe>(pipe: &mut P, key: &str, deadline: Instant) -> Result<Vec<Value>, Refusal> {
    let argv: Vec<String> = server::ARGV.iter().map(|a| a.to_string()).collect();
    let opened = pipe.open(NEED, key, &argv).map_err(|code| pipe_refusal(&code))?;
    let mut reader = Reader::new(&opened.session);
    let listed = list_models(pipe, &mut reader, deadline);
    let _ = pipe.close(&opened.session);
    listed
}

fn list_models<P: Pipe>(pipe: &mut P, reader: &mut Reader, deadline: Instant) -> Result<Vec<Value>, Refusal> {
    let session = reader.session.clone();
    let send = |pipe: &mut P, line: String| pipe.send(&session, &[line]).map_err(|code| pipe_refusal(&code));
    send(pipe, server::initialize("cyfr-initialize"))?;
    reader.answer(pipe, "cyfr-initialize", deadline)?;
    send(pipe, server::initialized())?;
    let mut models = Vec::new();
    let mut cursor: Option<String> = None;
    for page in 0..LISTING_PAGES {
        let id = format!("cyfr-models-{page}");
        send(pipe, server::model_list(&id, cursor.as_deref()))?;
        let (listed, _) = reader.answer(pipe, &id, deadline)?;
        models.extend(
            listed["data"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|m| m.get("id").and_then(Value::as_str).is_some_and(model_id))
                .cloned(),
        );
        cursor = listed.get("nextCursor").and_then(Value::as_str).map(str::to_string);
        if cursor.is_none() {
            break;
        }
    }
    Ok(models)
}

/// What this catalyst can do, with the options Codex lets a caller set:
/// the model and effort from its listing when it could be asked. With a
/// `model`, that model's window, which Codex does not list.
pub fn describe(model: Option<&str>, listing: Option<&[Value]>) -> Value {
    let mut options = Vec::new();
    if let Some(models) = listing.filter(|m| !m.is_empty()) {
        let mut values: Vec<&str> = vec![DEFAULT_MODEL];
        for id in models.iter().filter_map(|m| m["id"].as_str()) {
            if !values.contains(&id) {
                values.push(id);
            }
        }
        options.push(json!({"name": "model", "kind": "enum", "values": values}));
        let mut levels: Vec<&str> = Vec::new();
        for model in models {
            for level in model["supportedReasoningEfforts"].as_array().into_iter().flatten() {
                if let Some(level) = level["reasoningEffort"].as_str().filter(|l| !l.is_empty()) {
                    if !levels.contains(&level) {
                        levels.push(level);
                    }
                }
            }
        }
        if !levels.is_empty() {
            options.push(json!({"name": "effort", "kind": "enum", "values": levels}));
        }
    }
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
        described["context_window"] = json!(context_window(model, listing));
    }
    described
}

/// A model's window from the catalog's table, `default` being the model
/// Codex's listing marks its default.
fn context_window(model: &str, listing: Option<&[Value]>) -> u64 {
    let id = match model {
        DEFAULT_MODEL => listing
            .and_then(|models| models.iter().find(|m| m["isDefault"] == true))
            .and_then(|m| m["id"].as_str())
            .unwrap_or(model),
        id => id,
    };
    CONTEXT_WINDOWS
        .iter()
        .find(|(known, _)| *known == id)
        .map_or(FALLBACK_CONTEXT_WINDOW, |(_, window)| *window)
}

/// `describe`'s envelope, from Codex's listing in a session of its own
/// (keyed `key`). With no login entry bound (the pipe answers `denied`) it
/// answers with no options, deliberately; any other failure to list keeps
/// its contract error.
pub fn describe_answer<P: Pipe>(pipe: &mut P, key: &str, model: Option<&str>, deadline: Instant) -> String {
    let listing = match listing(pipe, key, deadline) {
        Ok(listing) => Some(listing),
        Err(refusal) if refusal.code.as_deref() == Some("denied") => None,
        Err(refusal) => return refusal.envelope(),
    };
    json!({"status": 200, "data": describe(model, listing.as_deref())}).to_string()
}

/// The listing as contract entries, Codex's default first as `default`.
pub fn models(listing: &[Value]) -> Value {
    let mut entries = Vec::new();
    if let Some(default) = listing.iter().find(|m| m["isDefault"] == true) {
        let name = default.get("displayName").cloned().unwrap_or(default["id"].clone());
        entries.push(json!({"id": DEFAULT_MODEL, "name": format!("Default ({})", name.as_str().unwrap_or(""))}));
    }
    entries.extend(
        listing
            .iter()
            .map(|m| json!({"id": m["id"], "name": m.get("displayName").cloned().unwrap_or(m["id"].clone())})),
    );
    json!({"models": entries})
}

// ---------------------------------------------------------------------------
// Reading the session
// ---------------------------------------------------------------------------

/// The session's lines, read in order past `after`.
///
/// A read names the lines its buffer no longer held between its `after`
/// and its first line (`dropped`). A run's first read starts where no read
/// of its own stood, so the lines an earlier run released count there too,
/// and it counts no loss. Every later read is past this run's own: a gap
/// there is output Codex wrote and no one read (a call or the turn's end
/// among it, perhaps), so the turn cannot be answered from what is left.
/// The session is closed, and the next chat starts the program again and
/// resumes the thread from its home.
///
/// A run answers only once it has handled every line it read, and before
/// it answers it releases them (`release`): the lines the session holds
/// when the next run attaches are the ones no run has handled, such as
/// calls Codex made in parallel after this run's answer.
struct Reader {
    session: String,
    after: u64,
    first: bool,
}

impl Reader {
    fn new(session: &str) -> Self {
        Reader { session: session.to_string(), after: 0, first: true }
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
                ..Refusal::new(502, "provider_error", format!("{} lines of Codex's output were lost unread.", got.dropped))
            });
        }
        if got.lines.is_empty() && !got.running {
            return Ok(None);
        }
        Ok(Some(got.lines.into_iter().map(|(_, text)| text).collect()))
    }

    /// Let the session's buffer go of every line this run read: a read
    /// naming the last of them.
    fn release<P: Pipe>(&self, pipe: &mut P) {
        if self.after > 0 {
            let _ = pipe.recv(&self.session, self.after, 0);
        }
    }

    /// The answer to this catalyst's request `id`, and every other line read
    /// meanwhile, in order, for the turn to handle.
    fn answer<P: Pipe>(&mut self, pipe: &mut P, id: &str, deadline: Instant) -> Result<(Value, Vec<String>), Refusal> {
        let mut others = Vec::new();
        loop {
            let wait = wait_until(deadline).ok_or_else(timed_out)?;
            let lines = self.next(pipe, wait)?.ok_or_else(ended)?;
            let mut answered = None;
            for line in lines {
                match server::read(&line) {
                    Event::Response { id: got, result } if got == id && answered.is_none() => answered = Some(result),
                    _ => others.push(line),
                }
            }
            match answered {
                Some(Ok(result)) => return Ok((result, others)),
                Some(Err(_)) => return Err(Refusal::new(502, "provider_error", "Codex refused to start this session or turn.")),
                None => {}
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
        ..Refusal::new(504, "incomplete_stream", "Codex was still working when this run's time ran out.")
    }
}

/// What a turn answers when the pipe failed once this run sent anything,
/// or its time ran out: whether Codex received what was sent, acted on it
/// or answered it is not known, and sending it again could make it act
/// twice. The session is closed; the next message starts the program
/// again resuming the thread, which its home keeps (a call Codex held is
/// recorded there as cancelled). Not a type the loop retries.
fn interrupted() -> Refusal {
    Refusal::new(
        502,
        "provider_error",
        "The session with Codex was interrupted mid-turn: its pipe failed or its time ran out, and what reached it is not known. The next message resumes the session from its home.",
    )
}

fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

// ---------------------------------------------------------------------------
// chat
// ---------------------------------------------------------------------------

/// `content` within `MAX_RESULT_BYTES` as it is written into a line
/// (escaped as JSON), the rest named in a note.
pub fn bounded(content: &str) -> String {
    let escaped = |c: char| match c {
        '"' | '\\' | '\n' | '\r' | '\t' | '\u{8}' | '\u{c}' => 2,
        c if (c as u32) < 0x20 => 6,
        c => c.len_utf8(),
    };
    let total: usize = content.chars().map(escaped).sum();
    if total <= MAX_RESULT_BYTES {
        return content.to_string();
    }
    let note = |cut: usize| {
        format!("\n…[CYFR cut this result at {MAX_RESULT_BYTES} bytes, what one answer to Codex carries; {cut} more bytes were not shown. Ask for a narrower part.]")
    };
    let room = MAX_RESULT_BYTES - note(total).len() * 2;
    let mut kept = String::new();
    let mut used = 0;
    for c in content.chars() {
        if used + escaped(c) > room {
            break;
        }
        used += escaped(c);
        kept.push(c);
    }
    kept.push_str(&note(total - used));
    kept
}

/// The ids of this run's requests: unique to the run, so an answer left
/// unread by an earlier run is never taken for this run's.
struct Ids(String);

impl Ids {
    fn of(&self, what: &str) -> String {
        format!("cyfr-{what}-{}", self.0)
    }
}

/// One `chat`: the contract response, or a refusal. `fresh` names a new
/// session's key and this run's request ids.
pub fn chat<P: Pipe, S: Sink>(
    pipe: &mut P,
    deltas: &mut Deltas<S>,
    request: &Request,
    fresh: String,
    deadline: Instant,
) -> Result<Value, Refusal> {
    // A new thread is given the request's tools; a resumed one keeps the
    // tools it was started with, and the request's are not compared: the
    // host's gate refuses a call outside the tools a turn may use.
    let tools = match request.session {
        None => Some(dynamic_tools(&request.tools)?),
        Some(_) => None,
    };
    let key = request.session.as_ref().map_or(fresh.clone(), |s| s.key.clone());
    let argv: Vec<String> = server::ARGV.iter().map(|a| a.to_string()).collect();
    let mut opened = pipe.open(NEED, &key, &argv).map_err(|code| pipe_refusal(&code))?;
    // A running program whose newest turn ended on calls of CYFR's may
    // still hold them, and a new turn would wait behind them: the program
    // is closed and started again, and the thread resumed records them as
    // cancelled.
    if opened.resumed && matches!(request.input, Input::Message { held: true, .. }) {
        let _ = pipe.close(&opened.session);
        opened = pipe.open(NEED, &key, &argv).map_err(|code| pipe_refusal(&code))?;
        if opened.resumed {
            return Err(Refusal::new(502, "provider_error", "Codex's session could not be restarted."));
        }
    }
    let session = opened.session.clone();
    let mut reader = Reader::new(&session);
    let ids = Ids(fresh.chars().take(8).collect());
    // Once this run sends anything, a failure of the pipe interrupts the
    // session: it is closed, nothing is sent again, and the next message
    // resumes it (`interrupted`).
    match converse(pipe, deltas, &mut reader, request, &key, tools, opened.resumed, &ids, deadline) {
        Err(refusal) if refusal.code.is_some() => {
            let _ = pipe.close(&session);
            Err(interrupted())
        }
        answered => {
            reader.release(pipe);
            answered
        }
    }
}

/// Start the program's side of the turn (a new program is initialized, its
/// sign-in read and its thread started or resumed), send the request's
/// message or its answers, and read the turn to its first answer.
#[allow(clippy::too_many_arguments)]
fn converse<P: Pipe, S: Sink>(
    pipe: &mut P,
    deltas: &mut Deltas<S>,
    reader: &mut Reader,
    request: &Request,
    key: &str,
    tools: Option<Vec<Value>>,
    resumed: bool,
    ids: &Ids,
    deadline: Instant,
) -> Result<Value, Refusal> {
    let session = reader.session.clone();
    let send = |pipe: &mut P, line: String| pipe.send(&session, &[line]).map_err(|code| pipe_refusal(&code));
    // A thread or turn Codex refused to start leaves a program that would
    // refuse the next message the same way: it is closed, and the next
    // message starts it again.
    let closing = |pipe: &mut P, refusal: Refusal| {
        if refusal.code.is_none() {
            let _ = pipe.close(&session);
        }
        refusal
    };
    let mut early = Vec::new();
    let mut model = request.run_model.clone();
    // A new thread has used nothing; a known one has used what the session
    // the request names last read.
    let mut total = request.session.as_ref().and_then(|s| s.total);
    let thread = match (&request.session, resumed) {
        (Some(session), true) => session.thread.clone(),
        (known, false) => {
            send(pipe, server::initialize(&ids.of("initialize")))?;
            let (_, others) = reader.answer(pipe, &ids.of("initialize"), deadline)?;
            early.extend(others);
            send(pipe, server::initialized())?;
            send(pipe, server::account_read(&ids.of("account")))?;
            let (account, others) = reader.answer(pipe, &ids.of("account"), deadline)?;
            early.extend(others);
            if account["account"].is_null() && account["requiresOpenaiAuth"] != false {
                let _ = pipe.close(&session);
                return Err(not_signed_in());
            }
            let id = ids.of("thread");
            let line = match known {
                Some(known) => server::thread_resume(&id, &known.thread, request.system.as_deref()),
                None => {
                    total = Some([0; 4]);
                    server::thread_start(&id, request.system.as_deref(), tools.as_deref().unwrap_or(&[]))
                }
            };
            send(pipe, line)?;
            let (started, others) = reader.answer(pipe, &id, deadline).map_err(|r| closing(pipe, r))?;
            early.extend(others);
            if model.is_none() {
                model = started.get("model").and_then(Value::as_str).map(str::to_string);
            }
            match started["thread"].get("id").and_then(Value::as_str) {
                Some(thread) if session_id(thread) => thread.to_string(),
                _ => return Err(Refusal::new(502, "provider_error", "Codex started no thread this brain can name.")),
            }
        }
        // A fresh key names no running program.
        (None, true) => return Err(Refusal::new(502, "provider_error", "Codex's session could not be started.")),
    };
    let answered: Vec<Value>;
    let turn = match &request.input {
        Input::Answers(answers) if resumed => {
            for answer in answers {
                send(pipe, server::tool_answer(&answer.request, &bounded(&answer.content), !answer.is_error))?;
            }
            answered = answers.iter().map(|a| a.request.clone()).collect();
            answers[0].turn.clone()
        }
        input => {
            answered = Vec::new();
            let items = match input {
                Input::Message { items, .. } => items.clone(),
                // The program that held the calls ended; its resumed thread
                // records them cancelled, and CYFR's answers come as a
                // message.
                Input::Answers(answers) => vec![json!({"type": "text", "text": restarted(answers), "textElements": []})],
            };
            let id = ids.of("turn");
            send(pipe, server::turn_start(&id, &thread, &items, request.run_model.as_deref(), request.effort.as_deref()))?;
            let (started, others) = reader.answer(pipe, &id, deadline).map_err(|r| closing(pipe, r))?;
            early.extend(others);
            started["turn"]
                .get("id")
                .and_then(Value::as_str)
                .filter(|t| !t.is_empty())
                .ok_or_else(|| Refusal::new(502, "provider_error", "Codex started no turn."))?
                .to_string()
        }
    };
    let model = model.unwrap_or_else(|| request.model.clone());
    let turn = Turn { id: &turn, model: &model, key, thread: &thread, total, answered: &answered };
    read_turn(pipe, deltas, reader, &turn, early, deadline)
}

/// CYFR's answers to calls a thread held when its program ended, as a
/// message to the resumed thread.
fn restarted(answers: &[Answer]) -> String {
    let mut text = String::from("Your session restarted while CYFR held your calls, so they show as cancelled. CYFR's answers:");
    for answer in answers {
        let what = if answer.is_error { "refused it" } else { "ran it" };
        text.push_str(&format!("\n\n{}: CYFR {what} and answered:\n{}", answer.name, bounded(&answer.content)));
    }
    text
}

/// The turn a run reads: its id, the model it runs on, the session's key
/// and thread, the thread's usage before this run (`None` when not
/// known), and the requests this run has just answered.
struct Turn<'a> {
    id: &'a str,
    model: &'a str,
    key: &'a str,
    thread: &'a str,
    total: Option<Counts>,
    answered: &'a [Value],
}

/// Read the turn to its first answer: the lines read before the turn was
/// known (`early`), then the session's.
fn read_turn<P: Pipe, S: Sink>(
    pipe: &mut P,
    deltas: &mut Deltas<S>,
    reader: &mut Reader,
    turn: &Turn,
    early: Vec<String>,
    deadline: Instant,
) -> Result<Value, Refusal> {
    let mut text = String::new();
    let mut messages: Vec<String> = Vec::new();
    let mut streamed: Vec<String> = Vec::new();
    let mut calls: Vec<Value> = Vec::new();
    let mut shown: u64 = 0;
    // This run's usage is what the thread's total grew by past the total
    // before it. With no total known, the first snapshot read is only the
    // point the run counts from.
    let mut used: Counts = [0; 4];
    let mut total = turn.total;
    let response = |text: &str, content: Vec<Value>, stop: &str, used: &Counts, total: Option<&Counts>| {
        let mut blocks = Vec::new();
        if !text.is_empty() {
            blocks.push(json!({"type": "text", "text": text}));
        }
        blocks.extend(content);
        json!({"model": turn.model, "content": blocks, "stop_reason": stop, "usage": server::usage(used),
               "session": Session::name(turn.key, turn.thread, total)})
    };
    // An agent message after another is set apart by a blank line, in the
    // stream as in the answer.
    let begin = |item: &str, messages: &mut Vec<String>, deltas: &mut Deltas<S>| {
        if !messages.iter().any(|m| m == item) {
            if !messages.is_empty() {
                deltas.text("\n\n");
            }
            messages.push(item.to_string());
        }
    };

    let mut batch = Some(early);
    let mut finished: Option<Result<Value, Refusal>> = None;
    loop {
        let lines = match batch.take() {
            Some(lines) => lines,
            None => {
                let wait = match wait_until(deadline) {
                    Some(wait) if !calls.is_empty() => wait.min(SETTLE_MS),
                    Some(wait) => wait,
                    None => return Err(timed_out()),
                };
                match reader.next(pipe, wait)? {
                    Some(lines) => lines,
                    None => return Err(ended()),
                }
            }
        };
        if lines.is_empty() {
            deltas.flush();
            // The calls held, with none more arriving: the turn answers them.
            if !calls.is_empty() {
                let answer = response(&text, std::mem::take(&mut calls), "tool_call", &used, total.as_ref());
                stream::close(deltas, &answer);
                return Ok(answer);
            }
            continue;
        }
        for line in lines {
            match server::read(&line) {
                Event::Delta { turn: t, item, text: delta } if t == turn.id => {
                    begin(&item, &mut messages, deltas);
                    deltas.text(&delta);
                    if !streamed.contains(&item) {
                        streamed.push(item);
                    }
                }
                Event::Message { turn: t, item, text: whole } if t == turn.id => {
                    begin(&item, &mut messages, deltas);
                    if !streamed.contains(&item) {
                        deltas.text(&whole);
                    }
                    if !text.is_empty() {
                        text.push_str("\n\n");
                    }
                    text.push_str(&whole);
                }
                // Codex's own tool runs in the box (D2), and is shown by
                // name only, since what it ran may hold what its home holds.
                Event::OwnTool { turn: t, id, kind } if t == turn.id => {
                    stream::tool_call(deltas, shown, &id, &kind, None);
                    shown += 1;
                }
                Event::ToolCall { request, turn: t, call, tool, arguments } if t == turn.id => {
                    // A call this run has just answered, read again past
                    // an earlier run's release that did not reach the box.
                    if turn.answered.contains(&request) {
                        continue;
                    }
                    stream::tool_call(deltas, shown, &call, &tool, Some(&arguments));
                    shown += 1;
                    calls.push(json!({
                        "type": "tool_call",
                        "id": call,
                        "name": tool,
                        "arguments": arguments,
                        "provider_data": {"request_id": request, "turn_id": turn.id}
                    }));
                }
                // A call of a turn this run does not read: no one waits on
                // its answer, and Codex is told so.
                Event::ToolCall { request, .. } => {
                    let line = server::tool_answer(&request, "CYFR did not run this call: its turn is no longer the one CYFR answers.", false);
                    pipe.send(&reader.session, &[line]).map_err(|code| pipe_refusal(&code))?;
                }
                Event::Request { request, method, params } => {
                    let line = match server::allow(&method, &params, now_secs()) {
                        Some(allowed) => server::result(&request, allowed),
                        None => server::refuse(&request, &method),
                    };
                    pipe.send(&reader.session, &[line]).map_err(|code| pipe_refusal(&code))?;
                }
                Event::Usage { turn: t, total: now } if t == turn.id => {
                    if let Some(before) = &total {
                        server::consumed(&mut used, before, &now);
                    }
                    total = Some(now);
                }
                // A turn ends only once every call it made is answered. The
                // rest of the batch is still handled: the run releases it.
                Event::TurnDone { turn: t, status, error } if t == turn.id && finished.is_none() => {
                    finished = Some(match status.as_str() {
                        "completed" => Ok(response(&text, Vec::new(), "end_turn", &used, total.as_ref())),
                        "interrupted" => Err(Refusal::new(502, "provider_error", "Codex's turn was interrupted on its side.")),
                        _ => Err(turn_error(server::error_kind(&error))),
                    });
                }
                _ => {}
            }
        }
        if let Some(finished) = finished {
            if let Ok(answer) = &finished {
                stream::close(deltas, answer);
            }
            return finished;
        }
        deltas.flush_due();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    const KEY: &str = "0b5c7c1e-2f3a-4d6e-8a9b-1c2d3e4f5a6b";
    const THREAD: &str = "01a1bb90-88fc-72c0-895e-976b439b7eb5";
    const CANARY: &str = "CODEX-HOME-CANARY";

    /// A fake Codex app-server, answering as 0.167.0 answered when it was
    /// driven (README, "Verified against 0.167.0"). Each `turn/start` takes
    /// the next turn of the script, whose segments are written one at a
    /// time: the first after the turn starts, each next once every call the
    /// turn holds is answered. `{turn}` in a line stands for the turn's id.
    struct Codex {
        signed_in: bool,
        turns: VecDeque<VecDeque<Vec<String>>>,
        current: VecDeque<Vec<String>>,
        started: u64,
        turn: String,
        held: Vec<Value>,
        dynamic_tools: Value,
    }

    impl Codex {
        fn new(turns: Vec<Vec<Vec<String>>>) -> Self {
            Codex {
                signed_in: true,
                turns: turns.into_iter().map(VecDeque::from).collect(),
                current: VecDeque::new(),
                started: 0,
                turn: String::new(),
                held: Vec::new(),
                dynamic_tools: Value::Null,
            }
        }

        fn segment(&mut self) -> Vec<String> {
            let lines: Vec<String> = self
                .current
                .pop_front()
                .unwrap_or_default()
                .into_iter()
                .map(|l| l.replace("{turn}", &self.turn))
                .collect();
            for line in &lines {
                let v: Value = serde_json::from_str(line).unwrap();
                if v["method"] == "item/tool/call" && v["params"]["turnId"] == self.turn.as_str() {
                    self.held.push(v["id"].clone());
                }
            }
            lines
        }

        fn respond(&mut self, line: &str) -> Vec<String> {
            let v: Value = serde_json::from_str(line).unwrap();
            let id = v["id"].clone();
            let ok = |result: Value| json!({"id": id, "result": result}).to_string();
            match v["method"].as_str() {
                Some("initialize") => vec![ok(json!({"userAgent": "cyfr/0.167.0", "codexHome": "/home/k/.codex", "platformFamily": "unix", "platformOs": "linux"}))],
                Some("initialized") => vec![],
                Some("account/read") => vec![ok(if self.signed_in {
                    json!({"account": {"type": "chatgpt", "email": "p@example.com", "planType": "plus"}, "requiresOpenaiAuth": true})
                } else {
                    json!({"account": null, "requiresOpenaiAuth": true})
                })],
                Some("model/list") => vec![ok(json!({"data": [
                    {"id": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol", "isDefault": true,
                     "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "high"}, {"reasoningEffort": "ultra"}]},
                    {"id": "gpt-5.5", "displayName": "GPT-5.5", "isDefault": false,
                     "supportedReasoningEfforts": [{"reasoningEffort": "medium"}, {"reasoningEffort": "high"}]}
                ], "nextCursor": null}))],
                Some("thread/start") => {
                    self.dynamic_tools = v["params"]["dynamicTools"].clone();
                    vec![
                        ok(json!({"thread": {"id": THREAD, "path": format!("/home/k/.codex/sessions/{CANARY}.jsonl")}, "model": "gpt-6.1-sol"})),
                        json!({"method": "thread/started", "params": {"thread": {"id": THREAD}}}).to_string(),
                    ]
                }
                Some("thread/resume") if v["params"]["threadId"] == THREAD => {
                    vec![ok(json!({"thread": {"id": THREAD}, "model": "gpt-6.1-sol"}))]
                }
                Some("thread/resume") => vec![json!({"id": id, "error": {"code": -32600, "message": "no rollout found"}}).to_string()],
                Some("turn/start") => {
                    self.started += 1;
                    self.turn = format!("t{}", self.started);
                    self.current = self.turns.pop_front().unwrap_or_default();
                    let mut out = vec![
                        ok(json!({"turn": {"id": self.turn, "status": "inProgress", "items": []}})),
                        json!({"method": "turn/started", "params": {"threadId": THREAD, "turn": {"id": self.turn}}}).to_string(),
                    ];
                    out.extend(self.segment());
                    out
                }
                Some(_) => vec![],
                // An answer to one of Codex's requests.
                None => {
                    let before = self.held.len();
                    self.held.retain(|h| *h != id);
                    if before > 0 && self.held.is_empty() {
                        self.segment()
                    } else {
                        vec![]
                    }
                }
            }
        }
    }

    /// The program's pipe as the box keeps it: lines numbered in one
    /// sequence, each held until a read names a higher `after`.
    struct BoxPipe {
        codex: Codex,
        running: bool,
        buffer: Vec<(u64, String)>,
        seq: u64,
        log: Vec<String>,
        sent: Vec<String>,
        open_error: Option<String>,
        recv_errors: VecDeque<Option<String>>,
    }

    impl BoxPipe {
        fn new(codex: Codex) -> Self {
            BoxPipe {
                codex,
                running: false,
                buffer: Vec::new(),
                seq: 0,
                log: Vec::new(),
                sent: Vec::new(),
                open_error: None,
                recv_errors: VecDeque::new(),
            }
        }

        /// Lines the program writes on its own, after a run answered.
        fn write(&mut self, lines: Vec<String>) {
            for line in lines {
                self.seq += 1;
                self.buffer.push((self.seq, line));
            }
        }

        /// The methods (or `answer <id>`) of the lines sent since `from`.
        fn sent_since(&self, from: usize) -> Vec<String> {
            self.sent[from..]
                .iter()
                .map(|l| {
                    let v: Value = serde_json::from_str(l).unwrap();
                    v["method"].as_str().map(str::to_string).unwrap_or_else(|| format!("answer {}", v["id"]))
                })
                .collect()
        }

        fn sent_with(&self, method: &str) -> Value {
            self.sent
                .iter()
                .rev()
                .map(|l| serde_json::from_str::<Value>(l).unwrap())
                .find(|v| v["method"] == method)
                .unwrap_or(Value::Null)
        }

        fn answers(&self) -> Vec<Value> {
            self.sent
                .iter()
                .map(|l| serde_json::from_str::<Value>(l).unwrap())
                .filter(|v| v.get("method").is_none())
                .collect()
        }
    }

    impl Pipe for BoxPipe {
        fn open(&mut self, need: &str, key: &str, argv: &[String]) -> Result<Opened, String> {
            self.log.push(format!("open {need} {key} {}", argv.join(" ")));
            if let Some(code) = self.open_error.clone() {
                return Err(code);
            }
            let resumed = self.running;
            self.running = true;
            Ok(Opened { session: "pipe-1".into(), resumed })
        }
        fn send(&mut self, _session: &str, lines: &[String]) -> Result<(), String> {
            for line in lines {
                self.sent.push(line.clone());
                let out = self.codex.respond(line);
                self.write(out);
            }
            Ok(())
        }
        fn recv(&mut self, _session: &str, after: u64, _wait: u32) -> Result<Received, String> {
            if let Some(code) = self.recv_errors.pop_front().flatten() {
                return Err(code);
            }
            self.buffer.retain(|(seq, _)| *seq > after);
            let first = self.buffer.first().map_or(self.seq + 1, |(seq, _)| *seq);
            Ok(Received {
                lines: self.buffer.clone(),
                dropped: (first - 1).saturating_sub(after) as u32,
                running: self.running,
            })
        }
        fn close(&mut self, session: &str) -> Result<(), String> {
            self.log.push(format!("close {session}"));
            self.running = false;
            self.buffer.clear();
            self.codex.held.clear();
            Ok(())
        }
    }

    fn line(v: Value) -> String {
        v.to_string()
    }
    fn delta(item: &str, text: &str) -> String {
        line(json!({"method": "item/agentMessage/delta", "params": {"threadId": THREAD, "turnId": "{turn}", "itemId": item, "delta": text}}))
    }
    fn message(item: &str, text: &str) -> String {
        line(json!({"method": "item/completed", "params": {"item": {"type": "agentMessage", "id": item, "text": text}, "threadId": THREAD, "turnId": "{turn}"}}))
    }
    fn call(request: u64, call: &str, tool: &str, arguments: Value) -> String {
        line(json!({"method": "item/tool/call", "id": request, "params": {"threadId": THREAD, "turnId": "{turn}", "callId": call, "namespace": null, "tool": tool, "arguments": arguments}}))
    }
    fn own(item: &str, kind: &str) -> String {
        line(json!({"method": "item/started", "params": {"item": {"type": kind, "id": item, "command": format!("/bin/bash -lc 'cat {CANARY}'"), "status": "inProgress"}, "threadId": THREAD, "turnId": "{turn}"}}))
    }
    fn ask(request: u64, method: &str) -> String {
        line(json!({"method": method, "id": request, "params": {"threadId": THREAD, "turnId": "{turn}", "itemId": "c9", "command": CANARY}}))
    }
    /// A usage snapshot whose thread total is `input`, `cached` and `output`.
    fn usage(input: u64, cached: u64, output: u64) -> String {
        let counts = json!({"totalTokens": input + output, "inputTokens": input, "cachedInputTokens": cached, "cacheWriteInputTokens": 0, "outputTokens": output, "reasoningOutputTokens": 0});
        line(json!({"method": "thread/tokenUsage/updated", "params": {"threadId": THREAD, "turnId": "{turn}", "tokenUsage": {
            "total": counts, "last": {"totalTokens": 1, "inputTokens": 1}}}}))
    }
    fn done() -> String {
        line(json!({"method": "turn/completed", "params": {"threadId": THREAD, "turn": {"id": "{turn}", "status": "completed", "error": null}}}))
    }
    fn failed(info: Value) -> String {
        line(json!({"method": "turn/completed", "params": {"threadId": THREAD, "turn": {"id": "{turn}", "status": "failed",
            "error": {"message": format!("unexpected status, see {CANARY}"), "codexErrorInfo": info}}}}))
    }

    fn files() -> Value {
        json!({"name": "files", "description": "Read files", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}}})
    }

    fn request(params: Value) -> Request {
        parse_request(&params).unwrap()
    }

    fn first(text: &str) -> Request {
        request(json!({"model": "default", "system": "You are a crew member.", "tools": [files()],
                       "messages": [{"role": "user", "content": text}]}))
    }

    fn far() -> Instant {
        Instant::now() + Duration::from_secs(60)
    }

    /// One chat on `pipe`, with `KEY` as its fresh id: its answer and events.
    fn run(pipe: &mut BoxPipe, request: &Request, deadline: Instant) -> (Result<Value, Refusal>, Vec<Value>) {
        let mut deltas = Deltas::new(Vec::new());
        let answer = chat(pipe, &mut deltas, request, KEY.into(), deadline);
        (answer, deltas.into_sink())
    }

    fn text_of(events: &[Value]) -> String {
        events.iter().filter(|e| e["type"] == "text.delta").map(|e| e["text"].as_str().unwrap()).collect()
    }

    fn session() -> String {
        format!("{KEY}.{THREAD}")
    }

    /// The request that answers `answered`'s calls with `results`, by call id.
    fn answering(answered: &Value, results: &[(&str, &str, bool)]) -> Request {
        request(json!({"model": "default", "session": answered["session"], "messages": [
            {"role": "user", "content": "go"},
            {"role": "assistant", "content": answered["content"]},
            {"role": "tool", "content": results.iter().map(|(id, content, is_error)| json!(
                {"type": "tool_result", "tool_call_id": id, "content": content, "is_error": is_error})).collect::<Vec<_>>()}
        ]}))
    }

    fn calls_of(answer: &Value) -> Vec<Value> {
        answer["content"].as_array().unwrap().iter().filter(|b| b["type"] == "tool_call").cloned().collect()
    }

    #[test]
    fn a_first_message_starts_a_thread_with_cyfr_s_tools_and_streams_its_reply() {
        let mut pipe = BoxPipe::new(Codex::new(vec![vec![vec![
            delta("m0", "Hel"), delta("m0", "lo."), message("m0", "Hello."), usage(11, 3, 7), done(),
        ]]]));
        let (answer, events) = run(&mut pipe, &first("hi"), far());
        let answer = answer.unwrap();
        assert_eq!(pipe.log, [format!("open codex {KEY} app-server")]);
        assert_eq!(pipe.sent_since(0), ["initialize", "initialized", "account/read", "thread/start", "turn/start"]);
        let start = pipe.sent_with("thread/start");
        assert_eq!(start["params"]["dynamicTools"], json!([
            {"type": "function", "name": "files", "description": "Read files", "inputSchema": files()["parameters"]}
        ]));
        assert_eq!(start["params"]["developerInstructions"], "You are a crew member.");
        assert_eq!((start["params"]["approvalPolicy"].as_str(), start["params"]["sandbox"].as_str()), (Some("never"), Some("danger-full-access")));
        let turn = pipe.sent_with("turn/start");
        assert_eq!(turn["params"], json!({"threadId": THREAD, "input": [{"type": "text", "text": "hi", "textElements": []}]}),
                   "the default model and effort are Codex's own: none is sent");
        assert_eq!(answer, json!({
            "model": "gpt-6.1-sol",
            "content": [{"type": "text", "text": "Hello."}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 11, "output_tokens": 7, "cache_read_tokens": 3, "cache_write_tokens": 0},
            "session": format!("{session}.11-7-3-0", session = session())
        }));
        assert_eq!(text_of(&events), "Hello.");
        assert_eq!(events.last().unwrap(), &json!({"type": "stop", "stop_reason": "end_turn"}));
        assert!(pipe.running && pipe.buffer.is_empty(), "the program runs on, and every line the run read is released");
    }

    #[test]
    fn a_call_of_cyfr_s_tool_is_held_and_the_next_chat_answers_it() {
        let mut pipe = BoxPipe::new(Codex::new(vec![vec![
            vec![delta("m0", "Reading."), message("m0", "Reading."), call(0, "c1", "files", json!({"path": "a.txt"}))],
            vec![message("m1", "The file says hi."), done()],
        ]]));
        let (asked, events) = run(&mut pipe, &first("read a.txt"), far());
        let asked = asked.unwrap();
        assert_eq!(asked["stop_reason"], "tool_call");
        assert_eq!(calls_of(&asked), [json!({"type": "tool_call", "id": "c1", "name": "files", "arguments": {"path": "a.txt"},
                                             "provider_data": {"request_id": 0, "turn_id": "t1"}})]);
        assert_eq!(asked["content"][0], json!({"type": "text", "text": "Reading."}));
        let shown: Vec<&Value> = events.iter().filter(|e| e["type"].as_str().unwrap().starts_with("tool_call.")).collect();
        assert_eq!(shown, [
            &json!({"type": "tool_call.start", "index": 0, "id": "c1", "name": "files"}),
            &json!({"type": "tool_call.delta", "index": 0, "arguments": "{\"path\":\"a.txt\"}"}),
            &json!({"type": "tool_call.end", "index": 0}),
        ]);
        assert_eq!(pipe.codex.held, [json!(0)], "Codex holds the call while CYFR runs it");
        assert!(!pipe.log.iter().any(|l| l.starts_with("close")));

        let from = pipe.sent.len();
        let (answer, events) = run(&mut pipe, &answering(&asked, &[("c1", "hi", false)]), far());
        let answer = answer.unwrap();
        assert_eq!(pipe.sent_since(from), ["answer 0"], "the next chat answers the held call and nothing else");
        assert_eq!(pipe.answers().last().unwrap(), &json!({"id": 0, "result": {"contentItems": [{"type": "inputText", "text": "hi"}], "success": true}}));
        assert_eq!(answer["content"], json!([{"type": "text", "text": "The file says hi."}]));
        assert_eq!(answer["stop_reason"], "end_turn");
        assert_eq!(answer["session"], format!("{}.0-0-0-0", session()), "a new thread has used nothing the run read");
        assert_eq!(text_of(&events), "The file says hi.");
    }

    #[test]
    fn calls_codex_makes_in_parallel_are_answered_together_and_a_late_one_waits_for_the_next_run() {
        let mut pipe = BoxPipe::new(Codex::new(vec![vec![
            vec![call(0, "c1", "files", json!({"path": "a"})), call(1, "c2", "files", json!({"path": "b"}))],
            vec![message("m1", "Both read."), done()],
        ]]));
        let (asked, _) = run(&mut pipe, &first("read a and b"), far());
        let asked = asked.unwrap();
        let ids: Vec<Value> = calls_of(&asked).iter().map(|c| c["id"].clone()).collect();
        assert_eq!(ids, [json!("c1"), json!("c2")]);
        // A third call Codex makes after the run answered stays in the
        // session's buffer for the next run.
        pipe.codex.held.push(json!(2));
        pipe.write(vec![call(2, "c3", "files", json!({"path": "c"})).replace("{turn}", "t1")]);
        let from = pipe.sent.len();
        let (later, events) = run(&mut pipe, &answering(&asked, &[("c1", "A", false), ("c2", "denied", true)]), far());
        let later = later.unwrap();
        assert_eq!(pipe.sent_since(from), ["answer 0", "answer 1"]);
        assert_eq!(pipe.answers()[1]["result"]["success"], false, "a refused call is answered unsuccessful");
        assert_eq!(calls_of(&later), [json!({"type": "tool_call", "id": "c3", "name": "files", "arguments": {"path": "c"},
                                             "provider_data": {"request_id": 2, "turn_id": "t1"}})],
                   "the late call is the next run's tool_call, not let go");
        assert_eq!(events.iter().filter(|e| e["type"] == "tool_call.start").count(), 1);
        let (answer, _) = run(&mut pipe, &answering(&later, &[("c3", "C", false)]), far());
        assert_eq!(answer.unwrap()["content"], json!([{"type": "text", "text": "Both read."}]));
    }

    #[test]
    fn codex_s_own_tools_are_allowed_in_the_box_and_shown_by_name_only() {
        let mut pipe = BoxPipe::new(Codex::new(vec![vec![vec![
            own("c3", "commandExecution"),
            ask(5, "item/commandExecution/requestApproval"),
            ask(6, "item/fileChange/requestApproval"),
            ask(7, "item/tool/requestUserInput"),
            own("c4", "fileChange"),
            message("m0", "Ran it."),
            done(),
        ]]]));
        let (answer, events) = run(&mut pipe, &first("run it"), far());
        let answer = answer.unwrap();
        let answers = pipe.answers();
        assert_eq!(answers[0], json!({"id": 5, "result": {"decision": "accept"}}));
        assert_eq!(answers[1], json!({"id": 6, "result": {"decision": "accept"}}));
        assert_eq!(answers[2]["error"]["message"], "CYFR does not answer item/tool/requestUserInput");
        let shown: Vec<&Value> = events.iter().filter(|e| e["type"].as_str().unwrap().starts_with("tool_call.")).collect();
        assert_eq!(shown, [
            &json!({"type": "tool_call.start", "index": 0, "id": "c3", "name": "commandExecution"}),
            &json!({"type": "tool_call.end", "index": 0}),
            &json!({"type": "tool_call.start", "index": 1, "id": "c4", "name": "fileChange"}),
            &json!({"type": "tool_call.end", "index": 1}),
        ]);
        assert_eq!(answer["content"], json!([{"type": "text", "text": "Ran it."}]), "own tools never reach the answer");
        let seen = format!("{answer}{}", json!(events));
        assert!(!seen.contains(CANARY), "nothing of what Codex ran reaches the answer or the stream: {seen}");
    }

    #[test]
    fn a_session_resumes_its_thread_by_id_from_the_kept_home() {
        let mut pipe = BoxPipe::new(Codex::new(vec![vec![vec![message("m0", "Back."), done()]]]));
        let resumed = request(json!({"model": "gpt-5.5", "session": session(), "tools": [], "system": "Prompt.",
                                     "options": {"effort": "high"}, "messages": [{"role": "user", "content": "again"}]}));
        let (answer, _) = run(&mut pipe, &resumed, far());
        let answer = answer.unwrap();
        assert_eq!(pipe.log, [format!("open codex {KEY} app-server")], "the session's own key");
        assert_eq!(pipe.sent_since(0), ["initialize", "initialized", "account/read", "thread/resume", "turn/start"]);
        let resume = pipe.sent_with("thread/resume");
        assert_eq!(resume["params"]["threadId"], THREAD);
        assert_eq!(resume["params"]["developerInstructions"], "Prompt.");
        assert!(resume["params"].get("dynamicTools").is_none(), "the thread keeps the tools it started with");
        let turn = pipe.sent_with("turn/start");
        assert_eq!((turn["params"]["model"].as_str(), turn["params"]["effort"].as_str()), (Some("gpt-5.5"), Some("high")));
        assert_eq!(answer["session"], session());
        assert_eq!(answer["model"], "gpt-5.5");
    }

    #[test]
    fn the_budget_interrupts_the_session_and_the_next_message_resumes_it() {
        let mut pipe = BoxPipe::new(Codex::new(vec![
            vec![vec![delta("m0", "Working")]],
            vec![vec![message("m0", "Resumed."), done()]],
        ]));
        let (refusal, _) = run(&mut pipe, &first("long job"), Instant::now() + Duration::from_millis(300));
        let refusal = refusal.unwrap_err();
        assert_eq!(refusal.kind, "provider_error");
        assert!(refusal.message.contains("interrupted") && refusal.message.contains("next message"), "{}", refusal.message);
        assert_eq!(pipe.log.iter().filter(|l| l.starts_with("close")).count(), 1, "{:?}", pipe.log);

        let from = pipe.sent.len();
        let next = request(json!({"model": "default", "session": session(), "messages": [{"role": "user", "content": "go on"}]}));
        let (answer, _) = run(&mut pipe, &next, far());
        assert_eq!(pipe.sent_since(from), ["initialize", "initialized", "account/read", "thread/resume", "turn/start"]);
        assert_eq!(answer.unwrap()["content"], json!([{"type": "text", "text": "Resumed."}]));
    }

    #[test]
    fn a_thread_codex_refuses_to_resume_closes_the_program_so_the_next_message_starts_it_again() {
        let mut pipe = BoxPipe::new(Codex::new(vec![]));
        let gone = request(json!({"model": "default", "session": format!("{KEY}.{KEY}"), "messages": [{"role": "user", "content": "hi"}]}));
        let (refusal, _) = run(&mut pipe, &gone, far());
        assert_eq!(refusal.unwrap_err().kind, "provider_error");
        assert_eq!(pipe.log.last().unwrap(), "close pipe-1");
        assert!(!pipe.running);
    }

    #[test]
    fn a_codex_not_signed_in_is_refused_before_anything_reaches_a_thread() {
        let mut codex = Codex::new(vec![vec![vec![message("m0", "x"), done()]]]);
        codex.signed_in = false;
        let mut pipe = BoxPipe::new(codex);
        let (refusal, events) = run(&mut pipe, &first("hi"), far());
        let refusal = refusal.unwrap_err();
        assert_eq!((refusal.status, refusal.kind), (401, "authentication"));
        assert!(refusal.message.contains("Programs page"), "{}", refusal.message);
        assert_eq!(pipe.sent_since(0), ["initialize", "initialized", "account/read"]);
        assert_eq!(pipe.log.last().unwrap(), "close pipe-1", "the program is not left running");
        assert!(events.is_empty());
    }

    #[test]
    fn a_call_outside_the_tools_a_request_offers_reaches_cyfr_and_codex_is_given_cyfr_s_denial() {
        let web = json!({"name": "web", "description": "Search the web", "parameters": {"type": "object"}});
        let mut pipe = BoxPipe::new(Codex::new(vec![
            vec![vec![message("m0", "Ready."), done()]],
            vec![vec![call(3, "c9", "web", json!({"q": "news"}))], vec![message("m1", "Not allowed, then."), done()]],
        ]));
        let started = request(json!({"model": "default", "tools": [files(), web], "messages": [{"role": "user", "content": "hi"}]}));
        let (answer, _) = run(&mut pipe, &started, far());
        assert_eq!(answer.unwrap()["session"], format!("{}.0-0-0-0", session()));
        assert_eq!(pipe.codex.dynamic_tools.as_array().unwrap().len(), 2, "the thread starts with both tools");

        // A request narrowed to `files` goes on in the same thread: its
        // list is not compared, and Codex may still name `web`.
        let from = pipe.sent.len();
        let narrowed = request(json!({"model": "default", "session": session(), "tools": [files()],
                                      "messages": [{"role": "user", "content": "search the news"}]}));
        let (asked, _) = run(&mut pipe, &narrowed, far());
        let asked = asked.unwrap();
        assert_eq!(pipe.sent_since(from), ["turn/start"]);
        assert_eq!(calls_of(&asked)[0]["name"], "web", "the call is CYFR's to refuse, by its gate");
        let denial = "The call web is outside the tools this job may use.";
        let (answer, _) = run(&mut pipe, &answering(&asked, &[("c9", denial, true)]), far());
        assert_eq!(pipe.answers().last().unwrap(), &json!({"id": 3, "result": {"contentItems": [{"type": "inputText", "text": denial}], "success": false}}));
        assert_eq!(answer.unwrap()["content"], json!([{"type": "text", "text": "Not allowed, then."}]));
    }

    #[test]
    fn a_held_call_whose_program_ended_comes_back_as_a_message() {
        let mut pipe = BoxPipe::new(Codex::new(vec![
            vec![vec![call(0, "c1", "files", json!({"path": "a"}))]],
            vec![vec![message("m0", "Got it."), done()]],
        ]));
        let (asked, _) = run(&mut pipe, &first("read a"), far());
        let asked = asked.unwrap();
        pipe.close("pipe-1").unwrap();
        let from = pipe.sent.len();
        let (answer, _) = run(&mut pipe, &answering(&asked, &[("c1", "line one", false)]), far());
        assert_eq!(pipe.sent_since(from), ["initialize", "initialized", "account/read", "thread/resume", "turn/start"]);
        let text = pipe.sent_with("turn/start")["params"]["input"][0]["text"].as_str().unwrap().to_string();
        assert!(text.contains("files: CYFR ran it and answered:\nline one"), "{text}");
        assert!(pipe.answers().iter().all(|a| a["id"] != 0), "no answer goes to a call the program no longer holds");
        assert_eq!(answer.unwrap()["content"], json!([{"type": "text", "text": "Got it."}]));
    }

    #[test]
    fn a_new_message_while_calls_are_held_starts_the_program_again() {
        let mut pipe = BoxPipe::new(Codex::new(vec![
            vec![vec![call(0, "c1", "files", json!({"path": "a"}))]],
            vec![vec![message("m0", "New topic."), done()]],
        ]));
        let (asked, _) = run(&mut pipe, &first("read a"), far());
        let asked = asked.unwrap();
        let moved_on = request(json!({"model": "default", "session": asked["session"], "messages": [
            {"role": "user", "content": "read a"},
            {"role": "assistant", "content": asked["content"]},
            {"role": "tool", "content": [{"type": "tool_result", "tool_call_id": "c1", "content": "The call's outcome is unknown", "is_error": true}]},
            {"role": "user", "content": "something else"}
        ]}));
        let from = pipe.sent.len();
        let (answer, _) = run(&mut pipe, &moved_on, far());
        assert_eq!(&pipe.log[1..], ["open codex 0b5c7c1e-2f3a-4d6e-8a9b-1c2d3e4f5a6b app-server", "close pipe-1",
                                    "open codex 0b5c7c1e-2f3a-4d6e-8a9b-1c2d3e4f5a6b app-server"]);
        assert_eq!(pipe.sent_since(from), ["initialize", "initialized", "account/read", "thread/resume", "turn/start"]);
        assert_eq!(answer.unwrap()["content"], json!([{"type": "text", "text": "New topic."}]));
    }

    #[test]
    fn a_failed_turn_answers_its_contract_type_and_none_of_codex_s_words() {
        for (info, status, kind, words) in [
            (json!({"httpConnectionFailed": {"httpStatusCode": 401}}), 401, "authentication", "sign in again"),
            (json!("usageLimitExceeded"), 502, "provider_error", "usage or rate limit"),
            (json!("modelNotFound"), 404, "unknown_model", "model"),
        ] {
            let mut pipe = BoxPipe::new(Codex::new(vec![vec![vec![delta("m0", "Partial"), failed(info)]]]));
            let (refusal, _) = run(&mut pipe, &first("hi"), far());
            let refusal = refusal.unwrap_err();
            assert_eq!((refusal.status, refusal.kind), (status, kind));
            assert!(refusal.message.contains(words) && !refusal.message.contains(CANARY), "{}", refusal.message);
            assert!(!pipe.log.iter().any(|l| l.starts_with("close")), "the turn ended on Codex's side; nothing is closed");
        }
    }

    #[test]
    fn a_call_of_another_turn_is_told_cyfr_did_not_run_it() {
        let stale = call(4, "c0", "files", json!({})).replace("{turn}", "t0");
        let mut pipe = BoxPipe::new(Codex::new(vec![vec![vec![stale, message("m0", "Done."), done(), ask(8, "currentTime/read")]]]));
        let (answer, _) = run(&mut pipe, &first("hi"), far());
        assert_eq!(answer.unwrap()["stop_reason"], "end_turn");
        let told = pipe.answers().into_iter().find(|a| a["id"] == 4).unwrap();
        assert_eq!(told["result"]["success"], false);
        let clock = pipe.answers().into_iter().find(|a| a["id"] == 8).expect("a request after the turn's end is still answered");
        assert!(clock["result"]["currentTimeAt"].as_i64().unwrap() > 1_700_000_000);
    }

    #[test]
    fn agent_messages_are_set_apart_in_the_stream_and_the_answer() {
        let mut pipe = BoxPipe::new(Codex::new(vec![vec![vec![
            delta("m0", "One."), message("m0", "One."), message("m1", "Two."), done(),
        ]]]));
        let (answer, events) = run(&mut pipe, &first("hi"), far());
        assert_eq!(answer.unwrap()["content"][0]["text"], "One.\n\nTwo.");
        assert_eq!(text_of(&events), "One.\n\nTwo.");
    }

    #[test]
    fn a_read_lost_after_the_answer_interrupts_the_session_and_answers_once() {
        let mut pipe = BoxPipe::new(Codex::new(vec![
            vec![vec![call(0, "c1", "files", json!({}))], vec![message("m0", "x"), done()]],
            vec![vec![message("m0", "Resumed."), done()]],
        ]));
        let (asked, _) = run(&mut pipe, &first("read"), far());
        let asked = asked.unwrap();
        pipe.recv_errors = VecDeque::from([Some("unavailable".into())]);
        let (refusal, _) = run(&mut pipe, &answering(&asked, &[("c1", "A", false)]), far());
        let refusal = refusal.unwrap_err();
        assert!(refusal.message.contains("interrupted"), "{}", refusal.message);
        assert_eq!(pipe.answers().iter().filter(|a| a["id"] == 0).count(), 1);
        let next = request(json!({"model": "default", "session": session(), "messages": [{"role": "user", "content": "go on"}]}));
        let (answer, _) = run(&mut pipe, &next, far());
        assert_eq!(answer.unwrap()["content"][0]["text"], "Resumed.");
        assert_eq!(pipe.answers().iter().filter(|a| a["id"] == 0).count(), 1, "never answered again");
    }

    #[test]
    fn every_pipe_code_maps_to_a_contract_type() {
        for (code, kind) in [
            ("denied", "secret_denied"),
            ("setup_required", "secret_denied"),
            ("busy", "overloaded"),
            ("unavailable", "overloaded"),
            ("ended", "incomplete_stream"),
            ("invalid_request", "invalid_request"),
            ("too_large", "invalid_request"),
            ("lost", "provider_error"),
        ] {
            let mut pipe = BoxPipe::new(Codex::new(vec![]));
            pipe.open_error = Some(code.into());
            let (refusal, _) = run(&mut pipe, &first("hi"), far());
            assert_eq!(refusal.unwrap_err().kind, kind, "{code}");
        }
    }

    #[test]
    fn describe_and_models_read_codex_s_listing_in_a_session_of_their_own() {
        let mut pipe = BoxPipe::new(Codex::new(vec![]));
        let listed = listing(&mut pipe, "listing-1", far()).unwrap();
        assert_eq!(pipe.sent_since(0), ["initialize", "initialized", "model/list"]);
        assert_eq!(pipe.log, ["open codex listing-1 app-server", "close pipe-1"]);
        let described = describe(Some("gpt-5.5"), Some(&listed));
        assert_eq!(described["options"], json!([
            {"name": "model", "kind": "enum", "values": ["default", "gpt-6.1-sol", "gpt-5.5"]},
            {"name": "effort", "kind": "enum", "values": ["low", "high", "ultra", "medium"]}
        ]));
        assert_eq!(described["context_window"], 272_000);
        assert_eq!(models(&listed), json!({"models": [
            {"id": "default", "name": "Default (GPT-6.1-Sol)"},
            {"id": "gpt-6.1-sol", "name": "GPT-6.1-Sol"},
            {"id": "gpt-5.5", "name": "GPT-5.5"}
        ]}));

        let mut denied = BoxPipe::new(Codex::new(vec![]));
        denied.open_error = Some("denied".into());
        let answer: Value = serde_json::from_str(&describe_answer(&mut denied, "k", None, far())).unwrap();
        assert_eq!((answer["status"].clone(), answer["data"]["options"].clone()), (json!(200), json!([])));
        let mut lost = BoxPipe::new(Codex::new(vec![]));
        lost.open_error = Some("lost".into());
        let answer: Value = serde_json::from_str(&describe_answer(&mut lost, "k", None, far())).unwrap();
        assert_eq!(answer["error"]["type"], "provider_error");
    }

    #[test]
    fn describe_takes_each_model_s_window_from_the_pinned_catalog() {
        let listed = vec![
            json!({"id": "gpt-6.1-terra", "displayName": "GPT-6.1-Terra", "isDefault": true}),
            json!({"id": "gpt-5.5", "displayName": "GPT-5.5", "isDefault": false}),
        ];
        let window = |model: &str| describe(Some(model), Some(&listed))["context_window"].clone();
        assert_eq!(window("gpt-6.1-terra"), 500_000);
        assert_eq!(window("gpt-daybreak-red-latest"), 372_000);
        assert_eq!(window("gpt-5.5"), 272_000);
        assert_eq!(window("default"), 500_000, "the default is the model the listing marks it");
        assert_eq!(window("gpt-9-unlisted"), FALLBACK_CONTEXT_WINDOW, "a model the catalog does not hold");
        assert_eq!(describe(Some("default"), None)["context_window"], FALLBACK_CONTEXT_WINDOW);
    }

    #[test]
    fn a_usage_snapshot_codex_sends_again_counts_once() {
        let mut pipe = BoxPipe::new(Codex::new(vec![vec![vec![
            message("m0", "Done."), usage(11, 3, 7), usage(11, 3, 7), done(),
        ]]]));
        let (answer, _) = run(&mut pipe, &first("hi"), far());
        let answer = answer.unwrap();
        assert_eq!(answer["usage"], json!({"input_tokens": 11, "output_tokens": 7, "cache_read_tokens": 3, "cache_write_tokens": 0}));
        assert_eq!(answer["session"], format!("{KEY}.{THREAD}.11-7-3-0"), "the session carries the thread's total");
    }

    #[test]
    fn a_run_counts_from_the_total_the_last_answer_carried() {
        let mut pipe = BoxPipe::new(Codex::new(vec![vec![
            vec![usage(11, 3, 7), call(0, "c1", "files", json!({}))],
            // The next model call: its rate limits send the last total again
            // first, then the call's own.
            vec![usage(11, 3, 7), usage(20, 3, 9), message("m0", "Read."), done()],
        ]]));
        let (asked, _) = run(&mut pipe, &first("read"), far());
        let asked = asked.unwrap();
        assert_eq!(asked["usage"]["input_tokens"], 11);
        let (answer, _) = run(&mut pipe, &answering(&asked, &[("c1", "A", false)]), far());
        let answer = answer.unwrap();
        assert_eq!(answer["usage"], json!({"input_tokens": 9, "output_tokens": 2, "cache_read_tokens": 0, "cache_write_tokens": 0}));
        assert_eq!(answer["session"], format!("{KEY}.{THREAD}.20-9-3-0"));
    }

    #[test]
    fn a_tool_list_codex_cannot_be_given_whole_is_refused_before_anything_opens() {
        let named = |name: &str| json!({"name": name, "parameters": {"type": "object"}});
        for tools in [
            json!([named("files.read")]),
            json!([named("mcp__cyfr__files")]),
            json!([named("files"), named("files")]),
            json!([{"name": "big", "description": "x".repeat(MAX_LINE_BYTES), "parameters": {"type": "object"}}]),
        ] {
            let mut pipe = BoxPipe::new(Codex::new(vec![]));
            let req = request(json!({"model": "default", "tools": tools, "messages": [{"role": "user", "content": "hi"}]}));
            let (refusal, _) = run(&mut pipe, &req, far());
            assert_eq!(refusal.unwrap_err().kind, "invalid_request");
            assert!(pipe.log.is_empty(), "nothing opened: {:?}", pipe.log);
        }
    }

    #[test]
    fn a_result_past_the_bound_is_cut_with_a_note_within_it() {
        let long = "a\"".repeat(MAX_RESULT_BYTES);
        let cut = bounded(&long);
        let line = server::tool_answer(&json!(1), &cut, true);
        assert!(line.len() < MAX_LINE_BYTES, "{}", line.len());
        assert!(cut.contains("CYFR cut this result"));
        assert_eq!(bounded("short"), "short");
    }

    #[test]
    fn requests_off_the_contract_are_refused() {
        let base = json!({"model": "default", "messages": [{"role": "user", "content": "hi"}]});
        let with = |key: &str, value: Value| {
            let mut v = base.clone();
            v[key] = value;
            v
        };
        assert!(parse_request(&base).is_ok());
        assert!(parse_request(&with("session", json!("not-a-session"))).is_err());
        assert!(parse_request(&with("session", json!(KEY))).is_err(), "a session names its thread");
        assert!(parse_request(&with("session", json!(session()))).is_ok());
        let carried = parse_request(&with("session", json!(format!("{}.11-7-3-0", session())))).unwrap();
        assert_eq!(carried.session.unwrap().total, Some([11, 7, 3, 0]));
        for broken in [".11-7", ".a-b-c-d", ".1-2-3-4.5"] {
            assert!(parse_request(&with("session", json!(format!("{}{broken}", session())))).is_err(), "{broken}");
        }
        assert!(parse_request(&with("provider_tools", json!(["web_search"]))).is_err());
        assert!(parse_request(&with("options", json!({"temperature": 1}))).is_err());
        assert!(parse_request(&with("options", json!({"model": "gpt-5.5", "effort": "high"}))).is_ok());
        assert!(parse_request(&with("model", json!("bad model"))).is_err());
        assert!(parse_request(&with("messages", json!([{"role": "assistant", "content": "x"}]))).is_err());
        assert!(parse_request(&with("messages", json!([{"role": "user", "content": [
            {"type": "document", "media_type": "application/pdf", "data": "x"}]}]))).is_err());
        let image = parse_request(&with("messages", json!([{"role": "user", "content": [
            {"type": "image", "media_type": "image/png", "data": "QUJD"}]}]))).unwrap();
        assert_eq!(image.input, Input::Message { items: vec![json!({"type": "image", "url": "data:image/png;base64,QUJD"})], held: false });
    }

    #[test]
    fn fresh_ids_are_session_ids() {
        assert!(session_id(&uuid([u64::MAX, u64::MAX])));
        assert!(session_id(&uuid([0, 0])));
        assert!(session_id(THREAD), "Codex's thread ids are lowercase UUIDs");
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
        let listing = vec![json!({"id": "gpt-5.5", "supportedReasoningEfforts": [{"reasoningEffort": "low"}]}), json!({"id": "gpt-6"})];
        assert!(declared(&describe(Some("gpt-5.5"), Some(&listing))).is_ok());
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

    #[test]
    fn this_brain_s_responses_name_a_session_as_the_vectors_read_one() {
        let v = vectors();
        for case in v["valid_chat_responses"].as_array().unwrap() {
            let session = case["response"].get("session");
            assert_eq!(session.cloned().unwrap_or(Value::Null), case["session"], "{}", case["why"]);
        }
        for case in v["invalid_chat_responses"].as_array().unwrap() {
            let session = &case["response"]["session"];
            assert!(!session.as_str().is_some_and(|s| !s.is_empty()), "{}", case["why"]);
            assert_eq!(case["member"], "session");
        }
        assert!(session_id(&uuid([7, 9])));
    }
}
