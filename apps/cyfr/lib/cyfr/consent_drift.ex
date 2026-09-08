# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ConsentDrift do
  @moduledoc """
  Whether the consent this estate signed for the AQUA formula still covers
  what the shipped manifest grants.

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
    ref = Aqua.VirtualTools.aqua_formula()

    with {:ok, _needs, caps} <- Sanctum.Consent.ShapeDerivation.manifest_blocks(ctx, ref),
         {:ok, authority} <- Cyfr.Execution.authority_for(ctx, :default, ref) do
      declared = Sanctum.Consent.ShapeDerivation.expand_tools((caps && caps.tools) || [])
      {:ok, missing(declared, consented(authority))}
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
