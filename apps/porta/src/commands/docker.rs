use crate::docker::{health, lifecycle};
use crate::update::UpdateInfo;
use serde::Serialize;
use tauri::{Emitter, Manager};

#[derive(Debug, Clone, Serialize)]
struct UpgradeProgress {
    status: String,
    progress: f32,
}

#[tauri::command]
pub async fn docker_status() -> Result<String, String> {
    let container_status = lifecycle::status().await?;
    let healthy = health::check_health().await;

    Ok(serde_json::json!({
        "container": container_status,
        "healthy": healthy
    })
    .to_string())
}

#[tauri::command]
pub async fn docker_start(app: tauri::AppHandle) -> Result<(), String> {
    let proj_dir = dirs::home_dir()
        .expect("could not determine home directory")
        .join("cyfr");
    lifecycle::start(&app, &proj_dir).await?;
    Ok(())
}

#[tauri::command]
pub async fn docker_stop(_app: tauri::AppHandle) -> Result<(), String> {
    let proj_dir = dirs::home_dir()
        .expect("could not determine home directory")
        .join("cyfr");
    lifecycle::stop(&proj_dir).await?;
    Ok(())
}

#[tauri::command]
pub async fn docker_restart(app: tauri::AppHandle) -> Result<(), String> {
    let proj_dir = dirs::home_dir()
        .expect("could not determine home directory")
        .join("cyfr");
    lifecycle::stop(&proj_dir).await?;
    lifecycle::start(&app, &proj_dir).await?;
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
    Ok("http://localhost:4000".to_string())
}

#[tauri::command]
pub async fn open_url(url: String) -> Result<(), String> {
    std::process::Command::new("open")
        .arg(&url)
        .spawn()
        .map_err(|e| format!("Failed to open URL: {}", e))?;
    Ok(())
}

#[tauri::command]
pub async fn install_docker(app: tauri::AppHandle) -> Result<(), String> {
    use crate::docker;

    // Download and install Docker Desktop
    docker::install::install_docker_desktop(&app).await?;

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
    tokio::process::Command::new("open")
        .args(["-a", "Docker"])
        .output()
        .await
        .map_err(|e| format!("Failed to open Docker Desktop: {}", e))?;
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

#[tauri::command]
pub async fn perform_upgrade(app: tauri::AppHandle) -> Result<(), String> {
    use crate::cli;
    use crate::docker;
    use crate::TrayState;

    let proj_dir = dirs::home_dir()
        .expect("could not determine home directory")
        .join("cyfr");

    let emit_progress = |status: &str, progress: f32| {
        let _ = app.emit("upgrade-progress", UpgradeProgress {
            status: status.to_string(),
            progress,
        });
    };

    emit_progress("Stopping server...", 0.1);

    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("Cyfr: Updating...");
    }

    // Step 1: Stop container
    if let Err(e) = cli::run_cyfr(&["down"], &proj_dir).await {
        tracing::warn!("cyfr down during upgrade: {}", e);
    }

    // Step 2: Update CLI + pull Docker image
    emit_progress("Updating CLI and pulling latest image...", 0.3);

    match cli::run_cyfr(&["upgrade"], &proj_dir).await {
        Ok(output) if output.success => {
            tracing::info!("cyfr upgrade: {}", output.stdout.trim());
        }
        Ok(output) => {
            let msg = if output.stderr.is_empty() { &output.stdout } else { &output.stderr };
            tracing::warn!("cyfr upgrade warning: {}", msg.trim());
        }
        Err(e) => {
            tracing::warn!("cyfr upgrade failed: {}", e);
        }
    }

    // Step 3: Update project files
    emit_progress("Updating project files...", 0.5);

    match cli::run_cyfr(&["update"], &proj_dir).await {
        Ok(output) => {
            tracing::info!("cyfr update: {}", output.stdout.trim());
        }
        Err(e) => {
            tracing::warn!("cyfr update failed: {}", e);
        }
    }

    // Step 4: Start container
    emit_progress("Starting server...", 0.7);

    if let Err(e) = lifecycle::start(&app, &proj_dir).await {
        emit_progress(&format!("Failed: {}", e), 0.7);
        return Err(e);
    }

    // Step 5: Wait for health
    emit_progress("Waiting for server...", 0.9);
    let _ = docker::health::wait_healthy(60).await;

    // Step 6: Re-index components
    emit_progress("Indexing new components...", 0.95);
    let _ = cli::run_cyfr(&["register"], &proj_dir).await;

    // Done
    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("Cyfr: Running");
    }

    emit_progress("Update complete.", 1.0);

    Ok(())
}
