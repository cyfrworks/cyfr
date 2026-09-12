# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner do
  @moduledoc """
  The process that owns a conversation's turns.

  One runner per conversation, started on demand under
  `Aqua.RunnerSupervisor` and found through `Aqua.RunnerRegistry`. A
  browser session never owns a turn: the runner admits a send, accepts
  it on the tape with the turn it opens, runs the loop in a worker of
  its own (`Aqua.Loop`, the process that holds the turn's root), and
  keeps what a viewer joining now needs — whether a turn runs, the tool
  activity, the usage, the standing grants. Every row is the tape's;
  every viewer reads the same topic.

  ## Admission

  A send is held to, in order: the text and its size; the sender's
  standing; the addressing (`Aqua.Runner.Admission`); then, for a turn,
  the estate being filled (`:not_provisioned`, nothing written), the
  engine being up (`:execution_unavailable`), and the queue having room
  (`:busy`). Only then is the message accepted, atomically with the
  turn — or attached to the running turn as a steer when its own sender
  writes again, or queued behind it. A `client_id` the conversation
  already accepted answers the same identity.

  ## Turns

  One turn runs at a time. The loop ends the turn itself on every
  outcome but a pause; a turn paused on a card waits for the decision —
  the tape tells the runner — and continues as the person who sent it
  (`Sanctum.Tenancy.continuation/2`), or ends uncertain when that person
  is no longer seated. A loop that dies without an answer is aborted
  from here (`Aqua.Loop.abort/3`) and its turn ended uncertain, or
  cancelled when a cancel asked for it. A runner that starts finds the
  conversation's open turns and does what their rows say
  (`Aqua.Runner.RecoveryTable`).

  ## Broadcasts — `{:conversation, conversation_id, event}`

  The rows from the tape (`{:message, row}`, `{:turn_finished}`,
  `{:approval_resolved, _}`), and from here `{:turn_starting, user_id}`,
  `{:turn_started, turn_id}`, `{:queued, n}`, `{:grants, set}`,
  `{:restart_prompt, text, user_id}`, `{:error, text}`; the loop
  announces `{:usage, _}`, `{:tool_activity, _}`, `{:intents, _, _}`
  and `{:consent_required, _, _}`.
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
  def start_link({conversation_id, athanor_id}) do
    GenServer.start_link(__MODULE__, {conversation_id, athanor_id}, name: via(conversation_id))
  end

  defp via(conversation_id), do: {:via, Registry, {@registry, conversation_id}}

  @doc "The runner for a conversation, started if it is not running."
  @spec ensure(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure(conversation_id, athanor_id)
      when is_binary(conversation_id) and is_binary(athanor_id) do
    case Registry.lookup(@registry, conversation_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               @supervisor,
               {__MODULE__, {conversation_id, athanor_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          :ignore -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The runner's pid when one is running."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(conversation_id) do
    case Registry.lookup(@registry, conversation_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Whether a turn is running in this conversation right now, for a viewer of its estate."
  @spec turn_running?(Context.t(), String.t()) :: boolean()
  def turn_running?(%Context{athanor_id: athanor_id}, conversation_id) do
    case whereis(conversation_id) do
      nil ->
        false

      pid ->
        answer = GenServer.call(pid, :state)
        answer.running == true and answer.athanor_id == athanor_id
    end
  catch
    :exit, _ -> false
  end

  @doc "The PubSub topic a thread's viewers subscribe to, tenant-prefixed."
  @spec topic(String.t(), String.t()) :: String.t()
  def topic(conversation_id, athanor_id),
    do: Cyfr.Topics.conversation(conversation_id, athanor_id)

  @doc "Subscribe the calling process to a conversation's broadcasts."
  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(conversation_id, athanor_id),
    do: Phoenix.PubSub.subscribe(Emissary.PubSub, topic(conversation_id, athanor_id))

  @doc "Undo `subscribe/2` for the calling process."
  @spec unsubscribe(String.t(), String.t()) :: :ok
  def unsubscribe(conversation_id, athanor_id),
    do: Phoenix.PubSub.unsubscribe(Emissary.PubSub, topic(conversation_id, athanor_id))

  @doc "Tell a thread's viewers about a row appended outside a turn (a line said aloud)."
  @spec announce(Arca.Schemas.Message.t()) :: :ok | {:error, term()}
  def announce(%{conversation_id: conversation_id, athanor_id: athanor_id} = row) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      topic(conversation_id, athanor_id),
      {:conversation, conversation_id, {:message, row}}
    )
  end

  # ---------------------------------------------------------------------------
  # API — every call carries the acting member's context
  # ---------------------------------------------------------------------------

  @doc "The live part of the thread for a viewer joining now."
  @spec state(String.t(), String.t()) :: map() | {:error, term()}
  def state(conversation_id, athanor_id) do
    with {:ok, pid} <- ensure(conversation_id, athanor_id), do: safe_call(pid, :state)
  end

  @doc """
  Send a message: accepted on the tape and shown to every member; a turn
  is opened when it addresses an agent. `opts`: `:id` (a pre-minted
  message id), `:client_id`, `:attachments` (refs), `:model`,
  `:orchestrator` (a pick; an `@name` in the text wins), `:room` (the
  room the sender had open, `%{"athanor_id", "conversation_id", ...}`),
  `:orchestrators` (the roster, read here when absent).
  """
  @spec send_message(Context.t(), String.t(), String.t(), keyword()) ::
          {:ok, send_result()} | {:error, term()}
  def send_message(%Context{} = ctx, conversation_id, text, opts \\ []) do
    with :ok <- Cyfr.ControlPlane.assert_owner() do
      opts = Keyword.put_new_lazy(opts, :orchestrators, fn -> Aqua.Roster.roster(ctx) end)
      call(ctx, conversation_id, {:send, ctx, text, opts})
    end
  end

  @doc "Stop the running or paused turn and drop what waited behind it."
  @spec stop_turn(Context.t(), String.t()) :: :ok | {:error, term()}
  def stop_turn(%Context{} = ctx, conversation_id), do: call(ctx, conversation_id, {:stop, ctx})

  @doc "Stop auto-approving `{tool, action}` for `agent` in this conversation."
  @spec revoke_grant(Context.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def revoke_grant(%Context{} = ctx, conversation_id, agent, tool, action)
      when is_binary(agent) and is_binary(tool) and is_binary(action),
      do: call(ctx, conversation_id, {:revoke_grant, ctx, agent, tool, action})

  @doc "A consent granted mid-turn applies to future roots: the turn is cut and the sender asked to re-send."
  @spec restart_for_consent(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def restart_for_consent(%Context{} = ctx, conversation_id, result) when is_map(result),
    do: call(ctx, conversation_id, {:restart_for_consent, ctx, result})

  @doc "Start a runner for every conversation holding an open turn."
  @spec recover_all() :: :ok
  def recover_all do
    Enum.each(Tape.with_open_turns(), fn {athanor_id, conversation_id} ->
      ensure(conversation_id, athanor_id)
    end)

    :ok
  rescue
    e ->
      Logger.warning("[Aqua.Runner] boot recovery skipped: #{Exception.message(e)}")
      :ok
  end

  defp call(%Context{} = ctx, conversation_id, request) do
    with {:ok, conv} <- Tape.conversation(ctx, conversation_id),
         :ok <- open?(conv.athanor_id),
         {:ok, pid} <- ensure(conv.id, conv.athanor_id) do
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

  @impl true
  def init({conversation_id, athanor_id}) do
    Process.flag(:trap_exit, true)

    ctx =
      Sanctum.internal_context(user_id: "_conversations", athanor_id: athanor_id, scope: :athanor)

    with {:ok, conv} <- Tape.conversation(ctx, conversation_id),
         {:ok, %{status: "active"}} <- Athanors.get(athanor_id) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(athanor_id))
      :ok = subscribe(conv.id, athanor_id)

      state =
        touch(%{
          id: conv.id,
          athanor_id: athanor_id,
          ctx: ctx,
          # The running loop: its turn, task, sender and agent.
          live: nil,
          # A turn paused on a card or around a launch, waiting here.
          paused: nil,
          # Turns accepted behind the running one, oldest first.
          queue: [],
          usage: %{input: 0, output: 0},
          tool_activity: [],
          grants: MapSet.new(),
          orchestrator: conv.orchestrator,
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

  def handle_call({:send, ctx, text, opts}, _from, state) do
    opts = Keyword.put(opts, :last, state.orchestrator)

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

  def handle_call({:stop, ctx}, _from, state) do
    case Admission.standing(ctx, state.athanor_id) do
      :ok -> {:reply, :ok, state |> clear_queue("stopped") |> cut("stopped", "cancelled")}
      refusal -> {:reply, refusal, state}
    end
  end

  def handle_call({:revoke_grant, ctx, agent, tool, action}, _from, state) do
    case Admission.standing(ctx, state.athanor_id) do
      :ok ->
        for scope <- Aqua.ToolGrants.scopes() do
          Aqua.ToolGrants.revoke(ctx, %{
            scope: scope,
            conversation_id: state.id,
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

  def handle_call({:restart_for_consent, ctx, _result}, _from, state) do
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

        state = state |> clear_queue("restart required") |> cut("restart required", "cancelled")
        if prompt, do: broadcast(state, {:restart_prompt, prompt, ctx.user_id})
        {:reply, :ok, state}

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
        steer(state, ctx, text, opts)

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
  defp steer?(%{live: %{user_id: user_id, orchestrator: name}}, %Context{user_id: user_id}, name),
    do: true

  defp steer?(
         %{live: nil, paused: %{user_id: user_id, orchestrator: name}},
         %Context{user_id: user_id},
         name
       ),
       do: true

  defp steer?(_state, _ctx, _name), do: false

  defp busy?(%{live: nil, paused: nil}), do: false
  defp busy?(_state), do: true

  defp steer(state, ctx, text, opts) do
    %{turn_id: turn_id} = state.live || state.paused

    case Tape.accept(ctx, state.id, %{message: message(ctx, text, opts), steer_turn_id: turn_id}) do
      {:ok, %{message: row, replayed: replayed}} ->
        {:reply, {:ok, result(row, turn_id, replayed, :steer)}, touch(acknowledge(state))}

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
    do: paused |> Map.take([:turn_id, :user_id, :orchestrator]) |> Map.put(:ctx, nil)

  defp accept_turn(state, ctx, name, text, opts) do
    attrs = %{
      message: message(ctx, text, opts),
      turn: %{
        orchestrator: name,
        requested_by: ctx.user_id,
        model: Keyword.get(opts, :model),
        options: options(name, opts)
      }
    }

    case Tape.accept(ctx, state.id, attrs) do
      {:ok, %{message: row, turn: turn, replayed: true}} ->
        {:reply, {:ok, result(row, turn && turn.id, true, :turn)}, touch(state)}

      {:ok, %{message: row, turn: turn}} ->
        entry = %{turn_id: turn.id, user_id: ctx.user_id, ctx: ctx, orchestrator: name}
        state = %{state | orchestrator: name}

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

  defp run(state, entry, fun) do
    task = Task.Supervisor.async_nolink(Aqua.TaskSupervisor, fun)

    state = %{
      state
      | live: Map.merge(entry, %{task: task}),
        paused: nil,
        usage: %{input: 0, output: 0},
        tool_activity: []
    }

    broadcast(state, {:turn_starting, entry.user_id})
    broadcast(state, {:turn_started, entry.turn_id})
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
  def handle_info({ref, result}, %{live: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, after_loop(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{live: %{task: %Task{ref: ref}}} = state) do
    {:noreply, crashed(state, reason)}
  end

  # A card decided: the paused turn continues once none is pending.
  def handle_info(
        {:conversation, _id, {:approval_resolved, %{turn_id: turn_id}}},
        %{paused: %{turn_id: turn_id}} = state
      ) do
    {:noreply, settle_paused(state)}
  end

  def handle_info({:conversation, _id, {:usage, usage}}, state),
    do: {:noreply, %{state | usage: usage}}

  def handle_info({:conversation, _id, {:tool_activity, list}}, state),
    do: {:noreply, %{state | tool_activity: list}}

  def handle_info({:conversation, _id, _event}, state), do: {:noreply, state}

  def handle_info({:expire, turn_id}, %{paused: %{turn_id: turn_id}} = state) do
    _ = Aqua.Approvals.expire_due(state.ctx)
    {:noreply, settle_paused(%{state | paused: %{state.paused | expiry: nil}})}
  end

  def handle_info({:expire, _turn_id}, state), do: {:noreply, state}

  def handle_info({:resume, turn_id}, %{paused: %{turn_id: turn_id}} = state),
    do: {:noreply, settle_paused(state)}

  def handle_info({:resume, _turn_id}, state), do: {:noreply, state}

  # The athanor changed: an archive ends the runner, its turns cut.
  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, state) do
    case Athanors.get(state.athanor_id) do
      {:ok, %{status: "archived"}} ->
        state =
          state
          |> clear_queue("the athanor was archived")
          |> cut("the athanor was archived", "cancelled")

        {:stop, :normal, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:notify, _athanor_id, _kind, _payload}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:idle, %{live: nil, paused: nil, queue: []} = state),
    do: {:stop, :normal, state}

  def handle_info(:idle, state), do: {:noreply, touch(state)}

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
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
              orchestrator: live.orchestrator,
              reason: reason,
              expiry: nil
            }
        }

        broadcast(state, {:turn_paused, live.turn_id, reason})
        settle_paused(state)

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
          orchestrator: live.orchestrator,
          reason: pause_reason(turn),
          expiry: nil
        }

        state = %{state | live: nil, paused: paused}
        broadcast(state, {:turn_paused, live.turn_id, paused.reason})
        settle_paused(state)

      _ ->
        status = if match?({:cancel_requested, _}, reason), do: "cancelled", else: "uncertain"

        %{state | live: nil}
        |> abort_turn(live.turn_id, describe(reason))
        |> end_turn(live.turn_id, status, describe(reason))
        |> start_next()
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

  # The running or paused turn is aborted from here — the fence renewed
  # and the steps settled before the loop is stopped — and ended.
  defp cut(%{live: nil, paused: nil} = state, _reason, _status), do: state

  defp cut(%{live: %{turn_id: turn_id, task: task}} = state, reason, status) do
    state = abort_turn(state, turn_id, reason)
    Task.shutdown(task, :brutal_kill)

    %{state | live: nil}
    |> end_turn(turn_id, status, reason)
  end

  defp cut(%{paused: %{turn_id: turn_id, expiry: expiry}} = state, reason, status) do
    if expiry, do: Process.cancel_timer(expiry)

    %{state | paused: nil}
    |> abort_turn(turn_id, reason)
    |> end_turn(turn_id, status, reason)
  end

  defp abort_turn(state, turn_id, reason) do
    with {:ok, turn} <- Tape.turn(state.ctx, turn_id) do
      _ = Aqua.Loop.abort(state.ctx, turn, reason)
    end

    state
  end

  defp end_turn(state, turn_id, status, error) do
    with {:ok, turn} <- Tape.turn(state.ctx, turn_id),
         false <- turn.status in ["completed", "failed", "cancelled", "uncertain"] do
      case Tape.finish(state.ctx, turn, status, %{error: error}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("[Aqua.Runner] turn #{turn_id} not ended: #{inspect(reason)}")
      end
    end

    touch(state)
  end

  defp clear_queue(%{queue: []} = state, _reason), do: state

  defp clear_queue(%{queue: queue} = state, reason) do
    state = Enum.reduce(queue, state, &end_turn(&2, &1.turn_id, "cancelled", reason))
    state = %{state | queue: []}
    broadcast(state, {:queued, 0})
    state
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
          orchestrator: turn.orchestrator
        }

        recovered_start(state, entry)

      {:wait, turn} ->
        paused = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          orchestrator: turn.orchestrator,
          reason: pause_reason(turn),
          expiry: nil
        }

        settle_paused(%{state | paused: paused})

      {:continue, turn} ->
        entry = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          ctx: nil,
          orchestrator: turn.orchestrator
        }

        if busy?(state),
          do: %{state | queue: state.queue ++ [entry]},
          else: continue(state, entry, :resume)

      {:adopt, turn} ->
        entry = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          ctx: nil,
          orchestrator: turn.orchestrator
        }

        if busy?(state),
          do: %{state | queue: state.queue ++ [entry]},
          else: continue(state, entry, :adopt)

      {:uncertain, turn, why} ->
        state |> abort_turn(turn.id, why) |> end_turn(turn.id, "uncertain", why)
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
      streaming_text: "",
      tool_activity: state.tool_activity,
      usage: state.usage,
      grants: state.grants,
      orchestrator:
        state.orchestrator && %{"name" => state.orchestrator, "title" => state.orchestrator},
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
