# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ConversationRunner do
  @moduledoc """
  The process that owns a conversation's turn.

  One runner per conversation, started on demand under
  `Aqua.ConversationSupervisor` and found through
  `Aqua.ConversationRegistry`. A browser session never owns a turn: the
  runner starts the AQUA execution, follows its events, writes the rows
  (`Arca.ConversationStorage`) and broadcasts what changed on `topic/1`, so
  every member watching the thread sees the same stream, a closed tab
  changes nothing, and a second member can decide an approval the first
  one left pending.

  Members are interchangeable: any member's context may send the next
  message, stop the turn or decide an approval — attribution (`author`,
  `resolved_by`) records who did. The turn itself runs as the person who
  sent the message (their consented authority, their attribution on the
  execution).

  ## Who is being spoken to

  Every message is persisted and shown to every member as soon as it is
  sent — people talk to each other in the thread. Whether it also starts
  an AQUA turn is *addressing*, and it is derived rather than configured:
  an estate with exactly one human addresses its agent with every message,
  because there is nobody else the message could be for; any other estate
  needs a mention, every time. There is no follow-up rule — a sticky agent
  would leave you unable to speak to the people in the room without
  starting a turn.

  Nothing is dropped by that. A turn's task is every human message since
  the last turn, the ones that did not address AQUA included, so the agent
  hears the whole exchange and a bare follow-up reaches it on the next
  mention. Lines are prefixed with the speaker's name when several people
  are present. One turn runs at a time; a message that addresses AQUA
  while one runs is queued (bounded) and starts when it completes.

  ## Broadcasts — `{:conversation, conversation_id, event}`

  - `{:message, %Arca.Schemas.Message{}}` — a row appended
  - `{:message_updated, %Arca.Schemas.Message{}}` — an approval decided,
    a streamed reply finalised
  - `{:turn_starting, user_id}` / `{:turn_started, execution_id}` /
    `{:turn_finished}`; `{:queued, n}` — the number of turns waiting
  - `{:delta, chunk}`, `{:tool_activity, list}`, `{:usage, %{input, output}}`
  - `{:grants, MapSet}` — the "for this conversation" auto-approvals
  - `{:intents, intents, user_id}` — client intents (navigate, copy) for
    the sender's browser
  - `{:consent_required, component_ref, user_id}` — the sender must grant
  - `{:restart_prompt, text, user_id}` — the turn was cut for a consent
    delta; the sender re-sends
  - `{:error, text}` — a turn that could not start

  A runner idles out after `@idle_ms` without a turn; state that matters
  is in the rows, so a fresh runner picks up where the last one stopped.
  A turn that was running when the server stopped is re-followed on the
  next start (`recover_all/0`) or, if it finished meanwhile, closed off.

  The turn itself — resolving the addressed agent, pinning the profile,
  composing the formula input, starting the execution — is
  `Aqua.Turn.begin/5`, run in a task off the runner's loop; the engine
  half it calls into is read from `:cyfr, :aqua_turn` when a runner
  starts so a suite can stand in a fake. The agent addressed travels as an
  `Aqua.Orchestrator`: a name and its owner from the pick, the resolved
  detail once the task has read the tree.
  """

  use GenServer, restart: :transient

  require Logger

  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.Orchestrator
  alias Aqua.Turn, as: AquaTurn
  alias Sanctum.Context
  alias Sanctum.Tenancy.Athanors

  @recover_attempts 15
  # Turns waiting behind the running one; beyond it a sender is told `:busy`.
  @queue_max 8
  # One human line, in BYTES — the SSOT for message size, sitting under the
  # task window (`Aqua.Runner.Addressing`). The wire schema carries an
  # advisory `maxLength` too, but that counts graphemes and the LiveView
  # never passes through it; this check is what actually governs, for
  # every sender.
  @max_message_bytes 32 * 1024

  @type scope :: :once | :conversation | :always

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc false
  def start_link({conversation_id, athanor_id}) do
    GenServer.start_link(__MODULE__, {conversation_id, athanor_id}, name: via(conversation_id))
  end

  defp via(conversation_id), do: {:via, Registry, {Aqua.ConversationRegistry, conversation_id}}

  @doc "The runner for a conversation, started if it is not running."
  @spec ensure(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure(conversation_id, athanor_id)
      when is_binary(conversation_id) and is_binary(athanor_id) do
    # The Registry is keyed by conversation_id ALONE — the athanor_id here
    # seeds init for a fresh runner, it does not scope the lookup. Tenant
    # proof is the caller's: every public entry goes through a
    # tenant-keyed `Conversations.get` first (`call/3`), and
    # `turn_running?/2` re-checks the athanor on the answer.
    case Registry.lookup(Aqua.ConversationRegistry, conversation_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Aqua.ConversationSupervisor,
               {__MODULE__, {conversation_id, athanor_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          # `init/1` found no such conversation or athanor.
          :ignore -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The runner's pid when one is running."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(conversation_id) do
    case Registry.lookup(Aqua.ConversationRegistry, conversation_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Whether a turn is running in this conversation right now — asked of the
  runner itself, so a viewer looking at another thread gets the truth about
  this one. No runner means no turn. The caller's context scopes the
  answer: another athanor's conversation reads as not running, never as an
  existence oracle.
  """
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
  @spec subscribe(String.t(), String.t()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(conversation_id, athanor_id) do
    Phoenix.PubSub.subscribe(Emissary.PubSub, topic(conversation_id, athanor_id))
  end

  @doc "Undo `subscribe/2` for the calling process — a pane turning to another thread."
  @spec unsubscribe(String.t(), String.t()) :: :ok
  def unsubscribe(conversation_id, athanor_id) do
    Phoenix.PubSub.unsubscribe(Emissary.PubSub, topic(conversation_id, athanor_id))
  end

  @doc """
  Tell a thread's viewers about a row appended outside the runner — a line
  said aloud onto it (`Aqua.Aloud`). The runner reads the thread's rows by
  sequence when a turn starts, so the row is already the thread's; this is
  the fan-out the runner's own appends get.
  """
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

  @doc """
  The live part of the thread for a viewer joining now: whether a turn is
  running, the text streamed so far, tool activity, token usage, the
  conversation grants and the orchestrator in use.
  """
  @spec state(String.t(), String.t()) :: map() | {:error, term()}
  def state(conversation_id, athanor_id) do
    with {:ok, pid} <- ensure(conversation_id, athanor_id) do
      safe_call(pid, :state)
    end
  end

  @doc """
  Send a message: the row is appended and shown to every member; if it
  addresses AQUA a turn starts — or waits its turn behind the running one.

  `opts`: `:id` (a pre-minted message id — the sender wrote its
  attachments under it first), `:attachments` (their refs), `:model`,
  `:orchestrator` (a name; an `@name` mention in the text wins),
  `:context` (text the turn reads beside the task — a room read into the
  person's own thread by `Aqua.RoomExcerpt`; it rides that one turn's
  prompt and is never a row, never history).
  `{:error, :busy}` when the queue is full (nothing is written);
  `{:error, :context_too_long}` when the context is past the message cap;
  `{:error, :no_orchestrator}` when the athanor has none;
  `{:error, :not_member}` when the sender no longer belongs here;
  `{:error, :archived}` when the athanor has been archived.
  """
  @spec send_message(Context.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def send_message(%Context{} = ctx, conversation_id, text, opts \\ []) do
    # The orchestrator roster is an MCP call — resolved here, in the
    # caller, never inside the runner's handle_call, where one slow
    # resolve would block every member's sends.
    #
    # It belongs to THIS SENDER and is used for THIS message only. It used
    # to seed a 60-second cache on the runner that every subsequent
    # sender's mentions were then parsed against — so for up to a minute
    # after Alice spoke, Bob's `@tom` resolved against Alice's roster.
    # Harmless while every member shares one estate-wide roster; a
    # cross-wiring the moment agents belong to people.
    with :ok <- Cyfr.ControlPlane.assert_owner() do
      opts = Keyword.put_new_lazy(opts, :orchestrators, fn -> AquaTurn.roster(ctx) end)
      call(ctx, conversation_id, {:send, ctx, text, opts})
    end
  end

  @doc "Stop the running turn; the partial reply is kept as a cancelled message."
  @spec stop_turn(Context.t(), String.t()) :: :ok | {:error, term()}
  def stop_turn(%Context{} = ctx, conversation_id) do
    call(ctx, conversation_id, {:stop, ctx})
  end

  @doc "Approve a pending approval; `scope` is `:once | :conversation | :always`."
  @spec approve(Context.t(), String.t(), String.t(), scope()) :: :ok | {:error, term()}
  def approve(%Context{} = ctx, conversation_id, message_id, scope \\ :once)
      when scope in [:once, :conversation, :always] do
    call(ctx, conversation_id, {:approve, ctx, message_id, scope})
  end

  @doc "Decline a pending approval; `scope: :never` also drops the action from the allowlist."
  @spec decline(Context.t(), String.t(), String.t(), String.t(), :once | :never) ::
          :ok | {:error, term()}
  def decline(%Context{} = ctx, conversation_id, message_id, reason \\ "", scope \\ :once)
      when scope in [:once, :never] do
    call(ctx, conversation_id, {:decline, ctx, message_id, reason, scope})
  end

  @doc "Stop auto-approving `{tool, action}` for the rest of this conversation."
  @spec revoke_grant(Context.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def revoke_grant(%Context{} = ctx, conversation_id, agent, tool, action)
      when is_binary(agent) and is_binary(tool) and is_binary(action) do
    call(ctx, conversation_id, {:revoke_grant, ctx, agent, tool, action})
  end

  @doc """
  A consent granted mid-turn applies to future roots: the running turn is
  cut carrying `restart_required` and the sender is asked to re-send.
  """
  @spec restart_for_consent(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def restart_for_consent(%Context{} = ctx, conversation_id, result) when is_map(result) do
    call(ctx, conversation_id, {:restart_for_consent, ctx, result})
  end

  # The conversation must be the caller's athanor's, and that athanor must
  # still be open — both checked before a runner is even started for it, so
  # a closed furnace answers with what it is rather than "not found".
  defp call(%Context{} = ctx, conversation_id, request) do
    with {:ok, conv} <- Conversations.get(ctx, conversation_id),
         :ok <- open?(conv.athanor_id),
         {:ok, pid} <- ensure(conv.id, conv.athanor_id) do
      safe_call(pid, request)
    end
  end

  # A busy or just-died runner answers a refusal, never an exit that takes
  # the calling LiveView down with it.
  defp safe_call(pid, request, timeout \\ 30_000) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp open?(athanor_id) do
    if Athanors.active?(athanor_id), do: :ok, else: {:error, :archived}
  end

  # ---------------------------------------------------------------------------
  # Boot recovery
  # ---------------------------------------------------------------------------

  @doc """
  Start a runner for every conversation that was mid-turn when the server
  last stopped. Called once at boot; each runner re-follows or closes off
  its own turn.
  """
  @spec recover_all() :: :ok
  def recover_all do
    Conversations.with_running_turn()
    |> Enum.each(fn conv -> ensure(conv.id, conv.athanor_id) end)

    :ok
  rescue
    e ->
      Logger.warning("[Aqua.ConversationRunner] boot recovery skipped: #{Exception.message(e)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init({conversation_id, athanor_id}) do
    # Trapping exits so a supervisor shutdown mid-turn reaches terminate/2.
    Process.flag(:trap_exit, true)
    ctx = Aqua.Runner.Shared.system_ctx(athanor_id)

    # An archived athanor is a hard stop for a new runner too, not only for a
    # send into a live one: a tab left open on a chat whose furnace closed
    # would otherwise start one on its next click.
    with {:ok, conv} <- Conversations.get(ctx, conversation_id),
         {:ok, %{status: "active"}} <- Athanors.get(athanor_id) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(athanor_id))

      state = %{
        id: conv.id,
        athanor_id: athanor_id,
        system_ctx: ctx,
        turn: Application.get_env(:cyfr, :aqua_turn, AquaTurn),
        # The context of the member whose turn is running.
        turn_ctx: nil,
        running: false,
        execution_id: nil,
        # Set while a turn is starting: the async start has not yet
        # returned an execution id.
        starting: nil,
        # Highest event sequence applied this turn. Events reach the runner
        # twice — live via PubSub and replayed from the buffer (the
        # subscribe-gap catch-up) — and this gate keeps each applied once.
        last_event_seq: -1,
        cancel_requested: false,
        streaming_text: "",
        tool_activity: [],
        usage: %{input: 0, output: 0},
        grants: MapSet.new(),
        orchestrator: nil,
        # The profile the running turn pinned. An approval decided during
        # the turn roots THIS profile rather than re-selecting one; a
        # recovered turn reads it back off its execution row.
        profile_id: nil,
        tool_policy: %{},
        history: Conversations.history(conv),
        # System notes (approval outcomes) written while a turn runs — merged
        # into the history the turn hands back, so they are not lost to it.
        notes_in_flight: [],
        # The task text of the running turn, for the cancel synthesis.
        last_task: nil,
        # `seq` of the last human row a turn took up.
        turn_seq: conv.turn_seq || 0,
        # Turns waiting behind the running one.
        queue: [],
        # Display names of members, cached for the group prefix. Safe to
        # cache: a name is the same whoever is asking, unlike a roster.
        names: %{},
        idle_ref: nil
      }

      # The row remembers WHICH agent ran (name and owner), so the
      # recovered turn resolves the same one from the same tree.
      if conv.execution_id do
        send(
          self(),
          {:recover, conv.execution_id, Orchestrator.from_conversation(conv), @recover_attempts}
        )
      end

      {:ok, Aqua.Runner.Shared.touch(state)}
    else
      # No conversation, no athanor, or a furnace that has closed: no runner.
      {:ok, %{status: _archived}} -> :ignore
      {:error, _} -> :ignore
    end
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, Aqua.Runner.Shared.public_state(state), Aqua.Runner.Shared.touch(state)}
  end

  def handle_call({:send, ctx, text, opts}, _from, state) do
    text = String.trim(text || "")
    attachments = Keyword.get(opts, :attachments, [])

    cond do
      text == "" and attachments == [] ->
        {:reply, {:error, :empty}, state}

      byte_size(text) > @max_message_bytes ->
        # Nothing is written; the sender keeps the draft. Rows, the PubSub
        # fan-out to every viewer, and the stored history all ride on this
        # bound once a sender can be a machine.
        {:reply, {:error, :message_too_long}, state}

      byte_size(Keyword.get(opts, :context) || "") > @max_message_bytes ->
        # The same bound as the message: the room read is prompt bytes too.
        {:reply, {:error, :context_too_long}, state}

      (refusal = Aqua.Runner.Shared.standing(ctx, state)) != :ok ->
        {:reply, refusal, state}

      true ->
        case Aqua.Runner.Addressing.addressing(state, ctx, text, opts) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          # The queue is full: nothing is written, the sender keeps the draft.
          {:turn, _orch} when state.running and length(state.queue) >= @queue_max ->
            {:reply, {:error, :busy}, state}

          decision ->
            case Aqua.Runner.Addressing.persist_message(state, ctx, text, opts) do
              {:ok, row} ->
                state = Aqua.Runner.Shared.broadcast(state, {:message, row})

                {:reply, :ok,
                 Aqua.Runner.Addressing.after_persist(state, ctx, row, decision, opts)}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
        end
    end
  end

  # Stop ends the running turn and drops what was waiting behind it — a
  # member who says stop means the conversation, not one reply.
  def handle_call({:stop, ctx}, _from, state) do
    case Aqua.Runner.Shared.standing(ctx, state) do
      :ok -> Aqua.Runner.Addressing.do_stop(state, ctx)
      refusal -> {:reply, refusal, state}
    end
  end

  def handle_call({:approve, ctx, message_id, scope}, _from, state) do
    # Deciding a card runs a tool and can write the athanor's shared
    # allowlist: the same standing a send is held to, asked again here rather
    # than trusted from the mount that opened the socket.
    with :ok <- Aqua.Runner.Shared.standing(ctx, state),
         {:ok, peek} <- Conversations.get_message(ctx, message_id),
         # get_message is tenant-scoped, not conversation-scoped: without
         # this pin a member could drive conversation A's runner to settle
         # conversation B's card — the outcome note, the broadcast topic and
         # the tray attribution would all name the wrong conversation.
         :ok <- Aqua.Runner.Shared.same_conversation(peek, state.id),
         :ok <- Aqua.Runner.Approvals.scope_permitted(peek, scope),
         {:ok, msg} <-
           Conversations.resolve_approval(ctx, message_id, "pending", "running", %{
             resolution: %{"scope" => scope}
           }) do
      {:reply, :ok, Aqua.Runner.Approvals.run_approval(state, ctx, msg, scope)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:decline, ctx, message_id, reason, scope}, _from, state) do
    # The card's maxlength=80 is advice to the browser; the reason enters
    # the next turn's prompt, so the bound is enforced here too.
    reason = String.slice(reason || "", 0, 80)

    with :ok <- Aqua.Runner.Shared.standing(ctx, state),
         {:ok, msg} <- Conversations.get_message(ctx, message_id),
         # Same conversation pin as approve — see the comment there.
         :ok <- Aqua.Runner.Shared.same_conversation(msg, state.id),
         intent = Aqua.Runner.Approvals.approval_intent(msg),
         {summary, system_text} =
           AquaTurn.outcome_summary(:declined, %{reason: reason}, intent["title"] || ""),
         {:ok, msg} <-
           Conversations.resolve_approval(ctx, message_id, "pending", "declined", %{
             resolution: %{"reason" => reason, "summary" => summary, "scope" => scope}
           }) do
      state =
        if scope == :never, do: Aqua.Runner.Approvals.deny_standing(state, ctx, msg), else: state

      Aqua.Runner.Approvals.approval_telemetry(state, ctx, msg, :declined, scope, reason)
      Aqua.Runner.Approvals.notify_resolved(state, msg)

      state =
        state
        |> Aqua.Runner.Approvals.append_history(system_text)
        |> Aqua.Runner.Shared.broadcast({:message_updated, msg})

      {:reply, :ok, Aqua.Runner.Shared.touch(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:revoke_grant, ctx, agent, tool, action}, _from, state) do
    case Aqua.Runner.Shared.standing(ctx, state) do
      :ok ->
        # Withdraw the row, not just this process's copy of it — a grant
        # that survives a restart has to be revocable the same way, and
        # for the agent it was answered for, which the chat names.
        for scope <- Arca.Schemas.ToolGrant.scopes() do
          Aqua.ToolGrants.revoke(ctx, %{
            scope: scope,
            conversation_id: state.id,
            agent_name: agent,
            tool: tool,
            action: action
          })
        end

        {:reply, :ok, Aqua.Runner.Approvals.refresh_grants(state, ctx, agent)}

      refusal ->
        {:reply, refusal, state}
    end
  end

  def handle_call({:restart_for_consent, ctx, result}, _from, state) do
    with :ok <- Aqua.Runner.Shared.standing(ctx, state) do
      handle_restart_for_consent(ctx, result, state)
    else
      refusal -> {:reply, refusal, state}
    end
  end

  defp handle_restart_for_consent(ctx, result, state) do
    if state.running and state.execution_id do
      payload = %{
        profile_id: Map.get(result, :profile_id),
        new_revision: Map.get(result, :revision),
        missing: %{chain: [], edge: nil, activation: nil}
      }

      exec_id = state.execution_id
      turn = state.turn
      turn.unsubscribe(exec_id, state.turn_ctx || ctx)

      # A refused spawn is logged by start_task; the sweeper reaps the
      # execution the cancel would have stopped.
      _ =
        Aqua.Runner.Addressing.start_task(fn ->
          turn.cancel_for_restart(ctx, exec_id, payload)
        end)

      # The sender is asked to re-send; a queued turn firing now would send
      # for them.
      state =
        state
        |> Aqua.Runner.Addressing.clear_queue()
        |> Aqua.Runner.Stream.finish_turn()
        |> Aqua.Runner.Shared.broadcast({:restart_prompt, state.last_task, ctx.user_id})

      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Turn events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:turn_start_result, ref, result}, %{starting: ref} = state) do
    state = %{state | starting: nil}

    case result do
      {:ok, %{execution_id: eid} = started} ->
        state = %{
          state
          | execution_id: eid,
            tool_policy: started.tool_policy,
            orchestrator: started.orchestrator,
            profile_id: started.profile_id,
            grants: started.grants
        }

        Conversations.update(state.system_ctx, state.id, %{execution_id: eid})

        if state.cancel_requested do
          {:noreply, Aqua.Runner.Stream.cancel_turn(state, state.turn_ctx)}
        else
          state.turn.subscribe(eid, state.turn_ctx)

          # The execution was live before this result arrived — a fast
          # failure's terminal event broadcast before the subscribe above
          # and would never be delivered. Replay the buffer through the
          # same sequence gate live events pass: nothing missed, nothing
          # applied twice.
          state =
            state.turn.events_since(eid, state.athanor_id)
            |> Enum.reduce(
              Aqua.Runner.Shared.broadcast(state, {:turn_started, eid}),
              &Aqua.Runner.Stream.apply_sequenced_event(&2, &1)
            )

          {:noreply, state}
        end

      # The catalyst refusal gets its own sentence: "this estate has no
      # such model" is actionable, where the generic render of the tuple
      # is not. Deliberately fail-closed — see `Aqua.Turn.build_input/4`.
      {:error, {:catalyst_not_in_estate, ref}} ->
        {:noreply,
         Aqua.Runner.Stream.fail_turn(
           state,
           "The agent's model#{Aqua.Runner.Stream.ref_note(ref)} is not installed in this estate — " <>
             "install its catalyst here, or address another agent."
         )}

      {:error, {:unsupported_model_catalyst, ref}} ->
        {:noreply,
         Aqua.Runner.Stream.fail_turn(
           state,
           "The agent's model#{Aqua.Runner.Stream.ref_note(ref)} is not a model catalyst this " <>
             "assistant can speak to (#{Enum.join(Aqua.ModelCatalyst.names(), ", ")}) — pin one " <>
             "of those, or address another agent."
         )}

      {:error, reason} ->
        safe = Aqua.MCPHelpers.render_refusal(reason)

        {:noreply, Aqua.Runner.Stream.fail_turn(state, "Execution failed to start: #{safe}")}
    end
  end

  # A start result for a turn that is no longer the current one.
  def handle_info({:turn_start_result, _ref, _result}, state), do: {:noreply, state}

  # The deadline armed at turn start: firing while `starting` is still this
  # ref means the start task died without reporting — end the turn rather
  # than hold `running` forever. A result that already arrived cleared
  # `starting`, so a stale deadline matches the clause below and is dropped.
  def handle_info({:turn_start_timeout, ref}, %{starting: ref} = state) do
    {:noreply,
     Aqua.Runner.Stream.fail_turn(
       %{state | starting: nil},
       "The turn did not start. Send the message again."
     )}
  end

  def handle_info({:turn_start_timeout, _ref}, state), do: {:noreply, state}

  # An event only speaks for the turn it came from. `unsubscribe` happens
  # when a turn ends, but a message already in flight arrives after it —
  # and after the next turn has started — so an unmatched event would fold
  # a finished execution's text, tool activity or completion into the turn
  # that replaced it.
  def handle_info({:execution_event, %{execution_id: id} = event}, state)
      when is_binary(id) do
    if id == state.execution_id do
      {:noreply, Aqua.Runner.Stream.apply_sequenced_event(state, event)}
    else
      {:noreply, state}
    end
  end

  # An event that names no execution cannot be attributed to a turn, and
  # applying it to whichever turn happens to be current reintroduces
  # exactly the contamination the guarded clause above exists to prevent —
  # a stray `complete` would end a turn it never belonged to. Dropped.
  def handle_info({:execution_event, event}, state) do
    Logger.debug(
      "[Aqua.ConversationRunner] dropping execution event with no execution_id: " <>
        inspect(event[:type] || event["type"])
    )

    {:noreply, state}
  end

  def handle_info({:approval_result, message_id, ctx, outcome, payload}, state) do
    {:noreply, Aqua.Runner.Approvals.complete_approval(state, ctx, message_id, outcome, payload)}
  end

  def handle_info({:recover, execution_id, stored, attempts}, state) do
    {:noreply, Aqua.Runner.Recovery.recover(state, execution_id, stored, attempts)}
  end

  # The athanor changed (a rename, a settings patch, an archive): re-read
  # what the runner keeps of it. An archive ends
  # the runner — the turn is interrupted and recorded, the queue dropped —
  # so an already-open chat cannot keep running turns in a closed furnace.
  # Every other notify on the athanor's topic — approvals, executions,
  # members — is for the tray, not the runner.
  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, state) do
    case Athanors.get(state.athanor_id) do
      {:ok, %{status: "archived"}} ->
        state =
          if state.running,
            do: Aqua.Runner.Stream.shutdown(state, "the athanor was archived"),
            else: Aqua.Runner.Addressing.clear_queue(state)

        {:stop, :normal, state}

      {:ok, _athanor} ->
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:notify, _athanor_id, _kind, _payload}, state), do: {:noreply, state}

  # Trapping exits: a linked process ending is not the runner's concern.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:idle, %{running: false} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:idle, state), do: {:noreply, Aqua.Runner.Shared.touch(state)}

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{running: true} = state) when reason in [:normal, :shutdown] do
    Aqua.Runner.Stream.shutdown(state)
  end

  def terminate({:shutdown, _}, %{running: true} = state), do: Aqua.Runner.Stream.shutdown(state)
  def terminate(_reason, _state), do: :ok
end
