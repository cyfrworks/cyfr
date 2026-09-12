# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop do
  @moduledoc """
  The agent loop: one turn, run by the process that holds its root.

  A round drains the steer, projects the tape, plans the request (a
  compaction first when the window is full), records the model call
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
  alias Sanctum.Context

  @max_steps 30
  @model_timeout_ms 10 * 60 * 1000
  @step_timeout_ms 5 * 60 * 1000
  @launch_timeout_ms 10 * 60 * 1000
  @retry_delays_ms [2_000, 8_000, 20_000]
  @resume_backoff_ms [500, 2_000, 8_000]
  @recoverable ~w(rate_limited overloaded)
  @aborted_content "a call's outcome is unknown; tools may have partially executed"
  @setup ~w(authentication secret_denied)

  defmodule State do
    @moduledoc false
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
          conclude(state, loop(state))

        # The root is held but the turn never ran: ended with the actor's
        # own context, since no spec was built to carry it, and the root
        # closed by the release when the turn never came to carry it.
        {:error, {:after_claim, claim, turn, reason}} ->
          error = describe(reason)
          _ = Tape.finish(ctx, turn, "failed", %{error: error})
          Cyfr.Execution.release_turn_root(ctx, claim.execution_id, claim: claim, failed: error)
          {:failed, reason}

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

  defp setup_required(ctx, turn) do
    _ = Tape.finish(ctx, turn, "failed", %{error: "setup_required"})
    Tape.announce(ctx, turn.conversation_id, {:consent_required, source_ref(turn), ctx.user_id})
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
         {:ok, spec} <- Turn.build(ctx, turn, authority: authority, excerpt?: false) do
      state = %State{
        spec: spec,
        claim: claim,
        turn: turn,
        since: now(),
        active_ms: turn.active_ms
      }

      case settle(state) do
        {:continue, state} -> conclude(state, loop(state))
        {:halt, result, state} -> conclude(state, {result, state})
      end
    else
      {:error, {:reclaimed, claim, turn, reason}} ->
        state = %State{spec: nil, claim: claim, turn: turn}
        conclude(state, {{:failed, reason}, state})

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Abort a turn from outside its process, before it is stopped: the fence
  is renewed and the dispatched steps cancel-marked, every child is
  cancelled, dispatched steps close `uncertain` (an aborted read that is
  safe to replay closes `error`), unstarted steps are skipped, and the
  aborted mark is written. The caller then ends the turn.
  """
  @spec abort(Context.t(), Tape.turn(), String.t()) :: {:ok, Tape.turn()} | {:error, term()}
  def abort(%Context{} = ctx, turn, reason) do
    guest = Context.enter_guest(ctx)

    with {:ok, superseded} <- Tape.supersede(guest, turn),
         {:ok, steps} <- Tape.steps(guest, superseded) do
      Enum.each(steps, fn
        %{dispatch_state: "dispatched"} = step ->
          if step.child_execution_id, do: Cyfr.Execution.cancel(ctx, step.child_execution_id)

          if replay_safe_step?(step),
            do: Tape.close_step(guest, superseded, step, "error", %{error: reason}),
            else: Tape.mark_uncertain(guest, superseded, step, reason)

        _ ->
          :ok
      end)

      _ = Tape.skip_steps(guest, superseded, reason)
      _ = Tape.append_aborted(guest, superseded, reason)
      {:ok, superseded}
    end
  end

  # ---------------------------------------------------------------------------
  # Claiming
  # ---------------------------------------------------------------------------

  defp claim_and_start(ctx, turn) do
    with {:ok, claim} <-
           Cyfr.Execution.claim_turn_root(ctx, source_ref(turn),
             turn_id: turn.id,
             conversation_id: turn.conversation_id,
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
           {:ok, spec} <- Turn.build(ctx, started, authority: claim.authority) do
        {:ok,
         %State{
           spec: spec,
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
        _ = Tape.finish(ctx(state), ended.turn, status, %{error: error})
        release(ended)
        result
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
         {:ok, step} <- open_model_step(planned, "chat") do
      excerpt = if planned.excerpt_sent?, do: nil, else: planned.spec.excerpt
      request = request(planned, rows, excerpt)

      if excerpt do
        _ =
          Tape.mark_excluded(guest(planned), step, %{
            excluded: ["room_excerpt"],
            request_digest: digest(request)
          })
      end

      ask_model(%{planned | excerpt_sent?: true}, step, request, 0)
    else
      {:error, :superseded} -> {:halt, :cancelled, state}
      {:error, reason} -> {:halt, {:failed, reason}, state}
    end
  end

  defp request(%State{spec: spec} = state, rows, excerpt) do
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
        attachments: if(state.steps == 0, do: spec.attachments, else: [])
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
  defp open_model_step(%State{} = state, action) do
    with {:ok, step} <-
           Tape.record_model_intent(guest(state), state.turn, %{
             idempotency_key:
               "model:#{state.turn.id}:#{System.unique_integer([:positive, :monotonic])}",
             child_execution_id: Cyfr.UUID7.execution_id(),
             tool: state.spec.catalyst,
             action: action
           }) do
      Tape.mark_dispatched(guest(state), state.turn, step)
    end
  end

  defp ask_model(%State{} = state, step, request, retries) do
    case model_call(state, step, request) do
      {:ok, data} ->
        on_response(state, step, data)

      {:error, %{"type" => type}}
      when type in @recoverable and retries < length(@retry_delays_ms) ->
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: type})
        Process.sleep(Enum.at(@retry_delays_ms, retries))

        case open_model_step(state, "chat") do
          {:ok, again} -> ask_model(state, again, request, retries + 1)
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

      {:error, reason} ->
        text = describe(reason)
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: text})
        _ = system_row(state, "The model could not be reached: #{text}")
        {:halt, {:failed, reason}, state}

      {:exit, reason} ->
        _ = Tape.mark_uncertain(guest(state), state.turn, step, describe(reason))
        {:halt, {:uncertain, reason}, state}
    end
  end

  # The catalyst runs as a child of the root, in a worker: the answer is
  # the contract's data, a typed refusal, the engine's refusal, or the
  # worker's death.
  defp model_call(%State{spec: spec} = state, step, request) do
    input = %{"operation" => "chat", "params" => request}
    guest = guest(state)
    turn = state.turn

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
          charge: Binding.charge(step, turn),
          guest_fn: :spawn
        )
      end,
      @model_timeout_ms
    )
    |> case do
      {:ok, {:ok, %{output: output}}} -> Cyfr.Models.decode_envelope(output)
      {:ok, {:ok, output}} -> Cyfr.Models.decode_envelope(output)
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:exit, reason}
    end
  end

  # The whole response lands before any call runs.
  defp on_response(%State{} = state, step, data) do
    content = List.wrap(data["content"])
    text = content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("", & &1["text"])
    blocks = Enum.filter(content, &(&1["type"] == "tool_call"))

    resolved =
      Enum.map(blocks, fn block ->
        name = block["name"] || ""
        args = if is_map(block["arguments"]), do: block["arguments"], else: %{}

        {block,
         Binding.resolve(name, args,
           roles: Turn.role_names(state.spec),
           tool_call_id: block["id"]
         )}
      end)

    tool_calls =
      Enum.map(resolved, fn {block, call} -> call_attrs(state, step, block, call) end)

    usage = data["usage"] || %{}

    case Tape.record_response(guest(state), state.turn, step, %{
           text: if(text == "", do: nil, else: text),
           usage: usage,
           stop_reason: data["stop_reason"],
           tool_calls: tool_calls
         }) do
      {:ok, %{calls: recorded}} ->
        state =
          state
          |> count_usage(usage)
          |> Map.update!(:steps, &(&1 + 1))

        items =
          Enum.zip_with(recorded, resolved, fn %{step: call_step}, {_block, call} ->
            %{step: call_step, call: call, approved?: false}
          end)

        if items == [], do: {:halt, :completed, state}, else: dispatch(state, items)

      {:error, :superseded} ->
        {:halt, :cancelled, state}

      {:error, reason} ->
        {:halt, {:failed, reason}, state}
    end
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

  defp child_id_for(%Call{kind: kind}) when kind in [:hand, :launch],
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
    %{state | usage: totals, observed: if(input > 0, do: input, else: state.observed)}
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  # Cards first, then the runnable steps in source order; a group of
  # reads runs beside itself, everything else alone; a steer that
  # arrived skips what has not started.
  defp dispatch(%State{} = state, items) do
    touched = touched(state)
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

  defp decide_open(_state, _touched, %{approved?: true} = item, {runnable, cards}),
    do: {[item | runnable], cards}

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
           expires_at: DateTime.add(DateTime.utc_now(), 24 * 3600, :second),
           card: %{content: intent["title"], payload: %{"intent" => intent}}
         }) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp group(items) do
    Enum.chunk_while(
      items,
      [],
      fn item, acc ->
        cond do
          launch?(item) and acc == [] -> {:cont, {:launch, item}, []}
          launch?(item) -> {:cont, {:concurrent, Enum.reverse(acc)}, [item]}
          concurrent?(item) -> {:cont, [item | acc]}
          acc == [] -> {:cont, {:exclusive, item}, []}
          true -> {:cont, {:concurrent, Enum.reverse(acc)}, [item]}
        end
      end,
      fn
        [] ->
          {:cont, []}

        [item] ->
          if launch?(item),
            do: {:cont, {:launch, item}, []},
            else: {:cont, {:concurrent, [item]}, []}

        acc ->
          {:cont, {:concurrent, Enum.reverse(acc)}, []}
      end
    )
    |> Enum.flat_map(fn
      {:concurrent, [item]} ->
        [if(concurrent?(item), do: {:concurrent, [item]}, else: {:exclusive, item})]

      other ->
        [other]
    end)
  end

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
    task = Task.Supervisor.async_nolink(Aqua.TaskSupervisor, fn -> run_one(state, item) end)
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
  def run_one(%State{} = state, %{step: step, call: {:ok, %Call{} = call}}) do
    case Tape.mark_dispatched(guest(state), state.turn, step) do
      {:ok, step} ->
        case normalise(execute(state, step, call)) do
          {:uncertain, reason} ->
            {:uncertain, step, describe(reason)}

          result ->
            _ = close(state, step, call, result)
            :ok
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
      conversation_id: state.turn.conversation_id,
      agent_ref: Compendium.AgentSource.ref(state.turn.orchestrator),
      charge: Binding.charge(step, state.turn),
      execution_id: step.child_execution_id,
      step_id: step.id,
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

  # The step's result row and outcome: `ok`, `error`, or `denied` for a
  # refusal by the policy or the chain.
  defp close(%State{} = state, step, call, result) do
    {outcome, text, error?} =
      case result do
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
  # skipped; a dispatched one that is safe to run again closes as an
  # error the model may retry; a dispatched one whose effect is unknown
  # is reported (`:report`, the default) so the loop stops the turn on
  # it, or marked in place (`:mark`) once the turn's stop already covers
  # it.
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

        case call do
          {:ok, %Call{} = c} when c.kind != :clone ->
            if replay_safe?(c) do
              _ = close(state, fresh, c, {:error, "the call did not finish: #{describe(reason)}"})
              :ok
            else
              unknown(state, fresh, describe(reason), mode)
            end

          _ ->
            unknown(state, fresh, describe(reason), mode)
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
  defp handle(%State{} = state, step), do: {state.turn.id, step.id, step.generation}

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

  # A step found open: a model step without its response closes as an
  # error (its request cannot be rebuilt); a dispatched call that is
  # safe to run again is opened afresh; a dispatched call whose effect is
  # unknown stops the turn on it — a person continues, never a replay;
  # an approved or unstarted step is dispatched once; a steer that
  # arrived while the turn was away skips them all.
  defp settle(%State{} = state) do
    guest = guest(state)

    with {:ok, steps} <- Tape.steps(guest, state.turn) do
      open =
        Enum.reduce(steps, [], fn
          %{dispatch_state: "dispatched", kind: "model"} = step, open ->
            _ = Tape.close_step(guest, state.turn, step, "error", %{error: "not reproducible"})
            open

          %{dispatch_state: "dispatched"} = step, open ->
            if step.child_execution_id,
              do: Cyfr.Execution.cancel(ctx(state), step.child_execution_id)

            if replay_safe_step?(step) do
              _ = Tape.next_generation(guest, step, Cyfr.UUID7.execution_id())
              open
            else
              [step | open]
            end

          _step, open ->
            open
        end)
        |> Enum.reverse()

      state = %{state | restricted?: open != [] or Tape.restricted?(guest, state.turn)}

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
        %{step: step, call: recall(state, step), approved?: approved?(state, step)}
      end
    else
      _ -> []
    end
  end

  defp approved?(%State{} = state, %{approval_id: approval_id}) when is_binary(approval_id) do
    match?({:ok, %{status: "approved"}}, Tape.approval(guest(state), approval_id))
  end

  defp approved?(_state, _step), do: false

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

  defp compact(%State{spec: spec} = state, rows) do
    case Planner.plan(rows,
           capabilities: spec.capabilities,
           max_tokens: Request.max_tokens(spec.capabilities),
           observed_tokens: state.observed
         ) do
      :fit ->
        {:ok, state, rows}

      {:compact, boundary} ->
        older = Enum.filter(rows, &(&1.seq < boundary.first_kept_seq))
        previous = rows |> Enum.filter(&(&1.kind == "compaction")) |> List.last()

        request =
          Planner.summary_request(Request.messages(older),
            model: spec.model,
            previous_summary: previous && previous.content
          )

        with {:ok, step} <- open_model_step(state, "compaction"),
             {:ok, data} <- model_call(state, step, request),
             summary =
               data["content"]
               |> List.wrap()
               |> Enum.filter(&(&1["type"] == "text"))
               |> Enum.map_join("", & &1["text"]),
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
          {:ok, %{state | observed: nil, steps: state.steps + 1}, projected}
        else
          {:error, :superseded} ->
            {:error, :superseded}

          other ->
            Logger.warning(
              "[Aqua.Loop] compaction skipped for turn #{state.turn.id}: #{inspect(other)}"
            )

            {:ok, state, rows}
        end
    end
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

    match?({:child, _}, Sanctum.Authority.Transition.step(spec.authority, :call, target))
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

  defp pending?(%State{} = state) do
    case Tape.pending_approvals(guest(state), state.turn) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp replay_safe?(%Call{} = call), do: Policy.replay_safe?(call)

  defp replay_safe_step?(%{recovery: "replay_safe"}), do: true
  defp replay_safe_step?(_step), do: false

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
    Tape.append(guest(state), state.turn.conversation_id, %{
      author: Arca.Schemas.Message.system_author(),
      kind: "system",
      content: text,
      turn_id: state.turn.id,
      execution_id: state.turn.root_execution_id
    })
  end

  defp announce(%State{} = state, event),
    do: Tape.announce(guest(state), state.turn.conversation_id, event)

  defp worker(fun, timeout) do
    task = Task.Supervisor.async_nolink(Aqua.TaskSupervisor, fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:exit, reason}
      nil -> {:exit, :timeout}
    end
  end

  defp digest(request) do
    case Sanctum.JCS.hash(request) do
      {:ok, digest} -> digest
      _ -> nil
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: Aqua.Ops.render_refusal(reason)

  defp guest(%State{spec: %Turn{guest: guest}}), do: guest
  defp ctx(%State{spec: %Turn{ctx: ctx}}), do: ctx
  defp now, do: System.monotonic_time(:millisecond)
end
