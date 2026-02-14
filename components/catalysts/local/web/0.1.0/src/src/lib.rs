#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;

use serde_json::{json, Value};

const MAX_BODY_SIZE: usize = 5 * 1024 * 1024; // 5 MiB

const USER_AGENT: &str =
    "Mozilla/5.0 (compatible; CyfrWebCatalyst/0.1; +https://cyfr.dev)";

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
        "fetch" => op_fetch(&params),
        "extract" => op_extract(&params),
        "links" => op_links(&params),
        "metadata" => op_metadata(&params),
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
        let msg = err.as_str().unwrap_or("unknown host error");
        return Err(format!("HTTP error: {msg}"));
    }

    let status = resp.get("status").and_then(|v| v.as_i64()).unwrap_or(500);
    let body = resp.get("body").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let resp_headers = resp.get("headers");
    let content_type = resp_headers
        .and_then(|h| {
            // Try common casing variants
            h.get("content-type")
                .or_else(|| h.get("Content-Type"))
                .or_else(|| h.get("CONTENT-TYPE"))
        })
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    Ok((status, content_type, body))
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
        let msg = err.as_str().unwrap_or("unknown host error");
        return Ok(format_error(500, "http_error", msg));
    }

    let status = resp.get("status").and_then(|v| v.as_i64()).unwrap_or(500);
    let raw_body = resp.get("body").and_then(|v| v.as_str()).unwrap_or("");
    let resp_headers = resp.get("headers").cloned().unwrap_or(json!({}));
    let content_type = resp_headers
        .get("content-type")
        .or_else(|| resp_headers.get("Content-Type"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let truncated = raw_body.len() > MAX_BODY_SIZE;
    let body_out = if truncated {
        &raw_body[..MAX_BODY_SIZE]
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
// Operation: extract
// ---------------------------------------------------------------------------

fn op_extract(params: &Value) -> Result<String, String> {
    let url = require_url(params)?;
    let (status, content_type, body) = fetch_page(&url, params.get("headers"))?;

    if status < 200 || status >= 300 {
        return Ok(format_error(status, "http_error", &format!("HTTP {status}")));
    }

    let is_html = content_type.contains("html");
    if !is_html {
        let word_count = body.split_whitespace().count();
        return Ok(json!({
            "status": 200,
            "data": {
                "url": url,
                "content_type": content_type,
                "text": truncate_str(&body, MAX_BODY_SIZE),
                "word_count": word_count,
                "truncated": body.len() > MAX_BODY_SIZE
            }
        })
        .to_string());
    }

    let title = extract_title(&body);
    let text = html_to_text(&body);
    let word_count = text.split_whitespace().count();

    Ok(json!({
        "status": 200,
        "data": {
            "url": url,
            "title": title,
            "text": text,
            "word_count": word_count
        }
    })
    .to_string())
}

// ---------------------------------------------------------------------------
// Operation: links
// ---------------------------------------------------------------------------

fn op_links(params: &Value) -> Result<String, String> {
    let url = require_url(params)?;
    let (status, _, body) = fetch_page(&url, params.get("headers"))?;

    if status < 200 || status >= 300 {
        return Ok(format_error(status, "http_error", &format!("HTTP {status}")));
    }

    let links = extract_links(&body, &url);

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

    let title = extract_title(&body);
    let description = extract_meta_content(&body, "name", "description");
    let canonical = extract_canonical(&body);
    let og = extract_og_tags(&body);

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
// HTML-to-text engine
// ---------------------------------------------------------------------------

/// Single-pass HTML to plain-text converter.
fn html_to_text(html: &str) -> String {
    let mut out = String::with_capacity(html.len() / 3);
    let chars: Vec<char> = html.chars().collect();
    let len = chars.len();
    let mut i = 0;
    let mut suppress = false; // inside <script>, <style>, etc.
    let mut suppress_tag = String::new();

    while i < len {
        // HTML comment
        if i + 3 < len && chars[i] == '<' && chars[i + 1] == '!' && chars[i + 2] == '-' && chars[i + 3] == '-' {
            if let Some(end) = find_str(&chars, i + 4, "-->") {
                i = end + 3;
                continue;
            }
        }

        // Tag
        if chars[i] == '<' {
            if let Some(tag_end) = find_char(&chars, i + 1, '>') {
                let tag_content: String = chars[i + 1..tag_end].iter().collect();
                let tag_lower = tag_content.to_ascii_lowercase();
                let tag_name = extract_tag_name(&tag_lower);

                // Check for closing suppressed tag
                if suppress {
                    if tag_lower.starts_with('/') {
                        let close_name = extract_tag_name(&tag_lower[1..]);
                        if close_name == suppress_tag {
                            suppress = false;
                            suppress_tag.clear();
                        }
                    }
                    i = tag_end + 1;
                    continue;
                }

                // Start suppressing content
                if matches!(
                    tag_name.as_str(),
                    "script" | "style" | "noscript" | "svg" | "template"
                ) && !tag_lower.starts_with('/')
                    && !tag_content.ends_with('/')
                {
                    suppress = true;
                    suppress_tag = tag_name.clone();
                    i = tag_end + 1;
                    continue;
                }

                // Block-level elements: insert newline
                if is_block_element(&tag_name) {
                    if !out.ends_with('\n') {
                        out.push('\n');
                    }
                    // List items get a bullet prefix
                    if tag_name == "li" && !tag_lower.starts_with('/') {
                        out.push_str("- ");
                    }
                }

                // <br> / <br/>
                if tag_name == "br" {
                    out.push('\n');
                }

                i = tag_end + 1;
                continue;
            }
        }

        if suppress {
            i += 1;
            continue;
        }

        // HTML entity
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

    collapse_whitespace(&out)
}

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

fn extract_tag_name(tag_content: &str) -> String {
    tag_content
        .trim()
        .split(|c: char| c.is_whitespace() || c == '/' || c == '>')
        .next()
        .unwrap_or("")
        .to_string()
}

fn is_block_element(tag: &str) -> bool {
    matches!(
        tag,
        "p" | "div"
            | "h1"
            | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
            | "li"
            | "ul"
            | "ol"
            | "blockquote"
            | "pre"
            | "table"
            | "tr"
            | "section"
            | "article"
            | "header"
            | "footer"
            | "nav"
            | "main"
            | "aside"
            | "figure"
            | "figcaption"
            | "details"
            | "summary"
            | "hr"
            | "dt"
            | "dd"
    )
}

/// Decode an HTML entity starting at position `i` (which is '&').
/// Returns (decoded_string, chars_consumed) or None.
fn decode_entity(chars: &[char], i: usize) -> Option<(String, usize)> {
    // Find the semicolon (max 10 chars for entity name)
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

/// Collapse runs of whitespace and limit consecutive blank lines to one.
fn collapse_whitespace(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut blank_lines = 0u32;

    for line in text.split('\n') {
        let trimmed = collapse_spaces(line);
        if trimmed.is_empty() {
            blank_lines += 1;
            if blank_lines <= 1 {
                result.push('\n');
            }
        } else {
            blank_lines = 0;
            if !result.is_empty() && !result.ends_with('\n') {
                result.push('\n');
            }
            result.push_str(&trimmed);
            result.push('\n');
        }
    }

    result.trim().to_string()
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
        // Find a valid UTF-8 boundary
        let mut end = max;
        while end > 0 && !s.is_char_boundary(end) {
            end -= 1;
        }
        &s[..end]
    }
}

// ---------------------------------------------------------------------------
// Title extraction
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

// ---------------------------------------------------------------------------
// Link extraction
// ---------------------------------------------------------------------------

fn extract_links(html: &str, base_url: &str) -> Vec<Value> {
    let mut links = Vec::new();
    let lower = html.to_ascii_lowercase();
    let chars: Vec<char> = html.chars().collect();
    let lower_chars: Vec<char> = lower.chars().collect();
    let mut i = 0;

    while i < lower_chars.len() {
        // Find <a (case-insensitive)
        if lower_chars[i] == '<' && i + 2 < lower_chars.len() && lower_chars[i + 1] == 'a'
            && (lower_chars[i + 2].is_whitespace() || lower_chars[i + 2] == '>')
        {
            if let Some(tag_end) = find_char(&lower_chars, i + 1, '>') {
                let tag_orig: String = chars[i..tag_end + 1].iter().collect();

                // Extract href
                if let Some(href) = extract_attribute(&tag_orig, "href") {
                    // Extract inner text until </a>
                    let text_start = tag_end + 1;
                    let inner_text = if let Some(close) = find_str(&lower_chars, text_start, "</a") {
                        let raw: String = chars[text_start..close].iter().collect();
                        strip_tags(&raw).trim().to_string()
                    } else {
                        String::new()
                    };

                    let href_trimmed = href.trim();

                    // Filter out javascript:, mailto:, and fragment-only links
                    let href_lower = href_trimmed.to_ascii_lowercase();
                    if !href_lower.starts_with("javascript:")
                        && !href_lower.starts_with("mailto:")
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
fn extract_attribute(tag: &str, attr_name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let search = format!("{}=", attr_name);

    let pos = lower.find(&search)?;
    let val_start = pos + search.len();
    let rest: Vec<char> = tag[val_start..].chars().collect();

    if rest.is_empty() {
        return None;
    }

    match rest[0] {
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
    }
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
fn resolve_url(base: &str, href: &str) -> String {
    // Already absolute
    if href.starts_with("http://") || href.starts_with("https://") || href.starts_with("//") {
        if href.starts_with("//") {
            // Protocol-relative
            let proto = if base.starts_with("https") {
                "https:"
            } else {
                "http:"
            };
            return format!("{proto}{href}");
        }
        return href.to_string();
    }

    // Parse base URL components
    let (scheme_host, base_path) = split_url(base);

    if href.starts_with('/') {
        // Absolute path
        format!("{scheme_host}{href}")
    } else {
        // Relative path
        let parent = if let Some(last_slash) = base_path.rfind('/') {
            &base_path[..last_slash + 1]
        } else {
            "/"
        };
        format!("{scheme_host}{parent}{href}")
    }
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
// Metadata extraction
// ---------------------------------------------------------------------------

fn extract_meta_content(html: &str, attr: &str, name: &str) -> String {
    let lower = html.to_ascii_lowercase();
    let search = format!("<meta");
    let mut start = 0;

    while let Some(pos) = lower[start..].find(&search) {
        let abs_pos = start + pos;
        if let Some(tag_end) = find_char(&lower.chars().collect::<Vec<_>>(), abs_pos, '>') {
            let tag: String = html[abs_pos..tag_end + 1].chars().collect();
            let tag_lower: String = lower[abs_pos..tag_end + 1].chars().collect();

            // Check if this meta tag has the right attribute
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

fn extract_canonical(html: &str) -> String {
    let lower = html.to_ascii_lowercase();
    let search = "<link";
    let mut start = 0;

    while let Some(pos) = lower[start..].find(search) {
        let abs_pos = start + pos;
        if let Some(tag_end) = find_char(&lower.chars().collect::<Vec<_>>(), abs_pos, '>') {
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

fn extract_og_tags(html: &str) -> Value {
    let lower = html.to_ascii_lowercase();
    let search = "<meta";
    let mut og = serde_json::Map::new();
    let mut start = 0;

    while let Some(pos) = lower[start..].find(search) {
        let abs_pos = start + pos;
        if let Some(tag_end) = find_char(&lower.chars().collect::<Vec<_>>(), abs_pos, '>') {
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
