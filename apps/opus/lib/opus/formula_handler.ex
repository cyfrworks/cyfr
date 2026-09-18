# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.FormulaHandler do
  @moduledoc """
  Host function handler for Formula component composition.

  Provides the `cyfr:formula/invoke@0.1.0` WASI host function import that
  enables Formula components to call MCP tools and invoke sub-components
  from within WASM execution.

  ## Dispatch through the formula's attempt

  Every capability a formula's guest reaches is a host call of the
  formula's attempt (`Opus.HostClient`), decided by CYFR under the
  authority it holds for that attempt; the runner holds no authority that
  grants anything. An action the assignment names as intercepted
  (`Cyfr.Assignment`'s `intercepted`) is a child the host runs:
  `execution.run` and `execution.run_stream` are admitted by CYFR
  (`Opus.HostClient.admit_child/5`) and run in a runner of the formula's
  own runner group (`Opus.Subtree.start_child/2`). Every other action
  is a catalog tool call (`Opus.HostClient.tool_call/4`).

  ## Concurrency Model — Unbundled Promise Pattern

  WASM is single-threaded. Parallelism lives on the Elixir/BEAM host side
  via `Opus.AsyncTracker`, a per-formula GenServer backed by `Task.Supervisor`.

  Host functions exposed to WASM:

  | Function | Behavior |
  |----------|----------|
  | `call` | Synchronous — blocks until MCP tool returns |
  | `spawn` | Async — launches task, returns task_id immediately |
  | `await` | Blocks until specific task completes |
  | `await-all` | Blocks until ALL tasks complete |
  | `await-any` | Blocks until FIRST task completes |
  | `poll` | Non-blocking status check |
  | `cancel` | Cancel a spawned task |
  | `emit` | Push a progress/UI event through the formula's attempt, a `push_deltas` host call (`Opus.Runtime.emit/2`) |

  A called child's runner answers the calling process, and a spawned
  child's the tracker task that spawned it; either is killed when the
  process waiting for it exits. A streamed child runs until it closes.

  ## Architecture

  When a Formula starts executing, the handler spawns:

      Formula Execution
      ├── Task.Supervisor    (owns all spawned sub-tasks)
      └── AsyncTracker       (GenServer — manages task state)

  On completion or timeout, stopping the tracker kills the Task.Supervisor,
  which kills all orphaned tasks. Zero resource leaks.

  ## Request Format (JSON string from WASM)

      {
        "tool": "execution",
        "action": "run",
        "args": {"reference": "...", "input": {...}, "type": "catalyst"}
      }

  ## Response Format (JSON string returned to WASM)

  On success:
      {"status": "completed", "output": {...}}

  On error:
      {"error": {"type": "...", "message": "..."}}

  ## Usage

      {imports, tracker_pid} =
        Opus.FormulaHandler.build_formula_imports(host,
          limits: limits, intercepted: assignment.intercepted)
      # Merge imports and pass to Wasmex.Components.start_link
      # After execution: Opus.FormulaHandler.cleanup_registry(tracker_pid)
  """

  require Logger

  alias Cyfr.Limits
  alias Opus.{AsyncTracker, HostClient, Subtree}

  @ended "Execution attempt ended before it closed"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:formula/invoke@0.1.0` host function.

  Returns a `{imports_map, tracker_pid}` tuple. The imports map contains the
  `"cyfr:formula/invoke@0.1.0"` namespace with all eight invoke functions.

  `host` is the attached `Opus.HostClient` of the formula's attempt: every
  child, tool call and emit is one of its host calls, and the formula's
  execution id is its own.

  ## Options

  - `:limits` - The node's `Cyfr.Limits` (batch timeout, max concurrent
    tasks, request size)
  - `:intercepted` - The `tool.action` names the formula's assignment says
    its host runs rather than the catalog (default `[]`)
  """
  @spec build_formula_imports(HostClient.t(), keyword()) :: {map(), pid()}
  def build_formula_imports(%HostClient{} = host, opts \\ []) do
    parent_execution_id = host.execution_id
    limits = opts[:limits]

    batch_timeout_ms =
      case limits && Limits.batch_timeout_ms(limits) do
        {:ok, ms} -> ms
        _ -> 300_000
      end

    max_tasks = if limits, do: limits.max_concurrent_tasks, else: 10

    tracker =
      case AsyncTracker.start_link(
             parent_execution_id: parent_execution_id,
             max_tasks: max_tasks,
             batch_timeout_ms: batch_timeout_ms
           ) do
        {:ok, pid} ->
          pid

        {:error, reason} ->
          # The runner's boundary rescues this into a failed execution; a
          # bare MatchError here read as a host bug rather than the capacity
          # condition it is.
          raise "async tracker could not start: #{inspect(reason)}"
      end

    exec_opts = [limits: limits, intercepted: Keyword.get(opts, :intercepted, [])]

    imports = %{
      "cyfr:formula/invoke@0.1.0" => %{
        "call" =>
          {:fn,
           fn json_request ->
             guarded(parent_execution_id, "call", fn ->
               execute(json_request, host, exec_opts)
             end)
           end},
        "spawn" =>
          {:fn,
           fn json_request ->
             guarded(parent_execution_id, "spawn", fn ->
               handle_spawn(json_request, host, tracker, exec_opts)
             end)
           end},
        "await" =>
          {:fn,
           fn task_id ->
             guarded(parent_execution_id, "await", fn ->
               handle_await(task_id, tracker, batch_timeout_ms)
             end)
           end},
        "await-all" =>
          {:fn,
           fn json_request ->
             guarded(parent_execution_id, "await-all", fn ->
               handle_await_all(
                 json_request,
                 tracker,
                 batch_timeout_ms,
                 parent_execution_id,
                 max_tasks,
                 limits
               )
             end)
           end},
        "await-any" =>
          {:fn,
           fn json_request ->
             guarded(parent_execution_id, "await-any", fn ->
               handle_await_any(
                 json_request,
                 tracker,
                 batch_timeout_ms,
                 parent_execution_id,
                 max_tasks,
                 limits
               )
             end)
           end},
        "poll" =>
          {:fn,
           fn task_id ->
             guarded(parent_execution_id, "poll", fn ->
               handle_poll(task_id, tracker)
             end)
           end},
        "cancel" =>
          {:fn,
           fn task_id ->
             guarded(parent_execution_id, "cancel", fn ->
               handle_cancel(task_id, tracker, parent_execution_id)
             end)
           end},
        "emit" =>
          {:fn,
           fn json_event ->
             guarded(parent_execution_id, "emit", fn ->
               Opus.Runtime.emit(host, limits, json_event)
             end)
           end}
      }
    }

    {imports, tracker}
  end

  # Catch host-function raises and exits, including tracker call failures.
  # Return a generic typed error to the guest and log fault details on the host.
  defp guarded(parent_execution_id, name, fun) do
    fun.()
  rescue
    exception ->
      Logger.error(
        "[FormulaHandler] #{parent_execution_id} #{name} raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      encode_error(:dispatch_error, "The #{name} call failed.")
  catch
    :exit, reason ->
      Logger.error("[FormulaHandler] #{parent_execution_id} #{name} exited: #{inspect(reason)}")

      encode_error(:dispatch_error, "The #{name} call failed.")
  end

  @doc """
  Clean up async tracker for a formula execution.

  Stops the tracker GenServer, which stops the Task.Supervisor,
  killing all orphaned tasks.
  """
  # How long a graceful tracker stop may take before escalating. The
  # tracker blocks inside its own handle_call for the whole await window
  # (`Task.yield_many` up to the consented batch timeout, ceiling 30 min),
  # so a stop without a bound would park its caller behind that await.
  @cleanup_stop_timeout_ms 5_000

  @spec cleanup_registry(pid()) :: :ok
  def cleanup_registry(tracker_pid) when is_pid(tracker_pid) do
    GenServer.stop(tracker_pid, :normal, @cleanup_stop_timeout_ms)
    :ok
  rescue
    e in [ArgumentError, RuntimeError] ->
      Logger.warning("[FormulaHandler] cleanup_registry failed: #{inspect(e)}")
      :ok
  catch
    # `GenServer.stop/2` exits for a dead pid (`:noproc`), and every caller
    # reaches here after the process the tracker is linked to may already
    # have been killed: the tracker being gone is the outcome wanted.
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      :ok

    :exit, :noproc ->
      :ok

    :exit, {:timeout, _} ->
      # Still blocked in an await after the grace: a graceful stop cannot
      # land, so kill it — the link tears down its Task.Supervisor and the
      # spawned children with it, which is what stopping was for.
      Process.exit(tracker_pid, :kill)
      :ok

    :exit, reason ->
      Logger.warning("[FormulaHandler] cleanup_registry exited: #{inspect(reason)}")
      :ok
  end

  def cleanup_registry(_), do: :ok

  @doc """
  Execute an MCP tool call from a formula (synchronous).

  Parses the JSON request and runs it through the formula's attempt `host`:
  an intercepted action as a child the host runs, every other action as a
  catalog tool call. Returns a JSON response string. A refusal CYFR renders
  for the guest (a setup refusal with its `remediation`) is handed on as
  it is.

  ## Options

  - `:limits` - The node's `Cyfr.Limits` (request size)
  - `:intercepted` - The `tool.action` names the host runs (default `[]`)
  """
  @spec execute(String.t(), HostClient.t(), keyword()) :: String.t()
  def execute(json_request, %HostClient{} = host, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    case parse_mcp_request(json_request, opts[:limits]) do
      {:ok, %{tool: tool, action: action, args: args}} ->
        name = "#{tool}.#{action}"

        if intercepted?(name, opts) do
          dispatch_child_call(name, args, host, start_time)
        else
          dispatch_tool_call(tool, action, args, host, start_time)
        end

      {:error, type, message} ->
        emit_telemetry(host.execution_id, "unknown", :error, start_time)
        encode_error(type, message)
    end
  end

  @doc false
  # The host's arm for a `tool.action` its assignment intercepts: a called
  # child, or a streamed one. An intercepted action the host has no arm for
  # is a typed refusal, never a crash; a test pins that every intercepted
  # action has one.
  @spec child_runner(String.t()) :: {:ok, :call | :stream} | :error
  def child_runner("execution.run"), do: {:ok, :call}
  def child_runner("execution.run_stream"), do: {:ok, :stream}
  def child_runner(_name), do: :error

  defp intercepted?(name, opts), do: name in Keyword.get(opts, :intercepted, [])

  defp dispatch_child_call(name, args, host, start_time) do
    result =
      with {:ok, reference, need, input} <- child_request(name, args) do
        case child_runner(name) do
          {:ok, :call} -> run_child(host, reference, need, input)
          {:ok, :stream} -> stream_child(host, reference, need, input)
          :error -> {:refused, encode_error(:invalid_request, "#{name} has no host dispatch")}
        end
      end

    case result do
      {:ok, output} ->
        emit_telemetry(host.execution_id, name, :ok, start_time)
        encode_success(output)

      {:refused, response} ->
        emit_telemetry(host.execution_id, name, :error, start_time)
        response
    end
  end

  # Guest-supplied lineage keys never reach CYFR: the child's parent and
  # root are the formula attempt's, and its input is only what the
  # request's own "input" carried — or, for a delegate of the same formula,
  # what CYFR's copy of the parent's roster holds for it.
  defp child_request(name, args) do
    case {Map.get(args, "reference"), Map.get(args, "input") || %{}} do
      {reference, %{} = input} when is_binary(reference) and reference != "" ->
        {:ok, reference, Map.get(args, "need"), input}

      {reference, _input} when is_binary(reference) and reference != "" ->
        {:refused, encode_error(:invalid_request, "#{name} requires 'input' to be an object")}

      _ ->
        {:refused, encode_error(:invalid_request, "#{name} requires a 'reference'")}
    end
  end

  defp run_child(host, reference, need, input) do
    case HostClient.admit_child(host, reference, need, input, :call) do
      {:ok, child} -> child |> await_child() |> answered()
      {:error, refusal} -> {:refused, encode_refusal(refusal)}
    end
  end

  # A streamed child runs in a runner nothing waits for, and is answered
  # with its id and its event stream's URL at once.
  defp stream_child(host, reference, need, input) do
    case HostClient.admit_child(host, reference, need, input, :spawn) do
      {:ok, child} ->
        case Subtree.start_child(child, nil) do
          {:ok, _runner} ->
            id = child.assignment.execution_id
            {:ok, %{"execution_id" => id, "stream_url" => "/api/executions/#{id}/events"}}

          {:error, reason} ->
            {:refused, abandon(child, reason)}
        end

      {:error, refusal} ->
        {:refused, encode_refusal(refusal)}
    end
  end

  # The child runs in a runner of the formula's group that answers the
  # calling process, and is killed if the calling process exits first.
  defp await_child(child) do
    case Subtree.start_child(child, self()) do
      {:ok, runner} ->
        ref = Process.monitor(runner)

        receive do
          {Opus.Attempt, ^runner, answer} ->
            Process.demonitor(ref, [:flush])
            answer

          {:DOWN, ^ref, :process, ^runner, _reason} ->
            {:error, @ended}
        end

      {:error, reason} ->
        {:error, abandon_message(child, reason)}
    end
  end

  defp answered({:ok, output}), do: {:ok, output}
  defp answered({:error, message}), do: {:refused, encode_error(:dispatch_error, message)}

  # A child admitted but not started is closed failed, which gives back
  # what it holds.
  defp abandon(child, reason), do: encode_error(:dispatch_error, abandon_message(child, reason))

  defp abandon_message(child, reason) do
    Logger.error(
      "[Opus.FormulaHandler] child #{child.assignment.execution_id} was not started: " <>
        inspect(reason)
    )

    case HostClient.fail(child.client, "Execution refused: its runner could not start") do
      {:ok, message} -> message
      {:error, _refusal} -> @ended
    end
  end

  defp dispatch_tool_call(tool, action, args, host, start_time) do
    tool_action = tool_action(tool, action)

    case HostClient.tool_call(host, tool, Map.put(args, "action", action), :call) do
      {:ok, result} ->
        emit_telemetry(host.execution_id, tool_action, :ok, start_time)
        encode_success(result)

      {:error, refusal} ->
        emit_telemetry(host.execution_id, tool_action, :error, start_time)
        encode_refusal(refusal)
    end
  end

  defp tool_action(tool, action),
    do: if(String.contains?(tool, ":"), do: "external.call", else: "#{tool}.#{action}")

  # A refusal CYFR rendered for the guest is handed on as it is; a call
  # whose answer was lost says so; a host call CYFR did not answer is a
  # generic failure.
  defp encode_refusal({:guest_error, type, message}), do: encode_error(type, message)

  defp encode_refusal({:guest_error, type, message, remediation}),
    do: encode_error_with_remediation(type, message, remediation)

  defp encode_refusal({:uncertain, sentence}), do: encode_error(:uncertain, sentence)

  defp encode_refusal(refusal) do
    Logger.warning("[Opus.FormulaHandler] host call refused: #{inspect(refusal)}")
    encode_error(:dispatch_error, "The call failed.")
  end

  # ============================================================================
  # Host Function Implementations
  # ============================================================================

  defp handle_spawn(json_request, host, tracker, opts) do
    case parse_mcp_request(json_request, opts[:limits]) do
      {:ok, %{tool: tool, action: action, args: args}} ->
        name = "#{tool}.#{action}"

        cond do
          not intercepted?(name, opts) ->
            spawn_tool_call(tool, action, args, host, tracker)

          name == "execution.run" ->
            spawn_child_async(name, args, host, tracker)

          # There is no async shape for run_stream: a spawn promises
          # {"task_id": ...}, and a streamed child answers at once.
          name == "execution.run_stream" ->
            encode_error(
              :invalid_request,
              "run_stream cannot be spawned — spawn execution.run, or call run_stream directly"
            )

          true ->
            encode_error(:invalid_request, "#{name} cannot be spawned")
        end

      {:error, type, message} ->
        encode_error(type, message)
    end
  end

  # A spawned child is admitted before the tracker task exists, so a refusal
  # takes no task slot; the tracker's room is checked first, so an admitted
  # child always gets its task. Only the guest spawns, one host call at a
  # time, so the room cannot shrink between the check and the spawn.
  defp spawn_child_async(name, args, host, tracker) do
    with {:ok, reference, need, input} <- child_request(name, args),
         :ok <- tracker_room(tracker),
         {:ok, child} <- admit_spawned(host, reference, need, input) do
      spawn_child_task(child, host, tracker)
    else
      {:refused, response} -> response
    end
  end

  defp tracker_room(tracker) do
    if AsyncTracker.room?(tracker),
      do: :ok,
      else: {:refused, encode_error(:resource_limit, "Maximum concurrent tasks exceeded")}
  end

  defp admit_spawned(host, reference, need, input) do
    case HostClient.admit_child(host, reference, need, input, :spawn) do
      {:ok, child} -> {:ok, child}
      {:error, refusal} -> {:refused, encode_refusal(refusal)}
    end
  end

  defp spawn_child_task(child, host, tracker) do
    fun = fn ->
      start_time = System.monotonic_time(:millisecond)

      case await_child(child) do
        {:ok, output} ->
          emit_telemetry(host.execution_id, "execution.run", :ok, start_time)
          {encode_success(output), %{tool: "execution", action: "run"}}

        {:error, message} ->
          emit_telemetry(host.execution_id, "execution.run", :error, start_time)
          {encode_error(:dispatch_error, message), %{tool: "execution", action: "run"}}
      end
    end

    # A timed-out call has still landed in the tracker's mailbox, and the
    # task runs the child; any other exit means the task never started.
    spawned =
      try do
        AsyncTracker.spawn_task(tracker, fun, "execution.run")
      catch
        :exit, {:timeout, _} = reason -> {:unreachable, reason}
        :exit, reason -> {:error, {:tracker_unreachable, reason}}
      end

    case spawned do
      {:ok, task_id} ->
        Opus.Telemetry.formula_spawn(host.execution_id, task_id, "execution.run")
        safe_encode(%{"task_id" => task_id})

      {:unreachable, reason} ->
        Logger.warning("[Opus.FormulaHandler] spawn tracker unreachable: #{inspect(reason)}")
        encode_error(:spawn_failed, "task tracker unavailable")

      {:error, :max_tasks_exceeded} ->
        _message = abandon_message(child, :max_tasks_exceeded)
        encode_error(:resource_limit, "Maximum concurrent tasks exceeded")

      {:error, reason} ->
        _message = abandon_message(child, reason)
        encode_error(:spawn_failed, "task tracker unavailable")
    end
  end

  defp spawn_tool_call(tool, action, args, host, tracker) do
    tool_action = tool_action(tool, action)
    args_with_action = Map.put(args, "action", action)

    # Rescued in the task, the way the synchronous `execute/3` path is
    # wrapped by `guarded/3`, so an exit reason never reaches the guest's
    # response through the tracker.
    fun = fn ->
      start_time = System.monotonic_time(:millisecond)

      try do
        case HostClient.tool_call(host, tool, args_with_action, :spawn) do
          {:ok, result} ->
            emit_telemetry(host.execution_id, tool_action, :ok, start_time)
            {encode_success(result), %{tool: tool, action: action}}

          {:error, refusal} ->
            emit_telemetry(host.execution_id, tool_action, :error, start_time)
            {encode_refusal(refusal), %{tool: tool, action: action}}
        end
      rescue
        e ->
          emit_telemetry(host.execution_id, tool_action, :error, start_time)

          Logger.error(
            "[Opus.FormulaHandler] spawned #{tool_action} raised: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          {encode_error(:dispatch_error, "The call failed."), %{tool: tool, action: action}}
      end
    end

    case AsyncTracker.spawn_task(tracker, fun, tool_action) do
      {:ok, task_id} ->
        Opus.Telemetry.formula_spawn(host.execution_id, task_id, tool_action)
        safe_encode(%{"task_id" => task_id})

      {:error, :max_tasks_exceeded} ->
        encode_error(:resource_limit, "Maximum concurrent tasks exceeded")

      {:error, reason} ->
        encode_error(:spawn_failed, guest_reason(reason))
    end
  end

  defp handle_await(task_id, tracker, timeout_ms) do
    start = System.monotonic_time(:millisecond)

    case AsyncTracker.await_task(tracker, task_id, timeout_ms) do
      {:ok, {json_result, metadata}} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        Opus.Telemetry.formula_await(task_id, :completed, duration_ms)
        build_await_response(task_id, json_result, metadata)

      {:ok, result} when is_binary(result) ->
        # Direct string result (no metadata wrapper)
        duration_ms = System.monotonic_time(:millisecond) - start
        Opus.Telemetry.formula_await(task_id, :completed, duration_ms)
        build_await_response(task_id, result, %{})

      {:error, :timeout} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        Opus.Telemetry.formula_await(task_id, :timeout, duration_ms)

        safe_encode(%{
          "status" => "error",
          "error" => %{"type" => "timeout", "message" => "Task timed out"},
          "task_id" => task_id,
          "duration_ms" => duration_ms
        })

      {:error, :unknown_task} ->
        encode_error(:invalid_request, "Unknown task_id: #{task_id}")

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        Opus.Telemetry.formula_await(task_id, :error, duration_ms)

        safe_encode(%{
          "status" => "error",
          "error" => %{"type" => "task_failed", "message" => stringify_reason(reason)},
          "task_id" => task_id,
          "duration_ms" => duration_ms
        })
    end
  end

  defp handle_await_all(json_request, tracker, timeout_ms, parent_execution_id, max_tasks, limits) do
    with :ok <- envelope_bound(json_request, limits) do
      await_all_decoded(json_request, tracker, timeout_ms, parent_execution_id, max_tasks)
    else
      {:error, type, message} -> encode_error(type, message)
    end
  end

  defp await_all_decoded(json_request, tracker, timeout_ms, parent_execution_id, max_tasks) do
    case Jason.decode(json_request) do
      # The spawn cap bounds live-plus-undrained entries at max_tasks, so no
      # honest await list is longer; a fabricated one would burn quadratic
      # time in the tracker (which serializes every guest async op) for a
      # list of :unknown_task errors.
      {:ok, %{"task_ids" => task_ids}}
      when is_list(task_ids) and length(task_ids) > max_tasks ->
        encode_error(
          :invalid_request,
          "task_ids exceeds the concurrent-task limit (#{max_tasks})"
        )

      {:ok, %{"task_ids" => task_ids}} when is_list(task_ids) and task_ids != [] ->
        # Deduped where the guest's ids enter, so the tracker (which answers
        # once per distinct id) and this envelope's "count" agree.
        task_ids = Enum.uniq(task_ids)
        start = System.monotonic_time(:millisecond)

        case AsyncTracker.await_all(tracker, task_ids, timeout_ms) do
          {:ok, results} ->
            duration_ms = System.monotonic_time(:millisecond) - start

            timed_out =
              Enum.count(results, fn {_id, result} ->
                result == {:error, :timeout}
              end)

            Opus.Telemetry.formula_await_all(
              parent_execution_id,
              length(task_ids),
              timed_out,
              duration_ms
            )

            formatted =
              Enum.map(results, fn {task_id, result} ->
                format_task_result(task_id, result)
              end)

            safe_encode(%{"results" => formatted, "count" => length(task_ids)})
        end

      {:ok, %{"task_ids" => []}} ->
        safe_encode(%{"results" => [], "count" => 0})

      {:ok, _} ->
        encode_error(:invalid_request, "Request must include 'task_ids' array")

      {:error, _} ->
        encode_error(:invalid_json, "Invalid JSON request")
    end
  end

  defp handle_await_any(json_request, tracker, timeout_ms, parent_execution_id, max_tasks, limits) do
    with :ok <- envelope_bound(json_request, limits) do
      await_any_decoded(json_request, tracker, timeout_ms, parent_execution_id, max_tasks)
    else
      {:error, type, message} -> encode_error(type, message)
    end
  end

  defp await_any_decoded(json_request, tracker, timeout_ms, parent_execution_id, max_tasks) do
    case Jason.decode(json_request) do
      # Same bound as await-all, for the same reason.
      {:ok, %{"task_ids" => task_ids}}
      when is_list(task_ids) and length(task_ids) > max_tasks ->
        encode_error(
          :invalid_request,
          "task_ids exceeds the concurrent-task limit (#{max_tasks})"
        )

      {:ok, %{"task_ids" => task_ids}} when is_list(task_ids) and task_ids != [] ->
        # Same dedupe as await-all, and the timeout arm's "pending" echo
        # then lists each task once.
        task_ids = Enum.uniq(task_ids)
        start = System.monotonic_time(:millisecond)

        case AsyncTracker.await_any(tracker, task_ids, timeout_ms) do
          {:ok, winner_id, result, pending} ->
            duration_ms = System.monotonic_time(:millisecond) - start
            Opus.Telemetry.formula_await_any(parent_execution_id, winner_id, duration_ms)

            formatted_result = format_task_result(winner_id, result)

            safe_encode(%{
              "result" => formatted_result,
              "task_id" => winner_id,
              "pending" => pending
            })

          {:error, :timeout} ->
            duration_ms = System.monotonic_time(:millisecond) - start
            Opus.Telemetry.formula_await_any(parent_execution_id, nil, duration_ms)

            safe_encode(%{
              "status" => "error",
              "error" => %{"type" => "timeout", "message" => "All tasks timed out"},
              "pending" => task_ids
            })
        end

      {:ok, %{"task_ids" => []}} ->
        encode_error(:invalid_request, "task_ids array must be non-empty")

      {:ok, _} ->
        encode_error(:invalid_request, "Request must include 'task_ids' array")

      {:error, _} ->
        encode_error(:invalid_json, "Invalid JSON request")
    end
  end

  defp handle_poll(task_id, tracker) do
    case AsyncTracker.poll(tracker, task_id) do
      {:ok, :pending} ->
        safe_encode(%{"status" => "pending"})

      {:ok, {json_result, metadata}} ->
        build_await_response(task_id, json_result, metadata)

      {:ok, result} when is_binary(result) ->
        build_await_response(task_id, result, %{})

      {:error, :unknown_task} ->
        encode_error(:invalid_request, "Unknown task_id: #{task_id}")

      {:error, reason} ->
        safe_encode(%{
          "status" => "error",
          "error" => %{"type" => "task_failed", "message" => stringify_reason(reason)},
          "task_id" => task_id
        })
    end
  end

  defp handle_cancel(task_id, tracker, parent_execution_id) do
    case AsyncTracker.cancel_task(tracker, task_id) do
      :ok ->
        Opus.Telemetry.formula_cancel(parent_execution_id, task_id)
        safe_encode(%{"cancelled" => true, "task_id" => task_id})

      {:error, :already_completed} ->
        encode_error(:invalid_request, "Task #{task_id} already completed")

      {:error, :unknown_task} ->
        encode_error(:invalid_request, "Unknown task_id: #{task_id}")

      {:error, reason} ->
        encode_error(:cancel_failed, guest_reason(reason))
    end
  end

  # ============================================================================
  # Private: Request Parsing (MCP format)
  # ============================================================================

  defp parse_mcp_request(json_string, limits) do
    with :ok <- envelope_bound(json_string, limits) do
      case Jason.decode(json_string) do
        {:ok, %{"tool" => tool, "action" => action} = req}
        when is_binary(tool) and is_binary(action) ->
          args = Map.get(req, "args", %{})

          if is_map(args) do
            {:ok, %{tool: tool, action: action, args: args}}
          else
            {:error, :invalid_request, "args must be a map"}
          end

        {:ok, _} ->
          {:error, :invalid_request, "Request must include 'tool' (string) and 'action' (string)"}

        {:error, _} ->
          {:error, :invalid_json, "Invalid JSON request"}
      end
    end
  end

  # Enforce the request size cap before JSON decoding.
  defp envelope_bound(json_string, %Limits{} = limits) do
    case Opus.EdgeGuard.check_envelope_size(limits, json_string) do
      :ok ->
        :ok

      {:error, :request_too_large} ->
        {:error, :request_too_large,
         "Request exceeds the consented max_request_size for this component."}
    end
  end

  defp envelope_bound(_json_string, _limits), do: :ok

  # ============================================================================
  # Private: Response Encoding
  # ============================================================================

  defp safe_encode(data), do: Cyfr.WitResponse.safe_encode(data)

  defp encode_success(output) do
    safe_encode(%{
      "status" => "completed",
      "output" => output
    })
  end

  @doc false
  def encode_error(type, message),
    do: Cyfr.WitResponse.encode_error(type, stringify_reason(message))

  defp encode_error_with_remediation(type, message, remediation) do
    safe_encode(%{
      "error" => %{
        "type" => to_string(type),
        "message" => stringify_reason(message),
        "remediation" => remediation
      }
    })
  end

  defp build_await_response(task_id, json_result, metadata) do
    # Parse the invocation result to extract status/output/error
    base =
      case Jason.decode(json_result) do
        {:ok, %{"status" => "completed", "output" => output}} ->
          %{"status" => "completed", "output" => output}

        {:ok, %{"error" => error}} ->
          %{"status" => "error", "error" => error}

        _ ->
          %{
            "status" => "error",
            "error" => %{"type" => "unknown", "message" => "Unexpected result format"}
          }
      end

    base
    |> Map.put("task_id", task_id)
    |> Map.merge(format_metadata(metadata))
    |> safe_encode()
  end

  defp format_metadata(%{execution_id: eid, duration_ms: ms}) do
    result = %{"duration_ms" => ms}
    if eid, do: Map.put(result, "execution_id", eid), else: result
  end

  defp format_metadata(_), do: %{}

  defp format_task_result(task_id, {:ok, {json_result, metadata}}) do
    case Jason.decode(json_result) do
      {:ok, %{"status" => "completed", "output" => output}} ->
        %{"status" => "completed", "output" => output, "task_id" => task_id}
        |> Map.merge(format_metadata(metadata))

      {:ok, %{"error" => error}} ->
        %{"status" => "error", "error" => error, "task_id" => task_id}
        |> Map.merge(format_metadata(metadata))

      _ ->
        %{
          "status" => "error",
          "error" => %{"type" => "unknown", "message" => "Unexpected result"},
          "task_id" => task_id
        }
    end
  end

  defp format_task_result(task_id, {:ok, result}) when is_binary(result) do
    format_task_result(task_id, {:ok, {result, %{}}})
  end

  defp format_task_result(task_id, {:error, :timeout}) do
    %{
      "status" => "error",
      "error" => %{"type" => "timeout", "message" => "Task timed out"},
      "task_id" => task_id
    }
  end

  defp format_task_result(task_id, {:error, reason}) when is_binary(reason) do
    %{
      "status" => "error",
      "error" => %{"type" => "task_failed", "message" => reason},
      "task_id" => task_id
    }
  end

  defp format_task_result(task_id, {:error, reason}) do
    %{
      "status" => "error",
      "error" => %{"type" => "task_failed", "message" => guest_reason(reason)},
      "task_id" => task_id
    }
  end

  # ============================================================================
  # Private: Telemetry
  # ============================================================================

  defp emit_telemetry(execution_id, tool_action, status, start_time) do
    duration_ms = System.monotonic_time(:millisecond) - start_time
    Opus.Telemetry.mcp_tool_call(execution_id, tool_action, status, duration_ms)
  end

  defp stringify_reason(reason), do: render_reason(reason)

  # Guest-facing reason text below the `Cyfr.GuestError` vocabulary: a
  # crafted binary passes, a bare reason atom names itself verbatim, and
  # anything structured renders through the shared vocabulary or is logged
  # and generalized — never `inspect/1`, which would hand the guest whatever
  # the term carried.
  defp guest_reason(reason) when is_binary(reason), do: reason

  defp guest_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp guest_reason(reason) do
    case Cyfr.GuestError.render(reason) do
      nil ->
        Logger.warning("[FormulaHandler] unrenderable guest reason: #{inspect(reason)}")
        "the call failed"

      msg ->
        msg
    end
  end

  @doc """
  The guest's view of a refusal: the sentence `Cyfr.GuestError` renders
  from the reason's data, and never an internal term. A refusal CYFR wants
  a guest to see crosses the wire already rendered, as a guest error's
  `type` and `message`.
  """
  @spec render_reason(term()) :: String.t()
  def render_reason(reason) do
    # `nil` means the term is internal — logged where it was produced, never
    # handed to the guest.
    Cyfr.GuestError.render(reason) || "The call failed."
  end
end
