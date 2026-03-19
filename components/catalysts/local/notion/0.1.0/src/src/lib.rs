#[allow(warnings)]
mod bindings;

use bindings::cyfr::http::fetch;
use bindings::cyfr::secrets::read;
use bindings::exports::cyfr::catalyst::run::Guest;
use serde_json::{json, Value};

const NOTION_BASE: &str = "https://api.notion.com/v1";
const NOTION_VERSION: &str = "2022-06-28";

struct Component;
bindings::export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(input: String) -> String {
        match handle(&input) {
            Ok(v) => v.to_string(),
            Err(e) => json!({"error": e}).to_string(),
        }
    }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

fn handle(input: &str) -> Result<Value, String> {
    let req: Value = serde_json::from_str(input)
        .map_err(|e| format!("Invalid JSON input: {e}"))?;

    let action = req["action"]
        .as_str()
        .ok_or("Missing required field: action")?;

    let api_key = read::get("NOTION_API_KEY")
        .map_err(|e| format!("Secret error: {e}"))?;

    match action {
        "list_databases" => list_databases(&api_key),
        "query_database" => {
            let db_id = req["database_id"]
                .as_str()
                .ok_or("Missing required field: database_id")?;
            let filter = req.get("filter").cloned();
            query_database(&api_key, db_id, filter)
        }
        "list_themes" => {
            let db_id = req["database_id"]
                .as_str()
                .ok_or("Missing required field: database_id")?;
            list_themes(&api_key, db_id)
        }
        "get_page" => {
            let page_id = req["page_id"]
                .as_str()
                .ok_or("Missing required field: page_id")?;
            get_page(&api_key, page_id)
        }
        other => Err(format!(
            "Unknown action: '{other}'. Valid actions: list_databases, query_database, list_themes, get_page"
        )),
    }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

/// List all databases the integration has access to (via /search).
fn list_databases(api_key: &str) -> Result<Value, String> {
    let body = json!({
        "filter": { "value": "database", "property": "object" }
    });

    let resp = notion_post(api_key, "/search", &body)?;
    let results = resp["results"]
        .as_array()
        .ok_or("Unexpected response: missing results")?;

    let databases: Vec<Value> = results
        .iter()
        .map(|db| {
            let id = db["id"].as_str().unwrap_or("").to_string();
            let title = extract_plain_text(&db["title"]).unwrap_or_default();
            json!({ "id": id, "title": title })
        })
        .collect();

    Ok(json!({ "databases": databases }))
}

/// Query a database — returns all matching pages with their properties.
fn query_database(api_key: &str, database_id: &str, filter: Option<Value>) -> Result<Value, String> {
    let mut body = json!({});
    if let Some(f) = filter {
        body["filter"] = f;
    }

    let path = format!("/databases/{database_id}/query");
    let resp = notion_post(api_key, &path, &body)?;

    let results = resp["results"]
        .as_array()
        .ok_or("Unexpected response: missing results")?;

    let pages: Vec<Value> = results.iter().map(|p| format_page(p)).collect();
    Ok(json!({ "pages": pages }))
}

/// Query a database and return theme objects with all raw properties.
fn list_themes(api_key: &str, database_id: &str) -> Result<Value, String> {
    let path = format!("/databases/{database_id}/query");
    let resp = notion_post(api_key, &path, &json!({}))?;

    let results = resp["results"]
        .as_array()
        .ok_or("Unexpected response: missing results")?;

    // Return all properties as-is for each page
    let themes: Vec<Value> = results
        .iter()
        .map(|p| {
            json!({
                "id": p["id"],
                "created_time": p["created_time"],
                "last_edited_time": p["last_edited_time"],
                "properties": p["properties"]
            })
        })
        .collect();

    Ok(json!({ "themes": themes }))
}

/// Retrieve a single page by ID.
fn get_page(api_key: &str, page_id: &str) -> Result<Value, String> {
    let path = format!("/pages/{page_id}");
    let resp = notion_get(api_key, &path)?;
    Ok(format_page(&resp))
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn notion_get(api_key: &str, path: &str) -> Result<Value, String> {
    let url = format!("{NOTION_BASE}{path}");
    let req = json!({
        "method": "GET",
        "url": url,
        "headers": {
            "Authorization": format!("Bearer {api_key}"),
            "Notion-Version": NOTION_VERSION,
            "Content-Type": "application/json"
        }
    });

    let raw = fetch::request(&req.to_string());
    parse_notion_response(&raw)
}

fn notion_post(api_key: &str, path: &str, body: &Value) -> Result<Value, String> {
    let url = format!("{NOTION_BASE}{path}");
    let req = json!({
        "method": "POST",
        "url": url,
        "headers": {
            "Authorization": format!("Bearer {api_key}"),
            "Notion-Version": NOTION_VERSION,
            "Content-Type": "application/json"
        },
        "body": body.to_string()
    });

    let raw = fetch::request(&req.to_string());
    parse_notion_response(&raw)
}

/// Parse the host HTTP response, surfacing Notion API errors clearly.
fn parse_notion_response(raw: &str) -> Result<Value, String> {
    let resp: Value = serde_json::from_str(raw)
        .map_err(|e| format!("Failed to parse HTTP response: {e}"))?;

    // Host-level transport error
    if let Some(err) = resp.get("error") {
        let err_str = err.to_string();
        let msg = err.get("message").and_then(|m| m.as_str()).unwrap_or(&err_str);
        return Err(format!("HTTP error: {msg}"));
    }

    let status = resp["status"].as_u64().unwrap_or(0);
    let body_str = resp["body"].as_str().unwrap_or("");

    let body: Value = serde_json::from_str(body_str)
        .unwrap_or_else(|_| json!({ "raw": body_str }));

    if status < 200 || status >= 300 {
        // Notion error shape: { "object": "error", "code": "...", "message": "..." }
        let msg = body["message"].as_str()
            .unwrap_or(body_str);
        let code = body["code"].as_str().unwrap_or("unknown");
        return Err(format!("Notion API error {status} [{code}]: {msg}"));
    }

    Ok(body)
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

/// Flatten a Notion page into a cleaner object.
fn format_page(page: &Value) -> Value {
    json!({
        "id": page["id"],
        "created_time": page["created_time"],
        "last_edited_time": page["last_edited_time"],
        "url": page["url"],
        "properties": page["properties"]
    })
}

/// Extract plain text from a Notion rich_text / title array.
fn extract_plain_text(value: &Value) -> Option<String> {
    let arr = value.as_array()?;
    let text: String = arr
        .iter()
        .filter_map(|item| item["plain_text"].as_str())
        .collect();
    if text.is_empty() { None } else { Some(text) }
}
