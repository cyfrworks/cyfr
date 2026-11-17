//! The further messages of a running `chat` (`cyfr:model/inputs`): the
//! same file in every harness catalyst, its rule pinned by
//! `tests/fixtures/model_chat.json`'s inputs (`Prima.Model.check_input/1`).
//!
//! While a turn's reader waits on the harness, it asks between its
//! bounded receives for the call's next input, a message that arrived
//! after the call began, writes it into the harness's running session and
//! reports it sent once the harness accepted it. The host answers the same
//! input until it is reported, so the asking side (`Feed`) asks again only
//! once the input it was last handed is settled, never while its write
//! awaits the harness's answer or its report, and asks at most once every
//! `ASK_EVERY`. It stops asking for the rest of the call once anything of
//! the channel fails: an error from either call, an input it was handed
//! after it wrote it, an input that does not read, or one its harness
//! cannot take. Such an input is not written and not reported, so the
//! host carries it into the next call as an ordinary message. An input
//! whose write may have reached the harness is never written again.
//!
//! Nothing an input carries is logged, kept past its write or shown in a
//! refusal: `Input` has no `Debug`, and a refusal names a member.

use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

/// The most bytes an input's JSON may be: one line to the program
/// (`Prima.Model.max_input_bytes/0`).
pub const MAX_INPUT_BYTES: usize = 1_048_576;

/// The most blocks an input's content carries (`Prima.Model.max_input_blocks/0`).
pub const MAX_INPUT_BLOCKS: usize = 32;

/// The media types an input's attachment may be, by block kind
/// (`Prima.Model.input_media_types/0`).
pub const MEDIA_TYPES: &[(&str, &[&str])] = &[
    ("image", &["image/jpeg", "image/png", "image/gif", "image/webp"]),
    ("document", &["application/pdf"]),
];

/// How often a turn asks for its next input, at most.
pub const ASK_EVERY: Duration = Duration::from_secs(1);

/// One further message: the id its supplier knows it by, and its content,
/// a user message's (a string, or `text` and attachment blocks).
#[derive(Clone, PartialEq)]
pub struct Input {
    pub id: String,
    pub content: Value,
}

/// Where a running chat asks for its further messages: the host's import,
/// or a script in a test. An error is the import's code.
pub trait Inputs {
    /// The next input not yet reported sent, as its id and its content's
    /// JSON, or none.
    fn next(&mut self) -> Result<Option<(String, String)>, String>;
    /// Report that the input `id` was handed on.
    fn sent(&mut self, id: &str) -> Result<(), String>;
}

/// A channel that hands nothing.
#[cfg(test)]
pub struct NoInputs;

#[cfg(test)]
impl Inputs for NoInputs {
    fn next(&mut self) -> Result<Option<(String, String)>, String> {
        Ok(None)
    }
    fn sent(&mut self, _id: &str) -> Result<(), String> {
        Ok(())
    }
}

/// Whether `input` holds to the input rule, or the member that breaks it
/// (`Prima.Model.check_input/1`): `id`, `content`, `content[i]`,
/// `content[i].<member>`, an unknown member by its own name, `input` for
/// one that is not an object, and `content` for one past
/// `MAX_INPUT_BYTES`.
pub fn check(input: &Value) -> Result<(), String> {
    let Some(map) = input.as_object() else {
        return Err("input".into());
    };
    let mut unknown: Vec<&String> = map.keys().filter(|k| *k != "id" && *k != "content").collect();
    unknown.sort();
    if let Some(name) = unknown.first() {
        return Err((*name).clone());
    }
    if !map.get("id").and_then(Value::as_str).is_some_and(id) {
        return Err("id".into());
    }
    let decoded = content(map.get("content"))?;
    if serde_json::to_string(input).map_or(usize::MAX, |json| json.len()) > MAX_INPUT_BYTES || decoded > MAX_INPUT_BYTES {
        return Err("content".into());
    }
    Ok(())
}

/// The input the host handed, its content read from its JSON and the
/// whole held to `check`.
pub fn read(id: String, content: &str) -> Result<Input, String> {
    let content: Value = serde_json::from_str(content).map_err(|_| "content".to_string())?;
    check(&json!({"id": id, "content": content}))?;
    Ok(Input { id, content })
}

/// The block kinds an input carries, in the order they first appear.
#[cfg(test)]
pub fn kinds(content: &Value) -> Vec<&str> {
    match content {
        Value::String(_) => vec!["text"],
        Value::Array(blocks) => {
            let mut kinds: Vec<&str> = Vec::new();
            for kind in blocks.iter().filter_map(|b| b.get("type").and_then(Value::as_str)) {
                if !kinds.contains(&kind) {
                    kinds.push(kind);
                }
            }
            kinds
        }
        _ => Vec::new(),
    }
}

/// 1 to 128 characters of `[A-Za-z0-9_.:-]`.
fn id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
}

/// The content's attachments' decoded bytes, or the member that breaks it.
fn content(content: Option<&Value>) -> Result<usize, String> {
    match content {
        Some(Value::String(text)) if !text.is_empty() => Ok(0),
        Some(Value::Array(blocks)) if !blocks.is_empty() && blocks.len() <= MAX_INPUT_BLOCKS => {
            let mut decoded = 0;
            for (index, b) in blocks.iter().enumerate() {
                decoded += block(b, &format!("content[{index}]"))?;
            }
            Ok(decoded)
        }
        _ => Err("content".into()),
    }
}

fn block(block: &Value, at: &str) -> Result<usize, String> {
    let Some(map) = block.as_object() else {
        return Err(at.to_string());
    };
    let Some(kind) = map.get("type") else {
        return Err(at.to_string());
    };
    let kind = kind.as_str();
    if kind == Some("text") {
        members(map, at, &["text"])?;
        return match map.get("text").and_then(Value::as_str) {
            Some(text) if !text.is_empty() => Ok(0),
            _ => Err(format!("{at}.text")),
        };
    }
    let Some((_, media_types)) = MEDIA_TYPES.iter().find(|(name, _)| kind == Some(*name)) else {
        return Err(format!("{at}.type"));
    };
    // The checks in the order of their members' names: `data`, then
    // `media_type`.
    members(map, at, &["data", "media_type"])?;
    let decoded = map.get("data").and_then(Value::as_str).filter(|d| !d.is_empty()).and_then(base64);
    let Some(decoded) = decoded else {
        return Err(format!("{at}.data"));
    };
    match map.get("media_type").and_then(Value::as_str) {
        Some(media_type) if media_types.contains(&media_type) => Ok(decoded),
        _ => Err(format!("{at}.media_type")),
    }
}

/// A block's members are `type` and `names`, nothing else; the first other
/// one, by name, is refused.
fn members(map: &Map<String, Value>, at: &str, names: &[&str]) -> Result<(), String> {
    let mut unknown: Vec<&String> = map.keys().filter(|k| *k != "type" && !names.contains(&k.as_str())).collect();
    unknown.sort();
    match unknown.first() {
        Some(name) => Err(format!("{at}.{name}")),
        None => Ok(()),
    }
}

/// The bytes padded standard base64 decodes to, or none for text that is
/// not it: whole quartets of the alphabet, `=` only as the last one or two
/// characters.
fn base64(data: &str) -> Option<usize> {
    let bytes = data.as_bytes();
    if bytes.len() % 4 != 0 {
        return None;
    }
    let pad = bytes.iter().rev().take_while(|b| **b == b'=').count();
    if pad > 2 {
        return None;
    }
    let body = &bytes[..bytes.len() - pad];
    if !body.iter().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/')) {
        return None;
    }
    Some(bytes.len() / 4 * 3 - pad)
}

/// The asking side of one call: when it asks, what it was handed and
/// whether it asks any more.
pub struct Feed<'a> {
    inputs: &'a mut dyn Inputs,
    written: Vec<String>,
    on: bool,
    pending: bool,
    asked: Option<Instant>,
}

impl<'a> Feed<'a> {
    pub fn new(inputs: &'a mut dyn Inputs) -> Self {
        Feed { inputs, written: Vec::new(), on: true, pending: false, asked: None }
    }

    /// Whether to ask now: the channel still serves, no input it handed is
    /// unsettled, and the last ask was `ASK_EVERY` ago.
    pub fn due(&self) -> bool {
        self.on && !self.pending && self.asked.is_none_or(|at| at.elapsed() >= ASK_EVERY)
    }

    /// The next input, which the caller writes and then settles (`accepted`,
    /// `refused`, `cannot`), or none. Anything but an input that reads and
    /// was not handed before stops the asking.
    pub fn ask(&mut self) -> Option<Input> {
        self.asked = Some(Instant::now());
        let handed = match self.inputs.next() {
            Ok(Some(handed)) => handed,
            Ok(None) => return None,
            Err(_) => return self.stop(),
        };
        if self.written.contains(&handed.0) {
            return self.stop();
        }
        match read(handed.0, &handed.1) {
            Ok(input) => {
                self.pending = true;
                Some(input)
            }
            Err(_) => self.stop(),
        }
    }

    /// The harness accepted the input: it is reported sent. A report that
    /// fails stops the asking; the input is never written again.
    pub fn accepted(&mut self, id: &str) {
        self.written.push(id.to_string());
        self.pending = false;
        if self.inputs.sent(id).is_err() {
            self.on = false;
        }
    }

    /// The harness refused the input, or its write's outcome is not known:
    /// it is not reported and never written again, and the asking stops.
    pub fn refused(&mut self, id: &str) {
        self.written.push(id.to_string());
        self.pending = false;
        self.on = false;
    }

    /// The input cannot be written whole (a block its harness does not
    /// take, a line past its bound): nothing is written or reported, and
    /// the asking stops.
    pub fn cannot(&mut self) {
        self.pending = false;
        self.on = false;
    }

    /// Ask no more in this call.
    pub fn stop<T>(&mut self) -> Option<T> {
        self.on = false;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    fn vectors() -> Value {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../../../../tests/fixtures/model_chat.json");
        serde_json::from_str(&std::fs::read_to_string(path).expect("the shared vectors")).unwrap()
    }

    fn input_of(case: &Value) -> Value {
        if let Some(input) = case.get("input") {
            return input.clone();
        }
        let generate = &case["generate"];
        let id = generate["id"].clone();
        if let Some(n) = generate["text_blocks"].as_u64() {
            let blocks: Vec<Value> = (0..n).map(|_| json!({"type": "text", "text": "x"})).collect();
            json!({"id": id, "content": blocks})
        } else {
            let n = generate["text_bytes"].as_u64().unwrap() as usize;
            json!({"id": id, "content": "a".repeat(n)})
        }
    }

    #[test]
    fn the_bounds_are_the_shared_vectors() {
        let v = vectors();
        assert_eq!(v["max_input_bytes"], json!(MAX_INPUT_BYTES));
        assert_eq!(v["max_input_blocks"], json!(MAX_INPUT_BLOCKS));
        let types: Map<String, Value> = MEDIA_TYPES.iter().map(|(kind, types)| (kind.to_string(), json!(types))).collect();
        assert_eq!(v["input_media_types"], Value::Object(types));
    }

    #[test]
    fn every_valid_input_reads_and_names_its_kinds() {
        for case in vectors()["valid_inputs"].as_array().unwrap() {
            let input = input_of(case);
            assert_eq!(check(&input), Ok(()), "{}", case["why"]);
            assert_eq!(json!(kinds(&input["content"])), case["kinds"], "{}", case["why"]);
            let read = read(input["id"].as_str().unwrap().to_string(), &input["content"].to_string());
            assert!(read.is_ok(), "{}", case["why"]);
        }
    }

    #[test]
    fn every_invalid_input_is_refused_naming_its_member() {
        for case in vectors()["invalid_inputs"].as_array().unwrap() {
            assert_eq!(check(&input_of(case)), Err(case["member"].as_str().unwrap().to_string()), "{}", case["why"]);
        }
    }

    #[test]
    fn the_line_bound_counts_the_json_to_the_byte() {
        let v = vectors();
        let sized = |cases: &Value| {
            cases.as_array().unwrap().iter().find(|c| c["generate"].get("text_bytes").is_some()).map(input_of).unwrap()
        };
        assert_eq!(serde_json::to_string(&sized(&v["valid_inputs"])).unwrap().len(), MAX_INPUT_BYTES);
        assert_eq!(serde_json::to_string(&sized(&v["invalid_inputs"])).unwrap().len(), MAX_INPUT_BYTES + 1);
    }

    #[test]
    fn padded_base64_alone_decodes() {
        assert_eq!(base64("QQ=="), Some(1));
        assert_eq!(base64("QUI="), Some(2));
        assert_eq!(base64("QUJD"), Some(3));
        for not in ["Q===", "QQ", "Q Q=", "QQ==QQ==", "====", "QQ=Q", "QQ-_"] {
            assert_eq!(base64(not), None, "{not}");
        }
    }

    /// A channel that answers from a script and records each call.
    struct Scripted {
        next: VecDeque<Result<Option<(String, String)>, String>>,
        sent: VecDeque<Result<(), String>>,
        log: Vec<String>,
    }

    impl Inputs for Scripted {
        fn next(&mut self) -> Result<Option<(String, String)>, String> {
            self.log.push("next".into());
            self.next.pop_front().unwrap_or(Ok(None))
        }
        fn sent(&mut self, id: &str) -> Result<(), String> {
            self.log.push(format!("sent {id}"));
            self.sent.pop_front().unwrap_or(Ok(()))
        }
    }

    fn handed(id: &str, content: &str) -> Result<Option<(String, String)>, String> {
        Ok(Some((id.to_string(), content.to_string())))
    }

    #[test]
    fn a_feed_asks_again_only_once_its_input_is_settled() {
        let mut inputs = Scripted { next: VecDeque::from([handed("a", "\"hi\""), handed("b", "\"yo\"")]), sent: VecDeque::new(), log: Vec::new() };
        let mut feed = Feed::new(&mut inputs);
        assert!(feed.due());
        let a = feed.ask().unwrap();
        assert_eq!(a.id, "a");
        feed.asked = None;
        assert!(!feed.due(), "no ask while a write awaits its answer");
        feed.accepted("a");
        feed.asked = None;
        assert_eq!(feed.ask().unwrap().id, "b");
        feed.accepted("b");
        assert_eq!(inputs.log, ["next", "sent a", "next", "sent b"]);
    }

    #[test]
    fn a_feed_asks_at_most_once_every_second() {
        let mut inputs = NoInputs;
        let mut feed = Feed::new(&mut inputs);
        assert!(feed.ask().is_none());
        assert!(!feed.due());
        feed.asked = Some(Instant::now() - ASK_EVERY);
        assert!(feed.due());
    }

    #[test]
    fn anything_but_a_fresh_input_that_reads_stops_the_asking() {
        let cases: Vec<Vec<Result<Option<(String, String)>, String>>> = vec![
            vec![Err("unavailable".into())],
            vec![handed("evt x", "\"hi\"")],
            vec![handed("a", "[{\"type\":\"image\",\"url\":\"https://x.test\"}]")],
            vec![handed("a", "not json")],
        ];
        for script in cases {
            let mut inputs = Scripted { next: VecDeque::from(script), sent: VecDeque::new(), log: Vec::new() };
            let mut feed = Feed::new(&mut inputs);
            assert!(feed.ask().is_none());
            feed.asked = None;
            assert!(!feed.due());
        }

        // An input handed again after it was written is never written twice.
        let mut inputs = Scripted { next: VecDeque::from([handed("a", "\"hi\""), handed("a", "\"hi\"")]), sent: VecDeque::new(), log: Vec::new() };
        let mut feed = Feed::new(&mut inputs);
        let a = feed.ask().unwrap();
        feed.accepted(&a.id);
        feed.asked = None;
        assert!(feed.ask().is_none());
        feed.asked = None;
        assert!(!feed.due());
    }

    #[test]
    fn a_report_that_fails_a_refusal_or_an_input_that_cannot_be_written_stops_the_asking() {
        let mut inputs = Scripted { next: VecDeque::from([handed("a", "\"hi\"")]), sent: VecDeque::from([Err("unavailable".into())]), log: Vec::new() };
        let mut feed = Feed::new(&mut inputs);
        let a = feed.ask().unwrap();
        feed.accepted(&a.id);
        feed.asked = None;
        assert!(!feed.due());

        for refuse in [true, false] {
            let mut inputs = Scripted { next: VecDeque::from([handed("a", "\"hi\"")]), sent: VecDeque::new(), log: Vec::new() };
            let mut feed = Feed::new(&mut inputs);
            let a = feed.ask().unwrap();
            if refuse {
                feed.refused(&a.id);
            } else {
                feed.cannot();
            }
            feed.asked = None;
            assert!(!feed.due());
            assert_eq!(inputs.log, ["next"], "nothing is reported");
        }
    }
}
