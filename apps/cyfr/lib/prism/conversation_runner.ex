# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.ConversationRunner do
  @moduledoc """
  The process that owns a conversation's turn.

  One runner per conversation, started on demand under
  `Prism.ConversationSupervisor` and found through
  `Prism.ConversationRegistry`. A browser session never owns a turn: the
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
  an AQUA turn is *addressing*: in a person's own athanor every message
  does; in a group only a message that `@`-mentions an orchestrator does,
  unless the group's setting says AQUA answers everything
  (`Sanctum.Tenancy.Athanors.answer_mode/1`). A turn's task is every human
  message since the last turn — the ones that did not address AQUA
  included, so the agent hears the whole exchange — each line prefixed
  with the speaker's name in a group. One turn runs at a time; a message
  that addresses AQUA while one runs is queued (bounded) and starts when
  the running turn completes.

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

  The turn itself — the formula input, the execution, its events — is
  `Prism.AquaTurn`; the module is read from `:cyfr, :aqua_turn` when a
  runner starts so a suite can stand in a fake engine.
  """

  use GenServer, restart: :transient

  require Logger

  alias Arca.ConversationStorage, as: Conversations
  alias Prism.{AquaTurn, Attachments}
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members}

  @idle_ms :timer.minutes(15)
  @recover_retry_ms 2_000
  @recover_attempts 15
  # Turns waiting behind the running one; beyond it a sender is told `:busy`.
  @queue_max 8
  # A turn's task is bounded — a long-quiet group can pile up chatter.
  @window_rows 50
  @window_bytes 60_000
  # The athanor's orchestrator names are an MCP round trip; cached briefly.
  @orchestrators_ttl_ms 60_000

  @type scope :: :once | :conversation | :always

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc false
  def start_link({conversation_id, athanor_id}) do
    GenServer.start_link(__MODULE__, {conversation_id, athanor_id}, name: via(conversation_id))
  end

  defp via(conversation_id), do: {:via, Registry, {Prism.ConversationRegistry, conversation_id}}

  @doc "The runner for a conversation, started if it is not running."
  @spec ensure(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure(conversation_id, athanor_id)
      when is_binary(conversation_id) and is_binary(athanor_id) do
    case Registry.lookup(Prism.ConversationRegistry, conversation_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Prism.ConversationSupervisor,
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
    case Registry.lookup(Prism.ConversationRegistry, conversation_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Whether a turn is running in this conversation right now — asked of the
  runner itself, so a viewer looking at another thread gets the truth about
  this one. No runner means no turn.
  """
  @spec turn_running?(String.t()) :: boolean()
  def turn_running?(conversation_id) do
    case whereis(conversation_id) do
      nil -> false
      pid -> GenServer.call(pid, :state).running == true
    end
  catch
    :exit, _ -> false
  end

  @doc "The PubSub topic a thread's viewers subscribe to, tenant-prefixed."
  @spec topic(String.t(), String.t()) :: String.t()
  def topic(conversation_id, athanor_id),
    do: Prism.Topics.conversation(conversation_id, athanor_id)

  @doc "Subscribe the calling process to a conversation's broadcasts."
  @spec subscribe(String.t(), String.t()) :: :ok
  def subscribe(conversation_id, athanor_id) do
    Phoenix.PubSub.subscribe(Emissary.PubSub, topic(conversation_id, athanor_id))
  end

  # ---------------------------------------------------------------------------
  # API — every call carries the acting member's context
  # ---------------------------------------------------------------------------

  @doc """
  The live part of the thread for a viewer joining now: whether a turn is
  running, the text streamed so far, tool activity, token usage, the
  conversation grants and the orchestrator in use.
  """
  @spec state(String.t(), String.t()) :: map()
  def state(conversation_id, athanor_id) do
    with {:ok, pid} <- ensure(conversation_id, athanor_id) do
      GenServer.call(pid, :state)
    end
  end

  @doc """
  Send a message: the row is appended and shown to every member; if it
  addresses AQUA a turn starts — or waits its turn behind the running one.

  `opts`: `:id` (a pre-minted message id — the sender wrote its
  attachments under it first), `:attachments` (their refs), `:model`,
  `:orchestrator` (a name; an `@name` mention in the text wins).
  `{:error, :busy}` when the queue is full (nothing is written);
  `{:error, :no_orchestrator}` when the athanor has none;
  `{:error, :not_member}` when the sender no longer belongs here;
  `{:error, :archived}` when the athanor has been archived.
  """
  @spec send_message(Context.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def send_message(%Context{} = ctx, conversation_id, text, opts \\ []) do
    call(ctx, conversation_id, {:send, ctx, text, opts})
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
  @spec revoke_grant(Context.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke_grant(%Context{} = ctx, conversation_id, tool, action) do
    call(ctx, conversation_id, {:revoke_grant, tool, action})
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
      GenServer.call(pid, request, 30_000)
    end
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
      Logger.warning("[Prism.ConversationRunner] boot recovery skipped: #{Exception.message(e)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init({conversation_id, athanor_id}) do
    # Trapping exits so a supervisor shutdown mid-turn reaches terminate/2.
    Process.flag(:trap_exit, true)
    ctx = system_ctx(athanor_id)

    # An archived athanor is a hard stop for a new runner too, not only for a
    # send into a live one: a tab left open on a chat whose furnace closed
    # would otherwise start one on its next click.
    with {:ok, conv} <- Conversations.get(ctx, conversation_id),
         {:ok, %{status: "active"} = athanor} <- Athanors.get(athanor_id) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(athanor_id))

      state = %{
        id: conv.id,
        athanor_id: athanor_id,
        # person | group — a person's athanor addresses AQUA with every message.
        kind: athanor.kind,
        answer_mode: Athanors.answer_mode(athanor),
        system_ctx: ctx,
        turn: Application.get_env(:cyfr, :aqua_turn, AquaTurn),
        # The context of the member whose turn is running.
        turn_ctx: nil,
        running: false,
        execution_id: nil,
        # Set while a turn is starting: the async start has not yet
        # returned an execution id.
        starting: nil,
        cancel_requested: false,
        streaming_text: "",
        tool_activity: [],
        usage: %{input: 0, output: 0},
        grants: MapSet.new(),
        orchestrator: nil,
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
        # The athanor's orchestrator names, cached (mention detection).
        orchestrators: [],
        orchestrators_at: 0,
        # Display names of members, cached for the group prefix.
        names: %{},
        idle_ref: nil
      }

      state =
        if conv.execution_id do
          send(self(), {:recover, conv.execution_id, conv.orchestrator, @recover_attempts})
          state
        else
          state
        end

      {:ok, touch(state)}
    else
      # No conversation, no athanor, or a furnace that has closed: no runner.
      {:ok, %{status: _archived}} -> :ignore
      {:error, _} -> :ignore
    end
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, public_state(state), touch(state)}
  end

  def handle_call({:send, ctx, text, opts}, _from, state) do
    text = String.trim(text || "")
    attachments = Keyword.get(opts, :attachments, [])

    cond do
      text == "" and attachments == [] ->
        {:reply, {:error, :empty}, state}

      standing(ctx, state) != :ok ->
        {:reply, standing(ctx, state), state}

      true ->
        state = refresh_orchestrators(state, ctx)

        case addressing(state, ctx, text, opts) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          # The queue is full: nothing is written, the sender keeps the draft.
          {:turn, _orch} when state.running and length(state.queue) >= @queue_max ->
            {:reply, {:error, :busy}, state}

          decision ->
            case persist_message(state, ctx, text, opts) do
              {:ok, row} ->
                state = broadcast(state, {:message, row})
                {:reply, :ok, after_persist(state, ctx, row, decision, opts)}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
        end
    end
  end

  # Stop ends the running turn and drops what was waiting behind it — a
  # member who says stop means the conversation, not one reply.
  def handle_call({:stop, ctx}, _from, state) do
    case standing(ctx, state) do
      :ok -> do_stop(state, ctx)
      refusal -> {:reply, refusal, state}
    end
  end

  def handle_call({:approve, ctx, message_id, scope}, _from, state) do
    # Deciding a card runs a tool and can write the athanor's shared
    # allowlist: the same standing a send is held to, asked again here rather
    # than trusted from the mount that opened the socket.
    with :ok <- standing(ctx, state),
         {:ok, msg} <-
           Conversations.resolve_approval(ctx, message_id, "pending", "running", %{
             resolution: %{"scope" => scope}
           }) do
      {:reply, :ok, run_approval(state, ctx, msg, scope)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:decline, ctx, message_id, reason, scope}, _from, state) do
    with :ok <- standing(ctx, state),
         {:ok, msg} <- Conversations.get_message(ctx, message_id),
         intent = approval_intent(msg),
         {summary, system_text} =
           AquaTurn.outcome_summary(:declined, %{reason: reason}, intent["title"] || ""),
         {:ok, msg} <-
           Conversations.resolve_approval(ctx, message_id, "pending", "declined", %{
             resolution: %{"reason" => reason, "summary" => summary, "scope" => scope}
           }) do
      if scope == :never, do: drop_from_policy(ctx, msg)
      approval_telemetry(state, ctx, msg, :declined, scope, reason)
      notify_resolved(state, msg)
      state = state |> append_history(system_text) |> broadcast({:message_updated, msg})
      {:reply, :ok, touch(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:revoke_grant, tool, action}, _from, state) do
    state = %{state | grants: MapSet.delete(state.grants, {tool, action})}
    {:reply, :ok, broadcast(state, {:grants, state.grants})}
  end

  def handle_call({:restart_for_consent, ctx, result}, _from, state) do
    if state.running and state.execution_id do
      payload = %{
        profile_id: Map.get(result, :profile_id),
        new_revision: Map.get(result, :revision),
        missing: %{chain: [], edge: nil, activation: nil}
      }

      exec_id = state.execution_id
      turn = state.turn
      turn.unsubscribe(exec_id, state.turn_ctx || ctx)

      Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
        turn.cancel_for_restart(ctx, exec_id, payload)
      end)

      # The sender is asked to re-send; a queued turn firing now would send
      # for them.
      state =
        state
        |> clear_queue()
        |> finish_turn()
        |> broadcast({:restart_prompt, state.last_task, ctx.user_id})

      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Sending: persist, address, start or queue
  # ---------------------------------------------------------------------------

  # A member of the athanor may act; so may an operator who opened it
  # (`Context.focus/2` audited that). A context minted at mount is not
  # trusted forever: this is re-asked on every send and at every dequeue.
  defp do_stop(state, ctx) do
    state = clear_queue(state)

    cond do
      state.running and state.execution_id ->
        {:reply, :ok, cancel_turn(state, ctx)}

      state.running ->
        {:reply, :ok, %{state | cancel_requested: true}}

      true ->
        {:reply, :ok, state}
    end
  end

  # What every act in a live conversation is held to: the furnace is open and
  # the caller still belongs to it.
  defp standing(%Context{} = ctx, state) do
    cond do
      not Athanors.active?(state.athanor_id) -> {:error, :archived}
      not may_act?(ctx, state) -> {:error, :not_member}
      true -> :ok
    end
  end

  defp may_act?(%Context{platform_admin: true}, _state), do: true
  defp may_act?(%Context{user_id: user_id}, state), do: Members.member?(user_id, state.athanor_id)

  defp persist_message(state, ctx, text, opts) do
    Conversations.append(ctx, state.id, %{
      id: Keyword.get(opts, :id),
      author: ctx.user_id || "system",
      kind: "text",
      content: text,
      payload: attachment_payload(Keyword.get(opts, :attachments, []))
    })
  end

  defp attachment_payload([]), do: nil
  defp attachment_payload(refs) when is_list(refs), do: %{"attachments" => refs}

  # What a message means for AQUA: `:post` (people talking), or a turn for
  # an orchestrator. A person's athanor addresses AQUA with every message;
  # a group only when the text mentions an orchestrator, unless the group
  # answers everything.
  defp addressing(state, ctx, text, opts) do
    {_message, mentioned} = AquaTurn.parse_mention(text, state.orchestrators)

    addressed? = state.kind == "person" or state.answer_mode == "all" or not is_nil(mentioned)

    if addressed? do
      case pick_orchestrator(ctx, state, mentioned, opts) do
        {:ok, orchestrator} -> {:turn, orchestrator}
        {:error, reason} -> {:error, reason}
      end
    else
      :post
    end
  end

  defp after_persist(state, _ctx, _row, :post, _opts), do: touch(state)

  defp after_persist(state, ctx, row, {:turn, orchestrator}, opts) do
    entry = %{
      ctx: ctx,
      orchestrator: orchestrator,
      seq: row.seq,
      message_id: row.id,
      model: Keyword.get(opts, :model)
    }

    if state.running do
      state = %{state | queue: state.queue ++ [entry]}
      state |> broadcast({:queued, length(state.queue)}) |> touch()
    else
      start_turn(state, entry)
    end
  end

  # The next waiting turn, if any — only after a turn *completed*; a stop,
  # a failure or a restart prompt never launches what was queued.
  defp start_next(%{queue: []} = state), do: state

  defp start_next(%{queue: [entry | rest]} = state) do
    state = %{state | queue: rest} |> broadcast({:queued, length(rest)})

    if may_act?(entry.ctx, state) do
      start_turn(state, entry)
    else
      # The sender left the athanor while waiting; their turn does not run.
      state
      |> append_and_broadcast(%{
        author: "system",
        kind: "system",
        content: "A queued message was dropped — its sender is no longer a member."
      })
      |> start_next()
    end
  end

  defp clear_queue(%{queue: []} = state), do: state
  defp clear_queue(state), do: %{state | queue: []} |> broadcast({:queued, 0})

  # ---------------------------------------------------------------------------
  # Turn start
  # ---------------------------------------------------------------------------

  # The task is every human message since the last turn, up to and
  # including the one that addressed AQUA — bounded, mention-stripped, and
  # in a group prefixed with who said it. The cursor advances at start;
  # what a cancelled or failed turn consumed is folded into the history
  # instead (`cancel_turn/2`), so nothing is lost and nothing is fed twice.
  defp start_turn(state, %{ctx: ctx, orchestrator: orchestrator, seq: seq} = entry) do
    rows = window_rows(state, seq)
    {task, state} = task_of(state, rows)
    turn_attachments = Attachments.attachments_of(rows)
    conv_id = state.id

    Conversations.update(state.system_ctx, state.id, %{
      turn_seq: seq,
      orchestrator: orchestrator["name"]
    })

    ref = make_ref()
    runner = self()
    history = state.history
    group? = state.kind == "group"
    turn = state.turn

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      result =
        try do
          attachments = Attachments.load(ctx, conv_id, turn_attachments)

          %{input: input, tool_policy: policy} =
            AquaTurn.build_input(ctx, orchestrator, task,
              history: history,
              attachments: attachments,
              model: entry.model,
              group: group?
            )

          case turn.start(ctx, input) do
            {:ok, eid} -> {:ok, eid, policy}
            {:error, reason} -> {:error, reason}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end

      send(runner, {:turn_start_result, ref, result})
    end)

    state = %{
      state
      | turn_ctx: ctx,
        running: true,
        starting: ref,
        execution_id: nil,
        cancel_requested: false,
        streaming_text: "",
        tool_activity: [],
        usage: %{input: 0, output: 0},
        orchestrator: orchestrator,
        tool_policy: orchestrator["tool_policy"] || %{},
        turn_seq: seq,
        last_task: task
    }

    state
    |> broadcast({:turn_starting, ctx.user_id})
    |> touch()
  end

  # The human text rows a turn takes up: after the last cursor, up to the
  # addressing message; the newest @window_rows / @window_bytes of them.
  defp window_rows(state, upto_seq) do
    rows =
      Conversations.messages(state.system_ctx, state.id,
        after_seq: state.turn_seq,
        upto_seq: upto_seq
      )
      |> Enum.filter(&(&1.kind == "text" and &1.author not in ["aqua", "system"]))

    rows
    |> Enum.reverse()
    |> Enum.take(@window_rows)
    |> Enum.reduce_while({[], 0}, fn row, {kept, bytes} ->
      size = byte_size(row.content || "")

      if kept != [] and bytes + size > @window_bytes,
        do: {:halt, {kept, bytes}},
        else: {:cont, {[row | kept], bytes + size}}
    end)
    |> elem(0)
  end

  defp task_of(state, rows) do
    {lines, state} =
      Enum.map_reduce(rows, state, fn row, acc ->
        {text, _mention} = AquaTurn.parse_mention(row.content || "", acc.orchestrators)

        if acc.kind == "group" do
          {name, acc} = name_of(acc, row.author)
          {"#{name}: #{text}", acc}
        else
          {text, acc}
        end
      end)

    {Enum.join(lines, "\n"), state}
  end

  defp name_of(state, user_id) do
    case Map.fetch(state.names, user_id) do
      {:ok, name} ->
        {name, state}

      :error ->
        name = AquaTurn.display_name(user_id)
        {name, %{state | names: Map.put(state.names, user_id, name)}}
    end
  end

  # `@name` in the text wins, then an explicit option, then the
  # orchestrator of the previous turn, then the athanor's first.
  defp pick_orchestrator(ctx, state, mentioned, opts) do
    name =
      mentioned || Keyword.get(opts, :orchestrator) ||
        (state.orchestrator && state.orchestrator["name"]) ||
        (List.first(state.orchestrators) || %{})["name"]

    cond do
      is_nil(name) ->
        {:error, :no_orchestrator}

      state.orchestrator && state.orchestrator["name"] == name && is_nil(mentioned) &&
          is_nil(Keyword.get(opts, :orchestrator)) ->
        {:ok, state.orchestrator}

      true ->
        case AquaTurn.orchestrator(ctx, name) do
          nil -> {:error, :no_orchestrator}
          orchestrator -> {:ok, orchestrator}
        end
    end
  end

  # The athanor's orchestrator names — an MCP call as the sender, so cached
  # for a while; a change to the athanor invalidates the cache.
  defp refresh_orchestrators(state, ctx) do
    now = System.monotonic_time(:millisecond)

    if state.orchestrators == [] or now - state.orchestrators_at > @orchestrators_ttl_ms do
      %{state | orchestrators: AquaTurn.orchestrators(ctx), orchestrators_at: now}
    else
      state
    end
  end

  # ---------------------------------------------------------------------------
  # Turn events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:turn_start_result, ref, result}, %{starting: ref} = state) do
    state = %{state | starting: nil}

    case result do
      {:ok, eid, policy} ->
        state = %{state | execution_id: eid, tool_policy: policy}
        Conversations.update(state.system_ctx, state.id, %{execution_id: eid})

        if state.cancel_requested do
          {:noreply, cancel_turn(state, state.turn_ctx)}
        else
          state.turn.subscribe(eid, state.turn_ctx)
          {:noreply, broadcast(state, {:turn_started, eid})}
        end

      {:error, reason} ->
        {:noreply, fail_turn(state, "Execution failed to start: #{inspect(reason)}")}
    end
  end

  # A start result for a turn that is no longer the current one.
  def handle_info({:turn_start_result, _ref, _result}, state), do: {:noreply, state}

  def handle_info({:execution_event, %{type: "emit", data: data}}, state) do
    {:noreply, handle_emit(state, data["kind"] || data[:kind], data)}
  end

  def handle_info({:execution_event, %{type: "complete"}}, state) do
    {:noreply, complete_turn(state)}
  end

  def handle_info({:execution_event, %{type: "error", data: data}}, state) do
    err = data["message"] || data[:message] || inspect(data)
    {:noreply, fail_turn(state, err)}
  end

  def handle_info({:execution_event, _other}, state), do: {:noreply, state}

  def handle_info({:approval_result, message_id, ctx, outcome, payload}, state) do
    {:noreply, complete_approval(state, ctx, message_id, outcome, payload)}
  end

  def handle_info({:recover, execution_id, orchestrator_name, attempts}, state) do
    {:noreply, recover(state, execution_id, orchestrator_name, attempts)}
  end

  # The athanor changed (a rename, a settings patch such as the answer
  # mode, an archive): re-read what the runner keeps of it. An archive ends
  # the runner — the turn is interrupted and recorded, the queue dropped —
  # so an already-open chat cannot keep running turns in a closed furnace.
  # Every other notify on the athanor's topic — approvals, executions,
  # members — is for the tray, not the runner.
  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, state) do
    case Athanors.get(state.athanor_id) do
      {:ok, %{status: "archived"}} ->
        state =
          if state.running,
            do: shutdown(state, "the athanor was archived"),
            else: clear_queue(state)

        {:stop, :normal, state}

      {:ok, athanor} ->
        {:noreply, %{state | answer_mode: Athanors.answer_mode(athanor), orchestrators_at: 0}}

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

  def handle_info(:idle, state), do: {:noreply, touch(state)}

  def handle_info(msg, state) do
    Logger.debug("[Prism.ConversationRunner] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # A supervisor stop (a shutdown, a rolling deploy) mid-turn: write the
  # interruption while the Repo is still up, drop the queue, and let the
  # engine know — inline, since a task started here would die with us. A
  # crash writes nothing and keeps the row's `execution_id`, so the
  # transient restart re-follows a still-live execution.
  @impl true
  def terminate(reason, %{running: true} = state) when reason in [:normal, :shutdown] do
    shutdown(state)
  end

  def terminate({:shutdown, _}, %{running: true} = state), do: shutdown(state)
  def terminate(_reason, _state), do: :ok

  defp shutdown(state, why \\ "the server stopped") do
    exec_id = state.execution_id
    ctx = state.turn_ctx || state.system_ctx

    state =
      state
      |> clear_queue()
      |> interrupted(exec_id, why)

    if exec_id do
      state.turn.unsubscribe(exec_id, ctx)
      state.turn.cancel(ctx, exec_id)
    end

    state
  rescue
    e ->
      # Shutdown must not crash, but a failed cancel leaves the execution
      # running server-side while this runner reports itself stopped —
      # that orphan must be visible.
      Logger.warning(
        "[Prism.ConversationRunner] shutdown cancel failed for #{inspect(state.execution_id)}: " <>
          Exception.message(e)
      )

      %{state | running: false, execution_id: nil}
  catch
    :exit, reason ->
      Logger.warning(
        "[Prism.ConversationRunner] shutdown cancel exited for #{inspect(state.execution_id)}: " <>
          inspect(reason)
      )

      %{state | running: false, execution_id: nil}
  end

  # ---------------------------------------------------------------------------
  # Emits
  # ---------------------------------------------------------------------------

  defp handle_emit(state, "text_delta", data) do
    chunk = data["content"] || data[:content] || ""

    %{state | streaming_text: state.streaming_text <> chunk}
    |> broadcast({:delta, chunk})
  end

  defp handle_emit(state, "tool_use", data) do
    tool = data["tool"] || data[:tool] || "tool"
    activity = state.tool_activity ++ [%{tool: tool, status: :running, preview: nil}]
    %{state | tool_activity: activity} |> broadcast({:tool_activity, activity})
  end

  defp handle_emit(state, "tool_result", data) do
    tool = data["tool"] || data[:tool] || "tool"
    preview = data["preview"] || data[:preview]
    activity = AquaTurn.mark_tool_done(state.tool_activity, tool, preview)
    %{state | tool_activity: activity} |> broadcast({:tool_activity, activity})
  end

  # Whatever the component still needs, the consent walk is the one place
  # it gets granted — the sender is shown the sheet for the asking ref.
  defp handle_emit(state, kind, data) when kind in ["setup_required", "request_setup"] do
    case data["component_ref"] || data[:component_ref] || "" do
      "" -> state
      ref -> broadcast(state, {:consent_required, ref, turn_user(state)})
    end
  end

  defp handle_emit(state, "usage", data) do
    input = data["input_tokens"] || data[:input_tokens] || 0
    output = data["output_tokens"] || data[:output_tokens] || 0
    usage = %{input: state.usage.input + input, output: state.usage.output + output}
    %{state | usage: usage} |> broadcast({:usage, usage})
  end

  # The formula's full history (provider-canonical shape); kept for the
  # next turn so the agent has multi-turn memory. Notes appended while the
  # turn ran (an approval outcome) ride along, not under it.
  defp handle_emit(state, "conversation_complete", data) do
    history = (data["messages"] || data[:messages] || []) ++ state.notes_in_flight
    %{state | history: history, notes_in_flight: []}
  end

  defp handle_emit(state, _kind, _data), do: state

  # ---------------------------------------------------------------------------
  # Turn end
  # ---------------------------------------------------------------------------

  defp complete_turn(state) do
    ctx = state.turn_ctx || state.system_ctx
    if state.execution_id, do: state.turn.unsubscribe(state.execution_id, ctx)

    %{text: text, approvals: approvals, intents: intents, tripwires: tripwires} =
      AquaTurn.parse_completion(state.streaming_text, state.tool_policy)

    state =
      if text != "" do
        {:ok, row} =
          Conversations.append(ctx, state.id, %{
            author: "aqua",
            kind: "text",
            content: text,
            execution_id: state.execution_id
          })

        broadcast(state, {:message, row})
      else
        state
      end

    orchestrator_name = state.orchestrator && state.orchestrator["name"]

    approval_rows =
      Enum.map(approvals, fn intent ->
        {:ok, row} =
          Conversations.append(ctx, state.id, %{
            id: intent.id,
            author: "aqua",
            kind: "approval",
            content: intent.title,
            status: "pending",
            payload: %{"intent" => intent, "orchestrator" => orchestrator_name},
            execution_id: state.execution_id
          })

        row
      end)

    state = Enum.reduce(approval_rows, state, &broadcast(&2, {:message, &1}))

    state =
      Enum.reduce(tripwires, state, fn text, acc ->
        {:ok, row} =
          Conversations.append(ctx, acc.id, %{author: "system", kind: "error", content: text})

        broadcast(acc, {:message, row})
      end)

    if approval_rows != [] do
      Sanctum.Notify.broadcast(state.athanor_id, :approval_pending, %{
        conversation_id: state.id,
        count: length(approval_rows)
      })
    end

    state =
      state
      |> finish_turn()
      |> broadcast_intents(intents)

    # Conversation-grant fast path: a proposal the members already chose to
    # auto-approve "for this chat" runs at once.
    state =
      Enum.reduce(approval_rows, state, fn row, acc ->
        intent = approval_intent(row)

        if AquaTurn.granted?(atomize_intent(intent), acc.grants) do
          case Conversations.resolve_approval(ctx, row.id, "pending", "running", %{
                 resolution: %{"scope" => :conversation}
               }) do
            {:ok, msg} -> run_approval(acc, ctx, msg, :conversation)
            _ -> acc
          end
        else
          acc
        end
      end)

    start_next(state)
  end

  defp broadcast_intents(state, []), do: state

  defp broadcast_intents(state, intents),
    do: broadcast(state, {:intents, intents, turn_user(state)})

  defp fail_turn(state, text) do
    ctx = state.turn_ctx || state.system_ctx
    if state.execution_id, do: state.turn.unsubscribe(state.execution_id, ctx)

    state =
      case Conversations.append(ctx, state.id, %{author: "system", kind: "error", content: text}) do
        {:ok, row} -> broadcast(state, {:message, row})
        _ -> broadcast(state, {:error, text})
      end

    finish_turn(state)
  end

  # Cancel an in-flight turn: unsubscribe, ask the engine to stop, keep the
  # partial reply as a message, and synthesise the user + truncated
  # assistant turns into the history so the next message keeps context.
  defp cancel_turn(state, ctx) do
    exec_id = state.execution_id
    turn_ctx = state.turn_ctx || ctx
    turn = state.turn

    if exec_id do
      turn.unsubscribe(exec_id, turn_ctx)

      Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
        turn.cancel(ctx, exec_id)
      end)
    end

    partial = state.streaming_text

    state =
      if partial != "" do
        {:ok, row} =
          Conversations.append(turn_ctx, state.id, %{
            author: "aqua",
            kind: "text",
            content: partial <> "\n\n_(cancelled)_",
            execution_id: exec_id
          })

        broadcast(state, {:message, row})
      else
        state
      end

    user_turn =
      if state.last_task,
        do: [%{"role" => "user", "content" => state.last_task}],
        else: []

    assistant_turn =
      if partial != "",
        do: [%{"role" => "assistant", "content" => partial <> "\n\n(cancelled)"}],
        else: []

    %{
      state
      | history: state.history ++ user_turn ++ assistant_turn ++ state.notes_in_flight,
        notes_in_flight: []
    }
    |> finish_turn()
  end

  # Persist the history and clear the running execution; broadcast the end.
  defp finish_turn(state) do
    Conversations.update(state.system_ctx, state.id, %{
      history: state.history,
      execution_id: nil
    })

    %{
      state
      | running: false,
        execution_id: nil,
        starting: nil,
        cancel_requested: false,
        streaming_text: "",
        tool_activity: [],
        turn_ctx: nil
    }
    |> broadcast({:turn_finished})
    |> touch()
  end

  # ---------------------------------------------------------------------------
  # Approvals
  # ---------------------------------------------------------------------------

  # `msg` is already marked "running" by the caller's compare-and-set.
  defp run_approval(state, ctx, msg, scope) do
    intent = approval_intent(msg)
    proposal = proposal_of(intent)

    state = apply_scope(state, ctx, msg, proposal, scope)
    state = broadcast(state, {:message_updated, msg})

    case proposal do
      nil ->
        # A pure-confirmation card — nothing to execute; the acknowledgement
        # is the outcome.
        complete_approval(state, ctx, msg.id, :approved, %{result: %{status: "ok"}})

      %{} ->
        runner = self()
        id = msg.id
        turn = state.turn

        Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
          result =
            try do
              turn.run_approved(proposal, ctx)
            rescue
              e -> {:error, Exception.message(e)}
            end

          case result do
            {:ok, value} ->
              send(runner, {:approval_result, id, ctx, :approved, %{result: value}})

            {:error, reason} ->
              send(runner, {:approval_result, id, ctx, :error, %{reason: reason}})
          end
        end)

        state
    end
  end

  # `:conversation` remembers the pair for the rest of this chat; `:always`
  # also writes `"auto"` for it into the athanor's agent allowlist.
  defp apply_scope(state, ctx, msg, %{tool: tool, action: action}, scope)
       when scope in [:conversation, :always] do
    grants = MapSet.put(state.grants, {tool, action})
    state = %{state | grants: grants} |> broadcast({:grants, grants})

    if scope == :always do
      case approval_orchestrator(msg) do
        nil ->
          :ok

        name ->
          case Prism.AgentConfig.set_tool_auto(ctx, name, "#{tool}.#{action}") do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[Prism.ConversationRunner] could not persist always for #{tool}.#{action}: " <>
                  inspect(reason)
              )
          end
      end
    end

    state
  end

  defp apply_scope(state, _ctx, _msg, _proposal, _scope), do: state

  # Decline "never": the proposed action leaves the agent's allowlist.
  defp drop_from_policy(ctx, msg) do
    with %{tool: tool, action: action} <- proposal_of(approval_intent(msg)),
         name when is_binary(name) <- approval_orchestrator(msg) do
      Prism.AgentConfig.drop_tool(ctx, name, "#{tool}.#{action}")
    end

    :ok
  end

  defp complete_approval(state, ctx, message_id, outcome, payload) do
    case Conversations.get_message(ctx, message_id) do
      {:ok, msg} ->
        intent = approval_intent(msg)
        scope = Conversations.resolution(msg)["scope"]

        {summary, system_text} =
          AquaTurn.outcome_summary(outcome, payload, intent["title"] || "")

        status = if outcome == :approved, do: "approved", else: "error"

        case Conversations.resolve_approval(ctx, message_id, "running", status, %{
               resolution: %{
                 "summary" => summary,
                 "reason" => payload[:reason] && inspect(payload[:reason]),
                 "scope" => scope
               }
             }) do
          {:ok, updated} ->
            approval_telemetry(state, ctx, updated, outcome, scope, payload[:reason])
            notify_resolved(state, updated)

            state
            |> append_history(system_text)
            |> broadcast({:message_updated, updated})
            |> touch()

          {:error, _} ->
            state
        end

      {:error, _} ->
        state
    end
  end

  # A synthetic turn the agent should see next time. While a turn runs the
  # formula will hand back its own snapshot of the history at the end, so
  # the note is also kept aside and merged into that snapshot.
  defp append_history(state, system_text) do
    note = %{"role" => "user", "content" => system_text}
    history = state.history ++ [note]
    Conversations.update(state.system_ctx, state.id, %{history: history})

    notes = if state.running, do: state.notes_in_flight ++ [note], else: state.notes_in_flight
    %{state | history: history, notes_in_flight: notes}
  end

  # The tray: a card someone else was looking at is settled.
  defp notify_resolved(state, msg) do
    Sanctum.Notify.broadcast(state.athanor_id, :approval_resolved, %{
      conversation_id: state.id,
      message_id: msg.id,
      status: msg.status,
      resolved_by: msg.resolved_by
    })
  end

  defp approval_telemetry(state, ctx, msg, outcome, scope, reason) do
    proposal = proposal_of(approval_intent(msg)) || %{tool: nil, action: nil}
    intent = approval_intent(msg)

    :telemetry.execute([:cyfr, :prism, :aqua, :approval], %{count: 1}, %{
      id: msg.id,
      decision: outcome,
      scope: scope_atom(scope),
      tool: proposal[:tool],
      action: proposal[:action],
      kind: intent["action_kind"],
      conversation_id: state.id,
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      orchestrator: approval_orchestrator(msg),
      reason: reason
    })
  rescue
    # An approval decision's telemetry is compliance-relevant — dropping
    # it must leave a trace, even though it must not fail the decision.
    e ->
      Logger.warning(
        "[Prism.ConversationRunner] approval telemetry dropped: " <> Exception.message(e)
      )

      :ok
  end

  defp scope_atom(scope) when scope in [:once, :conversation, :always, :never], do: scope
  defp scope_atom("conversation"), do: :conversation
  defp scope_atom("always"), do: :always
  defp scope_atom("never"), do: :never
  defp scope_atom(_), do: :once

  # The intent as stored on the row (string keys after the JSON round trip).
  defp approval_intent(msg), do: Conversations.payload(msg)["intent"] || %{}
  defp approval_orchestrator(msg), do: Conversations.payload(msg)["orchestrator"]

  defp proposal_of(%{"proposal" => %{"tool" => tool, "action" => action} = p})
       when is_binary(tool) and is_binary(action),
       do: %{tool: tool, action: action, args: p["args"] || %{}}

  defp proposal_of(_), do: nil

  defp atomize_intent(intent), do: %{proposal: proposal_of(intent)}

  # ---------------------------------------------------------------------------
  # Recovery
  # ---------------------------------------------------------------------------

  # A turn that was running when the server stopped. If the engine is not
  # up yet, wait for it; if the execution is still running, follow it again
  # (its buffered events replay through the same handlers); if it finished
  # meanwhile, close the turn off with what the buffer still holds.
  defp recover(state, execution_id, orchestrator_name, attempts) do
    ctx = state.system_ctx
    turn = state.turn

    cond do
      state.running ->
        state

      not turn.engine_available?() and attempts > 0 ->
        Process.send_after(
          self(),
          {:recover, execution_id, orchestrator_name, attempts - 1},
          @recover_retry_ms
        )

        state

      not turn.engine_available?() ->
        interrupted(state, execution_id, "no execution engine")

      true ->
        events = turn.events_since(execution_id, state.athanor_id)
        finished? = Enum.any?(events, &(&1.type in ["complete", "error"]))

        # The turn's policy is the orchestrator's; the row remembers which,
        # so a recovered completion checks its intents against the right one
        # instead of an empty allowlist that would drop them all.
        orchestrator =
          state.orchestrator ||
            (orchestrator_name && AquaTurn.orchestrator(ctx, orchestrator_name))

        state = %{
          state
          | running: true,
            execution_id: execution_id,
            turn_ctx: ctx,
            orchestrator: orchestrator,
            tool_policy: (orchestrator || %{})["tool_policy"] || %{}
        }

        state = replay(state, events)

        cond do
          finished? ->
            state

          turn.running?(ctx, execution_id) ->
            turn.subscribe(execution_id, ctx)
            broadcast(state, {:turn_started, execution_id})

          true ->
            interrupted(state, execution_id, "the server restarted")
        end
    end
  end

  defp replay(state, events) do
    Enum.reduce(events, state, fn
      %{type: "emit", data: data}, acc ->
        if acc.running, do: handle_emit(acc, data["kind"] || data[:kind], data), else: acc

      %{type: "complete"}, acc ->
        if acc.running, do: complete_turn(acc), else: acc

      %{type: "error", data: data}, acc ->
        if acc.running,
          do: fail_turn(acc, data["message"] || data[:message] || inspect(data)),
          else: acc

      _, acc ->
        acc
    end)
  end

  defp interrupted(state, execution_id, why) do
    state =
      if state.streaming_text != "" do
        append_and_broadcast(state, %{
          author: "aqua",
          kind: "text",
          content: state.streaming_text <> "\n\n_(interrupted)_",
          execution_id: execution_id
        })
      else
        state
      end

    state
    |> append_and_broadcast(%{
      author: "system",
      kind: "system",
      content: "This turn was interrupted — #{why}. Send the message again to continue."
    })
    |> Map.put(:running, true)
    |> finish_turn()
  end

  defp append_and_broadcast(state, attrs) do
    case Conversations.append(state.system_ctx, state.id, attrs) do
      {:ok, row} -> broadcast(state, {:message, row})
      {:error, _} -> state
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp public_state(state) do
    %{
      running: state.running,
      execution_id: state.execution_id,
      streaming_text: state.streaming_text,
      tool_activity: state.tool_activity,
      usage: state.usage,
      grants: state.grants,
      orchestrator: state.orchestrator,
      turn_user: turn_user(state),
      queued: length(state.queue),
      kind: state.kind,
      answer_mode: state.answer_mode
    }
  end

  defp turn_user(%{turn_ctx: %Context{user_id: user_id}}), do: user_id
  defp turn_user(_), do: nil

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      topic(state.id, state.athanor_id),
      {:conversation, state.id, event}
    )

    state
  end

  defp touch(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)
    %{state | idle_ref: Process.send_after(self(), :idle, @idle_ms)}
  end

  # The runner's own hands inside the athanor: reads and the rows the agent
  # writes (`author: "aqua"` / `"system"`) when no member's context applies.
  defp system_ctx(athanor_id) do
    Sanctum.internal_context(user_id: "_conversations", athanor_id: athanor_id, scope: :athanor)
  end
end
