/// Build the system prompt — passthrough only.
///
/// The caller (LiveView, CLI, etc.) is responsible for composing the full
/// system prompt including platform context, MCP tools, guides, etc.
/// This formula just uses it as-is.
pub fn build_system_prompt(system: Option<&str>) -> String {
    system.unwrap_or("").to_string()
}
