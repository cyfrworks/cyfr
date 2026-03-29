use crate::{cli, config, docker, gateway, TrayState};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use tauri::{async_runtime, Emitter, Manager};
use tracing::info;

static BOOT_STARTED: AtomicBool = AtomicBool::new(false);

/// Tracks whether Porta started the container (so we only stop it on exit if we started it).
static PORTA_STARTED_CONTAINER: AtomicBool = AtomicBool::new(false);

/// Returns true if Porta was responsible for starting the container during this session.
pub fn did_start_container() -> bool {
    PORTA_STARTED_CONTAINER.load(Ordering::SeqCst)
}

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

/// Build a streaming callback that emits `boot-state` events with interpolated progress.
/// Progress advances from `start` toward `end` by `step` per output line.
fn boot_progress_callback(
    app: &tauri::AppHandle,
    state: &'static str,
    start: f32,
    end: f32,
    step: f32,
) -> impl Fn(&str, &str) + Send {
    let app = app.clone();
    let counter = Arc::new(AtomicU32::new(0));
    move |line: &str, _stream: &str| {
        let n = counter.fetch_add(1, Ordering::Relaxed);
        let progress = (start + (n as f32 * step)).min(end);
        let msg = line.to_string();
        info!("Boot: [{}] {}", state, msg);
        let _ = app.emit("boot-state", BootEvent {
            state,
            message: msg,
            progress: Some(progress),
        });
    }
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

    // Register Porta gateway with Cyfr (background, retries)
    gateway::spawn_registration(config::GATEWAY_PORT, 2, 3);

    // Ready
    emit(app, "ready", "Ready!", Some(1.0));

    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("CYFR: Running");
    }

    // Check for updates after a delay
    let update_app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        crate::update::check_and_notify(&update_app).await;
    });
}

/// Get the project directory: ~/cyfr/
fn project_dir() -> Result<std::path::PathBuf, String> {
    Ok(crate::home_dir()?.join("cyfr"))
}

async fn boot_sequence(app: tauri::AppHandle) {
    // Quick check: is CYFR server already running? (e.g., local dev server, existing container)
    emit(&app, "checking", "Checking for running CYFR server...", Some(0.05));

    if docker::health::check_health().await {
        info!("CYFR server already healthy at {} — skipping Docker/CLI setup", config::cyfr_url());
        emit(&app, "starting", "CYFR server detected!", Some(0.5));

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

                // Try Homebrew first (with streaming progress), then fall back to direct download
                let brew_app = app.clone();
                let installed = match cli::install_cli_brew_streaming(
                    120,
                    move |line, _stream| {
                        let _ = brew_app.emit("boot-state", BootEvent {
                            state: "installing_cli",
                            message: line.to_string(),
                            progress: None,
                        });
                    },
                ).await {
                    Ok(output) if output.success => true,
                    _ => {
                        emit(&app, "installing_cli", "Downloading cyfr CLI...", Some(0.2));
                        match cli::install_cli_direct().await {
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

                // Verify the CLI is now callable (install cached the path in CLI_PATH)
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
    let proj_dir = match project_dir() {
        Ok(d) => d,
        Err(e) => {
            reset_boot();
            emit(&app, "error", e, None);
            return;
        }
    };
    if let Err(e) = std::fs::create_dir_all(&proj_dir) {
        reset_boot();
        emit(&app, "error", format!("Failed to create project directory: {}", e), None);
        return;
    }

    // Step 4: Check if initialized (cyfr.yaml exists)
    let cyfr_yaml = proj_dir.join("cyfr.yaml");
    let mut first_boot = false;
    if !cyfr_yaml.exists() {
        emit(&app, "init", "Setting up CYFR for the first time...", Some(0.3));

        // Use streaming so Docker image pull progress is visible in the UI.
        // 600s idle timeout: `cyfr init` pulls Docker images which can be slow on
        // first boot with large images — as long as progress output flows, the idle
        // timer resets. The 600s is a safety net for pathological silence.
        let result = cli::run_cyfr_streaming(
            &["init"],
            &proj_dir,
            600,
            boot_progress_callback(&app, "init", 0.3, 0.44, 0.003),
        )
        .await;

        match result {
            Ok(output) if output.success => {
                first_boot = true;
            }
            Ok(output) => {
                let msg = if output.stderr.is_empty() { output.stdout } else { output.stderr };
                let _ = std::fs::remove_file(&cyfr_yaml);
                reset_boot();
                emit(&app, "error", format!("cyfr init failed: {}", msg.trim()), None);
                return;
            }
            Err(e) => {
                let _ = std::fs::remove_file(&cyfr_yaml);
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

    // Step 6: Start container (cyfr up) — skip if already healthy
    if docker::health::check_health().await {
        info!("Server already healthy, skipping cyfr up");
        emit(&app, "starting", "CYFR already running", Some(0.6));
    } else {
        emit(&app, "starting", "Starting CYFR...", Some(0.55));

        // Use 600s idle timeout on first boot in case init's image pull was
        // incomplete — docker compose up may need to pull the image itself.
        let up_idle_timeout = if first_boot { 600 } else { 120 };

        // Use streaming so Docker Compose output is visible in the UI
        let result = cli::run_cyfr_streaming(
            &["up"],
            &proj_dir,
            up_idle_timeout,
            boot_progress_callback(&app, "starting", 0.55, 0.68, 0.005),
        )
        .await;

        match result {
            Ok(output) if output.success => {
                PORTA_STARTED_CONTAINER.store(true, Ordering::SeqCst);
            }
            _ => {
                // First attempt failed — retry with down + up (matches upgrade flow)
                info!("First cyfr up failed, retrying with down + up");
                emit(&app, "starting", "Retrying startup...", Some(0.58));
                let _ = cli::run_cyfr(&["down"], &proj_dir).await;

                let retry_result = cli::run_cyfr_streaming(
                    &["up"],
                    &proj_dir,
                    up_idle_timeout,
                    boot_progress_callback(&app, "starting", 0.58, 0.68, 0.005),
                )
                .await;

                match retry_result {
                    Ok(output) if output.success => {
                        PORTA_STARTED_CONTAINER.store(true, Ordering::SeqCst);
                    }
                    Ok(output) => {
                        let msg = if output.stderr.is_empty() { output.stdout } else { output.stderr };
                        reset_boot();
                        emit(&app, "error", format!("Failed to start: {}", msg.trim()), None);
                        return;
                    }
                    Err(e) => {
                        reset_boot();
                        emit(&app, "error", format!("Failed to start: {}", e), None);
                        return;
                    }
                }
            }
        }
    }

    // Step 7: Wait for health (90s deadline — first boot may pull image + run migrations)
    emit(&app, "starting", "Waiting for CYFR to be ready...", Some(0.7));
    let health_app = app.clone();
    match docker::health::wait_healthy(
        |msg, progress| {
            emit(&health_app, "starting", msg, Some(progress));
        },
        90,
        0.7,
        0.95,
    ).await {
        Ok(()) => {
            emit(&app, "starting", "Server is up, verifying...", Some(0.9));
        }
        Err(e) => {
            reset_boot();
            emit(&app, "error", format!("Server did not start in time. {}", e), None);
            return;
        }
    }

    // Register Porta gateway with Cyfr now that both are up
    gateway::spawn_registration(config::GATEWAY_PORT, 0, 3);

    // Step 8: Ready — the React frontend will call transition_to_main
    emit(&app, "ready", "Ready!", Some(1.0));

    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("CYFR: Running");
    }

    // Check for updates after a delay
    let update_app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        crate::update::check_and_notify(&update_app).await;
    });
}
