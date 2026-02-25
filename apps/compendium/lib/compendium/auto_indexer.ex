defmodule Compendium.AutoIndexer do
  @moduledoc """
  Batch scanner for registering local/ and agent/ components.

  Discovers component directories containing a `cyfr-manifest.json` and
  corresponding `.wasm` file, then registers them in the Compendium registry
  with `source: "filesystem"`.

  This module does NOT auto-scan on boot. Registration is triggered manually
  via `scan/1` or the `component.register` MCP action.

  ## Security

  Only scans `local/` and `agent/` publisher subdirectories. Named publisher
  directories (e.g., `cyfr/`, `stripe/`) are ignored — those must be registered
  via `publish_bytes/3` with proper identity verification.

  ## Stale Entry Pruning

  After scanning, removes SQLite rows with `source: "filesystem"` where the
  component directory no longer exists on disk.
  """

  require Logger

  alias Compendium.Registry
  alias Sanctum.Context

  @component_types ["catalyst", "reagent", "formula"]
  @allowed_publishers ["local", "agent"]
  @doc """
  Scan component directories and register all discovered local/agent components.

  ## Parameters

  - `base_dirs` - List of base directories to scan (default: `["components"]`)

  ## Returns

  A summary map with counts and per-component details:
  - `:components` - List of per-component results (name, version, type, status)
  - `:registered` - Number of newly registered components
  - `:unchanged` - Number of components skipped (digest unchanged)
  - `:pruned` - Number of stale entries removed
  - `:errors` - Number of registration failures
  - `:total` - Total components discovered
  - `:elapsed_ms` - Time taken in milliseconds
  """
  def scan(base_dirs \\ default_component_dirs()) do
    start_time = System.monotonic_time(:millisecond)
    ctx = Context.local()

    directories = discover_component_directories(base_dirs)

    {results, discovered} =
      Enum.reduce(directories, {%{registered: 0, unchanged: 0, errors: 0, by_type: %{}, components: []}, []}, fn dir, {stats, disc} ->
        case Registry.register_from_directory(ctx, dir) do
          {:ok, :unchanged} ->
            case extract_path_metadata(dir) do
              {:ok, name, version, type} ->
                entry = %{name: name, version: version, type: type, status: "unchanged"}
                {%{stats | unchanged: stats.unchanged + 1, components: [entry | stats.components]}, [{name, version} | disc]}
              _ ->
                {%{stats | unchanged: stats.unchanged + 1}, disc}
            end

          {:ok, component} ->
            type_count = Map.get(stats.by_type, component.component_type, 0) + 1
            by_type = Map.put(stats.by_type, component.component_type, type_count)
            entry = %{name: component.name, version: component.version, type: component.component_type, status: "registered"}
            {%{stats | registered: stats.registered + 1, by_type: by_type, components: [entry | stats.components]}, [{component.name, component.version} | disc]}

          {:error, reason} ->
            Logger.warning("[AutoIndexer] Failed to register #{dir}: #{inspect(reason)}")
            error_entry = case extract_path_metadata(dir) do
              {:ok, name, version, type} -> %{name: name, version: version, type: type, status: "error", error: inspect(reason)}
              _ -> %{name: Path.basename(dir), version: "unknown", type: "unknown", status: "error", error: inspect(reason)}
            end
            {%{stats | errors: stats.errors + 1, components: [error_entry | stats.components]}, disc}
        end
      end)

    # Prune stale filesystem entries
    pruned = Registry.prune_stale_entries(ctx, discovered)

    elapsed = System.monotonic_time(:millisecond) - start_time
    total = results.registered + results.unchanged

    type_summary =
      results.by_type
      |> Enum.map(fn {type, count} -> "#{count} #{type}s" end)
      |> Enum.join(", ")

    if results.registered > 0 do
      Logger.info("[AutoIndexer] Registered #{results.registered} components (#{type_summary}) in #{elapsed}ms")
    end

    if pruned > 0 do
      Logger.info("[AutoIndexer] Pruned #{pruned} stale filesystem entries")
    end

    if results.errors > 0 do
      Logger.warning("[AutoIndexer] #{results.errors} components failed to register")
    end

    dir_info = Enum.map(base_dirs, fn dir -> %{path: dir, exists: File.dir?(dir)} end)

    %{
      components: Enum.reverse(results.components),
      registered: results.registered,
      unchanged: results.unchanged,
      pruned: pruned,
      errors: results.errors,
      total: total,
      elapsed_ms: elapsed,
      scanned_dirs: dir_info
    }
  end

  # ============================================================================
  # Directory Discovery
  # ============================================================================

  defp discover_component_directories(base_dirs) do
    Enum.flat_map(base_dirs, fn base_dir ->
      dir_exists = File.dir?(base_dir)
      Logger.info("[AutoIndexer] Scanning: #{base_dir} (exists: #{dir_exists})")

      if dir_exists do
        Enum.flat_map(@component_types, fn type ->
          type_dir = Path.join(base_dir, "#{type}s")

          Enum.flat_map(@allowed_publishers, fn publisher ->
            publisher_dir = Path.join(type_dir, publisher)
            results = scan_publisher_directory(publisher_dir)

            if results != [] do
              Logger.debug("[AutoIndexer] Found #{length(results)} component(s) in #{publisher_dir}")
            end

            results
          end)
        end)
      else
        Logger.warning("[AutoIndexer] Base directory does not exist: #{base_dir}")
        []
      end
    end)
  end

  defp scan_publisher_directory(publisher_dir) do
    case File.ls(publisher_dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          name_dir = Path.join(publisher_dir, name)

          if File.dir?(name_dir) do
            case File.ls(name_dir) do
              {:ok, versions} ->
                versions
                |> Enum.map(&Path.join(name_dir, &1))
                |> Enum.filter(&File.dir?/1)

              {:error, _} -> []
            end
          else
            []
          end
        end)

      {:error, _} -> []
    end
  end

  defp extract_path_metadata(directory_path) do
    parts = Path.split(directory_path)

    case Enum.split_while(parts, &(&1 != "components")) do
      {_before, ["components", type_plural, _publisher, name, version]} ->
        {:ok, name, version, String.trim_trailing(type_plural, "s")}
      _ ->
        :error
    end
  end

  defp default_component_dirs do
    case System.get_env("RELEASE_ROOT") do
      nil -> [Path.expand("components")]
      root -> [Path.join(root, "components")]
    end
  end
end
