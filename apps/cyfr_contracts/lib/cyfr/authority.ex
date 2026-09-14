# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.Authority do
  @moduledoc """
  The runtime authority of one execution in a consented chain, as data.

  An Authority is built once per root execution from a profile and its
  consent's resolved policy blob, then travels the chain by value: every
  child transition returns a *new* Authority. What a node may do is decided
  entirely by the cursor position and the edge resources captured here —
  the request context supplies tenant binding and attribution, never
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
  `zero_limits/0` constants. Their byte ceilings and rate limit are the
  shared `Cyfr.Limits` defaults; the other three fields (timeout,
  batch_timeout, max_concurrent_tasks) are deliberately tighter than
  `Cyfr.Limits.defaults/1`, so they are never derived from it.

  ## Root budget

  `budget` names the root-keyed invoke budget (`Cyfr.Authority.Budget`):
  an id and a cap, created once per root and copied into every child
  Authority — including unbound ones — so concurrency is bounded per root
  tree, not per level, and the bound survives closure capture across spawn
  layers. The id names the root's reservation row, which is the authority
  on what is in flight. The struct itself is plain data, and the wire
  carries the id alone: a reader takes the cap from the row.

  ## Wire

  An Authority is plain data end to end — `to_wire/1` gives the JCS-ready
  map of its twelve fields — so a worker on another node can run under
  exactly the authority the root resolved. Reading a wire map back
  re-establishes the platform ceiling and the reservation's cap, which
  this module does not hold.
  """

  alias Cyfr.Authority.Blob
  alias Cyfr.Authority.Budget
  alias Cyfr.Limits

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

  # ZeroAuthority limits (see moduledoc): the timeouts and the task bound
  # stay tighter than any type default.
  @zero_limits %Limits{
    timeout: "30s",
    max_memory_bytes: Limits.default_max_memory_bytes(),
    max_request_size: Limits.default_max_request_size(),
    max_response_size: Limits.default_max_response_size(),
    rate_limit: Limits.default_rate_limit(),
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

  Options:

    * `:ceiling` (required) — the ceiling map the blob is clamped to (the
      shape `Cyfr.Limits.Ceiling.lowered/1` returns); the instance's platform
      ceiling in production.
    * `:budget_id` — the id of an existing reservation the root budget
      charges; a fresh id when absent.
  """
  @spec root(profile(), Blob.t(), keyword()) :: {:ok, t()} | {:error, root_error()}
  def root(profile, %Blob{} = blob, opts) when is_list(opts) do
    ceiling = Keyword.fetch!(opts, :ceiling)

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
         budget:
           Budget.new(source_node.limits.max_concurrent_tasks, Keyword.get(opts, :budget_id))
       }}
    end
  end

  # ============================================================================
  # Child construction (used by Cyfr.Authority.Transition)
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
  Self-invocation at the same activation identity preserves the cursor
  and resources; only chain and depth advance.
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

  @doc """
  The limits consented for one node of the graph, by ref, whether or not
  the cursor stands on it. A caller that must size a request before
  stepping onto the node that will receive it needs this; `limits/1`
  answers only for where the cursor is.
  """
  @spec node_limits(t(), String.t()) :: {:ok, Limits.t()} | {:error, :unknown_node}
  def node_limits(%__MODULE__{policy: %Blob{} = blob}, node_ref) when is_binary(node_ref),
    do: Blob.node_limits(blob, node_ref)

  def node_limits(%__MODULE__{}, _node_ref), do: {:error, :unknown_node}

  # ============================================================================
  # Wire
  # ============================================================================

  @doc """
  The Authority as a JCS-ready map: string keys, JSON values, nothing
  process-bound. The budget travels as its id alone.
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
      "budget" => %{"id" => auth.budget.id}
    }
  end

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
