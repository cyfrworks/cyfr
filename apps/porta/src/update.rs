use crate::cli;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{Emitter, Manager};
use tracing::info;

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

/// Parse a semver string into (major, minor, patch). Returns None for non-semver (e.g., "dev").
fn parse_semver(v: &str) -> Option<(u64, u64, u64)> {
    let parts: Vec<&str> = v.split('.').collect();
    if parts.len() != 3 {
        return None;
    }
    Some((
        parts[0].parse().ok()?,
        parts[1].parse().ok()?,
        parts[2].parse().ok()?,
    ))
}

/// Returns true if `latest` is a newer version than `current` using semver comparison.
/// Returns false if either version is not valid semver (e.g., "dev") — skip update
/// rather than show a wrong result.
fn is_newer(latest: &str, current: &str) -> bool {
    if let (Some(l), Some(c)) = (parse_semver(latest), parse_semver(current)) {
        l > c
    } else {
        false
    }
}

fn github_client() -> Option<reqwest::Client> {
    reqwest::Client::builder()
        .user_agent("aqua-update-check")
        .build()
        .ok()
}

/// Check GitHub for a newer Cyfr release compared to the installed CLI version.
/// Filters for v* tags only (skips porta-v* releases).
pub async fn check_cyfr_update() -> Option<UpdateInfo> {
    let raw_version = cli::check_cli().await?;
    let current = parse_cli_version(&raw_version);

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

    // Find the latest Cyfr release (v* tag, not porta-v*)
    let cyfr_release = releases
        .iter()
        .find(|r| r.tag_name.starts_with('v') && !r.tag_name.starts_with("porta-"))?;

    let latest = cyfr_release.tag_name.trim_start_matches('v').to_string();

    if is_newer(&latest, &current) {
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

    if is_newer(&latest, current) {
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

/// Emit Cyfr update notification as a Tauri event (React frontend handles display).
fn show_cyfr_pill(app: &tauri::AppHandle, info: &UpdateInfo) {
    let _ = app.emit("update-available", serde_json::json!({
        "kind": "cyfr",
        "current": info.current,
        "latest": info.latest,
    }));
}

/// Emit Porta update notification as a Tauri event (React frontend handles display).
fn show_porta_pill(app: &tauri::AppHandle, info: &UpdateInfo, download_url: &str) {
    let _ = app.emit("update-available", serde_json::json!({
        "kind": "porta",
        "current": info.current,
        "latest": info.latest,
        "url": download_url,
    }));
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

    #[test]
    fn test_is_newer() {
        assert!(is_newer("1.2.0", "1.1.0"));
        assert!(is_newer("1.10.0", "1.9.0"));
        assert!(is_newer("2.0.0", "1.99.99"));
        assert!(!is_newer("1.1.0", "1.1.0"));
        assert!(!is_newer("1.0.0", "1.1.0"));
        // Non-semver versions: skip update (return false) rather than show wrong result
        assert!(!is_newer("dev", "1.1.0"));
        assert!(!is_newer("1.1.0", "dev"));
        assert!(!is_newer("dev", "dev"));
    }
}
