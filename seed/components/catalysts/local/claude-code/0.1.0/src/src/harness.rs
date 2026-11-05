//! Claude Code's own protocol on its standard input and output, as this
//! catalyst speaks it over the program's pipe: the command line a session
//! starts with, the lines written to it, and the events read back.
//!
//! The harness runs `-p` with stream-json in and out. Every line is one
//! JSON object: `user` messages and `control_request`/`control_response`
//! in both directions. CYFR's tools reach it through `mcp_set_servers`
//! (one MCP stdio server, `cyfr-stub`, given the tools on its command
//! line) rather than `--mcp-config`, since a pipe argument is at most
//! 4096 bytes and a tool list is not; the system prompt goes on the
//! `initialize` request as `appendSystemPrompt`, so the harness keeps its
//! own prompt.

use serde_json::{json, Map, Value};

/// The arguments every session starts with: stream-json both ways, partial
/// messages for streaming, no MCP server but the ones this catalyst sets,
/// and every permission ask of the harness's put to this catalyst.
pub const BASE_ARGV: &[&str] = &[
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--strict-mcp-config",
    "--permission-prompt-tool",
    "stdio",
];

/// The MCP server CYFR's tools are reached through, and the prefix the
/// harness names its tools with.
pub const SERVER: &str = "cyfr";
pub const TOOL_PREFIX: &str = "mcp__cyfr__";

/// The stub's command in the program's box (`Dockerfile.locus`).
pub const STUB: &str = "cyfr-stub";

/// Request ids of this catalyst's own control requests.
pub const INIT_ID: &str = "cyfr-initialize";
pub const TOOLS_ID: &str = "cyfr-tools";

/// How a session starts: as a new session under an id this catalyst
/// chose, or resuming one the harness keeps in its folder.
pub enum Start<'a> {
    New(&'a str),
    Resume(&'a str),
}

/// What a request sets on the command line.
#[derive(Default)]
pub struct Flags {
    pub model: Option<String>,
    pub effort: Option<String>,
    pub permission_mode: Option<String>,
    pub tools: Option<String>,
}

/// The command line a chat session starts with.
pub fn argv(start: Start, flags: &Flags) -> Vec<String> {
    let mut argv: Vec<String> = BASE_ARGV.iter().map(|a| a.to_string()).collect();
    match start {
        Start::New(id) => argv.extend(["--session-id".into(), id.to_string()]),
        Start::Resume(id) => argv.extend(["--resume".into(), id.to_string()]),
    }
    let pairs = [
        ("--model", &flags.model),
        ("--effort", &flags.effort),
        ("--permission-mode", &flags.permission_mode),
        ("--tools", &flags.tools),
    ];
    for (flag, value) in pairs {
        if let Some(value) = value {
            argv.push(flag.to_string());
            argv.push(value.clone());
        }
    }
    argv
}

/// The `initialize` request, carrying CYFR's system prompt to be appended
/// to the harness's own.
pub fn initialize(append: Option<&str>) -> String {
    let mut request = Map::new();
    request.insert("subtype".into(), json!("initialize"));
    if let Some(text) = append {
        request.insert("appendSystemPrompt".into(), json!(text));
    }
    json!({"type": "control_request", "request_id": INIT_ID, "request": request}).to_string()
}

/// One tool as the stub's argument: `{name, description, inputSchema}`.
pub fn stub_tool(name: &str, description: &str, parameters: &Value) -> String {
    json!({"name": name, "description": description, "inputSchema": parameters}).to_string()
}

/// The `mcp_set_servers` request: the stub with `tools` (each one argument,
/// as `stub_tool` writes it), or no server when there are none.
pub fn set_tools(tools: &[String]) -> String {
    let servers = if tools.is_empty() {
        json!({})
    } else {
        json!({SERVER: {"type": "stdio", "command": STUB, "args": tools}})
    };
    json!({
        "type": "control_request",
        "request_id": TOOLS_ID,
        "request": {"subtype": "mcp_set_servers", "servers": servers}
    })
    .to_string()
}

/// A user message of content blocks, in the harness's (the Messages API's)
/// block shapes.
pub fn user(content: Vec<Value>) -> String {
    json!({
        "type": "user",
        "message": {"role": "user", "content": content},
        "parent_tool_use_id": null,
        "session_id": ""
    })
    .to_string()
}

/// An allow of the ask `request_id`, with the input the call runs with.
pub fn allow(request_id: &str, input: &Value) -> String {
    json!({
        "type": "control_response",
        "response": {
            "subtype": "success",
            "request_id": request_id,
            "response": {"behavior": "allow", "updatedInput": input}
        }
    })
    .to_string()
}

/// A refusal of a control request this catalyst does not answer.
pub fn unanswered(request_id: &str, subtype: &str) -> String {
    json!({
        "type": "control_response",
        "response": {
            "subtype": "error",
            "request_id": request_id,
            "error": format!("CYFR does not answer {subtype}")
        }
    })
    .to_string()
}

/// One line of the harness's output, as far as a turn reads it.
#[derive(Debug, PartialEq)]
pub enum Event {
    /// A text fragment of the main session's reply as it streams.
    TextDelta(String),
    /// A whole assistant message of the main session: its text, and
    /// the error the harness typed it with, if any.
    Assistant { text: String, error: Option<String> },
    /// The harness asks whether it may run a tool.
    Ask {
        request_id: String,
        tool: String,
        input: Value,
        tool_use_id: Option<String>,
    },
    /// Any other request of the harness's, which this catalyst refuses.
    Request { request_id: String, subtype: String },
    /// The answer to one of this catalyst's own control requests.
    Answer {
        request_id: String,
        ok: bool,
        response: Value,
    },
    /// The turn's start, naming the model it runs on.
    Init { model: Option<String> },
    /// The turn's end.
    Result {
        ok: bool,
        subtype: String,
        usage: Value,
    },
    /// Anything else: subagents' messages, tool results, heartbeats.
    Other,
}

/// The event a line is. A line that is no JSON object is `Other`.
pub fn read(line: &str) -> Event {
    let Ok(value) = serde_json::from_str::<Value>(line) else {
        return Event::Other;
    };
    let main = value.get("parent_tool_use_id").is_none_or(Value::is_null);
    match value.get("type").and_then(Value::as_str) {
        Some("stream_event") if main => {
            let event = &value["event"];
            match (
                event.get("type").and_then(Value::as_str),
                event["delta"].get("type").and_then(Value::as_str),
            ) {
                (Some("content_block_delta"), Some("text_delta")) => {
                    Event::TextDelta(str_of(&event["delta"]["text"]))
                }
                _ => Event::Other,
            }
        }
        Some("assistant") if main => {
            let text = value["message"]["content"]
                .as_array()
                .map(|blocks| {
                    blocks
                        .iter()
                        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                        .map(|b| str_of(&b["text"]))
                        .collect::<String>()
                })
                .unwrap_or_default();
            let error = value.get("error").and_then(Value::as_str).map(str::to_string);
            Event::Assistant { text, error }
        }
        Some("control_request") => {
            let request_id = str_of(&value["request_id"]);
            let request = &value["request"];
            match request.get("subtype").and_then(Value::as_str) {
                Some("can_use_tool") => Event::Ask {
                    request_id,
                    tool: str_of(&request["tool_name"]),
                    input: match request.get("input") {
                        Some(input @ Value::Object(_)) => input.clone(),
                        _ => json!({}),
                    },
                    tool_use_id: request
                        .get("tool_use_id")
                        .and_then(Value::as_str)
                        .filter(|id| !id.is_empty())
                        .map(str::to_string),
                },
                subtype => Event::Request {
                    request_id,
                    subtype: subtype.unwrap_or("").to_string(),
                },
            }
        }
        Some("control_response") => {
            let response = &value["response"];
            Event::Answer {
                request_id: str_of(&response["request_id"]),
                ok: response.get("subtype").and_then(Value::as_str) == Some("success"),
                response: response.get("response").cloned().unwrap_or(Value::Null),
            }
        }
        Some("system") if value.get("subtype").and_then(Value::as_str) == Some("init") => Event::Init {
            model: value.get("model").and_then(Value::as_str).map(str::to_string),
        },
        Some("result") => Event::Result {
            ok: value.get("subtype").and_then(Value::as_str) == Some("success")
                && value.get("is_error").and_then(Value::as_bool) != Some(true),
            subtype: str_of(&value["subtype"]),
            usage: value.get("usage").cloned().unwrap_or(Value::Null),
        },
        _ => Event::Other,
    }
}

fn str_of(value: &Value) -> String {
    value.as_str().unwrap_or("").to_string()
}

/// The contract's usage from the harness's (the Messages API's) usage.
pub fn usage(usage: &Value) -> Value {
    let count = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    json!({
        "input_tokens": count("input_tokens"),
        "output_tokens": count("output_tokens"),
        "cache_read_tokens": count("cache_read_input_tokens"),
        "cache_write_tokens": count("cache_creation_input_tokens"),
    })
}

/// The contract's refusal type for an error the harness typed an assistant
/// message with: its account's, the provider's, the request's or the
/// model's.
pub fn error_kind(error: &str) -> &'static str {
    match error {
        "authentication_failed" | "oauth_org_not_allowed" | "account_on_hold" | "verification_required"
        | "billing_error" | "cloud_credential_error" => "authentication",
        "rate_limit" => "rate_limited",
        "overloaded" => "overloaded",
        "invalid_request" => "invalid_request",
        "model_not_found" => "unknown_model",
        _ => "provider_error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_session_starts_with_the_base_its_id_and_the_flags_set() {
        let flags = Flags {
            model: Some("opus".into()),
            effort: Some("high".into()),
            permission_mode: None,
            tools: Some(String::new()),
        };
        let mut want: Vec<String> = BASE_ARGV.iter().map(|a| a.to_string()).collect();
        want.extend(
            ["--session-id", "s-1", "--model", "opus", "--effort", "high", "--tools", ""]
                .iter()
                .map(|a| a.to_string()),
        );
        assert_eq!(argv(Start::New("s-1"), &flags), want);
        let resumed = argv(Start::Resume("s-1"), &Flags::default());
        assert_eq!(&resumed[BASE_ARGV.len()..], ["--resume", "s-1"]);
    }

    #[test]
    fn the_base_puts_every_ask_to_the_driver_and_loads_no_server_of_its_own() {
        for want in ["--strict-mcp-config", "--include-partial-messages"] {
            assert!(BASE_ARGV.contains(&want));
        }
        let at = BASE_ARGV.iter().position(|a| *a == "--permission-prompt-tool").unwrap();
        assert_eq!(BASE_ARGV[at + 1], "stdio");
        assert!(!BASE_ARGV.contains(&"--mcp-config"));
    }

    #[test]
    fn tools_reach_the_stub_one_per_argument_and_none_removes_it() {
        let tool = stub_tool("files", "Read files", &json!({"type": "object"}));
        let set: Value = serde_json::from_str(&set_tools(std::slice::from_ref(&tool))).unwrap();
        assert_eq!(set["request"]["subtype"], "mcp_set_servers");
        assert_eq!(set["request"]["servers"]["cyfr"]["command"], STUB);
        assert_eq!(set["request"]["servers"]["cyfr"]["args"], json!([tool]));
        let none: Value = serde_json::from_str(&set_tools(&[])).unwrap();
        assert_eq!(none["request"]["servers"], json!({}));
    }

    #[test]
    fn lines_are_single_lines() {
        let line = user(vec![json!({"type": "text", "text": "two\nlines"})]);
        assert!(!line.contains('\n'));
        let line = initialize(Some("a\nprompt"));
        assert!(!line.contains('\n'));
    }

    #[test]
    fn the_proven_event_shapes_read_as_events() {
        assert_eq!(
            read(r#"{"type":"system","subtype":"init","session_id":"s","model":"claude-haiku-5-5","tools":[]}"#),
            Event::Init { model: Some("claude-haiku-5-5".into()) }
        );
        assert_eq!(
            read(r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}},"parent_tool_use_id":null}"#),
            Event::TextDelta("Hi".into())
        );
        assert_eq!(
            read(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"The word is "},{"type":"tool_use","name":"Read","id":"t1","input":{}},{"type":"text","text":"marmalade."}]},"parent_tool_use_id":null}"#),
            Event::Assistant { text: "The word is marmalade.".into(), error: None }
        );
        assert_eq!(
            read(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]},"parent_tool_use_id":"toolu_sub"}"#),
            Event::Other
        );
        assert_eq!(
            read(r#"{"type":"control_request","request_id":"1a01","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"touch a"},"permission_suggestions":[]}}"#),
            Event::Ask {
                request_id: "1a01".into(),
                tool: "Bash".into(),
                input: json!({"command": "touch a"}),
                tool_use_id: None
            }
        );
        assert_eq!(
            read(r#"{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback"}}"#),
            Event::Request { request_id: "h1".into(), subtype: "hook_callback".into() }
        );
        assert_eq!(
            read(r#"{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":3}}"#),
            Event::Result { ok: true, subtype: "success".into(), usage: json!({"input_tokens": 3}) }
        );
        assert_eq!(
            read(r#"{"type":"result","subtype":"success","is_error":true}"#),
            Event::Result { ok: false, subtype: "success".into(), usage: Value::Null }
        );
        assert_eq!(read("not json"), Event::Other);
        assert_eq!(read(r#"{"type":"tool_progress","heartbeat":true}"#), Event::Other);
    }

    #[test]
    fn usage_takes_the_cache_counts() {
        let got = usage(&json!({"input_tokens": 4, "output_tokens": 9, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 7}));
        assert_eq!(got, json!({"input_tokens": 4, "output_tokens": 9, "cache_read_tokens": 100, "cache_write_tokens": 7}));
    }
}
