use crate::{cli, config, docker, home_dir};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeMode {
    ManagedLocal,
    AttachedDev,
    AttachedRemote,
}

static RUNTIME_MODE: Mutex<RuntimeMode> = Mutex::new(RuntimeMode::AttachedDev);

pub fn set_runtime_mode(mode: RuntimeMode) {
    if let Ok(mut guard) = RUNTIME_MODE.lock() {
        *guard = mode;
    }
}

pub fn runtime_mode() -> RuntimeMode {
    RUNTIME_MODE
        .lock()
        .map(|guard| *guard)
        .unwrap_or(RuntimeMode::ManagedLocal)
}

pub fn should_manage_local_project() -> bool {
    matches!(runtime_mode(), RuntimeMode::ManagedLocal)
}

pub fn should_stop_on_exit() -> bool {
    matches!(runtime_mode(), RuntimeMode::ManagedLocal)
}

pub fn project_dir() -> Result<PathBuf, String> {
    Ok(home_dir()?.join("cyfr"))
}

pub fn home_cwd() -> Result<PathBuf, String> {
    home_dir()
}

pub fn is_local_cyfr_url(url: &str) -> bool {
    let Ok(parsed) = url::Url::parse(url) else {
        return false;
    };

    match parsed.host_str() {
        Some("localhost" | "127.0.0.1" | "0.0.0.0") => true,
        Some("host.docker.internal") => true,
        _ => false,
    }
}

pub async fn detect_runtime_mode(server_healthy: bool) -> RuntimeMode {
    let cyfr_url = config::cyfr_url();
    if !is_local_cyfr_url(&cyfr_url) {
        return RuntimeMode::AttachedRemote;
    }

    if server_healthy {
        match docker::lifecycle::status().await {
            Ok(status) if status == "running" => RuntimeMode::ManagedLocal,
            _ => RuntimeMode::AttachedDev,
        }
    } else {
        RuntimeMode::ManagedLocal
    }
}

pub fn required_project_entries() -> [&'static str; 7] {
    [
        "cyfr.yaml",
        "docker-compose.yml",
        ".env",
        "data",
        "components/catalysts/local",
        "components/reagents/local",
        "components/formulas/local",
    ]
}

pub fn missing_project_entries(project_dir: &Path) -> Vec<&'static str> {
    required_project_entries()
        .into_iter()
        .filter(|entry| !project_dir.join(entry).exists())
        .collect()
}

pub async fn is_authenticated() -> Result<bool, String> {
    let output = cli::run_cyfr(&["whoami", "--json", "--no-interactive"], &home_cwd()?).await?;
    Ok(output.success)
}

pub fn command_cwd(args: &[String]) -> Result<PathBuf, String> {
    match args.first().map(String::as_str) {
        Some("up" | "down" | "init" | "update" | "upgrade") => {
            if should_manage_local_project() {
                project_dir()
            } else {
                Err("This command is only available when Porta manages the local CYFR stack.".to_string())
            }
        }
        _ => home_cwd(),
    }
}
