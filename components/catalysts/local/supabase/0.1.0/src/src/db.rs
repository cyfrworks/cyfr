use serde_json::{json, Value};

use crate::query;
use crate::{build_headers, do_request, format_error, parse_response, require_param, SupabaseContext};

/// Build headers for a PostgREST request, optionally with an access token for RLS.
fn db_headers(ctx: &SupabaseContext, params: &Value) -> Value {
    let api_key = ctx.api_key(params);

    // If an access_token is provided, use it in the Authorization header for RLS
    let mut extra: Vec<(&str, &str)> = Vec::new();
    let auth_header;
    if let Some(token) = params.get("access_token").and_then(|v| v.as_str()) {
        auth_header = format!("Bearer {token}");
        extra.push(("Authorization", &auth_header));
    }

    build_headers(api_key, if extra.is_empty() { None } else { Some(&extra) })
}

pub fn select(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let table = require_param(params, "table")?;
    let qs = query::build_query_string(params);

    let url = if qs.is_empty() {
        format!("{}/rest/v1/{table}", ctx.url)
    } else {
        format!("{}/rest/v1/{table}?{}", ctx.url, qs.join("&"))
    };

    let headers = db_headers(ctx, params);

    // If count is requested, add the Prefer header
    let count_mode = params.get("count").and_then(|v| v.as_str());
    let headers = if let Some(mode) = count_mode {
        let mut h = headers;
        if let Some(obj) = h.as_object_mut() {
            obj.insert(
                "Prefer".to_string(),
                Value::String(format!("count={mode}")),
            );
        }
        h
    } else {
        headers
    };

    Ok(parse_response(&do_request("GET", &url, &headers, "")))
}

pub fn insert(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let table = require_param(params, "table")?;
    let url = format!("{}/rest/v1/{table}", ctx.url);

    let body = params.get("body").unwrap_or(&json!(null));
    let headers = db_headers(ctx, params);

    // Return the inserted rows
    let headers = add_prefer(headers, "return=representation");

    Ok(parse_response(&do_request(
        "POST",
        &url,
        &headers,
        &body.to_string(),
    )))
}

pub fn update(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    if !query::has_filters(params) {
        return Ok(format_error(
            400,
            "safety_error",
            "db.update requires at least one filter to prevent accidental full-table updates",
        ));
    }

    let table = require_param(params, "table")?;
    let qs = query::build_query_string(params);

    let url = if qs.is_empty() {
        format!("{}/rest/v1/{table}", ctx.url)
    } else {
        format!("{}/rest/v1/{table}?{}", ctx.url, qs.join("&"))
    };

    let body = params.get("body").unwrap_or(&json!(null));
    let headers = db_headers(ctx, params);
    let headers = add_prefer(headers, "return=representation");

    Ok(parse_response(&do_request(
        "PATCH",
        &url,
        &headers,
        &body.to_string(),
    )))
}

pub fn upsert(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let table = require_param(params, "table")?;
    let url = format!("{}/rest/v1/{table}", ctx.url);

    let body = params.get("body").unwrap_or(&json!(null));
    let headers = db_headers(ctx, params);

    // resolution=merge-duplicates tells PostgREST to upsert
    let on_conflict = params.get("on_conflict").and_then(|v| v.as_str());
    let prefer = "return=representation,resolution=merge-duplicates";
    let headers = add_prefer(headers, &prefer);

    let url = if let Some(oc) = on_conflict {
        format!("{url}?on_conflict={oc}")
    } else {
        url
    };

    Ok(parse_response(&do_request(
        "POST",
        &url,
        &headers,
        &body.to_string(),
    )))
}

pub fn delete(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    if !query::has_filters(params) {
        return Ok(format_error(
            400,
            "safety_error",
            "db.delete requires at least one filter to prevent accidental full-table deletes",
        ));
    }

    let table = require_param(params, "table")?;
    let qs = query::build_query_string(params);

    let url = if qs.is_empty() {
        format!("{}/rest/v1/{table}", ctx.url)
    } else {
        format!("{}/rest/v1/{table}?{}", ctx.url, qs.join("&"))
    };

    let headers = db_headers(ctx, params);
    let headers = add_prefer(headers, "return=representation");

    Ok(parse_response(&do_request("DELETE", &url, &headers, "")))
}

pub fn rpc(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let function = require_param(params, "function")?;
    let url = format!("{}/rest/v1/rpc/{function}", ctx.url);

    let default_body = json!({});
    let body = params.get("body").unwrap_or(&default_body);
    let headers = db_headers(ctx, params);

    Ok(parse_response(&do_request(
        "POST",
        &url,
        &headers,
        &body.to_string(),
    )))
}

fn add_prefer(mut headers: Value, prefer: &str) -> Value {
    if let Some(obj) = headers.as_object_mut() {
        obj.insert("Prefer".to_string(), Value::String(prefer.to_string()));
    }
    headers
}
