use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const DEFAULT_CYFR_URL: &str = "http://localhost:4000";

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PortaConfig {
    #[serde(default, rename = "mcpServers")]
    pub mcp_servers: HashMap<String, ServerConfig>,

    /// Base URL for the Cyfr server. Defaults to http://localhost:4000.
    /// Set this when Cyfr runs on a remote host or non-default port.
    #[serde(default, rename = "cyfrUrl", skip_serializing_if = "Option::is_none")]
    pub cyfr_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    // stdio backend fields
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub env: HashMap<String, String>,
    // http backend fields
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub headers: HashMap<String, String>,
    // shared
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_true() -> bool {
    true
}

impl ServerConfig {
    /// Determine backend type from config fields
    pub fn backend_type(&self) -> &str {
        if self.command.is_some() {
            "stdio"
        } else {
            "http"
        }
    }
}

/// Gateway config is hardcoded — port 9500, bind 127.0.0.1
pub const GATEWAY_PORT: u16 = 9500;
pub const GATEWAY_BIND: &str = "127.0.0.1";

/// Convert ServerConfig to the BackendConfig format used by BackendRegistry
pub fn to_backend_config(name: &str, cfg: &ServerConfig) -> BackendConfig {
    BackendConfig {
        name: name.to_string(),
        backend_type: cfg.backend_type().to_string(),
        command: cfg.command.clone(),
        args: cfg.args.clone(),
        env: cfg.env.clone(),
        url: cfg.url.clone(),
        headers: cfg.headers.clone(),
        enabled: cfg.enabled,
    }
}

/// Legacy BackendConfig struct used by BackendRegistry
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackendConfig {
    pub name: String,
    #[serde(rename = "type")]
    pub backend_type: String,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub headers: HashMap<String, String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
}
