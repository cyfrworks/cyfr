use std::path::PathBuf;
use tauri::Emitter;
use tokio::process::Command;
use tracing::info;

/// Download URL for Docker Desktop based on architecture (macOS only)
#[cfg(target_os = "macos")]
fn docker_dmg_url() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "https://desktop.docker.com/mac/main/arm64/Docker.dmg",
        _ => "https://desktop.docker.com/mac/main/amd64/Docker.dmg",
    }
}

/// Download and install Docker automatically.
///
/// On macOS: download DMG → mount → copy Docker.app → unmount → cleanup → launch
/// On Linux: download official install script from get.docker.com → run via pkexec → start service
pub async fn install_docker_desktop(app: &tauri::AppHandle) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return install_docker_macos(app).await;
    }

    #[cfg(target_os = "linux")]
    {
        return install_docker_linux(app).await;
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = app;
        return Err("Automatic Docker installation is not supported on this platform.".to_string());
    }
}

#[cfg(target_os = "macos")]
async fn install_docker_macos(app: &tauri::AppHandle) -> Result<(), String> {
    let url = docker_dmg_url();
    let tmp_path = std::env::temp_dir().join("Docker.dmg");

    // Step 1: Download DMG with progress
    info!("Downloading Docker Desktop from {}", url);
    emit_install_progress(app, "Downloading Docker Desktop...", 0.0);

    download_with_progress(app, url, &tmp_path).await?;

    // Step 2: Mount DMG
    emit_install_progress(app, "Mounting installer...", 0.7);
    info!("Mounting DMG at {}", tmp_path.display());

    let mount_output = Command::new("hdiutil")
        .args(["attach", "-nobrowse", "-noverify", "-quiet"])
        .arg(&tmp_path)
        .output()
        .await
        .map_err(|e| format!("Failed to mount DMG: {}", e))?;

    if !mount_output.status.success() {
        let stderr = String::from_utf8_lossy(&mount_output.stderr);
        cleanup_dmg(&tmp_path);
        return Err(format!("Failed to mount DMG: {}", stderr.trim()));
    }

    // Step 3: Copy Docker.app to /Applications
    emit_install_progress(app, "Installing Docker Desktop...", 0.8);
    info!("Copying Docker.app to /Applications");

    let cp_output = Command::new("cp")
        .args(["-R", "/Volumes/Docker/Docker.app", "/Applications/"])
        .output()
        .await
        .map_err(|e| format!("Failed to copy Docker.app: {}", e))?;

    if !cp_output.status.success() {
        // Normal cp failed (likely permission denied) — try with admin privileges via osascript
        info!("Normal copy failed, requesting admin privileges via osascript");
        emit_install_progress(app, "Administrator password required...", 0.8);

        let admin_result = tokio::time::timeout(
            std::time::Duration::from_secs(120),
            Command::new("osascript")
                .args([
                    "-e",
                    r#"do shell script "cp -R /Volumes/Docker/Docker.app /Applications/" with administrator privileges"#,
                ])
                .output(),
        )
        .await;

        let admin_output = match admin_result {
            Err(_) => {
                // Timeout — user didn't respond to password dialog
                let _ = detach_volume().await;
                cleanup_dmg(&tmp_path);
                return Err(
                    "Admin password dialog timed out. Please try again.".to_string(),
                );
            }
            Ok(result) => result.map_err(|e| format!("Failed to run osascript: {}", e))?,
        };

        if !admin_output.status.success() {
            // Admin copy also failed — keep DMG mounted so user can drag manually
            info!("Admin copy also failed, leaving DMG mounted for manual drag");
            cleanup_dmg(&tmp_path);
            // Don't detach volume — user needs to drag from it
            return Err(
                "Could not copy Docker to Applications. \
                 Please drag Docker.app from the mounted disk image to your Applications folder, \
                 then click Retry."
                    .to_string(),
            );
        }
    }

    // Step 4: Unmount & cleanup
    emit_install_progress(app, "Cleaning up...", 0.9);
    let _ = detach_volume().await;
    cleanup_dmg(&tmp_path);

    // Step 5: Launch Docker Desktop
    emit_install_progress(app, "Starting Docker Desktop...", 0.95);
    info!("Launching Docker Desktop");

    Command::new("open")
        .args(["-a", "Docker"])
        .output()
        .await
        .map_err(|e| format!("Failed to launch Docker: {}", e))?;

    info!("Docker Desktop installed and launched");
    Ok(())
}

#[cfg(target_os = "macos")]
/// Download a file with progress reporting via Tauri events.
async fn download_with_progress(
    app: &tauri::AppHandle,
    url: &str,
    dest: &PathBuf,
) -> Result<(), String> {
    let client = reqwest::Client::new();
    let mut resp = client
        .get(url)
        .send()
        .await
        .map_err(|e| format!("Download failed: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("Download failed: HTTP {}", resp.status()));
    }

    let total_size = resp.content_length().unwrap_or(0);
    let mut downloaded: u64 = 0;
    let mut last_pct: u64 = 0;

    let mut file = tokio::fs::File::create(dest)
        .await
        .map_err(|e| format!("Failed to create temp file: {}", e))?;

    use tokio::io::AsyncWriteExt;

    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| format!("Download error: {}", e))?
    {
        file.write_all(&chunk)
            .await
            .map_err(|e| format!("Write error: {}", e))?;

        downloaded += chunk.len() as u64;

        // Report progress (scale download to 0–70% of total install progress)
        if total_size > 0 {
            let pct = (downloaded * 100) / total_size;
            if pct != last_pct {
                last_pct = pct;
                let progress = (downloaded as f64 / total_size as f64) * 0.65 + 0.05;
                let mb_done = downloaded as f64 / 1_048_576.0;
                let mb_total = total_size as f64 / 1_048_576.0;
                let msg = format!(
                    "Downloading Docker Desktop... {:.0}/{:.0} MB",
                    mb_done, mb_total
                );
                emit_install_progress(app, &msg, progress);
            }
        }
    }

    file.flush()
        .await
        .map_err(|e| format!("Flush error: {}", e))?;

    Ok(())
}

#[cfg(target_os = "macos")]
async fn detach_volume() -> Result<(), String> {
    Command::new("hdiutil")
        .args(["detach", "/Volumes/Docker", "-quiet"])
        .output()
        .await
        .map_err(|e| format!("Failed to detach: {}", e))?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn cleanup_dmg(path: &PathBuf) {
    let _ = std::fs::remove_file(path);
}

#[cfg(target_os = "linux")]
async fn install_docker_linux(app: &tauri::AppHandle) -> Result<(), String> {
    // Step 1: Download the official Docker install script
    emit_install_progress(app, "Downloading Docker installer...", 0.1);
    info!("Downloading Docker install script from https://get.docker.com");

    let script_path = std::env::temp_dir().join("get-docker.sh");

    let output = Command::new("curl")
        .args(["-fsSL", "-o"])
        .arg(&script_path)
        .arg("https://get.docker.com")
        .output()
        .await
        .map_err(|e| format!("Failed to download Docker installer: {}", e))?;

    if !output.status.success() {
        return Err("Failed to download Docker install script".to_string());
    }

    // Step 2: Run with pkexec for GUI privilege escalation
    emit_install_progress(app, "Installing Docker Engine (admin password required)...", 0.3);
    info!("Running Docker install script via pkexec");

    let install = Command::new("pkexec")
        .args(["sh"])
        .arg(&script_path)
        .output()
        .await
        .map_err(|e| format!("Failed to install Docker: {}", e))?;

    let _ = std::fs::remove_file(&script_path);

    if !install.status.success() {
        let stderr = String::from_utf8_lossy(&install.stderr);
        return Err(format!("Docker installation failed: {}", stderr.trim()));
    }

    // Step 3: Add current user to docker group so no sudo needed for docker commands
    emit_install_progress(app, "Configuring Docker permissions...", 0.8);

    if let Ok(user) = std::env::var("USER") {
        let _ = Command::new("pkexec")
            .args(["usermod", "-aG", "docker", &user])
            .output()
            .await;
    }

    // Step 4: Start and enable Docker service
    emit_install_progress(app, "Starting Docker service...", 0.9);

    let _ = Command::new("pkexec")
        .args(["systemctl", "enable", "--now", "docker"])
        .output()
        .await;

    info!("Docker Engine installed and started");
    Ok(())
}

fn emit_install_progress(app: &tauri::AppHandle, message: &str, progress: f64) {
    let _ = app.emit(
        "boot-state",
        crate::boot::BootEvent {
            state: "installing_docker",
            message: message.to_string(),
            progress: Some(progress as f32),
        },
    );
}
