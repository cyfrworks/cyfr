use super::{BackendStatus, McpBackend};
use crate::gateway::types::{Tool, ToolCallResult};
use crate::VERSION;
use async_trait::async_trait;
use serde_json::Value;
use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{oneshot, Mutex};
use tracing::{error, info, warn};

pub struct StdioBackend {
    name: String,
    command: String,
    args: Vec<String>,
    env: HashMap<String, String>,
    status: BackendStatus,
    tools: Vec<Tool>,
    child: Option<Child>,
    stdin: Option<Arc<Mutex<tokio::process::ChildStdin>>>,
    pending: Arc<Mutex<HashMap<i64, oneshot::Sender<Value>>>>,
    next_id: Arc<AtomicI64>,
}

impl StdioBackend {
    pub fn new(
        name: String,
        command: String,
        args: Vec<String>,
        env: HashMap<String, String>,
    ) -> Self {
        Self {
            name,
            command,
            args,
            env,
            status: BackendStatus::Disconnected,
            tools: Vec::new(),
            child: None,
            stdin: None,
            pending: Arc::new(Mutex::new(HashMap::new())),
            next_id: Arc::new(AtomicI64::new(1)),
        }
    }

    /// Send a JSON-RPC request and wait for a response
    async fn send_request(&self, method: &str, params: Value) -> Result<Value, String> {
        let stdin = self
            .stdin
            .as_ref()
            .ok_or("Backend not started")?;

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);

        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        });

        let mut line = serde_json::to_string(&request)
            .map_err(|e| format!("Failed to serialize request: {}", e))?;
        line.push('\n');

        // Register pending response
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = self.pending.lock().await;
            pending.insert(id, tx);
        }

        // Write to stdin
        {
            let mut stdin = stdin.lock().await;
            stdin
                .write_all(line.as_bytes())
                .await
                .map_err(|e| format!("Failed to write to stdin: {}", e))?;
            stdin
                .flush()
                .await
                .map_err(|e| format!("Failed to flush stdin: {}", e))?;
        }

        // Wait for response with timeout
        let result = tokio::time::timeout(std::time::Duration::from_secs(30), rx)
            .await
            .map_err(|_| format!("Timeout waiting for response to {}", method))?
            .map_err(|_| "Response channel closed".to_string())?;

        // Check for error in response
        if let Some(error) = result.get("error") {
            let message = error
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("Unknown error");
            return Err(message.to_string());
        }

        Ok(result.get("result").cloned().unwrap_or(Value::Null))
    }

    /// Send a notification (no response expected)
    async fn send_notification(&self, method: &str) -> Result<(), String> {
        let stdin = self
            .stdin
            .as_ref()
            .ok_or("Backend not started")?;

        let notification = serde_json::json!({
            "jsonrpc": "2.0",
            "method": method
        });

        let mut line = serde_json::to_string(&notification)
            .map_err(|e| format!("Failed to serialize notification: {}", e))?;
        line.push('\n');

        let mut stdin = stdin.lock().await;
        stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|e| format!("Failed to write notification: {}", e))?;
        stdin
            .flush()
            .await
            .map_err(|e| format!("Failed to flush stdin: {}", e))?;

        Ok(())
    }

    fn spawn_stdout_reader(
        stdout: tokio::process::ChildStdout,
        pending: Arc<Mutex<HashMap<i64, oneshot::Sender<Value>>>>,
        name: String,
    ) {
        tokio::spawn(async move {
            let reader = BufReader::new(stdout);
            let mut lines = reader.lines();

            while let Ok(Some(line)) = lines.next_line().await {
                let parsed: Result<Value, _> = serde_json::from_str(&line);
                match parsed {
                    Ok(msg) => {
                        if let Some(id) = msg.get("id").and_then(|id| id.as_i64()) {
                            let mut pending = pending.lock().await;
                            if let Some(sender) = pending.remove(&id) {
                                let _ = sender.send(msg);
                            }
                        }
                        // Notifications from server (no id) are logged but ignored
                    }
                    Err(e) => {
                        warn!("[{}] Failed to parse stdout line: {}", name, e);
                    }
                }
            }

            info!("[{}] stdout reader exited", name);
        });
    }

    fn spawn_stderr_reader(stderr: tokio::process::ChildStderr, name: String) {
        tokio::spawn(async move {
            let reader = BufReader::new(stderr);
            let mut lines = reader.lines();

            while let Ok(Some(line)) = lines.next_line().await {
                warn!("[{}] stderr: {}", name, line);
            }
        });
    }
}

#[async_trait]
impl McpBackend for StdioBackend {
    fn name(&self) -> &str {
        &self.name
    }

    fn backend_type(&self) -> &str {
        "stdio"
    }

    async fn initialize(&mut self) -> Result<(), String> {
        self.status = BackendStatus::Starting;

        info!("[{}] Spawning: {} {:?}", self.name, self.command, self.args);

        let mut child = Command::new(&self.command)
            .args(&self.args)
            .envs(&self.env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| {
                self.status = BackendStatus::Error(e.to_string());
                format!("Failed to spawn '{}': {}", self.command, e)
            })?;

        let stdout = child.stdout.take().ok_or("No stdout")?;
        let stderr = child.stderr.take().ok_or("No stderr")?;
        let stdin = child.stdin.take().ok_or("No stdin")?;

        self.stdin = Some(Arc::new(Mutex::new(stdin)));
        self.child = Some(child);

        // Spawn background readers
        Self::spawn_stdout_reader(stdout, self.pending.clone(), self.name.clone());
        Self::spawn_stderr_reader(stderr, self.name.clone());

        // MCP handshake: initialize
        let init_result = self
            .send_request(
                "initialize",
                serde_json::json!({
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {
                        "name": "aqua",
                        "version": VERSION
                    }
                }),
            )
            .await?;

        info!("[{}] Initialize response: {:?}", self.name, init_result);

        // Send initialized notification
        self.send_notification("notifications/initialized").await?;

        // Discover tools
        let tools_result = self
            .send_request("tools/list", serde_json::json!({}))
            .await?;

        let tools: Vec<Tool> = if let Some(tools_arr) = tools_result.get("tools") {
            serde_json::from_value(tools_arr.clone()).unwrap_or_default()
        } else {
            Vec::new()
        };

        info!("[{}] Discovered {} tools", self.name, tools.len());
        self.tools = tools;
        self.status = BackendStatus::Ready;

        Ok(())
    }

    async fn tools(&self) -> &[Tool] {
        &self.tools
    }

    async fn call_tool(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> Result<ToolCallResult, String> {
        if self.status != BackendStatus::Ready {
            return Err(format!("Backend '{}' is not ready", self.name));
        }

        let result = self
            .send_request(
                "tools/call",
                serde_json::json!({
                    "name": name,
                    "arguments": arguments
                }),
            )
            .await?;

        serde_json::from_value(result.clone()).map_err(|e| {
            error!("[{}] Failed to parse tool result: {}", self.name, e);
            format!("Invalid tool result: {}", e)
        })
    }

    async fn shutdown(&mut self) -> Result<(), String> {
        self.stdin = None;

        if let Some(mut child) = self.child.take() {
            let _ = child.kill().await;
        }

        self.status = BackendStatus::Disconnected;
        info!("[{}] Shutdown complete", self.name);
        Ok(())
    }

    fn status(&self) -> BackendStatus {
        self.status.clone()
    }
}
