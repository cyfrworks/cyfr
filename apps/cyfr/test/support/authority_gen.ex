# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Test.AuthorityGen do
  @moduledoc """
  StreamData generators for the Authority property suite.

  Generates randomized consented graphs — small ref alphabet so repeated
  refs, self-edges and cycles occur naturally — together with a `meta`
  oracle (source node, edge list, per-node declared needs, activation) the
  properties check outcomes against. Digests are fabricated; real release
  digests arrive with the digest phase.
  """

  import StreamData
  import ExUnitProperties, only: [gen: 2]

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob

  @types ~w(formula catalyst reagent)
  @names ~w(alpha bravo charlie delta echo)
  @needs ~w(source dest aux)
  @max_nodes 5
  @max_edges 10

  def needs_vocabulary, do: @needs

  @doc "A name-level ref from a small alphabet, so collisions are common."
  def ref do
    gen all type <- member_of(@types), name <- member_of(@names) do
      "#{type}:local.#{name}"
    end
  end

  def digest do
    gen all hex <- string(?a..?f, min_length: 12, max_length: 12) do
      "sha256:" <> hex
    end
  end

  @doc "Limits straddling the platform ceiling so clamping is exercised."
  def limits_map do
    gen all minutes <- integer(1..60),
            memory <- member_of([1_048_576, 67_108_864, 512 * 1024 * 1024]),
            tasks <- integer(1..100) do
      %{
        "timeout" => "#{minutes}m",
        "max_memory_bytes" => memory,
        "max_request_size" => 1_048_576,
        "max_response_size" => 5_242_880,
        "rate_limit" => %{"requests" => 100, "window" => "1m"},
        "max_concurrent_tasks" => tasks,
        "batch_timeout" => "5m"
      }
    end
  end

  @doc "A random resource set for one edge; sometimes empty (invocation-only)."
  def edge_resources do
    gen all vault? <- boolean(),
            entry <- string(?a..?z, min_length: 3, max_length: 6),
            domains <- list_of(member_of(["a.example", "b.example"]), max_length: 2),
            tools <-
              list_of(member_of(["storage.read", "storage.write", "execution.run"]),
                max_length: 3
              ) do
      base = %{"egress" => %{"domains" => Enum.uniq(domains)}, "tools" => Enum.uniq(tools)}

      if vault? do
        Map.put(base, "vault", %{
          "entry_id" => "vault-" <> entry,
          "binding_digest" => "sha256:bind-" <> entry
        })
      else
        base
      end
    end
  end

  @doc """
  A randomized graph: `{graph_map, meta}`.

  `meta` carries `source`, `nodes`, `edges` (as `{from, to, need}`),
  `declared_needs` (per node: the slots of its outgoing named edges) and
  `activation`. Pass `self_edges: false` to exclude self-edges (the D2
  property needs graphs where the same-ref-different-digest case cannot be
  satisfied by a real edge).
  """
  def graph(opts \\ []) do
    allow_self = Keyword.get(opts, :self_edges, true)

    gen all node_refs <- uniq_list_of(ref(), min_length: 2, max_length: @max_nodes),
            limits_list <- list_of(limits_map(), length: @max_nodes),
            digests <- uniq_list_of(digest(), length: @max_nodes),
            raw_edges <-
              list_of(
                tuple(
                  {integer(0..(@max_nodes - 1)), integer(0..(@max_nodes - 1)),
                   member_of(["" | @needs])}
                ),
                max_length: @max_edges
              ),
            resources_list <- list_of(edge_resources(), length: @max_edges),
            ingress_resources <- edge_resources(),
            source_index <- integer(0..(@max_nodes - 1)) do
      build_graph(
        node_refs,
        limits_list,
        digests,
        raw_edges,
        resources_list,
        ingress_resources,
        source_index,
        allow_self
      )
    end
  end

  defp build_graph(
         node_refs,
         limits_list,
         digests,
         raw_edges,
         resources_list,
         ingress_resources,
         source_index,
         allow_self
       ) do
    n = length(node_refs)
    at = fn index -> Enum.at(node_refs, rem(index, n)) end
    source = at.(source_index)

    edges =
      raw_edges
      |> Enum.map(fn {from, to, need} -> {at.(from), at.(to), need} end)
      |> then(fn edges ->
        if allow_self, do: edges, else: Enum.reject(edges, fn {from, to, _} -> from == to end)
      end)
      |> Enum.uniq_by(fn {from, to, need} -> {from, Blob.edge_key(to, need)} end)

    base_nodes =
      node_refs
      |> Enum.zip(limits_list)
      |> Map.new(fn {ref, limits} -> {ref, %{"limits" => limits, "edges" => %{}}} end)

    nodes =
      edges
      |> Enum.zip(resources_list)
      |> Enum.reduce(base_nodes, fn {{from, to, need}, resources}, acc ->
        put_in(acc, [from, "edges", Blob.edge_key(to, need)], resources)
      end)
      |> put_in([source, "edges", "@ingress"], ingress_resources)

    activation = node_refs |> Enum.zip(digests) |> Map.new()

    declared_needs =
      Map.new(node_refs, fn ref ->
        needs =
          edges
          |> Enum.filter(fn {from, _, need} -> from == ref and need != "" end)
          |> Enum.map(fn {_, _, need} -> need end)
          |> Enum.uniq()
          |> Enum.sort()

        {ref, needs}
      end)

    meta = %{
      source: source,
      nodes: node_refs,
      edges: edges,
      declared_needs: declared_needs,
      activation: activation
    }

    {%{"canonical" => "jcs-1", "nodes" => nodes}, meta}
  end

  @doc "Parse a generated graph map."
  def blob!(graph_map) do
    {:ok, blob} = Blob.parse(graph_map)
    blob
  end

  @doc "Root an authority over a generated graph."
  def rooted({graph_map, meta}, opts \\ []) do
    profile = %{
      profile_id: "prof-gen",
      consent_id: "consent-gen",
      source_ref: meta.source,
      kind: Keyword.get(opts, :kind, :owner),
      invoke_mode: Keyword.get(opts, :invoke_mode, :open_inert),
      activation: meta.activation
    }

    {:ok, auth} = Authority.root(profile, blob!(graph_map), Keyword.take(opts, [:ceiling]))
    auth
  end

  @doc """
  The invoke target the resolver would build at `auth`'s current node for
  `reference` — declared needs come from the caller's manifest (meta), the
  activation digest from the target's resolution.
  """
  def invoke_at(auth, meta, reference, need) do
    declared =
      case Authority.current_node(auth) do
        {:ok, node} -> Map.get(meta.declared_needs, node, [])
        :unbound -> []
      end

    {:invoke,
     %{
       reference: reference,
       need: need,
       activation_digest: Map.get(meta.activation, reference),
       declared_needs: declared
     }}
  end

  @doc "A random program over a graph: invoke steps with in- and off-graph targets."
  def walk(meta) do
    target = one_of([member_of(meta.nodes), ref(), constant("formula:evil.corp.helper")])

    list_of(
      tuple({member_of([:call, :spawn]), target, member_of([nil | @needs])}),
      min_length: 1,
      max_length: 12
    )
  end

  @doc """
  A need that passes the §2.7 rules at `auth`'s current node: `nil` when
  the node declares no needs, otherwise its first declared need.
  """
  def compliant_need(auth, meta) do
    case Authority.current_node(auth) do
      {:ok, node} ->
        case Map.get(meta.declared_needs, node, []) do
          [] -> nil
          [first | _] -> first
        end

      :unbound ->
        nil
    end
  end

  @doc """
  Fold a walk through the transition relation, following child outcomes
  and staying put on deny/invalid. Returns the trace as
  `[{auth_before, step, outcome, auth_after}]`.
  """
  def run_walk(auth, meta, steps) do
    {trace, _final} =
      Enum.map_reduce(steps, auth, fn {fun, target_ref, need} = step, acc ->
        outcome = Sanctum.Authority.Transition.step(acc, fun, invoke_at(acc, meta, target_ref, need))

        next =
          case outcome do
            {:child, child} -> child
            {:child_zero, child} -> child
            _ -> acc
          end

        {{acc, step, outcome, next}, next}
      end)

    trace
  end

  @doc "A random target of any of the six shapes, biased toward the graph."
  def target(meta) do
    invoke =
      gen all reference <- one_of([member_of(meta.nodes), ref()]),
              need <- member_of([nil | @needs]),
              activation <-
                one_of([
                  constant(nil),
                  digest(),
                  member_of(Map.values(meta.activation))
                ]),
              declared <- list_of(member_of(@needs), max_length: 3) do
        {:invoke,
         %{
           reference: reference,
           need: need,
           activation_digest: activation,
           declared_needs: Enum.uniq(declared)
         }}
      end

    one_of([
      invoke,
      gen all tool <- member_of(["storage", "component", "execution"]),
              action <- member_of(["read", "write", "run", "search"]) do
        {:tool, %{tool: tool, action: action}}
      end,
      gen all server <- digest(), tool <- string(?a..?z, min_length: 3, max_length: 8) do
        {:external_tool, %{server_digest: server, tool: tool}}
      end,
      gen all id <- integer(1..99) do
        {:task, "task_#{id}"}
      end,
      gen all ids <- list_of(integer(1..99), max_length: 3) do
        {:tasks, Enum.map(ids, &"task_#{&1}")}
      end,
      constant({:event, %{"progress" => 1}})
    ])
  end

  @doc "Outgoing edges per node, from meta: `%{from => [{to, need}]}`."
  def outgoing(meta) do
    meta.edges
    |> Enum.group_by(fn {from, _, _} -> from end, fn {_, to, need} -> {to, need} end)
    |> then(&Map.new(meta.nodes, fn ref -> {ref, Map.get(&1, ref, [])} end))
  end

  @doc """
  The edges actually invocable from `node` under the §2.7 rules: all of
  them when the node declares no needs; only the named ones otherwise —
  a needs-declaring manifest must name every dependency, so its unnamed
  edges are unreachable (omission is rejected).
  """
  def reachable_edges(meta, node) do
    edges = outgoing(meta)[node] || []

    case Map.get(meta.declared_needs, node, []) do
      [] -> edges
      _declared -> Enum.filter(edges, fn {_, need} -> need != "" end)
    end
  end

  @doc "The complement of `reachable_edges/2`."
  def unreachable_edges(meta, node) do
    (outgoing(meta)[node] || []) -- reachable_edges(meta, node)
  end
end
