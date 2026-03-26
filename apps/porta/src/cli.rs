use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::OnceLock;
use tokio::process::Command;
use tracing::{info, warn};

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
fn cli_command() -> std::ffi::OsString {
    if let Some(p) = CLI_PATH.get() {
        if p.exists() {
            return p.as_os_str().to_owned();
        }
    }
    std::ffi::OsString::from("cyfr")
}

/// Run a cyfr CLI command in the given project directory
pub async fn run_cyfr(args: &[&str], project_dir: &Path) -> Result<CliOutput, String> {
    let cmd = cli_command();
    info!(
        "Running: {} {} (in {})",
        cmd.to_string_lossy(),
        args.join(" "),
        project_dir.display()
    );

    let output = Command::new(&cmd)
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

/// Check if cyfr CLI is installed, returns version string if found.
/// Also caches the resolved path for future calls.
pub async fn check_cli() -> Option<String> {
    let cmd = cli_command();
    let output = Command::new(&cmd)
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
