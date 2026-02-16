# Supabase Catalyst

Supabase SDK for CYFR — database queries (PostgREST), auth (GoTrue), storage, and edge functions.

## Setup

```bash
# Register the catalyst
cyfr register

# Configure secrets
cyfr secrets set SUPABASE_URL "https://your-project.supabase.co"
cyfr secrets set SUPABASE_ANON_KEY "your-anon-key"
cyfr secrets set SUPABASE_SERVICE_ROLE_KEY "your-service-role-key"  # optional
```

## Operations

### Database (PostgREST)

**db.select** — Query rows with filters, joins, ordering, and pagination:
```json
{
  "operation": "db.select",
  "params": {
    "table": "posts",
    "select": "id, title, author:users(name, email)",
    "filters": [
      { "column": "published", "op": "is", "value": "true" },
      { "or": [
        { "column": "category", "op": "eq", "value": "tech" },
        { "column": "category", "op": "eq", "value": "science" }
      ]}
    ],
    "order": [{ "column": "created_at", "direction": "desc" }],
    "limit": 25
  }
}
```

**db.insert** — Insert one or many rows:
```json
{
  "operation": "db.insert",
  "params": {
    "table": "posts",
    "body": { "title": "New Post", "content": "Hello world" }
  }
}
```

**db.update** — Update rows matching filters (at least one filter required):
```json
{
  "operation": "db.update",
  "params": {
    "table": "posts",
    "body": { "published": true },
    "filters": [{ "column": "id", "op": "eq", "value": "42" }]
  }
}
```

**db.upsert** — Insert or update on conflict:
```json
{
  "operation": "db.upsert",
  "params": {
    "table": "posts",
    "body": { "id": 42, "title": "Updated Post" },
    "on_conflict": "id"
  }
}
```

**db.delete** — Delete rows matching filters (at least one filter required):
```json
{
  "operation": "db.delete",
  "params": {
    "table": "posts",
    "filters": [{ "column": "id", "op": "eq", "value": "42" }]
  }
}
```

**db.rpc** — Call a Postgres function:
```json
{
  "operation": "db.rpc",
  "params": {
    "function": "get_user_stats",
    "body": { "user_id": "abc-123" }
  }
}
```

### Filter Operators

`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, `is`, `in`, `contains`, `containedBy`, `overlaps`, `fts`, `not.<op>`

Top-level filters are ANDed. Use `{"or": [...]}` or `{"and": [...]}` for explicit grouping (nestable).

### RLS and Service Role

Any `db.*` operation accepts `"access_token": "..."` for RLS-aware queries, or `"service_role": true` to use the service role key (bypasses RLS).

### Auth (GoTrue)

| Operation | Required Params |
|---|---|
| `auth.signup` | `email`, `password` |
| `auth.signin` | `email`, `password` |
| `auth.signout` | `access_token` |
| `auth.user` | `access_token` |
| `auth.update_user` | `access_token`, `body` |
| `auth.reset_password` | `email` |
| `auth.refresh` | `refresh_token` |

### Storage

| Operation | Required Params |
|---|---|
| `storage.upload` | `bucket`, `path`, `body` |
| `storage.download` | `bucket`, `path` |
| `storage.list` | `bucket` |
| `storage.remove` | `bucket`, `prefixes` |
| `storage.move` | `bucket`, `from`, `to` |
| `storage.createSignedUrl` | `bucket`, `path` |

### Edge Functions

```json
{
  "operation": "functions.invoke",
  "params": {
    "function": "send-email",
    "body": { "to": "user@example.com", "subject": "Hello" }
  }
}
```

## Build

```bash
cd components/catalysts/local/supabase/0.1.0/src
cargo component build --release --target wasm32-wasip2
```
