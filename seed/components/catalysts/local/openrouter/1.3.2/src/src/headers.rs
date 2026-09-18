//! What a caller names that reaches a provider's request headers: the
//! attribution headers OpenRouter reads, `HTTP-Referer` from `referer` and
//! `X-Title` from `title`, are refused before the key is read and before
//! any request is built unless each keeps to its bound and carries no
//! control byte, and `referer` is an absolute `http://` or `https://` URL.

use serde_json::Value;

/// The longest `referer` accepted, in bytes.
pub const REFERER_MAX_LEN: usize = 2048;

/// The longest `title` accepted, in bytes.
pub const TITLE_MAX_LEN: usize = 256;

/// The `referer` param when present: a string of at most `REFERER_MAX_LEN`
/// bytes with no control byte that is an absolute `http://` or `https://`
/// URL. The message names the parameter and the rule it broke.
pub fn referer(params: &Value) -> Result<Option<String>, String> {
    let Some(value) = string(params, "referer")? else {
        return Ok(None);
    };
    if value.len() > REFERER_MAX_LEN {
        return Err(format!("'referer' must be at most {REFERER_MAX_LEN} bytes"));
    }
    if has_control_byte(value) {
        return Err("'referer' must not contain CR, LF or any other control byte".into());
    }
    if !absolute_http_url(value) {
        return Err("'referer' must be an absolute http:// or https:// URL".into());
    }
    Ok(Some(value.to_string()))
}

/// The `title` param when present: a string of at most `TITLE_MAX_LEN`
/// bytes with no control byte. The message names the parameter and the
/// rule it broke.
pub fn title(params: &Value) -> Result<Option<String>, String> {
    let Some(value) = string(params, "title")? else {
        return Ok(None);
    };
    if value.len() > TITLE_MAX_LEN {
        return Err(format!("'title' must be at most {TITLE_MAX_LEN} bytes"));
    }
    if has_control_byte(value) {
        return Err("'title' must not contain CR, LF or any other control byte".into());
    }
    Ok(Some(value.to_string()))
}

/// An absent or null param is absent; a present one must be a string.
fn string<'a>(params: &'a Value, key: &str) -> Result<Option<&'a str>, String> {
    match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        Some(_) => Err(format!("'{key}' must be a string")),
    }
}

/// A C0 control (0x00-0x1F, CR and LF among them) or DEL (0x7F) anywhere:
/// what would end a header line or slip a second one in.
fn has_control_byte(value: &str) -> bool {
    value.bytes().any(|b| b < 0x20 || b == 0x7F)
}

/// An absolute `http://` or `https://` URL: the scheme, then a non-empty
/// authority before any path, query or fragment, in visible ASCII
/// throughout (no space and no raw non-ASCII).
fn absolute_http_url(value: &str) -> bool {
    let Some(rest) = value
        .strip_prefix("http://")
        .or_else(|| value.strip_prefix("https://"))
    else {
        return false;
    };
    let authority = rest
        .split(|c| matches!(c, '/' | '?' | '#'))
        .next()
        .unwrap_or("");
    !authority.is_empty() && value.bytes().all(|b| (0x21..=0x7E).contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const REFERER_CONTROL: &str = "'referer' must not contain CR, LF or any other control byte";
    const REFERER_URL: &str = "'referer' must be an absolute http:// or https:// URL";
    const TITLE_CONTROL: &str = "'title' must not contain CR, LF or any other control byte";

    fn referer_of(value: Value) -> Result<Option<String>, String> {
        referer(&json!({"referer": value}))
    }

    fn title_of(value: Value) -> Result<Option<String>, String> {
        title(&json!({"title": value}))
    }

    #[test]
    fn a_referer_is_an_absolute_http_url_within_its_bound() {
        for url in [
            "https://example.com",
            "http://example.com/",
            "https://example.com/app?x=1#top",
            "https://user:pw@example.com:8443/path",
        ] {
            assert_eq!(referer_of(json!(url)).unwrap().as_deref(), Some(url), "{url}");
        }

        let longest = format!(
            "https://example.com/{}",
            "a".repeat(REFERER_MAX_LEN - "https://example.com/".len())
        );
        assert_eq!(longest.len(), REFERER_MAX_LEN);
        assert_eq!(referer_of(json!(longest)).unwrap().as_deref(), Some(longest.as_str()));
    }

    #[test]
    fn an_absent_or_null_referer_is_absent() {
        assert_eq!(referer(&json!({})).unwrap(), None);
        assert_eq!(referer_of(Value::Null).unwrap(), None);
    }

    #[test]
    fn a_referer_over_the_bound_is_refused() {
        let over = format!(
            "https://example.com/{}",
            "a".repeat(REFERER_MAX_LEN + 1 - "https://example.com/".len())
        );
        assert_eq!(over.len(), REFERER_MAX_LEN + 1);
        assert_eq!(
            referer_of(json!(over)).unwrap_err(),
            "'referer' must be at most 2048 bytes"
        );
    }

    #[test]
    fn a_referer_carrying_crlf_is_refused() {
        for value in [
            "https://example.com\r\nX-Injected: 1",
            "https://example.com\n",
            "https://example.com\r",
            "https://example.com/\r\n\r\n",
        ] {
            assert_eq!(referer_of(json!(value)).unwrap_err(), REFERER_CONTROL, "{value:?}");
        }
    }

    #[test]
    fn a_referer_carrying_any_other_control_byte_is_refused() {
        for value in [
            "https://example.com/\u{0}",
            "https://example.com/\t",
            "\u{1b}https://example.com/",
            "https://example.com/\u{7f}",
        ] {
            assert_eq!(referer_of(json!(value)).unwrap_err(), REFERER_CONTROL, "{value:?}");
        }
    }

    #[test]
    fn a_referer_that_is_not_an_absolute_http_url_is_refused() {
        for value in [
            "",
            "example.com",
            "//example.com",
            "/relative/path",
            "https:",
            "https://",
            "https:///path",
            "https://?query",
            "http:/example.com",
            "https://exa mple.com",
            "https://ex\u{e4}mple.com",
            "HTTPS://example.com",
            "javascript:alert(1)",
            "data:text/plain,hi",
        ] {
            assert_eq!(referer_of(json!(value)).unwrap_err(), REFERER_URL, "{value:?}");
        }
    }

    #[test]
    fn an_ftp_referer_is_refused() {
        assert_eq!(referer_of(json!("ftp://example.com/file")).unwrap_err(), REFERER_URL);
    }

    #[test]
    fn a_referer_that_is_not_a_string_is_refused() {
        for value in [json!(42), json!(true), json!(["https://example.com"]), json!({})] {
            assert_eq!(referer_of(value.clone()).unwrap_err(), "'referer' must be a string", "{value}");
        }
    }

    #[test]
    fn a_title_within_its_bound_and_free_of_control_bytes_is_accepted() {
        for value in ["My App", "\u{dc}n\u{ef}c\u{f6}d\u{e9} app", "a b", ""] {
            assert_eq!(title_of(json!(value)).unwrap().as_deref(), Some(value), "{value:?}");
        }
        let longest = "t".repeat(TITLE_MAX_LEN);
        assert_eq!(title_of(json!(longest)).unwrap().as_deref(), Some(longest.as_str()));
    }

    #[test]
    fn an_absent_or_null_title_is_absent() {
        assert_eq!(title(&json!({})).unwrap(), None);
        assert_eq!(title_of(Value::Null).unwrap(), None);
    }

    #[test]
    fn a_title_over_the_bound_is_refused() {
        assert_eq!(
            title_of(json!("t".repeat(TITLE_MAX_LEN + 1))).unwrap_err(),
            "'title' must be at most 256 bytes"
        );
        // The bound is in bytes: 200 two-byte characters are 400 bytes.
        assert_eq!(
            title_of(json!("\u{e9}".repeat(200))).unwrap_err(),
            "'title' must be at most 256 bytes"
        );
    }

    #[test]
    fn a_title_carrying_crlf_is_refused() {
        for value in ["My App\r\nX-Injected: 1", "My\nApp", "My\rApp", "\r\n"] {
            assert_eq!(title_of(json!(value)).unwrap_err(), TITLE_CONTROL, "{value:?}");
        }
    }

    #[test]
    fn a_title_carrying_any_other_control_byte_is_refused() {
        for value in ["My\u{0}App", "My\tApp", "\u{1b}[31mMy App", "My App\u{7f}"] {
            assert_eq!(title_of(json!(value)).unwrap_err(), TITLE_CONTROL, "{value:?}");
        }
    }

    #[test]
    fn a_title_that_is_not_a_string_is_refused() {
        for value in [json!(1), json!(false), json!(["x"]), json!({})] {
            assert_eq!(title_of(value.clone()).unwrap_err(), "'title' must be a string", "{value}");
        }
    }
}
