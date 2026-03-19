#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;
use bindings::cyfr::secrets::read as secrets;
use serde_json::{json, Value};

// ─────────────────────────────────────────────────────────────────────────────
// Component entry point
// ─────────────────────────────────────────────────────────────────────────────

struct Component;
bindings::export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(input: String) -> String {
        match handle(&input) {
            Ok(v) => v.to_string(),
            Err(e) => json!({"error": e}).to_string(),
        }
    }
}

fn handle(input: &str) -> Result<Value, String> {
    let req: Value = serde_json::from_str(input)
        .map_err(|e| format!("Invalid JSON input: {e}"))?;

    let operation = req
        .get("operation")
        .and_then(|v| v.as_str())
        .ok_or("Missing required field: 'operation'")?;

    let params = req.get("params").cloned().unwrap_or(json!({}));

    // Obtain an OAuth 2.0 access token before every call.
    // WASM instances are ephemeral (one invocation = one instance), so there is
    // no long-lived in-process cache.  We fetch a fresh token each time, which
    // is safe because refresh-token → access-token round-trips are cheap and
    // the resulting token has a 1-hour TTL on Google's side.
    let access_token = get_access_token()?;

    match operation {
        "list_messages"  => list_messages(&access_token, &params),
        "get_message"    => get_message(&access_token, &params),
        "send_message"   => send_message(&access_token, &params),
        "list_labels"    => list_labels(&access_token),
        "get_profile"    => get_profile(&access_token),
        other => Err(format!(
            "Unknown operation '{}'. Valid operations: list_messages, get_message, \
             send_message, list_labels, get_profile",
            other
        )),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// OAuth 2.0 — exchange refresh token for access token
// ─────────────────────────────────────────────────────────────────────────────

fn get_access_token() -> Result<String, String> {
    let client_id = secrets::get("GMAIL_CLIENT_ID")
        .map_err(|e| format!("Secret error (GMAIL_CLIENT_ID): {e}"))?;
    let client_secret = secrets::get("GMAIL_CLIENT_SECRET")
        .map_err(|e| format!("Secret error (GMAIL_CLIENT_SECRET): {e}"))?;
    let refresh_token = secrets::get("GMAIL_REFRESH_TOKEN")
        .map_err(|e| format!("Secret error (GMAIL_REFRESH_TOKEN): {e}"))?;

    let body = format!(
        "grant_type=refresh_token&client_id={}&client_secret={}&refresh_token={}",
        url_encode(&client_id),
        url_encode(&client_secret),
        url_encode(&refresh_token),
    );

    let req = json!({
        "method": "POST",
        "url": "https://oauth2.googleapis.com/token",
        "headers": {
            "Content-Type": "application/x-www-form-urlencoded"
        },
        "body": body
    });

    let raw = fetch::request(&req.to_string());
    let resp: Value = serde_json::from_str(&raw)
        .map_err(|e| format!("Failed to parse token response: {e}"))?;

    if let Some(err) = resp.get("error") {
        // HTTP-level error from the host
        let msg = err.get("message").and_then(|v| v.as_str()).unwrap_or("unknown");
        return Err(format!("HTTP error fetching token: {msg}"));
    }

    let status = resp.get("status").and_then(|v| v.as_u64()).unwrap_or(0);
    let body_str = resp.get("body").and_then(|v| v.as_str()).unwrap_or("");
    let body_json: Value = serde_json::from_str(body_str).unwrap_or(json!({}));

    if status != 200 {
        let error = body_json
            .get("error_description")
            .or_else(|| body_json.get("error"))
            .and_then(|v| v.as_str())
            .unwrap_or("OAuth token exchange failed");
        return Err(format!("Token exchange error (HTTP {status}): {error}"));
    }

    body_json
        .get("access_token")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| "Token response missing 'access_token'".to_string())
}

// ─────────────────────────────────────────────────────────────────────────────
// Gmail API helpers
// ─────────────────────────────────────────────────────────────────────────────

const GMAIL_BASE: &str = "https://gmail.googleapis.com/gmail/v1/users/me";

/// Perform a GET request to the Gmail API, returning the parsed response body.
/// Automatically surfaces API-level errors with descriptive messages.
fn gmail_get(token: &str, path: &str) -> Result<Value, String> {
    let url = format!("{}{}", GMAIL_BASE, path);
    let req = json!({
        "method": "GET",
        "url": url,
        "headers": {
            "Authorization": format!("Bearer {}", token),
            "Accept": "application/json"
        }
    });

    let raw = fetch::request(&req.to_string());
    parse_gmail_response(&raw)
}

/// Perform a POST request to the Gmail API with a JSON body.
fn gmail_post(token: &str, path: &str, payload: &Value) -> Result<Value, String> {
    let url = format!("{}{}", GMAIL_BASE, path);
    let req = json!({
        "method": "POST",
        "url": url,
        "headers": {
            "Authorization": format!("Bearer {}", token),
            "Content-Type": "application/json",
            "Accept": "application/json"
        },
        "body": payload.to_string()
    });

    let raw = fetch::request(&req.to_string());
    parse_gmail_response(&raw)
}

/// Parse a raw fetch response, surfacing both host-level and API-level errors.
fn parse_gmail_response(raw: &str) -> Result<Value, String> {
    let resp: Value = serde_json::from_str(raw)
        .map_err(|e| format!("Failed to parse Gmail response: {e}"))?;

    // Host-level error (domain blocked, timeout, etc.)
    if let Some(err) = resp.get("error") {
        if resp.get("status").is_none() {
            // This is a host-generated error object, not a Google API error body
            let t = err.get("type").and_then(|v| v.as_str()).unwrap_or("unknown");
            let msg = err.get("message").and_then(|v| v.as_str()).unwrap_or("unknown");
            return Err(format!("HTTP host error [{t}]: {msg}"));
        }
    }

    let status = resp.get("status").and_then(|v| v.as_u64()).unwrap_or(0);
    let body_str = resp.get("body").and_then(|v| v.as_str()).unwrap_or("{}");
    let body: Value = serde_json::from_str(body_str).unwrap_or(json!({}));

    if status < 200 || status >= 300 {
        // Parse Google's error format: { "error": { "code": N, "message": "..." } }
        let api_msg = body
            .get("error")
            .and_then(|e| e.get("message"))
            .and_then(|v| v.as_str())
            .unwrap_or("Gmail API error");
        return Err(format!("Gmail API error (HTTP {status}): {api_msg}"));
    }

    Ok(body)
}

// ─────────────────────────────────────────────────────────────────────────────
// Operation: list_messages
// ─────────────────────────────────────────────────────────────────────────────

fn list_messages(token: &str, params: &Value) -> Result<Value, String> {
    let query       = params.get("query").and_then(|v| v.as_str()).unwrap_or("");
    let max_results = params.get("max_results").and_then(|v| v.as_u64()).unwrap_or(20);
    let max_results = max_results.min(500); // Gmail API cap

    // Build query string
    let mut qs = format!("?maxResults={}", max_results);
    if !query.is_empty() {
        qs.push_str(&format!("&q={}", url_encode(query)));
    }
    if let Some(labels) = params.get("label_ids").and_then(|v| v.as_array()) {
        for label in labels {
            if let Some(l) = label.as_str() {
                qs.push_str(&format!("&labelIds={}", url_encode(l)));
            }
        }
    }

    let list_body = gmail_get(token, &format!("/messages{}", qs))?;

    // The list endpoint only returns {id, threadId} pairs.
    // Fetch metadata (snippet + headers) for each message using a minimal format
    // request so we avoid N full-body fetches.
    let messages_raw = list_body
        .get("messages")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    let result_size_estimate = list_body
        .get("resultSizeEstimate")
        .and_then(|v| v.as_u64())
        .unwrap_or(messages_raw.len() as u64);

    let mut messages = Vec::new();
    for msg in &messages_raw {
        let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("");
        if id.is_empty() { continue; }

        // Fetch metadata format — fast, includes headers + snippet but not body
        match gmail_get(token, &format!("/messages/{}?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date", id)) {
            Ok(meta) => messages.push(extract_message_summary(&meta)),
            Err(_) => {
                // On error include the bare id so callers can retry individually
                messages.push(json!({ "id": id, "thread_id": msg.get("threadId").and_then(|v| v.as_str()).unwrap_or("") }));
            }
        }
    }

    Ok(json!({
        "status": 200,
        "data": {
            "messages": messages,
            "result_size_estimate": result_size_estimate,
            "next_page_token": list_body.get("nextPageToken")
        }
    }))
}

/// Pull the key display fields out of a Gmail message resource.
fn extract_message_summary(msg: &Value) -> Value {
    let id        = str_field(msg, "id");
    let thread_id = str_field(msg, "threadId");
    let snippet   = str_field(msg, "snippet");
    let label_ids = msg.get("labelIds").cloned().unwrap_or(json!([]));

    let headers   = extract_headers(msg);
    let subject   = headers.get("subject").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let from      = headers.get("from").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let date      = headers.get("date").and_then(|v| v.as_str()).unwrap_or("").to_string();

    json!({
        "id": id,
        "thread_id": thread_id,
        "snippet": snippet,
        "subject": subject,
        "from": from,
        "date": date,
        "label_ids": label_ids
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Operation: get_message
// ─────────────────────────────────────────────────────────────────────────────

fn get_message(token: &str, params: &Value) -> Result<Value, String> {
    let message_id = params
        .get("message_id")
        .and_then(|v| v.as_str())
        .ok_or("Missing required param: 'message_id'")?;

    let format = params
        .get("format")
        .and_then(|v| v.as_str())
        .unwrap_or("full");

    // Validate format value
    let format = match format {
        "full" | "metadata" | "minimal" => format,
        other => return Err(format!(
            "Invalid format '{}'. Valid values: full, metadata, minimal", other
        )),
    };

    let path = format!("/messages/{}?format={}", message_id, format);
    let msg = gmail_get(token, &path)?;

    let id        = str_field(&msg, "id");
    let thread_id = str_field(&msg, "threadId");
    let snippet   = str_field(&msg, "snippet");
    let label_ids = msg.get("labelIds").cloned().unwrap_or(json!([]));
    let size      = msg.get("sizeEstimate").and_then(|v| v.as_u64()).unwrap_or(0);

    let headers = extract_headers(&msg);
    let subject  = hdr(&headers, "subject");
    let from     = hdr(&headers, "from");
    let to       = hdr(&headers, "to");
    let cc       = hdr(&headers, "cc");
    let bcc      = hdr(&headers, "bcc");
    let date     = hdr(&headers, "date");

    // Decode body — only available for "full" format
    let body = if format == "full" {
        let payload = msg.get("payload").cloned().unwrap_or(json!({}));
        extract_body_text(&payload)
    } else {
        String::new()
    };

    Ok(json!({
        "status": 200,
        "data": {
            "id": id,
            "thread_id": thread_id,
            "snippet": snippet,
            "label_ids": label_ids,
            "size_estimate": size,
            "subject": subject,
            "from": from,
            "to": to,
            "cc": cc,
            "bcc": bcc,
            "date": date,
            "body": body,
            "format": format
        }
    }))
}

/// Recursively walk a Gmail message payload tree to find and decode a text body.
/// Prefers text/plain, falls back to text/html.
fn extract_body_text(payload: &Value) -> String {
    let mime = payload
        .get("mimeType")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    // Direct body part
    if mime == "text/plain" || mime == "text/html" {
        if let Some(data) = payload
            .get("body")
            .and_then(|b| b.get("data"))
            .and_then(|d| d.as_str())
        {
            return base64url_decode(data);
        }
    }

    // Multipart — search parts, prefer plain
    if let Some(parts) = payload.get("parts").and_then(|v| v.as_array()) {
        let mut html_fallback = String::new();
        for part in parts {
            let part_mime = part
                .get("mimeType")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if part_mime == "text/plain" {
                let text = extract_body_text(part);
                if !text.is_empty() {
                    return text;
                }
            } else if part_mime == "text/html" {
                let text = extract_body_text(part);
                if !text.is_empty() && html_fallback.is_empty() {
                    html_fallback = text;
                }
            } else if part_mime.starts_with("multipart/") {
                let text = extract_body_text(part);
                if !text.is_empty() {
                    return text;
                }
            }
        }
        if !html_fallback.is_empty() {
            return html_fallback;
        }
    }

    String::new()
}

// ─────────────────────────────────────────────────────────────────────────────
// Operation: send_message
// ─────────────────────────────────────────────────────────────────────────────

fn send_message(token: &str, params: &Value) -> Result<Value, String> {
    let to = params
        .get("to")
        .and_then(|v| v.as_str())
        .ok_or("Missing required param: 'to'")?;
    let subject = params
        .get("subject")
        .and_then(|v| v.as_str())
        .ok_or("Missing required param: 'subject'")?;
    let body = params
        .get("body")
        .and_then(|v| v.as_str())
        .ok_or("Missing required param: 'body'")?;
    let cc  = params.get("cc").and_then(|v| v.as_str()).unwrap_or("");
    let bcc = params.get("bcc").and_then(|v| v.as_str()).unwrap_or("");

    // Build a minimal RFC 2822 message
    let mut rfc2822 = String::new();
    rfc2822.push_str(&format!("To: {}\r\n", to));
    if !cc.is_empty()  { rfc2822.push_str(&format!("Cc: {}\r\n", cc)); }
    if !bcc.is_empty() { rfc2822.push_str(&format!("Bcc: {}\r\n", bcc)); }
    rfc2822.push_str(&format!("Subject: {}\r\n", subject));
    rfc2822.push_str("MIME-Version: 1.0\r\n");
    rfc2822.push_str("Content-Type: text/plain; charset=UTF-8\r\n");
    rfc2822.push_str("Content-Transfer-Encoding: 7bit\r\n");
    rfc2822.push_str("\r\n");
    rfc2822.push_str(body);

    // Base64url-encode the raw message
    let encoded = base64url_encode(rfc2822.as_bytes());

    let payload = json!({ "raw": encoded });
    let result  = gmail_post(token, "/messages/send", &payload)?;

    Ok(json!({
        "status": 200,
        "data": {
            "id":        result.get("id").and_then(|v| v.as_str()).unwrap_or(""),
            "thread_id": result.get("threadId").and_then(|v| v.as_str()).unwrap_or(""),
            "label_ids": result.get("labelIds").cloned().unwrap_or(json!([]))
        }
    }))
}

// ─────────────────────────────────────────────────────────────────────────────
// Operation: list_labels
// ─────────────────────────────────────────────────────────────────────────────

fn list_labels(token: &str) -> Result<Value, String> {
    let body = gmail_get(token, "/labels")?;

    let labels: Vec<Value> = body
        .get("labels")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|l| json!({
            "id":   l.get("id").and_then(|v| v.as_str()).unwrap_or(""),
            "name": l.get("name").and_then(|v| v.as_str()).unwrap_or(""),
            "type": l.get("type").and_then(|v| v.as_str()).unwrap_or("user")
        }))
        .collect();

    Ok(json!({
        "status": 200,
        "data": { "labels": labels }
    }))
}

// ─────────────────────────────────────────────────────────────────────────────
// Operation: get_profile
// ─────────────────────────────────────────────────────────────────────────────

fn get_profile(token: &str) -> Result<Value, String> {
    let body = gmail_get(token, "/profile")?;

    Ok(json!({
        "status": 200,
        "data": {
            "email_address":   body.get("emailAddress").and_then(|v| v.as_str()).unwrap_or(""),
            "messages_total":  body.get("messagesTotal").and_then(|v| v.as_u64()).unwrap_or(0),
            "threads_total":   body.get("threadsTotal").and_then(|v| v.as_u64()).unwrap_or(0),
            "history_id":      body.get("historyId").and_then(|v| v.as_str()).unwrap_or("")
        }
    }))
}

// ─────────────────────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────────────────────

/// Extract the payload.headers array into a flat lowercase-key map.
fn extract_headers(msg: &Value) -> Value {
    let mut map = serde_json::Map::new();
    let headers = msg
        .get("payload")
        .and_then(|p| p.get("headers"))
        .and_then(|h| h.as_array());

    if let Some(hdrs) = headers {
        for h in hdrs {
            let name  = h.get("name").and_then(|v| v.as_str()).unwrap_or("").to_lowercase();
            let value = h.get("value").and_then(|v| v.as_str()).unwrap_or("").to_string();
            map.insert(name, json!(value));
        }
    }
    Value::Object(map)
}

/// Convenience: get a string from a JSON object or return empty string.
fn str_field<'a>(v: &'a Value, key: &str) -> String {
    v.get(key).and_then(|f| f.as_str()).unwrap_or("").to_string()
}

/// Convenience: get a header value from the extracted headers map.
fn hdr(headers: &Value, name: &str) -> String {
    headers.get(name).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

// ─── Base64url codec (pure Rust, no external crates) ─────────────────────────

const BASE64URL: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Encode bytes to base64url (no padding), as required by Gmail's raw message API.
fn base64url_encode(data: &[u8]) -> String {
    let mut out = String::with_capacity((data.len() * 4 + 2) / 3);
    let mut i = 0;
    while i < data.len() {
        let b0 = data[i] as u32;
        let b1 = if i + 1 < data.len() { data[i + 1] as u32 } else { 0 };
        let b2 = if i + 2 < data.len() { data[i + 2] as u32 } else { 0 };

        out.push(BASE64URL[((b0 >> 2) & 0x3F) as usize] as char);
        out.push(BASE64URL[((b0 << 4 | b1 >> 4) & 0x3F) as usize] as char);
        if i + 1 < data.len() {
            out.push(BASE64URL[((b1 << 2 | b2 >> 6) & 0x3F) as usize] as char);
        }
        if i + 2 < data.len() {
            out.push(BASE64URL[(b2 & 0x3F) as usize] as char);
        }
        i += 3;
    }
    out
}

/// Decode a base64url string (with or without padding) to a UTF-8 String.
/// Invalid characters are skipped; invalid UTF-8 is replaced with U+FFFD.
fn base64url_decode(input: &str) -> String {
    // Build a reverse lookup table
    let mut table = [0xFFu8; 256];
    for (i, &c) in BASE64URL.iter().enumerate() {
        table[c as usize] = i as u8;
    }
    // Also accept standard base64 '+' and '/'
    table[b'+' as usize] = 62;
    table[b'/' as usize] = 63;

    // Strip whitespace and padding
    let clean: Vec<u8> = input
        .bytes()
        .filter(|&b| b != b'=' && b != b'\n' && b != b'\r' && b != b' ')
        .collect();

    let mut bytes = Vec::with_capacity(clean.len() * 3 / 4);
    let mut i = 0;
    while i + 1 < clean.len() {
        let c0 = table[clean[i] as usize];
        let c1 = table[clean[i + 1] as usize];
        if c0 == 0xFF || c1 == 0xFF { i += 1; continue; }

        bytes.push((c0 << 2) | (c1 >> 4));

        if i + 2 < clean.len() {
            let c2 = table[clean[i + 2] as usize];
            if c2 != 0xFF {
                bytes.push((c1 << 4) | (c2 >> 2));
            }
            if i + 3 < clean.len() {
                let c3 = table[clean[i + 3] as usize];
                if c3 != 0xFF {
                    bytes.push((c2 << 6) | c3);
                }
            }
        }
        i += 4;
    }

    String::from_utf8_lossy(&bytes).into_owned()
}

// ─── URL-percent encoding ────────────────────────────────────────────────────

/// Percent-encode a string for use in a URL query parameter value.
/// Encodes everything except unreserved chars: A-Z a-z 0-9 - _ . ~
fn url_encode(input: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9'
            | b'-' | b'_' | b'.' | b'~' => out.push(byte as char),
            b => {
                out.push('%');
                out.push(HEX[(b >> 4) as usize] as char);
                out.push(HEX[(b & 0x0F) as usize] as char);
            }
        }
    }
    out
}
