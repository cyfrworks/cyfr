use serde_json::{json, Value};

use crate::{build_headers, do_request, parse_response, require_param, SupabaseContext};

pub fn invoke(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let function = require_param(params, "function")?;
    let url = format!("{}/functions/v1/{function}", ctx.url);

    let default_body = json!({});
    let body = params.get("body").unwrap_or(&default_body);

    let api_key = ctx.api_key(params);
    let mut extra: Vec<(&str, &str)> = Vec::new();
    let auth_header;

    if let Some(token) = params.get("access_token").and_then(|v| v.as_str()) {
        auth_header = format!("Bearer {token}");
        extra.push(("Authorization", &auth_header));
    }

    let headers = build_headers(api_key, if extra.is_empty() { None } else { Some(&extra) });

    Ok(parse_response(&do_request(
        "POST",
        &url,
        &headers,
        &body.to_string(),
    )))
}
