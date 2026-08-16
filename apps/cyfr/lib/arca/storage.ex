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
    The athanor lives *inside* the segment list — `Compendium.ComponentPath`
    builds `components/{athanor_id}/{type}s/...` — so component paths are not
    run through `tenant_segments/1` (which is for the `data/` root). Adapters
    pin them: a context may only reach `components/{its own athanor}/...`
    (a platform context reaches every athanor), and the seed bundle
    `components/_bundle/...` is readable only by system contexts.
  - **AQUA paths**: `["aqua" | rest]` → routed to `aqua_path`
  - **Global paths**: `cache`, `system` → stored at root level
  - **Tenant-scoped paths**: everything else → stored under
    `{athanor_id}/...` (see `tenant_segments/1`)

  `namespace` is a user-identity field and is NOT part of the path.

  This enables:
  - Components to be isolated per athanor under the `components/` root,
    matching the `data/` tenant layout (publishing in one athanor never
    overwrites another's blobs); a new athanor is given the bundled baseline
    by `Compendium.AthanorSeeder`
  - Services to store data isolated per athanor (the tenant boundary);
    members of an athanor share its storage

  ## Storage Structure

      components/                        # Component artifacts (separate root)
      ├── _bundle/{type}s/local/{name}/{version}/   # the seed source, never a tenant
      └── {athanor_id}/{type}s/{publisher}/{name}/{version}/

      aqua/                              # AQUA agent prompts/manifest (separate root)

      data/
      ├── {env}.db                       # SQLite database (all structured data)
      ├── cache/                         # Global: immutable cached artifacts
      │   └── oci/{digest}/
      ├── system/                        # Global: server-internal scratch (health probe)
      └── {athanor_id}/                  # Tenant-scoped
          ├── builds/                    # Locus build lifecycle
          ├── data/                      # Athanor data (agent conversations, etc.)
          ├── config/                    # Athanor config (retention settings, etc.)
          └── audit/                     # Audit events (append-only JSONL, opt-in)

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
  > buckets/prefixes. Single-deployment-per-root is the assumed topology.

  ## Tenancy

  Tenant-scoped paths use the athanor id built by `tenant_segments/1`.
  Every athanor on a server shares one storage root (filesystem path or
  object-store bucket prefix); isolation comes from the athanor segment.

  `Sanctum.Context.user_id` (e.g. `"github|https://github.com|123"`,
  `"oidcc|<iss>|<sub>"`, `"webhook:<slug>"`) and `namespace` are identity
  fields (attribution, display, tincture tokens) — they are *not* path
  primitives. Only `athanor_id` shapes the on-disk layout, so members of an
  athanor share its storage.

  ## Usage

  Services use the main `Arca` module which dispatches to the configured adapter:

      ctx = Sanctum.TestContext.local()

      # Tenant-scoped (auto-prefixed with {athanor_id}/)
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
  `{athanor_id}/` prefix that `tenant_segments/1` builds for everything
  else.

  - `cache` — global cache (OCI blobs, etc.) under `data/cache/`
  - `system` — server-internal scratch (the storage health probe) under
    `data/system/`
  - `aqua` — AQUA agent prompts and manifest, routed to `:cyfr, :aqua_path`
  """
  @global_prefixes ["cache", "system", "aqua"]

  def global_prefixes, do: @global_prefixes

  @doc """
  Build the tenant segment list `[athanor_id]` used by every storage adapter
  for tenant-scoped paths.

  Layout: `{athanor_id}/...`. A resolved `athanor_id` is required; a context
  without one raises (fail closed) — naming a directory is a separate concern
  from tenant-access control (where `:platform` legitimately bypasses): a
  platform or system task must still carry the athanor whose files it
  touches. `namespace` is a pure identity field and is NOT part of the path.
  """
  @spec tenant_segments(Context.t()) :: [String.t()]
  def tenant_segments(%Context{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    segments = [athanor_id]

    # Defense-in-depth: athanor ids are minted by trusted code, but a
    # corrupted row or a future code path that bypasses those validations
    # could inject `..` or null bytes. Run the same path-traversal check we
    # apply to user-supplied segments.
    validate_path!(segments)

    segments
  end

  def tenant_segments(%Context{} = ctx) do
    raise ArgumentError,
          "Arca.Storage.tenant_segments/1: a resolved athanor_id is required " <>
            "(user_id=#{inspect(ctx.user_id)} scope=#{inspect(ctx.scope)} " <>
            "auth_method=#{inspect(ctx.auth_method)})"
  end

  @doc """
  Whether `ctx` may touch `path` at all.

  The `components/` root is shared by every athanor, so its second segment
  is the tenant: a context reaches only `components/{its own athanor}/…`
  (a platform context reaches every athanor), a bare `components` listing
  is platform-only, and the seed bundle `components/_bundle/…` is readable
  only by server-internal contexts (`auth_method: :system`). Every other
  path is either global or tenant-prefixed by `tenant_segments/1` and needs
  no check here. `Arca` runs this before dispatching to any adapter.
  """
  @spec authorize_path(Context.t(), [String.t()]) :: :ok | {:error, :forbidden}
  def authorize_path(%Context{auth_method: :system}, ["components", "_bundle" | _]), do: :ok
  def authorize_path(%Context{}, ["components", "_bundle" | _]), do: {:error, :forbidden}
  def authorize_path(%Context{scope: :platform}, ["components" | _]), do: :ok

  def authorize_path(%Context{athanor_id: athanor_id}, ["components", athanor_id | _])
      when is_binary(athanor_id) and athanor_id != "",
      do: :ok

  def authorize_path(%Context{}, ["components" | _]), do: {:error, :forbidden}
  def authorize_path(%Context{}, _path), do: :ok

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
