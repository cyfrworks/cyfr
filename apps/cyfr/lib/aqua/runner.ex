# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner do
  @moduledoc """
  The process that owns a thread's turns.

  One runner per thread, started on demand under
  `Aqua.RunnerSupervisor` and found through `Aqua.RunnerRegistry`. A
  browser session never owns a turn: the runner admits a send, accepts
  it on the tape with the turn it opens, runs the loop in a worker of
  its own (`Aqua.Loop`, the process that holds the turn's root, which
  dies with the runner — `Aqua.Loop.Worker`), and keeps what a viewer
  joining now needs — whether a turn runs, the tool activity, the usage,
  the standing grants. Every row is the tape's; every viewer reads the
  same topic.

  ## Admission

  A send is held to, in order: the text and its size; the sender's
  standing; the addressing (`Aqua.Runner.Admission`); then, for a turn,
  the estate being filled (`:not_provisioned`, nothing written), the
  engine being up (`:execution_unavailable`), and the queue having room
  (`:busy`). Only then is the message accepted, atomically with the
  turn — or attached to the running turn as a steer when its own sender
  writes again, or queued behind it. A `client_id` the thread
  already accepted answers the same identity.

  ## Turns

  One turn runs at a time. The loop ends the turn itself on every
  outcome but a pause; a turn paused on a card waits for the decision —
  the tape tells the runner — and continues as the person who sent it
  (`Sanctum.Tenancy.continuation/2`), or ends uncertain when that person
  is no longer seated. A loop that dies without an answer is aborted
  from here (`Aqua.Loop.abort/4`) and its turn ended uncertain, or
  cancelled when a cancel asked for it.

  ## Recovery

  A runner starts only on a member that holds its slot in the cell
  (`Arca.ControlPlane.held?/0`) — started on demand or restarted after a
  crash alike — and only for a thread the row says nobody else is
  running. Finding no local runner is not finding no runner: the thread
  row is read, and a thread whose claim belongs to a turn a live peer
  holds is that peer's, so no runner is started for it, nothing is
  recovered and no recovery is counted against it. Three members joining
  in turn used to end one healthy turn `uncertain` that way.

  A runner that does start finds the thread's open turns and does what
  their rows say (`Aqua.Runner.RecoveryTable`), taking a turn only from
  the fence it read it with and only through the thread claim, which is
  taken in the same transaction as the recovery count. A turn another
  process on this boot still holds (`Aqua.Loop.holder/1`) — the loop of a
  runner that just died, until its kill lands — is not taken: the runner
  waits for that process to end, holds the turns behind it, and recovers
  the turn then, while the member still holds its slot.

  `suspend` sets a turn down with every row kept, its runtime released
  and the thread's claim given up, so any member may pick it up;
  `recover` takes a suspended or abandoned turn back, under a new fence
  and against the recovery cap.

  Every loop result, notification and timer checks the slot again. If it
  is lost or has expired, the runner stops its loop and exits without
  changing the tape or advancing queued turns. A holding runner recovers
  the open work from its durable rows.

  ## Broadcasts — `{:thread, thread_id, event}`

  The rows from the tape (`{:message, row}`, `{:turn_finished}`,
  `{:approval_resolved, _}`), and from here `{:turn_starting, user_id}`,
  `{:turn_started, turn_id}`, `{:queued, n}`, `{:grants, set}`,
  `{:restart_prompt, text, user_id}`, `{:error, text}`; the loop
  announces `{:usage, _}`, `{:tool_activity, _}`, `{:intents, _, _}`,
  `{:consent_required, _, _}`, the running loop's
  `{:turn_fence, turn_id, fence}`, a chat step's streamed text as
  `{:delta, _}` and `{:delta_abandoned, marker}` (`Aqua.Loop.Stream`),
  which the runner keeps for the running turn's current fence until each
  step's answer lands or is withdrawn.
  """

  use GenServer, restart: :transient

  require Logger

  alias Aqua.Runner.{Admission, RecoveryTable}
  alias Aqua.Tape
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members}

  @registry Aqua.RunnerRegistry
  @supervisor Aqua.RunnerSupervisor
  # Turns waiting behind the running one; beyond it a sender is told `:busy`.
  @queue_max 8
  # A runner with nothing to do for this long stops; the next send starts it again.
  @idle_ms :timer.minutes(15)
  @resume_retry_ms 5_000

  @type send_result :: %{
          accepted: true,
          message_id: String.t(),
          seq: non_neg_integer(),
          turn_id: String.t() | nil,
          replayed: boolean(),
          admitted: :turn | :steer | :post
        }

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc false
  def start_link({thread_id, athanor_id}) do
    GenServer.start_link(__MODULE__, {thread_id, athanor_id}, name: via(thread_id))
  end

  defp via(thread_id), do: {:via, Registry, {@registry, thread_id}}

  @doc """
  The runner for a thread, started if it is not running. A member that
  holds no cell slot starts none (`{:error, :control_plane_lost}`), and
  neither does one whose thread row says a live peer is running a turn
  there (`{:error, :busy}`).
  """
  @spec ensure(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure(thread_id, athanor_id)
      when is_binary(thread_id) and is_binary(athanor_id) do
    case Registry.lookup(@registry, thread_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        with :ok <- held(),
             :ok <- not_a_peers(thread_id, athanor_id),
             do: start_runner(thread_id, athanor_id)
    end
  end

  # Does this member hold its slot in the cell? A term read and an integer
  # comparison (`Arca.ControlPlane.held?/0`), asked again on every entry,
  # every loop result and every timer.
  defp held, do: if(Arca.ControlPlane.held?(), do: :ok, else: {:error, :control_plane_lost})

  # The rule that makes a join harmless to a running turn. A member that
  # finds no local runner has found NOTHING: absence from a registry is
  # never evidence, and "the holder is not on my node" is never evidence
  # that there is no holder. It reads the thread row instead, and a thread
  # whose claim is held by a live peer's turn is that peer's: this member
  # starts no runner for it, so it recovers nothing, counts no recovery
  # against it and does not fence out a turn that is running perfectly
  # well. A thread the row says nobody holds is this member's to pick up.
  #
  # A store that cannot answer admits nothing: the claim is the authority
  # and an unread authority is not a free one.
  defp not_a_peers(thread_id, athanor_id) do
    case Tape.claim_holder(internal_context(athanor_id), thread_id) do
      {:ok, %{live_peer?: false}} -> :ok
      {:ok, %{live_peer?: true}} -> {:error, :busy}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp internal_context(athanor_id),
    do: Sanctum.internal_context(user_id: "_threads", athanor_id: athanor_id, scope: :athanor)

  # A runner that declines to start answers why: the plane was lost in
  # between, or the thread is not an active estate's.
  defp start_runner(thread_id, athanor_id) do
    case DynamicSupervisor.start_child(
           @supervisor,
           {__MODULE__, {thread_id, athanor_id}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      :ignore -> with :ok <- held(), do: {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The runner's pid when one is running."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(thread_id) do
    case Registry.lookup(@registry, thread_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Whether a turn is running in this thread right now, for a viewer of its
  estate.

  No local runner is not "no turn": the thread row is asked, and a claim
  a live peer's turn holds is a turn that is running, on another member.
  A caller that acts on this — `thread.delete` refusing under a running
  turn — must be told the truth wherever the turn is.
  """
  @spec turn_running?(Context.t(), String.t()) :: boolean()
  def turn_running?(%Context{athanor_id: athanor_id} = ctx, thread_id) do
    case whereis(thread_id) do
      nil ->
        match?({:ok, %{live_peer?: true}}, Tape.claim_holder(ctx, thread_id))

      pid ->
        answer = GenServer.call(pid, :state)
        answer.running == true and answer.athanor_id == athanor_id
    end
  catch
    :exit, _ -> false
  end

  @doc "The PubSub topic a thread's viewers subscribe to, tenant-prefixed."
  @spec topic(String.t(), String.t()) :: String.t()
  def topic(thread_id, athanor_id),
    do: Cyfr.Bus.thread(thread_id, athanor_id)

  @doc "Subscribe the calling process to a thread's broadcasts."
  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(thread_id, athanor_id),
    do: Phoenix.PubSub.subscribe(Emissary.PubSub, topic(thread_id, athanor_id))

  @doc "Undo `subscribe/2` for the calling process."
  @spec unsubscribe(String.t(), String.t()) :: :ok
  def unsubscribe(thread_id, athanor_id),
    do: Phoenix.PubSub.unsubscribe(Emissary.PubSub, topic(thread_id, athanor_id))

  @doc "Tell a thread's viewers about a row appended outside a turn (a line said aloud)."
  @spec announce(Arca.Schemas.Message.t()) :: :ok | {:error, term()}
  def announce(%{thread_id: thread_id, athanor_id: athanor_id} = row) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      topic(thread_id, athanor_id),
      {:thread, thread_id, {:message, row}}
    )
  end

  # ---------------------------------------------------------------------------
  # API — every call carries the acting member's context
  # ---------------------------------------------------------------------------

  @doc "The live part of the thread for a viewer joining now."
  @spec state(String.t(), String.t()) :: map() | {:error, term()}
  def state(thread_id, athanor_id) do
    with {:ok, pid} <- ensure(thread_id, athanor_id), do: safe_call(pid, :state)
  end

  @doc """
  Send a message: accepted on the tape and shown to every member; a turn
  is opened when it addresses an agent. `opts`: `:id` (a pre-minted
  message id), `:client_id`, `:attachments` (refs), `:model`,
  `:agent` (a pick; an `@name` in the text wins), `:room` (the
  room the sender had open, `%{"athanor_id", "thread_id", ...}`),
  `:agents` (the roster, read here when absent).
  """
  @spec send_message(Context.t(), String.t(), String.t(), keyword()) ::
          {:ok, send_result()} | {:error, term()}
  def send_message(%Context{} = ctx, thread_id, text, opts \\ []) do
    with :ok <- held() do
      opts = Keyword.put_new_lazy(opts, :agents, fn -> Aqua.Roster.roster(ctx) end)
      call(ctx, thread_id, {:send, ctx, text, opts})
    end
  end

  @doc "Cancel the current running, paused or held turn and the turns queued behind it."
  @spec stop_turn(Context.t(), String.t()) :: :ok | {:error, term()}
  def stop_turn(%Context{} = ctx, thread_id), do: call(ctx, thread_id, {:stop, ctx})

  @doc "Stop auto-approving `{tool, action}` for `agent` in this thread."
  @spec revoke_grant(Context.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def revoke_grant(%Context{} = ctx, thread_id, agent, tool, action)
      when is_binary(agent) and is_binary(tool) and is_binary(action),
      do: call(ctx, thread_id, {:revoke_grant, ctx, agent, tool, action})

  @doc "A consent granted mid-turn applies to future roots: the turn is cut and the sender asked to re-send."
  @spec restart_for_consent(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def restart_for_consent(%Context{} = ctx, thread_id, result) when is_map(result),
    do: call(ctx, thread_id, {:restart_for_consent, ctx, result})

  @doc """
  Set the thread's turn down: every row it has written kept, its runtime
  capacity released and the thread's claim given up, so any member may
  pick it up (`turn.suspend`). `opts`: `:turn` — the exact turn the
  caller read, so a caller never suspends its successor — and `:reason`,
  which is recorded on the turn and shown in the transcript.

  A thread with no runner here is not this member's to set down: a turn a
  live peer runs is `{:error, :busy}` and anything else is already down,
  `{:error, :not_running}`.
  """
  @spec suspend_turn(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def suspend_turn(%Context{} = ctx, thread_id, opts \\ []) do
    request = {:suspend, ctx, Keyword.get(opts, :turn), Keyword.get(opts, :reason)}

    with :ok <- held(),
         {:ok, thread} <- Tape.thread(ctx, thread_id),
         :ok <- open?(thread.athanor_id) do
      case whereis(thread_id) do
        nil -> nothing_to_suspend(ctx, thread_id)
        pid -> safe_call(pid, request)
      end
    end
  end

  defp nothing_to_suspend(ctx, thread_id) do
    case Tape.claim_holder(ctx, thread_id) do
      {:ok, %{live_peer?: true}} -> {:error, :busy}
      {:ok, _free_or_ours} -> {:error, :not_running}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Take a suspended or abandoned turn and carry it on (`turn.recover`):
  the turn is named, never "whatever is there now".

  What the rows call for is the recovery table's to say, and the take is
  the thread's claim — refused for a turn a live peer runs
  (`{:error, :busy}`) and for one still running here
  (`{:error, :not_suspended}`). The turn's pinned consent head and
  capability identity are read again first: a recovery asked for by hand
  is a fresh admission of old work. Past the recovery cap the turn ends
  `uncertain` and the call answers `{:error, :recovery_exhausted}`.
  """
  @spec recover_turn(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def recover_turn(%Context{} = ctx, thread_id, turn_id)
      when is_binary(thread_id) and is_binary(turn_id) do
    with :ok <- held(),
         {:ok, thread} <- Tape.thread(ctx, thread_id),
         :ok <- open?(thread.athanor_id),
         {:ok, turn} <- turn_of(ctx, thread, turn_id),
         :ok <- recoverable?(ctx, thread, turn),
         :ok <- RecoveryTable.pins_hold(ctx, turn) do
      case whereis(thread_id) do
        # No runner here yet: starting one IS the recovery. It reads the
        # thread's open turns and does what their rows say, taking each
        # only through its thread claim and counting each take there.
        nil ->
          with {:ok, _pid} <- ensure(thread_id, thread.athanor_id),
               do: recovered(ctx, turn_id)

        pid ->
          safe_call(pid, {:recover, ctx, turn_id})
      end
    end
  end

  # The named turn, and it has to be this thread's: a turn of another
  # thread — or of another tenant, which the scoped read already refused —
  # is absent, never denied, so an id cannot be probed for.
  defp turn_of(ctx, thread, turn_id) do
    case Tape.turn(ctx, turn_id) do
      {:ok, %{thread_id: id} = turn} when id == thread.id -> {:ok, turn}
      {:ok, _elsewhere} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # A turn that is over has nothing to carry on; one a live peer is
  # running is that peer's; one a process here still holds is running, and
  # running is not suspended.
  defp recoverable?(ctx, thread, turn) do
    cond do
      Tape.terminal?(turn) ->
        {:error, :not_open}

      Aqua.Loop.holder(turn.id) ->
        {:error, :not_suspended}

      match?({:ok, %{live_peer?: true}}, Tape.claim_holder(ctx, thread.id)) ->
        {:error, :busy}

      true ->
        :ok
    end
  end

  # What a freshly started runner made of the turn: the row, read again. A
  # turn it gave up on because the cap was spent is `uncertain` with the
  # cap's own count, which is the cap answering; `uncertain` for any other
  # reason is reported as the status it is.
  defp recovered(ctx, turn_id) do
    cap = Tape.recovery_cap()

    case Tape.turn(ctx, turn_id) do
      {:ok, %{status: "uncertain", recovery_attempts: spent}} when spent >= cap ->
        {:error, :recovery_exhausted}

      {:ok, turn} ->
        {:ok, report_row(turn)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp report_row(turn) do
    %{
      recovered: true,
      turn: turn.id,
      status: turn.status,
      running: Aqua.Loop.holder(turn.id) != nil
    }
  end

  @doc "Start a runner for every thread holding an open turn, while this boot owns the control plane."
  @spec recover_all() :: :ok
  def recover_all do
    if Arca.ControlPlane.held?() do
      Enum.each(Tape.with_open_turns(), fn {athanor_id, thread_id} ->
        ensure(thread_id, athanor_id)
      end)
    end

    :ok
  rescue
    e ->
      Logger.warning("[Aqua.Runner] boot recovery skipped: #{Exception.message(e)}")
      :ok
  end

  defp call(%Context{} = ctx, thread_id, request) do
    with {:ok, thread} <- Tape.thread(ctx, thread_id),
         :ok <- open?(thread.athanor_id),
         {:ok, pid} <- ensure(thread.id, thread.athanor_id) do
      safe_call(pid, request)
    end
  end

  defp safe_call(pid, request, timeout \\ 30_000) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp open?(athanor_id), do: if(Athanors.active?(athanor_id), do: :ok, else: {:error, :archived})

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  # A boot that does not own the control plane starts no runner, a restart
  # after a crash included: it recovers nothing, and the supervisor drops
  # the child rather than retrying it.
  @impl true
  def init({thread_id, athanor_id}) do
    Process.flag(:trap_exit, true)

    ctx = internal_context(athanor_id)

    with :ok <- held(),
         {:ok, thread} <- Tape.thread(ctx, thread_id),
         {:ok, %{status: "active"}} <- Athanors.get(athanor_id) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(athanor_id))
      :ok = subscribe(thread.id, athanor_id)

      state =
        touch(%{
          id: thread.id,
          athanor_id: athanor_id,
          ctx: ctx,
          # The running loop: its turn, task, sender and agent.
          live: nil,
          # A turn paused on a card or around a launch, waiting here.
          paused: nil,
          # Turns accepted behind the running one, oldest first.
          queue: [],
          # Open turns another process on this boot still holds: turn id =>
          # its holder and monitor, or nil while a recovery retries.
          held: %{},
          usage: %{input: 0, output: 0},
          tool_activity: [],
          # The running turn's streamed answers (`Aqua.Loop.Stream`).
          partials: Aqua.Loop.Stream.new(),
          grants: MapSet.new(),
          agent: thread.agent,
          idle_ref: nil
        })

      # What the rows hold is known before the first send is admitted; a
      # runner that cannot read them admits nothing.
      case recover(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, {:unavailable, reason}}
      end
    else
      _ -> :ignore
    end
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, public_state(state), state}

  def handle_call(request, from, state) do
    if Arca.ControlPlane.held?(),
      do: handle_owned_call(request, from, state),
      else: {:stop, :normal, {:error, :control_plane_lost}, retire_runtime(state)}
  end

  defp handle_owned_call({:send, ctx, text, opts}, _from, state) do
    opts = Keyword.put(opts, :last, state.agent)

    case Admission.check(ctx, state.athanor_id, text, opts) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, :post, text} ->
        case Tape.accept(ctx, state.id, %{message: message(ctx, text, opts)}) do
          {:ok, %{message: row, replayed: replayed}} ->
            {:reply, {:ok, result(row, nil, replayed, :post)}, touch(state)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:ok, {:turn, name}, text} ->
        admit_turn(state, ctx, name, text, opts)
    end
  end

  defp handle_owned_call({:stop, ctx}, _from, state) do
    case Admission.standing(ctx, state.athanor_id) do
      :ok ->
        case cancel_work(state, "stopped") do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:stop, :normal, {:error, reason}, retire_runtime(state)}
        end

      refusal ->
        {:reply, refusal, state}
    end
  end

  defp handle_owned_call({:revoke_grant, ctx, agent, tool, action}, _from, state) do
    case Admission.standing(ctx, state.athanor_id) do
      :ok ->
        for scope <- Aqua.ToolGrants.scopes() do
          Aqua.ToolGrants.revoke(ctx, %{
            scope: scope,
            thread_id: state.id,
            agent_name: agent,
            tool: tool,
            action: action
          })
        end

        {:reply, :ok, refresh_grants(state, ctx)}

      refusal ->
        {:reply, refusal, state}
    end
  end

  defp handle_owned_call({:suspend, ctx, turn_id, reason}, _from, state) do
    case Admission.standing(ctx, state.athanor_id) do
      :ok ->
        case target_turn(state, turn_id) do
          nil -> {:reply, {:error, :not_running}, state}
          id -> suspend_work(state, id, reason)
        end

      refusal ->
        {:reply, refusal, state}
    end
  end

  defp handle_owned_call({:recover, ctx, turn_id}, _from, state) do
    case Admission.standing(ctx, state.athanor_id) do
      :ok -> recover_named(state, turn_id)
      refusal -> {:reply, refusal, state}
    end
  end

  defp handle_owned_call({:restart_for_consent, ctx, _result}, _from, state) do
    case Admission.standing(ctx, state.athanor_id) do
      :ok ->
        prompt =
          with %{turn_id: turn_id} <- state.live || state.paused,
               {:ok, turn} <- Tape.turn(state.ctx, turn_id),
               {:ok, row} <- Tape.message(state.ctx, turn.message_id) do
            row.content
          else
            _ -> nil
          end

        case cancel_work(state, "restart required") do
          {:ok, state} ->
            if prompt, do: broadcast(state, {:restart_prompt, prompt, ctx.user_id})
            {:reply, :ok, state}

          {:error, reason, state} ->
            {:stop, :normal, {:error, reason}, retire_runtime(state)}
        end

      refusal ->
        {:reply, refusal, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Admitting a turn
  # ---------------------------------------------------------------------------

  defp admit_turn(state, ctx, name, text, opts) do
    cond do
      opened_before?(state, ctx, opts) ->
        accept_turn(state, ctx, name, text, opts)

      steer?(state, ctx, name) ->
        steer(state, ctx, name, text, opts)

      Sanctum.Provisioning.ready(ctx) != :ok ->
        {:reply, {:error, :not_provisioned}, state}

      not Cyfr.Execution.available?() ->
        {:reply, {:error, :execution_unavailable}, state}

      busy?(state) and length(state.queue) >= @queue_max ->
        {:reply, {:error, :busy}, state}

      true ->
        accept_turn(state, ctx, name, text, opts)
    end
  end

  # A `client_id` that already opened a turn is offered as that turn's
  # opener again, never as a steer of it or a turn behind it: the tape
  # answers the identity it accepted, while the turn runs or after.
  defp opened_before?(state, ctx, opts) do
    case Keyword.get(opts, :client_id) do
      client_id when is_binary(client_id) ->
        match?(
          {:ok, %{message: %{id: id}, turn: %{message_id: id}}},
          Tape.accepted(ctx, state.id, client_id)
        )

      _ ->
        false
    end
  end

  # The turn's own sender writing again to the same agent steers it —
  # while it runs, or while it is paused (the row waits on the tape and
  # is drained on resume). A line to another agent, or from another
  # member, is a turn of its own.
  defp steer?(%{live: %{user_id: user_id, agent: name}}, %Context{user_id: user_id}, name),
    do: true

  defp steer?(
         %{live: nil, paused: %{user_id: user_id, agent: name}},
         %Context{user_id: user_id},
         name
       ),
       do: true

  defp steer?(_state, _ctx, _name), do: false

  defp busy?(%{live: nil, paused: nil, held: held}) when map_size(held) == 0, do: false
  defp busy?(_state), do: true

  defp steer(state, ctx, name, text, opts) do
    %{turn_id: turn_id} = state.live || state.paused

    case Tape.accept(ctx, state.id, %{message: message(ctx, text, opts), steer_turn_id: turn_id}) do
      {:ok, %{message: row, replayed: replayed}} ->
        {:reply, {:ok, result(row, turn_id, replayed, :steer)}, touch(acknowledge(state))}

      # The turn ended before its end reached this process: the line opens
      # the next turn, queued behind the end.
      {:error, :turn_over} ->
        accept_turn(state, ctx, name, text, opts)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # A turn stopped on a call whose outcome is unknown continues on its
  # sender's next line — the one past the boundary the stop moved; a
  # replayed earlier line is not that.
  defp acknowledge(%{live: nil, paused: %{reason: :uncertain, turn_id: turn_id} = paused} = state) do
    case Tape.turn(state.ctx, turn_id) do
      {:ok, %{status: "paused"} = turn} ->
        if Tape.steer_pending?(state.ctx, turn),
          do: continue(%{state | paused: nil}, entry_of(paused), :resume),
          else: state

      _ ->
        state
    end
  end

  defp acknowledge(state), do: state

  defp entry_of(paused),
    do: paused |> Map.take([:turn_id, :user_id, :agent]) |> Map.put(:ctx, nil)

  defp accept_turn(state, ctx, name, text, opts) do
    attrs = %{
      message: message(ctx, text, opts),
      turn: %{
        agent: name,
        requested_by: ctx.user_id,
        model: Keyword.get(opts, :model),
        options: options(name, opts)
      }
    }

    case Tape.accept(ctx, state.id, attrs) do
      {:ok, %{message: row, turn: turn, replayed: true}} ->
        {:reply, {:ok, result(row, turn && turn.id, true, :turn)}, touch(state)}

      {:ok, %{message: row, turn: turn}} ->
        entry = %{turn_id: turn.id, user_id: ctx.user_id, ctx: ctx, agent: name}
        state = %{state | agent: name}

        state =
          if busy?(state) do
            state = %{state | queue: state.queue ++ [entry]}
            broadcast(state, {:queued, length(state.queue)})
            state
          else
            start(state, entry)
          end

        {:reply, {:ok, result(row, turn.id, false, :turn)}, touch(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp message(ctx, text, opts) do
    %{
      author: ctx.user_id,
      content: text,
      id: Keyword.get(opts, :id),
      client_id: Keyword.get(opts, :client_id),
      payload:
        case Keyword.get(opts, :attachments, []) do
          [] -> nil
          refs -> %{"attachments" => refs}
        end
    }
  end

  defp options(name, opts) do
    %{"agent" => name, "room" => Keyword.get(opts, :room)}
    |> Aqua.AgentConfig.stringify_deep()
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp result(row, turn_id, replayed?, admitted) do
    %{
      accepted: true,
      message_id: row.id,
      seq: row.seq,
      turn_id: turn_id,
      replayed: replayed?,
      admitted: admitted
    }
  end

  # ---------------------------------------------------------------------------
  # Running the loop
  # ---------------------------------------------------------------------------

  defp start(state, %{turn_id: turn_id, ctx: ctx} = entry) do
    run(state, entry, fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn_id) end)
  end

  defp continue(state, %{turn_id: turn_id} = entry, mode) do
    case Sanctum.Tenancy.continuation(entry.user_id, state.athanor_id) do
      {:ok, actor} ->
        run(state, %{entry | ctx: actor}, fn ->
          Aqua.Loop.run_nested(ctx: actor, turn_id: turn_id, mode: mode)
        end)

      {:error, reason} ->
        state
        |> end_turn(turn_id, "uncertain", "the sender is no longer seated here (#{reason})")
        |> start_next()
    end
  end

  # Viewers hear the turn start before the loop can announce anything of it.
  # The loop is a worker of this process: it, and every worker under it,
  # is killed when the runner ends.
  defp run(state, entry, fun) do
    broadcast(state, {:turn_starting, entry.user_id})
    broadcast(state, {:turn_started, entry.turn_id})
    task = Aqua.Loop.Worker.async(fun)

    state = %{
      state
      | live: Map.merge(entry, %{task: task}),
        paused: nil,
        usage: %{input: 0, output: 0},
        tool_activity: [],
        partials: Aqua.Loop.Stream.new()
    }

    touch(state)
  end

  defp start_next(%{queue: []} = state), do: touch(state)

  defp start_next(%{queue: [entry | rest]} = state) do
    state = %{state | queue: rest}
    broadcast(state, {:queued, length(rest)})

    cond do
      not Members.member?(entry.user_id, state.athanor_id) ->
        state
        |> end_turn(entry.turn_id, "cancelled", "the sender is no longer a member")
        |> start_next()

      # Queued from its row by a recovery: it runs as its sender's continuation.
      is_nil(entry.ctx) ->
        recovered_start(state, entry)

      true ->
        start(state, entry)
    end
  end

  # ---------------------------------------------------------------------------
  # What the loop answers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(message, state) do
    if Arca.ControlPlane.held?() do
      handle_owned_info(message, state)
    else
      # Stop local work without aborting or settling its durable turn. The
      # owning boot recovers those rows; process exit retires subscriptions,
      # held monitors and timers addressed to this runner.
      {:stop, :normal, retire_runtime(state)}
    end
  end

  defp handle_owned_info(
         {ref, result},
         %{live: %{task: %Aqua.Loop.Worker.Handle{ref: ref}}} = state
       ) do
    Process.demonitor(ref, [:flush])

    case Aqua.Loop.Worker.stop(state.live.task.pid) do
      :ok -> {:noreply, after_loop(state, result)}
      {:error, _} -> {:stop, :normal, retire_runtime(state)}
    end
  end

  defp handle_owned_info(
         {:DOWN, ref, :process, _pid, reason},
         %{live: %{task: %Aqua.Loop.Worker.Handle{ref: ref}}} = state
       ) do
    case Aqua.Loop.Worker.stop(state.live.task.pid) do
      :ok -> crashed(state, reason)
      {:error, _} -> {:stop, :normal, retire_runtime(state)}
    end
  end

  # The process that held a turn is gone: the turn is recovered now.
  defp handle_owned_info({:DOWN, ref, :process, _pid, _reason} = msg, state) do
    case Enum.find(state.held, fn {_turn_id, held} -> match?(%{ref: ^ref}, held) end) do
      {turn_id, %{pid: holder}} ->
        case Aqua.Loop.Worker.stop(holder) do
          :ok -> {:noreply, recover_held(state, turn_id)}
          {:error, _} -> {:stop, :normal, retire_runtime(state)}
        end

      nil ->
        Cyfr.UnexpectedMessage.log(__MODULE__, msg)
        {:noreply, state}
    end
  end

  # A card decided: the paused turn continues once none is pending.
  defp handle_owned_info(
         {:thread, _id, {:approval_resolved, %{turn_id: turn_id}}},
         %{paused: %{turn_id: turn_id}} = state
       ) do
    {:noreply, settle_paused(state)}
  end

  defp handle_owned_info({:thread, _id, {:usage, usage}}, state),
    do: {:noreply, %{state | usage: usage}}

  defp handle_owned_info({:thread, _id, {:tool_activity, list}}, state),
    do: {:noreply, %{state | tool_activity: list}}

  defp handle_owned_info(
         {:thread, _id, {:turn_fence, turn_id, fence}},
         %{live: %{turn_id: turn_id}} = state
       ),
       do: {:noreply, %{state | partials: Aqua.Loop.Stream.advance(state.partials, fence)}}

  defp handle_owned_info(
         {:thread, _id, {:delta_abandoned, %{turn_id: turn_id} = marker}},
         %{live: %{turn_id: turn_id}} = state
       ),
       do: {:noreply, %{state | partials: Aqua.Loop.Stream.abandoned(state.partials, marker)}}

  defp handle_owned_info(
         {:thread, _id, {:delta, %{turn_id: turn_id} = delta}},
         %{live: %{turn_id: turn_id}} = state
       ),
       do: {:noreply, %{state | partials: Aqua.Loop.Stream.add(state.partials, delta)}}

  defp handle_owned_info({:thread, _id, {:message, row}}, state),
    do: {:noreply, %{state | partials: Aqua.Loop.Stream.landed(state.partials, row)}}

  defp handle_owned_info({:thread, _id, _event}, state), do: {:noreply, state}

  defp handle_owned_info({:expire, turn_id}, %{paused: %{turn_id: turn_id}} = state) do
    Aqua.Approvals.expire_due(state.ctx)
    {:noreply, settle_paused(%{state | paused: %{state.paused | expiry: nil}})}
  end

  defp handle_owned_info({:expire, _turn_id}, state), do: {:noreply, state}

  defp handle_owned_info({:resume, turn_id}, %{paused: %{turn_id: turn_id}} = state),
    do: {:noreply, settle_paused(state)}

  defp handle_owned_info({:resume, _turn_id}, state), do: {:noreply, state}

  defp handle_owned_info({:recover, turn_id}, %{held: held} = state)
       when is_map_key(held, turn_id) and :erlang.map_get(turn_id, held) == nil,
       do: {:noreply, recover_held(state, turn_id)}

  defp handle_owned_info({:recover, _turn_id}, state), do: {:noreply, state}

  # The athanor changed: an archive ends the runner, its turns cut.
  defp handle_owned_info({:notify, _athanor_id, :athanor_changed, _payload}, state) do
    case Athanors.get(state.athanor_id) do
      {:ok, %{status: "archived"}} ->
        case cancel_work(state, "the athanor was archived") do
          {:ok, state} -> {:stop, :normal, state}
          {:error, _reason, state} -> {:stop, :normal, retire_runtime(state)}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp handle_owned_info({:notify, _athanor_id, _kind, _payload}, state), do: {:noreply, state}
  defp handle_owned_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp handle_owned_info(:idle, %{live: nil, paused: nil, queue: [], held: held} = state)
       when map_size(held) == 0,
       do: {:stop, :normal, state}

  defp handle_owned_info(:idle, state), do: {:noreply, touch(state)}

  defp handle_owned_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  defp retry_timer(timer, state) do
    Process.send_after(self(), timer, @resume_retry_ms)
    state
  end

  defp after_loop(%{live: live} = state, result) do
    state = %{state | live: nil}

    case result do
      {:paused, reason} ->
        state = %{
          state
          | paused: %{
              turn_id: live.turn_id,
              user_id: live.user_id,
              agent: live.agent,
              reason: reason,
              expiry: nil
            }
        }

        broadcast(state, {:turn_paused, live.turn_id, reason})
        settle_paused(state)

      {:error, :held} ->
        hold_back(state, live.turn_id)

      {:error, reason} ->
        Logger.warning("[Aqua.Runner] turn #{live.turn_id} did not run: #{inspect(reason)}")
        state |> end_turn(live.turn_id, "failed", describe(reason)) |> start_next()

      _ended ->
        start_next(state)
    end
  end

  # The loop died without answering. A turn the rows already show paused
  # committed its stop before the process went: it is picked up as
  # paused and its local cleanup finished here. Otherwise what it left
  # is settled from the rows, the turn ended cancelled when a cancel
  # asked for it and uncertain otherwise. The root's slot went with the
  # process.
  defp crashed(%{live: live} = state, reason) do
    Logger.warning(
      "[Aqua.Runner] turn #{live.turn_id} stopped without an answer: #{inspect(reason)}"
    )

    case Tape.turn(state.ctx, live.turn_id) do
      {:ok, %{status: "paused"} = turn} ->
        paused = %{
          turn_id: live.turn_id,
          user_id: live.user_id,
          agent: live.agent,
          reason: pause_reason(turn),
          expiry: nil
        }

        state = %{state | live: nil, paused: paused}
        broadcast(state, {:turn_paused, live.turn_id, paused.reason})
        {:noreply, settle_paused(state)}

      _ ->
        status = if match?({:cancel_requested, _}, reason), do: "cancelled", else: "uncertain"

        case cancel_turn(state, live.turn_id, describe(reason), status) do
          :ok -> {:noreply, state |> retire_turn(live.turn_id) |> start_next()}
          {:error, _reason} -> {:stop, :normal, retire_runtime(state)}
        end
    end
  end

  # A paused turn: with cards still pending the runner waits for the
  # decision (and the expiry); stopped on a call whose outcome is unknown
  # it waits for its sender's next line, unless one is already on the
  # tape past the stop; with neither it continues as its sender.
  defp settle_paused(%{paused: %{turn_id: turn_id} = paused} = state) do
    case Tape.turn(state.ctx, turn_id) do
      {:ok, %{status: "paused", paused_reason: "uncertain"} = turn} ->
        if Tape.steer_pending?(state.ctx, turn),
          do: continue(%{state | paused: nil}, entry_of(paused), :resume),
          else: touch(state)

      {:ok, %{status: "paused"} = turn} ->
        case Tape.pending_approvals(state.ctx, turn) do
          {:ok, [_ | _] = pending} ->
            arm_expiry(state, pending)

          _ ->
            continue(%{state | paused: nil}, entry_of(paused), :resume)
        end

      {:ok, %{status: "running"}} ->
        # The loop is still taking the root back around its launch.
        Process.send_after(self(), {:resume, turn_id}, @resume_retry_ms)
        state

      _ ->
        # Ended meanwhile (a failed pin, a stop): nothing to continue.
        start_next(%{state | paused: nil})
    end
  end

  defp arm_expiry(%{paused: paused} = state, pending) do
    if paused.expiry, do: Process.cancel_timer(paused.expiry)

    soonest =
      pending
      |> Enum.map(& &1.expires_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> nil end)

    ref =
      if soonest do
        delay = max(DateTime.diff(soonest, DateTime.utc_now(), :millisecond), 0)
        Process.send_after(self(), {:expire, paused.turn_id}, delay)
      end

    touch(%{state | paused: %{paused | expiry: ref}})
  end

  # ---------------------------------------------------------------------------
  # Cutting turns short
  # ---------------------------------------------------------------------------

  # The target set belongs to this handler invocation. Retire each local
  # entry only after its durable cancellation succeeds; a later send is
  # processed after this call and opens new work.
  defp cancel_work(state, reason) do
    targets =
      Enum.uniq(
        Enum.flat_map([state.live, state.paused], fn
          nil -> []
          entry -> [entry.turn_id]
        end) ++ Map.keys(state.held) ++ Enum.map(state.queue, & &1.turn_id)
      )

    Enum.reduce_while(targets, {:ok, state}, fn id, {:ok, state} ->
      case cancel_turn(state, id, reason, "cancelled") do
        :ok -> {:cont, {:ok, retire_turn(state, id)}}
        {:error, error} -> {:halt, {:error, error, state}}
      end
    end)
  end

  defp cancel_turn(state, id, reason, status) do
    with :ok <- held(),
         {:ok, turn} <- Tape.turn(state.ctx, id) do
      if Tape.terminal?(turn) do
        Aqua.Loop.Worker.stop(local_holder(state, id) || Aqua.Loop.holder(id))
      else
        with {:ok, aborted} <-
               Aqua.Loop.abort(state.ctx, turn, reason, fn ->
                 Aqua.Loop.Worker.stop(local_holder(state, id))
               end),
             :ok <- held(),
             {:ok, _} <- Tape.finish(state.ctx, aborted, status, %{error: reason}) do
          :ok
        else
          {:error, :not_open} -> terminal_target(state, id)
          error -> error
        end
      end
    end
  end

  # A concurrent ordinary completion is already settled. A fence loss is
  # never handled here and never followed by a write under a reread fence.
  defp terminal_target(state, id) do
    case Tape.turn(state.ctx, id) do
      {:ok, turn} ->
        if Tape.terminal?(turn), do: :ok, else: {:error, :not_open}

      error ->
        error
    end
  end

  defp local_holder(%{live: %{turn_id: id, task: task}}, id), do: task.pid
  defp local_holder(state, id), do: get_in(state.held, [id, :pid])

  # ---------------------------------------------------------------------------
  # Setting a turn down, and picking one up
  # ---------------------------------------------------------------------------

  # Which turn a suspend names: the one the caller read, when this runner
  # is working it, and otherwise the one it is working now. A caller that
  # read a turn never sets its successor down by accident.
  defp target_turn(state, nil),
    do: (state.live || state.paused) && (state.live || state.paused).turn_id

  defp target_turn(state, id) do
    known =
      Enum.flat_map([state.live, state.paused], fn
        nil -> []
        entry -> [entry.turn_id]
      end) ++ Map.keys(state.held) ++ Enum.map(state.queue, & &1.turn_id)

    if id in known, do: id, else: nil
  end

  # The turn is taken from its holder first — the fence raised, the loop
  # and every worker under it stopped, its children cancelled and its
  # steps settled — so nothing it had in flight lands afterwards. Only
  # then is it set down durably, with the thread's claim released. Every
  # row written along the way stays: this ends no turn.
  defp suspend_work(state, id, reason) do
    text = reason || "the turn was suspended"

    with :ok <- held(),
         {:ok, turn} <- Tape.turn(state.ctx, id),
         false <- Tape.terminal?(turn),
         {:ok, aborted} <-
           Aqua.Loop.abort(state.ctx, turn, text, fn ->
             Aqua.Loop.Worker.stop(local_holder(state, id))
           end),
         {:ok, suspended} <- Tape.suspend(state.ctx, aborted, reason) do
      state = state |> retire_turn(id) |> start_next()

      {:reply, {:ok, %{suspended: true, turn: suspended.id, reason: reason}}, state}
    else
      true -> {:reply, {:error, :not_open}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # A turn this runner already holds was recovered by the runner's own
  # start, which reads the same rows and takes the same claim: the call is
  # answered with what that made of it, and no second recovery is spent.
  # A turn it does not hold is taken now — the claim and the count in one
  # transaction — and carried out by the action its rows call for.
  defp recover_named(state, turn_id) do
    if target_turn(state, turn_id) do
      {:reply, {:ok, report(state, turn_id)}, state}
    else
      case Tape.turn(state.ctx, turn_id) do
        {:ok, turn} -> recover_unheld(state, turn)
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  defp recover_unheld(state, turn) do
    if Tape.terminal?(turn) do
      {:reply, {:error, :not_open}, state}
    else
      case Tape.recover(state.ctx, turn) do
        {:ok, recovered} ->
          state =
            RecoveryTable.claimed(state.ctx, recovered)
            |> List.wrap()
            |> Enum.reduce(state, &recover_one/2)

          {:reply, {:ok, report(state, turn.id)}, touch(state)}

        {:error, :recovery_exhausted} ->
          state = give_up(state, turn, "the turn was interrupted too many times")
          {:reply, {:error, :recovery_exhausted}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  defp report(state, turn_id) do
    case Tape.turn(state.ctx, turn_id) do
      {:ok, turn} -> report_row(turn)
      _ -> %{recovered: true, turn: turn_id, status: nil, running: false}
    end
  end

  defp retire_turn(state, id) do
    if match?(%{turn_id: ^id}, state.live), do: Process.demonitor(state.live.task.ref, [:flush])

    if match?(%{turn_id: ^id}, state.paused) and state.paused.expiry,
      do: Process.cancel_timer(state.paused.expiry)

    if held = state.held[id], do: Process.demonitor(held.ref, [:flush])

    state = %{
      state
      | live: if(match?(%{turn_id: ^id}, state.live), do: nil, else: state.live),
        paused: if(match?(%{turn_id: ^id}, state.paused), do: nil, else: state.paused),
        held: Map.delete(state.held, id),
        queue: Enum.reject(state.queue, &(&1.turn_id == id))
    }

    broadcast(state, {:queued, length(state.queue)})
    touch(state)
  end

  defp retire_runtime(state) do
    if state.live, do: Aqua.Loop.Worker.stop(state.live.task.pid)
    state
  end

  defp end_turn(state, turn_id, status, error) do
    with {:ok, turn} <- Tape.turn(state.ctx, turn_id),
         false <- Tape.terminal?(turn) do
      case Tape.finish(state.ctx, turn, status, %{error: error}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("[Aqua.Runner] turn #{turn_id} not ended: #{inspect(reason)}")
      end
    end

    touch(state)
  end

  # ---------------------------------------------------------------------------
  # Recovery
  # ---------------------------------------------------------------------------

  defp recover(state) do
    with {:ok, actions} <- RecoveryTable.plan(state.ctx, state.id) do
      {:ok, Enum.reduce(actions, state, &recover_one/2)}
    end
  end

  defp recover_one(action, state) do
    case action do
      {:queue, turn} ->
        entry = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          ctx: nil,
          agent: turn.agent
        }

        recovered_start(state, entry)

      {:wait, turn} ->
        paused = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          agent: turn.agent,
          reason: pause_reason(turn),
          expiry: nil
        }

        settle_paused(%{state | paused: paused})

      {:continue, turn} ->
        entry = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          ctx: nil,
          agent: turn.agent
        }

        if busy?(state),
          do: %{state | queue: state.queue ++ [entry]},
          else: continue(state, entry, :resume)

      {:adopt, turn} ->
        entry = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          ctx: nil,
          agent: turn.agent
        }

        if busy?(state),
          do: %{state | queue: state.queue ++ [entry]},
          else: continue(state, entry, :adopt)

      {:held, turn, holder} ->
        %{
          state
          | held: Map.put(state.held, turn.id, %{pid: holder, ref: Process.monitor(holder)})
        }

      {:uncertain, turn, why} ->
        give_up(state, turn, why)
    end
  end

  # A turn recovery cannot continue is aborted from the fence it was read
  # with and ended under the fence the abort raised. A fence that moved in
  # between belongs to whoever moved it, and the turn is left to them.
  defp give_up(state, turn, why) do
    with {:ok, aborted} <- Aqua.Loop.abort(state.ctx, turn, why),
         {:ok, _ended} <- Tape.finish(state.ctx, aborted, "uncertain", %{error: why}) do
      touch(state)
    else
      {:error, reason} ->
        Logger.warning("[Aqua.Runner] turn #{turn.id} not ended: #{inspect(reason)}")
        touch(state)
    end
  end

  # A loop refused a turn another process on this boot holds: the turn
  # waits for that holder like one found at start.
  defp hold_back(state, turn_id) do
    case Aqua.Loop.holder(turn_id) do
      nil ->
        recover_held(%{state | held: Map.put(state.held, turn_id, nil)}, turn_id)

      holder ->
        %{
          state
          | held: Map.put(state.held, turn_id, %{pid: holder, ref: Process.monitor(holder)})
        }
    end
  end

  # A held turn whose holder is gone, planned again from its row. When the
  # rows cannot be read, retry later and keep the turns behind it waiting.
  defp recover_held(state, turn_id) do
    state = %{state | held: Map.put(state.held, turn_id, nil)}

    case RecoveryTable.plan_turn(state.ctx, state.id, turn_id) do
      {:ok, actions} ->
        state = %{state | held: Map.delete(state.held, turn_id)}
        state = Enum.reduce(actions, state, &recover_one/2)
        if busy?(state), do: touch(state), else: start_next(state)

      _unreadable ->
        retry_timer({:recover, turn_id}, state)
    end
  end

  defp pause_reason(%{paused_reason: "launch"}), do: :launch
  defp pause_reason(%{paused_reason: "uncertain"}), do: :uncertain
  defp pause_reason(_turn), do: :approval

  # A queued turn recovered from its row runs as its sender's continuation.
  defp recovered_start(state, entry) do
    if busy?(state) do
      %{state | queue: state.queue ++ [entry]}
    else
      case Sanctum.Tenancy.continuation(entry.user_id, state.athanor_id) do
        {:ok, actor} ->
          start(state, %{entry | ctx: actor})

        {:error, reason} ->
          end_turn(
            state,
            entry.turn_id,
            "cancelled",
            "the sender is no longer seated here (#{reason})"
          )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp public_state(state) do
    current = state.live || state.paused

    %{
      running: state.live != nil,
      paused: state.paused != nil,
      paused_reason: state.paused && state.paused.reason,
      athanor_id: state.athanor_id,
      turn_id: current && current.turn_id,
      partials: if(state.live, do: state.partials, else: Aqua.Loop.Stream.new()),
      tool_activity: state.tool_activity,
      usage: state.usage,
      grants: state.grants,
      agent: state.agent && %{"name" => state.agent, "title" => state.agent},
      turn_user: current && current.user_id,
      queued: length(state.queue),
      solo_human: Members.solo?(state.athanor_id)
    }
  end

  defp refresh_grants(state, ctx) do
    case Aqua.ToolGrants.allowed_by_agent(ctx, state.id) do
      {:ok, grants} ->
        state = %{state | grants: grants}
        broadcast(state, {:grants, grants})
        state

      {:error, _} ->
        state
    end
  end

  defp broadcast(state, event), do: Tape.announce(state.ctx, state.id, event)

  defp touch(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)
    %{state | idle_ref: Process.send_after(self(), :idle, @idle_ms)}
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: Aqua.Ops.render_refusal(reason)
end
