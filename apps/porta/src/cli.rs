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

/// Common directories where cyfr or docker might be installed.
fn candidate_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/opt/homebrew/sbin"),
    ];
    if let Some(home) = dirs::home_dir() {
        dirs.push(home.join(".local/bin"));
        // Newer Docker Desktop (4.x+) installs CLI tools here
        dirs.push(home.join(".docker/bin"));
    }
    dirs
}

/// Refresh the process PATH — re-reads the user's shell PATH and adds fallback dirs.
/// Call this after installing the CLI so subsequent `Command::new("cyfr")` calls find it.
#[cfg(target_os = "macos")]
pub fn refresh_path() {
    let current = std::env::var("PATH").unwrap_or_default();

    // Use login shell (-lc) NOT interactive (-ilc) to avoid hangs from
    // .zshrc hooks (nvm, conda, oh-my-zsh, etc.). Login mode sources
    // .zprofile/.zlogin where PATH additions live.
    let shell_path = {
        let mut child = match std::process::Command::new("/bin/zsh")
            .args(["-lc", "echo $PATH"])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                warn!("Failed to spawn zsh for PATH detection: {}", e);
                // Fall through — rely on candidate_dirs below
                return;
            }
        };

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            match child.try_wait() {
                Ok(Some(status)) if status.success() => {
                    break child.stdout.take().and_then(|mut out| {
                        let mut s = String::new();
                        use std::io::Read;
                        out.read_to_string(&mut s).ok()?;
                        let trimmed = s.trim().to_string();
                        if trimmed.is_empty() { None } else { Some(trimmed) }
                    });
                }
                Ok(Some(_)) => break None, // exited non-zero
                Ok(None) => {
                    if std::time::Instant::now() >= deadline {
                        warn!("zsh PATH detection timed out after 5s, killing");
                        let _ = child.kill();
                        let _ = child.wait();
                        break None;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(_) => break None,
            }
        }
    };

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
        Some("up" | "down" | "upgrade" | "update" | "init") => LONG_TIMEOUT,
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
/// Used on Linux where /usr/local/bin is the standard install target.
#[cfg(not(target_os = "macos"))]
pub async fn install_cli_direct() -> Result<CliOutput, String> {
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

const GITHUB_REPO: &str = "cyfrworks/cyfr";

/// Install cyfr CLI by downloading the binary directly from GitHub releases.
/// This gives full control over install location, ensuring the binary goes to
/// a directory in the user's terminal PATH (not just Porta's internal PATH).
#[cfg(target_os = "macos")]
pub async fn install_cli_direct() -> Result<CliOutput, String> {
    let arch = match std::env::consts::ARCH {
        "aarch64" => "arm64",
        "x86_64" => "amd64",
        other => return Err(format!("Unsupported architecture: {}", other)),
    };

    // Step 1: Resolve latest CLI version from GitHub releases
    info!("Resolving latest cyfr CLI version...");
    let version = resolve_latest_cli_version().await?;
    info!("Latest cyfr CLI version: {}", version);

    let archive_name = format!("cyfr_{}_darwin_{}.tar.gz", version, arch);
    let base_url = format!(
        "https://github.com/{}/releases/download/v{}",
        GITHUB_REPO, version
    );

    let tmpdir = std::env::temp_dir().join("cyfr-cli-install");
    let _ = std::fs::remove_dir_all(&tmpdir);
    std::fs::create_dir_all(&tmpdir)
        .map_err(|e| format!("Failed to create temp dir: {}", e))?;

    let archive_path = tmpdir.join(&archive_name);
    let checksums_path = tmpdir.join("checksums.txt");

    // Step 2: Download tarball and checksums
    info!("Downloading {}...", archive_name);
    let client = reqwest::Client::new();

    download_file(&client, &format!("{}/{}", base_url, archive_name), &archive_path).await?;
    download_file(&client, &format!("{}/checksums.txt", base_url), &checksums_path).await?;

    // Step 3: Verify SHA256 checksum
    info!("Verifying checksum...");
    verify_checksum(&archive_path, &checksums_path, &archive_name).await?;

    // Step 4: Extract tarball
    info!("Extracting...");
    let tar_output = Command::new("tar")
        .args(["-xzf"])
        .arg(&archive_path)
        .arg("-C")
        .arg(&tmpdir)
        .output()
        .await
        .map_err(|e| format!("Failed to extract archive: {}", e))?;

    if !tar_output.status.success() {
        let stderr = String::from_utf8_lossy(&tar_output.stderr);
        let _ = std::fs::remove_dir_all(&tmpdir);
        return Err(format!("Failed to extract archive: {}", stderr.trim()));
    }

    let binary_src = tmpdir.join("cyfr");
    if !binary_src.exists() {
        let _ = std::fs::remove_dir_all(&tmpdir);
        return Err("Extracted archive does not contain cyfr binary".to_string());
    }

    // Step 5: Copy binary to install dir
    let install_dir = resolve_install_dir();
    let dest = install_dir.join("cyfr");
    info!("Installing cyfr to {}", dest.display());

    // Try direct copy first
    let installed = if is_writable(&install_dir) {
        std::fs::copy(&binary_src, &dest).is_ok()
    } else {
        false
    };

    if !installed {
        // Need elevated permissions — use osascript on macOS
        info!("Requesting admin privileges to install to {}", install_dir.display());
        let admin_output = Command::new("osascript")
            .args([
                "-e",
                &format!(
                    r#"do shell script "cp '{}' '{}' && chmod +x '{}'" with administrator privileges"#,
                    binary_src.display(),
                    dest.display(),
                    dest.display()
                ),
            ])
            .output()
            .await
            .map_err(|e| format!("Failed to run osascript: {}", e))?;

        if !admin_output.status.success() {
            let _ = std::fs::remove_dir_all(&tmpdir);
            return Err(format!(
                "Could not install to {}. Please install manually from: https://github.com/{}/releases",
                install_dir.display(),
                GITHUB_REPO
            ));
        }
    } else {
        // Set executable permission
        let _ = Command::new("chmod")
            .args(["+x"])
            .arg(&dest)
            .output()
            .await;
    }

    // Cache the installed path
    let _ = CLI_PATH.set(dest.clone());

    // Cleanup
    let _ = std::fs::remove_dir_all(&tmpdir);

    let msg = format!("cyfr v{} installed to {}", version, dest.display());
    info!("{}", msg);

    Ok(CliOutput {
        stdout: msg,
        stderr: String::new(),
        success: true,
    })
}

/// Resolve the latest CLI release version from GitHub API.
/// Skips porta-v* tags and finds the first v* tag.
async fn resolve_latest_cli_version() -> Result<String, String> {
    let client = reqwest::Client::builder()
        .user_agent("cyfr-porta")
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let url = format!(
        "https://api.github.com/repos/{}/releases?per_page=20",
        GITHUB_REPO
    );

    let resp: Vec<serde_json::Value> = client
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("GitHub API request failed: {}", e))?
        .json()
        .await
        .map_err(|e| format!("Failed to parse GitHub releases: {}", e))?;

    for release in &resp {
        if let Some(tag) = release.get("tag_name").and_then(|t| t.as_str()) {
            if tag.starts_with("porta-") {
                continue;
            }
            if let Some(version) = tag.strip_prefix('v') {
                return Ok(version.to_string());
            }
        }
    }

    Err("Could not determine latest cyfr CLI version from GitHub releases".to_string())
}

/// Download a file from a URL to a local path.
async fn download_file(
    client: &reqwest::Client,
    url: &str,
    dest: &Path,
) -> Result<(), String> {
    let resp = client
        .get(url)
        .send()
        .await
        .map_err(|e| format!("Download failed: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("Download failed: HTTP {} for {}", resp.status(), url));
    }

    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("Download read failed: {}", e))?;

    tokio::fs::write(dest, &bytes)
        .await
        .map_err(|e| format!("Failed to write {}: {}", dest.display(), e))?;

    Ok(())
}

/// Verify SHA256 checksum of a file against checksums.txt.
async fn verify_checksum(
    file: &Path,
    checksums_file: &Path,
    archive_name: &str,
) -> Result<(), String> {
    // Read expected checksum from checksums.txt
    let checksums = tokio::fs::read_to_string(checksums_file)
        .await
        .map_err(|e| format!("Failed to read checksums: {}", e))?;

    let expected = checksums
        .lines()
        .find(|line| line.contains(archive_name))
        .and_then(|line| line.split_whitespace().next())
        .ok_or_else(|| format!("Checksum not found for {}", archive_name))?
        .to_string();

    // Compute actual checksum using shasum (always available on macOS)
    let output = Command::new("shasum")
        .args(["-a", "256"])
        .arg(file)
        .output()
        .await
        .map_err(|e| format!("Failed to run shasum: {}", e))?;

    if !output.status.success() {
        return Err("shasum failed".to_string());
    }

    let actual = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_string();

    if expected != actual {
        return Err(format!(
            "Checksum mismatch for {}:\n  expected: {}\n  actual:   {}",
            archive_name, expected, actual
        ));
    }

    info!("Checksum verified for {}", archive_name);
    Ok(())
}

/// Pick the best install directory for the cyfr CLI binary.
/// Prefers standard PATH locations so the binary is usable from terminal.
fn resolve_install_dir() -> PathBuf {
    let candidates = [
        PathBuf::from("/opt/homebrew/bin"),  // Apple Silicon Homebrew
        PathBuf::from("/usr/local/bin"),     // Intel Mac / standard
    ];
    for dir in &candidates {
        if dir.exists() && is_writable(dir) {
            return dir.clone();
        }
    }
    // Fallback — user-local (may not be in default terminal PATH)
    let local_bin = dirs::home_dir()
        .expect("could not determine home directory")
        .join(".local/bin");
    let _ = std::fs::create_dir_all(&local_bin);
    local_bin
}

/// Test if a directory is writable by the current user.
fn is_writable(path: &Path) -> bool {
    let test = path.join(".cyfr_write_test");
    match std::fs::File::create(&test) {
        Ok(_) => {
            let _ = std::fs::remove_file(&test);
            true
        }
        Err(_) => false,
    }
}
