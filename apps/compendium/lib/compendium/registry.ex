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

  Metadata is stored in SQLite via `Arca.ComponentStorage` (through MCP boundary).

  ## Component Lifecycle

  1. Develop components directly on the filesystem
  2. Execute via `{"local" => path}` reference
  3. Optionally register in SQLite via `publish_bytes/3` for named references
  4. Search/query components from Registry
  5. Run components by `name:version` reference

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
  alias Locus.Validator
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
  def publish_bytes(%Context{} = ctx, wasm_bytes, metadata, opts \\ []) when is_binary(wasm_bytes) and is_map(metadata) do
    allow_overwrite = Keyword.get(opts, :allow_overwrite, false)

    with {:ok, name} <- get_required(metadata, :name),
         {:ok, version} <- get_required(metadata, :version),
         {:ok, component_type} <- get_required(metadata, :type),
         :ok <- validate_name(name),
         :ok <- validate_version(version),
         {:ok, validation} <- Validator.validate(wasm_bytes),
         publisher = Map.get(metadata, :publisher, "local"),
         :ok <- validate_publish_namespace(publisher, ctx),
         :ok <- if(allow_overwrite, do: :ok, else: maybe_check_not_exists(ctx, name, version, publisher)),
         :ok <- store_wasm(ctx, component_type, publisher, name, version, wasm_bytes),
         manifest_bytes = Map.get(metadata, :manifest) || Map.get(metadata, "manifest"),
         component = build_component(ctx, name, version, metadata, validation, publisher, manifest: manifest_bytes),
         {:ok, _} <- put_component(ctx, component) do
      # Index dependencies from manifest if present in metadata
      index_dependencies(ctx, component, manifest_bytes)
      {:ok, component}
    end
  end

  @doc """
  Register a component from a directory containing a `cyfr-manifest.json` and WASM binary.

  This is a lighter operation than `publish_bytes/3` — intended for auto-indexing
  `local/` and `agent/` components from the filesystem. Components registered this
  way get `source: "filesystem"` in their metadata.

  ## Security

  Only components under `local/` or `agent/` publisher namespaces can be registered.
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
         {:ok, publisher, component_type, dir_name, dir_version} <- infer_path_metadata(directory_path),
         :ok <- validate_register_namespace(publisher),
         name = manifest["name"] || dir_name,
         version = manifest["version"] || dir_version,
         :ok <- validate_name(name),
         :ok <- validate_version(version),
         {:ok, wasm_bytes} <- read_wasm_binary(directory_path, component_type),
         {:ok, validation} <- Validator.validate(wasm_bytes) do

      # Skip if digest unchanged (unless forced)
      force = Keyword.get(opts, :force, false)
      metadata = build_metadata_from_manifest(manifest, component_type)
      if !force && digest_matches?(ctx, name, version, validation.digest, publisher, Map.fetch!(metadata, :type)) do
        {:ok, :unchanged}
      else
        component = build_component(ctx, name, version, metadata, validation, publisher,
          source: "filesystem", manifest: Jason.encode!(manifest))

        # Delete any existing rows for this name+version+publisher to avoid stale ID conflicts
        Arca.MCP.handle("component_store", ctx, %{
          "action" => "delete", "name" => name, "version" => version, "publisher" => publisher
        })

        with :ok <- store_wasm(ctx, component_type, publisher, name, version, wasm_bytes),
             :ok <- store_component_files(ctx, component_type, publisher, name, version, directory_path),
             {:ok, _} <- put_component(ctx, component) do
          # Index dependencies from the manifest
          index_dependencies(ctx, component, manifest)
          {:ok, component}
        end
      end
    end
  end

  @doc """
  Prune stale filesystem-registered entries.

  Removes SQLite rows with `source: "filesystem"` that are not in the given
  set of currently-discovered `{name, version}` tuples.
  """
  def prune_stale_entries(%Context{} = ctx, discovered_components) do
    # Get all filesystem-registered components
    args = %{"action" => "list", "source" => "filesystem", "limit" => 10_000}
    {:ok, %{components: existing}} = Arca.MCP.handle("component_store", ctx, args)

    discovered_set = MapSet.new(discovered_components)

    stale =
      Enum.filter(existing, fn comp ->
        not MapSet.member?(discovered_set, {comp.name, comp.version})
      end)

    for comp <- stale do
      Arca.MCP.handle("component_store", ctx, %{
        "action" => "delete",
        "name" => comp.name,
        "version" => comp.version
      })
    end

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

    args = %{"action" => "list", "limit" => limit}
    args = if type = filters[:type], do: Map.put(args, "component_type", type), else: args
    args = if category = filters[:category], do: Map.put(args, "category", category), else: args
    args = if query = filters[:query], do: Map.put(args, "query", query), else: args

    {:ok, %{components: results}} = Arca.MCP.handle("component_store", ctx, args)

    # Apply client-side filters not supported by SQL (tags, license)
    results =
      results
      |> decode_json_fields()
      |> Enum.map(&add_component_ref/1)
      |> filter_by_tags(filters[:tags])
      |> filter_by_license(filters[:license])
      |> Enum.take(limit)

    {:ok, %{components: results, total: length(results)}}
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
  def get(%Context{} = ctx, name, version, publisher \\ nil, component_type \\ nil) when is_binary(name) and is_binary(version) do
    if version == "latest" do
      {:error, :version_required}
    else
      args = %{"action" => "get", "name" => name, "version" => version}
      args = if publisher, do: Map.put(args, "publisher", publisher), else: args
      args = if component_type, do: Map.put(args, "component_type", component_type), else: args

      case Arca.MCP.handle("component_store", ctx, args) do
        {:ok, %{component: row}} -> {:ok, decode_row_json_fields(row)}
        {:error, :not_found} -> {:error, :not_found}
      end
    end
  end

  @doc """
  Get the most recently published version of a component by name.

  Optionally pass a publisher and component_type to disambiguate.

  Returns `{:ok, component}` or `{:error, :not_found}`.
  """
  def get_latest(%Context{} = ctx, name, publisher \\ nil, component_type \\ nil) when is_binary(name) do
    args = %{"action" => "list", "name" => name}
    args = if publisher, do: Map.put(args, "publisher", publisher), else: args
    args = if component_type, do: Map.put(args, "component_type", component_type), else: args

    case Arca.MCP.handle("component_store", ctx, args) do
      {:ok, %{components: []}} ->
        {:error, :not_found}

      {:ok, %{components: components}} ->
        latest =
          components
          |> Enum.sort_by(& &1.inserted_at, :desc)
          |> List.first()
          |> decode_row_json_fields()

        {:ok, latest}
    end
  end

  @doc """
  Get component WASM binary by digest.

  Searches for a matching component and reads its WASM file from the canonical path.
  """
  def get_blob(%Context{} = ctx, digest) when is_binary(digest) do
    # Find the component with this digest
    {:ok, %{components: components}} = Arca.MCP.handle("component_store", ctx, %{"action" => "list"})

    case Enum.find(components, &(&1.digest == digest)) do
      nil ->
        {:error, :blob_not_found}

      component ->
        publisher = Map.get(component, :publisher, "local")
        path = component_storage_path(component.component_type, publisher, component.name, component.version)

        case Arca.MCP.handle("storage", ctx, %{"action" => "read", "path" => path}) do
          {:ok, %{content: b64_content}} -> {:ok, Base.decode64!(b64_content)}
          {:error, _} -> {:error, :blob_not_found}
        end
    end
  end

  @doc """
  Delete a component from the registry.
  Removes metadata from SQLite and deletes the component directory.
  Optionally pass a publisher to disambiguate components with the same name/version.
  """
  def delete(%Context{} = ctx, name, version, publisher_filter \\ nil) when is_binary(name) and is_binary(version) do
    get_args = %{"action" => "get", "name" => name, "version" => version}
    get_args = if publisher_filter, do: Map.put(get_args, "publisher", publisher_filter), else: get_args

    case Arca.MCP.handle("component_store", ctx, get_args) do
      {:ok, %{component: component}} ->
        publisher = Map.get(component, :publisher, "local")
        path = component_storage_path(component.component_type, publisher, name, version)
        Arca.MCP.handle("storage", ctx, %{"action" => "delete", "path" => path})

        del_args = %{"action" => "delete", "name" => name, "version" => version}
        del_args = if publisher_filter, do: Map.put(del_args, "publisher", publisher_filter), else: del_args
        {:ok, _} = Arca.MCP.handle("component_store", ctx, del_args)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  List all versions of a component by name.
  """
  def list_versions(%Context{} = ctx, name) when is_binary(name) do
    {:ok, %{components: components}} = Arca.MCP.handle("component_store", ctx, %{"action" => "list", "name" => name})

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

  defp component_storage_path(type, publisher, name, version) do
    ["components", "#{type}s", publisher, name, version, "#{type}.wasm"]
  end

  defp store_wasm(ctx, type, publisher, name, version, bytes) do
    path = component_storage_path(type, publisher, name, version)

    case Arca.MCP.handle("storage", ctx, %{
      "action" => "write",
      "path" => path,
      "content" => Base.encode64(bytes)
    }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:wasm_write_failed, reason}}
    end
  end

  defp store_component_files(ctx, type, publisher, name, version, directory_path) do
    base = ["components", "#{type}s", publisher, name, version]

    # Copy cyfr-manifest.json
    manifest_src = Path.join(directory_path, "cyfr-manifest.json")
    if File.exists?(manifest_src) do
      {:ok, content} = File.read(manifest_src)
      Arca.MCP.handle("storage", ctx, %{
        "action" => "write", "path" => base ++ ["cyfr-manifest.json"],
        "content" => Base.encode64(content)
      })
    end

    # Copy README.md
    readme_src = Path.join(directory_path, "README.md")
    if File.exists?(readme_src) do
      {:ok, content} = File.read(readme_src)
      Arca.MCP.handle("storage", ctx, %{
        "action" => "write", "path" => base ++ ["README.md"],
        "content" => Base.encode64(content)
      })
    end

    # Copy src/ recursively
    src_dir = Path.join(directory_path, "src")
    if File.dir?(src_dir) do
      store_directory_recursive(ctx, base ++ ["src"], src_dir)
    end

    :ok
  end

  defp store_directory_recursive(ctx, arca_base, fs_dir) do
    case File.ls(fs_dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          full = Path.join(fs_dir, entry)
          if File.dir?(full) do
            store_directory_recursive(ctx, arca_base ++ [entry], full)
          else
            case File.read(full) do
              {:ok, content} ->
                Arca.MCP.handle("storage", ctx, %{
                  "action" => "write", "path" => arca_base ++ [entry],
                  "content" => Base.encode64(content)
                })
              _ -> :ok
            end
          end
        end)
      _ -> :ok
    end
  end

  # ============================================================================
  # Dependency Indexing
  # ============================================================================

  defp index_dependencies(_ctx, _component, nil), do: :ok

  defp index_dependencies(ctx, component, manifest) when is_binary(manifest) do
    case Jason.decode(manifest) do
      {:ok, decoded} -> index_dependencies(ctx, component, decoded)
      {:error, _} -> :ok
    end
  end

  defp index_dependencies(ctx, component, manifest) when is_map(manifest) do
    component_id = component[:id] || component["id"]

    case DependencyResolver.extract_from_manifest(manifest, component_id) do
      {:ok, []} ->
        :ok

      {:ok, deps} ->
        dep_attrs = Enum.map(deps, fn dep -> Map.new(dep, fn {k, v} -> {to_string(k), v} end) end)

        case Arca.MCP.handle("dependency_store", ctx, %{
               "action" => "put",
               "component_id" => component_id,
               "dependencies" => dep_attrs
             }) do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning("[Compendium.Registry] Failed to index dependencies for #{component_id}: #{inspect(reason)}")
            :ok
        end

      {:error, reason} ->
        Logger.warning("[Compendium.Registry] Failed to extract dependencies: #{inspect(reason)}")
        :ok
    end
  end

  # ============================================================================
  # MCP Boundary Helpers
  # ============================================================================

  # For local publisher, allow overwrite (skip check_not_exists).
  # Other publishers reject duplicates.
  defp maybe_check_not_exists(_ctx, _name, _version, publisher) when publisher in ["local", "agent"], do: :ok
  defp maybe_check_not_exists(ctx, name, version, publisher) do
    case Arca.MCP.handle("component_store", ctx, %{"action" => "exists", "name" => name, "version" => version, "publisher" => publisher}) do
      {:ok, %{exists: true}} -> {:error, {:already_exists, name, version}}
      {:ok, %{exists: false}} -> :ok
    end
  end

  defp put_component(ctx, component) do
    # Convert atom keys to string keys for MCP
    attrs = Map.new(component, fn {k, v} -> {to_string(k), v} end)
    Arca.MCP.handle("component_store", ctx, %{"action" => "put", "attrs" => attrs})
  end

  # ============================================================================
  # Index Operations
  # ============================================================================

  defp build_component(ctx, name, version, metadata, validation, publisher, opts \\ []) do
    now = DateTime.utc_now()
    component_type = Map.fetch!(metadata, :type)
    source = Keyword.get(opts, :source, "published")
    manifest = Keyword.get(opts, :manifest)

    %{
      id: generate_id(name, version, publisher, component_type),
      name: name,
      version: version,
      component_type: component_type,
      description: Map.get(metadata, :description, ""),
      tags: Jason.encode!(Map.get(metadata, :tags, [])),
      category: Map.get(metadata, :category),
      license: Map.get(metadata, :license),
      digest: validation.digest,
      size: validation.size,
      exports: Jason.encode!(validation.exports),
      manifest: manifest,
      publisher: publisher,
      publisher_id: ctx.user_id,
      org_id: ctx.org_id,
      source: source,
      inserted_at: now,
      updated_at: now
    }
  end

  defp generate_id(name, version, publisher \\ "local", component_type \\ "") do
    hash = :crypto.hash(:sha256, "#{publisher}:#{name}:#{version}:#{component_type}") |> Base.encode16(case: :lower) |> binary_part(0, 16)
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
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp add_component_ref(component) do
    type = component[:component_type]
    publisher = component[:publisher] || "local"
    name = component[:name]
    version = component[:version]

    ref = Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
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
      {:ok, list} when is_list(list) -> list
      _ -> []
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
  # "local" and "agent" are unrestricted; all other namespaces are open.
  defp validate_publish_namespace("cyfr", %Context{} = ctx) do
    if Context.has_permission?(ctx, :cyfr_publish) do
      :ok
    else
      {:error, {:namespace_reserved, "the 'cyfr' namespace is reserved for CYFR first-party components"}}
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

  @allowed_register_publishers ["local", "agent"]

  defp validate_register_namespace(publisher) when publisher in @allowed_register_publishers, do: :ok
  defp validate_register_namespace(publisher) do
    {:error, {:namespace_rejected, "only local/ and agent/ namespaces can be registered, got: #{publisher}"}}
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
        {:error, {:invalid_path, "expected components/{type}s/{publisher}/{name}/{version}/, got #{Enum.join(segments, "/")}"}}
      :error ->
        {:error, {:invalid_path, "could not find components/ in path: #{directory_path}"}}
    end
  end

  defp find_components_segments(parts) do
    case Enum.split_while(parts, &(&1 != "components")) do
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
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, {:missing_wasm, "#{component_type}.wasm not found in #{directory_path}"}}
      {:error, reason} -> {:error, {:wasm_read_error, reason}}
    end
  end

  defp digest_matches?(ctx, name, version, digest, publisher, component_type) do
    args = %{"action" => "get", "name" => name, "version" => version}
    args = if publisher, do: Map.put(args, "publisher", publisher), else: args
    args = if component_type, do: Map.put(args, "component_type", component_type), else: args

    case Arca.MCP.handle("component_store", ctx, args) do
      {:ok, %{component: existing}} -> existing.digest == digest
      {:error, _} -> false
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

end
