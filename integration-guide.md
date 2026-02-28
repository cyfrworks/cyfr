# Integration Guide

How to use CYFR as your application backend.

> **See also**: [Component Guide](component-guide.md) for building WASM components. This guide covers the other side — connecting your app to CYFR and calling components over HTTP.

---

## How CYFR Works as an App Backend

CYFR exposes a single HTTP endpoint that speaks [MCP](https://modelcontextprotocol.io/) (Model Context Protocol) over JSON-RPC 2.0. Your application sends a POST request, CYFR authenticates it, routes it to the right WASM component, executes it in a sandbox, and returns the result.

```
Your App                         CYFR Server                    Sandbox
───────                         ───────────                    ───────
POST /mcp  ──────────────────>  Authenticate (API key / session / JWT)
  Authorization: Bearer            │
  cyfr_sk_...                      ├── Resolve component reference
                                   ├── Load Host Policy (domains, rate limits)
                                   ├── Preload granted secrets
                                   │
                                   └── Execute WASM ──────────>  [Component]
                                                                    │
                                   <──────── Result ───────────────┘
  <──── JSON-RPC response ─────
```

Every CLI command (`cyfr run`, `cyfr secret set`, etc.) uses this same endpoint. AI agents, frontends, backend services, and CI/CD pipelines all use the same interface.

---

## Authentication Methods

CYFR supports three authentication methods. Choose the one that fits your use case:

| Method | When to Use | How It Works |
|--------|-------------|--------------|
| **API Keys** | Apps calling CYFR (frontend, backend, CI/CD) | `Authorization: Bearer cyfr_pk_...` header |
| **Session Tokens** | Human devs using the CLI (`cyfr login`) | OAuth device flow, session stored in `~/.cyfr/config.yaml` |
| **JWT** | Enterprise / multi-tenant deployments | Signed token with claims, verified by CYFR |

### API Keys

API keys are the primary way applications authenticate with CYFR. There are three types:

| Type | Prefix | Use Case | Security Considerations |
|------|--------|----------|------------------------|
| **Public** | `cyfr_pk_` | Frontend apps, client-side code | Safe to embed in browser code. Can execute and search, but cannot access secrets or admin operations. |
| **Secret** | `cyfr_sk_` | Backend services | Never expose client-side. Keep in environment variables. Can read/write secrets. |
| **Admin** | `cyfr_ak_` | CI/CD, automation, infrastructure | Use with IP allowlist. Full access to all operations including key management. |

API keys are generated as cryptographically random tokens. CYFR only stores a SHA-256 hash — the raw key is shown once at creation time and cannot be retrieved later.

### Session Tokens

Session tokens are for human developers using the CLI. The `cyfr login` command runs an OAuth device flow:

1. CLI calls CYFR with `action: "device-init"` and the GitHub provider
2. CYFR returns a user code and verification URL
3. You open the URL in a browser, enter the code, and authorize
4. CLI polls until authorization completes, then stores the session ID in `~/.cyfr/config.yaml`
5. CLI stores the registry JWT in `~/.cyfr/oci-credentials.json` for OCI push/pull access

Sessions expire after 24 hours of inactivity (configurable via `CYFR_SESSION_TTL_HOURS`).

```bash
cyfr login              # Interactive OAuth device flow (GitHub)
cyfr whoami             # Check current session
cyfr logout             # Destroy session
```

### JWT

For enterprise and multi-tenant deployments, CYFR can verify JWTs signed with a shared secret.

**Required claims:**

| Claim | Type | Required | Description |
|-------|------|----------|-------------|
| `sub` | string | Yes | User ID (must be non-empty) |
| `permissions` | string[] | No | Permission strings (default: `[]`) |
| `scope` | string | No | `"org"` or `"personal"` (default: `"personal"`) |
| `org` | string | No | Organization ID |
| `session_id` | string | No | Session ID (checked for revocation if present) |
| `exp` | integer | No | Expiration timestamp (validated with clock skew) |

**Signing algorithms:** HS256, HS384, HS512

**Configuration:**

```bash
export CYFR_JWT_SIGNING_KEY="your-256-bit-secret-minimum-32-bytes"
export CYFR_JWT_CLOCK_SKEW_SECONDS=60  # Default: 60, max: 300
```

---

## API Key Lifecycle

### Create

```bash
# Public key (frontend) — defaults to no admin scopes, can execute and search
cyfr key create --name "react-app" --type public

# Secret key (backend) — defaults to secrets_read
cyfr key create --name "node-backend" --type secret

# Secret key with extra scope
cyfr key create --name "node-backend-rw" --type secret --scope "secrets_read,secrets_write"

# Admin key (CI/CD) with IP allowlist — defaults to * (all scopes)
cyfr key create --name "github-actions" --type admin --ip-allowlist "140.82.112.0/20"
```

Or via MCP:

```json
{
  "jsonrpc": "2.0", "id": 1, "method": "tools/call",
  "params": {
    "name": "key",
    "arguments": {
      "action": "create",
      "name": "react-app",
      "type": "public"
    }
  }
}
```

Response (the raw key is shown **only once**):

```json
{
  "key": "cyfr_pk_aBcDeFgHiJkLmNoPqRsTuVwXyZ012345",
  "name": "react-app",
  "type": "public",
  "scope": [],
  "created_at": "2025-02-13T..."
}
```

### Available Scopes

Scopes control access to administrative operations only. Execution, component search, and other standard operations are available to any authenticated API key regardless of scope.

| Scope | What It Allows |
|-------|----------------|
| `secrets_read` | Read secrets |
| `secrets_write` | Write, grant, and revoke secrets |
| `users_manage` | Manage user permissions |
| `admin` | Manage API keys (create, revoke, rotate) |
| `*` | All of the above |

#### Key Type Defaults and Ceilings

Each key type has default scopes (applied when none are specified) and a ceiling (the maximum scopes it can be granted):

| Type | Default Scopes | Allowed Scopes (Ceiling) |
|------|---------------|--------------------------|
| **Public** | `[]` (none) | `[]` — cannot be granted any admin scopes |
| **Secret** | `["secrets_read"]` | `["secrets_read", "secrets_write"]` |
| **Admin** | `["*"]` (all) | `["secrets_read", "secrets_write", "users_manage", "admin", "*"]` |

### Rate Limiting

API keys can have per-key rate limits:

```bash
cyfr key create --name "rate-limited" --type public --scope execution --rate-limit "100/1m"
```

Rate limit format: `{count}/{window}` where window is `1m`, `5m`, `1h`, etc.

### IP Allowlist

Restrict which IPs can use a key (recommended for admin keys):

```bash
cyfr key create --name "ci" --type admin --ip-allowlist "140.82.112.0/20,10.0.0.1"
```

Supports exact IPs and CIDR notation. Both IPv4 and IPv6 are supported.

### Rotate

```bash
cyfr key rotate --name "react-app"
```

Returns a new key and invalidates the old one.

### Revoke

```bash
cyfr key revoke --name "react-app"
```

### List

```bash
cyfr key list
```

Lists all keys with their name, type, scope, and creation date. Raw key values are never shown — only the 12-character prefix (e.g., `cyfr_pk_aBcD...`).

---

## Secrets vs API Keys

These are two different things that serve different purposes:

| | API Keys | Secrets |
|---|----------|---------|
| **Purpose** | Authenticate your **app** to **CYFR** | Authenticate **components** to **external APIs** |
| **Example** | `cyfr_sk_...` in your backend's env | `STRIPE_API_KEY=sk-live-...` stored in CYFR |
| **Who uses it** | Your app (in the `Authorization` header) | WASM components (via `cyfr:secrets/read` host function) |
| **Stored where** | Your app's environment / secrets manager | CYFR's database (encrypted at rest with AES-256-GCM) |
| **Managed by** | `cyfr key create/revoke/rotate` | `cyfr secret set/grant/revoke` |

**Example flow:**

```
Your React App                    CYFR                        Stripe API
────────────                     ────                        ──────────
POST /mcp
  Authorization: Bearer          Validates your API key
  cyfr_sk_abc123...              (authenticates your app)
  Body: run stripe catalyst  ──>
                                 Loads STRIPE_API_KEY from
                                 encrypted storage
                                 (secret granted to component)
                                                          ──> GET /v1/charges
                                                              Authorization: Bearer
                                                              sk-live-xyz789...
                                 <── Result ──────────────────
  <── JSON-RPC response ────
```

---

## Connecting from Your App

### HTTP Request Format

All requests go to a single endpoint:

```
POST /mcp HTTP/1.1
Host: localhost:4000
Content-Type: application/json
MCP-Protocol-Version: 2025-11-25
Authorization: Bearer cyfr_sk_...
```

The body is a JSON-RPC 2.0 message:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "execution",
    "arguments": {
      "action": "run",
      "reference": "catalyst:local.claude:0.2.0",
      "input": {"operation": "messages.create", "params": {"model": "claude-sonnet-4-5-20250514", "messages": [{"role": "user", "content": "Hello"}]}},
      "type": "catalyst"
    }
  }
}
```

### Response Format

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"status\":\"completed\",\"execution_id\":\"exec_01234567-...\",\"result\":{...}}"
      }
    ]
  }
}
```

### Required Headers

| Header | Value | When |
|--------|-------|------|
| `Content-Type` | `application/json` | Always |
| `MCP-Protocol-Version` | `2025-11-25` | Always |
| `Authorization` | `Bearer cyfr_pk_...` or `Bearer cyfr_sk_...` | API key auth |
| `MCP-Session-Id` | `<token>` | Session-based auth (after initialization) |

### Session-Based Requests (Stateful)

Most integrations use API keys and can skip this section.

If using session tokens instead of API keys, you need to initialize a session first:

1. **Initialize** — first request without `MCP-Session-Id`:

```json
{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
```

2. **Capture** the `MCP-Session-Id` header from the response
3. **Include** it in all subsequent requests:

```
MCP-Session-Id: <token-from-step-2>
```

API key auth is stateless — no session initialization needed.

### Error Responses

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -33002,
    "message": "Invalid API key",
    "data": null
  }
}
```

**Common error codes:**

| Code | Name | Meaning |
|------|------|---------|
| -33001 | `auth_required` | Not authenticated — tool requires login (see [Public Tools](#public-tools-no-auth-required) for exceptions) |
| -33002 | `auth_invalid` | Invalid API key or token |
| -33003 | `auth_expired` | Session or JWT expired |
| -33004 | `insufficient_permissions` | Key scope doesn't cover this action, or IP not in allowlist |
| -33100 | `execution_failed` | Component execution failed |
| -33101 | `execution_timeout` | Component exceeded time limit |
| -33200 | `component_not_found` | Component reference doesn't resolve |
| -33102 | `capability_denied` | Component tried to use a capability it doesn't have |
| -33201 | `component_invalid` | Component failed validation (invalid WASM, missing exports, etc.) |
| -33202 | `registry_unavailable` | Registry is unreachable or returned an error |
| -33301 | `session_required` | Stateful request without session ID |
| -33302 | `session_expired` | Session not found or expired |
| -33303 | `invalid_protocol` | Invalid or missing MCP protocol version header |
| -33400 | `signature_invalid` | Component signature verification failed |
| -33401 | `signature_expired` | Component signature has expired |
| -33402 | `signature_missing` | Component requires a signature but none was found |

### Public Tools (No Auth Required)

Most tool calls require authentication (session login or API key). The following tools and actions are accessible without authentication — they support discovery and the login flow itself:

| Tool | Actions | Why Public |
|------|---------|------------|
| `session` | all (`login`, `device-init`, `device-poll`, `ping`, `logout`) | Needed to authenticate in the first place |
| `guide` | all (`list`, `get`, `readme`) | Read-only documentation |
| `component` | `search`, `inspect`, `categories`, `setup_plan`, `list` | Read-only component discovery |
| `system` | `status` | Health checks |

Everything else — `component.register`, `component.publish`, `execution.*`, `secret.*`, `key.*`, `permission.*`, `policy.*`, `audit.*`, `storage.*`, `system.notify` — returns error code `-33001` (`auth_required`) if the session is not authenticated.

---

## Example Scenarios

### React Frontend with Public Key

A public key is safe to embed in client-side code. It can execute and search components but cannot access secrets or admin operations.

```javascript
const CYFR_URL = "https://your-cyfr-server.example.com/mcp";
const CYFR_KEY = "cyfr_pk_aBcDeFgHiJkLmNoPqRsTuVwXyZ012345";

async function runComponent(reference, input, type = "catalyst") {
  const response = await fetch(CYFR_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "MCP-Protocol-Version": "2025-11-25",
      "Authorization": `Bearer ${CYFR_KEY}`,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "execution",
        arguments: { action: "run", reference, input, type },
      },
    }),
  });
  return response.json();
}

// Call a component
const result = await runComponent(
  "catalyst:local.claude:0.2.0",
  { operation: "messages.create", params: { model: "claude-sonnet-4-5-20250514", messages: [{ role: "user", content: "Hello" }] } }
);
```

### Node.js Backend with Secret Key

Secret keys should live in environment variables, never in source code.

```javascript
const CYFR_URL = process.env.CYFR_URL || "http://localhost:4000/mcp";
const CYFR_KEY = process.env.CYFR_SECRET_KEY; // cyfr_sk_...

async function cyfr(toolName, args) {
  const res = await fetch(CYFR_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "MCP-Protocol-Version": "2025-11-25",
      "Authorization": `Bearer ${CYFR_KEY}`,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: Date.now(),
      method: "tools/call",
      params: { name: toolName, arguments: args },
    }),
  });

  const data = await res.json();
  if (data.error) throw new Error(`CYFR error ${data.error.code}: ${data.error.message}`);
  return data.result;
}

// Execute a component
const result = await cyfr("execution", {
  action: "run",
  reference: "reagent:cyfr.json-transform:1.0.0",
  input: { data: [1, 2, 3] },
  type: "reagent",
});

// Search for components
const components = await cyfr("component", {
  action: "search",
  query: "sentiment analysis",
  type: "reagent",
});
```

### CI/CD with Admin Key

Admin keys are for automation. Always use an IP allowlist.

```yaml
# GitHub Actions example
jobs:
  deploy-component:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build component
        run: |
          cd components/reagents/local/my-tool/0.1.0/src
          cargo component build --release --target wasm32-wasip2
          cp target/wasm32-wasip2/release/my_tool.wasm ../reagent.wasm

      - name: Register components
        env:
          CYFR_URL: ${{ secrets.CYFR_URL }}
          CYFR_ADMIN_KEY: ${{ secrets.CYFR_ADMIN_KEY }}  # cyfr_ak_...
        run: |
          curl -X POST "$CYFR_URL/mcp" \
            -H "Content-Type: application/json" \
            -H "MCP-Protocol-Version: 2025-11-25" \
            -H "Authorization: Bearer $CYFR_ADMIN_KEY" \
            -d '{
              "jsonrpc": "2.0",
              "id": 1,
              "method": "tools/call",
              "params": {
                "name": "component",
                "arguments": {
                  "action": "register"
                }
              }
            }'
```

### Python Backend

```python
import requests
import os

CYFR_URL = os.environ.get("CYFR_URL", "http://localhost:4000/mcp")
CYFR_KEY = os.environ["CYFR_SECRET_KEY"]  # cyfr_sk_...

def cyfr_call(tool_name, arguments):
    response = requests.post(
        CYFR_URL,
        headers={
            "Content-Type": "application/json",
            "MCP-Protocol-Version": "2025-11-25",
            "Authorization": f"Bearer {CYFR_KEY}",
        },
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": arguments},
        },
    )
    data = response.json()
    if "error" in data:
        raise Exception(f"CYFR error {data['error']['code']}: {data['error']['message']}")
    return data["result"]

# Execute a component
result = cyfr_call("execution", {
    "action": "run",
    "reference": "catalyst:local.claude:0.2.0",
    "input": {"operation": "messages.create", "params": {"model": "claude-sonnet-4-5-20250514"}},
    "type": "catalyst",
})
```

---

## Building an Application on CYFR

The examples above show CYFR as a tool server your app calls into. But CYFR's component
model maps directly to traditional backend architecture — Formulas are your controllers,
Catalysts are your service clients, Reagents are your utilities. When your business logic
is HTTP API calls and data transformations, CYFR can serve as the primary backend.

### Component Roles in an Application

If you're coming from a Next.js or Express backend, here's how your code maps to CYFR components:

| Traditional Backend | CYFR Component | Reference |
|---------------------|----------------|-----------|
| `app/api/users/route.ts` (API route) | Formula | `f:local.users-api:0.1.0` |
| `lib/supabase.ts` (DB client) | Catalyst | `c:local.supabase:0.2.0` |
| `lib/stripe.ts` (payment client) | Catalyst | `c:local.stripe:0.1.0` |
| `lib/validators.ts` (input validation) | Reagent | `r:local.user-validator:0.1.0` |
| `lib/pricing.ts` (pure calculation) | Reagent | `r:local.price-calculator:0.1.0` |

**Decision guide — which component type?**

- **Calls an external service?** → Catalyst (HTTP calls governed by host policy)
- **Pure computation, no side effects?** → Reagent (no policy needed, no network access)
- **Coordinates multiple components?** → Formula (orchestrates Catalysts + Reagents)

### Naming Conventions

- **Formulas** — name by resource: `users-api`, `orders-api`, `auth-api`
- **Catalysts** — name by service: `supabase`, `stripe`, `sendgrid`
- **Reagents** — name by function: `user-validator`, `price-calculator`, `markdown-renderer`

```
components/
├── formulas/local/
│   ├── users-api/0.1.0/
│   └── orders-api/0.1.0/
├── catalysts/local/
│   ├── supabase/0.1.0/
│   └── stripe/0.1.0/
└── reagents/local/
    ├── user-validator/0.1.0/
    └── price-calculator/0.1.0/
```

### Concrete Example: User Management

A complete walkthrough of building user CRUD operations on CYFR.

#### 1. Supabase Catalyst (`c:local.supabase:0.2.0`)

Handles all database operations via Supabase's REST API.

**Setup:**

```bash
# Recommended: run cyfr setup to configure secrets, grants, and policies interactively
cyfr setup

# Or configure manually (omit version → applies to all registered versions):
cyfr secret set SUPABASE_URL=https://xyzcompany.supabase.co
cyfr secret set SUPABASE_SERVICE_KEY=eyJhbGciOiJIUzI1NiIs...
cyfr secret grant c:local.supabase SUPABASE_URL
cyfr secret grant c:local.supabase SUPABASE_SERVICE_KEY
cyfr policy set c:local.supabase allowed_domains '["xyzcompany.supabase.co"]'
```

**Input/output contract:**

```
Input:  { "table": "users", "action": "select|insert|update|delete", "params": {...} }
Output: { "data": [...], "error": null } or { "data": null, "error": "..." }
```

#### 2. User Validator Reagent (`r:local.user-validator:0.1.0`)

Pure validation logic — no secrets, no network, no policy needed.

**Input/output contract:**

```
Input:  { "action": "validate_create", "data": { "email": "...", "name": "..." } }
Output: { "valid": true } or { "valid": false, "errors": ["email is required", ...] }
```

#### 3. Users API Formula (`f:local.users-api:0.1.0`)

Orchestrates the validator and database catalyst.

**Setup:**

```bash
# Formula needs permission to call the other components
cyfr policy set f:local.users-api:0.1.0 allowed_tools '["execution.run"]'
```

**Pseudocode flow:**

```
receive input: { "action": "create", "data": { "email": "alice@example.com", "name": "Alice" } }

1. Call r:local.user-validator:0.1.0
   → { "action": "validate_create", "data": input.data }
   → if invalid, return { "error": "validation_failed", "details": errors }

2. Call c:local.supabase:0.2.0
   → { "table": "users", "action": "insert", "params": { "body": input.data } }
   → if error, return { "error": "db_error", "details": error }

3. Return { "user": data[0], "status": "created" }
```

#### 4. Frontend Calls the Formula

```javascript
// Your React/Next.js app calls the Formula via MCP
const result = await runComponent(
  "formula:local.users-api:0.1.0",
  { action: "create", data: { email: "alice@example.com", name: "Alice" } },
  "formula"
);
// result → { "user": { "id": 1, "email": "alice@example.com", "name": "Alice" }, "status": "created" }
```

### Structuring CRUD Operations

**Option A: One Formula per resource** — simpler. Input includes `"action": "create|read|update|delete"`. Good for small apps (e.g., `f:local.users-api:0.1.0`).

**Option B: One Formula per operation** — finer-grained policy, rate limits, and audit per operation. Use when different operations need different security postures (e.g., `f:local.users-delete:0.1.0` requires admin key, `f:local.users-list:0.1.0` allows public key).

### Where Application Data Lives

CYFR has two storage systems — don't confuse them:

| Storage | What Goes There | Managed By |
|---------|-----------------|------------|
| **Arca** (CYFR internal) | Secrets, policies, audit logs, API keys, sessions | CYFR platform |
| **External DB** (Supabase, Neon, PlanetScale) | Users, orders, products — your domain data | Your Catalysts |

Your application data stays in the external database. If you stop using CYFR tomorrow,
your data is still in Supabase where it always was. CYFR governs *access* to your data,
it doesn't *store* your data.

---

## Host Policy Setup

The recommended way to configure secrets, grants, and host policies for all your registered components is `cyfr setup`. It reads your component manifests, detects which secrets are needed, and walks you through setting everything up interactively.

```bash
cyfr setup
```

`cyfr register` scans and registers local components. Run `cyfr setup` afterwards to configure secrets, grants, and policies — it lets you choose which versions to apply to (all versions by default, or specific ones).

If you need fine-grained control or want to script individual policy changes, you can use the commands below directly.

Before components can run, you need to configure Host Policies. Catalysts **require** a policy with `allowed_domains` — without it, execution is rejected with a `POLICY_REQUIRED` error. Reagents don't need policy.

### Policy Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `allowed_domains` | string[] | `[]` (deny-all) | Domains the component can reach via HTTP |
| `allowed_methods` | string[] | `["GET","POST","PUT","DELETE","PATCH"]` | HTTP methods allowed |
| `rate_limit` | object | `nil` (no limit) | Rate limit per user per component. Format: `{"requests": N, "window": "1m"}` |
| `timeout` | string | `"30s"` | Max execution time (e.g., `"30s"`, `"1m"`) |
| `max_memory_bytes` | integer | 67108864 (64 MB) | Max WASM memory |
| `max_request_size` | integer | 1048576 (1 MB) | Max input size in bytes |
| `max_response_size` | integer | 5242880 (5 MB) | Max output size in bytes |
| `allowed_tools` | string[] | `[]` (deny-all) | MCP tools allowed (for Formulas using `cyfr:mcp/tools`) |
| `allowed_private_ips` | string[] | `[]` (deny-all) | Private IPs or CIDR ranges to allow (for on-prem/air-gapped deployments). `169.254.0.0/16` always blocked. |

### Setting Policies

```bash
# Allow a catalyst to call an external API (all registered versions)
cyfr policy set c:local.claude allowed_domains '["api.anthropic.com"]'

# Set a custom rate limit
cyfr policy set c:local.claude rate_limit '{"requests": 50, "window": "5m"}'

# Set a longer timeout for slow operations
cyfr policy set c:local.claude timeout '"60s"'

# Allow access to private network services (on-prem deployments)
cyfr policy set c:local.claude allowed_private_ips '["10.0.0.0/8", "192.168.1.100"]'

# Version-specific policy (only this version)
cyfr policy set c:local.claude:0.2.0 allowed_domains '["api.anthropic.com", "extra.api.com"]'

# View current policy
cyfr policy show c:local.claude

# List all policies
cyfr policy list
```

### Domain Matching

- Exact match: `"api.stripe.com"` matches only `api.stripe.com`
- Wildcard: `"*.stripe.com"` matches `api.stripe.com`, `dashboard.stripe.com`, etc.

### Private IP Access

By default, all private/reserved IP ranges are blocked to prevent SSRF attacks. For on-prem or air-gapped deployments where components need to reach services on private IPs, use `allowed_private_ips`:

```bash
# Allow all 10.x.x.x addresses
cyfr policy set c:local.my-catalyst allowed_private_ips '["10.0.0.0/8"]'

# Allow specific IPs and ranges
cyfr policy set c:local.my-catalyst allowed_private_ips '["192.168.1.100", "10.0.0.0/8"]'
```

- Accepts individual IPs (`"192.168.1.100"`) and CIDR ranges (`"10.0.0.0/8"`)
- `169.254.0.0/16` (link-local / cloud metadata) is **always blocked** regardless of this setting
- An empty list (the default) denies all private IPs, preserving current behavior

### MCP Tool Policies (for Formulas)

Formulas that use `cyfr:mcp/tools` need `allowed_tools` in their policy:

```bash
cyfr policy set f:local.my-formula:0.1.0 allowed_tools '["component.search", "component.pull"]'
```

Tool matching supports wildcards: `"component.*"` matches `component.search`, `component.list`, etc.

---

## Environment Variables Reference

### Required for Production

| Variable | Description | Example |
|----------|-------------|---------|
| `CYFR_SECRET_KEY_BASE` | Phoenix secret key base (generated during project init) | `<64-byte random base64>` |

### Server

| Variable | Default | Description |
|----------|---------|-------------|
| `CYFR_HOST` | `localhost` | Server bind address |
| `CYFR_PORT` | `4000` | Server port |
| `CYFR_PRISM_PORT` | `4001` | Prism dashboard port |
| `CYFR_DATABASE_PATH` | `data/cyfr.db` | SQLite database path (Arx edition only; Core uses fixed default) |
| `CYFR_DB_POOL_SIZE` | `5` | Database connection pool size |

### Authentication

| Variable | Default | Description |
|----------|---------|-------------|
| `CYFR_GITHUB_CLIENT_ID` | — | GitHub OAuth app client ID (for `cyfr login`) |
| `CYFR_GITHUB_CLIENT_SECRET` | — | GitHub OAuth app client secret |
| `CYFR_SESSION_TTL_HOURS` | `24` | Session timeout in hours |
| `CYFR_AUTH_PROVIDER` | auto-detect | Force auth provider: `oidc` or `simple_oauth` |
| `CYFR_ALLOWED_USER` | — | Comma-separated allowed emails (all auth paths) |

### JWT (Enterprise)

| Variable | Default | Description |
|----------|---------|-------------|
| `CYFR_JWT_SIGNING_KEY` | — | Shared secret for JWT verification (min 32 bytes) |
| `CYFR_JWT_CLOCK_SKEW_SECONDS` | `60` | Allowed clock skew in seconds (max 300) |

### OIDC (Enterprise)

| Variable | Description |
|----------|-------------|
| `CYFR_OIDC_ISSUER` | OIDC issuer URL (e.g., `https://auth.example.com`) |
| `CYFR_OIDC_CLIENT_ID` | OIDC client ID |
| `CYFR_OIDC_CLIENT_SECRET` | OIDC client secret |

---

## Quick Setup Checklist

This assumes you've completed the Quick Start in the [README](README.md) (install, init, server running).

```bash
# 1. Start CYFR and authenticate
cyfr up
cyfr login

# 2. Register a component (using the included Claude example)
cyfr register

# 3. Run setup to configure secrets, grants, and policies for your components
cyfr setup

# 4. Create an API key for your app
cyfr key create --name "my-app" --type secret

# 5. Use the returned key in your app's Authorization header
#    Authorization: Bearer cyfr_sk_...
```

The Prism dashboard is available at `http://localhost:4001` for visual monitoring of executions, builds, and components.

From here, your app can POST to `/mcp` with the API key and execute any component you've configured.

> **Development workflow**: When iterating on components, follow the loop: **build → register → run → iterate**. The `cyfr register` step is required after every rebuild because registration stores a SHA-256 digest of each WASM binary. If you rebuild a component without re-registering, `cyfr run` will reject it with: `Integrity check failed for <component>. Component may have been modified. Re-register with 'cyfr register'.`
>
> **Note**: `cyfr register` is only needed for local/agent components developed in `components/`. Components installed via `cyfr pull` are written to `components/` and indexed automatically — no registration step required.
