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

  The shape is manifest-sourced, always: it carries the declared needs,
  the flattened caps, the caps tools expanded against the live catalog,
  and the slot vocabulary (sorted need names). A manifest with no `needs`
  or `caps` blocks derives the empty ask — deny-all resources, no needs —
  exactly as if it declared empty blocks.

  The canonical caps encoding is dotted flat keys (`"egress.domains"`,
  `"limits.rate_limit.requests"`, …) over the digest's existing flat caps
  vocabulary — one spelling, no nesting grammar. Empty lists and absent
  limits are omitted: declaring nothing and asking for nothing are the
  same shape.
  """

  alias Compendium.Manifest.Caps
  alias Compendium.Manifest.Needs
  alias Sanctum.Consent.ShapeDigest
  alias Sanctum.ToolPattern

  @doc """
  The live shape digest for a source ref, or `{:error, reason}` when the
  shape inputs cannot be read — the caller treats that as no live shape,
  which fails closed to `needs_consent`.
  """
  # The live shape is a function of the athanor's registered manifests: it
  # is cached briefly and swept when the registry changes
  # (`Compendium.Registry.invalidate_executor_caches/1`).
  @live_cache_ttl_ms :timer.seconds(60)

  @spec live_digest(Sanctum.Context.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def live_digest(ctx, source_ref) do
    key = live_shape_key(ctx, source_ref)

    case key && Arca.Cache.get(key) do
      {:ok, digest} when is_binary(digest) ->
        {:ok, digest}

      _ ->
        with {:ok, input} <- shape_input(ctx, source_ref),
             {:ok, digest} <- ShapeDigest.compute(input) do
          if key, do: Arca.Cache.put(key, digest, @live_cache_ttl_ms)
          {:ok, digest}
        end
    end
  end

  defp live_shape_key(%Sanctum.Context{athanor_id: athanor_id}, source_ref)
       when is_binary(athanor_id) and athanor_id != "" and is_binary(source_ref),
       do: Arca.Cache.Keys.live_shape(athanor_id, source_ref)

  defp live_shape_key(_ctx, _source_ref), do: nil

  @doc "The `ShapeDigest.compute/1` input derived from live state."
  @spec shape_input(Sanctum.Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def shape_input(ctx, source_ref) do
    with {:ok, needs, caps} <- manifest_blocks(ctx, source_ref) do
      needs = needs || []
      caps = caps || Caps.from_manifest(%{"caps" => %{}})

      {:ok,
       %{
         scope: :versionless,
         source_ref: source_ref,
         needs: digest_needs(needs),
         caps: digest_caps(caps),
         tool_actions: expand_tools(caps.tools),
         slots: Enum.sort(Enum.map(needs, & &1.name))
       }}
    end
  end

  @doc """
  The declared manifest blocks for a source ref's latest release:
  `{:ok, needs, caps}` with `nil` for an absent block, or an error when
  the row cannot be read. The blocks are validated at registration, so
  `nil` from a present-but-invalid block cannot occur on a stored row.
  """
  @spec manifest_blocks(Sanctum.Context.t(), String.t()) ::
          {:ok, [map()] | nil, map() | nil} | {:error, term()}
  def manifest_blocks(ctx, source_ref) do
    with {:ok, ref} <- Sanctum.ComponentRef.parse(source_ref),
         {:ok, row} <- Compendium.Registry.get_latest(ctx, ref.name, ref.namespace, ref.type) do
      manifest = Compendium.Manifest.decode(Map.get(row, :manifest) || Map.get(row, "manifest"))
      {:ok, Needs.from_manifest(manifest), Caps.from_manifest(manifest)}
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
    # One provider roster (loaded-and-guarded) shared with the registry, so a
    # shape derived here can only name actions the registry can serve.
    for module <- Emissary.MCP.ToolRegistry.available_providers(),
        tool <- module.tools(),
        {action, _annotation} <- get_in(tool, [:annotations, :actions]) || %{},
        do: "#{tool.name}.#{action}"
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  # The digest's need rows: name/type/fields/scopes — the reason is prose
  # and required-ness surfaces on the sheet, neither is shape.
  defp digest_needs(needs) do
    Enum.map(needs, fn need ->
      %{
        name: need.name,
        type: "#{need.kind}:#{need.qualifier}",
        fields: need.fields,
        scopes: need.scopes
      }
    end)
  end

  defp digest_caps(caps) do
    %{}
    |> put_list("egress.domains", caps.egress.domains)
    |> put_list("egress.methods", caps.egress.methods)
    |> put_list("egress.schemes", caps.egress.schemes)
    |> put_list("egress.private_ips", caps.egress.private_ips)
    |> put_list("storage.paths", caps.storage.paths)
    |> put_list("storage.actions", caps.storage.actions)
    |> put_limits(caps.limits)
  end

  defp put_list(map, _key, []), do: map
  defp put_list(map, key, list), do: Map.put(map, key, list)

  defp put_limits(map, limits) do
    Enum.reduce(limits, map, fn
      {:rate_limit, %{requests: requests, window: window}}, acc ->
        acc
        |> Map.put("limits.rate_limit.requests", requests)
        |> Map.put("limits.rate_limit.window", window)

      {key, value}, acc ->
        Map.put(acc, "limits.#{key}", value)
    end)
  end
end
