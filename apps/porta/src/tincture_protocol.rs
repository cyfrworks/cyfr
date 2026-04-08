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

    // In remote mode the iframe URL has no `_session=` query (Porta uses
    // an api_key instead). The tincture endpoint reads `_key=cyfr_xxx`
    // from query params (see Sanctum.TinctureAuth.authenticate), not
    // Authorization headers, so we append it here when the URL doesn't
    // already have one.
    let api_key = crate::config::load_config().api_key;
    let needs_key_param = api_key.is_some()
        && uri.query().map(|q| !q.contains("_key=") && !q.contains("_session=")).unwrap_or(true);

    let upstream_url = match (uri.query(), needs_key_param, api_key.as_deref()) {
        (Some(q), true, Some(key)) => format!("{}{}?{}&_key={}", cyfr_url(), path, q, key),
        (Some(q), _, _) => format!("{}{}?{}", cyfr_url(), path, q),
        (None, true, Some(key)) => format!("{}{}?_key={}", cyfr_url(), path, key),
        (None, _, _) => format!("{}{}", cyfr_url(), path),
    };

    // Don't log the full URL when it contains an api_key
    let safe_log_url = if needs_key_param {
        format!("{}{} (with _key)", cyfr_url(), path)
    } else {
        upstream_url.clone()
    };
    info!("Tincture proxy: {} -> {}", uri, safe_log_url);

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
