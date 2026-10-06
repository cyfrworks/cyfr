# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeDiff do
  @moduledoc """
  What changed between the consent an operator approved and what the
  component now asks for — the `shape_diff` a `consent_required` carries
  so the delta sheet can show a difference instead of a whole sheet.

  Granted capabilities come from the head consent's blob (the source
  node's `@ingress` edge, and for a dependency an edge into it — what the
  operator actually approved, after any narrowing they chose), live ones
  from the component's ask today. Every node of the closure is compared,
  each entry naming its `node`: the source's ref for the app's own, a
  dependency's ref for that dependency's. A dependency the head never held
  is one entry per field it asks for, `new: true`, `added` holding all it
  asks and `removed` empty; one a release dropped is one entry per field
  the head granted it, `dropped: true`, `removed` holding that grant and
  `added` empty: nothing about it is granted any more. Every other entry
  carries `new: false` and `dropped: false`.

  Each entry names a capability with `added`, the values the live ask
  names that the head does not grant, and `removed`, the values the head
  grants that the ask no longer covers: a storage path the ask still admits
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

  Configuration the source provides for a dependency's need is one entry
  per dependency, `provided.<dep>`, since a dependency edge holds one
  credential: its `added` and `removed` are the destinations
  (`destination <scheme>://<hosts><paths>`) and value names (`value
  <name>`) the live block and the head's edge hold, never a value, and
  `need` names the need the live block provides for that dependency when
  it names exactly one (the head's blob names none). It is the app's own
  configuration, read from the app's manifest and the app's edges, so its
  `node` is the source's.

  The app's own entries come first, then each dependency's by its ref.

  Explains the loader's decision without changing it. A derivation failure
  returns an empty diff; a closure that cannot be resolved compares the
  source alone.
  """

  alias Prima.Authority.Blob
  alias Sanctum.Consent.BlobBuilder

  require Logger

  @egress ~w(domains methods schemes private_ips)
  @storage ~w(paths actions)

  # The side of a node the head never held, or the ask no longer names.
  @none %{"tools" => [], "egress" => %{}, "storage" => %{}}

  @typedoc """
  One capability of one node that changed since the head: `node` the
  node's ref; `capability` `"tools"`, `"egress.<field>"`,
  `"storage.<field>"`, `"policy.<mode>"` or `"provided.<dep>"`; `change`
  `:widened`, `:narrowed` or `:changed`; `added` and `removed` the values;
  `new` a dependency the head never held, `dropped` one the ask no longer
  names; and, on a `provided.<dep>` entry, `need`.
  """
  @type entry :: %{
          required(:node) => String.t(),
          required(:capability) => String.t(),
          required(:change) => :widened | :narrowed | :changed,
          required(:added) => [String.t()],
          required(:removed) => [String.t()],
          required(:new) => boolean(),
          required(:dropped) => boolean(),
          optional(:need) => String.t() | nil
        }

  @doc """
  Compare a head consent's granted shape against live capabilities, every
  node of the source's closure as it resolves now. Returns the entries, or
  `[]` when either side cannot be derived.
  """
  @spec compute(Sanctum.Context.t(), String.t(), String.t()) :: [entry()]
  def compute(ctx, source_ref, resolved_policy) do
    asked =
      case Sanctum.Consent.Plan.asked_blob(ctx, source_ref) do
        {:ok, asked} -> asked
        {:error, _underivable} -> nil
      end

    compute(ctx, source_ref, resolved_policy, asked)
  end

  @doc false
  # `compute/3` against the ask a plan has already built for the closure
  # (`Sanctum.Consent.Plan.asked_blob/2`'s, as JSON), so the closure is
  # resolved once; nil, for a closure that does not resolve, compares the
  # source alone.
  @spec compute(Sanctum.Context.t(), String.t(), String.t(), String.t() | nil) :: [entry()]
  def compute(ctx, source_ref, resolved_policy, asked) do
    with {:ok, blob} <- Blob.parse(resolved_policy),
         {:ok, edge} <- Blob.ingress(blob, source_ref),
         {:ok, component} <- Sanctum.Consent.Plan.fetch_component(ctx, source_ref),
         manifest = manifest(component, source_ref),
         {:ok, live} <- live_caps(ctx, source_ref, manifest) do
      own =
        Enum.map(
          diff_caps(flatten_edge(edge), live) ++ diff_provided(blob, source_ref, manifest),
          &on_node(&1, source_ref, :held)
        )

      own ++ diff_dependencies(resolved_policy, source_ref, asked)
    else
      _ -> []
    end
  end

  # Every node of the closure but the source, held against asked: what
  # the edges into it grant on the head and on the ask. A node only the
  # ask names is new, one only the head names dropped.
  defp diff_dependencies(_resolved_policy, _source_ref, nil), do: []

  defp diff_dependencies(resolved_policy, source_ref, asked) do
    with {:ok, %{"nodes" => held}} when is_map(held) <- Jason.decode(resolved_policy),
         {:ok, %{"nodes" => asking}} when is_map(asking) <- Jason.decode(asked) do
      (Map.keys(held) ++ Map.keys(asking))
      |> Enum.uniq()
      |> Enum.reject(&(&1 == source_ref))
      |> Enum.sort()
      |> Enum.flat_map(fn node ->
        case {Map.has_key?(held, node), Map.has_key?(asking, node)} do
          {false, true} ->
            tagged(diff_caps(@none, node_caps(asking, source_ref, node)), node, :new)

          {true, false} ->
            tagged(diff_caps(node_caps(held, source_ref, node), @none), node, :dropped)

          {true, true} ->
            granted = node_caps(held, source_ref, node)
            tagged(diff_caps(granted, node_caps(asking, source_ref, node)), node, :held)
        end
      end)
    else
      _underivable -> []
    end
  end

  defp tagged(entries, node, how), do: Enum.map(entries, &on_node(&1, node, how))

  defp on_node(entry, node, how),
    do: Map.merge(entry, %{node: node, new: how == :new, dropped: how == :dropped})

  # What the edges into `node` grant in `nodes`, in `diff_caps/2`'s shape;
  # nothing for a node no edge reaches.
  defp node_caps(nodes, source_ref, node) do
    resources = BlobBuilder.node_resources(nodes, source_ref, node) || %{}

    %{
      "tools" => resources["tools"] || [],
      "egress" => Map.take(resources["egress"] || %{}, @egress),
      "storage" => Map.take(resources["storage"] || %{}, @storage)
    }
  end

  defp live_caps(ctx, source_ref, manifest) do
    with {:ok, resources, _limits} <-
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

  # The provided configuration on the source's edges into its dependencies
  # against what its manifest provides now, one entry per dependency keyed
  # `provided.<dep>`: an edge holds one credential, and the blob names no
  # need, so the entry names the need the live block names for that
  # dependency when it names exactly one. Its values are the destinations
  # and value names each side holds, never a value.
  defp diff_provided(%Blob{nodes: nodes}, source_ref, manifest) do
    granted =
      case Map.fetch(nodes, source_ref) do
        {:ok, %Blob.Node{edges: edges}} ->
          for {key, %Blob.Edge{vault: %{provided: provided}}} <- edges,
              {:ok, dep} <- [Blob.edge_target(key)],
              into: %{},
              do: {dep, provided_tokens([provided])}

        :error ->
          %{}
      end

    live = live_provided(manifest)

    (Map.keys(granted) ++ Map.keys(live))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn dep ->
      {needs, live_tokens} = Map.get(live, dep, {[], []})

      case entry("provided.#{dep}", Map.get(granted, dep, []), live_tokens) do
        nil -> []
        diff -> [Map.put(diff, :need, single(needs))]
      end
    end)
  end

  defp live_provided(manifest) do
    case Prima.Manifest.Provides.from_manifest(manifest) do
      provides when is_map(provides) ->
        provides
        |> Enum.flat_map(fn {dep, needs} ->
          case Prima.ComponentRef.to_name_ref(dep) do
            {:ok, name_ref} -> [{name_ref, needs}]
            {:error, _} -> []
          end
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {dep, blocks} ->
          needs = Enum.reduce(blocks, %{}, &Map.merge(&2, &1))
          {dep, {needs |> Map.keys() |> Enum.sort(), provided_tokens(Map.values(needs))}}
        end)

      _none ->
        %{}
    end
  end

  defp single([need]), do: need
  defp single(_none_or_several), do: nil

  defp provided_tokens(entries) do
    entries
    |> Enum.flat_map(fn %{destination: destination, values: values} ->
      ["destination " <> destination_text(destination)] ++
        Enum.map(Map.keys(values), &("value " <> &1))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A destination as one line: the scheme, the hosts and port, the path
  # prefixes, and the methods when it names them.
  defp destination_text(destination) do
    map = Prima.Destination.to_map(destination)
    port = if map["port"], do: ":#{map["port"]}", else: ""
    paths = Enum.join(map["paths"] || [], ",")
    methods = if map["methods"], do: " (#{Enum.join(map["methods"], " ")})", else: ""
    "#{map["scheme"]}://#{Enum.join(map["hosts"], ",")}#{port}#{paths}#{methods}"
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
