use serde_json::{json, Value};

use crate::{build_headers, do_request, parse_response, require_param, SupabaseContext};

fn storage_headers(ctx: &SupabaseContext, params: &Value) -> Value {
    let api_key = ctx.api_key(params);
    let mut extra: Vec<(&str, &str)> = Vec::new();
    let auth_header;

    if let Some(token) = params.get("access_token").and_then(|v| v.as_str()) {
        auth_header = format!("Bearer {token}");
        extra.push(("Authorization", &auth_header));
    }

    build_headers(api_key, if extra.is_empty() { None } else { Some(&extra) })
}

pub fn upload(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let bucket = require_param(params, "bucket")?;
    let path = require_param(params, "path")?;
    let url = format!("{}/storage/v1/object/{bucket}/{path}", ctx.url);

    let body = params.get("body").and_then(|v| v.as_str()).unwrap_or("");

    let api_key = ctx.api_key(params);
    let content_type = params
        .get("content_type")
        .and_then(|v| v.as_str())
        .unwrap_or("application/octet-stream");

    let mut extra: Vec<(&str, &str)> = vec![("Content-Type", content_type)];
    let auth_header;
    if let Some(token) = params.get("access_token").and_then(|v| v.as_str()) {
        auth_header = format!("Bearer {token}");
        extra.push(("Authorization", &auth_header));
    }

    // Upsert mode
    if params.get("upsert").and_then(|v| v.as_bool()).unwrap_or(false) {
        extra.push(("x-upsert", "true"));
    }

    let headers = build_headers(api_key, Some(&extra));
    Ok(parse_response(&do_request("POST", &url, &headers, body)))
}

pub fn download(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let bucket = require_param(params, "bucket")?;
    let path = require_param(params, "path")?;
    let url = format!("{}/storage/v1/object/{bucket}/{path}", ctx.url);

    let headers = storage_headers(ctx, params);
    Ok(parse_response(&do_request("GET", &url, &headers, "")))
}

pub fn list(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let bucket = require_param(params, "bucket")?;
    let url = format!("{}/storage/v1/object/list/{bucket}", ctx.url);

    let body = json!({
        "prefix": params.get("prefix").and_then(|v| v.as_str()).unwrap_or(""),
        "limit": params.get("limit").and_then(|v| v.as_u64()).unwrap_or(100),
        "offset": params.get("offset").and_then(|v| v.as_u64()).unwrap_or(0),
        "sortBy": params.get("sort_by").unwrap_or(&json!({"column": "name", "order": "asc"}))
    });

    let headers = storage_headers(ctx, params);
    Ok(parse_response(&do_request(
        "POST",
        &url,
        &headers,
        &body.to_string(),
    )))
}

pub fn remove(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let bucket = require_param(params, "bucket")?;
    let url = format!("{}/storage/v1/object/{bucket}", ctx.url);

    let default_prefixes = json!([]);
    let prefixes = params.get("prefixes").unwrap_or(&default_prefixes);
    let body = json!({ "prefixes": prefixes });

    let headers = storage_headers(ctx, params);
    Ok(parse_response(&do_request(
        "DELETE",
        &url,
        &headers,
        &body.to_string(),
    )))
}

pub fn move_object(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let url = format!("{}/storage/v1/object/move", ctx.url);

    let body = json!({
        "bucketId": params.get("bucket").and_then(|v| v.as_str()).unwrap_or(""),
        "sourceKey": params.get("from").and_then(|v| v.as_str()).unwrap_or(""),
        "destinationKey": params.get("to").and_then(|v| v.as_str()).unwrap_or("")
    });

    let headers = storage_headers(ctx, params);
    Ok(parse_response(&do_request(
        "POST",
        &url,
        &headers,
        &body.to_string(),
    )))
}

pub fn create_signed_url(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let bucket = require_param(params, "bucket")?;
    let path = require_param(params, "path")?;
    let url = format!("{}/storage/v1/object/sign/{bucket}/{path}", ctx.url);

    let expires_in = params
        .get("expires_in")
        .and_then(|v| v.as_u64())
        .unwrap_or(3600);

    let body = json!({ "expiresIn": expires_in });

    let headers = storage_headers(ctx, params);
    Ok(parse_response(&do_request(
        "POST",
        &url,
        &headers,
        &body.to_string(),
    )))
}
