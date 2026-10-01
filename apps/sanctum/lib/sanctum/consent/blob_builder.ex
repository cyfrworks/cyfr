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
  granted whole at this grain) and limits from `Prima.Limits.defaults/1`
  under `caps.limits`. A manifest with no `needs`/`caps` blocks grants the
  empty ask — deny-all resources under type-default limits.

  The caller supplies a `vault_fn` deciding which vault resource (if any)
  rides each node: a bound entry (`entry_id`, `binding_digest`,
  `projection`) or a selection (`via` a profile of that node). An
  optional `opts[:edge_vault_fn]` `(from, dep, row, manifest -> vault | nil)`
  overrides the vault on one dependency edge; `nil` keeps the node's
  default. Commit binds the operator's chosen entries and selections;
  bootstrap selects on each vouched edge into a shipped dependency.

  ## Narrowing

  `opts[:subset]` narrows the ask per node (`narrow/5`): each kind whose
  enforcement point checks a subset — egress domains, methods, schemes and
  private ranges, storage paths and actions, tool actions, and the limits —
  takes the values the subset names, each of which must lie inside the ask,
  and the limits inside the platform ceiling too. A value outside is refused
  as a superset; granting more than the ask is the override decision, never
  a narrowing. A field the subset leaves out keeps its ask, and an empty set
  grants none. Credentials, tool servers and a tincture's declarations are
  granted whole or not at all, so a subset cannot name them
  (`Sanctum.Consent.Normalize.subset/3`).

  Inside the ask means inside it as its enforcement point reads it: a
  domain the ask names, or a plain host one of its patterns admits
  (`Prima.Network.domain_allowed?/2`); a private range the ask names, or an
  address or narrower range inside one of its ranges; a storage path the
  ask names, or a guest path the ask admits, read as
  `Crucible.GuestStorage` enforces a grant
  (`Prima.ComponentPath.path_granted?/2`); and exactly one of the ask's
  values for every other field.

  ## Preview rows

  `ask_rows/2` and `grant_rows/4` answer the typed rows of
  `Prima.ConsentPreview` in their JSON form for the resources, the limits
  and a tincture's declarations: the ask a plan shows, and the grant a
  built blob holds. A node whose ask names every tool (`"*"`) and whose
  grant is that whole ask has one wildcard tools row, as the grant states
  it, rather than the catalog it expands to. The commit adds the rows only
  it can name, the credentials, each with the edge it rides, and the tool
  servers, and `order_rows/1` puts every row in one order.
  """

  alias Prima.Manifest.Tincture
  alias Sanctum.Consent.Components
  alias Prima.JCS

  require Logger

  @type vault_fn ::
          (node_key :: String.t(), row :: map(), manifest :: map() -> map() | nil)

  @type edge_vault_fn ::
          (from :: String.t(), dep :: String.t(), row :: map(), manifest :: map() ->
             map() | nil)

  @typedoc "A preview row in its JSON form (`Prima.ConsentPreview.Row.encode/1`)."
  @type row :: %{required(String.t()) => term()}

  @typedoc "Per node, the kinds its narrowing changed."
  @type narrowed :: %{optional(String.t()) => [String.t()]}

  @resource_kinds ~w(egress storage tools)
  @set_fields %{
    "egress" => ~w(domains methods schemes private_ips),
    "storage" => ~w(paths actions)
  }
  @limit_fields Map.new(Prima.Limits.fields(), &{Atom.to_string(&1), &1})
  @integer_limits ~w(max_memory_bytes max_request_size max_response_size max_concurrent_tasks)
  # Zero bounds nothing its enforcement point reads, or reads there as no
  # bound at all, for these and for both durations: a narrowing names at
  # least one. A zero `max_concurrent_tasks` is a bound (the node may not
  # spawn), and so are zero requests in a rate limit (none admitted).
  @positive_integer_limits ~w(max_memory_bytes max_request_size max_response_size)

  @doc """
  Build the node map for a blob. `graph` is the activation graph
  (node ref → release digest); `source_ref` gets the `@ingress` edge.
  `opts[:ingress_extras]` merges extra resources (tool-server grants)
  into that edge alone. `opts[:edge_vault_fn]` overrides one dep edge's
  vault; `nil` keeps the node's default. `opts[:subset]` narrows each node
  it names (`narrow/5`), every node it names being one of the graph's, under
  `opts[:ceiling]` (the platform ceiling when absent); a refused narrowing
  answers `{:error, {:invalid_argument, sentence}}`.
  """
  @spec build(Sanctum.Context.t(), map(), String.t(), vault_fn(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build(ctx, graph, source_ref, vault_fn, opts \\ []) do
    extras = Keyword.get(opts, :ingress_extras, %{})
    vault_fns = {vault_fn, Keyword.get(opts, :edge_vault_fn)}
    subset = Keyword.get(opts, :subset, %{})

    with :ok <- subset_nodes(subset, graph) do
      narrowing = {subset, ceiling(subset, opts)}

      Enum.reduce_while(Map.keys(graph), {:ok, %{}}, fn node_key, {:ok, acc} ->
        case build_node(ctx, graph, node_key, source_ref, vault_fns, extras, narrowing) do
          {:ok, node} -> {:cont, {:ok, Map.put(acc, node_key, node)}}
          # A refused narrowing names its node already.
          {:error, {:invalid_argument, _sentence} = refusal} -> {:halt, {:error, refusal}}
          {:error, reason} -> {:halt, {:error, {node_key, reason}}}
        end
      end)
    end
  end

  @doc "Per node of `build/5`'s answer, the kinds its narrowing changed."
  @spec narrowed(map()) :: narrowed()
  def narrowed(nodes) when is_map(nodes) do
    for {node_key, %{narrowed: [_ | _] = kinds}} <- nodes, into: %{}, do: {node_key, kinds}
  end

  @doc """
  Narrow the decoded nodes of a blob built elsewhere (a public profile's
  published nodes) by `subset`: every edge into a narrowed node, and the
  ingress edge when that node is the source, takes the narrowed resources,
  and the node takes the narrowed limits. What those nodes grant is the ask
  each narrowing must lie inside. Answers the nodes and `narrowed/1`'s map.
  """
  @spec narrow_nodes(map(), String.t(), map(), keyword()) ::
          {:ok, map(), narrowed()} | {:error, {:invalid_argument, String.t()}}
  def narrow_nodes(nodes, source_ref, subset, opts \\ []) when is_map(nodes) do
    with :ok <- subset_nodes(subset, nodes) do
      ceiling = ceiling(subset, opts)

      subset
      |> Enum.sort()
      |> Enum.reduce_while({:ok, nodes, %{}}, fn {node_key, record}, {:ok, acc, narrowed} ->
        asked = node_resources(acc, source_ref, node_key)
        asked_limits = get_in(acc, [node_key, "limits"])

        case narrow(node_key, asked, asked_limits, record, ceiling) do
          {:ok, resources, limits, kinds} ->
            acc =
              acc
              |> put_node_resources(source_ref, node_key, resources)
              |> put_in([node_key, "limits"], limits)

            {:cont, {:ok, acc, put_narrowed(narrowed, node_key, kinds)}}

          {:error, _} = refusal ->
            {:halt, refusal}
        end
      end)
    end
  end

  @doc """
  The resources a decoded blob's `nodes` give `node_key`: the ingress edge
  for the source, and for any other node an edge into it, since every edge
  into a node carries that node's resources. `nil` for a node no edge
  reaches.
  """
  @spec node_resources(map(), String.t(), String.t()) :: map() | nil
  def node_resources(nodes, source_ref, node_key) when node_key == source_ref,
    do: get_in(nodes, [node_key, "edges", Prima.Authority.Blob.ingress_key()])

  def node_resources(nodes, _source_ref, node_key) do
    nodes
    |> Enum.sort()
    |> Enum.find_value(fn {_from, node} ->
      (node["edges"] || %{})
      |> Enum.sort()
      |> Enum.find_value(fn {key, edge} ->
        if Prima.Authority.Blob.edge_target(key) == {:ok, node_key}, do: edge
      end)
    end)
  end

  defp put_node_resources(nodes, source_ref, node_key, resources) do
    narrowed = Map.take(resources || %{}, @resource_kinds)

    Map.new(nodes, fn {from, node} ->
      edges =
        Map.new(node["edges"] || %{}, fn {key, edge} ->
          into? =
            case Prima.Authority.Blob.edge_target(key) do
              :ingress -> from == node_key and node_key == source_ref
              {:ok, target} -> target == node_key
            end

          {key, if(into?, do: Map.merge(edge, narrowed), else: edge)}
        end)

      {from, Map.put(node, "edges", edges)}
    end)
  end

  defp subset_nodes(subset, graph) do
    case Enum.find(subset |> Map.keys() |> Enum.sort(), &(not Map.has_key?(graph, &1))) do
      nil ->
        :ok

      node ->
        {:error,
         {:invalid_argument,
          "The narrowing names #{node}, which is not a node of this grant's consent graph"}}
    end
  end

  # The ceiling a narrowing's limits must lie inside, read only when a
  # narrowing names something.
  defp ceiling(subset, _opts) when subset == %{}, do: nil

  defp ceiling(_subset, opts),
    do: Keyword.get_lazy(opts, :ceiling, &Sanctum.Policy.Ceiling.platform_ceiling/0)

  defp put_narrowed(narrowed, _node_key, []), do: narrowed
  defp put_narrowed(narrowed, node_key, kinds), do: Map.put(narrowed, node_key, kinds)

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
    ingress = node.edges[Prima.Authority.Blob.ingress_key()]
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

  defp build_node(ctx, graph, node_key, source_ref, vault_fns, extras, {subset, ceiling}) do
    {vault_fn, edge_vault_fn} = vault_fns

    with {:ok, row} <- node_row(ctx, node_key),
         manifest = manifest(row, node_key),
         {:ok, asked, asked_limits} <- node_grant(ctx, node_key, manifest),
         {:ok, resources, limits, narrowed} <-
           narrow(node_key, asked, asked_limits, Map.get(subset, node_key), ceiling) do
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

          Map.put(edges, Prima.Authority.Blob.ingress_key(), ingress)
        else
          edges
        end

      {:ok,
       %{
         limits: limits,
         resources: Map.put(resources, "__vault__", vault),
         edges: edges,
         narrowed: narrowed
       }}
    end
  end

  defp edge_vault(nil, _from, _dep, _ctx), do: nil

  defp edge_vault(edge_vault_fn, from, dep, ctx) do
    case node_row(ctx, dep) do
      {:ok, row} ->
        manifest = manifest(row, dep)
        edge_vault_fn.(from, dep, row, manifest)

      {:error, _} ->
        nil
    end
  end

  @doc false
  # The manifest's declared caps are the grant; an absent block is the
  # empty ask, and a block that no longer meets the grammar is refused
  # (`ShapeDerivation.declared_caps/2`). Public for the plan verb, which
  # must show the same grant this builder would freeze.
  def node_grant(_ctx, node_key, manifest) do
    with {:ok, caps} <- Sanctum.Consent.ShapeDerivation.declared_caps(manifest, node_key) do
      {:ok, resource_map_from_caps(caps), limits_map_from_caps(node_key, caps)}
    end
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

  @doc """
  Narrow one node's ask: `resources` and `limits` in the blob's JSON form,
  `subset` the node's record as `Sanctum.Consent.Normalize.subset/3`
  answers it (or `nil`), and `ceiling` the platform ceiling. Answers the
  narrowed resources and limits and the kinds whose grant the narrowing
  changed, or `{:error, {:invalid_argument, sentence}}` naming the first
  value outside the ask or the ceiling.
  """
  @spec narrow(String.t(), map() | nil, map() | nil, map() | nil, map() | nil) ::
          {:ok, map() | nil, map() | nil, [String.t()]}
          | {:error, {:invalid_argument, String.t()}}
  def narrow(_node_key, resources, limits, nil, _ceiling), do: {:ok, resources, limits, []}

  def narrow(node_key, resources, limits, subset, ceiling) when is_map(subset) do
    with {:ok, egress} <- narrow_sets(node_key, "egress", kind(resources, "egress"), subset),
         {:ok, storage} <- narrow_sets(node_key, "storage", kind(resources, "storage"), subset),
         {:ok, tools} <- narrow_tools(node_key, kind(resources, "tools"), subset["tools"]),
         {:ok, narrowed_limits} <- narrow_limits(node_key, limits, subset["limits"], ceiling) do
      narrowed_resources =
        resources
        |> put_kind("egress", egress)
        |> put_kind("storage", storage)
        |> put_kind("tools", tools)

      changed =
        for kind <- @resource_kinds,
            Map.has_key?(subset, kind),
            kind(narrowed_resources, kind) != kind(resources, kind),
            do: kind

      changed =
        if Map.has_key?(subset, "limits") and narrowed_limits != limits,
          do: changed ++ ["limits"],
          else: changed

      {:ok, narrowed_resources, narrowed_limits, changed}
    end
  end

  defp kind(nil, _kind), do: nil
  defp kind(resources, kind), do: Map.get(resources, kind)

  defp put_kind(resources, _kind, nil), do: resources
  defp put_kind(nil, kind, value), do: %{kind => value}
  defp put_kind(resources, kind, value), do: Map.put(resources, kind, value)

  defp narrow_sets(node_key, kind, asked, subset) do
    case Map.fetch(subset, kind) do
      :error ->
        {:ok, asked}

      {:ok, chosen} ->
        Enum.reduce_while(Enum.sort(chosen), {:ok, asked}, fn {field, values}, {:ok, acc} ->
          asked_values = (asked && Map.get(asked, field)) || []

          case Enum.find(values, &(not inside?(kind, field, &1, asked_values))) do
            nil ->
              {:cont, {:ok, put_field(acc, field, values)}}

            outside ->
              {:halt, superset(node_key, "#{kind} #{singular(field)} #{shown(outside)}")}
          end
        end)
    end
  end

  # An empty narrowing of a kind the ask does not carry leaves it absent.
  defp put_field(nil, _field, []), do: nil
  defp put_field(nil, field, values), do: %{field => values}
  defp put_field(asked, field, values), do: Map.put(asked, field, values)

  defp narrow_tools(_node_key, asked, nil), do: {:ok, asked}

  defp narrow_tools(node_key, asked, chosen) do
    case Enum.find(chosen, &(&1 not in (asked || []))) do
      nil -> {:ok, if(asked == nil and chosen == [], do: nil, else: chosen)}
      outside -> superset(node_key, "tool action #{shown(outside)}")
    end
  end

  # Whether one value of a narrowing lies inside the ask, as the kind's
  # enforcement point reads the ask (see the moduledoc).
  defp inside?("egress", "domains", value, asked) do
    value in asked or
      (not String.contains?(value, "*") and Prima.Network.domain_allowed?(value, asked))
  end

  defp inside?("egress", "private_ips", value, asked),
    do: value in asked or in_range?(value, asked)

  # A narrowed path is itself a grant, and it lies inside the ask when
  # every path it admits the ask admits too; read by the one reading of a
  # storage grant, that is the ask admitting it as a path.
  defp inside?("storage", "paths", value, asked),
    do:
      value in asked or
        (guest_path?(value) and Prima.ComponentPath.path_granted?(value, asked))

  defp inside?(_kind, _field, value, asked), do: value in asked

  defp in_range?(value, asked) do
    case range(value) do
      {:ok, {network, prefix}} ->
        Enum.any?(asked, fn asked_range ->
          case range(asked_range) do
            {:ok, {asked_network, asked_prefix}} ->
              prefix >= asked_prefix and
                Prima.Cidr.ip_in_network?(network, asked_network, asked_prefix)

            :error ->
              false
          end
        end)

      :error ->
        false
    end
  end

  # An address is the range of its own full length.
  defp range(value) do
    case Prima.Cidr.parse_ip(value) do
      {:ok, ip} when tuple_size(ip) == 4 -> {:ok, {ip, 32}}
      {:ok, ip} -> {:ok, {ip, 128}}
      :error -> Prima.Cidr.parse_cidr(value)
    end
  end

  defp guest_path?(value) do
    Prima.PathSafety.validate_relative_path(value) == :ok and
      Arca.Storage.valid_guest_path?(value)
  end

  # Each limit the narrowing names must lie inside the ask by its own
  # reading, keep the meaning its enforcement point gives it, and survive
  # the ceiling's clamp unchanged; the rest keep their ask.
  defp narrow_limits(_node_key, limits, nil, _ceiling), do: {:ok, limits}

  defp narrow_limits(node_key, limits, record, ceiling) do
    asked = limits || %{}

    with {:ok, narrowed} <- narrow_limit_fields(node_key, asked, record),
         {:ok, struct} <- limits_struct(node_key, narrowed),
         :ok <- under_ceiling(node_key, struct, record, ceiling) do
      {:ok, narrowed}
    end
  end

  defp narrow_limit_fields(node_key, asked, record) do
    Enum.reduce_while(Enum.sort(record), {:ok, asked}, fn {field, value}, {:ok, acc} ->
      case narrow_limit(field, value, Map.get(asked, field)) do
        {:ok, narrowed} ->
          {:cont, {:ok, Map.put(acc, field, narrowed)}}

        {:error, why} ->
          {:halt,
           {:error,
            {:invalid_argument, "The narrowing of #{node_key} sets limits.#{field} #{why}"}}}
      end
    end)
  end

  defp narrow_limit(field, value, asked) when field in @integer_limits do
    cond do
      not is_integer(value) or value < 0 ->
        {:error, "to a value that is not a non-negative integer"}

      field in @positive_integer_limits and value == 0 ->
        {:error, "to zero, which bounds nothing there; name at least 1"}

      not is_integer(asked) ->
        {:error, "where the ask carries no such limit"}

      value > asked ->
        {:error, "to #{value}, above the #{asked} it asks for"}

      true ->
        {:ok, value}
    end
  end

  defp narrow_limit(field, value, asked) when field in ~w(timeout batch_timeout) do
    case {duration_ms(value), duration_ms(asked)} do
      {{:ok, 0}, _asked} ->
        {:error, "to zero, which bounds nothing there; name a positive duration"}

      {{:ok, ms}, {:ok, asked_ms}} when ms > asked_ms ->
        {:error, "to #{value}, above the #{asked} it asks for"}

      {{:ok, _ms}, {:ok, _asked_ms}} ->
        {:ok, value}

      {:error, _asked} ->
        {:error, "to a value that is not a duration"}

      {_value, :error} ->
        {:error, "where the ask carries no such limit"}
    end
  end

  defp narrow_limit("rate_limit", value, %{"requests" => asked_requests, "window" => asked_window})
       when is_map(value) and is_integer(asked_requests) do
    merged = Map.merge(%{"requests" => asked_requests, "window" => asked_window}, value)
    requests = merged["requests"]

    case {duration_ms(merged["window"]), duration_ms(asked_window)} do
      {{:ok, window_ms}, {:ok, asked_ms}} when is_integer(requests) and requests >= 0 ->
        cond do
          window_ms == 0 ->
            {:error, "to a window of zero, which holds nothing; name a positive window"}

          requests > asked_requests ->
            {:error, "to #{requests} requests, above the #{asked_requests} it asks for"}

          # Both bounds hold: no larger a burst, and no faster a rate.
          requests * asked_ms > asked_requests * window_ms ->
            {:error,
             "to #{requests} per #{merged["window"]}, a faster rate than the " <>
               "#{asked_requests} per #{asked_window} it asks for"}

          true ->
            {:ok, merged}
        end

      _unreadable ->
        {:error, "to a value that is not a rate limit"}
    end
  end

  defp narrow_limit("rate_limit", _value, _asked),
    do: {:error, "where the ask carries no rate limit"}

  defp narrow_limit(_field, _value, _asked), do: {:error, "which is not a limit"}

  defp duration_ms(value) when is_binary(value) do
    case Prima.Limits.parse_duration(value) do
      {:ok, ms} when ms >= 0 -> {:ok, ms}
      _ -> :error
    end
  end

  defp duration_ms(_value), do: :error

  defp limits_struct(node_key, narrowed) do
    case Prima.Limits.new(narrowed) do
      {:ok, limits} ->
        {:ok, limits}

      {:error, {:invalid_limit, field, why}} ->
        {:error,
         {:invalid_argument,
          "The narrowing of #{node_key} leaves limits that do not hold: #{field} #{why}"}}
    end
  end

  # The one clamp (`Prima.Limits.Ceiling.clamp/2`) decides: a limit the
  # narrowing names is inside the ceiling when clamping leaves it as named.
  defp under_ceiling(node_key, limits, record, ceiling) do
    clamped =
      Prima.Limits.Ceiling.clamp(limits, ceiling || Sanctum.Policy.Ceiling.platform_ceiling())

    above =
      record
      |> Map.keys()
      |> Enum.sort()
      |> Enum.find(fn field ->
        case Map.fetch(@limit_fields, field) do
          {:ok, atom} -> Map.get(clamped, atom) != Map.get(limits, atom)
          :error -> false
        end
      end)

    if above,
      do:
        {:error,
         {:invalid_argument,
          "The narrowing of #{node_key} sets limits.#{above} above the platform ceiling"}},
      else: :ok
  end

  defp singular("domains"), do: "domain"
  defp singular("methods"), do: "method"
  defp singular("schemes"), do: "scheme"
  defp singular("private_ips"), do: "private range"
  defp singular("paths"), do: "path"
  defp singular("actions"), do: "action"

  defp superset(node_key, what) do
    {:error,
     {:invalid_argument,
      "The narrowing of #{node_key} names #{what}, which it does not ask for; a narrowing " <>
        "grants part of the ask, and granting more is the override decision"}}
  end

  # A value the caller sent, shown in a refusal only while it is short.
  defp shown(value) when is_binary(value) and byte_size(value) <= 128, do: value
  defp shown(_value), do: "a value"

  # ---------------------------------------------------------------------------
  # Preview rows
  # ---------------------------------------------------------------------------

  @kind_order Prima.ConsentPreview.kinds()
              |> Enum.with_index()
              |> Map.new(fn {kind, index} -> {Atom.to_string(kind), index} end)

  @doc """
  The ask of each node of `node_keys` as preview rows: the resources and
  limits its manifest declares, none narrowed, and a tincture's
  declarations.
  """
  @spec ask_rows(Sanctum.Context.t(), [String.t()]) :: {:ok, [row()]} | {:error, term()}
  def ask_rows(ctx, node_keys) when is_list(node_keys) do
    collect_rows(Enum.sort(node_keys), fn node_key ->
      with {:ok, row} <- node_row(ctx, node_key),
           manifest = manifest(row, node_key),
           {:ok, resources, limits} <- node_grant(ctx, node_key, manifest),
           {:ok, wildcard} <- wildcard_ask(node_key, manifest),
           {:ok, declared} <- tincture_rows(node_key, manifest) do
        {:ok, node_rows(node_key, {resources, wildcard}, limits, []) ++ declared}
      end
    end)
  end

  @doc """
  The grant a decoded blob's `nodes` holds as preview rows: each node's
  resources and limits, marked narrowed where `narrowed` names the kind,
  and a tincture's declarations, which the shape digest binds.
  """
  @spec grant_rows(Sanctum.Context.t(), String.t(), map(), narrowed()) ::
          {:ok, [row()]} | {:error, term()}
  def grant_rows(ctx, source_ref, nodes, narrowed) when is_map(nodes) and is_map(narrowed) do
    collect_rows(nodes |> Map.keys() |> Enum.sort(), fn node_key ->
      with {:ok, row} <- node_row(ctx, node_key),
           manifest = manifest(row, node_key),
           {:ok, wildcard} <- wildcard_ask(node_key, manifest),
           {:ok, declared} <- tincture_rows(node_key, manifest) do
        resources = {node_resources(nodes, source_ref, node_key), wildcard}
        limits = get_in(nodes, [node_key, "limits"])
        {:ok, node_rows(node_key, resources, limits, Map.get(narrowed, node_key, [])) ++ declared}
      end
    end)
  end

  @doc """
  Rows in one order: by node, then by kind in `Prima.ConsentPreview.kinds/0`'s
  order, each kind's rows keeping the order they came in.
  """
  @spec order_rows([row()]) :: [row()]
  def order_rows(rows), do: Enum.sort_by(rows, &{&1["node"], Map.fetch!(@kind_order, &1["kind"])})

  @doc """
  The rows held to `Prima.ConsentPreview.Row`'s shape, each once, as
  `Prima.ConsentPreview` holds a whole preview's.
  """
  @spec check_rows([row()]) ::
          {:ok, [Prima.ConsentPreview.Row.t()]} | {:error, Prima.ConsentPreview.reason()}
  def check_rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn raw, {:ok, acc, seen} ->
      with {:ok, row} <- Prima.ConsentPreview.Row.decode(raw),
           identity = Prima.ConsentPreview.Row.identity(row),
           false <- MapSet.member?(seen, identity) do
        {:cont, {:ok, [row | acc], MapSet.put(seen, identity)}}
      else
        true -> {:halt, {:error, :duplicate_row}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, checked, _seen} -> {:ok, Enum.reverse(checked)}
      error -> error
    end
  end

  @doc "One preview row in its JSON form."
  @spec row(String.t(), String.t(), map(), boolean()) :: row()
  def row(kind, node_key, values, narrowed?),
    do: %{"kind" => kind, "node" => node_key, "values" => values, "narrowed" => narrowed?}

  defp collect_rows(node_keys, fun) do
    Enum.reduce_while(node_keys, {:ok, []}, fn node_key, {:ok, acc} ->
      case fun.(node_key) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # A resource kind is shown when it grants something or the narrowing
  # changed it, so a kind narrowed to nothing still shows, empty and
  # narrowed; the limits always show.
  defp node_rows(node_key, {resources, wildcard}, limits, narrowed) do
    egress = kind(resources, "egress")
    storage = kind(resources, "storage")
    tools = kind(resources, "tools")

    [
      set_row(node_key, "egress", egress, "domains", narrowed),
      set_row(node_key, "storage", storage, "paths", narrowed),
      tools_row(node_key, tools, narrowed, wildcard),
      is_map(limits) && row("limits", node_key, limits, "limits" in narrowed)
    ]
    |> Enum.filter(&is_map/1)
  end

  defp set_row(node_key, kind, granted, shown_by, narrowed) do
    values = Map.new(Map.fetch!(@set_fields, kind), &{&1, (granted && granted[&1]) || []})

    if values[shown_by] != [] or kind in narrowed,
      do: row(kind, node_key, values, kind in narrowed)
  end

  # An ask that names every tool, granted whole, is shown as the grant
  # states it: one wildcard, not the catalog it expands to today.
  defp tools_row(node_key, tools, narrowed, wildcard) do
    cond do
      is_list(wildcard) and "tools" not in narrowed and (tools || []) == wildcard ->
        row("tools", node_key, %{"tools" => Prima.ConsentPreview.Row.wildcard()}, false)

      (tools || []) != [] or "tools" in narrowed ->
        row("tools", node_key, %{"tools" => tools || []}, "tools" in narrowed)

      true ->
        nil
    end
  end

  # What a manifest's ask expands to when it names every tool, or nil.
  defp wildcard_ask(node_key, manifest) do
    with {:ok, caps} <- Sanctum.Consent.ShapeDerivation.declared_caps(manifest, node_key) do
      {:ok, if("*" in caps.tools, do: Sanctum.Consent.ShapeDerivation.expand_tools(caps.tools))}
    end
  end

  # A tincture's frame, streams, cards and system actions, from the
  # declaration the shape digest binds (`Prima.Manifest.Tincture`); none
  # for a manifest that declares none. Never narrowed.
  defp tincture_rows(node_key, manifest) do
    if Tincture.declared?(manifest) do
      case Tincture.from_manifest(manifest) do
        {:ok, declaration} -> {:ok, declaration_rows(node_key, Tincture.canonical(declaration))}
        {:error, _refusal} -> {:error, {:corrupt, {:manifest, node_key}}}
      end
    else
      {:ok, []}
    end
  end

  defp declaration_rows(node_key, canonical) do
    frame = Map.take(canonical["frame"], ~w(capabilities background placement))

    actions =
      case canonical["actions"] do
        [] -> []
        actions -> [row("system_actions", node_key, %{"actions" => actions}, false)]
      end

    [row("frame", node_key, frame, false)] ++
      Enum.map(canonical["streams"], &row("streams", node_key, &1, false)) ++
      Enum.map(canonical["cards"], &row("cards", node_key, card_values(&1), false)) ++
      actions
  end

  # A card's source, named whole, or none for a static card.
  defp card_values(%{"name" => name} = card) do
    case card["source"] do
      nil -> %{"name" => name}
      source -> Map.put(Map.take(source, ~w(component operation args)), "name", name)
    end
  end

  defp limits_map_from_caps(node_key, caps) do
    defaults =
      node_key
      |> node_type()
      |> Prima.Limits.defaults()
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
    case Prima.ComponentRef.parse(node_key) do
      {:ok, ref} -> String.to_existing_atom(ref.type)
      {:error, _} -> :reagent
    end
  end

  defp node_row(ctx, node_key) do
    case Prima.ComponentRef.parse(node_key) do
      {:ok, ref} ->
        case Components.get_latest(ctx, ref.name, ref.namespace, ref.type) do
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
    case Prima.Manifest.Dependencies.from_manifest(manifest) do
      {:ok, deps} ->
        deps
        |> Enum.map(fn dep ->
          {Prima.ComponentRef.build(dep.dep_type, dep.dep_namespace, dep.dep_name),
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

  # A manifest that does not decode declares nothing. The line names the
  # component, never the manifest's bytes.
  defp manifest(row, ref) do
    case Prima.Manifest.decode_strict(Map.get(row, :manifest) || Map.get(row, "manifest")) do
      {:ok, manifest} ->
        manifest

      {:error, :malformed_manifest} ->
        Logger.warning("[Sanctum.Consent.BlobBuilder] manifest malformed: #{ref}")
        %{}
    end
  end
end
