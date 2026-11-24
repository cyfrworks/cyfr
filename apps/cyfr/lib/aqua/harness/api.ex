# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Harness.Api do
  @moduledoc """
  The harness of a turn answered by a model through its catalyst
  (`Aqua.Harness`): one `Aqua.Loop.Worker` task for the turn, owned by the
  loop that holds it, which runs the turn's rounds and nothing of the
  engine's.

  A round starts when the loop says the rows moved (`moved/1`) and they
  owe one: no ask of the last round is still proposed or dispatched, and
  either a post waits or the model's last answer was not one that called
  nothing. It drains the steer, reads the turn's rows (`work.history`),
  plans the request (a compaction first when the window is full, preceded
  by a note flush), records the model step before the call, makes the
  call in a child worker under the turn's pinned brain grant, and commits
  the whole answer, its text, its asks and its usage, in one write
  (`Aqua.Tape.commit_events/3`) before the loop is told of it. The loop
  decides and runs the asks, a flush's among them; an answer that calls
  nothing is the harness's work done, said again on each later word that
  brings nothing new.

  The step cap and the deadline are this harness's, checked as a round
  starts: a batch that crosses the deadline runs to its end. A refused
  retryable answer is asked again after a pause. A model step the rows
  refuse while the turn's root is let go around a launch is asked again
  once the rows move. Every end is a reason (`Prima.Refusal`), never a
  sentence; the engine writes it.

  Its call runs as a child of the turn's root, so a launch, which lets the
  root go, waits while it runs: the rows refuse the launch's pause
  (`Arca.TurnStorage.pause/3`). A newer post supersedes the
  calls not yet started (`supersedes?`). A Stop while the call runs stops
  its worker, cancels its child, joins what the child read and closes the
  step as stopped (`stop/1`).
  """

  @behaviour Aqua.Harness

  require Logger

  alias Aqua.Loop.Binding
  alias Aqua.Loop.Binding.Call
  alias Aqua.Loop.{Planner, Policy, Request, Turn}
  alias Aqua.{Reader, Tape}

  @facts %{supersedes?: true, own_tools?: false}
  @max_steps 30
  @retry_delays_ms [2_000, 8_000, 20_000]
  # `{"operation":"chat","params":}` around the request, which is what
  # `Opus.Admission` encodes and weighs against the node's cap.
  @envelope_bytes 30
  # A retry opens a new step at a higher ordinal, and the refused step is
  # abandoned, so text a refused step streamed is withdrawn, never shown
  # beside the retry's (`Aqua.Loop.Stream`).
  @recoverable ~w(rate_limited overloaded incomplete_stream)
  # A refusal for want of a key bound to the brain is the brain's own
  # state, a key to enter (`Aqua.Loop.Turn.key_refusals/0`); a key the
  # provider refused (`authentication`) is the provider's to say.
  @setup Turn.key_refusals()
  @refused_key "authentication"
  # A note flush offers this action alone (`Aqua.Loop.Policy.flush_call/0`).
  @flush_tool elem(Policy.flush_call(), 0)
  @flush_action elem(Policy.flush_call(), 1)
  @flush_key "#{@flush_tool}.#{@flush_action}"
  @flush_instruction "The older part of this thread is about to be summarized, and what " <>
                       "the summary leaves out will be gone. Keep anything worth remembering " <>
                       "beyond it — a decision, a preference, a fact the work will need — with " <>
                       "notes.keep now. Reply with nothing else."

  defstruct [
    :work,
    :spec,
    :turn,
    :loop,
    steps: 0,
    observed: nil,
    # The highest seq the measured request carried, so rows appended since
    # can be counted. A bare token count says nothing about which rows it
    # was a count of.
    observed_seq: 0,
    sent_upto: 0,
    excerpt_sent?: false,
    # An end other than done was said: the harness rests until it is
    # stopped.
    over?: false
  ]

  # ===========================================================================
  # The boundary
  # ===========================================================================

  @doc """
  Open the turn's rounds: a worker task of the calling loop, which waits
  for the loop's first word. Opening never waits for the model.
  """
  @impl Aqua.Harness
  def open(work) do
    loop = self()
    task = Aqua.Loop.Worker.async(fn -> run(work, loop) end)
    {:ok, task.pid, @facts}
  end

  @doc "The turn's rows moved: what is owed is read from them."
  @impl Aqua.Harness
  def moved(harness) when is_pid(harness) do
    send(harness, :moved)
    :ok
  end

  @doc """
  The turn is held no longer, or is stopped: a call that runs is stopped
  and its step closed as stopped, and this answers once the harness is
  gone.
  """
  @impl Aqua.Harness
  def stop(harness) when is_pid(harness) do
    monitor = Process.monitor(harness)
    send(harness, :stop)

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    end
  end

  @doc "What the engine reads of this harness (`Aqua.Harness.facts/1`)."
  @impl Aqua.Harness
  def facts, do: @facts

  # ===========================================================================
  # The rounds
  # ===========================================================================

  defp run(work, loop) do
    with {:ok, steps} <- Tape.steps(work.guest, work.turn) do
      rest(%__MODULE__{
        work: work,
        spec: work.spec,
        turn: work.turn,
        loop: loop,
        steps: Enum.count(steps, &(&1.kind == "model"))
      })
    else
      {:error, _unread} ->
        %__MODULE__{work: work, spec: work.spec, turn: work.turn, loop: loop}
        |> lost(:write_failed)
        |> rest()
    end
  end

  # The harness waits for the loop's word; a Stop ends it, and a word that
  # the rows moved is taken with every one queued behind it.
  defp rest(%__MODULE__{} = state) do
    receive do
      :stop -> exit(:normal)
      :moved -> state |> tap(fn _ -> drain_moved() end) |> act() |> rest()
    end
  end

  defp drain_moved do
    receive do
      :moved -> drain_moved()
    after
      0 -> :ok
    end
  end

  # What the rows owe: nothing while a call of the turn is still open, an
  # ask of the last round or a page's, whose result the next request
  # carries; a round when a post waits or the last answer was not one that
  # called nothing, and otherwise the work is done. A turn whose row pins
  # no brain grant (a server's line that no longer stood) asks no model:
  # it is done, unless a post asks it again, which no brain can answer.
  defp act(%__MODULE__{over?: true} = state), do: state

  defp act(%__MODULE__{} = state) do
    with {:ok, steps} <- Tape.steps(guest(state), state.turn) do
      cond do
        Enum.any?(steps, &open_ask?/1) ->
          state

        state.spec.brain_authority == nil ->
          if Tape.steer_pending?(guest(state), state.turn),
            do: refused(state, {:crew_unready, Turn.brain_title(state.spec.agent), :unavailable}),
            else: done(state)

        Tape.steer_pending?(guest(state), state.turn) or not answered?(steps) ->
          next_round(state)

        true ->
          done(state)
      end
    else
      {:error, _unread} -> lost(state, :write_failed)
    end
  end

  defp open_ask?(%{kind: kind, dispatch_state: dispatch}) when kind not in ["model", "input"],
    do: dispatch in ["proposed", "dispatched"]

  defp open_ask?(_step), do: false

  # Whether the model's last answer called nothing: no step but a page's
  # came after it.
  defp answered?(steps) do
    case steps |> Enum.reverse() |> Enum.drop_while(&(&1.purpose == "page")) do
      [%{kind: "model", purpose: "chat", dispatch_state: "closed", outcome: "ok"} | _] -> true
      _ -> false
    end
  end

  defp next_round(%__MODULE__{} = state) do
    cond do
      over_deadline?(state) -> refused(state, harness_reason(state, :deadline))
      state.steps >= @max_steps -> refused(state, harness_reason(state, :step_cap))
      true -> model_round(state)
    end
  end

  defp model_round(%__MODULE__{} = state) do
    with {:ok, _drained} <- Tape.drain_steer(guest(state), state.turn),
         {:ok, rows, reading} <- projected(state),
         reading = %{reading | removed: removed_files(state.spec.ctx, rows)},
         files = later_files(state, rows),
         {:ok, planned, rows, reading} <- compact(state, rows, reading, files),
         {:ok, step, planned} <- open_model_step(planned, "chat") do
      excerpt = if planned.excerpt_sent?, do: nil, else: planned.spec.excerpt
      request = request(planned, rows, reading, excerpt, files)
      planned = %{planned | sent_upto: highest_seq(rows)}

      excluded =
        if excerpt do
          Tape.mark_excluded(guest(planned), planned.turn, step, %{
            excluded: ["room_excerpt"],
            request_digest: digest(request)
          })
        else
          {:ok, :none}
        end

      case kept(excluded) do
        :ok ->
          ask_model(
            %{planned | excerpt_sent?: true},
            step,
            request,
            retained(request, excerpt),
            0
          )

        {:lost, kind} ->
          lost(state, kind)
      end
    else
      {:error, reason} -> unopened(state, reason)
    end
  end

  # A round that did not reach its model's call. The turn's root is let go
  # around a launch: the round is asked again once the rows move.
  defp unopened(state, :illegal_transition), do: state
  defp unopened(state, :step_cap), do: refused(state, harness_reason(state, :step_cap))
  defp unopened(state, :superseded), do: lost(state, :ended)
  defp unopened(state, _reason), do: lost(state, :write_failed)

  defp ask_model(%__MODULE__{} = state, step, request, retained, retries) do
    case model_call(state, step, request, retained) do
      {:ok, data} ->
        on_response(state, step, data)

      # The turn's fence moved before the model's read threads could join it.
      {:error, :superseded} ->
        lost(state, :ended)

      # The retry's step opens before the failed one closes and before the
      # delay: the rows show the round's work throughout, so an earlier
      # done the loop has not yet finished on cannot end the turn under it.
      {:error, %{"type" => type}}
      when type in @recoverable and retries < length(@retry_delays_ms) ->
        case open_model_step(state, "chat") do
          {:ok, again, reopened} ->
            case closed(state, step, type) do
              :ok ->
                pause(reopened, again, Enum.at(@retry_delays_ms, retries))
                ask_model(reopened, again, request, retained, retries + 1)

              {:lost, kind} ->
                lost(reopened, kind)
            end

          {:error, reason} ->
            case closed(state, step, type) do
              :ok -> unopened(state, reason)
              {:lost, kind} -> lost(state, kind)
            end
        end

      # The brain's grant stands but holds no key to use, as the catalyst
      # says or as its admission refuses it: the brain's own state.
      {:error, %{"type" => type} = error} when type in @setup ->
        no_key(state, step, error["message"])

      # The brain's grant the turn pinned moved since (its key bound
      # again): admission refuses the call, and the turn moved on.
      {:error, {:setup_required, %{reason: "consent_moved"}}} ->
        then_refused(state, closed(state, step, "consent_moved"), :consent_moved)

      {:error, {:setup_required, _detail}} ->
        no_key(state, step, "setup_required")

      {:error, %{"type" => @refused_key} = error} ->
        then_refused(
          state,
          closed(state, step, error["message"]),
          {:model_key_refused, error["message"]}
        )

      {:error, %{"type" => type, "message" => message}} ->
        then_refused(
          state,
          closed(state, step, message),
          harness_reason(state, {:provider, type, message})
        )

      # A model request that died left nothing a person must judge
      # (`Prima.TurnStep.unresolved/1`): it ends the turn like a refusal.
      {failure, reason} when failure in [:error, :exit] ->
        text = describe(reason)

        case closed(state, step, text) do
          :ok -> lost(state, {:model_unreached, text})
          {:lost, kind} -> lost(state, kind)
        end
    end
  end

  # A brain whose grant holds no key to use is said as the brain's own
  # state, a line pointing at the Aqua page (`Aqua.Crew.unready/1`'s
  # `:no_key`), where its row in Aqua's setup takes the key.
  defp no_key(%__MODULE__{} = state, step, error) do
    then_refused(
      state,
      closed(state, step, error),
      {:crew_unready, Turn.brain_title(state.spec.agent), :no_key}
    )
  end

  # The whole response lands before any call runs: the loop is told of its
  # asks once they are written, and an answer that calls nothing is the
  # work done.
  defp on_response(%__MODULE__{} = state, step, data) do
    content = List.wrap(data["content"])
    text = content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("", & &1["text"])
    asks = resolve_calls(state, step, content)

    case commit_response(state, step, data, if(text == "", do: nil, else: text), asks) do
      {:ok, %{asks: []}} ->
        state |> count_usage(data) |> done()

      {:ok, %{asks: recorded}} ->
        state
        |> count_usage(data)
        |> tell({:ask, Enum.map(recorded, & &1.step)})

      {:error, :superseded} ->
        lost(state, :ended)

      {:error, _reason} ->
        lost(state, :write_failed)
    end
  end

  # What the turn has used is told to the loop, which says it as the rows
  # count it, and the request's measured size is kept for the next plan.
  defp count_usage(%__MODULE__{} = state, data) do
    state = tell(state, {:usage, data["usage"]})

    case (data["usage"] || %{})["input_tokens"] do
      input when is_integer(input) and input > 0 ->
        %{state | observed: input, observed_seq: state.sent_upto}

      _none ->
        state
    end
  end

  # The model's worker is waited for until it answers or dies, as every
  # worker is (`Aqua.Loop`), and a Stop meanwhile stops it: the worker,
  # then its child, whose read threads join the turn as a dead worker's
  # do, and its step closes as stopped. The loop's word that the rows moved
  # waits in the mailbox for the round's end.
  defp model_wait(%__MODULE__{} = state, step, %Aqua.Loop.Worker.Handle{ref: ref} = task) do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:exit, reason}

      :stop ->
        Aqua.Loop.Worker.shutdown(task)
        Opus.cancel(ctx(state), step.child_execution_id)

        _ =
          Tape.join_threads(
            guest(state),
            state.turn,
            read_threads(state, step.child_execution_id)
          )

        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: "stopped"})
        exit(:normal)
    end
  end

  # A pause before a retry, with the retry's step open, which a Stop ends:
  # the step then closes as stopped, as a model's call a Stop ends does.
  defp pause(%__MODULE__{} = state, step, ms) do
    receive do
      :stop ->
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: "stopped"})
        exit(:normal)
    after
      ms -> :ok
    end
  end

  # The asks of a flush are the loop's to decide and run: the flush waits
  # for each to close before the summary is made.
  defp await_settled(%__MODULE__{} = state, ids) do
    with {:ok, steps} <- Tape.steps(guest(state), state.turn) do
      if Enum.any?(steps, &(&1.id in ids and &1.dispatch_state in ["proposed", "dispatched"])) do
        receive do
          :stop -> exit(:normal)
          :moved -> await_settled(state, ids)
        end
      else
        :ok
      end
    end
  end

  # ===========================================================================
  # What the harness says
  # ===========================================================================

  defp tell(%__MODULE__{} = state, event) do
    send(state.loop, {Aqua.Harness, state.turn.id, event})
    state
  end

  defp done(%__MODULE__{} = state), do: tell(state, {:end, :done})

  defp refused(%__MODULE__{} = state, reason),
    do: %{tell(state, {:end, {:refused, reason}}) | over?: true}

  defp lost(%__MODULE__{} = state, kind) when is_atom(kind),
    do: %{tell(state, {:end, {:lost, harness_reason(state, kind)}}) | over?: true}

  defp lost(%__MODULE__{} = state, reason),
    do: %{tell(state, {:end, {:lost, reason}}) | over?: true}

  defp harness_reason(%__MODULE__{} = state, kind), do: {:harness, state.work.title, kind}

  # A write on the turn's path is never dropped (E2): one not kept ends the
  # harness, and with it the loop unwritten (`Aqua.Loop`), and one refused
  # for a moved fence leaves the turn to whoever took it. A step its own
  # answer closed already stays as it is.
  defp closed(%__MODULE__{} = state, step, error),
    do: kept(Tape.close_step(guest(state), state.turn, step, "error", %{error: error}))

  defp kept({:ok, _written}), do: :ok
  defp kept({:error, :not_dispatched}), do: :ok

  defp kept({:error, taken}) when taken in [:superseded, :not_open, :already_finished],
    do: {:lost, :ended}

  defp kept({:error, _unkept}), do: {:lost, :write_failed}

  defp then_refused(state, :ok, reason), do: refused(state, reason)
  defp then_refused(state, {:lost, kind}, _reason), do: lost(state, kind)

  # A flush that did not land is skipped, unless its step's close was not
  # kept: then nothing goes on after it.
  defp skipped(state, :ok), do: {:skipped, state}
  defp skipped(_state, {:lost, :ended}), do: {:error, :superseded}
  defp skipped(_state, {:lost, _kind}), do: {:error, :write_failed}

  # ===========================================================================
  # The request
  # ===========================================================================

  # The turn's rows as they stand now and their reading, joined before any
  # is read (`Aqua.Reader.join/5`).
  defp projected(%__MODULE__{} = state) do
    with {:ok, %{rows: rows, reading: reading}} <- state.work.history.(fn _row -> true end, []),
         do: {:ok, rows, reading}
  end

  # The rows again after the round wrote some, with the files deleted as
  # the round first read them: a compaction keeps a subset of those rows.
  defp reprojected(%__MODULE__{} = state, %{removed: removed}) do
    with {:ok, rows, reading} <- projected(state),
         do: {:ok, rows, %{reading | removed: removed}}
  end

  # The deadline is the turn's active time against its limit, checked as a
  # round starts (`work.active_ms`).
  defp over_deadline?(%__MODULE__{spec: %Turn{deadline_ms: limit}} = state)
       when is_integer(limit),
       do: state.work.active_ms.() >= limit

  defp over_deadline?(_state), do: false

  # Where a call is made (`Aqua.Loop.Policy.decide/3`).
  defp place(%__MODULE__{spec: spec}), do: [title: spec.agent["title"], ctx: spec.ctx]

  defp describe(reason), do: Aqua.Loop.describe(reason)

  defp guest(%__MODULE__{spec: %Turn{guest: guest}}), do: guest
  defp ctx(%__MODULE__{spec: %Turn{ctx: ctx}}), do: ctx

  # Every round carries the sender's attachments, and those of each later
  # post written into the turn (`files`, `later_files/2`): the projection
  # renders text, and an image or a document exists only as these typed
  # blocks, so a round without them would not show the model what it was
  # asked about.
  defp request(%__MODULE__{spec: spec} = state, rows, reading, excerpt, files) do
    # The opening post's files were read as the turn was built: they go only
    # while that post is still the turn's to read.
    attachments =
      if Enum.any?(rows, &(&1.id == state.turn.message_id)), do: spec.attachments, else: []

    rows = Planner.prune(rows)
    authors = rows |> Enum.map(& &1.author) |> Enum.uniq() |> Enum.reject(&agent_or_system?/1)

    messages =
      Request.messages(rows, %{reading | named?: length(authors) > 1},
        excerpt: excerpt,
        attachments: attachments,
        task_message_id: state.turn.message_id,
        files: files
      )

    Request.build(
      model: spec.model,
      # The turn's instructions and the facts that move by themselves, which
      # the engine hands apart, are one system prompt of one request here.
      system: Aqua.Prompt.system(state.work.system, state.work.facts),
      messages: messages,
      tools: spec.tools,
      capabilities: spec.capabilities,
      offers_search?: offers_search?(spec),
      options: spec.brain_options
    )
  end

  defp agent_or_system?(author),
    do: author in Prima.Author.reserved()

  # The files the person deleted (`Aqua.Reader.removed/2`): read once a
  # round, before the size estimate, which the dispatch shares, and only
  # for the rows the request carries to the model (`Request.carried/1`).
  defp removed_files(ctx, rows),
    do: Reader.removed(ctx, rows |> Planner.prune() |> Request.carried())

  # By row id, the files of each post written into the turn after the one
  # that opened it (a drained steer, `Tape.post?/2`), as blocks the brain
  # takes, made as the opening post's are (`Turn.file_blocks/3`). Read once
  # a round, beside `removed_files/2`, and only for the rows the request
  # carries; the opening post's ride `spec.attachments`.
  defp later_files(%__MODULE__{spec: spec, turn: turn}, rows) do
    for row <- rows |> Planner.prune() |> Request.carried(),
        row.turn_id == turn.id and row.id != turn.message_id and Tape.post?(row, turn.agent),
        Aqua.Attachments.refs_of(row) != [],
        into: %{},
        do: {row.id, Turn.file_blocks(spec.ctx, row, spec.capabilities.media_types)}
  end

  # The model step opens dispatched, before the call: a recovery finds it
  # without a response and never replays it. A chat step carries the posts
  # its request holds in that same write (`TurnStorage.put_step/3`), so a
  # post is never carried by a step that was not dispatched.
  # Every model step opened — a chat round, its retry, a compaction —
  # counts against the turn's cap, before it opens; the count is the
  # turn's, rebuilt from its rows on a continuation.
  #
  # What its request carries joined the turn before it was read
  # (`projected/1`).
  defp open_model_step(%__MODULE__{steps: steps}, _purpose) when steps >= @max_steps,
    do: {:error, :step_cap}

  defp open_model_step(%__MODULE__{} = state, purpose) do
    with {:ok, step} <-
           Tape.record_model_intent(guest(state), state.turn, %{
             idempotency_key:
               "model:#{state.turn.id}:#{System.unique_integer([:positive, :monotonic])}",
             child_execution_id: Prima.UUID7.execution_id(),
             tool: state.spec.catalyst,
             action: "chat",
             purpose: purpose,
             dispatch_state: "dispatched"
           }) do
      {:ok, step, %{state | steps: state.steps + 1}}
    end
  end

  # The request offers web search when the policy turns it on, the grant
  # carries it and the model has the tool.
  defp offers_search?(spec),
    do: Request.offers_search?(spec.offered, spec.authority, spec.capabilities)

  # The catalyst runs as a child of the root, in a worker, under the
  # brain's own grant the turn pinned (`Aqua.Loop.Turn`): the answer is
  # the contract's data, a typed refusal, the engine's refusal, or the
  # worker's death. The worker is waited for until the run ends, as every
  # worker is (`model_wait/3`). A chat step's text streams to the
  # thread while it runs, and is withdrawn when the step lands no text row;
  # a flush or a compaction streams nothing.
  #
  # Whatever it answers, the child's read threads join the step's turn
  # before the answer is handed back (`model_threads/3`): every use of a
  # model's output — a chat reply, a flush's notes, a compaction's
  # summary, a refusal's text — passes through here, and none happens
  # unless the join was written. A turn whose fence moved answers
  # `:superseded`.
  # What the model is handed is the request delivered
  # (`Aqua.Reader.deliver/2`): every text in it read without the thread's
  # mark, the engine's frames and rule then given it. The one place a
  # request of any purpose passes before it leaves.
  defp model_call(%__MODULE__{spec: spec} = state, step, request, retained) do
    mark = Reader.mark(state.turn.thread_id)
    input = %{"operation" => "chat", "params" => Reader.deliver(request, mark)}

    retained_input =
      retained && %{"operation" => "chat", "params" => Reader.deliver(retained, mark)}

    guest = guest(state)
    turn = state.turn
    streamed = stream_attrs(state, step)
    stream = streamed && Aqua.Loop.Stream.open(guest, step.child_execution_id, streamed)

    run = fn ->
      Opus.run_child(spec.brain_authority, spec.catalyst, nil, input,
        ctx: guest,
        execution_id: step.child_execution_id,
        step_id: step.id,
        parent_execution_id: turn.root_execution_id,
        root_execution_id: turn.root_execution_id,
        declared_needs: [],
        retention_class: "chat_step",
        retained_input: retained_input,
        charge: Binding.charge(step, turn),
        guest_fn: :spawn,
        envelope: true
      )
    end

    answer =
      try do
        model_wait(state, step, Aqua.Loop.Worker.async(run))
      after
        Aqua.Loop.Stream.close(stream)
      end

    result =
      case Tape.join_threads(guest, turn, model_threads(state, step, answer)) do
        :ok -> model_result(answer)
        {:error, :superseded} -> {:error, :superseded}
        {:error, _unwritten} -> {:error, :read_threads_unrecorded}
      end

    if streamed && not lands_text?(result), do: Aqua.Loop.Stream.abandon(guest, streamed)
    result
  end

  defp model_result({:ok, {:ok, %{output: output}}}), do: Prima.Model.decode_envelope(output)
  defp model_result({:ok, {:ok, output}}), do: Prima.Model.decode_envelope(output)
  defp model_result({:ok, {:error, reason}}), do: {:error, reason}
  defp model_result({:exit, reason}), do: {:exit, reason}

  # The read threads a model child's answer brings into its turn: what its
  # completion result carries, else its row's, read by the id the step
  # minted for it — a worker that died included, since its child may have
  # read before it did.
  defp model_threads(state, step, {:ok, answer}),
    do: child_threads(state, step.child_execution_id, answer)

  defp model_threads(state, step, {:exit, _reason}),
    do: read_threads(state, step.child_execution_id)

  # A child's read threads by the first carrier that holds them
  # (`Aqua.Loop.Policy.child_threads/1`): its completion result's, none
  # for a refusal made before any attempt existed, else its row's.
  defp child_threads(state, child_id, answer) do
    case Policy.child_threads(answer) do
      {:carried, threads} -> threads
      :nothing_ran -> []
      :unknown -> read_threads(state, child_id)
    end
  end

  # A child's read threads read from its row by the id the loop minted for
  # it. A row no longer held — retention prunes a terminal child while its
  # turn still runs — or one that cannot be read adds none.
  defp read_threads(state, child_id) when is_binary(child_id) do
    case Opus.read_threads(ctx(state), child_id) do
      {:ok, threads} -> threads
      {:error, _gone_or_unreadable} -> []
    end
  end

  defp read_threads(_state, _no_id), do: []

  # A turn's text streams under its own fence, named by its agent when
  # that is not the soul.
  defp stream_attrs(%__MODULE__{} = state, %{purpose: "chat"} = step) do
    %{
      thread_id: state.turn.thread_id,
      turn_id: state.turn.id,
      fence: state.turn.fence,
      source: state.turn.id,
      step_id: step.id,
      ordinal: state.steps,
      role: if(state.spec.soul?, do: nil, else: state.spec.agent["name"])
    }
  end

  defp stream_attrs(_state, _step), do: nil

  defp lands_text?({:ok, data}),
    do:
      Enum.any?(
        List.wrap(data["content"]),
        &(&1["type"] == "text" and &1["text"] not in [nil, ""])
      )

  defp lands_text?(_result), do: false

  # A model's calls as the steps proposed for them, with their `tool_call`
  # rows, as a program's asks are (`Aqua.Harness.ask/5`).
  defp resolve_calls(%__MODULE__{} = state, step, content) do
    for %{"type" => "tool_call"} = block <- content do
      name = block["name"] || ""
      args = if is_map(block["arguments"]), do: block["arguments"], else: %{}
      id = block["id"] || Prima.UUID7.generate_id("call")

      Aqua.Harness.ask(name, args, id, "call:#{state.turn.id}:#{step.id}:#{id}", %{
        "provider_data" => block["provider_data"],
        "step_id" => step.id
      })
    end
  end

  # A model's response lands whole with its step's close, through the one
  # writer of what a harness says (`Aqua.Tape.commit_events/3`): its text,
  # its calls and its usage, counted onto the step.
  defp commit_response(%__MODULE__{} = state, step, data, text, asks) do
    events =
      if(text, do: [{:text, %{text: text}}], else: []) ++
        Enum.map(asks, &{:ask, &1}) ++
        [{:usage, usage_event(state, data)}, {:stop, data["stop_reason"]}]

    Tape.commit_events(
      guest(state),
      %{
        thread: state.turn.thread_id,
        agent: state.turn.agent,
        turn: %{id: state.turn.id, fence: state.turn.fence}
      },
      %{events: events, position: {:step, step.id}}
    )
  end

  # What the model ran and its counts, as a program's usage is told: the
  # model the catalyst says answered, else the one asked for; a count it
  # did not tell is not a zero, so the result is partial, and with neither
  # count it is unknown.
  defp usage_event(%__MODULE__{spec: spec}, data) do
    usage = if is_map(data["usage"]), do: data["usage"], else: %{}
    counts = for {name, n} <- usage, is_integer(n), into: %{}, do: {name, n}
    told = Enum.count(~w(input_tokens output_tokens), &Map.has_key?(counts, &1))
    model = if is_binary(data["model"]), do: data["model"], else: spec.model || "default"

    case told do
      0 -> %{"models" => [], "accounting" => "unavailable"}
      1 -> %{"models" => [%{"model" => model, "counts" => counts}], "accounting" => "partial"}
      2 -> %{"models" => [%{"model" => model, "counts" => counts}], "accounting" => "complete"}
    end
  end

  defp compact(%__MODULE__{spec: spec} = state, rows, reading, files, flush? \\ true) do
    # Size the request the way the executor will: it encodes the input and
    # refuses it past the consented cap of the node being entered, which for
    # a model call is the catalyst, not the agent. Without this the turn
    # fails at admission on a request compaction could have made fit.
    excerpt = if state.excerpt_sent?, do: nil, else: spec.excerpt
    probe = request(state, rows, reading, excerpt, files)

    case Planner.plan(rows,
           capabilities: spec.capabilities,
           max_tokens: Request.max_tokens(spec.capabilities),
           observed_tokens: state.observed,
           new_bytes: appended_bytes(rows, state.observed_seq),
           request_bytes: encoded_size(probe),
           max_request_size: spec.request_cap
         ) do
      :fit ->
        {:ok, state, rows, reading}

      {:compact, %{summarized_through_seq: 0}} ->
        # Nothing older than the boundary: a summary of no rows costs a model
        # call and writes a row that stands for nothing. The estimate counts
        # only transcript rows, so on a small window the system prompt and
        # tool definitions alone can ask for this every round.
        {:ok, state, rows, reading}

      {:compact, boundary} when flush? ->
        # The flush's rows are newer than any boundary, so the plan is made
        # again over the rows as they now stand.
        case flush(state, rows, probe) do
          {:flushed, state} ->
            with {:ok, rows, reading} <- reprojected(state, reading),
                 do: compact(state, rows, reading, files, false)

          {:skipped, state} ->
            summarize(state, rows, boundary, reading)

          {:error, _superseded_or_unkept} = ended ->
            ended
        end

      {:compact, boundary} ->
        summarize(state, rows, boundary, reading)
    end
  end

  # One silent request before older rows are summarized away, so the model
  # can keep notes: `notes.keep` alone, when the policy runs it and its
  # offered set holds it, in a turn no unknown outcome
  # restricts, with room left for the flush, the summary and the next chat
  # request, and only when the request fits the catalyst's cap.
  defp flush(%__MODULE__{spec: spec} = state, rows, probe) do
    cap = spec.request_cap

    with true <- flush_room?(state.steps, Tape.restricted?(guest(state), state.turn)),
         offered = Turn.current_offered(spec),
         true <- flush_runs?(state, offered),
         request = flush_request(probe, Map.put(offered, @flush_key, "offered")),
         size when is_integer(size) and (is_nil(cap) or size <= cap) <- encoded_size(request),
         {:ok, step, opened} <- open_model_step(state, "flush") do
      keep_notes(%{opened | sent_upto: highest_seq(rows)}, step, request)
    else
      {:error, :superseded} = superseded -> superseded
      {:error, reason} when reason in [:step_cap, :illegal_transition] -> {:skipped, state}
      # The flush's step was not written: nothing goes on after it.
      {:error, _unkept} -> {:error, :write_failed}
      _not_flushed -> {:skipped, state}
    end
  end

  # A flush runs only where a keep would: the member is offered it. Each
  # kept note is decided again as it dispatches.
  defp flush_runs?(%__MODULE__{} = state, offered) do
    probe = %Call{
      kind: :catalog,
      tool: @flush_tool,
      action: @flush_action,
      args: %{},
      model_name: @flush_key
    }

    Policy.decide(probe, offered, place(state)) == :run
  end

  # The gate a flush passes before the offered set is read: a turn no
  # unknown outcome restricts, with room for the flush, the summary and the
  # next chat request under the step cap.
  defp flush_room?(steps, restricted?), do: not restricted? and steps + 3 <= @max_steps

  # The flush keeps notes of the rows a summary is about to replace, so it
  # is sent without the room excerpt: nothing of the room reaches it, and
  # the request the store keeps is the one sent.
  defp flush_request(probe, offered) do
    %{"messages" => messages} = Request.without_excerpt(probe)

    %{
      probe
      | "tools" => Request.catalog_tools(Map.take(offered, [@flush_key])),
        "provider_tools" => [],
        "messages" => Request.instruct(messages, @flush_instruction)
    }
  end

  # The reply's text is not the turn's and is not recorded; its calls are
  # asks of the flush's step, which the loop decides and runs by the
  # flush's rule (`Aqua.Loop`), and the summary waits for them to close.
  defp keep_notes(%__MODULE__{} = state, step, request) do
    case model_call(state, step, request, nil) do
      {:ok, data} ->
        asks = resolve_calls(state, step, List.wrap(data["content"]))

        case commit_response(state, step, data, nil, asks) do
          {:ok, %{asks: recorded}} ->
            state = count_usage(state, data)
            ids = Enum.map(recorded, & &1.step.id)
            if ids != [], do: tell(state, {:ask, Enum.map(recorded, & &1.step)})

            case await_settled(state, ids) do
              :ok -> {:flushed, state}
              {:error, _unread} -> {:error, :write_failed}
            end

          # The flush's answer was not kept: nothing goes on after it.
          {:error, :superseded} = superseded ->
            superseded

          {:error, _unkept} ->
            {:error, :write_failed}
        end

      {:error, :superseded} = superseded ->
        superseded

      {:error, %{"type" => _} = error} ->
        skipped(state, closed(state, step, describe(error)))

      {failure, reason} when failure in [:error, :exit] ->
        skipped(state, closed(state, step, describe(reason)))
    end
  end

  # `reading` is the round's, its deleted files among it: the rows a
  # summary stands for are among those the round's request carried, so a
  # compaction lists nothing of its own. A summary names no reader.
  defp summarize(%__MODULE__{spec: spec} = state, rows, boundary, reading) do
    previous = rows |> Enum.filter(&(&1.kind == "compaction")) |> List.last()

    # Only what the previous summary does not already stand for, and
    # never a compaction row: `Request.messages/3` renders the latest one
    # as a summary block, so leaving it in sends the previous summary
    # twice — once rendered, once as `previous_summary` below.
    since = if previous, do: Tape.payload(previous)["first_kept_seq"] || 0, else: 0

    older =
      Enum.filter(rows, fn row ->
        row.kind != "compaction" and row.seq >= since and
          row.seq < boundary.first_kept_seq
      end)

    request =
      Planner.summary_request(Request.messages(older, %{reading | me: nil, named?: false}),
        model: spec.model,
        previous_summary: previous && previous.content
      )

    case open_model_step(state, "compaction") do
      {:error, :step_cap} -> {:error, :step_cap}
      {:error, :superseded} -> {:error, :superseded}
      {:error, :illegal_transition} = paused -> skip_compaction(state, rows, reading, paused)
      # The summary's step was not written: nothing goes on after it.
      {:error, _unkept} -> {:error, :write_failed}
      {:ok, step, state} -> commit_summary(state, rows, reading, boundary, request, step)
    end
  end

  defp commit_summary(%__MODULE__{} = state, rows, reading, boundary, request, step) do
    with {:ok, data} <- model_call(state, step, request, nil),
         summary =
           data["content"]
           |> List.wrap()
           |> Enum.filter(&(&1["type"] == "text"))
           |> Enum.map_join("", & &1["text"]),
         {:ok, summary} <- Planner.summary_text(summary),
         {:kept, {:ok, _}} <- {:kept, commit_response(state, step, data, nil, [])},
         {:kept, {:ok, _}} <-
           {:kept,
            Tape.append_compaction(guest(state), state.turn, %{
              summary: summary,
              first_kept_seq: boundary.first_kept_seq,
              summarized_through_seq: boundary.summarized_through_seq,
              step_id: step.id
            })},
         {:kept, {:ok, projected, reread}} <- {:kept, reprojected(state, reading)} do
      {:ok, %{state | observed: nil}, projected, reread}
    else
      {:error, :superseded} ->
        {:error, :superseded}

      # The summary's answer, its row or the rows read after them were not
      # kept: nothing goes on after them.
      {:kept, {:error, :superseded}} ->
        {:error, :superseded}

      {:kept, {:error, _unkept}} ->
        {:error, :write_failed}

      other ->
        # The summary request answered nothing the turn can commit; a step
        # already closed by its response stays as it closed.
        case closed(state, step, failure(other)) do
          :ok -> skip_compaction(state, rows, reading, other)
          {:lost, _kind} -> {:error, :write_failed}
        end
    end
  end

  defp highest_seq([]), do: 0
  defp highest_seq(rows), do: rows |> Enum.map(& &1.seq) |> Enum.max()

  # What has arrived since the response whose token count we are reusing —
  # a steer, a tool result, a reply. Counting the estimate alone
  # would price the request as it stood one round ago.
  defp appended_bytes(rows, since) do
    rows
    |> Enum.filter(&(&1.seq > since))
    |> Enum.map(fn row ->
      byte_size(row.content || "") +
        byte_size(if(is_binary(row.payload), do: row.payload, else: ""))
    end)
    |> Enum.sum()
  end

  # nil rather than a guess when the request cannot be encoded: the byte
  # trigger stands down and the token estimate decides alone.
  defp encoded_size(request) do
    case Jason.encode(request) do
      # What the executor weighs is the invocation envelope, not the bare
      # request, so the envelope's own bytes are counted here too. Without
      # them a request just under the cap passes this check and is refused
      # where it is enforced.
      {:ok, json} -> byte_size(json) + @envelope_bytes
      {:error, _} -> nil
    end
  end

  defp failure({kind, reason}) when kind in [:error, :exit], do: describe(reason)
  defp failure(other), do: describe(other)

  # A compaction that did not land leaves the rows as they were; the
  # model step it opened stays counted.
  defp skip_compaction(%__MODULE__{} = state, rows, reading, reason) do
    Logger.warning(
      "[Aqua.Harness.Api] compaction skipped for turn #{state.turn.id}: #{inspect(reason)}"
    )

    {:ok, state, rows, reading}
  end

  defp retained(_request, nil), do: nil
  defp retained(request, _excerpt), do: Request.without_excerpt(request)

  defp digest(request) do
    case Prima.JCS.hash(request) do
      {:ok, digest} -> digest
      _ -> nil
    end
  end
end
