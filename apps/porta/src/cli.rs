use std::path::Path;
use std::process::Stdio;
use tokio::process::Command;
use tracing::{info, warn};

pub struct CliOutput {
    pub stdout: String,
    pub stderr: String,
    pub success: bool,
}

/// Run a cyfr CLI command in the given project directory
pub async fn run_cyfr(args: &[&str], project_dir: &Path) -> Result<CliOutput, String> {
    info!("Running: cyfr {} (in {})", args.join(" "), project_dir.display());

    let output = Command::new("cyfr")
        .args(args)
        .current_dir(project_dir)
        .env("COMPOSE_PROJECT_NAME", "cyfr")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("Failed to run cyfr: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if !stdout.is_empty() {
        info!("cyfr stdout: {}", stdout.trim());
    }
    if !stderr.is_empty() {
        warn!("cyfr stderr: {}", stderr.trim());
    }

    Ok(CliOutput {
        stdout,
        stderr,
        success: output.status.success(),
    })
}

/// Check if cyfr CLI is installed, returns version string if found
pub async fn check_cli() -> Option<String> {
    let output = Command::new("cyfr")
        .args(["--version"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .ok()?;

    if output.status.success() {
        let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
        Some(version)
    } else {
        None
    }
}

/// Install cyfr CLI via Homebrew
pub async fn install_cli_brew() -> Result<CliOutput, String> {
    // Check if brew is available
    let brew_check = Command::new("brew")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .await;

    if brew_check.is_err() || !brew_check.unwrap().status.success() {
        return Err("Homebrew not found".to_string());
    }

    info!("Installing cyfr via Homebrew...");

    let output = Command::new("brew")
        .args(["install", "--cask", "cyfrworks/cyfr/cyfr"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("Failed to run brew: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    Ok(CliOutput {
        stdout,
        stderr,
        success: output.status.success(),
    })
}
