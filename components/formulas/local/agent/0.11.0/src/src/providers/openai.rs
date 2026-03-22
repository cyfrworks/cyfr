//! OpenAI provider — uses the Responses API (/v1/responses) with web_search.
//!
//! The Responses API format is shared with Grok. This module re-exports
//! the shared functions from grok.rs and provides OpenAI-specific tool formatting.

pub use super::grok::{
    build_assistant_message, build_request, build_tool_results_message, extract_text,
    extract_tool_calls, extract_usage, format_tools_openai as format_tools, has_tool_calls,
};
