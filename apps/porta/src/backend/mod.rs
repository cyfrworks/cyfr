pub mod http;
pub mod registry;
pub mod stdio;

use crate::gateway::types::{Tool, ToolCallResult};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum BackendStatus {
    Starting,
    Ready,
    Disconnected,
    Error(String),
}

/// Trait that all MCP backends must implement
#[async_trait]
pub trait McpBackend: Send + Sync {
    /// Unique name for this backend
    fn name(&self) -> &str;

    /// Backend type identifier ("stdio" or "http")
    fn backend_type(&self) -> &str;

    /// Initialize the backend connection and discover tools
    async fn initialize(&mut self) -> Result<(), String>;

    /// Return the list of tools this backend provides
    async fn tools(&self) -> &[Tool];

    /// Call a tool on this backend
    async fn call_tool(&self, name: &str, arguments: serde_json::Value)
        -> Result<ToolCallResult, String>;

    /// Shutdown the backend gracefully
    async fn shutdown(&mut self) -> Result<(), String>;

    /// Current connection status
    fn status(&self) -> BackendStatus;
}
