# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ConsentStatus do
  @moduledoc """
  Whether the consent this estate signed still covers what the shipped
  source grants — for the AQUA soul and its roles, which are agent
  sources, and for the estate's own formulas, which a person may bring.

  The chain authority checks every in-chain call against the consent blob
  the estate froze, not against the manifest on disk. A seed upgrade that
  adds an action to `caps.tools` therefore leaves an estate consented
  against the older manifest with a policy that names the action and a
  click that is "Denied by chain authority" — silently, until someone
  re-consents. This names the gap so a page can say so.

  The sources are the component domain's facts
  (`Compendium.agent_source_refs/1`, `Compendium.local_formula_refs/1`),
  what a source declares is read through consent's own derivation
  (`Sanctum.Consent.ShapeDerivation`), and what was consented is the
  authority a turn would pin (`Crucible.authority_for/3`). A source
  that cannot be read is a typed refusal, never a silent absence: a page
  that cannot tell says so rather than showing a clean bill. The status
  grants nothing; it only reports.
  """

  alias Sanctum.Consent.ShapeDerivation
  alias Sanctum.Context

  @typedoc """
  What stands between a source and the authority a turn pins.

    * `:current` — the consented set covers what the shipped source
      declares.
    * `{:drifted, actions}` — the consent predates the source and lacks
      these actions.
    * `:stale` — the consent no longer answers for the estate's closure
      at all, which is what installing a dependency does to it: a turn is
      refused `consent_required` until a member consents again.
    * `:absent` — there is no one consent to judge: no source row, no
      default profile, a profile that needs consent or is revoked, more
      than one candidate, or a closure whose dependencies are not all
      installed. An absent consent is the bootstrap's or the setup's to
      make, not a drift.
  """
  @type state :: :current | :absent | :stale | {:drifted, [String.t()]}

  @typedoc """
  Why a state could not be read: a store that did not answer
  (`:unavailable`), a stored profile, consent or row that is damaged
  (`:corrupt`), or a context that names no estate (`:forbidden`).
  """
  @type refusal :: :unavailable | :corrupt | :forbidden

  # What the consent loader answers for a stored profile, consent or blob
  # it cannot trust, and for a release that does not re-derive from its
  # row: damage, not an outage and not an absence.
  @corrupt [
    :invalid_profile,
    :invalid_consent,
    :invalid_blob,
    :blob_digest_mismatch,
    :blob_refs_mismatch,
    :inconsistent_binding_digest,
    :integrity_alarm,
    :no_head_consent,
    :unknown_source_node,
    :missing_ingress
  ]

  @doc """
  The state of the source `ref`'s consent (`t:state/0`), or why it could
  not be read (`t:refusal/0`).
  """
  @spec state(Context.t(), String.t()) :: {:ok, state()} | {:error, refusal()}
  def state(%Context{athanor_id: athanor_id}, ref)
      when athanor_id in [nil, ""] and is_binary(ref),
      do: {:error, :forbidden}

  def state(%Context{} = ctx, ref) when is_binary(ref) do
    with {:ok, _needs, caps} <- ShapeDerivation.manifest_blocks(ctx, ref),
         {:ok, authority} <- Crucible.authority_for(ctx, :default, ref) do
      declared = ShapeDerivation.expand_tools((caps && caps.tools) || [])

      case missing(declared, consented(authority)) do
        [] -> {:ok, :current}
        actions -> {:ok, {:drifted, actions}}
      end
    else
      {:error, reason} -> classify(reason)
    end
  end

  @doc """
  Every local formula and agent whose consent no longer answers, with
  what is wrong: `{:ok, [{ref, :stale | {:drifted, actions}}]}`, formulas
  first.

  Installing a component widens the closure a consent was minted against,
  and it widens it for every source that names it. Recovery is per
  source, so the caller is told which, not just that something drifted.
  The whole answer fails on the first source that cannot be read, so an
  outage is never read as "nothing is stale".
  """
  @spec stale_refs(Context.t()) ::
          {:ok, [{String.t(), :stale | {:drifted, [String.t()]}}]} | {:error, refusal()}
  def stale_refs(%Context{} = ctx) do
    with {:ok, formulas} <- Compendium.local_formula_refs(ctx),
         {:ok, agents} <- Compendium.agent_source_refs(ctx) do
      (formulas ++ Enum.map(agents, & &1.ref))
      |> Enum.reduce_while([], fn ref, stale ->
        case state(ctx, ref) do
          {:ok, :stale} -> {:cont, [{ref, :stale} | stale]}
          {:ok, {:drifted, _} = drifted} -> {:cont, [{ref, drifted} | stale]}
          {:ok, _no_drift} -> {:cont, stale}
          {:error, _} = refused -> {:halt, refused}
        end
      end)
      |> case do
        {:error, _} = refused -> refused
        stale -> {:ok, Enum.reverse(stale)}
      end
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

  # Each answer a source's row or its authority can give, read as a state
  # or a refusal. Anything not named here is a store that did not answer.
  defp classify({:consent_required, _}), do: {:ok, :stale}

  defp classify(absent) when absent in [:not_found, :no_profile, :no_public_profile],
    do: {:ok, :absent}

  defp classify({absent, _})
       when absent in [:not_found, :profile_unavailable, :ambiguous, :setup_required],
       do: {:ok, :absent}

  defp classify(tenant) when tenant in [:no_athanor, :missing_tenant], do: {:error, :forbidden}
  defp classify(:corrupt), do: {:error, :corrupt}
  # Admission's damaged profile row or stored manifest (`Prima.Refusal`'s
  # corrupt rows).
  defp classify({:corrupt, _what}), do: {:error, :corrupt}
  defp classify({damage, _}) when damage in @corrupt, do: {:error, :corrupt}
  defp classify(_unreadable), do: {:error, :unavailable}
end
