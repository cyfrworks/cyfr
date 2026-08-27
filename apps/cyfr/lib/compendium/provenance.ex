# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Provenance do
  @moduledoc """
  Where a component's bytes come from, as one derived classification:

  - `:bundled` — shipped in the seed bundle, unedited; reads come from the
    seed through the overlay, the athanor owns no bytes.
  - `:bundled_modified` — shipped, but the athanor materialized (edited)
    its copy; the copy shadows the seed until reverted.
  - `:user` — the athanor's own: scaffolded, built, or forked here.
  - `:remote` — pulled from a registry (`source` `"oci"`/`"published"`).

  Provenance is DERIVED, never stored: the registry row's `source` column
  answers only the ingress channel, and the overlay's unit state changes
  inside `Arca` the moment a write copy-on-writes — a stored flag would be
  stale by then. The tree probe (`Arca.Overlay.unit_status/2`) is the
  SSOT; a row can cache the answer for display, but the tree wins.

  This module is also the release-catalog seam the deleted
  upstream-catalog module used to be: `shipped_versions/2` answers "what
  does this install ship for that name", and `drift/2` answers "how far
  is my copy from it".
  """

  alias Compendium.ComponentPath
  alias Sanctum.Context

  @type t :: :bundled | :bundled_modified | :user | :remote

  @doc """
  Classify one registry row (an `Arca.ComponentStorage` component map).
  A storage outage answers `{:error, term}` — provenance derived from a
  tree that cannot be read is not provenance.
  """
  @spec of(Context.t(), map()) :: {:ok, t()} | {:error, term()}
  def of(%Context{} = ctx, component) do
    if Compendium.Source.remote?(Map.get(component, :source)) do
      {:ok, :remote}
    else
      with {:ok, status} <- Arca.Overlay.unit_status(ctx, version_dir(component)) do
        {:ok, of_status(status)}
      end
    end
  end

  @doc """
  The one translation from an overlay unit state to provenance — every
  surface that speaks provenance (components and aqua alike) derives its
  words here, so the two cannot drift.
  """
  @spec of_status(Arca.Overlay.unit_status()) :: t()
  def of_status(:seed), do: :bundled
  def of_status(:materialized), do: :bundled_modified
  def of_status(status) when status in [:own, :own_shadowing, :absent], do: :user

  @doc """
  The wire spelling of a provenance — the MCP boundary stringifies
  through this closed function, so a typo'd atom raises instead of
  minting a new label.
  """
  @spec label(t()) :: String.t()
  def label(provenance) when provenance in [:bundled, :bundled_modified, :user, :remote],
    do: Atom.to_string(provenance)

  @doc """
  Classify every component the athanor's registry holds, in one pass: the
  rows list once, the overlay walks twice (`Arca.Overlay.unit_statuses/2`)
  — no per-component probes. Keyed `{name, version, publisher}`.
  """
  @spec map(Context.t()) ::
          {:ok, %{{String.t(), String.t(), String.t()} => t()}} | {:error, term()}
  def map(%Context{} = ctx) do
    with {:ok, statuses} <- Arca.Overlay.unit_statuses(ctx, "components"),
         {:ok, rows} <- Arca.ComponentStorage.list_components(ctx, limit: :none) do
      {:ok,
       Map.new(rows, fn row ->
         publisher = ComponentPath.normalize_publisher(Map.get(row, :publisher))
         {{row.name, row.version, publisher}, classify_row(statuses, row)}
       end)}
    end
  end

  defp classify_row(statuses, row) do
    if Compendium.Source.remote?(Map.get(row, :source)) do
      :remote
    else
      of_status(Map.get(statuses, version_dir(row), :absent))
    end
  end

  # A strictly newer shipped version exists than the row's own — the
  # conservative predicate: an unparsable seed directory name never
  # supersedes anything (Compendium.Semver.strictly_newer?/2).
  defp superseded?([], _version), do: false
  defp superseded?([newest | _], version), do: Compendium.Semver.strictly_newer?(newest, version)

  @doc """
  One component's whole overlay answer in ONE unit probe (`diff_unit/2`
  only when the copy is materialized): its provenance, its drift from the
  shipped bytes (`:pristine` for `:bundled`, `nil` where nothing shipped
  backs it), and whether the athanor's own work is shadowing a shipped
  counterpart.
  """
  @spec status(Context.t(), map()) ::
          {:ok,
           %{
             provenance: t(),
             drift: :pristine | {:modified, map()} | nil,
             shadows_shipped: boolean()
           }}
          | {:error, term()}
  def status(%Context{} = ctx, component) do
    if Compendium.Source.remote?(Map.get(component, :source)) do
      {:ok, %{provenance: :remote, drift: nil, shadows_shipped: false}}
    else
      unit_dir = version_dir(component)

      with {:ok, unit_status} <- Arca.Overlay.unit_status(ctx, unit_dir) do
        base = %{
          provenance: of_status(unit_status),
          drift: nil,
          shadows_shipped: unit_status == :own_shadowing
        }

        case unit_status do
          :materialized ->
            case Arca.Overlay.diff_unit(ctx, unit_dir) do
              {:ok, %{added: [], removed: [], changed: []}} -> {:ok, %{base | drift: :pristine}}
              {:ok, diff} -> {:ok, %{base | drift: {:modified, diff}}}
              {:error, _} = error -> error
            end

          :seed ->
            {:ok, %{base | drift: :pristine}}

          _own_or_absent ->
            {:ok, base}
        end
      end
    end
  end

  @doc """
  How a `:bundled_modified` copy differs from what the release shipped —
  `{:ok, :pristine}` for a byte-identical copy, `{:ok, {:modified, diff}}`
  with the added/removed/changed relative paths otherwise. Any other
  provenance answers `{:error, :not_bundled_modified}`. A thin reading of
  `status/2`.
  """
  @spec drift(Context.t(), map()) ::
          {:ok, :pristine | {:modified, map()}} | {:error, term()}
  def drift(%Context{} = ctx, component) do
    case status(ctx, component) do
      {:ok, %{drift: nil}} -> {:error, :not_bundled_modified}
      {:ok, %{drift: drift}} -> {:ok, drift}
      {:error, _} = error -> error
    end
  end

  @doc """
  Annotate registry rows with everything the update surfaces speak, in
  one pass: `provenance`, the `shipped_versions` this release carries for
  the name, `superseded` (a strictly newer shipped version exists),
  `shadows_shipped` (the athanor's own unit hides a shipped counterpart),
  and fork lineage — `forked_from` (read from the row's manifest, where
  the fork stamped it) with `upstream_superseded` (a newer version of the
  fork's upstream line is known locally — the fork-side symmetry of
  `superseded`). One overlay walk, one seed listing per distinct
  non-remote name, one targeted row query per forked row (forks are
  rare).
  """
  @spec annotate(Context.t(), [map()]) ::
          {:ok,
           [
             %{
               component: map(),
               provenance: t(),
               shipped_versions: [String.t()],
               superseded: boolean(),
               shadows_shipped: boolean(),
               forked_from: String.t() | nil,
               upstream_superseded: boolean()
             }
           ]}
          | {:error, term()}
  def annotate(%Context{} = ctx, rows) when is_list(rows) do
    with {:ok, statuses} <- Arca.Overlay.unit_statuses(ctx, "components") do
      catalog =
        rows
        |> Enum.reject(&remote_row?/1)
        |> Enum.map(&{type_of(&1), &1.name})
        |> Enum.uniq()
        |> Map.new(fn {type, name} -> {{type, name}, shipped_versions(type, name)} end)

      annotated =
        Enum.map(rows, fn row ->
          base =
            if remote_row?(row) do
              %{
                provenance: :remote,
                shipped_versions: [],
                superseded: false,
                shadows_shipped: false
              }
            else
              unit_status = Map.get(statuses, version_dir(row), :absent)
              shipped = Map.fetch!(catalog, {type_of(row), row.name})

              %{
                provenance: of_status(unit_status),
                shipped_versions: shipped,
                superseded: superseded?(shipped, row.version),
                shadows_shipped: unit_status == :own_shadowing
              }
            end

          lineage =
            case upstream_status(ctx, row) do
              nil ->
                %{forked_from: nil, upstream_superseded: false}

              %{forked_from: forked, upstream_superseded: superseded} ->
                %{forked_from: forked, upstream_superseded: superseded}
            end

          %{component: row} |> Map.merge(base) |> Map.merge(lineage)
        end)

      {:ok, annotated}
    end
  end

  @doc """
  A fork's upstream line, as this install knows it: the `forked_from` ref
  the fork stamped into its manifest, the upstream versions present
  locally, and whether a strictly newer one supersedes the version the
  fork was cut from. `nil` for a row with no (parsable) lineage. Local
  knowledge only, deliberately — the same "what this install knows"
  philosophy as `shipped_versions/2`; registry search stays the discovery
  path.
  """
  @spec upstream_status(Context.t(), map()) ::
          %{
            forked_from: String.t(),
            upstream_versions: [String.t()],
            upstream_superseded: boolean()
          }
          | nil
  def upstream_status(%Context{} = ctx, component) do
    with forked when is_binary(forked) <- forked_from(component),
         {:ok, %Sanctum.ComponentRef{} = cref} <- Sanctum.ComponentRef.parse(forked),
         {:ok, rows} <-
           Arca.ComponentStorage.list_components(ctx,
             name: cref.name,
             publisher: cref.namespace,
             component_type: cref.type,
             limit: :none
           ) do
      versions = rows |> Enum.map(& &1.version) |> sort_versions_desc()

      %{
        forked_from: forked,
        upstream_versions: versions,
        upstream_superseded: is_binary(cref.version) and superseded?(versions, cref.version)
      }
    else
      _no_or_malformed_lineage -> nil
    end
  end

  @doc """
  Every registry row annotated (`annotate/2`) — the whole athanor in one
  answer, the batch surface an updates view consumes.
  """
  @spec overview(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def overview(%Context{} = ctx) do
    with {:ok, rows} <- Arca.ComponentStorage.list_components(ctx, limit: :none) do
      annotate(ctx, rows)
    end
  end

  defp remote_row?(row), do: Compendium.Source.remote?(Map.get(row, :source))

  defp type_of(row), do: to_string(Map.get(row, :component_type, ""))

  # The fork's stamp, read through the manifest module's lenient decode —
  # the same read-side SSOT every other manifest consumer speaks, whatever
  # shape the row's manifest is on its journey (decoded map or raw JSON).
  # Lineage lives IN the manifest, deliberately: it travels with the
  # content on push and pull, and provenance stays derived, never stored.
  defp forked_from(row) do
    case Compendium.Manifest.decode(Map.get(row, :manifest)) do
      %{"forked_from" => forked} when is_binary(forked) -> forked
      _ -> nil
    end
  end

  @doc """
  The versions this install's seed bundle ships for a local name — the
  release catalog, read straight from the seed tree, newest first
  (semver-descending; unparsable directory names sort last, by string).
  """
  @spec shipped_versions(String.t(), String.t()) :: [String.t()]
  def shipped_versions(type, name) when is_binary(type) and is_binary(name) do
    prefix =
      Arca.Storage.seed_prefix("components") ++
        [ComponentPath.type_plural(type), ComponentPath.default_publisher(), name]

    case Arca.list_typed(Sanctum.system_context(), prefix) do
      {:ok, entries} ->
        sort_versions_desc(for {version, :dir} <- entries, do: version)

      {:error, _} ->
        []
    end
  end

  defp sort_versions_desc(versions), do: Compendium.Semver.sort_desc(versions)

  @doc false
  @spec version_dir(map()) :: [String.t()]
  def version_dir(component) do
    ComponentPath.version_dir(
      to_string(Map.get(component, :component_type, "")),
      Map.get(component, :publisher),
      component.name,
      component.version
    )
  end
end
