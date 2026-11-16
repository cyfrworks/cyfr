//! The one rule a harness session is rebuilt by, the same file in every
//! harness catalyst and pinned by `tests/fixtures/session_context.json`.
//!
//! A `chat` request carries the thread's whole projection (`Aqua.Loop.Request`):
//! every message the reading agent may read, in order, the last of them the
//! current ask (a user message, or the results of the calls the message
//! before it made). A session the request names already holds everything but
//! that last message, so a continued session is sent the current ask alone. A
//! session that starts fresh holds nothing, so it is handed the messages
//! before the current ask first, as context, then the current ask: who said
//! what (the projection's attribution kept as it is), the agent's own replies
//! and calls, and each call's outcome. History is context and never a call:
//! nothing in it is dispatched or answered again, and the opening says so to
//! the model.
//!
//! The history rides in the line that carries the current ask, so it is kept
//! within that line's bound: the newest messages that fit, whole, with a note
//! of how many earlier ones are not shown.

use serde_json::Value;

/// One part of a fresh session's history: text, or an attachment block as
/// the contract carries it (`{type, media_type, data}`).
#[derive(Debug, PartialEq, Clone)]
pub enum Part {
    Text(String),
    Media { kind: String, media_type: String, data: String },
}

/// The room a line keeps for its envelope, besides the history and the
/// current ask.
pub const MARGIN: usize = 65_536;

/// The bytes an attachment counts for besides its data and media type.
const MEDIA_OVERHEAD: usize = 64;

pub const OPENING: &str = "[CYFR] This session is new, and the thread it continues already has a history. \
Here it is, oldest first, as context only: every call in it has already run or ended as its outcome says, \
and none is to be made again because it is shown here.";

pub const CLOSING: &str = "[CYFR] The history ends here. What is asked now follows.";

/// What a brain takes as an attachment: the block kinds and media types.
pub struct Takes<'a> {
    pub kinds: &'a [&'a str],
    pub media_types: &'a [&'a str],
}

/// The history a session that starts fresh is handed before the current
/// ask (the last of `messages`), kept within `line_bytes`; none when the
/// current ask is all the request holds.
pub fn fresh(messages: &[Value], takes: &Takes, line_bytes: usize) -> Vec<Part> {
    let Some((current, before)) = messages.split_last() else {
        return Vec::new();
    };
    if before.is_empty() {
        return Vec::new();
    }
    let budget = line_bytes
        .saturating_sub(MARGIN)
        .saturating_sub(json_len(&current.to_string()))
        .saturating_sub(json_len(OPENING) + json_len(CLOSING));
    let rendered: Vec<Vec<Part>> = before.iter().map(|m| message(m, takes)).collect();
    let mut used = 0;
    let mut kept = 0;
    for parts in rendered.iter().rev() {
        let size: usize = parts.iter().map(size).sum();
        if used + size > budget {
            break;
        }
        used += size;
        kept += 1;
    }
    let dropped = rendered.len() - kept;
    let mut out = vec![Part::Text(OPENING.to_string())];
    if dropped > 0 {
        let note = match dropped {
            1 => "[1 earlier message of the thread is not shown here.]".to_string(),
            n => format!("[{n} earlier messages of the thread are not shown here.]"),
        };
        push(&mut out, Part::Text(note));
    }
    for parts in rendered.into_iter().skip(dropped) {
        for (i, part) in parts.into_iter().enumerate() {
            match part {
                Part::Text(text) if i == 0 => push(&mut out, Part::Text(text)),
                Part::Text(text) => append(&mut out, text),
                media => out.push(media),
            }
        }
    }
    push(&mut out, Part::Text(CLOSING.to_string()));
    out
}

/// A new paragraph: joined to the text before it, or a text of its own
/// after an attachment.
fn push(out: &mut Vec<Part>, part: Part) {
    match (out.last_mut(), part) {
        (Some(Part::Text(last)), Part::Text(text)) => {
            last.push_str("\n\n");
            last.push_str(&text);
        }
        (_, part) => out.push(part),
    }
}

/// The rest of one message's text, after an attachment of it.
fn append(out: &mut Vec<Part>, text: String) {
    match out.last_mut() {
        Some(Part::Text(last)) => {
            last.push('\n');
            last.push_str(&text);
        }
        _ => out.push(Part::Text(text)),
    }
}

/// One message as parts: its first part is text that opens with who
/// wrote it; a later text part follows an attachment of the same message.
fn message(message: &Value, takes: &Takes) -> Vec<Part> {
    let role = message.get("role").and_then(Value::as_str).unwrap_or("");
    let blocks: Vec<Value> = match message.get("content") {
        Some(Value::String(text)) => vec![serde_json::json!({"type": "text", "text": text})],
        Some(Value::Array(blocks)) => blocks.clone(),
        _ => Vec::new(),
    };
    let label = match role {
        "assistant" => "[you]".to_string(),
        "tool" => "[outcomes of your calls]".to_string(),
        "user" => "[user]".to_string(),
        other => format!("[{other}]"),
    };
    let mut parts = vec![Part::Text(label)];
    for block in &blocks {
        let str_of = |key: &str| block.get(key).and_then(Value::as_str).unwrap_or("");
        match block.get("type").and_then(Value::as_str).unwrap_or("") {
            "text" => line(&mut parts, str_of("text").to_string()),
            "tool_call" => {
                let arguments = block.get("arguments").map_or_else(|| "{}".to_string(), Value::to_string);
                line(&mut parts, format!("[you called {} with {arguments}]", str_of("name")));
            }
            "tool_result" => {
                let failed = block.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                let head = if failed { "failed" } else { "answered" };
                line(&mut parts, format!("[{} {head}]\n{}", str_of("name"), result_text(block.get("content"))));
            }
            kind @ ("image" | "document") => {
                let media_type = str_of("media_type");
                match block.get("data").and_then(Value::as_str) {
                    Some(data) if takes.kinds.contains(&kind) && takes.media_types.contains(&media_type) => {
                        parts.push(Part::Media { kind: kind.to_string(), media_type: media_type.to_string(), data: data.to_string() })
                    }
                    _ => line(&mut parts, format!("[an attachment ({media_type}) this session cannot be shown]")),
                }
            }
            _ => {}
        }
    }
    parts
}

/// A line of a message's text: on the text before it, or a text of its own
/// after an attachment.
fn line(parts: &mut Vec<Part>, text: String) {
    match parts.last_mut() {
        Some(Part::Text(last)) => {
            last.push('\n');
            last.push_str(&text);
        }
        _ => parts.push(Part::Text(text)),
    }
}

/// A tool result's content: a string, or its text blocks joined in order.
fn result_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(blocks)) => blocks.iter().filter_map(|b| b.get("text").and_then(Value::as_str)).collect(),
        _ => String::new(),
    }
}

/// The bytes `text` takes as a JSON string.
fn json_len(text: &str) -> usize {
    Value::String(text.to_string()).to_string().len()
}

/// The bytes a part counts for in the line's budget, with the paragraph
/// break that joins it.
fn size(part: &Part) -> usize {
    match part {
        Part::Text(text) => json_len(text) + 4,
        Part::Media { media_type, data, .. } => data.len() + media_type.len() + MEDIA_OVERHEAD,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn vectors() -> Value {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../../../../tests/fixtures/session_context.json");
        serde_json::from_str(&std::fs::read_to_string(path).expect("the shared vectors")).unwrap()
    }

    fn strs(value: &Value) -> Vec<&str> {
        value.as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect()
    }

    fn as_json(parts: &[Part]) -> Value {
        Value::Array(
            parts
                .iter()
                .map(|part| match part {
                    Part::Text(text) => json!({"text": text}),
                    Part::Media { kind, media_type, data } => {
                        json!({"media": {"kind": kind, "media_type": media_type, "data": data}})
                    }
                })
                .collect(),
        )
    }

    #[test]
    fn each_shared_case_renders_its_parts() {
        let vectors = vectors();
        let cases = vectors["cases"].as_array().unwrap();
        assert!(!cases.is_empty());
        for case in cases {
            let kinds = strs(&case["kinds"]);
            let media_types = strs(&case["media_types"]);
            let takes = Takes { kinds: &kinds, media_types: &media_types };
            let line_bytes = case["line_bytes"].as_u64().unwrap() as usize;
            let parts = fresh(case["messages"].as_array().unwrap(), &takes, line_bytes);
            assert_eq!(as_json(&parts), case["parts"], "{}", case["name"]);
        }
    }
}
