# CYFR Arx Readiness Roadmap

## Goal

CYFR ships as one codebase with two editions:

- **Sanctum Core**: single-user, single-project, fixed defaults, minimal ops surface.
- **Sanctum Arx**: an enabled extension on top of Core. Arx adds governance, org/project/membership, enterprise auth, hosted/on-prem operations, and scalable deployment patterns.

Target operating model:

- `cyfr` is the control plane: gateway, auth, governance, storage metadata, caching, dashboard UI.
- `opus` is the execution plane.
- `locus` is the build plane.
- Core runs these capabilities locally by default.
- Arx can run them separately when hosted or deployed on-prem at scale.

This roadmap is maintained through ongoing source-code audits (twenty-seventh pass as of 2026-03-16). See git history for per-pass details. All 189+ Elixir files across cyfr, opus, and locus have been audited file-by-file. Every remaining item references verified file paths and line numbers.

## Audit Summary (2026-03-16)

**Test runs**:

| Scope | Tests | Failures | Notes |
|---|---|---|---|
| Root `mix test` | 2729 | 0 | 2121 + 28 + 580, 22 excluded |
| Cyfr standalone | 2121 | 0 | 22 excluded (`ExUnit.configure(exclude: [:requires_opus])`) |
| Opus standalone | 580 | 0 | |
| Locus standalone | 28 | 0 | |

**Verification**:

| Category | Result |
|----------|--------|
| All tests pass | 2729 root / 2121 cyfr / 580 opus / 28 locus — 0 failures |
| Compilation | `mix compile --warnings-as-errors` — 0 warnings |
| Config consolidation | Complete — no stale OTP app keys in runtime code |
| Tenant isolation | Comprehensive — database, cache, PubSub, storage, RunningTasks ETS all properly scoped |
| Edition gating | Well-isolated via `SanctumArx.Edition` with compile-time macros |
| Dead code | None remaining — `due_schedules/1` removed in Phase 1h, `OCI.Auth.init_cache/0` removed in Phase 1o |
| Circular dependencies | None |
| SSRF protection | Complete — `Cyfr.Network.validate_redirect_url/1` on all OCI redirect URLs and webhook handler (`system_provider.ex:328`) |
| RateLimiter robustness | All 14 named processes have catch-all `handle_info/2` with `Logger.warning`. All 15 LiveViews have catch-all `handle_info/2` with `Logger.debug`. Cyfr(9): Cache.Sweeper, RetentionScheduler, AuditHandler, ToolRegistry, ResourceRegistry, SSEBuffer, RunningTasks, TelemetryBridge, AppRegistry. Opus(5): CronScheduler, RateLimiter, ExecutionSemaphore, AsyncTracker, ExecutionEventBuffer. Plus EmissaryWeb.Telemetry, PrismWeb.Telemetry (pollers), SharedEngine (Agent). RateLimiter rejects empty org_id in Arx mode with `{:error, :missing_tenant}` — cross-tenant collision risk resolved |

What is true today (collapsed from per-item audit — see git history for line-level evidence):

**Tenant isolation:**
- `QueryHelpers.where_tenant/2` on all Arca storage queries. `PubSub.topic/2` tenant-scoped (raises on empty org_id in Arx). RunningTasks ETS stores 4-tuple with org_id + `authorized_to_cancel?/3` check. Cache keys include org_id. Component storage paths org-scoped. PolicyLog/McpLog queries tenant-scoped. `verify_tenant` rejects nil org_id in Arx.

**Error handling:**
- `Arca.Repo.Errors.db_errors()` macro used in all storage modules, SanctumArx CRUD modules, and CronScheduler (Phase 1n). All MCP list/search queries capped at `min(limit, 1000)` (7 sites, Phase 1n). `ResourceRegistry.read/2` wrapped in `Task.async`/`Task.yield` with 5-minute timeout matching `ToolRegistry` (Phase 1n). All `Task.Supervisor.start_child` returns handled (13 sites) with timeout watchdogs on UI-facing tasks (8 sites). All `:DOWN` handlers clean up state maps. Zero `Jason.encode!`/`decode!` in production code (45+ sites converted to `safe_encode/1`). All `CronScheduler` return values case-matched with Logger.warning. All `Arca.put` results case-matched with error tuples. `encode_json_field` returns error tuples. Zero silent error-swallowing rescues remaining — all ~21 catch-all `rescue e ->` sites have Logger calls (Phase 1i removed the last rescue without logging). All LiveView `call_tool` catch-alls now log errors (~25 sites). All LiveView `handle_info` catch-alls now log unexpected messages (12 files). `Cache.put` returns `{:error, :cache_unavailable}` instead of raising. `SharedEngine` init uses descriptive error on failure. All storage error returns standardized to `{:error, :database_error}` (Phase 1l — 17 non-standard sites fixed across 3 files).

**Security:**
- Auth chain: OIDC → membership → context functional (Phase 2.1c). API key validation tenant-scoped, org_id derived from DB record. Auth provider crash → `{:error, :auth_provider_error}` → 503. `local_context/0` raises in Arx mode. Boot guard raises when auth provider nil in Arx.
- Atom safety: `@known_providers` allowlist (AuthLive), `@known_tool_statuses` map (AgentLive), `sanctum/atoms.ex` allowlist.
- Path traversal: recursive `fully_decode` + null byte check. SSRF: `Cyfr.Network.validate_redirect_url/1` on all external HTTP paths. CORS credentials for non-wildcard origins.
- License JOSE verification + zombie mode CRUD enforcement.

**Observability:**
- AuditSink behaviour with context injection + pipeline failure telemetry. JSONL sink nil-context guard. JSON logger formatter (Phase 2.1b). OTEL tenant attributes (Phase 2.1b). `LoggerContext` captures/restores metadata across processes. CronScheduler emits telemetry on load failure, record_error failure. Health check `/api/health/ready` with DB + cache checks.

**Architecture:**
- Umbrella 3-app (`cyfr`, `opus`, `locus`). All Opus refs in cyfr guarded with `Code.ensure_loaded?`. Cross-app `Compendium.WasmValidator` in cyfr, `Locus.Validator` delegates. 22 opus-dependent tests tagged `:requires_opus`. All 14 named processes have catch-all `handle_info/2` with `Logger.warning`. `SanctumArx.Edition` compile-time macros + runtime checks. Cache: 10k max entries + nearest-to-expiry eviction. WASM graceful shutdown (30s), SSE draining (30s), HTTP timeouts (60s). Builder Port cleanup prevents zombie OS processes. `ExecutionSemaphore` has `terminate/2` + dual-queue priority.

**False positives verified in prior audits** (confirmed not bugs): Rate limiter fallback blocks execution, auth provider fallback returns 503 in Arx, PubSub `broadcast/3` returns `:ok` for local adapter (TelemetryBridge wrapped in `safe_broadcast` — Phase 1o; secondary sites wrapped in `case` — Phase 1o), CronScheduler degraded state has telemetry+retry, `configure_database` silent success intentional for Arx/Postgres, RunningTasks `Process.exit` on dead PID is BEAM no-op, `File.mkdir_p!` correct fail-loud at boot, `system_context/0` current callers verified safe (only `retention_scheduler.ex:51`, Arx-only cross-tenant admin). Executor cache key `{:component_meta, org_id, project_id, reference}` IS tenant-scoped. `{:wasm_bytes, digest}` is content-addressed by SHA256, intentionally global (same bytes = same content). All `delete_all` sites rescue `db_errors()` with Logger.error/warning.

What is not true today:

- `Arca.Cache` silently degrades to always-miss on ETS table unavailability — intentional, logged via `Logger.warning`. `Cache.put` returns `{:error, :cache_unavailable}` on ETS re-init failure (fixed in Phase 1i).
- Residual `Exqlite.Connection disconnected` warnings in root test output are cosmetic — DB sandbox ownership race, not functional failures.
- OCI Cache (`oci/cache.ex`) is not tenant-scoped — shared filesystem, no org_id parameter. Content-addressed (sha256) so no security risk, but compliance concern for strict tenant data isolation requirements (Phase 2.3 informational).
- `Sanctum.system_context/0` (`sanctum.ex:97-99`) creates context without org_id — documented footgun for future Arx callers (`@doc` warning added in Phase 2.1c). Current callers verified safe (only `retention_scheduler.ex:51`).
- Core mode has no automatic retention cleanup — `RetentionScheduler` returns `:ignore`. This is by design (single-user, manual cleanup suffices), not a bug.
- Missing composite `(org_id, project_id)` indexes on `api_keys`, `permissions`, `secrets`, `secret_grants` tables. See Phase 2.2.
- No FK cascade from tenant-scoped tables (`components`, `policies`, `secrets`, `executions`, `api_keys`, etc.) to `orgs`/`projects` tables. See Phase 2.2.
- 4 items fixed in Phase 1o: TelemetryBridge `safe_broadcast` (6 sites), secondary PubSub `case` wrapping (4 sites), RetentionScheduler `{:continue, :first_run}`, Dockerfile `|| true` removal, edition check pattern documentation, `OCI.Auth.init_cache/0` dead code removal. See git history.
- 10 items fixed in Phases 1j–1n (struck-through in prior versions): auth chain catch-alls, CI redundancy, retention error surfacing, ComponentStorage delete_by_source, storage error consistency, LocalTest async, OtelTenantHandler tests, simple_oauth async, PolicyLog/McpLog tests, CronScheduler rescues, MCP limits, resource timeout. See git history.


## Non-Negotiable Invariants

- Core stays single-user and single-project with fixed defaults.
- Arx is an extension layer, not a second product.
- Edition/config/auth/license mismatches must fail at boot, never silently downgrade.
- Tenant-scoped Arx flows must never fall back to local or global operator credentials.
- Prefer BEAM-native patterns; add distributed mechanisms only when required.

---

## Completed Phases

All items verified against source code. See git history for per-phase details.

| Phase | Summary | Items |
|-------|---------|-------|
| 0 | Umbrella consolidation 8→3 apps, config keys to `:cyfr` | — |
| 1 (1.1–1.17) | Security hardening — crash/hang, CronScheduler, API key, path traversal | 17 |
| 1b (1b.1–1b.13) | Deep audit — `Context.local()`, `Jason.encode!` conversion | 13 |
| 1c (1c.1–1c.8) | Audit gaps — builds_live fallback, MCP encode, `atomize_keys` | 8 |
| 1d (1d.1–1d.4) | Core hardening — `encode_json_field` error tuples, endpoint salts | 4 |
| 1e (1e.1–1e.4) | Production — `safe_encode/1`, Task returns, CronScheduler exits | 4 |
| 1f (1f.1–1f.2) | OCI redirect SSRF prevention, session revocation tenant scoping | 2 |
| CI & Deploy | CI suppression removed, `.formatter.exs`, Dockerfile aligned | 4 |
| 2.0 Foundation | DB error abstraction, cache limits, health check, graceful shutdown | 13 |
| 2 Reliability | SSEBuffer leak, OCI cache migration, CronScheduler telemetry | 6 |
| 1.5 | Core hardening — JSONL nil guard, RunningTasks tenant isolation, SSRF | 17 |
| 2.0a | License boot guard, PubSub raises, health check Arx, S3 strategy | 6 |
| 1g (`ba4f214`) | GenServer catch-alls x10, Cache eviction, Semaphore dual queue | 18 |
| 1g-fix | CORS warning, RateLimiter tenant, OIDC/JWT env enforcement | 4 |
| 1h | API key Arx auth, 5 modules → `db_errors()`, dead code removal | 6 |
| 1h Addendum | `db_errors()` for 5 more modules (29 sites), bare rescue cleanup | 7 |
| 1i | SharedEngine safety, Cache.put contract, LiveView error logging + timeouts | 7 |
| 1j | Auth chain catch-all split (4 sites), CI redundancy removed | 4 |
| 1k | Final 5 LiveView catch-alls (15/15 covered), compiler warnings fixed | 5 |
| 1l | Storage error standardization (17 sites), RunningTasks terminate/2 | 9 |
| 1m | OtelTenantHandler tests, simple_oauth async, PolicyLog/McpLog tests, `@impl` | 4 |
| 1n | CronScheduler Postgres, MCP limit cap, resource timeout, RunningTasks test | 4 |
| 2.1a | RetentionScheduler GenServer for Arx auto-cleanup | 1 |
| 2.1b | JSON logger formatter, OTEL tenant attributes | 2 |
| 2.1c | Auth chain repair — OIDC → membership → context functional | 8 |
| 2.1f | Tiered policy ceilings — platform → org/plan cascade, save-time validation | 6 |
| 1o | Post-audit hardening — PubSub safety, RetentionScheduler continue, Dockerfile, edition docs, dead code | 5 |
| 1p | Locus cross-app decoupling — Builder progress callback, async registration | 2 |

---

## Architecture Assessment

Verified during deep audit (2026-03-16):

- **Tenant model**: Systematic via `QueryHelpers`, `Sanctum.Context`, and path scoping — ready for Arx multi-tenant extension.
- **Edition gating**: Clean compile-time macros (`SanctumArx.Edition`) + runtime checks — no leakage found.
- **Cross-app boundaries**: All Opus references in cyfr guarded with `Code.ensure_loaded?` — ready for release splitting. Locus.Builder uses progress callbacks (no direct SSEBuffer/PubSub). Post-compile registration is async fire-and-forget. Opus→CYFR coupling is clean (high-level APIs, behaviour-dispatched storage).
- **Security patterns**: Safe atom handling (allowlist in `sanctum/atoms.ex`, AuthLive uses `@known_providers` map, AgentLive uses `@known_tool_statuses` map), path traversal validation (recursive URL decode + null byte check), SSRF guards on all external HTTP paths (`HttpHandler`, `Cyfr.Network`, `system_provider.ex:328`), JWT verification — production ready.
- **Error handling**: Comprehensive — all `rescue` blocks have logging or error tuple returns. Phases 1.5, 2.0a, 1g, 1g-fix, 1h, 1h Addendum, 2.1a-c, 1i, 1j, 1k, 1l, 1n, and 1o all complete. PubSub broadcasts wrapped in `safe_broadcast` (TelemetryBridge) or `case` (secondary sites). All storage modules, SanctumArx CRUD modules, and CronScheduler use `db_errors()`. All MCP list/search queries capped at `min(limit, 1000)`. ResourceRegistry reads timeout-protected. Zero silent error-swallowing rescues — all ~21 catch-all `rescue e ->` sites have Logger calls. All LiveView `call_tool` catch-alls log errors. All 15 LiveView `handle_info` catch-alls log unexpected messages. SharedEngine uses descriptive error. Cache.put returns error tuple. UI task timeouts prevent indefinite loading states. Auth chain membership resolution errors logged explicitly (no silent catch-alls). All storage error returns standardized to `{:error, :database_error}` (Phase 1l). RunningTasks has `terminate/2` for clean shutdown.
- **Dead code**: None remaining. `Arca.CronSchedule.due_schedules/1` removed in Phase 1h. `Compendium.OCI.Auth.init_cache/0` removed in Phase 1o.
- **No circular dependencies found.**

---

## Silent Failure Classification

Open issues ranked by severity for Core vs Arx editions. Updated 2026-03-16 (twenty-seventh pass). 16 items fixed in Phases 1j–1n. 4 new items from 26th-pass audit.

| Issue | Core OK? | Arx OK? | Priority | Phase |
|-------|----------|---------|----------|-------|
| ~~PubSub broadcast ignored in TelemetryBridge (6 sites)~~ | ~~Yes~~ | ~~NO~~ | ~~P2~~ | ~~1o~~ FIXED |
| ~~PubSub broadcast ignored in 6 secondary sites~~ | ~~Yes~~ | ~~Yes~~ | ~~P3~~ | ~~1o~~ FIXED |
| ~~RetentionScheduler overlap guard~~ | ~~N/A~~ | ~~NO~~ | ~~P2~~ | ~~1o~~ FIXED |
| ~~Dockerfile `mix compile \|\| true`~~ | ~~Yes~~ | ~~Yes~~ | ~~P3~~ | ~~1o~~ FIXED |
| ~~Edition check inconsistency (3 patterns, ~24 sites)~~ | ~~Yes~~ | ~~Yes~~ | ~~P3~~ | ~~1o~~ FIXED |
| OCI Cache not tenant-scoped | Yes | Compliance | P3 | 2.3 |
| Missing composite indexes on tenant columns | Yes | **NO** (perf) | P2 | 2.2 |
| No FK cascade from tenant tables to orgs/projects | Yes | **NO** | P2 | 2.2 |
| Executor audit write returns `{:ok, result}` on failure | Yes | Configurable | P2 | 2.4 |
| 14/16 LiveViews lack dedicated test coverage | Yes | **NO** (regression risk) | P3 | 2.5 |
| `mcp_origin.ex` plug untested | Yes | **NO** (security gap) | P3 | 2.5 |
| 8 Opus modules lack unit tests | Yes | Yes | P3 | 2.5 |
| 3 OCI modules lack tests (blob.ex, transport.ex) | Yes | Yes | P3 | 2.5 |

---

## Storage & Observability Assessment

Cross-referenced codebase against Arx Roadmap and industry best practices. Assessment of storage, logging, and observability foundations for multi-tenant Arx readiness.

### Current State Inventory

| Layer | Implementation | Tenant Scoped? | Configurable Backend? |
|-------|---------------|----------------|----------------------|
| **Database** | SQLite via Ecto (`Arca.Repo`) | Yes (`QueryHelpers.where_tenant/2`) | Compile-time adapter swap |
| **File Storage** | `Arca.Adapters.Local` filesystem | User-scoped paths (`users/{user_id}/`) | Yes — `Arca.Storage` behaviour |
| **ETS Cache** | `:arca_cache` (60s TTL, 10k max, nearest-to-expiry eviction) | Yes (org_id in key tuples) | No — hardcoded ETS |
| **OCI Token Cache** | Via `Arca.Cache` with TTL | Yes (via Arca.Cache key scoping) | No |
| **Running Tasks** | `:emissary_mcp_running_tasks` ETS | Yes (user_id + org_id in ETS 4-tuple) | No |
| **Elixir Logger** | Default formatter, 5 metadata fields | Yes (user_id, org_id, project_id, auth_method) | Logger backends only |
| **Telemetry** | Prometheus via `TelemetryMetricsPrometheus.Core` | Partial (metadata has tenant fields) | Reporter is configurable |
| **OpenTelemetry** | OTLP exporter (disabled by default) | No (resource-level only) | Yes (env vars) |
| **Audit Trail** | `Arca.AuditSink` behaviour + Console/JSONL sinks | JSONL: fixed (nil guard), Console: yes | Yes — pluggable sinks |
| **MCP Request Logs** | `mcp_logs` SQLite table + `Arca.McpLog` | Yes (org_id, project_id columns) | No — SQLite only |
| **Policy Logs** | `policy_logs` SQLite table + `Arca.PolicyLog` | Yes (org_id, project_id columns) | No — SQLite only |
| **Execution Events** | `Arca.Cache` (ETS) + PubSub streaming | Yes (org_id in cache key) | No — ETS only |
| **Structured Log Context** | `Cyfr.LoggerContext` | Yes | N/A |

### Remaining Issues

#### Retention Enforcement Status

`Arca.Retention` has full implementation including tenant-scoped cleanup with dry-run support. Available via MCP tool (`storage` tool, actions: `get`, `set`, `cleanup`). **Arx mode**: `Arca.RetentionScheduler` (added Phase 2.1a) runs `cleanup_all_executions/2` and `cleanup_mcp_logs/2` on configurable interval (default 6h). **Core mode**: `RetentionScheduler` returns `:ignore` — retention is manual only. `cleanup_all_executions/2` now surfaces per-tenant errors in result map and `RetentionScheduler` logs them (Phase 1l).

#### No Log Retention/Rotation Strategy

No mechanism for rotating or archiving old MCP logs, policy logs, or audit JSONL files. No per-tenant retention policies. No log volume limits per tenant (DoS via log flooding). See Phase 2.3.

### Structural Gaps (For Arx Readiness)

**OCI Cache not tenant-scoped.** `Compendium.OCI.Cache` (`oci/cache.ex`) uses a shared filesystem layout at `~/.cyfr/oci-cache/` with no org_id parameter. Since it is content-addressed (sha256 digests), there is no security risk (same content = same digest regardless of tenant). However, for strict compliance requirements (data residency, tenant isolation audits), the shared cache may need tenant-scoping. This is informational — no functional bug. See Phase 2.3.

**Logger backend not pluggable for external destinations.** Current Logger uses `"$time $metadata[$level] $message\n"` (`config/config.exs:42-44`). Arx users wanting Datadog/Splunk/ELK need JSON output. Metadata fields already present — just need a JSON formatter (like `LoggerJSON`). Config-only change. See Phase 2.1.

**Telemetry metrics lack tenant labels.** `EmissaryWeb.Telemetry` Prometheus metrics (`telemetry.ex:54-63`) have no `org_id` tag. Operators cannot filter by tenant for SLA monitoring, usage-based billing, or noisy-neighbor detection. See Phase 2.3b.

**OpenTelemetry lacks tenant attributes.** `config/runtime.exs:377-395` only sets `service.name: "cyfr"`. No tenant attributes on spans. See Phase 2.1.

**Storage adapter has no object storage implementation.** `Arca.Storage` behaviour is well-defined with 7 callbacks (`storage.ex:117-136`). Only `Arca.Adapters.Local` exists. Key gap: `append/3` is used for audit JSONL files — S3 doesn't support append natively. See Phase 2.3.

**MCP/Policy logs are SQLite-only.** `Arca.McpLog` and `Arca.PolicyLog` use Ecto schemas. Postgres migration is natural via adapter swap. Missing: log export/archival mechanism for compliance. See Phase 2.3.

**No metrics export endpoint configuration.** Prometheus via `TelemetryMetricsPrometheus.Core` with no configurable scrape endpoint path or auth. See Phase 2.3b.

### What's Already Good

1. **`Cyfr.LoggerContext`** (`logger_context.ex:20-27`) — Captures/restores metadata across process boundaries via `capture/0` + `restore/1`.
2. **`Arca.AuditSink` behaviour** (`audit_sink.ex`) — Pluggable, fault-isolated, configurable via config. JSONL sink nil-context guard fixed.
3. **`Arca.Storage` behaviour** (`storage.ex:117-136`) — Clean adapter pattern with 7 callbacks. Ready for S3/GCS implementation.
4. **Tenant scoping in DB** — `QueryHelpers.where_tenant/2` (`query_helpers.ex:36-45`) is systematic across all storage modules.
5. **Telemetry event design** — Comprehensive events with metadata including tenant fields. Good foundation for any reporter.
6. **PubSub tenant scoping** — `Sanctum.PubSub.topic/2` namespaces topics per-tenant in Arx mode.
7. **OpenTelemetry opt-in** — Already plumbed (`runtime.exs:377-395`), disabled by default.

### Tenant Scoping Strategy Matrix

| Data Type | Core | Arx Single-Node | Arx Multi-Node |
|-----------|------|-----------------|----------------|
| **Structured data** (policies, components, keys, sessions) | SQLite, no org_id | Postgres, org_id+project_id scoped | Same Postgres, same scoping |
| **Audit trail** | Console logger | DB + JSONL per-tenant + optional SIEM sink | Same + S3 archival sink |
| **MCP/Policy logs** | SQLite local | Postgres, tenant-scoped queries | Same + export to object storage |
| **Execution events** | ETS cache + PubSub | Same (ephemeral, ok per-node) | PubSub via `:pg` for cross-node |
| **WASM binaries** | Local filesystem | Local or shared FS | Object storage (S3 adapter) |
| **OCI cache** | Local filesystem | Per-node (rebuild is cheap) | Per-node |
| **Metrics** | Prometheus (optional) | Prometheus + tenant labels | Same + StatsD/Datadog option |
| **Traces** | OTEL (optional) | OTEL + tenant attributes | Same |
| **Logs** | Console text | JSON format + external shipping | Same |

### Core Edition Production Readiness

As of the twenty-sixth-pass audit (2026-03-16), Sanctum Core is **production-ready** for its intended use case: single-user, single-project, local operation.

| Area | Status | Notes |
|------|--------|-------|
| **Tests** | 2700 pass, 0 fail | All three apps green |
| **Compilation** | 0 warnings | `--warnings-as-errors` clean |
| **Error handling** | Comprehensive | Zero silent error-swallowing rescues, all storage uses `db_errors()`, all LiveViews log errors |
| **Security** | Complete | SSRF, path traversal, atom safety, CORS, API key validation |
| **Tenant isolation** | N/A for Core | Single-user sentinel; infrastructure ready for Arx |
| **Retention** | Manual only | By design — no DoS vector in single-user mode. MCP `storage cleanup` tool available |
| **Database** | SQLite WAL mode | Appropriate for single-user; no size concern at intended scale |
| **Filesystem** | Standard OS paths | `~/.cyfr/` — standard OS tooling (backup, cleanup) suffices |
| **Backups** | Documentation task | SQLite `.backup` or filesystem copy; no automated solution needed for Core |

**Known limitations** (not bugs):
- No automatic retention cleanup — intentional, see Retention Enforcement Status above
- `system_context/0` creates context without org_id — documented footgun, current callers verified safe
- OCI cache not tenant-scoped — content-addressed, no security risk in Core
- ETS cache `max_entries` is approximate due to concurrent `put()` — not a bug, soft limit by design

**Verdict**: No blocking issues for Core production use. Remaining roadmap items (2.1d onward) target Arx readiness. All hardening phases (0–1o) complete.

---

## Phase 1m: Test Quality Hardening + @impl Annotations — COMPLETE

3 P3 test fixes (OtelTenantHandler `|| true` assertions, simple_oauth async race, PolicyLog/McpLog dedicated tests — 34 new tests) + `@impl true` annotations (~30 callbacks across 9 GenServer modules). All completed 2026-03-16.

---

## Phase 1n: Pre-Arx Final Hardening — COMPLETE

3 P1 items (CronScheduler `db_errors()` module attributes for Postgres, MCP `min(limit, 1000)` on 7 handlers, ResourceRegistry 5-min read timeout) + 1 P3 RunningTasks flaky test fix. Completed 2026-03-16.

---

## Phase 1o: Post-Audit Hardening — COMPLETE

5 items from 26th-pass audit + 1 dead code cleanup. Completed 2026-03-16.

- [x] **TelemetryBridge PubSub safety** (`telemetry_bridge.ex`): Extracted `safe_broadcast/3` wrapping all 6 `Phoenix.PubSub.broadcast` calls in `case` + `rescue`. Handler can never be detached by broadcast failure. Secondary sites wrapped in `case`: `builds_live.ex:91`, `cron_scheduler.ex:550`, `compendium/mcp.ex:1128,1155`. `health_controller.ex:69` was already wrapped. Tests in `telemetry_bridge_test.exs` (10 tests).
- [x] **RetentionScheduler `{:continue, :first_run}`** (`retention_scheduler.ex`): `init/1` returns `{:ok, state, {:continue, :first_run}}` instead of scheduling immediately. `handle_continue/2` runs cleanup then schedules next run. Runs cleanup immediately on Arx startup. Note: GenServer serializes messages, so the prior "overlap" concern was a false alarm — the change is for immediate-startup cleanup behavior.
- [x] **Dockerfile `|| true` removal** (line 34): Changed `mix compile || true` to `mix compile`.
- [x] **Edition check documentation** (`sanctum_arx/edition.ex`): Added `## Edition Check Patterns` section to `@moduledoc` documenting Pattern A/B/C and when to use each.
- [x] **Dead code removal**: Removed `Compendium.OCI.Auth.init_cache/0` (no-op) and its call in `Cyfr.Application`.

---

## Phase 1p: Locus Cross-App Decoupling — COMPLETE

2 items from architecture assessment (twenty-seventh pass). Locus independence for distributed build plane readiness.

- [x] **Builder progress callback** (`builder.ex`): Extracted PubSub/SSEBuffer notification into `:on_progress` callback opt. Builder is now a pure compiler with zero Emissary/PubSub references. `Locus.MCP` constructs callback bridging to PubSub + SSEBuffer.
- [x] **Async post-compile registration** (`locus/mcp.ex`): Replaced synchronous `Compendium.MCP.handle` call with fire-and-forget `Task.start`. Compile response returns `registration: "pending"`. Fallback to `AutoIndexer.scan` on failure.

---

## Phase 2: Single-Node Arx Enablement

Phases 2.0a, 1g (including 1g-fix), 1h, 1h Addendum, 1i, 1j, 1k, and 1l all complete.

### 2.1a Retention auto-enforcement — COMPLETE (tenth pass)

- [x] **`Arca.RetentionScheduler` GenServer** (`retention_scheduler.ex`): Returns `:ignore` in Core mode. In Arx mode, runs `cleanup_all_executions/2` and `cleanup_mcp_logs/2` on configurable interval (default 6h via `:retention_scheduler_interval` config). Added to `Cyfr.Application` supervision tree. Tests in `retention_scheduler_test.exs`.

### 2.1b Observability bootstrapping — COMPLETE (tenth pass)

- [x] **JSON logger formatter** (`json_formatter.ex`): `format/4` outputs single-line JSON with timestamp, level, message, and metadata. Activated by `CYFR_LOG_FORMAT=json` env var in `runtime.exs`. Core keeps human-readable default. Tests in `json_formatter_test.exs`.
- [x] **OTEL tenant attributes** (`otel_tenant_handler.ex`): Telemetry handler attaches to Phoenix endpoint/router events, adds `tenant.org_id`/`tenant.project_id`/`tenant.user_id` span attributes. Guards with `Code.ensure_loaded?(OpenTelemetry)`. Attached in `Cyfr.Application.start/2` when OTEL enabled. Tests in `otel_tenant_handler_test.exs`.

### 2.1c Auth chain repair — COMPLETE (tenth pass)

The OIDC → membership → context chain is now functional. All Arx tenant-scoped operations receive proper org_id/project_id.

**Fix summary:**
- [x] **`Sanctum.User` struct** (`user.ex:16`): Added `:org_id` and `:project_id` fields (both default nil). Updated `@type t` typespec.
- [x] **OIDC membership resolution** (`oidc.ex:70-82`): `authenticate/1` now calls `resolve_membership/1` which, in Arx mode, looks up `SanctumArx.Memberships.list_by_user/1`. Single-org → auto-assigns org_id. Multi-org → picks first accepted (Phase 2.1d adds org picker). Zero-org → leaves nil (handled downstream). Also resolves default project via `SanctumArx.Projects.list_by_org/2`.
- [x] **`Session.row_to_user/1`** (`session.ex:439-449`): Now uses struct fields directly (`%User{..., org_id: row[:org_id], project_id: row[:project_id]}`) instead of `Map.put` hack.
- [x] **`MCPSession.context_from_user/1`** (`mcp_session.ex:342-370`): Now calls `maybe_resolve_membership/1` to re-resolve stale sessions. Returns `{:error, :missing_tenant}` for users with no org_id in Arx mode. All call sites handle the error (hydration, get_context, re-initialize). New `missing_tenant_error_response/1` returns 403.
- [x] **`PrismWeb.LiveAuth.on_mount/4`** (`live_auth.ex:16-68`): Now calls `maybe_resolve_membership/1` for stale sessions. In Arx mode, redirects to `/login?error=no_org` if org_id is empty after resolution.
- [x] **`system_context/0` documentation** (`sanctum.ex:97-107`): Added `@doc` warning that it must NOT be used for tenant-scoped operations.
- [x] **AuthController cascade**: Works automatically — `Session.create/1` reads `user.org_id` from struct fields, so sessions now carry org_id when populated by OIDC auth.
- **Tests**: `user_struct_test.exs` (5 tests), `mcp_session_test.exs` (2 tests updated/added for Arx org_id enforcement).

### 2.1d Org/project selection UI/API

Depends on 2.1c, 1h, 1j, 1l, 1n — **all complete**. No blockers.

- [ ] **Selection strategy**: Auto-select for single-org users, picker modal for multi-org, `X-Cyfr-Org-Id` header for programmatic API access.
- [ ] **Prism Shell org picker**: LiveView component using `SanctumArx.Memberships.list_by_user/1`. Rendered in Shell chrome for multi-org users. Auto-selects when user has exactly one org membership.
- [ ] **Switch endpoint**: `POST /api/auth/switch-org` — validate membership via `SanctumArx.Memberships`, update session with new org_id/project_id, return new token. Reject if user has no membership in target org.
- [ ] **Session propagation**: MCPSession already re-resolves membership on context hydration; switch updates session storage. Verify that org switch invalidates stale cached contexts.
- [ ] **Integration test**: org create → membership assign → switch org → verify context carries new org_id through full request path.

### 2.1e Membership/role enforcement

Depends on 2.1c (context must have org_id) and 2.1d (user must be able to select org).

- [ ] **Enforce membership/role checks through `Sanctum.Context.authorize/3`**.
- [ ] **Add operator and tenant admin surfaces in Prism Shell** for orgs, projects, memberships, and plan-aware settings.

### 2.1f Tiered policy ceilings — COMPLETE

Cascading resource ceilings: Platform (absolute max) → Org/Plan tier → Resolved policy. Prevents policy escalation beyond infrastructure/plan limits.

- [x] **`Sanctum.Policy.Ceiling`** (`policy/ceiling.ex`): Platform ceiling (hardcoded + `:cyfr, :platform_ceiling` config override), plan ceiling (`:cyfr, :plan_ceilings` config), `effective_ceiling/1` (Core = platform only, Arx = platform → plan cascade with `Arca.Cache` org plan lookup), `clamp/2` (runtime safety net on `%Policy{}` structs), `validate/2` (save-time rejection with descriptive errors), `merge_ceilings/2` (composable for future project-level layer).
- [x] **Save-time validation**: `PolicyStore.put/3` and `put_type_default/3` reject values exceeding ceiling in `with` chain (after `FieldSchema.validate_fields`, before `get_rate_limit_window_seconds`).
- [x] **Runtime clamp**: `PolicyEnforcer.build_execution_opts/3` clamps resolved policy to ceiling before extracting timeout/memory opts.
- [x] **MCP `get_ceiling` action**: Returns effective ceiling + edition label. `get_effective` response now includes raw policy, clamped `:effective` values, and `:ceiling` map.
- [x] **Edition gating**: `Application.get_env(:cyfr, :edition, :core) == :arx` (matches `live_auth.ex`/`mcp_session.ex` pattern) — no SanctumArx compile dependency.
- [x] **Platform ceiling defaults**: timeout=30m, max_memory_bytes=256MB, max_request_size=10MB, max_response_size=50MB, rate_limit_requests=10000, max_concurrent_tasks=50, batch_timeout=30m. Allow-list fields have no ceiling.
- [x] **Tests**: 32 ceiling unit tests, 3 PolicyStore ceiling validation tests, 2 PolicyEnforcer clamp tests. All pass.

### 2.2 Tenant lifecycle

- [ ] Provision org + default project + initial admin membership in one transaction.
- [ ] Add suspend, reactivate, delete, export (schemas, audit logs, execution history, components, API keys), and secret rotation flows.
- [ ] Define background cleanup and audit requirements for tenant deletion.
- [ ] **Tenant provisioning webhook/API**: For billing integration — webhook on org create/suspend/delete to notify external billing systems (Stripe, etc.). Required for hosted Arx SaaS model.
- [ ] **Backup/restore strategy**: Automated DB backups, point-in-time recovery, per-tenant data export for GDPR compliance.
- [ ] **Secret rotation without restart**: `arx_runtime.exs` reads `CYFR_JWT_SIGNING_KEY` once at boot. No mechanism to rotate without restart. `ApiKeyStorage.rotate_key/5` exists but has no operator workflow.
- [ ] **Composite indexes on tenant columns** (from Phase 1l audit): Tables `api_keys`, `permissions`, `secrets`, `secret_grants` lack `(org_id, project_id)` compound indexes — `WHERE org_id = ?` queries can't use existing unique indexes whose leading columns differ. New migration required before Arx deployment.
- [ ] **Tenant deletion cascade strategy** (from Phase 1l audit): `projects` and `memberships` cascade correctly (migration `20260314000001`), but all other tenant-scoped tables (`components`, `policies`, `secrets`, `executions`, `api_keys`, etc.) have no FK to `orgs`/`projects`. Explicit cleanup required in tenant deletion workflow.

### 2.3 Durable hosted backends

- [ ] Add Postgres support as the Arx data backend. Core stays on SQLite.
- [ ] SQLite-to-Postgres migration audit:
  - Text search, PRAGMA statements, WAL mode (`application.ex:96-103`) are SQLite-specific.
  - Review all `Arca.Repo.query!/1` direct SQL calls for dialect compatibility.
  - `Arca.Cache` is ETS-based — multi-node Arx needs distributed cache or per-node with PubSub invalidation.
  - **Prerequisite**: Phase 1h + Phase 1h Addendum + Phase 1n all COMPLETE. All storage modules, SanctumArx CRUD modules, and CronScheduler use `db_errors()` — `Postgrex.Error` will be caught. Phase 1i P0/P1 should also complete before Postgres migration (SharedEngine crash, Cache.put contract, LiveView error handling).
  - Verify `on_conflict` syntax compatibility: `on_conflict: {:replace, [...]}` and `on_conflict: :nothing` across all storage modules.
  - Enumerate and audit all PRAGMA-specific patterns (`configure_database` at `application.ex:106-119`).
- [ ] Add object storage support for Arx artifacts and large binaries.
- [ ] Ensure OCI cache (`oci/cache.ex`) works with configurable non-local storage for Arx deployments. Note: OCI cache is content-addressed (sha256) so shared filesystem is safe, but compliance-sensitive deployments may want tenant-scoped cache paths.
- [ ] Add log retention/rotation — no mechanism for rotating MCP logs (`mcp_log.ex`), policy logs (`policy_log.ex`), or audit JSONL files. Add per-tenant retention TTL config + periodic cleanup.
- [ ] `Arca.Storage.append/3` (`storage.ex:124`) is not S3-compatible (S3 has no append). **Design decision (Phase 2.0a)**: Buffer-and-flush approach — S3 audit sink buffers events in-memory, flushes as single PutObject on interval (30s) or size threshold (1MB/1000 events), with graceful shutdown flush. `AuditSink.write/2` contract unchanged; S3 adapter uses `put/3` with timestamped keys (`audit/{org_id}/{date}/{timestamp}-{uuid}.jsonl`) instead of `append/3`. Alternatives rejected: per-event objects (API cost), multipart upload (5MB minimum), external brokers (violates "no external brokers" principle).
- [ ] **JSONL audit file size limits**: Unbounded append writes to audit JSONL files are a DoS vector in hosted Arx. Add file size limits and rotation before enabling multi-tenant audit sinks.
- [ ] Log export mechanism — batch query from `mcp_logs`/`policy_logs` + write to storage adapter for compliance archival.
- [ ] **Postgres connection pooling strategy**: Current `pool_size: 20` is for SQLite. `arx_runtime.exs` defaults to 10. Need: configurable pool per environment, statement timeouts, queue limits.
- [ ] **SQLite-to-Postgres data migration tooling**: Customers on Core upgrading to Arx need `mix cyfr.migrate_to_postgres`.
- [ ] **Dockerfile health check timeout**: `HEALTHCHECK --timeout=3s` may be too aggressive for Arx deployments with cold Postgres connections. `--start-period=15s` provides initial grace but steady-state 3s timeout could flap under load. Consider 5s or configurable via build arg.

### 2.3b Observability & metrics

- [ ] Add `org_id` tag to Prometheus metrics in Arx mode — `EmissaryWeb.Telemetry` metrics (`telemetry.ex:54-63`) have no tenant label. Gate with `SanctumArx.Edition.arx?()` to avoid cardinality in Core.
- [ ] Metrics endpoint auth — `TelemetryMetricsPrometheus.Core` scrape endpoint has no authentication. Arx deployments need authenticated metrics access.
- ~~Configurable telemetry reporters~~ — **Deferred**. Prometheus works with every monitoring system via remote-write. Revisit when a customer requests StatsD/Datadog.

### 2.4 Arx operational controls

- [ ] Per-tenant rate limits and quotas (extend `Opus.RateLimiter` which already has `Code.ensure_loaded?` guard at `policy.ex:545`). Note: rate limiter infrastructure already accepts `org_id` in rate key (`rate_limiter.ex:75,82`) — per-tenant enforcement is partially ready.
- [ ] Plan-tier enforcement for seats, API keys, executions, storage, and build concurrency.
- [ ] Hosted-safe registry, secret, and policy behavior with no fallback to local-only assumptions.
- [ ] **Per-tenant execution semaphore fairness**: `ExecutionSemaphore` is global (`max: 128`). One busy tenant can exhaust slots. Add per-tenant allocation or fair queuing.
- [ ] **Admin REST API**: Operator-only endpoints for org/project/membership CRUD, plan changes, suspension.
- [ ] **HTTP-layer rate limiting**: Per-tenant connection limits and request rate limits at the Arx gateway level. Current `Opus.RateLimiter` handles execution-level limits but HTTP endpoints have no rate limiting — a single tenant can exhaust Bandit connection pool. Add Plug-level rate limiting with configurable per-tenant thresholds.
- [ ] **Configurable audit write failure policy** (from Phase 1l audit): `Opus.Executor.finalize_execution/3` (`executor.ex:235-294`) logs error and emits telemetry on audit write failure, includes `audit_error` in metadata, but returns `{:ok, result}`. For compliance Arx deployments, add configurable `:audit_write_policy` — `:warn` (current behavior, default) or `:strict` (return `{:error, :audit_write_failed}`).

### 2.5 Arx validation matrix

- [ ] Integration tests for org/project auth flows.
- [ ] Integration tests for tenant lifecycle.
- [ ] Adapter contract tests for SQLite/Core and Postgres/Arx behavior.
- [ ] Browser/API coverage for credentialed cross-origin Arx flows (CORS credentials infrastructure already in place at `cors.ex:65-66`).
- [ ] **LiveView test coverage** (14/16 untested): Prioritize `secrets_live.ex`, `api_keys_live.ex` (security-sensitive), then `dashboard_live.ex`, `components_live.ex`, `executions_live.ex`, `logs_live.ex`, `builds_live.ex`, `policies_live.ex`, `schedules_live.ex`, `settings_live.ex`, `agent_live.ex`, `component_detail_live.ex`, `log_detail_live.ex`, `shell_live.ex`. Only `auth_live.ex` and `shell_compat.ex` have existing tests.
- [ ] **Plug test coverage**: `mcp_origin.ex` (security-relevant — origin validation), `execution_events_controller.ex` (SSE streaming).
- [ ] **Opus module unit tests** (8 missing): Prioritize `executor.ex` (core execution path), `secret_masker.ex` (security), then `http_handler.ex`, `http_stream_handler.ex`, `storage_handler.ex`, `formula_handler.ex`, `shared_engine.ex`, `component_type.ex`.
- [ ] **OCI module tests** (3 missing): `blob.ex`, `transport.ex` (401/retry/redirect paths), `errors.ex`.

### 2.6 Execution-path performance

- [ ] Add resolved policy cache — `Sanctum.Policy.get_effective/2` resolution chain does multiple DB lookups on cache miss. Cache the resolved effective policy result with invalidation on policy write.
- [ ] Add resolver cache to `Compendium.Resolver`. Every versionless component reference hits the registry — zero caching. Add TTL cache for version resolution results.

**Parallelization opportunities:**
- Phase 2.5 test coverage can run in parallel with any phase.
- Composite indexes (Phase 2.2 sub-item) can be pulled forward to run in parallel with 2.1d.
- Effective critical path: **2.1d → 2.1e → 2.2+** (with 2.2 composite indexes, 2.3b, 2.5, and 2.6 parallel).

Exit criteria for Phase 2:

- Arx is usable for hosted or on-prem operation on a single durable node.
- Tenant boundaries are enforced end to end, not just in storage tables.
- Core and Arx are clearly the same product with different enabled capabilities.

---

## Phase 3: Distributed Arx Scaling

Only start after single-node Arx is correct. Blocked on Phase 2.

### 3.0 Singleton and scaling inventory

Complete inventory from source audit. Every named process, ETS table, Registry, and file I/O dependency that needs a multi-node strategy.

#### Named Processes (14 singletons)

Note: `Opus.SharedEngine` is an Agent, not a GenServer. `AsyncTracker` and `ExecutionEventBuffer` are dynamic (per-execution), not singletons.

| Process | Type | Location | Multi-node strategy |
|---------|------|----------|---------------------|
| `Opus.CronScheduler` | GenServer | `opus/application.ex:30` | Leader election via `:global` — only one node fires cron |
| `Opus.ExecutionSemaphore` | GenServer | `opus/application.ex:21` | Per-node (guards local WASM memory) — correct as-is |
| `Opus.RateLimiter` | GenServer | `opus/application.ex:17` | Distributed counters (`:persistent_term` + `:erpc`) or per-node + aggregate |
| `Opus.SharedEngine` | Agent | `opus/application.ex:19` | Per-node (WASM compile cache) — correct as-is |
| `Emissary.MCP.ToolRegistry` | GenServer | `cyfr/application.ex:53` | Cluster invalidation via PubSub broadcast on register/deregister |
| `Emissary.MCP.ResourceRegistry` | GenServer | `cyfr/application.ex:54` | Cluster invalidation via PubSub broadcast |
| `Emissary.MCP.SSEBuffer` | GenServer | `cyfr/application.ex:55` | Sticky sessions (route SSE connections to originating node) |
| `Emissary.MCP.RunningTasks` | GenServer | `cyfr/application.ex:57` | Needs `:erpc` for cross-node task cancel |
| `Prism.AppRegistry` | GenServer | `cyfr/application.ex:63` | Shared filesystem or sync via PubSub |
| `Arca.Cache.Sweeper` | GenServer | `cyfr/application.ex:46` | Per-node (sweeps local ETS) — correct as-is |
| `Arca.RetentionScheduler` | GenServer | `cyfr/application.ex:47` | Per-node (returns `:ignore` in Core) — correct as-is |
| `Arca.AuditHandler` | GenServer | `cyfr/application.ex:48` | Per-node (dispatches to configured sinks) — correct as-is |
| `EmissaryWeb.Telemetry` | Poller | `cyfr/application.ex:50` | Per-node — correct as-is |
| `PrismWeb.Telemetry` | Poller | `cyfr/application.ex:61` | Per-node — correct as-is |
| `Prism.TelemetryBridge` | GenServer | `cyfr/application.ex:62` | Per-node — correct as-is |

#### ETS Tables (2)

| Table | Owner | Multi-node strategy |
|-------|-------|---------------------|
| `:arca_cache` | `Arca.Cache.init/0` | Distributed cache or per-node with PubSub invalidation |
| `:emissary_mcp_running_tasks` | `Emissary.MCP.RunningTasks.init/0` | Needs `:erpc` for cross-node task cancel |

#### Registries (2)

| Registry | Location | Multi-node strategy |
|----------|----------|---------------------|
| `Opus.ExecutionRegistry` | `opus/application.ex:22` | `:pg` process group for cross-node execution lookup + cancel |
| `Opus.ExecutionEventBuffer.Registry` | `opus/application.ex:24` | Route event subscriptions via PubSub to originating node |

#### File I/O hot zones (5)

| Path | Used by | Multi-node strategy |
|------|---------|---------------------|
| `~/.cyfr/registry/` | `Compendium.Registry`, `Arca.Adapters.Local` | Shared FS or object storage adapter |
| `~/.cyfr/oci-cache/` | `Compendium.OCI.Cache` | Per-node or shared (rebuild is cheap) |
| `data/` | `Arca.Adapters.Local.base_path/0` | Object storage adapter for Arx |
| `data/apps/` | `Prism.AppRegistry` | Shared FS or app discovery service |
| `components/` | `builds_live.ex`, component storage | Shared FS or object storage |

#### PubSub

- `Emissary.PubSub` (`cyfr/application.ex:44`) — currently uses local adapter.
- **One config change** to `:pg` adapter enables cluster-wide pub/sub.

### 3.1 Real release profiles

Current state: `cyfr` and `cyfr_arx` releases are identical except for `arx_runtime.exs` config provider (`mix.exs:33-54`). Both include all three apps with `:permanent` startup.

- [ ] `cyfr`: Core all-in-one (current — no change).
- [ ] `cyfr_arx`: control plane only (remove `opus: :permanent`, `locus: :permanent`).
- [ ] ~~`cyfr_arx_executor`: Opus execution node.~~ **Demand-driven** — single-node Arx handles substantial load.
- [ ] ~~`cyfr_arx_builder`: Locus build node.~~ **Demand-driven** — same as above.
- [ ] Health checks, boot validation, and release docs for each profile.

### 3.2 Control-plane clustering

- [ ] Enable DNS-based node discovery for clustered Arx deployments (DNSCluster already wired at `application.ex:43`, defaults to `:ignore`).
- [ ] Switch PubSub to `:pg` adapter for cluster-wide messaging.
- [ ] Resolve singleton concerns:
  - `Arca.Cache.Sweeper`: per-node is correct, but `:arca_cache` ETS needs invalidation broadcast.
  - `Emissary.MCP.ToolRegistry` / `ResourceRegistry`: PubSub-based cluster invalidation.
  - `Emissary.MCP.SSEBuffer`: sticky session routing.
- [ ] Make session and task coordination (`Emissary.TaskSupervisor`) correct across nodes.

### 3.3 Distributed execution plane

- [ ] Move Opus dispatch to explicit executor nodes via `:erpc`.
- [ ] Support cross-node cancellation:
  - `Opus.ExecutionRegistry` is node-local (`opus/application.ex:22`). Replace with `:pg` group.
  - `Opus.ExecutionEventBuffer` (`opus/application.ex:24-25`): route event streaming via PubSub.
  - `:emissary_mcp_running_tasks` ETS: cross-node cancel via `:erpc`.
- [ ] Keep `Opus.SharedEngine` and WASM compile caching node-local (correct).
- [ ] `Opus.ExecutionSemaphore`: stays per-node (guards local WASM memory — correct).
- [ ] `Opus.RateLimiter`: either distributed counters or per-node with periodic aggregate sync.
- [ ] `Opus.CronScheduler`: leader election via `:global` — only one node fires cron schedules.

### 3.4 Distributed build plane

- [ ] Move Locus compilation to explicit builder nodes.
- [ ] WASM validation (`Locus.Validator`) stays in cyfr — control plane can validate without builder runtime.
- [ ] Store build artifacts in durable shared storage (currently filesystem at `Arca.Adapters.Local.base_path/0`).

### 3.5 Distributed infrastructure choices

- [ ] Add a cache abstraction only when multi-node behavior requires it (currently `Arca.Cache` is ETS-based per-node).
- [ ] Prefer BEAM-native `:pg`, `:erpc`, PubSub, and supervisors over external brokers.

Exit criteria for Phase 3:

- `cyfr`, `opus`, and `locus` scale independently.
- Cluster behavior is explicit and tested.
- No distributed feature is added purely because it is possible.

---

## Things We Should Not Do Yet

- Do not treat partial Arx schemas as proof that hosted Arx is ready.
- Do not introduce Redis, Kafka, or service-to-service HTTP just to simulate separation.
- Do not split nodes before Core and single-node Arx are green.
- Do not let Core become configurable enough that it turns into a second hosted product shape.
- Do not add Mnesia or queue abstractions without a concrete use case that demands them.
- Do not add configurable telemetry reporters until a customer requests an alternative to Prometheus.

---

## Items That Are Over-Engineered or Premature

Removed or deferred from the active roadmap:

- **Configurable telemetry reporters** (was Phase 2.3b): Prometheus works with every monitoring system via remote-write. Defer until a customer requests StatsD/Datadog.
- **`cyfr_arx_executor` and `cyfr_arx_builder` release profiles** (was Phase 3.1): Keep as aspirational, not scheduled. Single-node Arx handles substantial load. Marked demand-driven.
- **Mnesia evaluation** (was Phase 3.5): No concrete use case. Per-node ETS + PubSub invalidation is proven. Mnesia adds netsplit complexity.
- **Queue abstraction** (was Phase 3.5): `Task.Supervisor` + `DynamicSupervisor` handles current workload. YAGNI until persistence/retry/backpressure is needed.

---

## Immediate Next Sequence

Phases 0–1o, 1.5, 1g/1g-fix, 1h/1h Addendum, 2.0/2.0a, 2.1a–c, 2.1f, and 2 Reliability all **COMPLETE** — see Completed Phases. Core edition is production-ready. All hardening phases (0–1o) complete.

1. ~~Phase 1o — Post-audit hardening.~~ **COMPLETE.**
2. Phase 2.1d — Org/project selection UI/API.
3. Phase 2.1e — Membership/role enforcement.
4. ~~Phase 2.1f — Tiered policy ceilings.~~ **COMPLETE.**
5. Phase 2.2 — Tenant lifecycle + backup/restore + provisioning webhook + composite indexes + tenant deletion cascade.
6. Phase 2.3 — Postgres + object storage + pooling + migration tooling + OCI cache compliance note.
7. Phase 2.3b — Observability metrics.
8. Phase 2.4 — Arx operational controls + semaphore fairness + admin API + HTTP rate limiting + audit write policy.
9. Phase 2.5 — Arx validation matrix + test coverage gaps (LiveViews, plugs, Opus modules, OCI modules).
10. Phase 2.6 — Execution-path performance.

**Critical path**: `2.1d → 2.1e → 2.2+`
**Parallel**: `2.2 composite indexes`, `2.5 test coverage` (can run in parallel with any phase)

**Next**: Phase 2.1d (org/project selection UI/API).
