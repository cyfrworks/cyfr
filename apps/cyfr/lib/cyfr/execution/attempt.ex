# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Attempt do
  @moduledoc """
  One process per open execution attempt, holding what CYFR keeps of a
  run between its admission and its terminal write. The attempt's runner
  reaches it only through host calls (`Cyfr.Execution.Host`), which verify
  the call before they reach here.

  `Cyfr.Execution.Admission` opens it once the run's row is admitted,
  registered under the execution's id (with the attempt id as its value)
  in `Cyfr.Execution.Attempt.Registry` and supervised by
  `Cyfr.Execution.Attempt.Supervisor`. The process that opens it is its
  waiter (`Cyfr.Execution.Dispatch.await/2`). It holds:

  - the close state (`Cyfr.Execution.Close`): the admitted row, the
    admission context and the node's limits, which only this process
    closes the run with;
  - the claim: the runner that attached (`attach/2`) and the nonces its
    calls have presented;
  - the masking set: the vault fields unsealed at attach, and every OAuth
    access token it dispenses;
  - the run's emitter (`Cyfr.Execution.Emit`): its stream, the root whose
    emit budget it draws on, the authority its events are attributed by,
    and the text it holds back;
  - the context a guest's calls run in (the admission context on the guest
    plane), the node's reference, the need its edge was reached through
    and its limits;
  - the worker service the run is dispatched to (its `Cyfr.WorkerAPI`
    module and boot id) and the component's bytes its runner runs;
  - what the run holds while it is open: its execution slot
    (`take_slot/3`), and, for a spawned child, the invoke-budget slot its
    waiter charged (taken over from the waiter) and its charge row.

  Its calls are serialized, so a token is either in the masking set before
  the run closes or is never dispensed, and a close waits for an emit in
  flight. A close sends the emitter's held text, masked, then runs
  `Cyfr.Execution.Close` in this process with the full set, gives back what
  the run held, tells the waiter the result, answers the runner and stops.

  A run whose runner was not started is closed failed (`refuse/2`).

  It stops without closing the run, sending nothing it held and giving
  back what the run held, when a call finds the attempt no longer holds its
  row (another attempt took it over, it was cancelled or it lapsed), when
  its runner is gone (`stop_unclosed/2`), and when its waiter exits. A
  waiter that exits kills the run: the attempt asks its worker service to
  kill the runner (`c:Cyfr.WorkerAPI.kill/1`), counts a kill of a runner
  that had attached against the athanor
  (`Cyfr.Execution.Semaphore.note_unreaped/2`), and lapses its row
  (`Cyfr.Execution.Lapse`). A waiter whose attempt stops without closing
  closes the run lost (`Cyfr.Execution.Close.lost/1`), which writes nothing
  over a row the attempt no longer holds.

  A process killed outright gives back its slots through their monitors,
  and its charge row through the reservation sweep.

  ## A boot that does not hold the control plane

  An attempt writes only while its boot holds the control plane
  (`Cyfr.ControlPlane.owner?/0`). Once it does not, the attempt stops
  without closing its run and gives back what the run held: at its next
  call, before any close would write, and within a second on its own. It
  unseals nothing, dispenses nothing and lapses nothing, and its waiter's
  lost close writes nothing (`Cyfr.Execution.Close.lost/1`); the rows are
  the holder's to settle.

  ## What it shows

  Its status (`:sys.get_status/1`) and a crash report of it show the
  attempt's identity and claim, never the masking set, the emitter's held
  text, the component's bytes or what its last call carried.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Cyfr.Delta
  alias Cyfr.Execution.{Charge, Close, Emit, Lapse, Outcome, Slot, StepSpans}
  alias Sanctum.Context

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor

  # A provider name is guest input that reaches a telemetry tag and a log
  # line; a real one is a short identifier.
  @provider_max 128

  # How long a presented nonce is remembered: twice the window a host call's
  # timestamp must fall within, so a replay inside that window is refused.
  @nonce_ttl_ms 60_000

  @owner_check_ms 1_000

  @redacted "[REDACTED]"

  @derive {Inspect,
           only: [:execution_id, :attempt, :fence, :component_ref, :claimed_by, :runner_id]}
  @enforce_keys [
    :execution_id,
    :attempt,
    :fence,
    :ctx,
    :authority,
    :component_ref,
    :limits,
    :emit,
    :close,
    :owner,
    :waiter
  ]
  defstruct @enforce_keys ++
              [
                :need,
                :claimed_by,
                :worker,
                :runner_id,
                :wasm_bytes,
                :slot,
                :charge,
                held_invoke: false,
                secrets: %{},
                tokens: [],
                nonces: %{}
              ]

  @typedoc "A verified host call's header fields (`Cyfr.WorkerAuth.host_call/0`)."
  @type caller :: Cyfr.WorkerAuth.host_call()

  @typedoc "An operation a runner calls on its attempt once it has attached."
  @type op ::
          {:complete, Outcome.t()}
          | {:fail, Outcome.t()}
          | {:push_deltas, [Delta.t()]}
          | {:oauth_token, String.t()}
          | {:take_rate, String.t()}

  @typedoc """
  What a runner in this BEAM runs its attempt with beyond its assignment:
  the context its guest's in-process calls run in (the admission context on
  the guest plane), the run's authority and the component's bytes.
  """
  @type admitted :: %{ctx: Context.t(), authority: Authority.t(), wasm_bytes: binary()}

  @doc """
  Open the attempt of an admitted execution. The calling process is its
  waiter, and the attempt stops when it exits.

  Required options: `:execution_id`, `:attempt` (the attempt id that owns
  the row), `:ctx` (the admission context), `:authority`, `:component_ref`
  (the node's reference, which keys its `oauth:` rate) and `:close` (the
  run's close state). Optional: `:fence` (default 1), `:need` (the need
  its edge was reached through), `:limits` (default the authority's node
  limits), `:stream_id` (the stream its guest's events go on, default the
  execution's), `:budget_id` (the root whose emit budget they draw on,
  default the execution's), `:step_spans`, `:worker` and `:runner_id` (the
  `Cyfr.WorkerAPI` module and the boot id of the worker service the run is
  dispatched to), `:wasm_bytes` (the component's bytes), `:held_invoke`
  (true when the waiter holds a charged invoke-budget slot of the
  authority's budget, which the attempt takes over) and `:charge` (the
  charge row that slot holds, `%{id: charge_id}`).

  Answers `{:error, {:already_started, pid}}` when the execution already
  has an open attempt.
  """
  @spec open(keyword()) :: {:ok, pid()} | {:error, term()}
  def open(opts) when is_list(opts) do
    opts =
      Keyword.merge(opts,
        owner: self(),
        callers: [self() | Process.get(:"$callers", [])],
        logger: Cyfr.LoggerContext.capture()
      )

    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def start_link(opts) do
    via = {:via, Registry, {@registry, Keyword.fetch!(opts, :execution_id), opts[:attempt]}}
    GenServer.start_link(__MODULE__, opts, name: via)
  end

  @doc "The process of the open attempt of `execution_id`, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(execution_id) when is_binary(execution_id) do
    case Registry.lookup(@registry, execution_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Take the run's execution slot of `class` in this attempt, waiting at
  most `timeout` ms (`Cyfr.Execution.Slot.acquire/4`). Answers `:ok` when
  the attempt holds it; a refusal closes the run failed with the refusal's
  sentence and answers `:closed`.
  """
  @spec take_slot(pid(), Cyfr.Execution.Semaphore.class(), timeout()) :: :ok | :closed
  def take_slot(pid, class, timeout) when is_pid(pid) do
    GenServer.call(pid, {:take_slot, class, timeout}, :infinity)
  catch
    :exit, _reason -> :closed
  end

  @doc """
  Close the run of the attempt `pid` failed with `sentence`, for a run
  whose runner was not started, and stop; the waiter hears the result.
  Answers `:closed`.
  """
  @spec refuse(pid(), String.t()) :: :closed
  def refuse(pid, sentence) when is_pid(pid) and is_binary(sentence) do
    GenServer.call(pid, {:refuse, sentence}, :infinity)
  catch
    :exit, _reason -> :closed
  end

  @doc """
  Attach the caller's runner, whose claim on the attempt row is written
  (`Arca.ExecutionAttempts.claim/4`), and answer the fields the run's vault
  edge projects: an empty map when it grants none.

  The first attach unseals the edge while its consent is still the
  profile's head, and marks the guest's start on the run's clock
  (`Cyfr.Execution.StepSpans.guest_started/1`). A selection the loader
  could not resolve, a consent that moved and an edge whose material cannot
  be produced each close the run failed as `{:setup_required, payload}`,
  which is answered. An attach by the runner already attached answers the
  same fields; one by any other runner is `:replayed`. A caller naming
  another attempt, fence or worker service, or an attempt that is not open,
  is `:lost`.
  """
  @spec attach(String.t(), caller()) ::
          {:ok, %{optional(String.t()) => String.t()}}
          | {:error, :lost | :replayed | {:setup_required, map()}}
  def attach(execution_id, caller) when is_binary(execution_id) and is_map(caller) do
    call(execution_id, {:attach, caller})
  end

  @doc """
  What the caller's runner runs the attempt with beyond its assignment
  (`t:admitted/0`), for a runner in this BEAM. The caller must be the
  attached runner at this attempt, fence and worker service, and the row
  must still be held
  by it; otherwise `:lost`, or `:unavailable` when the store cannot answer.
  """
  @spec admitted(String.t(), caller()) :: {:ok, admitted()} | {:error, :lost | :unavailable}
  def admitted(execution_id, caller) when is_binary(execution_id) and is_map(caller) do
    call(execution_id, {:admitted, caller})
  end

  @doc """
  Run `op` for the caller's runner. Before it runs, the caller must be the
  attached runner at this attempt, fence and worker service, its nonce must
  not have been
  presented before, and the attempt row must still be held by it
  (`Arca.ExecutionAttempts.held?/4`). A caller that fails the first two is
  `:lost`; a row no longer held is `:lost` and stops the attempt; a store
  that cannot answer is `:unavailable`.

  - `{:complete, outcome}` closes the run with the outcome's output:
    `{:ok, masked_output}`, or `{:error, {:failed, message}}` when the close
    recorded a failure instead.
  - `{:fail, outcome}` closes the run failed with the outcome's error: `:ok`.
    An `abandoned` outcome is first counted against the athanor as a kill
    whose native work may still run (`Cyfr.Execution.Semaphore.note_unreaped/2`).
  - `{:push_deltas, deltas}` emits each delta's event on the attempt's
    stream, masked with its set: `{:ok, replies}`, one reply per delta, the
    JSON a guest's `emit` returns. A delta naming another attempt is
    refused in its reply.
  - `{:oauth_token, provider}` dispenses a token from the edge's vault
    resource, charged to the node's `oauth:` rate and added to the masking
    set before it is answered: `{:ok, token}`, or
    `{:error, {:guest_error, "oauth_error", sentence}}` naming the shape of
    what went wrong, never the material involved.
  - `{:take_rate, bucket}` takes one request from the node's consented rate
    for `bucket`, which must be `"http:"` followed by the node's reference:
    `:ok`, or `{:error, {:guest_error, "rate_limited", sentence}}`.

  An outcome or delta naming another attempt than the caller's is refused
  without closing anything.
  """
  @spec call(String.t(), caller(), op()) :: term()
  def call(execution_id, caller, op) when is_binary(execution_id) and is_map(caller) do
    call(execution_id, {:call, caller, op})
  end

  @doc """
  Stop the open attempt `attempt`, dispatched to the worker service boot
  `runner_id`, without closing its run: its runner exited, or its row
  lapsed. An attempt dispatched elsewhere, or none open, is left alone.
  """
  @spec stop_unclosed(String.t(), String.t()) :: :ok
  def stop_unclosed(attempt, runner_id) when is_binary(attempt) and is_binary(runner_id) do
    for pid <- Registry.select(@registry, [{{:_, :"$1", attempt}, [], [:"$1"]}]) do
      try do
        GenServer.call(pid, {:stop_unclosed, attempt, runner_id}, :infinity)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp call(execution_id, message) do
    GenServer.call(via(execution_id), message, :infinity)
  catch
    :exit, _reason -> {:error, :lost}
  end

  defp via(execution_id), do: {:via, Registry, {@registry, execution_id}}

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # The opener's callers, so its database sandbox allowance covers the
    # writes and reads made here.
    Process.put(:"$callers", Keyword.fetch!(opts, :callers))
    Cyfr.LoggerContext.restore(Keyword.fetch!(opts, :logger))

    execution_id = Keyword.fetch!(opts, :execution_id)
    authority = Keyword.fetch!(opts, :authority)
    ctx = Context.enter_guest(Keyword.fetch!(opts, :ctx))
    owner = Keyword.fetch!(opts, :owner)
    owner_ref = Process.monitor(owner)

    state = %__MODULE__{
      execution_id: execution_id,
      attempt: Keyword.fetch!(opts, :attempt),
      fence: Keyword.get(opts, :fence, 1),
      ctx: ctx,
      authority: authority,
      component_ref: Keyword.fetch!(opts, :component_ref),
      need: Keyword.get(opts, :need),
      limits: Keyword.get_lazy(opts, :limits, fn -> Authority.limits(authority) end),
      emit:
        Emit.new(Keyword.get(opts, :stream_id, execution_id),
          ctx: ctx,
          authority: authority,
          budget_id: Keyword.get(opts, :budget_id, execution_id),
          step_spans: Keyword.get(opts, :step_spans)
        ),
      close: Keyword.fetch!(opts, :close),
      owner: owner_ref,
      waiter: owner,
      worker: Keyword.get(opts, :worker),
      runner_id: Keyword.get(opts, :runner_id),
      wasm_bytes: Keyword.get(opts, :wasm_bytes),
      charge: Keyword.get(opts, :charge),
      held_invoke: take_over_invoke(Keyword.get(opts, :held_invoke, false), authority, owner)
    }

    Process.send_after(self(), :owner_check, @owner_check_ms)
    {:ok, state}
  end

  # The waiter holds the slot under the invoke-budget guard until here; a
  # waiter that died first had its slot given back already.
  defp take_over_invoke(true, authority, owner),
    do: Sanctum.Authority.take_over_invoke(authority, owner) == :ok

  defp take_over_invoke(false, _authority, _owner), do: false

  @impl true
  def handle_call({:take_slot, class, timeout}, _from, state) do
    case Slot.acquire(class, state.ctx.athanor_id, timeout, nil) do
      {:ok, token} ->
        {:reply, :ok, %{state | slot: token}}

      {:error, sentence} ->
        refuse_run(state, sentence)
    end
  end

  def handle_call({:refuse, sentence}, _from, state), do: refuse_run(state, sentence)

  def handle_call({kind, _caller} = message, _from, state) when kind in [:attach, :admitted],
    do: owned(message, state)

  def handle_call({:call, _caller, _op} = message, _from, state), do: owned(message, state)

  def handle_call({:stop_unclosed, attempt, runner_id}, _from, state) do
    if state.attempt == attempt and state.runner_id == runner_id,
      do: {:stop, :normal, :ok, release_holds(state)},
      else: {:reply, :ok, state}
  end

  # A call no clause names is refused without matching its terms, which
  # can carry what a runner sent.
  def handle_call(message, _from, state) do
    Logger.error(
      "[Cyfr.Execution.Attempt] #{state.execution_id} refused an unknown call " <>
        inspect(message_shape(message))
    )

    {:reply, {:error, :lost}, state}
  end

  defp owned(message, state) do
    if Cyfr.ControlPlane.owner?(),
      do: handle_owned(message, state),
      else: stop_unowned({:error, :lost}, state)
  end

  defp handle_owned({:attach, caller}, state) do
    cond do
      not names_attempt?(state, caller) ->
        {:reply, {:error, :lost}, state}

      state.claimed_by == caller.runner ->
        {:reply, {:ok, state.secrets}, state}

      is_binary(state.claimed_by) ->
        {:reply, {:error, :replayed}, state}

      true ->
        unseal(state, caller)
    end
  end

  defp handle_owned({:admitted, caller}, state) do
    with :ok <- claimant(state, caller) do
      case held(caller) do
        :ok -> {:reply, {:ok, admitted(state)}, state}
        :gone -> {:stop, :normal, {:error, :lost}, release_holds(state)}
        :unavailable -> {:reply, {:error, :unavailable}, state}
      end
    else
      :lost -> {:reply, {:error, :lost}, state}
    end
  end

  defp handle_owned({:call, caller, op}, state) do
    with :ok <- claimant(state, caller),
         {:ok, noted} <- fresh_nonce(state, caller) do
      case held(caller) do
        :ok -> run(op, noted)
        :gone -> {:stop, :normal, {:error, :lost}, release_holds(noted)}
        :unavailable -> {:reply, {:error, :unavailable}, noted}
      end
    else
      :lost -> {:reply, {:error, :lost}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{owner: ref} = state) do
    kill_runner(state)
    lapse(state)
    {:stop, :normal, release_holds(state)}
  end

  def handle_info(:owner_check, state) do
    if Cyfr.ControlPlane.owner?() do
      Process.send_after(self(), :owner_check, @owner_check_ms)
      {:noreply, state}
    else
      {:stop, :normal, release_holds(state)}
    end
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, %__MODULE__{} = state} -> {:state, redact(state)}
      {:message, message} -> {:message, message_shape(message)}
      {:reason, reason} -> {:reason, reason_shape(reason)}
      {:log, _log} -> {:log, []}
      other -> other
    end)
  end

  defp redact(state) do
    %{
      state
      | secrets: @redacted,
        tokens: @redacted,
        nonces: @redacted,
        wasm_bytes: @redacted,
        emit: %{state.emit | held: @redacted}
    }
  end

  # A call's operation, without the outcome, deltas or assignment it carried.
  defp message_shape({:call, _caller, op}) when is_tuple(op), do: {:call, elem(op, 0)}
  defp message_shape(message) when is_tuple(message), do: elem(message, 0)
  defp message_shape(_message), do: @redacted

  # An exit reason can carry what the attempt held or a call carried (an
  # exception's fields, a failed match's value): only its kind is shown.
  defp reason_shape(reason) when is_atom(reason), do: reason
  defp reason_shape(%module{__exception__: true}), do: module

  defp reason_shape(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp reason_shape(_reason), do: @redacted

  defp admitted(state),
    do: %{ctx: state.ctx, authority: state.authority, wasm_bytes: state.wasm_bytes}

  # ---------------------------------------------------------------------------
  # Holds
  # ---------------------------------------------------------------------------

  # What the run held while open goes back when the attempt stops: its
  # execution slot, its invoke-budget slot and its charge row.
  defp release_holds(state) do
    if state.slot, do: Slot.release(state.slot)
    if state.held_invoke, do: Sanctum.Authority.release_invoke(state.authority)
    if state.charge, do: give_back_charge(state)
    %{state | slot: nil, held_invoke: false, charge: nil}
  end

  # A charge row the store cannot give back now is reclaimed by the
  # reservation sweep once its holder has ended.
  defp give_back_charge(state) do
    Charge.give_back(state.authority, charge: state.charge, ctx: state.ctx)
  catch
    :exit, reason ->
      Logger.error(
        "[Cyfr.Execution.Attempt] #{state.execution_id}'s charge was not given back: " <>
          inspect(reason)
      )
  end

  # A waiter that exited kills its run. The kill of a runner that attached
  # is counted before the attempt gives back its slot, so the athanor's next
  # acquisition sees it.
  defp kill_runner(%__MODULE__{worker: nil}), do: :ok

  defp kill_runner(state) do
    killed =
      try do
        state.worker.kill(state.execution_id)
      catch
        :exit, reason -> {:error, reason}
      end

    if killed == :ok and is_binary(state.claimed_by),
      do: note_unreaped(state)

    :ok
  end

  # A run dispatched to no worker service has no runner whose attempt lapses.
  defp lapse(%__MODULE__{worker: nil}), do: :ok
  defp lapse(state), do: Lapse.dispatched(state.runner_id, [state.attempt])

  defp note_unreaped(state) do
    tenant = state.ctx.athanor_id

    case Cyfr.Execution.Semaphore.note_unreaped(tenant, state.execution_id) do
      :ok ->
        :ok

      {:error, :unavailable} ->
        Logger.error(
          "[Cyfr.Execution.Attempt] unreaped kill of #{state.execution_id} for tenant " <>
            "#{inspect(tenant)} is uncharged: the semaphore did not answer"
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Attach
  # ---------------------------------------------------------------------------

  # Credentials come only from the current edge's vault resource, projected
  # by the vault reader, while the consent is still the profile's head.
  defp unseal(state, caller) do
    case fetch_secrets(state) do
      {:ok, secrets} ->
        StepSpans.guest_started(state.close.step_spans)
        {:reply, {:ok, secrets}, %{state | claimed_by: caller.runner, secrets: secrets}}

      {:setup_required, reason} ->
        typed = {:setup_required, setup_payload(state, reason)}

        close_run(state, fn _ -> {:error, typed} end, fn -> Close.fail(state.close, [], typed) end)

      {:raised, message} ->
        close_run(state, fn _ -> {:error, :lost} end, fn ->
          Close.fail(state.close, [], message)
        end)
    end
  end

  defp fetch_secrets(%__MODULE__{authority: authority, close: close}) do
    case authority do
      %Authority{resources: %Edge{vault: %{via: via}}} ->
        {:setup_required, {:selection_unbound, via.label}}

      %Authority{resources: %Edge{vault: %{} = vault}} ->
        if Sanctum.Consent.Loader.pinned_intact?(close.ctx, authority) do
          case Sanctum.VaultReader.fetch(close.ctx, vault) do
            {:ok, secrets} -> {:ok, secrets}
            {:error, reason} -> {:setup_required, reason}
          end
        else
          {:setup_required, :consent_moved}
        end

      _ ->
        {:ok, %{}}
    end
  rescue
    exception -> {:raised, Close.exception_message(exception, __STACKTRACE__)}
  end

  defp setup_payload(state, reason) do
    %{
      profile_id: state.authority.profile_id,
      node_ref: state.component_ref,
      need: state.need || "",
      reason: Close.setup_reason(reason)
    }
  end

  # ---------------------------------------------------------------------------
  # Calls
  # ---------------------------------------------------------------------------

  defp claimant(state, caller) do
    if names_attempt?(state, caller) and state.claimed_by == caller.runner,
      do: :ok,
      else: :lost
  end

  defp names_attempt?(state, caller) do
    caller.execution_id == state.execution_id and caller.attempt == state.attempt and
      caller.fence == state.fence and caller.worker == state.runner_id
  end

  defp fresh_nonce(state, %{nonce: nonce, ts: ts}) do
    now = System.system_time(:millisecond)
    nonces = Map.reject(state.nonces, fn {_nonce, seen} -> now - seen > @nonce_ttl_ms end)

    if Map.has_key?(nonces, nonce),
      do: :lost,
      else: {:ok, %{state | nonces: Map.put(nonces, nonce, max(ts, now))}}
  end

  defp held(caller) do
    case Arca.ExecutionAttempts.held?(
           caller.athanor_id,
           caller.attempt,
           caller.fence,
           caller.runner
         ) do
      true -> :ok
      false -> :gone
      {:error, _reason} -> :unavailable
    end
  end

  defp run({:complete, %Outcome{status: :completed} = outcome}, state) do
    if names_outcome?(state, outcome) do
      secrets = masking_set(state)

      close_run(state, &completed_answer/1, fn ->
        Close.complete(state.close, secrets, outcome.output, %{})
      end)
    else
      refuse_outcome(state)
    end
  end

  defp run({:fail, %Outcome{status: :failed} = outcome}, state) do
    if names_outcome?(state, outcome) do
      if outcome.abandoned, do: note_unreaped(state)

      close_run(state, fn _result -> :ok end, fn ->
        Close.fail(state.close, masking_set(state), outcome.error)
      end)
    else
      refuse_outcome(state)
    end
  end

  defp run({:push_deltas, deltas}, state) do
    {replies, emit} =
      Enum.map_reduce(deltas, state.emit, fn delta, emit -> emit_delta(state, emit, delta) end)

    {:reply, {:ok, replies}, %{state | emit: emit}}
  end

  defp run({:oauth_token, provider}, state) do
    provider = bound_provider(provider)

    case check_dispense_rate(state) do
      :ok ->
        {reply, state} = dispense(state, provider)
        {:reply, reply, state}

      {:error, message} ->
        {:reply, oauth_refusal(message), state}
    end
  end

  defp run({:take_rate, bucket}, state) do
    {:reply, take_rate(state, bucket), state}
  end

  defp run(_op, state), do: {:reply, {:error, :lost}, state}

  defp names_outcome?(state, %Outcome{} = outcome) do
    outcome.execution_id == state.execution_id and outcome.attempt == state.attempt and
      outcome.fence == state.fence
  end

  defp refuse_outcome(state) do
    Logger.error(
      "[Cyfr.Execution.Attempt] #{state.execution_id} refused an outcome naming another attempt"
    )

    {:reply, {:error, :lost}, state}
  end

  # A close sends what the emitter holds, masked with the set as it stands,
  # before the terminal row is written; what the run held goes back before
  # the waiter hears the result, and the waiter hears it before the runner
  # is answered and the attempt stops.
  defp close_run(state, answer, close, unowned \\ {:error, :lost}) do
    if Cyfr.ControlPlane.owner?(),
      do: close_owned(state, answer, close),
      else: stop_unowned(unowned, state)
  end

  # A run its runner was not started for answers its waiter `:closed`,
  # closed or not.
  defp refuse_run(state, sentence) do
    close_run(
      state,
      fn _result -> :closed end,
      fn -> Close.fail(state.close, [], sentence) end,
      :closed
    )
  end

  # Nothing of the run is sent, written or unsealed: its waiter's lost
  # close answers without writing either.
  defp stop_unowned(reply, state), do: {:stop, :normal, reply, release_holds(state)}

  defp close_owned(state, answer, close) do
    result =
      try do
        _flushed = Emit.flush(state.emit, masking_set(state))
        close.()
      rescue
        exception ->
          Close.fail(
            state.close,
            masking_set(state),
            Close.exception_message(exception, __STACKTRACE__)
          )
      end

    state = release_holds(state)
    send(state.waiter, {__MODULE__, self(), result})
    {:stop, :normal, answer.(result), state}
  end

  defp completed_answer({:ok, %{output: output}}), do: {:ok, output}

  defp completed_answer({:error, message}) when is_binary(message),
    do: {:error, {:failed, message}}

  defp completed_answer({:error, _typed}), do: {:error, {:failed, "Execution failed"}}

  defp emit_delta(state, emit, %Delta{} = delta) do
    if delta.execution_id == state.execution_id and delta.attempt == state.attempt and
         delta.fence == state.fence do
      Emit.emit(emit, delta.event, masking_set(state))
    else
      {emit_failed(), emit}
    end
  rescue
    exception ->
      Logger.error(
        "[Cyfr.Execution.Attempt] #{state.execution_id} emit raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {emit_failed(), emit}
  end

  defp emit_failed, do: Cyfr.WitResponse.encode_error(:dispatch_error, "The emit call failed.")

  defp masking_set(state), do: Map.values(state.secrets) ++ state.tokens

  # Each HTTP request draws on the node's `http:` bucket under its consented
  # limit; a limiter that cannot answer refuses.
  defp take_rate(state, "http:" <> ref = bucket) when ref == state.component_ref do
    case Cyfr.Execution.Rates.check(state.ctx.athanor_id, bucket, %{
           rate_limit: state.limits.rate_limit
         }) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        rate_refusal("HTTP egress rate limit exceeded; retry in #{retry_after}ms")

      {:error, :missing_tenant} ->
        rate_refusal("HTTP egress refused: no resolved athanor")
    end
  catch
    :exit, _reason -> rate_refusal("HTTP egress refused: rate limiter unavailable")
  end

  defp take_rate(_state, _bucket),
    do: rate_refusal("HTTP egress refused: the rate bucket is not this component's")

  defp rate_refusal(message), do: {:error, {:guest_error, "rate_limited", message}}

  defp oauth_refusal(message), do: {:error, {:guest_error, "oauth_error", message}}

  # Token requests are metered under their own `oauth:` bucket, apart from
  # HTTP egress; a limiter that cannot answer refuses the dispense.
  defp check_dispense_rate(state) do
    case Cyfr.Execution.Rates.check(
           state.ctx.athanor_id,
           "oauth:" <> state.component_ref,
           %{rate_limit: state.limits.rate_limit}
         ) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        {:error, "token dispense rate limit exceeded; retry in #{retry_after}ms"}

      {:error, :missing_tenant} ->
        {:error, "token dispense refused: no resolved athanor"}
    end
  catch
    :exit, _reason -> {:error, "token dispense refused: rate limiter unavailable"}
  end

  defp dispense(state, provider) do
    start_time = System.monotonic_time(:millisecond)

    case resolve_token(state, provider) do
      {:ok, token} ->
        token_request(state, provider, start_time, %{status: :ok})
        {{:ok, token}, %{state | tokens: [token | state.tokens]}}

      {:error, reason} ->
        message = refusal_message(reason)

        token_request(state, provider, start_time, %{
          status: :error,
          reason: String.slice(message, 0, 100)
        })

        {oauth_refusal(message), state}
    end
  end

  # The token comes from the current edge's vault resource through the
  # vault reader; an edge without one dispenses nothing.
  defp resolve_token(%__MODULE__{authority: %Authority{resources: resources}} = state, provider) do
    case resources do
      %Edge{vault: %{} = vault} ->
        Sanctum.VaultReader.oauth_token(state.ctx, vault, provider)

      _ ->
        {:error, "no vault resource granted on this edge"}
    end
  rescue
    exception ->
      Logger.error(
        "[Cyfr.Execution.Attempt] #{state.execution_id} token dispense raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :resolver_unavailable}
  catch
    _kind, _value -> {:error, :resolver_unavailable}
  end

  defp token_request(state, provider, start_time, metadata) do
    :telemetry.execute(
      [:cyfr, :opus, :oauth, :token_request],
      %{duration_ms: System.monotonic_time(:millisecond) - start_time},
      Map.merge(%{component_ref: state.component_ref, provider: provider}, metadata)
    )
  end

  defp bound_provider(provider) when is_binary(provider),
    do: binary_part(provider, 0, min(byte_size(provider), @provider_max))

  # One sentence per shape. The vault reader's reasons name what went wrong
  # and sometimes quote the material that did — `{:invalid_payload, payload}`
  # carries the payload itself — so the guest is told the shape of the
  # failure and never its contents.
  defp refusal_message(reason) when is_binary(reason), do: reason
  defp refusal_message(:anonymous_denied), do: "anonymous callers may not dispense tokens"
  defp refusal_message(:binding_mismatch), do: "the credential no longer matches its consent"
  defp refusal_message(:unseal_failed), do: "the credential could not be unsealed"
  defp refusal_message(:no_oauth_material), do: "this credential carries no OAuth material"
  defp refusal_message(:resolver_unavailable), do: "the credential store is unavailable"
  defp refusal_message({:entry_unavailable, status}), do: "the credential is #{status}"

  defp refusal_message({:provider_mismatch, provider}),
    do: "this credential is not for #{bound_provider(provider)}"

  defp refusal_message({:scope_projection_unsatisfiable, _scopes}),
    do: "the granted scopes do not cover this request"

  defp refusal_message(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp refusal_message({tag, _detail}) when is_atom(tag), do: refusal_message(tag)
  defp refusal_message(_other), do: "the token could not be dispensed"
end
