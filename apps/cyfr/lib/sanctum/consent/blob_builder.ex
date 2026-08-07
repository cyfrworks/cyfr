# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.BlobBuilder do
  @moduledoc """
  Builds the resolved-policy blob for a consent revision from an
  activation graph — shared by bootstrap (machine-minted revisions from
  legacy effective policy) and the commit verb (operator-decided
  revisions). One builder is what keeps the two indistinguishable to the
  loader: a blob is a blob, whoever minted it.

  Every edge A → B carries B's own effective resources — exactly what the
  callee-keyed model grants B today, which is what makes these revisions
  legacy-equivalent. The caller supplies a `vault_fn` deciding which vault
  resource (if any) rides each node; bootstrap mints legacy pointers,
  commit binds the operator's chosen entries.
  """

  alias Sanctum.JCS

  @type vault_fn ::
          (node_key :: String.t(), row :: map(), manifest :: map() -> map() | nil)

  @doc """
  Build the node map for a blob. `graph` is the activation graph
  (node ref → release digest); `source_ref` gets the `@ingress` edge.
  `opts[:ingress_extras]` merges extra resources (tool-server grants)
  into that edge alone.
  """
  @spec build(Sanctum.Context.t(), map(), String.t(), vault_fn(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build(ctx, graph, source_ref, vault_fn, opts \\ []) do
    extras = Keyword.get(opts, :ingress_extras, %{})

    Enum.reduce_while(Map.keys(graph), {:ok, %{}}, fn node_key, {:ok, acc} ->
      case build_node(ctx, node_key, source_ref, vault_fn, extras) do
        {:ok, node} -> {:cont, {:ok, Map.put(acc, node_key, node)}}
        {:error, reason} -> {:halt, {:error, {node_key, reason}}}
      end
    end)
  end

  @doc "Assemble and JCS-encode the final blob from built nodes."
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(nodes) do
    encoded_nodes =
      Map.new(nodes, fn {node_key, node} ->
        edges =
          Map.new(node.edges, fn
            {"@ingress", resources} ->
              {"@ingress", finalize_edge(resources)}

            {dep_key, %{"__dep__" => dep_key}} ->
              {dep_key, finalize_edge(nodes[dep_key].resources)}
          end)

        {node_key, %{"limits" => node.limits, "edges" => edges}}
      end)

    JCS.encode(%{"canonical" => "jcs-1", "nodes" => encoded_nodes})
  end

  @doc "The derived vault references for `consent_vault_refs`, deduplicated."
  @spec vault_refs(map()) :: [%{vault_entry_id: String.t(), binding_digest: String.t()}]
  def vault_refs(nodes) do
    for {_key, node} <- nodes,
        vault = node.resources["__vault__"],
        vault != nil,
        uniq: true do
      %{vault_entry_id: vault["entry_id"], binding_digest: vault["binding_digest"]}
    end
  end

  @doc "A node's blob resources from its legacy effective policy."
  @spec resource_map(Sanctum.Policy.t()) :: map()
  def resource_map(policy) do
    %{
      "egress" => %{
        "domains" => policy.allowed_domains,
        "methods" => policy.allowed_methods,
        "schemes" => ["https", "http"],
        "private_ips" => policy.allowed_private_ips
      },
      "storage" => %{
        "paths" => policy.allowed_paths,
        "actions" => policy.allowed_actions
      },
      "tools" => Sanctum.Consent.ShapeDerivation.expand_tools(policy.allowed_tools)
    }
  end

  @doc "A node's blob limits from its legacy effective policy."
  @spec limits_map(Sanctum.Policy.t()) :: map()
  def limits_map(policy) do
    %{
      "timeout" => policy.timeout,
      "max_memory_bytes" => policy.max_memory_bytes,
      "max_request_size" => policy.max_request_size,
      "max_response_size" => policy.max_response_size,
      "rate_limit" => rate_limit_map(policy.rate_limit),
      "max_concurrent_tasks" => policy.max_concurrent_tasks,
      "batch_timeout" => policy.batch_timeout
    }
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp build_node(ctx, node_key, source_ref, vault_fn, extras) do
    with {:ok, row} <- node_row(ctx, node_key),
         {:ok, policy, _meta} <- Sanctum.Policy.get_effective(ctx, node_key) do
      manifest =
        Compendium.Manifest.decode(Map.get(row, :manifest) || Map.get(row, "manifest"))

      resources = resource_map(policy)
      vault = vault_fn.(node_key, row, manifest)

      edges =
        manifest
        |> direct_dep_keys(node_key)
        |> Map.new(fn dep_key -> {dep_key, %{"__dep__" => dep_key}} end)

      edges =
        if node_key == source_ref do
          ingress =
            resources
            |> Map.merge(extras)
            |> Map.put("__vault__", vault)

          Map.put(edges, "@ingress", ingress)
        else
          edges
        end

      {:ok,
       %{
         limits: limits_map(policy),
         resources: Map.put(resources, "__vault__", vault),
         edges: edges
       }}
    end
  end

  defp node_row(ctx, node_key) do
    case Sanctum.ComponentRef.parse(node_key) do
      {:ok, ref} ->
        case Compendium.Registry.get_latest(ctx, ref.name, ref.namespace, ref.type) do
          {:ok, row} -> {:ok, row}
          {:error, reason} -> {:error, {:missing_node_row, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_node_key, reason}}
    end
  end

  defp direct_dep_keys(manifest, node_key) do
    case Compendium.DependencyResolver.extract_from_manifest(manifest, node_key) do
      {:ok, deps} ->
        deps
        |> Enum.map(fn dep -> "#{dep.dep_type}:#{dep.dep_namespace}.#{dep.dep_name}" end)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == node_key))

      {:error, _} ->
        []
    end
  end

  defp finalize_edge(resources) do
    {vault, rest} = Map.pop(resources, "__vault__")

    case vault do
      nil -> rest
      vault -> Map.put(rest, "vault", vault)
    end
  end

  # A nil legacy rate limit means unchecked; the blob grammar requires a
  # map, so the ceiling's maximum is the closest expressible equivalent.
  defp rate_limit_map(nil), do: %{"requests" => 10_000, "window" => "1m"}

  defp rate_limit_map(%{requests: requests, window: window}),
    do: %{"requests" => requests, "window" => window}
end
