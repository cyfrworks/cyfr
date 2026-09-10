pub mod attachments;
pub mod claude;
pub mod gemini;
pub mod grok;
pub mod openai;
pub mod openrouter;

use serde_json::Value;

/// The provider a model catalyst reference names: the component name of
/// `type:namespace.name[:version]`, matched exactly. A name this table does
/// not know is an error, never a guess at a shape.
pub fn detect_provider(catalyst_ref: &str) -> Result<Provider, String> {
    let name = catalyst_ref
        .split(':')
        .nth(1)
        .and_then(|ns_name| ns_name.rsplit('.').next())
        .unwrap_or("");

    match name {
        "claude" => Ok(Provider::Claude),
        "openai" => Ok(Provider::OpenAI),
        "openrouter" => Ok(Provider::OpenRouter),
        "gemini" => Ok(Provider::Gemini),
        "grok" => Ok(Provider::Grok),
        _ => Err(format!("Unsupported model catalyst: {catalyst_ref}")),
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Provider {
    Claude,
    OpenAI,
    OpenRouter,
    Gemini,
    Grok,
}

impl Provider {
    pub fn name(&self) -> &'static str {
        match self {
            Provider::Claude => "claude",
            Provider::OpenAI => "openai",
            Provider::OpenRouter => "openrouter",
            Provider::Gemini => "gemini",
            Provider::Grok => "grok",
        }
    }

    /// Format canonical tool definitions for this provider's API.
    /// `native_search` appends the provider's native search tool — granted
    /// only when the agent's `tool_policy` names it (see
    /// `native_search_allowed/1`).
    pub fn format_tools(&self, tools: &[Value], native_search: bool) -> Value {
        match self {
            Provider::Claude => claude::format_tools(tools, native_search),
            Provider::OpenAI => openai::format_tools(tools, native_search),
            Provider::OpenRouter => openrouter::format_tools(tools, native_search),
            Provider::Gemini => gemini::format_tools(tools, native_search),
            Provider::Grok => grok::format_tools(tools, native_search),
        }
    }

    /// Build the provider-specific LLM request
    pub fn build_request(
        &self,
        _catalyst_ref: &str,
        model: &str,
        messages: &[Value],
        system: &str,
        max_tokens: u64,
        tools: &Value,
        native_search: bool,
    ) -> Value {
        match self {
            Provider::Claude => claude::build_request(model, messages, system, max_tokens, tools),
            Provider::OpenAI => openai::build_request(model, messages, system, tools),
            Provider::OpenRouter => openrouter::build_request(model, messages, system, tools, native_search),
            Provider::Gemini => gemini::build_request(model, messages, system, tools),
            Provider::Grok => grok::build_request(model, messages, system, tools),
        }
    }

    /// Check if the LLM response indicates tool use
    pub fn has_tool_calls(&self, data: &Value) -> bool {
        match self {
            Provider::Claude => claude::has_tool_calls(data),
            Provider::OpenAI => openai::has_tool_calls(data),
            Provider::OpenRouter => openrouter::has_tool_calls(data),
            Provider::Gemini => gemini::has_tool_calls(data),
            Provider::Grok => grok::has_tool_calls(data),
        }
    }

    /// Extract tool calls from the LLM response
    pub fn extract_tool_calls(&self, data: &Value) -> Vec<ToolCall> {
        match self {
            Provider::Claude => claude::extract_tool_calls(data),
            Provider::OpenAI => openai::extract_tool_calls(data),
            Provider::OpenRouter => openrouter::extract_tool_calls(data),
            Provider::Gemini => gemini::extract_tool_calls(data),
            Provider::Grok => grok::extract_tool_calls(data),
        }
    }

    /// Build the assistant message to add to conversation from the LLM response
    pub fn build_assistant_message(&self, data: &Value) -> Value {
        match self {
            Provider::Claude => claude::build_assistant_message(data),
            Provider::OpenAI => openai::build_assistant_message(data),
            Provider::OpenRouter => openrouter::build_assistant_message(data),
            Provider::Gemini => gemini::build_assistant_message(data),
            Provider::Grok => grok::build_assistant_message(data),
        }
    }

    /// Build the tool results message to add to conversation
    pub fn build_tool_results_message(&self, results: &[(String, String, String)]) -> Value {
        match self {
            Provider::Claude => claude::build_tool_results_message(results),
            Provider::OpenAI => openai::build_tool_results_message(results),
            Provider::OpenRouter => openrouter::build_tool_results_message(results),
            Provider::Gemini => gemini::build_tool_results_message(results),
            Provider::Grok => grok::build_tool_results_message(results),
        }
    }

    /// Extract final text content from the LLM response
    pub fn extract_text(&self, data: &Value) -> String {
        match self {
            Provider::Claude => claude::extract_text(data),
            Provider::OpenAI => openai::extract_text(data),
            Provider::OpenRouter => openrouter::extract_text(data),
            Provider::Gemini => gemini::extract_text(data),
            Provider::Grok => grok::extract_text(data),
        }
    }

    /// Extract normalized token usage from the LLM response
    /// Returns `{"input_tokens": N, "output_tokens": N}` or `Value::Null`
    pub fn extract_usage(&self, data: &Value) -> Value {
        match self {
            Provider::Claude => claude::extract_usage(data),
            Provider::OpenAI => openai::extract_usage(data),
            Provider::OpenRouter => openrouter::extract_usage(data),
            Provider::Gemini => gemini::extract_usage(data),
            Provider::Grok => grok::extract_usage(data),
        }
    }

}

/// A normalized tool call from any provider
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
    /// Gemini thought signature — must be passed back on functionCall parts
    pub thought_signature: Option<Value>,
}

/// Whether the agent's `tool_policy` grants the provider-native search tool.
/// Only an explicit `"native_search": "auto"` counts — native search runs
/// inside the provider with no approval round-trip, so "ask" cannot gate it
/// and is treated as not granted.
pub fn native_search_allowed(policy: &Value) -> bool {
    policy
        .as_object()
        .and_then(|obj| obj.get("native_search"))
        .and_then(|v| v.as_str())
        == Some("auto")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_is_the_exact_component_name() {
        assert_eq!(detect_provider("catalyst:local.claude").unwrap(), Provider::Claude);
        assert_eq!(detect_provider("catalyst:local.gemini:1.1.0").unwrap(), Provider::Gemini);
        assert_eq!(detect_provider("catalyst:moonmoon69.openrouter:1.0.0").unwrap(), Provider::OpenRouter);
    }

    #[test]
    fn an_unknown_name_is_an_error_not_a_shape() {
        assert!(detect_provider("catalyst:local.claude-proxy").is_err());
        assert!(detect_provider("catalyst:local.files").is_err());
        assert!(detect_provider("").is_err());
    }
}
