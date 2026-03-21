use crate::cli;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::Manager;
use tracing::{info, warn};

const GITHUB_REPO: &str = "cyfrworks/cyfr";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateInfo {
    pub current: String,
    pub latest: String,
}

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
    html_url: String,
}

/// Tracks which versions the user dismissed so we don't nag about the same ones.
pub struct DismissedVersion(pub Mutex<DismissedState>);

#[derive(Default)]
pub struct DismissedState {
    pub cyfr: Option<String>,
    pub porta: Option<String>,
}

/// Parse the version string from `cyfr --version` output.
/// Handles formats like "cyfr version 1.1.0", "cyfr 1.1.0", "1.1.0", "dev".
fn parse_cli_version(raw: &str) -> String {
    raw.trim()
        .rsplit_once(' ')
        .map(|(_, v)| v)
        .unwrap_or(raw.trim())
        .trim_start_matches('v')
        .to_string()
}

fn github_client() -> Option<reqwest::Client> {
    reqwest::Client::builder()
        .user_agent("aqua-update-check")
        .build()
        .ok()
}

/// Check GitHub for a newer Cyfr release compared to the installed CLI version.
pub async fn check_cyfr_update() -> Option<UpdateInfo> {
    let raw_version = cli::check_cli().await?;
    let current = parse_cli_version(&raw_version);

    let release: GitHubRelease = github_client()?
        .get(format!(
            "https://api.github.com/repos/{GITHUB_REPO}/releases/latest"
        ))
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;

    let latest = release.tag_name.trim_start_matches('v').to_string();

    if latest != current {
        info!("Cyfr update available: {} -> {}", current, latest);
        Some(UpdateInfo { current, latest })
    } else {
        info!("Cyfr is up to date (v{})", current);
        None
    }
}

/// Check GitHub for a newer Porta release by scanning releases for porta-v* tags.
pub async fn check_porta_update() -> Option<(UpdateInfo, String)> {
    let current = crate::VERSION;

    let releases: Vec<GitHubRelease> = github_client()?
        .get(format!(
            "https://api.github.com/repos/{GITHUB_REPO}/releases?per_page=20"
        ))
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;

    // Find the latest porta-v* release
    let porta_release = releases
        .iter()
        .find(|r| r.tag_name.starts_with("porta-v"))?;

    let latest = porta_release
        .tag_name
        .trim_start_matches("porta-v")
        .to_string();

    if latest != current {
        info!("Porta update available: {} -> {}", current, latest);
        Some((
            UpdateInfo {
                current: current.to_string(),
                latest,
            },
            porta_release.html_url.clone(),
        ))
    } else {
        info!("Porta is up to date (v{})", current);
        None
    }
}

/// Check for both Cyfr and Porta updates, show pills as appropriate.
pub async fn check_and_notify(app: &tauri::AppHandle) {
    let dismissed = app
        .try_state::<DismissedVersion>()
        .map(|s| {
            let d = s.0.lock().unwrap();
            (d.cyfr.clone(), d.porta.clone())
        })
        .unwrap_or_default();

    // Check Cyfr
    if let Some(info) = check_cyfr_update().await {
        if dismissed.0.as_deref() != Some(&info.latest) {
            show_cyfr_pill(app, &info);
        }
    }

    // Check Porta
    if let Some((info, url)) = check_porta_update().await {
        if dismissed.1.as_deref() != Some(&info.latest) {
            show_porta_pill(app, &info, &url);
        }
    }
}

/// Inject the Cyfr upgrade pill (with "Update" button that triggers in-place upgrade).
fn show_cyfr_pill(app: &tauri::AppHandle, info: &UpdateInfo) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };

    let js = format!(
        r#"
        (function() {{
            if (document.getElementById('aqua-cyfr-pill')) return;
            var pill = document.createElement('div');
            pill.id = 'aqua-cyfr-pill';
            pill.style.cssText = 'position:fixed;top:12px;right:12px;z-index:99999;display:flex;align-items:center;gap:8px;padding:6px 14px;background:#1e293b;color:#e2e8f0;font-size:12px;font-family:system-ui,sans-serif;border-radius:20px;box-shadow:0 2px 12px rgba(0,0,0,0.4);cursor:default;';
            pill.innerHTML = '<span style="display:inline-block;width:6px;height:6px;background:#3b82f6;border-radius:50%;"></span>'
                + '<span>Cyfr v{latest} available</span>'
                + '<button id="aqua-cyfr-btn" style="padding:3px 10px;background:#3b82f6;color:white;border:none;border-radius:12px;cursor:pointer;font-size:11px;font-weight:500;">Update</button>'
                + '<button id="aqua-cyfr-dismiss" style="padding:0 4px;background:transparent;color:#64748b;border:none;cursor:pointer;font-size:14px;line-height:1;">\u00d7</button>';
            document.body.appendChild(pill);
            document.getElementById('aqua-cyfr-btn').addEventListener('click', function() {{
                this.disabled = true;
                this.textContent = 'Updating\u2026';
                window.aqua.invoke('perform_upgrade');
            }});
            document.getElementById('aqua-cyfr-dismiss').addEventListener('click', function() {{
                pill.remove();
                window.aqua.invoke('dismiss_update', {{ kind: 'cyfr', version: '{latest}' }});
            }});
        }})();
        "#,
        latest = info.latest
    );

    if let Err(e) = window.eval(&js) {
        warn!("Failed to inject Cyfr update pill: {}", e);
    }
}

/// Inject the Porta upgrade pill (with "Download" button that opens GitHub releases).
fn show_porta_pill(app: &tauri::AppHandle, info: &UpdateInfo, download_url: &str) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };

    let js = format!(
        r#"
        (function() {{
            if (document.getElementById('aqua-porta-pill')) return;
            // Position below the Cyfr pill if it exists
            var top = document.getElementById('aqua-cyfr-pill') ? '48px' : '12px';
            var pill = document.createElement('div');
            pill.id = 'aqua-porta-pill';
            pill.style.cssText = 'position:fixed;top:' + top + ';right:12px;z-index:99998;display:flex;align-items:center;gap:8px;padding:6px 14px;background:#1e293b;color:#e2e8f0;font-size:12px;font-family:system-ui,sans-serif;border-radius:20px;box-shadow:0 2px 12px rgba(0,0,0,0.4);cursor:default;';
            pill.innerHTML = '<span style="display:inline-block;width:6px;height:6px;background:#8b5cf6;border-radius:50%;"></span>'
                + '<span>A.Q.U.A. v{latest} available</span>'
                + '<button id="aqua-porta-btn" style="padding:3px 10px;background:#8b5cf6;color:white;border:none;border-radius:12px;cursor:pointer;font-size:11px;font-weight:500;">Download</button>'
                + '<button id="aqua-porta-dismiss" style="padding:0 4px;background:transparent;color:#64748b;border:none;cursor:pointer;font-size:14px;line-height:1;">\u00d7</button>';
            document.body.appendChild(pill);
            document.getElementById('aqua-porta-btn').addEventListener('click', function() {{
                window.aqua.openExternal('{url}');
            }});
            document.getElementById('aqua-porta-dismiss').addEventListener('click', function() {{
                pill.remove();
                window.aqua.invoke('dismiss_update', {{ kind: 'porta', version: '{latest}' }});
            }});
        }})();
        "#,
        latest = info.latest,
        url = download_url,
    );

    if let Err(e) = window.eval(&js) {
        warn!("Failed to inject Porta update pill: {}", e);
    }
}

/// Show Cyfr update pill directly (used by tray menu).
pub fn show_update_banner(app: &tauri::AppHandle, info: &UpdateInfo) {
    show_cyfr_pill(app, info);
}

/// Spawn a background task that polls for updates every 6 hours.
/// The first check is triggered by boot.rs immediately after the main window opens.
pub fn start_background_checker(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        let interval = std::time::Duration::from_secs(6 * 60 * 60);
        loop {
            tokio::time::sleep(interval).await;
            check_and_notify(&app).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_cli_version() {
        assert_eq!(parse_cli_version("cyfr version 1.1.0"), "1.1.0");
        assert_eq!(parse_cli_version("cyfr version dev"), "dev");
        assert_eq!(parse_cli_version("cyfr 1.1.0"), "1.1.0");
        assert_eq!(parse_cli_version("1.1.0"), "1.1.0");
        assert_eq!(parse_cli_version("v1.1.0"), "1.1.0");
        assert_eq!(parse_cli_version("  cyfr version 1.1.0  "), "1.1.0");
    }
}
