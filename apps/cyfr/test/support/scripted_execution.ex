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
  - `{:sleep, ms}` — wait before the next item.
  - `{:probe, pid}` — send `{:scripted_probe, self(), execution_id}` to
    `pid` and wait for `:continue` (5 s), so a test can inspect what the
    call holds while it runs.
  - `{:crash, :before_response}` — kill the calling process after
    admission, leaving the attempt open.
  - `{:crash, :after_persist}` — kill the calling process once the next
    answer is written, before it is returned.
  - `:hang` — never return.

  `run_root/5` and `run_root_edge/5` raise: a turn never roots through
  the guest path. Select the engine with `config :cyfr, :execution_impl`
  inside the test; users are `async: false` since the script is one
  named agent.
  """

  @behaviour Cyfr.Execution

  alias Sanctum.Authority

  @agent __MODULE__

  def child_spec(opts) do
    %{id: @agent, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Start the script agent: `ref:` the scripted reference, `script:` its items."
  def start_link(opts) do
    {:ok, key} = Compendium.Activation.key_for_ref(Keyword.fetch!(opts, :ref))
    script = Keyword.get(opts, :script, [])
    Agent.start_link(fn -> %{ref: key, script: script, calls: []} end, name: @agent)
  end

  @doc "Replace the remaining script."
  def script(items) when is_list(items), do: Agent.update(@agent, &%{&1 | script: items})

  @doc "Every scripted call so far, oldest first: `%{execution_id, input}`."
  def calls, do: @agent |> Agent.get(& &1.calls) |> Enum.reverse()

  # ---------------------------------------------------------------------------
  # The port
  # ---------------------------------------------------------------------------

  @impl true
  def run_root(_ctx, _selector, reference, _input, _opts),
    do: raise(ArgumentError, "the scripted engine roots nothing (asked for #{reference})")

  @impl true
  def run_root_edge(_ctx, source_ref, _reference, _input, _opts),
    do: raise(ArgumentError, "the scripted engine roots nothing (asked for #{source_ref})")

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
      Agent.get(pid, & &1.ref) == key
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

    attrs = %{
      id: id,
      request_id: ctx.request_id,
      reference: reference,
      input_hash: Arca.Execution.hash_input(input),
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      component_type: "catalyst",
      started_at: started_at,
      input: Jason.encode!(input),
      parent_execution_id: Keyword.get(opts, :parent_execution_id),
      root_execution_id: Keyword.get(opts, :root_execution_id) || id,
      kind: "component"
    }

    admission = [attempt: attempt] ++ barrier_opts(decision.authority, opts)

    with {:ok, _} <- Arca.Execution.admit(attrs, admission) do
      case slot().acquire(:child, ctx.athanor_id, 30_000, id) do
        {:ok, token} ->
          Agent.update(@agent, &%{&1 | calls: [%{execution_id: id, input: input} | &1.calls]})

          try do
            answer(ctx, id, attempt, started_at, false)
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

  defp answer(ctx, id, attempt, started_at, crash_after?) do
    case take_item() do
      nil ->
        fail(ctx, id, attempt, started_at, "script exhausted")
        {:error, "script exhausted"}

      {:sleep, ms} ->
        Process.sleep(ms)
        answer(ctx, id, attempt, started_at, crash_after?)

      {:probe, pid} ->
        send(pid, {:scripted_probe, self(), id})

        receive do
          :continue -> :ok
        after
          5_000 -> :ok
        end

        answer(ctx, id, attempt, started_at, crash_after?)

      {:crash, :before_response} ->
        Process.exit(self(), :kill)

      {:crash, :after_persist} ->
        answer(ctx, id, attempt, started_at, true)

      :hang ->
        Process.sleep(:infinity)

      {:error, message} ->
        fail(ctx, id, attempt, started_at, message)
        {:error, message}

      %{} = data ->
        envelope = %{"status" => 200, "data" => data}
        now = DateTime.utc_now()

        {:ok, _} =
          Arca.Execution.record_end(
            ctx,
            id,
            "completed",
            %{
              completed_at: now,
              duration_ms: DateTime.diff(now, started_at, :millisecond),
              output: Jason.encode!(envelope)
            },
            attempt
          )

        if crash_after?, do: Process.exit(self(), :kill)

        {:ok,
         %{
           status: :completed,
           output: envelope,
           metadata: %{execution_id: id, attempt: attempt}
         }}
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
end
