use serde_json::{json, Value};

use crate::bindings::cyfr::mcp::tools;

/// Build the system prompt by loading CYFR context (MCP tools, guides)
/// and prepending it to the caller's system prompt.
///
/// The formula is not opinionated about identity — it provides the
/// platform context and lets the caller define the agent's role via
/// the `system` input field.
pub fn build_system_prompt(
    project_path: &str,
    custom_system: Option<&str>,
) -> String {
    let mut sections = Vec::new();

    // Platform context — what tools and capabilities are available
    sections.push(
        "You are an agent running inside CYFR, a governed computation platform. \
         You have access to tools for interacting with files and CYFR components."
            .to_string(),
    );

    // Project context
    if !project_path.is_empty() {
        sections.push(format!(
            "Working directory: `{}`\nFile paths are relative to this root.",
            project_path
        ));
    }

    // Fetch and inject available MCP tools
    if let Some(tools_info) = fetch_mcp_tools() {
        sections.push(format!(
            "## CYFR Platform Tools\n\n\
             The following tools are available in this CYFR instance. \
             You can discover and invoke components from the registry.\n\n\
             {}",
            tools_info
        ));
    }

    // Fetch and inject guides (if available)
    if let Some(guide) = fetch_guide("component-guide") {
        let truncated = truncate_guide(&guide, 40000);
        sections.push(format!("## Component Guide\n\n{}", truncated));
    }

    if let Some(guide) = fetch_guide("integration-guide") {
        let truncated = truncate_guide(&guide, 20000);
        sections.push(format!("## Integration Guide\n\n{}", truncated));
    }

    // Caller's system prompt — appended so it can override/extend
    if let Some(custom) = custom_system {
        if !custom.is_empty() {
            sections.push(custom.to_string());
        }
    }

    sections.join("\n\n")
}

fn truncate_guide(guide: &str, max_len: usize) -> String {
    if guide.len() > max_len {
        format!(
            "{}\n\n[... truncated for context efficiency ...]",
            &guide[..max_len]
        )
    } else {
        guide.to_string()
    }
}

fn fetch_mcp_tools() -> Option<String> {
    let request = json!({
        "tool": "tools",
        "action": "list"
    });

    let response_str = tools::call(&request.to_string());
    let response: Value = serde_json::from_str(&response_str).ok()?;

    if response.get("error").is_some() {
        return None;
    }

    let result = response.get("result")?;
    let formatted = serde_json::to_string_pretty(result).ok()?;

    if formatted.len() > 50000 {
        Some(format!("{}\n[... truncated ...]", &formatted[..50000]))
    } else {
        Some(formatted)
    }
}

fn fetch_guide(name: &str) -> Option<String> {
    let request = json!({
        "tool": "guide",
        "action": "get",
        "args": { "name": name }
    });

    let response_str = tools::call(&request.to_string());
    let response: Value = serde_json::from_str(&response_str).ok()?;

    if response.get("error").is_some() {
        return None;
    }

    let result = response.get("result")?;

    if let Some(content) = result.as_str() {
        Some(content.to_string())
    } else if let Some(content) = result.get("content").and_then(|v| v.as_str()) {
        Some(content.to_string())
    } else {
        None
    }
}
