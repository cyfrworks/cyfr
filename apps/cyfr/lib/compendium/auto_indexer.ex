# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AutoIndexer do
  @moduledoc """
  Batch scanner for registering local components.

  Discovers component directories containing a `cyfr-manifest.json` and
  corresponding `.wasm` file, then registers them in the Compendium registry
  with `source: "filesystem"`.

  A scan is triggered when an athanor is provisioned and at every boot sync
  (`Compendium.Provisioning`, once the shipped bundle is copied into the
  athanor), by `component.register`, and from the Components page.

  ## Security

  Only scans the `local/` publisher subdirectory. Named publisher
  directories (e.g., `cyfr/`, `stripe/`) are ignored — those must be registered
  via `publish_bytes/3` with proper identity verification.

  ## Through the projection

  A scan is one reconciliation of the `components` root
  (`Compendium.ProjectionReconciler.reconcile/3`) naming every version
  directory the walk discovered and every unit a `filesystem` row names:
  each is derived from the tree and replaced with its acknowledgment in
  one transaction, with every other pending change of the root. A row
  whose version directory no longer holds a manifest — a unit gone from
  the athanor's tree, a shipped copy or its own — is removed, and the
  name-level cascade runs after the replacement commits.

  ## Stale Entry Pruning

  After scanning, removes registry rows with `source: "filesystem"` the
  walk no longer discovered: a version directory gone from the athanor's
  tree, a shipped copy or its own, loses its row.
  """

  require Logger

  alias Compendium.{ComponentPath, ProjectionReconciler}

  @root "components"

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
  `{:error, :projection_unavailable}` when three replacements conflicted:
  nothing was written and the changes stay pending for the next read.
  """
  def scan(opts) do
    start_time = System.monotonic_time(:millisecond)
    ctx = Keyword.fetch!(opts, :ctx)

    case discover(ctx) do
      {:ok, version_segment_lists} ->
        do_scan(ctx, version_segment_lists, start_time)

      {:error, reason} ->
        Logger.warning(
          "[AutoIndexer] Discovery failed; nothing registered or pruned: #{inspect(reason)}"
        )

        {:error, {:discovery_failed, reason}}
    end
  end

  defp do_scan(ctx, version_segment_lists, start_time) do
    discovered = Enum.map(version_segment_lists, &unit_key/1)

    # The units a filesystem row names, so a row whose directory is gone is
    # derived — as absent — and removed. A listing fault prunes nothing: the
    # discovered units still register, and the fault is reported.
    {rostered, prune_error} =
      case Arca.ComponentStorage.list_components(Sanctum.Context.actor(ctx),
             source: Compendium.Source.filesystem(),
             limit: :none
           ) do
        {:ok, rows} ->
          {for(row <- rows, do: unit_key(Compendium.Provenance.version_dir(row))), nil}

        {:error, reason} ->
          Logger.warning("[AutoIndexer] Prune skipped: #{inspect(reason)}")
          {[], reason}
      end

    units = Enum.uniq(discovered ++ rostered)

    case ProjectionReconciler.reconcile(ctx, @root, units: units) do
      {:ok, %{outcomes: outcomes, removed: removed}} ->
        {:ok, summary(version_segment_lists, outcomes, removed, prune_error, start_time)}

      {:error, reason} = error ->
        Logger.warning("[AutoIndexer] Scan not reconciled: #{inspect(reason)}")
        error
    end
  end

  defp summary(version_segment_lists, outcomes, removed, prune_error, start_time) do
    results =
      Enum.reduce(
        version_segment_lists,
        %{registered: 0, unchanged: 0, errors: 0, by_type: %{}, components: []},
        fn segs, stats ->
          count(stats, segs, Map.get(outcomes, unit_key(segs), :pending))
        end
      )

    discovered = MapSet.new(version_segment_lists, &unit_key/1)

    pruned =
      Enum.count(removed, fn row ->
        not MapSet.member?(discovered, unit_key(Compendium.Provenance.version_dir(row)))
      end)

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

    summary = %{
      components: Enum.reverse(results.components),
      registered: results.registered,
      unchanged: results.unchanged,
      pruned: pruned,
      errors: results.errors,
      total: total,
      elapsed_ms: elapsed,
      scanned_dirs: [
        %{
          path: Enum.join(ComponentPath.base_prefix(), "/") <> "/",
          via: "Arca.list_recursive"
        }
      ]
    }

    if prune_error, do: Map.put(summary, :prune_error, inspect(prune_error)), else: summary
  end

  defp count(stats, _segs, {:registered, component}) do
    type_count = Map.get(stats.by_type, component.component_type, 0) + 1

    entry = %{
      name: component.name,
      version: component.version,
      type: component.component_type,
      status: "registered"
    }

    %{
      stats
      | registered: stats.registered + 1,
        by_type: Map.put(stats.by_type, component.component_type, type_count),
        components: [entry | stats.components]
    }
  end

  defp count(stats, segs, unchanged) when unchanged in [:unchanged, {:kept, :direct}] do
    case extract_segment_metadata(segs) do
      {:ok, name, version, type, _publisher} ->
        entry = %{name: name, version: version, type: type, status: "unchanged"}
        %{stats | unchanged: stats.unchanged + 1, components: [entry | stats.components]}

      _ ->
        %{stats | unchanged: stats.unchanged + 1}
    end
  end

  defp count(stats, segs, outcome) do
    reason =
      case outcome do
        {:kept, {:error, reason}} -> reason
        {:removed, reason} -> reason
        {:kept, reason} -> reason
        :pending -> :projection_unavailable
      end

    Logger.warning("[AutoIndexer] Failed to register #{Enum.join(segs, "/")}: #{inspect(reason)}")

    error_entry =
      case extract_segment_metadata(segs) do
        {:ok, name, version, type, _publisher} ->
          %{name: name, version: version, type: type, status: "error", error: inspect(reason)}

        _ ->
          %{
            name: List.last(segs) || "unknown",
            version: "unknown",
            type: "unknown",
            status: "error",
            error: inspect(reason)
          }
      end

    %{stats | errors: stats.errors + 1, components: [error_entry | stats.components]}
  end

  defp unit_key(segments) do
    {@root, key} = Arca.Storage.UnitLocator.unit_key(segments)
    key
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
  athanor, and the reconciliation it feeds stays keyed on `ctx`, so no
  scan writes another athanor's rows. The walk is the
  athanor's own tree: the shipped copies provisioning laid, beside what
  the athanor registered itself.

  A listing outage answers `{:error, term}`, never an empty roster — an
  unreadable tree read as empty would prune every filesystem row and show
  a build picker with nothing in it.
  """
  @spec discover(Sanctum.Context.t()) :: {:ok, [[String.t()]]} | {:error, term()}
  def discover(ctx) do
    root = Compendium.ComponentPath.base_prefix()

    with {:ok, leaves} <- Arca.list_recursive(Sanctum.Context.actor(ctx), root) do
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
