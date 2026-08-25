# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Storage do
  @moduledoc """
  Behaviour for storage adapters.

  All paths are lists of segments, e.g. `["builds", "build_1.json"]`.
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
    `seed/aqua` the AQUA template; `seed_roots/0` is the table). Read in
    place from local disk (each root's config key), reachable only by
    system contexts, never stored through an adapter.
  - **Global paths**: `cache`, `system` → stored at root level
  - **Tenant-scoped paths**: everything else → stored verbatim under the
    context's athanor (see `tenant_segments/1`). Naming another athanor's
    tree is structurally impossible — there is no place in the path to put
    an athanor; platform code opens an athanor the way it does for rows,
    with a context focused on it. The scopes in use: `components/`
    (`Compendium.ComponentPath`), `aqua/`, `builds/`, `config/`,
    `conversations/`, and `guest/` — the WASM guest's `data/` scope, given
    its physical name by `Opus.StorageHandler` at the guest boundary so a
    `data/` grant can never see a host scope.

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
          ├── builds/                    # Locus build lifecycle
          ├── config/                    # Athanor config (retention settings, etc.)
          ├── conversations/             # chat attachment blobs
          └── guest/                     # guest (WASM) files — the guest's `data/` scope

  The seed media every athanor is provisioned from is not stored state —
  each root is read in place from its configured directory
  (`seed_roots/0`): the component bundle from `:bundle_path` (the repo
  checkout, or the baked image copy in Docker) and the AQUA template from
  `:aqua_template_path` (the repo's `aqua/`, or the operator-editable
  `/app/aqua` mount).

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
      Arca.put(ctx, ["builds", "build_1.json"], json_content)

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

  # Seed media: install media read in place from local disk, never tenant
  # state and never adapter-stored. Each logical root maps to the config key
  # holding its physical path. One table, so a new kind of seed media is a
  # new entry — not a new special case in every gate.
  @seed_roots %{
    "components" => :bundle_path,
    "aqua" => :aqua_template_path
  }

  @doc """
  The seed-media roots: logical `["seed", root | rest]` prefixes and the
  config key each one's physical path lives under. `Arca` pins them to the
  Local adapter, `authorize_path/2` admits only system contexts, and
  `Arca.Adapters.Local.build_path/2` routes them to their configured
  directories — outside the storage root.
  """
  @spec seed_roots() :: %{String.t() => atom()}
  def seed_roots, do: @seed_roots

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
    case segments do
      ["seed" | _] ->
        raise ArgumentError,
              "seed media is not tenant storage; Arca routes it to its configured root"

      [prefix | _] = segs ->
        if prefix in @global_prefixes,
          do: segs,
          else: ["athanors" | tenant_segments(ctx)] ++ segs

      [] ->
        ["athanors" | tenant_segments(ctx)]
    end
  end

  @doc """
  Whether `ctx` may touch `path` at all.

  Every tenant path — components and data alike — takes its athanor from
  the context, so there is nothing cross-tenant to refuse here: a context
  physically cannot name another athanor's tree. What remains reserved is
  the server's own: the seed media `seed/…` (system contexts only — `Arca`
  reads each root in place from its configured directory) and the global
  roots `cache/` (OCI blobs) and `system/` (health probes). `Arca` runs
  this before dispatching to any adapter.
  """
  @spec authorize_path(Context.t(), [String.t()]) :: :ok | {:error, :forbidden}
  def authorize_path(%Context{auth_method: :system}, ["seed" | _]), do: :ok
  def authorize_path(%Context{}, ["seed" | _]), do: {:error, :forbidden}

  def authorize_path(%Context{auth_method: :system}, [root | _]) when root in ["cache", "system"],
    do: :ok

  def authorize_path(%Context{}, [root | _]) when root in ["cache", "system"],
    do: {:error, :forbidden}

  def authorize_path(%Context{}, _path), do: :ok

  @doc """
  Validate that path segments contain no traversal attacks.

  Delegates to `Cyfr.PathSafety.validate_segments!/1` (the canonical
  denylist, shared with the Opus storage policy boundary).
  Must be called by all adapter implementations before building paths.

  ## Examples

      iex> Arca.Storage.validate_path!(["builds", "build_1.json"])
      :ok

      iex> Arca.Storage.validate_path!(["builds", "..", "..", "etc", "passwd"])
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
