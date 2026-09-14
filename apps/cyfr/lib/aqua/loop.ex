# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop do
  @moduledoc """
  The agent loop: one turn, run by the process that holds its root.

  A round drains the steer, projects the tape, plans the request (a
  compaction first when the window is full, preceded by a note flush when
  the agent keeps notes without asking), records the model call
  before making it, makes it in a worker, persists the whole response
  before any of its calls runs, and dispatches the calls: a card is
  opened for what asks, a refusal is closed as its own result, reads run
  beside each other and everything else alone, each in a worker of its
  own. A round with no calls ends the turn. A card pauses it — the loop
  releases the root itself before it returns — and a continuation
  resumes it from the rows. A launch a person approved is consumed by
  `Aqua.Launch` while the root is paused around it, so the application
  takes a root of its own.

  Every write goes through `Aqua.Tape` under the actor's guest-planed
  context; the loop process never runs a child on itself.
  """

  require Logger

  alias Aqua.Loop.Binding
  alias Aqua.Loop.Binding.Call
  alias Aqua.Loop.{Planner, Policy, Request, Turn}
  alias Aqua.Tape
  alias Arca.Schemas.TurnStep
  alias Sanctum.Context

  @max_steps 30
  @model_timeout_ms 10 * 60 * 1000
  @step_timeout_ms 5 * 60 * 1000
  @launch_timeout_ms 10 * 60 * 1000
  @retry_delays_ms [2_000, 8_000, 20_000]
  # `{"operation":"chat","params":}` around the request, which is what
  # `Opus.Executor` encodes and weighs against the node's cap.
  @envelope_bytes 30
  @resume_backoff_ms [500, 2_000, 8_000]
  @recoverable ~w(rate_limited overloaded)
  @aborted_content "a call's outcome is unknown; tools may have partially executed"
  @setup ~w(authentication secret_denied)
  # A note flush offers this action alone, and keeps a note this large at most.
  @flush_tool "notes"
  @flush_action "keep"
  @flush_key "#{@flush_tool}.#{@flush_action}"
  @flush_note_max_bytes 64 * 1024
  @flush_instruction "The older part of this thread is about to be summarized, and what " <>
                       "the summary leaves out will be gone. Keep anything worth remembering " <>
                       "beyond it — a decision, a preference, a fact the work will need — with " <>
                       "notes.keep now. Reply with nothing else."

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :spec,
      :claim,
      :turn,
      :parent,
      steps: 0,
      usage: %{input: 0, output: 0},
      activity: [],
      since: nil,
      active_ms: 0,
      observed: nil,
      # The highest seq the measured request carried, so rows appended since
      # can be counted. A bare token count says nothing about which rows it
      # was a count of.
      observed_seq: 0,
      sent_upto: 0,
      clone?: false,
      excerpt_sent?: false,
      # A call's outcome is unknown: only replay-safe reads run from here.
      restricted?: false
    ]
  end

  @type result ::
          :completed
          | {:paused, :approval | :launch | :uncertain}
          | {:failed, term()}
          | :cancelled
          | {:uncertain, term()}

  # ---------------------------------------------------------------------------
  # Entry points
  # ---------------------------------------------------------------------------

  @doc """
  Run an accepted turn as its root: claim the root on this process,
  start the turn with its pins, and loop. `opts`: `:ctx` (the actor's
  external-plane context), `:turn_id`. Ends the turn itself on every
  outcome but a pause.
  """
  @spec run(keyword()) :: result() | {:error, term()}
  def run(opts) do
    ctx = Keyword.fetch!(opts, :ctx)

    with {:ok, turn} <- Tape.turn(ctx, Keyword.fetch!(opts, :turn_id)) do
      case claim_and_start(ctx, turn) do
        {:ok, state} ->
          Aqua.Loop.Stream.announce_fence(state.spec.guest, state.turn)
          conclude(state, loop(state))

        {:error, {:after_claim, claim, turn, reason}} ->
          never_ran(ctx, claim, turn, reason)

        # The source has no consent to run under: the person is asked for it.
        {:error, :no_profile} ->
          setup_required(ctx, turn)

        {:error, {:profile_unavailable, _}} ->
          setup_required(ctx, turn)

        {:error, reason} ->
          _ = Tape.finish(ctx, turn, "failed", %{error: describe(reason)})
          {:failed, reason}
      end
    end
  end

  # The root is held but the turn never ran: ended with the actor's own
  # context, since no spec was built to carry it, and the root closed by
  # the release when the turn never came to carry it. A model its catalyst
  # could not describe for want of a key asks the person for the
  # catalyst's consent.
  defp never_ran(ctx, claim, turn, reason) do
    case needs_setup(reason) do
      nil ->
        end_unrun(ctx, claim, turn, describe(reason))
        {:failed, reason}

      catalyst ->
        end_unrun(ctx, claim, turn, "setup_required")
        Tape.announce(ctx, turn.thread_id, {:consent_required, catalyst, ctx.user_id})
        {:failed, :setup_required}
    end
  end

  defp end_unrun(ctx, claim, turn, error) do
    _ = Tape.finish(ctx, turn, "failed", %{error: error})
    Cyfr.Execution.release_turn_root(ctx, claim.execution_id, claim: claim, failed: error)
  end

  defp needs_setup({:setup_required, catalyst}), do: catalyst

  defp needs_setup({:model_refused, catalyst, %{"type" => type}}) when type in @setup,
    do: catalyst

  defp needs_setup(_reason), do: nil

  defp setup_required(ctx, turn) do
    _ = Tape.finish(ctx, turn, "failed", %{error: "setup_required"})
    Tape.announce(ctx, turn.thread_id, {:consent_required, source_ref(turn), ctx.user_id})
    {:failed, :setup_required}
  end

  @doc """
  Continue a turn on this process: `:resume` a paused turn (the root is
  taken back first; a refusal leaves it paused), or `:adopt` a running
  turn whose successor attempt a takeover already opened. `opts`: `:ctx`,
  `:turn_id`, `:mode`. Open steps are settled before the loop goes on.
  """
  @spec run_nested(keyword()) :: result() | {:error, term()}
  def run_nested(opts) do
    ctx = Keyword.fetch!(opts, :ctx)
    mode = Keyword.get(opts, :mode, :resume)

    with {:ok, turn} <- Tape.turn(ctx, Keyword.fetch!(opts, :turn_id)),
         {:ok, claim, turn} <- reclaim(ctx, turn, mode),
         {:ok, authority} <- pinned_authority(ctx, turn),
         {:ok, spec} <- Turn.build(ctx, turn, authority: authority, excerpt?: false),
         {:ok, turn} <- Tape.pin_catalyst(ctx, turn, spec.catalyst) do
      spec = Turn.with_turn(spec, turn)

      state = %State{
        spec: spec,
        claim: claim,
        turn: turn,
        since: now(),
        active_ms: turn.active_ms
      }

      Aqua.Loop.Stream.announce_fence(spec.guest, turn)

      case settle(state) do
        {:continue, state} -> conclude(state, loop(state))
        {:halt, result, state} -> conclude(state, {result, state})
      end
    end
  end

  @doc """
  Abort a turn from outside its process, before it is stopped: the fence
  of the turn and of its open clones is raised and their dispatched steps
  cancel-marked, every child execution and every in-process catalog
  handler is cancelled, dispatched steps settle by
  `Arca.Schemas.TurnStep.unresolved/1` — a call whose effect is unknown is
  marked `uncertain`, since a cancel does not prove the effect never
  happened — unstarted steps are skipped, each open clone ends
  `cancelled`, and the aborted mark is written. The caller then ends the
  turn; stopping its process stops every worker and clone loop under it
  (`Aqua.Loop.Worker`).
  """
  @spec abort(Context.t(), Tape.turn(), String.t()) :: {:ok, Tape.turn()} | {:error, term()}
  def abort(%Context{} = ctx, turn, reason) do
    guest = Context.enter_guest(ctx)

    with {:ok, superseded} <- Tape.supersede(guest, turn),
         {:ok, clones} <- Tape.open_clones(guest, superseded) do
      for clone <- clones do
        settle_aborted(ctx, clone, reason)
        _ = Tape.close_clone_turn(guest, clone, "cancelled", %{error: reason})
      end

      settle_aborted(ctx, superseded, reason)
      _ = Tape.append_aborted(guest, superseded, reason)
      {:ok, superseded}
    end
  end

  defp settle_aborted(ctx, turn, reason) do
    guest = Context.enter_guest(ctx)

    with {:ok, steps} <- Tape.steps(guest, turn) do
      for %{dispatch_state: "dispatched"} = step <- steps do
        if step.child_execution_id, do: Cyfr.Execution.cancel(ctx, step.child_execution_id)
        Aqua.Ops.cancel_call(handle(turn, step))

        case TurnStep.unresolved(step) do
          :uncertain -> Tape.mark_uncertain(guest, turn, step, reason)
          :unknown -> Tape.close_step(guest, turn, step, "uncertain", %{error: reason})
          _unanswered_or_replay -> Tape.close_step(guest, turn, step, "error", %{error: reason})
        end
      end
    end

    _ = Tape.skip_steps(guest, turn, reason)
  end

  # ---------------------------------------------------------------------------
  # Claiming
  # ---------------------------------------------------------------------------

  defp claim_and_start(ctx, turn) do
    with {:ok, claim} <-
           Cyfr.Execution.claim_turn_root(ctx, source_ref(turn),
             turn_id: turn.id,
             thread_id: turn.thread_id,
             envelope: %{"turn" => turn.id}
           ) do
      with {:ok, snapshot} <- Compendium.AgentIndex.snapshot(ctx, turn.orchestrator),
           :ok <- consented_release(ctx, claim.authority, turn, snapshot),
           {:ok, started} <-
             Tape.start_turn(ctx, turn, %{
               root_execution_id: claim.execution_id,
               attempt: claim.attempt,
               budget_id: claim.budget_id,
               profile_id: claim.authority.profile_id,
               consent_id: claim.authority.consent_id,
               agent_revision_digest: snapshot.revision_digest,
               agent_capability_digest: snapshot.capability_digest
             }),
           {:ok, spec} <- Turn.build(ctx, started, authority: claim.authority),
           {:ok, started} <- Tape.pin_catalyst(ctx, started, spec.catalyst) do
        {:ok,
         %State{
           spec: Turn.with_turn(spec, started),
           claim: claim,
           turn: started,
           since: now(),
           active_ms: started.active_ms
         }}
      else
        {:error, reason} -> {:error, {:after_claim, claim, turn, reason}}
      end
    end
  end

  defp reclaim(ctx, turn, :resume) do
    case Cyfr.Execution.resume_turn_root(ctx, turn.root_execution_id,
           turn_id: turn.id,
           fence: turn.fence
         ) do
      {:ok, %{turn: resumed} = claim} -> {:ok, claim, resumed}
      {:error, _} = error -> error
    end
  end

  defp reclaim(ctx, turn, :adopt) do
    with {:ok, claim} <-
           Cyfr.Execution.adopt_turn_root(ctx, turn.root_execution_id, attempt: turn.attempt) do
      {:ok, claim, turn}
    end
  end

  # The turn's pinned authority, loaded again: the profile at its head
  # must still be at the pinned consent, and the budget is the turn's
  # reservation.
  defp pinned_authority(ctx, %{profile_id: profile_id} = turn) when is_binary(profile_id) do
    case Cyfr.Execution.authority_for(ctx, {:id, profile_id}, source_ref(turn),
           budget_id: turn.budget_id
         ) do
      {:ok, %{consent_id: consent_id} = authority} when consent_id == turn.consent_id ->
        {:ok, authority}

      {:ok, _moved} ->
        {:error, :consent_moved}

      {:error, _} = error ->
        error
    end
  end

  defp pinned_authority(_ctx, _turn), do: {:error, :no_pin}

  # The source a turn runs as: the soul, or the role a person addressed.
  defp source_ref(%{orchestrator: name}) do
    if Compendium.AgentSource.soul?(name),
      do: Compendium.AgentSource.soul_ref(),
      else: Compendium.AgentSource.ref(name)
  end

  # The file the turn pins must be the release the loaded consent names
  # for its own node; a file edited past its consent is refused, never
  # run under the old grant.
  defp consented_release(ctx, %{activation: activation}, turn, %{agent: agent}) do
    with {:ok, roster} <- Compendium.AgentSource.enabled_roster(ctx) do
      consented = Map.get(activation || %{}, source_ref(turn))
      projected = Compendium.AgentSource.row(agent, roster).release_digest

      if is_binary(consented) and consented == projected,
        do: :ok,
        else: {:error, :agent_changed}
    end
  end

  # ---------------------------------------------------------------------------
  # Ending
  # ---------------------------------------------------------------------------

  # The one terminal transaction, then the local cleanup — from this
  # process, which holds the slot. A paused turn already let it go.
  defp conclude(%State{clone?: true}, {result, _state}), do: result

  defp conclude(%State{} = state, {result, ended}) do
    case result do
      {:paused, _} ->
        result

      _ ->
        {status, error} = terminal(result)

        case Tape.finish(ctx(state), ended.turn, status, %{error: error}) do
          # A steer landed while the last answer was written: the turn goes
          # on to answer it.
          {:error, :steer_pending} ->
            conclude(state, loop(ended))

          finish ->
            final = finished(ended, status, result, finish)
            release(ended)
            final
        end
    end
  end

  defp finished(ended, status, result, finish) do
    case finish do
      {:ok, _} ->
        result

      other ->
        # Saying "completed" while the row still says "running" puts the
        # runtime and the rows in disagreement, and the runner would take
        # the next message believing this one had landed. The row is left
        # for recovery, which is what owns a turn nobody finished.
        Logger.error(
          "[Aqua.Loop] turn #{ended.turn.id} could not be finished as #{status}: " <>
            "#{inspect(other)}"
        )

        {:uncertain, "the turn's terminal write did not land"}
    end
  end

  defp terminal(:completed), do: {"completed", nil}
  defp terminal(:cancelled), do: {"cancelled", "stopped"}
  defp terminal({:failed, reason}), do: {"failed", describe(reason)}
  defp terminal({:uncertain, reason}), do: {"uncertain", describe(reason)}

  defp release(%State{claim: %{execution_id: execution_id} = claim} = state) do
    Cyfr.Execution.release_turn_root(ctx(state), execution_id, claim: claim)
  end

  defp release(_state), do: :ok

  # ---------------------------------------------------------------------------
  # The loop
  # ---------------------------------------------------------------------------

  @doc false
  def loop(%State{} = state) do
    case step(state) do
      {:continue, state} -> loop(state)
      {:halt, result, state} -> {result, state}
    end
  end

  defp step(%State{} = state) do
    cond do
      state.steps >= @max_steps ->
        {:halt, {:failed, :step_cap}, state}

      over_deadline?(state) ->
        {:halt, {:failed, :deadline}, state}

      true ->
        model_round(state)
    end
  end

  defp model_round(%State{} = state) do
    with {:ok, _drained} <- Tape.drain_steer(guest(state), state.turn),
         {:ok, rows} <- Tape.projection(guest(state), state.turn),
         {:ok, planned, rows} <- compact(state, rows),
         first? = planned.steps == 0,
         {:ok, step, planned} <- open_model_step(planned, "chat") do
      excerpt = if planned.excerpt_sent?, do: nil, else: planned.spec.excerpt
      request = request(planned, rows, excerpt, first?)
      planned = %{planned | sent_upto: highest_seq(rows)}

      if excerpt do
        _ =
          Tape.mark_excluded(guest(planned), planned.turn, step, %{
            excluded: ["room_excerpt"],
            request_digest: digest(request)
          })
      end

      ask_model(%{planned | excerpt_sent?: true}, step, request, retained(request, excerpt), 0)
    else
      {:error, :superseded} -> {:halt, :cancelled, state}
      {:error, reason} -> {:halt, {:failed, reason}, state}
    end
  end

  # Every round carries the sender's attachments. A later round used to send
  # none, on the belief that the rows carry them: they do not — the
  # projection renders text, and an image or a document exists only as these
  # typed blocks. After the first tool call the model could no longer see
  # what it had been asked about.
  defp request(%State{spec: spec} = state, rows, excerpt, _first?) do
    rows = Planner.prune(rows)
    authors = rows |> Enum.map(& &1.author) |> Enum.uniq() |> Enum.reject(&agent_or_system?/1)
    multi? = spec.several_people? or length(authors) > 1

    names =
      if multi?, do: Map.new(authors, &{&1, Sanctum.Tenancy.Users.display_name(&1)}), else: %{}

    messages =
      Request.messages(rows,
        names: names,
        multi_author?: multi?,
        excerpt: excerpt,
        attachments: spec.attachments,
        task_message_id: state.turn.message_id
      )

    Request.build(
      model: spec.model,
      system: spec.system,
      messages: messages,
      tools:
        if(state.clone?,
          do: Enum.reject(spec.tools, &(&1["name"] in Turn.role_names(spec))),
          else: spec.tools
        ),
      capabilities: spec.capabilities,
      native_search?: Map.get(spec.policy, "native_search") == "auto"
    )
  end

  defp agent_or_system?(author),
    do: author in [Arca.Schemas.Message.agent_author(), Arca.Schemas.Message.system_author()]

  # The model step is dispatched before the call: a recovery finds it
  # without a response and never replays it.
  # Every model step opened — a chat round, its retry, a compaction —
  # counts against the turn's cap, before it opens; the count is the
  # turn's, rebuilt from its rows on a continuation.
  defp open_model_step(%State{steps: steps}, _purpose) when steps >= @max_steps,
    do: {:error, :step_cap}

  defp open_model_step(%State{} = state, purpose) do
    with {:ok, step} <-
           Tape.record_model_intent(guest(state), state.turn, %{
             idempotency_key:
               "model:#{state.turn.id}:#{System.unique_integer([:positive, :monotonic])}",
             child_execution_id: Cyfr.UUID7.execution_id(),
             tool: state.spec.catalyst,
             action: "chat",
             purpose: purpose
           }),
         {:ok, step} <- Tape.mark_dispatched(guest(state), state.turn, step) do
      {:ok, step, %{state | steps: state.steps + 1}}
    end
  end

  defp ask_model(%State{} = state, step, request, retained, retries) do
    case model_call(state, step, request, retained) do
      {:ok, data} ->
        on_response(state, step, data)

      {:error, %{"type" => type}}
      when type in @recoverable and retries < length(@retry_delays_ms) ->
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: type})
        Process.sleep(Enum.at(@retry_delays_ms, retries))

        case open_model_step(state, "chat") do
          {:ok, again, state} -> ask_model(state, again, request, retained, retries + 1)
          {:error, reason} -> {:halt, {:failed, reason}, state}
        end

      {:error, %{"type" => type} = error} when type in @setup ->
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: error["message"]})
        announce(state, {:consent_required, state.spec.catalyst, ctx(state).user_id})
        {:halt, {:failed, :setup_required}, state}

      {:error, %{"type" => _type, "message" => message}} ->
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: message})
        _ = system_row(state, "The model could not answer: #{message}")
        {:halt, {:failed, message}, state}

      # A model request that died left nothing a person must judge
      # (`TurnStep.unresolved/1`): it ends the turn like a refusal.
      {failure, reason} when failure in [:error, :exit] ->
        text = describe(reason)
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: text})
        _ = system_row(state, "The model could not be reached: #{text}")
        {:halt, {:failed, reason}, state}
    end
  end

  # The catalyst runs as a child of the root, in a worker: the answer is
  # the contract's data, a typed refusal, the engine's refusal, or the
  # worker's death. A chat step's text streams to the thread while it runs,
  # and is withdrawn when the step lands no text row; a flush or a
  # compaction streams nothing.
  defp model_call(%State{spec: spec} = state, step, request, retained) do
    input = %{"operation" => "chat", "params" => request}
    retained_input = retained && %{"operation" => "chat", "params" => retained}
    guest = guest(state)
    turn = state.turn
    streamed = stream_attrs(state, step)
    stream = streamed && Aqua.Loop.Stream.open(guest, step.child_execution_id, streamed)

    answer =
      try do
        worker(
          fn ->
            Cyfr.Execution.run_child(spec.authority, spec.catalyst, nil, input,
              ctx: guest,
              execution_id: step.child_execution_id,
              step_id: step.id,
              parent_execution_id: turn.root_execution_id,
              root_execution_id: turn.root_execution_id,
              parent_reference: Compendium.AgentSource.ref(turn.orchestrator),
              declared_needs: [],
              retention_class: "chat_step",
              retained_input: retained_input,
              charge: Binding.charge(step, turn),
              guest_fn: :spawn
            )
          end,
          @model_timeout_ms
        )
      after
        Aqua.Loop.Stream.close(stream)
      end

    result =
      case answer do
        {:ok, {:ok, %{output: output}}} -> Cyfr.Models.decode_envelope(output)
        {:ok, {:ok, output}} -> Cyfr.Models.decode_envelope(output)
        {:ok, {:error, reason}} -> {:error, reason}
        {:exit, reason} -> {:exit, reason}
      end

    if streamed && not lands_text?(result), do: Aqua.Loop.Stream.abandon(guest, streamed)
    result
  end

  # A clone's text streams under the soul's turn and fence, from its own
  # turn and named by its role.
  defp stream_attrs(%State{} = state, %{purpose: "chat"} = step) do
    {soul, role} =
      if state.clone?,
        do: {state.parent.turn, state.spec.agent["name"]},
        else: {state.turn, nil}

    %{
      thread_id: state.turn.thread_id,
      turn_id: soul.id,
      fence: soul.fence,
      source: state.turn.id,
      step_id: step.id,
      ordinal: state.steps,
      role: role
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

  # The whole response lands before any call runs.
  defp on_response(%State{} = state, step, data) do
    content = List.wrap(data["content"])
    text = content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("", & &1["text"])
    {resolved, tool_calls} = resolve_calls(state, step, content)
    usage = data["usage"] || %{}

    case Tape.record_response(guest(state), state.turn, step, %{
           text: if(text == "", do: nil, else: text),
           usage: usage,
           stop_reason: data["stop_reason"],
           tool_calls: tool_calls
         }) do
      {:ok, %{calls: recorded}} ->
        state = count_usage(state, usage)

        items =
          Enum.zip_with(recorded, resolved, fn %{step: call_step}, {_block, call} ->
            %{step: call_step, call: call, approval: nil}
          end)

        if items == [], do: {:halt, :completed, state}, else: dispatch(state, items)

      {:error, :superseded} ->
        {:halt, :cancelled, state}

      {:error, reason} ->
        {:halt, {:failed, reason}, state}
    end
  end

  defp resolve_calls(%State{} = state, step, content) do
    resolved =
      for %{"type" => "tool_call"} = block <- content do
        name = block["name"] || ""
        args = if is_map(block["arguments"]), do: block["arguments"], else: %{}

        {block,
         Binding.resolve(name, args,
           roles: Turn.role_names(state.spec),
           tool_call_id: block["id"]
         )}
      end

    {resolved, Enum.map(resolved, fn {block, call} -> call_attrs(state, step, block, call) end)}
  end

  defp call_attrs(%State{} = state, model_step, block, call) do
    name = block["name"] || ""
    args = if is_map(block["arguments"]), do: block["arguments"], else: %{}
    id = block["id"] || Cyfr.UUID7.generate_id("call")

    {tool, action, kind, recovery, child, step_kind} =
      case call do
        {:ok, %Call{} = call} ->
          {call.tool, call.action, kind_of(call), recovery_of(call), child_id_for(call),
           step_kind(call)}

        {:error, _} ->
          {name, nil, "unknown", nil, nil, "tool"}
      end

    %{
      tool_call_id: id,
      name: name,
      tool: tool,
      action: action,
      arguments: args,
      provider_data: block["provider_data"],
      kind: kind,
      recovery: recovery,
      child_execution_id: child,
      idempotency_key: "call:#{state.turn.id}:#{model_step.id}:#{id}",
      proposal_digest:
        Policy.proposal_digest(%{"tool" => tool, "action" => action, "args" => args}),
      step_kind: step_kind
    }
  end

  defp kind_of(%Call{kind: :hand, tool: tool, action: action}),
    do: to_string(Aqua.Kinds.kind_for(tool, action) || "unknown")

  defp kind_of(%Call{kind: :catalog, tool: tool, action: action}),
    do: to_string(Aqua.Kinds.kind_for(tool, action) || "unknown")

  defp kind_of(%Call{kind: :external}), do: "external"
  defp kind_of(%Call{kind: :launch}), do: "execute"
  defp kind_of(%Call{kind: kind}), do: to_string(kind)

  defp recovery_of(%Call{} = call), do: if(replay_safe?(call), do: "replay_safe", else: nil)

  defp child_id_for(%Call{kind: kind}) when kind in [:hand, :launch, :external],
    do: Cyfr.UUID7.execution_id()

  defp child_id_for(_call), do: nil

  defp step_kind(%Call{kind: :launch}), do: "launch"
  defp step_kind(%Call{kind: :clone}), do: "clone"
  defp step_kind(%Call{kind: :ui}), do: "ui"
  defp step_kind(_call), do: "tool"

  defp count_usage(%State{} = state, usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    totals = %{input: state.usage.input + input, output: state.usage.output + output}
    announce(state, {:usage, totals})

    if input > 0 do
      %{state | usage: totals, observed: input, observed_seq: state.sent_upto}
    else
      %{state | usage: totals}
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  # Cards first, then the runnable steps in source order; a group of
  # reads runs beside itself, everything else alone; a steer that
  # arrived skips what has not started.
  defp dispatch(%State{} = state, items) do
    # What the turn has already written to, and what this response is about
    # to. The closed calls alone are a snapshot from before any of these ran,
    # so a write, a build and a run proposed together were every one of them
    # judged against a turn that had touched nothing — and the launch rule
    # that asks for a card after a write never saw the write.
    touched = MapSet.union(touched(state), proposes(items))
    {runnable, cards} = Enum.reduce(items, {[], 0}, &decide(state, touched, &1, &2))
    runnable = Enum.reverse(runnable)

    case run_groups(state, group(runnable)) do
      {:halt, result, state} ->
        {:halt, result, state}

      {:ok, state} ->
        cond do
          over_deadline?(state) ->
            {:halt, {:failed, :deadline}, state}

          cards > 0 and pending?(state) ->
            pause(state, :approval)

          true ->
            {:continue, state}
        end
    end
  end

  # A restricted turn runs replay-safe reads and nothing else — before a
  # card's approval or the policy can say otherwise.
  defp decide(
         %State{restricted?: true} = state,
         touched,
         %{step: step, call: {:ok, %Call{} = call}} = item,
         acc
       ) do
    if Policy.replay_safe?(call) do
      decide_open(state, touched, item, acc)
    else
      close(
        state,
        step,
        call,
        {:error,
         {:denied,
          "#{call.tool}.#{call.action} may not run: an earlier call's outcome is unknown, " <>
            "and until a new turn starts only replay-safe reads run"}}
      )

      acc
    end
  end

  defp decide(state, touched, item, acc), do: decide_open(state, touched, item, acc)

  # An approved call runs as it was approved: the call recalled from its row
  # must be the proposal the approval's digest names.
  defp decide_open(
         state,
         _touched,
         %{approval: %{} = approval, step: step, call: {:ok, %Call{} = call}} = item,
         {runnable, cards}
       ) do
    if Aqua.Approvals.proposal?(approval, Policy.proposal(call)) do
      {[item | runnable], cards}
    else
      close(state, step, call, {:error, {:denied, "the call no longer matches its approval"}})
      {runnable, cards}
    end
  end

  defp decide_open(state, _touched, %{step: step, call: {:error, message}}, {runnable, cards}) do
    close(state, step, nil, {:error, message})
    {runnable, cards}
  end

  defp decide_open(
         %State{clone?: true} = state,
         _touched,
         %{step: step, call: {:ok, %Call{kind: :clone}}},
         acc
       ) do
    close(state, step, nil, {:error, "a role works with its own hands and clones nobody"})
    acc
  end

  defp decide_open(
         state,
         touched,
         %{step: step, call: {:ok, %Call{} = call}} = item,
         {runnable, cards}
       ) do
    decision =
      Policy.decide(call, state.spec.policy,
        consented?: &consented?(state, &1),
        touched: touched,
        restricted?: state.restricted?
      )

    case decision do
      :auto ->
        {[item | runnable], cards}

      :ask when state.clone? ->
        close(
          state,
          step,
          call,
          {:error,
           "#{call.tool}.#{call.action} needs the person's approval, which a role cannot ask for"}
        )

        {runnable, cards}

      :ask ->
        case open_card(state, step, call) do
          :ok ->
            {runnable, cards + 1}

          {:error, reason} ->
            close(state, step, call, {:error, describe(reason)})
            {runnable, cards}
        end

      {:deny, message} ->
        close(state, step, call, {:error, {:denied, message}})
        {runnable, cards}

      {:refuse, message} ->
        close(state, step, call, {:error, {:denied, message}})
        {runnable, cards}
    end
  end

  defp open_card(%State{} = state, step, %Call{} = call) do
    intent =
      Policy.card(call, id: Cyfr.UUID7.generate_id("apr"))
      |> Map.put("tool_call_id", call.tool_call_id)

    case Tape.open_approval(guest(state), state.turn, step, %{
           id: intent["id"],
           proposal_digest: Policy.proposal_digest(intent),
           expires_at: DateTime.add(DateTime.utc_now(), state.spec.approval_ttl_s, :second),
           card: %{content: intent["title"], payload: %{"intent" => intent}}
         }) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc false
  # Public for its own test: which calls share a group decides what runs
  # beside what, and a wrong grouping is invisible from outside until two
  # things race.
  #
  # Reads gather; anything else runs alone. A non-read has to flush the
  # reads waiting behind it AND stand alone, which is two emissions for one
  # item — `chunk_while` allows one, so it seeded the next group with the
  # write instead and the following read joined it.
  def group(items) do
    {groups, pending} =
      Enum.reduce(items, {[], []}, fn item, {groups, reads} ->
        cond do
          launch?(item) -> {[{:launch, item} | flush(reads, groups)], []}
          concurrent?(item) -> {groups, [item | reads]}
          true -> {[{:exclusive, item} | flush(reads, groups)], []}
        end
      end)

    pending |> flush(groups) |> Enum.reverse()
  end

  defp flush([], groups), do: groups
  defp flush(reads, groups), do: [{:concurrent, Enum.reverse(reads)} | groups]

  defp launch?(%{step: %{kind: "launch"}}), do: true
  defp launch?(_item), do: false

  defp concurrent?(%{call: {:ok, %Call{} = call}}), do: Policy.overlap(call) == :concurrent
  defp concurrent?(_item), do: false

  # Every group's outcome rides out: a group that stopped the turn on an
  # unknown outcome halts the dispatch with the pause it established.
  defp run_groups(%State{} = state, groups) do
    Enum.reduce_while(groups, {:ok, state}, fn group, {:ok, state} ->
      cond do
        over_deadline?(state) ->
          _ = Tape.skip_steps(guest(state), state.turn, "the turn ran out of time")
          {:halt, {:ok, state}}

        Tape.steer_pending?(guest(state), state.turn) ->
          _ = Tape.skip_steps(guest(state), state.turn, "a newer message arrived")
          {:halt, {:ok, state}}

        true ->
          case run_group(state, group) do
            {:ok, state} -> {:cont, {:ok, state}}
            {:halt, _result, _state} = halt -> {:halt, halt}
          end
      end
    end)
  end

  defp run_group(%State{} = state, {:launch, item}), do: run_launch(state, item)

  defp run_group(%State{} = state, {:exclusive, item}) do
    state = activity(state, [item], :running)

    outcome =
      case worker(fn -> run_one(state, item) end, @step_timeout_ms) do
        {:ok, {:uncertain, step, reason}} -> {:uncertain, step, reason}
        {:ok, _} -> :ok
        {:exit, reason} -> settle_dead(state, item, reason)
      end

    state = activity(state, [item], :done)

    case outcome do
      {:uncertain, step, reason} -> stop_uncertain(state, step, reason, [])
      _ -> {:ok, state}
    end
  end

  defp run_group(%State{} = state, {:concurrent, items}) do
    state = activity(state, items, :running)
    cap = max(state.spec.authority.budget.cap, 1)
    outcome = run_concurrent(state, items, min(length(items), cap))
    state = activity(state, items, :done)

    case outcome do
      {:uncertain, step, reason, rest} -> stop_uncertain(state, step, reason, rest)
      :ok -> {:ok, state}
    end
  end

  # The reads of a group run beside each other, at most `cap` at once,
  # each in a worker of its own: every answer, timeout and death is
  # attributed to its step as it arrives. The first unknown outcome stops
  # the group — nothing more is started, and what still runs is handed
  # back to be cancelled once the turn's stop is durable.
  defp run_concurrent(%State{} = state, items, cap) do
    collect(state, items, %{}, cap)
  end

  defp collect(_state, [], running, _cap) when map_size(running) == 0, do: :ok

  defp collect(state, pending, running, cap) when map_size(running) < cap and pending != [] do
    [item | rest] = pending
    task = Aqua.Loop.Worker.async(fn -> run_one(state, item) end)
    deadline = System.monotonic_time(:millisecond) + @step_timeout_ms

    collect(
      state,
      rest,
      Map.put(running, task.ref, %{item: item, task: task, deadline: deadline}),
      cap
    )
  end

  defp collect(state, pending, running, cap) do
    {soonest_ref, %{deadline: deadline}} = Enum.min_by(running, fn {_ref, r} -> r.deadline end)
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {ref, result} when is_map_key(running, ref) ->
        Process.demonitor(ref, [:flush])
        {%{item: item}, running} = Map.pop(running, ref)

        case result do
          {:uncertain, step, reason} ->
            {:uncertain, step, reason, Map.values(running) ++ pending_items(pending)}

          _ ->
            collect(state, pending, running, cap)
        end
        |> tap(fn _ -> item end)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        {%{item: item}, running} = Map.pop(running, ref)

        case settle_dead(state, item, reason) do
          {:uncertain, step, why} ->
            {:uncertain, step, why, Map.values(running) ++ pending_items(pending)}

          _ ->
            collect(state, pending, running, cap)
        end
    after
      wait ->
        {%{item: item, task: task}, running} = Map.pop(running, soonest_ref)
        Task.shutdown(task, :brutal_kill)

        case settle_dead(state, item, :timeout) do
          {:uncertain, step, why} ->
            {:uncertain, step, why, Map.values(running) ++ pending_items(pending)}

          _ ->
            collect(state, pending, running, cap)
        end
    end
  end

  defp pending_items(pending), do: Enum.map(pending, &%{item: &1, task: nil})

  # In a worker: the step is dispatched, run, and closed with what it
  # answered. A step that is no longer proposed (skipped, superseded)
  # runs nothing. An outcome that cannot be known is not closed here: it
  # is reported, and the loop stops the turn on it.
  @doc false
  def run_one(%State{} = state, %{step: step, call: {:ok, %Call{} = call}} = item) do
    case still_granted(state, item, call) do
      :ok -> dispatch_one(state, step, call)
      {:denied, message} -> settle_denied(state, step, call, message)
    end
  end

  # The grants a member holds are their live decision; the loop decides from
  # a snapshot `Turn.build/3` took. Revoking "allow in this thread"
  # writes the rows and refreshes the runner, and reaches no loop already
  # running — so the window between a response landing and its calls
  # dispatching, and the window while an earlier call of the same response
  # runs, both belonged to a grant that had gone. Every call asks again as
  # it dispatches. The check can only withdraw an `auto`: a card the person
  # answered is their decision about this exact call, and a standing grant's
  # withdrawal does not retract it.
  defp still_granted(_state, %{approval: %{}}, _call), do: :ok

  defp still_granted(%State{} = state, _item, %Call{} = call) do
    case Turn.current_policy(state.spec) do
      {:ok, policy} ->
        if Policy.auto?(call, policy),
          do: :ok,
          else: {:denied, "#{call.tool}.#{call.action} is no longer allowed in this thread"}

      # A store that cannot answer whether the grant still stands is not a
      # grant. Fail closed, the way every other standing question does.
      {:error, _reason} ->
        {:denied, "#{call.tool}.#{call.action} could not be checked against the agent's grants"}
    end
  end

  defp settle_denied(%State{} = state, step, %Call{} = call, message) do
    case close(state, step, call, {:error, {:denied, message}}) do
      {:ok, _closed} -> :ok
      other -> {:uncertain, step, describe({:result_lost, other})}
    end
  end

  defp dispatch_one(%State{} = state, step, %Call{} = call) do
    case Tape.mark_dispatched(guest(state), state.turn, step) do
      {:ok, step} ->
        case normalise(execute(state, step, call)) do
          {:uncertain, reason} ->
            {:uncertain, step, describe(reason)}

          result ->
            case close(state, step, call, result) do
              {:ok, _closed} ->
                :ok

              other ->
                # The canonical result is what the next round reads. Without
                # it the step stays dispatched, the model is handed a
                # synthetic "outcome is unknown", and the turn finishes as
                # though the call had answered. That is the uncertain path,
                # and it stops the turn.
                {:uncertain, step, describe({:result_lost, other})}
            end
        end

      {:error, :not_proposed} ->
        :skipped

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute(%State{} = state, _step, %Call{kind: :ui, args: args}) do
    case Aqua.Intents.validate(args) do
      {:ok, intent} ->
        announce(state, {:intents, [intent], ctx(state).user_id})
        {:ok, "done"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp execute(%State{} = state, step, %Call{kind: :clone} = call),
    do: Aqua.Loop.Clone.run(state, step, call)

  defp execute(%State{spec: spec} = state, step, %Call{
         kind: :launch,
         target: reference,
         args: args
       }) do
    Cyfr.Execution.run_child(spec.authority, reference, args["need"], args["input"] || %{},
      ctx: guest(state),
      execution_id: step.child_execution_id,
      step_id: step.id,
      parent_execution_id: state.turn.root_execution_id,
      root_execution_id: state.turn.root_execution_id,
      parent_reference: Compendium.AgentSource.ref(state.turn.orchestrator),
      declared_needs: [],
      retention_class: "chat_step",
      charge: Binding.charge(step, state.turn),
      guest_fn: :spawn
    )
  end

  defp execute(%State{spec: spec} = state, step, %Call{} = call) do
    Binding.dispatch(call, %{
      ctx: guest(state),
      authority: spec.authority,
      root_execution_id: state.turn.root_execution_id,
      attempt: state.turn.attempt,
      thread_id: state.turn.thread_id,
      agent_ref: Compendium.AgentSource.ref(state.turn.orchestrator),
      charge: Binding.charge(step, state.turn),
      execution_id: step.child_execution_id,
      step_id: step.id,
      step: %{id: step.id, generation: step.generation},
      cancel_handle: handle(state, step)
    })
  end

  # One outcome vocabulary at the loop's boundary: an effect that may
  # have happened with no result (`uncertain`), one that happened whose
  # result could not be kept (`result_lost`), one whose ending could not
  # be recorded (`not_recorded`) — all unknown outcomes to the turn.
  defp normalise({:error, {:uncertain, reason}}), do: {:uncertain, reason}
  defp normalise({:error, {:result_lost, reason}}), do: {:uncertain, reason}
  defp normalise({:error, {:not_recorded, reason}}), do: {:uncertain, reason}
  defp normalise(other), do: other

  # The step's result row and outcome: `ok`, `error`, `denied` for a
  # refusal by the policy or the chain, `skipped` for a call not started,
  # or `uncertain` for a call closed with its outcome unknown.
  defp close(%State{} = state, step, call, result) do
    {outcome, text, error?} =
      case result do
        {:unknown, message} ->
          {"uncertain", message, true}

        {:skipped, message} ->
          {"skipped", message, true}

        {:error, {:denied, message}} ->
          {"denied", message, true}

        {:error, {:invoke_denied, reason}} ->
          {"denied", "Denied by chain authority: #{inspect(reason)}", true}

        {:error, message} when is_binary(message) ->
          if String.starts_with?(message, "Denied by chain authority"),
            do: {"denied", message, true},
            else: {"error", message, true}

        {:ok, text} when is_binary(text) ->
          {"ok", text, false}

        other ->
          %{text: text, is_error: error?} = render(call, other)
          {if(error?, do: "error", else: "ok"), text, error?}
      end

    Tape.close_step(guest(state), state.turn, step, outcome, %{
      result: %{
        content: text,
        payload: %{
          "tool_call_id" => call && call.tool_call_id,
          "name" => call && call.model_name,
          "is_error" => error?
        }
      },
      execution_id: step.child_execution_id,
      error: if(error?, do: text, else: nil)
    })
  end

  defp render(nil, {:error, reason}), do: %{text: describe(reason), is_error: true}

  defp render(%Call{kind: :launch} = call, result),
    do: Binding.render(%{call | kind: :hand}, result)

  defp render(%Call{} = call, result), do: Binding.render(call, result)

  # A worker that died or timed out: a step it never dispatched is
  # skipped; a dispatched one settles by `TurnStep.unresolved/1` — one safe
  # to run again closes as an error the model may retry, a flush's closes
  # with its outcome unknown, and one whose effect is unknown is reported
  # (`:report`, the default) so the loop stops the turn on it, or marked in
  # place (`:mark`) once the turn's stop already covers it.
  defp settle_dead(%State{} = state, %{step: step, call: call}, reason, mode \\ :report) do
    guest = guest(state)

    case Tape.step(guest, step.id) do
      {:ok, %{dispatch_state: "proposed"} = fresh} ->
        _ =
          Tape.close_step(guest, state.turn, fresh, "skipped", %{
            result: %{content: "the call was not started", payload: %{"skipped" => true}}
          })

        :ok

      {:ok, %{dispatch_state: "dispatched"} = fresh} ->
        if fresh.child_execution_id,
          do: Cyfr.Execution.cancel(ctx(state), fresh.child_execution_id)

        why = describe(reason)

        case TurnStep.unresolved(fresh) do
          :uncertain ->
            unknown(state, fresh, why, mode)

          :unknown ->
            _ = close(state, fresh, unwrap(call), {:unknown, "the outcome is unknown: #{why}"})
            :ok

          _replay ->
            _ = close(state, fresh, unwrap(call), {:error, "the call did not finish: #{why}"})
            :ok
        end

      _ ->
        :ok
    end
  end

  defp unknown(_state, step, reason, :report), do: {:uncertain, step, reason}

  defp unknown(%State{} = state, step, reason, :mark) do
    _ = Tape.mark_uncertain(guest(state), state.turn, step, reason)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Stopping on an unknown outcome
  # ---------------------------------------------------------------------------

  # The one sequence for every path. A root turn: the durable stop first
  # — the step's mark, the cancel-marks, the skips, the covering aborted
  # row and the pause in one transaction — then the siblings still
  # running are cancelled and settled against it, and the pause rides out
  # of the dispatch. A clone marks its own step and halts; its parent's
  # stop covers the clone step.
  defp stop_uncertain(%State{clone?: true} = state, step, reason, rest) do
    guest = guest(state)
    _ = Tape.mark_uncertain(guest, state.turn, step, reason)
    cancel_rest(state, rest)
    _ = Tape.skip_steps(guest, state.turn, "the role stopped: a call's outcome is unknown")
    {:halt, {:uncertain, reason}, state}
  end

  defp stop_uncertain(%State{} = state, step, reason, rest) do
    case pause_uncertain(state, step, reason) do
      {:ok, state} ->
        cancel_rest(state, rest)
        {:halt, {:paused, :uncertain}, %{state | restricted?: true}}

      {:error, error} ->
        {:halt, {:failed, error}, state}
    end
  end

  # The root held: the slot and the keeper go with the rows. The root
  # already let go around a launch: the rows alone.
  defp pause_uncertain(%State{claim: %{execution_id: id} = claim} = state, step, reason) do
    uncertain = %{
      step_id: step.id,
      generation: step.generation,
      reason: reason,
      content: @aborted_content
    }

    case Cyfr.Execution.pause_turn_root(ctx(state), id,
           claim: claim,
           turn_id: state.turn.id,
           fence: state.turn.fence,
           reason: "uncertain",
           uncertain: uncertain
         ) do
      {:ok, %{turn: paused} = moved} ->
        if moved[:aborted],
          do: announce(state, {:message, moved.aborted})

        {:ok, %{state | turn: paused, claim: nil, since: nil, active_ms: paused.active_ms}}

      {:error, _} = error ->
        error
    end
  end

  defp pause_uncertain(%State{claim: nil, turn: %{status: "paused"}} = state, step, reason) do
    case Tape.pause_uncertain(guest(state), state.turn, %{
           step_id: step.id,
           generation: step.generation,
           reason: reason,
           content: @aborted_content
         }) do
      {:ok, %{turn: paused}} -> {:ok, %{state | turn: paused}}
      {:error, _} = error -> error
    end
  end

  defp pause_uncertain(%State{} = state, _step, _reason), do: {:error, {:no_claim, state.turn.id}}

  # What the group still had in flight when it stopped: each child
  # execution cancelled, each nested handler stopped by its handle, each
  # worker killed, then the step settled against the boundary.
  defp cancel_rest(%State{} = state, rest) do
    Enum.each(rest, fn %{item: %{step: step} = item, task: task} ->
      if step.child_execution_id, do: Cyfr.Execution.cancel(ctx(state), step.child_execution_id)
      Aqua.Ops.cancel_call(handle(state, step))
      if task, do: Task.shutdown(task, :brutal_kill)
      _ = settle_dead(state, item, :cancelled, :mark)
      Aqua.Ops.release_call(handle(state, step))
    end)
  end

  # The caller-owned name of one in-chain call, for cancelling its
  # handler without the request id the loop does not hold.
  defp handle(%State{} = state, step), do: handle(state.turn, step)
  defp handle(%{id: turn_id}, step), do: {turn_id, step.id, step.generation}

  # ---------------------------------------------------------------------------
  # Launches: the root is let go around the application's own root
  # ---------------------------------------------------------------------------

  defp run_launch(%State{clone?: true} = state, %{step: step, call: call}) do
    close(state, step, unwrap(call), {:error, "a role launches nothing"})
    {:ok, state}
  end

  defp run_launch(%State{} = state, %{step: step, call: call}) do
    guest = guest(state)

    case Tape.mark_dispatched(guest, state.turn, step) do
      {:ok, step} ->
        case pause_root(state, :launch, step.id) do
          {:ok, state} ->
            case worker(fn -> Aqua.Launch.dispatch(ctx(state), step) end, @launch_timeout_ms) do
              {:ok, {:ok, %{execution_id: id, result: result}}} ->
                {:ok,
                 state |> close_launch(step, unwrap(call), {:ok, id, result}) |> resume_root(0)}

              {:ok, {:error, reason}} ->
                {:ok,
                 state |> close_launch(step, unwrap(call), {:error, reason}) |> resume_root(0)}

              # Whether the application started is not known: the turn
              # stops here, its root already let go.
              {:exit, reason} ->
                stop_uncertain(state, step, describe(reason), [])
            end

          # The root did not let go: the launch never started.
          {:error, reason} ->
            _ = close(state, step, unwrap(call), {:error, describe(reason)})
            {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  defp close_launch(state, step, call, {:ok, id, result}) do
    text = Jason.encode!(result, pretty: true)

    _ =
      Tape.close_step(guest(state), state.turn, step, "ok", %{
        result: %{
          content: text,
          payload: %{
            "tool_call_id" => call && call.tool_call_id,
            "name" => call && call.model_name,
            "is_error" => false
          }
        },
        execution_id: id
      })

    state
  end

  defp close_launch(state, step, call, {:error, reason}) do
    close(state, step, call, {:error, describe(reason)})
    state
  end

  defp unwrap({:ok, %Call{} = call}), do: call
  defp unwrap(_), do: nil

  # The slot and the keeper go, then the rows: this process holds both.
  defp pause_root(
         %State{claim: %{execution_id: execution_id} = claim} = state,
         reason,
         launch_step_id
       ) do
    case Cyfr.Execution.pause_turn_root(ctx(state), execution_id,
           claim: claim,
           turn_id: state.turn.id,
           fence: state.turn.fence,
           reason: Atom.to_string(reason),
           launch_step_id: launch_step_id
         ) do
      {:ok, %{turn: paused}} ->
        {:ok, %{state | turn: paused, claim: nil, since: nil, active_ms: paused.active_ms}}

      {:error, _} = error ->
        error
    end
  end

  defp pause_root(state, _reason, _step), do: {:error, {:no_claim, state.turn.id}}

  defp pause(%State{} = state, reason) do
    case pause_root(state, reason, nil) do
      {:ok, state} -> {:halt, {:paused, reason}, state}
      {:error, error} -> {:halt, {:failed, error}, state}
    end
  end

  defp resume_root(%State{} = state, tries) do
    case Cyfr.Execution.resume_turn_root(ctx(state), state.turn.root_execution_id,
           turn_id: state.turn.id,
           fence: state.turn.fence
         ) do
      {:ok, %{turn: resumed} = claim} ->
        %{state | turn: resumed, claim: claim, since: now(), active_ms: resumed.active_ms}

      {:error, _reason} when tries < length(@resume_backoff_ms) ->
        Process.sleep(Enum.at(@resume_backoff_ms, tries))
        resume_root(state, tries + 1)

      {:error, reason} ->
        Logger.warning(
          "[Aqua.Loop] turn #{state.turn.id} stays paused after its launch: #{inspect(reason)}"
        )

        state
    end
  end

  # ---------------------------------------------------------------------------
  # Settling open steps on a continuation
  # ---------------------------------------------------------------------------

  # A step found open settles by `TurnStep.unresolved/1`: a model step
  # without its response closes as an error (its request cannot be
  # rebuilt); a dispatched call that is safe to run again is opened afresh;
  # a flush's dispatched call closes with its outcome unknown and its
  # unstarted ones are skipped; a dispatched call whose effect is unknown
  # stops the turn on it — a person continues, never a replay; an approved
  # or unstarted step is dispatched once; a steer that arrived while the
  # turn was away skips them all.
  defp settle(%State{} = state) do
    guest = guest(state)

    with {:ok, steps} <- Tape.steps(guest, state.turn) do
      open =
        Enum.reduce(steps, [], fn
          %{dispatch_state: "dispatched"} = step, open ->
            if step.child_execution_id,
              do: Cyfr.Execution.cancel(ctx(state), step.child_execution_id)

            case TurnStep.unresolved(step) do
              :unanswered ->
                _ =
                  Tape.close_step(guest, state.turn, step, "error", %{error: "not reproducible"})

                open

              :replay ->
                _ = Tape.next_generation(guest, state.turn, step, Cyfr.UUID7.execution_id())
                open

              :unknown ->
                _ =
                  close(
                    state,
                    step,
                    unwrap(recall(state, step)),
                    {:unknown, "the turn was interrupted"}
                  )

                open

              :uncertain ->
                [step | open]
            end

          %{dispatch_state: "proposed", purpose: "flush"} = step, open ->
            _ =
              close(
                state,
                step,
                unwrap(recall(state, step)),
                {:skipped, "the turn was interrupted"}
              )

            open

          _step, open ->
            open
        end)
        |> Enum.reverse()

      state = %{
        state
        | restricted?: open != [] or Tape.restricted?(guest, state.turn),
          steps: Enum.count(steps, &(&1.kind == "model"))
      }

      cond do
        open != [] ->
          [first | others] = open
          rest = Enum.map(others, &%{item: %{step: &1, call: recall(state, &1)}, task: nil})
          stop_uncertain(state, first, "the turn was interrupted", rest)

        Tape.steer_pending?(guest, state.turn) ->
          _ = Tape.skip_steps(guest, state.turn, "a newer message arrived")
          {:continue, state}

        true ->
          case proposed_items(state) do
            [] -> {:continue, state}
            items -> dispatch(state, items)
          end
      end
    else
      {:error, reason} -> {:halt, {:failed, reason}, state}
    end
  end

  defp proposed_items(%State{} = state) do
    guest = guest(state)

    with {:ok, steps} <- Tape.steps(guest, state.turn) do
      for %{dispatch_state: "proposed", kind: kind} = step <- steps, kind != "model" do
        %{step: step, call: recall(state, step), approval: approved(state, step)}
      end
    else
      _ -> []
    end
  end

  defp approved(%State{} = state, %{approval_id: approval_id}) when is_binary(approval_id) do
    case Tape.approval(guest(state), approval_id) do
      {:ok, %{status: "approved"} = approval} -> approval
      _ -> nil
    end
  end

  defp approved(_state, _step), do: nil

  # The call a proposed step was recorded for, from its tool_call row.
  defp recall(%State{} = state, %{message_id: message_id}) when is_binary(message_id) do
    with {:ok, row} <- Tape.message(guest(state), message_id) do
      payload = Tape.payload(row)

      Binding.resolve(payload["name"] || "", payload["arguments"] || %{},
        roles: Turn.role_names(state.spec),
        tool_call_id: payload["tool_call_id"]
      )
    else
      _ -> {:error, "the call's row is gone"}
    end
  end

  defp recall(_state, _step), do: {:error, "the step names no call"}

  # ---------------------------------------------------------------------------
  # Compaction
  # ---------------------------------------------------------------------------

  defp compact(%State{spec: spec} = state, rows, flush? \\ true) do
    # Size the request the way the executor will: it encodes the input and
    # refuses it past the consented cap of the node being entered, which for
    # a model call is the catalyst, not the agent. Without this the turn
    # fails at admission on a request compaction could have made fit.
    excerpt = if state.excerpt_sent?, do: nil, else: spec.excerpt
    probe = request(state, rows, excerpt, state.steps == 0)

    case Planner.plan(rows,
           capabilities: spec.capabilities,
           max_tokens: Request.max_tokens(spec.capabilities),
           observed_tokens: state.observed,
           new_bytes: appended_bytes(rows, state.observed_seq),
           request_bytes: encoded_size(probe),
           max_request_size: catalyst_request_cap(spec)
         ) do
      :fit ->
        {:ok, state, rows}

      {:compact, %{summarized_through_seq: 0}} ->
        # Nothing older than the boundary: a summary of no rows costs a model
        # call and writes a row that stands for nothing. The estimate counts
        # only transcript rows, so on a small window the system prompt and
        # tool definitions alone can ask for this every round.
        {:ok, state, rows}

      {:compact, boundary} when flush? ->
        # The flush's rows are newer than any boundary, so the plan is made
        # again over the rows as they now stand.
        case flush(state, rows, probe) do
          {:flushed, state} ->
            with {:ok, rows} <- Tape.projection(guest(state), state.turn),
                 do: compact(state, rows, false)

          :skipped ->
            summarize(state, rows, boundary)

          {:error, :superseded} = superseded ->
            superseded
        end

      {:compact, boundary} ->
        summarize(state, rows, boundary)
    end
  end

  # One silent request before older rows are summarized away, so the model
  # can keep notes: `notes.keep` alone, under a standing `auto` re-read from
  # the member's grants, in a turn no unknown outcome restricts, with room
  # left for the flush, the summary and the next chat request, and only
  # when the request fits the catalyst's cap.
  defp flush(%State{spec: spec} = state, rows, probe) do
    cap = catalyst_request_cap(spec)

    with true <- flush_room?(state.steps, state.restricted?),
         {:ok, policy} <- Turn.current_policy(spec),
         "auto" <- Map.get(policy, @flush_key),
         request = flush_request(probe, policy),
         size when is_integer(size) and (is_nil(cap) or size <= cap) <- encoded_size(request),
         {:ok, step, state} <- open_model_step(state, "flush") do
      keep_notes(%{state | sent_upto: highest_seq(rows)}, step, request)
    else
      {:error, :superseded} = superseded -> superseded
      _not_flushed -> :skipped
    end
  end

  @doc false
  # Public for its own test: the gate a flush passes before the grant store
  # is asked — a turn no unknown outcome restricts, with room for the flush,
  # the summary and the next chat request under the step cap.
  @spec flush_room?(non_neg_integer(), boolean()) :: boolean()
  def flush_room?(steps, restricted?), do: not restricted? and steps + 3 <= @max_steps

  # The flush keeps notes of the rows a summary is about to replace, so it
  # is sent without the room excerpt: nothing of the room reaches it, and
  # the request the store keeps is the one sent.
  defp flush_request(probe, policy) do
    %{"messages" => messages} = Request.without_excerpt(probe)

    %{
      probe
      | "tools" => Request.catalog_tools(Map.take(policy, [@flush_key])),
        "provider_tools" => [],
        "messages" => Request.instruct(messages, @flush_instruction)
    }
  end

  # The reply's text is not the turn's and is not recorded; its calls are.
  defp keep_notes(%State{} = state, step, request) do
    case model_call(state, step, request, nil) do
      {:ok, data} ->
        {resolved, tool_calls} = resolve_calls(state, step, List.wrap(data["content"]))
        usage = data["usage"] || %{}

        case Tape.record_response(guest(state), state.turn, step, %{
               text: nil,
               usage: usage,
               stop_reason: data["stop_reason"],
               tool_calls: tool_calls
             }) do
          {:ok, %{calls: recorded}} ->
            state = count_usage(state, usage)

            Enum.zip_with(recorded, resolved, fn %{step: call_step}, {_block, call} ->
              keep_note(state, call_step, call)
            end)

            {:flushed, state}

          {:error, :superseded} = superseded ->
            superseded

          {:error, reason} ->
            _ =
              Tape.close_step(guest(state), state.turn, step, "error", %{error: describe(reason)})

            :skipped
        end

      {failure, reason} when failure in [:error, :exit] ->
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: describe(reason)})
        :skipped
    end
  end

  # A flush runs `notes.keep` and nothing else, never through a card: the
  # grant is asked again as the call dispatches, and an unknown outcome is
  # recorded on the call without stopping or restricting the turn.
  defp keep_note(
         %State{} = state,
         step,
         {:ok, %Call{kind: :catalog, tool: @flush_tool, action: @flush_action} = call}
       ) do
    content = call.args["content"]

    if is_binary(content) and byte_size(content) > @flush_note_max_bytes do
      close(
        state,
        step,
        call,
        {:error,
         {:denied, "a note kept before a summary holds at most #{@flush_note_max_bytes} bytes"}}
      )
    else
      item = %{step: step, call: {:ok, call}, approval: nil}

      case worker(fn -> run_one(state, item) end, @step_timeout_ms) do
        {:ok, {:uncertain, step, reason}} ->
          close(state, step, call, {:unknown, "the note's outcome is unknown: #{reason}"})

        {:ok, _settled} ->
          :ok

        {:exit, reason} ->
          settle_dead(state, item, reason)
      end
    end
  end

  defp keep_note(%State{} = state, step, {:ok, %Call{} = call}),
    do:
      close(
        state,
        step,
        call,
        {:error, {:denied, "only #{@flush_key} runs while the thread is summarized"}}
      )

  defp keep_note(%State{} = state, step, {:error, message}),
    do: close(state, step, nil, {:error, message})

  defp summarize(%State{spec: spec} = state, rows, boundary) do
    previous = rows |> Enum.filter(&(&1.kind == "compaction")) |> List.last()

    # Only what the previous summary does not already stand for, and
    # never a compaction row: `Request.messages/2` renders the latest one
    # as a summary block, so leaving it in sends the previous summary
    # twice — once rendered, once as `previous_summary` below.
    since = if previous, do: Tape.payload(previous)["first_kept_seq"] || 0, else: 0

    older =
      Enum.filter(rows, fn row ->
        row.kind != "compaction" and row.seq >= since and
          row.seq < boundary.first_kept_seq
      end)

    request =
      Planner.summary_request(Request.messages(older),
        model: spec.model,
        previous_summary: previous && previous.content
      )

    case open_model_step(state, "compaction") do
      {:error, :step_cap} -> {:error, :step_cap}
      {:error, reason} -> skip_compaction(state, rows, reason)
      {:ok, step, state} -> commit_summary(state, rows, boundary, request, step)
    end
  end

  defp commit_summary(%State{} = state, rows, boundary, request, step) do
    with {:ok, data} <- model_call(state, step, request, nil),
         summary =
           data["content"]
           |> List.wrap()
           |> Enum.filter(&(&1["type"] == "text"))
           |> Enum.map_join("", & &1["text"]),
         {:ok, summary} <- summary_text(summary),
         {:ok, _} <-
           Tape.record_response(guest(state), state.turn, step, %{
             text: nil,
             usage: data["usage"] || %{},
             stop_reason: data["stop_reason"],
             tool_calls: []
           }),
         {:ok, _} <-
           Tape.append_compaction(guest(state), state.turn, %{
             summary: summary,
             first_kept_seq: boundary.first_kept_seq,
             summarized_through_seq: boundary.summarized_through_seq,
             step_id: step.id
           }),
         {:ok, projected} <- Tape.projection(guest(state), state.turn) do
      {:ok, %{state | observed: nil}, projected}
    else
      {:error, :superseded} ->
        {:error, :superseded}

      other ->
        # The summary request answered nothing the turn can commit; a step
        # already closed by its response stays as it closed.
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: failure(other)})
        skip_compaction(state, rows, other)
    end
  end

  defp highest_seq([]), do: 0
  defp highest_seq(rows), do: rows |> Enum.map(& &1.seq) |> Enum.max()

  # What has arrived since the response whose token count we are reusing —
  # a steer, a tool result, a clone's summary. Counting the estimate alone
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

  @doc false
  # Public for its own test. Whether the cap resolves is otherwise
  # unobservable: the token estimate trips before a transcript can reach the
  # byte cap under ordinary conditions, so no end-to-end turn reaches this
  # branch, and a cap of nil looks exactly like a request that fits.
  # By name, without the version. The spec carries a versioned ref because
  # that is what resolved, but the consent graph keys every node by name —
  # `Cyfr.Execution.Admission` steps by name and `Authority.limits/1` matches on
  # that. A versioned key finds nothing, and a cap of nil is a check that
  # never fires.
  def catalyst_request_cap(%{authority: authority, catalyst: catalyst}) do
    with {:ok, name_ref} <- Cyfr.ComponentRef.to_name_ref(catalyst),
         {:ok, %Cyfr.Limits{max_request_size: cap}} <-
           Cyfr.Authority.node_limits(authority, name_ref) do
      cap
    else
      _ -> nil
    end
  end

  # A compaction that did not land leaves the rows as they were; the
  # model step it opened stays counted.
  @doc """
  The summary a compaction may commit, or `:empty_summary`.

  A compaction row commits its boundary seqs, so the projection drops every
  row before `first_kept_seq` and renders the summary in their place. An empty
  summary would drop them behind nothing. Any reply carrying no text block
  produces one — not only a reply that is all tool calls.

  Public because the branch is unobservable end-to-end: reaching it needs a
  transcript past the compaction threshold and a model that answers it without
  text, and a skipped compaction looks exactly like a request that fit.
  """
  @spec summary_text(String.t()) :: {:ok, String.t()} | {:error, :empty_summary}
  def summary_text(summary) when is_binary(summary) do
    if String.trim(summary) == "", do: {:error, :empty_summary}, else: {:ok, summary}
  end

  defp failure({kind, reason}) when kind in [:error, :exit], do: describe(reason)
  defp failure(other), do: describe(other)

  defp skip_compaction(%State{} = state, rows, reason) do
    Logger.warning("[Aqua.Loop] compaction skipped for turn #{state.turn.id}: #{inspect(reason)}")
    {:ok, state, rows}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp consented?(%State{spec: spec}, reference) do
    target =
      {:invoke,
       %{
         reference: Aqua.Hands.name_level(reference),
         need: nil,
         activation_digest: nil,
         declared_needs: []
       }}

    match?({:child, _}, Cyfr.Authority.Transition.step(spec.authority, :call, target))
  rescue
    ArgumentError -> false
  end

  # What this turn and its clones wrote to, from the durable rows.
  defp touched(%State{} = state) do
    case Tape.closed_calls(guest(state), state.turn) do
      {:ok, payloads} -> Policy.touched_refs(payloads)
      _ -> MapSet.new()
    end
  end

  # The references this response's own calls would write to, whatever order
  # they run in and whether or not they have closed.
  defp proposes(items) do
    items
    |> Enum.flat_map(fn
      %{call: {:ok, %Call{} = call}} ->
        [%{"tool" => call.tool, "action" => call.action, "arguments" => call.args}]

      _ ->
        []
    end)
    |> Policy.touched_refs()
  end

  defp pending?(%State{} = state) do
    case Tape.pending_approvals(guest(state), state.turn) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp replay_safe?(%Call{} = call), do: Policy.replay_safe?(call)

  defp over_deadline?(%State{parent: %State{} = parent}), do: over_deadline?(parent)

  defp over_deadline?(%State{since: since, active_ms: active_ms, spec: %Turn{deadline_ms: limit}}) do
    running = if since, do: now() - since, else: 0
    active_ms + running >= limit
  end

  defp over_deadline?(_state), do: false

  defp activity(%State{} = state, items, status) do
    names =
      Enum.map(items, fn %{call: call} ->
        if(match?({:ok, _}, call), do: elem(call, 1).model_name, else: "tool")
      end)

    activity =
      case status do
        :running ->
          state.activity ++ Enum.map(names, &%{tool: &1, status: :running, preview: nil})

        :done ->
          Enum.reduce(names, state.activity, &mark_done(&2, &1))
      end

    announce(state, {:tool_activity, activity})
    %{state | activity: activity}
  end

  # The newest running entry for `tool` is done; none running adds a done one.
  defp mark_done(activity, tool) do
    index =
      activity
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {entry, i} ->
        entry.tool == tool and entry.status == :running and i
      end)

    case index do
      nil -> activity ++ [%{tool: tool, status: :done, preview: nil}]
      i -> List.update_at(activity, i, &%{&1 | status: :done})
    end
  end

  defp system_row(%State{} = state, text) do
    Tape.append(guest(state), state.turn.thread_id, %{
      author: Arca.Schemas.Message.system_author(),
      kind: "system",
      content: text,
      turn_id: state.turn.id,
      execution_id: state.turn.root_execution_id
    })
  end

  defp announce(%State{} = state, event),
    do: Tape.announce(guest(state), state.turn.thread_id, event)

  defp worker(fun, timeout) do
    task = Aqua.Loop.Worker.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:exit, reason}
      nil -> {:exit, :timeout}
    end
  end

  # The request the store keeps: the one sent, less the room excerpt the
  # builder placed last — sent to the model, recorded as excluded on the
  # step, never retained.
  defp retained(_request, nil), do: nil
  defp retained(request, _excerpt), do: Request.without_excerpt(request)

  defp digest(request) do
    case Cyfr.JCS.hash(request) do
      {:ok, digest} -> digest
      _ -> nil
    end
  end

  defp describe({:model_refused, _catalyst, %{"message" => message}}) when is_binary(message),
    do: "The model could not be described: #{message}"

  defp describe({:unknown_model, model}), do: "#{model} is not a model its catalyst knows"
  defp describe(:no_model), do: "The agent names no model"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: Aqua.Ops.render_refusal(reason)

  defp guest(%State{spec: %Turn{guest: guest}}), do: guest
  defp ctx(%State{spec: %Turn{ctx: ctx}}), do: ctx
  defp now, do: System.monotonic_time(:millisecond)
end
