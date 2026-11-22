# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Tape do
  @moduledoc """
  The one persistence port of the runner and the loop: every row a turn
  writes — messages, turns, steps, events — goes through here,
  and nothing under `Aqua.Runner` or `Aqua.Loop` names a storage module.

  Each write is one storage transaction (`Arca.TurnStorage`), fenced on
  the turn's `fence`: a runner whose fence moved is refused
  `{:error, :superseded}`. The rows a person sees are broadcast on the
  thread's topic AFTER the transaction commits, as plain maps in
  `Cyfr.Bus.ThreadEvent`s of kind `:message`, and after the same commits
  a thread's place in its person's list (`Aqua.ThreadList`) and a crew
  member's job beginning and ending (`Aqua.Crew.Activity`). A
  guest-planed context writes here unchanged: the tape is a narrow
  interface, not a plane, and the tenant is the context's.

  Pausing and resuming a turn are `Opus`'s
  (`Opus.pause_turn_root/3`, `resume_turn_root/3`): they move
  the rows with the root's slot and lease, which only the process holding
  them can do.

  ## The thread's claim

  Which turn may run at all is `threads.active_turn_id`, not a process on
  any member. `start_turn/3` takes it, `finish/4` gives it up,
  `bump_recovery/2` takes it from a turn whose holder is not a live
  member, and `claim_holder/2` reads it. A pause keeps it.
  """

  require Logger

  alias Aqua.Crew.Activity
  alias Aqua.ThreadList
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Sanctum.Context

  # The rows `Arca.TurnStorage` and `Arca.ThreadStorage` answer, each a
  # plain map of the row's columns.
  @type turn :: %{required(:id) => String.t(), optional(atom()) => term()}
  @type step :: %{required(:id) => String.t(), optional(atom()) => term()}
  @type row :: %{required(:id) => String.t(), optional(atom()) => term()}

  @doc "Whether the turn has a terminal status in the durable lifecycle."
  @spec terminal?(turn()) :: boolean()
  def terminal?(%{status: status}), do: Prima.TurnState.terminal?(status)

  # ---------------------------------------------------------------------------
  # Acceptance
  # ---------------------------------------------------------------------------

  @doc """
  Accept a message atomically with the work it opens. `attrs`:
  `:message` (`:author`, `:sent_by`, `:content`, `:payload`, optional
  `:id`, `:client_id`, `:addressee`, `:reply_to`, `:outcome`, `:status`),
  and one of `:turn` (`%{agent, requested_by, model, options}`) or
  `:steer_turn_id`, or neither for room content; and the crew members of
  `TurnStorage.accept_message/3` as they stand: `:reply_address`,
  `:request`, `:answers`, `:receipt`. A request recorded wakes the crew's
  delivery consumer (`Cyfr.Bus.crew_deliveries/0`) after the commit.

  A turn opened here is recorded with the origin `ctx` carries
  (`Prima.Origin`), which the admission entry that built the context
  set, so a turn recovered after a restart resumes under it; an origin
  named in `:turn` is not read. A turn asked for under a context that
  carries none is refused `{:error, :no_origin}` with nothing written.

  A `client_id` this thread already accepted answers the existing
  acceptance as `replayed: true` when it is the same send — same actor,
  text, attachments, and the same work: the agent, model and room of the
  turn it opened, or the turn it steered — and `{:error, :client_id_reused}`
  when it is not. A message `id` already
  taken is answered the same way through its `client_id`, and refused
  `{:error, :message_id_reused}` without one or under another's.
  """
  @spec accept(Context.t(), String.t(), map()) ::
          {:ok, %{message: row(), turn: turn() | nil, replayed: boolean()}} | {:error, term()}
  def accept(%Context{} = ctx, thread_id, attrs) when is_map(attrs) do
    attrs = with_origin(attrs, ctx)

    case TurnStorage.accept_message(Sanctum.Context.actor(ctx), thread_id, attrs) do
      {:ok, %{message: message, turn: turn}} ->
        announce_lists(ctx, thread_id, turn && {:started, turn})
        broadcast(ctx, thread_id, row_kind(message), message)
        if Map.get(attrs, :request), do: wake_crew(ctx)
        {:ok, %{message: message, turn: turn, replayed: false}}

      {:error, reason} when reason in [:duplicate_client_id, :message_id_reused] ->
        replay(ctx, thread_id, attrs, reason)

      other ->
        other
    end
  end

  # The turn takes its context's origin, whatever the caller put in it.
  defp with_origin(%{turn: %{} = turn} = attrs, %Context{origin: origin}),
    do: %{attrs | turn: Map.put(turn, :origin, origin)}

  defp with_origin(attrs, _ctx), do: attrs

  # The identity offered again — by client id, or by a message id already
  # taken — answers what was accepted when it is the same send; the
  # client id is what names the accepted row, so an id offered without one
  # is another send's.
  defp replay(ctx, thread_id, attrs, reason) do
    case get_in(attrs, [:message, :client_id]) do
      client_id when is_binary(client_id) ->
        case TurnStorage.accepted(Sanctum.Context.actor(ctx), thread_id, client_id) do
          {:ok, %{message: message, turn: turn}} ->
            if same_send?(message, turn, attrs),
              do: {:ok, %{message: message, turn: turn, replayed: true}},
              else: {:error, reused(reason)}

          {:error, :not_found} ->
            {:error, reused(reason)}

          {:error, _} = error ->
            error
        end

      _ ->
        {:error, reused(reason)}
    end
  end

  defp reused(:duplicate_client_id), do: :client_id_reused
  defp reused(:message_id_reused), do: :message_id_reused

  @doc """
  The server's nudge of a quiet workspace thread, accepted under the
  thread's lock where it is decided afresh
  (`Arca.TurnStorage.nudge/3`): it joins the turn that holds the thread
  when that turn is Aqua's and asks a model, or opens one as the
  context's person under its origin with the `:options` of the work it is
  bound to (`:work`, the turn the binding was read from). `attrs`:
  `:content`, `:options`, `:work`, `:quiet`, `:claim`,
  `:slot`, `:join_only`. The row is broadcast after the commit, and a turn it
  opened announced as an acceptance's is.
  """
  @spec nudge(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def nudge(%Context{} = ctx, thread_id, attrs) when is_map(attrs) do
    storage = %{
      message: %{content: Map.fetch!(attrs, :content)},
      turn: line_turn(ctx, Map.get(attrs, :options, %{})),
      work: Map.fetch!(attrs, :work),
      quiet: Map.fetch!(attrs, :quiet),
      claim: Map.fetch!(attrs, :claim),
      slot: Map.fetch!(attrs, :slot),
      join_only: Map.get(attrs, :join_only, false)
    }

    case TurnStorage.nudge(Sanctum.Context.actor(ctx), thread_id, storage) do
      {:ok, %{message: message, turn: turn} = accepted} ->
        announce_lists(ctx, thread_id, turn && {:started, turn})
        broadcast(ctx, thread_id, :message, message)
        {:ok, accepted}

      other ->
        other
    end
  end

  # The turn a server's line opens: Aqua's, as the context's person under
  # its origin, with the options of the work it is bound to.
  defp line_turn(%Context{} = ctx, options) do
    soul = Prima.AgentRef.soul_name()

    %{
      agent: soul,
      requested_by: ctx.user_id,
      model: nil,
      options: Map.put(options, "agent", soul),
      origin: ctx.origin
    }
  end

  @doc """
  As a turn a server's line opened first starts, whether its line still
  stands to be answered (`Arca.TurnStorage.line_stands/2`); any other
  turn's line stands. A store that cannot answer is `{:error, _}`.
  """
  @spec line_stands(Context.t(), turn()) :: {:ok, boolean()} | {:error, term()}
  def line_stands(%Context{} = ctx, turn),
    do: TurnStorage.line_stands(Sanctum.Context.actor(ctx), turn)

  @doc """
  The acceptance a `client_id` already produced in this thread:
  its message and, when the row opened or steered a turn, that turn.
  `{:error, :not_found}` for a `client_id` never accepted.
  """
  @spec accepted(Context.t(), String.t(), String.t()) ::
          {:ok, %{message: row(), turn: turn() | nil}} | {:error, term()}
  def accepted(%Context{} = ctx, thread_id, client_id) when is_binary(client_id),
    do: TurnStorage.accepted(Sanctum.Context.actor(ctx), thread_id, client_id)

  @doc """
  Append one row outside a turn's step machinery (a system note, a
  compaction, an aborted mark). `attrs` name `:sent_by` as every row does.
  """
  @spec append(Context.t(), String.t(), map()) :: {:ok, row()} | {:error, term()}
  def append(%Context{} = ctx, thread_id, attrs) when is_map(attrs) do
    with {:ok, row} <- Threads.append(Sanctum.Context.actor(ctx), thread_id, attrs) do
      broadcast(ctx, thread_id, :message, row)
      {:ok, row}
    end
  end

  @doc "The `turn_aborted` system row: tools may have partially executed."
  @spec append_aborted(Context.t(), turn(), String.t()) :: {:ok, row()} | {:error, term()}
  def append_aborted(%Context{} = ctx, turn, reason) when is_binary(reason) do
    turn_row(ctx, turn, %{
      author: Prima.Author.system(),
      kind: "turn_aborted",
      content: reason
    })
  end

  # A row the turn owns, written inside its fence. Both of these change what
  # the next request reads, so a runner whose fence has moved must not be
  # able to add one — the generic `append/3` asks the thread and would
  # have let a superseded loop rewrite its successor's projection.
  defp turn_row(%Context{} = ctx, turn, attrs) do
    attrs =
      attrs
      |> Map.put(:execution_id, turn.root_execution_id)
      |> Map.put(:fence, turn.fence)

    with {:ok, row} <- TurnStorage.append_turn_row(Sanctum.Context.actor(ctx), turn.id, attrs) do
      broadcast(ctx, turn.thread_id, :message, row)
      {:ok, row}
    end
  end

  @doc """
  The compaction row: `first_kept_seq` (inclusive), `summarized_through_seq`
  and the summary the projection reads in place of the rows before it.
  """
  @spec append_compaction(Context.t(), turn(), map()) :: {:ok, row()} | {:error, term()}
  def append_compaction(%Context{} = ctx, turn, attrs) when is_map(attrs) do
    turn_row(ctx, turn, %{
      author: Prima.Author.system(),
      kind: "compaction",
      content: Map.get(attrs, :summary, ""),
      payload: %{
        "first_kept_seq" => Map.fetch!(attrs, :first_kept_seq),
        "summarized_through_seq" => Map.fetch!(attrs, :summarized_through_seq),
        "step_id" => Map.get(attrs, :step_id)
      }
    })
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Start an accepted turn with its root, attempt, budget and pins
  (`TurnStorage.start/3`), taking the thread's claim with it and storing
  the recovery limit the caller's policy names (`:recovery_limit`), which
  the turn is held to from then on.

  The claim names the consumed sequence read here, a moment before the
  statement that compares it: that read and that write are the
  compare-and-set which decides, between two members planning from the
  same thread, whose turn runs. A sequence that moved under the read is
  not a refusal — a peer accepted the next message, which changes nothing
  about this turn's right to run — so the thread is read again, a bounded
  number of times. A thread another turn holds is
  `{:error, {:held_elsewhere, turn_id}}` and is the caller's to queue
  behind.
  """
  @spec start_turn(Context.t(), turn(), map()) :: {:ok, turn()} | {:error, term()}
  def start_turn(%Context{} = ctx, turn, attrs) when is_map(attrs) do
    with {:ok, started} <- start_turn(ctx, turn, attrs, 3) do
      Activity.started(ctx, started)
      {:ok, started}
    end
  end

  defp start_turn(_ctx, _turn, _attrs, 0), do: {:error, :stale}

  defp start_turn(%Context{} = ctx, turn, attrs, tries) do
    actor = Sanctum.Context.actor(ctx)

    attrs =
      case Threads.get(actor, turn.thread_id) do
        {:ok, thread} -> Map.put(attrs, :turn_seq, thread.turn_seq || 0)
        {:error, _} -> attrs
      end

    case TurnStorage.start(actor, turn.id, Map.put_new(attrs, :fence, turn.fence)) do
      {:error, :stale} -> start_turn(ctx, turn, Map.delete(attrs, :turn_seq), tries - 1)
      other -> other
    end
  end

  @doc """
  Which turn holds the thread, and whether a live peer runs it
  (`Arca.ThreadStorage.claim_holder/2`) — the row's answer to "is anybody
  working this thread", which a local registry cannot give.
  """
  @spec claim_holder(Context.t(), String.t()) ::
          {:ok, %{turn_id: String.t() | nil, runner_id: String.t() | nil, live_peer?: boolean()}}
          | {:error, term()}
  def claim_holder(%Context{} = ctx, thread_id),
    do: Threads.claim_holder(Sanctum.Context.actor(ctx), thread_id)

  @doc """
  End a turn: the one terminal transaction (`TurnStorage.finish/4`),
  under the grant its root's attempt stores. Every program session the
  turn started ends with it (`Opus.end_turn_programs/2`). A completion needs that
  grant to stand; a turn that fails, is cancelled or ends uncertain
  retires work and needs only the stored stamp. A turn with a reply
  address recorded its reply there, and the crew's delivery consumer is
  woken after the commit.
  """
  @spec finish(Context.t(), turn(), String.t(), map()) :: {:ok, turn()} | {:error, term()}
  def finish(%Context{} = ctx, turn, status, attrs \\ %{}) do
    with {:ok, finished} <-
           TurnStorage.finish(
             Sanctum.Context.actor(ctx),
             turn.id,
             status,
             attrs
             |> Map.put_new(:fence, turn.fence)
             |> standing(if(status == "completed", do: :current, else: :retiring))
           ) do
      Opus.end_turn_programs(finished.athanor_id, finished.id)
      announce_lists(ctx, turn.thread_id, {:ended, finished})
      broadcast(ctx, turn.thread_id, :turn_finished, nil)
      if finished.asking_thread_id || workspace?(ctx, turn.thread_id), do: wake_crew(ctx)
      end_fire(ctx, finished)
      {:ok, finished}
    end
  end

  @doc """
  The schedule and occurrence a turn a schedule's line started carries on
  its options (`Aqua.Runner`'s `:schedule`), or nil for any other turn.
  """
  @spec schedule_of(map()) :: %{schedule_id: String.t(), occurrence_id: String.t()} | nil
  def schedule_of(%{options: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"schedule" => %{"schedule_id" => schedule_id, "occurrence_id" => occurrence_id}}}
      when is_binary(schedule_id) and is_binary(occurrence_id) ->
        %{schedule_id: schedule_id, occurrence_id: occurrence_id}

      _none ->
        nil
    end
  end

  def schedule_of(_turn), do: nil

  # A schedule's turn that ended ends its occurrence, on the scheduler's
  # one ending (`Opus.end_schedule_turn/4`), from the turn's
  # root as its row now stands: here, after the turn's terminal write, is
  # the one place every end of a turn passes. An end that does not land
  # (the root still open, the slot lost) leaves the occurrence to the
  # scheduler's recovery, which ends it from the same row.
  # Whatever it meets, it never fails the turn's own end, which has
  # committed.
  defp end_fire(ctx, finished) do
    ended_fire(ctx, finished)
  catch
    kind, reason ->
      Logger.warning(
        "[Aqua.Tape] the occurrence of turn #{finished.id} not ended: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )
  end

  defp ended_fire(ctx, finished) do
    with %{occurrence_id: occurrence_id} <- schedule_of(finished) do
      case Opus.end_schedule_turn(
             Sanctum.Context.actor(ctx),
             occurrence_id,
             finished.root_execution_id,
             finished.error
           ) do
        {:ok, _state} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Aqua.Tape] occurrence #{occurrence_id} of turn #{finished.id} not ended: " <>
              inspect(reason)
          )
      end
    end
  end

  @doc """
  Take over a turn another runner lost: the successor attempt, the new
  fence and the recovery count (`TurnStorage.takeover/3`), from the fence
  `turn` was read with. Refused once the turn's stored limit is spent.
  """
  @spec bump_recovery(Context.t(), turn()) :: {:ok, turn()} | {:error, term()}
  def bump_recovery(%Context{} = ctx, turn),
    do:
      TurnStorage.takeover(
        Sanctum.Context.actor(ctx),
        turn.id,
        standing(%{fence: turn.fence}, :current)
      )

  # The grant a write on the turn's root attempt runs under: the stamp that
  # attempt stores (`TurnStorage`'s "The root's grant"), which must still
  # stand, or — for a turn that retires its work — need only be carried.
  defp standing(attrs, :current),
    do: Map.merge(attrs, %{grant: :stored, verify: &Sanctum.ExecutionStanding.verify/1})

  defp standing(attrs, :retiring),
    do: Map.merge(attrs, %{grant: :stored, verify: &Sanctum.ExecutionStanding.stamp_only/1})

  @doc "Pin the program row the turn's brain runs on (`TurnStorage.pin_program/4`)."
  @spec pin_program(Context.t(), turn(), String.t()) :: {:ok, turn()} | {:error, term()}
  def pin_program(%Context{} = ctx, turn, row_id),
    do: TurnStorage.pin_program(Sanctum.Context.actor(ctx), turn.id, row_id, %{fence: turn.fence})

  @doc "Renew the fence and cancel-mark the dispatched steps, before the loop is stopped."
  @spec supersede(Context.t(), turn()) :: {:ok, turn()} | {:error, term()}
  def supersede(%Context{} = ctx, turn),
    do: TurnStorage.supersede(Sanctum.Context.actor(ctx), turn.id, %{fence: turn.fence})

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  @doc "Record the model call the loop is about to make, before it is made."
  @spec record_model_intent(Context.t(), turn(), map()) :: {:ok, step()} | {:error, term()}
  def record_model_intent(%Context{} = ctx, turn, attrs \\ %{}) do
    TurnStorage.put_step(
      Sanctum.Context.actor(ctx),
      turn.id,
      attrs |> Map.put(:kind, "model") |> Map.put_new(:fence, turn.fence)
    )
  end

  @doc """
  Persist a model response before any of its calls runs: the reply and
  the tool calls as rows, every call as a proposed step
  (`TurnStorage.record_response/4`). The rows are broadcast after commit.
  """
  @spec record_response(Context.t(), turn(), step(), map()) ::
          {:ok, %{text: row() | nil, calls: [map()]}} | {:error, term()}
  def record_response(%Context{} = ctx, turn, model_step, response) when is_map(response) do
    with {:ok, %{text: text, calls: calls} = recorded} <-
           TurnStorage.record_response(
             Sanctum.Context.actor(ctx),
             turn.id,
             model_step.id,
             Map.put_new(response, :fence, turn.fence)
           ) do
      if text, do: broadcast(ctx, turn.thread_id, :message, text)
      Enum.each(calls, &broadcast(ctx, turn.thread_id, :message, &1.message))
      {:ok, recorded}
    end
  end

  @doc """
  Join `threads` into the turn's read threads
  (`TurnStorage.join_threads/4`), under the turn's row lock and its fence:
  what a child's run read joins its turn before the turn uses the child's
  answer. A runner whose fence moved is refused `{:error, :superseded}`;
  nothing to join writes nothing.
  """
  @spec join_threads(Context.t(), turn(), [String.t()]) :: :ok | {:error, term()}
  def join_threads(%Context{}, _turn, []), do: :ok

  def join_threads(%Context{} = ctx, turn, threads) when is_list(threads),
    do:
      TurnStorage.join_threads(Sanctum.Context.actor(ctx), turn.id, threads, %{fence: turn.fence})

  @doc """
  Join what `turn` is about to read of `rows` and answer those it may
  read, as they now read, with the posts they cite: the one rule, decided
  and recorded in one transaction under the turn's fence from the rows as
  they stand there (`TurnStorage.join_read/3`), so only their ids go in.
  `read` is `:history`, the turn reading what its thread holds (a
  request's rows, a program's post and context); the threads the turn
  asked to read; or `:search`, whose answer points at posts and quotes no
  citation. `most` bounds how many are handed over, and so recorded.

  What a row says of itself is this module's to read, from the row the
  transaction read: a pointer's, a report's or a wait's workspace thread
  and an opening's daily thread; the read threads a report kept and those
  a copied file carries (`Aqua.Attachments.copied_threads/1`); the turn a
  crew row or a report came from; and the posts an opening cites.
  """
  @spec join_read(
          Context.t(),
          turn(),
          :history | :search | [String.t()],
          [row()],
          pos_integer() | nil
        ) :: {:ok, map()} | {:error, term()}
  def join_read(%Context{} = ctx, turn, read, rows, most \\ nil) when is_list(rows) do
    TurnStorage.join_read(Sanctum.Context.actor(ctx), turn.id, %{
      fence: turn.fence,
      read: if(is_list(read), do: read, else: []),
      history?: read == :history,
      cite?: read != :search,
      most: most,
      rows: Enum.map(rows, & &1.id),
      also: &said_by/1
    })
  end

  @doc """
  Of `rows`, the posts a program refused, by each delivery's outcome and
  never by the carry (`TurnStorage.refused_posts/2`).
  """
  @spec refused_posts(Context.t(), [row()]) :: {:ok, [String.t()]} | {:error, term()}
  def refused_posts(%Context{} = ctx, rows) when is_list(rows) do
    case for(%{id: id, carried_by: step} <- rows, is_binary(step), do: id) do
      [] -> {:ok, []}
      ids -> TurnStorage.refused_posts(Sanctum.Context.actor(ctx), ids)
    end
  end

  @doc """
  Whether the caller still holds `turn`, open, at the fence it read,
  inside the caller's own transaction (`TurnStorage.hold/3`): what a
  publication a turn makes checks where it commits.
  """
  @spec hold(Context.t(), turn()) :: :ok | {:error, :superseded | :not_open}
  def hold(%Context{} = ctx, turn),
    do: TurnStorage.hold(Sanctum.Context.actor(ctx), turn.id, turn.fence)

  @doc """
  Write the notes of the workspace thread `turn` runs in, the bytes
  `Aqua.Notes` encodes or nil to clear them, under the turn's fence
  (`TurnStorage.write_notes/4`).
  """
  @spec write_notes(Context.t(), turn(), String.t() | nil) :: :ok | {:error, term()}
  def write_notes(%Context{} = ctx, turn, notes),
    do: TurnStorage.write_notes(Sanctum.Context.actor(ctx), turn.id, notes, %{fence: turn.fence})

  @doc """
  Propose a page's call as a step of the running `turn`, under its fence
  (`TurnStorage.put_step/3`): `attrs` as `Aqua.PageCalls.proposal/3`
  makes them, with the call's own row or the row the turn opened on. A
  turn that is not running, paused around a launch among them, refuses
  it `{:error, :illegal_transition}`.
  """
  @spec propose_call(Context.t(), turn(), map()) :: {:ok, step()} | {:error, term()}
  def propose_call(%Context{} = ctx, turn, attrs) when is_map(attrs),
    do:
      TurnStorage.put_step(
        Sanctum.Context.actor(ctx),
        turn.id,
        Map.put_new(attrs, :fence, turn.fence)
      )

  @doc "Flip a proposed step to dispatched, in its own commit."
  @spec mark_dispatched(Context.t(), turn(), step()) :: {:ok, step()} | {:error, term()}
  def mark_dispatched(%Context{} = ctx, turn, step),
    do: TurnStorage.dispatch_step(Sanctum.Context.actor(ctx), step.id, %{fence: turn.fence})

  @doc "Close a step with its result row, outcome and event, in one transaction."
  @spec close_step(Context.t(), turn(), step(), String.t(), map()) ::
          {:ok, %{step: step(), result: row() | nil}} | {:error, term()}
  def close_step(%Context{} = ctx, turn, step, outcome, attrs \\ %{}) do
    with {:ok, %{result: result} = closed} <-
           TurnStorage.close_step(
             Sanctum.Context.actor(ctx),
             step.id,
             outcome,
             Map.put_new(attrs, :fence, turn.fence)
           ) do
      if result, do: broadcast(ctx, turn.thread_id, :message, result)
      {:ok, closed}
    end
  end

  @doc """
  Forget the brain's session the turn's thread keeps, at the thread's
  session `generation` the turn read (`TurnStorage.forget_session/3`), and
  answer the generation the turn keeps a session under from here.
  """
  @spec forget_session(Context.t(), turn(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def forget_session(%Context{} = ctx, turn, generation),
    do:
      TurnStorage.forget_session(Sanctum.Context.actor(ctx), turn.id, %{
        fence: turn.fence,
        generation: generation
      })

  @doc """
  Record one delivery to a program brain before its command is written,
  under the turn's fence (`Arca.TurnStorage.carry/3`): `:deliver`
  (`"post"`, `"answer"` or `"notice"`), `:row_id`, `:generation`,
  `:silence_ms`.
  """
  @spec carry(Context.t(), turn(), map()) :: {:ok, %{step: step(), row: row()}} | {:error, term()}
  def carry(%Context{} = ctx, turn, attrs) when is_map(attrs),
    do:
      TurnStorage.carry(
        Sanctum.Context.actor(ctx),
        turn.id,
        Map.put_new(attrs, :fence, turn.fence)
      )

  @doc "Take back a delivery whose command was certainly not written (`Arca.TurnStorage.uncarry/3`)."
  @spec uncarry(Context.t(), turn(), String.t()) :: :ok | {:error, term()}
  def uncarry(%Context{} = ctx, turn, step_id),
    do:
      TurnStorage.uncarry(Sanctum.Context.actor(ctx), turn.id, %{
        fence: turn.fence,
        step_id: step_id
      })

  @doc """
  Commit what a batch of a program brain's lines did with its position
  (`Arca.TurnStorage.commit_brain/3`); the posts it wrote and the calls
  it recorded are broadcast after the commit.
  """
  @spec commit_brain(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def commit_brain(%Context{} = ctx, thread_id, attrs) when is_map(attrs) do
    with {:ok, committed} <-
           TurnStorage.commit_brain(Sanctum.Context.actor(ctx), thread_id, attrs) do
      Enum.each(committed.said, &broadcast(ctx, thread_id, :message, &1))
      if committed.said != [], do: announce_lists(ctx, thread_id, nil)
      {:ok, committed}
    end
  end

  @doc "Reconcile a program turn's deliveries with a resumed transcript (`Arca.TurnStorage.reconcile_brain/3`)."
  @spec reconcile_brain(Context.t(), turn(), map()) :: {:ok, map()} | {:error, term()}
  def reconcile_brain(%Context{} = ctx, turn, attrs),
    do:
      TurnStorage.reconcile_brain(
        Sanctum.Context.actor(ctx),
        turn.id,
        Map.put_new(attrs, :fence, turn.fence)
      )

  @doc "The recovery prompts a program turn owes (`Arca.TurnStorage.brain_notices/2`)."
  @spec brain_notices(Context.t(), turn()) :: {:ok, [map()]} | {:error, term()}
  def brain_notices(%Context{} = ctx, turn),
    do: TurnStorage.brain_notices(Sanctum.Context.actor(ctx), turn.id)

  @doc "The deliveries a resuming start names as pending (`Arca.TurnStorage.brain_pending/2`)."
  @spec brain_pending(Context.t(), turn()) :: {:ok, [String.t()]} | {:error, term()}
  def brain_pending(%Context{} = ctx, turn),
    do: TurnStorage.brain_pending(Sanctum.Context.actor(ctx), turn.id)

  @doc "The key of a turn's host `program.start` (`Arca.TurnStorage.brain_start_key/1`)."
  @spec brain_start_key(String.t()) :: String.t()
  defdelegate brain_start_key(turn_id), to: TurnStorage

  @doc "The key of a program brain's ask (`Arca.TurnStorage.brain_ask_key/2`)."
  @spec brain_ask_key(String.t(), String.t()) :: String.t()
  defdelegate brain_ask_key(turn_id, ask), to: TurnStorage

  @doc "A program brain's session as its thread keeps it (`Arca.TurnStorage.brain/2`)."
  @spec brain(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def brain(%Context{} = ctx, thread_id),
    do: TurnStorage.brain(Sanctum.Context.actor(ctx), thread_id)

  @doc "Whether a program brain's silence ran out (`Arca.TurnStorage.brain_silence/2`)."
  @spec brain_silence(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def brain_silence(%Context{} = ctx, thread_id),
    do: TurnStorage.brain_silence(Sanctum.Context.actor(ctx), thread_id)

  @doc "The posts of a program turn that wait for their delivery (`Arca.TurnStorage.brain_posts/2`)."
  @spec brain_posts(Context.t(), turn()) :: {:ok, [row()]} | {:error, term()}
  def brain_posts(%Context{} = ctx, turn),
    do: TurnStorage.brain_posts(Sanctum.Context.actor(ctx), turn.id)

  @doc "The results a program turn owes its brain (`Arca.TurnStorage.brain_results/2`)."
  @spec brain_results(Context.t(), turn()) :: {:ok, [map()]} | {:error, term()}
  def brain_results(%Context{} = ctx, turn),
    do: TurnStorage.brain_results(Sanctum.Context.actor(ctx), turn.id)

  @doc """
  Mark a dispatched step whose effect cannot be known, under the turn's
  fence and the step's generation: a sibling the turn's pause already
  covers.
  """
  @spec mark_uncertain(Context.t(), turn(), step(), String.t() | nil) ::
          {:ok, step()} | {:error, term()}
  def mark_uncertain(%Context{} = ctx, turn, step, reason \\ nil),
    do:
      TurnStorage.mark_step_uncertain(Sanctum.Context.actor(ctx), step.id, reason, %{
        fence: turn.fence,
        generation: step.generation
      })

  @doc """
  Stop a root turn on a call whose outcome is unknown: the step marked
  `uncertain`, its siblings settled and the turn paused `uncertain`, in one
  transaction (`TurnStorage.pause_uncertain/3`).
  `attrs`: `:step_id`, `:generation`, `:reason`, `:content`. The aborted
  row is broadcast after commit.
  """
  @spec pause_uncertain(Context.t(), turn(), map()) ::
          {:ok, %{turn: turn(), aborted: row()}} | {:error, term()}
  def pause_uncertain(%Context{} = ctx, turn, attrs) when is_map(attrs) do
    with {:ok, %{aborted: aborted} = paused} <-
           TurnStorage.pause_uncertain(
             Sanctum.Context.actor(ctx),
             turn.id,
             Map.put_new(attrs, :fence, turn.fence)
           ) do
      broadcast(ctx, turn.thread_id, :message, aborted)
      {:ok, paused}
    end
  end

  @doc "Set down a running turn a dead runner left with an unacknowledged uncertainty (`TurnStorage.pause_recovered/3`)."
  @spec pause_recovered(Context.t(), turn(), String.t()) :: {:ok, turn()} | {:error, term()}
  def pause_recovered(%Context{} = ctx, turn, content) when is_binary(content),
    do:
      TurnStorage.pause_recovered(
        Sanctum.Context.actor(ctx),
        turn.id,
        standing(%{content: content, fence: turn.fence}, :current)
      )

  @doc "Whether the turn holds an uncertainty its sender has not acknowledged."
  @spec unacknowledged_episode?(Context.t(), turn()) :: boolean()
  def unacknowledged_episode?(%Context{} = ctx, turn),
    do: TurnStorage.unacknowledged_episode?(Sanctum.Context.actor(ctx), turn.id) == true

  @doc "Whether the turn is restricted to replay-safe reads: any of its steps is `uncertain`."
  @spec restricted?(Context.t(), turn()) :: boolean()
  def restricted?(%Context{} = ctx, turn),
    do: TurnStorage.restricted?(Sanctum.Context.actor(ctx), turn.id) == true

  @doc """
  Close every unstarted step as skipped; with `only`, the ids of the
  steps to skip, those of them still unstarted.
  """
  @spec skip_steps(Context.t(), turn(), String.t(), [String.t()] | nil) ::
          {:ok, [step()]} | {:error, term()}
  def skip_steps(%Context{} = ctx, turn, reason, only \\ nil) do
    with {:ok, steps} <-
           TurnStorage.skip_steps(Sanctum.Context.actor(ctx), turn.id, reason, %{
             fence: turn.fence,
             only: only
           }) do
      Enum.each(steps, fn step ->
        with {:ok, row} <- Threads.get_message(Sanctum.Context.actor(ctx), step.result_message_id),
             do: broadcast(ctx, turn.thread_id, :message, row)
      end)

      {:ok, steps}
    end
  end

  @doc """
  The page's call `request` in `thread_id` ended unanswered
  (`TurnStorage.end_call/4`): no step of it is recorded or dispatched
  from now on, and its step still proposed is skipped with `reason`.
  Answers the call's turn and the steps skipped, or `nil` for a call
  with no row yet.
  """
  @spec end_call(Context.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{turn_id: String.t(), skipped: [step()]} | nil} | {:error, term()}
  def end_call(%Context{} = ctx, thread_id, request, reason) do
    with {:ok, ended} <-
           TurnStorage.end_call(Sanctum.Context.actor(ctx), thread_id, request, reason) do
      for %{skipped: steps} <- List.wrap(ended), steps != [] do
        Enum.each(steps, fn step ->
          with {:ok, row} <-
                 Threads.get_message(Sanctum.Context.actor(ctx), step.result_message_id),
               do: broadcast(ctx, thread_id, :message, row)
        end)
      end

      {:ok, ended}
    end
  end

  @doc "Open the next generation of a replay-safe step with a fresh child id."
  @spec next_generation(Context.t(), turn(), step(), String.t()) ::
          {:ok, step()} | {:error, term()}
  def next_generation(%Context{} = ctx, turn, step, child_execution_id),
    do:
      TurnStorage.next_generation(Sanctum.Context.actor(ctx), step.id, %{
        child_execution_id: child_execution_id,
        fence: turn.fence
      })

  @doc "Record what a model request left out (`[\"room_excerpt\"]`) or its digest."
  @spec mark_excluded(Context.t(), turn(), step(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def mark_excluded(%Context{} = ctx, turn, step, attrs),
    do:
      TurnStorage.update_step(
        Sanctum.Context.actor(ctx),
        step.id,
        Map.put(attrs, :fence, turn.fence)
      )

  # ---------------------------------------------------------------------------
  # The crew
  # ---------------------------------------------------------------------------

  @doc "The child thread `member` works in under `room_id`, made when none stands (`Arca.ThreadStorage.crew_thread/3`)."
  @spec crew_thread(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def crew_thread(%Context{} = ctx, room_id, member),
    do: Threads.crew_thread(Sanctum.Context.actor(ctx), room_id, member)

  @doc """
  Archive the person's daily or workspace thread
  (`Arca.ThreadStorage.archive/2`): it moves behind their list's Archived
  filter, which the storage announces after the commit, with its window
  closed by the browser that holds it (`Opus.Browser`), and nothing else
  about it changes. Refused `:working` while work remains in it, and
  `:not_a_room` for a crew member's thread, which is retired (`retire/2`).
  """
  @spec archive(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def archive(%Context{} = ctx, thread_id),
    do: Threads.archive(Sanctum.Context.actor(ctx), thread_id)

  @doc """
  Retire a child thread, its open turns cancelled with their replies in
  the same transaction (`Arca.ThreadStorage.retire/3`), under the stamp
  each root's attempt stores: a cancel retires work. Viewers hear the
  turns end and the crew's delivery consumer is woken after the commit;
  the runtime still holding the cancelled turns is the caller's to stop
  (`Aqua.Runner.stop_cancelled/1`).
  """
  @spec retire(Context.t(), String.t()) ::
          {:ok, %{thread: map(), cancelled: [map()]}} | {:error, term()}
  def retire(%Context{} = ctx, thread_id) do
    open = open_jobs(ctx, [thread_id])

    with {:ok, %{cancelled: cancelled}} = retired <-
           Threads.retire(Sanctum.Context.actor(ctx), thread_id, standing(%{}, :retiring)) do
      if cancelled != [] do
        broadcast(ctx, thread_id, :turn_finished, nil)
        wake_crew(ctx)
        Activity.cancelled(ctx, open, cancelled)
      end

      retired
    end
  end

  @doc """
  The kinds of a person's rooms, the threads a crew member's child thread
  works under: daily and workspace threads (`Arca.ThreadStorage.room_kinds/0`).
  """
  @spec room_kinds() :: [String.t()]
  defdelegate room_kinds(), to: Threads

  @doc """
  Delete a thread, and with a room its crew members' child threads, their
  open turns cancelled in the same transaction (`Arca.ThreadStorage.delete/3`)
  under the stamp each root's attempt stores; the runtime still holding
  them is the caller's to stop (`Aqua.Runner.stop_cancelled/1`), and a
  runner on another member stops on hearing each cancelled turn's thread
  told its turn finished. The holders of the program sessions the
  deletion owed their removal, its threads' and its readers', are closed
  once it commits (`Opus.Brain.forgotten/2`).
  """
  @spec delete_thread(Context.t(), String.t()) ::
          {:ok, %{cancelled: [map()], forgotten: [map()]}} | {:error, term()}
  def delete_thread(%Context{} = ctx, thread_id) do
    actor = Sanctum.Context.actor(ctx)

    children =
      case Threads.children(actor, thread_id) do
        children when is_list(children) -> Enum.map(children, & &1.id)
        {:error, _unread} -> []
      end

    open = open_jobs(ctx, children)

    with {:ok, %{cancelled: cancelled, forgotten: forgotten}} = deleted <-
           Threads.delete(actor, thread_id, standing(%{}, :retiring)) do
      :ok = Opus.Brain.forgotten(ctx.athanor_id, forgotten)
      ThreadList.removed(ctx, thread_id)
      Activity.cancelled(ctx, open, cancelled)
      announce_ended(ctx, cancelled)
      deleted
    end
  end

  @doc """
  The person's stop of a workspace thread: everything of its work ends
  in one transaction, in it and in its crew members' threads
  (`Arca.TurnStorage.stop_work/3`), under the stamp each root's attempt
  stores, and the thread is `stopped`; the runtime still holding the
  cancelled turns is the caller's to stop (`Aqua.Runner.stop_cancelled/1`).
  The thread's place in the person's list is announced after the commit.
  """
  @spec stop_work(Context.t(), String.t()) ::
          {:ok, %{cancelled: [map()]}} | {:error, term()}
  def stop_work(%Context{} = ctx, thread_id) do
    actor = Sanctum.Context.actor(ctx)

    children =
      case Threads.children(actor, thread_id) do
        children when is_list(children) -> Enum.map(children, & &1.id)
        {:error, _unread} -> []
      end

    open = open_jobs(ctx, children)

    with {:ok, %{cancelled: cancelled}} = stopped <-
           TurnStorage.stop_work(actor, thread_id, standing(%{error: "stopped"}, :retiring)) do
      # What a turn's own end does after its commit (`finish/4`), for each
      # turn the stop ended, and the deliveries it left nothing to land
      # woken to say so.
      Enum.each(cancelled, &Opus.end_turn_programs(ctx.athanor_id, &1.turn_id))
      announce_lists(ctx, thread_id, nil)
      Activity.cancelled(ctx, open, cancelled)
      announce_ended(ctx, cancelled)
      wake_crew(ctx)
      stopped
    end
  end

  # Each thread whose turns a committed write cancelled hears that its
  # turn finished: the runner holding one, on whichever member, stops
  # what it holds of it on hearing (`Aqua.Runner`).
  defp announce_ended(ctx, cancelled) do
    cancelled
    |> Enum.map(& &1.thread_id)
    |> Enum.uniq()
    |> Enum.each(&broadcast(ctx, &1, :turn_finished, nil))
  end

  @doc """
  An opening whose delivery is refused for good, with the consumer's
  receipt (`Arca.TurnStorage.refuse_opening/4`): the opening ends, and
  the server's `error` report tells the daily thread why the work could
  not start. The thread's place in the person's list is announced and
  the crew's delivery consumer woken after the commit.
  """
  @spec refuse_opening(Context.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def refuse_opening(%Context{} = ctx, workspace_id, opening_id, attrs) when is_map(attrs) do
    with {:ok, thread} <-
           TurnStorage.refuse_opening(Sanctum.Context.actor(ctx), workspace_id, opening_id, attrs) do
      announce_lists(ctx, workspace_id, nil)
      wake_crew(ctx)
      {:ok, thread}
    end
  end

  # The open turns a write that may cancel them leaves no row of after it:
  # read first, so its announcement names the jobs it ended. A read that
  # fails announces none of them.
  defp open_jobs(ctx, thread_ids) do
    case Activity.open_turns(ctx, thread_ids) do
      {:ok, turns} -> turns
      {:error, _unread} -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Workspace threads
  # ---------------------------------------------------------------------------

  @doc """
  Open a workspace thread, or ask an existing one again: the thread, its
  opening and the daily thread's pointer, with the `workspace_open`
  record, in one transaction (`Arca.TurnStorage.open_workspace/2`, whose
  `attrs` these are). The opening and the pointer are broadcast on their
  threads after the commit, both threads' places in the person's list
  are announced, and the crew's delivery consumer is woken.
  """
  @spec open_workspace(Context.t(), map()) ::
          {:ok, %{workspace: map(), opening: row(), pointer: row()}} | {:error, term()}
  def open_workspace(%Context{} = ctx, attrs) when is_map(attrs) do
    with {:ok, %{workspace: workspace, opening: opening, pointer: pointer}} = opened <-
           TurnStorage.open_workspace(Sanctum.Context.actor(ctx), attrs) do
      announce_lists(ctx, workspace.id, nil)
      announce_lists(ctx, pointer.thread_id, nil)
      broadcast(ctx, workspace.id, :message, opening)
      broadcast(ctx, pointer.thread_id, :message, pointer)
      wake_crew(ctx)
      opened
    end
  end

  @doc """
  Report the outcome of the workspace thread `turn` runs in, under its
  fence (`Arca.TurnStorage.report_workspace/4`): its `workspace_report`
  recorded, and the thread moved to the outcome once its work is finished. The thread's place in the person's list is
  announced and the crew's delivery consumer woken after the commit.
  """
  @spec report_workspace(Context.t(), turn(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def report_workspace(%Context{} = ctx, turn, outcome, attrs) when is_map(attrs) do
    with {:ok, thread} <-
           TurnStorage.report_workspace(
             Sanctum.Context.actor(ctx),
             turn.id,
             outcome,
             Map.put_new(attrs, :fence, turn.fence)
           ) do
      announce_lists(ctx, thread.id, nil)
      wake_crew(ctx)
      {:ok, thread}
    end
  end

  @doc """
  A post of `turn` into the thread it runs in, under its fence
  (`Arca.TurnStorage.append_turn_row/3`): its text, and in `:payload` the
  files stored under its `:id` and its links. Broadcast after the commit.
  """
  @spec post(Context.t(), turn(), map()) :: {:ok, row()} | {:error, term()}
  def post(%Context{} = ctx, turn, attrs) when is_map(attrs) do
    with {:ok, row} <-
           turn_row(ctx, turn, %{
             id: Map.fetch!(attrs, :id),
             author: Prima.Author.agent(),
             kind: "text",
             content: Map.get(attrs, :content, ""),
             payload: Map.get(attrs, :payload)
           }) do
      announce_lists(ctx, turn.thread_id, nil)
      {:ok, row}
    end
  end

  @doc """
  A thread's steps across its turns, newest first, by cursor
  (`Arca.TurnStorage.thread_steps/3`).
  """
  @spec thread_steps(Context.t(), String.t(), keyword()) :: {:ok, [step()]} | {:error, term()}
  def thread_steps(%Context{} = ctx, thread_id, opts \\ []),
    do: TurnStorage.thread_steps(Sanctum.Context.actor(ctx), thread_id, opts)

  @doc "The requests of a thread still waiting on a crew member's reply, oldest first."
  @spec pending_requests(Context.t(), String.t()) :: [row()] | {:error, term()}
  def pending_requests(%Context{} = ctx, thread_id),
    do: Threads.pending_requests(Sanctum.Context.actor(ctx), thread_id: thread_id)

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc "The rows a turn may read now, in `seq` order (`TurnStorage.projection/2`)."
  @spec projection(Context.t(), turn()) :: {:ok, [row()]} | {:error, term()}
  def projection(%Context{} = ctx, turn),
    do: TurnStorage.projection(Sanctum.Context.actor(ctx), turn.id)

  @doc "Drain the steer rows past the turn's boundary, moving the boundary."
  @spec drain_steer(Context.t(), turn()) :: {:ok, [row()]} | {:error, term()}
  def drain_steer(%Context{} = ctx, turn),
    do: TurnStorage.drain_steer(Sanctum.Context.actor(ctx), turn.id, %{fence: turn.fence})

  @doc "Whether `row`, of a turn of `agent`, is a post written into it (`TurnStorage.post?/2`)."
  @spec post?(row(), String.t()) :: boolean()
  defdelegate post?(row, agent), to: TurnStorage

  @doc "Whether a steer row waits past the turn's boundary."
  @spec steer_pending?(Context.t(), turn()) :: boolean()
  def steer_pending?(%Context{} = ctx, turn),
    do: TurnStorage.steer_pending?(Sanctum.Context.actor(ctx), turn.id) == true

  @doc "One turn, re-read."
  @spec turn(Context.t(), String.t()) :: {:ok, turn()} | {:error, term()}
  def turn(%Context{} = ctx, turn_id), do: TurnStorage.get(Sanctum.Context.actor(ctx), turn_id)

  @doc "A turn's read threads as its row stands; a turn that cannot be read holds none."
  @spec turn_threads(Context.t(), String.t()) :: [String.t()]
  def turn_threads(%Context{} = ctx, turn_id) do
    case turn(ctx, turn_id) do
      {:ok, %{read_threads: stored}} -> Arca.ThreadStorage.threads_of(stored)
      {:error, _unread} -> []
    end
  end

  @doc "A turn's steps in order."
  @spec steps(Context.t(), turn()) :: {:ok, [step()]} | {:error, term()}
  def steps(%Context{} = ctx, turn), do: TurnStorage.steps(Sanctum.Context.actor(ctx), turn.id)

  @doc "One step, re-read."
  @spec step(Context.t(), String.t()) :: {:ok, step()} | {:error, term()}
  def step(%Context{} = ctx, step_id), do: TurnStorage.step(Sanctum.Context.actor(ctx), step_id)

  @doc """
  What the thread's latest turn (`TurnStorage.latest/2`) has used, as the
  thread's menu shows it and `:usage` tells it: for a turn on a program,
  the models and tokens its `program.start` step stores, unknown and never
  zero while it stores none; for any other turn, the tokens its model
  steps were told, added up. A thread with no turn yet has used none, and
  one that cannot be read now is unknown.
  """
  @spec usage(Context.t(), String.t()) :: map()
  def usage(%Context{} = ctx, thread_id) do
    actor = Sanctum.Context.actor(ctx)

    with {:ok, %{} = turn} <- TurnStorage.latest(actor, thread_id),
         {:ok, steps} <- TurnStorage.steps(actor, turn.id) do
      key = brain_start_key(turn.id)

      case Enum.find(steps, &(&1.idempotency_key == key)) do
        nil when is_nil(turn.program) -> model_usage(steps)
        start -> program_usage(stored_usage(start && start.usage) || %{})
      end
    else
      {:ok, nil} -> %{input: 0, output: 0}
      {:error, _unread} -> %{input: 0, output: 0, accounting: :unavailable}
    end
  end

  defp model_usage(steps) do
    told = for %{kind: "model", usage: usage} <- steps, told = stored_usage(usage), do: told
    sum = fn name -> told |> Enum.map(&(&1[name] || 0)) |> Enum.sum() end
    %{input: sum.("input_tokens"), output: sum.("output_tokens")}
  end

  # A program's counts, by model, and whether they are all of its results'
  # (`Arca.TurnStorage`'s "usage"): none counted is unknown.
  defp program_usage(usage) do
    models = usage["models"] || %{}
    sum = fn name -> models |> Map.values() |> Enum.map(&(&1[name] || 0)) |> Enum.sum() end

    %{
      input: sum.("input_tokens"),
      output: sum.("output_tokens"),
      models: models |> Map.keys() |> Enum.sort(),
      accounting: accounting(usage, models)
    }
  end

  defp accounting(_usage, models) when map_size(models) == 0, do: :unavailable
  defp accounting(%{"partial" => 0, "unknown" => 0}, _models), do: :complete
  defp accounting(_usage, _models), do: :partial

  defp stored_usage(json) when is_binary(json), do: Jason.decode!(json)
  defp stored_usage(usage), do: usage

  @doc "The open turns of a thread, oldest first."
  @spec open_turns(Context.t(), String.t()) :: {:ok, [turn()]} | {:error, term()}
  def open_turns(%Context{} = ctx, thread_id),
    do: TurnStorage.open_turns(Sanctum.Context.actor(ctx), thread_id)

  @doc """
  The open turn a chain's call comes from: the one of the thread the gate's
  lineage names (`args["thread_id"]`) whose root is the lineage's root
  execution (`args["root_execution_id"]`), both stamped by the host and
  never by the caller (`Sanctum.Dispatch`). A call with no open turn behind
  it, such as a component's run started by a key, a webhook or a schedule,
  answers `{:error, :not_addressable}`.
  """
  @spec calling_turn(Context.t(), map()) :: {:ok, turn()} | {:error, term()}
  def calling_turn(%Context{} = ctx, %{"thread_id" => thread_id, "root_execution_id" => root})
      when is_binary(thread_id) and is_binary(root) do
    with {:ok, turns} <- open_turns(ctx, thread_id) do
      case Enum.find(turns, &(&1.root_execution_id == root)) do
        nil -> {:error, :not_addressable}
        turn -> {:ok, turn}
      end
    end
  end

  def calling_turn(%Context{}, _args), do: {:error, :not_addressable}

  @doc """
  The open turn a chain's call comes from (`calling_turn/2`), held by the
  holder that made the call: a call the turn's root made itself names
  the root's attempt in its lineage (`args["attempt"]`, stamped by the
  host), and one whose attempt the turn no longer runs, a holder a
  takeover replaced, is `{:error, :superseded}`. What a write under the
  turn's fence takes it from, so a writer that lost the turn writes
  nothing (`post/3`, `report_workspace/4`).
  """
  @spec held_turn(Context.t(), map()) :: {:ok, turn()} | {:error, term()}
  def held_turn(%Context{} = ctx, args) do
    with {:ok, turn} <- calling_turn(ctx, args) do
      case args do
        %{"parent_execution_id" => root, "root_execution_id" => root, "attempt" => attempt}
        when is_binary(attempt) and attempt != turn.attempt ->
          {:error, :superseded}

        _held ->
          {:ok, turn}
      end
    end
  end

  @doc """
  Every thread with an open root turn, across tenants — the boot's
  recovery scan; `{:error, :unavailable}` when the database cannot answer.
  """
  @spec with_open_turns() :: {:ok, [{String.t(), String.t()}]} | {:error, :unavailable}
  def with_open_turns, do: TurnStorage.with_open_turns()

  @doc "The agent bytes a turn pinned, by their digest."
  @spec agent_revision(Context.t(), turn()) :: {:ok, binary()} | {:error, term()}
  def agent_revision(%Context{} = ctx, %{agent_revision_digest: digest}) when is_binary(digest),
    do: Arca.AgentRevisions.get(Context.actor(ctx), digest)

  @doc """
  Announce an ephemeral console event on the thread's topic — a
  delta, the tool activity, the usage, the sender's intents — without a
  row: a `Cyfr.Bus.ThreadEvent` of `kind` carrying `data`.
  """
  @spec announce(Context.t(), String.t(), Cyfr.Bus.ThreadEvent.kind(), term()) :: :ok
  def announce(%Context{} = ctx, thread_id, kind, data \\ nil),
    do: broadcast(ctx, thread_id, kind, data)

  @doc "The decoded `payload` of a message row."
  @spec payload(row()) :: map()
  def payload(row), do: Threads.payload(row)

  # What a row says it depends on and cites, read from that row alone
  # (`TurnStorage.join_read/3`'s `also:`).
  defp said_by(row) do
    %{
      names: named(row),
      copies: kept(row) ++ files_carried(row),
      from: from_turn(row),
      cites: cites(row)
    }
  end

  defp named(%{workspace_id: id}) when is_binary(id), do: [id]

  defp named(%{kind: "opening"} = row) do
    case payload(row) do
      %{"from" => %{"thread" => id}} -> ids(id)
      _none -> []
    end
  end

  defp named(_row), do: []

  defp cites(%{kind: "opening"} = row) do
    case payload(row) do
      %{"from" => %{"thread" => daily}, "refs" => refs} when is_binary(daily) and is_list(refs) ->
        %{thread: daily, posts: ids(refs)}

      _none ->
        nil
    end
  end

  defp cites(_row), do: nil

  defp kept(%{kind: "report"} = row), do: ids(payload(row)["read_threads"])
  defp kept(_row), do: []

  defp files_carried(row),
    do: Enum.flat_map(Aqua.Attachments.refs_of(row), &Aqua.Attachments.copied_threads/1)

  defp from_turn(row), do: ids(payload(row)["from_turn"])

  defp ids(stored), do: for(id <- List.wrap(stored), is_binary(id) and id != "", do: id)

  @doc "One message row of the tenant."
  @spec message(Context.t(), String.t()) :: {:ok, row()} | {:error, term()}
  def message(%Context{} = ctx, message_id),
    do: Threads.get_message(Sanctum.Context.actor(ctx), message_id)

  @doc "The thread a turn belongs to."
  @spec thread(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def thread(%Context{} = ctx, thread_id), do: Threads.get(Sanctum.Context.actor(ctx), thread_id)

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  # The thread's place in its person's list and, for a crew member's turn,
  # its job, announced before the thread's own events: a holder of the
  # thread acts on those, so nothing of this write is still reading once
  # they are heard.
  defp announce_lists(ctx, thread_id, job) do
    ThreadList.changed(ctx, thread_id)

    case job do
      {:started, turn} -> Activity.started(ctx, turn)
      {:ended, turn} -> Activity.ended(ctx, turn)
      nil -> :ok
    end
  end

  # What a row is to a viewer: a request to a crew member, a reply
  # answering one, or any other row.
  defp row_kind(%{reply_to: reply_to}) when is_binary(reply_to), do: :reply

  defp row_kind(%{addressee: addressee, status: status})
       when is_binary(addressee) and status in ["pending", "answered"],
       do: :request

  defp row_kind(_row), do: :message

  # A workspace thread's turn ending may have recorded a report
  # (`Arca.TurnStorage`'s host moves); a read that fails wakes nobody, and
  # the consumer's tick delivers it.
  defp workspace?(ctx, thread_id),
    do: match?({:ok, %{kind: "workspace"}}, Threads.get(Sanctum.Context.actor(ctx), thread_id))

  # A wake-up for the delivery consumer, after the commit that recorded
  # its work; a lost one is delivered by its tick.
  defp wake_crew(ctx) do
    _ =
      Cyfr.Bus.broadcast_global(
        Cyfr.Bus.crew_deliveries(),
        Cyfr.Bus.CrewPending.new(Sanctum.Context.actor(ctx))
      )

    :ok
  end

  # Durable rows reach viewers only after their transaction committed. A
  # row is plain data already (`Arca.TurnStorage` answers maps); a
  # refused or failed publish costs the viewers one update, never the
  # write.
  defp broadcast(ctx, thread_id, kind, data) do
    actor = Sanctum.Context.actor(ctx)
    event = Cyfr.Bus.ThreadEvent.new(actor, thread_id, kind, data)
    _ = Cyfr.Bus.broadcast(actor, Cyfr.Bus.thread(actor, thread_id), event)
    :ok
  end

  # The same send, as far as the rows can tell: actor, text, attachments,
  # and the work it asked for.
  defp same_send?(message, turn, attrs) do
    wanted = Map.get(attrs, :message, %{})
    wanted_turn = Map.get(attrs, :turn)
    payload = Threads.payload(message)

    message.author == Map.get(wanted, :author) and
      message.content == (Map.get(wanted, :content) || "") and
      Map.get(payload, "attachments") == attachments_of(Map.get(wanted, :payload)) and
      same_work?(turn, wanted_turn, Map.get(attrs, :steer_turn_id))
  end

  defp attachments_of(nil), do: nil

  defp attachments_of(payload) when is_map(payload), do: payload["attachments"]

  defp same_work?(nil, nil, nil), do: true

  defp same_work?(%{id: id}, nil, steer_id) when is_binary(steer_id), do: id == steer_id

  defp same_work?(%{message_id: message_id} = turn, %{} = wanted, nil)
       when is_binary(message_id) do
    turn.agent == Map.get(wanted, :agent) and
      turn.model == Map.get(wanted, :model) and
      turn.options == encode(Map.get(wanted, :options))
  end

  defp same_work?(_turn, _wanted, _steer), do: false

  defp encode(nil), do: nil
  defp encode(value), do: Jason.encode!(value)
end
