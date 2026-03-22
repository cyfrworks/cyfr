pub mod attachments;
pub mod claude;
pub mod gemini;
pub mod grok;
pub mod openai;
pub mod openrouter;

use serde_json::Value;

/// Detect provider from catalyst_ref string
pub fn detect_provider(catalyst_ref: &str) -> Provider {
    let lower = catalyst_ref.to_lowercase();
    if lower.contains("claude") {
        Provider::Claude
    } else if lower.contains("grok") {
        Provider::Grok
    } else if lower.contains("openrouter") {
        Provider::OpenRouter
    } else if lower.contains("openai") {
        Provider::OpenAI
    } else if lower.contains("gemini") {
        Provider::Gemini
    } else {
        Provider::Generic
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Provider {
    Claude,
    OpenAI,
    OpenRouter,
    Gemini,
    Grok,
    Generic,
}

impl Provider {
    pub fn name(&self) -> &'static str {
        match self {
            Provider::Claude => "claude",
            Provider::OpenAI => "openai",
            Provider::OpenRouter => "openrouter",
            Provider::Gemini => "gemini",
            Provider::Grok => "grok",
            Provider::Generic => "generic",
        }
    }

    /// Format canonical tool definitions for this provider's API
    pub fn format_tools(&self, tools: &[Value], visible_tools: Option<&[String]>) -> Value {
        match self {
            Provider::Claude => claude::format_tools(tools, visible_tools),
            Provider::OpenAI => openai::format_tools(tools, visible_tools),
            Provider::OpenRouter => openrouter::format_tools(tools, visible_tools),
            Provider::Gemini => gemini::format_tools(tools, visible_tools),
            Provider::Grok => grok::format_tools(tools, visible_tools),
            Provider::Generic => claude::format_tools(tools, visible_tools),
        }
    }

    /// Build the provider-specific LLM request
    pub fn build_request(
        &self,
        catalyst_ref: &str,
        model: &str,
        messages: &[Value],
        system: &str,
        max_tokens: u64,
        tools: &Value,
        visible_tools: Option<&[String]>,
    ) -> Value {
        match self {
            Provider::Claude => claude::build_request(model, messages, system, max_tokens, tools),
            Provider::OpenAI => openai::build_request(model, messages, system, tools),
            Provider::OpenRouter => openrouter::build_request(model, messages, system, tools, visible_tools),
            Provider::Gemini => gemini::build_request(model, messages, system, tools),
            Provider::Grok => grok::build_request(model, messages, system, tools),
            Provider::Generic => claude::build_request(model, messages, system, max_tokens, tools),
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
            Provider::Generic => false,
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
            Provider::Generic => vec![],
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
            Provider::Generic => claude::build_assistant_message(data),
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
            Provider::Generic => claude::build_tool_results_message(results),
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
            Provider::Generic => claude::extract_text(data),
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
            Provider::Generic => claude::extract_usage(data),
        }
    }

    /// Whether tool results should be spliced as multiple messages
    /// vs a single message (Claude, Gemini)
    pub fn splices_tool_results(&self) -> bool {
        matches!(self, Provider::OpenAI | Provider::OpenRouter | Provider::Grok)
    }
}

/// A normalized tool call from any provider
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

/// Check if a native tool name is allowed by visible_tools.
pub fn native_tool_allowed(visible_tools: Option<&[String]>, name: &str) -> bool {
    match visible_tools {
        None => true,
        Some(visible) => visible.iter().any(|v| v == name),
    }
}
