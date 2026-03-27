pub mod health;
pub mod install;
pub mod lifecycle;

use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::Mutex;

/// Cached absolute path to the docker binary. Resettable if needed.
static DOCKER_PATH: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Known locations where the docker binary may live.
fn docker_candidate_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/opt/homebrew/bin"),
    ];
    #[cfg(target_os = "macos")]
    dirs.push(PathBuf::from(
        "/Applications/Docker.app/Contents/Resources/bin",
    ));
    if let Some(home) = dirs::home_dir() {
        dirs.push(home.join(".docker/bin"));
    }
    dirs
}

/// Search common install locations for the docker binary directly.
fn find_docker_path() -> Option<PathBuf> {
    if let Ok(guard) = DOCKER_PATH.lock() {
        if let Some(p) = guard.as_ref() {
            if p.exists() {
                return Some(p.clone());
            }
        }
    }
    for dir in docker_candidate_dirs() {
        let candidate = dir.join("docker");
        if candidate.exists() {
            if let Ok(mut guard) = DOCKER_PATH.lock() {
                *guard = Some(candidate.clone());
            }
            return Some(candidate);
        }
    }
    None
}

/// Get the command name/path for running docker.
/// Uses cached absolute path if available, otherwise falls back to bare "docker" (PATH lookup).
pub fn docker_command() -> OsString {
    if let Ok(guard) = DOCKER_PATH.lock() {
        if let Some(p) = guard.as_ref() {
            if p.exists() {
                return p.as_os_str().to_owned();
            }
        }
    }
    if let Some(p) = find_docker_path() {
        return p.as_os_str().to_owned();
    }
    OsString::from("docker")
}
