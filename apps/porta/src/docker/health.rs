use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;
use tracing::{info, warn};

/// Timeout for each `cyfr status` invocation. Short so the polling loop stays
/// responsive — the Go CLI's own HTTP timeout handles slow servers.
const STATUS_TIMEOUT: Duration = Duration::from_secs(10);

/// Run `cyfr status --json` and return (success, error_message).
/// Success means exit code 0 and JSON `"status": "ok"`.
///
/// Uses `cli_command()` directly with a short timeout instead of `run_cyfr`
/// (which uses a 60s default). Does not require a project directory —
/// `cyfr status` works from any cwd.
async fn run_cyfr_status() -> (bool, String) {
    let cmd = crate::cli::cli_command();

    let result = tokio::time::timeout(
        STATUS_TIMEOUT,
        Command::new(&cmd)
            .args(["status", "--json"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output(),
    )
    .await;

    let output = match result {
        Err(_) => return (false, "cyfr status timed out".to_string()),
        Ok(Err(e)) => return (false, format!("Failed to run cyfr: {}", e)),
        Ok(Ok(o)) => o,
    };

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if output.status.success() {
        // Parse JSON to confirm status is "ok"
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&stdout) {
            if json.get("status").and_then(|s| s.as_str()) == Some("ok") {
                return (true, String::new());
            }
            // CLI succeeded but status isn't "ok" — extract what we can
            let status = json
                .get("status")
                .and_then(|s| s.as_str())
                .unwrap_or("unknown");
            return (false, format!("status: {}", status));
        }
        // Couldn't parse JSON but command succeeded
        (true, String::new())
    } else {
        // Command failed — use stderr (or stdout) as the error
        let msg = if stderr.trim().is_empty() {
            stdout.trim().to_string()
        } else {
            stderr.trim().to_string()
        };
        (false, msg)
    }
}

/// Poll `cyfr status --json` until it reports healthy.
/// Uses a soft deadline for progress display and a hard deadline (5 minutes) as
/// an absolute maximum.
///
/// Progress is reported via `on_progress(message, progress_fraction)` so callers
/// can emit the appropriate event type (boot-state vs upgrade-progress).
///
/// `progress_start` / `progress_end` define the progress range this function
/// reports within, so callers can place it at the right position in their
/// overall progress bar without regressions.
pub async fn wait_healthy<F>(
    on_progress: F,
    soft_deadline_secs: u64,
    progress_start: f32,
    progress_end: f32,
) -> Result<(), String>
where
    F: Fn(&str, f32),
{
    let start = tokio::time::Instant::now();
    let soft_deadline = Duration::from_secs(soft_deadline_secs);
    let hard_deadline = Duration::from_secs(300); // 5 minutes absolute max
    let poll_interval = Duration::from_secs(3);

    // Split the progress range: 80% before soft deadline, 20% after (slow-start extension).
    let soft_progress = progress_start + (progress_end - progress_start) * 0.8;

    let mut last_error = String::new();

    loop {
        let (healthy, err_msg) = run_cyfr_status().await;

        if healthy {
            info!("Health check passed (cyfr status ok)");
            return Ok(());
        }

        if !err_msg.is_empty() {
            warn!("Health check failed: {}", err_msg);
            last_error = err_msg;
        }

        let elapsed = start.elapsed();

        // Hard deadline — give up regardless
        if elapsed >= hard_deadline {
            let detail = if last_error.is_empty() {
                String::new()
            } else {
                format!(" Last error: {}", last_error)
            };
            return Err(format!(
                "Server did not become healthy within 5 minutes.{}",
                detail
            ));
        }

        let elapsed_secs = elapsed.as_secs();
        let error_suffix = if last_error.is_empty() {
            String::new()
        } else {
            format!(" — {}", last_error)
        };

        if elapsed >= soft_deadline {
            // Past soft deadline — scale progress from soft_progress to progress_end
            let beyond_soft = (elapsed - soft_deadline).as_secs_f32();
            let soft_to_hard = (hard_deadline - soft_deadline).as_secs_f32();
            let progress =
                (soft_progress + (beyond_soft / soft_to_hard) * (progress_end - soft_progress))
                    .min(progress_end);
            on_progress(
                &format!(
                    "Server is still starting up... ({}s){}",
                    elapsed_secs, error_suffix
                ),
                progress,
            );
        } else {
            // Before soft deadline — scale progress from progress_start to soft_progress
            let fraction = elapsed_secs as f32 / soft_deadline_secs as f32;
            let progress = progress_start + fraction * (soft_progress - progress_start);
            on_progress(
                &format!(
                    "Waiting for server to be ready... ({}s){}",
                    elapsed_secs, error_suffix
                ),
                progress.min(soft_progress),
            );
        }

        tokio::time::sleep(poll_interval).await;
    }
}

/// Single health check (non-blocking). Returns true if `cyfr status` reports ok.
pub async fn check_health() -> bool {
    let (healthy, _) = run_cyfr_status().await;
    healthy
}
