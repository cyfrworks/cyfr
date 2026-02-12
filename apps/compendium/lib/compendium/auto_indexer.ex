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

  A summary map with counts:
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
      Enum.reduce(directories, {%{registered: 0, unchanged: 0, errors: 0, by_type: %{}}, []}, fn dir, {stats, disc} ->
        case Registry.register_from_directory(ctx, dir) do
          {:ok, :unchanged} ->
            case extract_name_version(dir) do
              {:ok, name, version} ->
                {%{stats | unchanged: stats.unchanged + 1}, [{name, version} | disc]}
              _ ->
                {%{stats | unchanged: stats.unchanged + 1}, disc}
            end

          {:ok, component} ->
            type_count = Map.get(stats.by_type, component.component_type, 0) + 1
            by_type = Map.put(stats.by_type, component.component_type, type_count)
            {%{stats | registered: stats.registered + 1, by_type: by_type}, [{component.name, component.version} | disc]}

          {:error, reason} ->
            Logger.warning("[AutoIndexer] Failed to register #{dir}: #{inspect(reason)}")
            {%{stats | errors: stats.errors + 1}, disc}
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

    %{
      registered: results.registered,
      unchanged: results.unchanged,
      pruned: pruned,
      errors: results.errors,
      total: total,
      elapsed_ms: elapsed
    }
  end

  # ============================================================================
  # Directory Discovery
  # ============================================================================

  defp discover_component_directories(base_dirs) do
    Enum.flat_map(base_dirs, fn base_dir ->
      Enum.flat_map(@component_types, fn type ->
        type_dir = Path.join(base_dir, "#{type}s")

        Enum.flat_map(@allowed_publishers, fn publisher ->
          publisher_dir = Path.join(type_dir, publisher)
          scan_publisher_directory(publisher_dir)
        end)
      end)
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
                |> Enum.filter(&has_manifest_and_wasm?/1)

              {:error, _} -> []
            end
          else
            []
          end
        end)

      {:error, _} -> []
    end
  end

  defp has_manifest_and_wasm?(version_dir) do
    File.dir?(version_dir) &&
      File.exists?(Path.join(version_dir, "cyfr-manifest.json")) &&
      has_any_wasm?(version_dir)
  end

  defp has_any_wasm?(dir) do
    Enum.any?(@component_types, fn type ->
      File.exists?(Path.join(dir, "#{type}.wasm"))
    end)
  end

  defp extract_name_version(directory_path) do
    parts = Path.split(directory_path)

    case Enum.split_while(parts, &(&1 != "components")) do
      {_before, ["components", _type_plural, _publisher, name, version]} ->
        {:ok, name, version}
      _ ->
        :error
    end
  end

  defp default_component_dirs do
    [Path.expand("components")]
  end
end
