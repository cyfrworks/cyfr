# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Provenance do
  @moduledoc """
  Where a component's bytes come from, as one derived classification:

  - `:bundled` — the athanor's copy of a unit the server ships.
  - `:bundled_modified` — a shipped copy whose bytes differ from what
    ships. Only the surfaces that compare bytes answer it (`status/2`,
    `drift/2`, `Compendium.AquaTemplate.status/1`); a reset restores what
    the release ships.
  - `:user` — the athanor's own: scaffolded, built, or forked here.
  - `:remote` — pulled from a registry (`source` `"oci"`/`"published"`).

  Provenance is DERIVED, never stored: the registry row's `source` column
  answers only the ingress channel, and whether the seed ships a unit is
  the tree's answer (`Arca.Overlay.unit_status/2`). A row can cache the
  answer for display, but the tree wins.

  `shipped_versions/2` lists bundled versions for a name; `drift/2` compares
  the tenant copy with its shipped counterpart.
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
      with {:ok, status} <-
             Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), version_dir(component)) do
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
  def of_status(status) when status in [:available, :shipped], do: :bundled
  def of_status(status) when status in [:own, :absent], do: :user

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
    with {:ok, statuses} <- Arca.Overlay.unit_statuses(Sanctum.Context.actor(ctx), "components"),
         {:ok, rows} <-
           Arca.ComponentStorage.list_components(Sanctum.Context.actor(ctx), limit: :none) do
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
  One component's whole answer: its provenance, and its drift from the
  shipped bytes — `:pristine` for an unedited copy, `{:modified, diff}`
  for an edited one (whose provenance then reads `:bundled_modified`),
  `nil` where nothing shipped backs it.
  """
  @spec status(Context.t(), map()) ::
          {:ok, %{provenance: t(), drift: :pristine | {:modified, map()} | nil}}
          | {:error, term()}
  def status(%Context{} = ctx, component) do
    if Compendium.Source.remote?(Map.get(component, :source)) do
      {:ok, %{provenance: :remote, drift: nil}}
    else
      unit_dir = version_dir(component)

      case Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit_dir) do
        {:ok, :shipped} ->
          with {:ok, diff} <- Arca.Overlay.diff_unit(Sanctum.Context.actor(ctx), unit_dir) do
            case diff do
              %{added: [], removed: [], changed: []} ->
                {:ok, %{provenance: :bundled, drift: :pristine}}

              diff ->
                {:ok, %{provenance: :bundled_modified, drift: {:modified, diff}}}
            end
          end

        {:ok, :available} ->
          {:ok, %{provenance: :bundled, drift: :pristine}}

        {:ok, _own_or_absent} ->
          {:ok, %{provenance: :user, drift: nil}}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  How a bundled copy differs from what the release shipped —
  `{:ok, :pristine}` for a byte-identical copy, `{:ok, {:modified, diff}}`
  with the added/removed/changed relative paths otherwise. Any other
  provenance answers `{:error, :not_bundled}`. A thin reading of
  `status/2`.
  """
  @spec drift(Context.t(), map()) ::
          {:ok, :pristine | {:modified, map()}} | {:error, term()}
  def drift(%Context{} = ctx, component) do
    case status(ctx, component) do
      {:ok, %{drift: nil}} -> {:error, :not_bundled}
      {:ok, %{drift: drift}} -> {:ok, drift}
      {:error, _} = error -> error
    end
  end

  @doc """
  Annotate registry rows with everything the update surfaces speak, in
  one pass: `provenance`, the `shipped_versions` this release carries for
  the name, `superseded` (a strictly newer shipped version exists), and
  fork lineage — `forked_from` (read from the row's manifest, where
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
               forked_from: String.t() | nil,
               upstream_superseded: boolean()
             }
           ]}
          | {:error, term()}
  def annotate(%Context{} = ctx, rows) when is_list(rows) do
    with {:ok, statuses} <- Arca.Overlay.unit_statuses(Sanctum.Context.actor(ctx), "components"),
         {:ok, catalog} <- shipped_catalog(rows) do
      annotated =
        Enum.map(rows, fn row ->
          base =
            if remote_row?(row) do
              %{provenance: :remote, shipped_versions: [], superseded: false}
            else
              unit_status = Map.get(statuses, version_dir(row), :absent)
              shipped = Map.fetch!(catalog, {type_of(row), row.name})

              %{
                provenance: of_status(unit_status),
                shipped_versions: shipped,
                superseded: superseded?(shipped, row.version)
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
         {:ok, %Prima.ComponentRef{} = cref} <- Prima.ComponentRef.parse(forked),
         {:ok, rows} <-
           Arca.ComponentStorage.list_components(Sanctum.Context.actor(ctx),
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
    with {:ok, rows} <-
           Arca.ComponentStorage.list_components(Sanctum.Context.actor(ctx), limit: :none) do
      annotate(ctx, rows)
    end
  end

  # The release catalog for every distinct non-remote {type, name} in the
  # rows — one seed listing each, and the first listing fault fails the
  # whole annotate (a partially-lying catalog is worse than no answer).
  defp shipped_catalog(rows) do
    rows
    |> Enum.reject(&remote_row?/1)
    |> Enum.map(&{type_of(&1), &1.name})
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn {type, name}, {:ok, acc} ->
      case shipped_versions(type, name) do
        {:ok, versions} -> {:cont, {:ok, Map.put(acc, {type, name}, versions)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp remote_row?(row), do: Compendium.Source.remote?(Map.get(row, :source))

  defp type_of(row) do
    to_string(Map.get(row, :component_type) || Map.get(row, "component_type") || "")
  end

  # The fork's stamp, read through the manifest module's lenient decode —
  # the same read-side SSOT every other manifest consumer speaks, whatever
  # shape the row's manifest is on its journey (decoded map or raw JSON).
  # Lineage lives IN the manifest, deliberately: it travels with the
  # content on push and pull, and provenance stays derived, never stored.
  defp forked_from(row) do
    case Prima.Manifest.decode(Map.get(row, :manifest)) do
      %{"forked_from" => forked} when is_binary(forked) -> forked
      _ -> nil
    end
  end

  @doc """
  The versions this install's seed bundle ships for a local name — the
  release catalog, read straight from the seed tree, newest first
  (semver-descending; unparsable directory names sort last, by string).

  A seed tree that cannot be listed answers `{:error, term}`, never an
  empty catalog — "ships nothing" during an outage would read as
  `superseded: false` on every row and misroute scaffold's shipped-name
  refusal.
  """
  @spec shipped_versions(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def shipped_versions(type, name) when is_binary(type) and is_binary(name) do
    prefix =
      Arca.Storage.seed_prefix("components") ++
        [ComponentPath.type_plural(type), ComponentPath.default_publisher(), name]

    with {:ok, entries} <- Arca.list_typed(Prima.Actor.system(), prefix) do
      {:ok, sort_versions_desc(for {version, :dir} <- entries, do: version)}
    end
  end

  defp sort_versions_desc(versions), do: Compendium.Semver.sort_desc(versions)

  @wasm_types ~w(catalyst reagent formula)

  @doc """
  The release digest of the unit the seed ships at this row's path —
  the install media's artifact and manifest, not the athanor's copy.
  A version the seed does not hold is `{:error, :not_shipped}`. Cached
  under a seed-only key: a version directory is immutable.
  """
  @spec shipped_release_digest(map()) :: {:ok, String.t()} | {:error, term()}
  def shipped_release_digest(component) when is_map(component) do
    type = type_of(component)

    publisher =
      ComponentPath.normalize_publisher(
        Map.get(component, :publisher) || Map.get(component, "publisher")
      )

    name = Map.get(component, :name) || Map.get(component, "name")
    version = Map.get(component, :version) || Map.get(component, "version")

    cond do
      type not in @wasm_types ->
        {:error, :not_wasm_unit}

      not (is_binary(name) and name != "" and is_binary(version) and version != "") ->
        {:error, :invalid_row}

      true ->
        key =
          {:seed_release_digest, Application.get_env(:arca, :seed_path), type, publisher, name,
           version}

        case Arca.Cache.get(key) do
          {:ok, digest} when is_binary(digest) ->
            {:ok, digest}

          :miss ->
            with {:ok, digest} <- compute_seed_release(type, publisher, name, version) do
              Arca.Cache.put(key, digest, :timer.hours(24))
              {:ok, digest}
            end
        end
    end
  end

  defp compute_seed_release(type, publisher, name, version) do
    rel = [ComponentPath.type_plural(type), publisher, name, version]
    prefix = Arca.Storage.seed_prefix("components") ++ rel

    with {:ok, manifest} <-
           Arca.get_json(Prima.Actor.system(), prefix ++ [ComponentPath.manifest_name()]),
         {:ok, bytes} <-
           Arca.get(Prima.Actor.system(), prefix ++ [ComponentPath.wasm_name(type)]) do
      digest = Prima.Wasm.compute_digest(bytes)
      Compendium.ReleaseDigest.compute(digest, Prima.Manifest.decode(manifest))
    else
      {:error, :not_found} -> {:error, :not_shipped}
      {:error, reason} -> {:error, reason}
    end
  end

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
