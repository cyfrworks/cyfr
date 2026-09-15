# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Runner do
  @moduledoc """
  Runs one assigned execution attempt: attaches, runs the component,
  renews the attempt's lease while it runs and closes the attempt.

  `Opus.WorkerService` starts a runner with the assignment it read, the
  input the assignment's digest binds and a host client
  (`Opus.HostClient`) holding the attempt's key. The runner reaches the
  attempt only through that client. In order it:

    1. attaches with the assignment (`Opus.HostClient.attach/2`), which
       answers the run's vault fields; an attach CYFR refuses leaves the
       attempt to CYFR;
    2. reads the authority the assignment carries
       (`Cyfr.Authority.from_wire/1`) for its own egress checks: the edge a
       guest's HTTP requests are checked against and the node's limits;
    3. asks what the attempt runs with beyond its assignment
       (`Opus.HostClient.admitted/1`): the context and the authority its
       guest's in-process calls (formula children and catalog tools) run
       under;
    4. runs the component in a process of its own
       (`Opus.Runtime.execute_component/3`) under the assignment's
       timeout, renewing the lease every minute; a timeout, a lost lease
       and a cancel asked of the attempt each kill that process. The
       component's bytes are fetched by the assignment's digest
       (`Opus.HostClient.fetch_artifact/2`) only when no compiled component
       for that digest is cached, and are run only if they hash to it;
    5. closes the attempt: `complete` with the guest's output, or `fail`
       with a sentence, marked `abandoned` when it killed the component
       call.

  The runner tells its worker service its component process and what that
  process started (`Opus.WorkerService.track/1`), so a kill stops them all.
  It exits `:normal` once CYFR has closed the attempt, and
  `{:shutdown, :attempt_open}` when it leaves the attempt open.
  """

  require Logger

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Opus.{HostClient, WorkerService}

  # A renewal every minute pushes the row's lease out, so the sweeper knows
  # a slow execution from a dead runner.
  @lease_tick_ms 60_000

  @typedoc """
  What a runner starts with: the assignment token and what it carries, the
  decoded input, the attempt's host client, and the starting caller's
  process callers and log metadata.
  """
  @type start :: %{
          token: Cyfr.Assignment.token(),
          assignment: Cyfr.Assignment.t(),
          input: map(),
          client: HostClient.t(),
          callers: [pid()],
          logger: keyword()
        }

  @doc false
  def child_spec(start) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [start]}, restart: :temporary}
  end

  @doc "Start a runner for `start` (`t:start/0`), linked to the calling supervisor."
  @spec start_link(start()) :: {:ok, pid()}
  def start_link(start) when is_map(start) do
    {:ok, spawn_link(fn -> run(start) end)}
  end

  defp run(start) do
    # The starting caller's callers, so its database sandbox allowance
    # covers what this process and the component's calls read and write.
    Process.put(:"$callers", start.callers)
    Cyfr.LoggerContext.restore(start.logger)
    Cyfr.LoggerContext.set_execution_id(start.assignment.execution_id)

    case run_attempt(start) do
      :normal -> :ok
      reason -> exit(reason)
    end
  end

  defp run_attempt(%{client: client, assignment: assignment} = start) do
    case HostClient.attach(client, start.token) do
      {:ok, fields} ->
        run_attached(start, fields)

      {:error, {:setup_required, _payload}} ->
        :normal

      {:error, refusal} ->
        Logger.warning(
          "[Opus.Runner] attach of #{assignment.execution_id} refused: #{inspect(refusal)}"
        )

        {:shutdown, :attempt_open}
    end
  end

  defp run_attached(%{client: client, assignment: assignment} = start, fields) do
    with {:ok, authority} <- Authority.from_wire(assignment.authority),
         {:ok, component_type} <- Opus.ComponentType.parse(assignment.component.type),
         {:ok, admitted} <- HostClient.admitted(client) do
      runtime_opts =
        runtime_opts(assignment, authority, component_type, admitted,
          preloaded_fields: fields,
          host: client
        )

      watch = %{client: client, until: DateTime.from_unix!(assignment.lease_until, :millisecond)}

      artifact = artifact(client, assignment.component.digest)

      outcome =
        try do
          execute(artifact, start.input, runtime_opts, assignment.timeout_ms, watch)
        rescue
          e -> {:error, exception_message(e, __STACKTRACE__)}
        end

      close(client, outcome)
    else
      {:error, refusal} when refusal in [:lost, :unavailable] ->
        {:shutdown, :attempt_open}

      {:error, reason} ->
        Logger.error(
          "[Opus.Runner] #{assignment.execution_id} cannot run its assignment: #{inspect(reason)}"
        )

        close(client, {:error, "Execution error: the assignment could not be run"})
    end
  end

  # The options the runtime runs under: the node's limits and the edge
  # from the assignment's authority, the run's identity and component from
  # the assignment, and what CYFR answered for the rest.
  defp runtime_opts(assignment, authority, component_type, admitted, opts) do
    limits = Authority.limits(authority)
    component = assignment.component

    [
      component_type: component_type,
      max_memory_bytes: limits.max_memory_bytes,
      edge: edge(authority),
      limits: limits,
      component_ref: component.ref,
      reference: component.ref,
      digest: component.digest,
      declared_needs: component.declared_needs,
      activation_digest: component.activation_digest,
      ctx: admitted.ctx,
      authority: admitted.authority,
      execution_id: assignment.execution_id,
      execution_attempt: assignment.attempt,
      root_execution_id: assignment.root_execution_id
    ] ++ opts
  end

  defp edge(%Authority{resources: %Edge{} = edge}), do: edge
  defp edge(%Authority{resources: :none}), do: nil

  # The component's bytes as CYFR answers them for the assignment's digest,
  # refused unless they hash to it.
  defp artifact(client, digest) do
    fn ->
      case HostClient.fetch_artifact(client, digest) do
        {:ok, bytes} ->
          if Cyfr.Digest.sha256(bytes) == digest,
            do: {:ok, bytes},
            else:
              {:error,
               {:artifact, "Execution error: the component's bytes do not match its digest"}}

        {:error, refusal} ->
          Logger.warning(
            "[Opus.Runner] artifact #{digest} of #{client.execution_id} refused: " <>
              inspect(refusal)
          )

          {:error, {:artifact, "Execution error: the component's bytes could not be fetched"}}
      end
    end
  end

  defp close(client, {:ok, {output, _metadata}}) do
    case HostClient.complete(client, output) do
      {:ok, _recorded} -> :normal
      {:error, {:failed, _message}} -> :normal
      {:error, _refusal} -> {:shutdown, :attempt_open}
    end
  end

  defp close(client, {:error, reason}), do: fail(client, reason, [])
  defp close(client, {:abandoned, reason}), do: fail(client, reason, abandoned: true)

  defp fail(client, reason, opts) do
    case HostClient.fail(client, failure_message(reason), opts) do
      :ok -> :normal
      {:error, _refusal} -> {:shutdown, :attempt_open}
    end
  end

  defp failure_message(reason) when is_binary(reason), do: reason

  defp failure_message(reason) do
    Logger.warning("[Opus.Runner] unrenderable failure reason: #{inspect(reason)}")
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
      "[Opus.Runner] execution raised: " <> Exception.format(:error, exception, stacktrace)
    )

    "Execution error: the engine raised an internal error"
  end

  # ---------------------------------------------------------------------------
  # The component process
  # ---------------------------------------------------------------------------

  # The component runs in a process of its own, linked to the runner and
  # trapping exits, so a Wasmex crash reaches it as a message. No exit it
  # traps can stop it, so it starts only once its worker service has been
  # told of it (ahead of any exit of the runner's), and a kill names it. Answers `{:ok, {output, metadata}}`,
  # `{:error, reason}`, or `{:abandoned, reason}` when the component call was
  # killed.
  defp execute(artifact, input, runtime_opts, timeout_ms, watch) do
    runner = self()
    ref = make_ref()
    start_time = System.monotonic_time(:millisecond)
    runtime_opts = Keyword.put(runtime_opts, :notify_cleanup_refs, {runner, ref})
    logger_metadata = Cyfr.LoggerContext.capture()
    callers = Process.get(:"$callers", [])

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)
        Process.put(:"$callers", [runner | callers])
        Cyfr.LoggerContext.restore(logger_metadata)

        receive do
          {:go, ^ref} -> :ok
          {:EXIT, ^runner, _reason} -> exit(:normal)
        end

        result =
          try do
            Opus.Runtime.execute_component(artifact, input, runtime_opts)
          rescue
            e -> {:error, Exception.message(e)}
          catch
            :exit, reason -> {:error, "Exit: #{inspect(reason)}"}
            kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
          end

        send(runner, {ref, result})
      end)

    WorkerService.track(%{component: pid})
    send(pid, {:go, ref})

    # A failure before the runtime sends its cleanup refs (an authority
    # guard, a bad option) arrives as the final result instead.
    handshake =
      receive do
        {:cleanup_refs, ^ref, refs} -> {:refs, refs}
        {^ref, {:ok, output, metadata}} -> {:early, {:ok, {output, metadata}}}
        {^ref, {:error, _} = error} -> {:early, error}
      after
        timeout_ms -> nil
      end

    case handshake do
      {:early, result} ->
        result

      nil ->
        kill(pid, nil)
        {:abandoned, "Execution timeout after #{timeout_ms}ms"}

      {:refs, refs} ->
        WorkerService.track(%{cleanup: refs})
        remaining_ms = max(timeout_ms - (System.monotonic_time(:millisecond) - start_time), 0)
        await_result(ref, pid, refs, remaining_ms, timeout_ms, watch)
    end
  end

  defp await_result(ref, pid, refs, remaining_ms, timeout_ms, watch) do
    wait_ms = min(remaining_ms, @lease_tick_ms)

    receive do
      {^ref, {:ok, output, metadata}} ->
        {:ok, {output, metadata}}

      {^ref, {:error, _} = error} ->
        error
    after
      wait_ms ->
        if remaining_ms <= wait_ms do
          kill(pid, refs)
          {:abandoned, "Execution timeout after #{timeout_ms}ms"}
        else
          renewed(ref, pid, refs, remaining_ms - wait_ms, timeout_ms, renew_watch(watch))
        end
    end
  end

  defp renewed(ref, pid, refs, remaining_ms, timeout_ms, {:ok, watch}),
    do: await_result(ref, pid, refs, remaining_ms, timeout_ms, watch)

  defp renewed(_ref, pid, refs, _remaining_ms, _timeout_ms, :lapsed) do
    kill(pid, refs)
    {:abandoned, "Execution lease lost: the row is no longer this attempt's to finish"}
  end

  defp renewed(_ref, pid, refs, _remaining_ms, _timeout_ms, :cancelled) do
    kill(pid, refs)
    {:abandoned, "Execution cancelled"}
  end

  @doc false
  # A renewal CYFR answers `lost` stops the runner at once: the row is
  # another's (cancelled, swept, finished, taken over). A renewal CYFR
  # cannot answer keeps the runner working only while the lease it last
  # held is still good.
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
        if DateTime.compare(now, watch.until) == :lt,
          do: {:ok, watch},
          else: :lapsed

      {:error, _refusal} ->
        :lapsed
    end
  end

  # The kill frees the component's BEAM process, not the component call's
  # native thread; the attempt's `fail` says so (`abandoned`). The tokens
  # dispensed to the run stay in its attempt's masking set, which masks the
  # error when the attempt closes the run.
  defp kill(pid, refs) do
    Process.unlink(pid)
    Process.exit(pid, :kill)

    if refs[:stream_exec_ref],
      do: Opus.HttpStreamHandler.cleanup_registry(refs.stream_exec_ref)

    if refs[:formula_tracker_pid],
      do: Opus.FormulaHandler.cleanup_registry(refs.formula_tracker_pid)

    :ok
  end
end
