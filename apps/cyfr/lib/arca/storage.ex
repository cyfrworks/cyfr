# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Storage do
  @moduledoc """
  Behaviour for storage adapters.

  All paths are lists of segments, e.g. `["guest", "notes.txt"]`.
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
    the way it does for rows, with a context focused on it. Each scope has
    exactly one spelling module for its intra-root shapes:
    `components/` → `Compendium.ComponentPath`; `aqua/` →
    `Compendium.AquaPath`; `conversations/` →
    `Arca.ConversationStorage.blob_root/1` (the conversation domain's one
    module owns both planes' spellings); `guest/` — the WASM guest's
    `data/` scope — has none by design (the guest names its own paths;
    `guest_scopes/0` is the map, applied by `Opus.StorageHandler` at the
    guest boundary, so a `data/` grant can never see a host scope). The
    global roots keep their literal at their single consumer, with a
    roster-membership witness in that consumer's test.
  - **Anything else** → refused (`authorize_path/2`): an unknown first
    segment is never silently minted as a new subtree.

  `namespace` is a user-identity field and is NOT part of the path.

  `physical_segments/2` is the single translation from this logical
  vocabulary to the stored layout; every adapter joins its output under one
  storage root, so publishing in one athanor never overwrites another's
  blobs and members of an athanor share its storage. A new athanor sees
  the bundled baseline through the seed overlay (`Arca.Overlay`) — no
  copy is made until it writes.

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
          ├── conversations/             # chat attachment blobs
          └── guest/                     # guest (WASM) files — the guest's `data/` scope

  Per-athanor settings (retention policy included) are rows — the
  `athanors.settings` document — never blobs; the tree holds only content.

  The seed media every athanor is provisioned from is not stored state —
  every root is read in place as a same-named subdirectory of the one seed
  tree (`:seed_path`, the repo's `seed/` on a checkout, `/app/seed` in
  Docker): the component bundle at `seed/components` (baked into the image)
  and the AQUA template at `seed/aqua` (the operator-editable mount).

  ## The volume vs. the seed tree

  Two trees, two lifetimes — the split is load-bearing, never merge them:

  - everything under `:base_path` is **mutable state**: volume-mounted,
    backed up, gitignored (CI asserts it), owned by athanors or the server.
  - everything under `:seed_path` is **install media**: git-tracked or
    image-baked, read in place, read-only at this facade and at every
    adapter. A new image ships a new bundle precisely because the volume
    does not hold it; the operator's AQUA overlay (`./aqua` →
    `/app/seed/aqua` in compose) is operator input, not athanor state.

  At-rest encryption of the volume or bucket is the operator's concern
  (disk/volume encryption, S3 default SSE) — the blob plane holds content
  only; secrets are always `Sanctum.Cipher`-sealed database rows and never
  become blobs.

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
      Arca.put(ctx, ["guest", "notes.txt"], content)

      # Global (no tenant prefix)
      Arca.put(ctx, ["cache", "oci", "sha256_abc"], wasm_binary)

  """

  alias Sanctum.Context

  @type path :: [String.t()]

  @typedoc """
  What an adapter callback answers besides success. Common reasons:
  `:not_found`; `:symlink_denied` (Local refuses links); `:enotdir`
  (listing a file); `:object_too_large` (S3's append past its ceiling);
  `{:s3_error, status}` and raw `File.posix()` atoms for transport and
  filesystem failures. A directory is not a readable object: `get/2` and
  `serve_to_conn/4` on one answer `:not_found` on every adapter. The
  facade adds its own vocabulary on top — see the Errors section in
  `Arca`'s moduledoc.
  """
  @type error ::
          {:error,
           :not_found
           | :symlink_denied
           | :enotdir
           | :object_too_large
           | {:s3_error, non_neg_integer()}
           | atom()
           | term()}

  # The one layout table: every root this layer knows, one row each —
  # `{root, class, guest-facing name, seed relationship}`. The rosters
  # below (`tenant_roots/0`, `global_prefixes/0`, `guest_scopes/0`,
  # `seed_roots/0`, `overlay_roots/0`, `reserved_roots/0`) are derived
  # views of this table, so a new kind of state is a new row — never a
  # fourth list to keep in step, and a typo cannot desynchronize one
  # roster from the others.
  #
  # - class: `:tenant` roots live under `athanors/{athanor_id}/`;
  #   `:tenant_reserved` roots live there too but only the server's own
  #   machinery may mutate them (`Arca.Overlay`'s internal-write scope or
  #   an `auth_method: :system` context — the `meta/` origin marks);
  #   `:global` roots stay at the storage root.
  # - guest name: what a WASM guest calls the root (`nil` = host-only,
  #   invisible at the guest boundary). `guest/` is the one renamed scope —
  #   the guest says `data/` — so a `data/` grant is a physical SIBLING of
  #   the host scopes, never their parent.
  # - seed: how the root relates to the seed tree (`seed/{root}`) — one
  #   model: `:overlay` is a read-through union with copy-on-write
  #   (`Arca.Overlay`): the athanor's tree shadows the seed tree per
  #   shadow unit, a write materializes the shadowed unit first, and a
  #   release only ever changes what an UNmaterialized unit reads through
  #   to, adding new units beside materialized ones — the unit granularity
  #   IS the upgrade granularity (aqua's file units upgrade per file,
  #   automatically; component version directories arrive additively).
  #   The unit shapes themselves are the domain's: each overlaid root
  #   names an `Arca.Storage.UnitLocator` in the `:overlay_locators`
  #   config (`Compendium.ComponentPath`, `Compendium.AquaPath`), and
  #   `locate/1` below is the one lookup. `nil` — no seed counterpart.
  #   A future overlaid root is one row here plus one locator module
  #   (and, if its media has validity rules, a provisioning seed-check).
  #
  # The volume holds more than Arca paths: `cyfr.db` (+ WAL/SHM) and the
  # `mcp-bridge/` sidecar state live inside `:base_path`, and Caddy keeps
  # its own named volumes — none of them are, or should become, rows here.
  # Arca addresses tenant and global blobs; everything else on the volume
  # is another program's file.
  @layout [
    {"aqua", :tenant, nil, :overlay},
    {"components", :tenant, "components", :overlay},
    {"conversations", :tenant, nil, nil},
    {"guest", :tenant, "data", nil},
    {"meta", :tenant_reserved, nil, nil},
    {"cache", :global, nil, nil},
    {"system", :global, nil, nil}
  ]

  @doc """
  The configured tenant adapter — the one spelling of the
  `:storage_adapter` read and its Local default, shared by the `Arca`
  facade and the `Arca.Overlay` decorator so the two can never disagree
  about the fallback.
  """
  @spec configured_adapter() :: module()
  def configured_adapter do
    Application.get_env(:cyfr, :storage_adapter, Arca.Adapters.Local)
  end

  @doc """
  Global path prefixes that are NOT tenant-scoped.

  These paths are stored at the root level — they bypass the
  `{athanor_id}/` prefix that `tenant_segments/1` builds for everything
  else.

  - `cache` — global cache (OCI blobs, etc.) under `data/cache/`
  - `system` — server-internal scratch (the storage health probe) under
    `data/system/`

  AQUA agent and skill definitions (`aqua/agents/*.md`,
  `aqua/skills/*/SKILL.md`) are the athanor's own — an ordinary tenant
  path, served through the seed overlay like `components/`: the shipped
  template shows through until a file is edited.
  """
  @global_prefixes for {root, :global, _guest, _seed} <- @layout, do: root

  def global_prefixes, do: @global_prefixes

  # The closed roster of tenant scopes. Every athanor tree holds exactly
  # these subtrees; an unknown first segment is refused, never silently
  # minted as a new subtree. A new kind of tenant state is a new row in
  # `@layout`.
  @tenant_roots for {root, class, _guest, _seed} <- @layout,
                    class in [:tenant, :tenant_reserved],
                    do: root

  @doc """
  The tenant scopes: the first segments a tenant-scoped path may start
  with, each a subtree of `athanors/{athanor_id}/`. `authorize_path/2`
  refuses everything outside this roster (and outside the seed/global
  vocabularies), so a typo'd or invented root is a typed refusal instead
  of a brand-new subtree.
  """
  @spec tenant_roots() :: [String.t()]
  def tenant_roots, do: @tenant_roots

  # Tenant roots only the server's own machinery may mutate. `meta/`
  # holds the overlay's origin marks — the facts `unit_status/2` trusts
  # to tell a copy of shipped media from the athanor's own work — so a
  # member-level write there could forge a mark and turn "reset" into
  # deleting member work. Reads stay ordinary tenant reads.
  @reserved_roots for {root, :tenant_reserved, _guest, _seed} <- @layout, do: root

  @doc """
  The reserved tenant roots: subtrees of the athanor's tree that only the
  overlay's internal-write scope (`Arca.Overlay.with_internal_writes/1`)
  or an `auth_method: :system` context may mutate — `Arca.mutating/4`
  enforces it. They live and die with the tree (an athanor purge deletes
  them like any tenant bytes); only who may write them differs.
  """
  @spec reserved_roots() :: [String.t()]
  def reserved_roots, do: @reserved_roots

  # The guest (WASM) storage vocabulary and the physical tenant scope each
  # guest scope stores under. The guest contract says `data/`; the host
  # stores that scope under `guest/`, a physical sibling of the host
  # scopes (aqua/, conversations/) so a `data/` grant can never see them.
  @guest_scopes Map.new(
                  for {root, _class, guest, _seed} <- @layout, guest != nil, do: {guest, root}
                )

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
  Whether `name` is spelled like an in-flight atomic write (`<file>.tmp.<n>`,
  the shape `Arca.Adapters.Local` renames over its target). One predicate,
  two consumers: the facade reserves the shape on writes so no adapter
  ever stores content a Local listing would hide, and the Local adapter —
  the only one that creates the shape — hides it from listings and walks
  (S3 never stores one, so it filters nothing).
  """
  @spec tmp_name?(String.t()) :: boolean()
  def tmp_name?(name) when is_binary(name), do: name =~ ~r/\.tmp\.\d+$/

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
  # seed tree (`:seed_path`), named after its logical root — the rows of
  # `@layout` whose seed column is set.
  @seed_roots for {root, _class, _guest, seed} <- @layout, seed != nil, do: root

  @doc """
  The seed-media roots: the logical `["seed", root | rest]` prefixes, each a
  same-named subdirectory of the one seed tree (`:seed_path`). `Arca` pins
  them to the Local adapter, `authorize_path/2` admits only system contexts,
  and `Arca.Adapters.Local.build_path/2` routes them under the seed tree —
  outside the storage root.
  """
  @spec seed_roots() :: [String.t()]
  def seed_roots, do: @seed_roots

  @doc """
  The logical prefix of one seed root — `["seed", root]`, the one spelling
  of the seed vocabulary (`Arca.Overlay`, `Compendium.AquaTemplate` and
  `Sanctum.Provisioning`'s bundle-presence probe consume it). A root
  outside `seed_roots/0` raises (fail closed, like the rest of this
  module).

  ## Examples

      iex> Arca.Storage.seed_prefix("components")
      ["seed", "components"]

  """
  @spec seed_prefix(String.t()) :: path()
  def seed_prefix(root) when root in @seed_roots, do: ["seed", root]

  @doc """
  The inverse of `seed_prefix/1`'s vocabulary: strip the `"seed"` head
  from a seed-side path, back to logical segments — the one spelling of
  that strip, so no consumer hand-patterns the literal.

  ## Examples

      iex> Arca.Storage.seed_logical(["seed", "aqua", "agents", "aqua.md"])
      ["aqua", "agents", "aqua.md"]

  """
  @spec seed_logical(path()) :: path()
  def seed_logical(["seed" | rest]), do: rest

  # The overlay roots, from the layout table. Their unit shapes live with
  # the domain locators (`locate/1`).
  @overlay_roots for {root, _class, _guest, :overlay} <- @layout, do: root

  @doc """
  The seed-overlaid roots: `Arca.Overlay` resolves reads through the seed
  tree below these roots and materializes a shadowed unit on first write.
  How each root's units are shaped is its locator's answer — `locate/1`.
  """
  @spec overlay_roots() :: [String.t()]
  def overlay_roots, do: @overlay_roots

  @typedoc """
  Where a path sits relative to a shadow unit: `:not_overlaid` (the root
  has no seed union at all — including the empty path), `:above_unit`
  (inside an overlaid root but above any unit — listings union here), or
  at/below one unit, shaped as its locator declares it
  (`Arca.Storage.UnitLocator`).
  """
  @type location ::
          :not_overlaid
          | :above_unit
          | {:file, unit :: path()}
          | {:dir, unit :: path(), sentinel :: String.t()}

  @locators_key {__MODULE__, :overlay_locators}

  @doc """
  Assert the locator wiring and install it: `:overlay_locators` must name
  exactly the overlaid roots (`overlay_roots/0`), each value a module
  exporting `locate/1` — checked loudly at boot
  (`Cyfr.Application.start/2`), before anything scans the union, instead
  of on the first touch of whichever root was forgotten. The verified map
  is cached in `:persistent_term` so `locate/1` — called per leaf in
  batch walks — never re-reads config. The map is boot-frozen by design:
  a test that ever swaps `:overlay_locators` must call this again after
  `put_env` and after the restore.
  """
  @spec install_locators!() :: %{String.t() => module()}
  def install_locators! do
    configured = Application.get_env(:cyfr, :overlay_locators, %{})
    roots = MapSet.new(@overlay_roots)
    keys = MapSet.new(Map.keys(configured))

    unless MapSet.equal?(roots, keys) do
      raise ArgumentError, """
      :overlay_locators must name exactly the overlaid roots.
        overlaid roots (Arca.Storage layout): #{inspect(Enum.sort(roots))}
        configured locators:                  #{inspect(Enum.sort(keys))}
      Remedy: add the missing root's Arca.Storage.UnitLocator to
      `config :cyfr, :overlay_locators`, or add/remove the root's row in
      the layout table — the two must always agree.
      """
    end

    for {root, mod} <- configured,
        not (Code.ensure_loaded?(mod) and function_exported?(mod, :locate, 1)) do
      raise ArgumentError,
            "locator for #{inspect(root)} (#{inspect(mod)}) does not implement " <>
              "Arca.Storage.UnitLocator"
    end

    :persistent_term.put(@locators_key, configured)
    configured
  end

  @doc """
  Locate `path` against the overlay's unit grammar: the one lookup from a
  logical path to its shadow unit and shape, answered by the root's
  installed `Arca.Storage.UnitLocator` (pure — no I/O, so batch walks
  can classify every leaf without a probe). A non-overlaid root — `meta/`,
  `guest/`, the empty path — is `:not_overlaid`. The wiring is asserted
  and cached by `install_locators!/0` at boot; the lazy fallback here
  covers `--no-start` scripts.
  """
  @spec locate(path()) :: location()
  def locate([root | _] = path) when root in @overlay_roots do
    locators =
      case :persistent_term.get(@locators_key, :not_installed) do
        :not_installed -> install_locators!()
        map -> map
      end

    Map.fetch!(locators, root).locate(path)
  end

  def locate(_path), do: :not_overlaid

  @doc """
  Whether a guest-facing storage path names a guest scope: the empty string
  (the scope listing), a bare scope (`"data"`, `"components"`), or anything
  under one (`"data/notes.txt"`). One predicate shared by the manifest
  parser (`Compendium.Manifest.Caps`) and the WIT boundary
  (`Opus.StorageHandler.validate_path_scope/1`), so a grant no runtime
  would honor is refused at parse — and the two layers cannot drift.

  ## Examples

      iex> Arca.Storage.valid_guest_path?("data/notes.txt")
      true

      iex> Arca.Storage.valid_guest_path?("aqua/agent.json")
      false

  """
  @spec valid_guest_path?(String.t()) :: boolean()
  def valid_guest_path?(""), do: true

  def valid_guest_path?(path) when is_binary(path) do
    Enum.any?(Map.keys(@guest_scopes), fn scope ->
      path == scope or String.starts_with?(path, scope <> "/")
    end)
  end

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
  Whether this context can name a tenant tree at all: a resolved
  `athanor_id` matching the id grammar. The boundary spelling of the
  invariant `tenant_segments/1` enforces by raising — total predicates
  (`Arca.exists?/2`) and guest-facing refusals (`Opus.StorageHandler`)
  consume this; everything else keeps the fail-closed raise.
  """
  @spec athanor_ready?(Context.t()) :: boolean()
  def athanor_ready?(%Context{athanor_id: id}) when is_binary(id) and id != "",
    do: id =~ @athanor_id_format

  def athanor_ready?(%Context{}), do: false

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

  # The one physical directory every athanor tree lives under. Spelled as
  # an attribute so `physical_segments/2` and the Local sweep walk share
  # it — the layout's one spelling of where tenants are stored.
  @tenant_physical_root "athanors"

  @doc """
  The physical directory every athanor tree lives under — the layout's one
  spelling. `physical_segments/2` prefixes tenant paths with it; the Local
  adapter's stale-tmp sweep walks it.
  """
  @spec tenant_physical_root() :: String.t()
  def tenant_physical_root, do: @tenant_physical_root

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

  The raises here are unreachable through the `Arca` facade — the seed
  branch is refused earlier as `:seed_read_only` on writes (and routed to
  the seed tree on reads), and an unknown root as `:forbidden` by
  `authorize_path/2` — so they are the fail-closed backstop for code that
  reaches an adapter directly.
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
        [@tenant_physical_root | tenant_segments(ctx)] ++ segments

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
  Refuse a seed write at the adapter itself — one raise, one message,
  whichever adapter is asked. Seed media is read-only at the `Arca`
  facade for every context; this is the backstop that keeps a direct
  adapter call from writing into (or `rm_rf`-ing out of) the operator's
  install media, spelled once so the adapters cannot drift apart in how
  they refuse.
  """
  @spec refuse_seed_write!(path()) :: :ok
  def refuse_seed_write!(["seed" | _]) do
    raise ArgumentError, "seed media is read-only; no adapter accepts seed writes"
  end

  def refuse_seed_write!(_path), do: :ok

  @doc """
  Validate that path segments contain no traversal attacks.

  Delegates to `Cyfr.PathSafety.validate_segments!/1` (the canonical
  denylist, shared with the Opus storage policy boundary). Called once
  per operation, from the adapter's single path/key builder
  (`Arca.Adapters.Local.build_path/2`, the S3 adapter's key builder) —
  never per callback on top.

  ## Examples

      iex> Arca.Storage.validate_path!(["guest", "notes.txt"])
      :ok

      iex> Arca.Storage.validate_path!(["guest", "..", "..", "etc", "passwd"])
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

  @doc """
  Recursively delete a directory tree at path.

  Idempotent: deleting a tree that does not exist is `:ok` — the
  postcondition already holds. `{:error, :not_found}` is `delete/2`'s
  answer for a missing single object, never this callback's.
  """
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
  Read a whole subtree through any adapter, as `{relative_path, binary}`
  pairs — ONE algorithm (`list_recursive/2` + concurrent `get/2`) instead
  of a per-adapter callback, so the vanished-file rule and the file-path
  contract exist exactly once. `relative_path` is the segment list
  relative to the input prefix; listing order is kept.

  Contract: a file path answers `{:error, :enotdir}` (a file is not a
  subtree — an empty listing is disambiguated with one `list_typed/2`);
  a missing prefix is `{:ok, []}`; a leaf that vanishes between the
  listing and its read is skipped (concurrent deletion is not an error
  for a tree dump); any other per-leaf error halts.

  Memory-bounded: bytes are buffered in-memory. Use `serve_to_conn/4` for
  large single-file streaming. Concurrency comes from the
  `:read_subtree_concurrency` config (default 10), overridable per call
  with `:concurrency`; the per-leaf read deadline is `:timeout` (default
  30s). A leaf read that hangs past the deadline or crashes answers
  `{:error, {:subtree_read_failed, leaf, reason}}` — never an exit in the
  caller.
  """
  @spec read_subtree_via(module(), Context.t(), path(), keyword()) ::
          {:ok, [{path(), binary()}]} | error()
  def read_subtree_via(adapter, %Context{} = ctx, path, opts \\ []) do
    with {:ok, leaf_segments} <- adapter.list_recursive(ctx, path) do
      case leaf_segments do
        [] ->
          case adapter.list_typed(ctx, path) do
            {:error, :enotdir} -> {:error, :enotdir}
            _directory_or_missing -> {:ok, []}
          end

        leaves ->
          concurrency =
            Keyword.get(opts, :concurrency) ||
              Application.get_env(:cyfr, :read_subtree_concurrency, 10)

          # `:kill_task` (with `:zip_input_on_exit` naming the leaf) turns a
          # hung or crashed per-leaf read into a typed error instead of
          # killing the caller — the contract promises a tuple, and the
          # callers of a bulk read are request handlers, not supervisors.
          leaves
          |> Task.async_stream(fn segs -> {segs, adapter.get(ctx, segs)} end,
            max_concurrency: concurrency,
            timeout: Keyword.get(opts, :timeout, 30_000),
            on_timeout: :kill_task,
            zip_input_on_exit: true,
            ordered: true
          )
          |> Enum.reduce_while([], fn
            {:ok, {segs, result}}, acc ->
              case result do
                {:ok, content} -> {:cont, [{Enum.drop(segs, length(path)), content} | acc]}
                {:error, :not_found} -> {:cont, acc}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            {:exit, {segs, reason}}, _acc ->
              {:halt, {:error, {:subtree_read_failed, segs, reason}}}
          end)
          |> case do
            {:error, _} = error -> error
            pairs -> {:ok, Enum.reverse(pairs)}
          end
      end
    end
  end

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

  @stale_tmp_max_age_seconds 86_400

  @doc "How old a `.tmp.<n>` artifact must be before the sweep reclaims it."
  @spec stale_tmp_max_age_seconds() :: non_neg_integer()
  def stale_tmp_max_age_seconds, do: @stale_tmp_max_age_seconds

  # Build droppings a checked-out component tree may carry (someone ran
  # cargo or npm inside src/). Never part of a component; every tree copy
  # (overlay materialization, fork) excludes them by this one predicate.
  @build_droppings ~w(target node_modules .git)

  @doc """
  Whether a relative path runs through a build-droppings directory
  (`target/`, `node_modules/`, `.git/`) — the shared exclusion every
  component tree copy applies.
  """
  @spec build_dropping?(path()) :: boolean()
  def build_dropping?(relative) when is_list(relative),
    do: Enum.any?(relative, &(&1 in @build_droppings))

  @doc """
  Optional: reclaim stale atomic-write temp artifacts older than the given
  age in seconds, answering how many were removed. Local's write-then-
  rename discipline leaves `.tmp.<n>` files behind on a crash; an adapter
  with no in-flight artifacts to reclaim (an object store) simply does not
  export this — `Arca.sweep_stale_tmp/0` answers `{:ok, 0}` without
  asking.
  """
  @callback sweep_stale_tmp(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}

  @optional_callbacks sweep_stale_tmp: 1
end
