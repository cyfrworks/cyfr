use crate::{cli, config, docker, gateway, TrayState};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{async_runtime, Emitter, Manager};
use tracing::info;

static BOOT_STARTED: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, Serialize)]
pub struct BootEvent {
    pub state: &'static str,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<f32>,
}

fn emit(app: &tauri::AppHandle, state: &'static str, message: impl Into<String>, progress: Option<f32>) {
    let msg = message.into();
    info!("Boot: [{}] {}", state, msg);
    let _ = app.emit("boot-state", BootEvent {
        state,
        message: msg,
        progress,
    });
}

/// Try to start boot — deduplicates multiple triggers
pub async fn try_start_boot(app: tauri::AppHandle) {
    if BOOT_STARTED.swap(true, Ordering::SeqCst) {
        info!("Boot already started, skipping");
        return;
    }
    boot_sequence(app).await;
}

pub fn reset_boot() {
    BOOT_STARTED.store(false, Ordering::SeqCst);
}

/// Bind and start the MCP gateway. Returns Ok if bind succeeds, Err if port is in use.
async fn start_gateway(app: &tauri::AppHandle) -> Result<(), String> {
    let cfg = config::load_config();
    let gateway_port = config::GATEWAY_PORT;
    let gateway_bind = config::GATEWAY_BIND;

    let registry: gateway::SharedRegistry = app.state::<gateway::SharedRegistry>().inner().clone();
    {
        let mut reg = registry.write().await;
        for (name, server_cfg) in &cfg.mcp_servers {
            if server_cfg.enabled {
                let backend_cfg = config::to_backend_config(name, server_cfg);
                if let Err(e) = reg.start_backend(&backend_cfg).await {
                    tracing::warn!("Failed to start backend '{}': {}", name, e);
                }
            }
        }
    }

    // Bind first — fail fast if port is in use
    let listener = gateway::bind(gateway_bind, gateway_port)
        .await
        .map_err(|e| format!("Failed to start MCP gateway on port {}: {}", gateway_port, e))?;

    // Serve in background — bind succeeded so this is safe to fire-and-forget
    let gateway_registry = registry.clone();
    async_runtime::spawn(async move {
        if let Err(e) = gateway::serve(listener, gateway_registry).await {
            tracing::error!("Gateway serve error: {}", e);
        }
    });

    Ok(())
}

/// Fast-path boot: CYFR server is already running, just start the gateway and finish.
async fn boot_gateway_and_finish(app: &tauri::AppHandle) {
    // Start MCP gateway
    emit(app, "starting", "Starting MCP gateway...", Some(0.6));

    if let Err(e) = start_gateway(app).await {
        tracing::warn!("Gateway failed in fast-path: {}", e);
        // Non-fatal in fast path — server is already running, tools may still work via direct calls
    }

    // Ready
    emit(app, "ready", "Ready!", Some(1.0));

    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("Cyfr: Running");
    }

    // Check for updates after a delay
    let update_app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        crate::update::check_and_notify(&update_app).await;
    });
}

/// Get the project directory: ~/cyfr/
fn project_dir(_app: &tauri::AppHandle) -> std::path::PathBuf {
    dirs::home_dir()
        .expect("could not determine home directory")
        .join("cyfr")
}

async fn boot_sequence(app: tauri::AppHandle) {
    // Quick check: is CYFR server already running? (e.g., local dev server, existing container)
    emit(&app, "checking", "Checking for running Cyfr server...", Some(0.05));

    if docker::health::check_health().await {
        info!("CYFR server already healthy at localhost:4000 — skipping Docker/CLI setup");
        emit(&app, "starting", "Cyfr server detected!", Some(0.5));

        // Still need the MCP gateway and CLI for tool calls
        boot_gateway_and_finish(&app).await;
        return;
    }

    // Step 1: Check Docker
    emit(&app, "checking", "Checking Docker...", Some(0.1));

    match docker::lifecycle::check_docker_state().await {
        docker::lifecycle::DockerState::NotInstalled => {
            reset_boot();
            emit(&app, "docker_not_found",
                "Docker is required. Click Install to download and set up automatically.",
                None);
            return;
        }
        docker::lifecycle::DockerState::NotRunning(_) => {
            reset_boot();
            emit(&app, "docker_not_running",
                "Please start Docker and click Retry.",
                None);
            return;
        }
        docker::lifecycle::DockerState::Ready => {}
    }

    // Step 2: Check cyfr CLI
    emit(&app, "checking", "Checking cyfr CLI...", Some(0.15));

    match cli::check_cli().await {
        Some(version) => {
            info!("cyfr CLI found: {}", version);
        }
        None => {
            // CLI not in PATH — try direct path search before installing
            if let Some(path) = cli::find_cli_path() {
                info!("cyfr CLI found at {} (not in PATH)", path.display());
            } else {
                emit(&app, "installing_cli", "Installing cyfr CLI...", Some(0.2));

                // Try Homebrew first, then fall back to install script
                let installed = match cli::install_cli_brew().await {
                    Ok(output) if output.success => true,
                    _ => {
                        // Fall back to install script (works on macOS and Linux without Homebrew)
                        emit(&app, "installing_cli", "Installing cyfr CLI via install script...", Some(0.2));
                        match cli::install_cli_script().await {
                            Ok(output) if output.success => true,
                            _ => false,
                        }
                    }
                };

                if !installed {
                    reset_boot();
                    emit(&app, "cli_not_found",
                        "Could not install cyfr CLI. Download from: https://github.com/cyfrworks/cyfr/releases".to_string(),
                        None);
                    return;
                }

                // Refresh PATH so the newly installed binary is discoverable
                cli::refresh_path();

                // Verify the CLI is now callable
                if cli::check_cli().await.is_none() {
                    // PATH still doesn't have it — try direct path search
                    if cli::find_cli_path().is_none() {
                        reset_boot();
                        emit(&app, "cli_not_found",
                            "cyfr CLI was installed but could not be found. Please add it to your PATH and click Retry.".to_string(),
                            None);
                        return;
                    }
                }

                emit(&app, "installing_cli", "cyfr CLI installed!", Some(0.25));
            }
        }
    }

    // Step 3: Ensure project directory exists
    let proj_dir = project_dir(&app);
    if let Err(e) = std::fs::create_dir_all(&proj_dir) {
        reset_boot();
        emit(&app, "error", format!("Failed to create project directory: {}", e), None);
        return;
    }

    // Step 4: Check if initialized (cyfr.yaml exists)
    let cyfr_yaml = proj_dir.join("cyfr.yaml");
    if !cyfr_yaml.exists() {
        emit(&app, "init", "Setting up CYFR for the first time...", Some(0.3));

        match cli::run_cyfr(&["init"], &proj_dir).await {
            Ok(output) if output.success => {
                // Show init output
                for line in output.stdout.lines() {
                    if !line.trim().is_empty() {
                        emit(&app, "init", line.trim(), None);
                    }
                }
            }
            Ok(output) => {
                let msg = if output.stderr.is_empty() { output.stdout } else { output.stderr };
                reset_boot();
                emit(&app, "error", format!("cyfr init failed: {}", msg.trim()), None);
                return;
            }
            Err(e) => {
                reset_boot();
                emit(&app, "error", format!("Failed to run cyfr init: {}", e), None);
                return;
            }
        }
    }

    // Step 5: Start MCP gateway
    emit(&app, "starting", "Starting MCP gateway...", Some(0.45));

    if let Err(e) = start_gateway(&app).await {
        reset_boot();
        emit(&app, "error", e, None);
        return;
    }

    // Step 6: Start container (cyfr up) — skip if already running
    let container_status = docker::lifecycle::status().await.unwrap_or_default();
    if container_status == "running" {
        info!("Container already running, skipping cyfr up");
        emit(&app, "starting", "Cyfr already running", Some(0.6));
    } else {
        emit(&app, "starting", "Starting Cyfr...", Some(0.55));
        match docker::lifecycle::start(&app, &proj_dir).await {
            Ok(stdout) => {
                for line in stdout.lines() {
                    if !line.trim().is_empty() {
                        emit(&app, "starting", line.trim(), None);
                    }
                }
            }
            Err(e) => {
                reset_boot();
                emit(&app, "error", format!("Failed to start: {}", e), None);
                return;
            }
        }
    }

    // Step 7: Wait for health (90s deadline — first boot may pull image + run migrations)
    emit(&app, "starting", "Waiting for Cyfr to be ready...", Some(0.7));
    match docker::health::wait_healthy(&app, 90).await {
        Ok(()) => {
            emit(&app, "starting", "Server is up, verifying...", Some(0.9));
        }
        Err(e) => {
            reset_boot();
            emit(&app, "error", format!("Server did not start in time. {}", e), None);
            return;
        }
    }

    // Step 7b: Verify MCP endpoint is ready (what login actually needs)
    // Poll up to 30s — health passed so this should be relatively fast
    emit(&app, "starting", "Verifying API endpoint...", Some(0.92));
    let mut mcp_ready = false;
    for _ in 0..30 {
        if docker::health::check_mcp_ready().await {
            mcp_ready = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    if !mcp_ready {
        tracing::warn!("MCP endpoint not ready — login may fail until server finishes starting");
    }

    // Step 8: Ready — the React frontend will call transition_to_main
    emit(&app, "ready", "Ready!", Some(1.0));

    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("Cyfr: Running");
    }

    // Check for updates after a delay
    let update_app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        crate::update::check_and_notify(&update_app).await;
    });
}
