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
  alias Prima.Destination
  alias Prima.Limits
  alias Prima.Manifest.Needs
  alias Prima.Manifest.Provides

  defmodule Edge do
    @moduledoc """
    The resources one consent edge grants. `"@ingress"` and resource-less
    invocation edges are all-empty instances of the same type — an edge that
    authorizes invocation while granting nothing is representable.

    A vault resource is one of three:

      * **bound** — an entry, the binding digest the consent approved, the
        entry's `scope` (`"athanor"` for an athanor's own entry,
        `"instance"` for an instance entry), its `destination`
        (`Prima.Destination`), the need's `attach` rule
        (`Prima.Manifest.Needs`, nil for a disclose-only need) and the
        binding's own `binding_key` (`binding_key/3`). Beside it, under
        `named`, an edge may bind further entries by account name, each
        its own bound resource with its own key; a call names one
        (`vault_for/2`) and gets the default otherwise.
      * **selected** — the entry that the edge's target binds on the
        ingress of its own owner profile of the named label, pinned to a
        binding digest when the consent pinned one. Loading a consent at
        root turns a selection into a bound resource when that profile is
        active and its ingress carries a matching entry: the bound
        resource carries the borrower's `binding_key`, where it sits, and
        pins the `lender` (`profile_id`, `consent_id` and the lender's own
        `binding_key`), so a later revoke or revision refuses the next
        unseal and a use answers to both bindings; a selection that does
        not resolve stays a selection, and a run under it answers
        setup_required.
      * **provided** — a publisher's public configuration
        (`Prima.Manifest.Provides`): its destination, its values and the
        rule they are attached by.
    """

    @type projection :: %{fields: [String.t()], scopes: [String.t()]} | nil

    @type lender :: %{profile_id: String.t(), consent_id: String.t(), binding_key: String.t()}

    @type attach :: Prima.Manifest.Needs.attach() | nil

    @type bound_vault :: %{
            required(:entry_id) => String.t(),
            required(:binding_digest) => String.t(),
            required(:scope) => String.t(),
            required(:binding_key) => String.t(),
            required(:destination) => Prima.Destination.t(),
            required(:attach) => attach(),
            required(:projection) => projection(),
            optional(:lender) => lender(),
            optional(:named) => %{optional(String.t()) => bound_vault()}
          }

    @type selected_vault :: %{
            via: %{label: String.t(), binding_digest: String.t() | nil},
            projection: projection()
          }

    @type provided_vault :: %{
            provided: %{
              destination: Prima.Destination.t(),
              values: %{optional(String.t()) => String.t()},
              attach: Prima.Manifest.Needs.attach()
            }
          }

    @type vault :: bound_vault() | selected_vault() | provided_vault()
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
  @scopes ["athanor", "instance"]
  @default_slot "default"
  @name_slot "name:"
  @max_name_bytes 128

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

  An edge read alone has no place in a graph, so its binding keys are held
  to their grammar but not to a node, an edge or a slot: an Authority's
  `resources` are the edge its cursor was reached through, and a child's
  vault is the one binding its call picked, named or not.
  """
  @spec parse_edge(map()) :: {:ok, Edge.t()} | {:error, error()}
  def parse_edge(map) when is_map(map) and not is_struct(map) do
    parse_edge(:unplaced, "<wire>", "<wire>", map)
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

  @doc """
  One vault resource as the JSON-ready map an edge's `vault` holds, which
  parsing reads back. A disclose-only binding's nil `attach` is omitted,
  as every absent value is: the canonical form (`Prima.JCS`) holds no
  null, and an absent rule reads back as nil.
  """
  @spec vault_to_map(Edge.vault()) :: map()
  def vault_to_map(%{entry_id: id, binding_digest: digest} = vault) do
    %{
      "entry_id" => id,
      "binding_digest" => digest,
      "scope" => vault.scope,
      "binding_key" => vault.binding_key,
      "destination" => Destination.to_map(vault.destination)
    }
    |> put_resource("attach", vault.attach && Needs.attach_to_map(vault.attach))
    |> put_resource("projection", vault.projection && string_lists_to_map(vault.projection))
    |> put_resource("lender", lender_to_map(Map.get(vault, :lender)))
    |> put_resource("named", named_to_map(Map.get(vault, :named)))
  end

  def vault_to_map(%{via: %{label: label, binding_digest: digest}, projection: projection}) do
    via = %{"label" => label} |> put_resource("binding_digest", digest)

    %{"via" => via}
    |> put_resource("projection", projection && string_lists_to_map(projection))
  end

  def vault_to_map(%{provided: %{destination: destination, values: values, attach: attach}}) do
    %{
      "provided" => %{
        "destination" => Destination.to_map(destination),
        "values" => values,
        "attach" => Needs.attach_to_map(attach)
      }
    }
  end

  defp lender_to_map(%{profile_id: profile_id, consent_id: consent_id, binding_key: key}),
    do: %{"profile_id" => profile_id, "consent_id" => consent_id, "binding_key" => key}

  defp lender_to_map(_), do: nil

  defp named_to_map(nil), do: nil

  defp named_to_map(named),
    do: Map.new(named, fn {name, vault} -> {name, vault_to_map(vault)} end)

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
  Whether a vault resource is bound: to an entry, or to a publisher's
  provided configuration (as opposed to selected from another profile,
  or absent).
  """
  @spec bound_vault?(Edge.vault() | nil) :: boolean()
  def bound_vault?(%{entry_id: _}), do: true
  def bound_vault?(%{provided: _}), do: true
  def bound_vault?(_), do: false

  @doc """
  The binding a call through `edge` uses: the named account `connection`
  names, or the default when it names none. The default comes without
  its `named` bindings, so a child holds the one binding its call picked.
  A name the edge does not bind — on an edge with no vault, a selection
  or a provided resource too — is `{:error, :connection_not_granted}`.
  """
  @spec vault_for(Edge.t() | nil, String.t() | nil) ::
          {:ok, Edge.vault() | nil} | {:error, :connection_not_granted}
  def vault_for(nil, nil), do: {:ok, nil}
  def vault_for(%Edge{vault: vault}, nil), do: {:ok, without_named(vault)}

  def vault_for(%Edge{vault: %{named: named}}, connection) when is_binary(connection) do
    case Map.fetch(named, connection) do
      {:ok, vault} -> {:ok, vault}
      :error -> {:error, :connection_not_granted}
    end
  end

  def vault_for(_edge, _connection), do: {:error, :connection_not_granted}

  defp without_named(%{named: _} = vault), do: Map.delete(vault, :named)
  defp without_named(vault), do: vault

  @doc """
  The key of the binding `slot` names on the edge `edge_key` of the node
  `node_ref`: `<node>|<edge key>|default` for the unnamed binding (a nil
  slot) and `<node>|<edge key>|name:<name>` for a named one. The edge key
  is `edge_key/2`'s, `"@ingress"` for a root's own binding. One binding,
  one key, so two edges or two names of one entry are two bindings.
  """
  @spec binding_key(String.t(), String.t(), String.t() | nil) :: String.t()
  def binding_key(node_ref, edge_key, nil),
    do: node_ref <> "|" <> edge_key <> "|" <> @default_slot

  def binding_key(node_ref, edge_key, name) when is_binary(name),
    do: node_ref <> "|" <> edge_key <> "|" <> @name_slot <> name

  @doc """
  The node, edge key and slot a binding key spells: the slot is nil for
  the unnamed binding and the name for a named one. `:error` for a key
  outside the grammar: a node that is no name-level ref, an edge key
  `parse/1` would refuse, or a slot that is neither `default` nor
  `name:` and a valid account name.
  """
  @spec parse_binding_key(term()) :: {:ok, {String.t(), String.t(), String.t() | nil}} | :error
  def parse_binding_key(key) when is_binary(key) do
    with [node_ref, rest] <- String.split(key, "|", parts: 2),
         [_ | _] = parts <- String.split(rest, "|"),
         {slot, edge_parts} = List.pop_at(parts, -1),
         edge_key = Enum.join(edge_parts, "|"),
         :ok <- validate_name_level_ref(node_ref, :error),
         :ok <- validate_edge_key(node_ref, edge_key),
         {:ok, name} <- read_slot(slot) do
      {:ok, {node_ref, edge_key, name}}
    else
      _ -> :error
    end
  end

  def parse_binding_key(_key), do: :error

  @doc """
  Whether `name` is an account name a named binding may carry: 1 to 128
  bytes of text, no control character and no `|`, which the binding key
  reserves.
  """
  @spec valid_account_name?(term()) :: boolean()
  def valid_account_name?(name) when is_binary(name) do
    byte_size(name) in 1..@max_name_bytes and String.valid?(name) and
      not String.contains?(name, "|") and not String.match?(name, ~r/[\x00-\x1F\x7F]/)
  end

  def valid_account_name?(_name), do: false

  defp read_slot(@default_slot), do: {:ok, nil}

  defp read_slot(@name_slot <> name) do
    if valid_account_name?(name), do: {:ok, name}, else: :error
  end

  defp read_slot(_slot), do: :error

  @doc """
  Entry ids that appear on more than one bound vault, named bindings
  included, with unequal binding digests. Commit and the loader refuse
  rather than pick.
  """
  @spec entry_digest_conflicts(t()) :: [String.t()]
  def entry_digest_conflicts(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.flat_map(fn {_ref, %Node{edges: edges}} ->
      Enum.flat_map(edges, fn {_key, %Edge{vault: vault}} -> entry_digests(vault) end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_id, digests} -> digests |> Enum.uniq() |> length() > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp entry_digests(%{entry_id: id, binding_digest: digest} = vault) do
    named = vault |> Map.get(:named, %{}) |> Map.values()
    [{id, digest} | Enum.flat_map(named, &entry_digests/1)]
  end

  defp entry_digests(_vault), do: []

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
           {:ok, edge} <- parse_edge(:placed, node_ref, edge_key, edge_raw) do
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

  # `placement` is `:placed` for an edge of a parsed graph, whose node and
  # edge key a binding key must name, and `:unplaced` for an edge read
  # alone (`parse_edge/1`).
  defp parse_edge(placement, node_ref, edge_key, edge_raw) do
    path = "nodes[#{node_ref}].edges[#{edge_key}]"

    with {:ok, edge_map} <- as_object(edge_raw, path),
         :ok <- strict_keys(edge_map, Map.keys(@edge_resource_kinds), path),
         {:ok, resources} <- parse_resources(placement, node_ref, edge_key, edge_map) do
      {:ok, struct(Edge, resources)}
    end
  end

  defp parse_resources(placement, node_ref, edge_key, edge_map) do
    Enum.reduce_while(edge_map, {:ok, %{}}, fn {kind_str, raw}, {:ok, acc} ->
      kind = Map.fetch!(@edge_resource_kinds, kind_str)

      validated =
        if kind == :vault,
          do: validate_vault(raw, place(placement, node_ref, edge_key)),
          else: validate_resource(kind, raw)

      case validated do
        {:ok, validated} ->
          {:cont, {:ok, Map.put(acc, kind, validated)}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_resource, node_ref, edge_key, kind, reason}}}
      end
    end)
  end

  defp place(:placed, node_ref, edge_key), do: {node_ref, edge_key}
  defp place(:unplaced, _node_ref, _edge_key), do: :unplaced

  # A selection binds the lender's entry when it resolves; it names no
  # account of its own and carries no binding key until the loader
  # resolves it where it sits.
  defp validate_vault(%{"via" => via} = raw, _place) do
    with :ok <- refuse_named(raw, "a selection binds no named accounts"),
         :ok <- keys_or_reason(raw, ["via", "projection"]),
         {:ok, via_map} <- as_object(via, "via"),
         :ok <- keys_or_reason(via_map, ["label", "binding_digest"]),
         {:ok, label} <- required_string(via_map, "label"),
         {:ok, digest} <- optional_string(via_map, "binding_digest"),
         {:ok, projection} <- validate_projection(Map.get(raw, "projection")) do
      {:ok, %{via: %{label: label, binding_digest: digest}, projection: projection}}
    end
  end

  defp validate_vault(%{"provided" => provided} = raw, _place) do
    with :ok <- refuse_named(raw, "provided configuration binds no named accounts"),
         :ok <- keys_or_reason(raw, ["provided"]),
         {:ok, provided} <- as_reason_object(provided, "provided must be an object"),
         :ok <- keys_or_reason(provided, ["destination", "values", "attach"]),
         {:ok, attach} <- required_attach(provided),
         {:ok, entry} <- read_provided(Map.delete(provided, "attach")) do
      {:ok, %{provided: Map.put(entry, :attach, attach)}}
    end
  end

  defp validate_vault(raw, place) when is_map(raw) and not is_struct(raw) do
    with {:ok, vault} <- validate_bound(raw, place, nil),
         {:ok, named} <- validate_named(Map.get(raw, "named"), place) do
      {:ok, if(named, do: Map.put(vault, :named, named), else: vault)}
    end
  end

  defp validate_vault(_raw, _place), do: {:error, "unexpected shape"}

  @bound_keys ~w(entry_id binding_digest scope binding_key destination attach projection)

  # One bound resource: the default (`slot` nil), whose map may also carry
  # a lender and named bindings, or the named binding `slot`, which carries
  # neither.
  defp validate_bound(raw, place, slot) do
    allowed = if slot, do: @bound_keys, else: @bound_keys ++ ["lender", "named"]

    with :ok <- keys_or_reason(raw, allowed),
         {:ok, entry_id} <- required_string(raw, "entry_id"),
         {:ok, digest} <- required_string(raw, "binding_digest"),
         {:ok, scope} <- validate_scope(raw["scope"]),
         {:ok, binding_key} <- validate_binding_key(raw["binding_key"], place, slot),
         {:ok, destination} <- validate_destination(raw["destination"]),
         {:ok, attach} <- optional_attach(raw),
         {:ok, projection} <- validate_projection(Map.get(raw, "projection")),
         {:ok, lender} <- validate_lender(Map.get(raw, "lender")) do
      vault = %{
        entry_id: entry_id,
        binding_digest: digest,
        scope: scope,
        binding_key: binding_key,
        destination: destination,
        attach: attach,
        projection: projection
      }

      {:ok, if(lender, do: Map.put(vault, :lender, lender), else: vault)}
    end
  end

  defp validate_named(nil, _place), do: {:ok, nil}

  defp validate_named(named, place) when is_map(named) and map_size(named) > 0 do
    with :ok <- distinct_names(Map.keys(named)) do
      Enum.reduce_while(named, {:ok, %{}}, fn {name, raw}, {:ok, acc} ->
        with true <- valid_account_name?(name),
             {:ok, raw} <- as_reason_object(raw, "a named binding must be an object"),
             {:ok, vault} <- validate_bound(raw, place, name) do
          {:cont, {:ok, Map.put(acc, name, vault)}}
        else
          false -> {:halt, {:error, "named binding #{inspect(name)} is not an account name"}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_named(_named, _place), do: {:error, "named must be a non-empty object"}

  # Two names a person would read as one are one name repeated.
  defp distinct_names(names) do
    folded = Enum.map(names, &if(is_binary(&1), do: String.downcase(&1), else: &1))

    if length(Enum.uniq(folded)) == length(folded),
      do: :ok,
      else: {:error, "a named account repeats"}
  end

  defp refuse_named(raw, reason) do
    if Map.has_key?(raw, "named"), do: {:error, reason}, else: :ok
  end

  defp validate_scope(scope) when scope in @scopes, do: {:ok, scope}
  defp validate_scope(_scope), do: {:error, "scope must be athanor or instance"}

  # Placed, a binding key names the node and edge it sits on and its own
  # slot: `default` for the unnamed binding, `name:<name>` for a named
  # one. Unplaced, it is held to the grammar alone.
  defp validate_binding_key(key, :unplaced, _slot) do
    case parse_binding_key(key) do
      {:ok, _parts} -> {:ok, key}
      :error -> {:error, "binding_key is not a binding key"}
    end
  end

  defp validate_binding_key(key, {node_ref, edge_key}, slot) do
    if key == binding_key(node_ref, edge_key, slot),
      do: {:ok, key},
      else: {:error, "binding_key must name this node, edge and slot"}
  end

  defp validate_destination(raw) do
    case Destination.from_map(raw) do
      {:ok, destination} -> {:ok, destination}
      {:error, {:invalid_destination, reason}} -> {:error, "destination: #{reason_kind(reason)}"}
    end
  end

  # A disclose-only binding's rule is nil: written absent, and read back
  # from an absent or a null member alike.
  defp optional_attach(raw) do
    case Map.get(raw, "attach") do
      nil -> {:ok, nil}
      rule -> read_attach(rule)
    end
  end

  defp required_attach(raw) do
    case Map.get(raw, "attach") do
      nil -> {:error, "provided configuration must name its attach rule"}
      rule -> read_attach(rule)
    end
  end

  defp read_attach(rule) do
    case Needs.read_attach(rule) do
      {:ok, rule} -> {:ok, rule}
      {:error, reason} -> {:error, "attach: #{reason_kind(reason)}"}
    end
  end

  defp read_provided(raw) do
    case Provides.read_entry(raw) do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> {:error, "provided: #{reason_kind(reason)}"}
    end
  end

  # What kind of refusal a reader answered, never the value it refused:
  # the message is rendered, and the value is the stored blob's.
  defp reason_kind({:invalid_destination, reason}), do: "destination " <> reason_kind(reason)
  defp reason_kind({kind, _value}) when is_atom(kind), do: Atom.to_string(kind)
  defp reason_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp reason_kind(_reason), do: "malformed"

  defp as_reason_object(value, _reason) when is_map(value) and not is_struct(value),
    do: {:ok, value}

  defp as_reason_object(_value, reason), do: {:error, reason}

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

  # The lender's binding is in the lender's own graph, so its key is held
  # to the grammar here and to its place by the lender's revision.
  defp validate_lender(raw) when is_map(raw) do
    with :ok <- keys_or_reason(raw, ["profile_id", "consent_id", "binding_key"]),
         {:ok, profile_id} <- required_string(raw, "profile_id"),
         {:ok, consent_id} <- required_string(raw, "consent_id"),
         {:ok, key} <- required_string(raw, "binding_key"),
         {:ok, key} <- validate_binding_key(key, :unplaced, nil) do
      {:ok, %{profile_id: profile_id, consent_id: consent_id, binding_key: key}}
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
      keys = edges |> Map.keys() |> Enum.reject(&(&1 == @ingress_key))

      keys
      |> Enum.find_index(fn key ->
        [target | _] = String.split(key, "|", parts: 2)
        not Map.has_key?(nodes, target)
      end)
      |> case do
        nil -> {:cont, :ok}
        index -> {:halt, {:error, {:dangling_edge, node_ref, Enum.at(keys, index)}}}
      end
    end)
  end

  # ============================================================================
  # Private: strict-shape helpers
  # ============================================================================

  # Both answer the first key outside `allowed` by its index, so a nil key
  # is unknown, not read as "no unknown key".
  defp strict_keys(map, allowed, path) do
    case unknown_key(map, allowed) do
      :none -> :ok
      {:unknown, key} -> {:error, {:unknown_field, join_path(path, to_string(key))}}
    end
  end

  defp keys_or_reason(map, allowed) do
    case unknown_key(map, allowed) do
      :none -> :ok
      {:unknown, key} -> {:error, "unknown key \"#{key}\""}
    end
  end

  defp unknown_key(map, allowed) do
    keys = Map.keys(map)

    case Enum.find_index(keys, &(&1 not in allowed)) do
      nil -> :none
      index -> {:unknown, Enum.at(keys, index)}
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
