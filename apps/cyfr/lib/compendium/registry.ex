# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry do
  @moduledoc """
  The athanor's component index: rows (`Arca.ComponentStorage`, on
  `Arca.Repo`) over bytes the overlay serves
  (`components/{type}s/{publisher}/{name}/{version}/` —
  `Compendium.ComponentPath` owns the shape, the tenant is never in the
  path). A row makes a component addressable by
  `type:namespace.name:version` reference; the bytes stay the tree's.

  ## The four ingresses

  Everything that mints a row converges on one builder:

  - `publish_bytes/4` (`source: "published"`) — raw WASM from a
    same-machine caller; refuses tinctures; `origin: :remote` may never
    mint into `local` (`Compendium.NamespacePolicy`).
  - `publish_tincture_archive/4` (`source: "oci"`) — a tar+gzip tincture
    bundle, decompression-bounded (`Compendium.Archive.gunzip_bounded/2`),
    symlink-refusing, validated before a byte is stored.
  - `register_from_arca/3` (`source: "filesystem"`) — the scanner's path
    (`Compendium.AutoIndexer` walks the seed UNION, so bundled versions
    get rows without a byte copied); `local` publisher only.
  - the OCI pull (`Compendium.OCI.Client`) — stores files then registers
    with `allow_overwrite`, never into `local`.

  ## Delete vs reset — provenance decides

  `delete/4` asks `Compendium.Provenance` first: a `:bundled` component
  is the release's, not the athanor's (refused); a `:bundled_modified`
  copy refuses too — "delete" never means "revert"; the revert is
  `reset/4`, which asks the overlay's `revert_copy/2` (only a
  materialized copy reverts; member work never does). A `:user`/`:remote`
  component deletes bytes FIRST, then rows, so the DB can never claim a
  deletion the tree didn't make.

  Sibling homes for what used to live here: canonical hostnames —
  `Compendium.RegistryHost`; archive mechanics — `Compendium.Archive`;
  the name-level removal cascade — `Compendium.Cascade`.
  """

  require Logger

  alias Sanctum.Context
  alias Compendium.WasmValidator, as: Validator
  alias Compendium.DependencyResolver
  alias Compendium.ComponentPath

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Publish raw WASM bytes to the local registry.

  ## Parameters

  - `ctx` - User context
  - `wasm_bytes` - Raw WASM binary bytes
  - `metadata` - Component metadata map:
    - `:name` - Component name (required)
    - `:version` - Semantic version (required)
    - `:type` - Component type: catalyst, reagent, formula (required)
    - `:description` - Human-readable description
    - `:tags` - List of tags for search
    - `:category` - Category name
    - `:license` - SPDX license identifier

  For `local` publisher, allows overwriting an existing version.
  Other publishers reject duplicate name:version combinations unless
  `allow_overwrite: true` is passed in opts (used by OCI pull).

  ## Options

  - `:allow_overwrite` - When true, overwrites existing components instead of
    rejecting duplicates. Used by OCI pull to update cached components.
  - `:origin` - `:remote` marks the bytes as sourced from a remote registry
    (the OCI pull path). Remote content may never mint into the `local`
    publisher namespace — that namespace is reserved for components
    registered from the filesystem.

  ## Returns

  - `{:ok, component}` - Published component metadata
  - `{:error, reason}` - Publication failed
  """
  def publish_bytes(%Context{} = ctx, wasm_bytes, metadata, opts \\ [])
      when is_binary(wasm_bytes) and is_map(metadata) do
    allow_overwrite = Keyword.get(opts, :allow_overwrite, false)
    unit_files = Keyword.get(opts, :unit_files, [])

    with {:ok, name} <- get_required(metadata, :name),
         {:ok, version} <- get_required(metadata, :version),
         {:ok, component_type} <- get_required(metadata, :type),
         :ok <- validate_name(name),
         :ok <- validate_version(version),
         :ok <- reject_tincture_publish_bytes(component_type),
         {:ok, validation} <- Validator.validate(wasm_bytes),
         publisher = ComponentPath.normalize_publisher(Map.get(metadata, :publisher)),
         :ok <- validate_publish_namespace(publisher, ctx),
         :ok <- validate_publish_origin(publisher, Keyword.get(opts, :origin)),
         manifest_bytes = Map.get(metadata, :manifest) || Map.get(metadata, "manifest"),
         {:ok, manifest_map} <- decode_manifest_strict(manifest_bytes),
         :ok <- validate_manifest_capability_blocks(manifest_map),
         # Before the unit commit: a refused republish must leave no bytes
         # behind for the scanner to pick up.
         :ok <-
           check_release_immutable(
             ctx,
             name,
             version,
             validation.digest,
             manifest_bytes,
             publisher,
             component_type
           ),
         {:ok, _written} <-
           commit_component_unit(
             ctx,
             component_type,
             publisher,
             name,
             version,
             wasm_bytes,
             manifest_bytes,
             unit_files
           ),
         {:ok, component} <-
           register_row_or_roll_back(ctx, name, version, metadata, validation, publisher,
             type: component_type,
             manifest: manifest_bytes,
             manifest_map: manifest_map,
             allow_overwrite: allow_overwrite,
             source: Keyword.get(opts, :source)
           ) do
      invalidate_executor_caches(ctx)
      {:ok, component}
    end
  end

  # One unit commit before the row: the artifact, any extra unit files (a
  # pull's README and src/ tree), and the manifest sentinel — synthesized
  # minimal when the publish carries none, so every published unit reads
  # complete and completeness and rows can never disagree. The storage
  # cap sees the whole incoming unit, not just the artifact.
  defp commit_component_unit(ctx, type, publisher, name, version, wasm_bytes, manifest, extras) do
    version_dir = ComponentPath.version_dir(type, publisher, name, version)
    wasm_rel = [List.last(ComponentPath.wasm_path(type, publisher, name, version))]

    total =
      byte_size(wasm_bytes) + Enum.sum(for {_rel, bytes} <- extras, do: byte_size(bytes))

    sentinel =
      manifest ||
        Jason.encode!(%{
          "name" => name,
          "version" => version,
          "type" => type,
          "publisher" => publisher
        })

    case Arca.Overlay.commit_unit(ctx, version_dir, {:files, [{wasm_rel, wasm_bytes} | extras]},
           cap: {:checked, total},
           sentinel: sentinel
         ) do
      {:ok, _written} = ok -> ok
      {:error, {:limit_reached, _, _}} = cap -> cap
      {:error, :storage_unverifiable} = unverifiable -> unverifiable
      {:error, reason} -> {:error, {:wasm_write_failed, reason}}
    end
  end

  # The row lands only after the unit is whole — and a refused row must
  # not leave an orphaned unit behind for the scanner to read as a
  # component. Dependency refs validate before the row is saved.
  defp register_row_or_roll_back(ctx, name, version, metadata, validation, publisher, opts) do
    build_opts =
      [manifest: opts[:manifest], manifest_map: opts[:manifest_map]] ++
        if opts[:source], do: [source: opts[:source]], else: []

    result =
      with {:ok, component} <-
             build_component(ctx, name, version, metadata, validation, publisher, build_opts),
           :ok <- validate_dependencies(component, opts[:manifest]),
           {:ok, _} <-
             save_component(ctx, component, opts[:allow_overwrite], name, version) do
        {:ok, component}
      end

    case result do
      {:ok, _component} = ok ->
        ok

      {:error, _} = error ->
        version_dir = ComponentPath.version_dir(opts[:type], publisher, name, version)

        case Arca.delete_tree(ctx, version_dir) do
          :ok ->
            :ok

          {:error, cleanup} ->
            Logger.warning(
              "[Compendium.Registry] unit cleanup after refused row failed for " <>
                "#{Enum.join(version_dir, "/")}: #{inspect(cleanup)}"
            )
        end

        error
    end
  end

  @doc """
  Publish a tincture from a tar+gzip archive (used by OCI pull).

  Extracts the archive to a temp directory, validates with `TinctureValidator`,
  stores files to Arca, and registers the component in the database.

  Unlike `publish_bytes/3`, this handles directory-based tincture packages
  rather than single WASM binaries.

  ## Parameters

  - `ctx` - User context
  - `archive_bytes` - Gzipped tar archive of the tincture directory
  - `metadata` - Component metadata map (name, version, type, publisher, etc.)
  - `opts` - Options:
    - `:allow_overwrite` - Allow overwriting existing versions (default: false)
  """
  def publish_tincture_archive(%Context{} = ctx, archive_bytes, metadata, opts \\ [])
      when is_binary(archive_bytes) and is_map(metadata) do
    allow_overwrite = Keyword.get(opts, :allow_overwrite, false)

    with {:ok, name} <- get_required(metadata, :name),
         {:ok, version} <- get_required(metadata, :version),
         {:ok, "tincture"} <- get_required(metadata, :type),
         :ok <- validate_name(name),
         :ok <- validate_version(version),
         publisher = ComponentPath.normalize_publisher(Map.get(metadata, :publisher)),
         :ok <- validate_publish_namespace(publisher, ctx),
         # This ingress only ever carries registry-sourced archives (local
         # tinctures register from the filesystem), so the local-namespace
         # refusal is unconditional here — no origin marker to forget.
         :ok <- validate_publish_origin(publisher, :remote),
         manifest_bytes = Map.get(metadata, :manifest),
         # Validate the manifest blocks on the OCI pull path too — the WASM
         # path (publish_bytes/4) already does, and a manifest sourced from a
         # remote registry is no more trustworthy than a directly-published one.
         {:ok, manifest_map} <- decode_manifest_strict(manifest_bytes),
         :ok <- validate_manifest_capability_blocks(manifest_map),
         {:ok, validation} <-
           extract_and_store_tincture(ctx, archive_bytes, publisher, name, version,
             # The unit commit itself checks the storage cap against the
             # measured decompressed total (the extracted tree is what
             # actually lands); this hook keeps only release immutability,
             # still after validation and before any Arca write.
             before_store: fn validation ->
               check_release_immutable(
                 ctx,
                 name,
                 version,
                 validation.digest,
                 manifest_bytes,
                 publisher,
                 "tincture"
               )
             end,
             # The metadata manifest — the pull path's authoritative config
             # blob — is the commit's sentinel when present; absent, the
             # archive's own manifest completes the unit.
             sentinel: manifest_bytes,
             # Extra unit files (a pull's README and src/ tree) ride the
             # same commit; listed after the archive's entries, so a layer
             # wins any name collision with an archived file.
             unit_files: Keyword.get(opts, :unit_files, [])
           ),
         {:ok, component} <-
           build_component(ctx, name, version, metadata, validation, publisher,
             source: Compendium.Source.oci(),
             manifest: manifest_bytes,
             manifest_map: manifest_map
           ),
         {:ok, _} <- save_component(ctx, component, allow_overwrite, name, version),
         :ok <- validate_dependencies(component, manifest_bytes) do
      invalidate_executor_caches(ctx)
      {:ok, component}
    end
  end

  @doc """
  Register a component from Arca segments (storage-adapter-agnostic).

  Used by `Compendium.AutoIndexer` after an `Arca.list_recursive/2` scan.
  Reads manifest + WASM via `Arca`, so it works on the Local FS adapter and
  any configured object-store adapter without code changes.

  ## Parameters

  - `ctx` - User context (used by Arca for tenant scoping)
  - `segments` - Path segments for the component version directory, e.g.
    `["components", "catalysts", "local", "my-tool", "0.1.0"]`
  - `opts` - `:force` re-registers an unchanged component
  """
  def register_from_arca(%Context{} = ctx, segments, opts \\ []) when is_list(segments) do
    with {:ok, manifest} <- read_manifest_arca(ctx, segments),
         {:ok, publisher, component_type, dir_name, dir_version} <-
           infer_segment_metadata(segments),
         :ok <- validate_register_namespace(publisher),
         name = manifest["name"] || dir_name,
         version = manifest["version"] || dir_version,
         :ok <- validate_name(name),
         :ok <- validate_version(version),
         :ok <- validate_manifest_capability_blocks(manifest),
         {:ok, validation} <- validate_artifact_arca(ctx, segments, component_type) do
      do_register(ctx, manifest, publisher, component_type, name, version, validation, opts)
    end
  end

  defp do_register(ctx, manifest, publisher, component_type, name, version, validation, opts) do
    force = Keyword.get(opts, :force, false)
    metadata = build_metadata_from_manifest(manifest, component_type)
    {:ok, manifest_json} = Jason.encode(manifest)

    if !force &&
         content_matches?(
           ctx,
           name,
           version,
           validation.digest,
           manifest_json,
           publisher,
           Map.fetch!(metadata, :type)
         ) do
      {:ok, :unchanged}
    else
      with {:ok, component} <-
             build_component(ctx, name, version, metadata, validation, publisher,
               source: Compendium.Source.filesystem(),
               manifest: manifest_json,
               manifest_map: manifest
             ) do
        Arca.ComponentStorage.delete_component(ctx, name, version, publisher, nil)

        with {:ok, _} <- put_component(ctx, component),
             :ok <- validate_dependencies(component, manifest) do
          invalidate_executor_caches(ctx)

          :telemetry.execute(
            [:cyfr, :compendium, :component, :install],
            %{system_time: System.system_time()},
            %{
              name: name,
              version: version,
              publisher: publisher,
              component_type: Map.fetch!(metadata, :type),
              digest: validation.digest,
              athanor_id: ctx.athanor_id,
              user_id: ctx.user_id
            }
          )

          {:ok, component}
        end
      end
    end
  end

  @doc """
  Prune stale filesystem-registered entries.

  Removes SQLite rows with `source: "filesystem"` that are not in the given
  set of currently-discovered `{name, version, publisher}` tuples.
  """
  def prune_stale_entries(%Context{} = ctx, discovered_components) do
    # Get all filesystem-registered components
    {:ok, existing} =
      Arca.ComponentStorage.list_components(ctx,
        source: Compendium.Source.filesystem(),
        limit: :none
      )

    discovered_set = MapSet.new(discovered_components)

    stale =
      Enum.filter(existing, fn comp ->
        publisher = ComponentPath.normalize_publisher(Map.get(comp, :publisher))
        not MapSet.member?(discovered_set, {comp.name, comp.version, publisher})
      end)

    for comp <- stale do
      publisher = ComponentPath.normalize_publisher(Map.get(comp, :publisher))
      # DB-only cleanup: remove the registry entry.
      # Do NOT delete filesystem files — prune is an automatic process that runs
      # during scan/register. If a component temporarily fails to be discovered
      # (mid-edit, transient error), we must not destroy user source files.
      # File deletion only happens via explicit `component.delete` (Registry.delete).
      Arca.ComponentStorage.delete_component(ctx, comp.name, comp.version, publisher, nil)
    end

    # After all deletions, clean up name-level entries for components with no remaining versions
    stale
    |> Enum.uniq_by(fn comp ->
      {comp.name, ComponentPath.normalize_publisher(Map.get(comp, :publisher))}
    end)
    |> Enum.each(fn comp -> Compendium.Cascade.name_removed(ctx, comp) end)

    if stale != [], do: invalidate_executor_caches(ctx)

    length(stale)
  end

  @doc """
  Search for components in the local registry.

  ## Filter Options

  - `:query` - Text search in name/description
  - `:type` - Component type filter
  - `:category` - Category filter
  - `:tags` - Tags filter (AND logic)
  - `:license` - License filter
  - `:limit` - Max results (default 20)
  """
  def search(%Context{} = ctx, filters \\ %{}) do
    limit = Map.get(filters, :limit, 20)

    opts = [limit: limit]
    opts = if type = filters[:type], do: Keyword.put(opts, :component_type, type), else: opts

    opts =
      if category = filters[:category], do: Keyword.put(opts, :category, category), else: opts

    opts = if query = filters[:query], do: Keyword.put(opts, :query, query), else: opts

    case Arca.ComponentStorage.list_components(ctx, opts) do
      {:ok, results} ->
        results =
          results
          |> decode_json_fields()
          |> Enum.map(&add_component_ref/1)
          |> filter_by_tags(filters[:tags])
          |> filter_by_license(filters[:license])
          |> Enum.take(limit)

        {:ok, %{components: results, total: length(results)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get a specific component by name and explicit version.

  The version must be an explicit semver string (e.g., `"1.0.0"`). Passing
  `"latest"` is not supported — callers must resolve the concrete version
  first (see `get_latest/4`).

  When looking up by namespace.name:version reference, pass the name and version
  extracted by `Sanctum.ComponentRef.parse/1`. Optionally pass a publisher and
  component_type to disambiguate.
  """
  def get(%Context{} = ctx, name, version, publisher \\ nil, component_type \\ nil)
      when is_binary(name) do
    if version == nil do
      {:error, :version_required}
    else
      case Arca.ComponentStorage.get_component(ctx, name, version, publisher, component_type) do
        {:ok, row} -> {:ok, decode_row_json_fields(row)}
        {:error, :not_found} -> {:error, :not_found}
      end
    end
  end

  @doc """
  Get the most recently published version of a component by name.

  Optionally pass a publisher and component_type to disambiguate.

  Returns `{:ok, component}` or `{:error, :not_found}`.
  """
  def get_latest(%Context{} = ctx, name, publisher \\ nil, component_type \\ nil)
      when is_binary(name) do
    case latest_row(ctx, name, publisher, component_type) do
      {:ok, row} -> {:ok, decode_row_json_fields(row)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get the latest version's raw storage row for a component by name.

  The single "latest" ordering every resolver shares: semver-aware sort in
  Elixir over the complete version set (adapter row order is never the
  authority — `"1.10.0"` sorts before `"1.2.0"` lexically but after it
  semantically), with `inserted_at` as the tiebreak. Activation digests are
  computed from this pick, so it must be deterministic and identical on
  every adapter.

  Returns the undecoded row (as `Arca.ComponentStorage` produced it);
  `get_latest/4` wraps it in the decoded document shape.
  """
  @spec latest_row(Context.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, :not_found | term()}
  def latest_row(%Context{} = ctx, name, publisher \\ nil, component_type \\ nil)
      when is_binary(name) do
    opts = [name: name, limit: :none]
    opts = if publisher, do: Keyword.put(opts, :publisher, publisher), else: opts
    opts = if component_type, do: Keyword.put(opts, :component_type, component_type), else: opts

    case Arca.ComponentStorage.list_components(ctx, opts) do
      {:ok, []} ->
        {:error, :not_found}

      {:ok, components} ->
        {:ok, latest_of(components)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The semver-latest of a list of rows, `inserted_at` as the tiebreak —
  the one place ROWS (not bare strings) are ordered. Registered versions
  are validated semver; the comparator (`Compendium.Semver`) is total
  regardless.
  """
  @spec latest_of([map()]) :: map() | nil
  def latest_of(rows) when is_list(rows) do
    rows
    |> Enum.sort(fn a, b ->
      case Compendium.Semver.compare(a.version, b.version) do
        :gt -> true
        :lt -> false
        :eq -> DateTime.compare(a.inserted_at, b.inserted_at) == :gt
      end
    end)
    |> List.first()
  end

  @doc """
  Get component WASM binary by digest.

  Searches for a matching component and reads its WASM file from the canonical path.
  """
  def get_blob(%Context{} = ctx, digest) when is_binary(digest) do
    # Direct digest lookup via indexed query (replaces O(n) linear scan)
    case Arca.ComponentStorage.get_by_digest(ctx, digest) do
      {:ok, %{component_type: "tincture"}} ->
        # Tinctures are directory-based, not single binary blobs
        {:error, :not_applicable}

      {:ok, component} ->
        publisher = ComponentPath.normalize_publisher(Map.get(component, :publisher))

        path =
          ComponentPath.artifact_path(
            component.component_type,
            publisher,
            component.name,
            component.version
          )

        Logger.debug(
          "[Registry.get_blob] Found #{component.name}:#{component.version}, reading path=#{inspect(path)}"
        )

        case Arca.get(ctx, path) do
          {:ok, content} ->
            Logger.debug("[Registry.get_blob] OK: read #{byte_size(content)} bytes")
            {:ok, content}

          {:error, reason} ->
            Logger.warning(
              "[Registry.get_blob] FAIL: file read failed for #{inspect(path)}, reason=#{inspect(reason)}"
            )

            {:error, :blob_not_found}
        end

      {:error, _} ->
        Logger.warning("[Registry.get_blob] FAIL: digest not found: #{digest}")
        {:error, :blob_not_found}
    end
  end

  @doc """
  Delete a component from the registry — and "deleted" means GONE.

  Provenance decides first (`Compendium.Provenance`): a `:bundled`
  component is the release's, not the athanor's — refused as
  `{:error, :bundled}` before anything is touched (deleting its row would
  only be resurrected by the next scan, while §3.10's profile revocation
  would silently outlive it). A `:bundled_modified` copy refuses as
  `{:error, :bundled_modified}` — "delete" never means "revert"; the
  revert is `reset/4`. A `:user`/`:remote` component deletes bytes FIRST
  (any storage failure keeps the row, so the DB can never claim a
  deletion the tree didn't make), then the row and its associations.
  Answers `{:ok, :deleted}` — or `{:ok, :revealed_shipped}` when the
  deleted unit was the athanor's own work shadowing a shipped
  counterpart, which the delete has just uncovered (the next scan
  re-registers it as bundled): the surface must say so, or shipped
  components look deletable.

  Optionally pass a publisher to disambiguate components with the same
  name/version.
  """
  @spec delete(Context.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, :deleted | :revealed_shipped}
          | {:error, :not_found | :bundled | :bundled_modified | term()}
  def delete(%Context{} = ctx, name, version, publisher_filter \\ nil)
      when is_binary(name) and is_binary(version) do
    case Arca.ComponentStorage.get_component(ctx, name, version, publisher_filter, nil) do
      {:ok, component} ->
        with {:ok, disposition} <- delete_disposition(ctx, component),
             :ok <- cleanup_component_associations(ctx, component) do
          Arca.ComponentStorage.delete_component(ctx, name, version, publisher_filter, nil)
          Compendium.Cascade.name_removed(ctx, component)
          invalidate_executor_caches(ctx)

          :telemetry.execute(
            [:cyfr, :compendium, :component, :remove],
            %{system_time: System.system_time()},
            %{
              name: name,
              version: version,
              publisher: Map.get(component, :publisher) || publisher_filter,
              component_type: Map.get(component, :component_type),
              athanor_id: ctx.athanor_id,
              user_id: ctx.user_id
            }
          )

          {:ok, disposition}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # Provenance decides the refusals; the overlay's unit state says what a
  # permitted delete uncovers. The extra probe runs only for the
  # athanor's own units — remote rows have no seed counterpart to reveal.
  defp delete_disposition(ctx, component) do
    case Compendium.Provenance.of(ctx, component) do
      {:ok, :bundled} ->
        {:error, :bundled}

      {:ok, :bundled_modified} ->
        {:error, :bundled_modified}

      {:ok, :remote} ->
        {:ok, :deleted}

      {:ok, :user} ->
        case Arca.Overlay.unit_status(ctx, Compendium.Provenance.version_dir(component)) do
          {:ok, :own_shadowing} -> {:ok, :revealed_shipped}
          {:ok, _own_or_absent} -> {:ok, :deleted}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Revert a `:bundled_modified` component to exactly what the release
  shipped: delete the athanor's materialized copy (the seed shows through
  again) and re-register so the row matches the pristine bytes. Refused
  for anything else — `{:ok, :already_pristine}` for an unedited bundled
  component, `{:error, :not_bundled}` for the athanor's own or a pulled
  one.
  """
  @spec reset(Context.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, :reset | :already_pristine} | {:error, term()}
  def reset(%Context{} = ctx, name, version, publisher_filter \\ nil)
      when is_binary(name) and is_binary(version) do
    with {:ok, component} <-
           Arca.ComponentStorage.get_component(ctx, name, version, publisher_filter, nil) do
      # The overlay's revert verb IS the policy: only a materialized copy
      # reverts. The athanor's own work (a fork, a pull, its own name a
      # release later shipped) refuses as :not_a_copy; an unmaterialized
      # bundled unit as :bundled — both mapped to this surface's words.
      case Arca.Overlay.revert_copy(ctx, Compendium.Provenance.version_dir(component)) do
        :ok ->
          with {:ok, _} <-
                 register_from_arca(ctx, Compendium.Provenance.version_dir(component)) do
            invalidate_executor_caches(ctx)
            {:ok, :reset}
          end

        {:error, :bundled} ->
          {:ok, :already_pristine}

        {:error, refused} when refused in [:not_a_copy, :not_found, :not_overlaid] ->
          {:error, :not_bundled}

        {:error, _} = error ->
          error
      end
    end
  end

  # ============================================================================
  # Storage Operations
  # ============================================================================

  # Extract a tincture tar+gzip archive, validate it, and store files to Arca.
  # Returns {:ok, %{digest, size, exports}} on success.
  # Strip SQLite runtime artifacts defensively; `data.db` itself is allowed
  # as a regular shipped asset.
  @tincture_excluded_on_pull ~w(data.db-wal data.db-shm)

  defp extract_and_store_tincture(ctx, archive_bytes, publisher, name, version, opts) do
    # Hook between validation and the first Arca write. Callers use it to
    # refuse a publish without leaving extracted files behind.
    before_store = Keyword.get(opts, :before_store, fn _validation -> :ok end)

    # arca:bypass-ok=D — `:erl_tar.extract` requires a real local FS to write
    # to. After extraction we validate the bundle and write the validated
    # files back through Arca via `store_tincture_files/4`.
    tmp_dir = Path.join(System.tmp_dir!(), "cyfr_tincture_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    try do
      # Bound the decompressed size — a small gzip can expand to many GB
      # (decompression bomb) and OOM the node. The tar that follows can hold no
      # more bytes than the gunzip output, so this also caps total extracted
      # content.
      case Compendium.Archive.gunzip_bounded(archive_bytes, tincture_max_decompressed_bytes()) do
        {:ok, tar_binary} ->
          # arca:bypass-ok=D — tar extraction into the scratch dir above.
          case :erl_tar.extract({:binary, tar_binary}, [{:cwd, String.to_charlist(tmp_dir)}]) do
            :ok ->
              with {:ok, validation} <- Compendium.TinctureValidator.validate(tmp_dir),
                   :ok <- before_store.(validation),
                   {:ok, entries} <- collect_tincture_entries(tmp_dir, tmp_dir) do
                version_dir =
                  Compendium.ComponentPath.version_dir(
                    "tincture",
                    publisher,
                    name,
                    version
                  )

                extras = Keyword.get(opts, :unit_files, [])
                extras_bytes = Enum.sum(for {_rel, bytes} <- extras, do: byte_size(bytes))

                # One unit commit: the validated files stream from the
                # scratch dir one at a time (lazy reads keep the memory
                # bound), the manifest sentinel lands last, a partial
                # write rolls back — the registry never records a healthy
                # component whose stored files miss its digest.
                source =
                  {:files,
                   Enum.map(entries, fn {rel, path} ->
                     {rel, fn -> read_scratch(tmp_dir, path) end}
                   end) ++ extras}

                case Arca.Overlay.commit_unit(ctx, version_dir, source,
                       cap: {:checked, validation.size + extras_bytes},
                       sentinel: Keyword.get(opts, :sentinel)
                     ) do
                  {:ok, _written} ->
                    {:ok, validation}

                  {:error, {:limit_reached, _, _} = cap} ->
                    {:error, cap}

                  {:error, :storage_unverifiable} = unverifiable ->
                    unverifiable

                  {:error, reason} ->
                    {:error, {:tincture_store_failed, reason}}
                end
              end

            {:error, reason} ->
              {:error, "Failed to extract tincture archive: #{inspect(reason)}"}
          end

        {:error, :too_large} ->
          {:error,
           "Tincture archive decompresses beyond the allowed limit " <>
             "(#{tincture_max_decompressed_bytes()} bytes)"}

        {:error, _reason} ->
          {:error, "Failed to decompress tincture archive"}
      end
    rescue
      e -> {:error, "Failed to decompress tincture archive: #{Exception.message(e)}"}
    after
      # arca:bypass-ok=D — clean up the tar-extract tmp dir.
      File.rm_rf!(tmp_dir)
    end
  end

  # Default cap for a decompressed tincture archive (256 MB). Tinctures are
  # frontend bundles — typically a few MB — so this is generous headroom while
  # still bounding a decompression bomb. Operators may override via
  # `config :cyfr, :tincture_max_decompressed_bytes`.
  @default_tincture_max_decompressed 256 * 1024 * 1024

  defp tincture_max_decompressed_bytes do
    Application.get_env(
      :cyfr,
      :tincture_max_decompressed_bytes,
      @default_tincture_max_decompressed
    )
  end

  # arca:bypass-ok=D — read a tar-extract scratch file for the commit's
  # lazy write; a vanished or unreadable scratch entry aborts the commit.
  defp read_scratch(base_dir, path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error, {:tincture_read_failed, Path.relative_to(path, base_dir), reason}}
    end
  end

  # Walks the tar-extract scratch dir into `{relative_segments, path}`
  # pairs for the unit commit — validation-side exclusions and the
  # symlink backstop live here; the write discipline is the commit's.
  defp collect_tincture_entries(base_dir, current_dir) do
    current_dir
    # arca:bypass-ok=D — list the tar-extract scratch dir.
    |> File.ls!()
    |> Enum.reject(&(&1 in @tincture_excluded_on_pull))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      path = Path.join(current_dir, entry)

      cond do
        # lstat, not stat: File.dir?/File.read follow symlinks, so a link
        # here would recurse into itself or copy a host file into Arca.
        # The validator refuses links too; this is the store-side backstop.
        # arca:bypass-ok=D — stat the tar-extract scratch entries.
        match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) ->
          {:halt, {:error, {:tincture_symlink_rejected, Path.relative_to(path, base_dir)}}}

        # arca:bypass-ok=D — walk the scratch tree.
        File.dir?(path) ->
          case collect_tincture_entries(base_dir, path) do
            {:ok, sub} -> {:cont, {:ok, acc ++ sub}}
            {:error, _} = error -> {:halt, error}
          end

        true ->
          rel = Path.relative_to(path, base_dir)
          {:cont, {:ok, acc ++ [{String.split(rel, "/"), path}]}}
      end
    end)
  end

  # ============================================================================
  # Dependency validation
  # ============================================================================
  #
  # A manifest's dependency refs must parse; the edges themselves are read
  # from the manifest at activation time (`Compendium.Activation`), so
  # nothing is stored here — a bad ref simply refuses the registration.

  defp validate_dependencies(_component, nil), do: :ok

  defp validate_dependencies(component, manifest) when is_binary(manifest) do
    case Jason.decode(manifest) do
      {:ok, decoded} ->
        validate_dependencies(component, decoded)

      {:error, err} ->
        Logger.warning(
          "[Registry] Failed to decode manifest for dependency validation: #{inspect(err)}"
        )

        :ok
    end
  end

  defp validate_dependencies(component, manifest) when is_map(manifest) do
    component_id = component[:id] || component["id"]

    case DependencyResolver.extract_from_manifest(manifest, component_id) do
      {:ok, _deps} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Compendium.Registry] Failed to extract dependencies: #{inspect(reason)}")
        {:error, {:dependency_extraction_failed, reason}}
    end
  end

  # ============================================================================
  # MCP Boundary Helpers
  # ============================================================================

  # For local publisher, allow overwrite (skip check_not_exists).
  # Other publishers reject duplicates.
  defp put_component(ctx, component) do
    Arca.ComponentStorage.put_component(ctx, component)
  end

  # Atomically insert or upsert depending on allow_overwrite.
  # For local publisher, always upsert (allow_overwrite semantics).
  # For non-local, use insert_component to detect duplicates atomically.
  defp save_component(ctx, component, true = _allow_overwrite, _name, _version) do
    put_component(ctx, component)
  end

  defp save_component(ctx, component, false, name, version) do
    publisher = ComponentPath.normalize_publisher(Map.get(component, :publisher))

    if ComponentPath.local_publisher?(publisher) do
      put_component(ctx, component)
    else
      case Arca.ComponentStorage.insert_component(ctx, component) do
        {:ok, _} = ok -> ok
        {:error, :already_exists} -> {:error, {:already_exists, name, version}}
        error -> error
      end
    end
  end

  # ============================================================================
  # Index Operations
  # ============================================================================

  defp build_component(ctx, name, version, metadata, validation, publisher, opts) do
    now = DateTime.utc_now()
    component_type = Map.fetch!(metadata, :type)
    source = Keyword.get(opts, :source, Compendium.Source.published())
    manifest = Keyword.get(opts, :manifest)

    # Every ingress converges here — the one place the closed source
    # roster is enforced, since the row store takes raw attrs. A value
    # outside it would silently skew provenance and the signature
    # verifier's fail-closed branch.
    unless source in Compendium.Source.values() do
      raise ArgumentError,
            "unknown component source #{inspect(source)}; " <>
              "the roster is #{inspect(Compendium.Source.values())}"
    end

    # Every ingress converges here, so this is the one place activation
    # identity is computed. Callers pass the already-decoded manifest so the
    # digest sees exactly what validation saw.
    with {:ok, release_digest} <-
           Compendium.ReleaseDigest.compute(validation.digest, Keyword.get(opts, :manifest_map)),
         {:ok, tags_json} <- Jason.encode(Map.get(metadata, :tags, [])),
         {:ok, exports_json} <- Jason.encode(validation.exports) do
      component = %{
        id: generate_id(name, version, publisher, component_type, ctx.athanor_id),
        name: name,
        version: version,
        component_type: component_type,
        description: Map.get(metadata, :description, ""),
        tags: tags_json,
        category: Map.get(metadata, :category),
        license: Map.get(metadata, :license),
        digest: validation.digest,
        release_digest: release_digest,
        size: validation.size,
        exports: exports_json,
        manifest: manifest,
        publisher: publisher,
        publisher_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        source: source,
        signature_verified: Map.get(metadata, :signature_verified, false),
        signer_identity: Map.get(metadata, :signer_identity),
        signer_issuer: Map.get(metadata, :signer_issuer),
        inserted_at: now,
        updated_at: now
      }

      # Validate component identity here — in the registry (the component
      # domain) — so Arca.ComponentStorage persists already-validated
      # attributes. A validation error returns directly (not wrapped as a
      # JSON-encode failure, which only the `<-` clauses above produce).
      with :ok <- validate_attrs(component), do: {:ok, component}
    else
      # A manifest the canonicalizer refuses (a float or null in a security
      # block) is a malformed release, not an encoding accident — keep the
      # typed reason so the publisher can see which field is at fault.
      {:error, {:invalid_manifest, _} = reason} -> {:error, reason}
      {:error, {:invalid_artifact_digest, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:json_encode_failed, reason}}
    end
  end

  defp generate_id(name, version, publisher, component_type, athanor_id) do
    Compendium.ComponentId.compute(name, version, publisher, component_type, athanor_id)
  end

  # ============================================================================
  # JSON Field Helpers
  # ============================================================================

  defp decode_json_fields(rows) when is_list(rows) do
    Enum.map(rows, &decode_row_json_fields/1)
  end

  # Local components arrive as `%Arca.Schemas.Component{}` structs; normalize
  # to the plain, atom-keyed map the document model uses (remote components
  # already arrive as maps), then decode the JSON-text columns.
  defp decode_row_json_fields(%Arca.Schemas.Component{} = row) do
    row |> Map.from_struct() |> Map.delete(:__meta__) |> decode_row_json_fields()
  end

  defp decode_row_json_fields(row) when is_map(row) do
    row
    |> Map.update(:tags, [], &decode_json/1)
    |> Map.update(:exports, [], &decode_json/1)
    |> Map.update(:manifest, nil, &decode_manifest_json/1)
  end

  defp decode_manifest_json(nil), do: nil
  defp decode_manifest_json(value) when is_map(value), do: value

  defp decode_manifest_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) ->
        map

      other ->
        Logger.warning("[Registry] Failed to decode manifest JSON: #{inspect(other)}")
        nil
    end
  end

  defp add_component_ref(component) do
    type = component[:component_type]
    publisher = ComponentPath.normalize_publisher(component[:publisher])
    name = component[:name]
    version = component[:version]

    ref =
      Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
        type: type,
        namespace: publisher,
        name: name,
        version: version
      })

    Map.put(component, :component_ref, ref)
  end

  defp decode_json(nil), do: []
  defp decode_json(value) when is_list(value), do: value

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) ->
        list

      other ->
        Logger.warning("[Registry] Failed to decode JSON field: #{inspect(other)}")
        []
    end
  end

  # ============================================================================
  # Filter Functions
  # ============================================================================

  defp filter_by_tags(components, nil), do: components
  defp filter_by_tags(components, []), do: components

  defp filter_by_tags(components, tags) do
    Enum.filter(components, fn c ->
      component_tags = Map.get(c, :tags, [])
      Enum.all?(tags, &(&1 in component_tags))
    end)
  end

  defp filter_by_license(components, nil), do: components

  defp filter_by_license(components, license) do
    Enum.filter(components, &(&1.license == license))
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp get_required(map, key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      nil -> {:error, {:missing_required, key}}
      "" -> {:error, {:missing_required, key}}
      value -> {:ok, value}
    end
  end

  # The "cyfr" namespace is reserved for first-party components: only a
  # platform-scoped caller may publish there. The gate used to ask for a
  # `:cyfr_publish` permission that appears in no vocabulary and can be
  # granted to nobody — `Sanctum.Atoms` would strip it off a key — so the
  # only thing that ever passed was the `:*` wildcard every interactive
  # login carries, which is to say the reservation held against no one.
  # "local" is unrestricted; all other namespaces are open.
  defp validate_publish_namespace("cyfr", %Context{scope: :platform}), do: :ok
  defp validate_publish_namespace("cyfr", %Context{platform_admin: true}), do: :ok

  defp validate_publish_namespace("cyfr", %Context{}) do
    {:error,
     {:namespace_reserved, "the 'cyfr' namespace is reserved for CYFR first-party components"}}
  end

  defp validate_publish_namespace(_publisher, _ctx), do: :ok

  # Remote (registry-sourced) content must never mint into `local`,
  # however the ref was spelled on the way in — the policy is
  # `Compendium.NamespacePolicy`'s; this wraps its refusal in the publish
  # surface's error shape. Direct local publishes (no `:remote` origin)
  # are unaffected — same-machine callers, equivalent in trust to the
  # register path.
  defp validate_publish_origin(publisher, :remote) do
    case Compendium.NamespacePolicy.refuse_remote_ingress(publisher) do
      :ok -> :ok
      {:error, message} -> {:error, {:namespace_rejected, message}}
    end
  end

  defp validate_publish_origin(_publisher, _origin), do: :ok

  defp validate_name(name) do
    case Sanctum.ComponentRef.validate_name(name) do
      :ok -> :ok
      {:error, msg} -> {:error, {:invalid_name, msg}}
    end
  end

  defp validate_version(version) do
    case Sanctum.ComponentRef.validate_version(version) do
      :ok -> :ok
      {:error, msg} -> {:error, {:invalid_version, msg}}
    end
  end

  @doc """
  Validate component-identity attributes before storage.

  Component-identity rules live here, with the registry (the component domain) —
  not in the Arca storage layer, which persists already-validated bytes. Checks
  that name/version/component_type/publisher are present and each passes its
  `Sanctum.ComponentRef` field validator. Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_attrs(map()) :: :ok | {:error, term()}
  def validate_attrs(attrs) when is_map(attrs) do
    with {:ok, name} <- require_field(attrs, :name),
         {:ok, version} <- require_field(attrs, :version),
         {:ok, type} <- require_field(attrs, :component_type),
         {:ok, publisher} <- require_field(attrs, :publisher),
         :ok <- Sanctum.ComponentRef.validate_name(name),
         :ok <- Sanctum.ComponentRef.validate_version(version),
         :ok <- Sanctum.ComponentRef.validate_type(type),
         :ok <- Sanctum.ComponentRef.validate_publisher(publisher) do
      :ok
    end
  end

  defp require_field(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      nil -> {:error, {:missing_required, key}}
      "" -> {:error, {:missing_required, key}}
      value -> {:ok, value}
    end
  end

  # Every register path decodes the manifest strictly before this runs, so
  # the input is always nil or a map — a malformed manifest is rejected
  # upstream instead of silently passing validation with zero declarations.
  defp decode_manifest_strict(manifest) do
    case Compendium.Manifest.decode_strict(manifest) do
      {:ok, map} -> {:ok, map}
      {:error, :malformed_manifest} -> {:error, {:invalid_manifest, "manifest is not valid JSON"}}
    end
  end

  # The needs/caps blocks are digest-covered manifest vocabulary; a manifest
  # carrying a malformed block is refused at every register/publish ingress.
  # The retired setup/oauth/wasi blocks are refused outright — the frozen
  # model has no arm that could honor them, so accepting one would register
  # a component whose declared ask silently never applies.
  defp validate_manifest_capability_blocks(manifest) do
    with :ok <- reject_legacy_manifest_blocks(manifest),
         :ok <- Compendium.Manifest.Needs.validate(manifest) do
      Compendium.Manifest.Caps.validate(manifest)
    end
  end

  @legacy_manifest_blocks ~w(setup oauth wasi)

  defp reject_legacy_manifest_blocks(manifest) when is_map(manifest) do
    case Enum.filter(@legacy_manifest_blocks, &Map.has_key?(manifest, &1)) do
      [] ->
        :ok

      keys ->
        {:error,
         {:legacy_manifest_blocks,
          "Manifest declares retired block(s) #{Enum.join(keys, "/")} — declare needs/caps " <>
            "instead (see component-guide.md, \"Migrating from setup/oauth\")"}}
    end
  end

  defp reject_legacy_manifest_blocks(_manifest), do: :ok

  # ============================================================================
  # Registration Helpers
  # ============================================================================

  defp validate_register_namespace(publisher) do
    case Compendium.NamespacePolicy.require_local_register(publisher) do
      :ok -> :ok
      {:error, message} -> {:error, {:namespace_rejected, message}}
    end
  end

  # ---------------------------------------------------------------------------
  # Arca-based readers (used by `register_from_arca/3`)
  # ---------------------------------------------------------------------------

  defp read_manifest_arca(ctx, segments) do
    case Arca.get(ctx, segments ++ [ComponentPath.manifest_name()]) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} ->
            {:ok, manifest}

          {:error, _} ->
            {:error, {:invalid_manifest, "#{ComponentPath.manifest_name()} is not valid JSON"}}
        end

      {:error, :not_found} ->
        {:error, {:missing_manifest, "#{ComponentPath.manifest_name()} not found"}}

      {:error, reason} ->
        {:error, {:manifest_read_error, reason}}
    end
  end

  defp read_wasm_binary_arca(ctx, segments, component_type) do
    case Arca.get(ctx, segments ++ ["#{component_type}.wasm"]) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, :not_found} ->
        {:error, {:missing_wasm, "#{component_type}.wasm not found"}}

      {:error, reason} ->
        {:error, {:wasm_read_error, reason}}
    end
  end

  defp validate_artifact_arca(ctx, segments, "tincture") do
    case Arca.read_subtree(ctx, segments) do
      {:ok, pairs} -> Compendium.TinctureValidator.validate_from_pairs(pairs)
      {:error, reason} -> {:error, {:tincture_read_error, reason}}
    end
  end

  defp validate_artifact_arca(ctx, segments, component_type) do
    with {:ok, wasm_bytes} <- read_wasm_binary_arca(ctx, segments, component_type),
         {:ok, validation} <- Validator.validate(wasm_bytes) do
      {:ok, validation}
    end
  end

  # Infer metadata from Arca segments — the one parser
  # (`Compendium.ComponentPath.parse/1`), no Path.split, no filesystem
  # lookup. The athanor flows through `ctx` into `do_register/8`.
  defp infer_segment_metadata(segments) do
    case Compendium.ComponentPath.parse(segments) do
      {:ok, %{rest: [], type: type, publisher: publisher, name: name, version: version}} ->
        {:ok, publisher, type, name, version}

      _not_a_version_dir ->
        {:error,
         {:invalid_path,
          "expected components/{type}s/{publisher}/{name}/{version}/, got #{Enum.join(segments, "/")}"}}
    end
  end

  defp reject_tincture_publish_bytes("tincture") do
    {:error, "Tinctures cannot be published via publish_bytes. Use scaffold."}
  end

  defp reject_tincture_publish_bytes(_type), do: :ok

  @doc false
  # A published release is immutable: the same (publisher, name, version,
  # type) may never come to mean different code or different declared
  # capability. Re-publishing identical content is allowed — an OCI re-pull
  # is idempotent and legitimately refreshes signature metadata — but
  # anything else is refused.
  #
  # Deliberately compares artifact bytes AND the manifest verbatim rather
  # than the release digest: the release digest covers only the
  # security-relevant manifest subset, so a digest-keyed check would let a
  # republish silently rewrite a release's description or schema in place.
  #
  # The directory/scanner ingress does not call this. That exemption is
  # keyed on the ingress path, never on the publisher string: a local
  # rebuild legitimately produces new bytes at an unchanged version, and it
  # takes a new activation identity to say so.
  defp check_release_immutable(
         ctx,
         name,
         version,
         digest,
         manifest_json,
         publisher,
         component_type
       ) do
    case release_status(ctx, name, version, digest, manifest_json, publisher, component_type) do
      :absent ->
        :ok

      :identical ->
        :ok

      {:error, reason} ->
        # A database fault must not read as "no prior release" — that would
        # let a republish overwrite an existing version with different bytes
        # during the exact window this check exists to close.
        {:error, {:release_status_unavailable, reason}}

      :differs ->
        {:error,
         {:release_immutable,
          %{
            publisher: publisher,
            name: name,
            version: version,
            type: component_type
          }}}
    end
  end

  defp release_status(ctx, name, version, digest, manifest_json, publisher, component_type) do
    case Arca.ComponentStorage.get_component(ctx, name, version, publisher, component_type) do
      {:ok, existing} ->
        if existing.digest == digest and existing.manifest == manifest_json,
          do: :identical,
          else: :differs

      {:error, :not_found} ->
        :absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_matches?(ctx, name, version, digest, manifest_json, publisher, component_type) do
    case release_status(ctx, name, version, digest, manifest_json, publisher, component_type) do
      :identical ->
        true

      _ ->
        false
    end
  end

  defp build_metadata_from_manifest(manifest, default_type) do
    %{
      type: manifest["type"] || default_type,
      description: manifest["description"] || "",
      tags: manifest_tags(manifest),
      category: manifest["category"],
      license: manifest["license"]
    }
  end

  defp manifest_tags(manifest) do
    case manifest["tags"] do
      tags when is_list(tags) -> tags
      _ -> []
    end
  end

  # ============================================================================
  # Cleanup Helpers
  # ============================================================================

  defp cleanup_component_associations(ctx, comp) do
    component_type = Map.get(comp, :component_type, "")
    publisher = ComponentPath.normalize_publisher(Map.get(comp, :publisher))

    # Delete entire version directory (wasm, manifest, README, src/, etc.)
    # — and PROPAGATE a failure: the caller keeps the row when the bytes
    # survive, so DB and storage cannot diverge. (A missing tree is `:ok`
    # by the delete_tree contract.)
    version_dir =
      ComponentPath.version_dir(component_type, publisher, comp.name, comp.version)

    case Arca.delete_tree(ctx, version_dir) do
      :ok ->
        # Clean up empty parent directories (name, then publisher)
        name_dir = ComponentPath.name_dir(component_type, publisher, comp.name)
        maybe_remove_empty_dir(ctx, name_dir)

        publisher_dir = ComponentPath.publisher_dir(component_type, publisher)
        maybe_remove_empty_dir(ctx, publisher_dir)

        :ok

      {:error, reason} ->
        {:error, {:storage_delete_failed, reason}}
    end
  end

  @doc false
  def invalidate_executor_caches(%Context{athanor_id: athanor_id}) do
    # Every writer keys through Arca.Cache.Keys, so the sweep matches exactly
    # what was written: component metadata (Opus.Executor), resolved
    # activations (Compendium.Activation) and live shape digests
    # (Sanctum.Consent.ShapeDerivation) — all functions of this athanor's
    # registry. Compiled components are keyed by digest and need no sweep: a
    # changed component is a changed digest.
    Arca.Cache.delete_match(Arca.Cache.Keys.match_component_meta(athanor_id))
    Arca.Cache.delete_match(Arca.Cache.Keys.match_activation(athanor_id))
    Arca.Cache.delete_match(Arca.Cache.Keys.match_live_shape(athanor_id))

    Logger.debug(
      "[Compendium.Registry] Invalidated component execution caches for athanor #{athanor_id}"
    )
  end

  # List-then-delete is a real (accepted) race: a concurrent publish into
  # a just-emptied name dir can land between the empty listing and the
  # tree delete and be removed with it. The window is sub-second, needs
  # two members deleting and publishing the same component name at once,
  # only matters on the Local adapter (an object store has no directories
  # to tidy), and heals on republish — the tree is rewritten whole. An
  # atomic remove-if-empty would mean new adapter surface for that margin.
  defp maybe_remove_empty_dir(ctx, dir_path) do
    case Arca.list(ctx, dir_path) do
      {:ok, []} ->
        Arca.delete_tree(ctx, dir_path)

      _ ->
        :ok
    end
  end
end
