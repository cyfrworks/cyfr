use crate::docker::{health, lifecycle};
use crate::update::UpdateInfo;
use serde::Serialize;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use tauri::{Emitter, Manager};

#[derive(Debug, Clone, Serialize)]
struct UpgradeProgress {
    status: String,
    progress: f32,
}

#[tauri::command]
pub async fn docker_status() -> Result<String, String> {
    let healthy = health::check_health().await;

    Ok(serde_json::json!({
        "healthy": healthy
    })
    .to_string())
}

#[tauri::command]
pub async fn docker_start(app: tauri::AppHandle) -> Result<(), String> {
    let proj_dir = crate::preflight::project_dir()?;
    if !crate::preflight::should_manage_local_project() {
        return Err("Start is only available when Porta manages the local CYFR stack.".to_string());
    }
    lifecycle::start_streaming(&app, &proj_dir, 120, |_line, _stream| {}).await?;
    Ok(())
}

#[tauri::command]
pub async fn docker_stop(app: tauri::AppHandle) -> Result<(), String> {
    let proj_dir = crate::preflight::project_dir()?;
    if !crate::preflight::should_manage_local_project() {
        return Err("Stop is only available when Porta manages the local CYFR stack.".to_string());
    }
    lifecycle::stop(&app, &proj_dir).await?;
    Ok(())
}

#[tauri::command]
pub async fn docker_restart(app: tauri::AppHandle) -> Result<(), String> {
    let proj_dir = crate::preflight::project_dir()?;
    if !crate::preflight::should_manage_local_project() {
        return Err("Restart is only available when Porta manages the local CYFR stack.".to_string());
    }
    lifecycle::stop(&app, &proj_dir).await?;
    lifecycle::start_streaming(&app, &proj_dir, 120, |_line, _stream| {}).await?;
    Ok(())
}

/// Called by boot UI when JS event listeners are ready (fast path)
#[tauri::command]
pub async fn start_boot(app: tauri::AppHandle) -> Result<(), String> {
    tauri::async_runtime::spawn(async move {
        crate::boot::try_start_boot(app).await;
    });
    Ok(())
}

/// Called by retry buttons
#[tauri::command]
pub async fn retry_boot(app: tauri::AppHandle) -> Result<(), String> {
    crate::boot::reset_boot();
    tauri::async_runtime::spawn(async move {
        crate::boot::try_start_boot(app).await;
    });
    Ok(())
}

/// Transition the boot window into the main app window.
/// Called by the React frontend when boot completes.
#[tauri::command]
pub async fn transition_to_main(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(boot_window) = app.get_webview_window("boot") {
        let _ = boot_window.close();
    }

    // Create a fresh main window — changing maximizable on an existing window
    // doesn't work reliably on macOS.
    // Pass ?booted=1 so the React app knows to skip boot and go straight to auth.
    let _ = tauri::WebviewWindowBuilder::new(
        &app,
        "main",
        tauri::WebviewUrl::App("index.html?booted=1".into()),
    )
    .title("CYFR")
    .inner_size(1280.0, 800.0)
    .min_inner_size(800.0, 500.0)
    .center()
    .resizable(true)
    .maximizable(true)
    .minimizable(true)
    .build();
    Ok(())
}

/// Returns the CYFR API base URL.
#[tauri::command]
pub async fn get_cyfr_url() -> Result<String, String> {
    Ok(crate::config::cyfr_url())
}

#[tauri::command]
pub async fn open_url(url: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&url)
            .spawn()
            .map_err(|e| format!("Failed to open URL: {}", e))?;
        return Ok(());
    }

    #[cfg(target_os = "linux")]
    {
        // Try common URL openers — xdg-open may not exist on minimal installs
        for opener in &["xdg-open", "sensible-browser", "x-www-browser", "firefox", "chromium"] {
            if let Ok(mut child) = std::process::Command::new(opener).arg(&url).spawn() {
                // Don't wait for the browser — just check it launched
                let _ = child.try_wait();
                return Ok(());
            }
        }
        return Err(format!(
            "No browser found. Please open this URL manually:\n{}",
            url
        ));
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    return Err("URL opening not supported on this platform".to_string());
}

#[tauri::command]
pub async fn install_docker(app: tauri::AppHandle) -> Result<(), String> {
    use crate::docker;

    // Download and install Docker Desktop / Engine
    match docker::install::install_docker_desktop(&app).await {
        Err(e) if e == "RELOGIN_REQUIRED" => {
            // Linux: docker group added but not active in this session.
            // The user must log out of their desktop session (not just close CYFR)
            // for the docker group membership to take effect.
            return Err(
                "Docker was installed successfully. You need to log out of your \
                 desktop session and log back in for Docker permissions to take \
                 effect, then reopen CYFR. (Your user was added to the 'docker' \
                 group, which requires a session restart.)"
                    .to_string(),
            );
        }
        Err(e) => return Err(e),
        Ok(()) => {}
    }

    // Wait for Docker to become ready (poll docker info for up to 120s)
    for i in 0..60 {
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;

        let progress = 0.95 + (i as f32 / 60.0) * 0.05;
        let _ = app.emit(
            "boot-state",
            crate::boot::BootEvent {
                state: "installing_docker",
                message: "Waiting for Docker Desktop to start...".to_string(),
                progress: Some(progress),
            },
        );

        if let docker::lifecycle::DockerState::Ready =
            docker::lifecycle::check_docker_state().await
        {
            // Docker is ready — trigger boot
            crate::boot::reset_boot();
            let boot_app = app.clone();
            tauri::async_runtime::spawn(async move {
                crate::boot::try_start_boot(boot_app).await;
            });
            return Ok(());
        }
    }

    Err("Docker Desktop was installed but did not start within 2 minutes. Please start it manually and click Retry.".to_string())
}

/// Check if Docker daemon is ready (for polling from frontend)
#[tauri::command]
pub async fn check_docker_ready() -> Result<bool, String> {
    match lifecycle::check_docker_state().await {
        lifecycle::DockerState::Ready => Ok(true),
        _ => Ok(false),
    }
}

#[tauri::command]
pub async fn open_docker_desktop() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        tokio::process::Command::new("open")
            .args(["-a", "Docker"])
            .output()
            .await
            .map_err(|e| format!("Failed to open Docker Desktop: {}", e))?;
    }

    #[cfg(target_os = "linux")]
    {
        // Linux uses Docker Engine (daemon), not Docker Desktop — start via systemctl.
        // Try pkexec first (graphical password prompt), fall back to direct systemctl
        // (works if user has passwordless sudo or docker group membership).
        let started = if let Ok(output) = tokio::process::Command::new("pkexec")
            .args(["systemctl", "start", "docker"])
            .output()
            .await
        {
            output.status.success()
        } else {
            false
        };

        if !started {
            // pkexec failed (Wayland, cancelled, etc.) — try without escalation
            // in case the user has permissions via docker group or sudoers
            let result = tokio::process::Command::new("systemctl")
                .args(["start", "docker"])
                .output()
                .await
                .map_err(|e| format!("Failed to start Docker: {}", e))?;

            if !result.status.success() {
                return Err(
                    "Could not start Docker. Try running in a terminal:\n  \
                     sudo systemctl start docker"
                        .to_string(),
                );
            }
        }
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        return Err("Please start Docker manually.".to_string());
    }

    Ok(())
}

#[tauri::command]
pub async fn check_for_update() -> Result<Option<UpdateInfo>, String> {
    Ok(crate::update::check_cyfr_update().await)
}

#[tauri::command]
pub async fn dismiss_update(app: tauri::AppHandle, kind: String, version: String) -> Result<(), String> {
    if let Some(state) = app.try_state::<crate::update::DismissedVersion>() {
        let mut dismissed = state.0.lock().unwrap();
        match kind.as_str() {
            "porta" => dismissed.porta = Some(version),
            _ => dismissed.cyfr = Some(version),
        }
    }
    Ok(())
}

/// Build a streaming callback that emits `upgrade-progress` events with interpolated progress.
/// Progress advances from `start` toward `end` by `step` per output line.
fn progress_emitter(
    app: &tauri::AppHandle,
    start: f32,
    end: f32,
    step: f32,
) -> impl Fn(&str, &str) + Send {
    let app = app.clone();
    let counter = Arc::new(AtomicU32::new(0));
    move |line: &str, _stream: &str| {
        let n = counter.fetch_add(1, Ordering::Relaxed);
        let progress = (start + (n as f32 * step)).min(end);
        let _ = app.emit("upgrade-progress", UpgradeProgress {
            status: line.to_string(),
            progress,
        });
    }
}

#[tauri::command]
pub async fn perform_upgrade(app: tauri::AppHandle) -> Result<(), String> {
    use crate::cli;
    use crate::docker;
    use crate::TrayState;

    if !crate::preflight::should_manage_local_project() {
        return Err("Upgrade is only available when Porta manages the local CYFR stack.".to_string());
    }

    let proj_dir = crate::preflight::project_dir()?;

    let emit_progress = |status: &str, progress: f32| {
        let _ = app.emit("upgrade-progress", UpgradeProgress {
            status: status.to_string(),
            progress,
        });
    };

    // Capture pre-upgrade version for diagnostics
    let pre_version = cli::check_cli().await.unwrap_or_else(|| "unknown".to_string());
    tracing::info!("Starting upgrade from CLI version: {}", pre_version);

    if !crate::preflight::missing_project_entries(&proj_dir).is_empty() {
        emit_progress("Repairing project files...", 0.05);
        let repair = cli::run_cyfr_streaming(
            &["init"],
            &proj_dir,
            600,
            progress_emitter(&app, 0.05, 0.18, 0.003),
        )
        .await?;

        if !repair.success {
            let msg = if repair.stderr.is_empty() {
                repair.stdout
            } else {
                repair.stderr
            };
            return Err(format!("Failed to repair local CYFR project: {}", msg.trim()));
        }
    }

    emit_progress("Stopping server...", 0.1);

    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("CYFR: Updating...");
    }

    // Step 1: Stop container
    if let Err(e) = cli::run_cyfr(&["down"], &proj_dir).await {
        tracing::warn!("cyfr down during upgrade: {}", e);
    }

    // Step 2: Update CLI (streams brew/download progress to UI)
    emit_progress("Updating CLI...", 0.2);

    let upgrade_ok = match cli::run_cyfr_streaming(
        &["upgrade"],
        &proj_dir,
        120,
        progress_emitter(&app, 0.2, 0.45, 0.005),
    )
    .await
    {
        Ok(output) if output.success => {
            tracing::info!("cyfr upgrade: {}", output.stdout.trim());
            true
        }
        Ok(output) => {
            let msg = if output.stderr.is_empty() { &output.stdout } else { &output.stderr };
            tracing::warn!("cyfr upgrade failed: {}", msg.trim());
            false
        }
        Err(e) => {
            tracing::warn!("cyfr upgrade failed: {}", e);
            false
        }
    };

    if !upgrade_ok {
        // Upgrade failed — restart old container to restore service
        emit_progress("Upgrade failed, restarting previous version...", 0.5);
        let start_result = lifecycle::start(&app, &proj_dir).await;

        if let Err(e) = &start_result {
            tracing::warn!("Rollback start failed: {}", e);
            if let Some(state) = app.try_state::<TrayState>() {
                let _ = state.status_item.set_text("CYFR: Error");
            }
            return Err(
                "Upgrade failed. Could not restart previous version. \
                 Run `cyfr up` manually to recover."
                    .to_string(),
            );
        }

        let rollback_app = app.clone();
        if let Err(e) = docker::health::wait_healthy(
            |msg, _| {
                let _ = rollback_app.emit("upgrade-progress", UpgradeProgress {
                    status: msg.to_string(),
                    progress: 0.5,
                });
            },
            60,
            0.5,
            0.5,
        ).await {
            tracing::warn!("Rollback health check failed: {}", e);
            if let Some(state) = app.try_state::<TrayState>() {
                let _ = state.status_item.set_text("CYFR: Error");
            }
            return Err(
                "Upgrade failed. Previous version restarted but not responding. \
                 Check 'docker logs cyfr' for details."
                    .to_string(),
            );
        }

        if let Some(state) = app.try_state::<TrayState>() {
            let _ = state.status_item.set_text("CYFR: Running");
        }
        return Err("Upgrade failed. Previous version has been restored.".to_string());
    }

    // Clear CLI path cache so we pick up the potentially new binary location
    cli::clear_cli_cache();
    // refresh_path() spawns a sync process — run on blocking pool to avoid stalling async runtime
    tokio::task::spawn_blocking(cli::refresh_path).await.ok();

    let post_version = cli::check_cli().await.unwrap_or_else(|| "unknown".to_string());
    tracing::info!("Post-upgrade CLI version: {} (was: {})", post_version, pre_version);
    if post_version == pre_version && pre_version != "unknown" {
        tracing::warn!("CLI version unchanged after upgrade ({}) — Docker image may still have been updated", post_version);
    }

    // Step 3: Update project files + pull Docker image (streams progress to UI).
    // 600s idle timeout: `cyfr update` pulls Docker images which can take a while
    // on slow connections. The idle timer resets on every progress line.
    emit_progress("Pulling latest image and updating files...", 0.5);

    let update_succeeded = match cli::run_cyfr_streaming(
        &["update"],
        &proj_dir,
        600,
        progress_emitter(&app, 0.5, 0.68, 0.003),
    )
    .await
    {
        Ok(output) if output.success => true,
        Ok(output) => {
            let msg = if output.stderr.is_empty() { &output.stdout } else { &output.stderr };
            tracing::warn!("cyfr update failed: {}", msg.trim());
            false
        }
        Err(e) => {
            tracing::warn!("cyfr update failed: {}", e);
            false
        }
    };

    // Step 4: Start container (streaming so progress bar advances).
    // Use a longer idle timeout if the image update failed — docker compose up
    // may need to pull the image implicitly, which can be slow.
    let up_idle_timeout = if update_succeeded { 120 } else { 600 };
    emit_progress("Starting server...", 0.7);

    if let Err(e) = lifecycle::start_streaming(
        &app,
        &proj_dir,
        up_idle_timeout,
        progress_emitter(&app, 0.7, 0.85, 0.005),
    ).await {
        // Start failed — try once more with down + up
        tracing::warn!("First start failed after upgrade: {}", e);
        emit_progress("Retrying startup...", 0.75);
        let _ = cli::run_cyfr(&["down"], &proj_dir).await;

        if let Err(e2) = lifecycle::start_streaming(
            &app,
            &proj_dir,
            up_idle_timeout,
            progress_emitter(&app, 0.75, 0.85, 0.005),
        ).await {
            emit_progress(&format!("Failed: {}", e2), 0.75);
            if let Some(state) = app.try_state::<TrayState>() {
                let _ = state.status_item.set_text("CYFR: Error");
            }
            return Err(format!("Failed to start after upgrade: {}", e2));
        }
    }

    // Step 5: Wait for health
    emit_progress("Waiting for server...", 0.9);
    let health_app = app.clone();
    if let Err(e) = docker::health::wait_healthy(
        |msg, progress| {
            let _ = health_app.emit("upgrade-progress", UpgradeProgress {
                status: msg.to_string(),
                progress,
            });
        },
        90,
        0.9,
        0.98,
    ).await {
        if let Some(state) = app.try_state::<TrayState>() {
            let _ = state.status_item.set_text("CYFR: Error");
        }
        emit_progress("Server did not pass health check.", 0.95);
        return Err(format!(
            "Update applied but server health check failed: {}. Check 'docker logs cyfr' for details.",
            e
        ));
    }

    // Step 6: Re-index components (streaming for progress visibility)
    emit_progress("Indexing new components...", 0.95);
    let _ = cli::run_cyfr_streaming(
        &["register"],
        &proj_dir,
        120,
        progress_emitter(&app, 0.95, 0.99, 0.002),
    ).await;

    // Re-register Porta gateway with the new Cyfr container
    crate::gateway::spawn_registration(crate::config::GATEWAY_PORT, 0, 3);

    // Done
    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("CYFR: Running");
    }

    if update_succeeded {
        emit_progress("Update complete.", 1.0);
        Ok(())
    } else {
        emit_progress("Server restarted but image update failed.", 1.0);
        Err(
            "Server is running but the Docker image update failed. \
             You may still be on the previous version. Check your network and retry."
                .to_string(),
        )
    }
}
