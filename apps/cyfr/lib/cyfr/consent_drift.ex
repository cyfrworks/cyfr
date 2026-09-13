# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ConsentDrift do
  @moduledoc """
  Whether the consent this estate signed still covers what the shipped
  source grants — for the AQUA soul and its roles, which are agent
  sources since 3.3, and for the estate's own formulas, which a person
  may still bring.

  The chain authority checks every in-chain call against the consent blob
  the estate froze, not against the manifest on disk. A seed upgrade that
  adds an action to `caps.tools` therefore leaves an estate consented
  against the older manifest with a policy that names the action and a
  click that is "Denied by chain authority" — silently, until someone
  re-consents. This names the gap so a page can say so.
  """

  alias Sanctum.Context

  @doc """
  The tool actions the shipped manifest grants that the estate's frozen
  consent does not — `{:ok, []}` when the consent is current, `{:ok,
  missing}` when it is behind, `:unknown` when either side cannot be read
  (no formula, no default profile, no consent yet): an absent consent is
  the bootstrap's to make, not a drift.
  """
  @spec missing(Context.t()) :: {:ok, [String.t()]} | :unknown
  def missing(%Context{} = ctx) do
    case state(ctx) do
      {:drifted, actions} -> {:ok, actions}
      :ok -> {:ok, []}
      _ -> :unknown
    end
  end

  @doc """
  Every local formula or agent whose consent no longer answers, with
  what is wrong.

  Installing a component widens the closure a consent was minted against,
  and it widens it for every source that names the component. Recovery
  is per source, so the caller is told which, not just that something
  drifted.
  """
  @spec stale_refs(Context.t()) :: [{String.t(), {:drifted, [String.t()]} | :stale}]
  def stale_refs(%Context{} = ctx) do
    for ref <- local_formula_refs(ctx) ++ local_agent_refs(ctx),
        state = state(ctx, ref),
        state != :ok and state != :unknown,
        do: {ref, state}
  end

  # The estate's own formulas: what a fill consents, and what installing a
  # component can therefore invalidate.
  defp local_formula_refs(%Context{} = ctx) do
    case Arca.ComponentStorage.list_components(ctx,
           publisher: Compendium.ComponentPath.default_publisher(),
           component_type: "formula",
           limit: :none
         ) do
      {:ok, rows} -> rows |> Enum.map(&"formula:local.#{&1.name}") |> Enum.uniq()
      _ -> []
    end
  end

  defp local_agent_refs(%Context{} = ctx) do
    case Compendium.AgentIndex.list(ctx) do
      {:ok, rows} -> Enum.map(rows, &Compendium.AgentSource.ref(&1.name))
      _ -> []
    end
  end

  @doc """
  What stands between a source and the authority a turn pins. With no
  ref, the soul.

  `:ok` — the consented set covers what the shipped source declares.
  `{:drifted, actions}` — the consent predates the source and lacks these.
  `:stale` — the consent no longer answers for the estate's closure at all,
  which is what installing a dependency does to it: a turn is refused
  `consent_required` until a member consents again.
  `:unknown` — the question could not be asked (no profile yet, an
  unreadable manifest, a store that did not answer).
  """
  @spec state(Context.t()) :: :ok | {:drifted, [String.t()]} | :stale | :unknown
  def state(%Context{} = ctx), do: state(ctx, Compendium.AgentSource.soul_ref())

  @spec state(Context.t(), String.t()) :: :ok | {:drifted, [String.t()]} | :stale | :unknown
  def state(%Context{} = ctx, ref) when is_binary(ref) do
    with {:ok, _needs, caps} <- Sanctum.Consent.ShapeDerivation.manifest_blocks(ctx, ref) do
      case Cyfr.Execution.authority_for(ctx, :default, ref) do
        {:ok, authority} ->
          declared = Sanctum.Consent.ShapeDerivation.expand_tools((caps && caps.tools) || [])

          case missing(declared, consented(authority)) do
            [] -> :ok
            actions -> {:drifted, actions}
          end

        {:error, {:consent_required, _}} ->
          :stale

        _ ->
          :unknown
      end
    else
      _ -> :unknown
    end
  end

  @doc "The declared actions the consented set lacks, in the manifest's order."
  @spec missing([String.t()], [String.t()]) :: [String.t()]
  def missing(declared, consented) when is_list(declared) and is_list(consented) do
    granted = MapSet.new(consented)
    Enum.reject(declared, &MapSet.member?(granted, &1))
  end

  defp consented(%{resources: %{tools: tools}}) when is_list(tools), do: tools
  defp consented(_authority), do: []
end
