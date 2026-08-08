# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.BlobBuilder do
  @moduledoc """
  Builds the resolved-policy blob for a consent revision from an
  activation graph — shared by bootstrap (machine-minted revisions) and
  the commit verb (operator-decided revisions). One builder is what keeps
  the two indistinguishable to the loader: a blob is a blob, whoever
  minted it.

  Every edge A → B carries B's own resources, and every node's grant is
  manifest-sourced: resources come from the declared caps (the ask,
  granted whole at this grain) and limits from `Sanctum.Limits.defaults/1`
  under `caps.limits`. A manifest with no `needs`/`caps` blocks grants the
  empty ask — deny-all resources under type-default limits.

  The caller supplies a `vault_fn` deciding which vault resource (if any)
  rides each node; commit binds the operator's chosen entries.
  """

  alias Compendium.Manifest.Caps
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

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp build_node(ctx, node_key, source_ref, vault_fn, extras) do
    with {:ok, row} <- node_row(ctx, node_key),
         manifest =
           Compendium.Manifest.decode(Map.get(row, :manifest) || Map.get(row, "manifest")),
         {:ok, resources, limits} <- node_grant(ctx, node_key, manifest) do
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
         limits: limits,
         resources: Map.put(resources, "__vault__", vault),
         edges: edges
       }}
    end
  end

  @doc false
  # The manifest's declared caps are the grant; an absent block is the
  # empty ask. Public for the plan verb, which must show the same grant
  # this builder would freeze.
  def node_grant(_ctx, node_key, manifest) do
    caps = Caps.from_manifest(manifest) || Caps.from_manifest(%{"caps" => %{}})
    {:ok, resource_map_from_caps(caps), limits_map_from_caps(node_key, caps)}
  end

  # The declared ask becomes the granted resources at this grain (the
  # operator's per-need decisions refine it at commit). Schemes absent
  # means https-only — the one place the default materializes.
  defp resource_map_from_caps(caps) do
    %{
      "egress" => %{
        "domains" => caps.egress.domains,
        "methods" => caps.egress.methods,
        "schemes" => if(caps.egress.schemes == [], do: ["https"], else: caps.egress.schemes),
        "private_ips" => caps.egress.private_ips
      },
      "storage" => %{
        "paths" => caps.storage.paths,
        "actions" => caps.storage.actions
      },
      "tools" => Sanctum.Consent.ShapeDerivation.expand_tools(caps.tools)
    }
  end

  defp limits_map_from_caps(node_key, caps) do
    defaults =
      node_key
      |> node_type()
      |> Sanctum.Limits.defaults()
      |> Map.from_struct()

    defaults
    |> Map.merge(caps.limits)
    |> Map.new(fn
      {:rate_limit, %{requests: requests, window: window}} ->
        {"rate_limit", %{"requests" => requests, "window" => window}}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end

  defp node_type(node_key) do
    case Sanctum.ComponentRef.parse(node_key) do
      {:ok, ref} -> String.to_existing_atom(ref.type)
      {:error, _} -> :reagent
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
end
