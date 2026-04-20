# CYFR Auth & Identity Refactor

> **Status: CLOSED 2026-04-20.** Phases A / B / C / D.1 / D.2a shipped. Arx Shell UI + cross-edition integration tests are tracked in `docs/Arx_Roadmap.md` §2.1e.1. This document is archival; §2 captures the verifiable current state, §4 the ongoing Arx-deploy compliance contract.
>
> **Verification stance.** Every claim in §2 is verifiable against commit HEAD (cyfr ~2026-04-19; cyfr.run `58af29d` 2026-04-18) via `rg` / `Read`. §3 describes Phase A changes as deltas against §2. §4 enumerates Arx-deployment MUST/MUST NOT clauses. No §2 sentence prescribes change language; no §3 sentence describes current code behavior except as an explicit cross-reference.

## 1. Architectural invariants

These seven invariants are pre-requisites for every later section. §3 upholds them; §4 enforces them against Arx deployments. Every §3 and §4 subsection header names the invariant(s) it touches.

1. **Sanctum = auth service.** The **auth sliver** (`apps/cyfr/lib/sanctum/auth/*` + `apps/cyfr/lib/sanctum/mcp.ex`) is Compendium-free. Component-aware Sanctum modules (`policy.ex`, `policy_store.ex`, `oauth.ex`, `tincture_access.ex`) retain their Compendium dependencies by design — outside the sliver, orthogonal to this refactor.
2. **Compendium = registry service.** Registry URL, component ref, OCI client, `CredentialStore`, and namespace-membership mirror all live under `apps/cyfr/lib/compendium/`. cyfr.run is the remote peer; cyfr talks to it only through Compendium.
3. **Edition swap point for auth = `:cyfr, :auth_provider`.** No module branches on `:cyfr, :edition` for auth decisions. Other `:edition` readers (policy ceilings, tenant scoping, registry URL pinning, Arx UI presence) are orthogonal infrastructure gates.
4. **`Sanctum.User.id` = `"<provider>|<iss>|<subject>"` on both editions.** Pipe-delimited, scheme-prefixed `iss` (RFC 7519 shape). Edition is **never** part of the id. Same human via same provider on Core and Arx ⇒ same id ⇒ same cyfr.run identity.
5. **Accepted cross-layer coupling = auth → registry handoff after `Session.create/1`.** `Sanctum.Auth.DeviceFlow.poll_for_session/2` and `EmissaryWeb.AuthController.callback/2` MAY call `Compendium.CyfrRun.Client.probe_identity/3` + `Compendium.Registry.CredentialStore.put/4`. **No other edges from the auth sliver into Compendium are permitted.**
6. **Single-registry scope.** cyfr talks to cyfr.run apex (Core) OR a self-deployed cyfr.run (Arx). No ghcr.io, Docker Hub, or generic OCI registry is in scope. `Compendium.OCI.Auth` collapses accordingly (see §3).
7. **Arx Lane 1 hard requirement.** Arx deployments that use GitHub/Google as the IdP MUST use `ueberauth_github` / `ueberauth_google` directly. MUST NOT wire `ueberauth_oidcc` against github.com / accounts.google.com issuers — that would yield `id = "oidcc|..."` and break §1.4. (Lane 2 enterprise OIDC remains `ueberauth_oidcc` against real enterprise issuers only.)

**Goal in one sentence.** cyfr owns identity; cyfr.run is a minimal-identity registry holding `namespaces` + `namespace_members` + `push_tokens` with opaque-bearer auth. The push token is the single coupling point between the two services.

**Core shape.** One BEAM node serves N users (gated by `CYFR_ALLOWED_USER` at `config/runtime.exs:288`); each user has their own session rows and their own per-namespace push tokens; users share infra but never credentials. One project per instance (`project_id: "default"`, `org_id: ""` / nil — see §2.2 for today's asymmetry).

**Arx shape.** Same id format. Same push-token flow. Same cyfr.run wire protocol. Only `:cyfr, :auth_provider` + registry URL envs differ. Zero cyfr.run schema change for Arx; `identity_links` is Arx-side-only (Phase D, Lane 2 only).

---

## 2. Current state

Each bullet below is verifiable today by `rg` / `Read`. No bullet prescribes change; §3 owns all change language. Deltas after Phase A are computable against §2.4 `rg` counts.

### 2.1 cyfr.run (Go) — `/Users/moonmoon/Projects/cyfr.run/`

**Post-Phase A state (shipped 2026-04-18, HEAD `58af29d`).** Namespace-model + opaque push-token auth live. Pre-Phase-A internals (JWT issuer, OIDC validator, device-flow endpoints, orgs/publishers tables, `autoJoinOrgsByDomain`, 7-field `CyfrContext`, `/v1/auth/*` routes) are fully removed. `CyfrContext` is `{NamespaceSlug, TokenID, CreatedVia, RequestID}`. All 401s set `WWW-Authenticate: Basic realm=...` for Docker/OCI compat. For the historical pre-refactor surface (original §2.1 bullets), see cyfr.run git history pre-commit `0fe1200`.

### 2.2 cyfr (Elixir) — `/Users/moonmoon/Projects/cyfr/apps/cyfr/`

- **`Sanctum.User` struct** is `[:id, :email, :provider, :org_id, :project_id, permissions: []]` at `user.ex:18`.
- **`Sanctum.User.id` is raw** at every construction site today (no compound format):
  - `user.ex:31-38` (`from_oidc_claims/1`) → `id: claims["sub"]` (subject string only).
  - `simple_oauth.ex:43-48` → `id: user_info.id`.
  - `device_flow.ex:330-339` (`create_session/2`) → `id: user_info.id`.
  - `sanctum_arx/auth/oidc.ex:72-80` → `id: to_string(auth.uid)`.
  - `local/0` at `user.ex:54-61` → `id: "local_user"` sentinel.
  - `sanctum_arx/auth/oidc.ex:105-110` API-key path → `id: "api_key:<name>"` sentinel.
- **Providers.** `Sanctum.Auth.SimpleOAuth.@supported_providers` is `[:github]` only at `simple_oauth.ex:36`. No Google on Core today. `jose ~> 1.11` at `mix.exs:41`; HS256 verify at `context.ex:277` (cyfr's own session crypto).
- **`Compendium.Registry.CredentialStore`** — key format `_registry.{registry}.{user_id}` at `credential_store.ex:110-112`; `String.to_existing_atom` at `:150`. One credential per user per registry today.
- **`Compendium.OCI.Auth.resolve_credentials/2`** at `auth.ex:128-139` dispatches on `:basic`/`:bearer`/`:oauth2_client`/`:key_pair` (branches at `:27-57`). **Four external call sites**: `compendium/mcp.ex:511`, `compendium/mcp.ex:1707` (anonymous-probe inside `do_oci_pull/2`), `compendium/cyfr_run/client.ex:220`, `compendium/oci/client.ex:1033`. Plus two internal self-calls at `auth.ex:33, :185`. Token cache at `:145-161`, realm-exchange at `:167-227`, `resolve_any_credential/1` at `:275-280` (cross-registry fallback via `CredentialStore.get_for_registry/1`).
- **Cross-user credential fallback exists today.** `Compendium.Registry.Identity.resolve_core_credentials/2` at `identity.ex:98-122` falls through to `CredentialStore.get_for_registry/1` (the `:not_found` arm begins at `:110`), returning "any user's credential for this registry" — privacy leak in multi-user Core. Matching fallback at `oci/auth.ex:275-280`.
- **`Compendium.Registry.Identity.resolve_credentials/1`** is a private helper at `identity.ex:88-96` with one call site at `:22` inside `identity/1`. Name collides with `Compendium.OCI.Auth.resolve_credentials/2` (unrelated concerns).
- **`Registry.Identity.do_whoami/2`** at `:35-77` posts Basic auth (`Base.encode64("#{username}:#{password}")` at `:40`); reads `data["publisher_name"]` at `:59`. `registry_url/0` at `:79-84` defaults to `"registry.cyfr.run"` (literal at `:81-82`).
- **`Sanctum.ComponentRef.@namespace_regex`** at `:41` is `~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/` — **disallows dots entirely**. Today's validator rejects `stripe.com` outright, not just the parser. `parse_ns_name/1` at `:398-417`; `validate_namespace/1` at `:448-468`; `validate_publisher/1` at `:482`; `validate_ref_parts/2` at `:528`. Doctests at `:440-444, 477-478, 492-493`.
- **Session cookies** at `emissary_web/endpoint.ex:20-21` + `prism_web/endpoint.ex:13-14` set `same_site: "Lax"` + `http_only: true` but **missing `secure: true`**.
- **`Sanctum.MCP` Compendium edges (violate §1.1) at two call sites:** `sanctum/mcp.ex:445` (whoami's `Compendium.Registry.Identity.identity(ctx)` call) and `sanctum/mcp.ex:560` (`Compendium.Registry.CredentialStore.put(...)` inside the `registry-login` handler defined at `:511`). Today's `session.whoami` at `:438-447` returns `{user_id, org_id, scope, permissions, registry: Compendium.Registry.Identity.identity(ctx)}`. Also `sanctum/mcp.ex:512` holds a `"registry.cyfr.run"` literal as default inside `Map.get(args, "registry", "registry.cyfr.run")` inside the `registry-login` handler body — **NOT** the handler signature itself.
- **`api_keys` project-scoping is half-landed.** Migration `20260312000001_add_tenant_columns_and_scope_rename.exs` added `project_id` column at `:20-22` (`NOT NULL DEFAULT 'default'`) and 4-col unique index `(name, scope_type, org_id, project_id)` at `:25`. However its `drop_if_exists unique_index(:api_keys, [:name, :scope_type])` at `:24` is a **typo signature mismatch** — the original 2024 migration `20240303000001_create_api_keys.exs` created `unique_index(:api_keys, [:name, :scope_type, :org_id])` (3-col, named `api_keys_name_scope_type_org_id_index`); the 2026 migration's `drop_if_exists` line was meant to drop *that* but wrote a 2-col signature. Result: the stale 3-col index `api_keys_name_scope_type_org_id_index` survives and dominates the new 4-col, shadow-breaking project scoping. §3 Phase A `DROP INDEX IF EXISTS api_keys_name_scope_type_org_id_index` (line ~697) explicitly fixes this. `api_key.ex:345-356` `build_key_metadata/2` **does not emit** `:project_id` (key absent in returned map; consumers reading `metadata[:project_id]` at `mcp_session.ex:503` get nil for a missing key). `arca/api_key_storage.ex` query sites don't filter on `project_id` either.
- **`Context.local/0` vs `SessionStorage` `org_id` asymmetry.** `context.ex:68-77` omits `org_id` (defaults to nil via `build/1`); `Arca.SessionStorage` at `session_storage.ex:36-37` fills missing `org_id` with `""`. Downstream equality checks that compare `org_id` across both surfaces will see nil vs `""`.
- **`Compendium.OCI.Client`** at `:1032-1050` base64-decodes JWT payloads without signature verification (`resolve_publisher_name/2` + `decode_jwt_publisher/1`) — defense-in-depth gap.
- **`Arca.SessionStorage`** supports multi-row per `user_id`; `session_id` column at `:35` used by `Sanctum.Session.revoke/2`. Multi-session-per-user already works.
- **`Compendium.CyfrRun.Client`** exists at `compendium/cyfr_run/client.ex`; `@default_api_url "https://cyfr.run"` at `:19`; private `auth_headers/1` at `:219-236` reads via `Compendium.OCI.Auth.resolve_credentials/2` and emits `Bearer <jwt>` today.
- **`SanctumArx.Memberships`** is not referenced from `apps/cyfr/lib/sanctum/auth/` today (`rg "Memberships\." apps/cyfr/lib/sanctum/auth/` → 0 — already clean; §1.1 holds on this axis).
- **codex** (Go, `apps/codex/`):
  - `internal/ref/ref.go:70-73` rewrites `@` → `:`, mangling `c:@alice.foo`. `:79` uses `strings.Index(s, ":")` for the type-prefix (correct — first colon). `:92-105` uses `strings.Index` for version/namespace splits (wrong for multi-dot publishers).
  - `cmd/login.go:36` and `:61` hardcode `"provider": "github"`; `:23` docstring says "via GitHub" only. `cmd/login.go:186-198` whoami consumer reads single-action response.
  - `cmd/component.go:85-97, :151` render `publisher_name` with fallback. `cmd/component.go:505-512` makes an interactive `registry-login` MCP call (username/password prompt → Sanctum session tool).
  - `cmd/tincture.go:32,38,65,70` accept positional `<publisher>` arg without ref-parse validation.
- **Porta** (Tauri, `apps/porta/`):
  - `src-ui/src/state/auth-store.ts:34-40` reads single-action whoami containing `registry.email` + `registry.publisher_name`. `:106-142` device-poll consumer lacks `needs_personal_namespace` handling.
  - `src-ui/src/api/cyfr-mcp.ts:25-27` has single-action whoami return type.
  - `src-ui/src/config/labels.ts` maps `publisher_name` → human label.
  - `src/preflight.rs:109` + `src/commands/cyfr.rs:319-388` assert the single-action whoami shape.

### 2.3 Config — today's state

- `:cyfr, :registry_token_url` at `device_flow.ex:392` read via `Application.get_env` (not an OS env var).
- `:cyfr, :registry` — keyword list `[url, username, password]` written by `config/runtime.exs:213-249` and mirrored in `config/arx_runtime.exs:123-129`. **`:username`/`:password` are dead** — no code in `apps/cyfr/lib/` reads them. Per-user credentials live in `CredentialStore`.
- `:cyfr, :cyfr_run_api_url` read at `compendium/application.ex:65-78` (`validate_api_url!/0` pins Core to `cyfr.run`) and `compendium/cyfr_run/client.ex:213`.
- `:cyfr, :auth_provider` dispatcher at `config/runtime.exs:298-338` auto-selects via `Code.ensure_loaded?(SanctumArx.Auth.OIDC)`; hard-pinned to `SanctumArx.Auth.OIDC` at `config/arx_runtime.exs:17`.
- `:cyfr, :jwt_signing_key` at `config/runtime.exs:256-259` — cyfr's **own** Sanctum session crypto; unrelated to cyfr.run JWTs.
- `CYFR_ALLOWED_USER` gate at `config/runtime.exs:288`.
- Hardcoded `"registry.cyfr.run"` literals: `application.ex:41`, `edition.ex:9`, `registry/identity.ex:81-82`, `oci/reference.ex:26,36,71,94,96,122`, `credential_store.ex:32` (docstring), `compendium/mcp.ex:512` (default inside `Map.get`), `device_flow.ex:126`, `emissary/mcp/tools/system_provider.ex:380-381`.

### 2.4 Layering baseline — `rg` counts

Inputs to §3 pre-merge assertions. **cyfr.run rows are satisfied (Phase A shipped at `58af29d`).** cyfr / codex rows remain as pre-merge assertions for the open Elixir/CLI/UI work.

```
# cyfr.run (SHIPPED — all greps satisfied at 58af29d; see §2.1):
# publisher_name / cc.(Email|PublisherName|OrgID|UserID|Permissions|Scope) / GetOrCreatePublisher / JWT_SIGNING_KEY|JWTIssuer all 0 in internal/ (live code; 1 test comment + 1 package-doc mention are non-runtime).

# cyfr / codex (OPEN — pre-merge targets for Elixir/CLI work):
rg "Compendium\." apps/cyfr/lib/sanctum/auth/       → 1  (device_flow.ex:124 — post-refactor: same 1, repointed to CredentialStore.put/4)
rg "Compendium\." apps/cyfr/lib/sanctum/mcp.ex      → 2  (:445 whoami, :560 registry-login) → post-refactor 0
rg "Memberships\." apps/cyfr/lib/sanctum/auth/      → 0  (already clean)
rg "get_for_registry" apps/cyfr/lib/                → 4  (credential_store.ex:71-72 spec+def; identity.ex:111 caller; oci/auth.ex:276 caller) → post-refactor 0
rg "resolve_any_credential" apps/cyfr/lib/          → 3  (oci/auth.ex:275 def; oci/auth.ex:133, :137 callers) → post-refactor 0
rg "publisher_name" apps/cyfr/lib/                  → 10 across 4 files → post-refactor 0
rg "publisher_name" apps/codex/                     → 2  (cmd/component.go:85-97 and :151) → post-refactor 0
rg "registry-login" apps/cyfr/lib/ apps/codex/      → 2  (sanctum/mcp.ex:511 handler, codex/cmd/component.go:505 caller) → post-refactor 0
```

---

## Deployment cutover

**cyfr.run cutover complete 2026-04-18 at `58af29d`** (pre-wipe `pg_dump -Fc` archived in `/var/backups/`; migrations 000004–000008 applied; `revoked_tokens` renamed to `revoked_push_tokens`; no rollback invoked). Historical schema lives in cyfr.run git history pre-`0fe1200`.

**cyfr-side code shipped 2026-04-20** — Elixir Phase A at cyfr@80c2a1f, codex at cyfr@a923996, Porta at cyfr@c3feaeb. Migration `20260420000001_rekey_credential_store_and_indexes.exs` is in the codebase; it runs on the next `mix ecto.migrate` / release deploy (TRUNCATE `sessions`, TRUNCATE `api_keys`, `DELETE FROM secrets WHERE name LIKE '_registry.%' OR name = 'registry_credentials'`). Expected post-deploy behavior: users re-login → probe → CredentialStore rekeyed under `_registry.{registry}.{user_id}.{namespace_slug}`. No atomic-iss-change dance required (opaque tokens carry no `iss`).

---

## Namespace format

**Naming convention.** `namespace_slug` is a DB **column name** on cyfr.run (`namespaces.slug` is the primary key; `components.namespace_slug`, `namespace_members.namespace_slug`, `push_tokens.namespace_slug` are the FKs). In API response shapes, chi path params, JSON keys, and CredentialStore stored values, use `slug` / `namespace` (without the `_slug` suffix) for brevity. The compound noun is DB-only.

Component refs stay in the canonical `type:<owner>.name:version` shape (`Sanctum.ComponentRef`, `apps/cyfr/lib/sanctum/component_ref.ex`). The `<owner>` slot has **three shapes distinguished syntactically** — all OCI-name-grammar compliant (`[a-z0-9]+(?:[._-][a-z0-9]+)*`):

| Shape | Marker | Wire format | DB storage | Verification |
|---|---|---|---|---|
| Publisher | contains `.` (≥1 dot) | `c:stripe.com.api:0.1.0` | `namespaces.slug = "stripe.com"` | DNS TXT (`_cyfr-verify=<token>`) |
| Reserved | bare, in seeded list | `c:local.foo:0.1.0` | Seeded row, `reserved=true` | Built-in |
| Personal | bare, not reserved | `c:alice.foo:0.1.0` | `namespaces.slug = "alice"` | First-come-first-served (any provider) |

**Dispatcher ordering** (applied both in cyfr.run gateway regex gate and in `Sanctum.ComponentRef.classify_namespace/1`):
1. If slug contains `.` → publisher (validate against RFC 1035 hostname).
2. Else if slug in reserved seeded list → reserved.
3. Else → personal (validate GitHub-style `^[a-z0-9]+(-[a-z0-9]+)*$`, 1–39 chars).

**No `@` prefix anywhere** — wire, DB, CLI input, or UI. Wire format matches the OCI distribution name grammar (`[a-z0-9]+(?:[._-][a-z0-9]+)*`), so `/v2/<slug>/<type>/<name>:<version>` round-trips through any OCI-conformant registry (Zot, Docker Hub, ghcr.io, etc.). An earlier draft used `@alice` as a personal-slug marker; that proved incompatible with the OCI name grammar (`@` is reserved for digest refs in Docker reference syntax) and was dropped. Clients that want a visual "this is a user" cue render it at display time — the wire has a single format.

**Personal namespaces are first-come-first-served.** No `username == userinfo.login` check. Both GitHub and Google follow the same rule. Rationale: a tighter "must match provider login" rule would create an asymmetric footgun (a Google user claims `alice`, then the real GitHub user `alice` can never claim any slug at all because the rule allows them *only* their exact login, which is now taken). Industry norm for personal registries (Docker Hub, ghcr.io, npm, PyPI) is first-come-first-served at the personal tier; trust for brand names is elevated via the publisher tier (DNS verification) or via moderation (Phase C).

**Why this kills squatting for brands**: `stripe` (bare personal, community) and `stripe.com` (publisher, DNS-verified) are syntactically distinct slugs, coexist, don't conflict. Brand owners stake their claim via publisher DNS verification; bare-`stripe` personal claims carry no verified-publisher badge and no trust weight. `alice` (user) and `stripe.com` (publisher) never collide on slug PK.

**Invariants**:
- Slugs share a single unique `namespaces.slug` PK. Reserved seeds occupy the slug table; a personal claim of a reserved name fails `ON CONFLICT DO NOTHING` → 409 `slug_taken`.
- **Exactly one personal namespace per `(claimed_provider, claimed_provider_subject)` pair.** Enforced by partial unique index `namespaces (claimed_provider, claimed_provider_subject) WHERE kind = 'personal'` AND app-layer pre-check on `POST /v1/namespaces/personal/claim` that returns 409 `already_claimed`. A user's identity is 1:1 with one personal slug for life of the account.
- Personal usernames: `^[a-z0-9]+(-[a-z0-9]+)*$`, 1–39 chars (GitHub-style; no leading/trailing/consecutive hyphens). Validator rejects any `@` character with 400 `INVALID_USERNAME` — fail-loud on muscle-memory.
- Publisher slugs: valid DNS hostname per RFC 1035 — lowercase, ≤253 chars, each label 1–63 chars, ≥1 dot. App-layer MUST reject IDN (require punycode), trailing dots (normalize), IPv4/IPv6 literals, `localhost`, port suffixes. DB-level `CHECK (slug LIKE '%.%')` is a weak gate (passes `.`, `a.`, `.a`, `a..b`) — not sufficient on its own.
- Reserved slugs: lowercase, no dot, from the seeded list. App-layer additionally reserves prefixes `cyfr*`, `arx*`, `admin*`, `support*`, `security*` — requires admin approval.
- Personal namespaces have **no members** (`namespace_members` rows are invalid with `kind='personal'` namespaces; enforced app-layer). Only publisher namespaces accept members.
- Publisher namespaces have **at least one admin** at all times — demotion/removal of the sole admin rejected at app layer.
- Periodic DNS re-verification (daily cron) keeps `namespaces.domain_verified` honest: 3 consecutive failures flip to `false`; 90-day `verified_at` hard-expire.

**Parser**: name regex forbids dots and `@`, so the **last `.` before the version** always separates namespace and name. Split on **last `:`** to isolate version, then on **last `.`** for namespace/name. Unambiguous:

```
c:alice.foo:0.1.0       → ns=alice,      name=foo      (personal or reserved — DB decides)
c:stripe.com.api:0.1.0  → ns=stripe.com, name=api      (publisher)
c:local.foo:0.1.0       → ns=local,      name=foo      (reserved seed)
```

Classification kept internal to `Sanctum.ComponentRef` — used for per-shape validation but NOT exposed as a struct field. No call sites branch on it: verified `compendium/component.ex:195` and `compendium/mcp.ex:1922` pattern-match `%Sanctum.ComponentRef{type: ..., namespace: ..., name: ..., version: ...}` (struct pattern, not list destructure).

**ComponentRef rewrite scope** — wider than "change split direction": today's `@namespace_regex` at `component_ref.ex:41` (`~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/`) disallows dots entirely. Three-shape validation requires three regexes (publisher RFC-1035, reserved seeded-list, personal GitHub-style), a `classify_namespace/1` dispatcher (dispatch order: publisher first by dot presence, then reserved, then personal), and a rewrite of `validate_namespace/1` (`:448-468`). Callers of `validate_namespace/1` inherit the semantics change — audit `validate_publisher/1` (`:482`), `validate_ref_parts/2` (`:528`), `Sanctum.TinctureAccess`, and any other call site. Update doctests at `:440-444, 477-478, 492-493`.

**Wire-format fix (security-relevant).** codex currently rewrites `@` → `:` at `apps/codex/internal/ref/ref.go:70-73` — drop that line AND reject any `@` in the incoming ref (personal slugs are bare post-refactor); add regex validation for the three shapes; flip `strings.Index` → `strings.LastIndex` for both `:` and `.` splits.

---

## 3. Phased rollout

Phase A is the bulk of the work and the only phase that must ship as a unit (identity foundation + namespace model + opaque push tokens + `OCI.Auth` collapse). B/C/D are additive. §4 below enumerates the Arx compliance contract that MUST hold after every phase.

| Phase | Scope | Ships alone? |
|---|---|---|
| A | Identity foundation: cyfr-owned `Sanctum.User`, namespace claim + opaque push tokens on cyfr.run, three-shape refs, DNS verification, Google provider | Yes |
| B | Deprecation + yank (`components.status` trio) | Yes — pure additive |
| C | Admin moderation + abuse reports (`ADMIN_TOKEN` on cyfr.run; `PrismWeb.AdminLive` on cyfr) | Yes |
| D | Arx overrides: edition-gated config, Arx-local `identity_links` | Blocks on Arx 2.1d/2.1e |

**No Phase E.** Publisher-OIDC / BYO-IdP is deferred indefinitely — Arx handles enterprise SSO internally; no concrete third-party-IdP ask has landed.

---

### Phase A — Identity foundation [SHIPPED]

#### What shipped — cyfr.run (Go)

> **SHIPPED 2026-04-18 (commit `58af29d`).** Everything below is the **client integration contract** — what cyfr (Elixir), codex, and Porta call. Server-side implementation (schema DDL, push-auth middleware, CTE SQL, provider verification, SSRF guard, DNS cron, audit emission, reaper) lives in `/Users/moonmoon/Projects/cyfr.run/` HEAD — treat cyfr.run code as authoritative for those details; this doc stops trying to mirror them.

**Client wire format.** Send `Authorization: Bearer <push_token>` on every request (tokens formatted `cyfr_pt_<base32>`, opaque, no client-visible expiry). 401 responses carry `WWW-Authenticate: Basic realm=...` (Docker/OCI compat) — treat as "token revoked / missing; surface re-login." Server also accepts `Basic base64(anyuser:token)` so `docker login` / `skopeo` / `oras` work against the same endpoints.

**Endpoints** — `/v1/namespaces/*` + `/v1/identity/probe`:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/namespaces/personal/claim` | Body `{username, provider, access_token, label}`. Two 409s to distinguish: (1) **slug collision** → `slug_taken`; (2) **second-claim by same identity** → `already_claimed` (1:1 immutable). Mandatory before dashboard/API access on the cyfr side (gated by `RequirePersonalNamespace` plug). |
| `POST` | `/v1/namespaces/publisher/claim` | Body `{slug, provider, access_token}`. Auth: Bearer for caller's personal namespace. Returns TXT challenge. |
| `POST` | `/v1/namespaces/publisher/verify` | Body `{slug}`. On success: `domain_verified=true`, caller inserted as sole `role='admin'`, first push token issued. |
| `GET` | `/v1/namespaces/{slug}` | Public — `{slug, kind, domain_verified, claimed_provider, verified_at}`. |
| `POST` | `/v1/namespaces/{slug}/members` | Body `{target_personal_slug, role}`. Auth: admin Bearer. Rejects if `{slug}` is personal. **404 `target_personal_namespace_not_found`** if target hasn't claimed their personal slug yet — surface: `"User '<slug>' has not claimed their personal namespace on cyfr.run yet — they need to sign up and claim before you can add them."` Target receives token at their next `/v1/identity/probe`. |
| `PATCH` | `/v1/namespaces/{slug}/members/{target_personal_slug}` | Body `{role}`. Admin-only. **409 `sole_admin`** on demoting the last admin. |
| `DELETE` | `/v1/namespaces/{slug}/members/{target_personal_slug}` | Admin-only. Same `sole_admin` protection. Server atomically revokes removed user's tokens for this namespace — **next-request-effective**, not instant-kill-in-flight. |
| `GET` | `/v1/namespaces/{slug}/members` | Auth: Bearer for `{slug}` (admin or member). Returns `[{member_provider, member_provider_subject, role, added_at}]`. |
| `POST` | `/v1/namespaces/{slug}/tokens` | Bearer + body `{label}` → issues additional token. **429 `rate_limited`** if caller issued 10 tokens in the last hour. |
| `DELETE` | `/v1/namespaces/{slug}/tokens/{id}` | Auth: Bearer any valid token for `{slug}`. Mark revoked. |
| `POST` | `/v1/identity/probe` | Body `{provider, access_token, label}`. Returns `{personal_namespace: {slug, token} \| null, memberships: [{slug, role, token}]}`. Each call issues fresh tokens (capabilities — not upserted; revoke explicitly to retire). cyfr invokes this automatically after every login. If `personal_namespace: null`, follow up with `/v1/namespaces/personal/claim`. |
| `GET` | `/.well-known/cyfr-registry.json` | **Shipped 2026-04-20** — handler registered at `router.go:87` (cyfr.run@718852a). Returns JSON with `registry_url`, `oci_registry_url`, `edition`, `api_version` for client discovery. Test coverage in `wellknown_test.go`. |

**Error codes clients must surface distinctly** (each maps to different UI):
- `slug_taken` (409) — someone else already holds that slug; re-prompt for a different one.
- `already_claimed` (409) — this identity already claimed a personal namespace (1:1 immutable); fetch their existing slug instead of re-claiming.
- `sole_admin` (409) — can't demote/remove the last admin; require promotion of another member first.
- `target_personal_namespace_not_found` (404, `POST /v1/namespaces/{slug}/members`) — target hasn't signed up + claimed yet.
- `rate_limited` (429) — per-IP bucket exceeded, or per-bearer token-issue cap (10/hour), or per-subject probe cap (10/hour). Back off + retry or surface rate-limit notice.
- `invalid_label` (400) — `label` must match `^[\x20-\x7E]{1,64}$` (printable ASCII, 1–64 chars).

**Post-probe store contract.** Probe returns up to N+1 fresh push tokens. `CredentialStore.put/4` applies per-token independently — partial success is OK. On any individual put failure, cyfr calls `DELETE /v1/namespaces/{slug}/tokens/{id}` to revoke the orphan server-side; failed namespaces re-mint at next probe. Server's 365-day inactivity reaper is the backstop.

**Probe failure does not block session creation.** Session row stays in DB; user lands on claim-gate with a "Retry probe" action (web: cached `access_token`; CLI: re-runs DeviceFlow). CLI `--no-probe` flag for offline-first-login.

**Rate limits (handle 429 gracefully).** `/v1/namespaces/*` 20/min burst 5; `/v1/identity/probe` 10/min burst 3 + per-subject cap 10 probes/hour; `/v1/components` 60/min burst 10; `/v2/*` 600/min burst 50.

#### What shipped — cyfr (Elixir)

**`Sanctum.User`** — **no struct change**. Today's `[:id, :email, :provider, :org_id, :project_id, permissions: []]` (`user.ex:18`) is sufficient.

- `:id` semantic: **`"<provider>|<iss>|<provider_subject>"`** on **both Core AND Arx**. Scheme-prefixed `iss` matches RFC 7519 and prevents cross-tenant subject collisions. Examples: `"github|https://github.com|12345678"`, `"google|https://accounts.google.com|108xyz"`, `"oidcc|https://okta.acme.com|<sub>"` (Arx enterprise OIDC via `ueberauth_oidcc`). Pipe-delimited for grep-ability. Edition is a deployment concern, never baked into the id. A human on GitHub on Core and on Arx resolves to the same id string = same cyfr.run identity.
- **Four construction sites must update in lockstep** (all build `%User{}` directly — bypassing `from_oidc_claims/1` at the latter three):
  - `user.ex:31-38` (`from_oidc_claims/1`) builds `id: "#{provider}|#{claims["iss"]}|#{claims["sub"]}"`.
  - `simple_oauth.ex:43-48` — replace `id: user_info.id` with `id: "#{provider}|#{provider_iss(provider)}|#{user_info.id}"` where `provider_iss/1` returns the hardcoded per-provider issuer (`"https://github.com"` / `"https://accounts.google.com"`).
  - `device_flow.ex:330-339` (`create_session/2`) — same (hardcoded issuer per provider).
  - `sanctum_arx/auth/oidc.ex:72-80` (`authenticate/1` Ueberauth path) — replace `id: to_string(auth.uid)` with `id: "#{provider}|#{iss}|#{auth.uid}"` where `iss` comes from `auth.info.urls[:oidc_issuer]` or `auth.extra.raw_info["id_token"]["iss"]` for the `:oidcc` provider, and from the hardcoded provider issuer for `:github` / `:google` (Lane 1 Arx). Arx uses the **same** id format as Core.
- `local/0` (`user.ex:54-61`) keeps today's `id: "local_user"` sentinel verbatim (no collision with `"<provider>|<iss>|<sub>"` format).
- `sanctum_arx/auth/oidc.ex:105-110` API-key path keeps `id: "api_key:<name>"` sentinel unchanged.
- `:email`, `:provider`, `:org_id`, `:project_id` stay — dropping them would trigger a 51-hit / 13-file cascade for zero benefit.
- No `:cyfr_username` field — cyfr doesn't need one; username only matters at cyfr.run namespace-claim time (stored as the slug on cyfr.run side).
- **No `:provider_login` field, no `display_name/1` helper.** UI renders `email || id` directly; since both GitHub and Google are required to return verified `email` (reject `email_verified=false`), the `email` branch always fires for real users. `api_key:<name>` and `local_user` variants never hit UI. Logs use raw `id` for grep-ability; UI templates handling the rare id-only case use a small `String.split("|", parts: 3)` helper to render `@provider:subject` form.

**`Compendium.Registry.CredentialStore`** — key scheme + full API cascade:
- Old key: `_registry.{registry}.{user_id}` (one credential per user per registry).
- New key: `_registry.{registry}.{user_id}.{namespace_slug}` (one per user per namespace). A single user legitimately holds multiple entries — one for their personal namespace + one per publisher namespace they belong to. Keys read like `_registry.cyfr.run.github|https://github.com|12345678.alice` — human-readable in audit.
- Stored value: `%{type: :push_token, token: "cyfr_pt_...", namespace: "alice", issued_at, label}`.
- Token format: `cyfr_pt_` prefix (matches existing `cyfr_pk_`/`cyfr_sk_`/`cyfr_ak_` convention in `Sanctum.ApiKey`) + 32 bytes base32 ≈ 256 bits entropy.
- `type: :push_token` is additive to today's store types (`:basic`, `:bearer`, `:oauth2_client`, `:key_pair`). Legacy `type: :basic` records (written by `device_flow.ex:124-132`) disappear with the device-flow rewrite — the migration wipes `secrets WHERE name LIKE '_registry.%'`.
- **Encryption:** same `Sanctum.Secrets` + `Sanctum.Crypto` path used for existing basic/bearer creds — no dedicated salt. Discrimination via `type` field at decode time. (Earlier draft spec'd a `"cyfr_registry_push_token_v1"` salt; dropped — would require per-entry salt plumbing that the `secrets` table doesn't support today, and adds no security property beyond type-tagging.)
- **Full API cascade** (every function signature changes):
  - `put/3(user_id, registry, credential)` → `put/4(user_id, registry, namespace_slug, credential)`.
  - `get/2(user_id, registry)` → `get/3(user_id, registry, namespace_slug)` for push path.
  - `delete/2` → `delete/3`.
  - **`get_for_registry/1` — DELETED.** Per §2.2, the "any user's credential" fallback lives today at `registry/identity.ex:98-122` (the `:not_found` arm begins at `:110`) AND at `Compendium.OCI.Auth.resolve_any_credential/1` (`oci/auth.ex:275-280`). Two rationales apply:
    (1) Core supports multi-user (comma-separated `CYFR_ALLOWED_USER` list at `config/runtime.exs:288`); when multiple users share a BEAM node, the fallback would silently return user A's token to user B's push — a potential privacy leak. Core's typical deployment is single-user, but the leak is real for any multi-user install.
    (2) The stronger justification: the only other caller (`resolve_any_credential/1`) was a cross-registry fallback for non-cyfr.run registries; with single-registry scope (cyfr.run apex or self-deployed cyfr.run), cross-registry doesn't exist, so the fallback has no legitimate use case anywhere.
    Post-refactor: no fallback anywhere. `resolve_core_credentials/2` returns `:not_found`; callers surface `{:error, :no_push_token}` with message "run `cyfr login` to claim or probe." Pre-merge assertion: `rg "get_for_registry" apps/cyfr/lib/` → zero.
  - NEW `list_for_user/2(user_id, registry)` returns all creds across namespaces (drives whoami, probe sync, UI). **Deterministic ordering**: personal-namespace entries first (kind=personal — no dot), then publisher namespaces (kind=publisher — dot) alphabetical. Implementation: `ORDER BY CASE WHEN position('.' in namespace) = 0 THEN 0 ELSE 1 END, namespace`. `Compendium.CyfrRun.Client.auth_headers/1` for non-namespace-scoped calls (probe) uses the head of this list — which is the user's personal-namespace entry when present.
- Stored value is **uniformly `%{type: :push_token, token, namespace, issued_at, label}`** — cyfr.run is the only registry cyfr talks to, so no `:basic`/`:bearer`/`:oauth2_client`/`:key_pair` types post-refactor.
- `@valid_keys` module attribute lists only atoms the `:push_token` shape needs: `:type, :token, :namespace, :issued_at, :label, :role, :push_token`. Dropped vs. earlier draft: `:username, :password, :client_id, :client_secret, :token_url, :public_key, :private_key, :basic, :bearer, :oauth2_client, :key_pair` (non-push-token types deleted).

**Caller cascade for the signature change** — every call site updates:
- `Compendium.OCI.Auth.resolve_credentials/2` at `auth.ex:128-139` → **renamed to `fetch_credential/3(registry, namespace_slug, ctx)`** (see C5 below); callers pass namespace from the ref (push path) or from the URL (`/v1/namespaces/alice/...`).
- `Compendium.OCI.Auth.auth_headers/3` at `:27-57` → `auth_headers/4(registry, repository, namespace_slug, ctx)`; gains `:push_token` branch emitting `Bearer <token>`.
- `Compendium.OCI.Auth.handle_challenge/4`, `exchange_token/4` — **DELETED** (no realm dance with push tokens; no cross-registry to exchange against).
- `Compendium.Registry.Identity` — `resolve_core_credentials/2` iterates via `list_for_user/2` and returns a list (not a single cred); `resolve_tenant_credentials/2` (Arx) keeps single-cred semantics. Arx tenant creds are push tokens post-refactor (target is a self-deployed cyfr.run); `Arca.SecretStorage` returns decoded `%{token: push_token, namespace: <slug>}`, not `%{username, password}`. Multi-namespace Arx tenant creds are a Phase D problem.
- `Compendium.CyfrRun.Client.auth_headers/1` (`client.ex:219-236`) — resolve by URL path's slug for namespace-scoped endpoints; for `/v1/identity/probe` (not namespace-scoped), pick "any token for this user" via `list_for_user/2` head.

**`resolve_credentials` rename (C5).** Only one rename is needed — the naming collision disappears once `OCI.Auth` is renamed:
- `Compendium.Registry.Identity.resolve_credentials/1` (private at `identity.ex:88-96`, one caller) — **kept as a private helper.** Clean 3-line edition dispatch; inlining would only bloat `identity/1`.
- `Compendium.OCI.Auth.resolve_credentials/2` (public, **four callers** per §2.2: `compendium/mcp.ex:511`, `compendium/mcp.ex:1707`, `compendium/cyfr_run/client.ex:220`, `compendium/oci/client.ex:1033`) — **rename** to `fetch_credential/3(registry, namespace_slug, ctx)` (also gains the namespace arg per the cascade above). `fetch_credential` reads more clearly as "grab a specific credential entry" and is distinct from the identity-level concept. No backward-compat alias. The `mcp.ex:1707` site (anonymous-probe inside `do_oci_pull/2`) is the one least-obvious to miss; the Phase A checklist below covers it explicitly.
Once `OCI.Auth.resolve_credentials/2` is renamed, the `Registry.Identity.resolve_credentials/1` private helper no longer collides with anything.

**`Compendium.CyfrRun.Client`** — EXTEND (do NOT create `Sanctum.CyfrRun.Client` — naming collision). Add:
- `probe_identity/3(provider, access_token, label)` → `{:ok, %{personal_namespace: {:ok, %{slug, token}} | nil, memberships: [%{slug, role, token}]}}` | `{:error, _}`. Called automatically by `DeviceFlow.poll_for_session/2` + `EmissaryWeb.AuthController.callback/2` after session creation. Device `label` defaults to `:inet.gethostname/0`; overridable via `:cyfr, :device_label` application env or `CYFR_DEVICE_LABEL`. **Label is non-unique** (two devices with the same hostname produce duplicate-labeled tokens) — distinguish by token id + `last_used_at` via `cyfr registry tokens list <ns>`.
- `claim_personal_namespace/4(username, provider, access_token, label)` → `{:ok, %{slug, token}}` | `{:error, :already_claimed | :slug_taken | :reserved | ...}` — called from the claim-gate after `probe_identity` returns `personal_namespace: nil`.
- `claim_publisher_namespace/2(slug, bearer_token)` → `{:ok, %{verify_token}}` — requires caller's personal-namespace bearer.
- `verify_publisher_namespace/1(slug)` → `{:ok, %{slug, token}}` | `{:error, :dns_failed}`.
- `issue_additional_token/3(slug, bearer_token, label)` → `{:ok, %{token, id}}` (rotation; bearer for `{slug}` required — single auth path only).
- `revoke_token/3(slug, token_id, bearer_token)` → `:ok`.
- `add_member/4(slug, target_personal_slug, role, bearer_token)` — admin-only. Returns `:ok` | `{:error, :not_admin | :target_not_found | :slug_is_personal}`.
- `update_member/4(slug, target_personal_slug, role, bearer_token)` — admin-only; admin-protection for sole-admin demotion.
- `remove_member/3(slug, target_personal_slug, bearer_token)` — admin-only; same protection; cascades token revocation server-side.
- `list_members/2(slug, bearer_token)` → `{:ok, [%{member_provider, member_provider_subject, role, added_at}]}`.
- `get_namespace/1(slug)` → `{:ok, %{...}}`.
- `whoami/1(bearer_token)` — simplified; returns `{:ok, %{slug, kind, last_used_at}}` for the given token; no user model.
- **Modify existing `defp auth_headers(ctx)` at `:219-236`** (it already exists — reads via the renamed `Compendium.OCI.Auth.fetch_credential/3`, see C5 above) to emit `Bearer <push_token>` when the resolved credential has `type: :push_token`. Also accepts an explicit `bearer_token` arg for the claim/verify/tokens/members endpoints that pass a specific token (not via ctx).
- NO `exchange_provider_identity/3`, NO `refresh/1`, NO `claim_username/2`, NO JWT decode.

**`Sanctum.Auth.SimpleOAuth`** — extend to include Google:
- `:36` `@supported_providers` → `[:github, :google]`.
- `:170-174` `provider_configured?/1` → add `:google` clause.
- `:176-184` `github_config/0` → add `google_config/0`.
- `:186-192` `extract_user_info/1` `:github` clause → add `:google` clause.
- `:43-48` — `%User{}` construction must format `id: "#{provider}|#{provider_iss(provider)}|#{user_info.id}"` (not raw `user_info.id`); `provider_iss/1` hardcodes `"https://github.com"` / `"https://accounts.google.com"`.
- `:27` docstring — remove "Google" from the "requires Sanctum Arx" list.
- Implementation stays behaviour-compatible with `Sanctum.Auth` (`authenticate/1`, `current_user/1`). `SanctumArx.Auth.OIDC` at `apps/cyfr/lib/sanctum_arx/auth/oidc.ex` continues to satisfy the same behaviour unchanged.
- `ueberauth_google ~> 0.12.1` already at `mix.exs:45`. Wire Google client_id/secret via `config/runtime.exs` (a block that mirrors the GitHub block at `:201-211`).

**`:cyfr, :auth_provider` dispatcher update** (`config/runtime.exs:298-338`) — `github_configured?` alone no longer enables SimpleOAuth. Add parallel `google_configured? = env!("CYFR_GOOGLE_CLIENT_ID", :string, nil) != nil`; SimpleOAuth enabling condition becomes `(github_configured? or google_configured?) ->`; error message at `:325-335` mentions Google as a valid option.

**`Sanctum.Auth.DeviceFlow`** — parameterize endpoints on provider AND drive the first-login probe/claim flow:
- Replace the fixed `@github_device_url` / `@github_token_url` / `@github_user_url` / `@github_scope` module attributes at `:36-42` with per-provider maps (or add `@google_*` parallels).
- `:187` `request_device_code(:github, ...)` → add `(:google, ...)` clause (`https://oauth2.googleapis.com/device/code`).
- `:227` `request_token(:github, ...)` → add `(:google, ...)` clause (`https://oauth2.googleapis.com/token`).
- `:275` `fetch_user_info(:github, ...)` → add `(:google, ...)` clause (`https://www.googleapis.com/oauth2/v3/userinfo`).
- `:345-348` `get_client_id(:github)` → add `get_client_id(:google)` reading `:cyfr, :google_client_id` / `CYFR_GOOGLE_CLIENT_ID`.
- Remove the silent best-effort `/auth/token` exchange at `:119-138` (endpoint no longer exists — cyfr.run does not issue JWTs).
- Remove `:registry_token_url` application env entirely (dead after the exchange block is removed).
- `:330-339` (`create_session/2`) — `%User{}` construction must format `id: "#{provider}|#{provider_iss(provider)}|#{user_info.id}"` (not raw `user_info.id`); hardcoded per-provider issuer same as `simple_oauth.ex`.
- **After `Session.create/1`, before returning**: invoke `Compendium.CyfrRun.Client.probe_identity/3(provider, access_token, label)`. Store returned tokens in `CredentialStore` under `(user_id, registry, namespace_slug)` keys. If response has `personal_namespace: nil`, include `needs_personal_namespace: true` + `suggested_username: <provider_login>` in the MCP response so codex/Porta can prompt the user. Access_token is **not persisted** — used for the probe call and discarded.
- **Accepted cross-layer coupling marker** — add module-doc comment at top of `device_flow.ex`: `# Auth→Registry handoff: this module intentionally calls Compendium.CyfrRun.Client.probe_identity/3 and Compendium.Registry.CredentialStore.put/4 after Session.create/1. See auth_refactor.md §"Accepted cross-layer coupling".`
- **Wire-shape commitment:** the MCP `session.device-init` / `session.device-poll` response shapes remain stable for existing fields (`{status: "pending"|"complete"|"expired"|"denied", session_id, user: {id, email, name}}`). Post-refactor ADDS `needs_personal_namespace` (bool) and `suggested_username` (string) when status=complete and probe returned no personal namespace. Porta (`auth-store.ts:106-142`) and codex consume — update consumers in the same release.
- **Arx scope:** DeviceFlow stays core-only (GitHub + Google). Arx CLI auth is out of Phase A scope; enterprise uses web OIDC via `SanctumArx.Auth.OIDC`. **No runtime edition guard inside DeviceFlow itself** — the gate is two-layered: (1) `:cyfr, :auth_provider` dispatcher routes Arx to `SanctumArx.Auth.OIDC` (which doesn't expose device-flow), and (2) Arx Shell does not register `session.device-init`/`session.device-poll` MCP actions in its tool surface. Adding a third runtime guard inside `DeviceFlow.poll_for_session/2` would duplicate the dispatcher; the contract is "if `:auth_provider == SanctumArx.Auth.OIDC`, no client should reach DeviceFlow." Pre-merge confirmation: trace MCP tool registration in `Compendium.MCP` for the device-flow actions and verify they're under a Core-edition or `:auth_provider == SimpleOAuth` gate.

**`EmissaryWeb.AuthController.callback/2`** (`auth_controller.ex:66-110`) — today's `authenticate_with_provider/1` path (at `:235-259`) never reads `auth.credentials.token`; the full Ueberauth `auth` struct is passed in but the access_token inside it is effectively unused. Phase A fix:
1. At the top of `callback/2`, extract `access_token = auth.credentials && auth.credentials.token` before calling `authenticate_with_provider(auth)`. Keep `authenticate_with_provider/1` signature unchanged.
2. After `Sanctum.Session.create(user)` succeeds, invoke `Compendium.CyfrRun.Client.probe_identity/3(provider, access_token, hostname_label)` with the extracted token.
3. Store each returned token in `CredentialStore` under `{user_id, registry, namespace_slug}` keys.
4. If `personal_namespace: nil`: store the `access_token` in the **signed session cookie** under key `:pending_probe_access_token` (TTL 10 min — session cookies already `secure: true` + `http_only: true` + `same_site: "Lax"` post-refactor); redirect to `/claim-namespace` gate. Gate page offers `suggested_username` (= provider login) and posts to `/claim-namespace/submit` which calls `claim_personal_namespace/4` then redirects to dashboard on success. **On success, clear the cookie field.** Not stored in LiveView assigns (endpoint restart loses it); not stored in the session DB row (secret sprawl).
5. If `personal_namespace: {slug, token}`: proceed to dashboard as today.
6. **On probe 401 `invalid_access_token` at any point** (initial probe OR "Retry probe" action): redirect to `/auth/reauthenticate` to restart OAuth from scratch. Do NOT loop on retry — expired tokens can't be refreshed without user interaction.
7. **On `/claim-namespace/submit` POST with missing or expired `:pending_probe_access_token` cookie** (cookie 10-min TTL exceeded, or signed-cookie verification failed, or session was never set): return 400 with user-facing message "Login session expired. Please re-authenticate." and redirect to `/auth/reauthenticate`. The form action handler MUST validate cookie presence + signature BEFORE invoking `claim_personal_namespace/4` — never attempt the claim with a missing/expired access_token (the claim would itself fail at cyfr.run with 401, but failing fast in the handler gives a cleaner UX message). The cookie is cleared on success in step 4; this step covers the case where the user lingered on the form past TTL.

**Accepted cross-layer coupling marker** — add module-doc comment at top of `auth_controller.ex`:
```elixir
# Auth→Registry handoff: this module intentionally calls Compendium.*
# after Session.create/1 (probe + CredentialStore.put). See
# auth_refactor.md §"Accepted cross-layer coupling".
```

**CSRF verification** — `/claim-namespace/submit` is a browser-session-authenticated write; verify `EmissaryWeb.Router`'s `:browser` pipeline includes `plug :protect_from_forgery` AND the claim-namespace routes are under that pipeline (not the API pipeline). Pre-merge assertion: `rg ':protect_from_forgery' apps/cyfr/lib/emissary_web/router.ex` shows the plug.

Personal-namespace claim is **mandatory at first login** (dashboard is gated until it succeeds). No "decoupled from login" path.

**`Sanctum.ComponentRef`** — three-shape parser with internal classification (no `:namespace_kind` struct field — no call sites branch on it); per-shape validation. See the detail in §Namespace format above — NOT a drop-in regex swap: today's `@namespace_regex` disallows dots, so publisher slugs fail today's validator, not just the parser. The rewrite replaces the regex with three dedicated validators (personal regex, publisher RFC-1035 function, reserved seeded-list) + `classify_namespace/1` dispatcher + rewrite of `validate_namespace/1` at `:448-468`. Callers (`validate_publisher/1`, `validate_ref_parts/2`, `Sanctum.TinctureAccess`) inherit the semantics change — audit before shipping. `parse_ns_name/1` at `:398-417` splits on **last `:`** then **last `.`**. Doctests at `:440-444, 477-478, 492-493` update.

**MCP tool relocation** — the `registry` tool moves from Sanctum to Compendium for clean separation.
- `sanctum/mcp.ex:131-190` — DELETE `registry`/`type`/`username`/`password`/`token`/`client_id`/`client_secret`/`token_url` fields; DELETE `registry-login` from `action` enum at `:135-141`. Keep the rest of the session tool (login/logout/whoami/device-init/device-poll). Update `provider` enum at `:178-182` to `["github", "google"]`.
- `sanctum/mcp.ex:511` — DELETE the `registry-login` handler entirely.
- `sanctum/mcp.ex:576` — error message drops `registry-login`.
- `compendium/mcp.ex` — ADD new `registry` tool with actions: `probe`, `claim-personal`, `claim-publisher`, `verify-publisher`, `tokens-list`/`issue`/`revoke`, `members-list`/`add`/`update`/`remove`, `whoami` (returns `{authenticated, personal_namespace, memberships}` — see whoami split above). Handlers delegate to `Compendium.CyfrRun.Client.*`. The new tool registers through Emissary's MCP router via the standard `handle/3` dispatch pattern used by `component`/`aqua` tools — see `apps/cyfr/lib/emissary/mcp/` for the registration convention.
- `emissary/mcp/tool_visibility.ex:45` — replace `"session.registry-login" => :admin` with per-action visibility under `"registry.*"` (default `:user`; admin-gating applied inside handler for `members-*` actions).
- `compendium/mcp.ex:512` — the `"registry.cyfr.run"` inline literal in the push path repoints to derived `:oci_registry_url` (see registry-url config below).

**Whoami split — Sanctum stays Compendium-free.** Today's `Sanctum.MCP.session.whoami` at `sanctum/mcp.ex:438-447` returns `{user_id, org_id, scope, permissions, registry: Compendium.Registry.Identity.identity(ctx)}` — Sanctum (auth layer) reaching into Compendium (registry layer), reverse of intended layering. Phase A drops `org_id`/`scope`/`permissions` (in Core these are always default; Arx Shell UIs read `Sanctum.Context` directly via `prism_web/auth_helpers.ex:52-54` + `emissary_web/plugs/mcp_session.ex:288, 398-400`, not via whoami — grep-verified no codex/Porta/Rust consumer reads these whoami fields). Phase A splits whoami into two actions:

1. **`Sanctum.MCP.session.whoami`** returns local user only:
   ```json
   {
     "user_id": "github|https://github.com|12345678",
     "email": "alice@example.com",
     "provider": "github",
     "display_name": "alice@example.com"
   }
   ```
2. **`Compendium.MCP.registry.whoami`** (new action on the relocated `registry` tool) returns registry identity only:
   ```json
   {
     "authenticated": true,
     "personal_namespace": {"slug": "alice", "last_used_at": "..."},
     "memberships": [{"slug": "stripe.com", "role": "member", "last_used_at": "..."}]
   }
   ```
   `authenticated: false` when `personal_namespace: null` AND `memberships: []`.

**Clients compose the two.** codex (`cmd/login.go:186-198`) calls both actions and composes the combined output before printing. Porta (`auth-store.ts:34-40`) calls both and merges in state. Same end-user shape as before the split — but the **auth/identity sliver** of Sanctum (`sanctum/auth/*` + `sanctum/mcp.ex` session actions) becomes Compendium-free. Component-aware Sanctum features (`sanctum/policy.ex`, `sanctum/policy_store.ex`, `sanctum/oauth.ex`, `sanctum/tincture_access.ex`) keep their existing `Compendium.Registry`/`Compendium.Manifest` calls — those are intentional dependencies for component-metadata reads, unchanged by Phase A. Pre-merge assertions (scoped to the auth sliver):
- `rg "Compendium\." apps/cyfr/lib/sanctum/auth/` → only `device_flow.ex` (the accepted CredentialStore.put handoff after probe).
- `rg "Compendium\." apps/cyfr/lib/sanctum/mcp.ex` → zero (post-whoami-split + post-`registry-login`-deletion).
- `rg "Compendium\." apps/cyfr/lib/emissary_web/controllers/auth_controller.ex` → only the CredentialStore.put handoff after probe.

**Ship Sanctum + Compendium + codex + Porta in the same release.**

**`Compendium.Registry.Identity`** (`registry/identity.ex`) — significant rewrite:
- `resolve_credentials/1` (currently `defp` at `:88-96`, single caller) — **kept as private helper.** Clean 3-line edition dispatch; inlining into `identity/1` would only bloat it. Once `OCI.Auth.resolve_credentials/2` renames to `fetch_credential/3`, the naming collision disappears and the helper keeps its name.
- `do_whoami/2` at `:35-77` — rewrite from Basic auth (`Base.encode64("#{username}:#{password}")` at `:40`) to Bearer (`Authorization: Bearer #{push_token}`). Target changes from `/v1/auth/whoami` (deleted) to `/v1/namespaces/{slug}` per-token; iterate user's CredentialStore entries via `CredentialStore.list_for_user/2`.
- Drop the `data["publisher_name"]` read at `:59`.
- New `identity/1` return shape: `%{authenticated: boolean, user_id: string, personal_namespace: %{slug, last_used_at} | nil, memberships: [%{slug, role, last_used_at}]}` — now consumed by the new `Compendium.MCP.registry.whoami` action (not by `Sanctum.MCP.session.whoami`; see whoami split above).
- `registry_url/0` at `:79-84` simplifies to bare-string read of `:cyfr, :oci_registry_url` (default derived from `:registry_url`). See registry-url config below.
- The Arx `resolve_tenant_credentials/2` path at `:124-147` keeps single-cred semantics but simplifies: today it decodes `%{"username", "password"}` from `Arca.SecretStorage` JSON; post-refactor Arx tenant creds are push tokens (target is a self-deployed cyfr.run), so `Arca.SecretStorage` returns decoded `%{token: push_token, namespace: <slug>}`. The fallback to `resolve_core_credentials/2` remains. Multi-namespace Arx tenant creds are a Phase D problem.

**`Compendium.OCI.Auth`** (`apps/cyfr/lib/compendium/oci/auth.ex`) — **central credential resolver, plan-critical file**. Collapse to push-token-only (cyfr only talks to cyfr.run apex or a self-deployed cyfr.run — no cross-registry):
- `auth_headers/3` at `:27-57` → `auth_headers/4(registry, repository, namespace_slug, ctx)`. Two branches only: `:push_token` emits `Authorization: Bearer <token>`; `:none` emits **no** `Authorization` header (used when no credential exists — e.g., public-component pull). **DELETE** the `:basic`, `:bearer`, `:oauth2_client`, `:key_pair`, and legacy `{username, password}` branches.
- `resolve_credentials/2` at `:128-139` — **RENAME to `fetch_credential/3(registry, namespace_slug, ctx)`** and pick the right `CredentialStore.get/3` entry by namespace. Pre-existing naming collision with `Identity.resolve_credentials/1` resolved in same change (C5 above).
- `handle_challenge/4`, `exchange_token/4` (`:167-227` + callers) — **DELETE**. No realm dance with push tokens; no non-cyfr.run registry to exchange against.
- Token cache at `:145-161` (`get_cached_token/2`, `cache_token/4`) — **DELETE**. Push tokens don't auto-expire; caching buys nothing.
- `resolve_any_credential/1` at `:275-280` — **DELETE**. Calls `CredentialStore.get_for_registry/1` which is also deleted; fallback path doesn't exist post-refactor (forces callers to route through explicit namespace-scoped lookup or surface `:no_push_token` actionable error).

**`Compendium.OCI.Client`**:
- Delete `resolve_publisher_name/2` and `decode_jwt_publisher/1` at `:1032-1050` — no JWT in push path.
- Wrap push HTTP calls with retry-on-401: check `get_namespace/1`; if token revoked, bubble `{:error, :token_revoked}` — user runs `cyfr registry login` to reclaim. No refresh needed (opaque tokens don't auto-expire).

**`publisher_name` scrub on Elixir side** — beyond the OCI client deletion above:
- `apps/cyfr/lib/compendium/mcp.ex` — response-shaping sites that include `publisher_name` drop the key (whoami and component responses shift to `namespace_slug`).
- `apps/cyfr/lib/compendium/registry/identity.ex:59` — stop reading `data["publisher_name"]` from whoami response.
- `apps/cyfr/lib/prism_web/live/components_live.ex:965, 1194, 1378` — LiveView `comp[:publisher_name]` reads → render `comp[:namespace_slug]` (post-schema change).
- codex `apps/codex/cmd/component.go:85-97` — drop the `publisher_name` fallback in search-result rendering.
- Porta `apps/porta/src-ui/src/config/labels.ts` — remove the `publisher_name` label mapping.

**Config consolidation** — two knobs (REST + OCI), single apex for Core:
- `:cyfr, :registry_url` (REST host, bare string, default `"cyfr.run"`) — source of truth for the cyfr.run REST API.
- `:cyfr, :oci_registry_url` (OCI host, bare string, default `"registry.#{registry_url}"`) — source of truth for the OCI Distribution endpoint. Optional override. The default derivation assumes the bare-apex convention; Arx deployments that serve both on the same host (e.g., `registry.acme.com` for both) set both explicitly.
  - Core (apex): `CYFR_REGISTRY_URL=cyfr.run` → REST at `https://cyfr.run`, OCI at `registry.cyfr.run`.
  - Arx co-host: `CYFR_REGISTRY_URL=registry.acme.com CYFR_OCI_REGISTRY_URL=registry.acme.com` → both on same host.
  - Arx split: `CYFR_REGISTRY_URL=api.acme.com CYFR_OCI_REGISTRY_URL=registry.acme.com` → separate hosts.
- DELETE `:cyfr, :registry` keyword list block at `config/runtime.exs:213-249`.
- DELETE parallel `:cyfr, :registry` block at `config/arx_runtime.exs:123-129` (Arx edition mirror).
- DELETE `:cyfr, :registry_token_url`.
- DELETE `:cyfr, :cyfr_run_api_url` (replaced by `:registry_url`).
- KEEP `:cyfr, :jwt_signing_key` at `config/runtime.exs:256-259` — unrelated to cyfr.run JWTs (used for Sanctum's own session/API-key crypto).
- Replace the deleted block with:
  ```elixir
  config :cyfr, :registry_url, env!("CYFR_REGISTRY_URL", :string, "cyfr.run")
  config :cyfr, :oci_registry_url,
    env!("CYFR_OCI_REGISTRY_URL", :string, "registry.#{Application.get_env(:cyfr, :registry_url, "cyfr.run")}")
  ```
  (add to both `config/runtime.exs` and `config/arx_runtime.exs`; the `oci_registry_url` default derives at runtime from the already-set `registry_url`).
- `compendium/application.ex`: delete `validate_registry_credentials!/0` (`:13-34`); delete `validate_api_url!/0` (`:64-78` — redundant after `:cyfr_run_api_url` goes away); simplify `validate_registry_url!/0` (`:36-62`) to read the bare `:cyfr, :registry_url` string; keep Core-edition pin logic. Add parallel `validate_oci_registry_url!/0` that pins Core to `registry.cyfr.run`.
- All hardcoded `"registry.cyfr.run"` literals (see §Today's state) rewrite to derive from `:oci_registry_url` (for OCI host uses) or `:registry_url` (for REST host uses). Pick the right one per site — most existing literals are OCI host references.

**Core-edition gate** — `validate_registry_url!/0` + `validate_oci_registry_url!/0` pin Core to `cyfr.run` / `registry.cyfr.run`. Arx overrides via env vars.

**Cookie hardening (latent fix)** — add `secure: config_env() == :prod` to session cookie config at `apps/cyfr/lib/emissary_web/endpoint.ex:20-21` and `apps/cyfr/lib/prism_web/endpoint.ex:13-14`. Pin `same_site: "Lax"` (Strict would break OAuth callbacks from github.com/google.com). (`prism_web/endpoint.ex:15`'s `max_age: 30*24*60*60` stays unchanged.)

**API-key project scoping (folded into Phase A; completes a half-landed migration — see §2.2).** API keys must be **project-scoped only** — no org-wide or platform-wide keys, even in Arx. Per §2.2, the column and 4-col unique index already exist (`20260312000001_add_tenant_columns_and_scope_rename.exs`); the stale 3-col index `(name, scope_type, org_id)` was never dropped due to a typo in that migration's `drop_if_exists` line. Phase A finishes the work:

- **Migration** `apps/cyfr/priv/repo/migrations/*_rekey_credential_store_and_indexes.exs` (the existing auth-refactor migration — fold the index cleanup in, no separate corrective migration needed):
  - `DROP INDEX IF EXISTS api_keys_name_scope_type_org_id_index` — the stale 3-col index that 20260312000001 failed to drop.
  - The 4-col unique index `api_keys_name_scope_type_org_id_project_id_index` from 20260312000001 already exists and becomes authoritative once the stale one is gone. **No `CREATE INDEX` needed.**
  - No `ADD COLUMN project_id` — column already exists (`NOT NULL DEFAULT 'default'`).
  - The auth-refactor's existing `TRUNCATE api_keys` makes backfill moot in practice; column-default applies to all post-deploy inserts.
- **`apps/cyfr/lib/arca/api_key_storage.ex`** — 8 sites (`:48` insert + `:68, :100, :141, :183, :222, :260, :285` queries) extend their key tuple from `(scope_type, org_id)` to `(scope_type, org_id, project_id)`. Function signatures gain a `project_id` arg throughout.
- **`apps/cyfr/lib/sanctum/api_key.ex`** — thread `project_id(ctx)` through every storage call:
  - `:188, :205, :218, :232, :239, :250, :318` — call sites pass `project_id(ctx)`.
  - Add `defp project_id(ctx), do: ctx.project_id || "default"` (mirror existing `defp org_id(ctx)` at `:542`).
  - `:345-356` `build_key_metadata/2` — add `project_id: row[:project_id]` (now backed by a real column).
  - `:300-310` `validate_key/1` — accept and propagate `project_id` opt; default to `"default"` for unscoped/Core lookups.
- **`apps/cyfr/lib/emissary_web/plugs/mcp_session.ex:500-511`** — already reads `metadata[:project_id]` and propagates via `Context.build/1`. Now wired through with non-nil source. Verify no caller assumes `project_id == nil` means "any project".
- **Pre-merge assertion:** `rg "org_id\(ctx\)" apps/cyfr/lib/sanctum/api_key.ex apps/cyfr/lib/arca/api_key_storage.ex` — every match must be paired with `project_id(ctx)` in the same call.
- **Test coverage:** add cases verifying two keys with same `(name, scope_type, org_id)` but different `project_id` coexist; key created in project A is rejected when validated against project B (same org). Core unaffected (single project, both default to `"default"`).
- **Orthogonality with push tokens (no overlap):** push tokens are user+namespace-scoped, NOT project-scoped — publishing to a namespace is a per-user capability, valid from any project the user is logged into. CredentialStore key remains `_registry.{registry}.{user_id}.{namespace_slug}` (no `project_id` segment). API-key project scoping and push-token namespace scoping are independent concerns.

**No plugs/caches removed from scope** — explicitly NOT created:
- `apps/cyfr/lib/sanctum/plugs/verify_jwt.ex` — not needed (no JWTs to verify).
- `apps/cyfr/lib/sanctum/auth/jwks_cache.ex` — not needed.
- Per-identity refresh mutex — not needed (no refresh tokens).

**`Phoenix.Logger`** `:filter_parameters` in `config/runtime.exs` — add `:push_token` atom to guard against accidental token leakage in logs.

**Migration** `*_rekey_credential_store_and_indexes.exs`:
- `CREATE INDEX ON sessions (user_id)` — for multi-session listing.
- `TRUNCATE sessions` — `user_id` shape changes to `"github|12345"`.
- `DELETE FROM secrets WHERE name LIKE '_registry.%'` — CredentialStore rekeys.
- `TRUNCATE api_keys` — `created_by` shape changes.
- Assert `oauth_credentials.component_ref` values still parse under the new three-shape rules; one-off backfill if any don't (already normalized by `20260328100001_normalize_oauth_component_refs`; should pass).

#### What shipped — codex (Go CLI, at `apps/codex/`)

codex does **no auth itself** — all auth commands delegate to cyfr's MCP `session` and `registry` tools.

- `cmd/login.go:36 AND :61` — drop hardcoded `"provider": "github"` at **both** sites (the second is inside the poll loop, easy to miss); add `--provider` flag (`github` | `google`) with GitHub as the default. `:23` docstring updates from "via GitHub" to "via GitHub or Google (via `--provider`)".
- **First-login claim prompt**: after `session.device-poll` returns `status: "complete"` with `needs_personal_namespace: true`, codex prompts interactively `"Claim your namespace (default: {suggested_username}): "` and invokes `registry.claim-personal`. On 409 `slug_taken` re-prompt. On 400 `INVALID_USERNAME` (user typed `@foo`) re-prompt with a "drop the `@` — slugs are bare" hint. Mandatory — exits with error if user declines.
- `internal/ref/ref.go:70-73` — delete `strings.Replace(s, "@", ":", 1)`. Add explicit regex validation for the three shapes.
- `internal/ref/ref.go:92-105` — flip `strings.Index` → `strings.LastIndex` for both `:` (version) and `.` (namespace/name) splits. Parse order: split on **last `:`** for version, then on **last `.`** for namespace/name within the remainder.
- `internal/ref/ref.go` regex (must match cyfr exactly):
  - Personal: `^[a-z0-9]+(-[a-z0-9]+)*$`, 1–39 chars (bare, no `@`).
  - Publisher: RFC 1035 hostname, ≥1 dot, ≤253 chars, no IDN/IP/port/localhost/trailing-dot.
  - Reserved: seeded list lookup.
  - Name: `^[a-z0-9]+(-[a-z0-9]+)*$`, 1–39 chars.
  - Version: `^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?$`.
- `internal/ref/ref_test.go:107-108` — invert the broken test. Today `c:local.supabase@0.1.0` asserts the `@`-as-version-separator bug as expected behavior; after the fix this must be REJECTED as invalid (any `@` in a ref is invalid post-refactor — personal slugs are bare). Add three-shape positive + negative + round-trip coverage: `c:alice.foo:0.1.0` (personal), `c:stripe.com.api:0.1.0` (publisher), `c:local.foo:0.1.0` (reserved), `c:@alice.foo:0.1.0` (reject — `@` not permitted anywhere), `c:stripe.api:0.1.0` (ambiguous without DB — parses as ns=stripe, name=api; server decides whether `stripe` is a valid personal).
- `cmd/tincture.go:32,38,65,70` — route positional `<publisher>` arg through `ref.ParseRef`; reject any `@` in input with `invalid namespace "<arg>" — personal slugs are bare (e.g. "alice"); publishers require a dot (e.g. "stripe.com")`.
- `cmd/component.go:87 AND :151` — drop the `publisher_name` fallback in search-result rendering at **both** sites; render `namespace_slug` directly.
- `cmd/registry.go` NEW — subcommands: `publisher claim <domain>`, `publisher verify <domain>`, `tokens list <namespace>` / `issue <namespace> --label "..."` / `revoke <id>`, `members list <namespace>` / `add <namespace> <target-personal-slug> [--role admin|member]` / `update <namespace> <target-personal-slug> --role ...` / `remove <namespace> <target-personal-slug>`, `probe` (manual re-sync), `whoami`. All delegate to cyfr MCP `registry` tool. **Naming note**: codex already has `cmd/register.go` (component registration) — use the explicit `cmd/registry.go` or `cmd/registry/` subpackage to avoid developer confusion.
- Existing flat commands stay: `cyfr login`, `cyfr logout`, `cyfr whoami`.
- `cmd/login.go:186-198` (current whoami consumer) — **call both `session.whoami` AND `registry.whoami` MCP actions** (the whoami split — see §Whoami split). Compose the combined view in codex before rendering: local user from `session.whoami`, registry identity from `registry.whoami`. End-user output format unchanged. Same compose pattern applies to `cyfr whoami` flat command.

#### What shipped — Porta (Tauri client, at `apps/porta/`)

Updates to consume the new whoami shape AND the first-login personal-namespace claim prompt. Ship in the SAME release as cyfr MCP schema change.

- `apps/porta/src-ui/src/state/auth-store.ts:34-40` — whoami consumer: **call both `session.whoami` AND `registry.whoami` MCP actions** (the whoami split puts local user and registry identity in two actions; see §Whoami split). Merge the responses in state: local user from `session.whoami` (`user_id, email, provider, display_name`), registry identity from `registry.whoami` (`authenticated, personal_namespace, memberships`). Drop reads of `registry.email` and `registry.publisher_name` (old fields).
- `apps/porta/src-ui/src/state/auth-store.ts:106-142` — device-poll consumer: handle new fields `needs_personal_namespace` + `suggested_username` on status=complete; route to claim-namespace gate when present.
- `apps/porta/src-ui/src/api/cyfr-mcp.ts:25-27` — docstring + return type updated for new whoami (two-action composition).
- **NEW** claim-namespace gate UI (React component) — prompts user for personal-namespace slug with `suggested_username` default, calls `registry.claim-personal` MCP action, handles 409 `slug_taken` with re-prompt. Mandatory: user can't reach the rest of the UI until the claim succeeds (or they explicitly log out).
- `apps/porta/src-ui/src/config/labels.ts` — remove `publisher_name` label mapping.
- `apps/porta/src/preflight.rs:109` — expected-shape checks for new whoami: calls both `session.whoami` (top-level `user_id`) and `registry.whoami` (top-level `authenticated`); update assertions accordingly.
- `apps/porta/src/commands/cyfr.rs:319-353` — Rust MCP fallback path; generic JSON parsing already forward-safe, but update documented expected shape to reflect the two-action whoami.

#### Phase A checklist

cyfr.run (Go) — **SHIPPED 2026-04-18 at `58af29d`.** All 36 checklist items satisfied (migrations 000004–000008; new API/store/providers/httpclient/dnsverify/tokenreaper packages; legacy JWT/OIDC/deviceflow/orgs/publishers removed; Bearer+Basic push-token auth with `WWW-Authenticate`; synchronous `audit.*` emission; rate-limit buckets wired; integration tests passing). See §2.1 + cyfr.run git log `0fe1200..58af29d` for detail. **Phase A follow-up shipped 2026-04-20** — `GET /.well-known/cyfr-registry.json` handler registered at `router.go:87` (cyfr.run@718852a).

**Client-side Phase A status (2026-04-20): SHIPPED.** All cyfr (Elixir) / codex / Porta items below are complete. All §2.4 pre-merge grep assertions pass: `Memberships.` / `publisher_name` / `registry-login` / `get_for_registry` / `resolve_any_credential` / `(:basic|:bearer|:oauth2_client|:key_pair)` in `apps/cyfr/lib/compendium/` / `provider_login` / `display_name/1` all return 0 (only `registry-login` has one residual user-facing error message + comment, and `get_for_registry` has one docstring memorial). Layering greps pass: `apps/cyfr/lib/sanctum/auth/` Compendium edges restricted to `device_flow.ex` (post-probe handoff); `sanctum/mcp.ex` Compendium-free; `auth_controller.ex` Compendium edges only at the documented post-probe `CredentialStore.put/4` handoff. cyfr Elixir `mix test --warnings-as-errors` clean; codex `go test ./...` green; Porta `pnpm tsc + pnpm build` green. All seven §1 invariants satisfied; Arx Lane 1 + Lane 2 readiness preserved. The orthogonal Porta agent-UI tree shipped alongside Phase A at cyfr@c3feaeb (2026-04-20) in the same release.

cyfr (Elixir):
- [x] **User.id format change — FOUR sites (unified across Core + Arx):** format is `"<provider>|<iss>|<subject>"` with scheme-prefixed iss (RFC 7519 shape). `apps/cyfr/lib/sanctum/user.ex:31-38` (`from_oidc_claims/1`) builds `id: "#{provider}|#{claims["iss"]}|#{claims["sub"]}"`; `apps/cyfr/lib/sanctum/auth/simple_oauth.ex:43-48` (direct `%User{}` build) formats `id: "#{provider}|#{provider_iss(provider)}|#{user_info.id}"` where `provider_iss/1` hardcodes `"https://github.com"` / `"https://accounts.google.com"`; `apps/cyfr/lib/sanctum/auth/device_flow.ex:330-339` (`create_session/2`) same hardcoded-iss pattern; `apps/cyfr/lib/sanctum_arx/auth/oidc.ex:72-80` — replace `id: to_string(auth.uid)` with `id: "#{provider}|#{iss}|#{auth.uid}"` where `iss` comes from `auth.info.urls[:oidc_issuer]` or `auth.extra.raw_info["id_token"]["iss"]` for `:oidcc`, and from the hardcoded provider issuer for `:github`/`:google` (Lane 1 Arx). Arx uses the **same** id format as Core. `user.ex:54-61` `local/0` keeps `id: "local_user"` unchanged; `sanctum_arx/auth/oidc.ex:105-110` API-key path keeps `id: "api_key:<name>"` unchanged. **No `:provider_login` field, no `display_name/1` helper** — UI renders `email || id` directly (GitHub + Google reject `email_verified=false` so `email` is always present for real users).
- [x] `apps/cyfr/lib/compendium/cyfr_run/client.ex` EXTEND — `probe_identity/3`, `claim_personal_namespace/4`, `claim_publisher_namespace/2`, `verify_publisher_namespace/1`, `issue_additional_token/3`, `revoke_token/3`, `add_member/4`, `update_member/4`, `remove_member/3`, `list_members/2`, `get_namespace/1`, `whoami/1`. **Modify existing `defp auth_headers(ctx)` at `:219-236`** to emit `Bearer <push_token>` for `type: :push_token` credentials (function exists; do not create new helper). Resolve by URL's slug for namespace-scoped calls; use the head (personal-namespace-first) of `CredentialStore.list_for_user/2` for `/v1/identity/probe` (not namespace-scoped). **Finch response-body redaction — single wrapper:** introduce `Compendium.CyfrRun.Client.Finch.token_redacting_wrapper/2` used by every token-returning endpoint call (`/v1/namespaces/personal/claim`, `/v1/namespaces/publisher/verify`, `/v1/namespaces/{slug}/tokens`, `/v1/identity/probe`). Wrapper masks `token` / `push_token` fields in any `:telemetry` event or log emission. Single-point enforcement; adding future token-returning endpoints only requires using the wrapper, not per-path audit. Phoenix `:filter_parameters` only covers inbound request params, not outbound response bodies.
- [x] `apps/cyfr/lib/compendium/registry/credential_store.ex` — **API cascade**: key `_registry.{registry}.{user_id}.{namespace_slug}`; `put/3 → put/4`, `get/2 → get/3`, `delete/2 → delete/3`; NEW `list_for_user/2`; **DELETE `get_for_registry/1`** entirely (two justifications: Core is multi-user — fallback is a privacy leak; cross-registry doesn't exist — so the other caller `resolve_any_credential/1` has no legitimate use). Stored value uniformly `%{type: :push_token, token, namespace, issued_at, label}`. **Drop** dedicated salt (C4 — use same `Sanctum.Secrets` encryption). `@valid_keys` attribute lists `:type, :token, :namespace, :issued_at, :label, :role, :push_token` only (drop `:username, :password, :client_id, :client_secret, :token_url, :public_key, :private_key, :basic, :bearer, :oauth2_client, :key_pair` — non-push-token types deleted). Callers of the deleted function must be rewritten (no silent fallback; surface `:no_push_token` with actionable message).
- [x] `apps/cyfr/lib/compendium/oci/auth.ex` — **collapse to push-token only** (no cross-registry): rename `resolve_credentials/2` at `:128-139` → `fetch_credential/3(registry, namespace_slug, ctx)`; `auth_headers/3` at `:27-57` → `auth_headers/4(registry, repository, namespace_slug, ctx)` with only two branches (`:push_token` → Bearer; fallback → anonymous); **DELETE** the `:basic`/`:bearer`/`:oauth2_client`/`:key_pair`/legacy-map dispatch branches, `resolve_any_credential/1` at `:275-280`, `get_cached_token/2` + `cache_token/4` at `:145-161`, `handle_challenge/4` + `exchange_token/4` at `:167-227` + callers. All dead code under single-registry scope.
- [x] `apps/cyfr/lib/sanctum/auth/simple_oauth.ex:36,170,176,186,27,43-48` — `@supported_providers [:github, :google]`; add `:google` clauses to `provider_configured?/1`, `github_config/0` parallel, `extract_user_info/1`; docstring at `:27` drops "Google" from the "requires Sanctum Arx" list; `%User{}` build at `:43-48` formats id as `"#{provider}|#{provider_iss(provider)}|#{user_info.id}"` with hardcoded per-provider issuer. Behaviour contract unchanged.
- [x] `apps/cyfr/lib/sanctum/auth/device_flow.ex` — parameterize endpoint constants by provider (URL constants at `:37-39`, scope at `:42`); add `:google` clauses to `request_device_code/2` (`:187`), `request_token/3` (`:227`), `fetch_user_info/2` (`:275`), `get_client_id/1` (`:345-348`); remove silent best-effort `/auth/token` exchange at `:119-138`; drop `registry_token_url/0` (`:391-393`); format `%User{}` id in `create_session/2` (`:330-339`). **After `Session.create/1` in `poll_for_session/2` (function defined at `:106`; the body block to update is at `:114-181`): invoke `Compendium.CyfrRun.Client.probe_identity/3`** with the in-hand `tokens.access_token`; store returned tokens in `CredentialStore`; augment MCP response with `needs_personal_namespace` + `suggested_username` when applicable. Discard access_token after probe.
- [x] `apps/cyfr/lib/emissary_web/controllers/auth_controller.ex:66-110` — at top of `callback/2`, extract `access_token = auth.credentials && auth.credentials.token` BEFORE calling `authenticate_with_provider/1` (which today never reads `auth.credentials.token`). After `Session.create/1`, invoke `probe_identity/3` with the extracted token; if `personal_namespace: nil` redirect to `/claim-namespace` gate (mandatory claim before dashboard); else proceed. Add `/claim-namespace` + `/claim-namespace/submit` routes with their LiveView/controller. Keep `authenticate_with_provider/1` signature unchanged — SimpleOAuth and OIDC modules continue to return `{:ok, user}`. **Probe failure does NOT block session creation** — session row stays in DB, user lands on claim-gate (or dashboard) with a "Retry probe" action that re-invokes `probe_identity/3` with the still-cached `access_token`.
- [x] **NEW** `apps/cyfr/lib/emissary_web/plugs/require_personal_namespace.ex` + `apps/cyfr/lib/emissary_web/plugs/personal_namespace_cache.ex` (ETS cache GenServer). Plug checks **at runtime** whether the authed user has a personal-namespace credential: first consults ETS cache (keyed by `{user_id, oci_registry_url}`, 30s TTL, boolean value); on miss, calls `Compendium.Registry.CredentialStore.list_for_user/2(user_id, oci_registry_url)` and tests for any entry whose namespace is bare (no dot — personal + reserved are both bare, so this check treats both as "has a non-publisher credential"; since reserved namespaces are admin-only, a regular user's bare credential is always their personal namespace); populates cache. If no personal entry, redirect to `/claim-namespace`. **Bypass list:** `/claim-namespace/*`, `/auth/*`, `/health`, `/mcp` (all methods — MCP uses Bearer/API-key auth, separate plane), `/assets/*`. **`/live/*` is NOT bypassed** — LiveSocket WS upgrades carry the session cookie and hit the `:browser` pipeline; gating them uniformly prevents a dashboard LiveView from mounting for a not-yet-claimed user during the 30s cache window. One extra ETS hit per WS upgrade; negligible. **Mount order (critical):** in `EmissaryWeb.Router`'s `:browser` pipeline, **after** `plug Sanctum.Plugs.FetchCurrentUser` (or equivalent authentication plug that sets `conn.assigns.current_user`) and BEFORE any route dispatch. Same plug + mount in `prism_web/` for the LiveView shell. **No PubSub invalidation** — 30s TTL self-heals across multi-session (user claims on device A, device B's next request after 30s exits the gate). This was a deliberate choice over pub/sub broadcast: simpler, fewer moving parts; one-time-claim delay of ≤30s is acceptable. Verify mount order with `mix phx.routes`. ETS cache GenServer starts in `Cyfr.Application` supervision tree before the Endpoints.
- [x] `apps/cyfr/lib/sanctum/component_ref.ex` — full three-shape rewrite: replace `@namespace_regex` at `:41` with bare-personal regex (`^[a-z0-9]+(-[a-z0-9]+)*$`, 1–39 chars) + publisher RFC-1035 validator function + reserved seeded-list lookup + `classify_namespace/1` dispatcher (order: publisher-if-dot → reserved-if-seeded → personal-else; reject any `@`); rewrite `validate_namespace/1` at `:448-468`; `parse_ns_name/1` at `:398-417` splits on last `:` then last `.`; audit `validate_publisher/1` (`:482`), `validate_ref_parts/2` (`:528`), `Sanctum.TinctureAccess` for the semantics change (a bare slug like `"foo"` is now valid as personal, a change from today's regex which already forbids dots but passes bare names); update doctests `:440-444, 477-478, 492-493`.
- [x] `apps/cyfr/lib/sanctum/mcp.ex:131-190, 511, 576, 178-182` — **MCP tool relocation**: DELETE `registry-login` action + its fields from session tool (`registry/type/username/password/token/client_id/client_secret/token_url`); DELETE handler at `:511`; update error message at `:576`; update `provider` enum at `:178-182` to `["github", "google"]`. Keep `login`/`logout`/`whoami`/`device-init`/`device-poll`.
- [x] `apps/cyfr/lib/sanctum/mcp.ex:438-447` — **whoami split**: `session.whoami` returns local user only (`{user_id, email, provider, display_name}`); DROP the `registry` sub-object entirely (registry identity moves to `Compendium.MCP.registry.whoami`). Remove all `Compendium.*` references from `sanctum/mcp.ex`.
- [x] `apps/cyfr/lib/compendium/mcp.ex` — ADD new `registry` tool with actions `probe`, `claim-personal`, `claim-publisher`, `verify-publisher`, `tokens-list`/`issue`/`revoke`, `members-list`/`add`/`update`/`remove`, `whoami` (returns `{authenticated, personal_namespace, memberships}` via `Compendium.Registry.Identity.identity/1`). Handlers delegate to `Compendium.CyfrRun.Client.*`. Replace `publisher_name` fields in response shapes with `namespace_slug`. Simplify `default_registry/0` (`:1381-1389`) to `Application.get_env(:cyfr, :oci_registry_url)`. Replace `"registry.cyfr.run"` literal at `:512` with `:oci_registry_url` host.
- [x] `apps/cyfr/lib/emissary/mcp/tool_visibility.ex:45` — replace `"session.registry-login" => :admin` with `"registry.*" => :user` (admin-gating applied inside handlers for `members-*`).
- [x] `apps/cyfr/lib/compendium/oci/client.ex:1032-1050` — DELETE `resolve_publisher_name/2`, `decode_jwt_publisher/1`.
- [x] `apps/cyfr/lib/compendium/oci/client.ex` (push helpers) — retry-on-401: check `get_namespace/1`; bubble `{:error, :token_revoked}` if revoked. No refresh.
- [x] `apps/cyfr/lib/compendium/registry/identity.ex` — **keep `resolve_credentials/1`** (private helper at `:88-96`) as-is; rename only `OCI.Auth.resolve_credentials/2` (C5); rewrite `do_whoami/2` at `:35-77` from Basic → Bearer, target `/v1/namespaces/{slug}` per-token, iterate via `CredentialStore.list_for_user/2`; new return shape `%{authenticated, user_id, personal_namespace, memberships}` (consumed by new `Compendium.MCP.registry.whoami` action, not by `Sanctum.MCP.session.whoami`); drop `data["publisher_name"]` read at `:59`; simplify `registry_url/0` at `:79-84` to bare-string read of `:oci_registry_url`; keep Arx `resolve_tenant_credentials/2` at `:124-147` intact.
- [x] `apps/cyfr/lib/compendium/application.ex:7-78` — DELETE `validate_registry_credentials!/0` (`:13-34`); DELETE `validate_api_url!/0` (`:64-78`); simplify `validate_registry_url!/0` (`:36-62`) to bare-string read; ADD parallel `validate_oci_registry_url!/0` pinning Core to `registry.cyfr.run`; update orchestrator at `:7-11`.
- [x] `apps/cyfr/lib/compendium/edition.ex:9` — derive `@cyfr_run_registry` from `:oci_registry_url`.
- [x] `apps/cyfr/lib/emissary/mcp/tools/system_provider.ex:378-380` — bare-string read of `:oci_registry_url`.
- [x] `apps/cyfr/lib/prism_web/live/components_live.ex:965, 1194, 1378` — render `comp[:namespace_slug]` instead of `comp[:publisher_name]`.
- [x] Display-format audit — `prism_web/components/layouts/app.html.heex:91`, `prism_web/auth_helpers.ex`, `prism_web/live/settings_live.ex`, `prism_web/live/shell_compat.ex` — render `@current_user.email || @current_user.id` directly. For the rare id-only fallback (no email), use a local `String.split("|", parts: 3)` helper to pretty-print `@<provider>:<subject>` rather than the raw pipe-delimited id. No `display_name/1` helper needed.
- [x] `config/runtime.exs` — DELETE `:cyfr, :registry` keyword-list block at `:213-249`; DELETE `:cyfr_run_api_url` at `:383-385`; replace with `config :cyfr, :registry_url` + `config :cyfr, :oci_registry_url` (see §Config consolidation). After `:211` GitHub block, ADD parallel Google block (`CYFR_GOOGLE_CLIENT_ID`, `CYFR_GOOGLE_CLIENT_SECRET`, `Ueberauth.Strategy.Google.OAuth`). Add `google_configured?` at `:300-302` and update dispatcher condition at `:320-322` + error msg at `:325-335`. After `:344` Ueberauth providers list, add `google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]}`. Add `:push_token` to `:filter_parameters`. Keep `:jwt_signing_key` block at `:256-259`.
- [x] `config/arx_runtime.exs` — DELETE `:cyfr, :registry` block at `:123-129`; replace with `:registry_url` + `:oci_registry_url` env mappings. Keep `:auth_provider` pin at `:17`, Ueberauth providers at `:80-85`, Google wiring at `:117-121`.
- [x] **API-key project scoping (full cascade — see §API-key project scoping):** new migration `*_add_project_id_to_api_keys.exs` (ADD COLUMN + DROP/CREATE unique index); `apps/cyfr/lib/arca/api_key_storage.ex` 8 sites take `project_id` arg + filter by it; `apps/cyfr/lib/sanctum/api_key.ex` `:188, :205, :218, :232, :239, :250, :318` thread `project_id(ctx)`; add `defp project_id(ctx)` (mirror `:542`); `:345-356` `build_key_metadata/2` adds `project_id: row[:project_id]`; `:300-310` `validate_key/1` accepts `project_id` opt. Pre-merge: every `org_id(ctx)` paired with `project_id(ctx)`.
- [x] **Latent fix:** `apps/cyfr/lib/emissary_web/endpoint.ex:20-21`, `apps/cyfr/lib/prism_web/endpoint.ex:13-14` — add `secure: config_env() == :prod`; pin `same_site: "Lax"`.
- [x] Migration `apps/cyfr/priv/repo/migrations/*_rekey_credential_store_and_indexes.exs` — `CREATE INDEX ON sessions (user_id)`; `TRUNCATE TABLE IF EXISTS sessions`; `DELETE FROM secrets WHERE name LIKE '_registry.%' OR name = 'registry_credentials'` (latter covers legacy Arx tenant creds — see §Arx tenant-cred wipe); `TRUNCATE TABLE IF EXISTS api_keys`. No `provider_login` column add (field dropped from `%User{}`).
- [x] UPDATE `apps/cyfr/test/compendium/oci/client_test.exs:335-402` — NOT dead tests. This is the `describe "startup validation"` block with three tests of `Compendium.Application.validate_registry_config!/0` using `"ghcr.io"` as the example non-cyfr.run URL for Core rejection + Arx acceptance. Update assertions + fixtures to the new two-knob config (`:registry_url` + `:oci_registry_url`) and the renamed validators (`validate_registry_url!/0` + new `validate_oci_registry_url!/0`). Keep the three test cases.
- [x] `apps/cyfr/test/sanctum/component_ref_test.exs` — extend with three-shape + homograph/IDN rejection + trailing-dot normalization + round-trip. Update doctest expectations on `validate_namespace/1`.
- [x] Audit 13 files touching `user.{email|provider|org_id|project_id}` via dot-access (5 test + 8 lib; 51 total hits); only additions for logging (no drops) — grep-verify no regressions.
- [x] Pre-merge assertions: `rg "Memberships\\." apps/cyfr/lib/sanctum/auth/` → zero (SimpleOAuth/DeviceFlow must not reach into SanctumArx); `rg "publisher_name" apps/cyfr/lib/ apps/codex/` → zero; `rg "registry-login" apps/cyfr/lib/ apps/codex/` → zero (covers both sanctum/mcp.ex:511 handler AND codex/cmd/component.go:505-512 call block); `rg "get_for_registry" apps/cyfr/lib/` → zero; `rg "resolve_any_credential" apps/cyfr/lib/` → zero; `rg "(:basic\\|:bearer\\|:oauth2_client\\|:key_pair)" apps/cyfr/lib/compendium/` → zero (non-push-token credential types deleted); **layering (auth sliver only)** `rg "Compendium\\." apps/cyfr/lib/sanctum/auth/` → only `device_flow.ex` (post-probe CredentialStore.put handoff) AND `rg "Compendium\\." apps/cyfr/lib/sanctum/mcp.ex` → zero AND `rg "Compendium\\." apps/cyfr/lib/emissary_web/controllers/auth_controller.ex` → only the post-probe CredentialStore.put handoff. (Component-aware Sanctum modules — `policy.ex`, `policy_store.ex`, `oauth.ex`, `tincture_access.ex` — keep their existing Compendium deps by design; not part of this assertion.)

codex (Go, at `apps/codex/`):
- [x] `cmd/login.go:36 AND :61` — drop hardcoded `"provider": "github"` at **both** sites; add `--provider` flag (github | google; default github). `:23` docstring updates from "via GitHub" to "via GitHub or Google".
- [x] `cmd/login.go` post-`device-poll` — when response has `needs_personal_namespace: true`, prompt user interactively (default = `suggested_username`), then invoke `registry.claim-personal` MCP action. On 409 `slug_taken` re-prompt. Login exits with error if user cancels (personal namespace is mandatory).
- [x] `internal/ref/ref.go:70-73, 92-105` — delete the `strings.Replace(s, "@", ":", 1)` block; flip `strings.Index` → `strings.LastIndex` at `:92` (version `:` separator), `:93` (namespace/name `.` separator), `:99/:101` (version `:` within remainder). **Keep `strings.Index(s, ":")` at `:79`** — that's the type-prefix detector (`c:`, `t:`, `w:` — always a leading short token followed by the FIRST colon); flipping to LastIndex there would mis-parse `c:@alice.foo:0.1.0`. Add three-shape regex validation.
- [x] `internal/ref/ref_test.go:107-108` — invert the broken test (`c:local.supabase@0.1.0` must now REJECT — any `@` in ref is invalid); add three-shape positive + negative + round-trip coverage: `c:alice.foo:0.1.0` (personal), `c:stripe.com.api:0.1.0` (publisher), `c:local.foo:0.1.0` (reserved), `c:@alice.foo:0.1.0` (reject — `@` banned), `alice` (reject — no name).
- [x] `cmd/tincture.go:32,38,65,70` — route positional `<publisher>` arg through `ref.ParseRef`; reject bare unqualified names.
- [x] `cmd/component.go:87 AND :151` — drop the `publisher_name` fallback in search-result rendering at **both** sites; render `namespace_slug` directly.
- [x] `cmd/component.go:505-512` — DELETE the `registry-login` MCP call block (interactive username/password prompt → `session` tool `registry-login` action). Push auth moves to push_token; credential bootstrap is automatic via `cyfr login` → probe → CredentialStore.put/4. Ship in lockstep with `sanctum/mcp.ex:511` handler deletion.
- [x] `cmd/registry.go` (or `cmd/registry/` subpackage) NEW — `publisher claim|verify`, `tokens list|issue|revoke`, `members list|add|update|remove|promote|demote`, `probe`, `whoami` subcommands. Naming guard against existing `cmd/register.go` (component registration).
- [x] `cmd/login.go:186-198` (current whoami consumer) + flat `cyfr whoami` command — call BOTH `session.whoami` and `registry.whoami` MCP actions and compose the combined view before rendering (whoami split — see §Whoami split). Output format unchanged; only the wire protocol changes. **`--no-probe` follow-up:** when `cyfr whoami` calls `registry.whoami` and the response shows `authenticated: false` (no CredentialStore entries for the configured registry), codex automatically invokes `registry.probe` MCP action with the still-cached access_token (web flow) or re-runs DeviceFlow (CLI flow) to mint tokens. Closes the offline-first-login gap: a user who logged in with `--no-probe` runs `cyfr whoami` once back online and tokens auto-mint without explicit re-login.

Porta (Tauri, at `apps/porta/`):
- [x] `src-ui/src/state/auth-store.ts:34-40` — consume new whoami shape via TWO MCP actions: `session.whoami` (local user: `user_id, email, provider, display_name`) + `registry.whoami` (registry identity: `authenticated, personal_namespace, memberships`). Merge in state; drop old `registry.email`/`registry.publisher_name` reads.
- [x] `src-ui/src/state/auth-store.ts:106-142` — device-poll consumer: handle `needs_personal_namespace` + `suggested_username` fields on status=complete; route to claim-namespace gate.
- [x] `src-ui/src/api/cyfr-mcp.ts:25-27` — docstring + return type updated for new whoami.
- [x] NEW claim-namespace gate React component + route — prompts user for personal-namespace slug (default = `suggested_username`), posts to `registry.claim-personal` MCP action, re-prompts on `slug_taken`, blocks UI until claim succeeds.
- [x] `src-ui/src/config/labels.ts` — remove `publisher_name` label mapping.
- [x] `src/preflight.rs:109` + `src/commands/cyfr.rs:319-388` — expected-shape checks for new whoami: calls both `session.whoami` (top-level `user_id`) and `registry.whoami` (top-level `authenticated`); update assertions and the Rust MCP fallback path to reflect the two-action composition. Generic JSON parsing already forward-safe. (Previous draft cited a nonexistent `src/commands/cli.rs`; the whoami-shape checks live in `preflight.rs` and `commands/cyfr.rs`.)
- [x] SHIP in the same release as cyfr MCP schema change and cyfr.run rollout.

#### Done when

1. **CLI login (GitHub)**: `cyfr login --provider github` → DeviceFlow completes → `Sanctum.Session` created cyfr-locally → `probe_identity` auto-called with access_token → if personal namespace not yet claimed, codex prompts + claims → all returned push tokens stored in CredentialStore. One command end-to-end.
2. **CLI login (Google)**: same via Google.
3. **Web login**: browser OAuth → AuthController.callback → probe → if personal namespace not yet claimed, redirect to `/claim-namespace` gate (dashboard inaccessible until gate satisfied) → on submit, tokens stored, dashboard opens.
4. **Personal namespace is 1:1**: concurrent `POST /v1/namespaces/personal/claim` from same `(provider, subject)` with different slugs — exactly one succeeds; others get 409 `already_claimed` (partial unique index enforces). Second-time claim by same user always 409.
5. **Publisher claim**: `cyfr registry publisher claim acme.com` (requires bearer for caller's personal namespace) → TXT challenge → user sets DNS → `cyfr registry publisher verify acme.com` → namespace `domain_verified=true`, caller inserted as sole admin in `namespace_members`, first push token issued atomically.
6. **Member add**: admin runs `cyfr registry members add acme.com bob` → cyfr.run resolves `bob` to `(github, 99999)`, inserts `namespace_members` row. Bob's cyfr next calls `/v1/identity/probe` (via `cyfr whoami` or next login) → receives `acme.com` membership + fresh push token → stored.
7. **Publish**: `cyfr publish c:acme.com.widget:1.0.0` → Bob's cyfr resolves `acme.com` token from CredentialStore → OCI push with Bearer → rbac.go looks up `push_tokens WHERE token_hash=$1 AND revoked_at IS NULL` → namespace match → allowed. Audit `audit.push.allowed` emits synchronously.
8. **Member remove**: admin runs `cyfr registry members remove acme.com bob` → atomic DB ops: delete `namespace_members` row + revoke all `push_tokens` where `namespace_slug='acme.com' AND created_via='github|99999'`. Bob's next push to `/v2/acme.com/*` returns 401 with `WWW-Authenticate: Basic realm=...`.
9. **Sole-admin protection**: attempt to demote/remove the last admin of a publisher → 409 `sole_admin`.
10. **Multi-session same user**: Alice opens tab 1 + tab 2 → both logged in (separate `Arca.SessionStorage` rows, same `user_id`), share the same CredentialStore namespace tokens. CLI `cyfr publish` concurrent — no conflict.
11. **Multi-user same instance**: Bob logs in on same cyfr → separate `Sanctum.User` (id `github|99999`) → separate CredentialStore entries under `_registry.<url>.github|99999.*`. Independent pushes.
12. **Docker compat**: `docker login registry.cyfr.run -u anyuser -p <push_token>` succeeds; `docker push registry.cyfr.run/alice/foo:latest` works. 401 responses carry `WWW-Authenticate: Basic realm=...`.
13. **Squat semantics**: `claim stripe` (bare personal, not a reserved seed) → succeeds first-come-first-served. Brand trust is earned via the publisher tier: `stripe.com` (DNS-verified) carries the verified-publisher badge; bare `stripe` does not. Both slugs coexist as distinct entities.
14. **Instant revocation**: `cyfr registry tokens revoke <id>` → next push returns 401 within one request cycle.
15. **Concurrent slug-claim atomicity**: N parallel claims for same slug → exactly one succeeds; no orphan namespace rows.
16. **DNS re-verification**: mock DNS removal → cron fires 3 times with exponential backoff → `domain_verified=false` → next push to that publisher returns 403.
17. **Arx switch**: `CYFR_EDITION=arx` + `CYFR_REGISTRY_URL=acme.internal` + `CYFR_OCI_REGISTRY_URL=acme.internal` → cyfr points at self-hosted cyfr.run → all flows work unchanged. Arx-ready invariants preserved (SanctumArx.Memberships uncoupled from SimpleOAuth paths; `:push_token` support in OCI.Auth covers both per-user and Arx tenant-scoped creds).
18. **Post-deploy assertions**: `rg "publisher_name" apps/cyfr/lib/ apps/codex/ ~/Projects/cyfr.run/internal/` → zero; `rg "registry-login" apps/cyfr/lib/` → zero; `rg "cc\\.(Email|PublisherName|OrgID|UserID)" ~/Projects/cyfr.run/internal/` → zero; `rg "Memberships\\." apps/cyfr/lib/sanctum/auth/` → zero.
19. **Layering assertions**: `rg "get_for_registry" apps/cyfr/lib/` → zero (fallback deleted); **scoped to auth sliver**: `rg "Compendium\\." apps/cyfr/lib/sanctum/auth/` → only `device_flow.ex` AND `rg "Compendium\\." apps/cyfr/lib/sanctum/mcp.ex` → zero AND `rg "Compendium\\." apps/cyfr/lib/emissary_web/controllers/auth_controller.ex` → only the CredentialStore.put handoff. Component-aware Sanctum modules (policy.ex, policy_store.ex, oauth.ex, tincture_access.ex) keep their Compendium deps by design — these are not layering violations and not part of the assertion.
20. **Multi-user Core privacy test**: user A on the same Core instance as user B. User A has a push token for `alice.foo` (namespace `alice`, name `foo`); user B has no credential. User B's attempt to push to `alice.foo` returns `{:error, :no_push_token}` with actionable message. User A's token is never silently returned as a fallback.
21. **Cross-edition identity test**: Alice on Core via GitHub OAuth and Alice on Arx (with GitHub configured as IdP) via GitHub OAuth both produce `Sanctum.User.id = "github|https://github.com|12345678"`. cyfr.run resolves both to the same personal namespace `alice`; her memberships apply in both sessions. No Phase D `identity_links` row needed for this case. **Cross-edition simultaneous publish arbitration**: if Alice publishes the same `c:alice.foo:1.0.0` from Core and Arx concurrently, cyfr.run's `components` UNIQUE constraint `(component_type, namespace_slug, name, version)` arbitrates — first commit wins, second receives 409 `version_exists`. cyfr/codex surface this as a re-version-and-retry prompt (no auto-bump).
22. **Arx enterprise-OIDC lane test**: Alice on Arx via Okta (OIDC) produces `id = "oidcc|<subject>"`. Without a Phase D `identity_links` row, her namespace claim attempts on cyfr.run fail cleanly (cyfr.run has no way to verify OIDC tokens). With a linked GitHub identity, claims succeed using the linked GitHub access_token.
23. **Whoami split assertion**: `rg "Compendium\\.Registry\\.Identity" apps/cyfr/lib/sanctum/mcp.ex` → zero. The `session.whoami` action returns local user only; `registry.whoami` (new Compendium action) returns registry identity.
24. **Test suite**: `apps/cyfr/test/compendium/oci/client_test.exs` three `validate_registry_config!` tests still pass under the renamed validators (`validate_registry_url!/0` + new `validate_oci_registry_url!/0`).
25. **API-key project scoping**: API key created in project A is rejected when validated against project B in the same Arx org. Two keys with same `(name, scope_type, org_id)` but different `project_id` coexist. Core unaffected — single project, both default to `"default"`.
26. **OCI.Auth push-token only**: `rg "(:basic\|:bearer\|:oauth2_client\|:key_pair)" apps/cyfr/lib/compendium/` → zero. Cross-registry dispatch branches, token cache, and realm-exchange all deleted (single-registry scope; no ghcr.io / Docker Hub / generic OCI).
27. **No-fallback guarantee**: `rg "resolve_any_credential\|get_for_registry" apps/cyfr/lib/` → zero outside of tests. Callers surface `:no_push_token` actionable error when no credential exists.
28. **Codex registry-login extinction**: `rg "registry-login" apps/codex/` → zero (component.go:505-512 block deleted in lockstep with server-side handler).
29. **Claim-gate self-heals across multi-session**: runtime-computed via `CredentialStore.list_for_user/2`, cached in ETS with 30s TTL. User on device A claims personal namespace; device B's next request after 30s exits the gate on its own (CredentialStore now has the entry). No schema flag; no manual session reset needed. `Arca.SessionStorage` table unchanged.
30. **iss-included id format**: `rg '"github\|https://github\.com\|"' logs/` shows canonical Core id shape in production logs. `rg '"google\|https://accounts\.google\.com\|"' logs/` same for Google.
31. **No provider_login / display_name**: `rg 'provider_login' apps/cyfr/lib/` → zero. `rg 'display_name/1' apps/cyfr/lib/` → zero.
32. **Reaper integration test**: seed one token with `last_used_at = now() - interval '400 days'` and one fresh token for same namespace; run reaper; assert only the 400-day token revoked (most-recent-per-namespace protection for the fresh one).
33. **Probe rate-limit integration test**: 11th `/v1/identity/probe` from same IP within 1 min returns 429; concurrent legitimate `/v1/namespaces/*` calls from same IP still succeed (separate bucket).
34. **Arx tenant-cred wipe**: seed `INSERT INTO secrets (name, ...) VALUES ('registry_credentials', ...)` pre-migration; post-migration `SELECT * FROM secrets WHERE name = 'registry_credentials'` returns zero rows.
35. **Constraint-name dispatch**: force birthday collision via test seam → handler retries token generation once and succeeds. Force `(provider, subject)` re-claim → 409 `already_claimed`. Force `slug` collision → 409 `slug_taken`.
36. **CSRF on claim-namespace**: POST `/claim-namespace/submit` without CSRF token returns 403 (`:protect_from_forgery` plug active in `:browser` pipeline).
37. **Deploy sequence docs**: `deploy.sh` help output lists maintenance-page on/off + `pg_dump` pre-wipe step. Rollback documented.
38. **slog JSON + label sanitization**: submit a POST with `label="alice\nFAKE LOG"`; assert log output JSON-escapes `\n` (no literal newline in log line). Labels > 64 chars return 400.
39. **ETS cache correctness**: claim-gate test — request 1 populates cache (hit on DB), requests 2-N within 30s skip DB (cache hit); after claim + 30s TTL expiry, cache miss → CredentialStore lookup returns `true` → user exits gate without manual reset.

#### Not touched in Phase A

Explicit out-of-scope confirmations (prevents scope-creep mid-execution):

- `Arca.OAuthStorage` + `oauth_credentials` table — host-managed OAuth for WASM components (WIT `cyfr:oauth/token`). Orthogonal to user auth.
- `Arca.SecretStorage` — backs Arx tenant creds; untouched. Multi-namespace Arx tenant creds are a Phase D problem.
- `SanctumArx.Memberships` — Phase D template for `identity_links`; not modified in Phase A.
- `Sanctum.Secrets` / `Sanctum.Crypto` internals — unchanged; reused for CredentialStore encryption.
- WIT interface `cyfr:oauth/token` — unchanged.
- Porta credential storage (today: plaintext JSON) — deferred to a dedicated Porta security pass.
- **Air-gapped Arx deployments** — Phase A's `internal/providers/{github,google}.go` call github.com / googleapis.com userinfo endpoints directly; air-gapped Arx cannot reach those. Phase D ships `internal/providers/oidc.go` with local id_token verification (no external network), enabling air-gapped Arx namespace claims.
- **Probe amplification risk** — `/v1/identity/probe` issues push tokens for all of a user's namespaces atomically on every call. A stolen OAuth access_token yields access to every namespace the user belongs to. Phase A mitigations: separate per-IP rate-limit bucket (10/min burst 3), per-subject cap (10 probes/hour), synchronous `audit.identity.probe` event. **User email notification on new-device probe remains deferred** — not shipped in Phase C (cyfr.run has no email infrastructure today). Tracked in §Deferred below.
- **Personal-namespace impersonation** — an attacker (any provider) registers first and claims `alice`; real Alice is locked out of that slug. Phase A has no automatic recourse — personal namespaces are first-come-first-served, identical to Docker Hub / ghcr.io / npm / PyPI. Brand-sensitive names should claim the publisher tier (`alice.com` with DNS verification). Phase C admin moderation (`abuse_reports` + takedown) is the backstop for trademark disputes.
- **Subdomain squat on verified parent** — `evil.stripe.com` can be DNS-claimed independently of `stripe.com`; parent-domain owner has no veto. Deliberate design (DNS is the only ownership signal). Phase C abuse reports cover pathological cases.
- **Root shell on Core BEAM node** — out of threat model. CredentialStore AES-256-GCM encryption prevents casual DB dumps; runtime memory extraction / env-var exposure is not defended.
- **TLS compromise** — a push token intercepted mid-TLS grants namespace-scoped push until explicit revocation or 365-day reaper. Acceptable post-TLS-compromise stance.

---

### Phase B — Deprecation + yank [SHIPPED]

Unchanged in concept from earlier draft. `components.status` trio (`active` | `deprecated` | `yanked` | `taken_down`); endpoints gated by valid push token for owning namespace.

**What ships:**
- `components.status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','deprecated','yanked','taken_down'))`, `status_reason TEXT`, `status_changed_at TIMESTAMPTZ`. Same columns serve Phase C takedowns.
- `POST /v1/components/{slug}/{type}/{name}/{version}/{deprecate|yank} {reason}`. Auth: valid push token for `{slug}`. Refuse to overwrite `status='taken_down'`.
- Indexer filters `yanked`/`taken_down` from search; surfaces `status` in download payloads for warning badges.
- Pinned downloads: `deprecated`/`yanked` allowed (reproducibility); `taken_down` blocked.
- Non-pinned resolution: skip `yanked`/`taken_down`.

**Schema** (`000005_status_trio.up.sql`):
```sql
ALTER TABLE components
  ADD COLUMN status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','deprecated','yanked','taken_down')),
  ADD COLUMN status_reason TEXT,
  ADD COLUMN status_changed_at TIMESTAMPTZ;
CREATE INDEX idx_components_status ON components (status) WHERE status != 'active';
```

**Phase B checklist** (shipped 2026-04-20 — cyfr.run@eaacfea + 473ddd3; cyfr@c1304d3):
- [x] `000005_status_trio.up.sql` + `.down.sql` (renumbered to `000009_status_trio` in cyfr.run since Phase A hardening consumed through 000008).
- [x] Deprecate + yank handlers in `internal/api/components.go`.
- [x] `internal/search/*.go` + `internal/indexer/process.go` — filter + surface status.
- [x] Download path: block `taken_down`; allow pinned `deprecated`/`yanked`; skip non-pinned.
- [x] codex: `cyfr component deprecate <ref> --reason "..."`, `cyfr component yank <ref>`.
- [x] cyfr Shell: deprecation/yank UI on component detail page.

**Done when:** publisher deprecates a version (search shows warning, downloads work); yanks a version (search omits, pinned downloads work, unpinned picks different); cannot downgrade `taken_down`.

---

### Phase C — Admin moderation + abuse reports [SHIPPED]

Simpler than earlier draft — no identity model to suspend. Token revocation IS namespace-level takedown.

**What ships:**
- `abuse_reports` table — categories (`impersonation`, `malware`, `dmca`, `spam`, `other`), lifecycle (`open` → `resolved` | `dismissed`).
- Admin endpoints: `POST /v1/admin/components/{...}/takedown`, `POST /v1/admin/namespaces/{slug}/revoke-all-tokens`, `POST /v1/admin/abuse-reports/{id}/resolve`.
- Public: `POST /v1/abuse-reports` (authenticated — user must hold ANY valid push token; bootstraps abuse reporting without a global login system).
- Admin auth: single opaque `ADMIN_TOKEN` env var seeded at deploy time; checked on all `/v1/admin/*`. No user/role model on cyfr.run. Rotating = swap env var and redeploy.
- Admin UI in cyfr Shell: `PrismWeb.AdminLive` authenticates via operator's cyfr session, then uses `ADMIN_TOKEN` stored in operator's CredentialStore for `/v1/admin/*` calls.
- Audit: structured logs (`log.Info("moderation.action", actor=cyfr_admin, target=..., reason=...)`).

**Schema** (`000006_moderation.up.sql`):
```sql
CREATE TABLE abuse_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category TEXT NOT NULL CHECK (category IN ('impersonation','malware','dmca','spam','other')),
  target_namespace TEXT REFERENCES namespaces(slug) ON DELETE SET NULL,
  target_component_id UUID REFERENCES components(id) ON DELETE SET NULL,
  details TEXT NOT NULL,
  reporter_created_via TEXT,                       -- "github|https://github.com|12345678" from reporter's token
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','dismissed')),
  resolution TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ
);
CREATE INDEX idx_abuse_reports_open ON abuse_reports (created_at) WHERE status = 'open';
```

**Phase C checklist** (shipped 2026-04-20 — cyfr.run@42de075; cyfr@e629346):
- [x] `000006_moderation.up.sql` + `.down.sql` (renumbered to `000010_moderation` in cyfr.run).
- [x] `internal/moderation/` package NEW.
- [x] `POST /v1/abuse-reports` intake — auth: any valid push token.
- [x] `internal/api/admin.go` NEW — `ADMIN_TOKEN` middleware; takedown/revoke/resolve handlers.
- [x] `ADMIN_TOKEN` env var added to `internal/config/config.go` + `.env.example`.
- [x] `apps/cyfr/lib/prism_web/live/admin_live.ex` NEW.
- [x] codex: `cyfr report <ref> --category impersonation --details "..."`.

**Done when:** user reports impersonation → admin resolves with takedown → component removed from search/downloads; all tokens for offending namespace revoked; audit log emitted; report `resolved`. Re-publishing under the taken-down namespace blocked (mark `namespaces.reserved=true`).

---

### Phase D — Arx ↔ cyfr identity overrides (Arx-only) [D.1 SHIPPED, D.2a SHIPPED]

> **Arx Shell UI + integration tests** are tracked in `docs/Arx_Roadmap.md` §2.1e.1 (blocks on Arx 2.1d/2.1e) — out of scope for this document.

**Premise**: Arx replaces the cyfr-side identity provider with OIDC; everything else (CredentialStore, push tokens, namespace claims against cyfr.run) stays the same. Zero new cyfr.run endpoints. `Sanctum.User.id` format is the **same** `"<provider>|<iss>|<subject>"` shape as Core — only the `<provider>` value differs (`"oidcc|..."` when Arx admin configures enterprise OIDC; `"github|..."` or `"google|..."` when Arx admin configures GitHub/Google as the IdP — same as Core in that case).

**Scope**: Phase D exists only to handle **Lane 2** from §Arx-readiness — Arx users on enterprise OIDC who can't hit cyfr.run directly with their OIDC token. Lane 1 users (Arx-on-GitHub/Google) need **no Phase D changes at all** — their id is `"github|https://github.com|12345678"` (same as Core), their GitHub access_token works directly against cyfr.run, no `identity_links` row needed.

**What ships (two deliverables):**

### D.1 — Self-hosted cyfr.run OIDC verifier (for air-gapped / strict-compliance Arx)

Self-hosted cyfr.run gains a 3rd provider `internal/providers/oidc.go` that validates enterprise OIDC id_tokens **locally** (no github.com / google.com round-trip). Admin configures per deployment:
- `OIDC_ISSUER_URL` — must start with `https://` (**hard requirement** — prevents collision with Core's hardcoded `https://github.com` / `https://accounts.google.com` issuer values).
- `OIDC_JWKS_URL` (or `OIDC_JWKS` static JSON).
- `OIDC_AUDIENCE` — expected `aud` claim.

Probe endpoint accepts `provider="oidcc"` + `id_token=<jwt>` (not access_token — id_tokens verify locally via JWKS). cyfr.run rejects id_tokens whose `iss` claim doesn't start with `https://`. User.id ends up as `"oidcc|<verified_iss>|<sub>"`, matching the format Lane 2 uses cyfr-side.

Public cyfr.run apex does NOT enable this verifier (rejected at config-time unless `CYFR_EDITION=arx`).

Air-gapped Arx: admin configures only the OIDC verifier; GitHub + Google verifiers can be disabled via `CYFR_DISABLE_PROVIDERS=github,google`.

### D.2 — `identity_links` for Lane 2 hybrid deployments (Arx enterprise OIDC + public cyfr.run apex)

For Arx deployments that point at the public cyfr.run (not self-hosted), `identity_links` maps Arx tenant users to a linked GitHub/Google identity for cyfr.run namespace claims:
  ```sql
  CREATE TABLE identity_links (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT NOT NULL,                          -- "oidcc|<real_iss>|<subject>" (Arx enterprise OIDC)
    provider TEXT NOT NULL,                         -- 'github' | 'google' (the linked identity)
    provider_subject TEXT NOT NULL,
    access_token_ciphertext BYTEA,                  -- for multi-device re-verify flow
    linked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, provider)
  );
  CREATE INDEX ON identity_links (user_id);
  ```
- `SanctumArx.IdentityLinks` module — sibling to `SanctumArx.Memberships`.

**Phase D checklist:**
- [x] `internal/providers/oidc.go` NEW (cyfr.run, Arx self-hosted only) — JWKS fetch + local id_token verification; `iss` allowlist enforces `https://` prefix; rejects any `iss` matching `https://github.com` / `https://accounts.google.com` (reserved for Core hardcoded values). (**D.1 shipped 2026-04-20** — cyfr.run@d7d2628; 14 unit tests in `oidc_test.go`.)
- [x] `internal/config/config.go` — add `OIDC_ISSUER_URL`, `OIDC_JWKS_URL`, `OIDC_AUDIENCE`, `CYFR_DISABLE_PROVIDERS` config; guard OIDC verifier construction on `EDITION=arx`. (**D.1 shipped 2026-04-20** — cyfr.run@d7d2628.)
- [x] `apps/cyfr/priv/repo/migrations/*_create_identity_links.exs` NEW (Arx-only). (**D.2a shipped 2026-04-20** — migration `20260420000002_create_identity_links.exs`; cyfr@92c887f.)
- [x] `apps/cyfr/lib/sanctum_arx/identity_links.ex` NEW. (**D.2a shipped 2026-04-20** — plus `SanctumArx.IdentityLink` schema + 12-case unit test file; cyfr@92c887f.)

**Done when:** storage layer for identity links is in place; cyfr.run can verify enterprise OIDC id_tokens when self-hosted. End-to-end Arx-tenant namespace-claim flow + integration tests live in `docs/Arx_Roadmap.md` §2.1e.1.

---

## 4. Arx compliance contract — MUST / MUST NOT clauses

Each clause is numbered and references the §1 invariant it enforces. An Arx deployment that violates any clause regresses auth; a pre-deploy audit MUST verify each clause. Applies after every phase, not just Phase A.

1. **Edition swap point is `:cyfr, :auth_provider` only** — upholds §1.3. Arx pin at `config/arx_runtime.exs:17` auto-selects `SanctumArx.Auth.OIDC`. No module outside `SanctumArx.Auth.*` MUST branch on `:cyfr, :edition` for auth decisions. Infrastructure gates (policy ceilings, tenant scoping, registry URL pinning, Arx UI presence) reading `:edition` are orthogonal and unaffected. SimpleOAuth's additive Google support (Phase A) stays Core-only: Arx pin ⇒ SimpleOAuth never runs in Arx.

2. **`Sanctum.Auth` behaviour contract is stable** — upholds §1.3. `authenticate/1` and `current_user/1` signatures MUST NOT change; both `Sanctum.Auth.SimpleOAuth` and `SanctumArx.Auth.OIDC` continue to satisfy them after Phase A.

3. **`Sanctum.User.id` format is identical across editions** — upholds §1.4. Format MUST be `"<provider>|<iss>|<subject>"` on both Core and Arx. Edition MUST NOT appear in the id. Tenant scoping lives in `Sanctum.Context.org_id` / `SanctumArx.Memberships`, never in `.id`.

4. **Lane 1 strategy choice (Arx-on-GitHub/Google)** — upholds §1.4 + §1.7. Lane 1 Arx deployments MUST use `ueberauth_github` / `ueberauth_google` as the Ueberauth strategy in `config/arx_runtime.exs`. MUST NOT wire `ueberauth_oidcc` against `https://github.com` or `https://accounts.google.com` issuers. Rationale: `SanctumArx.Auth.OIDC.authenticate/1` reads `auth.provider` verbatim; strategy choice at config time determines `id` shape. Mis-wiring yields `id = "oidcc|..."` on Arx while Core produces `"github|https://github.com|..."` — same human, different id, breaks §1.4. The existing Google wiring at `config/arx_runtime.exs:117-121` already uses the direct strategy; preserve that pattern. Phase D's self-hosted-OIDC verifier on cyfr.run additionally MUST reject admin-configured OIDC issuers matching `https://github.com` / `https://accounts.google.com` (reserved for Core).

5. **Lane 2 enterprise OIDC does not hit cyfr.run directly** — upholds §1.4. Lane 2 Arx deployments (Okta, Azure AD, generic `ueberauth_oidcc` against real enterprise issuers) produce `id = "oidcc|<real_iss>|<subject>"`. cyfr.run MUST NOT attempt to verify such tokens (no JWKS trust for arbitrary issuers). Lane 2 users MUST separately link a GitHub or Google identity via Phase D `identity_links`; the linked identity's access_token enables namespace claim.

6. **CredentialStore key format is opaque in `user_id`** — upholds §1.2 + §1.4. Key `_registry.{registry}.{user_id}.{namespace_slug}`. `user_id` is an arbitrary string; the unified `"<provider>|<iss>|<subject>"` format slots in without parser changes.

7. **Arx tenant-cred path preserved and simplified** — upholds §1.2. `Compendium.Registry.Identity.resolve_tenant_credentials/2` keeps single-cred semantics; post-Phase-A, `Arca.SecretStorage` returns `%{token, namespace}` (push token) instead of `%{username, password}`. `Compendium.OCI.Auth.fetch_credential/3` `:push_token` branch covers per-user AND tenant-scoped. Multi-namespace Arx tenant creds = Phase D problem.

8. **Registry URL is edition-configurable** — upholds §1.6. `:cyfr, :registry_url` + `:oci_registry_url` envs let Arx override both (apex, co-host, split topology). cyfr.run schema is edition-agnostic; zero schema change for Arx.

9. **`identity_links` is Arx-side only** — upholds §1.3. Phase D's `identity_links` table lives in cyfr's Arx migration; cyfr.run-side schema unchanged. Core installs never see this table.

10. **DeviceFlow is Core-only** — upholds §1.3. Arx uses enterprise web OIDC; Arx CLI auth explicitly out of Phase A scope. `SimpleOAuth` (Core) and `DeviceFlow` (Core) MUST NOT reach into `SanctumArx.*`. Pre-merge: `rg "Memberships\." apps/cyfr/lib/sanctum/auth/` → 0 (also upholds §1.1).

11. **cyfr.run `namespace_members` ≠ `SanctumArx.Memberships`** — upholds §1.2. The cyfr.run-side table is a registry concept (membership-of-publisher-namespace); `SanctumArx.Memberships` is a cyfr-side tenant concept (org/project scoping). Arx self-hosted registry uses the same `namespace_members` schema as Core; no interaction between the two membership concepts.

12. **Accepted cross-layer coupling is bounded** — upholds §1.5. Only `Sanctum.Auth.DeviceFlow.poll_for_session/2` and `EmissaryWeb.AuthController.callback/2` MAY call `Compendium.CyfrRun.Client.probe_identity/3` + `Compendium.Registry.CredentialStore.put/4` after `Session.create/1`. No other edges from `apps/cyfr/lib/sanctum/auth/*` OR `apps/cyfr/lib/sanctum/mcp.ex` into Compendium. Component-aware Sanctum modules (`policy.ex`, `policy_store.ex`, `oauth.ex`, `tincture_access.ex`) keep their Compendium deps — outside the auth sliver, outside this contract. Pre-merge: `rg "Compendium\." apps/cyfr/lib/sanctum/auth/` → only `device_flow.ex` (`:124`); `rg "Compendium\." apps/cyfr/lib/sanctum/mcp.ex` → 0 (both `:445` whoami edge and `:560` registry-login edge gone).

**Acceptance bar (pre-deploy assertion).** Upholds §1.4 + §1.7. Claim `alice` on Core via GitHub → `Sanctum.User.id = "github|https://github.com|12345678"`. Spin up a fresh Arx instance with Lane 1 GitHub IdP. Same GitHub account signs in on Arx → `Sanctum.User.id` MUST be the **bit-identical** string `"github|https://github.com|12345678"`. A mismatch = deployment violates clause 3, 4, or both. Automate this check in Arx deploy CI.

---

## Resolved decisions

Decisions captured by §1 invariants (ownership split, id format, swap point, accepted coupling, single-registry scope, Lane 1 hard requirement) are not restated here. Only decisions not already captured as invariants:

- **No cyfr.run `users`/`identities` tables.** Namespace ownership anchored to `(claimed_provider, claimed_provider_subject)` columns on `namespaces`. Multi-device recognition works without a users table.
- **Three-shape namespace model (personal / publisher / reserved)** — syntactic distinction resolves squatting + parser ambiguity. Enforced by the `CHECK` constraint in §3's schema.
- **One personal namespace per user, immutable, claimed at first login.** Partial unique index `namespaces (claimed_provider, claimed_provider_subject) WHERE kind = 'personal'` + app-layer pre-check. Claim is **mandatory** — dashboard gated until it succeeds. No "defer claim" path.
- **Publisher namespaces have members (the "org" concept).** First DNS-claimer becomes admin; admin adds by target's personal-namespace slug (`alice`). Sole-admin protection. Member removal atomically revokes that user's tokens for the namespace.
- **Opaque push tokens as the push capability.** SHA-256 hash stored; no JWT, no refresh, no expiry on use. 365-day inactivity reaper with "keep most-recent-per-namespace" guard. Revocation is explicit + next-request-effective. Users legitimately hold multiple tokens (one personal + one per publisher membership).
- **Multi-device without token copying.** `POST /v1/identity/probe` verifies userinfo and returns fresh tokens for personal + all memberships; cyfr invokes automatically after every login.
- **Multi-session native + multi-user native.** `Arca.SessionStorage` already supports multi-row per `user_id`; each user on a shared BEAM node gets separate CredentialStore entries.
- **Core = one project per instance.** `project_id: "default"` / `org_id: ""` defaults (note the `Context.local/0` vs `SessionStorage` asymmetry in §2.2; Phase A normalizes or documents). Arx populates both via OIDC claims.
- **API-key project scoping vs push-token user+namespace scoping are orthogonal.** API keys: `(scope_type, org_id, project_id)` (Phase A completes the half-landed migration — see §2.2). Push tokens: `(user_id, namespace_slug)` via CredentialStore. The two scoping concerns never interact.
- **Reject signups with missing/unverified email** from both GitHub and Google — simplifies the data model and prevents unverified-email identity fragmentation.
- **No `auto-join-by-domain`** — DELETED entirely. Only DNS-verified publisher-token issuance + explicit multi-device-token issuance are trust paths.
- **DNS re-verification** — daily cron, exponential backoff (1d → 7d cap), 3 permanent-failure flip, 90-day `verified_at` hard-expire. Transient failures (SERVFAIL, timeout, connect error) don't increment the strike counter.
- **SSRF-guarded outbound HTTP** in its own `internal/httpclient/` package — shared by `internal/providers/` (userinfo) and `internal/dnsverify/` (HTTPS probes).
- **Rate limiting (post-refactor).** Three buckets: `/v1/namespaces/*` + `/v1/identity/probe` at 20/min burst 5 (shared, new); `/v1/components` at 60/min burst 10 (unchanged); `/v2/*` at 600/min burst 50 (unchanged). `/v1/auth/*` dropped. `/v1/admin/*` (Phase C) shares the namespaces bucket. In-process single-node only; multi-instance scaling needs shared-counter infra.
- **`WWW-Authenticate: Basic realm=...` on every 401 from `/v2/*`.** Required for Docker/OCI retry-with-credentials. Also fixes today's latent Docker-compat gap.
- **CSRF immune by construction** on cyfr.run (all writes are Bearer/Basic-token auth; no session cookies). On cyfr (web claim-namespace flow), `:protect_from_forgery` is required in the `:browser` pipeline.
- **Config consolidation.** Two knobs: `:cyfr, :registry_url` (REST) + optional `:cyfr, :oci_registry_url` (OCI; default `"registry.#{registry_url}"`). Deletes `:registry` keyword list, `:cyfr_run_api_url`, `:registry_token_url`. Supports apex / Arx co-host / Arx split topologies.
- **Core edition pin.** `validate_registry_url!/0` + `validate_oci_registry_url!/0` pin Core to `cyfr.run` / `registry.cyfr.run`. Arx overrides via env.
- **Naming cleanup.** Phase A resolves the `resolve_credentials` collision with a single rename: `OCI.Auth.resolve_credentials/2` → `fetch_credential/3` (four external callers per §2.2). `Identity.resolve_credentials/1` stays as a private helper. No alias.
- **Identity-level audit log** via `slog.InfoContext` with `audit.*` prefix on cyfr.run. Synchronous emission (not via async indexer, which drops events on queue timeout). Events: `audit.namespace.*`, `audit.token.*`, `audit.push.*`, `audit.member.*`, `audit.identity.probe`.
- **Cookie hardening.** Add `secure: config_env() == :prod` to both endpoints. Pin `same_site: "Lax"` (Strict breaks OAuth callbacks from github.com / google.com).
- **Admin auth on cyfr.run (Phase C).** Single `ADMIN_TOKEN` env var. No admin user model, no DB re-check. Rotate = swap env var + redeploy.
- **`needs_personal_namespace` computed at runtime, not stored.** `RequirePersonalNamespace` plug → ETS 30s-TTL cache → `CredentialStore.list_for_user/2`. Self-healing across multi-session; no `Arca.SessionStorage` schema change. `/live/*` NOT bypassed (see §3); 30s TTL self-heal used instead of pub/sub invalidation.
- **No Phase E.** Publisher-OIDC / BYO-IdP deferred indefinitely. Arx handles enterprise SSO internally.

---

## Deferred

- **New-device probe email notification** — surfacing "new device signed in" to the user's email on fresh `/v1/identity/probe` from an unseen `label`. Requires email infrastructure on cyfr.run (SMTP / transactional provider); out of scope for Phase A/B/C (not shipped in C despite earlier pre-deploy note). Revisit when the email channel warrants.

- **Cross-provider account linking on cyfr.run** — if/when needed, add:
  ```sql
  CREATE TABLE namespace_providers (
    namespace_slug TEXT NOT NULL REFERENCES namespaces(slug) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    provider_subject TEXT NOT NULL,
    linked_via TEXT NOT NULL,         -- "github|https://github.com|12345678" that authorized the link
    linked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (namespace_slug, provider, provider_subject)
  );
  ```
  Strictly additive; backfill from today's `namespaces.claimed_provider` + `claimed_provider_subject`. Multi-device flow then checks this table instead of the two columns.

- **Cross-instance identity federation (hub-spoke)** — if we ever want "same user, same internal ID across multiple cyfr deployments" (e.g., Alice on self-hosted Arx and public cyfr.run are the same logical user), migrate with:
  1. Add `users (id UUID PRIMARY KEY, ...)` to cyfr.run.
  2. Add `identities (provider, provider_subject, user_id FK)` unique on `(provider, provider_subject)`.
  3. Backfill: one `users` + `identities` row per distinct `(claimed_provider, claimed_provider_subject)` across `namespaces` + `namespace_providers`.
  4. Add `namespaces.owner_user_id UUID REFERENCES users(id)`; backfill via join.
  5. Expose `POST /v1/auth/resolve` (access_token → `{user_id, namespaces}`).
  6. cyfr servers store `user_id` in local sessions for cross-instance correlation.
  Zero breaking changes to v1 push path. Don't build until asked.

- **Mnemonic / web3-style self-sovereign identity** — addable as an alternative claim-by-signature path (`POST /v1/namespaces/{slug}/claim-by-signature`). Doesn't break v1 opaque tokens. Requires designing: key generation UX, recovery, rotation.

- **Publisher team admin/member roles on tokens** — all tokens equal in v1. If Arx needs admin-only token issuance later, add `push_tokens.role TEXT` column.

- **Username renames** — disabled v1; lockfile rewrite tooling needed first.

- **Cryptographic component signing** — JWT + TLS sufficient for v1.

- **Per-identity 2FA** — inherit from upstream IdP.

- **Webhook subscriptions** on component events.

- **GitHub Actions workload identity (CI publishing)** — separate feature with its own scope/audience binding; not in Phase A.

- **Multiple email domains per publisher** — v1 has one domain per publisher (= the slug).

- **Subdomain publishers as separate namespaces** (`team.acme.com` distinct from `acme.com`) — works in v1 since each is DNS-verifiable; no admin tooling for the relationship.

- **Porta OS-keychain migration** — today's Porta stores credentials in plaintext JSON (`porta.json`/`prefs.json`). Push tokens raise blast radius of a file-system leak. Defer to a dedicated Porta security pass (`tauri-plugin-stronghold` or native macOS Keychain / Windows Credential Manager). Not a Phase A blocker — today's JWT lives in the same plaintext.

- **Integration test fixtures for whoami wire-shape** — pin Porta/codex consumer assertions against JSON fixtures to prevent silent drift as the shape evolves.

- **Per-entry push-token salt** — unified-key encryption (`Sanctum.Secrets`) is sufficient for Phase A. Per-entry KDF would require schema extension (`secrets.salt` column) and gives only marginal security improvement over type-discriminated single-key.

- **cyfr.run dedicated audit-log infrastructure** — Phase A uses `slog.InfoContext` with `audit.*` prefix. A proper audit sink with rotation, structured storage, and Prometheus integration is a separate hardening pass.

- **Membership-change notifications to target user** — when Bob adds Alice to a publisher, Alice's cyfr doesn't know until her next probe. Acceptable race in v1; webhook or push-notification path deferred.

- **Member-add by email or by provider subject** — v1 only supports add-by-personal-namespace-slug (`alice`). Requires target to have signed up + claimed personal namespace. Email-based add is trust-on-first-use (see the `autoJoinOrgsByDomain` privesc we're removing); subject-based add is power-user only. Defer.

- **`namespace_members.role = 'viewer'`** — v1 has `admin` + `member`. Viewer role (pull-only access for private-registry use cases) can layer on later without schema churn beyond the CHECK constraint.

- **Rename `OCI.Auth.fetch_credential/3` to remove namespace parameter** — if the CredentialStore API ever collapses back to single-cred-per-user (e.g., if the one-personal-namespace invariant tightens further), this can simplify. Not on the roadmap.

- **Re-adding non-cyfr.run OCI registry support** — if cyfr ever wants to pull/push to ghcr.io, Docker Hub, or generic OCI registries, the deleted `OCI.Auth` branches (token cache, realm-exchange, `:basic`/`:bearer`/`:oauth2_client`/`:key_pair` dispatch) would come back as a separate feature with its own credential type on CredentialStore. Not on roadmap.

---

## Reused existing primitives

- `Sanctum.Auth` behaviour (`sanctum/auth.ex`) — unchanged. `Sanctum.Auth.SimpleOAuth` (core) + `SanctumArx.Auth.OIDC` (arx) both continue to satisfy it.
- `Sanctum.Auth.DeviceFlow` — extended with Google provider clauses + first-login probe invocation. Best-effort `/auth/token` exchange removed; no cyfr.run JWT round-trip. Core-only.
- `config :cyfr, :auth_provider` dispatcher at `config/runtime.exs:298-338` — unchanged as a dispatcher; Google enabling condition added to its branch logic, but Arx swap mechanism untouched.
- `EmissaryWeb.AuthController` (Ueberauth) — callback extended to invoke `/v1/identity/probe` + route to claim-namespace gate when personal namespace absent.
- `Compendium.CyfrRun.Client` — existing REST client extended with claim/verify/token/member/probe endpoints and simplified whoami. Existing private `auth_headers/1` at `:219-236` is **modified** (emits Bearer push_token) — not a new function. Finch-based pool unchanged.
- `Compendium.OCI.Auth` — existing central credential resolver, collapsed to push-token-only (no cross-registry scope). `auth_headers/3` → `auth_headers/4` (two branches: `:push_token` Bearer + anonymous fallback). `resolve_credentials/2` → `fetch_credential/3` (rename + namespace arg). Token cache, realm-exchange, `resolve_any_credential/1`, and `:basic`/`:bearer`/`:oauth2_client`/`:key_pair` dispatch branches all DELETED.
- `Compendium.Registry.CredentialStore` — existing keyed-by-user_id store; full API cascade (key + `put`/`get`/`delete` signatures + new `list_for_user/2`). Same `Sanctum.Secrets` encryption; no dedicated push-token salt.
- `Sanctum.Crypto` (AES-256-GCM, PBKDF2) — already used for `oauth_credentials` + secrets; reused for push-token ciphertext with the existing keying (no per-type salt).
- `jose ~> 1.11` — still present at `apps/cyfr/mix.exs:41` but no longer used for JWT verification (no cyfr.run JWTs). Still used by `sanctum/context.ex:277` for Sanctum's own session/API-key crypto; keep.
- `internal/auth/auth.go::extractToken` on cyfr.run — preserved **as-is** to accept both `Bearer` and `Basic` schemes (Docker/OCI compat). Only the lookup logic that follows changes.
- cyfr.run DNS TXT challenge handler — extracted into `internal/dnsverify/` + cron; SSRF guard in `internal/httpclient/`.
- `Sanctum.ComponentRef` — rewrite (not just extend): three-shape validation replaces the single dot-free regex; classifier dispatcher internal; struct unchanged.
- `SanctumArx.Memberships` — Phase D template for `SanctumArx.IdentityLinks`. Orthogonal to cyfr.run-side `namespace_members`.

---

## File map

**cyfr.run (Go):**

| Phase | File | Change |
|---|---|---|
| A | `/Users/moonmoon/Projects/cyfr.run/` HEAD `58af29d` | **SHIPPED 2026-04-18.** Migrations 000004–000008 (000007/000008 are Phase A post-ship hardening); new `internal/api/{namespaces,members,identity_probe}.go` + `internal/store/postgres/{namespaces,namespace_members,push_tokens}.go` + `internal/providers/{github,google}.go` + packages `internal/httpclient/` + `internal/dnsverify/` + `internal/tokenreaper/`; `cyfrctx.Context` shrunk to `{NamespaceSlug, TokenID, CreatedVia, RequestID}`; Bearer+Basic push-token auth with `WWW-Authenticate`; synchronous `audit.*` emission; rate-limit buckets wired; `deploy.sh wipe-db` shipped. Legacy `jwt.go / oidc.go / deviceflow.go / auth_handlers.go / auth_logout.go / orgs.go / namespace.go / verification.go / publishers.go` deleted; domain types `org.go / publisher.go / deviceflow.go / verification.go` deleted, `namespace.go / push_token.go / namespace_member.go` added. See §2.1 + cyfr.run git log `0fe1200..58af29d` for detail. **Phase A follow-up shipped 2026-04-20** — `GET /.well-known/cyfr-registry.json` handler registered at `router.go:87` (cyfr.run@718852a; tested in `wellknown_test.go`). |
| B | `migrations/000009_status_trio.up.sql` / `.down.sql` | NEW pair (**Phase B shipped 2026-04-20** — cyfr.run@eaacfea; renumbered because Phase A hardening consumed through 000008) |
| B | `internal/api/components.go` | Deprecate + yank handlers (**Phase B shipped 2026-04-20** — cyfr.run@473ddd3) |
| C | `migrations/000010_moderation.up.sql` / `.down.sql` | NEW pair (**Phase C shipped 2026-04-20** — cyfr.run@42de075) |
| C | `internal/api/admin.go` | NEW — `ADMIN_TOKEN` middleware + takedown/revoke/resolve handlers (**Phase C shipped 2026-04-20** — cyfr.run@42de075) |
| C | `internal/moderation/` | NEW package (**Phase C shipped 2026-04-20** — cyfr.run@42de075) |

**cyfr (Elixir):**

| Phase | File | Change |
|---|---|---|
| A | `apps/cyfr/lib/sanctum/user.ex:31-38, 54-61` | `from_oidc_claims/1` builds `id: "#{provider}\|#{claims["iss"]}\|#{claims["sub"]}"`; `local/0` keeps today's `id: "local_user"` sentinel unchanged. No `:provider_login` field, no `display_name/1` helper — UI renders `email \|\| id` (email always present post `email_verified` check) |
| A | `apps/cyfr/lib/sanctum/auth/simple_oauth.ex:43-48` | `%User{}` build formats `id: "#{provider}\|#{provider_iss(provider)}\|#{user_info.id}"` where `provider_iss/1` hardcodes `"https://github.com"` / `"https://accounts.google.com"` |
| A | `apps/cyfr/lib/sanctum/auth/device_flow.ex:330-339` | `%User{}` build in `create_session/2` same id format fix (hardcoded iss per provider) |
| A | `apps/cyfr/lib/sanctum_arx/auth/oidc.ex:72-80` | **NEW to this plan:** `%User{}` build uses `id: "#{provider}\|#{iss}\|#{auth.uid}"` where `iss` comes from `auth.info.urls[:oidc_issuer]` or `auth.extra.raw_info["id_token"]["iss"]` for `:oidcc`, and hardcoded per-provider for `:github`/`:google` (Lane 1 Arx). Arx uses same format as Core. API-key path at `:105-110` keeps `"api_key:<name>"` sentinel |
| A | `apps/cyfr/lib/compendium/cyfr_run/client.ex:219-236` | EXTEND — `probe_identity/3`, `claim_personal_namespace/4`, `claim_publisher_namespace/2`, `verify_publisher_namespace/1`, `issue_additional_token/3`, `revoke_token/3`, `add_member/4`, `update_member/4`, `remove_member/3`, `list_members/2`, `get_namespace/1`, `whoami/1`. **Modify existing `auth_headers/1`** (already exists) |
| A | `apps/cyfr/lib/compendium/oci/auth.ex` | **Collapse to push-token only** (no cross-registry): `resolve_credentials/2` → `fetch_credential/3` (rename + namespace arg); `auth_headers/3` → `auth_headers/4` with two branches (`:push_token` Bearer + anonymous fallback). **DELETE**: `:basic`/`:bearer`/`:oauth2_client`/`:key_pair` dispatch branches, `resolve_any_credential/1` (:275-280), `get_cached_token/2` + `cache_token/4` (:145-161), `handle_challenge/4` + `exchange_token/4` (:167-227) |
| A | `apps/cyfr/lib/compendium/registry/credential_store.ex` | **Full API cascade**: key `_registry.{registry}.{user_id}.{namespace_slug}`; `put/3→put/4`, `get/2→get/3`, `delete/2→delete/3`; NEW `list_for_user/2`; **DELETE `get_for_registry/1`** entirely (two callers gone: identity.ex privacy leak + oci/auth.ex cross-registry fallback; single-registry scope means neither has a use case); stored value uniformly `%{type: :push_token, token, namespace, issued_at, label}`; NO dedicated salt; `@valid_keys` covers only push-token atoms (`:type, :token, :namespace, :issued_at, :label, :role, :push_token`) |
| A | `apps/cyfr/lib/sanctum/auth/simple_oauth.ex:27,36,170,176,186` | Add Google to `@supported_providers`, `provider_configured?/1`, config reader, `extract_user_info/1`; update docstring |
| A | `apps/cyfr/lib/sanctum/auth/device_flow.ex` | Parameterize endpoints (URLs at `:37-39`, scope at `:42`); add Google clauses at `:187, :227, :275, :345-348`; remove registry-JWT exchange at `:119-138`; drop `registry_token_url/0` (`:391-393`); **after `Session.create/1` in `poll_for_session/2` (function at `:106`; body at `:114-181`) invoke `probe_identity/3`** and augment MCP response with `needs_personal_namespace` + `suggested_username`; preserve existing MCP wire-shape fields |
| A | `apps/cyfr/lib/emissary_web/controllers/auth_controller.ex:66-110` | Extract `access_token = auth.credentials && auth.credentials.token` at top of `callback/2` BEFORE `authenticate_with_provider/1` (today's path never reads `auth.credentials.token`); invoke `probe_identity/3` post-`Session.create/1` with the extracted token; route to `/claim-namespace` gate if `personal_namespace: nil`; add `/claim-namespace` + submit routes |
| A | `apps/cyfr/lib/sanctum/component_ref.ex` | Full three-shape rewrite: replace `@namespace_regex` with three regex/validators + `classify_namespace/1`; rewrite `validate_namespace/1` (`:448-468`); `parse_ns_name/1` at `:398-417` last-`:`/last-`.` split; audit callers for semantics change (`"foo"` → invalid); update doctests `:440-444, 477-478, 492-493` |
| A | `apps/cyfr/lib/sanctum/mcp.ex:131-190, 511, 576, 178-182, 438-447` | **MCP tool relocation + whoami split:** DELETE `registry-login` action + fields from session tool; DELETE handler at `:511`; update error message at `:576`; update `provider` enum at `:178-182` to `["github", "google"]`; `session.whoami` at `:438-447` returns local user only (`user_id, email, provider, display_name`) — DROP the `registry` sub-object; registry identity moves to `Compendium.MCP.registry.whoami` |
| A | `apps/cyfr/lib/compendium/mcp.ex` | ADD new `registry` tool (probe + claim-* + verify-publisher + tokens-* + members-* + whoami returning `{authenticated, personal_namespace, memberships}`); replace `publisher_name` in response shapes with `namespace_slug`; simplify `default_registry/0` (`:1381-1389`) to read `:oci_registry_url`; replace `"registry.cyfr.run"` at `:512` with derived host |
| A | `apps/cyfr/lib/emissary/mcp/tool_visibility.ex:45` | Replace `"session.registry-login" => :admin` with `"registry.*" => :user` |
| A | `apps/cyfr/lib/compendium/oci/client.ex:1032-1050` | DELETE `resolve_publisher_name/2`, `decode_jwt_publisher/1` |
| A | `apps/cyfr/lib/compendium/oci/client.ex` (push helpers) | Retry-on-401 → `get_namespace/1` → bubble `{:error, :token_revoked}`; no refresh |
| A | `apps/cyfr/lib/compendium/registry/identity.ex` | **Keep** `resolve_credentials/1` (`:88-96`) as private helper — collision with OCI.Auth dissolves once that renames; rewrite `do_whoami/2` (`:35-77`) Basic→Bearer; target `/v1/namespaces/{slug}` per-token via `CredentialStore.list_for_user/2`; drop `publisher_name` read at `:59`; new return shape (`personal_namespace` + `memberships`) feeds new `Compendium.MCP.registry.whoami` action; `registry_url/0` at `:79-84` reads `:oci_registry_url`; keep Arx tenant path intact |
| A | `apps/cyfr/lib/compendium/application.ex:7-78` | DELETE `validate_registry_credentials!/0`; DELETE `validate_api_url!/0`; simplify `validate_registry_url!/0`; ADD `validate_oci_registry_url!/0`; update orchestrator at `:7-11`; keep Core-edition pin |
| A | `apps/cyfr/lib/compendium/edition.ex:9` | Derive `@cyfr_run_registry` from `:oci_registry_url` |
| A | `apps/cyfr/lib/emissary/mcp/tools/system_provider.ex:378-381` | Bare-string read of `:oci_registry_url` |
| A | `apps/cyfr/lib/emissary_web/plugs/mcp_session.ex:500-511` | Verify `project_id` flows through `Context.build` (depends on `api_key.ex` fix) |
| A | `apps/cyfr/lib/prism_web/live/components_live.ex:965, 1194, 1378` | Render `namespace_slug` in place of `publisher_name` |
| A | `apps/cyfr/lib/prism_web/{components/layouts/app.html.heex:91, auth_helpers.ex, live/settings_live.ex, live/shell_compat.ex}` | Render `@current_user.email \|\| @current_user.id` directly; use a local `String.split("\|", parts: 3)` helper for the rare id-only fallback to pretty-print `@<provider>:<subject>`. No `display_name/1` helper needed. |
| A | `apps/cyfr/lib/sanctum/api_key.ex` | **Project scoping cascade:** thread `project_id(ctx)` through `:188, :205, :218, :232, :239, :250, :318`; add `defp project_id(ctx)` (mirror `:542`); `:345-356` `build_key_metadata/2` adds `project_id: row[:project_id]`; `:300-310` `validate_key/1` accepts `project_id` opt |
| A | `apps/cyfr/lib/arca/api_key_storage.ex` | **Project scoping cascade:** 8 sites (`:48, :68, :100, :141, :183, :222, :260, :285`) — function signatures gain `project_id` arg, queries filter by `(scope_type, org_id, project_id)` |
| A | `apps/cyfr/priv/repo/migrations/*_add_project_id_to_api_keys.exs` | NEW — `ADD COLUMN project_id TEXT NOT NULL DEFAULT 'default'`; drop existing unique index; recreate as `(name, scope_type, org_id, project_id)` |
| A | `apps/cyfr/lib/emissary_web/endpoint.ex:20-21`, `prism_web/endpoint.ex:13-14` | **Latent fix:** add `secure: config_env() == :prod`; pin `same_site: "Lax"` |
| A | `config/runtime.exs` | DELETE `:cyfr, :registry` block at `:213-249`; DELETE `:cyfr_run_api_url` at `:383-385`; ADD `:registry_url` + `:oci_registry_url`; ADD Google OAuth block post-`:211`; ADD `google_configured?` at `:300-302` + update dispatcher; ADD google Ueberauth provider post-`:344`; ADD `:push_token` to `:filter_parameters`; keep `:jwt_signing_key` block |
| A | `config/arx_runtime.exs:17, 80-85, 117-121, 123-129` | Keep `:auth_provider` pin; keep Ueberauth providers and Google wiring; DELETE `:registry` block at `:123-129`; ADD `:registry_url` + `:oci_registry_url` env mappings |
| A | `apps/cyfr/priv/repo/migrations/*_rekey_credential_store_and_indexes.exs` | CREATE INDEX ON sessions (user_id); TRUNCATE sessions; DELETE FROM secrets LIKE '_registry.%'; TRUNCATE api_keys |
| A | `apps/cyfr/test/compendium/oci/client_test.exs:335-402` | UPDATE (not delete): these are the `describe "startup validation"` tests of `Compendium.Application.validate_registry_config!/0` using `"ghcr.io"` as the non-cyfr.run example for Core rejection + Arx acceptance. Update to the new two-knob config (`:registry_url` + `:oci_registry_url`) and renamed validators. |
| A | `apps/cyfr/test/sanctum/component_ref_test.exs` | EXTEND three-shape + IDN/trailing-dot coverage; update `validate_namespace/1` doctest expectations |
| C | `apps/cyfr/lib/prism_web/live/admin_live.ex` | NEW (**Phase C shipped 2026-04-20** — cyfr@e629346) |
| D | `apps/cyfr/priv/repo/migrations/*_create_identity_links.exs` | NEW (Arx-only) (**D.2a shipped 2026-04-20** — `20260420000002_create_identity_links.exs`; cyfr@92c887f) |
| D | `apps/cyfr/lib/sanctum_arx/identity_links.ex` | NEW (Arx-only) (**D.2a shipped 2026-04-20** — plus `SanctumArx.IdentityLink` schema + unit tests; cyfr@92c887f) |

**Files explicitly NOT created (differ from earlier drafts):**
- `apps/cyfr/lib/sanctum/plugs/verify_jwt.ex` — no JWTs to verify
- `apps/cyfr/lib/sanctum/auth/jwks_cache.ex` — no JWKS
- Per-identity refresh mutex — no refresh tokens
- `apps/cyfr/lib/sanctum/plugs/` directory — not needed

**codex (Go, at `apps/codex/`):**

codex does no auth itself; all auth commands delegate to cyfr's MCP `session` and `registry` tools.

| Phase | Target | Description |
|---|---|---|
| A | `cmd/login.go:23, :36, :61` | Docstring update (`:23`); drop hardcoded `"provider": "github"` at **both** `:36` and `:61`; add `--provider` flag (github\|google, default github); handle `needs_personal_namespace: true` response by prompting for slug + invoking `registry.claim-personal` (mandatory before login considered complete) |
| A | `internal/ref/ref.go:70-73, 92-105` | Delete `@`→`:` replace; `strings.Index` → `strings.LastIndex` for both `:` and `.`; three-shape regex |
| A | `internal/ref/ref_test.go:107-108` | Invert broken test; add three-shape coverage (including reject cases: `c:@alice.foo:0.1.0` — `@` banned; `alice` — no name) |
| A | `cmd/tincture.go:32,38,65,70` | Route positional arg through `ref.ParseRef`; reject bare names |
| A | `cmd/component.go:87, :151` | Drop `publisher_name` fallback in search-result rendering at **both** sites |
| A | `cmd/component.go:505-512` | DELETE the `registry-login` MCP call block (interactive username/password prompt → `session` tool `registry-login` action). Push auth moves to push_token; credential bootstrap is automatic via `cyfr login` → probe → CredentialStore.put/4 |
| A | `cmd/registry.go` (or `cmd/registry/` subpackage) | NEW — `publisher claim/verify`, `tokens list/issue/revoke`, `members list/add/update/remove/promote/demote`, `probe`, `whoami`. Naming chosen to avoid collision with existing `cmd/register.go` (component registration) |
| B | `cyfr component {deprecate,yank} <ref>` | NEW |
| C | `cyfr report <ref>` | NEW |

**Porta (Tauri, at `apps/porta/`):**

| Phase | Target | Description |
|---|---|---|
| A | `src-ui/src/state/auth-store.ts:34-40` | **Whoami split:** call BOTH `session.whoami` (local: `user_id, email, provider, display_name`) AND `registry.whoami` (registry: `authenticated, personal_namespace, memberships`); merge in state. Drop `registry?.email` + `registry?.publisher_name` reads |
| A | `src-ui/src/state/auth-store.ts:106-142` | Device-poll consumer — handle new `needs_personal_namespace` + `suggested_username` fields when status=complete; route to claim-namespace gate |
| A | `src-ui/src/api/cyfr-mcp.ts:25-27` | Docstring + return type for new whoami |
| A | NEW claim-namespace gate | React component + route — prompts user for personal-namespace slug, calls `registry.claim-personal`, re-prompts on `slug_taken`, blocks UI until claim succeeds |
| A | `src-ui/src/config/labels.ts` | Drop `publisher_name` label mapping |
| A | `src/preflight.rs:109` + `src/commands/cyfr.rs:319-388` | Expected-shape checks for new whoami: calls BOTH `session.whoami` (top-level `user_id`) and `registry.whoami` (top-level `authenticated`); update assertions and Rust MCP fallback path to reflect two-action composition |

---

## Open-core split

Per `project_open_core.md`: three-shape namespace authority, DNS domain verification, opaque-token issuance + revocation, deprecation/yank, and abuse moderation are all FOSS — they belong to public registry hygiene. Arx-only: `identity_links` table + `SanctumArx.IdentityLinks` module + Arx Shell UI for identity linking and tenant-scoped namespace management. Arx-only code paths are gated behind `SanctumArx.Edition.arx?/0`.
