# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeDerivation do
  @moduledoc """
  The one computation of a component's consent *shape* from live state.

  Both sides of the §2.6 versionless comparison call this module: consent
  time (bootstrap, and the plan verb) computes the shape it stores, and
  the loader computes the live shape to compare against. One code path is
  what makes "the release changed but the shape did not → allow and
  record" checkable at all — two implementations would drift and either
  re-consent every release (worst case) or falsely allow (unacceptable).

  Today's shape inputs are exactly what bootstrap froze: the versionless
  scope, the source ref, and the source's effective-policy tool grants
  expanded against the live tool catalog. Named needs and caps join the
  shape when manifests grow the `needs` block — that is a release-digest
  change, so it forces re-consent by itself and cannot slip past this
  comparison.
  """

  alias Sanctum.Consent.ShapeDigest
  alias Sanctum.ToolPattern

  @doc """
  The live shape digest for a source ref, or `{:error, reason}` when the
  effective policy cannot be read — the caller treats that as no live
  shape, which fails closed to `needs_consent`.
  """
  @spec live_digest(Sanctum.Context.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def live_digest(ctx, source_ref) do
    with {:ok, input} <- shape_input(ctx, source_ref) do
      ShapeDigest.compute(input)
    end
  end

  @doc "The `ShapeDigest.compute/1` input derived from live state."
  @spec shape_input(Sanctum.Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def shape_input(ctx, source_ref) do
    with {:ok, tools} <- tool_actions(ctx, source_ref) do
      {:ok, %{scope: :versionless, source_ref: source_ref, tool_actions: tools}}
    end
  end

  @doc "The source's effective tool grants, expanded against the live catalog."
  @spec tool_actions(Sanctum.Context.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def tool_actions(ctx, source_ref) do
    case Sanctum.Policy.get_effective(ctx, source_ref) do
      {:ok, policy, _meta} -> {:ok, expand_tools(policy.allowed_tools)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Expand tool patterns against the registered tool catalog. Grants are
  stored expanded: a pattern is not a stable capability, so an action
  added upstream later is correctly outside an existing consent.
  """
  @spec expand_tools([String.t()]) :: [String.t()]
  def expand_tools(patterns) when is_list(patterns) do
    ToolPattern.expand(patterns, all_tool_actions())
  end

  @doc false
  def all_tool_actions do
    for module <- Application.get_env(:cyfr, :tool_providers, []),
        tool <- module.tools(),
        {action, _annotation} <- get_in(tool, [:annotations, :actions]) || %{},
        do: "#{tool.name}.#{action}"
  end
end
