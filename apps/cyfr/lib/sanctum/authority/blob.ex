# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.Blob do
  @moduledoc """
  The parsed, typed form of a consent revision's resolved policy blob.

  A blob is one JSON document per consent revision: a map of graph nodes
  (name-level component refs) to their resolved limits and outgoing edges.
  Edges are keyed by target ref plus named-need slot and carry the exact
  resources that edge grants — vault projection, egress, storage, expanded
  tool actions, tool servers. The reserved `"@ingress"` edge carries the
  resources a profile's source node receives when invoked directly.

  Parsing is a fail-closed allowlist: unknown keys anywhere, malformed
  limits, dangling edge targets, or a version-pinned ref in a key are
  errors, never warnings. Code identity is carried by the consent's
  activation map, so blob keys are always name-level.

  Runtime consumers deserialize and look up edges — there is no policy
  computation here beyond `clamp/2`, applied once when an Authority is
  built.
  """

  alias Sanctum.ComponentRef
  alias Sanctum.Limits

  defmodule Edge do
    @moduledoc """
    The resources one consent edge grants. `"@ingress"` and resource-less
    invocation edges are all-empty instances of the same type — an edge that
    authorizes invocation while granting nothing is representable.
    """

    @type vault :: %{
            entry_id: String.t(),
            binding_digest: String.t(),
            projection: %{fields: [String.t()], scopes: [String.t()]} | nil
          }
    @type egress :: %{
            domains: [String.t()],
            methods: [String.t()],
            schemes: [String.t()],
            private_ips: [String.t()]
          }
    @type storage :: %{paths: [String.t()], actions: [String.t()]}
    @type tool_server :: %{
            server_digest: String.t(),
            server_name: String.t(),
            tool_patterns: [String.t()],
            descriptions_digest: String.t() | nil
          }

    @type t :: %__MODULE__{
            vault: vault() | nil,
            egress: egress() | nil,
            storage: storage() | nil,
            tools: [String.t()],
            tool_servers: [tool_server()]
          }

    defstruct vault: nil, egress: nil, storage: nil, tools: [], tool_servers: []
  end

  defmodule Node do
    @moduledoc false

    @type t :: %__MODULE__{
            limits: Sanctum.Limits.t(),
            edges: %{optional(String.t()) => Sanctum.Authority.Blob.Edge.t()}
          }

    @enforce_keys [:limits]
    defstruct [:limits, edges: %{}]
  end

  @type t :: %__MODULE__{
          canonical: String.t(),
          nodes: %{optional(String.t()) => Node.t()}
        }

  defstruct canonical: "jcs-1", nodes: %{}

  @canonical "jcs-1"
  @ingress_key "@ingress"

  @type error ::
          {:invalid_json, term()}
          | {:unsupported_canonical, term()}
          | {:invalid_structure, String.t(), String.t()}
          | {:unknown_field, String.t()}
          | {:invalid_node_ref, String.t()}
          | {:invalid_edge_key, String.t(), String.t()}
          | {:dangling_edge, String.t(), String.t()}
          | {:invalid_limits, String.t(), {:invalid_limit, atom(), String.t()}}
          | {:invalid_resource, String.t(), String.t(), atom(), String.t()}

  # ============================================================================
  # Parse
  # ============================================================================

  @doc """
  Parse a blob from its JSON string or already-decoded map form.

  Fail-closed: returns the first error found; a valid result contains only
  validated, atom-keyed structures.
  """
  @spec parse(String.t() | map()) :: {:ok, t()} | {:error, error()}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        parse(decoded)

      {:ok, other} ->
        {:error, {:invalid_structure, "", "must be an object, got: #{inspect(other)}"}}

      {:error, err} ->
        {:error, {:invalid_json, err}}
    end
  end

  def parse(map) when is_map(map) and not is_struct(map) do
    with :ok <- strict_keys(map, ["canonical", "nodes"], ""),
         :ok <- check_canonical(map),
         {:ok, nodes_raw} <- fetch_object(map, "nodes", "nodes"),
         {:ok, nodes} <- parse_nodes(nodes_raw),
         :ok <- check_edge_targets(nodes) do
      {:ok, %__MODULE__{canonical: @canonical, nodes: nodes}}
    end
  end

  def parse(other), do: {:error, {:invalid_json, other}}

  @doc """
  Parse one edge from its map form (the shape `nodes[..].edges[..]` holds).
  """
  @spec parse_edge(map()) :: {:ok, Edge.t()} | {:error, error()}
  def parse_edge(map) when is_map(map) and not is_struct(map) do
    parse_edge("<wire>", "<wire>", map)
  end

  # ============================================================================
  # Encode — the exact inverse of parse/1
  # ============================================================================

  @doc """
  The blob as the JSON-ready map `parse/1` reads: `parse(to_map(blob)) ==
  {:ok, blob}` for every blob. Absent resources are omitted, never written
  as null.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{canonical: canonical, nodes: nodes}) do
    %{
      "canonical" => canonical,
      "nodes" =>
        Map.new(nodes, fn {ref, %Node{limits: limits, edges: edges}} ->
          {ref,
           %{
             "limits" => Limits.to_map(limits),
             "edges" => Map.new(edges, fn {key, edge} -> {key, edge_to_map(edge)} end)
           }}
        end)
    }
  end

  @doc "One edge as the JSON-ready map `parse_edge/1` reads."
  @spec edge_to_map(Edge.t()) :: map()
  def edge_to_map(%Edge{} = edge) do
    %{}
    |> put_resource("vault", edge.vault && vault_to_map(edge.vault))
    |> put_resource("egress", edge.egress && string_lists_to_map(edge.egress))
    |> put_resource("storage", edge.storage && string_lists_to_map(edge.storage))
    |> put_resource("tools", if(edge.tools == [], do: nil, else: edge.tools))
    |> put_resource(
      "tool_servers",
      if(edge.tool_servers == [],
        do: nil,
        else: Enum.map(edge.tool_servers, &tool_server_to_map/1)
      )
    )
  end

  defp put_resource(map, _key, nil), do: map
  defp put_resource(map, key, value), do: Map.put(map, key, value)

  defp vault_to_map(%{entry_id: id, binding_digest: digest, projection: projection}) do
    %{"entry_id" => id, "binding_digest" => digest}
    |> put_resource("projection", projection && string_lists_to_map(projection))
  end

  # `%{domains: [...], methods: [...]}` → `%{"domains" => [...], ...}`,
  # dropping nil lists (an absent key on the way in).
  defp string_lists_to_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp tool_server_to_map(server) do
    %{
      "server_digest" => server.server_digest,
      "server_name" => server.server_name,
      "tool_patterns" => server.tool_patterns
    }
    |> put_resource("descriptions_digest", server.descriptions_digest)
  end

  # ============================================================================
  # Clamp
  # ============================================================================

  @doc """
  Clamp every node's limits against a ceiling map (applied once, at
  Authority construction).
  """
  @spec clamp(t(), map()) :: t()
  def clamp(%__MODULE__{} = blob, ceiling) when is_map(ceiling) do
    nodes =
      Map.new(blob.nodes, fn {ref, node} ->
        {ref, %{node | limits: Limits.clamp(node.limits, ceiling)}}
      end)

    %{blob | nodes: nodes}
  end

  # ============================================================================
  # Lookup
  # ============================================================================

  @doc """
  The canonical edge-key spelling — the single composition point.

  The unnamed slot is the bare ref; a named need appends `|need`. Parse
  rejects any other spelling (trailing `|`, empty need, `|` inside a need),
  so each edge has exactly one representation.
  """
  @spec edge_key(String.t(), String.t()) :: String.t()
  def edge_key(ref, ""), do: ref
  def edge_key(ref, need) when is_binary(need), do: ref <> "|" <> need

  @doc """
  A node's `"@ingress"` edge.
  """
  @spec ingress(t(), String.t()) :: {:ok, Edge.t()} | {:error, :missing_ingress}
  def ingress(%__MODULE__{} = blob, node_ref) do
    case blob.nodes do
      %{^node_ref => %Node{edges: %{@ingress_key => edge}}} -> {:ok, edge}
      _ -> {:error, :missing_ingress}
    end
  end

  @doc """
  Look up the edge from `node_ref` to `target_ref` under `need` (`""` for
  the unnamed slot). The transition relation's only blob read.
  """
  @spec lookup_edge(t(), String.t(), String.t(), String.t()) ::
          {:ok, Edge.t()} | {:error, :no_edge}
  def lookup_edge(%__MODULE__{} = blob, node_ref, target_ref, need) do
    key = edge_key(target_ref, need)

    case blob.nodes do
      %{^node_ref => %Node{edges: %{^key => edge}}} -> {:ok, edge}
      _ -> {:error, :no_edge}
    end
  end

  @doc """
  A node by ref.
  """
  @spec node(t(), String.t()) :: {:ok, Node.t()} | {:error, :unknown_node}
  def node(%__MODULE__{} = blob, node_ref) do
    case blob.nodes do
      %{^node_ref => node} -> {:ok, node}
      _ -> {:error, :unknown_node}
    end
  end

  @doc """
  A node's limits by ref.
  """
  @spec node_limits(t(), String.t()) :: {:ok, Limits.t()} | {:error, :unknown_node}
  def node_limits(%__MODULE__{} = blob, node_ref) do
    with {:ok, node} <- node(blob, node_ref), do: {:ok, node.limits}
  end

  # ============================================================================
  # Private: node parsing
  # ============================================================================

  defp check_canonical(map) do
    case Map.get(map, "canonical") do
      @canonical -> :ok
      other -> {:error, {:unsupported_canonical, other}}
    end
  end

  defp parse_nodes(nodes_raw) do
    Enum.reduce_while(nodes_raw, {:ok, %{}}, fn {node_ref, node_raw}, {:ok, acc} ->
      case parse_node(node_ref, node_raw) do
        {:ok, node} -> {:cont, {:ok, Map.put(acc, node_ref, node)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_node(node_ref, node_raw) do
    path = "nodes[#{node_ref}]"

    with :ok <- validate_name_level_ref(node_ref, {:invalid_node_ref, node_ref}),
         {:ok, node_map} <- as_object(node_raw, path),
         :ok <- strict_keys(node_map, ["limits", "edges"], path),
         {:ok, limits_raw} <- fetch_object(node_map, "limits", "#{path}.limits"),
         {:ok, limits} <- parse_limits(node_ref, limits_raw),
         {:ok, edges_raw} <- fetch_object(node_map, "edges", "#{path}.edges"),
         {:ok, edges} <- parse_edges(node_ref, edges_raw) do
      {:ok, %Node{limits: limits, edges: edges}}
    end
  end

  defp parse_limits(node_ref, limits_raw) do
    case Limits.new(limits_raw) do
      {:ok, limits} -> {:ok, limits}
      {:error, err} -> {:error, {:invalid_limits, node_ref, err}}
    end
  end

  # A blob key is always name-level: activation carries code identity, so a
  # pinned version in a key would be a second, conflicting identity channel.
  defp validate_name_level_ref(ref, error) do
    case ComponentRef.parse(ref) do
      {:ok, %ComponentRef{version: nil}} -> :ok
      _ -> {:error, error}
    end
  end

  # ============================================================================
  # Private: edge parsing
  # ============================================================================

  defp parse_edges(node_ref, edges_raw) do
    Enum.reduce_while(edges_raw, {:ok, %{}}, fn {edge_key, edge_raw}, {:ok, acc} ->
      with :ok <- validate_edge_key(node_ref, edge_key),
           {:ok, edge} <- parse_edge(node_ref, edge_key, edge_raw) do
        {:cont, {:ok, Map.put(acc, edge_key, edge)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_edge_key(_node_ref, @ingress_key), do: :ok

  defp validate_edge_key(node_ref, key) do
    error = {:error, {:invalid_edge_key, node_ref, key}}

    # "@" is a reserved namespace; only the ingress literal is defined.
    if String.starts_with?(key, "@") do
      error
    else
      case String.split(key, "|", parts: 2) do
        [ref] ->
          with :ok <- validate_name_level_ref(ref, {:invalid_edge_key, node_ref, key}), do: :ok

        [ref, need] ->
          # The unnamed slot is spelled as the bare ref — an empty or
          # pipe-bearing need would give one edge two spellings.
          if need == "" or String.contains?(need, "|") do
            error
          else
            with :ok <- validate_name_level_ref(ref, {:invalid_edge_key, node_ref, key}), do: :ok
          end
      end
    end
  end

  @edge_resource_kinds %{
    "vault" => :vault,
    "egress" => :egress,
    "storage" => :storage,
    "tools" => :tools,
    "tool_servers" => :tool_servers
  }

  defp parse_edge(node_ref, edge_key, edge_raw) do
    path = "nodes[#{node_ref}].edges[#{edge_key}]"

    with {:ok, edge_map} <- as_object(edge_raw, path),
         :ok <- strict_keys(edge_map, Map.keys(@edge_resource_kinds), path),
         {:ok, resources} <- parse_resources(node_ref, edge_key, edge_map) do
      {:ok, struct(Edge, resources)}
    end
  end

  defp parse_resources(node_ref, edge_key, edge_map) do
    Enum.reduce_while(edge_map, {:ok, %{}}, fn {kind_str, raw}, {:ok, acc} ->
      kind = Map.fetch!(@edge_resource_kinds, kind_str)

      case validate_resource(kind, raw) do
        {:ok, validated} ->
          {:cont, {:ok, Map.put(acc, kind, validated)}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_resource, node_ref, edge_key, kind, reason}}}
      end
    end)
  end

  defp validate_resource(:vault, raw) when is_map(raw) do
    with :ok <- keys_or_reason(raw, ["entry_id", "binding_digest", "projection"]),
         {:ok, entry_id} <- required_string(raw, "entry_id"),
         {:ok, digest} <- required_string(raw, "binding_digest"),
         {:ok, projection} <- validate_projection(Map.get(raw, "projection")) do
      {:ok, %{entry_id: entry_id, binding_digest: digest, projection: projection}}
    end
  end

  defp validate_resource(:egress, raw) when is_map(raw) do
    string_list_resource(raw, [
      {"domains", :domains},
      {"methods", :methods},
      {"schemes", :schemes},
      {"private_ips", :private_ips}
    ])
  end

  defp validate_resource(:storage, raw) when is_map(raw) do
    string_list_resource(raw, [{"paths", :paths}, {"actions", :actions}])
  end

  defp validate_resource(:tools, raw) when is_list(raw) do
    if Enum.all?(raw, &(is_binary(&1) and &1 != "")) do
      {:ok, raw}
    else
      {:error, "must be a list of non-empty tool.action strings"}
    end
  end

  defp validate_resource(:tool_servers, raw) when is_list(raw) do
    raw
    |> Enum.reduce_while({:ok, []}, fn server_raw, {:ok, acc} ->
      case validate_tool_server(server_raw) do
        {:ok, server} -> {:cont, {:ok, [server | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, servers} -> {:ok, Enum.reverse(servers)}
      {:error, _} = err -> err
    end
  end

  defp validate_resource(_kind, raw), do: {:error, "unexpected shape: #{inspect(raw)}"}

  # `server_name` exists so a digest mismatch is distinguishable from
  # never-granted (drift explanation, §4.6 display, and the D8 baseline
  # anchor); matching stays digest-keyed. `descriptions_digest` is the D8
  # baseline over the granted tools' descriptions — advisory, absent when
  # the catalogue was unreachable at commit.
  defp validate_tool_server(raw) when is_map(raw) do
    with :ok <-
           keys_or_reason(raw, [
             "server_digest",
             "server_name",
             "tool_patterns",
             "descriptions_digest"
           ]),
         {:ok, digest} <- required_string(raw, "server_digest"),
         {:ok, name} <- required_string(raw, "server_name"),
         {:ok, patterns} <- required_string_list(raw, "tool_patterns"),
         :ok <- validate_tool_patterns(patterns),
         {:ok, descriptions} <- optional_string(raw, "descriptions_digest") do
      {:ok,
       %{
         server_digest: digest,
         server_name: name,
         tool_patterns: patterns,
         descriptions_digest: descriptions
       }}
    end
  end

  defp validate_tool_server(raw),
    do: {:error, "tool server must be an object, got: #{inspect(raw)}"}

  defp validate_tool_patterns(patterns) do
    case Enum.reject(patterns, &Sanctum.ToolPattern.valid?/1) do
      [] -> :ok
      bad -> {:error, "invalid tool patterns: #{inspect(bad)}"}
    end
  end

  defp validate_projection(nil), do: {:ok, nil}

  defp validate_projection(raw) when is_map(raw) do
    with :ok <- keys_or_reason(raw, ["fields", "scopes"]),
         {:ok, fields} <- optional_string_list(raw, "fields"),
         {:ok, scopes} <- optional_string_list(raw, "scopes") do
      {:ok, %{fields: fields, scopes: scopes}}
    end
  end

  defp validate_projection(raw),
    do: {:error, "projection must be an object, got: #{inspect(raw)}"}

  defp string_list_resource(raw, keys) do
    with :ok <- keys_or_reason(raw, Enum.map(keys, &elem(&1, 0))) do
      Enum.reduce_while(keys, {:ok, %{}}, fn {str_key, atom_key}, {:ok, acc} ->
        case optional_string_list(raw, str_key) do
          {:ok, list} -> {:cont, {:ok, Map.put(acc, atom_key, list)}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  # ============================================================================
  # Private: dangling-edge check
  # ============================================================================

  # Every edge target must have its own node entry — a bound cursor must
  # always land on a node whose limits exist.
  defp check_edge_targets(nodes) do
    Enum.reduce_while(nodes, :ok, fn {node_ref, %Node{edges: edges}}, :ok ->
      edges
      |> Map.keys()
      |> Enum.reject(&(&1 == @ingress_key))
      |> Enum.find(fn key ->
        [target | _] = String.split(key, "|", parts: 2)
        not Map.has_key?(nodes, target)
      end)
      |> case do
        nil -> {:cont, :ok}
        key -> {:halt, {:error, {:dangling_edge, node_ref, key}}}
      end
    end)
  end

  # ============================================================================
  # Private: strict-shape helpers
  # ============================================================================

  defp strict_keys(map, allowed, path) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, {:unknown_field, join_path(path, to_string(key))}}
    end
  end

  defp keys_or_reason(map, allowed) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, "unknown key #{inspect(key)}"}
    end
  end

  defp fetch_object(map, key, path) do
    case Map.get(map, key) do
      value when is_map(value) and not is_struct(value) -> {:ok, value}
      _ -> {:error, {:invalid_structure, path, "must be an object"}}
    end
  end

  defp as_object(value, _path) when is_map(value) and not is_struct(value), do: {:ok, value}
  defp as_object(_value, path), do: {:error, {:invalid_structure, path, "must be an object"}}

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, "#{key} must be a non-empty string, got: #{inspect(other)}"}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, "#{key} must be a non-empty string when present, got: #{inspect(other)}"}
    end
  end

  defp required_string_list(map, key) do
    case Map.get(map, key) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, "#{key} must be a list of strings"}
        end

      other ->
        {:error, "#{key} must be a list of strings, got: #{inspect(other)}"}
    end
  end

  defp optional_string_list(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, []}
      _present -> required_string_list(map, key)
    end
  end

  defp join_path("", key), do: key
  defp join_path(path, key), do: "#{path}.#{key}"
end
