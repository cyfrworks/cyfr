use crate::{cli, config, docker, gateway, preflight, TrayState};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use tauri::{async_runtime, Emitter, Manager};
use tracing::info;

static BOOT_STARTED: AtomicBool = AtomicBool::new(false);
/// Tracks whether the local MCP gateway has already bound to its port. Used
/// to make `start_gateway` idempotent across boot retries — the Rust process
/// outlives JS-side page reloads (which is how "Switch instance" works),
/// so the listener from the first boot is still alive and re-binding would
/// fail with "Address already in use".
static GATEWAY_STARTED: AtomicBool = AtomicBool::new(false);

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

    // The gateway listener is created once per Rust process. Subsequent boots
    // (e.g. after Switch instance, which reloads the webview but not the Rust
    // process) reuse the existing listener — backends are still refreshed
    // above, so any porta.json changes take effect.
    if GATEWAY_STARTED.swap(true, Ordering::SeqCst) {
        info!("MCP gateway already running on port {} — skipping bind", gateway_port);
        return Ok(());
    }

    let listener = match gateway::bind(gateway_bind, gateway_port).await {
        Ok(l) => l,
        Err(e) => {
            // Roll back the flag so a future retry can try again.
            GATEWAY_STARTED.store(false, Ordering::SeqCst);
            return Err(format!("Failed to start MCP gateway on port {}: {}", gateway_port, e));
        }
    };

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
    // In remote mode auth lives in porta.json (api_key), not the CLI's
    // config.json — so `cyfr whoami` would always say "not authenticated".
    // The frontend's checkAuth() uses the shared MCP client with the api_key
    // and is the source of truth. Skip the CLI probe here in remote mode.
    let ready_message = if preflight::runtime_mode() == preflight::RuntimeMode::AttachedRemote {
        "Ready!"
    } else {
        match preflight::is_authenticated().await {
            Ok(true) => "Ready!",
            Ok(false) => "Environment ready. Sign in to continue.",
            Err(_) => "Ready!",
        }
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

/// Ensure the managed project's compose setup includes the MCP gateway bridge
/// that lets the cyfr container reach porta's gateway at
/// `host.docker.internal:9500`. This is porta's concern, not codex's — codex
/// stopped shipping the `extra_hosts` line in its templates, so porta adds it
/// for its own local-managed project via a `docker-compose.override.yml`.
///
/// Non-destructive: if either `docker-compose.yml` or
/// `docker-compose.override.yml` already contains the bridge marker
/// (`host.docker.internal:host-gateway`), this returns `Ok(false)` without
/// touching any files. Only writes an override file when the bridge is
/// genuinely missing.
///
/// Returns `Ok(true)` if an override was written, `Ok(false)` if everything
/// was already in place, `Err` on IO failure.
fn ensure_mcp_gateway_bridge(proj_dir: &std::path::Path) -> Result<bool, String> {
    const BRIDGE_MARKER: &str = "host.docker.internal:host-gateway";
    const OVERRIDE_CONTENT: &str = "\
# Auto-generated by porta — MCP gateway bridge for local-managed mode.
# Lets the cyfr container reach porta's MCP gateway at host.docker.internal:9500.
# Safe to delete; porta will recreate it on next boot if still missing.
services:
  cyfr:
    extra_hosts:
      - \"host.docker.internal:host-gateway\"
";

    let compose_path = proj_dir.join("docker-compose.yml");
    let override_path = proj_dir.join("docker-compose.override.yml");

    // If either file already has the bridge entry, we're done.
    for path in [&compose_path, &override_path] {
        if let Ok(content) = std::fs::read_to_string(path) {
            if content.contains(BRIDGE_MARKER) {
                info!(
                    "MCP gateway bridge already present in {} — leaving compose files alone",
                    path.display()
                );
                return Ok(false);
            }
        }
    }

    // Neither has it — write the override.
    std::fs::write(&override_path, OVERRIDE_CONTENT)
        .map_err(|e| format!("Failed to write {}: {}", override_path.display(), e))?;
    info!("Wrote {} with MCP gateway bridge", override_path.display());
    Ok(true)
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
            // Some required entries (like `aqua/`) may not be created by older
            // cyfr CLI versions that don't know about them. Create any missing
            // directory-only entries here as a fallback so Porta works against
            // a not-yet-updated CLI. The container's entrypoint seeds the
            // contents on first start.
            for entry in preflight::missing_project_entries(&proj_dir) {
                let target = proj_dir.join(entry);
                if !entry.contains('.') {
                    let _ = std::fs::create_dir_all(&target);
                }
            }

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
    // First-run gate: if the user hasn't picked a mode yet, render the wizard.
    // The wizard saves a mode and re-invokes start_boot.
    if preflight::needs_setup_wizard() {
        reset_boot();
        emit(
            &app,
            "setup_required",
            "Choose how to connect to CYFR",
            None,
        );
        return;
    }

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

            // Porta owns the MCP gateway bridge line in compose. Ensure it's
            // present via a docker-compose.override.yml if neither the main
            // compose nor an existing override already has it. Non-fatal on
            // failure: on macOS, Docker Desktop auto-resolves
            // host.docker.internal even without the extra_hosts mapping.
            match ensure_mcp_gateway_bridge(&proj_dir) {
                Ok(true) => info!("Added MCP gateway bridge to managed project"),
                Ok(false) => {}
                Err(e) => tracing::warn!(
                    "Failed to ensure MCP gateway bridge: {} — porta's gateway may be \
                     unreachable from the cyfr container on Linux (macOS is fine via \
                     Docker Desktop)",
                    e
                ),
            }

            if server_healthy {
                // Healthy doesn't mean it's OUR container — an external
                // process (e.g. `mix phx.server`, an old `cyfr up` from a
                // different project, or a leftover from local-attached
                // mode) could be holding port 4000. Verify the cyfr docker
                // container is actually running before assuming we own it.
                let is_our_container = matches!(
                    docker::lifecycle::status().await,
                    Ok(s) if s == "running"
                );
                if is_our_container {
                    info!(
                        "Managed local CYFR already healthy at {} — skipping Docker startup",
                        config::cyfr_url()
                    );
                    emit(&app, "starting", "CYFR server detected!", Some(0.5));
                } else {
                    reset_boot();
                    emit(
                        &app,
                        "error",
                        "Port 4000 is in use by another process (not Porta's Cyfr container). \
                         Stop it (e.g. quit a running `mix phx.server` or `cyfr up` from another \
                         project) and click Retry.",
                        None,
                    );
                    return;
                }
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
