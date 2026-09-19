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
  waiter (`Cyfr.Execution.Dispatch.await/2`) until it hands the attempt to
  the runner that claimed it (`hand_over/1`), as a formula's child run in
  its parent's runner is handed over. It holds:

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
  - what its guest's children and catalog tools are decided under
    (`Cyfr.Execution.Host.Children`): the run's authority, its root, the
    declared needs and activation digest the resolver gave its component,
    and the delegation roster its admitted input carries
    (`Cyfr.Execution.Delegation`);
  - what its assignment is signed from, so a child admitted under a key
    its runner minted is handed to that runner again (`admitted/2`);
  - the worker service the run is dispatched to (its
    `t:Cyfr.WorkerAPI.endpoint/0` and boot id) and the digest of the
    component its runner runs;
  - what the run holds while it is open: its execution slot
    (`take_slot/3`), and, for a spawned child, the invoke-budget slot its
    waiter charged (taken over from the waiter) and its charge row.

  Its calls are serialized, so a token is either in the masking set before
  the run closes or is never dispensed, and a close waits for an emit in
  flight. A close sends the emitter's held text, masked, then runs
  `Cyfr.Execution.Close` in this process with the full set, gives back what
  the run held, tells the waiter the result, answers the runner and stops.

  ## The execution slot

  `Cyfr.Slots.acquire/4` blocks its caller for as long as the run is
  queued, so the attempt does not call it: a slot holder, a process linked
  to the attempt, waits for the slot and then holds it for the attempt,
  and the attempt answers `take_slot/3` when the holder reports. While its
  run is queued the attempt therefore hears everything it hears at any
  other time: its waiter's exit, a row that ended (`stop_ended/1`,
  `stop_unclosed/2`), its owner check and its supervisor's stop. Whatever
  stops the attempt ends the holder, and `Cyfr.Slots` takes a dead process
  out of its queue or takes its slot back, whichever it had, so the slot
  goes back once on every path and a run that leaves its wait never takes
  one.

  A slot is waited for, and a granted one kept, only by a run that is
  still live. The attempt reads its row before it waits, so a row that
  ended before the attempt was registered is seen, and again when the
  holder reports the grant, where one whose row ended while it waited
  stops: `take_slot/3` answers `:ok` only for a run whose start may
  follow. A row that ends after that answer is told to the attempt by
  whoever ended it (`stop_ended/1`), and the claim its runner's attach
  needs (`Arca.ExecutionAttempts.claim/4`) is refused by the row itself.

  ## Stopping

  A run whose runner was not started is closed failed (`refuse/2`); one
  whose runner attached is never refused, since the start it answers for
  happened.

  It stops without closing the run, sending nothing it held and giving
  back what the run held, when a call finds the attempt no longer holds its
  row (another attempt took it over, it was cancelled or it lapsed), when
  its row was ended before a runner attached (`stop_ended/1`), when
  its runner is gone (`stop_unclosed/2`), and when its waiter exits. A
  waiter that exits kills the run: the attempt asks its worker service to
  kill the runner (`c:Cyfr.WorkerAPI.kill/1`), unless the run is still
  waiting for its slot and so has none, counts a kill of a runner
  that had attached against the athanor (`note_unreaped/2`), and lapses
  its row (`Cyfr.Execution.Lapse`). A waiter whose attempt stops without closing
  closes the run lost (`Cyfr.Execution.Close.lost/1`), which writes nothing
  over a row the attempt no longer holds. An attempt handed to its runner
  has no waiter: it is registered under its execution's id in
  `Cyfr.Execution.Registry` as dispatched to its worker service, so
  `Cyfr.Execution.Dispatch.stop/2` kills its run through that worker
  service, and the worker service's report of the run's exit
  (`stop_unclosed/2`) stops it.

  A stop by its supervisor runs to the end: a waiter already gone is
  reacted to as above, whether or not its exit was handled yet, and what
  the run held goes back. An attempt killed outright takes its slot holder
  with it, so its execution slot or its place in the queue goes back
  through the slots' monitor, its invoke-budget slot through its guard's,
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
  text or what its last call carried.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Cyfr.Delta
  alias Cyfr.Execution.{Charge, Close, Emit, Host, Lapse, Outcome, StepSpans}
  alias Cyfr.Slots
  alias Sanctum.Context

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor
  @slots Cyfr.Execution.Slots

  # A provider name is guest input that reaches a telemetry tag and a log
  # line; a real one is a short identifier.
  @provider_max 128

  # How long a presented nonce is remembered: twice the window a host call's
  # timestamp must fall within, so a replay inside that window is refused.
  @nonce_ttl_ms 60_000

  @owner_check_ms 1_000

  @redacted "[REDACTED]"

  @derive {Inspect,
           only: [
             :execution_id,
             :attempt,
             :fence,
             :component_ref,
             :claimed_by,
             :service_id,
             :boot_id
           ]}
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
                :root_execution_id,
                :activation_digest,
                :claimed_by,
                :worker,
                :service_id,
                :boot_id,
                :deadline,
                :digest,
                :slot,
                :charge,
                :assignment,
                declared_needs: [],
                roster: [],
                held_invoke: false,
                secrets: %{},
                tokens: [],
                nonces: %{}
              ]

  @typedoc "A verified host call's header fields (`Cyfr.WorkerAuth.host_call/0`)."
  @type caller :: Cyfr.WorkerAuth.host_call()

  @typedoc "An operation a runner calls on its attempt once it has attached."
  @type op ::
          :chain
          | {:complete, Outcome.t()}
          | {:fail, Outcome.t()}
          | {:push_deltas, [Delta.t()]}
          | {:oauth_token, String.t()}
          | {:take_rate, String.t()}
          | Host.Storage.op()

  @typedoc """
  What a run's guest's children and catalog tools are decided under: the
  context its guest's calls run in, the run's authority, its component's
  reference, its root, the declared needs and activation digest the
  resolver gave its component, the delegation roster its admitted input
  carries and the endpoint of the worker service it runs on.
  """
  @type chain :: %{
          ctx: Context.t(),
          authority: Authority.t(),
          component_ref: String.t(),
          root_execution_id: String.t(),
          declared_needs: [String.t()],
          activation_digest: String.t() | nil,
          roster: [map()],
          worker: Cyfr.WorkerAPI.endpoint() | nil,
          deadline: non_neg_integer() | nil
        }

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
  default the execution's), `:root_execution_id` (default the execution's),
  `:declared_needs` (default `[]`) and `:activation_digest` (the
  resolver's, for its guest's children), `:roster` (the delegation roster
  of its admitted input, default `[]`), `:step_spans`, `:worker`,
  `:service_id` and `:boot_id` (the `t:Cyfr.WorkerAPI.endpoint/0`, the id
  and the boot of the worker service the run is dispatched to), `:deadline` (the
  run's subtree deadline in Unix ms, which caps its children's), `:digest` (the digest of the
  component's artifact, which the runner fetches), `:held_invoke` (true
  when the waiter holds a charged invoke-budget slot of the authority's
  budget, which the attempt takes over), `:charge` (the charge row that
  slot holds, `%{id: charge_id}`) and `:assignment` (what the run's
  assignment is signed from, `t:Cyfr.Execution.Assignments.admitted/0`,
  which `admitted/2` answers to the runner holding the claim).

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
  Take the run's execution slot of `class` for this attempt, keyed by its
  athanor, waiting at most `timeout` ms (`Cyfr.Slots.acquire/4` on
  `Cyfr.Execution.Slots`, in the attempt's slot holder). Answers `:ok`
  when the attempt holds the slot and its row, read once the slot was
  granted, is still its to run: the caller may start the run. A refusal
  closes the run failed with the refusal's sentence
  (`Cyfr.Slots.refusal/1`) and answers `:closed`, as does a row that
  cannot be read. An attempt whose row had ended when it was asked, that
  stops while the run is queued, or whose row ended by the time the slot
  was granted, answers `:closed` without closing the run, and holds no
  slot.
  """
  @spec take_slot(pid(), Slots.class(), timeout()) :: :ok | :closed
  def take_slot(pid, class, timeout) when is_pid(pid) do
    GenServer.call(pid, {:take_slot, class, timeout}, :infinity)
  catch
    :exit, _reason -> :closed
  end

  @doc """
  Tell the open attempt of `execution_id`, if there is one, that its row
  was ended by the caller (a cancel, a parent's cascade). Nothing is
  waited for: whoever ends a row is never held up by what its attempt is
  doing.

  The row decides, not the caller. An attempt no runner has attached to
  re-reads its row and, when the run is no longer its to run, stops
  without closing it and gives back what the run held: one still queued
  for its slot leaves the queue, and one that holds its slot gives it
  back, leaving a runner its start may have reached to its waiter's kill.
  An attempt whose runner attached is left to that runner's exit report
  (`stop_unclosed/2`). One whose row is still live, or cannot be read, is
  left as it is; a queued one re-reads its row when its slot is granted.
  """
  @spec stop_ended(String.t()) :: :ok
  def stop_ended(execution_id) when is_binary(execution_id),
    do: GenServer.cast(via(execution_id), :stop_ended)

  @doc """
  Close the run of the attempt `pid` failed with `sentence`, for a run
  whose runner was not started, and stop; the waiter hears the result.
  Answers `:closed`, or `:attached` when a runner has attached: the run
  was started, and it is left to that runner.
  """
  @spec refuse(pid(), String.t()) :: :closed | :attached
  def refuse(pid, sentence) when is_pid(pid) and is_binary(sentence) do
    GenServer.call(pid, {:refuse, sentence}, :infinity)
  catch
    :exit, _reason -> :closed
  end

  @doc """
  Close the run of the attempt `pid` failed with `sentence` and stop,
  whether or not a runner has attached: the runner that claimed it gives
  it back (`c:Cyfr.HostAPI.release_child/2`), which `Cyfr.Execution.Host`
  verifies before calling. Answers `:closed`.
  """
  @spec release(pid(), String.t()) :: :closed
  def release(pid, sentence) when is_pid(pid) and is_binary(sentence) do
    GenServer.call(pid, {:release, sentence}, :infinity)
  catch
    :exit, _reason -> :closed
  end

  @doc """
  Hand the attempt `pid`, attached by the runner that claimed it, from its
  waiter to that runner: the calling process, its waiter, stops waiting and
  the attempt is registered under its execution's id in
  `Cyfr.Execution.Registry` as dispatched to its worker service. Answers
  `:ok`, or `{:error, :lost}` when the attempt is not attached, is not the
  caller's to hand over, or has stopped.
  """
  @spec hand_over(pid()) :: :ok | {:error, :lost}
  def hand_over(pid) when is_pid(pid) do
    GenServer.call(pid, :hand_over, :infinity)
  catch
    :exit, _reason -> {:error, :lost}
  end

  @doc """
  Attach the caller's runner, whose claim on the attempt row is written
  (`Arca.ExecutionAttempts.claim/4`), and answer the fields the run's vault
  edge projects: an empty map when it grants none.

  The first attach unseals the edge while its consent is still the
  profile's head, audits each field it hands over as
  `[:cyfr, :opus, :secret, :dispensed]`, by its name and never its value,
  under the identity this attempt was admitted with, and marks the guest's
  start on the run's clock
  (`Cyfr.Execution.StepSpans.guest_started/1`). A selection the loader
  could not resolve, a consent that moved and an edge whose material cannot
  be produced each close the run failed as `{:setup_required, payload}`,
  which is answered. An attach by the runner already attached answers the
  same fields and audits nothing again, so a runner retrying an attach
  whose answer was lost leaves one entry per field; one by any other
  runner is `:replayed`. A caller naming
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
  Run `op` for the caller's runner. Before it runs, the caller must be the
  attached runner at this attempt, fence and worker service, its nonce must
  not have been
  presented before, and the attempt row must still be held by it
  (`Arca.ExecutionAttempts.held?/4`). A caller that fails the first two is
  `:lost`; a row no longer held is `:lost` and stops the attempt; a store
  that cannot answer is `:unavailable`.

  - `:chain` answers what the run's guest's children and catalog tools are
    decided under (`t:chain/0`). Before it does, the row must also be live
    (`Arca.ExecutionAttempts.live?/4`): a row with a cancel asked of it, or
    whose execution is no longer running, is `:lost` without stopping the
    attempt.
  - `{:complete, outcome}` closes the run with the outcome's output:
    `{:ok, masked_output}`, or `{:error, {:failed, message}}` when the close
    recorded a failure instead.
  - `{:fail, outcome}` closes the run failed with the outcome's error:
    `{:ok, message}`, the failure as the close recorded it, masked. An
    `abandoned` outcome is first counted against the athanor as a kill
    whose native work may still run (`note_unreaped/2`).
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
  - `{:storage, op, args}`, `{:fetch_artifact, digest}` and
    `{:record_denial, denial}` run as `Cyfr.Execution.Host.Storage.run/2`
    answers them, in the attempt's context, under its edge and limits, for
    its component. A storage write runs only while the row is still held
    by the caller, decided with the write
    (`Arca.ExecutionAttempts.while_held/5`); one refused there is `:lost`
    and stops the attempt.

  An outcome or delta naming another attempt than the caller's is refused
  without closing anything.
  """
  @spec call(String.t(), caller(), op()) :: term()
  def call(execution_id, caller, op) when is_binary(execution_id) and is_map(caller) do
    call(execution_id, {:call, caller, op})
  end

  @typedoc """
  Who holds an attempt: the worker service it was dispatched to (nil when
  the control plane holds it), that service's boot, and the runner that
  claimed it (nil to match any).
  """
  @type holder :: %{service_id: String.t() | nil, boot_id: String.t(), runner: String.t() | nil}

  @doc """
  What the attempt of `execution_id` was admitted with, for the runner
  that holds its claim to be handed it again: what its assignment is
  signed from (`t:Cyfr.Execution.Assignments.admitted/0`, the `:assignment`
  it was opened with) and the secrets its attach unsealed. `holder` must
  name the runner that attached on the service and boot the attempt was
  dispatched to, and the row must still be live under it
  (`Arca.ExecutionAttempts.live?/4`): a child that ended, or one another
  runner holds, is `{:error, :lost}`; a store that cannot answer is
  `{:error, :unavailable}`.
  """
  @spec admitted(String.t(), holder()) ::
          {:ok, %{assignment: Cyfr.Execution.Assignments.admitted(), secrets: map()}}
          | {:error, :lost | :unavailable}
  def admitted(execution_id, %{runner: runner} = holder)
      when is_binary(execution_id) and is_binary(runner) do
    call(execution_id, {:admitted, holder})
  end

  @doc """
  Stop the open attempt `attempt` held by `holder`, without closing its
  run: its runner exited, or its row lapsed. An attempt held by another
  service, boot or runner, or none open, is left alone.
  """
  @spec stop_unclosed(String.t(), holder()) :: :ok
  def stop_unclosed(attempt, %{boot_id: boot_id} = holder)
      when is_binary(attempt) and is_binary(boot_id) do
    for pid <- Registry.select(@registry, [{{:_, :"$1", attempt}, [], [:"$1"]}]) do
      try do
        GenServer.call(pid, {:stop_unclosed, attempt, holder}, :infinity)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  @doc """
  Count a kill of `execution_id` whose native work may still run against
  `tenant`'s execution slots (`Cyfr.Slots.note_unreaped/3`), and emit
  `[:cyfr, :opus, :execution, :unreaped_kill]` with the tenant's live
  count. From any process: a cancel runs in the canceller's, never the
  holder's, and the note is acknowledged before the kill it precedes. A
  nil tenant charges nobody; a kill the slots could not be told of is
  uncharged, and logged by execution.
  """
  @spec note_unreaped(String.t() | nil, String.t()) :: :ok
  def note_unreaped(nil, _execution_id), do: :ok

  def note_unreaped(tenant, execution_id) when is_binary(tenant) do
    case Slots.note_unreaped(@slots, tenant, execution_id) do
      {:ok, count} ->
        :telemetry.execute(
          [:cyfr, :opus, :execution, :unreaped_kill],
          %{system_time: System.system_time(), unreaped_count: count},
          %{tenant: tenant, execution_id: execution_id}
        )

      {:error, :unavailable} ->
        Logger.error(
          "[Cyfr.Execution.Attempt] unreaped kill of #{inspect(execution_id)} for tenant " <>
            "#{inspect(tenant)} is uncharged: the execution slots did not answer"
        )
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

    # Trapped, so a supervisor's stop runs `terminate/2` instead of cutting
    # off a reaction to the waiter partway.
    Process.flag(:trap_exit, true)

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
      root_execution_id: Keyword.get(opts, :root_execution_id, execution_id),
      declared_needs: Keyword.get(opts, :declared_needs, []),
      activation_digest: Keyword.get(opts, :activation_digest),
      roster: Keyword.get(opts, :roster, []),
      worker: Keyword.get(opts, :worker),
      service_id: Keyword.get(opts, :service_id),
      boot_id: Keyword.get(opts, :boot_id),
      deadline: Keyword.get(opts, :deadline),
      digest: Keyword.get(opts, :digest),
      charge: Keyword.get(opts, :charge),
      assignment: Keyword.get(opts, :assignment),
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

  # A row can end before its attempt is registered, where no `stop_ended/1`
  # finds it: a parent's cascade waits on the lock its child's admission
  # holds, and lands as that admission commits. So the row is read before
  # the wait as well as at the grant, and every row that ends later finds a
  # registered attempt to tell. A row that cannot be read here is read at
  # the grant.
  #
  # The call is answered when the slot holder reports (`handle_info/2`), or
  # by whatever stops the attempt first (`release_holds/1`).
  @impl true
  def handle_call({:take_slot, class, timeout}, from, %__MODULE__{slot: nil} = state) do
    if row_live(state) == false do
      {:stop, :normal, :closed, release_holds(state)}
    else
      holder = hold_slot(state.ctx.athanor_id, class, timeout)
      {:noreply, %{state | slot: {:waiting, holder, from}}}
    end
  end

  # A runner that attached was started: the answer its waiter lost, not the
  # start, and the run stays the runner's.
  def handle_call({:refuse, _sentence}, _from, %__MODULE__{claimed_by: runner} = state)
      when is_binary(runner),
      do: {:reply, :attached, state}

  def handle_call({:refuse, sentence}, _from, state), do: refuse_run(state, sentence)

  # A claimant's give-back closes the run whoever holds the claim.
  def handle_call({:release, sentence}, _from, state), do: refuse_run(state, sentence)

  # Only the waiter hands the attempt over, once a runner has attached, and
  # only to a worker service that can stop the run.
  def handle_call(:hand_over, {from, _tag}, %__MODULE__{waiter: from} = state)
      when is_binary(state.claimed_by) and is_map(state.worker) do
    case Registry.register(
           Cyfr.Execution.Registry,
           state.execution_id,
           {:dispatched, state.worker}
         ) do
      {:ok, _owner} ->
        Process.demonitor(state.owner, [:flush])
        {:reply, :ok, %{state | owner: nil, waiter: nil}}

      {:error, {:already_registered, _holder}} ->
        {:reply, {:error, :lost}, state}
    end
  end

  def handle_call(:hand_over, _from, state), do: {:reply, {:error, :lost}, state}

  def handle_call({:attach, _caller} = message, _from, state), do: owned(message, state)

  def handle_call({:call, _caller, _op} = message, _from, state), do: owned(message, state)

  def handle_call({:admitted, holder}, _from, state) do
    held? =
      is_map(state.assignment) and state.claimed_by == holder.runner and
        state.service_id == holder.service_id and state.boot_id == holder.boot_id

    with true <- held?,
         true <-
           Arca.ExecutionAttempts.live?(
             state.ctx.athanor_id,
             state.attempt,
             state.fence,
             holder.runner
           ) do
      {:reply, {:ok, %{assignment: state.assignment, secrets: state.secrets}}, state}
    else
      {:error, _reason} -> {:reply, {:error, :unavailable}, state}
      false -> {:reply, {:error, :lost}, state}
    end
  end

  def handle_call({:stop_unclosed, attempt, holder}, _from, state) do
    held? =
      state.attempt == attempt and state.service_id == holder.service_id and
        state.boot_id == holder.boot_id and
        (is_nil(holder.runner) or state.claimed_by == holder.runner)

    if held?,
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

  defp handle_owned({:call, caller, op}, state) do
    with :ok <- claimant(state, caller),
         {:ok, noted} <- fresh_nonce(state, caller) do
      case held(caller, op) do
        :ok -> run(op, noted)
        :ending -> {:reply, {:error, :lost}, noted}
        :gone -> {:stop, :normal, {:error, :lost}, release_holds(noted)}
        :unavailable -> {:reply, {:error, :unavailable}, noted}
      end
    else
      :lost -> {:reply, {:error, :lost}, state}
    end
  end

  # A runner that attached was started: its exit report stops the attempt.
  @impl true
  def handle_cast(:stop_ended, %__MODULE__{claimed_by: runner} = state) when is_binary(runner),
    do: {:noreply, state}

  def handle_cast(:stop_ended, state) do
    case row_live(state) do
      true ->
        {:noreply, state}

      false ->
        {:stop, :normal, release_holds(state)}

      :unavailable ->
        Logger.error(
          "[Cyfr.Execution.Attempt] #{state.execution_id} was told its row ended, and could " <>
            "not read it"
        )

        {:noreply, state}
    end
  end

  def handle_cast(message, state) do
    Logger.error(
      "[Cyfr.Execution.Attempt] #{state.execution_id} dropped an unknown cast " <>
        inspect(message_shape(message))
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{owner: ref} = state) do
    waiter_gone(state)
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

  def handle_info({:slot, holder, {:ok, _ref}}, %__MODULE__{slot: {:waiting, holder, _}} = state),
    do: granted(state)

  def handle_info(
        {:slot, holder, {:error, reason}},
        %__MODULE__{slot: {:waiting, holder, _}} = state
      ),
      do: refuse_slot(state, Slots.refusal(reason))

  # The holder reports before it ends, and the attempt ends it before it
  # stops, so an exit seen here is a holder that died of something else:
  # the slots took back whatever it had.
  def handle_info({:EXIT, holder, _reason}, %__MODULE__{slot: {:waiting, holder, _}} = state),
    do: refuse_slot(state, Slots.refusal(:unavailable))

  def handle_info({:EXIT, holder, reason}, %__MODULE__{slot: {:held, holder}} = state) do
    Logger.error(
      "[Cyfr.Execution.Attempt] #{state.execution_id}'s slot holder ended (" <>
        "#{inspect(reason_shape(reason))}): the run goes on without its execution slot"
    )

    {:noreply, %{state | slot: nil}}
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # Every stop but a normal one (after which nothing is held) finishes here:
  # a supervisor's shutdown can arrive before the waiter's exit is handled.
  @impl true
  def terminate(:normal, _state), do: :ok

  def terminate(_reason, state) do
    if is_pid(state.waiter) and not Process.alive?(state.waiter), do: waiter_gone(state)
    _ = release_holds(state)
    :ok
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

  # ---------------------------------------------------------------------------
  # Holds
  # ---------------------------------------------------------------------------

  # What the run held while open goes back when the attempt stops: its
  # execution slot or its place in the queue for one, its invoke-budget
  # slot and its charge row. The attempt stops right after, so each goes
  # back once.
  defp release_holds(state) do
    give_back_slot(state.slot)
    if state.held_invoke, do: Sanctum.Authority.release_invoke(state.authority)
    if state.charge, do: give_back_charge(state)
    %{state | slot: nil, held_invoke: false, charge: nil}
  end

  # The process that waits for the run's execution slot and then holds it
  # (the moduledoc's "The execution slot"). It is linked, so it ends with an
  # attempt that is killed, and it watches the attempt, so it ends with one
  # that stopped any other way; it reports once, before it holds or ends.
  defp hold_slot(key, class, timeout) do
    attempt = self()

    spawn_link(fn ->
      answer = Slots.acquire(@slots, key, class, wait_ms: timeout)
      send(attempt, {:slot, self(), answer})

      with {:ok, _ref} <- answer do
        watch = Process.monitor(attempt)

        receive do
          {:DOWN, ^watch, :process, ^attempt, _reason} -> :ok
        end
      end
    end)
  end

  # Ending the holder gives back whichever it had: `Cyfr.Slots` takes a dead
  # process out of its queue, and takes back the slot it held or was handed
  # meanwhile. A call still waiting for the slot is answered.
  defp give_back_slot(nil), do: :ok
  defp give_back_slot({:held, holder}), do: end_holder(holder)

  defp give_back_slot({:waiting, holder, from}) do
    end_holder(holder)
    GenServer.reply(from, :closed)
  end

  defp end_holder(holder) do
    Process.unlink(holder)
    Process.exit(holder, :kill)
    :ok
  end

  # A granted slot is kept only by a run that may still start: a boot that
  # lost the control plane starts nothing, and a row that ended while the
  # run was queued (a cancel, its parent's cascade, a lapse) is read here,
  # before `take_slot/3` is answered `:ok`.
  defp granted(%__MODULE__{slot: {:waiting, holder, from}} = state) do
    case Cyfr.ControlPlane.owner?() and row_live(state) do
      true ->
        GenServer.reply(from, :ok)
        {:noreply, %{state | slot: {:held, holder}}}

      false ->
        {:stop, :normal, release_holds(state)}

      :unavailable ->
        refuse_slot(state, "the execution could not be read before its start")
    end
  end

  # A run refused its slot was not started: it is closed failed, which
  # answers the `take_slot/3` call with what else the run held.
  defp refuse_slot(state, sentence) do
    {:stop, :normal, :closed, state} = refuse_run(state, sentence)
    {:stop, :normal, state}
  end

  # Whether the run is still this attempt's to start: its execution points
  # at this attempt, running at its fence. Every write that ends a run ends
  # its attempt row in the same transaction, so one read decides.
  defp row_live(state) do
    case Arca.ExecutionAttempts.current(state.ctx.athanor_id, state.execution_id) do
      %Arca.Schemas.ExecutionAttempt{attempt: attempt, fence: fence, state: "running"}
      when attempt == state.attempt and fence == state.fence ->
        true

      {:error, _reason} ->
        :unavailable

      _ended ->
        false
    end
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

  # A waiter that exited kills its run and lapses its row. The kill of a
  # runner that attached is counted before the attempt gives back its slot,
  # so the athanor's next acquisition sees it.
  defp waiter_gone(state) do
    kill_runner(state)
    lapse(state)
  end

  defp kill_runner(%__MODULE__{worker: nil}), do: :ok

  # A run still waiting for its slot was never started: it has no runner.
  defp kill_runner(%__MODULE__{slot: {:waiting, _holder, _from}}), do: :ok

  defp kill_runner(state) do
    killed = Cyfr.Execution.WorkerClient.kill(state.worker, state.execution_id)

    if killed == :ok and is_binary(state.claimed_by),
      do: note_unreaped(state.ctx.athanor_id, state.execution_id)

    :ok
  end

  # A run dispatched to no worker service has no runner whose attempt lapses.
  defp lapse(%__MODULE__{worker: nil}), do: :ok
  defp lapse(state), do: Lapse.dispatched(state.service_id, state.boot_id, nil, [state.attempt])

  # ---------------------------------------------------------------------------
  # Attach
  # ---------------------------------------------------------------------------

  # Credentials come only from the current edge's vault resource, projected
  # by the vault reader, while the consent is still the profile's head.
  # What is handed over is audited here, at the one attach that claims the
  # attempt: a repeat by the same runner answers the same fields from the
  # claim and audits nothing again.
  defp unseal(state, caller) do
    case fetch_secrets(state) do
      {:ok, secrets} ->
        StepSpans.guest_started(state.close.step_spans)
        audit_dispensed(state, caller.runner, secrets)
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

  # One audit entry per field handed to the claiming runner, by its name and
  # never its value, attributed from what this attempt was admitted with:
  # its athanor and person, execution, attempt, fence, component and
  # consent, with the runner that claimed it and the worker service it was
  # dispatched to.
  defp audit_dispensed(state, runner, secrets) do
    for field <- secrets |> Map.keys() |> Enum.sort() do
      :telemetry.execute(
        [:cyfr, :opus, :secret, :dispensed],
        %{system_time: System.system_time()},
        Map.put(audit_identity(state, runner), :field, field)
      )
    end

    :ok
  end

  defp audit_identity(state, runner) do
    %{
      athanor_id: state.ctx.athanor_id,
      user_id: state.ctx.user_id,
      execution_id: state.execution_id,
      attempt: state.attempt,
      fence: state.fence,
      component_ref: state.component_ref,
      consent_id: state.authority.consent_id,
      runner: runner,
      service: state.service_id
    }
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

  # The header names this attempt at this fence, on the worker service and
  # the boot the row was dispatched to: a delayed call from an earlier boot
  # of the same service is lost.
  defp names_attempt?(state, caller) do
    caller.execution_id == state.execution_id and caller.attempt == state.attempt and
      caller.fence == state.fence and caller.service == state.service_id and
      caller.boot == state.boot_id
  end

  defp fresh_nonce(state, %{nonce: nonce, ts: ts}) do
    now = System.system_time(:millisecond)
    nonces = Map.reject(state.nonces, fn {_nonce, seen} -> now - seen > @nonce_ttl_ms end)

    if Map.has_key?(nonces, nonce),
      do: :lost,
      else: {:ok, %{state | nonces: Map.put(nonces, nonce, max(ts, now))}}
  end

  # A call its guest's children and tools are decided under needs a live
  # row; one still held but ending (a cancel asked, its execution closed)
  # is refused without stopping the attempt, which its runner still closes.
  defp held(caller, :chain) do
    case Arca.ExecutionAttempts.live?(
           caller.athanor_id,
           caller.attempt,
           caller.fence,
           caller.runner
         ) do
      true -> :ok
      false -> with(:ok <- held(caller, nil), do: :ending)
      {:error, _reason} -> :unavailable
    end
  end

  defp held(caller, _op) do
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

  defp run(:chain, state) do
    chain = %{
      ctx: state.ctx,
      authority: state.authority,
      component_ref: state.component_ref,
      root_execution_id: state.root_execution_id,
      declared_needs: state.declared_needs,
      activation_digest: state.activation_digest,
      roster: state.roster,
      worker: state.worker,
      deadline: state.deadline
    }

    {:reply, {:ok, chain}, state}
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
      if outcome.abandoned, do: note_unreaped(state.ctx.athanor_id, state.execution_id)

      close_run(state, &failed_answer/1, fn ->
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

  defp run(op, state) when elem(op, 0) in [:storage, :fetch_artifact, :record_denial] do
    case Host.Storage.run(op, host_storage(state)) do
      {:error, :lost} -> {:stop, :normal, {:error, :lost}, release_holds(state)}
      reply -> {:reply, reply, state}
    end
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
    if is_pid(state.waiter), do: send(state.waiter, {__MODULE__, self(), result})
    {:stop, :normal, answer.(result), state}
  end

  defp completed_answer({:ok, %{output: output}}), do: {:ok, output}

  defp completed_answer({:error, message}) when is_binary(message),
    do: {:error, {:failed, message}}

  defp completed_answer({:error, _typed}), do: {:error, {:failed, "Execution failed"}}

  defp failed_answer({:error, message}) when is_binary(message), do: {:ok, message}
  defp failed_answer(_result), do: {:ok, "Execution failed"}

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

  defp host_storage(state) do
    %{
      ctx: state.ctx,
      admission_ctx: state.close.ctx,
      authority: state.authority,
      limits: state.limits,
      component_ref: state.component_ref,
      digest: state.digest,
      audit: audit_identity(state, state.claimed_by),
      hold: &while_held(state, &1)
    }
  end

  # The claim the call was checked against: this attempt, at its fence, held
  # by the runner that attached.
  defp while_held(state, write) do
    case Arca.ExecutionAttempts.while_held(
           state.ctx.athanor_id,
           state.attempt,
           state.fence,
           state.claimed_by,
           write
         ) do
      {:ok, result} -> {:ok, result}
      {:error, :lost} -> {:error, :lost}
      {:error, :database_error} -> {:error, :unavailable}
    end
  end

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
