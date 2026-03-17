defmodule Compendium.Registry do
  @moduledoc """
  Local component registry with SQLite-backed metadata and canonical directory layout.

  Components are stored at:
  - `components/{type}s/{publisher}/{name}/{version}/{type}.wasm` - WASM binary
  - `components/{type}s/{publisher}/{name}/{version}/config.json` - Developer defaults

  The `publisher` is a flat namespace scoped to signing identity:
  - `local` — reserved for unsigned local components (default for local publish)
  - `cyfr` — CYFR first-party components
  - `alice` — community publisher

  Metadata is stored in SQLite via `Arca.ComponentStorage`.

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

  The type prefix is required. Shorthand prefixes are accepted: `c:` (catalyst), `r:` (reagent), `f:` (formula).

  ## Usage

      ctx = Sanctum.Context.local()

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
         {:ok, validation} <- Validator.validate(wasm_bytes),
         publisher = Map.get(metadata, :publisher, "local"),
         :ok <- validate_publish_namespace(publisher, ctx),
         :ok <- store_wasm(ctx, component_type, publisher, name, version, wasm_bytes),
         manifest_bytes = Map.get(metadata, :manifest) || Map.get(metadata, "manifest"),
         {:ok, component} <-
           build_component(ctx, name, version, metadata, validation, publisher,
             manifest: manifest_bytes
           ),
         {:ok, _} <- save_component(ctx, component, allow_overwrite, name, version),
         :ok <- index_dependencies(ctx, component, manifest_bytes) do
      invalidate_executor_caches(ctx)
      warnings = check_capability_escalation(ctx, name, version, component_type, manifest_bytes)
      {:ok, Map.put(component, :capability_warnings, warnings)}
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
    with {:ok, manifest} <- read_manifest(directory_path),
         {:ok, publisher, component_type, dir_name, dir_version} <-
           infer_path_metadata(directory_path),
         :ok <- validate_register_namespace(publisher),
         name = manifest["name"] || dir_name,
         version = manifest["version"] || dir_version,
         :ok <- validate_name(name),
         :ok <- validate_version(version),
         {:ok, wasm_bytes} <- read_wasm_binary(directory_path, component_type),
         {:ok, validation} <- Validator.validate(wasm_bytes) do
      # Skip if digest and manifest unchanged (unless forced)
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
                 manifest: manifest_json
               ) do
          # Delete any existing rows for this name+version+publisher to avoid stale ID conflicts
          Arca.ComponentStorage.delete_component(ctx, name, version, publisher, nil)

          with {:ok, _} <- put_component(ctx, component),
               :ok <- index_dependencies(ctx, component, manifest) do
            invalidate_executor_caches(ctx)
            warnings = check_capability_escalation(ctx, name, version, component_type, manifest)
            {:ok, Map.put(component, :capability_warnings, warnings)}
          end
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
        publisher = Map.get(comp, :publisher, "local")
        not MapSet.member?(discovered_set, {comp.name, comp.version, publisher})
      end)

    for comp <- stale do
      publisher = Map.get(comp, :publisher, "local")
      cleanup_component_associations(ctx, comp)
      Arca.ComponentStorage.delete_component(ctx, comp.name, comp.version, publisher, nil)
    end

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
    opts = [name: name]
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
          |> decode_row_json_fields()

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
      {:ok, component} ->
        publisher = Map.get(component, :publisher, "local")

        path =
          component_storage_path(
            component.component_type,
            publisher,
            component.name,
            component.version,
            org_id: ctx.org_id
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
        invalidate_executor_caches(ctx)
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

  defp component_storage_path(type, publisher, name, version, opts) do
    org_id = Keyword.get(opts, :org_id)
    Compendium.ComponentPath.wasm_path(type, publisher, name, version, org_id)
  end

  defp store_wasm(ctx, type, publisher, name, version, bytes) do
    path = component_storage_path(type, publisher, name, version, org_id: ctx.org_id)

    case Arca.put(ctx, path, bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, {:wasm_write_failed, reason}}
    end
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
    publisher = Map.get(component, :publisher, "local")

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

    with {:ok, tags_json} <- Jason.encode(Map.get(metadata, :tags, [])),
         {:ok, exports_json} <- Jason.encode(validation.exports) do
      {:ok,
       %{
         id: generate_id(name, version, publisher, component_type, ctx.org_id, ctx.project_id),
         name: name,
         version: version,
         component_type: component_type,
         description: Map.get(metadata, :description, ""),
         tags: tags_json,
         category: Map.get(metadata, :category),
         license: Map.get(metadata, :license),
         digest: validation.digest,
         size: validation.size,
         exports: exports_json,
         manifest: manifest,
         publisher: publisher,
         publisher_id: ctx.user_id,
         org_id: Arca.QueryHelpers.normalize_org_id(ctx.org_id),
         project_id: ctx.project_id || "default",
         source: source,
         signature_verified: Map.get(metadata, :signature_verified, false),
         signer_identity: Map.get(metadata, :signer_identity),
         signer_issuer: Map.get(metadata, :signer_issuer),
         inserted_at: now,
         updated_at: now
       }}
    else
      {:error, reason} -> {:error, {:json_encode_failed, reason}}
    end
  end

  defp generate_id(name, version, publisher, component_type, org_id, project_id) do
    org = Arca.QueryHelpers.normalize_org_id(org_id)
    proj = project_id || "default"

    hash =
      :crypto.hash(:sha256, "#{org}:#{proj}:#{publisher}:#{name}:#{version}:#{component_type}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "comp_#{hash}"
  end

  # ============================================================================
  # JSON Field Helpers
  # ============================================================================

  defp decode_json_fields(rows) when is_list(rows) do
    Enum.map(rows, &decode_row_json_fields/1)
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
    publisher = component[:publisher] || "local"
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

  # ============================================================================
  # Registration Helpers
  # ============================================================================

  @allowed_register_publishers ["local"]

  defp validate_register_namespace(publisher) when publisher in @allowed_register_publishers,
    do: :ok

  defp validate_register_namespace(publisher) do
    {:error, {:namespace_rejected, "only local/ namespace can be registered, got: #{publisher}"}}
  end

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
    # Expected path: .../components/{type}s/{publisher}/{name}/{version}/
    parts = Path.split(directory_path)

    # Find "components" in the path and extract relative segments
    case find_components_segments(parts) do
      {:ok, [type_plural, publisher, name, version]} ->
        component_type = String.trim_trailing(type_plural, "s")
        {:ok, publisher, component_type, name, version}

      {:ok, segments} ->
        {:error,
         {:invalid_path,
          "expected components/{type}s/{publisher}/{name}/{version}/, got #{Enum.join(segments, "/")}"}}

      :error ->
        {:error, {:invalid_path, "could not find components/ in path: #{directory_path}"}}
    end
  end

  defp find_components_segments(parts) do
    case Enum.split_while(parts, &(&1 != "components")) do
      {_before, ["components", maybe_org, type_plural | rest]}
      when length(rest) >= 2 and type_plural in ["catalysts", "reagents", "formulas"] ->
        # Could be Core (maybe_org is type_plural) or Arx (maybe_org is org_id).
        # If maybe_org is a known type plural, it's Core — handled by next clause.
        # Otherwise it's Arx: [org_id, type_plural, publisher, name, version]
        if maybe_org in ["catalysts", "reagents", "formulas"] do
          {:ok, Enum.take([maybe_org, type_plural | rest], 4)}
        else
          {:ok, Enum.take([type_plural | rest], 4)}
        end

      {_before, ["components" | rest]} when length(rest) >= 4 ->
        {:ok, Enum.take(rest, 4)}

      {_before, ["components" | rest]} ->
        {:ok, rest}

      _ ->
        :error
    end
  end

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

  defp content_matches?(ctx, name, version, digest, manifest_json, publisher, component_type) do
    case Arca.ComponentStorage.get_component(ctx, name, version, publisher, component_type) do
      {:ok, existing} ->
        existing.digest == digest && existing.manifest == manifest_json

      {:error, _} ->
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
    publisher = Map.get(comp, :publisher, "local")
    component_type = Map.get(comp, :component_type, "")
    name = comp.name
    version = comp.version
    component_ref = "#{component_type}:#{publisher}.#{name}:#{version}"

    component_id =
      generate_id(name, version, publisher, component_type, ctx.org_id, ctx.project_id)

    # Delete policy
    Arca.PolicyStorage.delete_policy(ctx, component_ref)

    # Delete all secret grants
    Arca.SecretStorage.delete_grants_for_component(ctx, component_ref)

    # Delete dependencies
    Arca.DependencyStorage.delete_dependencies(ctx, component_id)

    :ok
  end

  defp cleanup_component_associations(ctx, comp) do
    cleanup_db_associations(ctx, comp)

    alias Compendium.ComponentPath

    component_type = Map.get(comp, :component_type, "")
    publisher = Map.get(comp, :publisher, "local")

    # Delete entire version directory (wasm, manifest, README, src/, etc.)
    version_dir =
      ComponentPath.version_dir(component_type, publisher, comp.name, comp.version, ctx.org_id)

    Arca.delete_tree(ctx, version_dir)

    # Clean up empty parent directories (name, then publisher)
    name_dir = ComponentPath.name_dir(component_type, publisher, comp.name, ctx.org_id)
    maybe_remove_empty_dir(ctx, name_dir)

    publisher_dir = ComponentPath.publisher_dir(component_type, publisher, ctx.org_id)
    maybe_remove_empty_dir(ctx, publisher_dir)

    :ok
  end

  defp invalidate_executor_caches(%Context{} = ctx) do
    org_id = ctx.org_id || ""
    project_id = ctx.project_id || "default"
    Arca.Cache.delete_match({:component_meta, org_id, project_id, :_})
    Arca.Cache.delete_match({:compiled_component, org_id, project_id, :_})

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

  # Check if a newly registered version declares capabilities not present
  # in the previous latest version. Returns a list of new capability keys.
  defp check_capability_escalation(ctx, name, new_version, component_type, manifest_data) do
    new_setup_policy = extract_setup_policy_from_manifest(manifest_data)

    # Find the previous latest version (any version other than the one just registered)
    case Arca.ComponentStorage.list_components(ctx, name: name, component_type: component_type) do
      {:ok, components} ->
        previous =
          components
          |> Enum.reject(&(&1.version == new_version))
          |> Enum.sort(fn a, b ->
            case Version.compare(a.version, b.version) do
              :gt -> true
              :lt -> false
              :eq -> DateTime.compare(a.inserted_at, b.inserted_at) == :gt
            end
          end)
          |> List.first()

        if previous do
          old_setup_policy =
            previous
            |> decode_row_json_fields()
            |> extract_setup_policy_from_component()

          Sanctum.Policy.CapabilityDiff.diff(old_setup_policy, new_setup_policy)
        else
          []
        end

      _ ->
        []
    end
  end

  defp extract_setup_policy_from_manifest(nil), do: nil

  defp extract_setup_policy_from_manifest(manifest) when is_binary(manifest) do
    case Jason.decode(manifest) do
      {:ok, decoded} -> extract_setup_policy_from_manifest(decoded)
      _ -> nil
    end
  end

  defp extract_setup_policy_from_manifest(manifest) when is_map(manifest) do
    setup = manifest["setup"] || %{}
    setup["policy"]
  end

  defp extract_setup_policy_from_component(component) do
    manifest_raw = component[:manifest] || component["manifest"]
    extract_setup_policy_from_manifest(manifest_raw)
  end
end
