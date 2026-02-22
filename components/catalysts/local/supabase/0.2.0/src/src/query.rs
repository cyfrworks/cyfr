use serde_json::Value;

/// Encode a single filter value for PostgREST query parameters.
fn encode_value(val: &Value) -> String {
    match val {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Null => "null".to_string(),
        Value::Array(arr) => {
            let items: Vec<String> = arr.iter().map(|v| encode_value(v)).collect();
            format!("({})", items.join(","))
        }
        _ => val.to_string(),
    }
}

/// Map our operator names to PostgREST operators.
fn postgrest_op(op: &str) -> &str {
    match op {
        "eq" => "eq",
        "neq" => "neq",
        "gt" => "gt",
        "gte" => "gte",
        "lt" => "lt",
        "lte" => "lte",
        "like" => "like",
        "ilike" => "ilike",
        "is" => "is",
        "in" => "in",
        "contains" => "cs",
        "containedBy" => "cd",
        "overlaps" => "ov",
        "fts" => "fts",
        _ => op, // pass-through for not.eq, etc.
    }
}

/// Encode a single filter object into a PostgREST query string fragment.
/// Returns (column, operator.value) for simple filters,
/// or a logical group string for or/and.
fn encode_filter(filter: &Value) -> Option<String> {
    if let Some(or_filters) = filter.get("or").and_then(|v| v.as_array()) {
        let parts: Vec<String> = or_filters.iter().filter_map(encode_filter).collect();
        if parts.is_empty() {
            return None;
        }
        return Some(format!("or=({})", parts.join(",")));
    }

    if let Some(and_filters) = filter.get("and").and_then(|v| v.as_array()) {
        let parts: Vec<String> = and_filters.iter().filter_map(encode_filter).collect();
        if parts.is_empty() {
            return None;
        }
        return Some(format!("and=({})", parts.join(",")));
    }

    let column = filter.get("column").and_then(|v| v.as_str())?;
    let op = filter.get("op").and_then(|v| v.as_str())?;
    let value = filter.get("value")?;

    let pg_op = postgrest_op(op);
    let encoded_val = encode_value(value);

    // For logical group inner items, return column.op.value (no = separator)
    // But at top level, the caller adds column=op.value
    Some(format!("{column}.{pg_op}.{encoded_val}"))
}

/// Build query string parameters from the params object.
/// Returns a vector of "key=value" strings ready to join with "&".
pub fn build_query_string(params: &Value) -> Vec<String> {
    let mut qs: Vec<String> = Vec::new();

    // select columns
    if let Some(select) = params.get("select").and_then(|v| v.as_str()) {
        qs.push(format!("select={select}"));
    }

    // filters
    if let Some(filters) = params.get("filters").and_then(|v| v.as_array()) {
        for filter in filters {
            // Logical groups (or/and) at top level
            if filter.get("or").is_some() || filter.get("and").is_some() {
                if let Some(encoded) = encode_filter(filter) {
                    qs.push(encoded);
                }
            } else {
                // Simple column filter → column=op.value
                if let (Some(column), Some(op), Some(value)) = (
                    filter.get("column").and_then(|v| v.as_str()),
                    filter.get("op").and_then(|v| v.as_str()),
                    filter.get("value"),
                ) {
                    let pg_op = postgrest_op(op);
                    let encoded_val = encode_value(value);
                    qs.push(format!("{column}={pg_op}.{encoded_val}"));
                }
            }
        }
    }

    // order
    if let Some(orders) = params.get("order").and_then(|v| v.as_array()) {
        let parts: Vec<String> = orders
            .iter()
            .filter_map(|o| {
                let col = o.get("column").and_then(|v| v.as_str())?;
                let dir = o
                    .get("direction")
                    .and_then(|v| v.as_str())
                    .unwrap_or("asc");
                let nulls = o.get("nulls_first").and_then(|v| v.as_bool());
                let mut part = format!("{col}.{dir}");
                if let Some(nf) = nulls {
                    part.push_str(if nf { ".nullsfirst" } else { ".nullslast" });
                }
                Some(part)
            })
            .collect();
        if !parts.is_empty() {
            qs.push(format!("order={}", parts.join(",")));
        }
    }

    // limit
    if let Some(limit) = params.get("limit").and_then(|v| v.as_u64()) {
        qs.push(format!("limit={limit}"));
    }

    // offset
    if let Some(offset) = params.get("offset").and_then(|v| v.as_u64()) {
        qs.push(format!("offset={offset}"));
    }

    qs
}

/// Check that at least one filter is present. Used by update/delete for safety.
pub fn has_filters(params: &Value) -> bool {
    params
        .get("filters")
        .and_then(|v| v.as_array())
        .map(|a| !a.is_empty())
        .unwrap_or(false)
}
