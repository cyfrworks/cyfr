//! What a caller names that reaches a provider's request: a model id is
//! refused before any request unless it keeps to a strict grammar.

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

#[cfg(test)]
mod tests {
    use super::*;

    const OPENROUTER: &[char] = &['/', ':', '~'];

    #[test]
    fn an_identifier_keeps_to_the_grammar_or_is_refused() {
        for id in [
            "openai/gpt-6-astra",
            "meta-llama/llama-3.3-70b-instruct:free",
            "~anthropic/claude-sonnet-latest",
            "openrouter/auto",
        ] {
            assert!(valid(id, OPENROUTER), "{id}");
        }
        assert!(valid(&"a".repeat(MAX_LEN), OPENROUTER));

        for id in [
            "",
            "..",
            "../models",
            "vendor/../model",
            "vendor/./model",
            "/model",
            "vendor/",
            "vendor//model",
            "%2e%2e/models",
            "vendor%2Fmodel",
            "vendor/model?x=1",
            "vendor/model#frag",
            "vendor/model name",
            " vendor/model",
            "vendor/model\n",
            "@preset/mine",
        ] {
            assert!(!valid(id, OPENROUTER), "{id:?}");
        }
        assert!(!valid(&"a".repeat(MAX_LEN + 1), OPENROUTER));
    }
}
