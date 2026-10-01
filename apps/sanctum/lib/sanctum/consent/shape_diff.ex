# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeDiff do
  @moduledoc """
  What changed between the consent an operator approved and what the
  component now asks for — the `shape_diff` a `consent_required` carries
  so the delta sheet can show a difference instead of a whole sheet.

  Granted capabilities come from the head consent's blob (the source
  node's `@ingress` edge — what the operator actually approved, after any
  narrowing they chose), live ones from the component's ask today. Each
  entry names a capability with `added`, the values the live ask names
  that the head does not grant, and `removed`, the values the head grants
  that the ask no longer covers: a storage path the ask still admits
  (`Prima.ComponentPath.path_granted?/2`), such as a sub-folder the person
  picked inside a folder still asked for, or a host a still-asked domain
  pattern admits (`Prima.Network.domain_allowed?/2`), is not among them.
  `added` is not only what the component newly asks for: a value the
  person narrowed away is in it too, since the head does not grant it, so
  a renderer words it as "asks for what your grant does not give", never
  as the component widening. A capability
  with only `added` values is `:widened`, one with only `removed` values
  `:narrowed`, and both is `:changed`, each read against the head as
  narrowed.

  Explains the loader's decision without changing it. A derivation failure
  returns an empty diff.
  """

  alias Prima.Authority.Blob

  require Logger

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
    with {:ok, component} <- Sanctum.Consent.Plan.fetch_component(ctx, source_ref),
         manifest = manifest(component, source_ref),
         {:ok, resources, _limits} <-
           Sanctum.Consent.BlobBuilder.node_grant(ctx, source_ref, manifest) do
      {:ok,
       %{
         "tools" => resources["tools"] || [],
         "egress" => Map.take(resources["egress"] || %{}, @egress),
         "storage" => Map.take(resources["storage"] || %{}, @storage)
       }
       |> Map.merge(policy_caps(manifest))}
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

    policy =
      Enum.map(~w(policy.auto policy.ask), fn key ->
        entry(key, granted[key], live[key])
      end)

    ([tools] ++ egress ++ storage ++ policy) |> Enum.reject(&is_nil/1)
  end

  defp policy_caps(%{"agent" => %{"policy" => policy}}) when is_map(policy) do
    %{
      "policy.auto" => policy["auto"] || [],
      "policy.ask" => policy["ask"] || []
    }
  end

  defp policy_caps(_), do: %{}

  defp entry(capability, granted, live) do
    granted = normalize(granted)
    live = normalize(live)

    added = live -- granted
    removed = Enum.reject(granted -- live, &covered?(capability, &1, live))

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

  # Whether the live ask still covers a value the head grants, as the
  # value's enforcement point reads the ask: a path a picker chose inside a
  # folder the ask still names, or a host inside a domain pattern it still
  # names, is no value the component stopped asking for.
  defp covered?("storage.paths", path, live), do: Prima.ComponentPath.path_granted?(path, live)
  defp covered?("egress.domains", host, live), do: Prima.Network.domain_allowed?(host, live)
  defp covered?(_capability, _value, _live), do: false

  defp change_kind([], _removed), do: :narrowed
  defp change_kind(_added, []), do: :widened
  defp change_kind(_added, _removed), do: :changed

  defp normalize(nil), do: []
  defp normalize(list) when is_list(list), do: list |> Enum.filter(&is_binary/1) |> Enum.sort()
  defp normalize(_), do: []

  # A manifest that does not decode declares nothing. The line names the
  # component, never the manifest's bytes.
  defp manifest(row, ref) do
    case Prima.Manifest.decode_strict(Map.get(row, :manifest) || Map.get(row, "manifest")) do
      {:ok, manifest} ->
        manifest

      {:error, :malformed_manifest} ->
        Logger.warning("[Sanctum.Consent.ShapeDiff] manifest malformed: #{ref}")
        %{}
    end
  end
end
