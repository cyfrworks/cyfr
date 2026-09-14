# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution do
  @moduledoc """
  The execution port: how cyfr asks for a component to run, follows its
  events, and stops it — without a compile-time path into the engine.

  The engine (`Opus`) is named in configuration
  (`config :cyfr, :execution_impl`); a build without it — a headless control
  plane, a test that stubs the engine — answers `available?/0` false and
  every call `{:error, :execution_unavailable}`. The functions mirror the
  engine's public surface one to one so the seam is a name, not a
  translation; a worker split changes the implementation, not the callers.
  """

  alias Cyfr.Authority.RootSelect
  alias Cyfr.Execution.StepSpans
  alias Sanctum.Context

  @type impl :: module()

  @callback run_root(Context.t(), RootSelect.selector(), String.t(), map(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback run_root_edge(Context.t(), String.t(), String.t(), map(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback authority_for(Context.t(), RootSelect.selector(), String.t(), keyword()) ::
              {:ok, term()} | {:error, term()}
  # The second argument is anything carrying an `:athanor_id` — a
  # `Sanctum.Context` OR the execution record itself, which is the natural
  # source wherever the OWNING athanor is what the topic must resolve to
  # and the viewer's context carries a different one. Both the buffer's
  # `topic/2` and `Opus.subscribe_events/2` document that; typing it
  # `Context.t()` here contradicted them, and made the whole SSE stream
  # loop in `EmissaryWeb.ExecutionEventsController` read as unreachable to
  # static analysis — a function nobody could check.
  @type event_scope :: Context.t() | %{:athanor_id => String.t(), optional(atom()) => any()}

  @callback subscribe_events(String.t(), event_scope()) :: :ok | {:error, term()}
  @callback unsubscribe_events(String.t(), event_scope()) :: :ok | {:error, term()}
  # The cursor is `{durable, n}`: the last durable event delivered and,
  # under it, the last delta.
  @callback events_since(String.t(), {non_neg_integer(), non_neg_integer()}, String.t()) ::
              [map()]
  # The in-chain entry, mirrored one to one as the rest: `authority` is the
  # chain's, `need` the edge's (nil for none), and `opts` carry `ctx` and
  # the host lineage (`parent_execution_id`, `root_execution_id`) exactly
  # as the formula host builds them for a guest's child call. Never a root.
  @callback run_child(Cyfr.Authority.t(), String.t(), String.t() | nil, map(), keyword()) ::
              {:ok, map()} | {:error, term()}
  # The logical root a host loop holds for a turn: an `executions` row of
  # kind `turn` with its attempt, reservation and a `:root` slot, taken
  # WITHOUT entering the WASM path. Every callback runs in the process
  # that owns the slot (the loop task); the lease keeper it starts is
  # linked to that process and exits it when the lease is lost.
  @callback claim_turn_root(Context.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback pause_turn_root(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback resume_turn_root(Context.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback adopt_turn_root(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback release_turn_root(Context.t(), String.t(), keyword()) :: :ok
  @callback cancel(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback cancel_for_restart(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback get(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback list(Context.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback ready?() :: boolean()

  @doc "The configured engine module, or nil when none is loadable."
  @spec impl() :: impl() | nil
  def impl do
    # The load check keeps one static config honest across builds: the
    # cyfr app alone (its own tests, a control-plane-only node) has no
    # Opus on the code path, and a name that cannot load is no engine.
    case Application.get_env(:cyfr, :execution_impl) do
      nil -> nil
      mod -> if Code.ensure_loaded?(mod), do: mod, else: nil
    end
  end

  @doc "Whether an engine is registered and ready to admit work."
  @spec available?() :: boolean()
  def available? do
    case impl() do
      nil -> false
      mod -> mod.ready?()
    end
  end

  @spec run_root(Context.t(), RootSelect.selector(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root(ctx, profile_selector, reference, input, opts \\ []),
    do: call(:run_root, [ctx, profile_selector, reference, input, opts])

  @spec run_root_edge(Context.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root_edge(ctx, source_ref, reference, input, opts) when is_list(opts),
    do: call(:run_root_edge, [ctx, source_ref, reference, input, opts])

  @spec authority_for(Context.t(), RootSelect.selector(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def authority_for(ctx, profile_selector, reference, opts \\ []),
    do: call(:authority_for, [ctx, profile_selector, reference, opts])

  @spec subscribe_events(String.t(), event_scope()) :: :ok | {:error, term()}
  def subscribe_events(execution_id, ctx), do: call(:subscribe_events, [execution_id, ctx])

  @spec unsubscribe_events(String.t(), event_scope()) :: :ok | {:error, term()}
  def unsubscribe_events(execution_id, ctx), do: call(:unsubscribe_events, [execution_id, ctx])

  @spec events_since(String.t(), {non_neg_integer(), non_neg_integer()}, String.t()) :: [map()]
  def events_since(execution_id, cursor, athanor_id) do
    # Dispatched on the impl directly, not through call/2: the callback
    # answers a bare list, and a `case` that matched one error tuple and
    # fell everything else through would hand a future impl's `{:error, _}`
    # to callers typed `[map()]` as if it were the events.
    case impl() do
      nil -> []
      mod -> mod.events_since(execution_id, cursor, athanor_id)
    end
  end

  @doc """
  Run a component as a CHILD of a running chain's authority — the hop the
  formula host makes for a guest's `execution.run`, offered to the host
  itself so an approved hand call (`Aqua.Loop`)
  runs the wrapped catalyst under the card's pinned authority with the
  card's execution as its lineage, never as a fresh root. `opts` may
  carry `:retained_input`: the map the payload store keeps as the
  execution's input in place of `input`, for a request that carries
  transient content (the room excerpt); the row's `input_hash` and
  envelope still describe `input`, the bytes that were sent.

  The call is timed (`Cyfr.Execution.StepSpans`): its clock rides to the
  engine in `opts` as `:step_spans`, replacing any the caller set.
  """
  @spec run_child(Cyfr.Authority.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_child(authority, reference, need, input, opts) when is_list(opts) do
    clock = StepSpans.start(reference, opts)

    try do
      call(:run_child, [authority, reference, need, input, Keyword.put(opts, :step_spans, clock)])
    after
      StepSpans.returned(clock)
    end
  end

  @doc """
  Claim a turn's logical root: the `kind: "turn"` execution, its attempt,
  its reservation and a `:root` slot on the calling process, with the
  agent's authority loaded and no guest started. `opts`: `:profile`
  (a `RootSelect` selector, `:default` when absent), `:turn_id`,
  `:thread_id`, `:envelope` (the input keys the row records).
  Answers the claim the loop keeps (`execution_id`, `attempt`,
  `authority`, `activation_digest`, `lease_until`, `budget_id`, `token`,
  `keeper`).
  """
  @spec claim_turn_root(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_turn_root(ctx, agent_ref, opts \\ []),
    do: call(:claim_turn_root, [ctx, agent_ref, opts])

  @doc """
  Pause the turn root: keeper stopped, rows flipped, slot released
  (`:turn_id`, `:fence`, `:reason`, `:launch_step_id`, `:claim`). With
  `:uncertain` (`%{step_id, generation, reason, content}`) the pause is
  the uncertain boundary: the step's mark, the covering aborted row and
  the pause in one transaction; the answer carries the `aborted` row.
  """
  @spec pause_turn_root(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def pause_turn_root(ctx, execution_id, opts),
    do: call(:pause_turn_root, [ctx, execution_id, opts])

  @doc "Resume a paused turn root from the calling process: slot first, then the rows, then a keeper (`:turn_id`, `:fence`)."
  @spec resume_turn_root(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resume_turn_root(ctx, execution_id, opts),
    do: call(:resume_turn_root, [ctx, execution_id, opts])

  @doc "Adopt a turn root whose attempt a takeover already opened: slot and keeper only (`:attempt`)."
  @spec adopt_turn_root(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def adopt_turn_root(ctx, execution_id, opts),
    do: call(:adopt_turn_root, [ctx, execution_id, opts])

  @doc "Local cleanup after the turn's terminal write: keeper stopped, slot released (`:claim`)."
  @spec release_turn_root(Context.t(), String.t(), keyword()) :: :ok
  def release_turn_root(ctx, execution_id, opts) do
    case impl() do
      nil -> :ok
      mod -> mod.release_turn_root(ctx, execution_id, opts)
    end
  end

  @spec cancel(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(ctx, execution_id), do: call(:cancel, [ctx, execution_id])

  @spec cancel_for_restart(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def cancel_for_restart(ctx, execution_id, payload),
    do: call(:cancel_for_restart, [ctx, execution_id, payload])

  @spec get(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(ctx, execution_id), do: call(:get, [ctx, execution_id])

  @spec list(Context.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(ctx, opts \\ []), do: call(:list, [ctx, opts])

  defp call(fun, args) do
    case impl() do
      nil -> {:error, :execution_unavailable}
      mod -> apply(mod, fun, args)
    end
  end
end
