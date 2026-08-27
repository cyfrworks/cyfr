# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AutoIndexer do
  @moduledoc """
  Batch scanner for registering local components.

  Discovers component directories containing a `cyfr-manifest.json` and
  corresponding `.wasm` file, then registers them in the Compendium registry
  with `source: "filesystem"`.

  A scan is triggered when an athanor is provisioned and at every boot sync
  (`Sanctum.Provisioning` — the walk sees the seed bundle through
  `Arca.Overlay`, so bundled versions get rows without any copy), by
  `component.register`, and from the Components page.

  ## Security

  Only scans the `local/` publisher subdirectory. Named publisher
  directories (e.g., `cyfr/`, `stripe/`) are ignored — those must be registered
  via `publish_bytes/3` with proper identity verification.

  ## Stale Entry Pruning

  After scanning, removes registry rows with `source: "filesystem"` the
  walk no longer discovered. "Present" means present in the UNION: a
  bundled version directory is always discoverable through the seed, so
  bundled rows survive every prune without the athanor holding a byte —
  only a genuinely deleted local component loses its row.
  """

  require Logger

  alias Compendium.Registry

  @doc """
  Scan the context's athanor's `components/` tree via
  `Arca.list_recursive/2` and register all discovered local components.

  Identical behaviour on the Local FS adapter and any configured object-store
  adapter — discovery and content reads both flow through Arca.

  ## Returns

  `{:ok, summary}` — a map with counts and per-component details:
  - `:components` - List of per-component results (name, version, type, status)
  - `:registered` - Number of newly registered components
  - `:unchanged` - Number of components skipped (digest unchanged)
  - `:pruned` - Number of stale entries removed
  - `:errors` - Number of registration failures
  - `:total` - Total components discovered
  - `:elapsed_ms` - Time taken in milliseconds

  Or `{:error, {:discovery_failed, reason}}` when the components tree
  cannot be listed at all. A discovery outage registers nothing and —
  critically — prunes nothing: an unreadable tree is not an empty one,
  and treating it as empty would delete every filesystem-sourced row.
  """
  def scan(opts) do
    start_time = System.monotonic_time(:millisecond)
    ctx = Keyword.fetch!(opts, :ctx)

    case discover(ctx) do
      {:ok, version_segment_lists} ->
        {:ok, do_scan(ctx, version_segment_lists, start_time)}

      {:error, reason} ->
        Logger.warning(
          "[AutoIndexer] Discovery failed; nothing registered or pruned: #{inspect(reason)}"
        )

        {:error, {:discovery_failed, reason}}
    end
  end

  defp do_scan(ctx, version_segment_lists, start_time) do
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

    # Prune stale filesystem entries. A prune fault never fails the scan —
    # the registrations above already landed — but it is reported, never
    # read as "nothing was stale".
    {pruned, prune_error} =
      case Registry.prune_stale_entries(ctx, discovered) do
        {:ok, pruned} ->
          {pruned, nil}

        {:error, reason} ->
          Logger.warning("[AutoIndexer] Prune failed: #{inspect(reason)}")
          {0, reason}
      end

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

    summary = %{
      components: Enum.reverse(results.components),
      registered: results.registered,
      unchanged: results.unchanged,
      pruned: pruned,
      errors: results.errors,
      total: total,
      elapsed_ms: elapsed,
      scanned_dirs: [%{path: "components/", via: "Arca.list_recursive"}]
    }

    if prune_error, do: Map.put(summary, :prune_error, inspect(prune_error)), else: summary
  end

  # ============================================================================
  # Discovery via Arca
  # ============================================================================

  @doc """
  The manifest-bearing local version directories of the athanor's
  `components/` union, as segment lists — the BUILD plane's roster.

  Two planes, deliberately: registry rows are the INVOCATION plane (the
  Components page, consent, execution — a row exists only once an
  artifact validates), while this walk is the BUILD plane — a freshly
  scaffolded component has a manifest but no compiled artifact yet, so it
  lives here before it can ever earn a row. `scan/1` registers from this
  same walk; the build picker (`PrismWeb.BuildsLive`) lists it directly.

  Each athanor indexes its own subtree — the listing is rooted in `ctx`'s
  athanor, and `register_from_arca`/`prune_stale_entries` stay keyed on
  `ctx`, so no scan writes another athanor's rows. The walk is the seed
  UNION (`Arca.Overlay`): bundled version directories the athanor has not
  materialized are discovered — and stay discovered — so their rows
  survive every prune without a byte copied.

  A listing outage answers `{:error, term}`, never an empty roster — an
  unreadable tree read as empty would prune every filesystem row and show
  a build picker with nothing in it.
  """
  @spec discover(Sanctum.Context.t()) :: {:ok, [[String.t()]]} | {:error, term()}
  def discover(ctx) do
    root = Compendium.ComponentPath.base_prefix()

    with {:ok, leaves} <- Arca.list_recursive(ctx, root) do
      {:ok,
       leaves
       |> Compendium.ComponentPath.manifest_leaves()
       # Drop the manifest filename to get the version directory.
       |> Enum.map(&Enum.drop(&1, -1))
       |> Enum.uniq()
       |> Enum.filter(&allowed_segments?/1)}
    end
  end

  # A registrable version directory: the one parser accepts it whole, and
  # only the local namespace registers from the tree.
  defp allowed_segments?(segments) do
    case Compendium.ComponentPath.parse(segments) do
      {:ok, %{rest: [], publisher: publisher}} ->
        Compendium.ComponentPath.local_publisher?(publisher)

      _not_a_version_dir ->
        false
    end
  end

  defp extract_segment_metadata(segments) do
    case Compendium.ComponentPath.parse(segments) do
      {:ok, %{rest: [], type: type, publisher: publisher, name: name, version: version}} ->
        {:ok, name, version, type, publisher}

      _not_a_version_dir ->
        :error
    end
  end
end
