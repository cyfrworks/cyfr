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
        // ---- Blocks ----
        "get_block" => {
            let block_id = req_str(&req, "block_id")?;
            get_block(&api_key, block_id)
        }
        "update_block" => {
            let block_id = req_str(&req, "block_id")?;
            let properties = req_obj(&req, "properties")?;
            update_block(&api_key, block_id, properties)
        }
        "delete_block" => {
            let block_id = req_str(&req, "block_id")?;
            delete_block(&api_key, block_id)
        }
        "get_block_children" => {
            let block_id = req_str(&req, "block_id")?;
            let page_size = req.get("page_size").and_then(|v| v.as_u64());
            let start_cursor = req.get("start_cursor").and_then(|v| v.as_str());
            get_block_children(&api_key, block_id, page_size, start_cursor)
        }
        "append_block_children" => {
            let block_id = req_str(&req, "block_id")?;
            let children = req_arr(&req, "children")?;
            append_block_children(&api_key, block_id, children)
        }

        // ---- Pages ----
        "create_page" => {
            let parent = req_obj(&req, "parent")?;
            let properties = req_obj(&req, "properties")?;
            let children = req.get("children").cloned();
            let icon = req.get("icon").cloned();
            let cover = req.get("cover").cloned();
            create_page(&api_key, parent, properties, children, icon, cover)
        }
        "get_page" => {
            let page_id = req_str(&req, "page_id")?;
            get_page(&api_key, page_id)
        }
        "update_page" => {
            let page_id = req_str(&req, "page_id")?;
            let properties = req_obj(&req, "properties")?;
            let archived = req.get("archived").and_then(|v| v.as_bool());
            let icon = req.get("icon").cloned();
            let cover = req.get("cover").cloned();
            update_page(&api_key, page_id, properties, archived, icon, cover)
        }
        "get_page_property" => {
            let page_id = req_str(&req, "page_id")?;
            let property_id = req_str(&req, "property_id")?;
            get_page_property(&api_key, page_id, property_id)
        }

        // ---- Databases ----
        "create_database" => {
            let parent = req_obj(&req, "parent")?;
            let title = req_arr(&req, "title")?;
            let properties = req_obj(&req, "properties")?;
            create_database(&api_key, parent, title, properties)
        }
        "get_database" => {
            let database_id = req_str(&req, "database_id")?;
            get_database(&api_key, database_id)
        }
        "update_database" => {
            let database_id = req_str(&req, "database_id")?;
            let title = req.get("title").cloned();
            let description = req.get("description").cloned();
            let properties = req.get("properties").cloned();
            update_database(&api_key, database_id, title, description, properties)
        }
        "query_database" => {
            let database_id = req_str(&req, "database_id")?;
            let filter = req.get("filter").cloned();
            let sorts = req.get("sorts").cloned();
            let page_size = req.get("page_size").and_then(|v| v.as_u64());
            let start_cursor = req.get("start_cursor").and_then(|v| v.as_str());
            query_database(&api_key, database_id, filter, sorts, page_size, start_cursor)
        }
        "list_databases" => list_databases(&api_key),

        // ---- Comments ----
        "create_comment" => {
            let rich_text = req_arr(&req, "rich_text")?;
            let parent = req.get("parent").cloned();
            let discussion_id = req.get("discussion_id").and_then(|v| v.as_str());
            create_comment(&api_key, rich_text, parent, discussion_id)
        }
        "list_comments" => {
            let block_id = req_str(&req, "block_id")?;
            let page_size = req.get("page_size").and_then(|v| v.as_u64());
            let start_cursor = req.get("start_cursor").and_then(|v| v.as_str());
            list_comments(&api_key, block_id, page_size, start_cursor)
        }

        // ---- Search ----
        "search" => {
            let query = req.get("query").and_then(|v| v.as_str());
            let filter = req.get("filter").cloned();
            let sort = req.get("sort").cloned();
            let page_size = req.get("page_size").and_then(|v| v.as_u64());
            let start_cursor = req.get("start_cursor").and_then(|v| v.as_str());
            search(&api_key, query, filter, sort, page_size, start_cursor)
        }

        // ---- Users ----
        "list_users" => {
            let page_size = req.get("page_size").and_then(|v| v.as_u64());
            let start_cursor = req.get("start_cursor").and_then(|v| v.as_str());
            list_users(&api_key, page_size, start_cursor)
        }
        "get_user" => {
            let user_id = req_str(&req, "user_id")?;
            get_user(&api_key, user_id)
        }
        "get_me" => get_me(&api_key),

        // ---- Legacy ----
        "list_themes" => {
            let database_id = req_str(&req, "database_id")?;
            list_themes(&api_key, database_id)
        }

        other => Err(format!(
            "Unknown action: '{other}'. Valid actions: \
             get_block, update_block, delete_block, get_block_children, append_block_children, \
             create_page, get_page, update_page, get_page_property, \
             create_database, get_database, update_database, query_database, list_databases, \
             create_comment, list_comments, \
             search, \
             list_users, get_user, get_me, \
             list_themes"
        )),
    }
}

// ---------------------------------------------------------------------------
// Helper extractors
// ---------------------------------------------------------------------------

fn req_str<'a>(req: &'a Value, field: &str) -> Result<&'a str, String> {
    req[field]
        .as_str()
        .ok_or_else(|| format!("Missing required field: {field}"))
}

fn req_obj<'a>(req: &'a Value, field: &str) -> Result<&'a Value, String> {
    let v = &req[field];
    if v.is_object() {
        Ok(v)
    } else {
        Err(format!("Missing or invalid field: {field} (expected object)"))
    }
}

fn req_arr<'a>(req: &'a Value, field: &str) -> Result<&'a Value, String> {
    let v = &req[field];
    if v.is_array() {
        Ok(v)
    } else {
        Err(format!("Missing or invalid field: {field} (expected array)"))
    }
}

// ---------------------------------------------------------------------------
// Block actions
// ---------------------------------------------------------------------------

/// GET /blocks/{block_id}
fn get_block(api_key: &str, block_id: &str) -> Result<Value, String> {
    notion_get(api_key, &format!("/blocks/{block_id}"))
}

/// PATCH /blocks/{block_id}
fn update_block(api_key: &str, block_id: &str, properties: &Value) -> Result<Value, String> {
    notion_patch(api_key, &format!("/blocks/{block_id}"), properties)
}

/// DELETE /blocks/{block_id}
fn delete_block(api_key: &str, block_id: &str) -> Result<Value, String> {
    notion_delete(api_key, &format!("/blocks/{block_id}"))
}

/// GET /blocks/{block_id}/children
fn get_block_children(
    api_key: &str,
    block_id: &str,
    page_size: Option<u64>,
    start_cursor: Option<&str>,
) -> Result<Value, String> {
    let mut params: Vec<(&str, String)> = Vec::new();
    let ps_str;
    if let Some(ps) = page_size {
        ps_str = ps.to_string();
        params.push(("page_size", ps_str));
    }
    let sc_owned;
    if let Some(sc) = start_cursor {
        sc_owned = sc.to_string();
        params.push(("start_cursor", sc_owned));
    }
    notion_get_with_params(api_key, &format!("/blocks/{block_id}/children"), &params)
}

/// PATCH /blocks/{block_id}/children
fn append_block_children(api_key: &str, block_id: &str, children: &Value) -> Result<Value, String> {
    let body = json!({ "children": children });
    notion_patch(api_key, &format!("/blocks/{block_id}/children"), &body)
}

// ---------------------------------------------------------------------------
// Page actions
// ---------------------------------------------------------------------------

/// POST /pages
fn create_page(
    api_key: &str,
    parent: &Value,
    properties: &Value,
    children: Option<Value>,
    icon: Option<Value>,
    cover: Option<Value>,
) -> Result<Value, String> {
    let mut body = json!({
        "parent": parent,
        "properties": properties,
    });
    if let Some(c) = children {
        body["children"] = c;
    }
    if let Some(i) = icon {
        body["icon"] = i;
    }
    if let Some(cv) = cover {
        body["cover"] = cv;
    }
    notion_post(api_key, "/pages", &body)
}

/// GET /pages/{page_id}
fn get_page(api_key: &str, page_id: &str) -> Result<Value, String> {
    let resp = notion_get(api_key, &format!("/pages/{page_id}"))?;
    Ok(format_page(&resp))
}

/// PATCH /pages/{page_id}
fn update_page(
    api_key: &str,
    page_id: &str,
    properties: &Value,
    archived: Option<bool>,
    icon: Option<Value>,
    cover: Option<Value>,
) -> Result<Value, String> {
    let mut body = json!({ "properties": properties });
    if let Some(a) = archived {
        body["archived"] = json!(a);
    }
    if let Some(i) = icon {
        body["icon"] = i;
    }
    if let Some(cv) = cover {
        body["cover"] = cv;
    }
    notion_patch(api_key, &format!("/pages/{page_id}"), &body)
}

/// GET /pages/{page_id}/properties/{property_id}
fn get_page_property(api_key: &str, page_id: &str, property_id: &str) -> Result<Value, String> {
    notion_get(api_key, &format!("/pages/{page_id}/properties/{property_id}"))
}

// ---------------------------------------------------------------------------
// Database actions
// ---------------------------------------------------------------------------

/// POST /databases
fn create_database(
    api_key: &str,
    parent: &Value,
    title: &Value,
    properties: &Value,
) -> Result<Value, String> {
    let body = json!({
        "parent": parent,
        "title": title,
        "properties": properties,
    });
    notion_post(api_key, "/databases", &body)
}

/// GET /databases/{database_id}
fn get_database(api_key: &str, database_id: &str) -> Result<Value, String> {
    notion_get(api_key, &format!("/databases/{database_id}"))
}

/// PATCH /databases/{database_id}
fn update_database(
    api_key: &str,
    database_id: &str,
    title: Option<Value>,
    description: Option<Value>,
    properties: Option<Value>,
) -> Result<Value, String> {
    let mut body = json!({});
    if let Some(t) = title {
        body["title"] = t;
    }
    if let Some(d) = description {
        body["description"] = d;
    }
    if let Some(p) = properties {
        body["properties"] = p;
    }
    notion_patch(api_key, &format!("/databases/{database_id}"), &body)
}

/// POST /databases/{database_id}/query
fn query_database(
    api_key: &str,
    database_id: &str,
    filter: Option<Value>,
    sorts: Option<Value>,
    page_size: Option<u64>,
    start_cursor: Option<&str>,
) -> Result<Value, String> {
    let mut body = json!({});
    if let Some(f) = filter {
        body["filter"] = f;
    }
    if let Some(s) = sorts {
        body["sorts"] = s;
    }
    if let Some(ps) = page_size {
        body["page_size"] = json!(ps);
    }
    if let Some(sc) = start_cursor {
        body["start_cursor"] = json!(sc);
    }

    let path = format!("/databases/{database_id}/query");
    let resp = notion_post(api_key, &path, &body)?;
    Ok(paginated_response(resp))
}

/// List all databases accessible to the integration (via /search).
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

// ---------------------------------------------------------------------------
// Comment actions
// ---------------------------------------------------------------------------

/// POST /comments
fn create_comment(
    api_key: &str,
    rich_text: &Value,
    parent: Option<Value>,
    discussion_id: Option<&str>,
) -> Result<Value, String> {
    let mut body = json!({ "rich_text": rich_text });
    if let Some(p) = parent {
        body["parent"] = p;
    }
    if let Some(did) = discussion_id {
        body["discussion_id"] = json!(did);
    }
    notion_post(api_key, "/comments", &body)
}

/// GET /comments?block_id={block_id}
fn list_comments(
    api_key: &str,
    block_id: &str,
    page_size: Option<u64>,
    start_cursor: Option<&str>,
) -> Result<Value, String> {
    let mut params: Vec<(&str, String)> = vec![("block_id", block_id.to_string())];
    let ps_str;
    if let Some(ps) = page_size {
        ps_str = ps.to_string();
        params.push(("page_size", ps_str));
    }
    let sc_owned;
    if let Some(sc) = start_cursor {
        sc_owned = sc.to_string();
        params.push(("start_cursor", sc_owned));
    }
    let resp = notion_get_with_params(api_key, "/comments", &params)?;
    Ok(paginated_response(resp))
}

// ---------------------------------------------------------------------------
// Search action
// ---------------------------------------------------------------------------

/// POST /search
fn search(
    api_key: &str,
    query: Option<&str>,
    filter: Option<Value>,
    sort: Option<Value>,
    page_size: Option<u64>,
    start_cursor: Option<&str>,
) -> Result<Value, String> {
    let mut body = json!({});
    if let Some(q) = query {
        body["query"] = json!(q);
    }
    if let Some(f) = filter {
        body["filter"] = f;
    }
    if let Some(s) = sort {
        body["sort"] = s;
    }
    if let Some(ps) = page_size {
        body["page_size"] = json!(ps);
    }
    if let Some(sc) = start_cursor {
        body["start_cursor"] = json!(sc);
    }
    let resp = notion_post(api_key, "/search", &body)?;
    Ok(paginated_response(resp))
}

// ---------------------------------------------------------------------------
// User actions
// ---------------------------------------------------------------------------

/// GET /users  (paginated)
fn list_users(
    api_key: &str,
    page_size: Option<u64>,
    start_cursor: Option<&str>,
) -> Result<Value, String> {
    let mut params: Vec<(&str, String)> = Vec::new();
    let ps_str;
    if let Some(ps) = page_size {
        ps_str = ps.to_string();
        params.push(("page_size", ps_str));
    }
    let sc_owned;
    if let Some(sc) = start_cursor {
        sc_owned = sc.to_string();
        params.push(("start_cursor", sc_owned));
    }
    let resp = notion_get_with_params(api_key, "/users", &params)?;
    Ok(paginated_response(resp))
}

/// GET /users/{user_id}
fn get_user(api_key: &str, user_id: &str) -> Result<Value, String> {
    notion_get(api_key, &format!("/users/{user_id}"))
}

/// GET /users/me
fn get_me(api_key: &str) -> Result<Value, String> {
    notion_get(api_key, "/users/me")
}

// ---------------------------------------------------------------------------
// Legacy actions (kept for backward compatibility)
// ---------------------------------------------------------------------------

/// Query a database and return raw property objects (legacy list_themes shape).
fn list_themes(api_key: &str, database_id: &str) -> Result<Value, String> {
    let path = format!("/databases/{database_id}/query");
    let resp = notion_post(api_key, &path, &json!({}))?;
    let results = resp["results"]
        .as_array()
        .ok_or("Unexpected response: missing results")?;
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

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn notion_headers(api_key: &str) -> Value {
    json!({
        "Authorization": format!("Bearer {api_key}"),
        "Notion-Version": NOTION_VERSION,
        "Content-Type": "application/json"
    })
}

fn notion_get(api_key: &str, path: &str) -> Result<Value, String> {
    let url = format!("{NOTION_BASE}{path}");
    let req = json!({
        "method": "GET",
        "url": url,
        "headers": notion_headers(api_key)
    });
    parse_notion_response(&fetch::request(&req.to_string()))
}

/// GET with query-string parameters.
fn notion_get_with_params(
    api_key: &str,
    path: &str,
    params: &[(&str, String)],
) -> Result<Value, String> {
    let qs: String = params
        .iter()
        .map(|(k, v)| format!("{}={}", k, url_encode(v)))
        .collect::<Vec<_>>()
        .join("&");
    let url = if qs.is_empty() {
        format!("{NOTION_BASE}{path}")
    } else {
        format!("{NOTION_BASE}{path}?{qs}")
    };
    let req = json!({
        "method": "GET",
        "url": url,
        "headers": notion_headers(api_key)
    });
    parse_notion_response(&fetch::request(&req.to_string()))
}

fn notion_post(api_key: &str, path: &str, body: &Value) -> Result<Value, String> {
    let url = format!("{NOTION_BASE}{path}");
    let req = json!({
        "method": "POST",
        "url": url,
        "headers": notion_headers(api_key),
        "body": body.to_string()
    });
    parse_notion_response(&fetch::request(&req.to_string()))
}

fn notion_patch(api_key: &str, path: &str, body: &Value) -> Result<Value, String> {
    let url = format!("{NOTION_BASE}{path}");
    let req = json!({
        "method": "PATCH",
        "url": url,
        "headers": notion_headers(api_key),
        "body": body.to_string()
    });
    parse_notion_response(&fetch::request(&req.to_string()))
}

fn notion_delete(api_key: &str, path: &str) -> Result<Value, String> {
    let url = format!("{NOTION_BASE}{path}");
    let req = json!({
        "method": "DELETE",
        "url": url,
        "headers": notion_headers(api_key)
    });
    parse_notion_response(&fetch::request(&req.to_string()))
}

/// Parse the host HTTP response, surfacing Notion API errors clearly.
fn parse_notion_response(raw: &str) -> Result<Value, String> {
    let resp: Value = serde_json::from_str(raw)
        .map_err(|e| format!("Failed to parse HTTP response: {e}"))?;

    // Host-level transport error
    if let Some(err) = resp.get("error") {
        let err_str = err.to_string();
        let msg = err
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or(&err_str);
        return Err(format!("HTTP error: {msg}"));
    }

    let status = resp["status"].as_u64().unwrap_or(0);
    let body_str = resp["body"].as_str().unwrap_or("");

    let body: Value = serde_json::from_str(body_str)
        .unwrap_or_else(|_| json!({ "raw": body_str }));

    if status < 200 || status >= 300 {
        // Notion error shape: { "object": "error", "code": "...", "message": "..." }
        let msg = body["message"].as_str().unwrap_or(body_str);
        let code = body["code"].as_str().unwrap_or("unknown");
        return Err(format!("Notion API error {status} [{code}]: {msg}"));
    }

    Ok(body)
}

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

/// Normalise any paginated Notion list response into a consistent shape.
fn paginated_response(resp: Value) -> Value {
    let next_cursor = resp["next_cursor"].clone();
    let has_more = resp["has_more"].as_bool().unwrap_or(false);
    let results = resp["results"].clone();
    json!({
        "results": results,
        "next_cursor": next_cursor,
        "has_more": has_more
    })
}

/// Flatten a Notion page into a cleaner object (kept for backward compat).
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
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

/// Minimal percent-encoding for query string values (encodes the characters
/// that could break a URL while keeping the code dependency-free).
fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9'
            | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => {
                out.push('%');
                out.push(char::from_digit((b >> 4) as u32, 16).unwrap_or('0'));
                out.push(char::from_digit((b & 0xf) as u32, 16).unwrap_or('0'));
            }
        }
    }
    out
}
