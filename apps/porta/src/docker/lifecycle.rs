use crate::TrayState;
use std::path::Path;
use std::process::Stdio;
use tauri::Manager;
use tokio::process::Command;
use tracing::info;

/// Docker availability state
pub enum DockerState {
    Ready,
    NotInstalled,
    NotRunning(String),
}

/// Check Docker availability, distinguishing not-installed from not-running.
pub async fn check_docker_state() -> DockerState {
    match Command::new("docker")
        .arg("info")
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .await
    {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => DockerState::NotInstalled,
        Err(e) => DockerState::NotRunning(e.to_string()),
        Ok(output) if !output.status.success() => {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            DockerState::NotRunning(stderr)
        }
        Ok(_) => {
            info!("Docker is available");
            DockerState::Ready
        }
    }
}

/// Start Cyfr via `cyfr up` in the project directory
pub async fn start(app: &tauri::AppHandle, project_dir: &Path) -> Result<String, String> {
    info!("Running cyfr up in {}", project_dir.display());

    let output = crate::cli::run_cyfr(&["up"], project_dir).await?;

    if output.success {
        update_tray_status(app, "Cyfr: Running");
        Ok(output.stdout)
    } else {
        let msg = if output.stderr.is_empty() {
            output.stdout
        } else {
            output.stderr
        };
        Err(format!("cyfr up failed: {}", msg.trim()))
    }
}

/// Stop Cyfr via `cyfr down` in the project directory
pub async fn stop(project_dir: &Path) -> Result<String, String> {
    info!("Running cyfr down in {}", project_dir.display());

    let output = crate::cli::run_cyfr(&["down"], project_dir).await?;

    if output.success {
        Ok(output.stdout)
    } else {
        Err(format!("cyfr down failed: {}", output.stderr.trim()))
    }
}

/// Get the current status of the cyfr container
pub async fn status() -> Result<String, String> {
    let output = Command::new("docker")
        .args(["inspect", "--format", "{{.State.Status}}", "cyfr"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("Failed to inspect container: {}", e))?;

    if !output.status.success() {
        return Ok("not_found".to_string());
    }

    let status = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok(status)
}

fn update_tray_status(app: &tauri::AppHandle, text: &str) {
    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text(text);
    }
}
