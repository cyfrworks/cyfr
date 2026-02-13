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
  - `reagent:local.my-tool:latest` - Latest version (auto-resolved)
  - `catalyst:cyfr.my-tool:1.0.0` - CYFR first-party component

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
    - `:type` - Component type: catalyst, reagent, formula (optional, auto-detected)
    - `:description` - Human-readable description
    - `:tags` - List of tags for search
    - `:category` - Category name
    - `:license` - SPDX license identifier

  For `local` publisher, allows overwriting an existing version.
  Other publishers reject duplicate name:version combinations.

  ## Returns

  - `{:ok, component}` - Published component metadata
  - `{:error, reason}` - Publication failed
  """
  def publish_bytes(%Context{} = ctx, wasm_bytes, metadata) when is_binary(wasm_bytes) and is_map(metadata) do
    with {:ok, name} <- get_required(metadata, :name),
         {:ok, version} <- get_required(metadata, :version),
         :ok <- validate_name(name),
         :ok <- validate_version(version),
         {:ok, validation} <- Validator.validate(wasm_bytes),
         component_type = Map.get(metadata, :type) || to_string(validation.suggested_type),
         publisher = Map.get(metadata, :publisher, "local"),
         :ok <- maybe_check_not_exists(ctx, name, version, publisher),
         :ok <- store_wasm(ctx, component_type, publisher, name, version, wasm_bytes),
         component = build_component(ctx, name, version, metadata, validation, publisher),
         {:ok, _} <- put_component(ctx, component) do
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
      if !force && digest_matches?(ctx, name, version, validation.digest) do
        {:ok, :unchanged}
      else
        metadata = build_metadata_from_manifest(manifest, component_type)
        component = build_component(ctx, name, version, metadata, validation, publisher, source: "filesystem")

        with :ok <- store_wasm(ctx, component_type, publisher, name, version, wasm_bytes),
             {:ok, _} <- put_component(ctx, component) do
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
      |> filter_by_tags(filters[:tags])
      |> filter_by_license(filters[:license])
      |> Enum.take(limit)

    {:ok, %{components: results, total: length(results)}}
  end

  @doc """
  Get a specific component by name and version.
  Use "latest" as version to get the most recent version.

  When looking up by namespace.name:version reference, pass the name and version
  extracted by `Sanctum.ComponentRef.parse/1`. Optionally pass a publisher and
  component_type to disambiguate.
  """
  def get(%Context{} = ctx, name, version, publisher \\ nil, component_type \\ nil) when is_binary(name) and is_binary(version) do
    if version == "latest" do
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
    component_type = Map.get(metadata, :type) || to_string(validation.suggested_type)
    source = Keyword.get(opts, :source, "published")

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

  defp validate_name(name) do
    cond do
      byte_size(name) < 2 ->
        {:error, {:invalid_name, "must be at least 2 characters"}}

      byte_size(name) > 64 ->
        {:error, {:invalid_name, "must be at most 64 characters"}}

      not Regex.match?(~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/, name) ->
        {:error, {:invalid_name, "must be lowercase alphanumeric with hyphens, cannot start/end with hyphen"}}

      true ->
        :ok
    end
  end

  defp validate_version(version) do
    if Regex.match?(~r/^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?$/, version) do
      :ok
    else
      {:error, {:invalid_version, "must be valid semver (e.g., 1.0.0)"}}
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

  defp digest_matches?(ctx, name, version, digest) do
    case Arca.MCP.handle("component_store", ctx, %{"action" => "get", "name" => name, "version" => version}) do
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
