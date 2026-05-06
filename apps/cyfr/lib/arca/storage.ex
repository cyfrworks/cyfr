defmodule Arca.Storage do
  @moduledoc """
  Behaviour for storage adapters.

  All paths are lists of segments, e.g. `["builds", "build_1", "started.json"]`.
  The adapter handles joining to the actual storage location.

  ## Single seam policy

  All file/blob/cache I/O in CYFR flows through this behaviour. Adding a new
  `File.*` / `Path.wildcard` call elsewhere in `apps/cyfr/lib`, `apps/opus/lib`,
  `apps/locus/lib`, or `apps/arx/lib` is a regression — it means the same code
  no longer behaves identically on Local FS (Core) and S3 (Arx).

  CI greps for direct filesystem calls and fails on any not tagged with one of
  the four acceptable bypass groups below. To intentionally bypass, mark the
  call with a comment like `# arca:bypass-ok=B` (matching the group letter).

  | Group | When | Why bypass is OK | Examples |
  |-------|------|------------------|----------|
  | A | Inside the adapter itself | The adapter IS the layer that translates segments to bytes. | `Arca.Adapters.Local`, `Arx.Adapters.S3` |
  | B | Pre-Arca bootstrap | Code runs before `Arca.Repo` / config is up; chicken-and-egg. | `Cyfr.Application.ensure_db_directory!`, `verify_db_writable!` |
  | C | Compile-time embedded resources | Module attribute `@external_resource` — not runtime I/O. | `@sdk_source`, `@component_guide`, `@wit_files_*` |
  | D | Local-only sandbox / OS toolchain / user-import boundary | Tar extraction tmp dirs, cargo build sandbox, user-supplied filesystem paths during publish. After validation, content rejoins Arca. | `Compendium.Registry.extract_and_store_tincture`, `Locus.Builder`, `register_from_directory` |

  Any code that doesn't fit one of these groups must use `Arca` (which dispatches
  to the configured adapter via `Application.get_env(:cyfr, :storage_adapter, ...)`).

  ## Path Scoping

  Paths are automatically scoped based on the first segment:

  - **Component paths**: `["components" | rest]` → routed to `components_path`
  - **AQUA paths**: `["aqua" | rest]` → routed to `aqua_path`
  - **Global paths**: `cache` → stored at root level
  - **Tenant-scoped paths**: everything else → stored under
    `{org_or_namespace}/{project_id}/{namespace}/...` (see `tenant_segments/1`)

  Core edition fills the org slot with the namespace and the project slot
  with `"default"`, so a single-user instance lives at
  `data/{namespace}/default/{namespace}/...`. Arx fills the slots with the
  real `org_id`/`project_id` minted by the tenant policy.

  This enables:
  - Components to live in a single `components/` directory (no duplication)
  - Services to store tenant-scoped data with org/project/namespace isolation

  ## Storage Structure

      components/                        # Component artifacts (separate root)
      └── {type}s/{publisher}/{name}/{version}/

      aqua/                              # AQUA agent prompts/manifest (separate root)

      data/
      ├── {env}.db                       # SQLite database (all structured data)
      ├── cache/                         # Global: immutable cached artifacts
      │   └── oci/{digest}/
      └── {org_or_namespace}/            # Tenant-scoped
          └── {project_id}/              #   Core: "default"; Arx: real project id
              └── {namespace}/           #   personal slug minted via cyfr.run
                  ├── builds/            # Locus build lifecycle
                  ├── data/              # User data (agent conversations, etc.)
                  ├── config/            # User config (retention settings, etc.)
                  └── audit/             # Audit events (append-only JSONL, opt-in)

  ## Structured Logs (SQLite only)

  MCP request logs, execution records, and policy consultation logs are stored
  exclusively in SQLite tables (`mcp_logs`, `executions`, `policy_logs`).
  They are NOT written to disk files.

  ## Implementations

  - `Arca.Adapters.Local` - Filesystem storage (Core)
  - `Arx.Adapters.S3` - S3-compatible storage, lives in `apps/arx/` (Arx only)

  > #### Deployment isolation {: .warning}
  >
  > **Core and Arx must not share a storage root.** Use separate filesystem
  > paths (`base_path` config) or separate S3 buckets/prefixes. Core writes
  > to `data/{namespace}/default/{namespace}/...` (substituting namespace
  > for `org_id`), so a Core instance with namespace `"acme"` and an Arx
  > instance with org_id `"acme"` would collide if pointed at the same root.
  > Single-deployment-per-edition is the assumed topology.

  ## Tenancy and the namespace segment

  Tenant-scoped paths use the 3-tuple `{org_or_namespace, project_id, namespace}`
  built by `tenant_segments/1`. Multi-tenant deployments (Arx) share one storage
  root (filesystem path or S3 bucket prefix) across orgs; isolation comes from
  the org/project/namespace tuple. Single-user deployments (Core) substitute
  the user's namespace for the missing `org_id` and use `"default"` for
  `project_id`, so the same path-construction logic works on both editions.

  `Sanctum.Context.user_id` (e.g. `"github|https://github.com|123"`,
  `"oidcc|<iss>|<sub>"`, `"webhook:<slug>"`) is still the globally unique
  identity, but it is *not* a path primitive — only `org_id`, `project_id`,
  and `namespace` shape the on-disk layout.

  ## Usage

  Services use the main `Arca` module which dispatches to the configured adapter:

      ctx = Sanctum.TestContext.local()

      # Tenant-scoped (auto-prefixed with {org_or_ns}/{project}/{namespace}/)
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
  `{org_or_namespace}/{project_id}/{namespace}/` tenant tuple that
  `tenant_segments/1` builds for everything else.

  - `cache` — global cache (OCI blobs, etc.) under `data/cache/`
  - `aqua` — AQUA agent prompts and manifest, routed to `:cyfr, :aqua_path`
  """
  @global_prefixes ["cache", "aqua"]

  def global_prefixes, do: @global_prefixes

  @doc """
  Build the 3-segment tenant tuple `[org_or_namespace, project_id, namespace]`
  used by Local + S3 adapters for user-scoped paths.

  Layout:
  - Arx: `{real_org_id}/{real_project_id}/{namespace}/...` — multi-tenant scope.
  - Core: `{namespace}/default/{namespace}/...` — `org_id` is nil so we
    substitute the namespace; `project_id` defaults to "default".

  Raises if `ctx.namespace` is unset — this is the storage layer's
  invariant. System contexts that legitimately don't write user-scoped
  data should use `scope: :platform` and avoid calling this.
  """
  @spec tenant_segments(Context.t()) :: [String.t()]
  def tenant_segments(%Context{} = ctx) do
    ns = ctx.namespace

    unless is_binary(ns) and ns != "" do
      raise ArgumentError,
            "Arca.Storage.tenant_segments/1 requires Context.namespace to be set " <>
              "(user_id=#{inspect(ctx.user_id)} scope=#{inspect(ctx.scope)} " <>
              "auth_method=#{inspect(ctx.auth_method)}). " <>
              "If this is a system/scheduled context that needs to write " <>
              "user-scoped data, supply :namespace explicitly or use the " <>
              "\"_system\" sentinel."
    end

    # Core: ctx.org_id is nil/"" → substitute namespace. Either form occurs
    # in practice (CredentialStore can hand back "" for unset values), and
    # `Path.join/1` silently drops empty segments — which would resolve to
    # `data/default/<ns>/...` instead of `data/<ns>/default/<ns>/...` and
    # silently miss every file written under the correct path.
    # Arx: ctx.org_id is the real org id (validated by Arx.Sanctum.TenantPolicy).
    org = if ctx.org_id in [nil, ""], do: ns, else: ctx.org_id
    proj = if ctx.project_id in [nil, ""], do: "default", else: ctx.project_id
    segments = [org, proj, ns]

    # Defense-in-depth: namespace/org/project are minted by trusted authorities
    # (cyfr.run validates slug regex; tenant policy validates org/project ids),
    # but a corrupted CredentialStore entry or a future code path that bypasses
    # those validations could inject `..` or null bytes. Run the same path-
    # traversal check we apply to user-supplied segments.
    validate_path!(segments)

    segments
  end

  @doc """
  Validate that path segments contain no traversal attacks.

  Rejects any segment containing `..` to prevent directory traversal.
  Must be called by all adapter implementations before building paths.

  ## Examples

      iex> Arca.Storage.validate_path!(["builds", "build_1", "started.json"])
      :ok

      iex> Arca.Storage.validate_path!(["builds", "..", "..", "etc", "passwd"])
      ** (ArgumentError) Path traversal rejected: segment \"..\" is not allowed

  """
  def validate_path!(segments) when is_list(segments) do
    Enum.each(segments, fn segment ->
      cond do
        segment == ".." ->
          raise ArgumentError, "Path traversal rejected: segment \"..\" is not allowed"

        String.contains?(segment, <<0>>) ->
          raise ArgumentError, "Path traversal rejected: null bytes are not allowed"

        fully_decode(segment) =~ ~r/(^|[\/\\])\.\.($|[\/\\])/ ->
          raise ArgumentError, "Path traversal rejected: encoded \"..\" is not allowed"

        true ->
          :ok
      end
    end)

    :ok
  end

  # Decode URI-encoded segments until output stabilizes, catching multi-layer encoding.
  defp fully_decode(segment) do
    decoded = URI.decode(segment)
    if decoded == segment, do: segment, else: fully_decode(decoded)
  end

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
