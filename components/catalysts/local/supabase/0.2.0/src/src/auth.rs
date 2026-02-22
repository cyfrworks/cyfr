use serde_json::{json, Value};

use crate::{build_headers, do_request, parse_response, require_param, SupabaseContext};

pub fn signup(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let url = format!("{}/auth/v1/signup", ctx.url);

    let body = json!({
        "email": params.get("email"),
        "password": params.get("password"),
        "data": params.get("data").unwrap_or(&json!({}))
    });

    let headers = build_headers(&ctx.anon_key, None);
    Ok(parse_response(&do_request("POST", &url, &headers, &body.to_string())))
}

pub fn signin(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let url = format!("{}/auth/v1/token?grant_type=password", ctx.url);

    let body = json!({
        "email": params.get("email"),
        "password": params.get("password")
    });

    let headers = build_headers(&ctx.anon_key, None);
    Ok(parse_response(&do_request("POST", &url, &headers, &body.to_string())))
}

pub fn signout(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let token = require_param(params, "access_token")?;
    let url = format!("{}/auth/v1/logout", ctx.url);

    let auth_header = format!("Bearer {token}");
    let headers = build_headers(&ctx.anon_key, Some(&[("Authorization", &auth_header)]));

    Ok(parse_response(&do_request("POST", &url, &headers, "")))
}

pub fn user(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let token = require_param(params, "access_token")?;
    let url = format!("{}/auth/v1/user", ctx.url);

    let auth_header = format!("Bearer {token}");
    let headers = build_headers(&ctx.anon_key, Some(&[("Authorization", &auth_header)]));

    Ok(parse_response(&do_request("GET", &url, &headers, "")))
}

pub fn update_user(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let token = require_param(params, "access_token")?;
    let url = format!("{}/auth/v1/user", ctx.url);

    let default_body = json!({});
    let body = params.get("body").unwrap_or(&default_body);

    let auth_header = format!("Bearer {token}");
    let headers = build_headers(&ctx.anon_key, Some(&[("Authorization", &auth_header)]));

    Ok(parse_response(&do_request("PUT", &url, &headers, &body.to_string())))
}

pub fn reset_password(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let email = require_param(params, "email")?;
    let url = format!("{}/auth/v1/recover", ctx.url);

    let body = json!({ "email": email });
    let headers = build_headers(&ctx.anon_key, None);

    Ok(parse_response(&do_request("POST", &url, &headers, &body.to_string())))
}

pub fn refresh(ctx: &SupabaseContext, params: &Value) -> Result<String, String> {
    let refresh_token = require_param(params, "refresh_token")?;
    let url = format!("{}/auth/v1/token?grant_type=refresh_token", ctx.url);

    let body = json!({ "refresh_token": refresh_token });
    let headers = build_headers(&ctx.anon_key, None);

    Ok(parse_response(&do_request("POST", &url, &headers, &body.to_string())))
}
