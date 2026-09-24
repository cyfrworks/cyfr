# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium do
  @moduledoc """
  Component registry and lifecycle: publishing, resolution and activation of
  the four component kinds (catalyst, reagent, formula, tincture), local and
  OCI storage, manifests, dependency resolution, and the registry client for
  cyfr.run. Component references are parsed by `Prima.ComponentRef`.

  The functions below are the domain's door for callers outside it: the
  tincture rules (`Compendium.Tincture`), and the component facts the
  assistant reads — its model catalysts, its agent sources and the
  estate's own formulas. Every fact is read under the caller's context
  and names nothing it did not read; running a catalyst is not here.
  """

  alias Compendium.{AgentIndex, AquaAgent, Registry, Tincture}
  alias Sanctum.Context

  # The most rows one listing of the estate's catalysts reads.
  @catalyst_limit 1000

  @typedoc """
  One installed catalyst release: its name-level `node_key`, its full
  `ref`, its `publisher`, `name` and `version` as the row holds them, and
  the `contracts` its manifest declares.
  """
  @type catalyst :: %{
          node_key: String.t(),
          ref: String.t(),
          publisher: String.t() | nil,
          name: String.t(),
          version: String.t() | nil,
          contracts: [String.t()]
        }

  @typedoc "One agent source: its ref, its name, and whether it is the soul."
  @type agent_source :: %{ref: String.t(), name: String.t(), soul?: boolean()}

  @doc "The entry a tincture serves. See `Compendium.Tincture.entry/1`."
  @spec tincture_entry(term()) :: {:ok, String.t()} | {:error, :no_entry | :invalid_entry}
  defdelegate tincture_entry(tincture), to: Tincture, as: :entry

  @doc "A tincture version's discovered media. See `Compendium.Tincture.media/2`."
  @spec tincture_media(Context.t(), [String.t()]) ::
          %{icon: String.t() | nil, previews: [String.t()]}
  defdelegate tincture_media(ctx, version_segs), to: Tincture, as: :media

  @doc "The immutable tincture asset rules. See `Compendium.Tincture.asset_rules/0`."
  @spec tincture_asset_rules() :: Tincture.asset_rules()
  defdelegate tincture_asset_rules(), to: Tincture, as: :asset_rules

  @doc "Whether a `tincture.connect` entry is a bare domain. See `Prima.Manifest`."
  @spec valid_tincture_connect_domain?(term()) :: boolean()
  defdelegate valid_tincture_connect_domain?(domain), to: Tincture, as: :valid_connect_domain?

  @doc """
  Every installed catalyst release in the caller's estate, each with the
  contracts its manifest declares — what the assistant's model listing
  chooses from. Nothing is run.

  The caller is an authenticated context focused on an estate that may
  read its components (`:component_read`); anything else is
  `{:error, :forbidden}`. A component index behind its tree, or a store
  that cannot answer, is `{:error, :unavailable}`. An estate nobody has
  opened starts filling here, as the component listing does, and answers
  the rows that exist.
  """
  @spec model_catalysts(Context.t()) :: {:ok, [catalyst()]} | {:error, :forbidden | :unavailable}
  def model_catalysts(%Context{} = ctx) do
    with :ok <- component_reader(ctx) do
      Sanctum.Provisioning.start_provisioning(ctx)

      case Registry.search(ctx, %{type: "catalyst", limit: @catalyst_limit}) do
        {:ok, %{components: rows}} -> {:ok, Enum.map(rows, &catalyst/1)}
        {:error, _behind_or_unreadable} -> {:error, :unavailable}
      end
    end
  end

  defp component_reader(
         %Context{authenticated: true, scope: :athanor, athanor_id: athanor_id} = ctx
       )
       when is_binary(athanor_id) and athanor_id != "" do
    case Context.require_permission(ctx, :component_read) do
      :ok -> :ok
      {:error, _} -> {:error, :forbidden}
    end
  end

  defp component_reader(%Context{}), do: {:error, :forbidden}

  defp catalyst(row) do
    %{
      node_key: Prima.ComponentRow.node_key(row),
      ref: row.component_ref,
      publisher: row.publisher,
      name: row.name,
      version: row.version,
      contracts: Prima.Manifest.contracts(Prima.Manifest.decode(row.manifest))
    }
  end

  @doc """
  The estate's indexed agents as consent sources, the soul first:
  `{:ok, [%{ref, name, soul?}]}`. An index behind its tree, or a store
  that cannot answer, is `{:error, :unavailable}`; a context that names
  no estate is `{:error, :forbidden}`.
  """
  @spec agent_source_refs(Context.t()) ::
          {:ok, [agent_source()]} | {:error, :unavailable | :forbidden}
  def agent_source_refs(%Context{} = ctx) do
    case AgentIndex.list(ctx) do
      {:ok, rows} ->
        soul = AquaAgent.soul_type()

        {:ok,
         Enum.map(
           rows,
           &%{ref: Prima.AgentRef.ref(&1.name), name: &1.name, soul?: &1.kind == soul}
         )}

      {:error, :no_athanor} ->
        {:error, :forbidden}

      {:error, _behind_or_unreadable} ->
        {:error, :unavailable}
    end
  end

  @doc """
  The estate's own formulas, as the name-level refs a fill consents:
  `{:ok, ["formula:local.<name>"]}`. A store that cannot answer is
  `{:error, :unavailable}`; a context that names no estate is
  `{:error, :forbidden}`.
  """
  @spec local_formula_refs(Context.t()) ::
          {:ok, [String.t()]} | {:error, :unavailable | :forbidden}
  def local_formula_refs(%Context{} = ctx) do
    case Arca.ComponentStorage.list_components(Context.actor(ctx),
           publisher: Prima.ComponentPath.default_publisher(),
           component_type: "formula",
           limit: :none
         ) do
      {:ok, rows} ->
        {:ok,
         rows
         |> Enum.map(
           &Prima.ComponentRef.build("formula", Prima.ComponentPath.default_publisher(), &1.name)
         )
         |> Enum.uniq()}

      {:error, :no_athanor} ->
        {:error, :forbidden}

      {:error, _unreadable} ->
        {:error, :unavailable}
    end
  end
end
