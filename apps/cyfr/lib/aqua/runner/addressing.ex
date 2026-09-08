# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.Addressing do
  @moduledoc """
  A message arrives: it is persisted, addressed, queued behind a running turn, and a turn is started for it.

  Part of `Aqua.ConversationRunner`: every function here takes the
  runner's state and answers the state, and is called from the runner's
  callbacks alone — the public face stays `Aqua.ConversationRunner`.
  """

  require Logger
  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.Attachments
  alias Aqua.Orchestrator
  alias Aqua.Turn, as: AquaTurn
  alias Sanctum.Tenancy.Members

  # The two reserved authors, as the schema spells them: the assistant's
  # own speech, and the runner's voice.
  @agent_author Arca.Schemas.Message.agent_author()
  @system_author Arca.Schemas.Message.system_author()
  # A turn's task is bounded — a long-quiet group can pile up chatter.
  @window_rows 50
  @window_bytes 60_000
  # Ceiling on the async turn start reporting back. Every fault inside the
  # task is converted to a `{:turn_start_result, ...}` message, so this
  # fires only when the task itself was killed (supervisor shutdown, brutal
  # kill) — without it, `running: true` with no execution id was permanent
  # and the conversation answered `:busy` forever.
  @turn_start_timeout_ms :timer.minutes(2)

  # ---------------------------------------------------------------------------
  # Sending: persist, address, start or queue
  # ---------------------------------------------------------------------------

  @doc false
  def do_stop(state, ctx) do
    state = clear_queue(state)

    cond do
      state.running and state.execution_id ->
        {:reply, :ok, Aqua.Runner.Stream.cancel_turn(state, ctx)}

      state.running ->
        {:reply, :ok, %{state | cancel_requested: true}}

      true ->
        {:reply, :ok, state}
    end
  end

  @doc false
  def persist_message(state, ctx, text, opts) do
    Conversations.append(ctx, state.id, %{
      id: Keyword.get(opts, :id),
      author: ctx.user_id || @system_author,
      kind: "text",
      content: text,
      payload: attachment_payload(Keyword.get(opts, :attachments, []))
    })
  end

  @doc false
  def attachment_payload([]), do: nil
  def attachment_payload(refs) when is_list(refs), do: %{"attachments" => refs}

  # What a message means for AQUA: `:post` (people talking), or a turn for
  # an orchestrator.
  #
  # An estate with exactly one human addresses its agent with every
  # message — there is nobody else the message could be for. Any other
  # estate requires a mention, every time. There is deliberately no
  # "follow-up" rule that keeps addressing the last agent: once sticky, a
  # person who said `@tom` could not say anything to the people in the room
  # without starting a turn, and there is no un-mention. Nothing is lost by
  # it — `task_of/2` carries every human line since the last turn, so a
  # bare follow-up reaches the agent on the next mention.
  #
  # This used to read a stored `answer_mode` and the athanor's `kind`. Both
  # are derivable, and `"all"` stopped meaning anything once an agent could
  # belong to a person: whose agent answers every line?
  @doc false
  def addressing(state, _ctx, text, opts) do
    roster = Keyword.get(opts, :orchestrators, [])
    {_message, mentioned} = AquaTurn.parse_mention(text, roster)

    if solo_human?(state) or not is_nil(mentioned) do
      case pick_orchestrator(state, roster, mentioned, opts) do
        {:ok, orchestrator} -> {:turn, orchestrator}
        {:error, reason} -> {:error, reason}
      end
    else
      :post
    end
  end

  @doc false
  def solo_human?(state), do: Members.solo?(state.athanor_id)

  # Several people speak here, so the task prefixes each line with a name
  # and the prompt says so. The same derivation as `solo_human?/1` —
  # "whose message is this?" and "does the agent need to be told who is
  # talking?" are one fact, and they used to be two stored ones.
  @doc false
  def multi_author?(rows) do
    rows |> Enum.map(& &1.author) |> Enum.uniq() |> length() > 1
  end

  @doc false
  def attributed(acc, row, text) do
    {name, acc} = name_of(acc, row.author)
    {"#{name}: #{text}", acc}
  end

  @doc false
  def after_persist(state, _ctx, _row, :post, _opts), do: Aqua.Runner.Shared.touch(state)

  def after_persist(state, ctx, row, {:turn, orchestrator}, opts) do
    entry = %{
      ctx: ctx,
      orchestrator: orchestrator,
      seq: row.seq,
      message_id: row.id,
      model: Keyword.get(opts, :model),
      # What the sender had open beside this thread, for this turn alone —
      # it is not in the row, so it has to travel with the entry.
      context: Keyword.get(opts, :context),
      # This sender's roster, carried with the message it belongs to. A
      # queued turn may start long after the send, and it must still strip
      # the mention against the roster of whoever wrote that line.
      roster: Keyword.get(opts, :orchestrators, [])
    }

    if state.running do
      state = %{state | queue: state.queue ++ [entry]}

      state
      |> Aqua.Runner.Shared.broadcast({:queued, length(state.queue)})
      |> Aqua.Runner.Shared.touch()
    else
      start_turn(state, entry)
    end
  end

  # The next waiting turn, if any — only after a turn *completed*; a stop,
  # a failure or a restart prompt never launches what was queued.
  @doc false
  def start_next(%{queue: []} = state), do: state

  def start_next(%{queue: [entry | rest]} = state) do
    state = %{state | queue: rest} |> Aqua.Runner.Shared.broadcast({:queued, length(rest)})

    if Aqua.Runner.Shared.may_act?(entry.ctx, state) do
      start_turn(state, entry)
    else
      # The sender left the athanor while waiting; their turn does not run.
      state
      |> Aqua.Runner.Recovery.append_and_broadcast(%{
        author: @system_author,
        kind: "system",
        content: "A queued message was dropped — its sender is no longer a member."
      })
      |> start_next()
    end
  end

  @doc false
  def clear_queue(%{queue: []} = state), do: state
  def clear_queue(state), do: %{state | queue: []} |> Aqua.Runner.Shared.broadcast({:queued, 0})

  # Engine work pushed out of the runner's loop (turn starts, cancels,
  # approvals). The WORK reports back by message; the SPAWN is checked
  # here — a supervisor at its ceiling used to drop the work silently,
  # leaving whatever waited on the message waiting forever.
  @doc false
  def start_task(fun) do
    logger_metadata = Cyfr.LoggerContext.capture()

    case Task.Supervisor.start_child(Aqua.TaskSupervisor, fn ->
           Cyfr.LoggerContext.restore(logger_metadata)
           fun.()
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Aqua.ConversationRunner] task not started: #{inspect(reason)}")
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # Turn start
  # ---------------------------------------------------------------------------

  # The task is every human message since the last turn, up to and
  # including the one that addressed AQUA — bounded, mention-stripped, and
  # in a group prefixed with who said it. The cursor advances at start;
  # what a cancelled or failed turn consumed is folded into the history
  # instead (`cancel_turn/2`, `fail_turn/2`), so nothing is lost and
  # nothing is fed twice.
  #
  # The runner's loop decides only what it holds: the cursor, the task
  # and the row. Everything that reaches storage or MCP — resolving the
  # pick, the pin, the composition, the start — is `Aqua.Turn.begin/5`,
  # run in a task that reports back by message.
  @doc false
  def start_turn(state, %{ctx: ctx, orchestrator: pick, seq: seq} = entry) do
    # Belt: every turn-end path drains or clears the queue synchronously,
    # so an entry should never carry a seq behind the cursor — but if one
    # ever does, the cursor must not move backwards, or the next turn
    # re-reads messages a finished turn already consumed.
    seq = max(seq, state.turn_seq || 0)
    rows = window_rows(state, seq)
    {task, state} = task_of(state, rows, seq, entry.roster)

    Conversations.update(state.system_ctx, state.id, %{turn_seq: seq, orchestrator: pick.name})

    ref = make_ref()
    runner = self()
    conversation_id = state.id

    begin_opts = [
      engine: state.turn,
      attachments: Attachments.attachments_of(rows),
      history: state.history,
      model: entry.model,
      group: not solo_human?(state),
      room_context: entry.context
    ]

    spawned =
      start_task(fn ->
        result =
          try do
            AquaTurn.begin(ctx, conversation_id, pick, task, begin_opts)
          rescue
            e -> {:error, Exception.message(e)}
          catch
            # The loads and the start reach GenServers and MCP: a call
            # timeout or a dead process arrives as an exit, not an
            # exception. Uncaught, the task died silently and the runner
            # waited forever on a result that was never coming.
            kind, reason ->
              Logger.warning("[Aqua.ConversationRunner] turn start #{kind}: #{inspect(reason)}")
              {:error, "the engine did not respond while starting the turn"}
          end

        send(runner, {:turn_start_result, ref, result})
      end)

    case spawned do
      :ok ->
        # The task is the only thing that reports back; if it is killed
        # mid-flight, the deadline turns the silence into a failed turn.
        Process.send_after(self(), {:turn_start_timeout, ref}, @turn_start_timeout_ms)

        %{
          state
          | turn_ctx: ctx,
            running: true,
            starting: ref,
            execution_id: nil,
            last_event_seq: -1,
            cancel_requested: false,
            streaming_text: "",
            tool_activity: [],
            usage: %{input: 0, output: 0},
            # Until the task reports the resolved detail, the previous
            # turn's agent stands in for display; a resolved pick replaces
            # it at once.
            orchestrator: if(Orchestrator.resolved?(pick), do: pick, else: state.orchestrator),
            tool_policy: Orchestrator.tool_policy(pick),
            turn_seq: seq,
            last_task: task
        }
        |> Aqua.Runner.Shared.broadcast({:turn_starting, ctx.user_id})
        |> Aqua.Runner.Shared.touch()

      :error ->
        # The supervisor refused the task: the turn never started, so the
        # state must not say it did. Same shape as the dropped-member case
        # above — tell the room, then keep draining the queue.
        state
        |> Aqua.Runner.Recovery.append_and_broadcast(%{
          author: @system_author,
          kind: "error",
          content: "The turn could not start — the server is busy. Send the message again."
        })
        |> start_next()
    end
  end

  # The human text rows a turn takes up: after the last cursor, up to the
  # addressing message; the newest @window_rows / @window_bytes of them.
  @doc false
  def window_rows(state, upto_seq) do
    rows =
      Conversations.messages(state.system_ctx, state.id,
        after_seq: state.turn_seq,
        upto_seq: upto_seq
      )
      |> Enum.filter(&(&1.kind == "text" and &1.author not in [@agent_author, @system_author]))

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

  # The turn's task: every human line since the last cursor.
  #
  # Only the TRIGGERING line has its mention stripped, and only against the
  # roster of the person who wrote it. Its `@tom` is routing metadata that
  # `addressing/4` already consumed; everyone else's is content, and the
  # model should see who Bob was addressing. Stripping the whole window
  # against one sender's roster would delete Bob's `@tom` because Alice
  # happens to have a Tom.
  @doc false
  def task_of(state, rows, trigger_seq, roster) do
    # Attribute when this task carries more than one voice, or when there
    # is more than one person here to carry a second. Reading the ROWS and
    # not just the roster matters: a member can leave between writing a
    # line and the turn that consumes it, and their words still need a
    # name on them.
    attribute? = multi_author?(rows) or not solo_human?(state)

    {lines, state} =
      Enum.map_reduce(rows, state, fn row, acc ->
        text =
          if row.seq == trigger_seq do
            {stripped, _mention} = AquaTurn.parse_mention(row.content || "", roster)
            stripped
          else
            row.content || ""
          end

        if attribute?, do: attributed(acc, row, text), else: {text, acc}
      end)

    {Enum.join(lines, "\n"), state}
  end

  @doc false
  def name_of(state, user_id) do
    case Map.fetch(state.names, user_id) do
      {:ok, name} ->
        {name, state}

      :error ->
        name = AquaTurn.display_name(user_id)
        {name, %{state | names: Map.put(state.names, user_id, name)}}
    end
  end

  # `@name` in the text wins, then an explicit option, then the
  # orchestrator of the previous turn, then the athanor's first (the
  # roster lists the soul first). Only the NAME is decided here (against
  # the roster the send carried — no network in handle_call); the run-time
  # detail resolves inside the turn-start task. `roster` is THIS sender's,
  # resolved for this message. The fallback to the turn's last
  # orchestrator is a name-resolution convenience once a message is
  # already addressed — it never decides that a bare line IS addressed,
  # which is `addressing/4`'s job alone.
  @spec pick_orchestrator(map(), [map()], map() | nil, keyword()) ::
          {:ok, Orchestrator.t()} | {:error, :no_orchestrator}
  @doc false
  def pick_orchestrator(state, roster, mentioned, opts) do
    named = mentioned || entry_named(roster, Keyword.get(opts, :orchestrator))

    cond do
      named -> pick(named)
      # The previous turn's agent — its IDENTITY, never its resolved
      # detail: the turn-start task reads the current definition and the
      # current standing answers again, so an edit, a disabling or a
      # revoked "always" since the last turn holds for this one.
      state.orchestrator -> {:ok, Orchestrator.identity(state.orchestrator)}
      first = List.first(roster) -> pick(first)
      true -> {:error, :no_orchestrator}
    end
  end

  # The name only; the turn-start task resolves (and thereby validates)
  # the detail — an unknown name fails the turn there rather than holding
  # the send hostage to a catalog read. An entry with no usable name is
  # nobody, refused here, never a crash in the loop.
  @doc false
  def pick(%{"name" => name}) when is_binary(name), do: {:ok, Orchestrator.by_name(name)}
  def pick(_entry), do: {:error, :no_orchestrator}

  # The explicit option: a roster entry (the picker hands the whole map),
  # or a bare name for older callers. An unknown name still picks; the
  # turn-start task is where it fails.
  @doc false
  def entry_named(_roster, nil), do: nil
  def entry_named(_roster, %{"name" => _} = entry), do: entry

  def entry_named(roster, name) when is_binary(name),
    do: Enum.find(roster, &(&1["name"] == name)) || %{"name" => name}
end
