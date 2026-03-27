use crate::TrayState;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tauri::Manager;
use tokio::process::Command;
use tracing::info;

/// Docker availability state
pub enum DockerState {
    Ready,
    NotInstalled,
    NotRunning(String),
}

/// Known locations where Docker Desktop may install the CLI binary on macOS.
#[cfg(target_os = "macos")]
fn docker_cli_candidates() -> Vec<std::path::PathBuf> {
    let mut paths = vec![
        std::path::PathBuf::from("/usr/local/bin/docker"),
        std::path::PathBuf::from("/opt/homebrew/bin/docker"),
        // Inside Docker.app bundle — available before Desktop creates symlinks
        std::path::PathBuf::from("/Applications/Docker.app/Contents/Resources/bin/docker"),
    ];
    if let Some(home) = dirs::home_dir() {
        // Docker Desktop 4.x+ installs CLI tools here
        paths.push(home.join(".docker/bin/docker"));
    }
    paths
}

/// Timeout for docker info/inspect commands (prevents hanging on unresponsive daemon).
const DOCKER_CMD_TIMEOUT: Duration = Duration::from_secs(15);

/// Check Docker availability, distinguishing not-installed from not-running.
pub async fn check_docker_state() -> DockerState {
    let result = tokio::time::timeout(
        DOCKER_CMD_TIMEOUT,
        Command::new(super::docker_command())
            .arg("info")
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output(),
    )
    .await;

    let output = match result {
        Err(_) => {
            // Timeout — daemon is not responding
            return DockerState::NotRunning(
                "Docker is not responding (timed out). Please restart Docker.".to_string(),
            );
        }
        Ok(inner) => inner,
    };

    match output {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            // `docker` binary not in PATH — check if Docker Desktop is actually installed
            #[cfg(target_os = "macos")]
            {
                // If Docker.app exists, Docker is installed but CLI isn't in PATH
                // or Docker Desktop hasn't been opened yet to create symlinks.
                if Path::new("/Applications/Docker.app").exists() {
                    info!("Docker.app found but `docker` binary not in PATH");
                    return DockerState::NotRunning(
                        "Docker Desktop is installed but the CLI is not in PATH. \
                         Please start Docker Desktop."
                            .to_string(),
                    );
                }

                // Also check if the docker binary exists in known locations
                // but just isn't in PATH
                for candidate in docker_cli_candidates() {
                    if candidate.exists() {
                        info!(
                            "Found docker binary at {} (not in PATH)",
                            candidate.display()
                        );
                        // Use the absolute path directly — avoids unsafe set_var in async context
                        return check_docker_info_at(&candidate).await;
                    }
                }
            }
            DockerState::NotInstalled
        }
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

/// Run `docker info` using an absolute path to the docker binary.
/// Used when docker is found at a known location but isn't in PATH.
async fn check_docker_info_at(docker_path: &std::path::Path) -> DockerState {
    let result = tokio::time::timeout(
        DOCKER_CMD_TIMEOUT,
        Command::new(docker_path)
            .arg("info")
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output(),
    )
    .await;

    match result {
        Err(_) => DockerState::NotRunning(
            "Docker is not responding (timed out). Please restart Docker.".to_string(),
        ),
        Ok(Err(e)) => DockerState::NotRunning(e.to_string()),
        Ok(Ok(output)) if !output.status.success() => {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            DockerState::NotRunning(stderr)
        }
        Ok(Ok(_)) => {
            info!("Docker is available (via {})", docker_path.display());
            DockerState::Ready
        }
    }
}

/// Start Cyfr via `cyfr up` in the project directory
pub async fn start(app: &tauri::AppHandle, project_dir: &Path) -> Result<String, String> {
    info!("Running cyfr up in {}", project_dir.display());

    let output = crate::cli::run_cyfr(&["up"], project_dir).await?;

    if output.success {
        update_tray_status(app, "CYFR: Running");
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

/// Start Cyfr via `cyfr up` with streaming output.
/// Uses an idle timeout instead of a hard timeout — the timer resets on each
/// output line, so Docker image pulls keep the process alive as long as
/// progress is flowing. Preferred over `start()` when progress visibility matters.
pub async fn start_streaming<F>(
    app: &tauri::AppHandle,
    project_dir: &Path,
    idle_timeout_secs: u64,
    on_line: F,
) -> Result<String, String>
where
    F: Fn(&str, &str) + Send,
{
    info!("Running cyfr up (streaming) in {}", project_dir.display());

    let output = crate::cli::run_cyfr_streaming(
        &["up"],
        project_dir,
        idle_timeout_secs,
        on_line,
    )
    .await?;

    if output.success {
        update_tray_status(app, "CYFR: Running");
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
pub async fn stop(app: &tauri::AppHandle, project_dir: &Path) -> Result<String, String> {
    info!("Running cyfr down in {}", project_dir.display());
    update_tray_status(app, "CYFR: Stopping...");

    let output = crate::cli::run_cyfr(&["down"], project_dir).await?;

    if output.success {
        update_tray_status(app, "CYFR: Stopped");
        Ok(output.stdout)
    } else {
        update_tray_status(app, "CYFR: Error");
        Err(format!("cyfr down failed: {}", output.stderr.trim()))
    }
}

/// Get the current status of the cyfr container
pub async fn status() -> Result<String, String> {
    let output = tokio::time::timeout(
        DOCKER_CMD_TIMEOUT,
        Command::new(super::docker_command())
            .args(["inspect", "--format", "{{.State.Status}}", "cyfr"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output(),
    )
    .await
    .map_err(|_| "Docker inspect timed out — daemon may be unresponsive".to_string())?
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
