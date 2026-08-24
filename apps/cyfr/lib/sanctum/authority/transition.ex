# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.Transition do
  @moduledoc """
  The total transition relation over the eight guest-facing invoke
  functions.

  `step/3` maps `(authority, guest function, target)` to exactly one
  outcome of a closed set. The relation itself is literal data: `@relation`
  enumerates every `(cursor, function, target-tag)` combination — all
  #{2 * 8 * 6} of them — and `step/3` looks the handler up with
  `Map.fetch!/2`. There is no catch-all clause anywhere in the dispatch: a
  combination missing from the map is a crash caught by the totality test,
  never a silently-matching wildcard. Protocol nonsense (awaiting an
  invoke, emitting a task id) is a *defined* `{:invalid, _}` outcome, not a
  default.

  This module returns the **Authority-side verdict only**. The in-chain
  authorization equation is `identity permission AND Authority tool action`
  (model §3.9); the identity-permission conjunct belongs to
  `Sanctum.Context` and composes with this verdict at the dispatch layer.
  Context alone never authorizes an in-chain operation — and an allow here
  never bypasses the Context check.

  ## Resolver-supplied inputs

  The `:invoke` target carries `activation_digest` (the target's resolved
  release digest) and `declared_needs` (the named needs declared by the
  **current node's** manifest — the caller's, since needs name the caller's
  dependency roles), and the `:external_tool` target carries
  `server_digest`. These are **resolver-supplied**: the host resolves them
  from the registry and the consent, never from the guest request. Plumbing
  them from guest input would hand the guest control of the need-rejection
  and self-invocation gates.

  ## Root budget

  Every `spawn` outcome that starts work — a bound child, a zero child, or
  an allowed tool dispatch — takes one slot of the root-keyed invoke
  budget at a single chokepoint; exhaustion turns the outcome into
  `{:deny, :invoke_budget_exhausted}`. A denied or malformed spawn
  consumes nothing. Synchronous `call` is bounded by the depth cap
  instead: it adds no concurrency, the parent blocks. The caller releases
  the slot via `Sanctum.Authority.release_invoke/1` when the spawned work
  completes.

  ## Phase notes

  `emit` outcomes model provenance only (`{:attributed, node}` vs
  `:untrusted`); size caps, rate limits and the envelope `origin` marker
  are enforcement-layer work. External tool patterns use a provisional
  exact/prefix glob until the consolidated pattern module lands.
  """

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob

  @guest_functions [:call, :spawn, :await, :await_all, :await_any, :poll, :cancel, :emit]
  @target_tags [:invoke, :tool, :external_tool, :task, :tasks, :event]
  @cursor_tags [:bound, :unbound]

  @type guest_fn :: :call | :spawn | :await | :await_all | :await_any | :poll | :cancel | :emit

  @type invoke_target :: %{
          required(:reference) => String.t(),
          required(:need) => String.t() | nil,
          required(:activation_digest) => String.t() | nil,
          required(:declared_needs) => [String.t()]
        }

  @type target ::
          {:invoke, invoke_target()}
          | {:tool, %{required(:tool) => String.t(), required(:action) => String.t()}}
          | {:external_tool,
             %{required(:server_digest) => String.t(), required(:tool) => String.t()}}
          | {:task, String.t()}
          | {:tasks, [String.t()]}
          | {:event, map()}

  @type deny_reason ::
          :depth_cap
          | :invoke_budget_exhausted
          | :edge_only
          | {:need, :required | :undeclared}
          | :tool_not_granted
          | :tool_server_not_granted
          | :unbound_control_plane

  @type outcome ::
          {:child, Authority.t()}
          | {:child_zero, Authority.t()}
          | {:deny, deny_reason()}
          | {:allow_tool, {:tools, String.t()} | {:tool_server, String.t()}}
          | {:allow_async, :await | :await_all | :await_any | :poll | :cancel}
          | {:allow_emit, {:attributed, String.t()} | :untrusted}
          | {:invalid, {:malformed_target, guest_fn(), atom()}}

  @outcome_tags [:child, :child_zero, :deny, :allow_tool, :allow_async, :allow_emit, :invalid]

  # ============================================================================
  # The relation — every combination, written out
  # ============================================================================

  # Literal on purpose: a generated map would let a newly added target tag
  # be absorbed by whatever rule generated it. Here, growing any dimension
  # without deciding every new combination fails the totality test.
  @relation %{
    # --- call ---------------------------------------------------------------
    {:bound, :call, :invoke} => :invoke_bound,
    {:bound, :call, :tool} => :tool_bound,
    {:bound, :call, :external_tool} => :external_bound,
    {:bound, :call, :task} => :reject_malformed,
    {:bound, :call, :tasks} => :reject_malformed,
    {:bound, :call, :event} => :reject_malformed,
    {:unbound, :call, :invoke} => :invoke_unbound,
    {:unbound, :call, :tool} => :control_plane_unbound,
    {:unbound, :call, :external_tool} => :control_plane_unbound,
    {:unbound, :call, :task} => :reject_malformed,
    {:unbound, :call, :tasks} => :reject_malformed,
    {:unbound, :call, :event} => :reject_malformed,
    # --- spawn --------------------------------------------------------------
    {:bound, :spawn, :invoke} => :invoke_bound,
    {:bound, :spawn, :tool} => :tool_bound,
    {:bound, :spawn, :external_tool} => :external_bound,
    {:bound, :spawn, :task} => :reject_malformed,
    {:bound, :spawn, :tasks} => :reject_malformed,
    {:bound, :spawn, :event} => :reject_malformed,
    {:unbound, :spawn, :invoke} => :invoke_unbound,
    {:unbound, :spawn, :tool} => :control_plane_unbound,
    {:unbound, :spawn, :external_tool} => :control_plane_unbound,
    {:unbound, :spawn, :task} => :reject_malformed,
    {:unbound, :spawn, :tasks} => :reject_malformed,
    {:unbound, :spawn, :event} => :reject_malformed,
    # --- await --------------------------------------------------------------
    {:bound, :await, :invoke} => :reject_malformed,
    {:bound, :await, :tool} => :reject_malformed,
    {:bound, :await, :external_tool} => :reject_malformed,
    {:bound, :await, :task} => :async_ok,
    {:bound, :await, :tasks} => :reject_malformed,
    {:bound, :await, :event} => :reject_malformed,
    {:unbound, :await, :invoke} => :reject_malformed,
    {:unbound, :await, :tool} => :reject_malformed,
    {:unbound, :await, :external_tool} => :reject_malformed,
    {:unbound, :await, :task} => :async_ok,
    {:unbound, :await, :tasks} => :reject_malformed,
    {:unbound, :await, :event} => :reject_malformed,
    # --- await_all ----------------------------------------------------------
    {:bound, :await_all, :invoke} => :reject_malformed,
    {:bound, :await_all, :tool} => :reject_malformed,
    {:bound, :await_all, :external_tool} => :reject_malformed,
    {:bound, :await_all, :task} => :reject_malformed,
    {:bound, :await_all, :tasks} => :async_ok,
    {:bound, :await_all, :event} => :reject_malformed,
    {:unbound, :await_all, :invoke} => :reject_malformed,
    {:unbound, :await_all, :tool} => :reject_malformed,
    {:unbound, :await_all, :external_tool} => :reject_malformed,
    {:unbound, :await_all, :task} => :reject_malformed,
    {:unbound, :await_all, :tasks} => :async_ok,
    {:unbound, :await_all, :event} => :reject_malformed,
    # --- await_any ----------------------------------------------------------
    {:bound, :await_any, :invoke} => :reject_malformed,
    {:bound, :await_any, :tool} => :reject_malformed,
    {:bound, :await_any, :external_tool} => :reject_malformed,
    {:bound, :await_any, :task} => :reject_malformed,
    {:bound, :await_any, :tasks} => :async_ok,
    {:bound, :await_any, :event} => :reject_malformed,
    {:unbound, :await_any, :invoke} => :reject_malformed,
    {:unbound, :await_any, :tool} => :reject_malformed,
    {:unbound, :await_any, :external_tool} => :reject_malformed,
    {:unbound, :await_any, :task} => :reject_malformed,
    {:unbound, :await_any, :tasks} => :async_ok,
    {:unbound, :await_any, :event} => :reject_malformed,
    # --- poll ---------------------------------------------------------------
    {:bound, :poll, :invoke} => :reject_malformed,
    {:bound, :poll, :tool} => :reject_malformed,
    {:bound, :poll, :external_tool} => :reject_malformed,
    {:bound, :poll, :task} => :async_ok,
    {:bound, :poll, :tasks} => :reject_malformed,
    {:bound, :poll, :event} => :reject_malformed,
    {:unbound, :poll, :invoke} => :reject_malformed,
    {:unbound, :poll, :tool} => :reject_malformed,
    {:unbound, :poll, :external_tool} => :reject_malformed,
    {:unbound, :poll, :task} => :async_ok,
    {:unbound, :poll, :tasks} => :reject_malformed,
    {:unbound, :poll, :event} => :reject_malformed,
    # --- cancel -------------------------------------------------------------
    {:bound, :cancel, :invoke} => :reject_malformed,
    {:bound, :cancel, :tool} => :reject_malformed,
    {:bound, :cancel, :external_tool} => :reject_malformed,
    {:bound, :cancel, :task} => :async_ok,
    {:bound, :cancel, :tasks} => :reject_malformed,
    {:bound, :cancel, :event} => :reject_malformed,
    {:unbound, :cancel, :invoke} => :reject_malformed,
    {:unbound, :cancel, :tool} => :reject_malformed,
    {:unbound, :cancel, :external_tool} => :reject_malformed,
    {:unbound, :cancel, :task} => :async_ok,
    {:unbound, :cancel, :tasks} => :reject_malformed,
    {:unbound, :cancel, :event} => :reject_malformed,
    # --- emit ---------------------------------------------------------------
    {:bound, :emit, :invoke} => :reject_malformed,
    {:bound, :emit, :tool} => :reject_malformed,
    {:bound, :emit, :external_tool} => :reject_malformed,
    {:bound, :emit, :task} => :reject_malformed,
    {:bound, :emit, :tasks} => :reject_malformed,
    {:bound, :emit, :event} => :emit_bound,
    {:unbound, :emit, :invoke} => :reject_malformed,
    {:unbound, :emit, :tool} => :reject_malformed,
    {:unbound, :emit, :external_tool} => :reject_malformed,
    {:unbound, :emit, :task} => :reject_malformed,
    {:unbound, :emit, :tasks} => :reject_malformed,
    {:unbound, :emit, :event} => :emit_unbound
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Apply one guest function to a target under an Authority.

  Total over the closed vocabulary: any `(authority, guest_fn, target)`
  where `guest_fn` is one of the eight and `target` one of the six shapes
  has a defined outcome. A term outside the vocabulary is a caller bug and
  raises `ArgumentError`.
  """
  @spec step(Authority.t(), guest_fn(), target()) :: outcome()
  def step(%Authority{} = auth, guest_fn, target) when guest_fn in @guest_functions do
    key = {cursor_tag(auth), guest_fn, target_tag(target)}

    @relation
    |> Map.fetch!(key)
    |> apply_handler(auth, guest_fn, target)
    |> charge_spawn_budget(auth, guest_fn)
  end

  @doc "The eight guest function names."
  @spec guest_functions() :: [guest_fn()]
  def guest_functions, do: @guest_functions

  @doc "The six target tags."
  @spec target_tags() :: [atom()]
  def target_tags, do: @target_tags

  @doc "The two cursor tags."
  @spec cursor_tags() :: [atom()]
  def cursor_tags, do: @cursor_tags

  @doc "The closed outcome tag set."
  @spec outcome_tags() :: [atom()]
  def outcome_tags, do: @outcome_tags

  @doc "The full relation, for the totality gate."
  @spec relation() :: %{optional({atom(), guest_fn(), atom()}) => atom()}
  def relation, do: @relation

  # ============================================================================
  # Handlers — one per relation value, no catch-alls
  # ============================================================================

  defp apply_handler(:invoke_bound, auth, _fun, {:invoke, inv}), do: invoke_bound(auth, inv)
  defp apply_handler(:invoke_unbound, auth, _fun, {:invoke, inv}), do: invoke_unbound(auth, inv)
  defp apply_handler(:tool_bound, auth, _fun, {:tool, t}), do: tool_bound(auth, t)

  defp apply_handler(:external_bound, auth, _fun, {:external_tool, t}),
    do: external_bound(auth, t)

  defp apply_handler(:control_plane_unbound, _auth, _fun, _target),
    do: {:deny, :unbound_control_plane}

  defp apply_handler(:async_ok, _auth, fun, _target), do: {:allow_async, fun}

  defp apply_handler(:emit_bound, auth, _fun, {:event, _payload}) do
    {:ok, node} = Authority.current_node(auth)
    {:allow_emit, {:attributed, node}}
  end

  defp apply_handler(:emit_unbound, _auth, _fun, {:event, _payload}),
    do: {:allow_emit, :untrusted}

  defp apply_handler(:reject_malformed, _auth, fun, target),
    do: {:invalid, {:malformed_target, fun, target_tag(target)}}

  # ============================================================================
  # Invoke — bound: depth → D2 → needs → edge (each step fail-closed)
  # ============================================================================

  defp invoke_bound(auth, inv) do
    {:ok, node} = Authority.current_node(auth)

    case check_depth(auth) do
      {:deny, _} = deny ->
        deny

      :ok ->
        # D2 before the need rules: self-invocation bypasses edge selection
        # entirely, so the callee's need vocabulary does not apply to it —
        # otherwise an agent with named needs could not spawn sub-agents.
        if self_invocation?(auth, node, inv) do
          {:child, Authority.self_child(auth, inv.reference)}
        else
          case check_need(inv) do
            {:error, reason} -> {:deny, {:need, reason}}
            :ok -> dispatch_edge(auth, node, inv)
          end
        end
    end
  end

  defp dispatch_edge(auth, node, inv) do
    case Blob.lookup_edge(auth.policy, node, inv.reference, inv.need || "") do
      {:ok, edge} ->
        {:child, Authority.bound_child(auth, inv.reference, edge)}

      {:error, :no_edge} ->
        case auth.invoke_mode do
          # Dynamic dispatch is normal; it just carries nothing.
          :open_inert -> {:child_zero, Authority.unbound_child(auth, inv.reference)}
          # Containment: a public profile cannot even trampoline inertly.
          :edge_only -> {:deny, :edge_only}
        end
    end
  end

  # Unbound invoke consults no blob node — the Authority has none to
  # consult (policy is :none, structurally). Only the universal bounds
  # apply; the outcome is always a zero child.
  defp invoke_unbound(auth, inv) do
    case check_depth(auth) do
      {:deny, _} = deny -> deny
      :ok -> {:child_zero, Authority.unbound_child(auth, inv.reference)}
    end
  end

  defp check_depth(%Authority{depth: depth}) do
    if depth + 1 > Authority.depth_cap() do
      {:deny, :depth_cap}
    else
      :ok
    end
  end

  # D2: keyed on activation identity, never on ref equality — the same ref
  # at a different activation is a different node and gets no inheritance.
  defp self_invocation?(auth, node, %{activation_digest: digest}) do
    is_binary(digest) and Map.get(auth.activation, node) == digest
  end

  # §2.7: omission is valid only when the callee declares no named needs;
  # a need the callee does not declare is rejected, never coerced.
  defp check_need(%{need: need, declared_needs: declared}) do
    cond do
      declared != [] and need in [nil, ""] -> {:error, :required}
      need not in [nil, ""] and need not in declared -> {:error, :undeclared}
      true -> :ok
    end
  end

  # ============================================================================
  # Tool plane — current node's own edge resources only
  # ============================================================================

  @doc """
  Is this internal tool action among the authority's edge tool grants?

  The membership half of the tool-plane verdict, public so the in-chain
  discovery view and the per-call step read the same grant. `:none`
  resources grant nothing.
  """
  @spec tool_granted?(Authority.t(), String.t(), String.t()) :: boolean()
  def tool_granted?(%Authority{resources: %{tools: tools}}, tool, action) when is_list(tools),
    do: (tool <> "." <> action) in tools

  def tool_granted?(%Authority{}, _tool, _action), do: false

  @doc """
  Does the authority's edge grant this remote tool on this server digest?

  The membership half of the external-tool verdict, public for the same
  reason as `tool_granted?/3`. Patterns match the remote tool name — the
  edge names the server by digest, never by prefix.
  """
  @spec external_tool_granted?(Authority.t(), String.t() | nil, String.t()) :: boolean()
  def external_tool_granted?(%Authority{resources: %{tool_servers: servers}}, digest, tool)
      when is_list(servers) do
    case Enum.find(servers, &(&1.server_digest == digest)) do
      %{tool_patterns: patterns} -> Enum.any?(patterns, &Sanctum.ToolPattern.matches?(&1, tool))
      nil -> false
    end
  end

  def external_tool_granted?(%Authority{}, _digest, _tool), do: false

  defp tool_bound(auth, %{tool: tool, action: action}) do
    if tool_granted?(auth, tool, action) do
      {:allow_tool, {:tools, tool <> "." <> action}}
    else
      {:deny, :tool_not_granted}
    end
  end

  defp external_bound(auth, %{server_digest: digest, tool: tool}) do
    if external_tool_granted?(auth, digest, tool) do
      {:allow_tool, {:tool_server, digest}}
    else
      {:deny, :tool_server_not_granted}
    end
  end

  # ============================================================================
  # Budget chokepoint
  # ============================================================================

  # Every spawn outcome that starts work takes one root-keyed slot; a
  # denied or malformed spawn takes nothing. Charging happens here, after
  # the decision, so no handler can forget it and no deny path needs a
  # rollback.
  defp charge_spawn_budget(outcome, auth, :spawn)
       when elem(outcome, 0) in [:child, :child_zero, :allow_tool] do
    case Authority.try_acquire_invoke(auth) do
      :ok -> outcome
      {:error, :invoke_budget_exhausted} -> {:deny, :invoke_budget_exhausted}
    end
  end

  defp charge_spawn_budget(outcome, _auth, _fun), do: outcome

  # ============================================================================
  # Tags
  # ============================================================================

  defp cursor_tag(%Authority{cursor: {:bound, _}}), do: :bound
  defp cursor_tag(%Authority{cursor: :unbound}), do: :unbound

  defp target_tag(
         {:invoke,
          %{reference: ref, need: need, activation_digest: digest, declared_needs: declared}}
       )
       when is_binary(ref) and (is_nil(need) or is_binary(need)) and
              (is_nil(digest) or is_binary(digest)) and is_list(declared),
       do: :invoke

  defp target_tag({:tool, %{tool: tool, action: action}})
       when is_binary(tool) and is_binary(action),
       do: :tool

  defp target_tag({:external_tool, %{server_digest: digest, tool: tool}})
       when is_binary(digest) and is_binary(tool),
       do: :external_tool

  defp target_tag({:task, id}) when is_binary(id), do: :task

  defp target_tag({:tasks, ids}) when is_list(ids), do: :tasks

  defp target_tag({:event, %{} = payload}) when not is_struct(payload), do: :event

  defp target_tag(other) do
    raise ArgumentError, "not a transition target: #{inspect(other)}"
  end
end
