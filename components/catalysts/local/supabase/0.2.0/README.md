# Supabase Catalyst

Supabase SDK for CYFR — database queries (PostgREST), auth (GoTrue), storage, and edge functions.

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

Any `db.*` operation accepts `"access_token": "..."` for RLS-aware queries, or `"service_role": true` to use the secret key (bypasses RLS).

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

## Setup

Automatic (recommended):

```bash
cyfr setup c:local.supabase
```

This reads the manifest and prompts for credentials, grants access, and derives the host policy from your project URL.

| What | Value |
|------|-------|
| Secrets | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY` |
| Domain | Derived from `SUPABASE_URL` |

<details><summary>Manual setup</summary>

```bash
cyfr register
cyfr secret set SUPABASE_URL=https://your-project.supabase.co
cyfr secret set SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
cyfr secret set SUPABASE_SECRET_KEY=sb_secret_...
cyfr secret grant c:local.supabase SUPABASE_URL
cyfr secret grant c:local.supabase SUPABASE_PUBLISHABLE_KEY
cyfr secret grant c:local.supabase SUPABASE_SECRET_KEY
```

</details>

## Usage

### CLI

```bash
# Select rows
cyfr run c:local.supabase --input '{"operation": "db.select", "params": {"table": "posts", "select": "id, title", "limit": 10}}'

# Insert a row
cyfr run c:local.supabase --input '{"operation": "db.insert", "params": {"table": "posts", "body": {"title": "New Post"}}}'

# Call an edge function
cyfr run c:local.supabase --input '{"operation": "functions.invoke", "params": {"function": "hello", "body": {}}}'
```

### MCP

```bash
curl -X POST http://localhost:4000/mcp \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -H "Authorization: Bearer cyfr_sk_..." \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "execution",
      "arguments": {
        "action": "run",
        "reference": {"registry": "catalyst:local.supabase:0.2.0"},
        "input": {
          "operation": "db.select",
          "params": {"table": "posts", "select": "id, title", "limit": 10}
        },
        "type": "catalyst"
      }
    }
  }'
```

## Secrets

| Secret | Description | How to Obtain |
|--------|-------------|---------------|
| `SUPABASE_URL` | Project URL | Supabase Dashboard > Settings > API |
| `SUPABASE_PUBLISHABLE_KEY` | Publishable key | Supabase Dashboard > Settings > API |
| `SUPABASE_SECRET_KEY` | Secret key | Supabase Dashboard > Settings > API |

## Build

```bash
cd src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/supabase_catalyst.wasm ../catalyst.wasm
```
