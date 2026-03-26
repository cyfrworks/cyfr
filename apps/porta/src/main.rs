#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use porta::{backend, commands, gateway, tray, update};
use std::process::Stdio;
use std::sync::Arc;
use tauri::{async_runtime, Manager, RunEvent, WindowEvent};
use tokio::sync::RwLock;
use tracing::info;
use tracing_subscriber::prelude::*;
use tracing_subscriber::EnvFilter;

fn main() {
    // Singleton check: try to bind a TCP port as an instance lock.
    // If another instance is running, it holds the port → our bind fails → exit.
    let _lock = match std::net::TcpListener::bind("127.0.0.1:19500") {
        Ok(listener) => Some(listener),
        Err(_) => {
            eprintln!("CYFR is already running.");
            std::process::exit(1);
        }
    };

    // Fix PATH for .app bundles on macOS — they inherit a minimal PATH
    // that doesn't include /usr/local/bin, /opt/homebrew/bin, or ~/.local/bin
    // where Docker and the cyfr CLI live.
    porta::cli::refresh_path();

    let filter = EnvFilter::from_default_env().add_directive("porta=info".parse().unwrap());

    // File logging: ~/.cyfr/logs/porta.log (daily rotation, keep 7 days)
    let log_dir = dirs::home_dir()
        .expect("could not determine home directory")
        .join(".cyfr")
        .join("logs");
    let file_appender = tracing_appender::rolling::daily(&log_dir, "porta.log");
    let (non_blocking, _guard) = tracing_appender::non_blocking(file_appender);

    let file_layer = tracing_subscriber::fmt::layer()
        .with_writer(non_blocking)
        .with_ansi(false);

    let stdout_layer = tracing_subscriber::fmt::layer();

    tracing_subscriber::registry()
        .with(filter)
        .with(file_layer)
        .with(stdout_layer)
        .init();

    info!("Starting CYFR");

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            commands::docker::docker_status,
            commands::docker::docker_start,
            commands::docker::docker_stop,
            commands::docker::docker_restart,
            commands::docker::start_boot,
            commands::docker::retry_boot,
            commands::docker::install_docker,
            commands::docker::check_docker_ready,
            commands::docker::open_docker_desktop,
            commands::docker::open_url,
            commands::docker::transition_to_main,
            commands::docker::get_cyfr_url,
            commands::docker::check_for_update,
            commands::docker::dismiss_update,
            commands::docker::perform_upgrade,
            commands::settings::get_config_json,
            commands::settings::save_config_json,
            commands::settings::list_backends,
            commands::settings::launch_chrome,
            commands::settings::check_debug_port,
            commands::mcp_proxy::mcp_proxy,
            commands::cyfr::cyfr_command,
            commands::sse_proxy::connect_sse,
            commands::cyfr::save_cli_session,
            commands::cyfr::read_cli_session,
            commands::cyfr::save_prefs,
            commands::cyfr::load_prefs,
        ])
        .setup(|app| {
            // Create shared backend registry
            let registry: gateway::SharedRegistry =
                Arc::new(RwLock::new(backend::registry::BackendRegistry::new()));
            app.manage(registry.clone());

            // Track dismissed update versions
            app.manage(update::DismissedVersion(std::sync::Mutex::new(
                update::DismissedState::default(),
            )));

            // Setup system tray
            tray::setup(app)?;

            // Auto-start boot after delay (fallback if JS trigger fails)
            let app_handle = app.handle().clone();
            async_runtime::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                porta::boot::try_start_boot(app_handle).await;
            });

            // Start background Cyfr update checker
            update::start_background_checker(app.handle().clone());

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build tauri app")
        .run(|app, event| match event {
            RunEvent::WindowEvent {
                label,
                event: WindowEvent::CloseRequested { api, .. },
                ..
            } => {
                // Hide window to tray instead of quitting
                if label == "boot" || label == "main" {
                    if let Some(window) = app.get_webview_window(&label) {
                        let _ = window.hide();
                        api.prevent_close();
                    }
                }
            }
            RunEvent::Exit => {
                // Final event before process terminates — stop the container.
                // Use spawn + wait_timeout pattern so app doesn't hang if Docker is unresponsive.
                let proj_dir = dirs::home_dir()
                    .expect("could not determine home directory")
                    .join("cyfr");
                if proj_dir.exists() {
                    info!("Shutting down: running cyfr down...");
                    let cmd = porta::cli::cli_command();
                    if let Ok(mut child) = std::process::Command::new(&cmd)
                        .args(["down"])
                        .current_dir(&proj_dir)
                        .env("COMPOSE_PROJECT_NAME", "cyfr")
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .spawn()
                    {
                        // Wait up to 10 seconds, then kill
                        let start = std::time::Instant::now();
                        loop {
                            match child.try_wait() {
                                Ok(Some(_)) => break,
                                Ok(None) => {
                                    if start.elapsed() > std::time::Duration::from_secs(10) {
                                        info!("cyfr down timed out, killing");
                                        let _ = child.kill();
                                        let _ = child.wait();
                                        break;
                                    }
                                    std::thread::sleep(std::time::Duration::from_millis(200));
                                }
                                Err(_) => break,
                            }
                        }
                    }
                    info!("cyfr down complete");
                }
            }
            _ => {}
        });
}
