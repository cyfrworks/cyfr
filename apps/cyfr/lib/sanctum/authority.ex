# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority do
  @moduledoc """
  The runtime authority of one execution in a consented chain.

  An Authority is built once per root execution from a profile and its
  consent's resolved policy blob, then travels the chain by value: every
  child transition returns a *new* Authority. What a node may do is decided
  entirely by the cursor position and the edge resources captured here —
  a `Sanctum.Context` supplies tenant binding and attribution, never
  in-chain authorization.

  ## Cursor

  `{:bound, node_ref}` — the execution is a node of the consented graph;
  its consumable resources are exactly the edge it was reached through.
  `:unbound` — the execution fell off the graph (dynamic dispatch to an
  unconsented component). Unbound is structural: `policy` and `resources`
  become `:none` and the identity fields nil, so no descendant *can*
  consult a consent node. Boundness is never regained.

  ## ZeroAuthority

  `zero/0` is the authority of code with no applicable profile: no
  resources, no control-plane access, only inert invocation, under the
  `zero_limits/0` constants. Those constants are deliberately literals —
  `Sanctum.Limits.defaults/1` is looser on three of the seven fields
  (timeout, batch_timeout, max_concurrent_tasks), so deriving them would
  silently widen what unconsented code gets.

  ## Root budget

  `budget` names the root-keyed invoke budget (`Sanctum.Authority.Budget`):
  an id and a cap, created once per root and copied into every child
  Authority — including unbound ones — so concurrency is bounded per root
  tree, not per level, and the bound survives closure capture across spawn
  layers. The counter behind the id is node-local; the struct itself is
  plain data.

  ## Wire

  An Authority is plain data end to end — `to_wire/1` gives the JCS-ready
  map of its twelve fields and `from_wire/1` reads it back — so a worker
  on another node can run under exactly the authority the root resolved.
  """

  alias Sanctum.Authority.Blob
  alias Sanctum.Authority.Budget
  alias Sanctum.Limits

  @type cursor :: {:bound, String.t()} | :unbound
  @type invoke_mode :: :open_inert | :edge_only
  @type profile_kind :: :owner | :public

  @type profile :: %{
          required(:profile_id) => String.t(),
          required(:consent_id) => String.t(),
          required(:source_ref) => String.t(),
          required(:kind) => profile_kind(),
          required(:invoke_mode) => invoke_mode(),
          required(:activation) => %{optional(String.t()) => String.t()}
        }

  @type root_error ::
          {:invalid_profile, atom()}
          | {:unknown_source_node, String.t()}
          | {:missing_ingress, String.t()}

  @type t :: %__MODULE__{
          profile_id: String.t() | nil,
          consent_id: String.t() | nil,
          source_ref: String.t() | nil,
          profile_kind: profile_kind() | nil,
          policy: Blob.t() | :none,
          activation: %{optional(String.t()) => String.t()},
          invoke_mode: invoke_mode(),
          cursor: cursor(),
          resources: Blob.Edge.t() | :none,
          chain: [String.t()],
          depth: non_neg_integer(),
          budget: Budget.t()
        }

  defstruct [
    :profile_id,
    :consent_id,
    :source_ref,
    :profile_kind,
    :policy,
    :activation,
    :invoke_mode,
    :cursor,
    :resources,
    :chain,
    :depth,
    :budget
  ]

  # Chain depth bound. Must sit strictly below the per-tenant execution
  # semaphore slot count (default 16): a parent holds its slot while
  # blocking on a child, so a deeper chain than there are slots would
  # self-deadlock a tenant. Asserted against live config in the opus suite.
  @depth_cap 8

  # ZeroAuthority limits — absolute literal constants (see moduledoc).
  @zero_limits %Limits{
    timeout: "30s",
    max_memory_bytes: 67_108_864,
    max_request_size: 1_048_576,
    max_response_size: 5_242_880,
    rate_limit: %{requests: 100, window: "1m"},
    max_concurrent_tasks: 1,
    batch_timeout: "30s"
  }

  @valid_kinds [:owner, :public]
  @valid_invoke_modes [:open_inert, :edge_only]

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  The authority of a component with no applicable profile.
  """
  @spec zero() :: t()
  def zero do
    %__MODULE__{
      profile_id: nil,
      consent_id: nil,
      source_ref: nil,
      profile_kind: nil,
      policy: :none,
      activation: %{},
      invoke_mode: :open_inert,
      cursor: :unbound,
      resources: :none,
      chain: [],
      depth: 0,
      budget: Budget.new(@zero_limits.max_concurrent_tasks)
    }
  end

  @doc """
  The ZeroAuthority limit constants.
  """
  @spec zero_limits() :: Limits.t()
  def zero_limits, do: @zero_limits

  @doc """
  Build the root Authority for a profile from its consent's resolved blob.

  The blob is ceiling-clamped here — an Authority is clamped by
  construction, never at use time. Fails closed when the blob has no node
  for the profile's source ref or that node lacks an `"@ingress"` edge
  (authority always comes from an edge, even for direct invocation), and
  when a public profile is not `:edge_only`.

  Options: `:ceiling` overrides the platform ceiling (tests only).
  """
  @spec root(profile(), Blob.t(), keyword()) :: {:ok, t()} | {:error, root_error()}
  def root(profile, %Blob{} = blob, opts \\ []) do
    ceiling = Keyword.get(opts, :ceiling) || Sanctum.Policy.Ceiling.platform_ceiling()

    with :ok <- validate_profile(profile),
         clamped = Blob.clamp(blob, ceiling),
         {:ok, source_node} <- fetch_source_node(clamped, profile.source_ref),
         {:ok, ingress_edge} <- fetch_ingress(clamped, profile.source_ref) do
      {:ok,
       %__MODULE__{
         profile_id: profile.profile_id,
         consent_id: profile.consent_id,
         source_ref: profile.source_ref,
         profile_kind: profile.kind,
         policy: clamped,
         activation: profile.activation,
         invoke_mode: profile.invoke_mode,
         cursor: {:bound, profile.source_ref},
         resources: ingress_edge,
         chain: [profile.source_ref],
         depth: 0,
         budget: Budget.new(source_node.limits.max_concurrent_tasks)
       }}
    end
  end

  # ============================================================================
  # Child construction (used by Sanctum.Authority.Transition)
  # ============================================================================

  @doc """
  The Authority a child receives through a consented edge: bound at the
  target, carrying exactly that edge's resources.
  """
  @spec bound_child(t(), String.t(), Blob.Edge.t()) :: t()
  def bound_child(%__MODULE__{cursor: {:bound, _}} = auth, dep_ref, %Blob.Edge{} = edge) do
    %{
      auth
      | cursor: {:bound, dep_ref},
        resources: edge,
        chain: auth.chain ++ [dep_ref],
        depth: auth.depth + 1
    }
  end

  @doc """
  The Authority a child receives with no matching edge: ZeroAuthority state
  with the parent's chain, depth and root budget. Structural — the blob and
  identity fields are gone, so unboundness is absorbing by construction.
  """
  @spec unbound_child(t(), String.t()) :: t()
  def unbound_child(%__MODULE__{} = auth, target_ref) do
    %{
      auth
      | profile_id: nil,
        consent_id: nil,
        source_ref: nil,
        profile_kind: nil,
        policy: :none,
        activation: %{},
        invoke_mode: :open_inert,
        cursor: :unbound,
        resources: :none,
        chain: auth.chain ++ [target_ref],
        depth: auth.depth + 1
    }
  end

  @doc """
  Self-invocation at the same activation identity (D2): cursor and
  resources are preserved; only chain and depth advance. A component is not
  a boundary against itself.
  """
  @spec self_child(t(), String.t()) :: t()
  def self_child(%__MODULE__{cursor: {:bound, _}} = auth, reference) do
    %{auth | chain: auth.chain ++ [reference], depth: auth.depth + 1}
  end

  # ============================================================================
  # Inspection
  # ============================================================================

  @doc """
  The chain depth cap.
  """
  @spec depth_cap() :: pos_integer()
  def depth_cap, do: @depth_cap

  @spec bound?(t()) :: boolean()
  def bound?(%__MODULE__{cursor: {:bound, _}}), do: true
  def bound?(%__MODULE__{cursor: :unbound}), do: false

  @spec current_node(t()) :: {:ok, String.t()} | :unbound
  def current_node(%__MODULE__{cursor: {:bound, node}}), do: {:ok, node}
  def current_node(%__MODULE__{cursor: :unbound}), do: :unbound

  @doc """
  The limits governing this execution: the current node's clamped limits
  when bound, the ZeroAuthority constants when unbound. A bound Authority
  without a blob is unrepresentable through the constructors, so there is
  deliberately no clause for it.
  """
  @spec limits(t()) :: Limits.t()
  def limits(%__MODULE__{cursor: {:bound, node}, policy: %Blob{} = blob}) do
    {:ok, limits} = Blob.node_limits(blob, node)
    limits
  end

  def limits(%__MODULE__{cursor: :unbound}), do: @zero_limits

  # ============================================================================
  # Root budget
  # ============================================================================

  @doc """
  Take one root-keyed invoke-budget slot. Every acquire must be paired with
  `release_invoke/1` when the spawned work completes.
  """
  @spec try_acquire_invoke(t()) :: :ok | {:error, :invoke_budget_exhausted}
  def try_acquire_invoke(%__MODULE__{budget: %Budget{} = budget}), do: Budget.try_acquire(budget)

  @spec release_invoke(t()) :: :ok
  def release_invoke(%__MODULE__{budget: %Budget{} = budget}), do: Budget.release(budget)

  @spec budget(t()) :: %{in_flight: non_neg_integer(), cap: non_neg_integer()}
  def budget(%__MODULE__{budget: %Budget{} = budget}), do: Budget.snapshot(budget)

  # ============================================================================
  # Wire
  # ============================================================================

  @doc """
  The Authority as a JCS-ready map: string keys, JSON values, nothing
  process-bound. `from_wire/1` reads it back.
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = auth) do
    %{
      "profile_id" => auth.profile_id,
      "consent_id" => auth.consent_id,
      "source_ref" => auth.source_ref,
      "profile_kind" => auth.profile_kind && Atom.to_string(auth.profile_kind),
      "policy" => if(match?(%Blob{}, auth.policy), do: Blob.to_map(auth.policy), else: nil),
      "activation" => auth.activation,
      "invoke_mode" => Atom.to_string(auth.invoke_mode),
      "cursor" =>
        case auth.cursor do
          {:bound, ref} -> %{"bound" => ref}
          :unbound -> "unbound"
        end,
      "resources" =>
        if(match?(%Blob.Edge{}, auth.resources), do: Blob.edge_to_map(auth.resources), else: nil),
      "chain" => auth.chain,
      "depth" => auth.depth,
      "budget" => %{"id" => auth.budget.id, "cap" => auth.budget.cap}
    }
  end

  @doc """
  An Authority back from its wire map. Fail-closed: every field is
  validated the way the blob parser validates a consent — an unknown key,
  a malformed cursor or a policy that does not parse is an error, never a
  looser Authority.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, term()}
  def from_wire(%{} = wire) do
    with :ok <- wire_keys(wire),
         {:ok, profile_kind} <- wire_enum(wire["profile_kind"], [:owner, :public], true),
         {:ok, invoke_mode} <- wire_enum(wire["invoke_mode"], [:open_inert, :edge_only], false),
         {:ok, policy} <- wire_policy(wire["policy"]),
         {:ok, cursor} <- wire_cursor(wire["cursor"]),
         {:ok, resources} <- wire_resources(wire["resources"]),
         {:ok, budget} <- wire_budget(wire["budget"]),
         :ok <- wire_strings(wire["chain"], "chain"),
         :ok <- wire_activation(wire["activation"]),
         :ok <- wire_depth(wire["depth"]) do
      {:ok,
       %__MODULE__{
         profile_id: wire["profile_id"],
         consent_id: wire["consent_id"],
         source_ref: wire["source_ref"],
         profile_kind: profile_kind,
         policy: policy,
         activation: wire["activation"],
         invoke_mode: invoke_mode,
         cursor: cursor,
         resources: resources,
         chain: wire["chain"],
         depth: wire["depth"],
         budget: budget
       }}
    end
  end

  def from_wire(other), do: {:error, {:invalid_wire, other}}

  @wire_keys Enum.sort(
               ~w(profile_id consent_id source_ref profile_kind policy activation invoke_mode cursor resources chain depth budget)
             )

  defp wire_keys(wire) do
    case Enum.sort(Map.keys(wire)) do
      @wire_keys -> :ok
      keys -> {:error, {:invalid_wire_keys, keys}}
    end
  end

  defp wire_enum(nil, _allowed, true), do: {:ok, nil}

  defp wire_enum(value, allowed, _nil_ok) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_wire_value, value}}
      atom -> {:ok, atom}
    end
  end

  defp wire_enum(value, _allowed, _nil_ok), do: {:error, {:invalid_wire_value, value}}

  defp wire_policy(nil), do: {:ok, :none}

  defp wire_policy(%{} = map) do
    case Blob.parse(map) do
      {:ok, blob} -> {:ok, blob}
      {:error, reason} -> {:error, {:invalid_wire_policy, reason}}
    end
  end

  defp wire_policy(other), do: {:error, {:invalid_wire_policy, other}}

  defp wire_cursor("unbound"), do: {:ok, :unbound}
  defp wire_cursor(%{"bound" => ref}) when is_binary(ref) and ref != "", do: {:ok, {:bound, ref}}
  defp wire_cursor(other), do: {:error, {:invalid_wire_cursor, other}}

  defp wire_resources(nil), do: {:ok, :none}

  defp wire_resources(%{} = map) do
    case Blob.parse_edge(map) do
      {:ok, edge} -> {:ok, edge}
      {:error, reason} -> {:error, {:invalid_wire_resources, reason}}
    end
  end

  defp wire_resources(other), do: {:error, {:invalid_wire_resources, other}}

  defp wire_budget(%{"id" => id, "cap" => cap} = map)
       when is_binary(id) and id != "" and is_integer(cap) and cap >= 0 and map_size(map) == 2,
       do: {:ok, %Budget{id: id, cap: cap}}

  defp wire_budget(other), do: {:error, {:invalid_wire_budget, other}}

  defp wire_strings(list, _label) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, {:invalid_wire_chain, list}}
  end

  defp wire_strings(other, label), do: {:error, {:"invalid_wire_#{label}", other}}

  defp wire_activation(%{} = map) do
    if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end),
      do: :ok,
      else: {:error, {:invalid_wire_activation, map}}
  end

  defp wire_activation(other), do: {:error, {:invalid_wire_activation, other}}

  defp wire_depth(depth) when is_integer(depth) and depth >= 0, do: :ok
  defp wire_depth(other), do: {:error, {:invalid_wire_depth, other}}

  # ============================================================================
  # Private
  # ============================================================================

  defp validate_profile(%{} = profile) do
    cond do
      not (is_binary(profile[:profile_id]) and profile[:profile_id] != "") ->
        {:error, {:invalid_profile, :profile_id}}

      not (is_binary(profile[:consent_id]) and profile[:consent_id] != "") ->
        {:error, {:invalid_profile, :consent_id}}

      not (is_binary(profile[:source_ref]) and profile[:source_ref] != "") ->
        {:error, {:invalid_profile, :source_ref}}

      profile[:kind] not in @valid_kinds ->
        {:error, {:invalid_profile, :kind}}

      profile[:invoke_mode] not in @valid_invoke_modes ->
        {:error, {:invalid_profile, :invoke_mode}}

      not valid_activation?(profile[:activation]) ->
        {:error, {:invalid_profile, :activation}}

      profile[:kind] == :public and profile[:invoke_mode] != :edge_only ->
        {:error, {:invalid_profile, :public_requires_edge_only}}

      true ->
        :ok
    end
  end

  defp validate_profile(_), do: {:error, {:invalid_profile, :not_a_map}}

  defp valid_activation?(%{} = activation) when not is_struct(activation) do
    Enum.all?(activation, fn {k, v} -> is_binary(k) and is_binary(v) end)
  end

  defp valid_activation?(_), do: false

  defp fetch_source_node(blob, source_ref) do
    case Blob.node(blob, source_ref) do
      {:ok, node} -> {:ok, node}
      {:error, :unknown_node} -> {:error, {:unknown_source_node, source_ref}}
    end
  end

  defp fetch_ingress(blob, source_ref) do
    case Blob.ingress(blob, source_ref) do
      {:ok, edge} -> {:ok, edge}
      {:error, :missing_ingress} -> {:error, {:missing_ingress, source_ref}}
    end
  end
end
