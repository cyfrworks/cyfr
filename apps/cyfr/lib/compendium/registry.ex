# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry do
  @moduledoc """
  Local component registry with database-backed metadata and canonical directory layout.

  Components are stored at (project-scoped, matching the `data/` tenant layout):
  - `components/{org}/{project}/{type}s/{publisher}/{name}/{version}/{type}.wasm` - WASM binary
  - `components/{org}/{project}/{type}s/{publisher}/{name}/{version}/config.json` - Developer defaults

  The `publisher` is a flat namespace scoped to signing identity:
  - `local` — reserved for unsigned local components (default for local publish)
  - `cyfr` — CYFR first-party components
  - `alice` — community publisher

  Metadata is stored via `Arca.ComponentStorage`.

  ## Component Lifecycle

  1. Develop components directly on the filesystem
  2. Register via `cyfr register` to make them executable by canonical reference
  3. Optionally publish to SQLite via `publish_bytes/3` for named references
  4. Search/query components from Registry
  5. Run components by `type:namespace.name:version` canonical reference

  ## Reference Format

  Components are identified by `type:namespace.name:version` references:
  - `catalyst:local.my-tool:1.0.0` - Specific version in local namespace
  - `reagent:cyfr.sentiment:1.0.0` - CYFR first-party reagent
  - `formula:local.list-models:0.1.0` - Local formula

  The type prefix is required. Shorthand prefixes are accepted: `c:` (catalyst), `r:` (reagent), `f:` (formula), `t:` (tincture).

  ## Usage

      ctx = Sanctum.TestContext.local()

      # Publish raw WASM bytes directly
      {:ok, component} = Registry.publish_bytes(ctx, wasm_bytes, %{
        name: "my-tool",
        version: "1.0.0",
        type: "reagent",
        description: "My awesome tool"
      })

      # Search components
      {:ok, results} = Registry.search(ctx, %{type: "reagent"})

      # Get a specific component (name + version from namespace.name:version reference)
      {:ok, component} = Registry.get(ctx, "my-tool", "1.0.0")

      # Get component binary
      {:ok, wasm_bytes} = Registry.get_blob(ctx, "sha256:abc123...")
  """

  require Logger

  alias Sanctum.Context
  alias Compendium.WasmValidator, as: Validator
  alias Compendium.DependencyResolver
  alias Compendium.ComponentPath

  # Guards can't call functions; pinned at compile time from the SSOT.
  @type_plurals Compendium.ComponentPath.type_plurals()

  # ============================================================================
  # Canonical Hosts
  # ============================================================================

  @default_oci_host "registry.cyfr.run"
  @default_rest_host "cyfr.run"

  @doc """
  Canonical OCI Distribution host for this deployment.

  Defaults to `"registry.cyfr.run"`. Self-hosted deployments override via
  `CYFR_OCI_REGISTRY_URL` (wired in `config/runtime.exs`).
  """
  @spec canonical_host() :: String.t()
  def canonical_host,
    do: Application.get_env(:cyfr, :oci_registry_url, @default_oci_host)

  @doc """
  Canonical REST API host for this deployment (cyfr.run `/v1/*` endpoints).

  Defaults to `"cyfr.run"`. Self-hosted deployments override via
  `CYFR_REGISTRY_URL`.
  """
  @spec canonical_rest_host() :: String.t()
  def canonical_rest_host,
    do: Application.get_env(:cyfr, :registry_url, @default_rest_host)

  @doc """
  Validate that an OCI registry hostname matches the canonical host
  for this deployment. Rejects any other host with an explanatory
  error tuple.
  """
  @spec validate_host(String.t()) :: :ok | {:error, String.t()}
  def validate_host(host) do
    canonical = canonical_host()

    if host == canonical do
      :ok
    else
      {:error, "This deployment only supports #{canonical}, got: #{host}."}
    end
  end

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
         # Before store_wasm: a refused republish must leave no bytes behind
         # for the scanner to pick up.
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
         :ok <- store_wasm(ctx, component_type, publisher, name, version, wasm_bytes),
         {:ok, component} <-
           build_component(ctx, name, version, metadata, validation, publisher,
             manifest: manifest_bytes,
             manifest_map: manifest_map
           ),
         {:ok, _} <- save_component(ctx, component, allow_overwrite, name, version),
         :ok <- index_dependencies(ctx, component, manifest_bytes) do
      invalidate_executor_caches(ctx)
      {:ok, component}
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
             # Runs after validation, before any Arca write — same ordering
             # guarantee as the WASM path, where the check precedes store_wasm.
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
             end
           ),
         {:ok, component} <-
           build_component(ctx, name, version, metadata, validation, publisher,
             source: "oci",
             manifest: manifest_bytes,
             manifest_map: manifest_map
           ),
         {:ok, _} <- save_component(ctx, component, allow_overwrite, name, version),
         :ok <- index_dependencies(ctx, component, manifest_bytes) do
      invalidate_executor_caches(ctx)
      {:ok, component}
    end
  end

  @doc """
  Register a component from a directory containing a `cyfr-manifest.json` and WASM binary.

  This is a lighter operation than `publish_bytes/3` — intended for auto-indexing
  `local/` components from the filesystem. Components registered this
  way get `source: "filesystem"` in their metadata.

  ## Security

  Only components under the `local/` publisher namespace can be registered.
  Other publisher namespaces (e.g., `cyfr/`, `stripe/`) are rejected — those must
  go through `publish_bytes/3` with proper identity verification.

  ## Parameters

  - `ctx` - User context
  - `directory_path` - Absolute path to the component version directory
    (e.g., `components/catalysts/local/my-tool/0.1.0/`)
  - `opts` - Options:
    - `:force` - Re-register even if digest matches (default: false)

  ## Returns

  - `{:ok, component}` - Registered component metadata
  - `{:ok, :unchanged}` - Skipped because digest matches existing entry
  - `{:error, reason}` - Registration failed
  """
  def register_from_directory(%Context{} = ctx, directory_path, opts \\ []) do
    # Group D: explicit user-supplied filesystem path (CLI / manual register).
    # Reads manifest + validates artifact via local FS. The Arca-based variant
    # (`register_from_arca/3`) is used by the auto-indexer and works with any
    # storage adapter.
    with {:ok, manifest} <- read_manifest(directory_path),
         {:ok, publisher, component_type, dir_name, dir_version} <-
           infer_path_metadata(directory_path),
         :ok <- validate_register_namespace(publisher),
         name = manifest["name"] || dir_name,
         version = manifest["version"] || dir_version,
         :ok <- validate_name(name),
         :ok <- validate_version(version),
         :ok <- validate_manifest_capability_blocks(manifest),
         {:ok, validation} <- validate_artifact(directory_path, component_type) do
      do_register(ctx, manifest, publisher, component_type, name, version, validation, opts)
    end
  end

  @doc """
  Register a component from Arca segments (storage-adapter-agnostic).

  Used by `Compendium.AutoIndexer` after an `Arca.list_recursive/2` scan.
  Equivalent to `register_from_directory/3` but reads manifest + WASM via
  `Arca` so it works on the Local FS adapter and any configured object-store
  adapter without code changes.

  ## Parameters

  - `ctx` - User context (used by Arca for tenant scoping)
  - `segments` - Path segments for the component version directory, e.g.
    `["components", "<org_id>", "<project_id>", "catalysts", "local", "my-tool", "0.1.0"]`
  - `opts` - Same as `register_from_directory/3` (`:force`)
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
               source: "filesystem",
               manifest: manifest_json,
               manifest_map: manifest
             ) do
        Arca.ComponentStorage.delete_component(ctx, name, version, publisher, nil)

        with {:ok, _} <- put_component(ctx, component),
             :ok <- index_dependencies(ctx, component, manifest) do
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
              org_id: ctx.org_id,
              project_id: ctx.project_id,
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
      Arca.ComponentStorage.list_components(ctx, source: "filesystem", limit: 10_000)

    discovered_set = MapSet.new(discovered_components)

    stale =
      Enum.filter(existing, fn comp ->
        publisher = ComponentPath.normalize_publisher(Map.get(comp, :publisher))
        not MapSet.member?(discovered_set, {comp.name, comp.version, publisher})
      end)

    for comp <- stale do
      publisher = ComponentPath.normalize_publisher(Map.get(comp, :publisher))
      # DB-only cleanup: remove registry entry and associated grants/policies.
      # Do NOT delete filesystem files — prune is an automatic process that runs
      # during scan/register. If a component temporarily fails to be discovered
      # (mid-edit, transient error), we must not destroy user source files.
      # File deletion only happens via explicit `component.delete` (Registry.delete).
      cleanup_db_associations(ctx, comp)
      Arca.ComponentStorage.delete_component(ctx, comp.name, comp.version, publisher, nil)
    end

    # After all deletions, clean up name-level entries for components with no remaining versions
    stale
    |> Enum.uniq_by(fn comp ->
      {comp.name, ComponentPath.normalize_publisher(Map.get(comp, :publisher))}
    end)
    |> Enum.each(fn comp -> maybe_cleanup_name_level(ctx, comp) end)

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
    # A single name rarely has more than a handful of versions; the raised
    # limit just guarantees the sort sees all of them.
    opts = [name: name, limit: 10_000]
    opts = if publisher, do: Keyword.put(opts, :publisher, publisher), else: opts
    opts = if component_type, do: Keyword.put(opts, :component_type, component_type), else: opts

    case Arca.ComponentStorage.list_components(ctx, opts) do
      {:ok, []} ->
        {:error, :not_found}

      {:ok, components} ->
        latest =
          components
          |> Enum.sort(fn a, b ->
            case Version.compare(a.version, b.version) do
              :gt -> true
              :lt -> false
              :eq -> DateTime.compare(a.inserted_at, b.inserted_at) == :gt
            end
          end)
          |> List.first()

        {:ok, latest}

      {:error, reason} ->
        {:error, reason}
    end
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
          component_storage_path(
            component.component_type,
            publisher,
            component.name,
            component.version,
            ctx
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
  Delete a component from the registry.
  Removes metadata from SQLite and deletes the component directory.
  Optionally pass a publisher to disambiguate components with the same name/version.
  """
  def delete(%Context{} = ctx, name, version, publisher_filter \\ nil)
      when is_binary(name) and is_binary(version) do
    case Arca.ComponentStorage.get_component(ctx, name, version, publisher_filter, nil) do
      {:ok, component} ->
        cleanup_component_associations(ctx, component)
        Arca.ComponentStorage.delete_component(ctx, name, version, publisher_filter, nil)
        maybe_cleanup_name_level(ctx, component)
        invalidate_executor_caches(ctx)

        :telemetry.execute(
          [:cyfr, :compendium, :component, :remove],
          %{system_time: System.system_time()},
          %{
            name: name,
            version: version,
            publisher: Map.get(component, :publisher) || publisher_filter,
            component_type: Map.get(component, :component_type),
            org_id: ctx.org_id,
            project_id: ctx.project_id,
            user_id: ctx.user_id
          }
        )

        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  List all versions of a component by name.
  """
  def list_versions(%Context{} = ctx, name) when is_binary(name) do
    {:ok, components} = Arca.ComponentStorage.list_components(ctx, name: name)

    versions =
      components
      |> Enum.map(fn row ->
        %{
          "version" => row.version,
          "published_at" => row.inserted_at,
          "digest" => row.digest
        }
      end)
      |> Enum.sort_by(& &1["published_at"], :desc)

    {:ok, versions}
  end

  # ============================================================================
  # Storage Operations
  # ============================================================================

  defp component_storage_path("tincture", publisher, name, version, tenant) do
    Compendium.ComponentPath.version_dir("tincture", publisher, name, version, tenant)
  end

  defp component_storage_path(type, publisher, name, version, tenant) do
    Compendium.ComponentPath.wasm_path(type, publisher, name, version, tenant)
  end

  defp store_wasm(ctx, type, publisher, name, version, bytes) do
    # Compendium.ComponentPath raises on an unresolved org/project, the same
    # fail-closed guard Arca.Storage applies to the data/ tree.
    path = component_storage_path(type, publisher, name, version, ctx)

    case Arca.put(ctx, path, bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, {:wasm_write_failed, reason}}
    end
  end

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
      case gunzip_bounded(archive_bytes, tincture_max_decompressed_bytes()) do
        {:ok, tar_binary} ->
          case :erl_tar.extract({:binary, tar_binary}, [{:cwd, String.to_charlist(tmp_dir)}]) do
            :ok ->
              with {:ok, validation} <- Compendium.TinctureValidator.validate(tmp_dir),
                   :ok <- before_store.(validation) do
                version_dir =
                  Compendium.ComponentPath.version_dir(
                    "tincture",
                    publisher,
                    name,
                    version,
                    ctx
                  )

                case store_tincture_files(ctx, tmp_dir, tmp_dir, version_dir) do
                  :ok ->
                    {:ok, validation}

                  {:error, reason} ->
                    # A partial write must never register: the stored files
                    # would not match the component's digest. Best-effort
                    # cleanup so a retry starts from an empty version dir.
                    Arca.delete_tree(ctx, version_dir)
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

  # Streaming gzip inflate that aborts once the output exceeds `max_bytes`, so a
  # malicious archive can never materialize an unbounded binary in memory.
  defp gunzip_bounded(data, max_bytes) when is_binary(data) do
    z = :zlib.open()

    try do
      # 31 = 15 (max window) + 16 (gzip header/trailer).
      :zlib.inflateInit(z, 31)
      inflate_bounded(z, data, [], 0, max_bytes)
    rescue
      e -> {:error, Exception.message(e)}
    after
      :zlib.close(z)
    end
  end

  defp inflate_bounded(z, input, acc, total, max_bytes) do
    case :zlib.safeInflate(z, input) do
      {:continue, output} ->
        new_total = total + IO.iodata_length(output)

        if new_total > max_bytes do
          {:error, :too_large}
        else
          # Subsequent calls drain the internal buffer with [].
          inflate_bounded(z, [], [output | acc], new_total, max_bytes)
        end

      {:finished, output} ->
        new_total = total + IO.iodata_length(output)

        if new_total > max_bytes do
          {:error, :too_large}
        else
          {:ok, IO.iodata_to_binary(Enum.reverse([output | acc]))}
        end
    end
  end

  # arca:bypass-ok=D — recursively walks the tar-extract tmp dir set up by
  # `extract_and_store_tincture/5` and writes each file back through
  # `Arca.put/3`. Once this returns, no Arca content lives on local FS.
  #
  # Halts on the first failed write and returns the error: a partially
  # stored tincture must abort registration, or the registry would record a
  # healthy component whose stored files do not match its digest.
  defp store_tincture_files(ctx, base_dir, current_dir, arca_base) do
    current_dir
    |> File.ls!()
    |> Enum.reject(&(&1 in @tincture_excluded_on_pull))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      path = Path.join(current_dir, entry)

      result =
        if File.dir?(path) do
          store_tincture_files(ctx, base_dir, path, arca_base)
        else
          rel = Path.relative_to(path, base_dir)
          segments = arca_base ++ String.split(rel, "/")

          case File.read(path) do
            {:ok, content} -> Arca.put(ctx, segments, content)
            {:error, reason} -> {:error, {:tincture_read_failed, rel, reason}}
          end
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # ============================================================================
  # Dependency Indexing
  # ============================================================================

  defp index_dependencies(_ctx, _component, nil), do: :ok

  defp index_dependencies(ctx, component, manifest) when is_binary(manifest) do
    case Jason.decode(manifest) do
      {:ok, decoded} ->
        index_dependencies(ctx, component, decoded)

      {:error, err} ->
        Logger.warning(
          "[Registry] Failed to decode manifest for dependency indexing: #{inspect(err)}"
        )

        :ok
    end
  end

  defp index_dependencies(ctx, component, manifest) when is_map(manifest) do
    component_id = component[:id] || component["id"]

    case DependencyResolver.extract_from_manifest(manifest, component_id) do
      {:ok, []} ->
        :ok

      {:ok, deps} ->
        case resolve_dep_versions(ctx, deps) do
          {:ok, resolved_deps} ->
            dep_attrs =
              Enum.map(resolved_deps, fn dep ->
                Map.new(dep, fn {k, v} -> {to_string(k), v} end)
              end)

            case Arca.DependencyStorage.put_dependencies(ctx, component_id, dep_attrs) do
              {:ok, _} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "[Compendium.Registry] Failed to index dependencies for #{component_id}: #{inspect(reason)}"
                )

                {:error, {:dependency_index_failed, reason}}
            end
        end

      {:error, reason} ->
        Logger.warning("[Compendium.Registry] Failed to extract dependencies: #{inspect(reason)}")
        {:error, {:dependency_extraction_failed, reason}}
    end
  end

  defp resolve_dep_versions(ctx, deps) do
    resolved =
      Enum.map(deps, fn dep ->
        if dep.dep_version == nil do
          case Compendium.Resolver.resolve(ctx, dep.dependency_ref) do
            {:ok, resolved_ref, _metadata} ->
              {:ok, parsed} = Sanctum.ComponentRef.parse(resolved_ref)
              %{dep | dep_version: parsed.version, dependency_ref: resolved_ref}

            {:error, _reason} ->
              # Not resolvable locally — store as-is for downstream auto-pull
              Logger.debug(
                "[Compendium.Registry] Dep #{dep.dependency_ref} not resolvable locally, storing versionless"
              )

              dep
          end
        else
          dep
        end
      end)

    {:ok, resolved}
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

    if publisher == "local" do
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
    source = Keyword.get(opts, :source, "published")
    manifest = Keyword.get(opts, :manifest)

    # Every ingress converges here, so this is the one place activation
    # identity is computed. Callers pass the already-decoded manifest so the
    # digest sees exactly what validation saw.
    with {:ok, release_digest} <-
           Compendium.ReleaseDigest.compute(validation.digest, Keyword.get(opts, :manifest_map)),
         {:ok, tags_json} <- Jason.encode(Map.get(metadata, :tags, [])),
         {:ok, exports_json} <- Jason.encode(validation.exports) do
      component = %{
        id: generate_id(name, version, publisher, component_type, ctx.org_id, ctx.project_id),
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
        org_id: Arca.QueryHelpers.normalize_org_id(ctx.org_id),
        project_id: Arca.QueryHelpers.normalize_project_id(ctx.project_id),
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

  defp generate_id(name, version, publisher, component_type, org_id, project_id) do
    Compendium.ComponentId.compute(name, version, publisher, component_type, org_id, project_id)
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

  # The "cyfr" namespace is reserved for first-party components.
  # Publishing to it requires the :cyfr_publish permission.
  # "local" is unrestricted; all other namespaces are open.
  defp validate_publish_namespace("cyfr", %Context{} = ctx) do
    if Context.has_permission?(ctx, :cyfr_publish) do
      :ok
    else
      {:error,
       {:namespace_reserved, "the 'cyfr' namespace is reserved for CYFR first-party components"}}
    end
  end

  defp validate_publish_namespace(_publisher, _ctx), do: :ok

  # The `local` namespace is the highest-trust one: the scanner indexes it and
  # the seeder copies it into every new project. Remote (registry-sourced)
  # content must never mint a component there, however the ref was spelled on
  # the way in. Direct local publishes (no `:remote` origin) are unaffected —
  # they are same-machine callers, equivalent in trust to the register path.
  defp validate_publish_origin(publisher, :remote) do
    if ComponentPath.local_publisher?(publisher) do
      {:error,
       {:namespace_rejected,
        "remote content cannot be published into the 'local' namespace — " <>
          "local components are registered from the filesystem, never pulled"}}
    else
      :ok
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

  @allowed_register_publishers ["local"]

  defp validate_register_namespace(publisher) when publisher in @allowed_register_publishers,
    do: :ok

  defp validate_register_namespace(publisher) do
    {:error, {:namespace_rejected, "only local/ namespace can be registered, got: #{publisher}"}}
  end

  # arca:bypass-ok=D — filesystem read for the user-CLI `register_from_directory`
  # flow. The Arca-routed equivalent (`read_manifest_arca/2`) is below.
  defp read_manifest(directory_path) do
    manifest_path = Path.join(directory_path, "cyfr-manifest.json")

    case File.read(manifest_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, _} -> {:error, {:invalid_manifest, "cyfr-manifest.json is not valid JSON"}}
        end

      {:error, :enoent} ->
        {:error, {:missing_manifest, "cyfr-manifest.json not found in #{directory_path}"}}

      {:error, reason} ->
        {:error, {:manifest_read_error, reason}}
    end
  end

  defp infer_path_metadata(directory_path) do
    # Expected path: .../components/{org}/{project}/{type}s/{publisher}/{name}/{version}/
    parts = Path.split(directory_path)

    # Find "components" in the path and extract relative segments
    case find_components_segments(parts) do
      {:ok, [type_plural, publisher, name, version]} ->
        component_type = String.trim_trailing(type_plural, "s")
        {:ok, publisher, component_type, name, version}

      :error ->
        {:error,
         {:invalid_path,
          "expected components/{org}/{project}/{type}s/{publisher}/{name}/{version}/, " <>
            "got #{directory_path}"}}
    end
  end

  # The on-disk layout is a single fixed shape; org/project are not returned
  # here because the canonical tenant flows through `ctx` into `do_register/8`.
  defp find_components_segments(parts) do
    case Enum.split_while(parts, &(&1 != "components")) do
      {_before, ["components", _org, _project, type_plural, publisher, name, version | _]}
      when type_plural in @type_plurals ->
        {:ok, [type_plural, publisher, name, version]}

      _ ->
        :error
    end
  end

  # arca:bypass-ok=D — filesystem read for the user-CLI `register_from_directory`
  # flow. Arca-routed equivalent: `read_wasm_binary_arca/3`.
  defp read_wasm_binary(directory_path, component_type) do
    wasm_path = Path.join(directory_path, "#{component_type}.wasm")

    case File.read(wasm_path) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, :enoent} ->
        {:error, {:missing_wasm, "#{component_type}.wasm not found in #{directory_path}"}}

      {:error, reason} ->
        {:error, {:wasm_read_error, reason}}
    end
  end

  defp validate_artifact(directory_path, "tincture") do
    Compendium.TinctureValidator.validate(directory_path)
  end

  defp validate_artifact(directory_path, component_type) do
    with {:ok, wasm_bytes} <- read_wasm_binary(directory_path, component_type),
         {:ok, validation} <- Validator.validate(wasm_bytes) do
      {:ok, validation}
    end
  end

  # ---------------------------------------------------------------------------
  # Arca-based variants (used by `register_from_arca/3`)
  # ---------------------------------------------------------------------------

  defp read_manifest_arca(ctx, segments) do
    case Arca.get(ctx, segments ++ ["cyfr-manifest.json"]) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, _} -> {:error, {:invalid_manifest, "cyfr-manifest.json is not valid JSON"}}
        end

      {:error, :not_found} ->
        {:error, {:missing_manifest, "cyfr-manifest.json not found"}}

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

  # Infer metadata from Arca segments. Mirrors `infer_path_metadata/1` but
  # operates on segment lists (no Path.split, no filesystem lookup).
  #
  # Layout: ["components", org_id, project_id, "{type}s", publisher, name, version]
  # The org_id/project_id segments are informational here; the canonical tenant
  # flows through `ctx` into `do_register/8`, and the scan (`AutoIndexer`) only
  # ever passes segments whose tenant already matches `ctx`.
  defp infer_segment_metadata([
         "components",
         _org_id,
         _project_id,
         type_plural,
         publisher,
         name,
         version
       ])
       when type_plural in @type_plurals do
    component_type = String.trim_trailing(type_plural, "s")
    {:ok, publisher, component_type, name, version}
  end

  defp infer_segment_metadata(segments) do
    {:error,
     {:invalid_path,
      "expected components/{org}/{project}/{type}s/{publisher}/{name}/{version}/, got #{Enum.join(segments, "/")}"}}
  end

  defp reject_tincture_publish_bytes("tincture") do
    {:error,
     "Tinctures cannot be published via publish_bytes. Use register_from_directory or scaffold."}
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

      {:error, _} ->
        :absent
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

  defp cleanup_db_associations(ctx, comp) do
    publisher = ComponentPath.normalize_publisher(Map.get(comp, :publisher))
    component_type = Map.get(comp, :component_type, "")
    name = comp.name
    version = comp.version

    component_id =
      generate_id(name, version, publisher, component_type, ctx.org_id, ctx.project_id)

    # Delete dependencies
    Arca.DependencyStorage.delete_dependencies(ctx, component_id)

    :ok
  end

  # Called AFTER delete_component to check if the removed version was the last one.
  # If no versions remain, revokes profiles and disables registrations so
  # a future component with the same name inherits nothing.
  defp maybe_cleanup_name_level(ctx, comp) do
    publisher = ComponentPath.normalize_publisher(Map.get(comp, :publisher))

    unless Arca.ComponentStorage.has_remaining_versions?(ctx, comp.name, publisher) do
      component_type = Map.get(comp, :component_type, "")
      name_ref = "#{component_type}:#{publisher}.#{comp.name}"

      revoke_profiles(ctx, name_ref)
      disable_registrations(ctx, name_ref)

      Logger.debug(
        "[Compendium.Registry] Cleaned up name-level state for #{name_ref} (last version removed)"
      )
    end
  end

  # §3.10: removing a component revokes its profiles. Consent rows stay —
  # they are insert-only history, and the revoked profile status is the
  # live gate. Vault entries stay too: they are the operator's, and they
  # outlive any component that borrowed them.
  defp revoke_profiles(ctx, name_ref) do
    case Arca.ProfileStorage.list_for_source(ctx.org_id, ctx.project_id, name_ref) do
      {:ok, profiles} ->
        Enum.each(profiles, fn profile ->
          Arca.ProfileStorage.set_status(ctx.org_id, profile.id, "revoked")
        end)

      _ ->
        :ok
    end
  end

  # A registration outliving its target is a standing invocation channel
  # pointed at nothing — and one that would go live again the moment
  # anyone republished the name (D5).
  defp disable_registrations(ctx, name_ref) do
    disable_webhooks(ctx, name_ref)
    disable_schedules(ctx, name_ref)
  end

  defp disable_webhooks(ctx, name_ref) do
    {scope_type, org_id, project_id} = Sanctum.TenantScope.extract(ctx)

    case Arca.WebhookStorage.list_webhooks(scope_type, org_id, project_id) do
      {:ok, webhooks} ->
        webhooks
        |> Enum.filter(&targets?(&1.target_ref, name_ref))
        |> Enum.each(fn webhook ->
          Arca.WebhookStorage.set_disabled(webhook.name, scope_type, org_id, project_id)
        end)

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[Compendium.Registry] webhook cascade failed for #{name_ref}: #{Exception.message(error)}"
      )

      :ok
  end

  defp disable_schedules(ctx, name_ref) do
    ctx
    |> Arca.CronSchedule.list_by_user(limit: 1000)
    |> Enum.filter(fn schedule ->
      targets?(schedule.resolved_reference, name_ref) or
        targets?(Map.get(schedule, :reference), name_ref)
    end)
    |> Enum.each(fn schedule -> Arca.CronSchedule.soft_delete(ctx, schedule.id) end)

    :ok
  rescue
    error ->
      Logger.warning(
        "[Compendium.Registry] schedule cascade failed for #{name_ref}: #{Exception.message(error)}"
      )

      :ok
  end

  # Registrations may name a versioned or a name-level ref; both point at
  # the component that just went away.
  defp targets?(nil, _name_ref), do: false

  defp targets?(target_ref, name_ref) when is_binary(target_ref) do
    case Compendium.Activation.key_for_ref(target_ref) do
      {:ok, ^name_ref} -> true
      _ -> false
    end
  end

  defp targets?(_target_ref, _name_ref), do: false

  defp cleanup_component_associations(ctx, comp) do
    cleanup_db_associations(ctx, comp)

    component_type = Map.get(comp, :component_type, "")
    publisher = ComponentPath.normalize_publisher(Map.get(comp, :publisher))

    # Delete entire version directory (wasm, manifest, README, src/, etc.)
    version_dir =
      ComponentPath.version_dir(component_type, publisher, comp.name, comp.version, ctx)

    Arca.delete_tree(ctx, version_dir)

    # Clean up empty parent directories (name, then publisher)
    name_dir = ComponentPath.name_dir(component_type, publisher, comp.name, ctx)
    maybe_remove_empty_dir(ctx, name_dir)

    publisher_dir = ComponentPath.publisher_dir(component_type, publisher, ctx)
    maybe_remove_empty_dir(ctx, publisher_dir)

    :ok
  end

  @doc false
  def invalidate_executor_caches(%Context{} = ctx) do
    org_id = ctx.org_id
    project_id = ctx.project_id

    # :component_meta keys are written from raw ctx coordinates
    # (Opus.Executor), while :compiled_component keys are normalized by
    # Opus.ComponentCache — sweep each with the coordinates its writer uses,
    # or a nil/"" org leaves a stale compiled component serving for its TTL.
    Arca.Cache.delete_match({:component_meta, org_id, project_id, :_})

    Arca.Cache.delete_match(
      {:compiled_component, Arca.QueryHelpers.normalize_org_id(org_id),
       Arca.QueryHelpers.normalize_project_id(project_id), :_}
    )

    Logger.debug(
      "[Compendium.Registry] Invalidated component execution caches for tenant #{org_id}/#{project_id}"
    )
  end

  defp maybe_remove_empty_dir(ctx, dir_path) do
    case Arca.list(ctx, dir_path) do
      {:ok, []} ->
        Arca.delete_tree(ctx, dir_path)

      _ ->
        :ok
    end
  end
end
