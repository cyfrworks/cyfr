# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AutoIndexer do
  @moduledoc """
  Batch scanner for registering local components.

  Discovers component directories containing a `cyfr-manifest.json` and
  corresponding `.wasm` file, then registers them in the Compendium registry
  with `source: "filesystem"`.

  This module does NOT auto-scan on boot. A scan is triggered when an
  athanor is provisioned (`Compendium.AthanorSeeder` registers the copies it
  just wrote), by `component.register`, and from the Components page.

  ## Security

  Only scans the `local/` publisher subdirectory. Named publisher
  directories (e.g., `cyfr/`, `stripe/`) are ignored — those must be registered
  via `publish_bytes/3` with proper identity verification.

  ## Stale Entry Pruning

  After scanning, removes registry rows with `source: "filesystem"` whose
  component directory is no longer present in storage (Local FS or S3).
  """

  require Logger

  alias Compendium.Registry

  # Guards can't call functions; pinned at compile time from the SSOT.
  @type_plurals Compendium.ComponentPath.type_plurals()
  @allowed_publishers ["local"]
  @doc """
  Scan the context's athanor's `components/` tree via
  `Arca.list_recursive/2` and register all discovered local components.

  Identical behaviour on the Local FS adapter and any configured object-store
  adapter — discovery and content reads both flow through Arca.

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
  def scan(opts) do
    start_time = System.monotonic_time(:millisecond)
    ctx = Keyword.fetch!(opts, :ctx)

    version_segment_lists = discover_component_segments(ctx)

    {results, discovered} =
      Enum.reduce(
        version_segment_lists,
        {%{registered: 0, unchanged: 0, errors: 0, by_type: %{}, components: []}, []},
        fn segs, {stats, disc} ->
          case Registry.register_from_arca(ctx, segs) do
            {:ok, :unchanged} ->
              case extract_segment_metadata(segs) do
                {:ok, name, version, type, publisher} ->
                  entry = %{name: name, version: version, type: type, status: "unchanged"}

                  {%{
                     stats
                     | unchanged: stats.unchanged + 1,
                       components: [entry | stats.components]
                   }, [{name, version, publisher} | disc]}

                _ ->
                  {%{stats | unchanged: stats.unchanged + 1}, disc}
              end

            {:ok, component} ->
              publisher =
                Compendium.ComponentPath.normalize_publisher(Map.get(component, :publisher))

              type_count = Map.get(stats.by_type, component.component_type, 0) + 1
              by_type = Map.put(stats.by_type, component.component_type, type_count)

              entry = %{
                name: component.name,
                version: component.version,
                type: component.component_type,
                status: "registered"
              }

              {%{
                 stats
                 | registered: stats.registered + 1,
                   by_type: by_type,
                   components: [entry | stats.components]
               }, [{component.name, component.version, publisher} | disc]}

            {:error, reason} ->
              Logger.warning(
                "[AutoIndexer] Failed to register #{Enum.join(segs, "/")}: #{inspect(reason)}"
              )

              case extract_segment_metadata(segs) do
                {:ok, name, version, type, publisher} ->
                  error_entry = %{
                    name: name,
                    version: version,
                    type: type,
                    status: "error",
                    error: inspect(reason)
                  }

                  {%{
                     stats
                     | errors: stats.errors + 1,
                       components: [error_entry | stats.components]
                   }, [{name, version, publisher} | disc]}

                _ ->
                  error_entry = %{
                    name: List.last(segs) || "unknown",
                    version: "unknown",
                    type: "unknown",
                    status: "error",
                    error: inspect(reason)
                  }

                  {%{
                     stats
                     | errors: stats.errors + 1,
                       components: [error_entry | stats.components]
                   }, disc}
              end
          end
        end
      )

    # Prune stale filesystem entries
    pruned = Registry.prune_stale_entries(ctx, discovered)

    elapsed = System.monotonic_time(:millisecond) - start_time
    total = results.registered + results.unchanged

    type_summary =
      results.by_type
      |> Enum.map(fn {type, count} -> "#{count} #{type}s" end)
      |> Enum.join(", ")

    if results.registered > 0 do
      Logger.info(
        "[AutoIndexer] Registered #{results.registered} components (#{type_summary}) in #{elapsed}ms"
      )
    end

    if pruned > 0 do
      Logger.info("[AutoIndexer] Pruned #{pruned} stale filesystem entries")
    end

    if results.errors > 0 do
      Logger.warning("[AutoIndexer] #{results.errors} components failed to register")
    end

    # Keep TinctureRegistry in sync after any tincture changes
    has_tincture_changes =
      (results.registered > 0 and Map.get(results.by_type, "tincture", 0) > 0) or pruned > 0

    if has_tincture_changes do
      Prism.TinctureRegistry.reload()
    end

    %{
      components: Enum.reverse(results.components),
      registered: results.registered,
      unchanged: results.unchanged,
      pruned: pruned,
      errors: results.errors,
      total: total,
      elapsed_ms: elapsed,
      scanned_dirs: [%{path: "components/", via: "Arca.list_recursive"}]
    }
  end

  # ============================================================================
  # Discovery via Arca
  # ============================================================================

  # Walk the athanor's own `components/` subtree via the configured storage
  # adapter, find every `cyfr-manifest.json`, and return the
  # version-directory segment lists.
  #
  # Each athanor indexes its own subtree — the listing is rooted in `ctx`'s
  # athanor, and `register_from_arca`/`prune_stale_entries` stay keyed on
  # `ctx`, so no scan writes another athanor's rows. The seed bundle is
  # never reached: it lives under the reserved `seed/` root, not under any
  # athanor's tree.
  defp discover_component_segments(ctx) do
    root = Compendium.ComponentPath.base_prefix()

    case Arca.list_recursive(ctx, root) do
      {:ok, leaves} ->
        leaves
        |> Enum.filter(fn segs -> List.last(segs) == "cyfr-manifest.json" end)
        # Drop the manifest filename to get the version directory.
        |> Enum.map(&Enum.drop(&1, -1))
        |> Enum.uniq()
        |> Enum.filter(&allowed_segments?/1)

      {:error, reason} ->
        Logger.warning("[AutoIndexer] Cannot list #{Enum.join(root, "/")}: #{inspect(reason)}")
        []
    end
  end

  # Layout: ["components", type_plural, publisher, name, version]
  defp allowed_segments?(["components", type_plural, publisher, _name, _version])
       when type_plural in @type_plurals do
    publisher in @allowed_publishers
  end

  defp allowed_segments?(_), do: false

  defp extract_segment_metadata([
         "components",
         type_plural,
         publisher,
         name,
         version
       ])
       when type_plural in @type_plurals do
    {:ok, name, version, String.trim_trailing(type_plural, "s"), publisher}
  end

  defp extract_segment_metadata(_), do: :error
end
