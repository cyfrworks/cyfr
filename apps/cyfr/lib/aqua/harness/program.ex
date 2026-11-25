# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Harness.Program do
  @moduledoc """
  The harness of a turn on a program (`Aqua.Harness`): the turn's
  attendant, the one process that takes what the turn's session
  (`Opus.Brain`) says and writes what Aqua owes it. The loop holds its
  pid as the handle and knows nothing else of it.

  ## One lifetime

  It lives while a loop holds the turn. When the loop returns, at an end
  or at a pause, the loop stops it (`stop/1`): it closes the session and
  waits for the answer (`Opus.Brain.close/1`), ok being the place back,
  and what is unanswered Opus still owes. A start carries no word of a
  place: it opens at once and is admitted or refused on what is true
  then. A loop that dies has the session closed by this process, which
  watches it, and Stop stops it once the turn's fence moved and before
  the work stops. A later turn's open of the thread's session ends this
  one's first (`Opus.Brain`), so no two drivers run one native session.
  The native session stays in the program's folder, and the next turn's
  process, or a paused turn's next loop, resumes it.

  A turn whose agent names a program row opens with the host's
  `program.start` of that row, which `open/1` answers for the loop to
  decide as a model's `program.start` is decided. Opened again with that
  step admitted, it starts this process, which opens a session, hands the
  driver the turn's scrolls one at a time, each placed where its program
  looks for skills or yielded (a scroll the driver could not write ends
  the work naming it, with nothing started), starts or resumes the
  harness with the turn's instructions, which name the placed scrolls as
  its program lists them and index the rest (`Aqua.Prompt.program/3`),
  and configuration
  and sets the turn's work (`work`, with the turn's tools); the loop is
  told when the work is taken (`{:took, ...}`). Every start names the
  turn's tools too, a resume's among them: a harness that keeps its
  session's tools for the session's life (Codex) takes a new session's
  there alone, so a tool a later turn adds is not one it can call and one
  a later turn lacks is still refused at CYFR's gate, and one given its
  tools again at a resume (an ACP program) takes the turn's there. A start
  the program says is
  signed out is given no post, and no new native session of it is kept.
  The first post a process is written carries the turn's facts
  (`Aqua.Prompt`), since its instructions hold nothing that moves by
  itself. The turn's loop decides and runs the steps this process
  proposes with its own code and never reads the session itself. Every
  write of this process presents the fence the loop acquired, never one
  read again from the turn's row.

  The holder hands this process the driver's lines a batch at a time.
  Their effects (the posts the program said in the open turn's work, the
  asks it made, the deliveries the driver took or refused, the posts its
  `idle` answered, its usage) commit with the batch's position in one
  transaction (`Arca.TurnStorage.commit_events/3`), and only then is the
  holder told to read on. An ask of the open turn becomes a proposed step
  of purpose `brain`, recorded once by the native ask's id on a running
  or a paused turn, and the loop is told; an ask of other work, or of
  none, is no step and cannot be answered under this session's
  binding, so it is refused by closing the session, and the turn
  ends saying why. What the program says of no work stays out of the
  thread.

  Its text of the open work is announced to the thread's viewers as it is
  written, never stored (`Aqua.Loop.Stream`), once its batch committed:
  each native message streams as a step of its own, settled by its `said`
  row and withdrawn when no row will land, at its native turn's end or
  the session's. Its own tools of the open work, by the name it gives,
  are told to the turn's loop as they start and end, which shows them in
  the one list of what runs (`Aqua.Loop`); nothing of them is stored. The
  native turn's `idle` and the session's end are told the same way, and
  the loop settles what still shows running then, while a call runs too.

  It writes a command when one is owed, one at a time, as one view of its
  rows says each time the loop says they moved (`moved/1`): a recovery
  prompt its rows owe, then a closed ask's result as its `answer` and then
  each post of the open turn that waits, each first recorded as an `input`
  step (`carry/3`) whose id the command carries, so a delivery is attempted once whatever restarts
  follow. A post and a fresh session's context are in the words
  `Aqua.Reader` gives an API request, and what they bring in joins the
  turn before it is read. A post carries its files after its text as the
  API path words them (`Aqua.Loop.Turn.file_block/2`), an image or a PDF
  as itself where the wire carries its type; a file never refuses a
  post, and one past
  the line's bound is named as too large to hand over.
  `accepted` says the write was taken and nothing more: a post's
  obligation ends when an `idle` names it. A post the driver answers
  `later` was not written, its harness taking a message only between its
  native turns: it is held, its step and id kept, after every post held
  before it, none replacing another. Meanwhile an answer owed is written
  at once, as is the notice of an answer the harness refused, and every
  other post and recovery prompt waits behind the held ones. Once an
  `idle` ends the native turn, each held is written again as it was, in
  the order first answered `later`, one at a time; one answered `later`
  again stays first, and it and every one behind it wait for the next
  idle, so none overtakes an earlier one. The turn is not done while one
  waits. A session that
  ends meanwhile gives each back to the posts that wait, in order
  (`Aqua.Tape.uncarry/3`), so the next start does not name it pending and
  delivers it anew. A restart of CYFR while one is held loses that the
  program never took it: the next start names it pending, and the turn
  ends uncertain, the post never written again, unless the resume answers
  `gone`: then the fresh start's prompt carries the thread, the post in
  it, written once. A write that may have reached the driver, its answer
  lost, keeps its step and is never sent again: the session closes and
  recovery reconciles it.

  ## Recovery

  After the holder's or the driver's end at work, each time, and for a
  turn a loop continues, the next start resumes the native
  session, naming as `pending` the turn's posts owed an answer. A continued
  turn whose program had answered all it was given starts none and is done. A resume
  replays nothing and goes on with nothing by itself, so each post its
  transcript holds is continued by one recovery prompt (a `notice`,
  attempted once), and each it does not hold is uncertain: never sent
  again, the thread says so, and the turn ends failed. An answer whose
  ask the resumed session no longer holds is told as one notice that names
  the call; the recorded tool step is never run again. The prompts owed
  are rows (`Arca.TurnStorage.reconcile_brain/3`), each obligation kept
  until its prompt's own step is recorded, so a restart between the two
  loses none. A start lasts until the work is taken: a driver that ends
  before ends the turn, which says so, and that start is not made again
  by itself. A transcript the harness no longer has (`gone`) is forgotten:
  the thread says the program starts over, and it does, with the thread's
  posts as its context; in the middle of the work, one recorded prompt
  carries the thread so far and what the work's calls answered, none of
  which runs again.

  ## A post deleted before it was handed over

  A post goes with the workspace thread it names. One that opened the
  turn, or that went as the loop read it, which hands it over withheld,
  ends the turn saying so. One that went before the loop read it, or
  after and before its delivery was recorded, owes nothing: when the
  program was already idle, the turn completes, so no turn waits for
  good.

  ## Its end

  It tells the loop how the work ended, `t:finish/0`: a reason, never a
  sentence, which the loop words (`Prima.Refusal`). A failed commit, a
  failed read or write of what is owed, a session forgotten or replaced
  and a command the wire does not take each end the turn and replay
  nothing, so no turn waits on what will not come.

  ## The clock

  One clock, the `program_silence_ms` setting (`Opus.Brain.silence_ms/0`,
  thirty minutes), ends the work. Over a start it runs from the open until
  the work is taken, whatever the driver says meanwhile, and ends it as a
  start that failed, an open still out among it. At work it runs
  whenever the program owes something, a delivery's acknowledgement among
  it, and is kept in the thread's `brain_progress`, read by the database's
  clock; each process's hello starts a whole interval. A timer's message
  names its timer, and a stale one is nothing.
  """

  use GenServer, restart: :temporary

  @behaviour Aqua.Harness

  require Logger

  alias Aqua.{Reader, Tape}

  @sessions Aqua.Harness.Sessions
  # All the engine reads of this harness (`Aqua.Harness`): its process is
  # not the root's child, so a launch need not wait for it, and a post
  # written while it works is delivered, never a reason to skip a call.
  @facts %{supersedes?: false, own_tools?: true}
  # The most bytes a fresh session's context takes on its post's line, as
  # the line's JSON measures them, escapes included: the newest posts that
  # fit. A post a sender writes is at most 32 KiB, at most six times that
  # escaped, so its line with this context and its files' notices stays
  # within the wire's bound (`Opus.Brain.max_line_bytes/0`).
  @context_bytes 512 * 1024
  # How a fresh session's context opens, and what separates two posts.
  @context_opening "The thread so far, oldest first, as context only: nothing in it is to be " <>
                     "done again because it is shown here.\n\n"
  # How a resumed session's context of what it missed opens.
  @missed_opening "What was said in this thread since you last read it, oldest first, as " <>
                    "context only: nothing in it is to be done again because it is shown here.\n\n"
  @context_separator "\n\n"
  # The kinds of row a fresh session's context carries: the thread's posts.
  @context_kinds ~w(text opening report nudge pointer turn_aborted)
  # The phases of a start, which lasts until the work is taken.
  @starting [:opening, :scrolling, :starting, :started, :working]
  # The batch's effects that are events of the one writer
  # (`Arca.TurnStorage.commit_events/3`), by the event each is.
  @written %{said: :text, asks: :ask, accepted: :took, refused: :refused, usage: :usage}
  # A holder's refusals of a write after which it ends: its end follows.
  @ending [:ended, :not_written, :unavailable]

  # ===========================================================================
  # The boundary (`Aqua.Harness`)
  # ===========================================================================

  @doc """
  Open the turn's program. With no admitted step it answers the host's
  `program.start` of the turn's row at its epoch, for the loop to decide
  (`{:admit, call}`), once what the program is first given joined the
  turn and a session stored with another row was forgotten; or why the
  turn ends before it starts. With the admitted step it starts this
  turn's attendant, watching the loop that called, and answers at once:
  a start that was taken already goes on with its native session, and
  one not yet taken opens it.
  """
  @impl Aqua.Harness
  def open(%{admitted: nil} = work), do: work |> with_generation() |> admit()

  def open(%{admitted: %{} = start} = work) do
    work = work |> with_generation() |> Map.put(:start, start.id)

    case DynamicSupervisor.start_child(@sessions, {__MODULE__, {work, self()}}) do
      {:ok, pid} -> {:ok, pid, @facts}
      {:error, _reason} -> {:end, refused(work, :start_failed)}
    end
  end

  # The thread's session generation as stored now, which the work keeps
  # when the thread cannot be read again: the one the turn was built with.
  defp with_generation(%{spec: spec} = work) do
    case Tape.brain(work.guest, work.turn.thread_id) do
      {:ok, %{generation: generation}} -> Map.put(work, :generation, generation)
      {:error, _} -> Map.put(work, :generation, spec.thread.brain_generation)
    end
  end

  @doc "The turn's rows moved: what the program is owed is read from them (`deliver/1`)."
  @impl Aqua.Harness
  def moved(attendant) when is_pid(attendant), do: GenServer.cast(attendant, :moved)

  @doc """
  The turn is held no longer, or is stopped: its session is closed, its
  writes first, and this answers once Opus answered the close.
  """
  @impl Aqua.Harness
  def stop(attendant) when is_pid(attendant) do
    GenServer.call(attendant, :close, :infinity)
  catch
    :exit, _ -> :ok
  end

  @doc "What the engine reads of this harness (`Aqua.Harness.facts/1`)."
  @impl Aqua.Harness
  def facts, do: @facts

  @doc false
  def start_link(attending), do: GenServer.start_link(__MODULE__, attending)

  # ===========================================================================
  # The admission
  # ===========================================================================

  # The host's `program.start` of the turn's program row at its epoch,
  # recorded with its call's `tool_call` row as a model's is (`Opus.Brain`
  # reads the admitting call there).
  defp admit(%{program: %{row: row, epoch: epoch}} = work) do
    args = %{"action" => "start", "program" => row, "epoch" => epoch}
    call = Aqua.Loop.Binding.resolve("program", args, tool_call_id: "start")
    recorded = Aqua.Loop.recorded("program", call)

    # Replay safe: opening again starts a session that resumes the
    # thread's, and sets the work and the configuration it runs with; it
    # never replays an input or a tool's effect, and each write is checked
    # again against the admission (`Opus.Brain`). Before a session's
    # identity is committed, another start may make a fresh session.
    proposal = %{
      kind: recorded.step_kind,
      purpose: "brain",
      tool: "program",
      action: "start",
      recovery: "replay_safe",
      call: %{
        kind: "tool_call",
        content: "program",
        payload: %{
          "tool_call_id" => "start",
          "name" => "program",
          "tool" => "program",
          "action" => "start",
          "arguments" => args,
          "kind" => recorded.kind
        }
      }
    }

    with {:ok, work} <- moved_over(work),
         :ok <- join_startup(work),
         do: {:admit, proposal}
  end

  # A turn whose program is another row than the one the thread's native
  # session is stored with, its member's program moved since: the session
  # is forgotten, the stored row's transcript owed its removal first
  # (`Arca.TurnStorage.forget_session/3`), and the program starts over
  # from the thread's posts, which the thread is told. A moved fence ends
  # nothing here: the loop's own write of the end is refused for it.
  defp moved_over(%{program: %{row: row}} = work) do
    with {:ok, kept} <- Tape.brain(work.guest, work.turn.thread_id),
         %{session: session, generation: generation, progress: %{"row" => stored}}
         when is_binary(session) and stored != row <- kept,
         {:ok, raised} <- Tape.forget_session(work.guest, work.turn, generation),
         {:ok, _row} <-
           Tape.append_line(
             work.guest,
             work.turn,
             "#{work.title} runs on another program now, so it starts over from the " <>
               "thread's posts."
           ) do
      {:ok, %{work | generation: raised}}
    else
      {:error, :superseded} -> {:end, lost(work, :ended)}
      {:error, _unread_or_unkept} -> {:end, refused(work, {:start_failed, :session})}
      _same_row_or_no_session -> {:ok, work}
    end
  end

  # What the program is given before its first answer joins the turn's
  # read threads before its start is decided, as a request's rows join
  # before they are read (`Aqua.Reader.join/5`), so a thread's deletion
  # finds the turn: the turn's posts, and for a thread with no native
  # session the thread so far a fresh session's first post carries. The
  # post that opened the turn is one of those posts until it is handed
  # over. One that is not handed over was deleted with its workspace
  # thread, and a program started without it would wait on it for good:
  # the turn ends saying so.
  defp join_startup(%{turn: turn} = work) do
    with {:ok, posts} <- Tape.brain_posts(work.guest, turn),
         {:ok, context} <- startup_context(work, posts),
         {:ok, %{rows: handed}} <- Reader.join(work.guest, turn, posts ++ context) do
      if Enum.any?(handed, &(&1.id == turn.message_id)),
        do: :ok,
        else: {:end, refused(work, {:post_refused, :gone})}
    else
      {:error, _unread} -> {:end, refused(work, {:start_failed, :session})}
    end
  end

  defp startup_context(work, [first | _]) do
    case Tape.brain(work.guest, work.turn.thread_id) do
      {:ok, %{session: nil}} ->
        with {:ok, rows} <- Tape.projection(work.guest, work.turn),
             do: {:ok, Enum.filter(rows, &context_row?(&1, first.seq))}

      {:ok, _resumed} ->
        {:ok, []}

      {:error, _} = unread ->
        unread
    end
  end

  defp startup_context(_work, []), do: {:ok, []}

  defp context_row?(row, seq), do: row.kind in @context_kinds and row.seq < seq

  # ===========================================================================
  # The attendant
  # ===========================================================================

  @impl true
  def init({work, loop}) do
    Process.monitor(loop)

    state = %{
      thread_id: work.turn.thread_id,
      agent: work.agent,
      work: work,
      loop: loop,
      brain: nil,
      boot: nil,
      # Nothing is opened before the loop's first word, which comes once
      # its handle is where Stop looks (`Aqua.Loop`).
      phase: :unopened,
      outstanding: nil,
      # The posts the driver answered `later`, in the order first answered
      # so, each with whether the native turn it waits on is idle since
      # (`held/2`).
      later: [],
      # The start's scrolls still to hand, the one handed last, and those
      # its driver placed, each its name and the name its program lists it
      # by (`write_scrolls/1`).
      to_place: [],
      scrolling: nil,
      placed: [],
      # The start's scrolls its driver kept out because its program has its
      # own by their names or its places could not be read: said in the
      # turn's activity. A driver that places none keeps none so.
      kept: [],
      fresh?: false,
      missed?: false,
      facts?: false,
      how: :went_on,
      recovering?: false,
      pending: [],
      timer: nil,
      streams: %{},
      ordinal: 0
    }

    {:ok, state}
  end

  # The loop that closes it waits on it no more and is told nothing.
  @impl true
  def handle_call(:close, {caller, _tag}, state) do
    state = if caller == state.loop, do: %{state | loop: nil}, else: state
    {:stop, :normal, :ok, shut(state)}
  end

  # The loop's word that the turn's rows moved (`Aqua.Harness`): what is
  # owed is what the rows say, read again each time (`deliver/1`).
  @impl true
  def handle_cast(:moved, state), do: {:noreply, nudged(state)}

  # The loop says the rows moved whenever the thread moved or it waits
  # again: its first word opens the session, a start the program took
  # already going on with its native session; a session ready is written
  # the next owed, and one that owes nothing more and is idle ends the
  # turn; a start not yet made, its turn paused, is made now.
  defp nudged(%{phase: :unopened, work: %{admitted: %{dispatch_state: "closed"}}} = state),
    do: continued(state)

  defp nudged(%{phase: :unopened} = state), do: open_session(state)
  defp nudged(%{phase: :over} = state), do: state
  defp nudged(%{phase: :ready} = state), do: state |> deliver() |> rested()
  defp nudged(%{phase: :closed, brain: nil} = state), do: continued(state)
  defp nudged(state), do: state

  @impl true
  def handle_info({Opus.Brain, ref, {:lines, boot, lines}}, %{brain: {_pid, ref}} = state),
    do: {:noreply, batch(state, boot, lines)}

  def handle_info({Opus.Brain, ref, {:ended, reason}}, %{brain: {_pid, ref}} = state),
    do: {:noreply, session_lost(state, reason)}

  def handle_info({Opus.Brain, _stale, _message}, state), do: {:noreply, state}

  def handle_info({:timeout, timer, :silence}, %{timer: timer} = state),
    do: {:noreply, silence(%{state | timer: nil})}

  # A timer cancelled or replaced since its message was sent.
  def handle_info({:timeout, _stale, :silence}, state), do: {:noreply, state}

  # The loop that held the turn died: nothing holds it.
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, %{loop: pid} = state),
    do: {:stop, :normal, shut(%{state | loop: nil})}

  # A holder that was killed tells nobody. One that ended told first, so
  # only such a holder is still this session's here.
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, %{brain: {pid, _ref}} = state),
    do: {:noreply, session_lost(state, :exited)}

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

  # ---------------------------------------------------------------------------
  # The session

  # A start arms its clock and opens at once: an open that answers after
  # the clock ended finds that message waiting, ahead of any line.
  defp open_session(%{work: work} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = :erlang.start_timer(Opus.Brain.silence_ms(), self(), :silence)
    state = %{state | timer: timer}

    case Opus.Brain.open(bound(work)) do
      {:ok, {holder, _handle} = brain} ->
        Process.monitor(holder)
        %{state | brain: brain, phase: :opening}

      # A paused turn starts nothing: its loop says when it goes on.
      {:error, {:not_admitted, :paused}} ->
        %{state | phase: :closed}

      {:error, reason} ->
        fail(state, refused_open(work, reason))
    end
  end

  defp refused_open(work, {:not_admitted, :generation_moved}), do: lost(work, :forgotten)
  defp refused_open(work, {:not_admitted, _reason}), do: refused(work, :not_admitted)

  # The backends refused for want of room, at its owner's hold or at the
  # session's open: the person reads why, not that the program is away.
  defp refused_open(work, {:refused, :capacity, _boot}), do: refused_open(work, :capacity)
  defp refused_open(work, :capacity), do: {:refused, {:program_full, work.title}}
  defp refused_open(work, _unavailable), do: refused(work, :unreached)

  defp refused(work, kind), do: {:refused, {:harness, work.title, kind}}

  defp start_failed(work, {:exited, why}), do: {:start_failed, why, again(work)}
  defp start_failed(work, :restarted), do: {:start_failed, :restarted, again(work)}
  defp start_failed(_work, _unsaid), do: :start_failed

  # What starts the member again where its failed start is read
  # (`Prima.Refusal`): a message in its thread, asking a crew member for
  # its job again, or nothing the reader can give a schedule's or another
  # source's turn again from there.
  defp again(%{turn: %{request_id: request}}) when is_binary(request), do: :ask
  defp again(%{turn: %{origin: "interactive"}}), do: :message
  defp again(_work), do: :none
  defp lost(work, kind), do: {:lost, {:harness, work.title, kind}}
  defp signed_out(work), do: {:refused, {:crew_unready, work.title, :signed_out}}

  # The store did not answer for what the turn is owed or said.
  defp unkept(%{work: work} = state), do: fail(shut(state), lost(work, :write_failed))

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

  # Every line the program is handed is delivered (`Aqua.Reader.deliver/2`):
  # every text in it read without the thread's mark, the engine's frames and
  # rule then given it. The one place a line passes before it leaves.
  defp write(%{brain: brain, work: work}, command),
    do:
      Opus.Brain.write(
        brain,
        bound(work),
        Reader.deliver(command, Reader.mark(work.turn.thread_id))
      )

  # Every start is handed the turn's scrolls first, one `scroll` at a time
  # and each answered before the next: `placed` where its program looks for
  # skills, `yielded` to the model's harness's way, or `refused`, which
  # ends the work naming the scroll with nothing started, so no start runs
  # with part of the set. Then the start, whose instructions name the
  # placed as its program lists them and index the rest
  # (`Aqua.Prompt.program/3`); those yielded for a program's own of their
  # names, or for places its driver could not read, are said in the turn's
  # activity.
  # A start the wire would not take (an option, its instructions or its
  # tools) is refused before its scrolls, so it writes nothing.
  defp write_scrolls(%{work: work} = state) do
    if Opus.Brain.writable?(start_command(work, nil, [], work.system)),
      do: scrolls(state),
      else:
        fail(shut(state), refused(work, {:start_unfit, work.config |> Map.keys() |> Enum.sort()}))
  end

  defp scrolls(%{work: work} = state),
    do:
      scroll(%{
        state
        | phase: :scrolling,
          placed: [],
          kept: [],
          to_place: Enum.with_index(work.scrolls.entries)
      })

  defp scroll(%{to_place: []} = state) do
    case state.kept do
      [] -> write_start(state)
      kept -> state |> tell({:activity, {:yielded, kept}}) |> write_start()
    end
  end

  defp scroll(%{to_place: [{entry, i} | rest], work: work} = state) do
    id = "#{work.start}:scroll:#{i}"

    command = %{
      "t" => "scroll",
      "id" => id,
      "name" => entry.name,
      "description" => entry.description,
      "body" => entry.body
    }

    case write(state, command) do
      :ok -> %{state | to_place: rest, scrolling: {id, entry.name}}
      {:error, :unreadable} -> fail(shut(state), refused(work, {:scroll_unplaced, entry.name}))
      {:error, reason} -> write_failed(state, reason)
    end
  end

  # The scroll handed last is answered: the next is handed, or the start.
  defp on_scrolls(%{phase: :scrolling, scrolling: {id, name}, work: work} = state, effects) do
    cond do
      placed = List.keyfind(effects.placed, id, 0) ->
        as = elem(placed, 1)

        if listed_as?(as, name),
          do: scroll(%{state | scrolling: nil, placed: state.placed ++ [{name, as}]}),
          else: fail(shut(state), refused(work, {:scroll_unplaced, name}))

      yielded = List.keyfind(effects.yielded, id, 0) ->
        kept = if elem(yielded, 1), do: state.kept ++ [name], else: state.kept
        scroll(%{state | scrolling: nil, kept: kept})

      Enum.any?(effects.refused, &(&1["id"] == id)) ->
        fail(shut(state), refused(work, {:scroll_unplaced, name}))

      true ->
        state
    end
  end

  defp on_scrolls(state, _effects), do: state

  # The name a program lists a placed scroll by, which the start's
  # instructions quote: the program's word, so only the scroll's own name,
  # or a plain namespace, `:` and it (Claude Code's `cyfr:<name>`), is
  # taken.
  defp listed_as?(as, name),
    do: as == name or Regex.match?(~r/\A[A-Za-z0-9_-]+:#{Regex.escape(name)}\z/, as)

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
      {:error, _unanswered} -> fail(shut(state), refused(work, {:start_failed, :session}))
    end
  end

  defp pending(_work, nil), do: {:ok, []}
  defp pending(work, _session), do: Tape.brain_pending(work.guest, work.turn)

  # Every start names the work's tools beside the work's own: a harness
  # whose session keeps the tools it started with for its life (Codex)
  # takes a new session's here and nowhere else, one given its tools again
  # at a resume (an ACP program) takes them here at each start, and one
  # that takes each work's (Claude Code) reads them from the `work`.
  defp write_start(%{work: work} = state, session, pending) do
    command =
      start_command(
        work,
        session,
        pending,
        Aqua.Prompt.program(work.system, work.scrolls, state.placed)
      )

    case write(state, command) do
      :ok ->
        %{
          state
          | phase: :starting,
            pending: pending,
            fresh?: session == nil,
            missed?: session != nil,
            facts?: true
        }

      # The wire takes no such start: a startup option of the work's, its
      # instructions or its tools are not what the harness takes. Nothing
      # was written, and the work ends saying so.
      {:error, :unreadable} ->
        options = work.config |> Map.keys() |> Enum.sort()
        fail(shut(state), refused(work, {:start_unfit, options}))

      {:error, reason} ->
        write_failed(state, reason)
    end
  end

  defp start_command(work, session, pending, system) do
    %{
      "t" => "start",
      "gen" => work.generation,
      "config" => work.config,
      "system" => system,
      "session" => session,
      "pending" => if(pending != [], do: pending),
      "tools" => work.tools
    }
    |> reject_nil()
  end

  defp write_work(%{work: work} = state) do
    command = %{"t" => "work", "id" => work.start, "work" => work.turn.id, "tools" => work.tools}

    case write(state, command) do
      :ok -> %{state | phase: :working}
      {:error, reason} -> write_failed(state, reason)
    end
  end

  # A start's write that may have reached the driver fails the start,
  # which is not made again; one refused before writing says why the work
  # ends.
  defp write_failed(%{work: work} = state, :uncertain),
    do: fail(shut(state), refused(work, :start_failed))

  defp write_failed(%{work: work} = state, {:not_admitted, :generation_moved}),
    do: fail(shut(state), lost(work, :forgotten))

  defp write_failed(%{work: work} = state, _refused),
    do: fail(shut(state), refused(work, :work_refused))

  defp shut(%{brain: nil} = state), do: withdraw(state)

  # `:unanswered` is Opus's to close: nothing here holds the place.
  defp shut(%{brain: brain} = state) do
    _closed_or_owed = Opus.Brain.close(brain)

    phase = if state.phase == :over, do: :over, else: :closed

    %{state | brain: nil, boot: nil, phase: phase, outstanding: nil}
    |> release()
    |> withdraw()
    |> session_ended()
  end

  # The session ended: none of the turn's own tools runs any more, which
  # the loop settles in its list (`Aqua.Loop`).
  defp session_ended(state),
    do: tell(state, {:activity, :session_ended})

  # ---------------------------------------------------------------------------
  # Lines

  # What the open turn has used, once the batch's usage is committed: the
  # loop tells the thread as the rows count it (`Aqua.Tape.usage/2`).
  defp tell_usage(state, []), do: state
  defp tell_usage(state, usage), do: tell(state, {:usage, usage})

  defp batch(%{work: work} = state, boot, lines) do
    {last, _event} = List.last(lines)
    events = Enum.map(lines, &elem(&1, 1))
    turn = work.turn
    effects = effects(state, events)
    commit = effects.commit

    progress =
      commit
      |> Map.take([:session, :hello, :busy, :native, :answered])
      |> Map.merge(%{
        generation: work.generation,
        boot: boot,
        seq: last,
        row_id: work.program.row,
        epoch: work.program.epoch,
        silence_ms: Opus.Brain.silence_ms()
      })

    scope = %{
      thread: state.thread_id,
      agent: state.agent,
      turn: %{id: turn.id, fence: turn.fence}
    }

    case Tape.commit_events(work.guest, scope, %{
           events: effects.written,
           position: {:session, progress}
         }) do
      {:ok, committed} ->
        Opus.Brain.read_on(state.brain, boot, last)
        state = %{state | boot: boot}
        state = Enum.reduce(committed.said, state, &tell(&2, {:text, &1}))

        state =
          if committed.asks != [],
            do: tell(state, {:ask, Enum.map(committed.asks, & &1.step)}),
            else: state

        if effects.foreign?,
          do: foreign(state),
          else:
            state
            |> stream(of_work(lines, "text", turn), effects.commit.said)
            |> own(of_work(lines, "own", turn))
            |> tell_usage(effects.commit.usage)
            |> act(effects)
            |> arm()

      # A session the thread forgot is owed its removal from the program's
      # folder by the transaction that forgot it (`Opus.Brain.Cleanup`).
      {:error, :generation_moved} ->
        fail(shut(state), lost(work, :forgotten))

      # The session or the turn is no longer this work's. The loop says
      # nothing where the turn's fence moved.
      {:error, reason} when reason in [:superseded, :row_changed, :not_open] ->
        fail(shut(state), lost(work, :ended))

      {:error, reason} ->
        Logger.warning(
          "[Aqua.Harness.Program] a batch could not be committed: #{inspect(reason)}"
        )

        unkept(state)
    end
  end

  # The batch's events of type `t` that are the turn's work, each with
  # its line's number.
  defp of_work(lines, t, %{id: work_id}),
    do: for({seq, %{"t" => ^t, "work" => ^work_id} = event} <- lines, do: {seq, event})

  # What a batch's events do, judged here: the commit's attrs, and what
  # this process acts on once they are committed.
  defp effects(%{work: work, outstanding: outstanding}, events) do
    work_id = work.turn.id

    init = %{
      commit: %{said: [], asks: [], accepted: [], refused: [], answered: [], usage: []},
      # What the batch writes, in the order of its lines (`put_commit/3`).
      written: [],
      hello?: false,
      started: nil,
      gone?: false,
      accepted: [],
      refused: [],
      placed: [],
      yielded: [],
      idle: nil,
      # The batch's `later`s and idles, in the order of its lines.
      holds: [],
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

  # A start signed out is given no post, so a session new in it holds
  # nothing of the thread, and one it resumed is stored already.
  defp effect(
         %{"t" => "started", "account" => "signed_out"} = event,
         acc,
         _work,
         _work_id,
         _outstanding
       ),
       do: %{acc | started: event}

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
    acc = %{acc | refused: acc.refused ++ [event]}
    if input?(outstanding, id), do: put_commit(acc, :refused, id), else: acc
  end

  # A scroll's answers: where its program lists it, or that it keeps the
  # model's harness's way (`on_scrolls/2`); nothing of either is written.
  defp effect(%{"t" => "placed", "id" => id, "as" => as}, acc, _work, _work_id, _outstanding),
    do: %{acc | placed: acc.placed ++ [{id, as}]}

  defp effect(%{"t" => "yielded", "id" => id} = event, acc, _work, _work_id, _outstanding),
    do: %{acc | yielded: acc.yielded ++ [{id, event["why"]}]}

  # A post the harness takes only between its native turns, which waits
  # for the idle that ends the one it runs: nothing of it is written.
  defp effect(%{"t" => "later", "id" => id}, acc, _work, _work_id, _outstanding),
    do: %{acc | holds: acc.holds ++ [{:later, id}]}

  defp effect(%{"t" => "said", "work" => work_id} = event, acc, _work, work_id, _outstanding),
    do: put_commit(acc, :said, %{message: event["message"], text: event["text"]})

  defp effect(%{"t" => "ask", "work" => work_id} = event, acc, work, work_id, _outstanding),
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
    acc = %{acc | idle: event, holds: acc.holds ++ [:idle]}
    if event["work"] == work_id, do: busy(acc, false), else: acc
  end

  defp effect(%{"t" => "error"} = event, acc, _work, _work_id, _outstanding),
    do: %{acc | errors: acc.errors ++ [event]}

  # Text streamed, the harness's own tools, late prose and asks of other
  # work: nothing is written of them (`stream/3`).
  defp effect(_event, acc, _work, _work_id, _outstanding), do: acc

  defp put_commit(acc, key, value) do
    acc = %{acc | commit: Map.update!(acc.commit, key, &(&1 ++ [value]))}

    case @written[key] do
      nil -> acc
      tag -> %{acc | written: acc.written ++ [{tag, value}]}
    end
  end

  defp busy(acc, busy), do: %{acc | commit: Map.put(acc.commit, :busy, busy)}

  defp input?(%{id: id, input?: true}, id), do: true
  defp input?(_outstanding, _id), do: false

  # An ask of the open turn as the step the host proposes for it, decided
  # by the code that decides a model's call (`Aqua.Loop.recorded/2`), and
  # recorded once by the native ask's id. Its call row is a `tool_call`,
  # as a model's is.
  defp ask(work, %{"ask" => ask, "name" => name, "arguments" => arguments}),
    do: Aqua.Harness.ask(name, arguments, ask, Tape.brain_ask_key(work.turn.id, ask))

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
      tell(state, {:activity, {:own, own_name(name), phase}})
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
  defp act(state, effects) do
    state
    |> on_started(effects)
    |> on_scrolls(effects)
    |> on_answers(effects)
    |> held(effects)
    |> on_errors(effects)
    |> on_idle(effects)
    |> deliver()
  end

  defp on_started(%{phase: :opening} = state, %{hello?: true}), do: write_scrolls(state)

  defp on_started(%{phase: :starting} = state, %{gone?: true}), do: start_over(state)

  defp on_started(%{phase: :starting, work: work} = state, %{
         started: %{"account" => "signed_out"}
       }),
       do: fail(shut(state), signed_out(work))

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
      {:fail, state, finish} -> fail(shut(state), finish)
    end
  end

  defp on_started(state, _effects), do: state

  defp on_answers(%{work: work} = state, effects) do
    Enum.reduce(effects.refused, accepted(state, effects.accepted), fn refusal, state ->
      %{"id" => id, "reason" => reason} = refusal

      cond do
        state.phase == :working and id == work.start ->
          fail(shut(state), turned_away(work, refusal, {:work_refused, reason}))

        match?(%{id: ^id, deliver: "answer"}, state.outstanding) ->
          refused_answer(%{state | outstanding: nil}, effects, state.outstanding)

        match?(%{id: ^id}, state.outstanding) ->
          fail(shut(state), turned_away(work, refusal, {:post_refused, reason}))

        true ->
          state
      end
    end)
  end

  # An answer the harness refused goes as a notice only while the work
  # goes on: never once it ended, nor in the batch that ends it, whose
  # error or stop is read after its answers.
  defp refused_answer(%{phase: :ready, work: work} = state, effects, answer) do
    if ends?(effects, work.turn.id), do: state, else: renotice(state, answer)
  end

  defp refused_answer(state, _effects, _answer), do: state

  defp ends?(%{errors: [_ | _]}, _turn_id), do: true
  defp ends?(%{idle: %{"work" => id, "stop" => stop}}, id), do: stop != "end_turn"
  defp ends?(_effects, _turn_id), do: false

  # Signed out is the member's own state, never the driver's words. Every
  # other failure of an account stays the driver's or the provider's.
  defp turned_away(work, %{"account" => "signed_out"}, _kind), do: signed_out(work)
  defp turned_away(work, _refusal, kind), do: refused(work, kind)

  defp accepted(%{work: work} = state, ids) do
    Enum.reduce(ids, state, fn id, state ->
      cond do
        state.phase == :working and id == work.start ->
          tell(%{state | phase: :ready, recovering?: false}, {:took, [{work.start, state.how}]})

        match?(%{id: ^id}, state.outstanding) ->
          %{state | outstanding: nil}

        true ->
          state
      end
    end)
  end

  # Each post answered `later` is held as it was written, its step and id
  # kept, after those held before it, none replacing another, until an
  # idle after its `later` says the native turn it waited on ended
  # (`deliver/1`). One answered `later` again as it is written again
  # (`write_later/1`) goes back first, so none overtakes an earlier one.
  defp held(state, %{holds: holds}) do
    Enum.reduce(holds, state, fn
      :idle, state ->
        %{state | later: Enum.map(state.later, &%{&1 | rested?: true})}

      {:later, id}, state ->
        case state.outstanding do
          %{id: ^id, command: %{}} = delivery ->
            hold = %{delivery: delivery, rested?: false}

            later =
              if delivery[:held?],
                do: [hold | state.later],
                else: state.later ++ [hold]

            %{state | outstanding: nil, later: later}

          _not_this_post ->
            state
        end
    end)
  end

  # An error the harness reported ends the turn, saying it.
  defp on_errors(state, %{errors: []}), do: state

  defp on_errors(%{work: work} = state, %{errors: [error | _]}),
    do: fail(state, lost(work, {:provider, error["type"], error["message"]}))

  # The native turn ended: none of its own tools runs any more, which the
  # loop settles wherever it waits (`{:native, :idle}`), and the loop finds
  # whether its turn is done. Only the idle that names the turn's work is
  # its end: a resumed harness may send one of none first.
  defp on_idle(%{work: %{turn: %{id: id}} = work} = state, %{idle: %{"work" => id} = idle}) do
    state = withdraw(state)
    state = tell(state, {:activity, :idle})

    cond do
      state.phase == :over -> state
      idle["stop"] != "end_turn" -> fail(state, lost(work, {:ended, idle["stop"]}))
      # A held post is written now or after a later idle (`deliver/1`):
      # the turn goes on.
      state.later != [] -> state
      true -> tell(state, {:end, :done})
    end
  end

  defp on_idle(state, _effects), do: state

  # The program asked for a tool for work other than the turn's: the
  # ask cannot be answered under this session's binding and is never a
  # step, so the session is closed and the turn ends saying why.
  defp foreign(%{work: work} = state), do: fail(shut(state), refused(work, :foreign_ask))

  # The native session's transcript is gone: the thread forgets it, says
  # the program starts over, and it starts again with no session, the
  # thread's posts its context. Nothing backs the session forgotten, so
  # there is nothing of it to remove.
  defp start_over(%{work: work} = state) do
    with {:ok, generation} <- Tape.forget_session(work.guest, work.turn, work.generation),
         {:ok, _row} <-
           Tape.append_line(
             work.guest,
             work.turn,
             "#{work.title} no longer had its record of this thread, so it " <>
               "starts over from the thread's posts."
           ) do
      write_scrolls(%{state | work: %{work | generation: generation}, phase: :opening})
    else
      {:error, _reason} -> fail(shut(state), refused(work, {:start_failed, :over}))
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
      {:error, _reason} -> {:fail, state, refused(work, {:start_failed, :restart})}
    end
  end

  defp reconcile(%{work: work} = state, started) do
    case Tape.reconcile_brain(work.guest, work.turn, %{
           generation: work.generation,
           held: started["held"] || []
         }) do
      {:ok, %{absent: [], held: held}} ->
        if Enum.any?(held, &(&1.action == "notice")),
          do: {:fail, state, lost(work, :uncertain)},
          else: {:ok, %{state | pending: []}}

      {:ok, %{absent: [_ | _]}} ->
        {:fail, state, lost(work, :uncertain)}

      {:error, _reason} ->
        {:fail, state, refused(work, {:start_failed, :restart})}
    end
  end

  # ---------------------------------------------------------------------------
  # Deliveries

  # The next command the rows say is owed, one at a time while the session
  # is ready, chosen from one view of them (`Arca.TurnStorage.brain_owed/2`):
  # a prompt a recovery owes, then a closed ask's result, then a post that
  # waits. The posts answered `later` go first, in the order first
  # answered so, each once its native turn is idle: one that still waits
  # holds every one behind it. While any is held a result is still
  # written, and every other post and prompt waits behind them. A read
  # that did not answer is never nothing owed.
  defp deliver(%{phase: :ready, outstanding: nil, later: [%{rested?: true} | _]} = state),
    do: write_later(state)

  defp deliver(%{phase: :ready, outstanding: nil} = state), do: deliver_owed(state)

  defp deliver(state), do: state

  defp deliver_owed(%{work: work} = state) do
    held? = state.later != []

    case Tape.brain_owed(work.guest, work.turn) do
      {:ok, :none} -> state
      {:ok, {kind, _owed}} when held? and kind != :answer -> state
      {:ok, {:notice, %{context?: true, message_id: row_id}}} -> notice(state, "fresh", row_id)
      {:ok, {:notice, %{action: kind, message_id: row_id}}} -> notice(state, kind, row_id)
      {:ok, {:answer, result}} -> deliver_answer(state, result)
      {:ok, {:post, row}} -> deliver_post(state, row)
      {:error, _unread} -> unkept(state)
    end
  end

  # The first held post, written again as it was, under its id. It leaves
  # the hold before the write, so one that may have reached the driver
  # keeps its step (`not_written/3`) and is never given back
  # (`release/1`); one answered `later` again is held again, first.
  defp write_later(%{later: [%{delivery: delivery} | later]} = state) do
    delivery = Map.put(delivery, :held?, true)
    state = %{state | later: later}

    case write(state, delivery.command) do
      :ok -> delivered(state, delivery)
      {:error, reason} -> not_written(state, delivery, reason)
    end
  end

  # A held post was never written to the harness: as its session ends
  # each waits again among the turn's posts (`Aqua.Tape.uncarry/3`), in
  # the order held, so the next start does not name it pending and
  # delivers it anew. One that cannot be given back keeps its step, which
  # the next start names pending: uncertain, never written twice.
  defp release(%{later: later, work: work} = state) do
    Enum.each(later, fn %{delivery: %{id: id}} -> Tape.uncarry(work.guest, work.turn, id) end)

    %{state | later: []}
  end

  # The loop waits again after it found something pending. When that was
  # deleted before it was handed over, nothing is owed either way and the
  # program has been idle since it said so: it is told so again, and the
  # turn ends rather than wait for good on an idle that will not come.
  defp rested(%{phase: :ready, outstanding: nil} = state) do
    case answered(state) do
      {:ok, true} -> done(state)
      {:ok, false} -> state
      {:error, _unread} -> unkept(state)
    end
  end

  defp rested(state), do: state

  # A turn a loop continues whose program had answered all it was given,
  # its end alone not written, starts none: no idle of it would come.
  defp continued(state) do
    case answered(state) do
      {:ok, true} -> done(state)
      {:ok, false} -> open_session(%{state | recovering?: true})
      {:error, _unread} -> unkept(state)
    end
  end

  defp done(state), do: tell(state, {:end, :done})

  # Whether nothing is owed either way: nothing to deliver, no delivery
  # unacknowledged or unanswered, the program idle. What another turn of
  # the thread left owed is none of this one's.
  defp answered(%{work: work} = state) do
    with {:ok, :none} <- Tape.brain_owed(work.guest, work.turn),
         {:ok, %{progress: progress}} <- Tape.brain(work.guest, state.thread_id),
         false <- Map.get(progress, "busy", true),
         {:ok, []} <- Tape.brain_pending(work.guest, work.turn),
         {:ok, steps} <- Tape.steps(work.guest, work.turn) do
      {:ok, not Enum.any?(steps, &at_work?(&1, work))}
    else
      {:error, _reason} = unread -> unread
      _owed_or_at_work -> {:ok, false}
    end
  end

  # A delivery not yet answered, or an ask of the program the loop has not
  # settled: the work goes on while either does.
  defp at_work?(%{kind: "input", dispatch_state: "dispatched"}, _work), do: true

  defp at_work?(%{purpose: "brain", dispatch_state: state} = step, work)
       when state in ["proposed", "dispatched"],
       do: step.id != work.start

  defp at_work?(_step, _work), do: false

  # A closed ask's result, as the rows say it: its result row, the call
  # row of its ask and its step.
  defp deliver_answer(%{work: work} = state, %{row: row, call: call, step: ask}) do
    case carry(work, "answer", row.id) do
      {:ok, %{step: step}} ->
        command = %{
          "t" => "answer",
          "id" => step.id,
          "ask" => call && Tape.payload(call)["tool_call_id"],
          "content" => Reader.result(row, Reader.token()),
          "is_error" => ask.outcome != "ok"
        }

        case write(state, command) do
          :ok ->
            delivered(state, %{id: step.id, input?: true, deliver: "answer", row: row.id})

          # The resumed session no longer holds the ask: its answer goes as
          # one notice that names the call.
          {:error, :not_this_work} ->
            case Tape.uncarry(work.guest, work.turn, step.id) do
              :ok -> notice(state, "answer", row.id)
              {:error, _reason} -> unkept(state)
            end

          {:error, reason} ->
            not_written(state, step, reason)
        end

      {:error, reason} ->
        undelivered(state, reason)
    end
  end

  # A post of the turn that waits, read as it is handed over with what
  # goes before it (`work.history`): one the reading withholds went with
  # its workspace thread as it was handed over, which the turn may wait on
  # alone, and then would for good, so the turn ends saying so.
  defp deliver_post(%{work: work} = state, row) do
    with {:ok, given} <- given(state),
         {:ok, %{rows: rows, reading: reading}} <-
           work.history.(&earlier?(state, given, row, &1), [row]),
         {[handed], earlier} <- Enum.split_with(rows, &(&1.id == row.id)),
         {:ok, %{step: step}} <- carry(work, "post", row.id) do
      {:said, text} = Reader.read(handed, %{reading | named?: false})

      earlier =
        if state.missed?,
          do: Enum.filter(earlier, &said?(&1, %{reading | me: work.agent})),
          else: earlier

      context = opened_with(state, context(work, earlier, reading, opening(state)))

      command =
        %{
          "t" => "post",
          "id" => step.id,
          "work" => work.turn.id,
          "content" => [%{"type" => "text", "text" => text}],
          "context" => context
        }
        |> reject_nil()
        |> with_files(work, row)

      case write(state, command) do
        :ok ->
          delivered(
            %{state | fresh?: false, missed?: false, facts?: false},
            %{id: step.id, input?: true, deliver: "post", command: command}
          )

        {:error, reason} ->
          not_written(state, step, reason)
      end
    else
      {[], _earlier} -> fail(shut(state), refused(work, {:post_refused, :gone}))
      {:error, :not_waiting} -> fail(shut(state), refused(work, {:post_refused, :gone}))
      {:error, reason} -> undelivered(state, reason)
    end
  end

  # What a resumed session was given (`Arca.TurnStorage.brain_given/2`),
  # read only for one.
  defp given(%{missed?: true, work: work}), do: Tape.brain_given(work.guest, work.turn.thread_id)
  defp given(_state), do: {:ok, nil}

  # What goes before a post: for a fresh session the thread before it, for
  # a resumed one what it missed before it, and nothing otherwise.
  defp earlier?(%{fresh?: true}, _given, post, row), do: context_row?(row, post.seq)

  defp earlier?(%{missed?: true, work: work}, given, post, row),
    do: missed?(row, given, work) and row.seq < post.seq

  defp earlier?(_state, _given, _post, _row), do: false

  # What a resumed process missed, which the first post it is written
  # carries, a recovery prompt's or the person's: what the thread said
  # since what its session was given (`Arca.TurnStorage.brain_given/2`),
  # every post to it (`Aqua.Tape.post?/2`) it did not take. A post it was
  # never handed, its delivery refused or cut off before the send, is
  # among them, as context only; one still waiting to be handed is not.
  defp missed(%{work: work}, before?) do
    with {:ok, given} <- Tape.brain_given(work.guest, work.turn.thread_id),
         {:ok, %{rows: rows, reading: reading}} <-
           work.history.(&(missed?(&1, given, work) and before?.(&1)), []) do
      {:ok, %{rows: Enum.filter(rows, &said?(&1, %{reading | me: work.agent})), reading: reading}}
    end
  end

  defp missed?(row, %{seq: given, taken: taken}, work) do
    row.kind in @context_kinds and row.seq > (given || -1) and row.id not in taken and
      not waiting?(row, work)
  end

  # Not the agent's own speech, as the one wording of a row reads it as
  # the agent (`Aqua.Reader.read/2`): a report Aqua wrote and the server's
  # note of a stopped turn are said to it; its own words are its own.
  defp said?(row, reading), do: match?({:said, _text}, Reader.read(row, reading))

  # A post of the turn no delivery carried yet (`Aqua.Tape.post?/2`): it is
  # handed as itself.
  defp waiting?(row, work),
    do: row.turn_id == work.turn.id and is_nil(row.carried_by) and Tape.post?(row, work.agent)

  defp opening(%{missed?: true}), do: @missed_opening
  defp opening(_state), do: @context_opening

  # The first post a process is written ends its context with the turn's
  # facts, which are no part of the instructions it started with.
  defp opened_with(%{facts?: false}, history), do: history

  defp opened_with(%{work: work}, history),
    do: List.wrap(history) ++ [%{"type" => "text", "text" => work.facts}]

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
    prompt =
      with {:ok, context} <- prompt_context(state, kind),
           {:ok, carried} <- carry(work, "notice", row_id),
           do: {:ok, carried, context}

    case prompt do
      {:ok, %{step: step, row: row}, context} ->
        command =
          %{
            "t" => "post",
            "id" => step.id,
            "work" => work.turn.id,
            "content" => [%{"type" => "text", "text" => notice_text(work, kind, row)}],
            "context" => opened_with(state, context)
          }
          |> reject_nil()

        case write(state, command) do
          :ok ->
            delivered(
              %{state | fresh?: state.fresh? and kind != "fresh", missed?: false, facts?: false},
              %{id: step.id, input?: true, deliver: "notice", command: command}
            )

          {:error, reason} ->
            not_written(state, step, reason)
        end

      # A notice was attempted for this row already: no second follows.
      {:error, :carried} ->
        fail(shut(state), lost(work, :uncertain))

      {:error, reason} ->
        undelivered(state, reason)
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

  defp notice_text(_work, _answer, row), do: Reader.late_answer(row, Reader.token())

  defp prompt_context(%{work: work}, "fresh") do
    with {:ok, answers} <- answers(work),
         {:ok, joined} <- work.history.(&in_context?(&1, answers), []),
         do: {:ok, context(work, joined.rows, joined.reading, @context_opening)}
  end

  defp prompt_context(%{missed?: true, work: work} = state, _kind) do
    with {:ok, missed} <- missed(state, fn _row -> true end),
         do: {:ok, context(work, missed.rows, missed.reading, @missed_opening)}
  end

  defp prompt_context(_state, _kind), do: {:ok, nil}

  # What a delivery brings in joined the turn before it was worded
  # (`Aqua.Reader.join/5`).
  defp carry(work, deliver, row_id) do
    Tape.carry(work.guest, work.turn, %{
      deliver: deliver,
      row_id: row_id,
      generation: work.generation,
      silence_ms: Opus.Brain.silence_ms()
    })
  end

  # One written: the program owes its acknowledgement, and the clock runs.
  defp delivered(state, outstanding), do: arm(%{state | outstanding: outstanding})

  # A delivery that was not recorded, and so not written. A paused turn
  # takes no notice: its loop's next wait writes it. Anything else has
  # no event to be tried again on, so it ends the turn.
  defp undelivered(state, :not_running), do: state

  defp undelivered(%{work: work} = state, :generation_moved),
    do: fail(shut(state), lost(work, :forgotten))

  defp undelivered(%{work: work} = state, :not_admitted),
    do: fail(shut(state), refused(work, {:not_admitted, :working}))

  defp undelivered(%{work: work} = state, :superseded),
    do: fail(shut(state), lost(work, :ended))

  defp undelivered(state, _reason), do: unkept(state)

  # One that may have been written is uncertain, never unsent: it keeps
  # its step and its carrier, its session closes, and recovery reconciles
  # it with what the resumed transcript holds. One refused before it was
  # written is taken back. It is tried again only where an event will
  # follow, the holder's answer or its end; any other refusal ends the turn.
  defp not_written(state, _step, :uncertain) do
    state = shut(state)
    if state.phase == :over, do: state, else: open_session(%{state | recovering?: true})
  end

  defp not_written(%{work: work} = state, step, refused) do
    case Tape.uncarry(work.guest, work.turn, step.id) do
      :ok -> refused_write(state, refused)
      {:error, _reason} -> unkept(state)
    end
  end

  defp refused_write(state, :busy), do: state
  defp refused_write(state, refused) when refused in @ending, do: state

  defp refused_write(%{work: work} = state, {:not_admitted, :generation_moved}),
    do: fail(shut(state), lost(work, :forgotten))

  defp refused_write(state, {:not_admitted, :unavailable}), do: unkept(state)

  defp refused_write(%{work: work} = state, {:not_admitted, _reason}),
    do: fail(shut(state), refused(work, {:not_admitted, :working}))

  defp refused_write(%{work: work} = state, _refused),
    do: fail(shut(state), refused(work, :work_refused))

  # The thread so far for a fresh session, the newest of `rows` that fit
  # beside the turn's facts.
  # It opens saying it is context only, and when older posts are left out
  # one line says how many, in room kept for it.
  defp context(_work, [], _reading, _opening), do: nil

  defp context(work, rows, reading, opening) do
    room =
      @context_bytes - encoded_bytes(work.facts) - encoded_bytes(opening) -
        encoded_bytes(left_out(length(rows)) <> @context_separator)

    {kept, _size} =
      rows
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn row, {kept, size} ->
        line = line(work, row, reading)
        taken = size + encoded_bytes(line) + encoded_bytes(@context_separator)

        if taken > room,
          do: {:halt, {kept, size}},
          else: {:cont, {[line | kept], taken}}
      end)

    lines =
      case length(rows) - length(kept) do
        0 -> kept
        dropped -> [left_out(dropped) | kept]
      end

    [%{"type" => "text", "text" => opening <> Enum.join(lines, @context_separator)}]
  end

  defp left_out(1), do: "[1 earlier post of the thread is not shown here.]"
  defp left_out(n), do: "[#{n} earlier posts of the thread are not shown here.]"

  # For a session started anew in the middle of the work: every post and
  # the result rows of the open work's asks.
  defp in_context?(row, answers),
    do: row.kind in @context_kinds or (row.kind == "tool_result" and row.id in answers)

  # The result rows of the open work's asks that closed, never its start's.
  defp answers(work) do
    with {:ok, steps} <- Tape.steps(work.guest, work.turn) do
      {:ok,
       for(
         %{purpose: "brain", kind: kind, result_message_id: id} = step <- steps,
         kind != "input" and step.id != work.start and is_binary(id),
         do: id
       )}
    end
  end

  # The bytes `text` takes inside a JSON string on the line, as the wire
  # encodes it: escaping is the characters' own, so a text's parts add up.
  defp encoded_bytes(text), do: byte_size(Jason.encode!(text)) - 2

  # A context has no roles and no calls, so each row is said by who said
  # it (`me: :nobody`). A row's deleted files are named after it, inside
  # its share of the room.
  defp line(work, row, reading) do
    reading = %{reading | me: :nobody, removed: Reader.removed(work.guest, [row])}
    {:said, text} = Reader.read(row, reading)

    case reading.removed[row.id] do
      nil -> text
      refs -> text <> @context_separator <> Reader.removed_note(refs)
    end
  end

  # ---------------------------------------------------------------------------
  # Its end, and the clock

  defp session_lost(state, reason) do
    %{state | brain: nil, boot: nil, outstanding: nil}
    |> release()
    |> withdraw()
    |> session_ended()
    |> ended(reason)
  end

  defp ended(%{phase: :over} = state, _reason), do: state
  defp ended(%{work: work} = state, :forgotten), do: fail(state, lost(work, :forgotten))
  defp ended(%{work: work} = state, :replaced), do: fail(state, lost(work, :ended))

  # A driver that ends before it takes the work fails its start: the same
  # start is not made again by itself. Its end says why when the driver
  # said (`{:exited, why}`, `Opus.Brain.Wire.endings/0`) or the service it
  # ran on started again.
  defp ended(%{phase: phase, work: work} = state, reason) when phase in @starting,
    do: fail(state, refused(work, start_failed(work, reason)))

  # One that dies at work is resumed, once for each death.
  defp ended(state, _reason), do: open_session(%{state | phase: :closed, recovering?: true})

  # The clock ran out: over a start that was not taken, or over the
  # program's silence at work, by the database's clock.
  defp silence(%{phase: phase, work: work} = state) when phase in @starting do
    minutes = max(div(Opus.Brain.silence_ms() + 59_999, 60_000), 1)
    fail(shut(state), refused(work, {:start_failed, {:within, minutes}, again(work)}))
  end

  defp silence(%{phase: :ready, work: work} = state) do
    case Tape.brain_silence(work.guest, state.thread_id) do
      {:ok, %{expired?: true}} ->
        minutes = div(Opus.Brain.silence_ms(), 60_000)
        fail(shut(state), lost(work, {:silent, minutes}))

      {:ok, _running_or_paused} ->
        arm(state)

      {:error, _unread} ->
        unkept(state)
    end
  end

  defp silence(state), do: state

  # At work the timer follows the stored clock. A start keeps the one it
  # began with.
  defp arm(%{phase: :ready, work: work, timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)

    case Tape.brain_silence(work.guest, state.thread_id) do
      {:ok, %{due_ms: due}} when is_integer(due) ->
        %{state | timer: :erlang.start_timer(due, self(), :silence)}

      {:ok, _paused} ->
        %{state | timer: nil}

      {:error, _unread} ->
        unkept(%{state | timer: nil})
    end
  end

  defp arm(state), do: state

  # ---------------------------------------------------------------------------
  # Telling the loop

  # What the loop is told, after its commit (`Aqua.Harness`).
  defp tell(%{loop: nil} = state, _event), do: state

  defp tell(%{loop: loop, work: work} = state, event) do
    send(loop, {Aqua.Harness, work.turn.id, event})
    state
  end

  # The turn's work ends once, as `finish` says, which the loop words.
  defp fail(%{phase: :over} = state, _finish), do: state
  defp fail(state, finish), do: tell(%{state | phase: :over}, {:end, finish})

  defp reject_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
