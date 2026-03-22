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

/// Download and install Docker Desktop automatically.
///
/// On macOS: download DMG → mount → copy Docker.app → unmount → cleanup → launch
/// On Linux: not supported — returns an error directing the user to install manually.
pub async fn install_docker_desktop(app: &tauri::AppHandle) -> Result<(), String> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        return Err("Automatic Docker installation is only supported on macOS. Please install Docker Engine manually: https://docs.docker.com/engine/install/".to_string());
    }

    #[cfg(target_os = "macos")]
    install_docker_macos(app).await
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
        .args(["attach", "-nobrowse", "-quiet"])
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
        let stderr = String::from_utf8_lossy(&cp_output.stderr);
        let _ = detach_volume().await;
        cleanup_dmg(&tmp_path);
        return Err(format!("Failed to install Docker.app: {}", stderr.trim()));
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
