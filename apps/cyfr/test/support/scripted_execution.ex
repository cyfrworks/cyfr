# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedExecution do
  @moduledoc """
  The execution port with one scripted component. Every call reaches the
  real engine except `run_child/5` of the scripted reference, which runs
  the child's complete lifecycle without a guest: the chain's transition
  and invoke charge, the admission transaction with its hold and step
  barriers, a `:child` slot held by the calling process for the call, and
  the terminal attempt write — then answers the next scripted item.

  A script is a list consumed in order across calls. A call takes items
  until it reaches an answer:

  - `%{...}` — the `model/chat@1` data the child answers, wrapped in the
    envelope `%{"status" => 200, "data" => data}`; the call completes.
  - `{:error, message}` — the child fails with `message`.
  - `{:refuse, %{"type", "message"}}` — the child completes with the
    contract's typed refusal in its envelope.
  - `{:emit, events}` — push each event (a map) on the child's own event
    stream through `Opus.Emit`, as a streaming catalyst does, before the
    next item.
  - `{:sleep, ms}` — wait before the next item.
  - `{:probe, pid}` — send `{:scripted_probe, self(), execution_id}` to
    `pid` and wait for `:continue` (5 s), so a test can inspect what the
    call holds while it runs.
  - `{:crash, :before_response}` — kill the calling process after
    admission, leaving the attempt open.
  - `{:crash, :after_persist}` — kill the calling process once the next
    answer is written, before it is returned.
  - `:hang` — never return.

  A scripted reference is never rooted (a turn claims its root without a
  guest); every other root reaches the engine. Select the engine with
  `config :cyfr, :execution_impl`
  inside the test; users are `async: false` since the script is one
  named agent.
  """

  @behaviour Cyfr.Execution

  alias Sanctum.Authority

  @agent __MODULE__

  def child_spec(opts) do
    %{id: @agent, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc """
  Start the script agent: `ref:` the scripted reference (or a list),
  `script:` its items, `window:` the context window `describe` answers
  for any model (default 200_000), `describe:` `{:refuse, error}` to have
  a described model refused instead.
  """
  def start_link(opts) do
    keys =
      opts
      |> Keyword.fetch!(:ref)
      |> List.wrap()
      |> Enum.map(fn ref ->
        {:ok, key} = Compendium.Activation.key_for_ref(ref)
        key
      end)

    script = Keyword.get(opts, :script, [])
    window = Keyword.get(opts, :window, 200_000)
    describe = Keyword.get(opts, :describe, :answer)

    Agent.start_link(
      fn -> %{refs: keys, script: script, window: window, describe: describe, calls: []} end,
      name: @agent
    )
  end

  @doc "Replace the remaining script."
  def script(items) when is_list(items), do: Agent.update(@agent, &%{&1 | script: items})

  @doc "Every scripted call so far, oldest first: `%{execution_id, input, authority}`."
  def calls, do: @agent |> Agent.get(& &1.calls) |> Enum.reverse()

  # ---------------------------------------------------------------------------
  # The port
  # ---------------------------------------------------------------------------

  # A scripted reference is never rooted — a turn claims its root without
  # a guest, and a listing that probes the catalyst is refused; every
  # other root reaches the engine.
  @impl true
  def run_root(ctx, selector, reference, input, opts) do
    if scripted?(reference),
      do: {:error, "the scripted engine roots nothing"},
      else: engine().run_root(ctx, selector, reference, input, opts)
  end

  @impl true
  def run_root_edge(ctx, source_ref, reference, input, opts),
    do: engine().run_root_edge(ctx, source_ref, reference, input, opts)

  @impl true
  def authority_for(ctx, selector, reference, opts),
    do: engine().authority_for(ctx, selector, reference, opts)

  @impl true
  def subscribe_events(id, scope), do: engine().subscribe_events(id, scope)
  @impl true
  def unsubscribe_events(id, scope), do: engine().unsubscribe_events(id, scope)
  @impl true
  def events_since(id, seq, athanor_id), do: engine().events_since(id, seq, athanor_id)

  @impl true
  def run_child(%Authority{} = authority, reference, need, input, opts) do
    if scripted?(reference),
      do: scripted_child(authority, reference, need, input, opts),
      else: engine().run_child(authority, reference, need, input, opts)
  end

  @impl true
  def claim_turn_root(ctx, reference, opts), do: engine().claim_turn_root(ctx, reference, opts)
  @impl true
  def pause_turn_root(ctx, id, opts), do: engine().pause_turn_root(ctx, id, opts)
  @impl true
  def resume_turn_root(ctx, id, opts), do: engine().resume_turn_root(ctx, id, opts)
  @impl true
  def adopt_turn_root(ctx, id, opts), do: engine().adopt_turn_root(ctx, id, opts)
  @impl true
  def release_turn_root(ctx, id, opts), do: engine().release_turn_root(ctx, id, opts)
  @impl true
  def cancel(ctx, id), do: engine().cancel(ctx, id)
  @impl true
  def cancel_for_restart(ctx, id, payload), do: engine().cancel_for_restart(ctx, id, payload)
  @impl true
  def get(ctx, id), do: engine().get(ctx, id)
  @impl true
  def list(ctx, opts), do: engine().list(ctx, opts)
  @impl true
  def ready?, do: engine().ready?()

  # ---------------------------------------------------------------------------
  # The scripted child
  # ---------------------------------------------------------------------------

  defp scripted?(reference) do
    with pid when is_pid(pid) <- Process.whereis(@agent),
         {:ok, key} <- Compendium.Activation.key_for_ref(reference) do
      key in Agent.get(pid, & &1.refs)
    else
      _ -> false
    end
  end

  # The same shape as the engine's `run_child/5`: the decision charges the
  # invoke budget for a spawn, the guard releases it on :DOWN, and the
  # charge row is taken before the child runs and given back after.
  defp scripted_child(authority, reference, need, input, opts) do
    with {:ok, decision} <- chain().step_invoke(authority, reference, need, opts) do
      if Keyword.get(opts, :guest_fn) == :spawn do
        with :ok <- charge().take(decision.authority, opts) do
          Authority.guard_invoke(decision.authority)

          try do
            run_scripted(decision, reference, input, opts)
          after
            Authority.release_invoke(decision.authority)
            charge().give_back(decision.authority, opts)
          end
        end
      else
        run_scripted(decision, reference, input, opts)
      end
    end
  end

  defp run_scripted(decision, reference, input, opts) do
    ctx = Keyword.fetch!(opts, :ctx)
    id = Keyword.get(opts, :execution_id) || Cyfr.UUID7.execution_id()
    attempt = Arca.ExecutionAttempts.generate_id()
    started_at = DateTime.utc_now()
    retained = Keyword.get(opts, :retained_input) || input

    attrs = %{
      id: id,
      request_id: ctx.request_id,
      reference: reference,
      input_hash: Arca.Execution.hash_input(input),
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      component_type: "catalyst",
      started_at: started_at,
      input: Jason.encode!(retained),
      parent_execution_id: Keyword.get(opts, :parent_execution_id),
      root_execution_id: Keyword.get(opts, :root_execution_id) || id,
      kind: "component"
    }

    # The engine stages the retained form of the input with admission;
    # the sent form is what `calls/0` answers.
    {:ok, staged} =
      Arca.ExecutionPayloads.stage(
        ctx,
        id,
        "input",
        Jason.encode!(retained),
        Keyword.get(opts, :retention_class) || "api"
      )

    admission = [attempt: attempt, payloads: [staged]] ++ barrier_opts(decision.authority, opts)

    with {:ok, _} <- Arca.Execution.admit(attrs, admission) do
      case slot().acquire(:child, ctx.athanor_id, 30_000, id) do
        {:ok, token} ->
          Agent.update(@agent, fn state ->
            call = %{execution_id: id, input: input, authority: decision.authority}
            %{state | calls: [call | state.calls]}
          end)

          call = %{
            ctx: ctx,
            id: id,
            attempt: attempt,
            started_at: started_at,
            authority: decision.authority
          }

          try do
            answer(call, false, input)
          after
            slot().release(token)
          end

        {:error, refusal} ->
          fail(ctx, id, attempt, started_at, refusal)
          {:error, refusal}
      end
    end
  end

  # The barriers the engine's admission performs for a loop-dispatched
  # child: the hold row named by the charge, the step on its generation.
  defp barrier_opts(%Authority{budget: budget}, opts) do
    case Keyword.get(opts, :charge) do
      %{id: charge_id, generation: generation} ->
        step =
          case Keyword.get(opts, :step_id) do
            nil -> []
            step_id -> [step: %{id: step_id, generation: generation}]
          end

        [charge: %{reservation_id: budget.id, id: charge_id}] ++ step

      _ ->
        []
    end
  end

  # The catalyst's own answers about itself are not the script's: a
  # capability probe is answered the same way every time.
  defp answer(call, _crash_after?, %{"operation" => "describe", "params" => params}) do
    case Agent.get(@agent, & &1.describe) do
      {:refuse, error} -> refuse(call, error)
      :answer -> described(call, params)
    end
  end

  defp answer(call, crash_after?, _input), do: answer(call, crash_after?)

  defp described(call, params) do
    complete(
      call,
      Map.merge(
        %{
          "contracts" => ["model/chat@1"],
          "provider" => "scripted",
          "tools" => true,
          "provider_tools" => [],
          "media_types" => ["image/png"],
          "streaming" => true,
          "defaults" => %{}
        },
        described_model(params)
      )
    )
  end

  defp answer(call, crash_after?) do
    case take_item() do
      nil ->
        fail(call.ctx, call.id, call.attempt, call.started_at, "script exhausted")
        {:error, "script exhausted"}

      {:emit, events} ->
        emit(call, events)
        answer(call, crash_after?)

      {:sleep, ms} ->
        Process.sleep(ms)
        answer(call, crash_after?)

      {:probe, pid} ->
        send(pid, {:scripted_probe, self(), call.id})

        receive do
          :continue -> :ok
        after
          5_000 -> :ok
        end

        answer(call, crash_after?)

      {:crash, :before_response} ->
        Process.exit(self(), :kill)

      {:crash, :after_persist} ->
        answer(call, true)

      :hang ->
        Process.sleep(:infinity)

      {:error, message} ->
        fail(call.ctx, call.id, call.attempt, call.started_at, message)
        {:error, message}

      {:refuse, %{"type" => _} = error} ->
        refuse(call, error)

      %{} = data ->
        result = complete(call, data)
        if crash_after?, do: Process.exit(self(), :kill)
        result
    end
  end

  defp described_model(%{"model" => model}) when is_binary(model),
    do: %{"model" => model, "context_window" => Agent.get(@agent, & &1.window)}

  defp described_model(_params), do: %{}

  defp emit(call, events) do
    emitter = emitter().open(call.id, ctx: call.ctx, authority: call.authority)

    try do
      Enum.each(events, &emitter().emit(emitter, Jason.encode!(&1)))
    after
      emitter().close(emitter)
    end
  end

  # The catalyst's typed refusal: the run completes, the envelope refuses.
  defp refuse(call, error) do
    envelope = %{"status" => 429, "error" => error}
    written(call.ctx, call.id, call.attempt, call.started_at, envelope)
  end

  defp complete(call, data) do
    envelope = %{"status" => 200, "data" => data}
    written(call.ctx, call.id, call.attempt, call.started_at, envelope)
  end

  # The terminal write; a row that is no longer running (a cancel, a
  # sweep, a test that ended) answers a refusal instead of a crash.
  defp written(ctx, id, attempt, started_at, envelope) do
    now = DateTime.utc_now()

    case Arca.Execution.record_end(
           ctx,
           id,
           "completed",
           %{
             completed_at: now,
             duration_ms: DateTime.diff(now, started_at, :millisecond),
             output: Jason.encode!(envelope)
           },
           attempt
         ) do
      {:ok, _} ->
        {:ok,
         %{status: :completed, output: envelope, metadata: %{execution_id: id, attempt: attempt}}}

      {:error, reason} ->
        {:error, {:not_recorded, reason}}
    end
  end

  defp fail(ctx, id, attempt, started_at, message) do
    now = DateTime.utc_now()

    Arca.Execution.record_end(
      ctx,
      id,
      "failed",
      %{
        completed_at: now,
        duration_ms: DateTime.diff(now, started_at, :millisecond),
        error_message: to_string(message)
      },
      attempt
    )
  end

  defp take_item do
    Agent.get_and_update(@agent, fn
      %{script: []} = state -> {nil, state}
      %{script: [item | rest]} = state -> {item, %{state | script: rest}}
    end)
  end

  # Named at runtime: cyfr does not depend on opus, and these modules are
  # reachable only from the umbrella's own test run.
  defp engine, do: Module.concat([:Opus])
  defp chain, do: Module.concat([:Opus, :Chain])
  defp charge, do: Module.concat([:Opus, :Chain, :Charge])
  defp slot, do: Module.concat([:Opus, :Slot])
  defp emitter, do: Module.concat([:Opus, :Emit])
end
