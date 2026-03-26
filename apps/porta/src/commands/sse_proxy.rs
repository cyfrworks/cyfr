use serde::Serialize;
use tauri::Emitter;
use tracing::info;

const CYFR_URL: &str = "http://localhost:4000";
/// Max SSE buffer size (1 MB) to prevent unbounded memory growth.
const MAX_SSE_BUFFER: usize = 1_048_576;

#[derive(Debug, Clone, Serialize)]
struct SseEvent {
    execution_id: String,
    sequence: i64,
    event_type: String,
    data: String,
}

/// Connect to an SSE execution events stream and forward events as Tauri events.
/// The frontend listens for "sse-event" events with the execution_id.
#[tauri::command]
pub async fn connect_sse(
    app: tauri::AppHandle,
    execution_id: String,
    last_event_id: Option<String>,
) -> Result<(), String> {
    let url = format!("{}/api/executions/{}/events", CYFR_URL, execution_id);
    info!("SSE proxy connecting to {} (last_event_id: {:?})", url, last_event_id);

    let client = reqwest::Client::new();
    let mut req = client
        .get(&url)
        .header("Accept", "text/event-stream, application/json")
        .header("Cache-Control", "no-cache");

    if let Some(ref lei) = last_event_id {
        req = req.header("Last-Event-ID", lei.as_str());
    }

    let resp = req
        .send()
        .await
        .map_err(|e| format!("SSE connect failed: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("SSE HTTP {}", resp.status()));
    }

    // Stream in a background task
    let exec_id = execution_id.clone();
    tauri::async_runtime::spawn(async move {
        use futures_util::StreamExt;

        let mut stream = resp.bytes_stream();
        // Accumulate raw bytes to avoid splitting multi-byte UTF-8 chars
        let mut raw_buf: Vec<u8> = Vec::new();
        let mut event_id = String::new();
        let mut event_type = String::new();
        let mut event_data = String::new();

        while let Some(chunk) = stream.next().await {
            let chunk = match chunk {
                Ok(c) => c,
                Err(e) => {
                    tracing::warn!("SSE read error: {}", e);
                    break;
                }
            };

            raw_buf.extend_from_slice(&chunk);

            // Guard against unbounded buffer growth
            if raw_buf.len() > MAX_SSE_BUFFER {
                tracing::warn!("SSE proxy: buffer exceeded {}B for {}, closing", MAX_SSE_BUFFER, exec_id);
                break;
            }

            // Try to decode as much valid UTF-8 as possible
            // Find the last valid UTF-8 boundary
            let valid_up_to = match std::str::from_utf8(&raw_buf) {
                Ok(_) => raw_buf.len(),
                Err(e) => e.valid_up_to(),
            };

            if valid_up_to == 0 {
                continue; // Need more bytes
            }

            let valid_str = std::str::from_utf8(&raw_buf[..valid_up_to]).unwrap();
            let mut to_process = valid_str.to_string();
            // Keep the incomplete bytes for the next chunk
            raw_buf = raw_buf[valid_up_to..].to_vec();

            // Process complete lines
            while let Some(newline_pos) = to_process.find('\n') {
                let line = to_process[..newline_pos].trim_end_matches('\r').to_string();
                to_process = to_process[newline_pos + 1..].to_string();

                if line.is_empty() {
                    // Empty line = event boundary
                    if !event_data.is_empty() {
                        let seq = event_id.parse::<i64>().unwrap_or(0);
                        let _ = app.emit(
                            "sse-event",
                            SseEvent {
                                execution_id: exec_id.clone(),
                                sequence: seq,
                                event_type: if event_type.is_empty() {
                                    "message".to_string()
                                } else {
                                    event_type.clone()
                                },
                                data: event_data.clone(),
                            },
                        );

                        // Stop on terminal events
                        if event_type == "complete" || event_type == "error" {
                            info!("SSE proxy: terminal event '{}' for {}", event_type, exec_id);
                            return;
                        }
                    }
                    event_id.clear();
                    event_type.clear();
                    event_data.clear();
                } else if let Some(val) = line.strip_prefix("id: ") {
                    event_id = val.to_string();
                } else if let Some(val) = line.strip_prefix("event: ") {
                    event_type = val.to_string();
                } else if let Some(val) = line.strip_prefix("data: ") {
                    if !event_data.is_empty() {
                        event_data.push('\n');
                    }
                    event_data.push_str(val);
                } else if line.starts_with(':') {
                    // Comment (keep-alive), ignore
                }
            }

            // Put remaining incomplete line back into raw_buf
            if !to_process.is_empty() {
                let mut remaining = to_process.into_bytes();
                remaining.append(&mut raw_buf);
                raw_buf = remaining;
            }
        }

        // Stream ended without a terminal event — notify frontend so execution
        // doesn't appear stuck forever.
        info!("SSE proxy: stream ended unexpectedly for {}", exec_id);
        let _ = app.emit(
            "sse-event",
            SseEvent {
                execution_id: exec_id.clone(),
                sequence: 0,
                event_type: "error".to_string(),
                data: r#"{"error":"Connection to server lost"}"#.to_string(),
            },
        );
    });

    Ok(())
}
