# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeDiff do
  @moduledoc """
  What changed between the consent an operator approved and what the
  component now asks for — the `shape_diff` a `consent_required` carries
  so the delta sheet can show a difference instead of a whole sheet.

  Granted capabilities come from the head consent's blob (the source
  node's `@ingress` edge — what the operator actually approved), live
  ones from the component's effective policy today. Each entry names a
  capability, what was granted, and what is now wanted; a capability
  that only gained entries is `:widened`, one that only lost them is
  `:narrowed`, and both is `:changed`.

  Advisory by construction: this explains a decision the §2.6 table
  already made. A derivation failure yields an empty diff, never a
  different decision.
  """

  alias Sanctum.Authority.Blob

  @egress ~w(domains methods schemes private_ips)
  @storage ~w(paths actions)

  @doc """
  Compare a head consent's granted shape against live capabilities.
  Returns a list of maps, or `[]` when either side cannot be derived.
  """
  @spec compute(Sanctum.Context.t(), String.t(), String.t()) :: [map()]
  def compute(ctx, source_ref, resolved_policy) do
    with {:ok, granted} <- granted_caps(resolved_policy, source_ref),
         {:ok, live} <- live_caps(ctx, source_ref) do
      diff_caps(granted, live)
    else
      _ -> []
    end
  end

  defp granted_caps(resolved_policy, source_ref) do
    with {:ok, blob} <- Blob.parse(resolved_policy),
         {:ok, edge} <- Blob.ingress(blob, source_ref) do
      {:ok, flatten_edge(edge)}
    end
  end

  defp live_caps(ctx, source_ref) do
    with {:ok, policy, _meta} <- Sanctum.Policy.get_effective(ctx, source_ref) do
      resources = Sanctum.Consent.BlobBuilder.resource_map(policy)

      {:ok,
       %{
         "tools" => resources["tools"] || [],
         "egress" => Map.take(resources["egress"] || %{}, @egress),
         "storage" => Map.take(resources["storage"] || %{}, @storage)
       }}
    end
  end

  defp flatten_edge(edge) do
    %{
      "tools" => edge.tools || [],
      "egress" => %{
        "domains" => get_in(edge.egress, [:domains]) || [],
        "methods" => get_in(edge.egress, [:methods]) || [],
        "schemes" => get_in(edge.egress, [:schemes]) || [],
        "private_ips" => get_in(edge.egress, [:private_ips]) || []
      },
      "storage" => %{
        "paths" => get_in(edge.storage, [:paths]) || [],
        "actions" => get_in(edge.storage, [:actions]) || []
      }
    }
  end

  defp diff_caps(granted, live) do
    tools = entry("tools", granted["tools"], live["tools"])

    egress =
      Enum.map(@egress, fn key ->
        entry("egress.#{key}", get_in(granted, ["egress", key]), get_in(live, ["egress", key]))
      end)

    storage =
      Enum.map(@storage, fn key ->
        entry("storage.#{key}", get_in(granted, ["storage", key]), get_in(live, ["storage", key]))
      end)

    ([tools] ++ egress ++ storage) |> Enum.reject(&is_nil/1)
  end

  defp entry(capability, granted, live) do
    granted = normalize(granted)
    live = normalize(live)

    added = live -- granted
    removed = granted -- live

    case {added, removed} do
      {[], []} ->
        nil

      _ ->
        %{
          capability: capability,
          change: change_kind(added, removed),
          added: added,
          removed: removed
        }
    end
  end

  defp change_kind([], _removed), do: :narrowed
  defp change_kind(_added, []), do: :widened
  defp change_kind(_added, _removed), do: :changed

  defp normalize(nil), do: []
  defp normalize(list) when is_list(list), do: list |> Enum.filter(&is_binary/1) |> Enum.sort()
  defp normalize(_), do: []
end
