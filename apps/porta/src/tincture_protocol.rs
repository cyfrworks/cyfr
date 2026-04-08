use tauri::UriSchemeResponder;
use tracing::{info, warn};

fn cyfr_url() -> String {
    crate::config::cyfr_url()
}

/// Headers to forward from the Cyfr server response to the webview.
const FORWARD_HEADERS: &[&str] = &[
    "content-type",
    "content-security-policy",
    "cache-control",
    "x-content-type-options",
];

/// Register the `tincture://` custom URI scheme protocol.
///
/// This proxies all requests through the Rust HTTP client to the Cyfr server,
/// bypassing WKWebView's mixed-content blocking (tauri:// → http:// is blocked).
///
/// URL mapping (path is forwarded verbatim — must include /t/):
///   tincture://localhost/t/{publisher}/{name}?_session=sess_xxx
///     → GET {cyfr_url}/t/{publisher}/{name}?_session=sess_xxx
pub fn register(builder: tauri::Builder<tauri::Wry>) -> tauri::Builder<tauri::Wry> {
    builder.register_asynchronous_uri_scheme_protocol("tincture", |_ctx, request, responder| {
        tauri::async_runtime::spawn(async move {
            handle_request(request, responder).await;
        });
    })
}

async fn handle_request(request: tauri::http::Request<Vec<u8>>, responder: UriSchemeResponder) {
    let uri = request.uri();

    // Forward path verbatim — the iframe src and <base href> already include /t/
    let path = uri.path();
    let upstream_url = match uri.query() {
        Some(q) => format!("{}{}?{}", cyfr_url(), path, q),
        None => format!("{}{}", cyfr_url(), path),
    };

    info!("Tincture proxy: {} -> {}", uri, upstream_url);

    let client = reqwest::Client::new();
    match client.get(&upstream_url).send().await {
        Ok(resp) => {
            let status = resp.status().as_u16();

            // Collect headers we need to forward
            let mut builder = tauri::http::Response::builder().status(status);
            for &name in FORWARD_HEADERS {
                if let Some(val) = resp.headers().get(name) {
                    if let Ok(val_str) = val.to_str() {
                        builder = builder.header(name, val_str);
                    }
                }
            }

            // Allow this content to be framed by the Tauri app
            builder = builder.header("access-control-allow-origin", "*");

            match resp.bytes().await {
                Ok(body) => {
                    responder.respond(builder.body(body.to_vec()).unwrap_or_else(|_| {
                        tauri::http::Response::builder()
                            .status(500)
                            .body(b"Internal error".to_vec())
                            .unwrap()
                    }));
                }
                Err(e) => {
                    warn!("Tincture proxy body read failed: {}", e);
                    respond_error(responder, 502, "Failed to read upstream response");
                }
            }
        }
        Err(e) => {
            warn!("Tincture proxy request failed: {} -> {}", upstream_url, e);
            respond_error(responder, 502, "Failed to connect to CYFR server");
        }
    }
}

fn respond_error(responder: UriSchemeResponder, status: u16, msg: &str) {
    responder.respond(
        tauri::http::Response::builder()
            .status(status)
            .header("content-type", "text/plain")
            .body(msg.as_bytes().to_vec())
            .unwrap(),
    );
}
