#[allow(warnings)]
mod bindings;

mod auth;
mod db;
mod functions;
mod query;
mod storage;

use bindings::exports::cyfr::catalyst::run::Guest;
use bindings::cyfr::http::fetch;
use bindings::cyfr::secrets::read;

use serde_json::{json, Value};

struct Component;

impl Guest for Component {
    fn run(input: String) -> String {
        match handle_request(&input) {
            Ok(output) => output,
            Err(e) => format_error(500, "internal_error", &e),
        }
    }
}

bindings::export!(Component with_types_in bindings);

// ---------------------------------------------------------------------------
// Supabase context — holds project URL and keys for the request lifetime
// ---------------------------------------------------------------------------

pub(crate) struct SupabaseContext {
    pub url: String,
    pub publishable_key: String,
    pub secret_key: Option<String>,
}

impl SupabaseContext {
    fn load() -> Result<Self, String> {
        let url = read::get("SUPABASE_URL")
            .map_err(|e| format!("Failed to read SUPABASE_URL: {e}"))?;
        let publishable_key = read::get("SUPABASE_PUBLISHABLE_KEY")
            .map_err(|e| format!("Failed to read SUPABASE_PUBLISHABLE_KEY: {e}"))?;

        // Trim trailing slash from URL
        let url = url.trim_end_matches('/').to_string();

        let secret_key = read::get("SUPABASE_SECRET_KEY").ok();

        Ok(Self {
            url,
            publishable_key,
            secret_key,
        })
    }

    /// Pick the API key: secret if requested and available, otherwise publishable.
    pub fn api_key(&self, params: &Value) -> &str {
        if params
            .get("service_role")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            if let Some(ref key) = self.secret_key {
                return key;
            }
        }
        &self.publishable_key
    }
}

// ---------------------------------------------------------------------------
// Request routing
// ---------------------------------------------------------------------------

fn handle_request(input: &str) -> Result<String, String> {
    let parsed: Value =
        serde_json::from_str(input).map_err(|e| format!("Invalid JSON input: {e}"))?;

    let operation = parsed
        .get("operation")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing 'operation' field".to_string())?;

    let params = parsed.get("params").cloned().unwrap_or(json!({}));

    let ctx = match SupabaseContext::load() {
        Ok(c) => c,
        Err(e) => {
            return Ok(format_error(500, "secret_denied", &e));
        }
    };

    match operation {
        // Database (PostgREST)
        "db.select" => db::select(&ctx, &params),
        "db.insert" => db::insert(&ctx, &params),
        "db.update" => db::update(&ctx, &params),
        "db.upsert" => db::upsert(&ctx, &params),
        "db.delete" => db::delete(&ctx, &params),
        "db.rpc" => db::rpc(&ctx, &params),

        // Auth (GoTrue)
        "auth.signup" => auth::signup(&ctx, &params),
        "auth.signin" => auth::signin(&ctx, &params),
        "auth.signout" => auth::signout(&ctx, &params),
        "auth.user" => auth::user(&ctx, &params),
        "auth.update_user" => auth::update_user(&ctx, &params),
        "auth.reset_password" => auth::reset_password(&ctx, &params),
        "auth.refresh" => auth::refresh(&ctx, &params),

        // Storage
        "storage.upload" => storage::upload(&ctx, &params),
        "storage.download" => storage::download(&ctx, &params),
        "storage.list" => storage::list(&ctx, &params),
        "storage.remove" => storage::remove(&ctx, &params),
        "storage.move" => storage::move_object(&ctx, &params),
        "storage.createSignedUrl" => storage::create_signed_url(&ctx, &params),

        // Edge Functions
        "functions.invoke" => functions::invoke(&ctx, &params),

        _ => Ok(format_error(
            400,
            "unknown_operation",
            &format!("Unknown operation: {operation}"),
        )),
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

pub(crate) fn format_error(status: i64, error_type: &str, message: &str) -> String {
    json!({
        "status": status,
        "error": {
            "type": error_type,
            "message": message,
        }
    })
    .to_string()
}

pub(crate) fn require_param<'a>(params: &'a Value, key: &str) -> Result<&'a str, String> {
    params
        .get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| format!("Missing required param '{key}'"))
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

pub(crate) fn build_headers(api_key: &str, extra: Option<&[(&str, &str)]>) -> Value {
    let mut headers = json!({
        "apikey": api_key,
        "Authorization": format!("Bearer {api_key}"),
        "Content-Type": "application/json"
    });

    if let Some(pairs) = extra {
        if let Some(obj) = headers.as_object_mut() {
            for (k, v) in pairs {
                obj.insert(k.to_string(), Value::String(v.to_string()));
            }
        }
    }

    headers
}

pub(crate) fn do_request(method: &str, url: &str, headers: &Value, body: &str) -> String {
    let req = json!({
        "method": method,
        "url": url,
        "headers": headers,
        "body": body
    });
    fetch::request(&req.to_string())
}

pub(crate) fn parse_response(resp_str: &str) -> String {
    let resp: Value = match serde_json::from_str(resp_str) {
        Ok(v) => v,
        Err(e) => {
            return format_error(
                500,
                "parse_error",
                &format!("Failed to parse HTTP response: {e}"),
            );
        }
    };

    // Host-level error (e.g. domain blocked)
    if let Some(err) = resp.get("error") {
        let msg = match err {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        return format_error(500, "http_error", &msg);
    }

    let status = resp.get("status").and_then(|v| v.as_i64()).unwrap_or(500);
    let body_str = resp.get("body").and_then(|v| v.as_str()).unwrap_or("");

    if (200..300).contains(&status) {
        let data = serde_json::from_str::<Value>(body_str)
            .unwrap_or(Value::String(body_str.to_string()));
        json!({"status": status, "data": data}).to_string()
    } else {
        let error = serde_json::from_str::<Value>(body_str).unwrap_or_else(|_| {
            json!({"type": "api_error", "message": body_str})
        });
        json!({"status": status, "error": error}).to_string()
    }
}
