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
  granted whole at this grain) and limits from `Cyfr.Limits.defaults/1`
  under `caps.limits`. A manifest with no `needs`/`caps` blocks grants the
  empty ask — deny-all resources under type-default limits.

  The caller supplies a `vault_fn` deciding which vault resource (if any)
  rides each node: a bound entry (`entry_id`, `binding_digest`,
  `projection`) or a selection (`via` a profile of that node). An
  optional `opts[:edge_vault_fn]` `(from, dep, row, manifest -> vault | nil)`
  overrides the vault on one dependency edge; `nil` keeps the node's
  default. Commit binds the operator's chosen entries and selections;
  bootstrap selects on each vouched edge into a shipped dependency.
  """

  alias Compendium.Manifest.Caps
  alias Cyfr.JCS

  @type vault_fn ::
          (node_key :: String.t(), row :: map(), manifest :: map() -> map() | nil)

  @type edge_vault_fn ::
          (from :: String.t(), dep :: String.t(), row :: map(), manifest :: map() ->
             map() | nil)

  @doc """
  Build the node map for a blob. `graph` is the activation graph
  (node ref → release digest); `source_ref` gets the `@ingress` edge.
  `opts[:ingress_extras]` merges extra resources (tool-server grants)
  into that edge alone. `opts[:edge_vault_fn]` overrides one dep edge's
  vault; `nil` keeps the node's default.
  """
  @spec build(Sanctum.Context.t(), map(), String.t(), vault_fn(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build(ctx, graph, source_ref, vault_fn, opts \\ []) do
    extras = Keyword.get(opts, :ingress_extras, %{})
    edge_vault_fn = Keyword.get(opts, :edge_vault_fn)

    Enum.reduce_while(Map.keys(graph), {:ok, %{}}, fn node_key, {:ok, acc} ->
      case build_node(ctx, graph, node_key, source_ref, vault_fn, edge_vault_fn, extras) do
        {:ok, node} -> {:cont, {:ok, Map.put(acc, node_key, node)}}
        {:error, reason} -> {:halt, {:error, {node_key, reason}}}
      end
    end)
  end

  @doc """
  Assemble and JCS-encode the final blob from built nodes.

  Returns `{:error, {:dangling_dep, key}}` when a dependency edge names no graph node.
  """
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(nodes) do
    do_encode(nodes)
  catch
    {:dangling_dep, key} -> {:error, {:dangling_dep, key}}
  end

  defp do_encode(nodes) do
    encoded_nodes =
      Map.new(nodes, fn {node_key, node} ->
        edges =
          Map.new(node.edges, fn
            {"@ingress" = key, resources} ->
              {key, finalize_edge(resources)}

            {dep_key, %{"__dep__" => dep_key} = placeholder} ->
              # A dep key the activation graph does not carry is a
              # construction bug, not a `nil.resources` UndefinedFunctionError
              # raised out of `Consent.Bootstrap` — whose `run_components/2`
              # catches only typed skips and refusals, so provisioning
              # crashed the whole supervised task instead of recording one.
              case nodes[dep_key] do
                nil ->
                  throw({:dangling_dep, dep_key})

                dep ->
                  vault = Map.get(placeholder, "__vault__") || dep.resources["__vault__"]
                  {dep_key, finalize_edge(Map.put(dep.resources, "__vault__", vault))}
              end
          end)

        {node_key, %{"limits" => node.limits, "edges" => edges}}
      end)

    JCS.encode(%{"canonical" => "jcs-1", "nodes" => encoded_nodes})
  end

  @doc """
  The derived vault references for `consent_vault_refs`, deduplicated by
  `{entry_id, binding_digest}`. Only a bound entry is a reference; a
  selection names another profile's entry, which that profile's own
  consent already references.
  """
  @spec vault_refs(map()) :: [%{vault_entry_id: String.t(), binding_digest: String.t()}]
  def vault_refs(nodes) do
    for {_from, node} <- nodes,
        vault <- edge_vaults(node, nodes),
        %{"entry_id" => entry_id, "binding_digest" => digest} <- [vault],
        uniq: true do
      %{vault_entry_id: entry_id, binding_digest: digest}
    end
  end

  defp edge_vaults(node, nodes) do
    ingress = node.edges[Cyfr.Authority.Blob.ingress_key()]
    ingress_vault = if is_map(ingress), do: [ingress["__vault__"]], else: []

    dep_vaults =
      for {dep_key, %{"__dep__" => _} = placeholder} <- node.edges,
          dep = nodes[dep_key],
          is_map(dep) do
        Map.get(placeholder, "__vault__") || dep.resources["__vault__"]
      end

    ingress_vault ++ dep_vaults
  end

  @doc """
  The dependency refs `from` declares into `graph` — the edges a
  selection may name.
  """
  @spec dep_edges(map(), map(), String.t()) :: [String.t()]
  def dep_edges(manifest, graph, from)
      when is_map(manifest) and is_map(graph) and is_binary(from),
      do: direct_dep_keys(manifest, graph, from)

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp build_node(ctx, graph, node_key, source_ref, vault_fn, edge_vault_fn, extras) do
    with {:ok, row} <- node_row(ctx, node_key),
         manifest =
           Compendium.Manifest.decode(Map.get(row, :manifest) || Map.get(row, "manifest")),
         {:ok, resources, limits} <- node_grant(ctx, node_key, manifest) do
      vault = vault_fn.(node_key, row, manifest)

      edges =
        Map.new(direct_dep_keys(manifest, graph, node_key), fn dep_key ->
          {dep_key,
           %{
             "__dep__" => dep_key,
             "__vault__" => edge_vault(edge_vault_fn, node_key, dep_key, ctx)
           }}
        end)

      edges =
        if node_key == source_ref do
          ingress =
            resources
            |> Map.merge(extras)
            |> Map.put("__vault__", vault)

          Map.put(edges, Cyfr.Authority.Blob.ingress_key(), ingress)
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

  defp edge_vault(nil, _from, _dep, _ctx), do: nil

  defp edge_vault(edge_vault_fn, from, dep, ctx) do
    case node_row(ctx, dep) do
      {:ok, row} ->
        manifest = Compendium.Manifest.decode(Map.get(row, :manifest) || Map.get(row, "manifest"))
        edge_vault_fn.(from, dep, row, manifest)

      {:error, _} ->
        nil
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
      |> Cyfr.Limits.defaults()
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
    case Cyfr.ComponentRef.parse(node_key) do
      {:ok, ref} -> String.to_existing_atom(ref.type)
      {:error, _} -> :reagent
    end
  end

  defp node_row(ctx, node_key) do
    case Cyfr.ComponentRef.parse(node_key) do
      {:ok, ref} ->
        case Compendium.Registry.get_latest(ctx, ref.name, ref.namespace, ref.type) do
          {:ok, row} -> {:ok, row}
          {:error, reason} -> {:error, {:missing_node_row, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_node_key, reason}}
    end
  end

  # The node's dependency edges: every declared dependency, except an
  # OPTIONAL one the activation does not carry — it is not installed, the
  # activation attests to what can run, and an edge to nothing would be a
  # dangling dep. A required dependency always edges: the activation
  # refused to resolve without it, so it is in the graph.
  defp direct_dep_keys(manifest, graph, node_key) do
    case Compendium.DependencyResolver.extract_from_manifest(manifest, node_key) do
      {:ok, deps} ->
        deps
        |> Enum.map(fn dep ->
          {Cyfr.ComponentRef.build(dep.dep_type, dep.dep_namespace, dep.dep_name),
           dep.optional == true}
        end)
        |> Enum.reject(fn {key, optional?} -> optional? and not Map.has_key?(graph, key) end)
        |> Enum.map(&elem(&1, 0))
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
