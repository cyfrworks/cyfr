# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Attempt do
  @moduledoc """
  The process that runs one execution attempt: attaches, runs the
  component, renews the attempt's lease while it runs and closes the
  attempt.

  Its owner (`Opus.Subtree`: the runner the subtree was assigned to, or a
  worker service running subtrees in its own VM) starts it with the
  assignment it read, the input the assignment's digest binds and a host
  client (`Opus.HostClient`) holding the attempt's key. A formula's child
  runs in an attempt process of its own in the same subtree
  (`Opus.Subtree.start_child/2`), started from the child CYFR admitted and
  claimed for the formula's runner (`Opus.HostClient.admit_child/5`), with
  the vault fields that admission unsealed and the process waiting for its
  answer, if any. The process reaches the attempt only through its client.
  In order it:

    1. attaches with the assignment (`Opus.HostClient.attach/2`), which
       answers the run's vault fields; an attach CYFR refuses leaves the
       attempt to CYFR. A child, claimed at its admission, is already
       attached;
    2. reads the authority the assignment carries
       (`Cyfr.Authority.from_wire/1`) for its own egress checks and its
       guest's host functions: the edge a guest's HTTP requests are checked
       against and the node's limits. It grants nothing: CYFR decides every
       child and catalog tool call under the authority it holds;
    3. runs the component in a process of its own
       (`Opus.Runtime.execute_component/3`) under the assignment's
       timeout, renewing the lease every minute; a timeout, a lost lease
       and a cancel asked of the attempt each kill that process. The
       component's bytes are fetched by the assignment's digest
       (`Opus.HostClient.fetch_artifact/2`) only when no compiled component
       for that digest is cached, and are run only if they hash to it
       (`Opus.ComponentCache`);
    4. closes the attempt: `complete` with the guest's output, or `fail`
       with a sentence, marked `abandoned` when it killed the component
       call.

  The process tells its owner its component process and what that
  process started (`Opus.Subtree.track/1`), so a kill stops them all. A
  child's process tells its owner when CYFR has closed its attempt
  (`Opus.Subtree.settled/0`), then answers its waiting process what the
  close recorded, masked: `{Opus.Attempt, pid, {:ok, output}}` or
  `{Opus.Attempt, pid, {:error, message}}`. The process exits `:normal`
  once CYFR has closed the attempt, and `{:shutdown, :attempt_open}` when
  it leaves the attempt open.
  """

  require Logger

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Opus.{HostClient, Subtree}

  # A renewal every minute pushes the row's lease out, so the sweeper knows
  # a slow execution from a dead runner.
  @lease_tick_ms 60_000

  @ended "Execution attempt ended before it closed"

  @typedoc """
  What an attempt process starts with: the assignment token and what it carries, the
  decoded input, the attempt's host client, and the starting caller's
  process callers and log metadata. A child's start also carries the vault
  fields its admission unsealed (`:secrets`) and the process waiting for
  its answer (`:waiter`, nil when none does).
  """
  @type start :: %{
          required(:token) => Cyfr.Assignment.token(),
          required(:assignment) => Cyfr.Assignment.t(),
          required(:input) => map(),
          required(:client) => HostClient.t(),
          required(:callers) => [pid()],
          required(:logger) => keyword(),
          optional(:secrets) => %{optional(String.t()) => String.t()},
          optional(:waiter) => pid() | nil
        }

  @typedoc "What a waiting process is answered: the close as CYFR recorded it."
  @type answer :: {:ok, term()} | {:error, String.t()}

  @cancelled "Execution cancelled before it completed"

  @doc """
  Tell the attempt process `pid` to stop its component call and close its
  attempt as abandoned (`Opus.Subtree`'s `:abandon` cancel mode). One
  still attaching does so once attached; one already closing has nothing
  left to stop.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    send(pid, {__MODULE__, :cancel})
    :ok
  end

  @doc false
  def child_spec(start) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [start]}, restart: :temporary}
  end

  @doc "Start an attempt process for `start` (`t:start/0`), linked to the calling supervisor."
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

    {reason, answer} = run_attempt(start)

    case Map.get(start, :waiter) do
      waiter when is_pid(waiter) ->
        if reason == :normal, do: Subtree.settled()
        send(waiter, {__MODULE__, self(), answer})

      nil ->
        :ok
    end

    if reason != :normal, do: exit(reason)
    :ok
  end

  defp run_attempt(%{secrets: secrets} = start) when is_map(secrets),
    do: run_attached(start, secrets)

  defp run_attempt(%{client: client, assignment: assignment} = start) do
    case HostClient.attach(client, start.token) do
      {:ok, fields} ->
        run_attached(start, fields)

      {:error, {refusal, _detail}} when refusal in [:setup_required, :failed] ->
        {:normal, {:error, @ended}}

      {:error, refusal} ->
        Logger.warning(
          "[Opus.Attempt] attach of #{assignment.execution_id} refused: #{inspect(refusal)}"
        )

        {{:shutdown, :attempt_open}, {:error, @ended}}
    end
  end

  defp run_attached(%{client: client, assignment: assignment} = start, fields) do
    with {:ok, authority} <- Authority.from_wire(assignment.authority),
         {:ok, component_type} <- Opus.ComponentType.parse(assignment.component.type) do
      runtime_opts =
        runtime_opts(assignment, authority, component_type,
          preloaded_fields: fields,
          host: client
        )

      watch = %{client: client, until: DateTime.from_unix!(assignment.lease_until, :millisecond)}

      artifact = artifact(client, assignment.component.digest)

      outcome =
        try do
          execute(artifact, start.input, runtime_opts, budget_ms(assignment), watch)
        rescue
          e -> {:error, exception_message(e, __STACKTRACE__)}
        end

      close(client, outcome)
    else
      {:error, reason} ->
        Logger.error(
          "[Opus.Attempt] #{assignment.execution_id} cannot run its assignment: #{inspect(reason)}"
        )

        close(client, {:error, "Execution error: the assignment could not be run"})
    end
  end

  # The options the runtime runs under: the node's limits, the edge and the
  # authority as the assignment carries them, the run's identity, its
  # component and the actions its host intercepts.
  defp runtime_opts(assignment, authority, component_type, opts) do
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
      intercepted: assignment.intercepted,
      authority: authority,
      execution_id: assignment.execution_id
    ] ++ opts
  end

  defp edge(%Authority{resources: %Edge{} = edge}), do: edge
  defp edge(%Authority{resources: :none}), do: nil

  # The component's bytes as CYFR answers them for the assignment's digest;
  # the cache runs them only if they hash to it.
  defp artifact(client, digest) do
    fn ->
      case HostClient.fetch_artifact(client, digest) do
        {:ok, bytes} ->
          {:ok, bytes}

        {:error, refusal} ->
          Logger.warning(
            "[Opus.Attempt] artifact #{digest} of #{client.execution_id} refused: " <>
              inspect(refusal)
          )

          {:error, {:artifact, "Execution error: the component's bytes could not be fetched"}}
      end
    end
  end

  defp close(client, {:ok, {output, _metadata}}) do
    case HostClient.complete(client, output) do
      {:ok, recorded} -> {:normal, {:ok, recorded}}
      {:error, {:failed, message}} -> {:normal, {:error, message}}
      {:error, _refusal} -> {{:shutdown, :attempt_open}, {:error, @ended}}
    end
  end

  defp close(client, {:error, reason}), do: fail(client, reason, [])
  defp close(client, {:abandoned, reason}), do: fail(client, reason, abandoned: true)

  defp fail(client, reason, opts) do
    case HostClient.fail(client, failure_message(reason), opts) do
      {:ok, message} -> {:normal, {:error, message}}
      {:error, _refusal} -> {{:shutdown, :attempt_open}, {:error, @ended}}
    end
  end

  defp failure_message(reason) when is_binary(reason), do: reason

  defp failure_message(reason) do
    Logger.warning("[Opus.Attempt] unrenderable failure reason: #{inspect(reason)}")
    "Execution failed: internal error"
  end

  # A `RuntimeError` or `ArgumentError` carries a sentence authored where it
  # was raised; any other exception is reported as an internal error and
  # logged by its module and the functions it passed through, never by its
  # message or a frame's arguments, which can hold the terms it was raised
  # over, a guest's input among them.
  defp exception_message(%RuntimeError{message: message}, _stacktrace),
    do: "Execution error: #{message}"

  defp exception_message(%ArgumentError{message: message}, _stacktrace),
    do: "Execution error: #{message}"

  defp exception_message(exception, stacktrace) do
    frames =
      Enum.map(stacktrace, fn
        {module, function, args, location} when is_list(args) ->
          {module, function, length(args), location}

        frame ->
          frame
      end)

    Logger.error(
      "[Opus.Attempt] execution raised #{inspect(exception.__struct__)}\n" <>
        Exception.format_stacktrace(frames)
    )

    "Execution error: the engine raised an internal error"
  end

  @doc false
  # An exit or a throw out of the component call, as the run's error: by its
  # kind alone. An exit carries the call it ended, and a call carries what
  # it was asked with, a guest's input among it, so neither the reason nor
  # anything in it is rendered or logged; only an atom, which code wrote,
  # names what ended.
  @spec caught(:exit | :throw, term()) :: String.t()
  def caught(:exit, reason) do
    Logger.error("[Opus.Attempt] the component call exited (#{ended(reason)})")
    "Execution error: the component call ended (#{ended(reason)})"
  end

  def caught(:throw, _value) do
    Logger.error("[Opus.Attempt] the component call threw")
    "Execution error: the component call threw"
  end

  defp ended(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp ended({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp ended(_reason), do: "exit"

  # The run's budget from receipt: its timeout, and no more than what is
  # left of the absolute subtree deadline its assignment carries, so a
  # queued or retried start cannot extend the subtree. Clock skew is bounded
  # by the header window CYFR verifies every call within.
  defp budget_ms(assignment) do
    remaining = assignment.deadline - System.system_time(:millisecond)
    max(min(assignment.timeout_ms, remaining), 0)
  end

  # ---------------------------------------------------------------------------
  # The component process
  # ---------------------------------------------------------------------------

  # The component runs in a process of its own, linked to the attempt process and
  # trapping exits, so a Wasmex crash reaches it as a message. No exit it
  # traps can stop it, so it starts only once its worker service has been
  # told of it (ahead of any exit of the attempt process's), and a kill names it.
  # Answers `{:ok, {output, metadata}}`, `{:error, reason}`, or
  # `{:abandoned, reason}` when the component call was killed.
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
            e -> {:error, exception_message(e, __STACKTRACE__)}
          catch
            kind, reason -> {:error, caught(kind, reason)}
          end

        send(runner, {ref, result})
      end)

    Subtree.track(%{component: pid})
    send(pid, {:go, ref})

    # A failure before the runtime sends its cleanup refs (an authority
    # guard, a bad option) arrives as the final result instead.
    handshake =
      receive do
        {:cleanup_refs, ^ref, refs} -> {:refs, refs}
        {^ref, {:ok, output, metadata}} -> {:early, {:ok, {output, metadata}}}
        {^ref, {:error, _} = error} -> {:early, error}
        {__MODULE__, :cancel} -> :cancelled
      after
        timeout_ms -> nil
      end

    case handshake do
      {:early, result} ->
        result

      :cancelled ->
        kill(pid, nil)
        {:abandoned, @cancelled}

      nil ->
        kill(pid, nil)
        {:abandoned, "Execution timeout after #{timeout_ms}ms"}

      {:refs, refs} ->
        Subtree.track(%{cleanup: refs})
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

      {__MODULE__, :cancel} ->
        kill(pid, refs)
        {:abandoned, @cancelled}
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

  @doc false
  # A renewal CYFR answers `lost` stops the attempt at once: the row is
  # another's (cancelled, swept, finished, taken over). A renewal CYFR
  # cannot answer keeps the attempt working only while the lease it last
  # held is still good.
  @spec renew_watch(map(), DateTime.t()) :: {:ok, map()} | :lapsed
  def renew_watch(%{client: client} = watch, now \\ DateTime.utc_now()) do
    case HostClient.renew(client, [client.attempt]) do
      {:ok, renewals} ->
        case Map.get(renewals, client.attempt, :lost) do
          {:ok, until} -> {:ok, %{watch | until: DateTime.from_unix!(until, :millisecond)}}
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
  # native thread, which may spin on in this VM; the attempt's `fail` says
  # so (`abandoned`), and the subtree's runner is never reused
  # (`Opus.Subtree.unclean/1`): its service ends the VM, thread and all,
  # once the subtree completes. The tokens dispensed to the run stay in
  # its attempt's masking set, which masks the error when the attempt
  # closes the run.
  defp kill(pid, refs) do
    Subtree.unclean(:component_killed)
    Process.unlink(pid)
    Process.exit(pid, :kill)

    if refs[:stream_exec_ref],
      do: Opus.HttpStreamHandler.cleanup_registry(refs.stream_exec_ref)

    if refs[:formula_tracker_pid],
      do: Opus.FormulaHandler.cleanup_registry(refs.formula_tracker_pid)

    :ok
  end
end
