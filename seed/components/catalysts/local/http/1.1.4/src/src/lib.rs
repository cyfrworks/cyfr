#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;

use htmd::HtmlToMarkdown;
use serde_json::{json, Value};

const MAX_BODY_SIZE: usize = 5 * 1024 * 1024; // 5 MiB
const MAX_LINKS: usize = 500;

const USER_AGENT: &str =
    "Mozilla/5.0 (compatible; CyfrHttp/1.0)";

/// Headers that must not be forwarded from user input (defense-in-depth).
const BLOCKED_HEADERS: &[&str] = &[
    "host",
    "transfer-encoding",
    "content-length",
    "connection",
];

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        match handle_request(&input) {
            Ok(output) => output,
            Err(e) => format_error(500, "internal_error", &e),
        }
    }
}

bindings::export!(Component with_types_in bindings);

// ---------------------------------------------------------------------------
// Request routing
// ---------------------------------------------------------------------------

fn handle_request(input: &str) -> Result<String, String> {
    let parsed: Value =
        serde_json::from_str(input).map_err(|e| format!("Invalid JSON input: {e}"))?;

    let operation = parsed
        .get("operation")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing 'operation' field".to_string())?;

    let params = parsed.get("params").cloned().unwrap_or(json!({}));

    match operation {
        "read" => op_read(&params),
        "fetch" => op_fetch(&params),
        "links" => op_links(&params),
        "metadata" => op_metadata(&params),
        "head" => op_head(&params),
        _ => Ok(format_error(
            400,
            "unknown_operation",
            &format!("Unknown operation: {operation}"),
        )),
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn format_error(status: i64, error_type: &str, message: &str) -> String {
    json!({
        "status": status,
        "error": {
            "type": error_type,
            "message": message,
        }
    })
    .to_string()
}

fn require_url(params: &Value) -> Result<String, String> {
    params
        .get("url")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| "Missing 'url' in params".to_string())
}

fn default_headers() -> Value {
    json!({
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5"
    })
}

fn merge_headers(user_headers: Option<&Value>) -> Value {
    let mut headers = default_headers();
    if let Some(user) = user_headers {
        if let (Some(base), Some(extra)) = (headers.as_object_mut(), user.as_object()) {
            for (k, v) in extra {
                // Skip blocked headers (defense-in-depth)
                if BLOCKED_HEADERS.contains(&k.to_ascii_lowercase().as_str()) {
                    continue;
                }
                base.insert(k.clone(), v.clone());
            }
        }
    }
    headers
}

/// Execute an HTTP request and return the parsed host response.
fn do_http(method: &str, url: &str, headers: Value, body: &str) -> Result<Value, String> {
    let req = json!({
        "method": method,
        "url": url,
        "headers": headers,
        "body": body
    });
    let resp_str = fetch::request(&req.to_string());
    serde_json::from_str(&resp_str)
        .map_err(|e| format!("Failed to parse HTTP response: {e}"))
}

/// Fetch a URL with default browser-like headers and return (status, content_type, body_string).
fn fetch_page(url: &str, user_headers: Option<&Value>) -> Result<(i64, String, String), String> {
    let headers = merge_headers(user_headers);
    let resp = do_http("GET", url, headers, "")?;

    if let Some(err) = resp.get("error") {
        let msg = err
            .get("message")
            .and_then(|v| v.as_str())
            .or_else(|| err.as_str())
            .unwrap_or("unknown host error");
        return Err(format!("HTTP error: {msg}"));
    }

    let status = resp.get("status").and_then(|v| v.as_i64()).unwrap_or(500);
    let body = resp
        .get("body")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let content_type = resp
        .get("headers")
        .and_then(|h| h.get("content-type"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    Ok((status, content_type, body))
}

// ---------------------------------------------------------------------------
// Operation: read (local HTML→Markdown conversion)
// ---------------------------------------------------------------------------

fn op_read(params: &Value) -> Result<String, String> {
    let url = require_url(params)?;
    let (status, content_type, body) = fetch_page(&url, params.get("headers"))?;

    if status < 200 || status >= 300 {
        return Ok(format_error(status, "http_error", &format!("HTTP {status}")));
    }

    // Convert HTML to markdown locally, or return non-HTML as-is
    let (title, content) = if content_type.contains("html") {
        let title = extract_title(&body);
        let converter = HtmlToMarkdown::builder()
            .skip_tags(vec!["script", "style", "noscript"])
            .build();
        let md = converter.convert(&body).unwrap_or_else(|_| strip_tags(&body));
        (title, md)
    } else {
        (String::new(), body)
    };

    let word_count = content.split_whitespace().count();

    Ok(json!({
        "status": 200,
        "data": {
            "url": url,
            "title": title,
            "content": content,
            "word_count": word_count
        }
    })
    .to_string())
}

// ---------------------------------------------------------------------------
// Operation: fetch
// ---------------------------------------------------------------------------

fn op_fetch(params: &Value) -> Result<String, String> {
    let url = require_url(params)?;
    let method = params
        .get("method")
        .and_then(|v| v.as_str())
        .unwrap_or("GET");
    let body = params
        .get("body")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let headers = merge_headers(params.get("headers"));

    let resp = do_http(method, &url, headers, body)?;

    if let Some(err) = resp.get("error") {
        let msg = err
            .get("message")
            .and_then(|v| v.as_str())
            .or_else(|| err.as_str())
            .unwrap_or("unknown host error");
        return Ok(format_error(500, "http_error", msg));
    }

    let status = resp.get("status").and_then(|v| v.as_i64()).unwrap_or(500);
    let raw_body = resp.get("body").and_then(|v| v.as_str()).unwrap_or("");
    let resp_headers = resp.get("headers").cloned().unwrap_or(json!({}));
    let content_type = resp_headers
        .get("content-type")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let truncated = raw_body.len() > MAX_BODY_SIZE;
    let body_out = if truncated {
        truncate_str(raw_body, MAX_BODY_SIZE)
    } else {
        raw_body
    };

    Ok(json!({
        "status": status,
        "data": {
            "status_code": status,
            "content_type": content_type,
            "headers": resp_headers,
            "body": body_out,
            "truncated": truncated
        }
    })
    .to_string())
}

// ---------------------------------------------------------------------------
// Operation: head
// ---------------------------------------------------------------------------

fn op_head(params: &Value) -> Result<String, String> {
    let url = require_url(params)?;
    let headers = merge_headers(params.get("headers"));

    let resp = do_http("HEAD", &url, headers, "")?;

    if let Some(err) = resp.get("error") {
        let msg = err
            .get("message")
            .and_then(|v| v.as_str())
            .or_else(|| err.as_str())
            .unwrap_or("unknown host error");
        return Ok(format_error(500, "http_error", msg));
    }

    let status = resp.get("status").and_then(|v| v.as_i64()).unwrap_or(500);
    let resp_headers = resp.get("headers").cloned().unwrap_or(json!({}));
    let content_type = resp_headers
        .get("content-type")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let content_length = resp_headers
        .get("content-length")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    Ok(json!({
        "status": status,
        "data": {
            "status_code": status,
            "content_type": content_type,
            "content_length": content_length,
            "headers": resp_headers
        }
    })
    .to_string())
}

// ---------------------------------------------------------------------------
// Operation: links
// ---------------------------------------------------------------------------

fn op_links(params: &Value) -> Result<String, String> {
    let url = require_url(params)?;
    let max = params
        .get("max")
        .and_then(|v| v.as_u64())
        .map(|v| v as usize)
        .unwrap_or(MAX_LINKS);
    let (status, _, body) = fetch_page(&url, params.get("headers"))?;

    if status < 200 || status >= 300 {
        return Ok(format_error(status, "http_error", &format!("HTTP {status}")));
    }

    let base = find_base_url(&body, &url);
    let links = extract_links(&body, &base, max);

    Ok(json!({
        "status": 200,
        "data": {
            "url": url,
            "links": links,
            "count": links.len()
        }
    })
    .to_string())
}

// ---------------------------------------------------------------------------
// Operation: metadata
// ---------------------------------------------------------------------------

fn op_metadata(params: &Value) -> Result<String, String> {
    let url = require_url(params)?;
    let (status, _, body) = fetch_page(&url, params.get("headers"))?;

    if status < 200 || status >= 300 {
        return Ok(format_error(status, "http_error", &format!("HTTP {status}")));
    }

    let lower = body.to_ascii_lowercase();
    let lower_chars: Vec<char> = lower.chars().collect();

    let title = extract_title(&body);
    let description = extract_meta_content(&body, &lower, &lower_chars, "name", "description");
    let canonical = extract_canonical(&body, &lower, &lower_chars);
    let og = extract_og_tags(&body, &lower, &lower_chars);

    Ok(json!({
        "status": 200,
        "data": {
            "url": url,
            "title": title,
            "description": description,
            "canonical": canonical,
            "og": og
        }
    })
    .to_string())
}

// ---------------------------------------------------------------------------
// HTML helpers: link extraction
// ---------------------------------------------------------------------------

/// Find a <base href="..."> tag in the HTML head, or return the fetch URL.
fn find_base_url(html: &str, fetch_url: &str) -> String {
    let lower = html.to_ascii_lowercase();
    if let Some(pos) = lower.find("<base") {
        if let Some(tag_end) = lower[pos..].find('>') {
            let tag = &html[pos..pos + tag_end + 1];
            if let Some(href) = extract_attribute(tag, "href") {
                let trimmed = href.trim();
                if !trimmed.is_empty() {
                    return resolve_url(fetch_url, trimmed);
                }
            }
        }
    }
    fetch_url.to_string()
}

fn extract_links(html: &str, base_url: &str, max: usize) -> Vec<Value> {
    let mut links = Vec::new();
    let lower = html.to_ascii_lowercase();
    let chars: Vec<char> = html.chars().collect();
    let lower_chars: Vec<char> = lower.chars().collect();
    let mut i = 0;

    while i < lower_chars.len() && links.len() < max {
        // Find <a (case-insensitive)
        if lower_chars[i] == '<'
            && i + 2 < lower_chars.len()
            && lower_chars[i + 1] == 'a'
            && (lower_chars[i + 2].is_whitespace() || lower_chars[i + 2] == '>')
        {
            if let Some(tag_end) = find_char(&lower_chars, i + 1, '>') {
                let tag_orig: String = chars[i..tag_end + 1].iter().collect();

                if let Some(href) = extract_attribute(&tag_orig, "href") {
                    // Extract inner text until </a>
                    let text_start = tag_end + 1;
                    let inner_text =
                        if let Some(close) = find_str(&lower_chars, text_start, "</a") {
                            let raw: String = chars[text_start..close].iter().collect();
                            strip_tags(&raw).trim().to_string()
                        } else {
                            String::new()
                        };

                    let href_trimmed = href.trim();

                    // Filter out javascript:, mailto:, tel:, and fragment-only links
                    let href_lower = href_trimmed.to_ascii_lowercase();
                    if !href_lower.starts_with("javascript:")
                        && !href_lower.starts_with("mailto:")
                        && !href_lower.starts_with("tel:")
                        && !href_trimmed.starts_with('#')
                        && !href_trimmed.is_empty()
                    {
                        let resolved = resolve_url(base_url, href_trimmed);
                        let decoded_text = decode_text(&inner_text);
                        let text_collapsed = collapse_spaces(&decoded_text);
                        links.push(json!({
                            "href": resolved,
                            "text": text_collapsed
                        }));
                    }
                }

                i = tag_end + 1;
                continue;
            }
        }
        i += 1;
    }

    links
}

/// Extract the value of an HTML attribute from a tag string.
/// Ensures word-boundary matching: the character before the attribute name
/// must be whitespace (or start of tag content) to prevent matching
/// "data-href" when looking for "href".
fn extract_attribute(tag: &str, attr_name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let search = format!("{}=", attr_name);
    let mut search_start = 0;

    while let Some(rel_pos) = lower[search_start..].find(&search) {
        let pos = search_start + rel_pos;

        // Verify word boundary: char before must be whitespace or start of string
        let is_word_boundary = if pos == 0 {
            true
        } else {
            lower.as_bytes()[pos - 1].is_ascii_whitespace()
        };

        if is_word_boundary {
            let val_start = pos + search.len();
            let rest: Vec<char> = tag[val_start..].chars().collect();

            if rest.is_empty() {
                return None;
            }

            return match rest[0] {
                '"' => {
                    let end = find_char(&rest, 1, '"')?;
                    Some(rest[1..end].iter().collect())
                }
                '\'' => {
                    let end = find_char(&rest, 1, '\'')?;
                    Some(rest[1..end].iter().collect())
                }
                _ => {
                    // Unquoted: read until whitespace or >
                    let end = rest
                        .iter()
                        .position(|&c| c.is_whitespace() || c == '>')
                        .unwrap_or(rest.len());
                    Some(rest[..end].iter().collect())
                }
            };
        }

        search_start = pos + 1;
    }

    None
}

/// Strip all HTML tags from a string (for extracting inner text).
fn strip_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        if c == '<' {
            in_tag = true;
        } else if c == '>' {
            in_tag = false;
        } else if !in_tag {
            out.push(c);
        }
    }
    out
}

/// Resolve a potentially relative URL against a base URL.
/// Handles absolute, protocol-relative, absolute-path, and relative-path URLs.
/// Normalizes dot segments per RFC 3986 §5.2.4.
fn resolve_url(base: &str, href: &str) -> String {
    // Already absolute
    if href.starts_with("http://") || href.starts_with("https://") {
        return href.to_string();
    }

    // Protocol-relative
    if href.starts_with("//") {
        let proto = if base.starts_with("https") {
            "https:"
        } else {
            "http:"
        };
        return format!("{proto}{href}");
    }

    let (scheme_host, base_path) = split_url(base);

    let resolved_path = if href.starts_with('/') {
        // Absolute path
        href.to_string()
    } else {
        // Relative path — join with base directory
        let parent = if let Some(last_slash) = base_path.rfind('/') {
            &base_path[..last_slash + 1]
        } else {
            "/"
        };
        format!("{parent}{href}")
    };

    // Normalize dot segments (RFC 3986 §5.2.4)
    let normalized = normalize_path(&resolved_path);
    format!("{scheme_host}{normalized}")
}

/// Remove dot segments from a path per RFC 3986 §5.2.4.
fn normalize_path(path: &str) -> String {
    // Split path and query/fragment
    let (path_part, suffix) = if let Some(q) = path.find('?') {
        (&path[..q], &path[q..])
    } else if let Some(f) = path.find('#') {
        (&path[..f], &path[f..])
    } else {
        (path, "")
    };

    let mut segments: Vec<&str> = Vec::new();
    for seg in path_part.split('/') {
        match seg {
            "." => {}
            ".." => {
                // Don't pop past root
                if !segments.is_empty() {
                    segments.pop();
                }
            }
            s => segments.push(s),
        }
    }

    let mut result = segments.join("/");
    // Ensure leading slash
    if !result.starts_with('/') {
        result.insert(0, '/');
    }
    format!("{result}{suffix}")
}

/// Split a URL into (scheme://host[:port], /path).
fn split_url(url: &str) -> (&str, &str) {
    if let Some(proto_end) = url.find("://") {
        let after_proto = proto_end + 3;
        if let Some(path_start) = url[after_proto..].find('/') {
            let split = after_proto + path_start;
            (&url[..split], &url[split..])
        } else {
            (url, "/")
        }
    } else {
        (url, "/")
    }
}

// ---------------------------------------------------------------------------
// HTML helpers: metadata extraction
// ---------------------------------------------------------------------------

fn extract_title(html: &str) -> String {
    let lower = html.to_ascii_lowercase();
    if let Some(start) = lower.find("<title") {
        if let Some(tag_end) = lower[start..].find('>') {
            let content_start = start + tag_end + 1;
            if let Some(end) = lower[content_start..].find("</title") {
                let raw = &html[content_start..content_start + end];
                return decode_text(raw).trim().to_string();
            }
        }
    }
    String::new()
}

fn extract_meta_content(
    html: &str,
    lower: &str,
    lower_chars: &[char],
    attr: &str,
    name: &str,
) -> String {
    let search = "<meta";
    let mut start = 0;

    while let Some(pos) = lower[start..].find(search) {
        let abs_pos = start + pos;
        if let Some(tag_end) = find_char(lower_chars, abs_pos, '>') {
            let tag: String = html[abs_pos..tag_end + 1].chars().collect();
            let tag_lower: String = lower[abs_pos..tag_end + 1].chars().collect();

            let has_attr = extract_attribute(&tag_lower, attr)
                .map(|v| v.to_ascii_lowercase() == name)
                .unwrap_or(false);

            if has_attr {
                if let Some(content) = extract_attribute(&tag, "content") {
                    return decode_text(&content);
                }
            }

            start = tag_end + 1;
        } else {
            break;
        }
    }

    String::new()
}

fn extract_canonical(html: &str, lower: &str, lower_chars: &[char]) -> String {
    let search = "<link";
    let mut start = 0;

    while let Some(pos) = lower[start..].find(search) {
        let abs_pos = start + pos;
        if let Some(tag_end) = find_char(lower_chars, abs_pos, '>') {
            let tag: String = html[abs_pos..tag_end + 1].chars().collect();
            let tag_lower: String = lower[abs_pos..tag_end + 1].chars().collect();

            let is_canonical = extract_attribute(&tag_lower, "rel")
                .map(|v| v == "canonical")
                .unwrap_or(false);

            if is_canonical {
                if let Some(href) = extract_attribute(&tag, "href") {
                    return decode_text(&href);
                }
            }

            start = tag_end + 1;
        } else {
            break;
        }
    }

    String::new()
}

fn extract_og_tags(html: &str, lower: &str, lower_chars: &[char]) -> Value {
    let search = "<meta";
    let mut og = serde_json::Map::new();
    let mut start = 0;

    while let Some(pos) = lower[start..].find(search) {
        let abs_pos = start + pos;
        if let Some(tag_end) = find_char(lower_chars, abs_pos, '>') {
            let tag: String = html[abs_pos..tag_end + 1].chars().collect();
            let tag_lower: String = lower[abs_pos..tag_end + 1].chars().collect();

            if let Some(prop) = extract_attribute(&tag_lower, "property") {
                if prop.starts_with("og:") {
                    let key = prop[3..].to_string();
                    if let Some(content) = extract_attribute(&tag, "content") {
                        og.insert(key, Value::String(decode_text(&content)));
                    }
                }
            }

            start = tag_end + 1;
        } else {
            break;
        }
    }

    Value::Object(og)
}

// ---------------------------------------------------------------------------
// HTML helpers: text utilities
// ---------------------------------------------------------------------------

/// Decode HTML entities in a text fragment.
fn decode_text(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '&' {
            if let Some((decoded, advance)) = decode_entity(&chars, i) {
                out.push_str(&decoded);
                i += advance;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// Decode an HTML entity starting at position `i` (which is '&').
/// Returns (decoded_string, chars_consumed) or None.
fn decode_entity(chars: &[char], i: usize) -> Option<(String, usize)> {
    let max_end = (i + 12).min(chars.len());
    let semi_pos = (i + 1..max_end).find(|&j| chars[j] == ';')?;
    let entity: String = chars[i + 1..semi_pos].iter().collect();
    let advance = semi_pos - i + 1;

    // Numeric entities
    if entity.starts_with('#') {
        let num_str = &entity[1..];
        let code = if num_str.starts_with('x') || num_str.starts_with('X') {
            u32::from_str_radix(&num_str[1..], 16).ok()?
        } else {
            num_str.parse::<u32>().ok()?
        };
        let ch = char::from_u32(code)?;
        return Some((ch.to_string(), advance));
    }

    // Named entities
    let decoded = match entity.as_str() {
        "amp" => "&",
        "lt" => "<",
        "gt" => ">",
        "quot" => "\"",
        "apos" => "'",
        "nbsp" => " ",
        "ndash" => "\u{2013}",
        "mdash" => "\u{2014}",
        "lsquo" => "\u{2018}",
        "rsquo" => "\u{2019}",
        "ldquo" => "\u{201C}",
        "rdquo" => "\u{201D}",
        "bull" => "\u{2022}",
        "hellip" => "\u{2026}",
        "copy" => "\u{00A9}",
        "reg" => "\u{00AE}",
        "trade" => "\u{2122}",
        "deg" => "\u{00B0}",
        "plusmn" => "\u{00B1}",
        "times" => "\u{00D7}",
        "divide" => "\u{00F7}",
        "laquo" => "\u{00AB}",
        "raquo" => "\u{00BB}",
        "cent" => "\u{00A2}",
        "pound" => "\u{00A3}",
        "yen" => "\u{00A5}",
        "euro" => "\u{20AC}",
        "para" => "\u{00B6}",
        "sect" => "\u{00A7}",
        "rarr" => "\u{2192}",
        "larr" => "\u{2190}",
        _ => return None,
    };
    Some((decoded.to_string(), advance))
}

/// Collapse runs of spaces/tabs within a single line.
fn collapse_spaces(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut prev_space = false;
    for c in line.chars() {
        if c == ' ' || c == '\t' || c == '\r' {
            if !prev_space && !out.is_empty() {
                out.push(' ');
            }
            prev_space = true;
        } else {
            prev_space = false;
            out.push(c);
        }
    }
    out.trim_end().to_string()
}

fn truncate_str(s: &str, max: usize) -> &str {
    if s.len() <= max {
        s
    } else {
        let mut end = max;
        while end > 0 && !s.is_char_boundary(end) {
            end -= 1;
        }
        &s[..end]
    }
}

// ---------------------------------------------------------------------------
// Low-level utilities
// ---------------------------------------------------------------------------

fn find_char(chars: &[char], start: usize, target: char) -> Option<usize> {
    for j in start..chars.len() {
        if chars[j] == target {
            return Some(j);
        }
    }
    None
}

fn find_str(chars: &[char], start: usize, target: &str) -> Option<usize> {
    let target_chars: Vec<char> = target.chars().collect();
    let tlen = target_chars.len();
    if tlen == 0 || start + tlen > chars.len() {
        return None;
    }
    for j in start..=chars.len() - tlen {
        if chars[j..j + tlen] == target_chars[..] {
            return Some(j);
        }
    }
    None
}
