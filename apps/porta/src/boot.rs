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

/// Get the project directory (Tauri app data dir)
fn project_dir(app: &tauri::AppHandle) -> std::path::PathBuf {
    app.path()
        .app_data_dir()
        .expect("could not determine app data directory")
}

async fn boot_sequence(app: tauri::AppHandle) {
    // Step 1: Check Docker
    emit(&app, "checking", "Checking Docker...", Some(0.05));

    match docker::lifecycle::check_docker_state().await {
        docker::lifecycle::DockerState::NotInstalled => {
            emit(&app, "docker_not_found",
                "Docker Desktop is required. Click Install to download and set up automatically.",
                None);
            return;
        }
        docker::lifecycle::DockerState::NotRunning(_) => {
            emit(&app, "docker_not_running",
                "Please start Docker Desktop and click Retry.",
                None);
            return;
        }
        docker::lifecycle::DockerState::Ready => {}
    }

    // Step 2: Check cyfr CLI
    emit(&app, "checking", "Checking cyfr CLI...", Some(0.1));

    match cli::check_cli().await {
        Some(version) => {
            info!("cyfr CLI found: {}", version);
        }
        None => {
            // Try to install via Homebrew
            emit(&app, "installing_cli", "Installing cyfr CLI...", Some(0.15));

            match cli::install_cli_brew().await {
                Ok(output) if output.success => {
                    emit(&app, "installing_cli", "cyfr CLI installed!", Some(0.25));
                }
                Ok(output) => {
                    let msg = format!("Installation failed: {}", output.stderr.trim());
                    emit(&app, "cli_not_found", msg, None);
                    return;
                }
                Err(e) => {
                    // No brew or install failed
                    emit(&app, "cli_not_found",
                        format!("Could not install cyfr CLI. {} Download from: https://github.com/cyfrworks/cyfr/releases", e),
                        None);
                    return;
                }
            }
        }
    }

    // Step 3: Ensure project directory exists
    let proj_dir = project_dir(&app);
    if let Err(e) = std::fs::create_dir_all(&proj_dir) {
        emit(&app, "error", format!("Failed to create project directory: {}", e), None);
        return;
    }

    // Step 4: Check if initialized (cyfr.yaml exists)
    let cyfr_yaml = proj_dir.join("cyfr.yaml");
    if !cyfr_yaml.exists() {
        emit(&app, "init", "Setting up CYFR Porta for the first time...", Some(0.3));

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
                emit(&app, "error", format!("cyfr init failed: {}", msg.trim()), None);
                return;
            }
            Err(e) => {
                emit(&app, "error", format!("Failed to run cyfr init: {}", e), None);
                return;
            }
        }
    }

    // Step 5: Start MCP gateway
    emit(&app, "starting", "Starting MCP gateway...", Some(0.45));
    let cfg = config::load_config();
    let gateway_port = config::GATEWAY_PORT;
    let gateway_bind = config::GATEWAY_BIND.to_string();

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

    let gateway_registry = registry.clone();
    async_runtime::spawn(async move {
        if let Err(e) = gateway::start(gateway_bind, gateway_port, gateway_registry).await {
            tracing::error!("Gateway failed: {}", e);
        }
    });

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

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
                emit(&app, "error", format!("Failed to start: {}", e), None);
                return;
            }
        }
    }

    // Step 7: Wait for health
    emit(&app, "starting", "Waiting for Cyfr to be ready...", Some(0.7));
    match docker::health::wait_healthy(60).await {
        Ok(()) => {
            emit(&app, "starting", "Cyfr is ready!", Some(0.9));
        }
        Err(e) => {
            tracing::warn!("Health check warning: {}", e);
        }
    }

    // Step 8: Ready
    emit(&app, "ready", "Ready!", Some(1.0));
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    open_main_window(&app);

    if let Some(state) = app.try_state::<TrayState>() {
        let _ = state.status_item.set_text("Cyfr: Running");
    }

    // Check for Cyfr updates now that the main window is open
    let update_app = app.clone();
    tauri::async_runtime::spawn(async move {
        // Brief delay for the webview to finish loading
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        crate::update::check_and_notify(&update_app).await;
    });
}

fn open_main_window(app: &tauri::AppHandle) {
    if let Some(boot) = app.get_webview_window("boot") {
        let _ = boot.close();
    }

    // Persist webview data (cookies, localStorage) so sessions survive restarts
    // macOS uses dataStoreIdentifier (UUID as 16 bytes) instead of dataDirectory
    let data_store_id: [u8; 16] = [
        0xA0, 0x0A, 0xC1, 0xF2,
        0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01,
    ];

    let main_window = tauri::WebviewWindowBuilder::new(
        app,
        "main",
        tauri::WebviewUrl::External("http://localhost:4001".parse().unwrap()),
    )
    .title("CYFR Porta")
    .inner_size(1280.0, 800.0)
    .center()
    .data_store_identifier(data_store_id)
    .on_navigation(|url| {
        // Allow localhost (Prism UI), block everything else and open in browser
        if url.host_str() == Some("localhost") || url.host_str() == Some("127.0.0.1") {
            true
        } else {
            let _ = std::process::Command::new("open").arg(url.as_str()).spawn();
            false
        }
    })
    .build();

    // Inject CYFR Porta bridge + external link handler into Prism webview
    if let Ok(window) = main_window {
        let _ = window.eval(r#"
            // External link handler: open target="_blank" and https:// links in default browser
            document.addEventListener('click', function(e) {
                var link = e.target.closest('a[target="_blank"], a[href^="https://"], a[href^="http://"]');
                if (link && link.href) {
                    var url = new URL(link.href, window.location.origin);
                    if (url.hostname !== 'localhost' && url.hostname !== '127.0.0.1') {
                        e.preventDefault();
                        e.stopPropagation();
                        if (window.__TAURI__ && window.__TAURI__.core) {
                            window.__TAURI__.core.invoke('open_url', { url: link.href });
                        }
                    }
                }
            }, true);

            // CYFR Porta bridge: allows Prism (or automation) to interact with the desktop shell
            window.aqua = {
                navigate: function(path) {
                    window.location.href = 'http://localhost:4001' + path;
                },
                invoke: function(cmd, args) {
                    if (window.__TAURI__ && window.__TAURI__.core) {
                        return window.__TAURI__.core.invoke(cmd, args || {});
                    }
                    return Promise.reject('Tauri not available');
                },
                openExternal: function(url) {
                    if (window.__TAURI__ && window.__TAURI__.core) {
                        return window.__TAURI__.core.invoke('open_url', { url: url });
                    }
                }
            };

        "#);
    }
}
