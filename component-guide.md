# Component Guide

A practical guide for developers building WASM components for CYFR.

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

### Prerequisites

This guide assumes you've completed the Quick Start in the [README](README.md) — CYFR is installed, your project is initialized (`cyfr init`), and the server is running (`cyfr up`).

**To build WASM components (pick your language):**

| Tool | Install |
|------|---------|
| Rust + `cargo-component` | `rustup target add wasm32-wasip2` + `cargo install cargo-component` |
| TinyGo (optional) | `brew install tinygo` |
| `wasm-tools` | `cargo install wasm-tools` |

### Project Layout

After initialization, your project has:

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

### Storage Architecture

All components live in a single `components/` directory:

| Namespace | Purpose | Version control |
|-----------|---------|-----------------|
| `components/{type}s/local/` | Local development components | Checked in |
| `components/{type}s/agent/` | AI-agent-authored components | Checked in |
| `components/{type}s/{publisher}/` | Pulled/published components (OCI) | `.gitignored` |

**Registration flow** (`cyfr register`): scan `components/` for `local/` and `agent/` namespaces → validate WASM → index in SQLite → prune stale entries. No file copy — Opus reads directly from `components/`. Components registered this way get `source: "filesystem"`.

**Pull flow** (`cyfr pull`): download from OCI registry → write to `components/{type}s/{publisher}/...` → index in SQLite. Pulled components get `source: "published"`. No `cyfr register` needed.

**Pruning**: when a component is removed from `components/` and `cyfr register` runs, the pruning step removes: the SQLite metadata row, associated host policies, associated secret grants, and associated dependency records.

Opus reads WASM directly from `components/` via Arca.

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
| Async invoke (`spawn/await/await-all/await-any/poll/cancel`) | No | No | Yes |
| Call MCP tools (`cyfr:mcp/tools`) | No | No | Yes (optional) |
| Requires Host Policy | No | **Yes** (`allowed_domains`) | **If using MCP** (`allowed_tools`) |
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
- Parallel invocation of multiple sub-components via `spawn` + `await-all`

**Constraints**:
- Cannot perform I/O directly (no HTTP, no secrets)
- Invokes sub-components via `cyfr:formula/invoke` host function (`call` for sync, `spawn`/`await`/`await-all`/`await-any`/`poll`/`cancel` for async)
- All orchestration logic lives inside the WASM binary (loops, conditionals, branching)
- Opus intercepts each `invoke` call, executes the referenced component, and returns the result

**Interface**: `cyfr:formula/run`

**Imports**: `cyfr:formula/invoke@0.1.0` (`call`, `spawn`, `await`, `await-all`, `await-any`, `poll`, `cancel`)

---

## Component Lifecycle

```
Build → Validate → Register → Test → Publish → Pull → Setup → Execute
        Locus      Compendium  Opus   Compendium         Sanctum  Opus
```

| Stage | Command | Service |
|-------|---------|---------|
| **Build** | `cargo component build --release` | External |
| **Validate** | `build.validate` action | Locus |
| **Register** | `cyfr register` | Compendium |
| **Test** | `cyfr run <ref>` | Opus |
| **Publish** | `component.publish` | Compendium |
| **Pull** | `cyfr pull <ref>` → `components/` | Compendium |
| **Setup** | `cyfr setup` | Sanctum + Arca |
| **Execute** | `cyfr run <ref>` | Opus |

The manifest (`cyfr-manifest.json`) is present from Build onward — it travels through the entire lifecycle.

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

### Output Convention

All component types return a JSON string — Opus doesn't enforce a schema on the output. It records the return value verbatim in the execution record.

**Recommended convention** (used by all included components):

| Pattern | Format |
|---------|--------|
| Success | `{"data": {...}}` or `{"status": 200, "data": {...}}` |
| Error | `{"error": "message"}` or `{"error": {"type": "...", "message": "..."}}` |

If a Formula parses sub-component output, it should check for `.error` before using `.output`.

If the return string is not valid JSON, Opus wraps it as `{"raw": "<string>"}` — this is almost always a bug.

### Interface Packages

| Package | Interface | Signature | Used By | Description |
|---------|-----------|-----------|---------|-------------|
| `cyfr:reagent@0.1.0` | `compute` | `compute(input: string) -> string` | Reagent (export) | Pure computation |
| `cyfr:catalyst@0.1.0` | `run` | `run(input: string) -> string` | Catalyst (export) | I/O operation |
| `cyfr:formula@0.1.0` | `run` | `run(input: string) -> string` | Formula (export) | Orchestration |
| `cyfr:http@0.1.0` | `fetch` | `request(json-request: string) -> string` | Catalyst (import) | Synchronous HTTP |
| `cyfr:http@0.1.0` | `streaming` | `request/read/close` | Catalyst (import) | Polling-based streaming HTTP |
| `cyfr:secrets@0.1.0` | `read` | `get(name: string) -> result<string, string>` | Catalyst (import) | Secret retrieval |
| `cyfr:formula@0.1.0` | `invoke` | `call/spawn/await/await-all/await-any/poll/cancel` | Formula (import) | Sub-component invocation |
| `cyfr:mcp@0.1.0` | `tools` | `call(json-request: string) -> string` | Formula (import, optional) | Dynamic MCP tool access |

> The canonical `.wit` source files live in `wit/{reagent,catalyst,formula}/`. Always copy from there — they are the authoritative definitions.

### Catalyst Deps Layout

Catalysts require additional WIT dependency files under `wit/deps/`:

```
src/wit/
├── world.wit                      # cyfr:catalyst@0.1.0
└── deps/
    ├── cyfr-secrets/read.wit      # cyfr:secrets/read — get(name) -> result<string, string>
    └── cyfr-http/interfaces.wit   # cyfr:http/fetch + cyfr:http/streaming
```

---

## Component References

Components are identified by a single canonical string format:

```
type:namespace.name:version
```

| Segment | Description | Example |
|---------|-------------|---------|
| `type` | Component type (`catalyst`, `reagent`, `formula`, or shorthand `c`, `r`, `f`) | `catalyst` |
| `namespace` | Publisher / scope | `local`, `cyfr`, `acme` |
| `name` | Component name | `claude`, `sentiment-analyzer` |
| `version` | SemVer version (optional — see resolution behavior below) | `0.3.0` |

**Examples:**

| Reference | Meaning |
|-----------|---------|
| `catalyst:local.claude:0.3.0` | Claude catalyst, local namespace, version 0.3.0 |
| `reagent:cyfr.json-transform:1.0.0` | JSON transform reagent from cyfr namespace |
| `formula:local.list-models:0.3.0` | List-models formula, local namespace |
| `c:local.openai` | OpenAI catalyst (shorthand type, version resolved) |

When version is omitted, the CLI prompts you to select from available versions. In programmatic contexts (MCP, Formula invoke), the system resolves to the most recent registered version.

> **Dependency refs require exact versions**: `dependencies.static[].ref` does not support version ranges or omitted versions.

### Usage in Formula Invoke

When a Formula calls `cyfr:formula/invoke.call()`, the reference is a string in the JSON request:

```json
{
  "reference": "catalyst:local.my-api:0.1.0",
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

- **Policy isolation**: Each component ref gets its own `allowed_domains`, `rate_limit`, and `timeout` via `cyfr policy set <ref> <field> <value>`
- **Secret grants**: Secrets are granted per component ref — `cyfr secret grant c:local.gemini:0.1.0 API_KEY` only grants to that specific component
- **Rate limiting**: Rate limits are tracked per `{user_id, component_ref}` pair
- **Audit trail**: Every execution record includes the component ref for forensic analysis

### Version-Agnostic CLI Commands

When you omit the version from a component ref in CLI admin commands (`cyfr secret grant`, `cyfr policy set`, `cyfr setup`), the CLI automatically applies the operation to **all registered versions** of that component. The server always stores grants and policies per versioned ref — the CLI handles the convenience.

```bash
# Omit version → applies to all registered versions (0.1.0, 0.2.0, etc.)
cyfr secret grant c:local.claude API_KEY
cyfr policy set c:local.claude allowed_domains '["api.anthropic.com"]'

# Specify version → applies to that version only
cyfr secret grant c:local.claude:0.1.0 API_KEY
cyfr policy set c:local.claude:0.1.0 allowed_domains '["api.anthropic.com"]'
```

> **Note**: After registering, run `cyfr setup` to configure secrets, grants, and policies. It lets you choose which versions to apply to (all versions by default, or specific ones).

---

## Host Functions Reference

### `cyfr:http/fetch` — Synchronous HTTP

**Signature**: `request(json-request: string) -> string`

| Request Field | Type | Required | Description |
|---------------|------|----------|-------------|
| `method` | string | Yes | HTTP method (GET, POST, PUT, DELETE, PATCH) |
| `url` | string | Yes | Full URL |
| `headers` | object | No | Request headers |
| `body` | string | No | Request body (always a string — serialize JSON payloads first) |
| `body_encoding` | string | No | `"base64"` for binary data |
| `response_encoding` | string | No | `"base64"` to receive binary response |
| `multipart` | array | No | Multipart form fields (each: `name`, `value`/`data`, `filename`, `content_type`) |

**Success response**: `{"status": 200, "headers": {...}, "body": "..."}`

**Error response**: `{"error": {"type": "domain_blocked", "message": "..."}}`

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

**Protocol flow:**

```
1. WASM calls streaming.request(json)  ->  host returns {"handle": "abc123"}
2. WASM calls streaming.read("abc123") ->  host returns {"data": "chunk...", "done": false}
   ... (loop until done) ...
3. WASM calls streaming.read("abc123") ->  host returns {"data": "", "done": true}
4. WASM calls streaming.close("abc123") -> host returns {"ok": true}
```

Request format is the same as `cyfr:http/fetch`. All fetch error types also apply to `streaming.request`.

| Streaming Error Type | Cause |
|----------------------|-------|
| `stream_limit` | Exceeded max 3 concurrent streams per execution |
| `timeout` | Stream exceeded 60s timeout |
| `invalid_handle` | Unknown or already-closed stream handle |
| `response_too_large` | Cumulative streamed data exceeds policy `max_response_size` |

**Constraints**: Max **3 concurrent streams** per execution, **60s timeout** per stream, cumulative response size tracked, all streams auto-cleaned on execution completion.

**Example** (streaming request loop):

```rust
// 1. Open the stream
let handle_resp = streaming::request(&json!({
    "method": "POST",
    "url": "https://api.example.com/stream",
    "headers": {"Authorization": format!("Bearer {}", api_key)},
    "body": body.to_string()
}).to_string());
let handle_val: Value = serde_json::from_str(&handle_resp)?;
let handle = handle_val["handle"].as_str().unwrap();

// 2. Read chunks in a loop
let mut collected = String::new();
loop {
    let chunk: Value = serde_json::from_str(&streaming::read(handle))?;
    let done = chunk["done"].as_bool().unwrap_or(false);
    if let Some(data) = chunk["data"].as_str() {
        collected.push_str(data);
    }
    if done { break; }
}

// 3. Close the stream
streaming::close(handle);
```

See `components/catalysts/local/claude/0.2.0/src/src/lib.rs` for a production example with SSE parsing.

### `cyfr:secrets/read`

**Signature**: `get(name: string) -> result<string, string>`

Returns `ok(value)` on success, or `err("access-denied: {name}")` if the secret is not granted to this component.

### `cyfr:formula/invoke` — Sub-Component Invocation

**`call`** — synchronous, blocks until complete:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `reference` | string | Yes | Canonical ref (`type:namespace.name:version`) |
| `input` | object | Yes | JSON input for the sub-component |
| `type` | string | No | `"reagent"` (default), `"catalyst"`, or `"formula"` |

**Success**: `{"status": "completed", "output": {...}}`
**Error**: `{"error": {"type": "execution_failed", "message": "..."}}`

| Invoke Error Type | Cause |
|-------------------|-------|
| `invalid_json` | Request string is not valid JSON |
| `invalid_request` | Missing `reference` (string) or `input` (map) |
| `invalid_type` | `type` field is not `reagent`, `catalyst`, or `formula` |
| `execution_failed` | Sub-component execution failed (timeout, panic, policy violation, etc.) |
| `resource_limit` | Maximum concurrent tasks exceeded (policy `max_concurrent_tasks`) |
| `timeout` | Task or batch exceeded timeout (policy `batch_timeout`) |

**Async error handling notes:**

- **`spawn` can fail** — always check for the `"error"` key before reading `"task_id"`. The most common failure is hitting `max_concurrent_tasks`.
- **`await-all` returns mixed results** — each element in the `results` array has its own `status`. Some may be `"completed"` while others are `"error"`. Always check per-result rather than assuming all succeeded.
- **`await-any` returns on *any* completion, not only success** — a task that errors counts as "finished" and can be the winner. Check `result.status` before using the output.
- **Result ordering** — `await-all` results are ordered to match the input `task_ids` array. You can zip them with your original provider list to map results back (see the parallel invocation example below).

### Async Invocation (spawn / await / await-all / await-any / poll / cancel)

For Formulas that need to invoke multiple independent sub-components concurrently. WASM stays single-threaded — parallelism runs on the Elixir host via the AsyncTracker.

**`spawn`** — Input: same fields as `call`. Returns a task handle:

```json
{"task_id": "task_1"}
```

On failure (e.g., concurrent task limit reached):

```json
{"error": {"type": "resource_limit", "message": "Maximum concurrent tasks exceeded"}}
```

**`await`** — Input: `task_id` string. Blocks until the task completes or times out:

```json
{"status": "completed", "output": {...}, "task_id": "task_1", "execution_id": "exec_...", "duration_ms": 152}
```

If the sub-component failed:

```json
{"status": "error", "error": {"type": "execution_failed", "message": "..."}, "task_id": "task_1", "duration_ms": 85}
```

**`await-all`** — Input: `{"task_ids": ["id1", "id2", ...]}`. Blocks until every task completes. Results are ordered to match the input `task_ids` array:

```json
{
  "results": [
    {"status": "completed", "output": {...}, "task_id": "id1", "execution_id": "exec_...", "duration_ms": 120},
    {"status": "error", "error": {"type": "timeout", "message": "Task timed out"}, "task_id": "id2"}
  ],
  "count": 2
}
```

Each result has its own `status` — some may be `"completed"` while others are `"error"`. Always check per-result.

**`await-any`** — Input: `{"task_ids": ["id1", "id2", ...]}`. Blocks until the **first** task finishes (success **or** error), then returns immediately with the remaining task IDs:

```json
{
  "result": {"status": "completed", "output": {...}, "task_id": "id1", "execution_id": "exec_...", "duration_ms": 50},
  "task_id": "id1",
  "pending": ["id2", "id3"]
}
```

If all tasks time out:

```json
{"status": "error", "error": {"type": "timeout", "message": "All tasks timed out"}, "pending": ["id1", "id2"]}
```

**`poll`** — Input: `task_id` string. Non-blocking status check:

```json
{"status": "pending"}
```

or, if finished:

```json
{"status": "completed", "output": {...}, "task_id": "task_1", "execution_id": "exec_...", "duration_ms": 100}
```

**`cancel`** — Input: `task_id` string. Stops a pending task:

```json
{"cancelled": true, "task_id": "task_1"}
```

Returns an error if the task already completed or doesn't exist:

```json
{"error": {"type": "invalid_request", "message": "Task task_1 already completed"}}
```

Use `cancel` to stop tasks you no longer need — for example, after `await-any` returns a winner, cancel the remaining pending tasks to free resources.

**Constraints:**
- **`max_concurrent_tasks`**: Policy field (default 10). Spawn returns error when limit is reached.
- **`batch_timeout`**: Policy field (default "5m"). Used as timeout for `await-all` and `await-any`.
- **Cleanup**: All orphaned tasks are killed when the formula execution ends (via Task.Supervisor shutdown).
- **Crash isolation**: A sub-task crash doesn't kill the formula — it appears as an error result.

### `cyfr:mcp/tools` — Dynamic MCP Tool Access (Formula only)

**Signature**: `call(json-request: string) -> string`

Lets Formulas call any MCP tool dynamically. Deny-by-default — only tools listed in Host Policy `allowed_tools` are callable.

**Request format:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `tool` | string | Yes | MCP tool name (`component`, `execution`, `secret`, `storage`, `policy`, `build`, `audit`) |
| `action` | string | Yes | Action to perform (tool-specific) |
| `args` | object | No | Action-specific parameters |

**Success response**: `{"status": "ok", "result": {...}}`

**Error response**: `{"error": {"type": "...", "message": "..."}}`

| Error Type | Cause |
|------------|-------|
| `tool_denied` | Tool/action not in policy `allowed_tools` |
| `tool_not_found` | Unknown tool name |
| `invalid_request` | Missing `tool` or `action` field |
| `dispatch_error` | Underlying tool handler failed |

**Example** (search for components):

```rust
let resp = mcp::tools::call(&json!({
    "tool": "component",
    "action": "search",
    "args": {"query": "sentiment analysis", "type": "reagent"}
}).to_string());
```

> **Host Policy Required**: Formulas using `cyfr:mcp/tools` MUST have Host Policy defining `allowed_tools`. **Deny-by-default**: unlisted tools are blocked.

---

## Component Directory Structure

All components — user-developed, first-party, agent-generated, and Compendium-downloaded — follow the same canonical layout:

```
components/
+-- catalysts/
|   +-- cyfr/                            # Verified publisher (pulled from registry)
|   |   +-- stripe/1.0.0/
|   |       +-- src/                     # Source code (Cargo.toml, lib.rs, wit/)
|   |       +-- catalyst.wasm            # Built binary (always named by type)
|   |       +-- cyfr-manifest.json       # Component manifest (required)
|   |       +-- README.md                # Human-readable docs (recommended)
|   +-- local/                           # Human dev created (Cursor, Claude Code, etc.)
|   |   +-- my-tool/0.1.0/
|   |       +-- src/ + catalyst.wasm + cyfr-manifest.json
|   +-- agent/                           # Brain Formula generated (via build.compile)
|       +-- gen-abc123/0.1.0/
|           +-- catalyst.wasm + cyfr-manifest.json
+-- reagents/{cyfr,local,agent}/{name}/{version}/reagent.wasm
+-- formulas/{cyfr,local,agent}/{name}/{version}/formula.wasm
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

**Registry references map to local paths:**

| Registry Reference | Local Path |
|---|---|
| `cyfr.run/catalysts/stripe:1.0` | `components/catalysts/cyfr/stripe/1.0.0/catalyst.wasm` |
| `cyfr.run/reagents/json-transform:1.0` | `components/reagents/cyfr/json-transform/1.0.0/reagent.wasm` |

**Project-local data:**

All structured data (secrets, policy, logs, API keys, sessions) lives in `data/cyfr.db`. The `data/` directory should be `.gitignored` as it contains encrypted secrets and session tokens.

### What to Include in Version Control

**Include**: `{type}.wasm`, `cyfr-manifest.json`, `README.md`, `src/Cargo.toml`, `src/Cargo.lock`, `src/src/`, `src/wit/`, `src/src/bindings.rs` (generated by `wit-bindgen` — kept because it's small and required for building without re-running the generator).

**Exclude** (in `.gitignore`): `src/target/` (Cargo build output), `node_modules/`.

---

## Component Manifest (`cyfr-manifest.json`)

Every component must include a `cyfr-manifest.json` file alongside its WASM binary. The manifest is a machine-readable description of what the component **is** and **needs** — it is distinct from:

- **`setup` manifest section**: Declares secrets and recommended policy for streamlined onboarding (see [Setup](#setup))
- **Host Policy**: Enforcement rules (rate limits, allowed domains) set by the consumer, not the developer

The manifest travels with the component through the entire lifecycle: local development, testing, publishing, and pull.

> **Authoritative source**: The Compendium service documentation defines the manifest format for OCI packaging. This section covers the developer-facing usage.

### Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Bare component name (e.g., `claude`, `json-transform`) |
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

### Fields by Component Type

Which fields apply to each type — use this to know exactly what your manifest needs:

| Field | Reagent | Catalyst | Formula |
|-------|---------|----------|---------|
| `name` | Required | Required | Required |
| `type` | Required | Required | Required |
| `version` | Required | Required | Required |
| `description` | Required | Required | Required |
| `license` | Optional | Optional | Optional |
| `wasi` | — | **Required** | — |
| `setup.secrets` | — | Recommended | — |
| `setup.policy` | Optional | Recommended | Recommended |
| `schema` | Recommended | Recommended | Recommended |
| `defaults` | Optional | Optional | — |
| `dependencies` | — | — | Recommended |
| `examples` | Recommended | Recommended | Recommended |

- Fields marked `—` should be omitted for that type (those capabilities don't exist).
- `setup.policy` is available for all types. Generic fields (`timeout`, `max_memory_bytes`, `rate_limit`, etc.) apply uniformly. Catalyst-specific fields (`allowed_domains`, `allowed_methods`) only matter for catalysts. Formula-specific fields (`allowed_tools`) only matter for formulas using `cyfr:mcp/tools`.
- Default timeouts if no policy is set: reagent=1m, catalyst=3m, formula=5m. Declare `setup.policy.timeout` if you need a different default.

### `setup.policy` Fields

**Generic fields** (apply to all component types):

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `timeout` | string | reagent: `"1m"`, catalyst: `"3m"`, formula: `"5m"` | Max execution time |
| `max_memory_bytes` | integer | `67108864` (64MB) | Max WASM memory |
| `max_request_size` | integer | `1048576` (1MB) | Max input size in bytes |
| `max_response_size` | integer | `5242880` (5MB) | Max output size in bytes |
| `rate_limit` | object | none | `{"requests": N, "window": "1m"}` — per-user per-component rate limit |

**Catalyst-specific fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `allowed_domains` | string[] | `[]` (deny-all) | Domains the component can call via HTTP. **Required for catalysts to execute.** |
| `allowed_methods` | string[] | `["GET","POST","PUT","DELETE","PATCH"]` | HTTP methods allowed |
| `allowed_private_ips` | string[] | `[]` (deny-all) | Private IPs or CIDR ranges to allow for on-prem deployments. `169.254.0.0/16` always blocked. |

**Formula-specific fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `allowed_tools` | string[] | `[]` (deny-all) | MCP tools the formula can call. Only needed if the formula imports `cyfr:mcp/tools`. |
| `batch_timeout` | string | `"5m"` | Timeout for `await-all` and `await-any` batches |
| `max_concurrent_tasks` | integer | `10` | Max concurrent spawned tasks |

### Examples

**Reagent** (pure compute, no I/O):

```json
{
  "name": "data-processor",
  "type": "reagent",
  "version": "1.0.0",
  "description": "Transforms and validates structured data",
  "license": "MIT",
  "schema": {
    "input": {
      "type": "object",
      "required": ["action"],
      "properties": {
        "action": { "enum": ["validate", "transform", "parse"] },
        "data": { "type": "object" }
      }
    },
    "output": { "type": "object" }
  },
  "examples": [
    {
      "name": "Validate user data",
      "input": { "action": "validate", "data": { "email": "alice@example.com" } },
      "output": { "valid": true }
    }
  ]
}
```

Reagents need no `wasi`, `setup.secrets`, or `dependencies` — they are pure compute with no I/O. Just `cyfr register` and run. If your reagent needs more than the default 1m timeout or 64MB memory, add `setup.policy` with `timeout` and/or `max_memory_bytes`.

**Catalyst** (I/O capabilities, secrets, setup):

```json
{
  "name": "stripe",
  "type": "catalyst",
  "version": "1.0.0",
  "description": "Stripe payment processing bridge",
  "wasi": { "http": true, "secrets": true },
  "setup": {
    "secrets": [
      {
        "name": "STRIPE_API_KEY",
        "description": "Stripe secret key from dashboard.stripe.com/apikeys",
        "required": true
      }
    ],
    "policy": {
      "allowed_domains": ["api.stripe.com"],
      "rate_limit": { "requests": 100, "window": "1m" },
      "timeout": "30s"
    }
  },
  "schema": {
    "input": {
      "type": "object",
      "required": ["operation"],
      "properties": {
        "operation": { "enum": ["charge", "refund", "customers.list"] },
        "params": { "type": "object" }
      }
    },
    "output": { "type": "object" }
  },
  "defaults": {
    "max_charge_amount": 100000,
    "default_currency": "usd"
  },
  "examples": [
    {
      "name": "Create a charge",
      "description": "Charges a customer's default payment method",
      "input": { "operation": "charge", "params": { "amount": 5000, "customer_id": "cus_123" } },
      "output": { "status": 200, "data": { "id": "ch_...", "amount": 5000 } }
    }
  ]
}
```

How `cyfr setup` reads each field:

- **`wasi`** — declares what host functions the binary imports (must match actual WASM imports). `http` enables outbound HTTP, `secrets` enables reading from the secret store.
- **`setup.secrets`** — `cyfr setup` prompts for each secret, stores it encrypted, and grants the component access.
- **`setup.policy`** — `cyfr setup` applies these as the initial Host Policy. `allowed_domains` is required for catalysts to make HTTP calls. Deny-by-default — unlisted domains are blocked.
- **`defaults`** — informational only. Documents hardcoded values in the component source for consumer reference.
- **`schema`** — helps users and agents know what input the component expects and what output it returns.

For user-specific domains (e.g., Supabase project URLs), the user sets `allowed_domains` manually during `cyfr setup` or via `cyfr policy set` with their specific domain. The catalyst reads the URL from a secret at runtime.

**Formula** (orchestration, dependencies, MCP tools):

```json
{
  "name": "list-models",
  "type": "formula",
  "version": "1.0.0",
  "description": "Aggregates available models from all AI provider catalysts",
  "setup": {
    "policy": {
      "timeout": "5m"
    }
  },
  "dependencies": {
    "static": [
      { "ref": "catalyst:local.claude:0.2.0", "optional": true, "reason": "Claude API provider" },
      { "ref": "catalyst:local.openai:0.2.0", "optional": true, "reason": "OpenAI API provider" }
    ]
  },
  "schema": {
    "input": {
      "type": "object",
      "properties": {
        "providers": { "type": "array", "items": { "type": "string" } }
      }
    },
    "output": {
      "type": "object",
      "properties": {
        "models": { "type": "object" },
        "errors": { "type": "object" }
      }
    }
  },
  "examples": [
    {
      "name": "List all models",
      "input": {},
      "output": { "models": { "claude": { "data": ["..."] }, "openai": { "data": ["..."] } }, "errors": {} }
    }
  ]
}
```

How formulas differ:

- Formulas don't use the `wasi` field — their imports (`cyfr:formula/invoke`, `cyfr:mcp/tools`) are separate from catalyst capabilities. `invoke` is always available; MCP access is controlled by `setup.policy.allowed_tools`.
- No `setup.secrets` — formulas invoke sub-components that have their own secret grants. The formula itself never reads secrets directly.
- **`dependencies.static`** — `cyfr pull` auto-fetches these; `cyfr run` blocks if required deps are missing. Mark deps as `optional: true` when the formula can degrade gracefully without them.
- **`setup.policy.timeout`** — formulas often need longer timeouts since they orchestrate multiple sub-calls.
- For MCP-using formulas: add `setup.policy.allowed_tools` (e.g., `["component.search"]`). Deny-by-default — unlisted tools are blocked.

---

## Dependencies

Formulas invoke sub-components at runtime via `cyfr:formula/invoke`. The `dependencies` manifest field declares these relationships so the system can **auto-pull** them when you pull a formula and **block execution** if required dependencies are missing.

**`dependencies.static[]`** — components known at build time:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `ref` | string | Yes | Canonical component ref (`type:namespace.name:version`). **Exact version required** — no ranges, no constraints |
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

---

## Setup

The `setup` manifest section consolidates everything a component needs for onboarding into a single declaration. Instead of separate `config.json` files and manual secret/policy configuration, component developers declare their requirements directly in `cyfr-manifest.json`, and consumers run `cyfr setup` to apply them.

### Manifest `setup` Section

The `setup` section has two optional sub-fields:

| Field | Type | Purpose |
|-------|------|---------|
| `setup.secrets` | array | Secret requirements. Each entry: `name` (string), `description` (string, helps users obtain the value), `required` (bool) |
| `setup.policy` | object | Recommended Host Policy values (e.g., `allowed_domains`, `rate_limit`, `timeout`, `max_memory_bytes`) |

> **Note on Generic Policies:** While Opus provides default execution limits for all components (reagent=1m, catalyst=3m, formula=5m), `cyfr setup` relies exclusively on the manifest's `setup.policy` block to extract and configure developer-recommended overrides. If you want your component to default to a 5m timeout or higher `max_memory_bytes` when users run `cyfr setup`, you **must** explicitly declare those generic policies in `setup.policy`.

Components that need configurable values should:

1. **Accept them as part of the `input` JSON** — the caller passes config values in the request
2. **Read them via `cyfr:secrets/read`** — for sensitive values (API keys, tokens)
3. **Hardcode sensible defaults in source code** — this is the recommended pattern for catalysts

The manifest `defaults` block documents vendor-recommended values for human and tooling reference.

> **Setup vs Host Policy**: `setup.policy` is the component developer's *recommendation*. Host Policy is what is actually *enforced* by Opus at the WASI boundary. `cyfr setup` bridges the two by applying the recommended values as the initial policy.

### `cyfr setup` Workflow

```bash
cyfr setup c:local.my-catalyst           # All registered versions
cyfr setup c:local.my-catalyst:1.0.0     # Specific version only
```

The setup command: (1) reads `setup.secrets` and prompts for each secret value, (2) stores secrets via Sanctum and grants the component access, (3) applies `setup.policy` as initial Host Policy via Arca.

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

```bash
# Store a secret (encrypted at rest)
cyfr secret set API_KEY=sk-live-abc123

# Grant a catalyst access to the secret (all versions)
cyfr secret grant c:local.stripe-catalyst API_KEY

# Grant to a specific version only
cyfr secret grant c:local.stripe-catalyst:1.0.0 API_KEY

# Revoke access (all versions or specific)
cyfr secret revoke c:local.stripe-catalyst API_KEY

# List all stored secrets
cyfr secret list

# Delete a secret entirely
cyfr secret delete API_KEY
```

### MCP Actions for Secrets

AI agents and programmatic clients manage secrets via MCP tool calls:

| Action | Key Fields | Response |
|--------|-----------|----------|
| `set` | `name`, `value` | `{"stored": true, "name": "API_KEY"}` |
| `list` | — | `{"secrets": ["API_KEY", ...], "count": N}` |
| `grant` | `name`, `component_ref` | `{"granted": true, ...}` |
| `revoke` | `name`, `component_ref` | `{"status": "revoked", ...}` |
| `can_access` | `name`, `component_ref` | `{"allowed": true}` |
| `delete` | `name` | `{"deleted": true, "name": "API_KEY"}` |

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

### Anti-Exfiltration

Even after a catalyst reads a secret, it cannot send it to an unauthorized server. Layered defenses: `allowed_domains` blocks unauthorized HTTP, private IP blocking prevents SSRF, DNS pinning prevents rebinding, rate limiting stops slow exfil, SecretMasker scrubs all secret variants (plaintext, Base64, hex) from output, and the audit trail logs every access.

### Reagents Cannot Access Secrets

Reagents have no imports — they are pure computation. Locus rejects any reagent binary that declares imports. If your component needs secrets, it must be a catalyst.

---

## Supported Languages

CYFR validates WASM output, not source code. Any language that compiles to a valid WASM Component Model binary (`wasm32-wasip2`) can build components.

> All examples in this guide and the included components use Rust with `cargo-component`. The WIT interface definitions in `wit/` are language-agnostic — any language with a WASM Component Model toolchain can build CYFR components. The interface is simple: export a single function (`compute`, `run`, or `run` depending on type) that takes a JSON string and returns a JSON string.

---

## How to Verify Locally

### Using wasm-tools

```bash
wasm-tools validate component.wasm          # Validate WASM binary
wasm-tools component wit component.wasm     # Inspect exports
wasm-tools print component.wasm | grep "(import"  # Check imports (should be empty for reagents)
```

### Validation Checklist

- [ ] Binary is valid WASM (`wasm-tools validate`)
- [ ] Correct interface exported (`wasm-tools component wit`)
- [ ] No forbidden imports (check for WASI imports on reagents)
- [ ] Binary size under 50 MB
- [ ] Test with sample input/output locally

---

## Building a Component (Catalyst Walkthrough)

This section walks through building a **catalyst** — the most complex component type (HTTP + secrets + policy). For reagents and formulas, see the differences sections below.

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

[package.metadata.component]
package = "cyfr:catalyst"

[package.metadata.component.target]
world = "catalyst"
path = "wit"

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
            Err(e) => return serde_json::json!({"error": e.to_string()}).to_string(),
        };

        // Read API key from secrets
        let api_key = match bindings::cyfr::secrets::read::get("MY_API_KEY") {
            Ok(key) => key,
            Err(e) => return serde_json::json!({"error": e}).to_string(),
        };

        // Make HTTP request via host function
        let req = serde_json::json!({
            "method": "GET",
            "url": "https://api.example.com/data",
            "headers": { "Authorization": format!("Bearer {}", api_key) }
        });
        let response_json = bindings::cyfr::http::fetch::request(&req.to_string());
        // Response: {"status": 200, "headers": {...}, "body": "..."} or {"error": {...}}

        response_json
    }
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

Create `components/catalysts/local/my-api/0.1.0/cyfr-manifest.json` (see [Component Manifest](#component-manifest-cyfr-manifestjson) for full field reference):

```json
{
  "name": "my-api",
  "type": "catalyst",
  "version": "0.1.0",
  "description": "Bridge to Example API",
  "wasi": { "http": true, "secrets": true },
  "setup": {
    "secrets": [{ "name": "MY_API_KEY", "description": "API key from api.example.com/settings", "required": true }],
    "policy": { "allowed_domains": ["api.example.com"], "rate_limit": {"requests": 100, "window": "1m"}, "timeout": "30s" }
  },
  "schema": { "input": { "type": "object" }, "output": { "type": "object" } }
}
```

### 7. Run Setup, Validate, Register

```bash
# Interactive setup — prompts for secrets, applies recommended policy
cyfr setup c:local.my-api:0.1.0

# Validate the binary
wasm-tools validate components/catalysts/local/my-api/0.1.0/catalyst.wasm

# Register the component
cyfr register
```

Re-run `cyfr register` after every rebuild — the stored SHA-256 digest must match the binary on disk. Opus reads the WASM directly from `components/`, so no file copy is needed.

### Reagent Differences

Reagents are simpler — no secrets, no policy, no WIT deps.

**Cargo.toml**: Same structure, but no `[package.metadata.component.target.dependencies]` section. Package metadata uses `cyfr:reagent` and world `"reagent"`:

```toml
[dependencies]
wit-bindgen-rt = "0.25"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

[package.metadata.component]
package = "cyfr:reagent"

[package.metadata.component.target]
world = "reagent"
path = "wit"
```

**WIT**: Just `cp -r wit/reagent/ src/wit/` — no deps directory needed.

**Implementation**:

```rust
#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::reagent::compute::Guest;

struct MyReagent;

bindings::export!(MyReagent with_types_in bindings);

impl Guest for MyReagent {
    fn compute(input: String) -> String {
        let data: serde_json::Value = match serde_json::from_str(&input) {
            Ok(v) => v,
            Err(e) => return serde_json::json!({"error": e.to_string()}).to_string(),
        };
        // Your pure computation here
        serde_json::to_string(&data).unwrap_or_else(|e| {
            serde_json::json!({"error": e.to_string()}).to_string()
        })
    }
}
```

**Manifest**: Minimal — no `wasi` or `setup` fields needed.

**Setup**: None required. Just `cyfr register` and run.

### Formula Differences

Formulas invoke sub-components — no direct I/O.

**Cargo.toml**: Package metadata uses `cyfr:formula` and world `"formula"`. Declare MCP dep if using `cyfr:mcp/tools`:

```toml
[dependencies]
wit-bindgen-rt = "0.25"
serde_json = "1.0"

[package.metadata.component]
package = "cyfr:formula"

[package.metadata.component.target]
world = "formula"
path = "wit"

[package.metadata.component.target.dependencies]
"cyfr:mcp" = { path = "wit/deps/cyfr-mcp" }
```

**WIT**: `cp -r wit/formula/ src/wit/` — includes `deps/cyfr-mcp/` for MCP tools import.

**Implementation**:

```rust
#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::formula::run::Guest;
use bindings::cyfr::formula::invoke;

struct MyFormula;

bindings::export!(MyFormula with_types_in bindings);

impl Guest for MyFormula {
    fn run(input: String) -> String {
        let response_str = invoke::call(&serde_json::json!({
            "reference": "catalyst:local.my-api:0.1.0",
            "input": {"operation": "models.list", "params": {}},
            "type": "catalyst"
        }).to_string());

        let response: serde_json::Value = serde_json::from_str(&response_str)
            .unwrap_or_else(|e| serde_json::json!({"error": format!("parse failed: {e}")}));

        // Check for invoke-level errors
        if response.get("error").is_some() {
            return response.to_string();
        }

        // Extract the sub-component's output
        let output = &response["output"];
        // output may be a JSON string or an object — handle both
        let result: serde_json::Value = match output.as_str() {
            Some(s) => serde_json::from_str(s).unwrap_or(output.clone()),
            None => output.clone(),
        };

        result.to_string()
    }
}
```

**Manifest**: Declare `dependencies.static` for sub-components. No `wasi` or `secrets`.

**Prerequisites**: Sub-components must be registered and configured (secrets + policy) before the formula can invoke them.

### Parallel Invocation (Formula)

Formulas can invoke multiple catalysts concurrently using `spawn` + `await-all`. For a single sub-component, use `call` directly — the async overhead isn't worth it. For two or more, use `spawn` + `await-all`:

```rust
use serde_json::{json, Value};
use bindings::cyfr::formula::invoke;

struct Provider { key: &'static str, registry_ref: &'static str }

fn invoke_parallel(providers: &[&Provider]) -> Result<String, String> {
    // --- Phase 1: Spawn all tasks ---
    let mut task_ids: Vec<String> = Vec::new();

    for provider in providers {
        let request = json!({
            "reference": provider.registry_ref,
            "input": { "operation": "models.list", "params": {} },
            "type": "catalyst"
        });

        let spawn_resp_str = invoke::spawn(&request.to_string());
        let spawn_resp: Value = serde_json::from_str(&spawn_resp_str)
            .map_err(|e| format!("Failed to parse spawn response: {e}"))?;

        // Spawn can fail (e.g., max_concurrent_tasks exceeded) — check before using task_id
        if let Some(err) = spawn_resp.get("error") {
            return Err(format!("Spawn error: {err}"));
        }

        let task_id = spawn_resp["task_id"]
            .as_str()
            .ok_or("Spawn response missing task_id")?
            .to_string();
        task_ids.push(task_id);
    }

    // --- Phase 2: Await all results ---
    let response_str = invoke::await_all(&json!({"task_ids": task_ids}).to_string());
    let response: Value = serde_json::from_str(&response_str)
        .map_err(|e| format!("Failed to parse await-all response: {e}"))?;

    let results = response["results"]
        .as_array()
        .cloned()
        .unwrap_or_default();

    // --- Phase 3: Process per-result (results are ordered to match task_ids) ---
    let mut models = json!({});
    let mut errors = json!({});

    for (i, provider) in providers.iter().enumerate() {
        let result = &results[i];
        let status = result["status"].as_str().unwrap_or("error");

        if status == "completed" {
            // output may be a JSON string or an object — handle both
            let output = &result["output"];
            let parsed: Value = match output.as_str() {
                Some(s) => serde_json::from_str(s).unwrap_or(output.clone()),
                None => output.clone(),
            };
            models[provider.key] = parsed;
        } else {
            let err_msg = result["error"].to_string();
            errors[provider.key] = Value::String(err_msg);
        }
    }

    Ok(json!({"models": models, "errors": errors}).to_string())
}
```

> **Tip**: The `output` field in each result can be either a JSON object or a JSON-encoded string (depending on the sub-component). Always try to parse it as a string first, falling back to using it as-is. This double-parse pattern is shown above and in the production example.

See `components/formulas/local/list-models/` for a production example of parallel invocation across multiple providers (including the single-vs-multiple optimization).

### First-Result Pattern (await-any + cancel)

When you need the fastest response from several equivalent providers, use `await-any` to get the first result and `cancel` to clean up the rest:

```rust
fn invoke_fastest(providers: &[&Provider], input: &Value) -> Result<Value, String> {
    // Spawn all providers
    let mut task_ids: Vec<String> = Vec::new();
    for provider in providers {
        let request = json!({
            "reference": provider.registry_ref,
            "input": input,
            "type": "catalyst"
        });
        let resp: Value = serde_json::from_str(&invoke::spawn(&request.to_string()))
            .map_err(|e| format!("Spawn parse error: {e}"))?;
        if let Some(err) = resp.get("error") {
            return Err(format!("Spawn error: {err}"));
        }
        task_ids.push(resp["task_id"].as_str().unwrap().to_string());
    }

    // Wait for the first to finish (success or error)
    let resp_str = invoke::await_any(&json!({"task_ids": task_ids}).to_string());
    let resp: Value = serde_json::from_str(&resp_str)
        .map_err(|e| format!("await-any parse error: {e}"))?;

    // Cancel remaining pending tasks to free resources
    if let Some(pending) = resp["pending"].as_array() {
        for id in pending {
            if let Some(tid) = id.as_str() {
                invoke::cancel(tid);
            }
        }
    }

    // Check if the winner succeeded
    let result = &resp["result"];
    if result["status"].as_str() == Some("completed") {
        let output = &result["output"];
        let parsed: Value = match output.as_str() {
            Some(s) => serde_json::from_str(s).unwrap_or(output.clone()),
            None => output.clone(),
        };
        Ok(parsed)
    } else {
        Err(format!("First result was an error: {}", result["error"]))
    }
}
```

> **Note**: `await-any` returns on the first completion *including errors*. If you need the first *successful* result, loop: check the winner's status, and if it's an error, call `await-any` again with the remaining `pending` task IDs.

---

## Development Loop

### Build → Register → Run → Iterate

```
1. Build       cargo component build --release --target wasm32-wasip2
2. Validate    wasm-tools validate <type>.wasm
3. Register    cyfr register
4. Policy      cyfr policy set c:<ref> allowed_domains '["api.example.com"]'  ← catalysts only
5. Secrets     cyfr secret set KEY=val && cyfr secret grant c:<ref> KEY       ← catalysts only
6. Execute     cyfr run <type>:<reference> --input '{...}'
7. Verify      Check the JSON response
8. Logs        cyfr run --logs <execution_id>
9. Iterate     Rebuild → re-register → re-run (policy/secrets persist)
```

> **Tip**: Open `http://localhost:4001` to view execution details, logs, and resource usage in the Prism dashboard.

> **Why register?** Registration stores a SHA-256 digest of each WASM binary. If you rebuild without re-registering, the stored digest won't match and `cyfr run` will reject the component with a digest mismatch error. Always re-register after rebuilding.

Steps 4-5 only apply to catalysts. Reagents need zero setup. Formulas need setup only for their sub-components.

### Debugging

- **Server logs**: `println!` / `eprintln!` in Rust (or equivalent in other languages) write to the CYFR server's stdout/stderr. Run `cyfr up` in the foreground to see them.
- **Execution metadata**: `cyfr run --logs <execution_id>` shows status, duration, input, output (with secrets masked), and policy applied — useful for verifying what went in and came out.
- **Prism dashboard**: `http://localhost:4001` shows real-time execution details.
- **Common debugging pattern**: Return intermediate state in your output during development (e.g., `{"debug": {...}, "result": {...}}`) then remove before publishing.

> Per-execution stdout/stderr capture is planned but not yet available.

### `register` vs `publish`

| Operation | Who | Trust | Overwrite? | Enters via |
|-----------|-----|-------|------------|------------|
| `register` | Developer | `:local` (unsigned) | Always | `cyfr register` (filesystem scan) |
| `publish` | Verified identity | `:signed` / `:sigstore` | Never (non-local) | Explicit action + signature |

Both write to the same SQLite `components` table. All components live under `components/` — registration indexes them in SQLite without copying files. A `source` field distinguishes them:
- `"filesystem"` — registered from `local/` or `agent/` directories via `cyfr register`
- `"published"` — explicitly published via `component.publish`

### Namespace Guard

Registration enforces namespace restrictions:
- **Only** `local/` and `agent/` publisher namespaces are scanned
- **Ignores** components under other publisher names (e.g., `stripe/`, `cyfr/`)
- Only `publish` with proper identity verification can create named-publisher entries

### Execution Response Format

```json
{
  "status": "completed",
  "execution_id": "exec_01234567-...",
  "result": {"models": [...]},
  "duration_ms": 1523,
  "component_type": "catalyst",
  "component_digest": "sha256:abc...",
  "reference": "catalyst:local.my-api:0.1.0",
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
      "reference": "catalyst:local.my-api:0.1.0",
      "input": {"operation": "models.list", "params": {}}
    }
  }
}
```

**List:** `{"action": "list", "status": "all", "limit": 20}`

**Logs:** `{"action": "logs", "execution_id": "exec_..."}`

**Cancel:** `{"action": "cancel", "execution_id": "exec_..."}`

Always specify `"type"` explicitly — don't rely on the `"reagent"` default.

### Common Response Patterns

| Scenario | What You See |
|---|---|
| Success | `{"status": "completed", "result": {...}}` |
| Component returned error | `{"status": "completed", "result": {"error": {...}}}` |
| Missing policy | `"Catalyst 'X' has no allowed_domains configured."` |
| Rate limited | `"Rate limit exceeded. Retry in 60s"` |
| Timeout | `"Execution timeout after Nms"` |
| Secret denied | `"access-denied: API_KEY not granted to X"` |

---

## Publishing Checklist

Before publishing a component to the registry, verify:

- [ ] WASM binary passes `build.validate` (valid WASM, correct exports, no forbidden imports)
- [ ] `cyfr-manifest.json` present with required fields (`name`, `type`, `version`, `description`)
- [ ] Capability declarations in manifest match actual WASM imports (e.g., if your WIT imports `cyfr:http/fetch`, manifest has `wasi.http: true`)
- [ ] Input/output schemas defined in manifest (`schema.input`, `schema.output`)
- [ ] Setup section declares required secrets (`setup.secrets`) with descriptions
- [ ] Setup section declares recommended policy (`setup.policy`) if the component needs host policy
- [ ] Examples in manifest for common operations (recommended)
- [ ] `README.md` with usage examples (recommended)
- [ ] Tested with representative input via `cyfr run`
- [ ] **Catalysts only**: Host Policy set with `allowed_domains` and secrets granted

---

## Common Errors and Fixes

Quick reference for frequent issues.

### Build-Time Errors

#### FORBIDDEN_IMPORT

**Error**: Reagent imports WASI interface. **Fix**: Check `wasm-tools print component.wasm | grep "(import"`. Common causes: `std::time`, `std::net`, `std::fs`, random number generation, or transitive deps pulling in WASI. Use `#[cfg(target_arch = "wasm32")]` to exclude non-WASM code.

#### MISSING_EXPORT

**Error**: Required interface not exported. **Fix**: Verify WIT includes correct export, check `bindings::export!` macro and `Guest` trait implementation.

#### INVALID_WASM

**Error**: Binary is not valid WebAssembly. **Fix**: Verify target is `wasm32-wasip2` (the only supported target), update toolchain, run `wasm-tools validate` for details.

#### SIZE_EXCEEDED

**Error**: Binary exceeds 50 MB limit. **Fix**: Enable `lto = true`, use `opt-level = "s"`, remove unused deps, or split into multiple components.

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
cyfr policy set c:local.my-catalyst:1.0 rate_limit '{"requests": 200, "window": "1m"}'
```

#### EXECUTION_TIMEOUT

**Error**: Component exceeded time limit.

**Cause**: Component took longer than the configured timeout. Default timeouts: reagent=1m, catalyst=3m, formula=5m.

**Fix**: Optimize the component logic, or increase the timeout via policy:
```bash
cyfr policy set c:local.my-catalyst:1.0 timeout '"5m"'
```

#### SECRET_DENIED

**Error**: `Err("access-denied: API_KEY not granted to my-catalyst:1.0")`

**Cause**: Secret not granted to this component.

**Fix**:
```bash
cyfr secret grant c:local.my-catalyst:1.0 API_KEY
```

#### DIGEST_MISMATCH

**Error**: `Registry digest mismatch for <component>. Component may have been modified between inspect and fetch.`

**Cause**: The component was rebuilt after the last `cyfr register`, so the stored SHA-256 digest no longer matches the binary on disk.

**Fix**:
```bash
cyfr register
cyfr run c:local.my-component:0.1.0 --input '{}'
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

See `components/catalysts/local/claude/0.2.0/README.md` for a real-world example.

---

## Advanced Patterns

### Brain Formula Pattern

A **Brain Formula** uses LLM reasoning combined with `cyfr:mcp/tools` to dynamically discover, generate, and invoke components at runtime.

#### Flow

```
User Request → Brain calls LLM Catalyst for reasoning
  → LLM returns: "I need a sentiment analyzer"
  → Brain calls: mcp.call("component.search", {query: "sentiment"})
  → If found locally (already registered/pulled) → invoke directly
  → If found on registry (not yet pulled) → pull first, setup secrets/policy if needed, then invoke
  → If not found anywhere → Brain asks LLM to generate source
    → mcp.call("build.compile", {source: "...", language: "go", target: "reagent"})
    → Returns "reagent:agent.gen-xyz:0.1.0"
    → Brain invokes the generated component
  → Result returned to user
```

#### Example Policy

Brain Formulas require Host Policy with `allowed_tools`:

```bash
cyfr policy set f:local.brain:0.1.0 allowed_tools '["component.search", "component.pull", "build.compile", "secret.list", "storage.read", "storage.write"]'
```

The Brain can **list** secrets (to see what exists) but not **read** values. To use secrets, it invokes a Catalyst that has the secret granted.
