use crate::docker::{health, lifecycle};
use crate::update::UpdateInfo;
use tauri::Manager;

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
    let proj_dir = app.path()
        .app_data_dir()
        .map_err(|e| format!("No app data dir: {}", e))?;
    lifecycle::start(&app, &proj_dir).await?;
    Ok(())
}

#[tauri::command]
pub async fn docker_stop(app: tauri::AppHandle) -> Result<(), String> {
    let proj_dir = app.path()
        .app_data_dir()
        .map_err(|e| format!("No app data dir: {}", e))?;
    lifecycle::stop(&proj_dir).await?;
    Ok(())
}

#[tauri::command]
pub async fn docker_restart(app: tauri::AppHandle) -> Result<(), String> {
    let proj_dir = app.path()
        .app_data_dir()
        .map_err(|e| format!("No app data dir: {}", e))?;
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

#[tauri::command]
pub async fn navigate_prism(app: tauri::AppHandle, path: String) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("main") {
        let js = format!("window.location.href = 'http://localhost:4001{}'", path);
        window.eval(&js).map_err(|e| format!("Failed to navigate: {}", e))?;
    }
    Ok(())
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

    let proj_dir = app.path()
        .app_data_dir()
        .map_err(|e| format!("No app data dir: {}", e))?;

    // Show upgrading overlay in the main window
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.eval(r#"
            (function() {
                var overlay = document.createElement('div');
                overlay.id = 'aqua-upgrade-overlay';
                overlay.style.cssText = 'position:fixed;inset:0;z-index:999999;display:flex;flex-direction:column;align-items:center;justify-content:center;background:rgba(15,23,42,0.95);color:#e2e8f0;font-family:system-ui,sans-serif;';
                overlay.innerHTML = '<div style="font-size:20px;font-weight:600;margin-bottom:12px;">Updating Cyfr</div>'
                    + '<div id="aqua-upgrade-status" style="font-size:13px;color:#94a3b8;">Stopping server\u2026</div>'
                    + '<div style="margin-top:20px;width:200px;height:4px;background:#1e293b;border-radius:2px;overflow:hidden;">'
                    + '<div id="aqua-upgrade-bar" style="width:10%;height:100%;background:#3b82f6;border-radius:2px;transition:width 0.3s;"></div></div>';
                document.body.appendChild(overlay);
            })();
        "#);
    }

    // Update tray status
    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("Cyfr: Updating...");
    }

    // Step 1: Stop container
    if let Err(e) = cli::run_cyfr(&["down"], &proj_dir).await {
        tracing::warn!("cyfr down during upgrade: {}", e);
    }

    // Step 2: Update CLI + pull Docker image
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.eval(r#"
            document.getElementById('aqua-upgrade-status').textContent = 'Updating CLI and pulling latest image\u2026';
            document.getElementById('aqua-upgrade-bar').style.width = '30%';
        "#);
    }

    match cli::run_cyfr(&["upgrade"], &proj_dir).await {
        Ok(output) if output.success => {
            tracing::info!("cyfr upgrade: {}", output.stdout.trim());
        }
        Ok(output) => {
            let msg = if output.stderr.is_empty() { &output.stdout } else { &output.stderr };
            tracing::warn!("cyfr upgrade warning: {}", msg.trim());
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.eval(r#"
                    document.getElementById('aqua-upgrade-status').textContent = 'CLI upgrade had warnings, continuing\u2026';
                    document.getElementById('aqua-upgrade-status').style.color = '#fbbf24';
                "#);
            }
        }
        Err(e) => {
            tracing::warn!("cyfr upgrade failed: {}", e);
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.eval(r#"
                    document.getElementById('aqua-upgrade-status').textContent = 'CLI upgrade failed, continuing with image update\u2026';
                    document.getElementById('aqua-upgrade-status').style.color = '#fbbf24';
                "#);
            }
        }
    }

    // Step 3: Update project files (docs, WIT definitions)
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.eval(r#"
            document.getElementById('aqua-upgrade-status').textContent = 'Updating project files\u2026';
            document.getElementById('aqua-upgrade-bar').style.width = '50%';
        "#);
    }

    match cli::run_cyfr(&["update"], &proj_dir).await {
        Ok(output) => {
            tracing::info!("cyfr update: {}", output.stdout.trim());
        }
        Err(e) => {
            tracing::warn!("cyfr update failed: {}", e);
        }
    }

    // Step 4: Start container
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.eval(r#"
            document.getElementById('aqua-upgrade-status').textContent = 'Starting server\u2026';
            document.getElementById('aqua-upgrade-bar').style.width = '70%';
        "#);
    }

    if let Err(e) = lifecycle::start(&app, &proj_dir).await {
        if let Some(window) = app.get_webview_window("main") {
            let js = format!(
                "document.getElementById('aqua-upgrade-status').textContent = 'Failed: {}';",
                e.replace('\'', "\\'")
            );
            let _ = window.eval(&js);
        }
        return Err(e);
    }

    // Step 4: Wait for health
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.eval(r#"
            document.getElementById('aqua-upgrade-status').textContent = 'Waiting for server\u2026';
            document.getElementById('aqua-upgrade-bar').style.width = '90%';
        "#);
    }

    let _ = docker::health::wait_healthy(60).await;

    // Step 5: Done — reload Prism UI
    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("Cyfr: Running");
    }

    // Remove overlay and reload to get the updated Prism UI
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.eval("window.location.href = 'http://localhost:4001';");
    }

    Ok(())
}
