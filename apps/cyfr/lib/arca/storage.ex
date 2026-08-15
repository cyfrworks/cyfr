# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Storage do
  @moduledoc """
  Behaviour for storage adapters.

  All paths are lists of segments, e.g. `["builds", "build_1", "started.json"]`.
  The adapter handles joining to the actual storage location.

  ## Single seam policy

  All file/blob/cache I/O in CYFR flows through this behaviour. Adding a new
  `File.*` / `Path.wildcard` call elsewhere in `apps/cyfr/lib`, `apps/opus/lib`,
  or `apps/locus/lib` is a regression — it means the same code no longer
  behaves identically on the local filesystem and on a configured object-store
  adapter.

  Known divergence: `append/3` + `get/2` do not round-trip identically. Local
  appends into one file that `get/2` returns whole; S3 writes an immutable
  child object per append under the path-as-prefix, and `get/2` on that path
  returns `{:error, :not_found}` (enumerate via `list/2` instead). The only
  append caller today is the audit log, which never reads back through
  `get/2` — a future append-then-get caller must go through `list/2`.

  The `arca-seam` CI job (`.github/workflows/test.yml`) greps for direct
  filesystem calls and fails when a file makes one without carrying an
  `# arca:bypass-ok=<group>` tag. To intentionally bypass, mark the call with a
  comment like `# arca:bypass-ok=B` (matching the group letter).

  | Group | When | Why bypass is OK | Examples |
  |-------|------|------------------|----------|
  | A | Inside the adapter itself | The adapter IS the layer that translates segments to bytes. | `Arca.Adapters.Local`, any configured object-store adapter |
  | B | Pre-Arca bootstrap | Code runs before `Arca.Repo` / config is up; chicken-and-egg. | `Cyfr.Application.ensure_db_directory!`, `verify_db_writable!` |
  | C | Compile-time embedded resources | Module attribute `@external_resource` — not runtime I/O. | `@sdk_source`, `@component_guide`, `@wit_files_*` |
  | D | Local-only sandbox / OS toolchain / user-import boundary | Tar extraction tmp dirs, cargo build sandbox, user-supplied filesystem paths during publish. After validation, content rejoins Arca. | `Compendium.Registry.extract_and_store_tincture`, `Locus.Builder`, `register_from_directory` |

  Any code that doesn't fit one of these groups must use `Arca` (which dispatches
  to the configured adapter via `Application.get_env(:cyfr, :storage_adapter, ...)`).

  ## Path Scoping

  Paths are automatically scoped based on the first segment:

  - **Component paths**: `["components" | rest]` → routed to `components_path`.
    The tenant lives *inside* the segment list — `Compendium.ComponentPath`
    builds `components/{org}/{project}/{type}s/...` — so component paths are
    not run through `tenant_segments/1` (which is for the `data/` root).
  - **AQUA paths**: `["aqua" | rest]` → routed to `aqua_path`
  - **Global paths**: `cache` → stored at root level
  - **Tenant-scoped paths**: everything else → stored under
    `{org}/{project_id}/...` (see `tenant_segments/1`)

  A single-user instance uses the seeded `"local"` org and `"default"`
  project, so it lives at `data/local/default/...`. A tenant-scoped
  deployment fills the slots with the real `org_id`/`project_id` minted by
  the configured tenant policy. `namespace` is a user-identity field and is
  NOT part of the path.

  This enables:
  - Components to be isolated by org/project under the `components/` root,
    matching the `data/` tenant layout (publishing in one project never
    overwrites another's blobs); new projects are given a baseline via
    `Compendium.ProjectSeeder`
  - Services to store data isolated by org/project (the tenant boundary);
    members of a project share its storage

  ## Storage Structure

      components/                        # Component artifacts (separate root)
      └── {org}/{project}/{type}s/{publisher}/{name}/{version}/

      aqua/                              # AQUA agent prompts/manifest (separate root)

      data/
      ├── {env}.db                       # SQLite database (all structured data)
      ├── cache/                         # Global: immutable cached artifacts
      │   └── oci/{digest}/
      └── {org}/                         # Tenant-scoped (single-user: "local")
          └── {project_id}/              #   single-user: "default"; tenant-scoped: real project id
              ├── builds/                # Locus build lifecycle
              ├── data/                  # Project data (agent conversations, etc.)
              ├── config/                # Project config (retention settings, etc.)
              └── audit/                 # Audit events (append-only JSONL, opt-in)

  ## Structured Logs (database only)

  MCP request logs, execution records, and policy consultation logs are stored
  exclusively in database tables (`mcp_logs`, `executions`, `policy_logs`).
  They are NOT written to disk files.

  ## Implementations

  - `Arca.Adapters.Local` - filesystem storage (the default)
  - a configured object-store adapter - S3-compatible storage, selected via
    `config :cyfr, :storage_adapter`

  > #### Deployment isolation {: .warning}
  >
  > **Two deployments must not share a storage root.** Use separate
  > filesystem paths (`base_path` config) or separate object-store
  > buckets/prefixes. A single-user deployment writes to
  > `data/local/default/...`, so two such deployments pointed at the same
  > root would collide. Single-deployment-per-root is the assumed topology.

  ## Tenancy

  Tenant-scoped paths use the 2-tuple `{org, project_id}` built by
  `tenant_segments/1`. Deployments with multiple tenants share one storage
  root (filesystem path or object-store bucket prefix); isolation comes from
  the org/project tuple. Single-user deployments use the seeded `"local"` org
  and `"default"` project.

  `Sanctum.Context.user_id` (e.g. `"github|https://github.com|123"`,
  `"oidcc|<iss>|<sub>"`, `"webhook:<slug>"`) and `namespace` are identity
  fields (attribution, display, tincture tokens) — they are *not* path
  primitives. Only `org_id` and `project_id` shape the on-disk layout, so
  members of a project share its storage.

  ## Usage

  Services use the main `Arca` module which dispatches to the configured adapter:

      ctx = Sanctum.TestContext.local()

      # Tenant-scoped (auto-prefixed with {org}/{project}/)
      Arca.put(ctx, ["builds", "build_1", "started.json"], json_content)

      # Global (no tenant prefix)
      Arca.put(ctx, ["cache", "oci", "sha256_abc"], wasm_binary)

  """

  alias Sanctum.Context

  @type path :: [String.t()]
  @type error :: {:error, :not_found | :permission_denied | term()}

  @doc """
  Global path prefixes that are NOT tenant-scoped.

  These paths are stored at the root level — they bypass the
  `{org}/{project_id}/` tenant tuple that `tenant_segments/1` builds for
  everything else.

  - `cache` — global cache (OCI blobs, etc.) under `data/cache/`
  - `aqua` — AQUA agent prompts and manifest, routed to `:cyfr, :aqua_path`
  """
  @global_prefixes ["cache", "aqua"]

  def global_prefixes, do: @global_prefixes

  @doc """
  Build the 2-segment tenant tuple `[org, project_id]` used by every storage
  adapter for tenant-scoped paths.

  Layout: `{org}/{project_id}/...`. A single-user instance uses the seeded
  `"local"` org and `"default"` project (`data/local/default/...`).

  A resolved `org_id` is required; an org-less context raises (fail closed).
  `namespace` is a pure identity field and is NOT part of the path.
  """
  @spec tenant_segments(Context.t()) :: [String.t()]
  def tenant_segments(%Context{} = ctx) do
    segments = [path_org(ctx), Arca.QueryHelpers.normalize_project_id(ctx.project_id)]

    # Defense-in-depth: org/project are minted by trusted authorities (tenant
    # policy validates the ids), but a corrupted entry or a future code path
    # that bypasses those validations could inject `..` or null bytes. Run the
    # same path-traversal check we apply to user-supplied segments.
    validate_path!(segments)

    segments
  end

  # The org names the tenant directory. The seeded single-user sentinel "local"
  # is concrete (→ data/local/...); a real org is used as-is. nil/"" means a
  # caller bypassed the Sanctum.Context.require_tenant! chokepoint — fail closed.
  # Naming a directory is a separate concern from tenant-access control (where
  # :platform legitimately bypasses): a platform/system task must still carry a
  # concrete org to write files. `internal/1` supplies "local", so system tasks
  # resolve to data/local/default and never raise here.
  defp path_org(%Context{org_id: org}) when is_binary(org) and org != "", do: org

  defp path_org(%Context{} = ctx) do
    raise ArgumentError,
          "Arca.Storage.tenant_segments/1: a resolved org_id is required " <>
            "(user_id=#{inspect(ctx.user_id)} scope=#{inspect(ctx.scope)} " <>
            "auth_method=#{inspect(ctx.auth_method)})"
  end

  @doc """
  Validate that path segments contain no traversal attacks.

  Delegates to `Cyfr.PathSafety.validate_segments!/1` (the canonical
  denylist, shared with the Opus storage policy boundary).
  Must be called by all adapter implementations before building paths.

  ## Examples

      iex> Arca.Storage.validate_path!(["builds", "build_1", "started.json"])
      :ok

      iex> Arca.Storage.validate_path!(["builds", "..", "..", "etc", "passwd"])
      ** (ArgumentError) Path traversal rejected: segment \"..\" is not allowed

  """
  defdelegate validate_path!(segments), to: Cyfr.PathSafety, as: :validate_segments!

  @doc "Read content from storage"
  @callback get(Context.t(), path()) :: {:ok, binary()} | error()

  @doc "Write content to storage (overwrites existing)"
  @callback put(Context.t(), path(), binary()) :: :ok | error()

  @doc "Append content to storage (for append-only logs like audit/*.jsonl)"
  @callback append(Context.t(), path(), binary()) :: :ok | error()

  @doc "Delete content from storage"
  @callback delete(Context.t(), path()) :: :ok | error()

  @doc "List contents at path prefix"
  @callback list(Context.t(), path()) :: {:ok, [String.t()]} | error()

  @doc "Check if path exists"
  @callback exists?(Context.t(), path()) :: boolean()

  @doc "Recursively delete a directory tree at path"
  @callback delete_tree(Context.t(), path()) :: :ok | error()

  @doc """
  Recursively list all leaf paths under a prefix.

  Returns a list of full segment lists (not relative paths) so callers can
  pass them straight to `get/2` without reassembly. Order is unspecified.
  Implementations must call `validate_path!/1` on the input prefix.
  """
  @callback list_recursive(Context.t(), path()) :: {:ok, [path()]} | error()

  @doc """
  Recursive file count and byte total under a prefix.

  Quota enforcement reads this — it must reflect every leaf in the subtree,
  not just the top level, or a nested write evades the ceiling.
  Implementations must call `validate_path!/1` on the input prefix.
  """
  @callback usage(Context.t(), path()) ::
              {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | error()

  @doc """
  Read a whole subtree as a list of `{relative_path, binary}` pairs.

  Convenience for callers (validators, scanners) that need every file in a
  subtree as bytes. Order unspecified. `relative_path` is the segment list
  relative to the input prefix.

  Memory-bounded: bytes are buffered in-memory. Use `serve_to_conn/4` for
  large single-file streaming.
  """
  @callback read_subtree(Context.t(), path()) ::
              {:ok, [{path(), binary()}]} | error()

  @doc """
  Stream a stored object to a `Plug.Conn`.

  The adapter chooses the streaming strategy. The caller still owns
  Content-Type, CSP, caching headers, and any body transformation
  (e.g. SDK injection done before serving the index HTML).

  Returns `{:ok, conn}` on success or `{:error, term()}` so callers can
  produce a proper error response on Local-vs-S3 differences. Implementations
  must call `validate_path!/1` on the input prefix.
  """
  @callback serve_to_conn(
              Plug.Conn.t(),
              Context.t(),
              path(),
              opts :: keyword()
            ) :: {:ok, Plug.Conn.t()} | {:error, term()}
end
