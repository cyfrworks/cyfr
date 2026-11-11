//! What a caller names that is placed in a provider's URL.
//!
//! An identifier — a model, a batch, a file — is refused before any request
//! unless it keeps to a strict grammar, and is percent-encoded as the path
//! segment it becomes. A query value is percent-encoded whole.

/// The longest identifier accepted, in bytes.
pub const MAX_LEN: usize = 128;

/// Whether `id` is 1 to `MAX_LEN` ASCII letters, digits, `.`, `_` and `-`,
/// and the characters of `also` a provider's own ids use, with no empty,
/// `.` or `..` segment between slashes.
pub fn valid(id: &str, also: &[char]) -> bool {
    id.len() <= MAX_LEN
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') || also.contains(&c))
        && id.split('/').all(|segment| !matches!(segment, "" | "." | ".."))
}

/// `id` as one URL path segment: every byte but RFC 3986's unreserved
/// characters and `:` percent-encoded.
pub fn segment(id: &str) -> String {
    encode(id, b":")
}

/// `value` as a URL query value: every byte but RFC 3986's unreserved
/// characters percent-encoded.
pub fn query(value: &str) -> String {
    encode(value, b"")
}

fn encode(text: &str, keep: &[u8]) -> String {
    let mut encoded = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) || keep.contains(&byte) {
            encoded.push(char::from(byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_identifier_keeps_to_the_grammar_or_is_refused() {
        for id in ["claude-sonnet-4-6", "grok-build-0.1", "msgbatch_01Hk", "a..b", "x"] {
            assert!(valid(id, &[]), "{id}");
        }
        assert!(valid("vendor/model:free", &['/', ':']));
        assert!(valid(&"a".repeat(MAX_LEN), &[]));

        for id in [
            "",
            ".",
            "..",
            "../messages",
            "%2e%2e",
            "%2E%2E/messages",
            "model?alt=json",
            "model#frag",
            "model name",
            " model",
            "model\t",
            "model\n",
            "vendor/model",
            "model:countTokens",
            "modèle",
        ] {
            assert!(!valid(id, &[]), "{id:?}");
        }
        for id in ["vendor/../model", "vendor/./model", "/model", "vendor/", "vendor//model", "../model"] {
            assert!(!valid(id, &['/', ':']), "{id:?}");
        }
        assert!(!valid(&"a".repeat(MAX_LEN + 1), &[]));
    }

    #[test]
    fn a_segment_and_a_query_value_are_percent_encoded() {
        assert_eq!(segment("claude-sonnet-4-6"), "claude-sonnet-4-6");
        assert_eq!(segment("ft:gpt-4o:org::id"), "ft:gpt-4o:org::id");
        assert_eq!(segment("a/b c?#%"), "a%2Fb%20c%3F%23%25");
        assert_eq!(query("Ab+/=~_"), "Ab%2B%2F%3D~_");
        assert_eq!(query("a&b=c"), "a%26b%3Dc");
    }
}
