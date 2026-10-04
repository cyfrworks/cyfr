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
                                   ├── Resolve bound vault entries (credentials)
                                   │
                                   └── Execute WASM ──────────>  [Component]
                                                                    │
                                   <──────── Result ───────────────┘
  <──── JSON-RPC response ─────
```

Every CLI command (`cyfr run`, `cyfr profile grant`, etc.) uses this same endpoint. AI agents, frontends, backend services, and CI/CD pipelines all use the same interface.

The server has one HTTP endpoint (`:4000`), and three sets of routes share it: `/mcp`, the MCP interface this guide describes; the ingress routes — sign-in and sign-out under `/auth`, tinctures under `/t`, `/_s` and `/_f`, the health checks under `/api/health`, an execution's event stream (`/api/executions/:id/events`) and inbound webhooks (`/hooks`); and the Prism console at `/`. Each operation, whichever route reaches it, is admitted or refused by one gate against one table of operations, and an operation the table does not declare is refused.

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
| **Application** | `cyfr_pk_` | Frontend apps, client-side code | Safe to embed in browser code. Can execute and search, but cannot read the vault or perform admin operations by default. |
| **Service** | `cyfr_sk_` | Backend services | Never expose client-side. Keep in environment variables. Can read the vault. |
| **Admin** | `cyfr_ak_` | CI/CD, automation, infrastructure | Use with IP allowlist. Every permission, including key management. A person's interactive acts — vault writes, consent grants, defining or changing an MCP server, pushing a component, changing a registry namespace, its tokens or members, accepting the registry's policies, filing a report or an appeal — take a signed-in session instead. |

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
# Application key (frontend) — defaults to execute, component_read, storage_read
cyfr key create --name "react-app" --type application

# Service key (backend) — defaults to execute, vault_read, component_read, storage_read/write
cyfr key create --name "node-backend" --type service

# Service key with extra scope
cyfr key create --name "node-backend-rw" --type service --scope "vault_read,component_manage"

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
  "scope": ["execute", "component_read", "storage_read"],
  "created_at": "2025-02-13T..."
}
```

### Available Scopes

Scopes control what operations an API key can perform. Each scope maps to a category of actions:

| Scope | What It Allows |
|-------|----------------|
| `execute` | Run components, manage schedules, compile builds |
| `vault_read` | Read stored credential metadata (vault entries; material never leaves the vault) |
| `component_read` | Get component blobs, discover components |
| `component_manage` | Pull, push, register, remove, scaffold components |
| `storage_read` | View execution records, MCP logs, enforcement logs, retention config |
| `storage_write` | Set retention policies |
| `admin` | API key management, retention cleanup, session operations, force-release, operating saved MCP servers (get, test, refresh, restart, enable, disable, delete) |
| `*` | Wildcard — all permissions |

#### Key Type Defaults and Ceilings

Each key type has default scopes (applied when none are specified) and a ceiling (the maximum scopes it can be granted):

| Type | Default Scopes | Allowed Scopes (Ceiling) |
|------|---------------|--------------------------|
| **Application** | `["execute", "component_read", "storage_read"]` | `["execute", "vault_read", "component_read", "storage_read"]` |
| **Service** | `["execute", "vault_read", "component_read", "storage_read", "storage_write"]` | `["execute", "vault_read", "component_read", "component_manage", "storage_read", "storage_write"]` |
| **Admin** | `["*"]` (all) | `["vault_read", "admin", "*"]` |

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

## API Keys vs the Vault

Two different credential types serve two different purposes: API keys authenticate your **app** to **CYFR**; **vault entries** hold the credentials **components** use to reach third-party APIs. A vault entry is bound to a component through a consent revision — the component names a *role* (a manifest `need`), the operator picks which entry satisfies it, and the component only ever sees the projected fields, never the entry itself.

| | API Keys | Vault entries (`api_key` / `bundle`) | Vault entries (`oauth`) |
|---|----------|-----------------------------------|----------------------|
| **Purpose** | Authenticate your **app** to **CYFR** | Authenticate **components** to **service APIs** | Authenticate **components** to **user-scoped APIs** |
| **Example** | `cyfr_sk_...` in your backend's env | `STRIPE_API_KEY=sk-live-...` | Google/Slack grants |
| **Who uses it** | Your app (in the `Authorization` header) | WASM components (via `cyfr:vault/read`) | WASM components (via `cyfr:oauth/token`) |
| **Stored where** | Your app's environment | CYFR's vault (sealed, encrypted at rest) | CYFR's vault (sealed, encrypted at rest) |
| **Managed by** | `cyfr key create/revoke/rotate` | `vault` verbs + console Vault page; bound via `cyfr profile grant` | `vault.authorize` (browser grant) + `oauth.set_client` (provider app creds); bound via `cyfr profile grant` |
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
                                 the vault entry bound to the
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
      "io.modelcontextprotocol/serverInfo": {"name": "CYFR", "version": "<release>"}
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

**CYFR error codes.** This is the whole set — every code the server can put
on the wire.

| Code | Name | Meaning |
|------|------|---------|
| -33001 | `auth_required` | Not authenticated — tool requires login (see [Public Tools](#public-tools-no-auth-required) for exceptions) |
| -33002 | `auth_invalid` | Invalid API key or token |
| -33004 | `insufficient_permissions` | Key scope doesn't cover this action, the caller is not a platform admin, or the IP is not in the allowlist |
| -33100 | `internal` | The call failed for a reason the server could not confirm — check before retrying |
| -33101 | `conflict` | The state moved on — read it again and retry |
| -33102 | `not_owner` | This server does not currently own its control plane — retry shortly |
| -33103 | `unavailable` | A service the call needs could not answer — retry shortly |
| -33104 | `corrupt` | Stored data does not match what was recorded; retrying will not help |
| -33105 | `timeout` | The call timed out |
| -33106 | `uncertain` | The call may or may not have taken effect — check before retrying |
| -33304 | `rate_limited` | Too many requests — back off and retry. Honour `Retry-After` when present |
| -33305 | `request_cancelled` | The call was cancelled |
| -33501 | `setup_required` | A dependency needs configuring before this can run ([Readiness and typed errors](#readiness-and-typed-errors)) |
| -33502 | `consent_required` | The caller has no consent for this component |
| -33503 | `consent_conflict` | Consent exists but does not cover what was asked |
| -33504 | `restart_required` | Consent changed under a running execution |
| -33505 | `confirmation_required` | A sensitive change waits for the person's fresh confirmation and nothing was changed; `error.data.payload.id` is the asking client's own secret for this request — keep it, and never log or show it. The person confirms it with a fresh proof; `confirmation/pending` lists the pending confirmation by its ref, never by that id, and names the client that asked. Once it is confirmed, repeat the same `tools/call` with `params._meta["cyfr/confirmationId"]` set to that id, never as an argument: a repeat before the proof answers the same id and changes nothing, and a value not spelled `cnf_` and 43 base64url characters is refused `-32602` at HTTP 400 ([Readiness and typed errors](#readiness-and-typed-errors)) |

`-33304` is the one to branch on for backoff; the `-335xx` band is the
consent signals, whose `error.data` payload is described under
[Readiness and typed errors](#readiness-and-typed-errors). The `-331xx`
band answers a `resources/read` by the class of its refusal; a store that
cannot answer is `-33103`, never a missing resource.

Everything else a tool refuses arrives as a **successful** JSON-RPC response
whose `result.isError` is `true` and whose content carries the sentence —
including a component that does not resolve, a registry that is unreachable,
and a failed validation. Branch on `result.isError` for those, not on a code.

Two protocol-level codes are also in play, both standard JSON-RPC:
`-32601` for an unknown method and `-32022` (`UnsupportedProtocolVersion`),
which carries the supported list in `error.data`.

> **MCP Tool Reference**: For a complete mapping of CLI commands to MCP tool/action pairs (useful when building HTTP integrations), see [CLI → MCP Tool Reference](component-guide.md#cli--mcp-tool-reference) in the Component Guide.

### Public Tools (No Auth Required)

Almost every tool call requires authentication. An uncredentialed caller
reaches exactly the actions annotated `auth: :anonymous`, and no others —
the same set `tools/list` shows them, because discovery and dispatch read
one annotation. It is short:

| Tool | Actions | Why Public |
|------|---------|------------|
| `pairing` | `complete` | A new device holds neither a session nor a certificate: the short-lived, single-use pairing code a signed-in person's `pairing.begin` issued names the person and athanor, the device proves its key, and a session cookie the browser holds never chooses the person |
| `person` | `renew_certificate` | A device paired at another home renews the certificate this home issued it, holding no session here: it proves the device key the certification names over a single-use challenge this home issued, and only a certification still standing under the person's current keys is extended |
| `session` | `login`, `logout`, `whoami`, `device_init`, `device_poll`, `read_resource` | Needed to authenticate in the first place; `read_resource` tells a caller only its own identity and permissions |
| `system` | `status` | Health checks |
| `tincture` | `invoke_public` | A published tincture is public by definition: named by its public address (`athanor`, the URL's `@namespace` or group slug, with `publisher` and `tincture_name`), the call runs one of its declared dependencies under its active public profile, as its public page does; the address confers no authority, and one with no active public profile answers `not_found` |

That is the whole list, and it does **not** widen on a server without an
auth provider: a request with no credential is an unauthenticated context
either way. In particular `component.search`/`inspect`/`categories`,
`aqua.list`/`get`, and the `registry` identity actions all need a session
or an API key, and `session.use` — switching which athanor you work in —
needs one too, since there has to be a session to switch.

MCP resources follow the same rule. `resources/list` and
`resources/templates/list` are open metadata, but a `resources/read` is
admitted by the one operation that declares the URI's scheme, through the
same gate as a tool call: `compendium://` by `component.read_resource`
(`component_read`), `crucible://` by `execution.read_resource` and `arca://` by
`resource.read` (both `storage_read`), and `sanctum://identity` and
`sanctum://permissions` by `session.read_resource`, the one resource read an
uncredentialed caller may make. A read the gate refuses for authentication
or permission answers the same `-33001` or `-33004` a tool call gets; a
missing file answers the JSON-RPC `-32002` resource error; a malformed URI,
an unknown scheme or a path outside the caller's roots `-32602` (invalid
params); and any other refusal the code of its class in the table above.

A second tier sits between public and fully authenticated: actions
annotated `auth: :signed_in` serve a caller holding a live session that
has not yet claimed a namespace, which is how the first-login flow
(`registry.probe`, `registry.claim_personal`) completes. Those are not
public — they need the session — but they do not need a claimed identity.

Everything else — `execution.*`, `build.*`, `schedule.*`, `vault.*`, `oauth.*`, `key.*`, `webhook.*`, `profile.*`, `record.*`, `mcp_log.*`, `policy_log.*`, `decision.*`, `retention.*`, `component.register`, `component.push`, `component.pull`, `component.create`, `component.delete`, `component.get_blob`, `component.discover`, `component.read_resource`, `resource.read`, `system.notify` — returns error code `-33001` (`auth_required`) if the session is not authenticated.

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
data/athanors/{athanor_id}/components/
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

Events use standard SSE format with `event:` set to the event type. An execution's lifecycle (`execution.started`, `execution.completed`, `execution.failed`, `execution.cancelled`, `execution.lapsed`, `execution.result_lost`) is durable — each is a numbered row, and its `id` is that number. What a formula streams while it runs (`emit`) is a delta under the last durable event: its `id` is `<durable>.<n>`, and deltas are not replayed after a server restart.

```
id: 1
event: execution.started
data: {"attempt":"att_...","reference":"formula:local.agent:0.4.0"}

id: 1.1
event: emit
data: {"kind":"turn_start","turn":1}

id: 1.2
event: emit
data: {"kind":"text_delta","content":"Here's my approach...","turn":1}

id: 2
event: execution.completed
data: {"status":"completed","duration_ms":15234}
```

The endpoint supports `Last-Event-ID` for reconnection — either form of id — and sends keep-alive comments every 15 seconds. Durable events are delivered in the order they were numbered, whatever order they were published in. The connection closes on the terminal lifecycle event.

**Setup required events (during streaming):**

When a formula invokes a sub-component whose consent isn't satisfiable — a need with no live vault entry bound, or a shape that drifted past its approved consent — the system automatically emits a `setup_required` event with machine-readable fix instructions:

```
id: 1.5
event: emit
data: {"kind":"setup_required","component_ref":"catalyst:local.stripe:0.1.0","profile_id":"prf_...","issues":[{"type":"unbound_need","need":"api_key","message":"The need \"api_key\" has no live credential bound","fix":{"tool":"profile","action":"plan","args":{"ref":"catalyst:local.stripe:0.1.0"}}}],"setup_command":"cyfr profile grant catalyst:local.stripe:0.1.0","message":"This app needs a vault entry for \"api_key\""}
```

Each issue's `fix` object contains the MCP tool, action, and args to start the consent walk. Frontends can use these to render one-click fix buttons; `setup_command` provides the CLI alternative. A drifted consent surfaces the same way with issue type `consent_required` ("permissions changed since you approved them"). The formula still fails — the event is informational so consumers can act on it.

**Checking readiness up front** — `component.setup_plan` answers "can this run?" from the consent. Its `consent` section carries the profile (`profile_id`, `revision`, `scope`) and one row per need — `satisfied` plus a human-readable `detail` ("bound to my-anthropic-key", "no vault entry bound for 'api_key' — grant one to continue", "was rebound since this consent — re-approve to continue"). Top-level `ready` is true only when the profile is active and every need is bound to a live, digest-matching vault entry.

### Scheduling Recurring Executions

CYFR supports cron-based scheduling for recurring component execution. Create schedules via the MCP `schedule` tool or the `cyfr schedule` CLI commands. Bind each schedule to a consented execution profile using `profile_id` (MCP) or `--profile` (CLI); `cyfr profile list` shows available profile IDs.

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
      "profile_id": "prf_...",
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
cyfr schedule create --profile <profile_id> --name daily-report --cron "0 9 * * *" --ref "formula:local.report:1.0.0"
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
cyfr log get <call_id>                     # Full details for a specific log entry
cyfr log correlate <request_id>            # Find related log entries and decisions
```

Every call the server admitted or refused is also recorded once as an admission decision under its call ID, with how the admitted work ended — whichever route it arrived by: `/mcp`, a tincture's routes, a webhook, an execution's event stream, a schedule's fire, or a running component's call to a tool, and a refusal made before the gate (an unknown tool, a bad credential, a rate limit) as much as one the gate makes. Recording never changes a call's outcome: a decision the server could not write is counted (the `cyfr_grimoire_decision_lost_total` metric), never retried, and a decision with no recorded end has an unknown outcome, not a success. Inspect decisions via the `decision` tool or `cyfr decision` CLI commands; a platform admin reads every athanor's decisions and the host's own with `--global`:

```bash
cyfr decision list --admission refused     # Recent refusals
cyfr decision get <call_id>                # One decision
cyfr decision correlate <request_id>       # A request's decisions, logs and executions
cyfr decision list --global --athanor none # The host's own decisions (platform admins)
```

### Concrete Example: User Management

A complete walkthrough of building user CRUD operations on CYFR.

#### 1. Supabase Catalyst (`c:local.supabase:0.2.0`)

Handles all database operations via Supabase's REST API.

**Setup:**

```bash
# Create the catalyst project (if starting fresh)
cyfr new catalyst supabase --version 0.2.0

# Grant it: pick a vault entry for each need, approve the capability ask
cyfr profile grant c:local.supabase
```

Create the vault entry first (console Vault page, or `vault.create` with fields `SUPABASE_URL` + `SUPABASE_SERVICE_KEY`, a `destination` naming your project's host, and `disclose: true`, since the catalyst reads the fields itself). If you own the Supabase project, you can skip the vault entry entirely and pass the URL and anon key as call arguments — the sealed path is for values that must not appear in logs.

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
| **CYFR-managed** | Vault entries, consents, audit logs, API keys, sessions | CYFR |
| **Your external DB** (Supabase, Neon, PlanetScale, …) | Users, orders, products — your domain data | Your Catalysts |

Your application data stays in the external database. Tinctures invoke backend components via `cyfr.invoke()` — the component fetches from your real data source and returns results. If you stop using CYFR tomorrow, your data is still in your database where it always was. CYFR governs *access* to your data, it doesn't *store* your data.

---

## Granting Components: Vault Entries & Consent

Before a component can run, an operator grants it: which **vault entries** satisfy its manifest `needs`, and how much of its `caps` ask to approve. Nothing auto-applies — the manifest is an ask, and a human commits every grant. The interactive paths are `cyfr profile grant <ref>` and the console's Vault page; everything below is the same flow over MCP.

`cyfr register` scans and registers local components, auto-pulling any missing published dependencies. Grant each component afterwards — a catalyst with nothing granted is rejected with a `POLICY_REQUIRED` / `setup_required` error. Reagents need no grant.

### The vault (`vault` tool)

A vault entry holds credential material — sealed at rest, never returned by any API. Material flows one way: `create` and `rotate` accept field values; nothing ever returns them.

| Action | Key args | What it does |
|--------|----------|--------------|
| `list` | — | Enumerate entries (names, status, destination and disclosure, never material) and the athanor's default per provider |
| `status` | — | Each living entry's name, kind, status, created and updated times and whether a consent binds it — never material or a field; on both planes, under no consent class, so a tincture that declares it and an in-chain call may read it |
| `create` | `name`, `kind` (`api_key` \| `oauth` \| `bundle`), `fields`, `destination` (+ `disclose`) | Mint an entry with sealed material, bound to where it may go |
| `rename` | `id`, `name` | Relabel an entry — a label is unique among the athanor's living entries |
| `rotate` | `id`, `fields`, `expected_payload_rev` | Replace material, same field schema — CAS-guarded, **no re-consent needed** |
| `rebind` | `id` + binding fields (`field_names`, `destination`, `disclose`) | Change what the credential *talks to* — dependent consents stop being ready until re-approved. Scopes change only by re-authorizing; endpoints never change |
| `authorize` | `id` (re-auth, + `oauth_scopes`) or `name` + `provider_hint` + `destination` (+ `oauth_scopes`, `oauth_endpoints`, `disclose`) | Start a browser OAuth grant; the callback completes it into the entry |
| `revoke` | `id` | Kill the material; dependent profiles report not-ready |
| `delete` | `id` | Remove the entry |

**Every entry names its destination.** `destination` is required at `create` and at a new entry's `authorize`, and there is no default: `hosts` (exact names, or `*.` and a name), and optionally `scheme` (`https` unless `http` is stated), `port`, `methods` and `paths` (prefixes beginning with `/`). An entry is attach-only unless `disclose` is `true`: its value is never handed to a component, and a component asking for it (`cyfr:vault/read`, `cyfr:oauth/token`) is refused. Set `disclose: true` only for a component that must read the values itself. Both are binding fields, so moving either is a `rebind`. An external MCP server definition is refused, at create, at update and again when it connects, when a header names an entry whose destination does not cover its URL, or when a stdio backend's environment names an attach-only entry; nothing is unsealed first.

```json
{
  "jsonrpc": "2.0", "id": 1, "method": "tools/call",
  "params": {
    "name": "vault",
    "arguments": {
      "action": "create",
      "name": "stripe-live",
      "kind": "api_key",
      "fields": {"STRIPE_API_KEY": "sk-live-..."},
      "destination": {"hosts": ["api.stripe.com"]}
    }
  }
}
```

Vault mutations require an interactive session — components, tincture frames and guest-plane callers can never reach these verbs; `list` needs a surface that could finish a consent walk. A tincture never takes a secret itself: `cyfr.credential(name)` has the shell prompt the person, and the shell's prompt makes the `create`.

**OAuth is entry-keyed, not component-keyed.** Provider endpoints live on the vault entry (`google` is a built-in preset), and your OAuth app's client credentials are set once per provider with `oauth.set_client` (`provider`, `client_id`, `client_secret`) — operator configuration, not a manifest concern. The component only declares a need of type `oauth:<provider>` with the scopes it requires; at runtime it calls `get_access_token("<provider>")` and receives short-lived, auto-refreshed tokens.

### Instance entries (`instance_entry` tool)

An instance entry is a credential the platform admin enters once for the whole instance and offers to the people on it, owned by no athanor. It is always attach-only, and its destination names its `methods` and `paths` as well as its hosts. Every action but `offered` is a platform admin's, from an interactive session; `offered` is any signed-in person's read of what they may use.

| Action | Key args | What it does |
|--------|----------|--------------|
| `create` | `name`, `kind` (`api_key` \| `oauth` \| `bundle`), `fields`, `destination` (with `methods` and `paths`), `audience` (`everyone` \| `listed`, + `members`), optional `component_policy` (`any` \| `shipped`, `any` when omitted), `person_daily`, `total_daily` | Seal the material and offer it — needs a fresh confirmation |
| `rotate` | `entry_id`, `fields`, `expected_payload_rev` | Replace material, same field schema, CAS-guarded — needs a fresh confirmation |
| `rebind` | `entry_id`, `destination` | Move where it may go — every profile that binds it, in every athanor, stops being ready until re-approved |
| `set_audience` | `entry_id`, `audience`, `members` | Who it is offered to — widening (to `everyone`, or adding a person) needs a fresh confirmation; narrowing the session alone |
| `set_component_policy` | `entry_id`, `component_policy` | `shipped` admits only an unmodified shipped component; `shipped` to `any` needs a fresh confirmation, `any` to `shipped` the session alone |
| `set_caps` | `entry_id`, `person_daily`, `total_daily` | The day's request caps, at least one named; `null` takes the platform default, `0` admits no use, an omitted cap keeps its value |
| `revoke` | `entry_id` | Refuse its next use; every profile that binds it stops being ready |
| `delete` | `entry_id` | Erase the material; every profile that binds it stops being ready |
| `list` | — | Every living entry with its audience, policy and caps, never material |
| `usage` | `entry_id`, `days` (1–35) | Requests by person and day, and the day totals |
| `offered` | — | The active entries offered to you: provider, destination and component policy |

A change that widens is decided against what is stored, and written only while it still is: an audience or a policy that moved in between answers a conflict with nothing written; read it again and ask anew. Use is counted in requests at each attach, under the entry's own caps or, when unset, the `instance_entry_person_daily` and `instance_entry_total_daily` platform settings; a request past a cap is refused until the next UTC day.

### The consent walk (`profile` tool)

Granting is a three-step walk — nothing is granted outside it:

```
plan     {ref}                            → the component's needs + caps ask as
                                            preview rows, candidate vault
                                            entries, a plan_token
preview  {decisions, plan_token}          → the grant as typed rows, the origins
                                            it admits, commit_digest
commit   {decisions, plan_token, proof,
          commit_digest,
          expected_consent_revision}      → an immutable consent revision
```

`preview` exists so the approval proof binds the exact commit digest that was rendered — a decision changed after approval cannot ride on the old approval. `commit` CAS-checks the head revision, so concurrent grants conflict instead of clobbering. Decisions carry the bindings (`[{need, entry_id, fields, scopes}]`), the scope (`versionless` covers every release of the line — the default; `pinned` names one), a `subset` that narrows the ask per node and resource kind (exact domains, methods, schemes, private ranges, storage paths and actions, tools, and limits under the ask and the ceiling; a superset is refused), and the `origins` the grant admits.

**The preview is typed rows.** It answers `v`, `rows`, `origins` and `commit_digest` (the `Prima.ConsentPreview` document, whose shape `tests/fixtures/consent_preview.json` pins), beside the `proof` and `expected_consent_revision` a commit presents. Each row is one resource an edge of the grant gives — a credential and its projection, egress, storage, tools, tool servers, limits, and for a tincture its frame capabilities, placement, background permission, streams, cards and system actions — with the node it belongs to and whether a decision narrowed it. Render the rows yourself; there is no prose summary. Explanatory text, such as a need's reason, is shown but not bound, so rewording it invalidates no grant.

**Origins.** Every run carries the origin of the path that admitted it, whatever credential it holds: `interactive` for Prism under a session or a paired device (a tincture's frame and a public tincture's page included), `programmatic` for the HTTP API and MCP, `schedule` for a schedule's fire, `webhook` for a webhook delivery. A child runs under its root's origin. A grant admits the origins its decisions name, and `interactive` alone when they name none; a run under an origin the grant does not name is refused with `consent_required`, so a script, an API key or a schedule runs a component only under a grant that names its origin. `cyfr profile grant <ref> --origin programmatic` names one at grant time; a re-grant keeps the origins the grant had unless `--origin` names others.

| Action | Key args | Returns |
|--------|----------|---------|
| `plan` | `ref` | needs, caps ask, candidate vault entries, `plan_token` |
| `preview` | `decisions` | `v`, `rows`, `origins`, `commit_digest`, `proof`, `expected_consent_revision` |
| `commit` | `decisions`, `plan_token`, `proof`, `commit_digest`, `expected_consent_revision` | the new consent revision |
| `grant` | `profile_id`, `bindings`, `expected_consent_revision` | the new consent revision — binds vault entries to needs on an active owner profile whose component has not changed shape, CAS-checked like `commit`; a moved shape needs the walk again |
| `publish` | `profile_id`, `need_ids`, `durable_storage` | a `plan_token` for `preview` and `commit` — stages a public profile from an owner profile, keeping credentials only for `need_ids` |
| `list` | `ref` | profiles + head revisions |
| `grants` | one of `domain`, `path`, `entry_id` | the athanor's active grants whose resources reach that egress domain, storage path or vault entry, read as the enforcement point admits them: wildcard domains included, a path by prefix, an entry by the revision's vault references, and a narrowed grant only as far as it was narrowed |
| `revoke` | `profile_id` | revoked — effective on the next run |

Interactive sessions and consent-capable API keys may commit; a key's consent capability comes from its own key row, never from the request.

**Which runs used a grant.** `execution.usage` with a `profile_id` lists the root runs that profile admitted, newest first (`limit`, 20 by default, at most 1,000), each with its origin, its root and its time. A revoked profile's runs still answer, as history; another athanor's profile, or an unknown one, is refused as not found.

### Readiness and typed errors

`component.setup_plan` answers "can this run?" before you invoke: its `consent` section lists the profile and one row per need (`satisfied` + a human-readable `detail`), and top-level `ready` is true only when the profile is active and every need is bound to a live, digest-matching vault entry.

Five typed errors cross every surface (MCP, HTTP, CLI, consoles) with normative payloads:

| Error | Payload | Meaning / next step |
|-------|---------|---------------------|
| `setup_required` | `{profile_id, node_ref, need, reason}` | Names the unbound need — grant a vault entry for it (`profile.plan` / `cyfr profile grant <ref>`) |
| `consent_required` | `{profile_id, current_revision, shape_diff}` | The grant does not cover this run: the component's ask changed since approval (the shape diff shows exactly what), the grant does not admit the run's origin, or it names a storage path spelled other than the storage door reaches it. Review and grant again |
| `consent_conflict` | `{expected_revision, actual_revision, cause}` | `stale_plan` → re-run plan; `digest_changed` → re-run preview; `race` → retry commit |
| `restart_required` | `{profile_id, new_revision, missing}` | A new revision landed under a running execution — restart to pick it up |
| `confirmation_required` | `{id, operation, expires_at}` | A sensitive change needs the person's fresh confirmation before `expires_at`; nothing was changed, and it is no denial. `id` is the asking client's own secret for this one request: keep it, and never log or show it. The person confirms it with a fresh proof; `confirmation/pending` lists the pending confirmation by its ref, derived one way from `id`, never by `id` itself, and names the client that asked. Over MCP the asking client then repeats the same `tools/call` with `params._meta["cyfr/confirmationId"]` set to `id`, which no request log records; a repeat before the proof answers the same `id` and opens nothing, and a repeat after it completes the change once. The CLI repeats for you on a terminal: it shows the ref and repeats each time you press Enter. A plain HTTP endpoint carries no repeat |

On the MCP wire each arrives as a protocol-level JSON-RPC error — codes `-33501` (`setup_required`), `-33502` (`consent_required`), `-33503` (`consent_conflict`), `-33504` (`restart_required`), `-33505` (`confirmation_required`) — with `error.data` carrying `{"tag": …, "payload": {…}}` and a one-line human summary in `error.message`. A plain HTTP endpoint answers the same `data` beside its `code` and `message`, `confirmation_required` at `428 Precondition Required`. Branch on the code (or `data.tag`); the payload is the table above.

### What a grant enforces

The committed consent is the runtime capability — `ask ∩ operator choices ∩ platform ceiling`, frozen at commit:

- **Domains** — exact (`"api.stripe.com"`) or wildcard (`"*.stripe.com"`); deny-by-default. Schemes default to https-only.
- **Private IPs** — all private/reserved ranges blocked (SSRF prevention) unless the ask carried `egress.private_ips` and the operator approved it. `169.254.0.0/16` (link-local / cloud metadata) is always blocked.
- **Addresses** — the engine resolves no name. CYFR resolves each outbound host and pins the address the engine connects to, under the execution's grant (`egress_pin`); `CYFR_PRIVATE_EGRESS_TARGETS` is CYFR's own and never applies to a component. The engine follows no redirect: a component's next request to a `Location` is the redirect's next hop, pinned from the request it came from, and a hop to another scheme or host is refused as `redirect_credentials`, so a request's credentials never cross origins.
- **Storage** — granted `storage.paths` (directory prefixes end with `/`, must start with `data/` or `components/`) and `storage.actions`; empty = hard deny. A path is spelled as the storage door reaches it: no empty segment (`data//secrets/`), no `.` or `..` segment, and a folder ends in exactly one `/`. A manifest spelling a path otherwise is refused when it is published, and a grant already stored under such a spelling is refused at every run until it is granted again; the server lists those grants at boot and tells each athanor that holds one.
- **Tools (formulas)** — granted patterns (`"execution.run"`, `"component.*"`, `"*"`) expand to the concrete action list at commit; a tool added to the platform later never widens an existing consent. Discovery via `{"tool": "tools", "action": "list"}`.
- **Limits** — `timeout`, `rate_limit`, sizes, `max_concurrent_tasks`; the manifest's suggestions as adjusted by the operator, capped by the ceiling. Defaults when unasked: catalyst `"3m"`, formula `"5m"`, reagent `"1m"`, rate limit `{"requests": 100, "window": "1m"}`, memory 64 MB, request 1 MB, response 5 MB.

---

## Inbound Webhooks

A webhook (`webhook` tool, or the console's Webhooks page) is a `POST /hooks/:slug` a sender signs with HMAC-SHA256. The signature is verified before anything else: an unknown or disabled slug answers 404, a missing or wrong signature 401, and a webhook store that cannot answer 503. A webhook configured with an idempotency key header (GitHub's `X-GitHub-Delivery`, a Stripe event id) runs each delivery once: a request without the header answers 400, a key already seen answers 200 `{"status": "duplicate", "first_seen_at": "..."}` without running the target again, and when the replay store cannot answer the claim the delivery answers 503 `unavailable` and runs nothing, since without the claim nothing proves the delivery has not already run. A delivery that ends non-2xx gives its claim back, so the sender's retry runs as a fresh delivery.

---

## Tincture Routes

Tinctures are browser frontends the Prism shell opens in a sandboxed frame; the [Tincture Guide](tincture-guide.md) is their full reference. Their routes on the one endpoint:

| Route | Serves |
|-------|--------|
| `GET /t/:athanor/:publisher/:tincture_name` and `…/*path` | A public tincture's entry page and files, to anyone. A tincture is public when it has an active public consent profile: publish one with `profile.publish`, revoke it with `profile.revoke`, and read the current answer with `tincture_visibility.get` |
| `GET /_s/:credential/:publisher/:name/:version/*file` | A private tincture version's files, under the asset credential the shell mints for a person; the credential is verified on every request and opens that version's files alone |
| `POST /_f/v1/invoke`, `/_f/v1/action`, `/_f/v1/stream` | A frame's data requests, made by the SDK with the frame's per-open credential as a bearer, or by a public tincture's page naming itself; each is admitted against the tincture's declaration and recorded like any other call |

A path under `/_s/` carries a credential: no proxy in front of CYFR may log `/_s/` paths (the shipped `Caddyfile` keeps no access log). Every tincture response carries `Referrer-Policy: no-referrer`; each HTML page carries the Content Security Policy derived from the tincture's declaration. The guide lists the headers, the frame's policy and the wire's shapes.

---

## Tincture Data

Tinctures don't have their own database. They get data two ways:

- **Live data** — call your backend components from the browser with `cyfr.invoke()` (see the SDK in the [Tincture Guide](tincture-guide.md)). The component fetches from your real data source server-side and returns the result; credentials and consent are enforced for you.
- **Static seed data** — ship a JSON file (or any served type) as a static asset in the tincture and read it client-side. It's just another shipped file; CYFR serves it like any other asset.

A typical live-data pipeline:

```
1. Catalyst (yfinance)        → fetches stock data from a market API
2. Formula  (stock-feed)      → calls the catalyst, aggregates results
3. Tincture (stock-dashboard) → cyfr.invoke("f:local.stock-feed", "quote", {symbol: "AAPL"})
                                 receives data, renders the chart in the browser
```

---

## Configuration

Every variable the `cyfr` server reads and every platform setting, each
with what it sets and its default, is in
[configuration-guide.md](configuration-guide.md), rendered from the
server's settings roster; this guide does not repeat them. `.env.example`
is the starting `.env`, and the execution worker's and the Locus
services' own settings are in `.env.opus.example` and
`.env.locus.example`. What follows is what an integrator needs beyond
the values themselves.

### Platform admins

CYFR is one product: deploy it as-is (sqlite, local FS) or configure OIDC /
Postgres / a custom registry. There is no separate "edition" or "mode".

Once authentication is configured, two lists do two jobs. `CYFR_PLATFORM_ADMIN_EMAILS`
names the server's operators (platform admins): always let in, minted their
own athanor past the server caps, and able to run the operator verbs
(`door.*`, `instance_entry.*` but `offered`, `execution.force_release`,
`athanor.purge`, `athanor.destroy`).
The capability is over the instance, not a seat: an operator works inside one
athanor at a time like everyone else, and only in one they are a member of.
They enter no other athanor — opening one they hold no seat in is refused like
anyone's, and a session that names one they have left falls back to their own
— and there is no cross-athanor reach. The **server allowlist** (the door — `cyfr admin allow
<email|user_id|identifier|*>`, `cyfr admin deny …`, or the Settings page) is who else may
sign in at all: a match on first sign-in lets them in, no match is a 403, and
`*` lets in anyone the configured provider authenticates. Groups never open the
door: adding an unknown email to a group leaves an invitation that activates on
that person's first admitted sign-in and, when the door would refuse them, a
request for the operator.

### Reclaiming an archived athanor's storage

Archiving an athanor revokes its keys and cancels its running work but
deliberately leaves its storage tree (`data/athanors/<id>/`) in place, so
`athanor.unarchive` reopens the furnace intact; a member unarchives a group,
and allowing a denied person at the door reopens their own athanor. When the
bytes should actually be reclaimed, a platform admin runs `athanor.purge`
(the `athanor` tool) naming the archived athanor: it deletes the whole tree —
blobs only, rows remain — and is final. `athanor.destroy` deletes the rows
too, leaving only the archived tombstone, and refuses a person's own athanor.
Both are platform-scope operations: they need no seat in the athanor, never
read the one in focus, and open nothing in it. An operator with no seat may
read an archived athanor's public facts with `athanor.get` (its id, name,
status and when it was archived) and nothing it holds; `athanor.unarchive`
and every other verb refuse them like any non-member. A purged athanor that
is later unarchived comes back with empty storage. A group whose members were
all denied keeps no member to unarchive it — allowing them again at the door
reopens only their own athanors — so it can be purged or destroyed, and
reopened by no one.

With no auth configured, the deployment runs without sign-in: requests reach the
public read-only surface as an unauthenticated context, and tenant-scoped
operations are rejected.

### OIDC (federated identity)

Set `CYFR_AUTH_PROVIDER=oidc` to federate against a generic OIDC issuer. All
three variables are required when oidc is selected — the server refuses to boot
otherwise rather than silently degrading to no authentication. The issuer must
not be `github.com`/`accounts.google.com` (use GitHub/Google OAuth directly).

### Several members on one database (a cell)

One server per database is the default: a second one pointed at the same
database refuses to boot. A **cell** is several control-plane members
sharing one database, one object store and one set of workers, each
holding its own slot and taking a peer's work only after that peer's
lease has run out on the database's clock. `CYFR_CLUSTER=1` turns it on,
and it boots only with Postgres, `CYFR_STORAGE=s3`, TLS distribution,
`CYFR_CELL_COOKIE`, a discovery topology, a shared `CYFR_OPUS_KEY` and
this member's own `CYFR_HOST_API_URL`; each missing one is a named
refusal at boot, and the configuration guide says what each one sets.

Distribution must be TLS: start every member with `-proto_dist inet_tls`
and an `-ssl_dist_optfile` naming its certificate, key and CA. A cell of
control planes on plain distribution is an unauthenticated remote shell
onto the database.

What a cell changes for a client and an operator:

- **Nothing is routed by the client.** A turn runs on the member that
  accepted it and an execution on the member that admitted it. Put the
  members behind any load balancer; ownership is settled by rows.
- **A member's lease is 15 s, renewed every 5 s**, so an unclean stop is
  taken over within 20 s and a clean one at once. An execution whose
  member died is settled by the attempt lease (180 s) and the sweeper.
- **Every member names its own address.** `CYFR_HOST_API_URL` is the
  address a worker service reaches *this* member's host API at, and a
  cell refuses to boot without it. Every assignment a member issues
  carries that address and that member's boot, and a worker posts an
  attempt's host calls and its runner's exit report there, naming that
  member in every header. A member that is not the one named refuses the
  call, a lease renewal included, so one worker service can serve several
  members and a misrouted call is lost loudly rather than answered for
  work the member does not hold. Each member still lists the workers it
  dispatches to in its own `CYFR_OPUS_WORKERS`.
- **Stdio MCP servers are not available** in a cell.
- **Per-member ceilings multiply.** `CYFR_CRUCIBLE_MAX_CONCURRENT`,
  `CYFR_CRUCIBLE_MAX_CONCURRENT_PER_TENANT` and the per-credential
  stream cap on `execution.subscribe` and `notifications/listen` are each
  member's, so N members admit N times each. The tenant's durable
  ceilings are rows and hold for the cell: its consented invocation rate,
  its budget reservations and charges, and its storage cap.
- **Ingress rate limits are each member's too.** The ceiling that sees
  the whole cell is the reverse proxy's; set it there.

### Execution workers

Components run on worker services CYFR reaches over HTTP (the `opus`
compose service). `cyfr init` mints the root into `.env` and derives the
`opus` service's key from it. Compose hands the worker its id, its key and
the host API's URL from `.env`; `.env.opus.example` documents the worker's
own settings, and [Running a worker outside
Compose](#running-a-worker-outside-compose) what compose sets for it.

CYFR and its workers speak one versioned wire. Every body and answer
carries `"v": 1` as its first member and every `x-cyfr-auth` header begins
with the version token `v1`; a header at another version is refused
`unknown_version` before its body is read, and a body without `v` or at
another version is refused `unknown_version` before its operation is read,
so a worker and a CYFR at different versions refuse each other's work
rather than misread it. The engine resolves no name: a run's outbound
address is the one CYFR pins for it under the run's grant (see [What a
grant enforces](#what-a-grant-enforces)).

### Builds

Components and tinctures are built on the Locus builds service (the
`locus-builds` compose service), which CYFR reaches over a signed wire.
Builds are on after `cyfr init`, which writes the compose service's URL and
mints the key into `.env`. Set both variables or neither: with neither,
CYFR builds nothing and refuses every build; with one, or a malformed
value, it refuses to boot. `.env.locus.example` documents the builder's own
`LOCUS_BUILDS_*` side.

### Stdio MCP servers

Stdio MCP servers run on the Locus backends service (the `locus-backends`
compose service), which CYFR reaches over a signed wire; every compose
deploy starts it. Each backend runs under a pooled uid of its own, started
by `cyfr-keeper`, with a private home, an environment built only from its
server's definition and a memory bound of its own; the service keeps no
state, and CYFR sends each server's definition again when the service
restarts. With the URL or the key unset CYFR refuses stdio servers; with a
malformed value it refuses to boot. Stdio servers are not available in a
cell. `.env.locus.example` documents the service's own `LOCUS_BACKENDS_*`
side.

### Running a worker outside Compose

The `cyfr-opus` and `cyfr-locus` images also run without the shipped
`docker-compose.yml`: on another container platform, or on a host of their own.
Each release reads its settings from its own environment alone, so it is
given what compose's `environment:` gives its service besides the settings
of its own env example (`.env.opus.example`, `.env.locus.example`), and the
hardening the compose file gives the service: `cap_drop`, `cap_add`,
`security_opt`, `init`, the read-only root and its tmpfs mounts.

The execution worker takes `OPUS_SERVICE_ID`, `OPUS_SERVICE_KEY` and
`OPUS_HOST_URL` as `.env.example` documents them, and the two below, which
compose fixes for its container. CYFR lists the worker in `CYFR_OPUS_WORKERS`
under its service id at the URL of this listener, and binds
`CYFR_HOST_API_BIND` to an address the worker reaches at `OPUS_HOST_URL`
— or, where several members share the worker, at each member's own
`CYFR_HOST_API_URL`.

| Variable | Default | Description |
|----------|---------|-------------|
| `OPUS_BIND` | `127.0.0.1` | The address the worker's listener binds, one CYFR reaches. Compose binds every interface, since the container is attached to the worker network alone |
| `OPUS_PORT` | `4200` | The port the worker's listener binds (compose: `4200`) |

The builds service takes the key compose passes it from `.env`'s
`CYFR_LOCUS_BUILDS_KEY`; CYFR's `CYFR_LOCUS_BUILDS_URL` names the service's
listener.

| Variable | Default | Description |
|----------|---------|-------------|
| `LOCUS_BUILDS_KEY` | — | The builds key, 64 hex digits: the same value as `CYFR_LOCUS_BUILDS_KEY`. Required: the builder refuses to start without it |

The backends service takes the key compose passes it from `.env`'s
`CYFR_LOCUS_BACKENDS_KEY`, and runs under the keeper's `backends` pool,
which compose's `entrypoint:` names (`cyfr-keeper serve --pool
backends:20001-20032 …`) in place of the image's build pool; CYFR's
`CYFR_LOCUS_BACKENDS_URL` names the service's listener.

| Variable | Default | Description |
|----------|---------|-------------|
| `LOCUS_BACKENDS_KEY` | — | The backends key, 64 hex digits: the same value as `CYFR_LOCUS_BACKENDS_KEY`. A node with neither this nor `LOCUS_BUILDS_KEY` refuses to start |

### Docker requirement

The `opus`, `locus-builds` and `locus-backends` containers hold every
runner, build and backend to a memory bound of its own, a cgroup
`cyfr-keeper` makes for it. That needs **Docker Engine 28 or later on a
cgroup v2 host** and the containers' `security_opt: writable-cgroups=true`,
which the shipped `docker-compose.yml` sets and which adds no capability.
Without it nothing runs unbounded and nothing runs: `opus` starts no runner
and logs, naming `writable-cgroups=true`, that it cannot bound one, so no
component runs; every build is refused as `unavailable`, naming the option;
and every backend reports the keeper's refusal as its error.

Docker marks a container `OOMKilled` whenever a runner, a build or a
backend is ended at its own bound, though neither the container nor its
release was touched. Read it as a runner, a build or a backend that passed
its bound (the service's log says which), not as the container running out
of memory.

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
#     Edit data/athanors/{athanor_id}/components/catalysts/local/my-api/0.1.0/src/src/lib.rs
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
- Components installed via `cyfr pull` are written into the athanor's component tree (`data/athanors/{athanor_id}/components/`) and indexed automatically

**Tinctures** — vanilla (no compile step) or React (requires build):

```
Vanilla:  cyfr new tincture <name>                    → edit HTML/JS/CSS → cyfr register → reload
React:    cyfr new tincture <name> --template react   → edit src/App.tsx → cyfr build compile → cyfr register
```

- `cyfr new tincture <name>` scaffolds vanilla HTML/JS/CSS (SDK is auto-injected at serve time)
- `cyfr new tincture <name> --template react` scaffolds a React + TypeScript + Vite project (requires `cyfr build compile` before registering)
- Built tinctures run `npm ci && vite build` via Locus, installing exactly what `package-lock.json` pins — output is static HTML/JS/CSS, no runtime dependency
- Tinctures invoke backend components via `cyfr.invoke()` — declare dependencies in manifest `dependencies.static`
- View at `localhost:4000` (Prism → Tinctures tab) or `/t/:athanor/:publisher/:name` if public

See the [Component Guide](component-guide.md) for the full development loop and component authoring details.
