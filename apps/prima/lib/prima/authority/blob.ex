# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Prima.Authority.Blob do
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

  alias Prima.ComponentRef
  alias Prima.Limits

  defmodule Edge do
    @moduledoc """
    The resources one consent edge grants. `"@ingress"` and resource-less
    invocation edges are all-empty instances of the same type — an edge that
    authorizes invocation while granting nothing is representable.

    A vault resource is either **bound** — an entry and the binding digest
    the consent approved — or **selected**: the entry that the edge's
    target binds on the ingress of its own owner profile of the named
    label, pinned to a binding digest when the consent pinned one.
    Loading a consent at root turns a selection into a bound resource when
    that profile is active and its ingress carries a matching entry, and
    pins the lender (`profile_id`, `consent_id`) so a later revoke or
    revision refuses the next unseal; a selection that does not resolve
    stays a selection, and a run under it answers setup_required.
    """

    @type projection :: %{fields: [String.t()], scopes: [String.t()]} | nil

    @type lender :: %{profile_id: String.t(), consent_id: String.t()}

    @type bound_vault :: %{
            required(:entry_id) => String.t(),
            required(:binding_digest) => String.t(),
            required(:projection) => projection(),
            optional(:lender) => lender()
          }

    @type selected_vault :: %{
            via: %{label: String.t(), binding_digest: String.t() | nil},
            projection: projection()
          }

    @type vault :: bound_vault() | selected_vault()
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

    # A nil edge (an authority with `resources: :none`) and a nil resource
    # group read as empty lists, and an empty list grants nothing.

    @doc "The egress domains the edge allows; empty for a nil edge or egress group."
    @spec domains(t() | nil) :: [String.t()]
    def domains(edge), do: egress(edge, :domains)

    @doc "The storage paths the edge allows; empty for a nil edge or storage group."
    @spec paths(t() | nil) :: [String.t()]
    def paths(edge), do: storage(edge, :paths)

    @doc "The storage actions the edge allows; empty for a nil edge or storage group."
    @spec actions(t() | nil) :: [String.t()]
    def actions(edge), do: storage(edge, :actions)

    @doc "The tool actions the edge grants; empty for a nil edge."
    @spec tools(t() | nil) :: [String.t()]
    def tools(nil), do: []
    def tools(%__MODULE__{tools: tools}), do: tools

    defp egress(nil, _key), do: []
    defp egress(%__MODULE__{egress: nil}, _key), do: []
    defp egress(%__MODULE__{egress: egress}, key), do: Map.get(egress, key, [])

    defp storage(nil, _key), do: []
    defp storage(%__MODULE__{storage: nil}, _key), do: []
    defp storage(%__MODULE__{storage: storage}, key), do: Map.get(storage, key, [])
  end

  defmodule Node do
    @moduledoc false

    @type t :: %__MODULE__{
            limits: Prima.Limits.t(),
            edges: %{optional(String.t()) => Prima.Authority.Blob.Edge.t()}
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

  @doc """
  Returns the reserved ingress edge-key string used by consent writers
  and profile-tool node construction. `ingress/2` reads this edge.
  """
  @spec ingress_key() :: String.t()
  def ingress_key, do: @ingress_key

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

      {:ok, _other} ->
        {:error, {:invalid_structure, "", "must be an object"}}

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

  defp vault_to_map(%{entry_id: id, binding_digest: digest, projection: projection} = vault) do
    %{"entry_id" => id, "binding_digest" => digest}
    |> put_resource("projection", projection && string_lists_to_map(projection))
    |> put_resource("lender", lender_to_map(Map.get(vault, :lender)))
  end

  defp vault_to_map(%{via: %{label: label, binding_digest: digest}, projection: projection}) do
    via = %{"label" => label} |> put_resource("binding_digest", digest)

    %{"via" => via}
    |> put_resource("projection", projection && string_lists_to_map(projection))
  end

  defp lender_to_map(%{profile_id: profile_id, consent_id: consent_id}),
    do: %{"profile_id" => profile_id, "consent_id" => consent_id}

  defp lender_to_map(_), do: nil

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
  The target ref an edge key names: the bare ref for the unnamed slot, the
  ref before `|need` for a named one. The ingress key names no target.
  """
  @spec edge_target(String.t()) :: {:ok, String.t()} | :ingress
  def edge_target(@ingress_key), do: :ingress
  def edge_target(key) when is_binary(key), do: {:ok, key |> String.split("|", parts: 2) |> hd()}

  @doc """
  Whether a vault resource is bound to an entry (as opposed to selected
  from another profile, or absent).
  """
  @spec bound_vault?(Edge.vault() | nil) :: boolean()
  def bound_vault?(%{entry_id: _}), do: true
  def bound_vault?(_), do: false

  @doc """
  Entry ids that appear on more than one bound vault with unequal
  binding digests. Commit and the loader refuse rather than pick.
  """
  @spec entry_digest_conflicts(t()) :: [String.t()]
  def entry_digest_conflicts(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.flat_map(fn {_ref, %Node{edges: edges}} ->
      for {_key, %Edge{vault: %{entry_id: id, binding_digest: digest}}} <- edges,
          do: {id, digest}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_id, digests} -> digests |> Enum.uniq() |> length() > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  The blob with every edge rewritten by `fun`, which receives the node
  ref, the edge key and the edge and answers the edge to keep.
  """
  @spec map_edges(t(), (String.t(), String.t(), Edge.t() -> Edge.t())) :: t()
  def map_edges(%__MODULE__{nodes: nodes} = blob, fun) when is_function(fun, 3) do
    %{
      blob
      | nodes:
          Map.new(nodes, fn {ref, %Node{edges: edges} = node} ->
            {ref,
             %{node | edges: Map.new(edges, fn {key, edge} -> {key, fun.(ref, key, edge)} end)}}
          end)
    }
  end

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

  defp validate_resource(:vault, %{"via" => via} = raw) when is_map(raw) do
    with :ok <- keys_or_reason(raw, ["via", "projection"]),
         {:ok, via_map} <- as_object(via, "via"),
         :ok <- keys_or_reason(via_map, ["label", "binding_digest"]),
         {:ok, label} <- required_string(via_map, "label"),
         {:ok, digest} <- optional_string(via_map, "binding_digest"),
         {:ok, projection} <- validate_projection(Map.get(raw, "projection")) do
      {:ok, %{via: %{label: label, binding_digest: digest}, projection: projection}}
    end
  end

  defp validate_resource(:vault, raw) when is_map(raw) do
    with :ok <- keys_or_reason(raw, ["entry_id", "binding_digest", "projection", "lender"]),
         {:ok, entry_id} <- required_string(raw, "entry_id"),
         {:ok, digest} <- required_string(raw, "binding_digest"),
         {:ok, projection} <- validate_projection(Map.get(raw, "projection")),
         {:ok, lender} <- validate_lender(Map.get(raw, "lender")) do
      vault = %{entry_id: entry_id, binding_digest: digest, projection: projection}
      {:ok, if(lender, do: Map.put(vault, :lender, lender), else: vault)}
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

  defp validate_resource(_kind, _raw), do: {:error, "unexpected shape"}

  defp validate_lender(nil), do: {:ok, nil}

  defp validate_lender(raw) when is_map(raw) do
    with :ok <- keys_or_reason(raw, ["profile_id", "consent_id"]),
         {:ok, profile_id} <- required_string(raw, "profile_id"),
         {:ok, consent_id} <- required_string(raw, "consent_id") do
      {:ok, %{profile_id: profile_id, consent_id: consent_id}}
    end
  end

  defp validate_lender(_), do: {:error, "lender must be an object"}

  # Match grants by server digest. server_name identifies configuration
  # drift; descriptions_digest records an advisory description baseline
  # when the catalog is reachable at commit.
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

  defp validate_tool_server(_raw), do: {:error, "tool server must be an object"}

  defp validate_tool_patterns(patterns) do
    case Enum.reject(patterns, &Prima.ToolPattern.valid?/1) do
      [] -> :ok
      bad -> {:error, "invalid tool patterns: #{Enum.join(bad, ", ")}"}
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

  defp validate_projection(_raw), do: {:error, "projection must be an object"}

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
      key -> {:error, "unknown key \"#{key}\""}
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
      _other -> {:error, "#{key} must be a non-empty string"}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "#{key} must be a non-empty string when present"}
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

      _other ->
        {:error, "#{key} must be a list of strings"}
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
