# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible do
  @moduledoc """
  How CYFR runs a component, follows its events and stops it.

  Every way an execution starts is here. `run_root/5` is the external
  ingress: the reference runs under the authority its selected profile's
  consent grants. `run_root_edge/5` roots at a tincture's profile and runs
  one of its dependencies under that edge. `run_child/5` and
  `admit_child/5` are the in-chain entries: the target runs under the child
  authority the caller's authority steps to, bound or zero. `run_child/5`
  runs it on a worker service and waits for it; `admit_child/5` admits a
  formula's child for the runner that runs the formula, which runs it.
  `claim_turn_root/3` takes a turn's root without a guest. Every decision
  is taken before the run is dispatched (`Crucible.Dispatch.run/4`,
  `Crucible.Dispatch.claim/4`); a refusal runs nothing.

  A run is dispatched to the first worker service `config :cyfr, :workers`
  names that is loaded and answers; with none, `available?/0` is false and
  a dispatched run answers `{:error, :execution_unavailable}`.

  A spawn-shaped child's invoke-budget slot is charged by its step and
  held under the guard by the process that dispatches it, with its charge
  row; the child's attempt takes both over and gives them back at its
  terminal write or when it stops, and a child refused before its attempt
  opens gives them back at once.
  """

  alias Prima.Authority
  alias Prima.Authority.RootSelect

  alias Crucible.{
    Admission,
    Assignments,
    Attempt,
    Charge,
    Dispatch,
    Events,
    Record,
    StepSpans,
    TurnRoot
  }

  alias Sanctum.Context

  @typedoc """
  What an event stream is scoped by: anything carrying the `:athanor_id`
  of the athanor that owns the execution — a `Sanctum.Context`, or the
  execution record itself where the viewer's context carries another
  athanor.
  """
  @type event_scope :: Context.t() | %{:athanor_id => String.t(), optional(atom()) => any()}

  @doc "Whether a worker service is configured and answers, and the execution slots are up."
  @spec available?() :: boolean()
  def available? do
    is_pid(Process.whereis(Crucible.Slots)) and match?({:ok, _}, Dispatch.worker())
  end

  @doc "The service label a run is logged as routed to (`Crucible.Provider.service/0`)."
  @spec service() :: String.t()
  def service, do: Crucible.Provider.service()

  @doc """
  Root an execution chain under a profile's consent and run `reference`
  with `input` under the authority it grants.

  `profile_selector` and the options `:route`, `:ceiling` and
  `:live_shape_digest` are
  `Crucible.Admission.authority_for/4`'s. Remaining options pass
  through to `Crucible.Dispatch.run/4`.
  """
  @spec run_root(Context.t(), RootSelect.selector(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root(%Context{} = ctx, profile_selector, reference, input, opts \\ []) do
    # An unavailable executor refuses before any consent is resolved or any
    # row is written; dispatch checks the worker again when it runs.
    with {:ok, _worker} <- Dispatch.worker(reference),
         {:ok, %{authority: authority, stamp: stamp, profile: profile}} <-
           Admission.authority_and_stamp_for(ctx, profile_selector, reference, opts) do
      exec_opts =
        opts
        |> Keyword.drop([:route, :ceiling, :live_shape_digest])
        |> Keyword.merge(
          authority: authority,
          activation_stamp: stamp,
          # A formula threads the chain's activation identity to every
          # descendant row from this digest.
          activation_digest: stamp.activation_digest,
          # The row records the consent it ran under.
          profile_id: profile.id
        )

      Dispatch.run(ctx, reference, input, exec_opts)
    end
  end

  @doc """
  Root at a profile's source and traverse one edge: a tincture, whose
  profile owns the authority, invoking one of its dependencies. The
  dependency runs as the root execution, bound to the tincture→dependency
  edge's resources, or inert or denied exactly as the transition relation
  decides (`Crucible.Admission.root_edge/4`).

  `:route` is required — `:public` or `:protected` — and is the profile
  selection, public-first: authentication never upgrades a public route.
  A call without a route raises.
  """
  @spec run_root_edge(Context.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root_edge(%Context{} = ctx, source_ref, reference, input, opts) when is_list(opts) do
    with {:ok, %{root: root, decision: decision}} <-
           Admission.root_edge(ctx, source_ref, reference, opts) do
      dispatch_child(
        decision,
        input,
        Keyword.merge(opts, ctx: ctx, activation_stamp: root.stamp, profile_id: root.profile.id),
        &Dispatch.run/4
      )
    end
  end

  @doc """
  Derive, without running anything, the authority a `run_root/5` of this
  selector and reference would run under. See
  `Crucible.Admission.authority_for/4`.
  """
  @spec authority_for(Context.t(), RootSelect.selector(), String.t(), keyword()) ::
          {:ok, Authority.t()} | {:error, term()}
  defdelegate authority_for(ctx, profile_selector, reference, opts \\ []), to: Admission

  @doc """
  Subscribe the calling process to an execution's event stream. Pass the
  scope of the athanor that owns the execution, and the same scope to
  `unsubscribe_events/2`.
  """
  @spec subscribe_events(String.t(), event_scope()) :: :ok | {:error, term()}
  defdelegate subscribe_events(execution_id, scope), to: Events, as: :subscribe

  @doc "Unsubscribe from an execution's event stream, with the scope it was subscribed with."
  @spec unsubscribe_events(String.t(), event_scope()) :: :ok
  defdelegate unsubscribe_events(execution_id, scope), to: Events, as: :unsubscribe

  @doc """
  The events of an execution of `athanor_id` after the cursor
  `{durable, n}` — the last durable event delivered and, under it, the last
  delta — for replay on (re)connect.
  """
  @spec events_since(String.t(), {non_neg_integer(), non_neg_integer()}, String.t()) :: [map()]
  defdelegate events_since(execution_id, cursor, athanor_id), to: Events, as: :since

  @doc """
  Advance a running chain's `authority` through one invocation of
  `reference` and run it synchronously under the resulting child
  authority, with the chain's execution as its lineage, never as a fresh
  root.

  Required options: `:ctx`. `:parent_execution_id`,
  `:root_execution_id`, `:attempt` (the parent's attempt, which a child is
  admitted under), `:guest_fn` (`:call` or `:spawn`), `:declared_needs`
  and `:activation_digest` are host-threaded by the caller.
  `:retained_input` is the map the payload store keeps as the execution's
  input in place of `input`, for a request that carries transient content;
  the row's `input_hash` and envelope still describe `input`. `:charge` and
  `:step_id` name the hold and the loop step the child is admitted under.
  `:envelope` true reads the component's answer as its catalyst envelope,
  whose error is the component's refusal
  (`Crucible.Admission.admit/4`).

  The call is timed (`Crucible.StepSpans`): its clock rides to
  admission as `:step_spans`, replacing any the caller set.
  """
  @spec run_child(Authority.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_child(%Authority{} = authority, reference, need, input, opts) when is_list(opts) do
    clock = StepSpans.start(reference, opts)

    try do
      opts = opts |> Keyword.put(:step_spans, clock) |> Charge.identify()

      with {:ok, decision} <- Admission.step_invoke(authority, reference, need, opts) do
        dispatch_child(decision, input, opts, &Dispatch.run/4)
      end
    after
      StepSpans.returned(clock)
    end
  end

  @typedoc """
  A child admitted for the runner that runs its parent: what
  `Crucible.Dispatch.claim/4` answers, with `:input`, the input the
  child was admitted with, which its assignment's `input_digest` binds.
  """
  @type admitted_child :: %{
          assignment: Prima.Assignment.token(),
          attempt_keys: Prima.WorkerAuth.attempt_keys(),
          secrets: %{optional(String.t()) => String.t()},
          input: map()
        }

  @doc """
  Advance a formula's `authority` through one invocation of `reference`
  its guest asked for, and admit the child for the runner that runs the
  formula, which runs it (`Crucible.Dispatch.claim/4`).

  A spawn-shaped child (`:guest_fn` `:spawn`, a spawned or streamed child)
  charges the root invoke budget and takes its charge row, both held by the
  child's attempt until its terminal write; a synchronous one charges
  nothing. A refusal charges nothing and admits nothing.

  `:child_key` (required) is the key the runner minted for this child
  (`t:Prima.HostAPI.child_key/0`), which the child's row carries under its
  parent. The row decides a repeat, never anything held in a process: a
  key already carried by a child of `:parent_execution_id`
  (`Arca.Execution.child_by_key/3`) admits nothing and answers that child
  again — its assignment signed afresh from what it was admitted with, its
  attempt's keys, its secrets and its input — for the runner that holds
  its claim on the caller's service and boot; a key whose child has ended
  is refused `:lost`, as is one another runner holds. Two admissions
  racing under one key are decided by the row's unique index: the loser
  admits nothing, gives back what it charged and answers the winner's
  child.

  Other options as `run_child/5`'s host-threaded ones (`:ctx`,
  `:parent_execution_id`, `:root_execution_id`, `:attempt`, `:guest_fn`,
  `:declared_needs`, `:activation_digest`), and the runner the child is
  claimed for: `:runner`, with `:service_id`, `:boot_id` and `:worker`
  naming its worker service, that service's boot and its `Prima.WorkerAPI`
  module, and `:parent_deadline` (Unix ms), which caps the child's
  timeout at what remains of its parent's. Answers `{:ok, child}`
  (`t:admitted_child/0`) or `{:error, reason}`.
  """
  @spec admit_child(Authority.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, admitted_child()} | {:error, term()}
  def admit_child(%Authority{} = authority, reference, need, input, opts) when is_list(opts) do
    case child_under_key(opts) do
      :none -> admit_keyed_child(authority, reference, need, input, opts)
      {:ok, child} -> admitted_child(child, opts)
      {:error, :unavailable} = refused -> refused
    end
  end

  # The child of `:parent_execution_id` already carrying `:child_key`, by
  # its row alone.
  defp child_under_key(opts) do
    case Arca.Execution.child_by_key(
           Sanctum.Context.actor(Keyword.fetch!(opts, :ctx)),
           Keyword.fetch!(opts, :parent_execution_id),
           Keyword.fetch!(opts, :child_key)
         ) do
      {:error, :database_error} -> {:error, :unavailable}
      answer -> answer
    end
  end

  # A fresh admission under the key. One that loses the row's unique index
  # to an identical admission charged nothing that was not given back
  # (`Crucible.Dispatch.claim/4`), and answers the winner's child.
  defp admit_keyed_child(authority, reference, need, input, opts) do
    opts = Charge.identify(opts)

    with {:ok, decision} <- Admission.step_invoke(authority, reference, need, opts),
         {:ok, claimed} <- dispatch_child(decision, input, opts, &Dispatch.claim/4) do
      {:ok, Map.put(claimed, :input, input)}
    else
      {:error, :duplicate_child_key} ->
        case child_under_key(opts) do
          {:ok, child} -> admitted_child(child, opts)
          :none -> {:error, :lost}
          {:error, :unavailable} = refused -> refused
        end

      {:error, _reason} = refused ->
        refused
    end
  end

  # The child already admitted under the key, handed to its runner again:
  # its attempt answers what its assignment is signed from and its secrets
  # while the calling runner holds its claim and the row is live
  # (`Crucible.Attempt.admitted/2`), and the assignment is signed
  # afresh from that; its keys derive from the same attempt.
  defp admitted_child(%{id: child_id}, opts) do
    holder = %{
      service_id: Keyword.fetch!(opts, :service_id),
      boot_id: Keyword.fetch!(opts, :boot_id),
      runner: Keyword.fetch!(opts, :runner)
    }

    with {:ok, %{assignment: admitted, secrets: secrets}} <- Attempt.admitted(child_id, holder),
         {:ok, issued} <- Assignments.issue(admitted) do
      {:ok,
       %{
         assignment: issued.assignment,
         attempt_keys: issued.attempt_keys,
         secrets: secrets,
         input: admitted.input
       }}
    end
  end

  # A stepped invocation (`Crucible.Admission.step_invoke/4`) run
  # under its child authority by `dispatch`. A spawn-shaped step takes its
  # charge row and holds its invoke-budget slot under the guard until the
  # child's attempt takes both over.
  #
  # A bound target that no longer resolves is `setup_required`: the consent
  # names a dependency the installed world cannot satisfy. An unresolvable
  # unbound target proceeds to admission and is refused there.
  defp dispatch_child(decision, input, opts, dispatch) do
    ctx = Keyword.fetch!(opts, :ctx)
    spawned? = Keyword.get(opts, :guest_fn) == :spawn

    with :ok <- take_charge(decision, opts, spawned?) do
      if decision.bound? and is_nil(decision.component) do
        if spawned? do
          Sanctum.Authority.release_invoke(decision.authority)
          Charge.give_back(decision.authority, opts)
        end

        {:error,
         {:setup_required,
          %{
            profile_id: decision.authority.profile_id,
            node_ref: decision.reference,
            need: decision.need || "",
            reason: :unresolvable_target
          }}}
      else
        dispatch.(ctx, decision.reference, input, dispatch_opts(decision, opts, spawned?))
      end
    end
  end

  defp take_charge(_decision, _opts, false), do: :ok

  defp take_charge(decision, opts, true) do
    with :ok <- Charge.take(decision.authority, opts) do
      Sanctum.Authority.guard_invoke(decision.authority)
    end
  end

  defp dispatch_opts(decision, opts, spawned?) do
    [authority: decision.authority]
    |> put(:parent_execution_id, Keyword.get(opts, :parent_execution_id))
    |> put(:root_execution_id, Keyword.get(opts, :root_execution_id))
    |> put(:parent_attempt, parent_attempt(opts))
    |> put(:child_key, Keyword.get(opts, :child_key))
    |> put(:activation_digest, Keyword.get(opts, :activation_digest))
    |> put(:activation_stamp, Keyword.get(opts, :activation_stamp))
    |> put(:client_ip, Keyword.get(opts, :client_ip))
    |> put(:execution_id, Keyword.get(opts, :execution_id))
    # Only a root carries a profile; an in-chain child walks its parent's
    # authority.
    |> put(:profile_id, Keyword.get(opts, :profile_id))
    |> put(:type, decision.component && Map.get(decision.component, "type"))
    # The edge authorizing this hop, for audit attribution.
    |> put(:dep_ref, decision.reference)
    |> put(:need, decision.need)
    |> put(:retention_class, Keyword.get(opts, :retention_class))
    |> put(:retained_input, Keyword.get(opts, :retained_input))
    |> put(:charge, hold_of(decision.authority, opts))
    |> put(:step, step_of(opts))
    |> put(:step_spans, Keyword.get(opts, :step_spans))
    |> put(:envelope, Keyword.get(opts, :envelope) == true || nil)
    |> put(:held_invoke, spawned? || nil)
    |> put(:runner, Keyword.get(opts, :runner))
    |> put(:parent_deadline, Keyword.get(opts, :parent_deadline))
    |> put(:service_id, Keyword.get(opts, :service_id))
    |> put(:boot_id, Keyword.get(opts, :boot_id))
    |> put(:worker, Keyword.get(opts, :worker))
  end

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)

  # A child of a formula is admitted under its parent's attempt: a parent
  # that is no longer running admits nothing.
  defp parent_attempt(opts) do
    if Keyword.get(opts, :parent_execution_id), do: Keyword.get(opts, :attempt)
  end

  defp hold_of(%Authority{budget: budget}, opts) do
    case Keyword.get(opts, :charge) do
      %{id: id} -> %{reservation_id: budget.id, id: id}
      _ -> nil
    end
  end

  defp step_of(opts) do
    with step_id when is_binary(step_id) <- Keyword.get(opts, :step_id),
         %{generation: generation} <- Keyword.get(opts, :charge) do
      %{id: step_id, generation: generation}
    else
      _ -> nil
    end
  end

  @doc """
  Claim a turn's logical root: the `kind: "turn"` execution, its attempt,
  its reservation and a `:root` slot on the calling process, with the
  agent's authority loaded and no guest started. `opts`: `:profile`
  (a `RootSelect` selector, `:default` when absent), `:turn_id`,
  `:thread_id`, `:envelope` (the input keys the row records). Answers the
  claim the loop keeps (`t:Crucible.TurnRoot.claim/0`).
  """
  @spec claim_turn_root(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate claim_turn_root(ctx, agent_ref, opts \\ []), to: TurnRoot, as: :claim

  @doc """
  Pause the turn root: keeper stopped, rows moved, slot released
  (`:turn_id`, `:fence`, `:reason`, `:launch_step_id`, `:claim`). With
  `:uncertain` (`%{step_id, generation, reason, content}`) the pause is
  the uncertain boundary: the step's mark, the covering aborted row and
  the pause in one transaction; the answer carries the `aborted` row.
  """
  @spec pause_turn_root(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate pause_turn_root(ctx, execution_id, opts), to: TurnRoot, as: :pause

  @doc "Resume a paused turn root from the calling process: slot first, then the rows, then a keeper (`:turn_id`, `:fence`)."
  @spec resume_turn_root(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate resume_turn_root(ctx, execution_id, opts), to: TurnRoot, as: :resume

  @doc "Adopt a turn root whose attempt a takeover already opened: slot and keeper only (`:attempt`)."
  @spec adopt_turn_root(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate adopt_turn_root(ctx, execution_id, opts), to: TurnRoot, as: :adopt

  @doc "Local cleanup after the turn's terminal write: keeper stopped, slot released (`:claim`)."
  @spec release_turn_root(Context.t(), String.t(), keyword()) :: :ok
  defdelegate release_turn_root(ctx, execution_id, opts), to: TurnRoot, as: :release

  @doc """
  Cancel a running execution of the context's athanor; only a running
  execution can be cancelled. See `Crucible.Dispatch.cancel/3`.
  """
  @spec cancel(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(%Context{} = ctx, execution_id), do: Dispatch.cancel(ctx, execution_id)

  @doc """
  End a running execution because its consent changed underneath it: it
  ends `restart_required`, and a rerun selects the new revision.
  """
  @spec cancel_for_restart(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate cancel_for_restart(ctx, execution_id, payload), to: Dispatch

  @doc "An execution record of the context's athanor by id."
  @spec get(Context.t(), String.t()) :: {:ok, Record.t()} | {:error, term()}
  defdelegate get(ctx, execution_id), to: Record

  @doc """
  The execution records of the context's athanor. Options: `:limit`
  (default 20) and `:status` (`:running`, `:completed`, `:failed` or
  `:all`).
  """
  @spec list(Context.t(), keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  defdelegate list(ctx, opts \\ []), to: Record
end
