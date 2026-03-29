use crate::{cli, config, docker, gateway, preflight, TrayState};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
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

fn emit(
    app: &tauri::AppHandle,
    state: &'static str,
    message: impl Into<String>,
    progress: Option<f32>,
) {
    let msg = message.into();
    info!("Boot: [{}] {}", state, msg);
    let _ = app.emit(
        "boot-state",
        BootEvent {
            state,
            message: msg,
            progress,
        },
    );
}

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
        let _ = app.emit(
            "boot-state",
            BootEvent {
                state,
                message: msg,
                progress: Some(progress),
            },
        );
    }
}

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

pub fn should_stop_cyfr_on_exit() -> bool {
    preflight::should_stop_on_exit()
}

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

    let listener = gateway::bind(gateway_bind, gateway_port)
        .await
        .map_err(|e| format!("Failed to start MCP gateway on port {}: {}", gateway_port, e))?;

    let gateway_registry = registry.clone();
    async_runtime::spawn(async move {
        if let Err(e) = gateway::serve(listener, gateway_registry).await {
            tracing::error!("Gateway serve error: {}", e);
        }
    });

    Ok(())
}

async fn ensure_cli(app: &tauri::AppHandle) -> Result<(), String> {
    emit(app, "checking", "Checking cyfr CLI...", Some(0.15));

    match cli::check_cli().await {
        Some(version) => {
            info!("cyfr CLI found: {}", version);
            Ok(())
        }
        None => {
            if let Some(path) = cli::find_cli_path() {
                info!("cyfr CLI found at {} (not in PATH)", path.display());
                return Ok(());
            }

            emit(app, "installing_cli", "Installing cyfr CLI...", Some(0.2));
            let brew_app = app.clone();
            let installed = match cli::install_cli_brew_streaming(
                120,
                move |line, _stream| {
                    let _ = brew_app.emit(
                        "boot-state",
                        BootEvent {
                            state: "installing_cli",
                            message: line.to_string(),
                            progress: None,
                        },
                    );
                },
            )
            .await
            {
                Ok(output) if output.success => true,
                _ => {
                    emit(app, "installing_cli", "Downloading cyfr CLI...", Some(0.2));
                    matches!(cli::install_cli_direct().await, Ok(output) if output.success)
                }
            };

            if !installed {
                return Err(
                    "Could not install cyfr CLI. Download from: https://github.com/cyfrworks/cyfr/releases"
                        .to_string(),
                );
            }

            if cli::check_cli().await.is_none() && cli::find_cli_path().is_none() {
                return Err(
                    "cyfr CLI was installed but could not be found. Please add it to your PATH and click Retry."
                        .to_string(),
                );
            }

            emit(app, "installing_cli", "cyfr CLI installed!", Some(0.25));
            Ok(())
        }
    }
}

async fn finish_boot(app: &tauri::AppHandle) {
    let ready_message = match preflight::is_authenticated().await {
        Ok(true) => "Ready!",
        Ok(false) => "Environment ready. Sign in to continue.",
        Err(_) => "Ready!",
    };

    emit(app, "ready", ready_message, Some(1.0));

    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("CYFR: Running");
    }

    let update_app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        crate::update::check_and_notify(&update_app).await;
    });
}

async fn reconcile_managed_project(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    let proj_dir = preflight::project_dir()?;
    let existed_before = proj_dir.exists();
    std::fs::create_dir_all(&proj_dir)
        .map_err(|e| format!("Failed to create project directory: {}", e))?;

    let missing = preflight::missing_project_entries(&proj_dir);
    if missing.is_empty() {
        return Ok(proj_dir);
    }

    let setup_msg = if existed_before {
        "Repairing CYFR project files..."
    } else {
        "Setting up CYFR for the first time..."
    };
    emit(app, "init", setup_msg, Some(0.3));

    let result = cli::run_cyfr_streaming(
        &["init"],
        &proj_dir,
        600,
        boot_progress_callback(app, "init", 0.3, 0.44, 0.003),
    )
    .await;

    match result {
        Ok(output) if output.success => {
            let missing_after = preflight::missing_project_entries(&proj_dir);
            if missing_after.is_empty() {
                Ok(proj_dir)
            } else {
                Err(format!(
                    "CYFR project is still missing required files after init: {}",
                    missing_after.join(", ")
                ))
            }
        }
        Ok(output) => {
            let msg = if output.stderr.is_empty() {
                output.stdout
            } else {
                output.stderr
            };
            Err(format!("cyfr init failed: {}", msg.trim()))
        }
        Err(e) => Err(format!("Failed to run cyfr init: {}", e)),
    }
}

async fn boot_sequence(app: tauri::AppHandle) {
    emit(&app, "checking", "Checking for running CYFR server...", Some(0.05));
    let server_healthy = docker::health::check_health().await;
    let runtime_mode = preflight::detect_runtime_mode(server_healthy).await;
    preflight::set_runtime_mode(runtime_mode);

    if let Err(e) = ensure_cli(&app).await {
        reset_boot();
        emit(&app, "cli_not_found", e, None);
        return;
    }

    match runtime_mode {
        preflight::RuntimeMode::AttachedRemote => {
            if !server_healthy {
                reset_boot();
                emit(
                    &app,
                    "error",
                    format!("Could not reach configured CYFR server at {}", config::cyfr_url()),
                    None,
                );
                return;
            }
            emit(&app, "starting", "Connected to existing CYFR server", Some(0.5));
        }
        preflight::RuntimeMode::AttachedDev => {
            emit(&app, "starting", "CYFR dev server detected!", Some(0.5));
        }
        preflight::RuntimeMode::ManagedLocal => {
            let proj_dir = match reconcile_managed_project(&app).await {
                Ok(dir) => dir,
                Err(e) => {
                    reset_boot();
                    emit(&app, "error", e, None);
                    return;
                }
            };

            if server_healthy {
                info!(
                    "Managed local CYFR already healthy at {} — skipping Docker startup",
                    config::cyfr_url()
                );
                emit(&app, "starting", "CYFR server detected!", Some(0.5));
            } else {
                emit(&app, "checking", "Checking Docker...", Some(0.46));
                match docker::lifecycle::check_docker_state().await {
                    docker::lifecycle::DockerState::NotInstalled => {
                        reset_boot();
                        emit(
                            &app,
                            "docker_not_found",
                            "Docker is required. Click Install to download and set up automatically.",
                            None,
                        );
                        return;
                    }
                    docker::lifecycle::DockerState::NotRunning(_) => {
                        reset_boot();
                        emit(
                            &app,
                            "docker_not_running",
                            "Please start Docker and click Retry.",
                            None,
                        );
                        return;
                    }
                    docker::lifecycle::DockerState::Ready => {}
                }

                emit(&app, "starting", "Starting CYFR...", Some(0.55));
                let result = cli::run_cyfr_streaming(
                    &["up"],
                    &proj_dir,
                    120,
                    boot_progress_callback(&app, "starting", 0.55, 0.68, 0.005),
                )
                .await;

                match result {
                    Ok(output) if output.success => {}
                    _ => {
                        info!("First cyfr up failed, retrying with down + up");
                        emit(&app, "starting", "Retrying startup...", Some(0.58));
                        let _ = cli::run_cyfr(&["down"], &proj_dir).await;

                        let retry_result = cli::run_cyfr_streaming(
                            &["up"],
                            &proj_dir,
                            120,
                            boot_progress_callback(&app, "starting", 0.58, 0.68, 0.005),
                        )
                        .await;

                        match retry_result {
                            Ok(output) if output.success => {}
                            Ok(output) => {
                                let msg = if output.stderr.is_empty() {
                                    output.stdout
                                } else {
                                    output.stderr
                                };
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

                emit(&app, "starting", "Waiting for CYFR to be ready...", Some(0.7));
                let health_app = app.clone();
                match docker::health::wait_healthy(
                    |msg, progress| {
                        emit(&health_app, "starting", msg, Some(progress));
                    },
                    90,
                    0.7,
                    0.95,
                )
                .await
                {
                    Ok(()) => emit(&app, "starting", "Server is up, verifying...", Some(0.9)),
                    Err(e) => {
                        reset_boot();
                        emit(&app, "error", format!("Server did not start in time. {}", e), None);
                        return;
                    }
                }
            }
        }
    }

    emit(&app, "starting", "Starting MCP gateway...", Some(0.92));
    if let Err(e) = start_gateway(&app).await {
        reset_boot();
        emit(&app, "error", e, None);
        return;
    }

    finish_boot(&app).await;
}
