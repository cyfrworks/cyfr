//! Codex's app-server protocol on its standard input and output, as this
//! catalyst speaks it over the program's pipe (Codex 0.167.0,
//! `codex-rs/app-server-protocol`): JSON-RPC 2.0 messages without the
//! `jsonrpc` member, one per line. The catalyst sends requests
//! (`initialize`, `account/read`, `model/list`, `thread/start`,
//! `thread/resume`, `turn/start`) and the `initialized` notification, and
//! answers Codex's own requests: `item/tool/call` for CYFR's tools, given
//! to the thread as dynamic tools, and the approval requests, which are
//! allowed. Everything else Codex writes is a notification this module
//! reads into an `Event`.

use serde_json::{json, Value};

/// The command line's argument: the program's command is the login row's
/// (`npx -y @openai/codex@<version>`), and this starts its app-server on
/// standard input and output.
pub const ARGV: &[&str] = &["app-server"];

/// How a thread runs inside the keeper's box (the user's ruling D2): the
/// box is the only boundary. Codex's own sandbox is off, since it would
/// nest a second sandbox inside the box's and its namespaces are not the
/// box's to grant, and it asks for nothing: its commands and patches run
/// as the box lets them, and are shown by name only.
pub const APPROVAL_POLICY: &str = "never";
pub const SANDBOX: &str = "danger-full-access";

/// The `type`s of Codex's thread items that are its own tools, shown as a
/// `tool_call.start` and `tool_call.end` pair under that name.
pub const OWN_TOOLS: &[&str] = &[
    "commandExecution",
    "fileChange",
    "mcpToolCall",
    "webSearch",
    "imageView",
    "collabAgentToolCall",
];

/// A request of this catalyst's: `{id, method, params}`.
pub fn request(id: &str, method: &str, params: Value) -> String {
    json!({"id": id, "method": method, "params": params}).to_string()
}

/// `initialize`, opting into the experimental API: `thread/start`'s
/// `dynamicTools`, which carry CYFR's tools, is an experimental field.
pub fn initialize(id: &str) -> String {
    request(
        id,
        "initialize",
        json!({
            "clientInfo": {"name": "cyfr", "title": "CYFR", "version": env!("CARGO_PKG_VERSION")},
            "capabilities": {"experimentalApi": true}
        }),
    )
}

/// The notification that ends the handshake, after `initialize`'s answer.
pub fn initialized() -> String {
    json!({"method": "initialized"}).to_string()
}

pub fn account_read(id: &str) -> String {
    request(id, "account/read", json!({}))
}

pub fn model_list(id: &str, cursor: Option<&str>) -> String {
    let mut params = json!({});
    if let Some(cursor) = cursor {
        params["cursor"] = json!(cursor);
    }
    request(id, "model/list", params)
}

/// One of CYFR's tools as a dynamic tool: `{type: "function", name,
/// description, inputSchema}`.
pub fn dynamic_tool(name: &str, description: &str, parameters: &Value) -> Value {
    json!({"type": "function", "name": name, "description": description, "inputSchema": parameters})
}

/// `thread/start`: a new thread, under the policy above, with CYFR's system
/// prompt as developer instructions beside Codex's own and CYFR's tools as
/// its dynamic tools, which the thread keeps for its life.
pub fn thread_start(id: &str, system: Option<&str>, tools: &[Value]) -> String {
    let mut params = json!({
        "approvalPolicy": APPROVAL_POLICY,
        "sandbox": SANDBOX,
        "dynamicTools": tools,
    });
    if let Some(system) = system {
        params["developerInstructions"] = json!(system);
    }
    request(id, "thread/start", params)
}

/// `thread/resume`: the thread the kept home holds, with the dynamic tools
/// it was started with.
pub fn thread_resume(id: &str, thread: &str, system: Option<&str>) -> String {
    let mut params = json!({
        "threadId": thread,
        "approvalPolicy": APPROVAL_POLICY,
        "sandbox": SANDBOX,
        "excludeTurns": true,
    });
    if let Some(system) = system {
        params["developerInstructions"] = json!(system);
    }
    request(id, "thread/resume", params)
}

/// `turn/start`: a user message as Codex's input items, with the model and
/// effort the request sets, which Codex takes per turn.
pub fn turn_start(id: &str, thread: &str, input: &[Value], model: Option<&str>, effort: Option<&str>) -> String {
    let mut params = json!({"threadId": thread, "input": input});
    if let Some(model) = model {
        params["model"] = json!(model);
    }
    if let Some(effort) = effort {
        params["effort"] = json!(effort);
    }
    request(id, "turn/start", params)
}

/// The answer to Codex's request `request` (its id as Codex wrote it).
pub fn result(request: &Value, result: Value) -> String {
    json!({"id": request, "result": result}).to_string()
}

/// The answer to an `item/tool/call`: CYFR's answer as one text item, and
/// whether CYFR ran the call.
pub fn tool_answer(request: &Value, text: &str, success: bool) -> String {
    result(request, json!({"contentItems": [{"type": "inputText", "text": text}], "success": success}))
}

/// The refusal of a request of Codex's this catalyst does not answer.
pub fn refuse(request: &Value, method: &str) -> String {
    json!({"id": request, "error": {"code": -32601, "message": format!("CYFR does not answer {method}")}}).to_string()
}

/// The allow of an approval request, by its method; `None` for a request
/// that is no approval.
pub fn allow(method: &str, params: &Value, now_secs: i64) -> Option<Value> {
    Some(match method {
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => json!({"decision": "accept"}),
        "execCommandApproval" | "applyPatchApproval" => json!({"decision": "approved"}),
        "item/permissions/requestApproval" => json!({"permissions": params["permissions"], "scope": "turn"}),
        "mcpServer/elicitation/request" => json!({"action": "accept", "content": null}),
        // Not an approval, but a question Codex's clock provider asks its
        // client, which only this catalyst can answer.
        "currentTime/read" => json!({"currentTimeAt": now_secs}),
        _ => return None,
    })
}

/// One line of Codex's output, as far as this catalyst reads it.
#[derive(Debug, PartialEq)]
pub enum Event {
    /// The answer to a request of this catalyst's: its result, or the
    /// error's message.
    Response { id: String, result: Result<Value, String> },
    /// A text fragment of an agent message of `turn`.
    Delta { turn: String, item: String, text: String },
    /// A whole agent message of `turn`.
    Message { turn: String, item: String, text: String },
    /// One of Codex's own tools started in `turn`.
    OwnTool { turn: String, id: String, kind: String },
    /// Codex asks this catalyst to run one of CYFR's tools.
    ToolCall {
        request: Value,
        turn: String,
        call: String,
        tool: String,
        arguments: Value,
    },
    /// Any other request of Codex's: an approval or one this catalyst
    /// refuses.
    Request { request: Value, method: String, params: Value },
    /// The thread's token usage so far, as `turn` reported it.
    Usage { turn: String, total: Counts },
    /// `turn` ended: `completed`, `interrupted` or `failed`, with its error.
    TurnDone { turn: String, status: String, error: Value },
    /// Anything else: other notifications, other items.
    Other,
}

/// The event a line is. A line that is no JSON object is `Other`.
pub fn read(line: &str) -> Event {
    let Ok(value) = serde_json::from_str::<Value>(line) else {
        return Event::Other;
    };
    let params = &value["params"];
    let turn = || str_of(&params["turnId"]);
    match (value.get("method").and_then(Value::as_str), value.get("id")) {
        (None, Some(id)) => Event::Response {
            id: id.as_str().map(str::to_string).unwrap_or_else(|| id.to_string()),
            result: match value.get("error") {
                Some(error) => Err(str_of(&error["message"])),
                None => Ok(value.get("result").cloned().unwrap_or(Value::Null)),
            },
        },
        (Some("item/tool/call"), Some(request)) => Event::ToolCall {
            request: request.clone(),
            turn: turn(),
            call: str_of(&params["callId"]),
            tool: str_of(&params["tool"]),
            arguments: match params.get("arguments") {
                Some(arguments @ Value::Object(_)) => arguments.clone(),
                _ => json!({}),
            },
        },
        (Some(method), Some(request)) => Event::Request {
            request: request.clone(),
            method: method.to_string(),
            params: params.clone(),
        },
        (Some("item/agentMessage/delta"), None) => Event::Delta {
            turn: turn(),
            item: str_of(&params["itemId"]),
            text: str_of(&params["delta"]),
        },
        (Some("item/completed"), None) if params["item"]["type"] == "agentMessage" => Event::Message {
            turn: turn(),
            item: str_of(&params["item"]["id"]),
            text: str_of(&params["item"]["text"]),
        },
        (Some("item/started"), None) => {
            let kind = str_of(&params["item"]["type"]);
            if OWN_TOOLS.contains(&kind.as_str()) {
                Event::OwnTool { turn: turn(), id: str_of(&params["item"]["id"]), kind }
            } else {
                Event::Other
            }
        }
        (Some("thread/tokenUsage/updated"), None) => Event::Usage {
            turn: turn(),
            total: counts(&params["tokenUsage"]["total"]),
        },
        (Some("turn/completed"), None) => Event::TurnDone {
            turn: str_of(&params["turn"]["id"]),
            status: str_of(&params["turn"]["status"]),
            error: params["turn"]["error"].clone(),
        },
        _ => Event::Other,
    }
}

fn str_of(value: &Value) -> String {
    value.as_str().unwrap_or("").to_string()
}

/// The counts of a `TokenUsageBreakdown` this catalyst reads, in the
/// contract's order: input (cached input among it, as the Responses API
/// counts it), output, cached input, cache writes.
pub type Counts = [u64; 4];

pub fn counts(breakdown: &Value) -> Counts {
    let count = |key: &str| breakdown.get(key).and_then(Value::as_u64).unwrap_or(0);
    [count("inputTokens"), count("outputTokens"), count("cachedInputTokens"), count("cacheWriteInputTokens")]
}

/// What a usage snapshot adds to `sum`: its thread total past the total
/// before it. Codex adds each model call's usage to the thread's total and
/// sends the total again unchanged whenever its rate limits update
/// (`Session::update_rate_limits`), so only the difference is new. A total
/// lower than the one before (a compaction that refills the window resets
/// it) adds nothing.
pub fn consumed(sum: &mut Counts, before: &Counts, total: &Counts) {
    for i in 0..4 {
        sum[i] += total[i].saturating_sub(before[i]);
    }
}

/// The contract's usage from `sum`.
pub fn usage(sum: &Counts) -> Value {
    json!({"input_tokens": sum[0], "output_tokens": sum[1], "cache_read_tokens": sum[2], "cache_write_tokens": sum[3]})
}

/// The contract's refusal type for the error a turn failed with, by its
/// `codexErrorInfo`: the account's, the provider's, the request's or the
/// model's.
pub fn error_kind(error: &Value) -> &'static str {
    // A plain variant is a string; one carrying an HTTP status is an object
    // `{variant: {httpStatusCode}}`.
    let info = &error["codexErrorInfo"];
    let status = info
        .as_object()
        .and_then(|o| o.values().next())
        .and_then(|v| v.get("httpStatusCode"))
        .and_then(Value::as_u64);
    match (info.as_str(), status) {
        (Some("unauthorized"), _) | (_, Some(401 | 403)) => "authentication",
        (Some("usageLimitExceeded" | "rateLimitExceeded"), _) | (_, Some(429)) => "rate_limited",
        (Some("serverOverloaded"), _) | (_, Some(503 | 529)) => "overloaded",
        (Some("badRequest" | "contextWindowExceeded"), _) => "invalid_request",
        (Some("modelNotFound"), _) => "unknown_model",
        _ => "provider_error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Lines as Codex 0.167.0's app-server wrote them, recorded from the
    /// binary (README, "Verified against 0.167.0"), cut to the members read.
    #[test]
    fn the_recorded_lines_read_as_events() {
        assert_eq!(
            read(r#"{"id":"cyfr-turn-1","result":{"turn":{"id":"t1","status":"inProgress"}}}"#),
            Event::Response { id: "cyfr-turn-1".into(), result: Ok(json!({"turn": {"id": "t1", "status": "inProgress"}})) }
        );
        assert_eq!(
            read(r#"{"error":{"code":-32600,"message":"no active turn to interrupt"},"id":7}"#),
            Event::Response { id: "7".into(), result: Err("no active turn to interrupt".into()) }
        );
        assert_eq!(
            read(r#"{"method":"item/agentMessage/delta","params":{"threadId":"th","turnId":"t1","itemId":"m0","delta":"Look"},"emittedAtMs":1}"#),
            Event::Delta { turn: "t1".into(), item: "m0".into(), text: "Look".into() }
        );
        assert_eq!(
            read(r#"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m0","text":"Looking.","phase":null},"threadId":"th","turnId":"t1"}}"#),
            Event::Message { turn: "t1".into(), item: "m0".into(), text: "Looking.".into() }
        );
        assert_eq!(
            read(r#"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"c3","command":"/bin/bash -lc 'cat secret'","status":"inProgress"},"threadId":"th","turnId":"t1"}}"#),
            Event::OwnTool { turn: "t1".into(), id: "c3".into(), kind: "commandExecution".into() }
        );
        assert_eq!(
            read(r#"{"method":"item/started","params":{"item":{"type":"userMessage","id":"u","content":[]},"threadId":"th","turnId":"t1"}}"#),
            Event::Other
        );
        assert_eq!(
            read(r#"{"method":"item/tool/call","id":0,"params":{"threadId":"th","turnId":"t1","callId":"c1","namespace":null,"tool":"files","arguments":{"path":"a.txt"}}}"#),
            Event::ToolCall { request: json!(0), turn: "t1".into(), call: "c1".into(), tool: "files".into(), arguments: json!({"path": "a.txt"}) }
        );
        assert_eq!(
            read(r#"{"method":"item/fileChange/requestApproval","id":4,"params":{"turnId":"t1"}}"#),
            Event::Request { request: json!(4), method: "item/fileChange/requestApproval".into(), params: json!({"turnId": "t1"}) }
        );
        assert_eq!(
            read(r#"{"method":"thread/tokenUsage/updated","params":{"threadId":"th","turnId":"t1","tokenUsage":{"total":{"inputTokens":22},"last":{"totalTokens":18,"inputTokens":11,"cachedInputTokens":3,"cacheWriteInputTokens":0,"outputTokens":7,"reasoningOutputTokens":0}}}}"#),
            Event::Usage { turn: "t1".into(), total: [22, 0, 0, 0] }
        );
        assert_eq!(
            read(r#"{"method":"turn/completed","params":{"threadId":"th","turn":{"id":"t1","status":"failed","error":{"message":"unexpected status 401","codexErrorInfo":{"httpConnectionFailed":{"httpStatusCode":401}}}}}}"#),
            Event::TurnDone {
                turn: "t1".into(),
                status: "failed".into(),
                error: json!({"message":"unexpected status 401","codexErrorInfo":{"httpConnectionFailed":{"httpStatusCode":401}}})
            }
        );
        assert_eq!(read(r#"{"method":"thread/status/changed","params":{"threadId":"th","status":{"type":"idle"}}}"#), Event::Other);
        assert_eq!(read("not json"), Event::Other);
    }

    #[test]
    fn a_turn_s_error_maps_by_its_info() {
        let kind = |info: Value| error_kind(&json!({"message": "x", "codexErrorInfo": info}));
        assert_eq!(kind(json!({"httpConnectionFailed": {"httpStatusCode": 401}})), "authentication");
        assert_eq!(kind(json!("unauthorized")), "authentication");
        assert_eq!(kind(json!("usageLimitExceeded")), "rate_limited");
        assert_eq!(kind(json!({"responseStreamDisconnected": {"httpStatusCode": 429}})), "rate_limited");
        assert_eq!(kind(json!("serverOverloaded")), "overloaded");
        assert_eq!(kind(json!("modelNotFound")), "unknown_model");
        assert_eq!(kind(json!("contextWindowExceeded")), "invalid_request");
        assert_eq!(kind(json!("internalServerError")), "provider_error");
        assert_eq!(error_kind(&Value::Null), "provider_error");
    }

    #[test]
    fn a_thread_runs_with_codex_s_sandbox_off_and_no_asks() {
        let start: Value = serde_json::from_str(&thread_start("i", Some("prompt"), &[])).unwrap();
        assert_eq!(start["params"]["approvalPolicy"], "never");
        assert_eq!(start["params"]["sandbox"], "danger-full-access");
        assert_eq!(start["params"]["developerInstructions"], "prompt");
        let resume: Value = serde_json::from_str(&thread_resume("i", "th", None)).unwrap();
        assert_eq!(resume["params"]["approvalPolicy"], "never");
        assert_eq!(resume["params"]["sandbox"], "danger-full-access");
        assert!(resume["params"].get("dynamicTools").is_none(), "a resumed thread keeps the tools it started with");
        let init: Value = serde_json::from_str(&initialize("i")).unwrap();
        assert_eq!(init["params"]["capabilities"]["experimentalApi"], true);
    }

    #[test]
    fn every_approval_is_allowed_and_nothing_else_is() {
        for method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] {
            assert_eq!(allow(method, &json!({}), 0), Some(json!({"decision": "accept"})));
        }
        assert_eq!(allow("execCommandApproval", &json!({}), 0), Some(json!({"decision": "approved"})));
        let asked = json!({"permissions": {"network": {"enabled": true}}});
        assert_eq!(
            allow("item/permissions/requestApproval", &asked, 0),
            Some(json!({"permissions": {"network": {"enabled": true}}, "scope": "turn"}))
        );
        assert_eq!(allow("mcpServer/elicitation/request", &json!({}), 0), Some(json!({"action": "accept", "content": null})));
        assert_eq!(allow("currentTime/read", &json!({}), 7), Some(json!({"currentTimeAt": 7})));
        assert_eq!(allow("item/tool/requestUserInput", &json!({}), 0), None);
        assert_eq!(allow("account/chatgptAuthTokens/refresh", &json!({}), 0), None);
    }

    #[test]
    fn lines_are_single_lines() {
        assert!(!thread_start("i", Some("a\nprompt"), &[]).contains('\n'));
        assert!(!tool_answer(&json!(1), "two\nlines", true).contains('\n'));
    }

    #[test]
    fn usage_counts_what_each_total_adds_and_nothing_twice() {
        let mut sum = [0; 4];
        let first = counts(&json!({"inputTokens": 11, "cachedInputTokens": 3, "cacheWriteInputTokens": 1, "outputTokens": 7}));
        consumed(&mut sum, &[0; 4], &first);
        consumed(&mut sum, &first, &first);
        let second = counts(&json!({"inputTokens": 16, "cachedInputTokens": 3, "cacheWriteInputTokens": 1, "outputTokens": 9}));
        consumed(&mut sum, &first, &second);
        consumed(&mut sum, &second, &[0, 0, 0, 0]);
        assert_eq!(usage(&sum), json!({"input_tokens": 16, "output_tokens": 9, "cache_read_tokens": 3, "cache_write_tokens": 1}));
    }
}
