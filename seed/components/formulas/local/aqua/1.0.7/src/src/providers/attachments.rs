use serde_json::{json, Value};

/// Check if a media type is a text-based type that should be inlined as text content.
pub fn is_text_type(media_type: &str) -> bool {
    media_type.starts_with("text/")
        || media_type == "application/json"
        || media_type == "application/xml"
        || media_type == "application/javascript"
        || media_type == "application/typescript"
        || media_type == "application/x-yaml"
        || media_type == "application/toml"
        || media_type == "application/x-sh"
}

/// Check if a media type is an image type.
pub fn is_image_type(media_type: &str) -> bool {
    media_type.starts_with("image/")
}

/// Decode base64-encoded data to a UTF-8 string (best effort).
fn decode_base64_text(data: &str) -> String {
    // Simple base64 decode — WASM doesn't have the `base64` crate by default,
    // so we use a minimal inline decoder.
    match base64_decode(data) {
        Some(bytes) => String::from_utf8_lossy(&bytes).to_string(),
        None => format!("[Could not decode file content]"),
    }
}

/// Minimal base64 decoder (no external crate needed in WASM).
fn base64_decode(input: &str) -> Option<Vec<u8>> {
    let input = input.trim().replace('\n', "").replace('\r', "");
    let mut output = Vec::with_capacity(input.len() * 3 / 4);
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;

    for ch in input.bytes() {
        let val = match ch {
            b'A'..=b'Z' => ch - b'A',
            b'a'..=b'z' => ch - b'a' + 26,
            b'0'..=b'9' => ch - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            b' ' | b'\t' => continue,
            _ => return None,
        };
        buf = (buf << 6) | val as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            output.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }
    Some(output)
}

/// Convert provider-agnostic attachment blocks to Claude content blocks.
///
/// Claude format:
/// - Images: `{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"..."}}`
/// - PDFs: `{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"..."}}`
/// - Text: `{"type":"text","text":"--- filename ---\n<content>"}`
pub fn convert_for_claude(attachments: &[Value]) -> Vec<Value> {
    let mut blocks = Vec::new();
    for att in attachments {
        let media_type = att.get("media_type").and_then(|v| v.as_str()).unwrap_or("");
        let data = att.get("data").and_then(|v| v.as_str()).unwrap_or("");
        let filename = att.get("filename").and_then(|v| v.as_str()).unwrap_or("file");

        if is_text_type(media_type) {
            let text = decode_base64_text(data);
            blocks.push(json!({
                "type": "text",
                "text": format!("--- {} ---\n{}", filename, text)
            }));
        } else if is_image_type(media_type) {
            blocks.push(json!({
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": media_type,
                    "data": data
                }
            }));
        } else if media_type == "application/pdf" {
            blocks.push(json!({
                "type": "document",
                "source": {
                    "type": "base64",
                    "media_type": "application/pdf",
                    "data": data
                }
            }));
        } else {
            // Unknown type — try to pass as document (Claude may reject unsupported types)
            blocks.push(json!({
                "type": "document",
                "source": {
                    "type": "base64",
                    "media_type": media_type,
                    "data": data
                }
            }));
        }
    }
    blocks
}

// Note: OpenAI and Gemini attachment conversion is handled inline by each provider's
// build_request(), which converts from the canonical (Claude) format above.
// No separate convert_for_openai/convert_for_gemini functions needed.

