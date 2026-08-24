# Integration Guide

How to use CYFR as your application backend.

> **See also**: [Component Guide](component-guide.md) for building WASM components and tincture frontends. This guide covers the other side — connecting your app to CYFR via HTTP, serving tinctures, and feeding data to frontend displays.

---

## How CYFR Works as an App Backend

CYFR exposes a single HTTP endpoint that speaks [MCP](https://modelcontextprotocol.io/) (Model Context Protocol) over JSON-RPC 2.0. Your application sends a POST request, CYFR authenticates it, routes it to the right WASM component, executes it in a sandbox, and returns the result.

```
Your App                         CYFR Server                    Sandbox
───────                         ───────────                    ───────
POST /mcp  ──────────────────>  Authenticate (API key / session)
  Authorization: Bearer            │
  cyfr_sk_...                      ├── Resolve component reference
                                   ├── Load the granted capability (domains, rate limits)
                                   ├── Resolve bound Connections (credentials)
                                   │
                                   └── Execute WASM ──────────>  [Component]
                                                                    │
                                   <──────── Result ───────────────┘
  <──── JSON-RPC response ─────
```

Every CLI command (`cyfr run`, `cyfr profile grant`, etc.) uses this same endpoint. AI agents, frontends, backend services, and CI/CD pipelines all use the same interface.

---

## Authentication Methods

CYFR supports two authentication methods. Choose the one that fits your use case:

| Method | When to Use | How It Works |
|--------|-------------|--------------|
| **API Keys** | Apps and service-to-service callers (frontend, backend, CI/CD) | `Authorization: Bearer cyfr_pk_...` header |
| **Session Tokens** | Human devs using the CLI (`cyfr login`) | OAuth / OIDC login, session stored in `~/.cyfr/config.json` |

### API Keys

API keys are the primary way applications authenticate with CYFR. There are three types:

| Type | Prefix | Use Case | Security Considerations |
|------|--------|----------|------------------------|
| **Application** | `cyfr_pk_` | Frontend apps, client-side code | Safe to embed in browser code. Can execute and search, but cannot access secrets or admin operations by default. |
| **Service** | `cyfr_sk_` | Backend services | Never expose client-side. Keep in environment variables. Can read/write secrets. |
| **Admin** | `cyfr_ak_` | CI/CD, automation, infrastructure | Use with IP allowlist. Full access to all operations including key management. |

API keys are generated as cryptographically random tokens. CYFR only stores a SHA-256 hash — the raw key is shown once at creation time and cannot be retrieved later.

### Session Tokens

Session tokens are for human developers using the CLI. The `cyfr login` command runs an OAuth device flow:

1. CLI calls CYFR with `action: "device_init"` and the GitHub provider
2. CYFR returns a user code and verification URL
3. You open the URL in a browser, enter the code, and authorize
4. CLI polls until authorization completes, then stores the session ID in `~/.cyfr/config.json`
5. Registry credentials are stored server-side during the device flow

Sessions expire after 30 days (720 hours) of inactivity (configurable via `CYFR_SESSION_TTL_HOURS`; set it to `0` to never expire).

```bash
cyfr login              # Interactive OAuth device flow (GitHub)
cyfr whoami             # Check current session
cyfr logout             # Destroy session
```

### Service-to-service

Backend services and automation authenticate with API keys — a service key
(`cyfr_sk_`) for backends, an admin key (`cyfr_ak_`, ideally IP-allowlisted) for
CI/CD and infrastructure. See **API Key Lifecycle** below.

---

## API Key Lifecycle

### Create

```bash
# Application key (frontend) — defaults to execute, component_read, policy_read, storage_read
cyfr key create --name "react-app" --type application

# Service key (backend) — defaults to execute, secrets_read, component_read, policy_read, storage_read/write
cyfr key create --name "node-backend" --type service

# Service key with extra scope
cyfr key create --name "node-backend-rw" --type service --scope "secrets_read,secrets_write"

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
      "type": "application"
    }
  }
}
```

Response (the raw key is shown **only once**):

```json
{
  "key": "cyfr_pk_aBcDeFgHiJkLmNoPqRsTuVwXyZ012345",
  "name": "react-app",
  "type": "application",
  "scope": ["execute", "component_read", "policy_read", "storage_read"],
  "created_at": "2025-02-13T..."
}
```

### Available Scopes

Scopes control what operations an API key can perform. Each scope maps to a category of actions:

| Scope | What It Allows |
|-------|----------------|
| `execute` | Run components, manage schedules, compile builds |
| `secrets_read` | Read stored credential metadata (Connections; material never leaves the vault) |
| `secrets_write` | Store/replace provider credentials (e.g. `oauth set_client`) |
| `component_read` | Get component blobs, discover components |
| `component_manage` | Pull, push, register, remove, scaffold components |
| `policy_read` | View limit ceilings and type defaults |
| `policy_manage` | Manage limit ceilings and type defaults |
| `users_read` | View permissions |
| `users_manage` | Set permissions |
| `storage_read` | View execution records, MCP logs, enforcement logs, retention config |
| `storage_write` | Set retention policies |
| `execution_write` | Service-level execution management |
| `admin` | API key management, retention cleanup, session operations, force-release |
| `*` | Wildcard — all permissions |

#### Key Type Defaults and Ceilings

Each key type has default scopes (applied when none are specified) and a ceiling (the maximum scopes it can be granted):

| Type | Default Scopes | Allowed Scopes (Ceiling) |
|------|---------------|--------------------------|
| **Application** | `["execute", "component_read", "policy_read", "storage_read"]` | `["execute", "secrets_read", "component_read", "policy_read", "storage_read"]` |
| **Service** | `["execute", "secrets_read", "component_read", "policy_read", "storage_read", "storage_write"]` | `["execute", "secrets_read", "secrets_write", "component_read", "component_manage", "policy_read", "policy_manage", "users_read", "storage_read", "storage_write", "execution_write"]` |
| **Admin** | `["*"]` (all) | `["secrets_read", "secrets_write", "users_manage", "admin", "*"]` |

### Rate Limiting

API keys can have per-key rate limits:

```bash
cyfr key create --name "rate-limited" --type application --scope execute --rate-limit "100/1m"
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
cyfr key rotate react-app
```

Returns a new key and invalidates the old one.

### Revoke

```bash
cyfr key revoke react-app
```

### List

```bash
cyfr key list
```

Lists all keys with their name, type, scope, and creation date. Raw key values are never shown — only the 12-character prefix (e.g., `cyfr_pk_aBcD...`).

---

## API Keys vs Connections

Two different credential types serve two different purposes: API keys authenticate your **app** to **CYFR**; **Connections** (vault entries) hold the credentials **components** use to reach third-party APIs. A Connection is bound to a component through a consent revision — the component names a *role* (a manifest `need`), the operator picks which Connection satisfies it, and the component only ever sees the projected fields, never the entry itself.

| | API Keys | Connections (`api_key` / `bundle`) | Connections (`oauth`) |
|---|----------|-----------------------------------|----------------------|
| **Purpose** | Authenticate your **app** to **CYFR** | Authenticate **components** to **service APIs** | Authenticate **components** to **user-scoped APIs** |
| **Example** | `cyfr_sk_...` in your backend's env | `STRIPE_API_KEY=sk-live-...` | Google/Slack grants |
| **Who uses it** | Your app (in the `Authorization` header) | WASM components (via `cyfr:vault/read`) | WASM components (via `cyfr:oauth/token`) |
| **Stored where** | Your app's environment | CYFR's vault (sealed, encrypted at rest) | CYFR's vault (sealed, encrypted at rest) |
| **Managed by** | `cyfr key create/revoke/rotate` | `vault` verbs + console Connections page; bound via `cyfr profile grant` | `vault.authorize` (browser grant) + `oauth.set_client` (provider app creds); bound via `cyfr profile grant` |
| **Lifecycle** | Static — set once | Static — rotate without re-consent | Dynamic — host auto-refreshes |

**Example flow:**

```
Your React App                    CYFR                        Stripe API
────────────                     ────                        ──────────
POST /mcp
  Authorization: Bearer          Validates your API key
  cyfr_sk_abc123...              (authenticates your app)
  Body: run stripe catalyst  ──>
                                 Resolves STRIPE_API_KEY from
                                 the Connection bound to the
                                 component's need at consent
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
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: tools/call
Mcp-Name: execution
Authorization: Bearer cyfr_sk_...
```

The body is a JSON-RPC 2.0 message. Every request declares its own protocol
version and the capabilities of the client sending it — there is no handshake,
so there is nowhere else to say it:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "execution",
    "arguments": {
      "action": "run",
      "reference": "catalyst:local.claude:1.0.0",
      "input": {"operation": "messages.create", "params": {"model": "claude-sonnet-4-5-20250514", "messages": [{"role": "user", "content": "Hello"}]}},
      "type": "catalyst"
    },
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities": {},
      "io.modelcontextprotocol/clientInfo": {"name": "my-app", "version": "1.0.0"}
    }
  }
}
```

`Mcp-Method` and `Mcp-Name` mirror `method` and `params.name` into headers so a
gateway can route and rate-limit without parsing the body. The server checks
that they agree with the body and refuses the request with `-32020` if they do
not — a header that can disagree with what the server executes is worse than no
header at all. `Mcp-Name` carries `params.uri` for `resources/read`, and is
omitted entirely for methods that name no subject.

### Response Format

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "resultType": "complete",
    "content": [
      {
        "type": "text",
        "text": "{\"status\":\"completed\",\"execution_id\":\"exec_01234567-...\",\"result\":{...}}"
      }
    ],
    "isError": false,
    "_meta": {
      "io.modelcontextprotocol/serverInfo": {"name": "CYFR", "version": "0.5.8"}
    }
  }
}
```

Every result carries `resultType`. Today it is always `"complete"`; treat any
value you do not recognise as an error rather than assuming the result is
finished.

### Required Headers

| Header | Value | When |
|--------|-------|------|
| `Content-Type` | `application/json` | Always |
| `Accept` | `application/json, text/event-stream` | Always |
| `MCP-Protocol-Version` | `2026-07-28` | Always — must equal the `_meta` version |
| `Mcp-Method` | the request's `method` | Always |
| `Mcp-Name` | `params.name`, or `params.uri` for `resources/read` | Methods that name a subject |
| `Authorization` | `Bearer cyfr_pk_...`, `Bearer cyfr_sk_...`, or a session token | Always, unless calling a public action |

A value that is not plain visible ASCII travels Base64-encoded in the
specification's sentinel form, `=?base64?<encoded>?=`, and the server decodes it
before comparing against the body.

### There Is No Session To Establish

Earlier revisions of MCP opened with an `initialize` handshake and carried an
`Mcp-Session-Id` afterwards. **Neither exists in `2026-07-28`.** Every request
authenticates itself and declares its own version, so:

- There is no `initialize` call to make. Sending one returns `404` with
  `-32601`.
- The server never mints or echoes a session id. Do not look for one.
- `Authorization: Bearer ...` goes on **every** request. Both an API key and a
  Sanctum session token are accepted in that header, and both are re-checked
  against the database each time — so revoking either takes effect on the very
  next call rather than whenever a cached session happens to expire.

### Discovering What A Server Speaks

Optional. A client may call any method directly and handle
`-32022 UnsupportedProtocolVersion`, which carries the supported list. If you
would rather ask up front:

```json
{"jsonrpc": "2.0", "id": 1, "method": "server/discover",
 "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                      "io.modelcontextprotocol/clientCapabilities": {}}}}
```

The result carries `supportedVersions`, `capabilities`, `instructions`, and the
caching hints below.

### Caching

`server/discover`, `tools/list`, `resources/list`, `resources/templates/list`
and `resources/read` return `ttlMs` and `cacheScope`. `ttlMs` is how long you
may treat the answer as fresh; `cacheScope` is `"private"` when the answer
depends on who asked — CYFR filters the tool list by the caller's permissions,
so a shared cache must not serve one caller's list to another.

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
| -33003 | `auth_expired` | Session expired |
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

> **MCP Tool Reference**: For a complete mapping of CLI commands to MCP tool/action pairs (useful when building HTTP integrations), see [CLI → MCP Tool Reference](component-guide.md#cli--mcp-tool-reference) in the Component Guide.

### Public Tools (No Auth Required)

Most tool calls require authentication (session login or API key). The following tools and actions are accessible without authentication — they support discovery and the login flow itself:

| Tool | Actions | Why Public |
|------|---------|------------|
| `session` | all (`login`, `logout`, `whoami`, `device_init`, `device_poll`) | Needed to authenticate in the first place |
| `registry` | `probe`, `claim-personal`, `get-namespace` | Identity discovery and the first-login namespace claim. Other `registry` actions (`claim-publisher`, `verify-publisher`, `tokens-*`, `members-*`) require authentication. |
| `aqua` | `list`, `get` | Read-only access to the agent catalog and documentation |
| `component` | `search`, `inspect`, `categories`, `setup_plan`, `list` | Read-only component discovery |
| `system` | `status` | Health checks |

When an auth provider **is** configured, this anonymous surface narrows: component browsing requires sign-in, so only `component` `categories` and `setup_plan` stay public (alongside `session`, `aqua` `list`/`get`, the registry bootstrap actions, and `system status`).

Everything else — `execution.*`, `build.*`, `schedule.*`, `vault.*`, `oauth.*`, `key.*`, `permission.*`, `webhook.*`, `profile.*`, `record.*`, `mcp_log.*`, `policy_log.*`, `retention.*`, `component.register`, `component.push`, `component.pull`, `component.remove`, `component.new`, `component.get_blob`, `component.discover`, `system.notify` — returns error code `-33001` (`auth_required`) if the session is not authenticated.

---

## Example Scenarios

### React Frontend with Public Key

A public key is safe to embed in client-side code. It can execute and search components but cannot access secrets or admin operations.

```javascript
const CYFR_URL = "https://your-cyfr-server.example.com/mcp";
const CYFR_KEY = "cyfr_pk_aBcDeFgHiJkLmNoPqRsTuVwXyZ012345";
const PROTOCOL_VERSION = "2026-07-28";

async function runComponent(reference, input, type = "catalyst") {
  const response = await fetch(CYFR_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream",
      "MCP-Protocol-Version": PROTOCOL_VERSION,
      // Mirror the routed fields; the server refuses a header that disagrees.
      "Mcp-Method": "tools/call",
      "Mcp-Name": "execution",
      "Authorization": `Bearer ${CYFR_KEY}`,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "execution",
        arguments: { action: "run", reference, input, type },
        _meta: {
          "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
          "io.modelcontextprotocol/clientCapabilities": {},
        },
      },
    }),
  });
  return response.json();
}

// Call a component
const result = await runComponent(
  "catalyst:local.claude:1.0.0",
  { operation: "messages.create", params: { model: "claude-sonnet-4-5-20250514", messages: [{ role: "user", content: "Hello" }] } }
);
```

### Node.js Backend with Secret Key

Secret keys should live in environment variables, never in source code.

```javascript
const CYFR_URL = process.env.CYFR_URL || "http://localhost:4000/mcp";
const CYFR_KEY = process.env.CYFR_SECRET_KEY; // cyfr_sk_...
const PROTOCOL_VERSION = "2026-07-28";

async function cyfr(toolName, args) {
  const res = await fetch(CYFR_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream",
      "MCP-Protocol-Version": PROTOCOL_VERSION,
      "Mcp-Method": "tools/call",
      "Mcp-Name": toolName,
      "Authorization": `Bearer ${CYFR_KEY}`,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: Date.now(),
      method: "tools/call",
      params: {
        name: toolName,
        arguments: args,
        _meta: {
          "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
          "io.modelcontextprotocol/clientCapabilities": {},
        },
      },
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

**CLI-based (recommended):**

```yaml
# GitHub Actions example
jobs:
  deploy-component:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build and test component
        run: |
          cyfr build compile reagent:local.my-tool:0.1.0
          cyfr run reagent:local.my-tool:0.1.0 --input '{"test": true}'
```

**Raw HTTP alternative:**

```yaml
# GitHub Actions example
jobs:
  deploy-component:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Compile and register component
        env:
          CYFR_URL: ${{ secrets.CYFR_URL }}
          CYFR_ADMIN_KEY: ${{ secrets.CYFR_ADMIN_KEY }}  # cyfr_ak_...
        run: |
          curl -X POST "$CYFR_URL/mcp" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json, text/event-stream" \
            -H "MCP-Protocol-Version: 2026-07-28" \
            -H "Mcp-Method: tools/call" \
            -H "Mcp-Name: build" \
            -H "Authorization: Bearer $CYFR_ADMIN_KEY" \
            -d '{
              "jsonrpc": "2.0",
              "id": 1,
              "method": "tools/call",
              "params": {
                "name": "build",
                "arguments": {
                  "action": "compile",
                  "reference": "reagent:local.my-tool:0.1.0"
                },
                "_meta": {
                  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                  "io.modelcontextprotocol/clientCapabilities": {}
                }
              }
            }'
```

> **CI/CD tips**: Use `cyfr build toolchains` to verify the runner environment has the required compilation toolchain. Use `cyfr build validate` to validate a pre-compiled WASM binary without compiling from source.

### Python Backend

```python
import requests
import os

CYFR_URL = os.environ.get("CYFR_URL", "http://localhost:4000/mcp")
CYFR_KEY = os.environ["CYFR_SECRET_KEY"]  # cyfr_sk_...
PROTOCOL_VERSION = "2026-07-28"

def cyfr_call(tool_name, arguments):
    response = requests.post(
        CYFR_URL,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": PROTOCOL_VERSION,
            "Mcp-Method": "tools/call",
            "Mcp-Name": tool_name,
            "Authorization": f"Bearer {CYFR_KEY}",
        },
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": tool_name,
                "arguments": arguments,
                "_meta": {
                    "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
                    "io.modelcontextprotocol/clientCapabilities": {},
                },
            },
        },
    )
    data = response.json()
    if "error" in data:
        raise Exception(f"CYFR error {data['error']['code']}: {data['error']['message']}")
    return data["result"]

# Execute a component
result = cyfr_call("execution", {
    "action": "run",
    "reference": "catalyst:local.claude:1.0.0",
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

> Use `cyfr new <type> <name>` to scaffold each component. See the [Component Guide](component-guide.md#scaffold-with-cyfr-new) for details.

### Execution Event Streaming

For long-running formula executions (e.g., agentic loops), CYFR supports real-time event streaming so frontends can show progressive updates instead of waiting for the full result.

**Starting a streaming execution:**

Use `execution.run_stream` instead of `execution.run`. It returns immediately with an `execution_id` and `stream_url`:

```json
{
  "action": "run_stream",
  "reference": "formula:local.agent:0.4.0",
  "input": {"task": "Build a REST API", "model": "claude-sonnet-4-5-20250514"}
}
// Response:
{"execution_id": "exec_abc123", "stream_url": "/api/executions/exec_abc123/events"}
```

**Consuming events via SSE:**

Connect to the SSE endpoint to receive events as the formula executes:

```bash
curl -N http://localhost:4000/api/executions/exec_abc123/events
```

Events use standard SSE format with `event:` set to the event type:

```
id: 1
event: emit
data: {"kind":"turn_start","turn":1}

id: 2
event: emit
data: {"kind":"text_delta","content":"Here's my approach...","turn":1}

id: 999999999
event: complete
data: {"status":"completed","duration_ms":15234}
```

The endpoint supports `Last-Event-ID` for reconnection and sends keep-alive comments every 15 seconds. The connection closes automatically on `complete` or `error` events.

**Setup required events (during streaming):**

When a formula invokes a sub-component whose consent isn't satisfiable — a need with no live Connection bound, or a shape that drifted past its approved consent — the system automatically emits a `setup_required` event with machine-readable fix instructions:

```
id: 5
event: emit
data: {"kind":"setup_required","component_ref":"catalyst:local.stripe:0.1.0","profile_id":"prf_...","issues":[{"type":"unbound_need","need":"api_key","message":"The need \"api_key\" has no live credential bound","fix":{"tool":"profile","action":"plan","args":{"ref":"catalyst:local.stripe:0.1.0"}}}],"setup_command":"cyfr profile grant catalyst:local.stripe:0.1.0","message":"This app needs a connection for \"api_key\""}
```

Each issue's `fix` object contains the MCP tool, action, and args to start the consent walk. Frontends can use these to render one-click fix buttons; `setup_command` provides the CLI alternative. A drifted consent surfaces the same way with issue type `consent_required` ("permissions changed since you approved them"). The formula still fails — the event is informational so consumers can act on it.

**Checking readiness up front** — `component.setup_plan` answers "can this run?" from the consent. Its `consent` section carries the profile (`profile_id`, `revision`, `scope`) and one row per need — `satisfied` plus a human-readable `detail` ("bound to my-anthropic-key", "no connection bound for 'api_key' — grant one to continue", "was rebound since this consent — re-approve to continue"). Top-level `ready` is true only when the profile is active and every need is bound to a live, digest-matching Connection.

### Scheduling Recurring Executions

CYFR supports cron-based scheduling for recurring component execution. Create schedules via the MCP `schedule` tool or the `cyfr schedule` CLI commands.

**Creating a schedule via MCP:**

```json
{
  "jsonrpc": "2.0", "id": 1, "method": "tools/call",
  "params": {
    "name": "schedule",
    "arguments": {
      "action": "create",
      "name": "daily-report",
      "cron_expression": "0 9 * * *",
      "reference": "formula:local.report:1.0.0",
      "input": {"format": "summary"}
    }
  }
}
```

**Cron expression format:** 5-field standard cron — `minute hour day-of-month month day-of-week`. Supports `*` (any), ranges (`1-5`), steps (`*/15`), and lists (`1,3,5`). Minimum interval is 1 minute.

| Expression | Meaning |
|------------|---------|
| `*/5 * * * *` | Every 5 minutes |
| `0 9 * * *` | Daily at 9:00 AM |
| `0 */2 * * 1-5` | Every 2 hours on weekdays |
| `30 8 1 * *` | 8:30 AM on the 1st of each month |

**Managing schedules:**

```bash
cyfr schedule create --name daily-report --cron "0 9 * * *" --ref "formula:local.report:1.0.0"
cyfr schedule list
cyfr schedule pause <schedule_id>
cyfr schedule resume <schedule_id>
cyfr schedule delete <schedule_id>
```

**Constraints:** Maximum 25 schedules per user. Minimum interval is 1 minute.

### MCP Request Logs

Every MCP tool call is recorded with full input/output, status, and duration. Inspect logs via the `mcp_log` tool or `cyfr log` CLI commands:

```bash
cyfr log list                              # Recent logs
cyfr log list --tool execution --status error  # Filter by tool and status
cyfr log get <id>                          # Full details for a specific log entry
cyfr log correlate <request_id>            # Find related log entries
```

### Concrete Example: User Management

A complete walkthrough of building user CRUD operations on CYFR.

#### 1. Supabase Catalyst (`c:local.supabase:0.2.0`)

Handles all database operations via Supabase's REST API.

**Setup:**

```bash
# Create the catalyst project (if starting fresh)
cyfr new catalyst supabase --version 0.2.0

# Grant it: pick a Connection for each need, approve the capability ask
cyfr profile grant c:local.supabase
```

Create the Connection first (console Connections page, or `vault.create` with fields `SUPABASE_URL` + `SUPABASE_SERVICE_KEY`). If you own the Supabase project, you can skip the Connection entirely and pass the URL and anon key as call arguments — the sealed path is for values that must not appear in logs.

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
# The formula declares "caps": {"tools": ["execution.run"]} in its manifest;
# granting it approves that ask
cyfr profile grant f:local.users-api
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

CYFR has two kinds of storage — don't confuse them:

| Storage | What Goes There | Managed By |
|---------|-----------------|------------|
| **CYFR-managed** | Connections, consents, audit logs, API keys, sessions | CYFR |
| **Your external DB** (Supabase, Neon, PlanetScale, …) | Users, orders, products — your domain data | Your Catalysts |

Your application data stays in the external database. Tinctures invoke backend components via `cyfr.invoke()` — the component fetches from your real data source and returns results. If you stop using CYFR tomorrow, your data is still in your database where it always was. CYFR governs *access* to your data, it doesn't *store* your data.

---

## Granting Components: Connections & Consent

Before a component can run, an operator grants it: which **Connections** satisfy its manifest `needs`, and how much of its `caps` ask to approve. Nothing auto-applies — the manifest is an ask, and a human commits every grant. The interactive paths are `cyfr profile grant <ref>` and the console's Connections page; everything below is the same flow over MCP.

`cyfr register` scans and registers local components, auto-pulling any missing published dependencies. Grant each component afterwards — a catalyst with nothing granted is rejected with a `POLICY_REQUIRED` / `setup_required` error. Reagents need no grant.

### Connections (`vault` tool)

A Connection is a vault entry holding credential material — sealed at rest, never returned by any API. Material flows one way: `create` and `rotate` accept field values; nothing ever returns them.

| Action | Key args | What it does |
|--------|----------|--------------|
| `list` | — | Enumerate entries (names + status, never material) |
| `create` | `name`, `kind` (`api_key` \| `oauth` \| `bundle`), `fields` | Mint an entry with sealed material |
| `rotate` | `id`, `fields`, `expected_payload_rev` | Replace material, same field schema — CAS-guarded, **no re-consent needed** |
| `rebind` | `id` + binding fields (`field_names`, `oauth_endpoints`, `oauth_scopes`) | Change what the credential *talks to* — dependent consents stop being ready until re-approved |
| `authorize` | `id` (re-auth) or `name` + `provider_hint` (+ `oauth_scopes`) | Start a browser OAuth grant; the callback completes it into the entry |
| `revoke` | `id` | Kill the material; dependent profiles report not-ready |
| `delete` | `id` | Remove the entry |

Vault mutations require an interactive session — components and guest-plane callers can never reach these verbs.

**OAuth is Connection-keyed, not component-keyed.** Provider endpoints live on the Connection (`google` is a built-in preset), and your OAuth app's client credentials are set once per provider with `oauth.set_client` (`provider`, `client_id`, `client_secret`) — operator configuration, not a manifest concern. The component only declares a need of type `oauth:<provider>` with the scopes it requires; at runtime it calls `get_access_token("<provider>")` and receives short-lived, auto-refreshed tokens.

### The consent walk (`profile` tool)

Granting is a three-step walk — nothing is granted outside it:

```
plan     {ref}                            → the component's needs + caps ask,
                                            candidate connections, a plan_token
preview  {decisions, plan_token}          → the exact rendered grant + commit_digest
commit   {decisions, plan_token, proof,
          commit_digest,
          expected_consent_revision}      → an immutable consent revision
```

`preview` exists so the approval proof binds the exact commit digest that was rendered — a decision changed after approval cannot ride on the old approval. `commit` CAS-checks the head revision, so concurrent grants conflict instead of clobbering. Decisions carry the bindings (`[{need, entry_id, fields, scopes}]`), the scope (`versionless` covers every release of the line — the default; `pinned` names one), and any limit adjustments under the platform ceiling.

| Action | Key args | Returns |
|--------|----------|---------|
| `plan` | `ref` | needs, caps ask, candidate connections, `plan_token` |
| `preview` | `decisions` | rendered summary, `commit_digest` |
| `commit` | `decisions`, `plan_token`, `proof`, `commit_digest`, `expected_consent_revision` | the new consent revision |
| `list` | `ref` | profiles + head revisions |
| `revoke` | `profile_id` | revoked — effective on the next run |

Interactive sessions and consent-capable API keys may commit; a key's consent capability comes from its own key row, never from the request.

### Readiness and typed errors

`component.setup_plan` answers "can this run?" before you invoke: its `consent` section lists the profile and one row per need (`satisfied` + a human-readable `detail`), and top-level `ready` is true only when the profile is active and every need is bound to a live, digest-matching Connection.

Four typed errors cross every surface (MCP, CLI, consoles) with normative payloads:

| Error | Payload | Meaning / next step |
|-------|---------|---------------------|
| `setup_required` | `{profile_id, node_ref, need, reason}` | Names the unbound need — grant a Connection for it (`profile.plan` / `cyfr profile grant <ref>`) |
| `consent_required` | `{profile_id, current_revision, shape_diff}` | The component's ask changed since approval — the shape diff shows exactly what; review and re-approve |
| `consent_conflict` | `{expected_revision, actual_revision, cause}` | `stale_plan` → re-run plan; `digest_changed` → re-run preview; `race` → retry commit |
| `restart_required` | `{profile_id, new_revision, missing}` | A new revision landed under a running execution — restart to pick it up |

### What a grant enforces

The committed consent is the runtime capability — `ask ∩ operator choices ∩ platform ceiling`, frozen at commit:

- **Domains** — exact (`"api.stripe.com"`) or wildcard (`"*.stripe.com"`); deny-by-default. Schemes default to https-only.
- **Private IPs** — all private/reserved ranges blocked (SSRF prevention) unless the ask carried `egress.private_ips` and the operator approved it. `169.254.0.0/16` (link-local / cloud metadata) is always blocked.
- **Storage** — granted `storage.paths` (directory prefixes end with `/`, must start with `data/` or `components/`) and `storage.actions`; empty = hard deny.
- **Tools (formulas)** — granted patterns (`"execution.run"`, `"component.*"`, `"*"`) expand to the concrete action list at commit; a tool added to the platform later never widens an existing consent. Discovery via `{"tool": "tools", "action": "list"}`.
- **Limits** — `timeout`, `rate_limit`, sizes, `max_concurrent_tasks`; the manifest's suggestions as adjusted by the operator, capped by the ceiling. Defaults when unasked: catalyst `"3m"`, formula `"5m"`, reagent `"1m"`, rate limit `{"requests": 100, "window": "1m"}`, memory 64 MB, request 1 MB, response 5 MB.

---

## Tincture Routes

Tinctures are frontend components served by CYFR at dedicated routes. Unlike WASM components (which are called via the `/mcp` endpoint), tinctures are accessed directly via browser URLs.

### Private (Authenticated)

Served inside the Prism shell at `/t/:athanor/:publisher/:tincture_name`. Requires Prism session authentication (same as the dashboard).

```
GET /t/home/local/stock-dashboard           → index.html
GET /t/home/local/stock-dashboard/app.js    → static asset
GET /t/home/local/stock-dashboard/style.css → static asset
```

### Public (Unauthenticated)

Public tinctures use the same `/t/` path — no authentication needed. Set `tincture_visibility.set` to make a tincture public.

```
GET /t/home/local/stock-dashboard              → index.html (no auth needed if public)
GET /t/home/local/stock-dashboard/app.js       → static asset
```

### Security Headers

| Route | CSP Notable Differences |
|-------|------------------------|
| `/t/:athanor/:pub/:name` (index) | `script-src 'self' 'nonce-...'` (per-request nonce for auto-injected SDK), `connect-src 'self'` (extended from manifest `tincture.connect`), `object-src 'none'`, `base-uri 'self'`, `frame-ancestors 'self'` |
| `/t/:athanor/:pub/:name/*path` (assets) | `Access-Control-Allow-Origin: *` (CORS for sandboxed iframe module scripts) |

Both surfaces set `X-Content-Type-Options: nosniff`. Static assets include `Cache-Control: public, max-age=3600`. The Cyfr SDK is injected inline into `<head>` with a nonce — no separate `/sdk/` endpoint.

`frame-ancestors 'self'`: tinctures are framed by the Prism shell on the same origin (one endpoint serves both), so nothing else may frame them. The iframe is sandboxed (`allow-scripts` only, no `allow-same-origin`) with a per-request nonce, and private tinctures require a credential a third-party framer cannot obtain.

Sensitive files are never served: `data.db`, `cyfr-manifest.json`, `schema.sql`, dotfiles.

---

## Tincture Data

Tinctures don't have their own database. They get data two ways:

- **Live data** — call your backend components from the browser with `cyfr.invoke()` (see the SDK in the [Tincture Guide](tincture-guide.md)). The component fetches from your real data source server-side and returns the result; credentials and consent are enforced for you.
- **Static seed data** — ship a `data.db` (or any file) as a static asset in the tincture and read it client-side. It's just another shipped file; CYFR serves it like any other asset.

A typical live-data pipeline:

```
1. Catalyst (yfinance)        → fetches stock data from a market API
2. Formula  (stock-feed)      → calls the catalyst, aggregates results
3. Tincture (stock-dashboard) → cyfr.invoke("f:local.stock-feed", {symbol: "AAPL"})
                                 receives data, renders the chart in the browser
```

---

## Environment Variables Reference

### Required for Production

| Variable | Description | Example |
|----------|-------------|---------|
| `CYFR_SECRET_KEY_BASE` | Phoenix secret key base (generated during project init) | `<64-byte random base64>` |

### Server

| Variable | Default | Description |
|----------|---------|-------------|
| `CYFR_HOST` | `localhost` | Hostname for URL generation (not the bind address) |
| `CYFR_PORT` | `4000` | Server port |
| `CYFR_BIND_ADDRESS` | `0.0.0.0` | Network bind address for the MCP endpoint |
| `CYFR_DATABASE_PATH` | `data/cyfr.db` | SQLite database path |
| `CYFR_DB_POOL_SIZE` | `20` | Database connection pool size |
| `CYFR_DATA_PATH` | `data` | The one runtime storage root (athanor data and components, caches) |
| `CYFR_BUNDLE_PATH` | `components/_bundle` | Seed-bundle source, read in place |
| `CYFR_BEHIND_PROXY` | — | Set to `true` when behind a TLS-terminating reverse proxy |

### Authentication

| Variable | Default | Description |
|----------|---------|-------------|
| `CYFR_GITHUB_CLIENT_ID` | — | GitHub OAuth app client ID (for `cyfr login`) |
| `CYFR_GITHUB_CLIENT_SECRET` | — | GitHub OAuth app client secret |
| `CYFR_GOOGLE_CLIENT_ID` | — | Google OAuth client ID (alternative sign-in provider) |
| `CYFR_GOOGLE_CLIENT_SECRET` | — | Google OAuth client secret |
| `CYFR_SESSION_TTL_HOURS` | `720` | Session idle timeout in hours (30 days; `0` = never expire) |
| `CYFR_AUTH_PROVIDER` | auto-detect | Force auth provider: `oauth` (GitHub/Google) or `oidc` (federated) |
| `CYFR_PLATFORM_ADMIN_EMAILS` | — | Comma-separated emails of the server's operators (platform admins). They are always let in and manage the door — the server allowlist (`cyfr admin allow <email\|user_id\|*>`) that decides who else may sign in. Everyone not on either list is refused at sign-in (403). |
| `CYFR_MAX_ATHANORS`, `CYFR_MAX_GROUPS_PER_PERSON`, `CYFR_MAX_MEMBERS_PER_GROUP`, `CYFR_MINT_PER_HOUR`, `CYFR_ATHANOR_STORAGE_BYTES` | unset (off) | Public-door caps for a server whose allowlist is `*`. |

### Platform admins

CYFR is one product: deploy it as-is (sqlite, local FS, the seeded Home
athanor) or configure OIDC / Postgres / a custom registry. There is no separate
"edition" or "mode".

Once authentication is configured, two lists do two jobs. `CYFR_PLATFORM_ADMIN_EMAILS`
names the server's operators (platform admins): always let in, seated in the
Home group, and able to run the operator verbs (`door.*`, `execution.force_release`)
— but working inside one athanor at a time like everyone else; there is no
cross-athanor reach. The **server allowlist** (the door — `cyfr admin allow
<email|user_id|*>`, `cyfr admin deny …`, or the Settings page) is who else may
sign in at all: a match on first sign-in lets them in, no match is a 403, and
`*` lets in anyone the configured provider authenticates. Groups never open the
door: adding an unknown email to a group leaves an invitation that activates on
that person's first admitted sign-in and, when the door would refuse them, a
request for the operator.

With no auth configured, the deployment runs without sign-in: requests reach the
public read-only surface as an unauthenticated context, and tenant-scoped
operations are rejected.

### OIDC (federated identity)

Set `CYFR_AUTH_PROVIDER=oidc` to federate against a generic OIDC issuer. All
three variables are required when oidc is selected — the server refuses to boot
otherwise rather than silently degrading to no authentication. The issuer must
not be `github.com`/`accounts.google.com` (use GitHub/Google OAuth directly).

| Variable | Description |
|----------|-------------|
| `CYFR_OIDC_ISSUER` | OIDC issuer URL (e.g., `https://auth.example.com`) |
| `CYFR_OIDC_CLIENT_ID` | OIDC client ID |
| `CYFR_OIDC_CLIENT_SECRET` | OIDC client secret |

### Storage and database

| Variable | Default | Description |
|----------|---------|-------------|
| `CYFR_STORAGE` | `local` | `local` (filesystem) or `s3`. `s3` requires the `CYFR_S3_*` set |
| `CYFR_S3_BUCKET` / `CYFR_S3_REGION` | — | Required for S3 |
| `CYFR_S3_ACCESS_KEY_ID` / `CYFR_S3_SECRET_ACCESS_KEY` | — | Required for S3 |
| `CYFR_S3_ENDPOINT` / `CYFR_S3_PREFIX` / `CYFR_S3_PATH_STYLE` | — | Optional (MinIO etc.) |
| `CYFR_DATABASE_URL` | — | Required for a Postgres build (adapter is chosen at build time via `CYFR_DATABASE=postgres`; the published image is SQLite) |

### Registry and signing

| Variable | Default | Description |
|----------|---------|-------------|
| `CYFR_REGISTRY_URL` | `cyfr.run` | Component registry host the CLI/server publish to and pull from |
| `CYFR_OCI_REGISTRY_URL` | `registry.<CYFR_REGISTRY_URL>` | OCI registry endpoint for component blobs |
| `CYFR_COSIGN_KEY` / `CYFR_COSIGN_PASSWORD` | — | Cosign signing key (and its password) used when publishing components |

### Operations

| Variable | Default | Description |
|----------|---------|-------------|
| `CYFR_MCP_ALLOWED_ORIGINS` | — | Comma-separated origins allowed to call `/mcp` cross-origin (e.g. a PWA hosted on another domain) |
| `CYFR_LOG_FORMAT` | text | Set to `json` for structured (machine-parseable) logs |
| `CYFR_OTEL_ENABLED` | `false` | Set to `true` to enable OpenTelemetry distributed tracing |
| `CYFR_MAX_CONCURRENT_EXECUTIONS` | runtime default | Cap on concurrent component executions |

---

## Quick Setup Checklist

This assumes you've completed the Quick Start in the [README](README.md) (install, init, server running).

```bash
# 1. Start CYFR and authenticate
cyfr up
cyfr login

# 2a. Use existing components (e.g., the included Claude catalyst)
cyfr register
cyfr profile grant c:moonmoon69.claude

# 2b. Or create a new component from scratch
cyfr new catalyst my-api
#     Edit components/{athanor_id}/catalysts/local/my-api/0.1.0/src/src/lib.rs
cyfr build compile catalyst:local.my-api:0.1.0
cyfr profile grant catalyst:local.my-api

# 3. Create an API key for your app
cyfr key create --name "my-app" --type service

# 4. Use the returned key in your app's Authorization header
#    Authorization: Bearer cyfr_sk_...
```

The Prism dashboard is available at `http://localhost:4000` (the same endpoint as the API) for visual monitoring of executions, builds, components, and real-time agent formula progress.

From here, your app can POST to `/mcp` with the API key and execute any component you've configured.

### Development Workflow

**WASM components** — when iterating, the core loop is:

```
edit source → cyfr build compile <ref> → cyfr run <ref>
```

- `cyfr new <type> <name>` scaffolds a new component project (run once)
- `cyfr build compile` compiles, saves the `.wasm` binary, and auto-registers in one step
- `cyfr register` is only needed if you build components manually outside of `cyfr build compile`
- Components installed via `cyfr pull` are written to `components/` and indexed automatically

**Tinctures** — vanilla (no compile step) or React (requires build):

```
Vanilla:  cyfr new tincture <name>                    → edit HTML/JS/CSS → cyfr register → reload
React:    cyfr new tincture <name> --template react   → edit src/App.tsx → cyfr build compile → cyfr register
```

- `cyfr new tincture <name>` scaffolds vanilla HTML/JS/CSS (SDK is auto-injected at serve time)
- `cyfr new tincture <name> --template react` scaffolds a React + TypeScript + Vite project (requires `cyfr build compile` before registering)
- React builds run `npm install && vite build` via Locus — output is static HTML/JS/CSS, no runtime dependency
- Tinctures invoke backend components via `cyfr.invoke()` — declare dependencies in manifest `dependencies.static`
- View at `localhost:4000` (Prism → Tinctures tab) or `/t/:athanor/:publisher/:name` if public

See the [Component Guide](component-guide.md) for the full development loop and component authoring details.
