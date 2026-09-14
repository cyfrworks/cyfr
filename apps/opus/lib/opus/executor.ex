# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Executor do
  @moduledoc """
  Runs an admitted WASM component.

  CYFR admits the run and closes it: `Cyfr.Execution.Admission.admit/4`
  resolves, enforces, fetches, writes the row, signs the run's assignment
  and opens its `Cyfr.Execution.Attempt`. The executor is then the client
  of that attempt, reaching it only through host calls (`Opus.HostClient`):
  it attaches with the assignment (the answer carries the run's unsealed
  vault fields), holds an execution slot, runs the component in a runner
  process under the consented wall-clock timeout, renews the lease while it
  waits, kills the runner on a timeout, a lost lease, a cancel or the end
  of the attempt, and closes the attempt with `complete` or `fail`. The
  guest's emits, OAuth token requests and HTTP rate checks are host calls
  of the same client.

  The process that admitted the run waits for the attempt to close it
  (`Cyfr.Execution.Attempt.await/2`) and answers what the close recorded;
  an attempt the executor could not attach to or close is abandoned, and
  the run is closed lost.

  ## Usage

  Every execution roots under a `Cyfr.Authority` — production callers go
  through the `Opus` facade (`run_root`/`run_child`), which derives one from
  the caller's consented profile. Calling the executor directly requires
  passing the authority explicitly:

      ctx = Sanctum.TestContext.local()
      reference = "reagent:local.my-tool:0.1.0"
      input = %{"a" => 5, "b" => 10}

      {:ok, result} = Opus.Executor.run(ctx, reference, input, authority: authority)
      # result contains: output, execution_id, duration_ms, etc.

  ## Component Types

  - `:reagent` (default) - Pure sandboxed compute, no I/O
  - `:catalyst` - WASI enabled with HTTP/filesystem access
  - `:formula` - Composition of other components

  ## References

  Components are resolved by name from the local Compendium registry.
  All components must be registered (`cyfr register`) or pulled
  (`cyfr pull`) before execution.
  """

  require Logger

  alias Cyfr.Execution.{Admission, Attempt, Cascade, Record}
  alias Opus.HostClient
  alias Sanctum.Context

  @doc """
  Execute a WASM component with the given input.

  ## Parameters

  - `ctx` - Sanctum execution context
  - `reference` - Component reference string (e.g., "catalyst:local.claude:0.2.0")
  - `input` - Input data map to pass to the component
  - `opts` - `Cyfr.Execution.Admission.admit/4`'s options, and `:class`
    (`:background` for a run nobody waits on)

  ## Returns

  - `{:ok, result}` - Execution succeeded with result map
  - `{:error, reason}` - Execution failed with error message
  """
  @spec run(Context.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Context{} = ctx, reference, input, opts \\ [])
      when is_binary(reference) and is_map(input) do
    with {:ok, admitted} <- Admission.admit(ctx, reference, input, opts) do
      case run_attempt(admitted, input, opts) do
        :closed -> :ok
        :abandoned -> Attempt.abandon(admitted.execution_id)
      end

      Attempt.await(admitted.attempt, admitted.close)
    end
  end

  # The runner's half: attach, run the component and close the attempt.
  # `:closed` once CYFR has closed the run — on a close, or on a refused
  # attach it closed itself — and `:abandoned` when the attempt was left
  # open.
  defp run_attempt(admitted, input, opts) do
    %{assignment: assignment, attempt: attempt, attempt_key: key} = admitted.dispatch
    client = HostClient.new(attempt, key)
    attempt_ref = Process.monitor(admitted.attempt)

    try do
      case HostClient.attach(client, assignment) do
        {:ok, fields} ->
          runtime = Keyword.merge(admitted.runtime, preloaded_fields: fields, host: client)

          outcome =
            try do
              execute_wasm(admitted.wasm_bytes, input, runtime, opts, attempt_ref)
            rescue
              e -> {:error, exception_message(e, __STACKTRACE__)}
            end

          close(client, outcome)

        {:error, {:setup_required, _payload}} ->
          :closed

        {:error, refusal} ->
          Logger.warning(
            "[Executor] attach of #{admitted.execution_id} refused: #{inspect(refusal)}"
          )

          :abandoned
      end
    after
      Process.demonitor(attempt_ref, [:flush])
    end
  end

  defp close(client, {:ok, {output, _metadata}}) do
    case HostClient.complete(client, output) do
      {:ok, _recorded} -> :closed
      {:error, {:failed, _message}} -> :closed
      {:error, _refusal} -> :abandoned
    end
  end

  defp close(client, {:error, reason}) do
    case HostClient.fail(client, failure_message(reason)) do
      :ok -> :closed
      {:error, _refusal} -> :abandoned
    end
  end

  defp failure_message(reason) when is_binary(reason), do: reason

  defp failure_message(reason) do
    Logger.warning("[Executor] unrenderable failure reason: #{inspect(reason)}")
    "Execution failed: internal error"
  end

  # A `RuntimeError` or `ArgumentError` carries a sentence authored where it
  # was raised; any other exception is logged and reported as an internal
  # error.
  defp exception_message(%RuntimeError{message: message}, _stacktrace),
    do: "Execution error: #{message}"

  defp exception_message(%ArgumentError{message: message}, _stacktrace),
    do: "Execution error: #{message}"

  defp exception_message(exception, stacktrace) do
    Logger.error(
      "[Executor] execution raised: " <> Exception.format(:error, exception, stacktrace)
    )

    "Execution error: the engine raised an internal error"
  end

  defp execute_wasm(wasm_bytes, input, exec_opts, opts, attempt_ref) do
    # What this execution is to the semaphore: a hop under a parent takes a
    # child slot (never tenant-capped, a reserve of its own); a schedule or
    # webhook waits in the background; everything else is a root someone
    # is waiting on.
    class =
      cond do
        opts[:class] == :background -> :background
        opts[:parent_execution_id] || exec_opts[:parent_execution_id] -> :child
        true -> :root
      end

    # An execution that declared it must run under an authority may never fall
    # back to ambient permissions. Checked before the semaphore so nothing is
    # consumed; the raise fails the execution with its message intact.
    if Keyword.get(opts, :authority_required, Keyword.get(exec_opts, :authority_required, true)) and
         is_nil(Keyword.get(opts, :authority, Keyword.get(exec_opts, :authority))) do
      raise ArgumentError,
            "execution requires an authority but none was provided (reference: " <>
              "#{inspect(Keyword.get(exec_opts, :reference))})"
    end

    # Admission always derives timeout_ms from the consented limits; a
    # missing value means an opts filter dropped it — refuse rather than
    # substitute a ceiling nobody consented to.
    timeout_ms =
      exec_opts[:timeout_ms] || opts[:timeout_ms] ||
        raise(ArgumentError, "execution reached the runtime without a timeout — limits dropped")

    semaphore_timeout = min(timeout_ms, 30_000)

    tenant =
      case exec_opts[:ctx] do
        %{athanor_id: athanor_id} when is_binary(athanor_id) -> athanor_id
        _ -> nil
      end

    case Cyfr.Execution.Slot.acquire(class, tenant, semaphore_timeout, execution_id(exec_opts)) do
      {:ok, token} ->
        try do
          runtime_opts = runtime_opts(exec_opts, opts)

          # The plane flips exactly at the WASM boundary: admission ran with
          # the caller's external-plane context, but a context captured into
          # guest closures must never authorize an external-plane call
          # again. One-way; there is no inverse.
          runtime_opts =
            with auth when not is_nil(auth) <- runtime_opts[:authority],
                 %Sanctum.Context{} = c <- runtime_opts[:ctx] do
              Keyword.put(runtime_opts, :ctx, Sanctum.Context.enter_guest(c))
            else
              _ -> runtime_opts
            end

          execute_with_timeout(wasm_bytes, input, runtime_opts, timeout_ms, attempt_ref)
        after
          Cyfr.Execution.Slot.release(token)
        end

      {:error, sentence} ->
        {:error, sentence}
    end
  end

  # Register each execution's driving process for cancellation, including
  # synchronous runs and children. Existing registration by the same process
  # is a no-op.
  @runtime_opt_keys [
    :component_type,
    :max_memory_bytes,
    :preloaded_fields,
    # The run's host client (`Opus.HostClient`): what the guest's emits,
    # token requests and HTTP rate checks are host calls of.
    :host,
    :component_ref,
    :edge,
    :limits,
    :ctx,
    :execution_id,
    # The attempt that owns the row: the lineage a guest's in-chain calls
    # and spawns carry, and what the lease watch renews under.
    :execution_attempt,
    :root_execution_id,
    :reference,
    :digest,
    # Dropping :authority here would silently strip a chain's granted
    # capabilities and run the guest on ambient permissions; the runtime
    # re-checks :authority_required so a partial drop still fails closed.
    :authority,
    :authority_required,
    :declared_needs,
    :activation_digest,
    # The caller's latency clock (`Cyfr.Execution.StepSpans`), marked when
    # the guest starts.
    :step_spans
  ]

  @doc false
  # The options the runtime runs on. Caller opts fill in what admission did
  # not settle; they never overwrite what it did — for any key, so `:ctx`
  # (the tenant every host import scopes on), `:preloaded_fields` (the
  # vault map attach answered), `:host` (the attached client), `:digest`
  # (the compiled-component cache key) and `:execution_attempt` stay
  # admission's.
  @spec runtime_opts(keyword(), keyword()) :: keyword()
  def runtime_opts(exec_opts, opts) do
    opts
    |> Keyword.take(@runtime_opt_keys)
    |> Keyword.merge(exec_opts)
    |> Keyword.take(@runtime_opt_keys)
  end

  # Merge into the registry value for this execution, whatever shape it is
  # in. The entry starts as the `:running` atom (`register_execution/1`) and
  # becomes a map as the run's pids become known; a run with no entry — a
  # child, or one whose owner already unregistered — is a no-op.
  defp update_registry_meta(runtime_opts, fun) do
    case Keyword.get(runtime_opts, :execution_id) do
      nil ->
        :ok

      execution_id ->
        Registry.update_value(Cyfr.Execution.Registry, execution_id, fn
          meta when is_map(meta) -> fun.(meta)
          _atom -> fun.(%{status: :running})
        end)

        :ok
    end
  end

  defp execution_id(exec_opts), do: Keyword.get(exec_opts, :execution_id)

  # Execute WASM with wall-clock timeout enforcement.
  # This ensures long-running or stuck executions are terminated.
  # Uses spawn-based execution to avoid crashes propagating to caller.
  # Returns {:ok, {output, metadata}} or {:error, reason}
  defp execute_with_timeout(wasm_bytes, input, runtime_opts, timeout_ms, attempt_ref) do
    caller = self()
    ref = make_ref()
    start_time = System.monotonic_time(:millisecond)

    # Pass notify_cleanup_refs so Runtime sends us cleanup refs before executing.
    # On timeout kill, we use these to clean up orphaned Agent processes.
    runtime_opts_with_notify = Keyword.put(runtime_opts, :notify_cleanup_refs, {caller, ref})

    # Capture Logger metadata for propagation to spawned process
    logger_metadata = Cyfr.LoggerContext.capture()

    # Timeout mechanism: We use spawn_link (not spawn) deliberately.
    # If the spawned process crashes without sending the ref message,
    # the linked process EXIT signal propagates to the caller, which
    # is caught by the outer try/catch. This prevents indefinite hangs.
    # The outer `receive` has an `after timeout_ms` clause as the
    # primary timeout mechanism.
    pid =
      spawn_link(fn ->
        # Trap exits so that linked-process crashes (e.g. Wasmex GenServer dying
        # from a WASM trap) become messages instead of killing this process.
        # Without this, the `catch :exit` clause below never fires for link exits.
        Process.flag(:trap_exit, true)
        Cyfr.LoggerContext.restore(logger_metadata)

        result =
          try do
            Opus.Runtime.execute_component(wasm_bytes, input, runtime_opts_with_notify)
          rescue
            e -> {:error, Exception.message(e)}
          catch
            :exit, reason -> {:error, "Exit: #{inspect(reason)}"}
            kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
          end

        send(caller, {ref, result})
      end)

    # Name the runner in the registry the moment it exists, so `cancel/3` can
    # reach the process actually running the component. Killing the registered
    # process does not: the runner traps exits (just above, so a Wasmex crash
    # is a message rather than a death), and a link-propagated exit is
    # trappable whatever its reason — `:killed` included. Only the direct
    # `Process.exit(runner, :kill)` in `kill_running_process/1` is
    # untrappable, and a runner left alive keeps fetching, writing and
    # asking for OAuth tokens after its row reads cancelled.
    update_registry_meta(runtime_opts, &Map.put(&1, :runner_pid, pid))

    # Collect cleanup_refs sent by Runtime early in setup (before WASM execution starts).
    # Use the full timeout — if setup itself takes this long, we should timeout anyway.
    # A failure BEFORE Runtime sends the handshake (an authority guard, a bad
    # option) arrives as the final result instead — match it here too, or the
    # caller would sit out the full timeout holding its semaphore slot with
    # the answer already in its mailbox.
    handshake =
      receive do
        {:cleanup_refs, ^ref, refs} -> {:refs, refs}
        {^ref, {:ok, output, metadata}} -> {:early, {:ok, {output, metadata}}}
        {^ref, {:error, _} = error} -> {:early, error}
        {:DOWN, ^attempt_ref, :process, _, _} -> :attempt_ended
      after
        timeout_ms -> nil
      end

    cleanup_refs =
      case handshake do
        {:refs, refs} -> refs
        _ -> nil
      end

    # Store tracker PID in Cyfr.Execution.Registry so cancel can clean up AsyncTracker.
    # Without this, cancelling a formula leaves child catalyst tasks running.
    if cleanup_refs[:formula_tracker_pid] do
      update_registry_meta(
        runtime_opts,
        &Map.put(&1, :tracker_pid, cleanup_refs.formula_tracker_pid)
      )
    end

    # Register the streaming ref so cancellation stops in-flight fetching.
    if cleanup_refs[:stream_exec_ref] do
      update_registry_meta(
        runtime_opts,
        &Map.put(&1, :stream_exec_ref, cleanup_refs.stream_exec_ref)
      )
    end

    remaining_ms = max(timeout_ms - (System.monotonic_time(:millisecond) - start_time), 0)
    watch = lease_watch(runtime_opts)

    case handshake do
      {:early, result} ->
        result

      # The full timeout passed waiting for cleanup_refs: kill at once.
      nil ->
        # The kill frees the BEAM process, not the component call's native
        # thread (no epoch interruption) — the semaphore records the
        # liability first, acknowledged, so the tenant's unreaped count
        # gates its next acquisition whatever order the release lands in.
        kill_unreaped(pid, nil, watch)
        {:error, "Execution timeout after #{timeout_ms}ms"}

      :attempt_ended ->
        kill_unreaped(pid, nil, watch)
        {:error, "Execution attempt ended"}

      {:refs, _} ->
        await_result(ref, pid, cleanup_refs, remaining_ms, timeout_ms, watch, attempt_ref)
    end
  end

  # Lease renewals while a long execution runs: every minute a `renew` host
  # call pushes the row's lease out, so the sweeper knows a slow execution
  # from a dead runner. A renewal CYFR answers `lost` stops the runner at
  # once: the row is another's (cancelled, swept, finished, taken over)
  # and any result this attempt produced would be refused by the fence. A
  # renewal CYFR cannot answer keeps the runner working only while the
  # lease it LAST held is still good.
  @lease_tick_ms 60_000

  # What `await_result/7` watches between ticks: the attempt's host client,
  # the tenant to charge an unreaped kill to, and the expiry the attempt
  # last renewed to.
  defp lease_watch(runtime_opts) do
    case Keyword.get(runtime_opts, :host) do
      nil ->
        nil

      %HostClient{} = client ->
        %{client: client, tenant: tenant_of(runtime_opts), until: Record.lease_until()}
    end
  end

  defp tenant_of(runtime_opts) do
    case Keyword.get(runtime_opts, :ctx) do
      %Context{athanor_id: athanor_id} -> athanor_id
      _ -> nil
    end
  end

  # The run's attempt ending stops the runner as a lost lease does: nothing
  # the guest does after it can be masked, emitted or closed.
  defp await_result(ref, pid, cleanup_refs, remaining_ms, timeout_ms, watch, attempt_ref) do
    wait_ms = min(remaining_ms, @lease_tick_ms)

    receive do
      # Runtime.execute_component always returns 3-tuple {:ok, output, metadata}
      {^ref, {:ok, output, metadata}} ->
        {:ok, {output, metadata}}

      {^ref, {:error, _} = error} ->
        error

      {:DOWN, ^attempt_ref, :process, _, _} ->
        kill_unreaped(pid, cleanup_refs, watch)
        {:error, "Execution attempt ended"}
    after
      wait_ms ->
        cond do
          remaining_ms <= wait_ms ->
            kill_unreaped(pid, cleanup_refs, watch)
            {:error, "Execution timeout after #{timeout_ms}ms"}

          is_nil(watch) ->
            next = remaining_ms - wait_ms
            await_result(ref, pid, cleanup_refs, next, timeout_ms, watch, attempt_ref)

          true ->
            case renew_watch(watch) do
              {:ok, watch} ->
                next = remaining_ms - wait_ms
                await_result(ref, pid, cleanup_refs, next, timeout_ms, watch, attempt_ref)

              :lapsed ->
                kill_unreaped(pid, cleanup_refs, watch)
                {:error, "Execution lease lost: the row is no longer this attempt's to finish"}

              :cancelled ->
                kill_unreaped(pid, cleanup_refs, watch)
                {:error, "Execution cancelled"}
            end
        end
    end
  end

  @doc false
  @spec renew_watch(map(), DateTime.t()) :: {:ok, map()} | :lapsed | :cancelled
  def renew_watch(%{client: client} = watch, now \\ DateTime.utc_now()) do
    case HostClient.renew(client, [client.attempt]) do
      {:ok, renewals} ->
        case Map.get(renewals, client.attempt, :lost) do
          {:ok, until} -> {:ok, %{watch | until: DateTime.from_unix!(until, :millisecond)}}
          :cancel -> :cancelled
          :lost -> :lapsed
        end

      {:error, :unavailable} ->
        # Still inside the lease this attempt last held: the store may
        # merely be slow, and the next tick asks again. Past it, stop.
        if DateTime.compare(now, watch.until) == :lt,
          do: {:ok, watch},
          else: :lapsed

      {:error, _refusal} ->
        :lapsed
    end
  end

  # A kill that leaves the component call's native thread running (no
  # epoch interruption). The liability is recorded and acknowledged
  # BEFORE the kill, then the resources the dead process cannot release
  # are cleaned up. The tokens dispensed to the run stay in its attempt's
  # masking set, which masks the error when the attempt closes the run.
  defp kill_unreaped(pid, cleanup_refs, watch) do
    charge_unreaped(watch && watch.tenant, watch && watch.client.execution_id)
    Process.unlink(pid)
    Process.exit(pid, :kill)

    if cleanup_refs[:stream_exec_ref],
      do: Opus.HttpStreamHandler.cleanup_registry(cleanup_refs.stream_exec_ref)

    if cleanup_refs[:formula_tracker_pid],
      do: Opus.FormulaHandler.cleanup_registry(cleanup_refs.formula_tracker_pid)

    :ok
  end

  @doc """
  Cancel a running execution by killing its process.

  Looks up the execution's entry in `Cyfr.Execution.Registry` and kills what it
  names: the runner that is actually inside the component call, then the
  process driving it, then its AsyncTracker so spawned child tasks die too.
  The semaphore auto-releases via its :DOWN monitor, and the run's attempt
  stops when the driving process does.

  The runner is killed BY NAME rather than left to the link: it traps exits
  (so a Wasmex crash is a message, not a death), and a link-propagated exit
  is trappable however it is spelled. Only a direct kill stops it.
  """
  @spec cancel(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(ctx, execution_id, opts \\ [])

  def cancel(%Context{} = ctx, execution_id, opts) do
    # The tenant-scoped record cancel is the single authority for whether this
    # caller may cancel this execution: it enforces tenant ownership, the
    # authorize/3 chokepoint, and the ':running' precondition. It MUST succeed
    # before we touch the global, id-keyed process registry — otherwise a caller
    # could kill another tenant's execution just by knowing its id. (Same
    # authorize-before-act ordering the SSE read path uses.)
    case Record.cancel(ctx, execution_id, Keyword.take(opts, [:restart_required])) do
      {:ok, record} ->
        kill_running_process(execution_id, record.athanor_id)
        emit_cancel_telemetry(ctx, execution_id)
        Cascade.fail_children_of(execution_id)
        {:ok, %{cancelled: true, execution_id: execution_id}}

      error ->
        error
    end
  end

  @doc """
  Terminate a running execution because its consent changed underneath it.

  Commits consent for future roots and ends the current execution with
  `restart_required`. Rerunning selects the new revision; in-flight authority
  is never rebound.
  """
  @spec cancel_for_restart(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def cancel_for_restart(%Context{} = ctx, execution_id, payload) when is_map(payload) do
    cancel(ctx, execution_id, restart_required: payload)
  end

  # The liability is acknowledged before the kill. A semaphore that does
  # not answer leaves the kill uncharged; that is said, by execution, never
  # dropped silently.
  defp charge_unreaped(tenant, execution_id) do
    case Cyfr.Execution.Semaphore.note_unreaped(tenant, execution_id) do
      :ok ->
        :ok

      {:error, :unavailable} ->
        Logger.error(
          "[Executor] unreaped kill of #{inspect(execution_id)} for tenant " <>
            "#{inspect(tenant)} is uncharged: the semaphore did not answer"
        )
    end
  end

  # Kill the running BEAM process for an execution (if one is still registered)
  # and tear down its async tracker so spawned child tasks die too. Only called
  # after the tenant-scoped cancel above has authorized the operation.
  defp kill_running_process(execution_id, tenant) do
    case Registry.lookup(Cyfr.Execution.Registry, execution_id) do
      [{pid, meta}] ->
        # Extract tracker PID before killing — needed to stop child tasks.
        tracker_pid = if is_map(meta), do: meta[:tracker_pid], else: nil
        runner_pid = if is_map(meta), do: meta[:runner_pid], else: nil
        stream_exec_ref = if is_map(meta), do: meta[:stream_exec_ref], else: nil

        # Cancellation leaves native work unreapable without epoch interruption.
        # Record and acknowledge the tenant penalty before killing the caller.
        charge_unreaped(tenant, execution_id)

        # The runner FIRST, and by name. It traps exits, so the kill of its
        # parent below reaches it as an ordinary message and it would keep
        # running the component — a direct `:kill` is the only untrappable
        # one. Killing it before the parent also stops it from sending a
        # result nobody is waiting for any more.
        if is_pid(runner_pid), do: Process.exit(runner_pid, :kill)

        Process.exit(pid, :kill)

        # Clean up AsyncTracker → stops Task.Supervisor → kills spawned child tasks.
        # Without this, child catalyst executions survive the parent's cancellation
        # because they're spawned via async_nolink (not linked to the parent).
        if is_pid(tracker_pid) and Process.alive?(tracker_pid) do
          Opus.FormulaHandler.cleanup_registry(tracker_pid)
        end

        # Same for an in-flight streaming fetch: the streaming task is
        # unlinked from the Wasmex process, so killing the runner does not
        # stop it.
        if stream_exec_ref, do: Opus.HttpStreamHandler.cleanup_registry(stream_exec_ref)

        :ok

      [] ->
        :ok
    end
  end

  defp emit_cancel_telemetry(ctx, execution_id) do
    :telemetry.execute(
      [:cyfr, :opus, :execute, :exception],
      %{duration: 0, system_time: System.system_time()},
      %{execution_id: execution_id, user_id: ctx.user_id, error: "cancelled", status: :cancelled}
    )
  end
end
