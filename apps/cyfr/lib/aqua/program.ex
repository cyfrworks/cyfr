# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Program do
  @moduledoc """
  The attendant of a program used as a brain: the one process that takes
  what a held session (`Opus.Brain`) says and writes what Aqua owes it,
  for one thread and agent, from the session's start to its end, through
  tool runs, launch waits and the turns between.

  ## One attendant

  A turn whose agent names a program row opens with the host's
  `program.start` of that row (`Aqua.Loop`), decided as a model's
  `program.start` is; its dispatch is `attend/2`, which opens the session
  if none is held, starts or resumes the harness and sets the turn's work
  (`work`, with the turn's tools and the configuration it runs with). A
  start that opens a new native session names the turn's tools too, which
  a harness that keeps its session's tools for the session's life (Codex)
  takes there alone: a tool a later turn adds is not one it can call, and
  one a later turn lacks is still refused at CYFR's gate. The
  turn's loop then decides and runs the steps this process proposes with
  its own code and never reads the session itself.

  The holder hands this process the driver's lines a batch at a time.
  Their effects (the posts the program said in the open turn's work, the
  asks it made, the deliveries the driver took or refused, the posts its
  `idle` answered, its usage) commit with the batch's position in one
  transaction (`Arca.TurnStorage.commit_brain/3`), and only then is the
  holder told to read on. An ask of the open turn becomes a proposed step
  of purpose `brain`, recorded once by the native ask's id on a running
  or a paused turn, and the loop is told; an ask of other work, or with
  no turn open, is no step and cannot be answered under this session's
  binding, so it is refused by closing the session, and the open turn
  ends saying why. What the program says with no
  work open stays out of the thread.

  Its text of the open work is announced to the thread's viewers as it is
  written, never stored (`Aqua.Loop.Stream`), once its batch committed:
  each native message streams as a step of its own, settled by its `said`
  row and withdrawn when no row will land, at its native turn's end or
  the session's. Its own tools of the open work, by the name it gives,
  are told to the turn's loop as they start and end, which shows them in
  the one list of what runs (`Aqua.Loop`); nothing of them is stored. The
  native turn's `idle` and the session's end are told the same way, and
  the loop settles what still shows running then, while a call runs too.

  It writes a command when a row says one is owed, one at a time: a closed
  ask's result as its `answer`, then each post of the open turn that
  waits, each first recorded as an `input` step (`carry/3`) whose id the
  command carries, so a delivery is attempted once whatever restarts
  follow. A post carries its files after its text as the API path words
  them (`Aqua.Loop.Turn.file_block/2`), an image or a PDF as itself where
  the wire carries its type; a file never refuses a post, and one past
  the line's bound is named as too large to hand over.
  `accepted` says the write was taken and nothing more: a post's
  obligation ends when an `idle` names it.

  ## Recovery

  After the holder's or the driver's end the next start resumes the native
  session, naming as `pending` the turn's posts owed an answer. A resume
  replays nothing and goes on with nothing by itself, so each post its
  transcript holds is continued by one recovery prompt (a `notice`,
  attempted once), and each it does not hold is uncertain: never sent
  again, the thread says so, and the turn ends failed. An answer whose
  ask the resumed session no longer holds is told as one notice that names
  the call; the recorded tool step is never run again. The prompts owed
  are rows (`Arca.TurnStorage.reconcile_brain/3`), each obligation kept
  until its prompt's own step is recorded, so a restart between the two
  loses none. A start the driver cannot honour ends its process: the
  thread says so and the turn ends, and that start is not made again by
  itself. A transcript the harness no longer has (`gone`) is forgotten:
  the thread says the program starts over, and it does, with the thread's
  posts as its context; in the middle of the work, one recorded prompt
  carries the thread so far and what the work's calls answered, none of
  which runs again. A turn whose member's program is now another row than
  the held session's forgets that session, the old row's transcript owed
  its removal first, closes its holder, and starts over on the new row
  from the thread's posts, which the thread is told.

  ## Silence

  Thirty minutes (`Opus.Brain.silence_ms/0`) of the program's own silence
  end its job: the clock runs only while the program owes output and is
  kept in the thread's `brain_progress`, read by the database's clock. A
  session with no turn open that long is closed, and resumes at the next.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Aqua.Tape
  alias Sanctum.Context

  @registry Aqua.Program.Registry
  @sessions Aqua.Program.Sessions
  # The most bytes a fresh session's context takes on its post's line, as
  # the line's JSON measures them, escapes included: the newest posts that
  # fit. A post a sender writes is at most 32 KiB, at most six times that
  # escaped, so its line with this context and its files' notices stays
  # within the wire's bound (`Opus.Brain.max_line_bytes/0`).
  @context_bytes 512 * 1024
  # How a fresh session's context opens, and what separates two posts.
  @context_opening "The thread so far, oldest first, as context only: nothing in it is to be " <>
                     "done again because it is shown here.\n\n"
  @context_separator "\n\n"
  # The kinds of row a fresh session's context carries: the thread's posts.
  @context_kinds ~w(text opening report)

  @typedoc "What a turn's dispatch of its `program.start` hands the attendant."
  @type work :: %{
          ctx: Context.t(),
          guest: Context.t(),
          turn: map(),
          start: String.t(),
          program: %{row: String.t(), epoch: pos_integer(), name: String.t()},
          agent: String.t(),
          title: String.t(),
          generation: non_neg_integer(),
          config: map(),
          system: String.t(),
          tools: [map()]
        }

  # ===========================================================================
  # Entry points
  # ===========================================================================

  @doc """
  Of `rows` (a turn's projection), those a fresh session's context may
  carry before the post at `seq`: the thread's posts before it, of which
  the first post's context keeps the newest that fit. The loop joins
  their read threads before the turn's start is decided.
  """
  @spec context_rows([map()], integer()) :: [map()]
  def context_rows(rows, seq) when is_list(rows), do: Enum.filter(rows, &context_row?(&1, seq))

  defp context_row?(row, seq), do: row.kind in @context_kinds and row.seq < seq

  @doc """
  Attend `work`'s turn, for the loop `loop`: open the session if none is
  held, start the harness or resume its native session, and set the
  turn's work. Answers once the driver took the work: `{:ok, :started}`
  when the driver started a new native session for it, `{:ok, :went_on}`
  when it resumed the session or its process already ran; or `{:error,
  sentence}`, the reason the turn ends.
  """
  @spec attend(work(), pid()) :: {:ok, :started | :went_on} | {:error, String.t()}
  def attend(%{ctx: %Context{athanor_id: athanor_id}} = work, loop) when is_pid(loop) do
    key = {athanor_id, work.turn.thread_id, work.agent}

    with {:ok, pid} <- ensure(key) do
      GenServer.call(pid, {:attend, work, loop}, :infinity)
    end
  catch
    :exit, _ -> {:error, "#{work.title} stopped before it started."}
  end

  @doc """
  The loop of an attended turn says where it stands: `turn` as its row
  reads now (its fence and status), `loop` the process told of its asks,
  its `idle` and its end. A running turn whose session ended is started
  again, resuming. Answers the attendant, which the loop watches: one
  that ends ends nothing else, and the turn waits on it no longer.
  """
  @spec watch(work(), pid()) :: {:ok, pid()} | {:error, String.t()}
  def watch(%{ctx: %Context{athanor_id: athanor_id}} = work, loop) when is_pid(loop) do
    key = {athanor_id, work.turn.thread_id, work.agent}

    with {:ok, pid} <- if(pid = whereis(key), do: {:ok, pid}, else: ensure(key)) do
      GenServer.cast(pid, {:watch, work, loop})
      {:ok, pid}
    end
  end

  @doc """
  The turn `turn_id` is over: the session stays for the next turn, unless
  `close?`, which closes it as Stop does.
  """
  @spec release(String.t(), String.t(), String.t(), String.t(), boolean()) :: :ok
  def release(athanor_id, thread_id, agent, turn_id, close?) do
    case whereis({athanor_id, thread_id, agent}) do
      nil -> :ok
      pid -> GenServer.call(pid, {:release, turn_id, close?}, :infinity)
    end
  catch
    :exit, _ -> :ok
  end

  @doc "End the session of a thread and agent, its writes first: Stop closes it."
  @spec close(String.t(), String.t(), String.t()) :: :ok
  def close(athanor_id, thread_id, agent) do
    case whereis({athanor_id, thread_id, agent}) do
      nil -> :ok
      pid -> GenServer.call(pid, :close, :infinity)
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Whether a session of the thread and agent is held now."
  @spec holding?(String.t(), String.t(), String.t()) :: boolean()
  def holding?(athanor_id, thread_id, agent) do
    case whereis({athanor_id, thread_id, agent}) do
      nil -> false
      pid -> GenServer.call(pid, :holding?, 5_000)
    end
  catch
    :exit, _ -> false
  end

  defp whereis(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp ensure(key) do
    case DynamicSupervisor.start_child(@sessions, {__MODULE__, key}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} -> {:error, "the program's attendant could not start"}
    end
  end

  @doc false
  def start_link(key),
    do: GenServer.start_link(__MODULE__, key, name: {:via, Registry, {@registry, key}})

  # ===========================================================================
  # The attendant
  # ===========================================================================

  @impl true
  def init({athanor_id, thread_id, agent}) do
    {:ok,
     %{
       athanor_id: athanor_id,
       thread_id: thread_id,
       agent: agent,
       work: nil,
       loop: nil,
       brain: nil,
       boot: nil,
       phase: :closed,
       waiting: [],
       outstanding: nil,
       fresh?: false,
       how: :went_on,
       recovering?: false,
       pending: [],
       timer: nil,
       subscribed?: false,
       streams: %{},
       ordinal: 0
     }}
  end

  @impl true
  def handle_call({:attend, work, loop}, from, state) do
    {state, work} = moved(state, work)
    state = subscribe(%{state | work: work, loop: monitor(state, loop)})
    state = %{state | waiting: state.waiting ++ [from]}

    case state.phase do
      :closed -> {:noreply, open(state)}
      :ready -> {:noreply, write_work(%{state | how: :went_on})}
      _starting -> {:noreply, state}
    end
  end

  def handle_call({:release, turn_id, close?}, _from, %{work: %{turn: %{id: turn_id}}} = state) do
    state = %{state | work: %{state.work | turn: Map.put(state.work.turn, :status, "over")}}
    state = if close?, do: shut(state), else: state
    {:reply, :ok, arm(state)}
  end

  def handle_call({:release, _turn_id, _close?}, _from, state), do: {:reply, :ok, state}

  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, shut(state)}

  def handle_call(:holding?, _from, state), do: {:reply, state.brain != nil, state}

  @impl true
  def handle_cast({:watch, work, loop}, state) do
    state = subscribe(%{state | work: work, loop: monitor(state, loop)})

    cond do
      state.phase == :closed and work.turn.status == "running" ->
        {:noreply, open(%{state | recovering?: true})}

      state.phase == :ready ->
        {:noreply, deliver(state)}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({Opus.Brain, ref, {:lines, boot, lines}}, %{brain: {_pid, ref}} = state),
    do: {:noreply, batch(state, boot, lines)}

  def handle_info({Opus.Brain, ref, {:ended, reason}}, %{brain: {_pid, ref}} = state),
    do:
      %{state | brain: nil, boot: nil, outstanding: nil}
      |> withdraw()
      |> session_ended()
      |> ended(reason)

  def handle_info({Opus.Brain, _stale, _message}, state), do: {:noreply, state}

  def handle_info(:silence, state), do: silence(%{state | timer: nil})

  # A turn of the thread ended, whoever wrote its end: the clock may run
  # again, so it is read again with the work's turn as its row says.
  def handle_info(%Cyfr.Bus.ThreadEvent{kind: :turn_finished}, state),
    do: {:noreply, state |> settled() |> arm()}

  # A post or a result may now be owed: the thread moved.
  def handle_info(%Cyfr.Bus.ThreadEvent{}, %{phase: :ready} = state),
    do: {:noreply, deliver(state)}

  def handle_info(%Cyfr.Bus.ThreadEvent{}, state), do: {:noreply, state}

  # The turn's loop ended, perhaps after its turn's end and before its
  # release: the work's turn as its row says, and the clock with it.
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, %{loop: pid} = state),
    do: {:noreply, %{state | loop: nil} |> settled() |> arm()}

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # What the person posts and what the program says pass through here: no
  # status, debug log or crash report prints a byte of either.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {key, value} when key in [:state, :message, :reason, :log] -> {key, scrub(value)}
      other -> other
    end)
  end

  defp scrub(binary) when is_binary(binary), do: "#{byte_size(binary)} bytes"
  defp scrub(%module{} = struct), do: {module, struct |> Map.from_struct() |> scrub()}
  defp scrub(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, scrub(value)} end)
  defp scrub([head | tail]), do: [scrub(head) | scrub(tail)]

  defp scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> scrub() |> List.to_tuple()

  defp scrub(other), do: other

  defp monitor(%{loop: loop} = _state, loop), do: loop

  defp monitor(_state, loop) do
    Process.monitor(loop)
    loop
  end

  defp subscribe(%{subscribed?: true} = state), do: state

  defp subscribe(%{work: work} = state) do
    actor = Context.actor(work.ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.thread(actor, state.thread_id))
    %{state | subscribed?: true}
  end

  # ---------------------------------------------------------------------------
  # The session

  # A turn whose member's program is now another row than the one the held
  # session runs on: the session is forgotten, the old row's transcript
  # owed its removal first by the row stored with it
  # (`Arca.TurnStorage.forget_session/3`), its holder closed, and the
  # program starts over on the new row from the thread's posts, which the
  # thread is told. A forget that does not answer leaves the session as it
  # is stored: the holder is closed, and the new row's start resumes it,
  # which its driver answers as gone (`start_over/1`).
  defp moved(
         %{brain: brain, work: %{program: %{row: held}}} = state,
         %{program: %{row: row}} = work
       )
       when brain != nil and held != row do
    case Tape.forget_session(work.guest, work.turn, work.generation) do
      {:ok, generation} ->
        _ =
          system_row(
            work,
            "#{work.title} runs on another program now, so it starts over from the " <>
              "thread's posts."
          )

        {shut(state), %{work | generation: generation}}

      {:error, _unanswered} ->
        {shut(state), work}
    end
  end

  defp moved(state, work), do: {state, work}

  defp open(%{work: work} = state) do
    case Opus.Brain.open(bound(work)) do
      {:ok, brain} ->
        %{state | brain: brain, phase: :opening}

      {:error, reason} ->
        fail(state, refused_open(work, reason))
    end
  end

  defp refused_open(work, {:not_admitted, _reason}),
    do: "#{work.title} may not start for this work any more."

  # The backends refused for want of room, at its owner's hold or at the
  # session's open: the person reads why, not that the program is away.
  defp refused_open(work, {:refused, :capacity, _boot}), do: refused_open(work, :capacity)

  defp refused_open(work, :capacity),
    do: Prima.Refusal.message({:program_full, work.title, div(Opus.Brain.silence_ms(), 60_000)})

  defp refused_open(work, _unavailable),
    do: "#{work.title} could not be reached: its program did not open."

  # The binding each write is checked against again as it is about to be
  # written (`Opus.Brain`): the stored decision is the proof, and this
  # process adds no veto of its own.
  defp bound(work) do
    %{
      ctx: work.ctx,
      thread_id: work.turn.thread_id,
      agent: work.agent,
      turn_id: work.turn.id,
      origin: work.turn.origin,
      fence: work.turn.fence,
      step: work.start,
      row_id: work.program.row,
      epoch: work.program.epoch,
      generation: work.generation,
      admits?: fn -> true end
    }
  end

  defp write(%{brain: brain, work: work}, command, opts \\ []),
    do: Opus.Brain.write(brain, bound(work), command, opts)

  # The harness starts, resuming the thread's native session if it keeps
  # one, with the posts whose delivery its transcript says. A read that
  # did not answer says nothing of the session or of those posts: a fresh
  # start would leave a kept session behind, and a resume naming none
  # would leave the posts it holds unreconciled, so the work ends with
  # nothing written.
  defp write_start(%{work: work} = state) do
    with {:ok, %{session: session}} <- Tape.brain(work.guest, state.thread_id),
         {:ok, pending} <- pending(work, session) do
      write_start(state, session, pending)
    else
      {:error, _unanswered} ->
        fail(
          shut(state),
          "#{work.title} could not start: this thread's session could not be read."
        )
    end
  end

  defp pending(_work, nil), do: {:ok, []}
  defp pending(work, _session), do: Tape.brain_pending(work.guest, work.turn)

  # A start that opens a new native session names the work's tools beside
  # the work's own: a harness whose session keeps the tools it started
  # with for its life (Codex) takes them here and nowhere else, and one
  # that takes each work's (Claude Code) reads them from the `work`. A
  # resume names none, since the session keeps its own.
  defp write_start(%{work: work} = state, session, pending) do
    command =
      %{
        "t" => "start",
        "gen" => work.generation,
        "config" => work.config,
        "system" => work.system,
        "session" => session,
        "pending" => if(pending != [], do: pending),
        "tools" => if(is_nil(session), do: work.tools)
      }
      |> reject_nil()

    case write(state, command) do
      :ok -> %{state | phase: :starting, pending: pending, fresh?: session == nil}
      # The wire takes no such start: a startup option of the work's, its
      # instructions or its tools are not what the harness takes. Nothing
      # was written, and the work ends saying so.
      {:error, :unreadable} -> fail(shut(state), unreadable_start(work))
      {:error, reason} -> write_failed(state, reason)
    end
  end

  defp unreadable_start(work) do
    named = work.config |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    "#{work.title} could not start with what this work gives it: one of its options " <>
      "(#{named}), its instructions or its tools is not one it takes."
  end

  defp write_work(%{work: work} = state) do
    command = %{"t" => "work", "id" => work.start, "work" => work.turn.id, "tools" => work.tools}

    case write(state, command, config: work.config) do
      :ok -> %{state | phase: :working}
      {:ok, :restarted} -> %{state | phase: :opening}
      {:error, reason} -> write_failed(state, reason)
    end
  end

  # A write that may have reached the driver ends the session, and the
  # next start resumes; one refused before writing says why the work ends.
  defp write_failed(state, :uncertain), do: state

  defp write_failed(%{work: work} = state, _refused),
    do: fail(shut(state), "#{work.title} could not be given this work.")

  defp shut(%{brain: nil} = state), do: withdraw(state)

  defp shut(%{brain: brain} = state) do
    Opus.Brain.close(brain)

    %{state | brain: nil, boot: nil, phase: :closed, outstanding: nil}
    |> withdraw()
    |> session_ended()
  end

  # The session ended: none of the open work's own tools runs any more,
  # which the loop settles in its list (`Aqua.Loop`).
  defp session_ended(%{work: work} = state) do
    case open_turn(work) do
      %{id: id} -> tell(state, {__MODULE__, id, {:native, :session_ended}})
      nil -> state
    end
  end

  # ---------------------------------------------------------------------------
  # Lines

  # What the open turn has used, as its start step stores it once the
  # batch's usage is committed, told to the thread as the API path tells
  # its own (`:usage`, `Aqua.Tape.usage/2`): the models the program ran
  # and their tokens, and whether the accounting is partial or
  # unavailable, which is unknown and never zero.
  defp tell_usage(state, [], _open_turn), do: state
  defp tell_usage(state, _usage, nil), do: state

  defp tell_usage(%{work: work} = state, _usage, _open_turn) do
    Tape.announce(work.guest, state.thread_id, :usage, Tape.usage(work.guest, state.thread_id))
    state
  end

  defp batch(%{work: work} = state, boot, lines) do
    {last, _event} = List.last(lines)
    events = Enum.map(lines, &elem(&1, 1))
    open_turn = open_turn(work)
    effects = effects(state, events, open_turn)

    attrs =
      Map.merge(effects.commit, %{
        agent: state.agent,
        generation: work.generation,
        boot: boot,
        seq: last,
        row_id: work.program.row,
        epoch: work.program.epoch,
        silence_ms: Opus.Brain.silence_ms(),
        turn: open_turn && %{id: open_turn.id, fence: open_turn.fence}
      })

    case Tape.commit_brain(work.guest, state.thread_id, attrs) do
      {:ok, committed} ->
        Opus.Brain.read_on(state.brain, boot, last)
        state = %{state | boot: boot}
        if committed.asks != [] and open_turn, do: tell(state, {:page_call, open_turn.id})

        if effects.foreign?,
          do: state |> foreign() |> arm(),
          else:
            state
            |> stream(of_work(lines, "text", open_turn), effects.commit.said)
            |> own(of_work(lines, "own", open_turn))
            |> tell_usage(effects.commit.usage, open_turn)
            |> act(effects, committed)
            |> arm()

      {:error, reason} when reason in [:superseded, :generation_moved, :row_changed, :not_open] ->
        # The session is no longer this work's: its writes end here. A
        # session the thread forgot is owed its removal from the program's
        # folder by the transaction that forgot it (`Opus.Brain.Cleanup`).
        shut(state)

      {:error, reason} ->
        Logger.warning("[Aqua.Program] a batch could not be committed: #{inspect(reason)}")
        shut(state)
    end
  end

  # The batch's events of type `t` that are the open work's, each with
  # its line's number.
  defp of_work(lines, t, %{id: work_id}),
    do: for({seq, %{"t" => ^t, "work" => ^work_id} = event} <- lines, do: {seq, event})

  defp of_work(_lines, _t, nil), do: []

  # The turn the session works for while it is open, as the loop last said.
  defp open_turn(%{turn: %{status: status} = turn}) when status in ["running", "paused"], do: turn
  defp open_turn(_work), do: nil

  # What a batch's events do, judged here: the commit's attrs, and what
  # this process acts on once they are committed.
  defp effects(%{work: work, outstanding: outstanding}, events, open_turn) do
    work_id = open_turn && open_turn.id

    init = %{
      commit: %{said: [], asks: [], accepted: [], refused: [], answered: [], usage: []},
      hello?: false,
      started: nil,
      gone?: false,
      accepted: [],
      refused: [],
      idle: nil,
      errors: [],
      foreign?: false,
      native?: false
    }

    events
    |> Enum.reduce(init, fn event, acc ->
      # Every event of a native turn, and only those, carries its
      # generation (`Opus.Brain.Wire`, the program's own lines).
      acc = if Map.has_key?(event, "gen"), do: %{acc | native?: true}, else: acc
      effect(event, acc, work, work_id, outstanding)
    end)
    |> then(fn acc -> %{acc | commit: Map.put(acc.commit, :native, acc.native?)} end)
  end

  defp effect(%{"t" => "hello"}, acc, _work, _work_id, _outstanding),
    do: %{acc | hello?: true, commit: Map.put(acc.commit, :hello, true)}

  defp effect(%{"t" => "started"} = event, acc, _work, _work_id, _outstanding),
    do: %{acc | started: event, commit: Map.put(acc.commit, :session, event["session"])}

  defp effect(%{"t" => "gone"}, acc, _work, _work_id, _outstanding), do: %{acc | gone?: true}

  defp effect(%{"t" => "accepted", "id" => id}, acc, _work, _work_id, outstanding) do
    acc = %{acc | accepted: acc.accepted ++ [id]}

    if input?(outstanding, id),
      do: put_commit(acc, :accepted, id) |> busy(true),
      else: acc
  end

  defp effect(%{"t" => "refused", "id" => id} = event, acc, _work, _work_id, outstanding) do
    acc = %{acc | refused: acc.refused ++ [{id, event["reason"]}]}
    if input?(outstanding, id), do: put_commit(acc, :refused, id), else: acc
  end

  defp effect(%{"t" => "said", "work" => work_id} = event, acc, _work, work_id, _outstanding)
       when is_binary(work_id),
       do: put_commit(acc, :said, %{message: event["message"], text: event["text"]})

  defp effect(%{"t" => "ask", "work" => work_id} = event, acc, work, work_id, _outstanding)
       when is_binary(work_id),
       do: put_commit(acc, :asks, ask(work, event))

  # An ask of other work, or of none, is no step: the holder answers only
  # asks shown for the work it is bound to, so it is refused by closing
  # the session (`foreign/1`).
  defp effect(%{"t" => "ask"}, acc, _work, _work_id, _outstanding), do: %{acc | foreign?: true}

  defp effect(%{"t" => "usage"} = event, acc, _work, _work_id, _outstanding),
    do: put_commit(acc, :usage, event)

  # The open work's idle says the program owes nothing more for now; an
  # idle of other work answers its posts and leaves the open work's
  # obligation as it was.
  defp effect(%{"t" => "idle"} = event, acc, _work, work_id, _outstanding) do
    acc = Enum.reduce(event["answered"] || [], acc, &put_commit(&2, :answered, &1))
    acc = %{acc | idle: event}
    if is_binary(work_id) and event["work"] == work_id, do: busy(acc, false), else: acc
  end

  defp effect(%{"t" => "error"} = event, acc, _work, _work_id, _outstanding),
    do: %{acc | errors: acc.errors ++ [event]}

  # Text streamed, the harness's own tools, late prose and asks of other
  # work: nothing is written of them (`stream/3`).
  defp effect(_event, acc, _work, _work_id, _outstanding), do: acc

  defp put_commit(acc, key, value),
    do: %{acc | commit: Map.update!(acc.commit, key, &(&1 ++ [value]))}

  defp busy(acc, busy), do: %{acc | commit: Map.put(acc.commit, :busy, busy)}

  defp input?(%{id: id, input?: true}, id), do: true
  defp input?(_outstanding, _id), do: false

  # An ask of the open turn as the step the host proposes for it, decided
  # by the code that decides a model's call (`Aqua.Loop.recorded/2`), and
  # recorded once by the native ask's id. Its call row is a `tool_call`,
  # as a model's is.
  defp ask(work, %{"ask" => ask, "name" => name, "arguments" => arguments}) do
    call = Aqua.Loop.Binding.resolve(name, arguments, tool_call_id: ask)
    recorded = Aqua.Loop.recorded(name, call)

    %{
      kind: recorded.step_kind,
      tool: recorded.tool,
      action: recorded.action,
      recovery: recorded.recovery,
      child_execution_id: recorded.child_execution_id,
      idempotency_key: Tape.brain_ask_key(work.turn.id, ask),
      call: %{
        kind: "tool_call",
        content: name,
        payload:
          reject_nil(%{
            "tool_call_id" => ask,
            "name" => name,
            "tool" => recorded.tool,
            "action" => recorded.action,
            "arguments" => arguments,
            "kind" => recorded.kind
          })
      }
    }
  end

  # The open work's text, announced as it is written (`Aqua.Loop.Stream`),
  # each native message a step of its own, under the turn's fence as it
  # stands now: a message this batch said lands its row now, which settles
  # it, so none of its text is announced, and one said later is settled by
  # its row then.
  defp stream(state, texts, said) do
    said = MapSet.new(said, & &1.message)
    state = %{state | streams: Map.drop(state.streams, MapSet.to_list(said))}

    Enum.reduce(texts, state, fn {seq, %{"message" => message, "delta" => delta}}, state ->
      if delta == "" or MapSet.member?(said, message) do
        state
      else
        state = streaming(state, message)
        Aqua.Loop.Stream.announce(state.work.guest, streamed(state, message), {0, seq}, delta)
        state
      end
    end)
  end

  # A message first streamed takes the next ordinal, so a later message
  # outranks it while both are kept.
  defp streaming(%{streams: streams} = state, message) when is_map_key(streams, message),
    do: state

  defp streaming(state, message),
    do: %{
      state
      | streams: Map.put(state.streams, message, state.ordinal),
        ordinal: state.ordinal + 1
    }

  defp streamed(%{work: work} = state, message),
    do: %{
      thread_id: state.thread_id,
      turn_id: work.turn.id,
      fence: work.turn.fence,
      source: work.turn.id,
      step_id: message,
      ordinal: Map.fetch!(state.streams, message),
      role: if(Prima.AgentRef.soul?(work.agent), do: nil, else: work.agent)
    }

  # What streamed for messages no row will land is withdrawn: the open
  # work's native turn ended, or the session did.
  defp withdraw(%{streams: streams} = state) when map_size(streams) == 0, do: state

  defp withdraw(%{work: work, streams: streams} = state) do
    Enum.each(Map.keys(streams), &Aqua.Loop.Stream.abandon(work.guest, streamed(state, &1)))
    %{state | streams: %{}}
  end

  # The open work's own tools of the program, told to the loop as they
  # start and end: the loop keeps the one list of what runs, and nothing
  # of them is stored.
  defp own(state, owns) do
    Enum.reduce(owns, state, fn {_seq, %{"name" => name, "phase" => phase}}, state ->
      tell(state, {__MODULE__, state.work.turn.id, {:native, {:own, own_name(name), phase}}})
    end)
  end

  # The program's word for its tool is shown as text: a name as long as
  # the wire holds a tool's name to and with no control or format
  # character, or else a fixed word.
  defp own_name(name) do
    if Opus.Brain.tool_name?(name) and not String.match?(name, ~r/\p{C}/u),
      do: name,
      else: "tool"
  end

  # What this process does once a batch is committed.
  defp act(state, effects, _committed) do
    state
    |> on_started(effects)
    |> on_answers(effects)
    |> on_errors(effects)
    |> on_idle(effects)
    |> then(&if(&1.phase == :ready, do: deliver(&1), else: &1))
  end

  defp on_started(%{phase: :opening} = state, %{hello?: true}), do: write_start(state)

  defp on_started(%{phase: :starting} = state, %{gone?: true}), do: start_over(state)

  # The driver's `fresh` says whether the session is new, which is how the
  # turn's start is worded (`attend/2`).
  defp on_started(%{phase: :starting} = state, %{started: %{} = started}) do
    state = %{
      state
      | phase: :started,
        how: if(started["fresh"] == true, do: :started, else: :went_on)
    }

    case reconcile(state, started) do
      {:ok, state} -> write_work(state)
      {:fail, state, sentence} -> fail(state, sentence)
    end
  end

  defp on_started(state, _effects), do: state

  defp on_answers(%{work: work} = state, effects) do
    Enum.reduce(effects.refused, accepted(state, effects.accepted), fn {id, reason}, state ->
      cond do
        state.phase == :working and id == work.start ->
          fail(shut(state), "#{work.title} could not be given this work: #{reason}")

        match?(%{id: ^id, deliver: "answer"}, state.outstanding) ->
          renotice(%{state | outstanding: nil}, state.outstanding)

        match?(%{id: ^id}, state.outstanding) ->
          fail(shut(state), "#{work.title} refused the message: #{reason}")

        true ->
          state
      end
    end)
  end

  defp accepted(%{work: work} = state, ids) do
    Enum.reduce(ids, state, fn id, state ->
      cond do
        state.phase == :working and id == work.start ->
          reply_waiting(%{state | phase: :ready, recovering?: false}, {:ok, state.how})

        match?(%{id: ^id}, state.outstanding) ->
          %{state | outstanding: nil}

        true ->
          state
      end
    end)
  end

  # An error the harness reported ends the open turn, saying it.
  defp on_errors(state, %{errors: []}), do: state

  defp on_errors(%{work: work} = state, %{errors: [error | _]}) do
    if open_turn(work),
      do: fail(state, "#{work.title} could not answer: #{error["message"]}"),
      else: state
  end

  # The native turn ended: none of its own tools runs any more, which the
  # loop settles wherever it waits (`{:native, :idle}`), and the loop finds
  # whether its turn is done.
  defp on_idle(%{work: work} = state, %{idle: %{} = idle}) do
    case {open_turn(work), idle["work"]} do
      {%{id: id}, id} ->
        state = withdraw(state)
        state = tell(state, {__MODULE__, id, {:native, :idle}})

        if idle["stop"] == "end_turn",
          do: tell(state, {__MODULE__, id, :idle}),
          else: fail(state, "#{work.title} stopped before it finished (#{idle["stop"]}).")

      _late_or_other ->
        state
    end
  end

  defp on_idle(state, _effects), do: state

  # The program asked for a tool for work other than the open turn's: the
  # ask cannot be answered under this session's binding and is never a
  # step, so the session is closed and the open turn ends saying why.
  defp foreign(%{work: work} = state),
    do:
      fail(
        shut(state),
        "#{work.title} asked for a tool for other work than this, so it was stopped."
      )

  # The native session's transcript is gone: the thread forgets it, says
  # the program starts over, and it starts again with no session, the
  # thread's posts its context. Nothing backs the session forgotten, so
  # there is nothing of it to remove.
  defp start_over(%{work: work} = state) do
    with {:ok, generation} <- Tape.forget_session(work.guest, work.turn, work.generation),
         {:ok, _row} <-
           system_row(
             work,
             "#{work.title} no longer had its record of this thread, so it " <>
               "starts over from the thread's posts."
           ) do
      write_start(%{state | work: %{work | generation: generation}, phase: :opening})
    else
      {:error, _reason} -> fail(shut(state), "#{work.title} could not start over.")
    end
  end

  # A resumed session's transcript says which pending posts it holds:
  # each held is continued by one notice; one it does not hold, or a
  # notice held again, is uncertain and ends the turn saying so.
  defp reconcile(%{pending: [], recovering?: false} = state, _started), do: {:ok, state}

  # A session started anew while the turn was at work, its transcript
  # gone: nothing holds what was delivered, and the turn goes on with one
  # prompt that carries the thread so far (`Arca.TurnStorage`).
  defp reconcile(%{fresh?: true, work: work} = state, _started) do
    case Tape.reconcile_brain(work.guest, work.turn, %{generation: work.generation, fresh: true}) do
      {:ok, _reconciled} -> {:ok, %{state | pending: []}}
      {:error, _reason} -> {:fail, state, "#{work.title} could not go on after a restart."}
    end
  end

  defp reconcile(%{work: work} = state, started) do
    case Tape.reconcile_brain(work.guest, work.turn, %{
           generation: work.generation,
           held: started["held"] || []
         }) do
      {:ok, %{absent: [], held: held}} ->
        if Enum.any?(held, &(&1.action == "notice")),
          do: {:fail, state, uncertain_line(work)},
          else: {:ok, %{state | pending: []}}

      {:ok, %{absent: [_ | _]}} ->
        {:fail, state, uncertain_line(work)}

      {:error, _reason} ->
        {:fail, state, "#{work.title} could not go on after a restart."}
    end
  end

  defp uncertain_line(work),
    do:
      "#{work.title} was interrupted after it was handed your last message, and it is not " <>
        "handed that message again. Send a message to go on."

  # ---------------------------------------------------------------------------
  # Deliveries

  # The next command a row says is owed, one at a time while the session
  # is ready: a prompt a recovery owes, then a closed ask's result, then a
  # post that waits.
  defp deliver(%{outstanding: nil, work: work} = state) do
    case open_turn(work) do
      nil -> state
      turn -> deliver_next(state, turn)
    end
  end

  defp deliver(state), do: state

  defp deliver_next(%{work: work} = state, turn) do
    with nil <- next_notice(work, turn),
         nil <- next_result(work, turn),
         nil <- next_post(work, turn) do
      state
    else
      {:notice, %{context?: true, message_id: row_id}} -> notice(state, "fresh", row_id)
      {:notice, %{action: kind, message_id: row_id}} -> notice(state, kind, row_id)
      {:answer, result} -> answer(state, result)
      {:post, row} -> post(state, row)
    end
  end

  defp next_notice(work, turn) do
    case Tape.brain_notices(work.guest, turn) do
      {:ok, [notice | _]} -> {:notice, notice}
      _none -> nil
    end
  end

  defp next_result(work, turn) do
    case Tape.brain_results(work.guest, turn) do
      {:ok, [result | _]} -> {:answer, result}
      _none -> nil
    end
  end

  defp next_post(work, turn) do
    case Tape.brain_posts(work.guest, turn) do
      {:ok, [row | _]} -> {:post, row}
      _none -> nil
    end
  end

  defp answer(%{work: work} = state, %{row: row, call: call} = result) do
    with {:ok, %{step: step}} <- carry(work, "answer", row.id) do
      payload = if call, do: Tape.payload(call), else: %{}

      command = %{
        "t" => "answer",
        "id" => step.id,
        "ask" => payload["tool_call_id"],
        "content" => row.content || "",
        "is_error" => result.step.outcome != "ok"
      }

      case write(state, command) do
        :ok ->
          %{state | outstanding: %{id: step.id, input?: true, deliver: "answer", row: row.id}}

        # The resumed session no longer holds the ask: its answer goes as
        # one notice that names the call.
        {:error, :not_this_work} ->
          _ = Tape.uncarry(work.guest, work.turn, step.id)
          notice(state, "answer", row.id)

        {:error, reason} ->
          not_written(state, step, reason)
      end
    else
      {:error, _reason} -> state
    end
  end

  defp post(%{work: work} = state, row) do
    {context, read} = if state.fresh?, do: context(work, {:before, row.seq}), else: {nil, []}

    with {:ok, %{step: step}} <- carry(work, "post", row.id, [row | read]) do
      command =
        %{
          "t" => "post",
          "id" => step.id,
          "work" => work.turn.id,
          "content" => [%{"type" => "text", "text" => row.content || ""}],
          "context" => context
        }
        |> reject_nil()
        |> with_files(work, row)

      case write(state, command) do
        :ok ->
          %{state | outstanding: %{id: step.id, input?: true, deliver: "post"}, fresh?: false}

        {:error, reason} ->
          not_written(state, step, reason)
      end
    else
      {:error, _reason} -> state
    end
  end

  # The post's files after its text, in its order, each as the API path
  # makes its block for the media types the wire carries
  # (`Aqua.Loop.Turn.file_block/2`), which has no member for the file's
  # name. A file never refuses the post: one whose block would take the
  # line past the wire's bound is named as too large instead, and the post
  # goes with the rest; one whose bytes are gone is left out. A line's
  # bytes are its command's JSON, so a block adds its own and a comma.
  # Each file ends as its block or its notice, so a block is taken only
  # while the files after it still fit beside it, each by the smaller of
  # the two: a notice never stands in for a smaller block, and the post's
  # line passes the bound only when its text and those smaller ones alone
  # do.
  defp with_files(command, work, row) do
    files =
      Aqua.Attachments.load(work.guest, row.thread_id, Aqua.Attachments.attachments_of([row]))

    types = Opus.Brain.media_types()
    max = Opus.Brain.max_line_bytes()
    notices = Enum.map(files, &too_large/1)

    reserved =
      files
      |> Enum.zip(notices)
      |> Enum.map(fn {file, notice} ->
        block = file |> Aqua.Loop.Turn.file_block(types) |> Map.delete("filename")
        min(entry_bytes(block), entry_bytes(notice))
      end)
      |> Enum.sum()

    {blocks, _room} =
      files
      |> Enum.zip(notices)
      |> Enum.map_reduce({byte_size(Jason.encode!(command)), reserved}, &fit(&1, &2, types, max))

    Map.update!(command, "content", &(&1 ++ blocks))
  end

  # One file's block, or its notice, beside `bytes` taken so far and the
  # room `reserved` for the files after it.
  defp fit({file, notice}, {bytes, reserved}, types, max) do
    block = file |> Aqua.Loop.Turn.file_block(types) |> Map.delete("filename")
    reserved = reserved - min(entry_bytes(block), entry_bytes(notice))

    if bytes + entry_bytes(block) + reserved <= max,
      do: {block, {bytes + entry_bytes(block), reserved}},
      else: {notice, {bytes + entry_bytes(notice), reserved}}
  end

  defp entry_bytes(block), do: byte_size(Jason.encode!(block)) + 1

  defp too_large(%{"filename" => name, "media_type" => media}),
    do: %{
      "type" => "text",
      "text" =>
        "The file #{name} (#{media}) is attached, and it is too large to hand to this program."
    }

  # One recovery prompt, attempted once: for a post the transcript holds,
  # to go on with it or say where it stands; for a result its ask can no
  # longer take, the call named and what it answered; for a session
  # started anew in the middle of the work (`"fresh"`), the thread so far
  # with what the work's calls answered, which are not run again.
  defp notice(%{work: work} = state, kind, row_id) do
    {context, read} =
      if kind == "fresh", do: context(work, {:all, answers(work)}), else: {nil, []}

    case carry(work, "notice", row_id, read) do
      {:ok, %{step: step, row: row}} ->
        command =
          %{
            "t" => "post",
            "id" => step.id,
            "work" => work.turn.id,
            "content" => [%{"type" => "text", "text" => notice_text(work, kind, row)}],
            "context" => context
          }
          |> reject_nil()

        case write(state, command) do
          :ok ->
            %{
              state
              | outstanding: %{id: step.id, input?: true, deliver: "notice"},
                fresh?: state.fresh? and kind != "fresh"
            }

          {:error, reason} ->
            not_written(state, step, reason)
        end

      # A notice was attempted for this row already: no second follows.
      {:error, :carried} ->
        fail(state, uncertain_line(work))

      {:error, _reason} ->
        state
    end
  end

  defp renotice(state, %{row: row_id}), do: notice(state, "answer", row_id)

  # Each says what the work is known to have reached, never why it was
  # interrupted: the driver's end, a lost line and CYFR's restart read
  # alike here.
  defp notice_text(_work, "post", _row),
    do:
      "Your work on the last message was interrupted, and you already have that message. " <>
        "Go on with it, or say where it stands."

  defp notice_text(_work, "fresh", _row),
    do:
      "Your work was interrupted and you no longer had your record of this thread, so the " <>
        "thread so far is above, with what your calls in this work answered; they are not " <>
        "run again. Go on with the last message, or say where it stands."

  defp notice_text(_work, _answer, row) do
    payload = Tape.payload(row)

    "Your work was interrupted before your call #{payload["name"]} " <>
      "(#{payload["tool_call_id"]}) was answered, so its answer comes as this message " <>
      "instead. It answered" <>
      if(payload["is_error"], do: " with an error: ", else: ": ") <>
      (row.content || "")
  end

  # What the rows a delivery carries bring in joins the turn first: the
  # threads they and their files carry and the read threads of the turns
  # whose words they are.
  defp carry(work, deliver, row_id, rows \\ []) do
    Tape.carry(work.guest, work.turn, %{
      deliver: deliver,
      row_id: row_id,
      generation: work.generation,
      silence_ms: Opus.Brain.silence_ms(),
      threads: Tape.carried_threads(rows),
      threads_from: rows |> Tape.writing_turns() |> Enum.reject(&(&1 == work.turn.id))
    })
  end

  # A command refused before it was written: its delivery is taken back,
  # and the turn ends when its work may not be written to any more.
  defp not_written(state, _step, :uncertain), do: state

  defp not_written(%{work: work} = state, step, refused) do
    _ = Tape.uncarry(work.guest, work.turn, step.id)

    case refused do
      :busy ->
        state

      {:not_admitted, _reason} ->
        fail(shut(state), "#{work.title} may not go on with this work any more.")

      _not_now ->
        state
    end
  end

  # The thread so far for a fresh session, the newest that fit: its posts
  # before a post (`{:before, seq}`), or every post and the result rows
  # of the open work's asks (`{:all, ids}`), for one started anew in the
  # middle of it. It opens saying it is context only, and when older posts
  # are left out one line says how many, in room kept for it.
  defp context(work, bound) do
    case Tape.projection(work.guest, work.turn) do
      {:ok, rows} ->
        readable = rows |> Enum.filter(&read?(work, &1, bound)) |> Enum.reverse()

        room =
          @context_bytes - encoded_bytes(@context_opening) -
            encoded_bytes(left_out(length(readable)) <> @context_separator)

        kept =
          readable
          |> Enum.reduce_while({[], 0}, fn read, {kept, size} ->
            line = line(work, read)
            taken = size + encoded_bytes(line) + encoded_bytes(@context_separator)

            if taken > room,
              do: {:halt, {kept, size}},
              else: {:cont, {[{read, line} | kept], taken}}
          end)
          |> elem(0)

        context_of(readable, kept)

      {:error, _} ->
        {nil, []}
    end
  end

  defp context_of([], _kept), do: {nil, []}

  defp context_of(readable, kept) do
    lines =
      case length(readable) - length(kept) do
        0 -> Enum.map(kept, &elem(&1, 1))
        dropped -> [left_out(dropped) | Enum.map(kept, &elem(&1, 1))]
      end

    {[%{"type" => "text", "text" => @context_opening <> Enum.join(lines, @context_separator)}],
     Enum.map(kept, &elem(&1, 0))}
  end

  defp left_out(1), do: "[1 earlier post of the thread is not shown here.]"
  defp left_out(n), do: "[#{n} earlier posts of the thread are not shown here.]"

  defp read?(_work, row, {:before, seq}), do: context_row?(row, seq)

  defp read?(_work, row, {:all, answers}),
    do: row.kind in @context_kinds or (row.kind == "tool_result" and row.id in answers)

  # The result rows of the open work's asks that closed, never its start's.
  defp answers(work) do
    start = Tape.brain_start_key(work.turn.id)

    case Tape.steps(work.guest, work.turn) do
      {:ok, steps} ->
        for %{purpose: "brain", kind: kind, result_message_id: id} = step <- steps,
            kind != "input" and step.idempotency_key != start and is_binary(id),
            do: id

      {:error, _unread} ->
        []
    end
  end

  # The bytes `text` takes inside a JSON string on the line, as the wire
  # encodes it: escaping is the characters' own, so a text's parts add up.
  defp encoded_bytes(text), do: byte_size(Jason.encode!(text)) - 2

  defp line(_work, %{kind: "tool_result"} = row),
    do: "Your call #{Tape.payload(row)["name"]} answered: #{row.content}"

  defp line(work, row), do: "#{author(work, row)}: #{row.content}"

  # A person's row names them by its author, their id; its `sent_by` is
  # only "person".
  defp author(work, %{sent_by: agent}) when agent == work.agent, do: work.title

  defp author(_work, %{author: author}) when is_binary(author) do
    if author in Prima.Author.reserved(),
      do: "CYFR",
      else: Sanctum.Tenancy.Users.display_name(author)
  end

  defp author(_work, _row), do: "CYFR"

  # ---------------------------------------------------------------------------
  # Its end, and the clock

  defp ended(state, reason) when reason in [:closed, :replaced, :forgotten],
    do: {:noreply, reply_waiting(%{state | phase: :closed}, {:error, "the session was closed"})}

  # A start the driver could not honour ends its process: the thread says
  # so, the turn ends, and the same start is not made again by itself.
  defp ended(%{phase: phase, work: work} = state, _reason) when phase in [:opening, :starting],
    do: {:noreply, fail(%{state | phase: :closed}, "#{work.title} could not start.")}

  defp ended(%{work: work} = state, _reason) do
    state = %{state | phase: :closed}

    case open_turn(work) do
      %{status: "running"} -> {:noreply, open(%{state | recovering?: true})}
      _paused_or_none -> {:noreply, state}
    end
  end

  # Whether the silence ran out, by the database's clock: the open turn's
  # job ends, saying so; a session with no turn open is closed. The work's
  # turn is read first, so a turn that ended unreleased is not failed again
  # and a session with a turn of its thread waiting is never closed
  # (`Arca.TurnStorage.brain_silence/2`).
  defp silence(%{work: nil} = state), do: {:noreply, state}

  defp silence(state) do
    %{work: work} = state = settled(state)

    case Tape.brain_silence(work.guest, state.thread_id) do
      {:ok, %{expired?: true}} ->
        if open_turn(work) do
          minutes = div(Opus.Brain.silence_ms(), 60_000)

          {:noreply,
           fail(
             shut(state),
             "#{work.title} said nothing for #{minutes} minutes, so its work here ended."
           )}
        else
          {:stop, :normal, shut(state)}
        end

      _running_or_paused ->
        {:noreply, arm(state)}
    end
  end

  # The work's turn as its row reads now, when the loop last said it was
  # open: one that ended is over here too.
  defp settled(%{work: %{turn: %{id: id}} = work} = state) do
    with %{} <- open_turn(work),
         {:ok, turn} <- Tape.turn(work.guest, id),
         true <- Tape.terminal?(turn) do
      %{state | work: %{work | turn: Map.put(work.turn, :status, "over")}}
    else
      _open_or_unread -> state
    end
  end

  defp settled(state), do: state

  defp arm(%{work: nil} = state), do: state

  defp arm(%{work: work, timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)

    case Tape.brain_silence(work.guest, state.thread_id) do
      {:ok, %{due_ms: due}} when is_integer(due) ->
        %{state | timer: Process.send_after(self(), :silence, due)}

      _paused ->
        %{state | timer: nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Telling the loop

  defp tell(%{loop: nil} = state, _message), do: state

  defp tell(%{loop: loop} = state, message) do
    send(loop, message)
    state
  end

  # The open turn ends with `sentence`, which the loop writes in the
  # thread; whoever waits on the work's start is answered it.
  defp fail(%{work: work} = state, sentence) do
    state = reply_waiting(state, {:error, sentence})

    case open_turn(work) do
      %{id: id} -> tell(state, {__MODULE__, id, {:ended, {:failed, sentence}}})
      nil -> state
    end
  end

  defp reply_waiting(%{waiting: waiting} = state, answer) do
    Enum.each(waiting, &GenServer.reply(&1, answer))
    %{state | waiting: []}
  end

  defp system_row(work, text) do
    Tape.append(work.guest, work.turn.thread_id, %{
      author: Prima.Author.system(),
      sent_by: work.agent,
      kind: "system",
      content: text,
      turn_id: work.turn.id,
      execution_id: work.turn.root_execution_id
    })
  end

  defp reject_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
