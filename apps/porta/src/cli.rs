use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::OnceLock;
use std::time::Duration;
use tokio::process::Command;
use tracing::{info, warn};

/// Default timeout for CLI commands (60 seconds).
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);
/// Longer timeout for commands that involve Docker operations.
const LONG_TIMEOUT: Duration = Duration::from_secs(300);

/// Cached absolute path to the cyfr binary, resolved once and reused.
static CLI_PATH: OnceLock<PathBuf> = OnceLock::new();

pub struct CliOutput {
    pub stdout: String,
    pub stderr: String,
    pub success: bool,
}

/// Common directories where cyfr might be installed.
fn candidate_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/opt/homebrew/sbin"),
    ];
    if let Some(home) = dirs::home_dir() {
        dirs.push(home.join(".local/bin"));
    }
    dirs
}

/// Refresh the process PATH — re-reads the user's shell PATH and adds fallback dirs.
/// Call this after installing the CLI so subsequent `Command::new("cyfr")` calls find it.
#[cfg(target_os = "macos")]
pub fn refresh_path() {
    let current = std::env::var("PATH").unwrap_or_default();

    let shell_path = std::process::Command::new("/bin/zsh")
        .args(["-ilc", "echo $PATH"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        });

    let mut parts: Vec<String> = Vec::new();

    // Add shell-detected PATH
    if let Some(sp) = shell_path {
        parts.push(sp);
    }

    // Add all candidate dirs
    for dir in candidate_dirs() {
        let s = dir.display().to_string();
        if !parts.iter().any(|p| p.contains(&s)) {
            parts.push(s);
        }
    }

    // Add current PATH
    parts.push(current);

    std::env::set_var("PATH", parts.join(":"));
    info!("PATH refreshed");
}

#[cfg(not(target_os = "macos"))]
pub fn refresh_path() {
    // On non-macOS, just ensure candidate dirs are in PATH
    let current = std::env::var("PATH").unwrap_or_default();
    let mut extra: Vec<String> = Vec::new();
    for dir in candidate_dirs() {
        let s = dir.display().to_string();
        if !current.contains(&s) {
            extra.push(s);
        }
    }
    if !extra.is_empty() {
        extra.push(current);
        std::env::set_var("PATH", extra.join(":"));
        info!("PATH refreshed");
    }
}

/// Search common install locations for the cyfr binary directly.
/// Returns the absolute path if found.
pub fn find_cli_path() -> Option<PathBuf> {
    // Check cached path first
    if let Some(p) = CLI_PATH.get() {
        if p.exists() {
            return Some(p.clone());
        }
    }

    for dir in candidate_dirs() {
        let candidate = dir.join("cyfr");
        if candidate.exists() {
            info!("Found cyfr at {}", candidate.display());
            let _ = CLI_PATH.set(candidate.clone());
            return Some(candidate);
        }
    }

    None
}

/// Get the command name/path for running cyfr.
/// Uses cached absolute path if available, otherwise falls back to bare "cyfr" (PATH lookup).
pub fn cli_command() -> std::ffi::OsString {
    if let Some(p) = CLI_PATH.get() {
        if p.exists() {
            return p.as_os_str().to_owned();
        }
    }
    std::ffi::OsString::from("cyfr")
}

/// Determine the appropriate timeout for a CLI command.
fn timeout_for(args: &[&str]) -> Duration {
    match args.first().copied() {
        Some("up" | "down" | "upgrade" | "update") => LONG_TIMEOUT,
        _ => DEFAULT_TIMEOUT,
    }
}

/// Run a cyfr CLI command in the given project directory
pub async fn run_cyfr(args: &[&str], project_dir: &Path) -> Result<CliOutput, String> {
    let cmd = cli_command();
    let timeout = timeout_for(args);
    info!(
        "Running: {} {} (in {}, timeout {}s)",
        cmd.to_string_lossy(),
        args.join(" "),
        project_dir.display(),
        timeout.as_secs()
    );

    let fut = Command::new(&cmd)
        .args(args)
        .current_dir(project_dir)
        .env("COMPOSE_PROJECT_NAME", "cyfr")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();

    let output = tokio::time::timeout(timeout, fut)
        .await
        .map_err(|_| format!("cyfr {} timed out after {}s", args.join(" "), timeout.as_secs()))?
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

/// Check if cyfr CLI is installed, returns version string if found.
/// Uses a 10-second timeout to prevent hanging on corrupted binaries.
pub async fn check_cli() -> Option<String> {
    let cmd = cli_command();
    let output = tokio::time::timeout(
        Duration::from_secs(10),
        Command::new(&cmd)
            .args(["--version"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output(),
    )
    .await
    .ok()? // timeout
    .ok()?; // io error

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
        .args(["install", "cyfrworks/cyfr/cyfr"])
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

/// Install cyfr CLI via the install script (curl | sh).
/// Fallback for systems without Homebrew — works on macOS and Linux.
pub async fn install_cli_script() -> Result<CliOutput, String> {
    let curl_check = Command::new("curl")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .await;

    if curl_check.is_err() || !curl_check.unwrap().status.success() {
        return Err("curl not found".to_string());
    }

    info!("Installing cyfr via install script...");

    let output = Command::new("sh")
        .args([
            "-c",
            "curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("Failed to run install script: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    Ok(CliOutput {
        stdout,
        stderr,
        success: output.status.success(),
    })
}
