pub mod claude;
pub mod gemini;
pub mod openai;

use serde_json::Value;

/// Detect provider from catalyst_ref string
pub fn detect_provider(catalyst_ref: &str) -> Provider {
    let lower = catalyst_ref.to_lowercase();
    if lower.contains("claude") {
        Provider::Claude
    } else if lower.contains("openai") || lower.contains("openrouter") || lower.contains("grok") {
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
    Gemini,
    Generic,
}

impl Provider {
    pub fn name(&self) -> &'static str {
        match self {
            Provider::Claude => "claude",
            Provider::OpenAI => "openai",
            Provider::Gemini => "gemini",
            Provider::Generic => "generic",
        }
    }

    /// Check if the LLM response indicates tool use
    pub fn has_tool_calls(&self, data: &Value) -> bool {
        match self {
            Provider::Claude => claude::has_tool_calls(data),
            Provider::OpenAI => openai::has_tool_calls(data),
            Provider::Gemini => gemini::has_tool_calls(data),
            Provider::Generic => false,
        }
    }

    /// Extract tool calls from the LLM response
    pub fn extract_tool_calls(&self, data: &Value) -> Vec<ToolCall> {
        match self {
            Provider::Claude => claude::extract_tool_calls(data),
            Provider::OpenAI => openai::extract_tool_calls(data),
            Provider::Gemini => gemini::extract_tool_calls(data),
            Provider::Generic => vec![],
        }
    }

    /// Build the assistant message to add to conversation from the LLM response
    pub fn build_assistant_message(&self, data: &Value) -> Value {
        match self {
            Provider::Claude => claude::build_assistant_message(data),
            Provider::OpenAI => openai::build_assistant_message(data),
            Provider::Gemini => gemini::build_assistant_message(data),
            Provider::Generic => claude::build_assistant_message(data),
        }
    }

    /// Build the tool results message to add to conversation
    pub fn build_tool_results_message(&self, results: &[(String, String, String)]) -> Value {
        match self {
            Provider::Claude => claude::build_tool_results_message(results),
            Provider::OpenAI => openai::build_tool_results_message(results),
            Provider::Gemini => gemini::build_tool_results_message(results),
            Provider::Generic => claude::build_tool_results_message(results),
        }
    }

    /// Extract final text content from the LLM response
    pub fn extract_text(&self, data: &Value) -> String {
        match self {
            Provider::Claude => claude::extract_text(data),
            Provider::OpenAI => openai::extract_text(data),
            Provider::Gemini => gemini::extract_text(data),
            Provider::Generic => claude::extract_text(data),
        }
    }

    /// Extract normalized token usage from the LLM response
    /// Returns `{"input_tokens": N, "output_tokens": N}` or `Value::Null`
    pub fn extract_usage(&self, data: &Value) -> Value {
        match self {
            Provider::Claude => claude::extract_usage(data),
            Provider::OpenAI => openai::extract_usage(data),
            Provider::Gemini => gemini::extract_usage(data),
            Provider::Generic => claude::extract_usage(data),
        }
    }
}

/// A normalized tool call from any provider
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}
