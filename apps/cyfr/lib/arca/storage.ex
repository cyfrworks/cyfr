# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Storage do
  @moduledoc """
  Behaviour for storage adapters.

  All paths are lists of segments, e.g. `["config", "retention.json"]`.
  The adapter handles joining to the actual storage location.

  ## Single seam policy

  All file/blob/cache I/O in CYFR flows through this behaviour. Adding a new
  `File.*` / `Path.wildcard` call elsewhere in `apps/cyfr/lib`, `apps/opus/lib`,
  or `apps/locus/lib` is a regression — it means the same code no longer
  behaves identically on the local filesystem and on a configured object-store
  adapter.

  The `arca-seam` CI job (`.github/workflows/test.yml`) greps for direct
  filesystem calls and fails when a file makes one without carrying an
  `# arca:bypass-ok=<group>` tag. To intentionally bypass, mark the call with a
  comment like `# arca:bypass-ok=B` (matching the group letter).

  | Group | When | Why bypass is OK | Examples |
  |-------|------|------------------|----------|
  | A | Inside the adapter itself | The adapter IS the layer that translates segments to bytes. | `Arca.Adapters.Local`, any configured object-store adapter |
  | B | Pre-Arca bootstrap | Code runs before `Arca.Repo` / config is up; chicken-and-egg. | `Cyfr.Application.ensure_db_directory!`, `verify_db_writable!` |
  | C | Compile-time embedded resources | Module attribute `@external_resource` — not runtime I/O. | `@sdk_source`, `@component_guide`, `@wit_files_*` |
  | D | Local-only sandbox / OS toolchain / user-import boundary | Tar extraction tmp dirs, cargo build sandbox, user-supplied filesystem paths during publish. After validation, content rejoins Arca. | `Compendium.Registry.extract_and_store_tincture`, `Locus.Builder` |

  Any code that doesn't fit one of these groups must use `Arca` (which dispatches
  to the configured adapter via `Application.get_env(:cyfr, :storage_adapter, ...)`).

  ## Path Scoping

  Every logical path is tenant-relative: the athanor always comes from the
  context, never from the segments. Scoping keys on the first segment:

  - **Seed media**: `["seed", root | rest]` — the install media every
    athanor is provisioned from (`seed/components` the bundle,
    `seed/aqua` the AQUA template; `seed_roots/0` is the roster). Read in
    place from the one seed tree (`:seed_path`), reachable only by
    system contexts, never stored through an adapter.
  - **Global paths**: `cache`, `system` → stored at root level
  - **Tenant-scoped paths**: the closed roster in `tenant_roots/0` →
    stored verbatim under the context's athanor (see `tenant_segments/1`).
    Naming another athanor's tree is structurally impossible — there is no
    place in the path to put an athanor; platform code opens an athanor
    the way it does for rows, with a context focused on it. The scopes:
    `components/` (`Compendium.ComponentPath`), `aqua/`, `config/`, `conversations/`, and `guest/` — the WASM guest's `data/`
    scope (`guest_scopes/0` is the map, applied by `Opus.StorageHandler`
    at the guest boundary) so a `data/` grant can never see a host scope.
  - **Anything else** → refused (`authorize_path/2`): an unknown first
    segment is never silently minted as a new subtree.

  `namespace` is a user-identity field and is NOT part of the path.

  `physical_segments/2` is the single translation from this logical
  vocabulary to the stored layout; every adapter joins its output under one
  storage root, so publishing in one athanor never overwrites another's
  blobs and members of an athanor share its storage. A new athanor is given
  the bundled baseline by `Compendium.AthanorSeeder`.

  ## Storage Structure

  One runtime root (`:base_path`, default `data/`; an object-store adapter
  mirrors the same key shape under its configured prefix):

      data/
      ├── cyfr.db                        # SQLite database (all structured data)
      ├── mcp-bridge/                    # the mcp-bridge sidecar's own files — inside the
      │                                  # root (compose mounts it), never an Arca path
      ├── cache/                         # Global: immutable cached artifacts
      │   └── oci/{digest}/
      ├── system/                        # Global: server-internal scratch (health probe)
      └── athanors/{athanor_id}/         # Tenant-scoped: everything the athanor owns
          ├── components/{type}s/{publisher}/{name}/{version}/
          ├── aqua/                      # the athanor's AQUA agent definitions
          ├── config/                    # Athanor config (retention settings, etc.)
          ├── conversations/             # chat attachment blobs
          └── guest/                     # guest (WASM) files — the guest's `data/` scope

  The seed media every athanor is provisioned from is not stored state —
  every root is read in place as a same-named subdirectory of the one seed
  tree (`:seed_path`, the repo's `seed/` on a checkout, `/app/seed` in
  Docker): the component bundle at `seed/components` (baked into the image)
  and the AQUA template at `seed/aqua` (the operator-editable mount).

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
      Arca.put(ctx, ["config", "retention.json"], json_content)

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

  AQUA agent definitions (`aqua/agent.json` and the prompts) are the
  athanor's own — an ordinary tenant path, seeded from the shipped template
  by `Compendium.AquaTemplate` when the athanor is provisioned.
  """
  @global_prefixes ["cache", "system"]

  def global_prefixes, do: @global_prefixes

  # The closed roster of tenant scopes. Every athanor tree holds exactly
  # these subtrees; an unknown first segment is refused, never silently
  # minted as a new subtree. A new kind of tenant state is a new entry here.
  @tenant_roots ~w(aqua components config conversations guest)

  @doc """
  The tenant scopes: the first segments a tenant-scoped path may start
  with, each a subtree of `athanors/{athanor_id}/`. `authorize_path/2`
  refuses everything outside this roster (and outside the seed/global
  vocabularies), so a typo'd or invented root is a typed refusal instead
  of a brand-new subtree.
  """
  @spec tenant_roots() :: [String.t()]
  def tenant_roots, do: @tenant_roots

  # The guest (WASM) storage vocabulary and the physical tenant scope each
  # guest scope stores under. The guest contract says `data/`; the host
  # stores that scope under `guest/`, a physical sibling of the host
  # scopes (aqua/, config/, conversations/, …) so a `data/` grant can
  # never see them.
  @guest_scopes %{"data" => "guest", "components" => "components"}

  @doc """
  The guest storage scopes: what a WASM guest may name in a path, mapped
  to the physical tenant scope each one stores under. `Opus.StorageHandler`
  applies this at the guest boundary (requests come in speaking `data/`,
  responses keep speaking it); keeping the map here means the layout —
  including the one vocabulary difference between guest and host — is
  written down in a single module.
  """
  @spec guest_scopes() :: %{String.t() => String.t()}
  def guest_scopes, do: @guest_scopes

  @doc """
  Classify a logical path by its first segment: `:seed` (install media),
  `:global` (`cache/`, `system/`), `:tenant` (the closed roster in
  `tenant_roots/0`, plus the empty path — the athanor's whole tree), or
  `:invalid` (everything else — refused at the `Arca` gate).

  The one classification `physical_segments/2`, `authorize_path/2` and
  `Arca`'s usage-cache invalidation all share.
  """
  @spec classify(path()) :: :seed | :global | :tenant | :invalid
  def classify(["seed" | _]), do: :seed
  def classify([root | _]) when root in @global_prefixes, do: :global
  def classify([root | _]) when root in @tenant_roots, do: :tenant
  def classify([]), do: :tenant
  def classify(_), do: :invalid

  # Seed media: install media read in place from local disk, never tenant
  # state and never adapter-stored. Every root is a subdirectory of the one
  # seed tree (`:seed_path`), named after its logical root. One roster, so a
  # new kind of seed media is a new entry — not a new special case in every
  # gate.
  @seed_roots ~w(components aqua)

  @doc """
  The seed-media roots: the logical `["seed", root | rest]` prefixes, each a
  same-named subdirectory of the one seed tree (`:seed_path`). `Arca` pins
  them to the Local adapter, `authorize_path/2` admits only system contexts,
  and `Arca.Adapters.Local.build_path/2` routes them under the seed tree —
  outside the storage root.
  """
  @spec seed_roots() :: [String.t()]
  def seed_roots, do: @seed_roots

  # The athanor-id grammar for storage: strictly alphanumeric plus `_`/`-`.
  # No dots at all — an id of `"."` would join to `athanors/.` and expand to
  # the ALL-athanors root; `".."`, slashes and percent-encodings are refused
  # by the same stroke. `Arca.Schemas.Athanor` enforces the same shape on
  # the row.
  @athanor_id_format ~r/^[A-Za-z0-9_-]+$/

  @doc "The athanor-id grammar shared with `Arca.Schemas.Athanor`."
  @spec athanor_id_format() :: Regex.t()
  def athanor_id_format, do: @athanor_id_format

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
    # Defense-in-depth: athanor ids are minted by trusted code, but a
    # corrupted row or a future code path that bypasses those validations
    # could inject `..`, `"."` or a slash — each of which would name a
    # directory outside the athanor's own tree.
    unless athanor_id =~ @athanor_id_format do
      raise ArgumentError,
            "invalid athanor_id for storage: #{inspect(athanor_id)} " <>
              "(must match #{inspect(@athanor_id_format)})"
    end

    [athanor_id]
  end

  def tenant_segments(%Context{} = ctx) do
    raise ArgumentError,
          "Arca.Storage.tenant_segments/1: a resolved athanor_id is required " <>
            "(user_id=#{inspect(ctx.user_id)} scope=#{inspect(ctx.scope)} " <>
            "auth_method=#{inspect(ctx.auth_method)})"
  end

  @doc """
  Map logical segments to the physical segments every adapter stores under
  its one root — the single place the stored layout is written down.

  Everything an athanor owns lives under `athanors/{athanor_id}/`, logical
  segments verbatim — and the athanor is always the context's, never named
  in the path. The empty path is the athanor's whole tree (the storage
  cap's one walk). Globals (`cache/`, `system/`) stay at the root. Seed
  media never reaches an adapter (`Arca` routes each root to its
  configured directory). There is no all-athanors location — roster-driven
  code enumerates athanor rows and works inside each one's context.
  """
  @spec physical_segments(Context.t(), path()) :: path()
  def physical_segments(ctx, segments) do
    case classify(segments) do
      :seed ->
        raise ArgumentError,
              "seed media is not tenant storage; Arca routes it to its configured root"

      :global ->
        segments

      :tenant ->
        ["athanors" | tenant_segments(ctx)] ++ segments

      :invalid ->
        raise ArgumentError,
              "unknown storage root #{inspect(hd(segments))}; " <>
                "tenant scopes are #{inspect(@tenant_roots)} (see Arca.Storage.tenant_roots/0)"
    end
  end

  @doc """
  Whether `ctx` may touch `path` at all.

  Every tenant path takes its athanor from the context, so there is
  nothing cross-tenant to refuse here: a context physically cannot name
  another athanor's tree. What this gate refuses is (a) the server's own
  reserved vocabularies for non-system contexts — the seed media `seed/…`
  (read in place from the seed tree) and the global roots `cache/` (OCI
  blobs) and `system/` (health probes) — and (b) any first segment outside
  the closed rosters, for everyone: an unknown root is a typo or an
  invented subtree, never storage. `Arca` runs this before dispatching to
  any adapter. Writability is a separate gate — seed media is read-only
  at the `Arca` facade whatever the context.
  """
  @spec authorize_path(Context.t(), [String.t()]) :: :ok | {:error, :forbidden}
  def authorize_path(%Context{} = ctx, path) do
    case classify(path) do
      :tenant -> :ok
      :invalid -> {:error, :forbidden}
      _seed_or_global -> if ctx.auth_method == :system, do: :ok, else: {:error, :forbidden}
    end
  end

  @doc """
  Validate that path segments contain no traversal attacks.

  Delegates to `Cyfr.PathSafety.validate_segments!/1` (the canonical
  denylist, shared with the Opus storage policy boundary).
  Must be called by all adapter implementations before building paths.

  ## Examples

      iex> Arca.Storage.validate_path!(["config", "retention.json"])
      :ok

      iex> Arca.Storage.validate_path!(["config", "..", "..", "etc", "passwd"])
      ** (ArgumentError) Path traversal rejected: segment \"..\" is not allowed

  """
  defdelegate validate_path!(segments), to: Cyfr.PathSafety, as: :validate_segments!

  @doc "Read content from storage"
  @callback get(Context.t(), path()) :: {:ok, binary()} | error()

  @doc "Write content to storage (overwrites existing)"
  @callback put(Context.t(), path(), binary()) :: :ok | error()

  @doc """
  Append content to storage, creating the path when it does not exist.

  `get/2` returns the whole object afterwards, on every adapter. An adapter
  with no atomic append implements this as a read-modify-write, where
  concurrent appends to one path are last-writer-wins and an oversized object
  is refused; the local filesystem's `O_APPEND` write has neither limit.
  """
  @callback append(Context.t(), path(), binary()) :: :ok | error()

  @doc "Delete content from storage"
  @callback delete(Context.t(), path()) :: :ok | error()

  @doc "List the names directly under a path prefix"
  @callback list(Context.t(), path()) :: {:ok, [String.t()]} | error()

  @doc """
  List the entries directly under a path prefix, each with its kind.

  The kind is the adapter's to know: on a filesystem it is a stat, on an
  object store it is whether the key has anything below it. A caller that
  needs to tell a directory from a file asks here rather than reaching for a
  particular adapter's path layout.

  A path that is itself a file answers `{:error, :enotdir}` on every adapter;
  a path with nothing under it answers `{:ok, []}`.
  """
  @callback list_typed(Context.t(), path()) ::
              {:ok, [{String.t(), :file | :dir}]} | error()

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
