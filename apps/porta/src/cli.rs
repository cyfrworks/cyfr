use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tracing::{info, warn};

/// Default timeout for CLI commands (60 seconds).
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);
/// Longer timeout for commands that involve Docker operations.
const LONG_TIMEOUT: Duration = Duration::from_secs(300);

/// Cached absolute path to the cyfr binary. Resettable (e.g., after upgrade).
static CLI_PATH: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Clear the cached CLI path so it is re-resolved on next use.
/// Call after upgrade to pick up a potentially relocated binary.
pub fn clear_cli_cache() {
    if let Ok(mut guard) = CLI_PATH.lock() {
        *guard = None;
    }
}

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

/// Detect the user's default shell and build the command to read its full PATH.
///
/// Uses `$SHELL` to respect the user's configured shell. Sources the shell's
/// RC file (`.zshrc`, `.bashrc`) explicitly so tool version managers (nvm, volta,
/// uv, mise, pyenv, etc.) that configure PATH in RC files are picked up.
/// We do NOT use `-i` (interactive) to avoid prompt/theme initialisation that
/// could hang or pollute stdout.
fn shell_path_command() -> (String, Vec<String>) {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| {
        if cfg!(target_os = "macos") {
            "/bin/zsh".into()
        } else {
            "/bin/bash".into()
        }
    });

    let args = if shell.ends_with("/fish") {
        // Fish: login mode sources config.fish where PATH is configured.
        // PATH is a list in fish; join with ':' for POSIX format.
        vec!["-lc".into(), "string join : $PATH".into()]
    } else if shell.ends_with("/zsh") {
        // Zsh: -l sources .zprofile/.zlogin; explicitly source .zshrc for
        // tool managers (nvm, volta, uv, etc.) that add PATH there.
        vec![
            "-lc".into(),
            r#"source "${ZDOTDIR:-$HOME}/.zshrc" 2>/dev/null; printf '%s' "$PATH""#.into(),
        ]
    } else {
        // Bash and others: -l sources .bash_profile; explicitly source .bashrc
        // where most tool managers add their PATH entries.
        vec![
            "-lc".into(),
            r#"source "$HOME/.bashrc" 2>/dev/null; printf '%s' "$PATH""#.into(),
        ]
    };

    (shell, args)
}

/// Spawn the user's shell to read PATH, with a timeout.
/// Returns the colon-separated PATH string, or None on failure/timeout.
fn detect_shell_path() -> Option<String> {
    let (shell, args) = shell_path_command();
    info!("Detecting PATH via: {} {:?}", shell, args);

    let mut child = match std::process::Command::new(&shell)
        .args(&args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            warn!("Failed to spawn {} for PATH detection: {}", shell, e);
            return None;
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
                    if trimmed.is_empty() {
                        None
                    } else {
                        Some(trimmed)
                    }
                });
            }
            Ok(Some(_)) => break None, // exited non-zero
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    warn!("Shell PATH detection timed out after 5s, killing");
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(_) => break None,
        }
    }
}

/// Refresh the process PATH — re-reads the user's shell PATH and adds fallback dirs.
/// Call this after installing the CLI so subsequent `Command::new("cyfr")` calls find it.
pub fn refresh_path() {
    let current = std::env::var("PATH").unwrap_or_default();
    let shell_path = detect_shell_path();

    let mut parts: Vec<String> = Vec::new();

    // Add shell-detected PATH (includes RC file additions)
    if let Some(sp) = shell_path {
        parts.push(sp);
    }

    // Add all candidate dirs as fallback
    for dir in candidate_dirs() {
        let s = dir.display().to_string();
        if !parts.iter().any(|p| p.contains(&s)) {
            parts.push(s);
        }
    }

    // Add current PATH
    if !current.is_empty() {
        parts.push(current);
    }

    std::env::set_var("PATH", parts.join(":"));
    info!("PATH refreshed");
}

/// Search common install locations for the cyfr binary directly.
/// Returns the absolute path if found.
pub fn find_cli_path() -> Option<PathBuf> {
    // Check cached path first
    if let Ok(guard) = CLI_PATH.lock() {
        if let Some(p) = guard.as_ref() {
            if p.exists() {
                return Some(p.clone());
            }
        }
    }

    for dir in candidate_dirs() {
        let candidate = dir.join("cyfr");
        if candidate.exists() {
            info!("Found cyfr at {}", candidate.display());
            if let Ok(mut guard) = CLI_PATH.lock() {
                *guard = Some(candidate.clone());
            }
            return Some(candidate);
        }
    }

    None
}

/// Get the command name/path for running cyfr.
/// Uses cached absolute path if available, otherwise falls back to bare "cyfr" (PATH lookup).
pub fn cli_command() -> std::ffi::OsString {
    if let Ok(guard) = CLI_PATH.lock() {
        if let Some(p) = guard.as_ref() {
            if p.exists() {
                return p.as_os_str().to_owned();
            }
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

/// Read from an async reader, splitting on both `\r` and `\n` (and `\r\n`).
/// This captures Docker pull progress that uses `\r` for in-place updates,
/// ensuring the idle timer in `run_cyfr_streaming` resets on every progress line.
async fn read_cr_lf_lines<R: tokio::io::AsyncRead + Unpin>(
    reader: R,
    tx: tokio::sync::mpsc::Sender<(String, &'static str)>,
    stream_label: &'static str,
) {
    let mut buf_reader = tokio::io::BufReader::with_capacity(8192, reader);
    let mut line_buf = String::new();
    let mut read_buf = [0u8; 4096];
    let mut skip_next_lf = false;

    loop {
        match buf_reader.read(&mut read_buf).await {
            Ok(0) => {
                // EOF — flush any remaining partial line
                if !line_buf.is_empty() {
                    let _ = tx.send((line_buf, stream_label)).await;
                }
                break;
            }
            Ok(n) => {
                for &b in &read_buf[..n] {
                    if b == b'\n' && skip_next_lf {
                        skip_next_lf = false;
                        continue;
                    }
                    skip_next_lf = false;

                    if b == b'\r' {
                        skip_next_lf = true;
                        let line = std::mem::take(&mut line_buf);
                        if tx.send((line, stream_label)).await.is_err() {
                            return;
                        }
                    } else if b == b'\n' {
                        let line = std::mem::take(&mut line_buf);
                        if tx.send((line, stream_label)).await.is_err() {
                            return;
                        }
                    } else {
                        line_buf.push(b as char);
                    }
                }
            }
            Err(_) => break,
        }
    }
}

/// Run a cyfr CLI command with real-time streaming of stdout/stderr.
///
/// Instead of buffering all output and using a hard timeout, this reads
/// output line-by-line and uses an **idle timeout**: if no output is received
/// for `idle_timeout_secs`, the process is killed. This handles long-running
/// operations like Docker image pulls gracefully — as long as Docker is
/// producing progress output, the idle timer resets.
///
/// Each output line is passed to `on_line(line, stream)` where `stream` is
/// either `"stdout"` or `"stderr"`.
pub async fn run_cyfr_streaming<F>(
    args: &[&str],
    project_dir: &Path,
    idle_timeout_secs: u64,
    on_line: F,
) -> Result<CliOutput, String>
where
    F: Fn(&str, &str) + Send,
{
    let cmd = cli_command();
    info!(
        "Running (streaming): {} {} (in {}, idle timeout {}s)",
        cmd.to_string_lossy(),
        args.join(" "),
        project_dir.display(),
        idle_timeout_secs,
    );

    let mut child = Command::new(&cmd)
        .args(args)
        .current_dir(project_dir)
        .env("COMPOSE_PROJECT_NAME", "cyfr")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to run cyfr: {}", e))?;

    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");

    // Use a channel to merge stdout/stderr into a single stream.
    // Two reader tasks feed lines into the channel; the main loop
    // reads from it with an idle timeout.
    let (tx, mut rx) = tokio::sync::mpsc::channel::<(String, &'static str)>(100);

    // Two reader tasks split on both \r and \n so that Docker pull
    // progress (which uses \r for in-place updates) resets the idle timer.
    let tx_out = tx.clone();
    tokio::spawn(read_cr_lf_lines(stdout, tx_out, "stdout"));

    // Move (not clone) the remaining sender so the channel closes
    // when both reader tasks complete.
    let tx_err = tx;
    tokio::spawn(read_cr_lf_lines(stderr, tx_err, "stderr"));

    let mut all_stdout = String::new();
    let mut all_stderr = String::new();
    let idle = Duration::from_secs(idle_timeout_secs);

    loop {
        match tokio::time::timeout(idle, rx.recv()).await {
            Err(_) => {
                // Idle timeout — no output for too long
                warn!(
                    "cyfr {} idle timeout ({}s with no output), killing",
                    args.join(" "),
                    idle_timeout_secs
                );
                let _ = child.kill().await;
                return Err(format!(
                    "cyfr {} timed out (no output for {}s). The process may be stuck.",
                    args.join(" "),
                    idle_timeout_secs
                ));
            }
            Ok(None) => {
                // Channel closed — both readers finished
                break;
            }
            Ok(Some((line, stream))) => {
                if !line.trim().is_empty() {
                    on_line(&line, stream);
                }
                match stream {
                    "stdout" => {
                        all_stdout.push_str(&line);
                        all_stdout.push('\n');
                    }
                    _ => {
                        all_stderr.push_str(&line);
                        all_stderr.push('\n');
                    }
                }
            }
        }
    }

    let status = child
        .wait()
        .await
        .map_err(|e| format!("Failed to wait for cyfr: {}", e))?;

    if !all_stdout.is_empty() {
        info!("cyfr stdout: {}", all_stdout.trim());
    }
    if !all_stderr.is_empty() {
        warn!("cyfr stderr: {}", all_stderr.trim());
    }

    Ok(CliOutput {
        stdout: all_stdout,
        stderr: all_stderr,
        success: status.success(),
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

/// Install cyfr CLI via Homebrew with streaming output.
/// Uses an idle timeout that resets on each output line, so slow Homebrew
/// downloads don't trigger a timeout as long as progress is flowing.
pub async fn install_cli_brew_streaming<F>(
    idle_timeout_secs: u64,
    on_line: F,
) -> Result<CliOutput, String>
where
    F: Fn(&str, &str) + Send,
{
    // Check if brew is available
    let brew_check = tokio::time::timeout(
        Duration::from_secs(30),
        Command::new("brew")
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .output(),
    )
    .await;

    match brew_check {
        Err(_) => return Err("Homebrew check timed out".to_string()),
        Ok(Err(_)) => return Err("Homebrew not found".to_string()),
        Ok(Ok(output)) if !output.status.success() => {
            return Err("Homebrew not found".to_string());
        }
        Ok(Ok(_)) => {}
    }

    info!("Installing cyfr via Homebrew (streaming)...");

    let mut child = Command::new("brew")
        .args(["install", "cyfrworks/cyfr/cyfr"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to run brew: {}", e))?;

    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");

    let (tx, mut rx) = tokio::sync::mpsc::channel::<(String, &'static str)>(100);

    let tx_out = tx.clone();
    tokio::spawn(read_cr_lf_lines(stdout, tx_out, "stdout"));
    let tx_err = tx;
    tokio::spawn(read_cr_lf_lines(stderr, tx_err, "stderr"));

    let mut all_stdout = String::new();
    let mut all_stderr = String::new();
    let idle = Duration::from_secs(idle_timeout_secs);

    loop {
        match tokio::time::timeout(idle, rx.recv()).await {
            Err(_) => {
                warn!("brew install idle timeout ({}s with no output), killing", idle_timeout_secs);
                let _ = child.kill().await;
                return Err(format!(
                    "brew install timed out (no output for {}s). The process may be stuck.",
                    idle_timeout_secs
                ));
            }
            Ok(None) => break,
            Ok(Some((line, stream))) => {
                if !line.trim().is_empty() {
                    on_line(&line, stream);
                }
                match stream {
                    "stdout" => {
                        all_stdout.push_str(&line);
                        all_stdout.push('\n');
                    }
                    _ => {
                        all_stderr.push_str(&line);
                        all_stderr.push('\n');
                    }
                }
            }
        }
    }

    let status = child
        .wait()
        .await
        .map_err(|e| format!("Failed to wait for brew: {}", e))?;

    Ok(CliOutput {
        stdout: all_stdout,
        stderr: all_stderr,
        success: status.success(),
    })
}

const GITHUB_REPO: &str = "cyfrworks/cyfr";

/// Install cyfr CLI by downloading the binary directly from GitHub releases.
/// Downloads tarball + checksums, verifies SHA256, extracts, and installs.
pub async fn install_cli_direct() -> Result<CliOutput, String> {
    let os_name = if cfg!(target_os = "macos") { "darwin" } else { "linux" };
    let arch = match std::env::consts::ARCH {
        "aarch64" => "arm64",
        "x86_64" => "amd64",
        other => return Err(format!("Unsupported architecture: {}", other)),
    };

    // Step 1: Resolve latest CLI version from GitHub releases
    info!("Resolving latest cyfr CLI version...");
    let version = resolve_latest_cli_version().await?;
    info!("Latest cyfr CLI version: {}", version);

    let archive_name = format!("cyfr_{}_{}_{}.tar.gz", version, os_name, arch);
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
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(300))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

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
        elevate_install(&binary_src, &dest).await?;
    } else {
        let _ = Command::new("chmod")
            .args(["+x"])
            .arg(&dest)
            .output()
            .await;
    }

    // Cache the installed path
    if let Ok(mut guard) = CLI_PATH.lock() {
        *guard = Some(dest.clone());
    }

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

/// Escape a path for safe inclusion in a shell command string.
/// Wraps in single quotes and escapes any embedded single quotes.
fn shell_escape(path: &Path) -> String {
    let s = path.display().to_string();
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Copy binary with elevated privileges using `install -m 755`.
/// macOS uses osascript admin dialog, Linux uses pkexec (preferred) or sudo.
/// Uses `install` instead of `cp && chmod` to avoid shell string interpolation.
async fn elevate_install(src: &Path, dest: &Path) -> Result<(), String> {
    let install_dir = dest.parent().unwrap_or(Path::new("/usr/local/bin"));

    #[cfg(target_os = "macos")]
    {
        info!("Requesting admin privileges to install to {}", install_dir.display());
        let script = format!(
            r#"do shell script "/usr/bin/install -m 755 {} {}" with administrator privileges"#,
            shell_escape(src),
            shell_escape(dest),
        );
        let admin_output = Command::new("osascript")
            .args(["-e", &script])
            .output()
            .await
            .map_err(|e| format!("Failed to run osascript: {}", e))?;

        if !admin_output.status.success() {
            return Err(format!(
                "Could not install to {}. Please install manually from: https://github.com/{}/releases",
                install_dir.display(),
                GITHUB_REPO
            ));
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let has_pkexec = Command::new("which")
            .arg("pkexec")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .await
            .map(|o| o.status.success())
            .unwrap_or(false);

        let escalation_cmd = if has_pkexec { "pkexec" } else { "sudo" };
        info!(
            "Requesting admin privileges via {} to install to {}",
            escalation_cmd,
            install_dir.display()
        );

        // Pass arguments directly — no shell string interpolation needed
        let admin_output = Command::new(escalation_cmd)
            .args(["install", "-m", "755"])
            .arg(src)
            .arg(dest)
            .output()
            .await
            .map_err(|e| format!("Failed to run {}: {}", escalation_cmd, e))?;

        if !admin_output.status.success() {
            return Err(format!(
                "Could not install to {}. Please install manually from: https://github.com/{}/releases",
                install_dir.display(),
                GITHUB_REPO
            ));
        }
    }

    Ok(())
}

/// Resolve the latest CLI release version from GitHub API.
/// Skips porta-v* tags and finds the first v* tag.
async fn resolve_latest_cli_version() -> Result<String, String> {
    let client = reqwest::Client::builder()
        .user_agent("cyfr-porta")
        .timeout(Duration::from_secs(30))
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

    // Compute actual checksum: shasum on macOS, sha256sum on Linux
    let output = if cfg!(target_os = "macos") {
        Command::new("shasum")
            .args(["-a", "256"])
            .arg(file)
            .output()
            .await
            .map_err(|e| format!("Failed to run shasum: {}", e))?
    } else {
        Command::new("sha256sum")
            .arg(file)
            .output()
            .await
            .map_err(|e| format!("Failed to run sha256sum: {}", e))?
    };

    if !output.status.success() {
        return Err("Checksum command failed".to_string());
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
    if let Ok(home) = crate::home_dir() {
        let local_bin = home.join(".local/bin");
        let _ = std::fs::create_dir_all(&local_bin);
        warn!(
            "Installing to {}. This directory may not be in your terminal PATH. \
             Add it with: export PATH=\"$HOME/.local/bin:$PATH\"",
            local_bin.display()
        );
        local_bin
    } else {
        PathBuf::from("/usr/local/bin")
    }
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
