use super::http::HttpBackend;
use super::stdio::StdioBackend;
use super::{BackendStatus, McpBackend};
use crate::config::BackendConfig;
use crate::gateway::types::Tool;
use std::collections::HashMap;
use tracing::{error, info};

/// Manages all MCP backend lifecycles
pub struct BackendRegistry {
    backends: HashMap<String, Box<dyn McpBackend>>,
}

impl BackendRegistry {
    pub fn new() -> Self {
        Self {
            backends: HashMap::new(),
        }
    }

    /// Start a backend from config
    pub async fn start_backend(&mut self, cfg: &BackendConfig) -> Result<(), String> {
        info!("Starting backend '{}' (type: {})", cfg.name, cfg.backend_type);

        let mut backend: Box<dyn McpBackend> = match cfg.backend_type.as_str() {
            "stdio" => {
                let command = cfg
                    .command
                    .as_ref()
                    .ok_or_else(|| format!("Backend '{}' missing 'command'", cfg.name))?;
                Box::new(StdioBackend::new(
                    cfg.name.clone(),
                    command.clone(),
                    cfg.args.clone(),
                    cfg.env.clone(),
                ))
            }
            "http" => {
                let url = cfg
                    .url
                    .as_ref()
                    .ok_or_else(|| format!("Backend '{}' missing 'url'", cfg.name))?;
                Box::new(HttpBackend::new(
                    cfg.name.clone(),
                    url.clone(),
                    cfg.headers.clone(),
                ))
            }
            other => {
                return Err(format!("Unknown backend type: '{}'", other));
            }
        };

        if let Err(e) = backend.initialize().await {
            error!("Failed to initialize backend '{}': {}", cfg.name, e);
            // Still add to registry so it can be retried
        }

        self.backends.insert(cfg.name.clone(), backend);
        Ok(())
    }

    /// Stop and remove a backend
    pub async fn stop_backend(&mut self, name: &str) -> Result<(), String> {
        if let Some(mut backend) = self.backends.remove(name) {
            backend.shutdown().await?;
        }
        Ok(())
    }

    /// Get a reference to a backend by name
    pub fn get(&self, name: &str) -> Option<&dyn McpBackend> {
        self.backends.get(name).map(|b| b.as_ref())
    }

    /// List all tools from all ready backends, prefixed with backend name
    pub async fn list_all_tools(&self) -> Vec<Tool> {
        let mut all_tools = Vec::new();

        for (backend_name, backend) in &self.backends {
            if backend.status() != BackendStatus::Ready {
                continue;
            }

            let tools = backend.tools().await;
            for tool in tools {
                all_tools.push(Tool {
                    name: format!("{}__{}", backend_name, tool.name),
                    description: tool.description.as_ref().map(|d| {
                        format!("[{}] {}", backend_name, d)
                    }),
                    input_schema: tool.input_schema.clone(),
                });
            }
        }

        all_tools
    }

    /// Get status of all backends
    pub fn statuses(&self) -> Vec<BackendInfo> {
        self.backends
            .iter()
            .map(|(name, backend)| BackendInfo {
                name: name.clone(),
                backend_type: backend.backend_type().to_string(),
                status: backend.status(),
                tool_count: 0, // Will be filled by caller
            })
            .collect()
    }

    /// Get status of all backends with tool counts
    pub async fn statuses_with_tools(&self) -> Vec<BackendInfo> {
        let mut infos = Vec::new();

        for (name, backend) in &self.backends {
            infos.push(BackendInfo {
                name: name.clone(),
                backend_type: backend.backend_type().to_string(),
                status: backend.status(),
                tool_count: backend.tools().await.len(),
            });
        }

        infos
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct BackendInfo {
    pub name: String,
    pub backend_type: String,
    pub status: BackendStatus,
    pub tool_count: usize,
}
