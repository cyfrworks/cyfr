#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::formula::run::Guest;
use bindings::cyfr::formula::invoke;
use serde_json::{json, Value};

struct Component;
bindings::export!(Component with_types_in bindings);

// ── Constants ────────────────────────────────────────────────────────────────

const GMAIL_REF: &str = "catalyst:moonmoon69.gmail:0.1.1";
const CLAUDE_REF: &str = "catalyst:moonmoon69.claude:1.0.0";
const AIRTABLE_REF: &str = "catalyst:moonmoon69.airtable:0.1.0";

const CLAUDE_SYSTEM_PROMPT: &str = r#"You are a financial email categorizer. Given an email subject, sender, and body snippet, extract:
1. asset_symbols: array of stock tickers (AAPL, TSLA), crypto (BTC, ETH), or indices (SPY, QQQ) mentioned. Empty array [] if none.
2. category: one of "Earnings", "Market News", "Alert", "Newsletter", "Other"
3. summary: 1-2 sentence summary of the email content

CRITICAL: asset_symbols must be plain uppercase strings with NO quotes inside the array, NO special characters, letters and numbers only. Example: ["AAPL", "BTC"] not ["\"AAPL\""].

Respond with ONLY valid JSON, no prose: {"asset_symbols": ["AAPL", "BTC"], "category": "Market News", "summary": "..."}"#;

// ── Entry point ───────────────────────────────────────────────────────────────

impl Guest for Component {
    fn run(input: String) -> String {
        match handle_request(&input) {
            Ok(output) => output,
            Err(e) => json!({"error": e}).to_string(),
        }
    }
}

// ── Top-level orchestration ───────────────────────────────────────────────────

fn handle_request(input: &str) -> Result<String, String> {
    let parsed: Value = serde_json::from_str(input)
        .map_err(|e| format!("Invalid JSON input: {e}"))?;

    let base_id = parsed["airtable_base_id"]
        .as_str()
        .ok_or("Missing airtable_base_id")?
        .to_string();
    let table_name = parsed["airtable_table"]
        .as_str()
        .ok_or("Missing airtable_table")?
        .to_string();
    let gmail_query = parsed["gmail_query"]
        .as_str()
        .unwrap_or("newer_than:1h")
        .to_string();
    let max_results = parsed["max_results"].as_u64().unwrap_or(50) as usize;

    let mut errors: Vec<String> = Vec::new();

    // Step 1: Ensure Airtable table exists — returns the table ID (tblXXX)
    let table_id = ensure_table_exists(&base_id, &table_name, &mut errors)?;

    // Step 2: Fetch email list from Gmail
    let message_ids = fetch_gmail_message_ids(&gmail_query, max_results, &mut errors)?;

    if message_ids.is_empty() {
        return Ok(json!({
            "processed": 0,
            "upserted": 0,
            "errors": errors
        })
        .to_string());
    }

    // Step 3: Fetch full message details (parallel, batches of 5)
    let emails = fetch_gmail_messages(&message_ids, &mut errors);

    let processed = emails.len();

    // Step 4: Categorize each email with Claude
    let records = categorize_emails(&emails, &mut errors);

    // Step 5: Upsert into Airtable in chunks of 10 (use table ID, not name)
    let upserted = upsert_to_airtable(&base_id, &table_id, &records, &mut errors);

    Ok(json!({
        "processed": processed,
        "upserted": upserted,
        "errors": errors
    })
    .to_string())
}

// ── Step 1: Ensure Airtable table exists ─────────────────────────────────────

fn ensure_table_exists(
    base_id: &str,
    table_name: &str,
    errors: &mut Vec<String>,
) -> Result<String, String> {
    // List tables in base
    let resp_str = invoke::call(
        &json!({
            "tool": "execution",
            "action": "run",
            "args": {
                "reference": AIRTABLE_REF,
                "type": "catalyst",
                "input": {
                    "operation": "tables.list",
                    "params": { "baseId": base_id }
                }
            }
        })
        .to_string(),
    );

    let resp: Value = serde_json::from_str(&resp_str)
        .map_err(|e| format!("tables.list parse error: {e}"))?;

    let data = parse_catalyst_output(&resp)?;

    // Check if table already exists — return its ID if so
    if let Some(tables) = data.get("tables").and_then(|t| t.as_array()) {
        for table in tables {
            if table.get("name").and_then(|n| n.as_str()) == Some(table_name) {
                if let Some(id) = table.get("id").and_then(|i| i.as_str()) {
                    return Ok(id.to_string());
                }
            }
        }
    }

    // Table doesn't exist — create it and return its ID
    create_email_digest_table(base_id, table_name, errors)
}

fn create_email_digest_table(
    base_id: &str,
    table_name: &str,
    _errors: &mut Vec<String>,
) -> Result<String, String> {
    let resp_str = invoke::call(
        &json!({
            "tool": "execution",
            "action": "run",
            "args": {
                "reference": AIRTABLE_REF,
                "type": "catalyst",
                "input": {
                    "operation": "tables.create",
                    "params": {
                        "baseId": base_id,
                        "name": table_name,
                        "fields": [
                            {
                                "name": "Email ID",
                                "type": "singleLineText"
                            },
                            {
                                "name": "Received At",
                                "type": "dateTime",
                                "options": {
                                    "dateFormat": { "name": "iso" },
                                    "timeFormat": { "name": "24hour" },
                                    "timeZone": "utc"
                                }
                            },
                            {
                                "name": "From",
                                "type": "singleLineText"
                            },
                            {
                                "name": "Subject",
                                "type": "singleLineText"
                            },
                            {
                                "name": "Asset Symbols",
                                "type": "multilineText"
                            },
                            {
                                "name": "Category",
                                "type": "singleSelect",
                                "options": {
                                    "choices": [
                                        { "name": "Earnings" },
                                        { "name": "Market News" },
                                        { "name": "Alert" },
                                        { "name": "Newsletter" },
                                        { "name": "Other" }
                                    ]
                                }
                            },
                            {
                                "name": "Summary",
                                "type": "multilineText"
                            },
                            {
                                "name": "Raw Snippet",
                                "type": "multilineText"
                            }
                        ]
                    }
                }
            }
        })
        .to_string(),
    );

    let resp: Value = serde_json::from_str(&resp_str)
        .map_err(|e| format!("tables.create parse error: {e}"))?;

    let data = parse_catalyst_output(&resp)?;

    // Airtable returns the new table object with an "id" field (e.g. "tblXXXXXXXXXXXXXX")
    data.get("id")
        .and_then(|i| i.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| "tables.create response missing table id".to_string())
}

// ── Step 2: Fetch Gmail message IDs ──────────────────────────────────────────

fn fetch_gmail_message_ids(
    query: &str,
    max_results: usize,
    errors: &mut Vec<String>,
) -> Result<Vec<String>, String> {
    let mut all_ids: Vec<String> = Vec::new();
    let mut page_token: Option<String> = None;

    loop {
        let mut params = json!({
            "q": query,
            "max_results": max_results.min(500)
        });

        if let Some(ref token) = page_token {
            params["pageToken"] = json!(token);
        }

        let resp_str = invoke::call(
            &json!({
                "tool": "execution",
                "action": "run",
                "args": {
                    "reference": GMAIL_REF,
                    "type": "catalyst",
                    "input": {
                        "operation": "list_messages",
                        "params": params
                    }
                }
            })
            .to_string(),
        );

        let resp: Value = serde_json::from_str(&resp_str)
            .map_err(|e| format!("list_messages parse error: {e}"))?;

        let data = match parse_catalyst_output(&resp) {
            Ok(d) => d,
            Err(e) => {
                errors.push(format!("Gmail list_messages error: {e}"));
                break;
            }
        };

        if let Some(messages) = data.get("messages").and_then(|m| m.as_array()) {
            for msg in messages {
                if let Some(id) = msg.get("id").and_then(|i| i.as_str()) {
                    all_ids.push(id.to_string());
                    if all_ids.len() >= max_results {
                        return Ok(all_ids);
                    }
                }
            }
        }

        // Check for next page
        page_token = data
            .get("nextPageToken")
            .and_then(|t| t.as_str())
            .map(|s| s.to_string());

        if page_token.is_none() {
            break;
        }
    }

    Ok(all_ids)
}

// ── Step 3: Fetch full Gmail messages (parallel batches) ──────────────────────

struct EmailData {
    id: String,
    received_at: String,
    from: String,
    subject: String,
    snippet: String,
    body: String,
}

fn fetch_gmail_messages(message_ids: &[String], errors: &mut Vec<String>) -> Vec<EmailData> {
    let mut emails = Vec::new();

    // Process in parallel batches of 5
    for chunk in message_ids.chunks(5) {
        // Spawn all fetches in the chunk
        let mut task_ids: Vec<String> = Vec::new();
        let mut chunk_ids: Vec<String> = Vec::new();

        for id in chunk {
            let spawn_str = invoke::spawn(
                &json!({
                    "tool": "execution",
                    "action": "run",
                    "args": {
                        "reference": GMAIL_REF,
                        "type": "catalyst",
                        "input": {
                            "operation": "get_message",
                            "params": { "id": id }
                        }
                    }
                })
                .to_string(),
            );

            match serde_json::from_str::<Value>(&spawn_str) {
                Ok(resp) => {
                    if let Some(err) = resp.get("error") {
                        errors.push(format!("Spawn get_message({id}) error: {err}"));
                    } else if let Some(tid) = resp.get("task_id").and_then(|t| t.as_str()) {
                        task_ids.push(tid.to_string());
                        chunk_ids.push(id.clone());
                    }
                }
                Err(e) => errors.push(format!("Spawn parse error for {id}: {e}")),
            }
        }

        if task_ids.is_empty() {
            continue;
        }

        // Await all spawned tasks
        let await_str = invoke::await_all(
            &json!({ "task_ids": task_ids }).to_string(),
        );

        match serde_json::from_str::<Value>(&await_str) {
            Ok(await_resp) => {
                let results = await_resp
                    .get("results")
                    .and_then(|r| r.as_array())
                    .cloned()
                    .unwrap_or_default();

                for (result, msg_id) in results.iter().zip(chunk_ids.iter()) {
                    match parse_catalyst_output(result) {
                        Ok(data) => {
                            if let Some(email) = parse_gmail_message(msg_id, &data) {
                                emails.push(email);
                            } else {
                                errors.push(format!("Failed to parse message data for {msg_id}"));
                            }
                        }
                        Err(e) => errors.push(format!("get_message({msg_id}) failed: {e}")),
                    }
                }
            }
            Err(e) => errors.push(format!("await_all parse error: {e}")),
        }
    }

    emails
}

fn parse_gmail_message(id: &str, data: &Value) -> Option<EmailData> {
    let payload = data.get("payload")?;

    // Extract headers
    let headers = payload.get("headers").and_then(|h| h.as_array());
    let mut from = String::new();
    let mut subject = String::new();
    let mut date = String::new();

    if let Some(hdrs) = headers {
        for hdr in hdrs {
            let name = hdr.get("name").and_then(|n| n.as_str()).unwrap_or("");
            let value = hdr.get("value").and_then(|v| v.as_str()).unwrap_or("");
            match name.to_lowercase().as_str() {
                "from" => from = value.to_string(),
                "subject" => subject = value.to_string(),
                "date" => date = value.to_string(),
                _ => {}
            }
        }
    }

    let snippet = data
        .get("snippet")
        .and_then(|s| s.as_str())
        .unwrap_or("")
        .to_string();

    // Decode body: try parts first, then body.data
    let body = extract_body_text(payload);

    let received_at = parse_email_date(&date);

    // Extract sender email from "Name <email>" format
    let sender_email = extract_email_address(&from);

    Some(EmailData {
        id: id.to_string(),
        received_at,
        from: sender_email,
        subject,
        snippet,
        body,
    })
}

/// Extract plain-text body from Gmail payload (parts or body.data)
fn extract_body_text(payload: &Value) -> String {
    // Try multipart parts first
    if let Some(parts) = payload.get("parts").and_then(|p| p.as_array()) {
        for part in parts {
            let mime = part
                .get("mimeType")
                .and_then(|m| m.as_str())
                .unwrap_or("");
            if mime == "text/plain" {
                if let Some(decoded) = decode_base64_body(part) {
                    return decoded;
                }
            }
        }
        // Fallback: try text/html if no plain text
        for part in parts {
            let mime = part
                .get("mimeType")
                .and_then(|m| m.as_str())
                .unwrap_or("");
            if mime == "text/html" {
                if let Some(decoded) = decode_base64_body(part) {
                    // Strip HTML tags naively
                    return strip_html_tags(&decoded);
                }
            }
        }
        // Recurse into nested multipart
        for part in parts {
            let mime = part
                .get("mimeType")
                .and_then(|m| m.as_str())
                .unwrap_or("");
            if mime.starts_with("multipart/") {
                let nested = extract_body_text(part);
                if !nested.is_empty() {
                    return nested;
                }
            }
        }
    }

    // Fallback to body.data at top level
    if let Some(decoded) = decode_base64_body(payload) {
        return decoded;
    }

    String::new()
}

fn decode_base64_body(part: &Value) -> Option<String> {
    let data_b64 = part
        .get("body")
        .and_then(|b| b.get("data"))
        .and_then(|d| d.as_str())?;

    if data_b64.is_empty() {
        return None;
    }

    // Gmail uses URL-safe base64; convert to standard
    let standard = data_b64.replace('-', "+").replace('_', "/");
    // Decode bytes; if invalid base64 return None rather than panicking
    let bytes = base64_decode(&standard)?;
    // Convert to UTF-8, replacing invalid sequences rather than failing
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

/// Minimal base64 decoder (no external deps needed).
/// Returns None only if input contains characters outside the base64 alphabet.
fn base64_decode(input: &str) -> Option<Vec<u8>> {
    let input = input.trim();
    let table: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    let mut lookup = [255u8; 256];
    for (i, &c) in table.iter().enumerate() {
        lookup[c as usize] = i as u8;
    }

    // Filter padding and whitespace; collect clean bytes
    let input_bytes: Vec<u8> = input
        .bytes()
        .filter(|&b| b != b'=' && b != b'\n' && b != b'\r' && b != b' ')
        .collect();

    let mut output = Vec::with_capacity((input_bytes.len() * 3) / 4 + 3);
    let mut i = 0;

    // Process complete groups of 4
    while i + 4 <= input_bytes.len() {
        let a = lookup[input_bytes[i] as usize];
        let b = lookup[input_bytes[i + 1] as usize];
        let c = lookup[input_bytes[i + 2] as usize];
        let d = lookup[input_bytes[i + 3] as usize];

        if a == 255 || b == 255 {
            return None;
        }

        output.push((a << 2) | (b >> 4));
        if c != 255 {
            output.push((b << 4) | (c >> 2));
        }
        if d != 255 {
            output.push((c << 6) | d);
        }
        i += 4;
    }

    // Handle remaining bytes (1-3 leftover after stripping padding)
    let remaining = input_bytes.len() - i;
    if remaining >= 2 {
        let a = lookup[input_bytes[i] as usize];
        let b = lookup[input_bytes[i + 1] as usize];
        if a != 255 && b != 255 {
            output.push((a << 2) | (b >> 4));
        }
        if remaining >= 3 {
            let c = lookup[input_bytes[i + 2] as usize];
            if c != 255 {
                output.push((b << 4) | (c >> 2));
            }
        }
    }

    Some(output)
}

fn strip_html_tags(html: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => result.push(c),
            _ => {}
        }
    }
    // Collapse excessive whitespace
    result
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Safely truncate a UTF-8 string to at most `max_bytes` bytes without
/// splitting a multi-byte character.
fn truncate_to_char_boundary(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    // Walk back from max_bytes until we're on a char boundary
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Parse RFC 2822 date string to ISO 8601. Falls back to empty string on any
/// parse failure rather than panicking.
fn parse_email_date(date_str: &str) -> String {
    let s = date_str.trim();

    if s.is_empty() {
        return String::new();
    }

    // Already looks like ISO 8601?
    if s.len() >= 10 && s.chars().nth(4) == Some('-') {
        return s.to_string();
    }

    // Try to parse RFC2822-ish format
    // Format: [Weekday,] DD Mon YYYY HH:MM:SS [±HHMM|TZ]
    let parts: Vec<&str> = s.split_whitespace().collect();

    // Skip leading weekday if present ("Mon,")
    let start = if parts.first().map_or(false, |p| p.ends_with(',')) {
        1
    } else {
        0
    };

    // Need at least: day month year time [tz]
    if parts.len() < start + 4 {
        return s.to_string();
    }

    let day: u32 = parts[start].parse().unwrap_or(1);
    let month = month_name_to_num(parts.get(start + 1).copied().unwrap_or(""));
    let year: i32 = parts.get(start + 2).and_then(|p| p.parse().ok()).unwrap_or(2000);
    let time_str = parts.get(start + 3).copied().unwrap_or("00:00:00");
    let tz_str = parts.get(start + 4).copied().unwrap_or("+0000");

    let time_parts: Vec<&str> = time_str.split(':').collect();
    let hour: i64 = time_parts.first().and_then(|t| t.parse().ok()).unwrap_or(0);
    let minute: i64 = time_parts.get(1).and_then(|t| t.parse().ok()).unwrap_or(0);
    let second: i64 = time_parts.get(2).and_then(|t| t.parse().ok()).unwrap_or(0);

    // Parse timezone offset to UTC
    let tz_offset_mins: i64 = parse_tz_offset(tz_str);

    // Build naive UTC time by subtracting offset
    let total_mins = hour * 60 + minute - tz_offset_mins;
    let utc_hour = ((total_mins / 60).rem_euclid(24)) as u32;
    let utc_minute = (total_mins.rem_euclid(60)) as u32;
    let second = second.rem_euclid(60) as u32;

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.000Z",
        year, month, day, utc_hour, utc_minute, second
    )
}

fn month_name_to_num(name: &str) -> u32 {
    match name.to_lowercase().as_str() {
        "jan" | "january" => 1,
        "feb" | "february" => 2,
        "mar" | "march" => 3,
        "apr" | "april" => 4,
        "may" => 5,
        "jun" | "june" => 6,
        "jul" | "july" => 7,
        "aug" | "august" => 8,
        "sep" | "september" => 9,
        "oct" | "october" => 10,
        "nov" | "november" => 11,
        "dec" | "december" => 12,
        _ => 1,
    }
}

fn parse_tz_offset(tz: &str) -> i64 {
    // Handles "+0530", "-0700", "UTC", "GMT", "Z", and named zones
    let tz = tz.trim();
    if tz == "UTC" || tz == "GMT" || tz == "Z" || tz.is_empty() {
        return 0;
    }
    if tz.len() >= 5 {
        let sign: i64 = if tz.starts_with('-') { -1 } else { 1 };
        let digits = &tz[1..]; // everything after sign char
        // Use .get() to avoid panicking on short/malformed strings
        let hh: i64 = digits.get(..2).and_then(|s| s.parse().ok()).unwrap_or(0);
        let mm: i64 = digits.get(2..4).and_then(|s| s.parse().ok()).unwrap_or(0);
        return sign * (hh * 60 + mm);
    }
    0
}

/// Extract bare email address from "Display Name <email@example.com>".
/// Falls back to the full trimmed string if no angle brackets found.
fn extract_email_address(from: &str) -> String {
    if let Some(start) = from.rfind('<') {
        if let Some(end) = from.rfind('>') {
            if start < end {
                let addr = from[start + 1..end].trim().to_string();
                if !addr.is_empty() {
                    return addr;
                }
            }
        }
    }
    from.trim().to_string()
}

// ── Step 4: Categorize emails with Claude ────────────────────────────────────

struct CategorizedEmail {
    email_id: String,
    received_at: String,
    from: String,
    subject: String,
    snippet: String,
    asset_symbols: Vec<String>,
    category: String,
    summary: String,
}

fn categorize_emails(emails: &[EmailData], errors: &mut Vec<String>) -> Vec<CategorizedEmail> {
    let mut results = Vec::new();

    // Spawn Claude calls in parallel (batches of 5)
    for chunk in emails.chunks(5) {
        let mut task_ids: Vec<String> = Vec::new();
        let mut chunk_indices: Vec<usize> = Vec::new();

        for (i, email) in chunk.iter().enumerate() {
            // Safe UTF-8 truncation — avoids panic on multi-byte characters
            let body_preview = truncate_to_char_boundary(&email.body, 500);

            let user_message = format!(
                "Subject: {}\nFrom: {}\nSnippet: {}\nBody preview: {}",
                email.subject, email.from, email.snippet, body_preview
            );

            let spawn_str = invoke::spawn(
                &json!({
                    "tool": "execution",
                    "action": "run",
                    "args": {
                        "reference": CLAUDE_REF,
                        "type": "catalyst",
                        "input": {
                            "operation": "messages.create",
                            "params": {
                                "model": "claude-haiku-4-5",
                                "max_tokens": 256,
                                "system": CLAUDE_SYSTEM_PROMPT,
                                "messages": [
                                    {
                                        "role": "user",
                                        "content": user_message
                                    }
                                ]
                            }
                        }
                    }
                })
                .to_string(),
            );

            match serde_json::from_str::<Value>(&spawn_str) {
                Ok(resp) => {
                    if let Some(err) = resp.get("error") {
                        errors.push(format!("Spawn Claude for {}: {err}", email.id));
                    } else if let Some(tid) = resp.get("task_id").and_then(|t| t.as_str()) {
                        task_ids.push(tid.to_string());
                        chunk_indices.push(i);
                    }
                }
                Err(e) => errors.push(format!("Spawn Claude parse error for {}: {e}", email.id)),
            }
        }

        if task_ids.is_empty() {
            continue;
        }

        // Await all Claude responses
        let await_str =
            invoke::await_all(&json!({ "task_ids": task_ids }).to_string());

        match serde_json::from_str::<Value>(&await_str) {
            Ok(await_resp) => {
                let claude_results = await_resp
                    .get("results")
                    .and_then(|r| r.as_array())
                    .cloned()
                    .unwrap_or_default();

                for (result, &idx) in claude_results.iter().zip(chunk_indices.iter()) {
                    // Guard: idx must be in bounds for this chunk
                    let email = match chunk.get(idx) {
                        Some(e) => e,
                        None => {
                            errors.push(format!("Chunk index {idx} out of bounds"));
                            continue;
                        }
                    };

                    match parse_catalyst_output(result) {
                        Ok(data) => {
                            match parse_claude_response(&data) {
                                Ok((asset_symbols, category, summary)) => {
                                    results.push(CategorizedEmail {
                                        email_id: email.id.clone(),
                                        received_at: email.received_at.clone(),
                                        from: email.from.clone(),
                                        subject: email.subject.clone(),
                                        snippet: email.snippet.clone(),
                                        asset_symbols,
                                        category,
                                        summary,
                                    });
                                }
                                Err(e) => {
                                    errors.push(format!(
                                        "Claude parse failed for {}: {e}",
                                        email.id
                                    ));
                                    // Still include email with defaults
                                    results.push(CategorizedEmail {
                                        email_id: email.id.clone(),
                                        received_at: email.received_at.clone(),
                                        from: email.from.clone(),
                                        subject: email.subject.clone(),
                                        snippet: email.snippet.clone(),
                                        asset_symbols: vec![],
                                        category: "Other".to_string(),
                                        summary: email.snippet.clone(),
                                    });
                                }
                            }
                        }
                        Err(e) => {
                            errors.push(format!("Claude catalyst error for {}: {e}", email.id));
                            // Include with defaults rather than skip
                            results.push(CategorizedEmail {
                                email_id: email.id.clone(),
                                received_at: email.received_at.clone(),
                                from: email.from.clone(),
                                subject: email.subject.clone(),
                                snippet: email.snippet.clone(),
                                asset_symbols: vec![],
                                category: "Other".to_string(),
                                summary: email.snippet.clone(),
                            });
                        }
                    }
                }
            }
            Err(e) => errors.push(format!("await_all Claude parse error: {e}")),
        }
    }

    results
}

fn parse_claude_response(data: &Value) -> Result<(Vec<String>, String, String), String> {
    // Claude response: data.content[0].text = JSON string
    let text = data
        .get("content")
        .and_then(|c| c.as_array())
        .and_then(|arr| arr.first())
        .and_then(|item| item.get("text"))
        .and_then(|t| t.as_str())
        .ok_or_else(|| "No text content in Claude response".to_string())?;

    // Strip markdown code fences if present
    let json_str = text
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();

    // Try to find JSON object boundaries in case there's surrounding prose
    let json_str = find_json_object(json_str).unwrap_or(json_str);

    let parsed: Value = serde_json::from_str(json_str)
        .map_err(|e| format!("Claude JSON parse error: {e} — raw: {json_str}"))?;

    let asset_symbols: Vec<String> = parsed
        .get("asset_symbols")
        .and_then(|a| a.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| {
                    let raw = match v.as_str() {
                        Some(s) => s.to_string(),
                        None => return None,
                    };
                    // Strip ALL non-alphanumeric characters (quotes, backslashes,
                    // spaces, etc.) — keep only A-Z, a-z, 0-9.
                    // This handles cases like `"\"ONDS\""` → `ONDS`
                    let cleaned: String = raw
                        .chars()
                        .filter(|c| c.is_ascii_alphanumeric())
                        .collect::<String>()
                        .to_uppercase();
                    if cleaned.is_empty() {
                        None
                    } else {
                        Some(cleaned)
                    }
                })
                .collect()
        })
        .unwrap_or_default();

    let valid_categories = ["Earnings", "Market News", "Alert", "Newsletter", "Other"];
    let category = parsed
        .get("category")
        .and_then(|c| c.as_str())
        .filter(|c| valid_categories.contains(c))
        .unwrap_or("Other")
        .to_string();

    let summary = parsed
        .get("summary")
        .and_then(|s| s.as_str())
        .unwrap_or("")
        .to_string();

    Ok((asset_symbols, category, summary))
}

/// Try to extract the first JSON object `{...}` from a string that may have
/// surrounding text. Returns None if no balanced braces found.
fn find_json_object(s: &str) -> Option<&str> {
    let start = s.find('{')?;
    let mut depth = 0usize;
    let mut in_string = false;
    let mut escape_next = false;

    for (i, c) in s[start..].char_indices() {
        if escape_next {
            escape_next = false;
            continue;
        }
        match c {
            '\\' if in_string => escape_next = true,
            '"' => in_string = !in_string,
            '{' if !in_string => depth += 1,
            '}' if !in_string => {
                depth -= 1;
                if depth == 0 {
                    return Some(&s[start..start + i + 1]);
                }
            }
            _ => {}
        }
    }
    None
}

// ── Step 5: Upsert to Airtable ───────────────────────────────────────────────

fn upsert_to_airtable(
    base_id: &str,
    table_id: &str,   // Use table ID (tblXXX), not name — avoids URL encoding issues
    records: &[CategorizedEmail],
    errors: &mut Vec<String>,
) -> usize {
    let mut total_upserted = 0;

    // Chunk into batches of 10 (Airtable max per call)
    for chunk in records.chunks(10) {
        let airtable_records: Vec<Value> = chunk
            .iter()
            .map(|email| {
                // Asset Symbols stored as comma-separated string for multilineText.
                let symbols = email.asset_symbols.join(", ");

                json!({
                    "fields": {
                        "Email ID": email.email_id,
                        "Received At": email.received_at,
                        "From": email.from,
                        "Subject": email.subject,
                        "Asset Symbols": symbols,
                        "Category": email.category,
                        "Summary": email.summary,
                        "Raw Snippet": email.snippet
                    }
                })
            })
            .collect();

        let resp_str = invoke::call(
            &json!({
                "tool": "execution",
                "action": "run",
                "args": {
                    "reference": AIRTABLE_REF,
                    "type": "catalyst",
                    "input": {
                        "operation": "records.update_multi",
                        "params": {
                            "baseId": base_id,
                            "tableId": table_id,
                            "typecast": true,
                            "records": airtable_records,
                            "performUpsert": {
                                "fieldsToMergeOn": ["Email ID"]
                            }
                        }
                    }
                }
            })
            .to_string(),
        );

        match serde_json::from_str::<Value>(&resp_str) {
            Ok(resp) => match parse_catalyst_output(&resp) {
                Ok(data) => {
                    // Count upserted: created + updated records
                    let created = data
                        .get("createdRecords")
                        .and_then(|c| c.as_array())
                        .map(|a| a.len())
                        .unwrap_or(0);
                    let updated = data
                        .get("updatedRecords")
                        .and_then(|u| u.as_array())
                        .map(|a| a.len())
                        .unwrap_or(0);
                    // If no createdRecords/updatedRecords, count records array
                    let fallback = if created == 0 && updated == 0 {
                        data.get("records")
                            .and_then(|r| r.as_array())
                            .map(|a| a.len())
                            .unwrap_or(0)
                    } else {
                        0
                    };
                    total_upserted += created + updated + fallback;
                }
                Err(e) => errors.push(format!("Airtable upsert error: {e}")),
            },
            Err(e) => errors.push(format!("Airtable upsert parse error: {e}")),
        }
    }

    total_upserted
}

// ── Invoke output unwrapper ───────────────────────────────────────────────────

/// Unwrap 3-layer invoke response: invoke result → MCP wrapper → catalyst data
fn parse_catalyst_output(result: &Value) -> Result<Value, String> {
    // Check for top-level invoke errors
    if let Some(err) = result.get("error") {
        return Err(format!("Invoke error: {err}"));
    }

    let output = result.get("output").cloned().unwrap_or(Value::Null);

    // MCP execution.run wraps result in { result: ... }
    let catalyst_result = if let Some(inner) = output.get("result") {
        inner.clone()
    } else {
        match &output {
            Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(output.clone()),
            _ => output,
        }
    };

    // Check for catalyst-level errors
    if let Some(err) = catalyst_result.get("error") {
        return Err(format!("Catalyst error: {err}"));
    }

    // Check HTTP status
    if let Some(status) = catalyst_result.get("status").and_then(|s| s.as_u64()) {
        if status >= 400 {
            let err_body = catalyst_result.get("error").unwrap_or(&catalyst_result);
            return Err(format!("HTTP {status}: {err_body}"));
        }
    }

    // Return inner data if present
    Ok(catalyst_result
        .get("data")
        .cloned()
        .unwrap_or(catalyst_result))
}
