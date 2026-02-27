defmodule Opus.FormulaHandler do
  @moduledoc """
  Host function handler for Formula component composition.

  Provides the `cyfr:formula/invoke@0.1.0` WASI host function import that
  enables Formula components to invoke sub-components (Reagents, Catalysts,
  or other Formulas) from within WASM execution.

  ## Concurrency Model — Unbundled Promise Pattern

  WASM is single-threaded. Parallelism lives on the Elixir/BEAM host side
  via `Opus.AsyncTracker`, a per-formula GenServer backed by `Task.Supervisor`.

  Host functions exposed to WASM:

  | Function | Behavior |
  |----------|----------|
  | `call` | Synchronous — blocks until sub-component returns |
  | `spawn` | Async — launches task, returns task_id immediately |
  | `await` | Blocks until specific task completes |
  | `await-all` | Blocks until ALL tasks complete |
  | `await-any` | Blocks until FIRST task completes |
  | `poll` | Non-blocking status check |
  | `cancel` | Cancel a spawned task |

  ## Architecture

  When a Formula starts executing, the handler spawns:

      Formula Execution
      ├── Task.Supervisor    (owns all spawned sub-tasks)
      └── AsyncTracker       (GenServer — manages task state)

  On completion or timeout, stopping the tracker kills the Task.Supervisor,
  which kills all orphaned tasks. Zero resource leaks.

  ## Logging Model

  Sub-invocations go through `Executor.run/4` which writes execution records.
  Every sub-execution gets its own `exec_<uuid7>` ID, shares the parent's
  `request_id` for correlation, and stores `parent_execution_id` for lineage.

  ## Request Format (JSON string from WASM)

      {
        "reference": "catalyst:local.claude:0.2.0",
        "input": {...},
        "type": "reagent" | "catalyst" | "formula"
      }

  ## Response Format (JSON string returned to WASM)

  On success:
      {"status": "completed", "output": {...}}

  On error:
      {"error": {"type": "...", "message": "..."}}

  ## Usage

      {imports, tracker_pid} = Opus.FormulaHandler.build_formula_imports(ctx, parent_execution_id, policy)
      # Merge imports and pass to Wasmex.Components.start_link
      # Call Opus.FormulaHandler.cleanup_registry(tracker_pid) after execution
  """

  require Logger

  alias Sanctum.Context

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:formula/invoke@0.1.0` host function.

  Returns a `{imports_map, tracker_pid}` tuple. The imports map contains the
  `"cyfr:formula/invoke@0.1.0"` namespace with all seven invoke functions.

  ## Parameters

  - `ctx` - The execution `Sanctum.Context` (shared with sub-executions)
  - `parent_execution_id` - The formula's own execution ID for lineage tracking
  - `policy` - The `Sanctum.Policy` struct for the formula (for limits)
  """
  @spec build_formula_imports(Context.t(), String.t(), Sanctum.Policy.t() | nil) :: {map(), pid()}
  def build_formula_imports(%Context{} = ctx, parent_execution_id, policy \\ nil) do
    # Parse batch_timeout from policy
    batch_timeout_ms = if policy do
      case Sanctum.Policy.parse_duration(policy.batch_timeout) do
        {:ok, ms} -> ms
        {:error, _} -> 300_000
      end
    else
      300_000
    end

    max_tasks = if policy, do: policy.max_concurrent_tasks, else: 10

    {:ok, tracker} = Opus.AsyncTracker.start_link(
      parent_execution_id: parent_execution_id,
      max_tasks: max_tasks,
      batch_timeout_ms: batch_timeout_ms
    )

    imports = %{
      "cyfr:formula/invoke@0.1.0" => %{
        "call" => {:fn, fn json_request ->
          execute(json_request, ctx, parent_execution_id)
        end},
        "spawn" => {:fn, fn json_request ->
          handle_spawn(json_request, ctx, parent_execution_id, tracker)
        end},
        "await" => {:fn, fn task_id ->
          handle_await(task_id, tracker, batch_timeout_ms)
        end},
        "await-all" => {:fn, fn json_request ->
          handle_await_all(json_request, tracker, batch_timeout_ms, parent_execution_id)
        end},
        "await-any" => {:fn, fn json_request ->
          handle_await_any(json_request, tracker, batch_timeout_ms, parent_execution_id)
        end},
        "poll" => {:fn, fn task_id ->
          handle_poll(task_id, tracker)
        end},
        "cancel" => {:fn, fn task_id ->
          handle_cancel(task_id, tracker, parent_execution_id)
        end}
      }
    }

    {imports, tracker}
  end

  @doc """
  Clean up async tracker for a formula execution.

  Stops the tracker GenServer, which stops the Task.Supervisor,
  killing all orphaned tasks.
  """
  @spec cleanup_registry(pid()) :: :ok
  def cleanup_registry(tracker_pid) when is_pid(tracker_pid) do
    GenServer.stop(tracker_pid, :normal)
    :ok
  rescue
    _ -> :ok
  end

  def cleanup_registry(_), do: :ok

  @doc """
  Execute a sub-component invocation from a formula (synchronous).

  Parses the JSON request, invokes via `Opus.Executor.run/4`, and returns
  a JSON response string.
  """
  @spec execute(String.t(), Context.t(), String.t()) :: String.t()
  def execute(json_request, %Context{} = ctx, parent_execution_id) do
    case parse_request(json_request) do
      {:ok, %{reference: reference, input: input, type: type}} ->
        invoke_component(ctx, reference, input, type, parent_execution_id)

      {:error, type, message} ->
        encode_error(type, message)
    end
  end

  # ============================================================================
  # Host Function Implementations
  # ============================================================================

  defp handle_spawn(json_request, ctx, parent_execution_id, tracker) do
    case parse_request(json_request) do
      {:ok, %{reference: reference, input: input, type: type}} ->
        fun = fn ->
          invoke_component_with_metadata(ctx, reference, input, type, parent_execution_id)
        end

        case Opus.AsyncTracker.spawn_task(tracker, fun, reference) do
          {:ok, task_id} ->
            Opus.Telemetry.formula_spawn(parent_execution_id, task_id, reference)
            Jason.encode!(%{"task_id" => task_id})

          {:error, :max_tasks_exceeded} ->
            encode_error(:resource_limit, "Maximum concurrent tasks exceeded")

          {:error, reason} ->
            encode_error(:spawn_failed, inspect(reason))
        end

      {:error, type, message} ->
        encode_error(type, message)
    end
  end

  defp handle_await(task_id, tracker, timeout_ms) do
    start = System.monotonic_time(:millisecond)

    case Opus.AsyncTracker.await_task(tracker, task_id, timeout_ms) do
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
        Jason.encode!(%{
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
        Jason.encode!(%{
          "status" => "error",
          "error" => %{"type" => "task_failed", "message" => to_string(reason)},
          "task_id" => task_id,
          "duration_ms" => duration_ms
        })
    end
  end

  defp handle_await_all(json_request, tracker, timeout_ms, parent_execution_id) do
    case Jason.decode(json_request) do
      {:ok, %{"task_ids" => task_ids}} when is_list(task_ids) and task_ids != [] ->
        start = System.monotonic_time(:millisecond)

        case Opus.AsyncTracker.await_all(tracker, task_ids, timeout_ms) do
          {:ok, results} ->
            duration_ms = System.monotonic_time(:millisecond) - start
            timed_out = Enum.count(results, fn {_id, result} ->
              result == {:error, :timeout}
            end)

            Opus.Telemetry.formula_await_all(parent_execution_id, length(task_ids), timed_out, duration_ms)

            formatted = Enum.map(results, fn {task_id, result} ->
              format_task_result(task_id, result)
            end)

            Jason.encode!(%{"results" => formatted, "count" => length(task_ids)})
        end

      {:ok, %{"task_ids" => []}} ->
        Jason.encode!(%{"results" => [], "count" => 0})

      {:ok, _} ->
        encode_error(:invalid_request, "Request must include 'task_ids' array")

      {:error, _} ->
        encode_error(:invalid_json, "Invalid JSON request")
    end
  end

  defp handle_await_any(json_request, tracker, timeout_ms, parent_execution_id) do
    case Jason.decode(json_request) do
      {:ok, %{"task_ids" => task_ids}} when is_list(task_ids) and task_ids != [] ->
        start = System.monotonic_time(:millisecond)

        case Opus.AsyncTracker.await_any(tracker, task_ids, timeout_ms) do
          {:ok, winner_id, result, pending} ->
            duration_ms = System.monotonic_time(:millisecond) - start
            Opus.Telemetry.formula_await_any(parent_execution_id, winner_id, duration_ms)

            formatted_result = format_task_result(winner_id, result)
            Jason.encode!(%{
              "result" => formatted_result,
              "task_id" => winner_id,
              "pending" => pending
            })

          {:error, :timeout} ->
            duration_ms = System.monotonic_time(:millisecond) - start
            Opus.Telemetry.formula_await_any(parent_execution_id, nil, duration_ms)

            Jason.encode!(%{
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
    case Opus.AsyncTracker.poll(tracker, task_id) do
      {:ok, :pending} ->
        Jason.encode!(%{"status" => "pending"})

      {:ok, {json_result, metadata}} ->
        build_await_response(task_id, json_result, metadata)

      {:ok, result} when is_binary(result) ->
        build_await_response(task_id, result, %{})

      {:error, :unknown_task} ->
        encode_error(:invalid_request, "Unknown task_id: #{task_id}")

      {:error, reason} ->
        Jason.encode!(%{
          "status" => "error",
          "error" => %{"type" => "task_failed", "message" => to_string(reason)},
          "task_id" => task_id
        })
    end
  end

  defp handle_cancel(task_id, tracker, parent_execution_id) do
    case Opus.AsyncTracker.cancel_task(tracker, task_id) do
      :ok ->
        Opus.Telemetry.formula_cancel(parent_execution_id, task_id)
        Jason.encode!(%{"cancelled" => true, "task_id" => task_id})

      {:error, :already_completed} ->
        encode_error(:invalid_request, "Task #{task_id} already completed")

      {:error, :unknown_task} ->
        encode_error(:invalid_request, "Unknown task_id: #{task_id}")

      {:error, reason} ->
        encode_error(:cancel_failed, inspect(reason))
    end
  end

  # ============================================================================
  # Private: Request Parsing
  # ============================================================================

  defp parse_request(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"reference" => reference, "input" => input} = req} when is_binary(reference) and is_map(input) ->
        type = req["type"] || "reagent"

        case Opus.ComponentType.parse(type) do
          {:ok, component_type} ->
            {:ok, %{reference: reference, input: input, type: component_type}}
          {:error, reason} ->
            {:error, :invalid_request, to_string(reason)}
        end

      {:ok, %{"reference" => _}} ->
        {:error, :invalid_request, "Request must include 'reference' (string) and 'input' (map)"}

      {:ok, _} ->
        {:error, :invalid_request, "Request must include 'reference' and 'input'"}

      {:error, _} ->
        {:error, :invalid_json, "Invalid JSON request"}
    end
  end

  # ============================================================================
  # Private: Component Invocation
  # ============================================================================

  defp invoke_component(ctx, reference, input, type, parent_execution_id) do
    telemetry_ref = telemetry_ref(reference)

    case Opus.Executor.run(ctx, reference, input,
           type: type,
           parent_execution_id: parent_execution_id) do
      {:ok, %{output: output, metadata: %{execution_id: child_execution_id}}} ->
        Opus.Telemetry.formula_invoke(parent_execution_id, child_execution_id, telemetry_ref, :ok)
        encode_success(output)

      {:error, reason} ->
        Opus.Telemetry.formula_invoke(parent_execution_id, nil, telemetry_ref, :error)
        encode_error(:execution_failed, reason)
    end
  end

  defp invoke_component_with_metadata(ctx, reference, input, type, parent_execution_id) do
    start = System.monotonic_time(:millisecond)
    telemetry_ref = telemetry_ref(reference)

    case Opus.Executor.run(ctx, reference, input,
           type: type,
           parent_execution_id: parent_execution_id) do
      {:ok, %{output: output, metadata: %{execution_id: child_execution_id}}} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        Opus.Telemetry.formula_invoke(parent_execution_id, child_execution_id, telemetry_ref, :ok)
        {encode_success(output), %{execution_id: child_execution_id, duration_ms: duration_ms}}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        Opus.Telemetry.formula_invoke(parent_execution_id, nil, telemetry_ref, :error)
        {encode_error(:execution_failed, reason), %{execution_id: nil, duration_ms: duration_ms}}
    end
  end

  defp telemetry_ref(ref) when is_binary(ref), do: ref
  defp telemetry_ref(ref), do: inspect(ref)

  # ============================================================================
  # Private: Response Encoding
  # ============================================================================

  defp encode_success(output) do
    Jason.encode!(%{
      "status" => "completed",
      "output" => output
    })
  end

  @doc false
  def encode_error(type, message) do
    Jason.encode!(%{
      "error" => %{
        "type" => to_string(type),
        "message" => to_string(message)
      }
    })
  end

  defp build_await_response(task_id, json_result, metadata) do
    # Parse the invocation result to extract status/output/error
    base = case Jason.decode(json_result) do
      {:ok, %{"status" => "completed", "output" => output}} ->
        %{"status" => "completed", "output" => output}

      {:ok, %{"error" => error}} ->
        %{"status" => "error", "error" => error}

      _ ->
        %{"status" => "error", "error" => %{"type" => "unknown", "message" => "Unexpected result format"}}
    end

    base
    |> Map.put("task_id", task_id)
    |> Map.merge(format_metadata(metadata))
    |> Jason.encode!()
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
        %{"status" => "error", "error" => %{"type" => "unknown", "message" => "Unexpected result"}, "task_id" => task_id}
    end
  end

  defp format_task_result(task_id, {:ok, result}) when is_binary(result) do
    format_task_result(task_id, {:ok, {result, %{}}})
  end

  defp format_task_result(task_id, {:error, :timeout}) do
    %{"status" => "error", "error" => %{"type" => "timeout", "message" => "Task timed out"}, "task_id" => task_id}
  end

  defp format_task_result(task_id, {:error, reason}) when is_binary(reason) do
    %{"status" => "error", "error" => %{"type" => "task_failed", "message" => reason}, "task_id" => task_id}
  end

  defp format_task_result(task_id, {:error, reason}) do
    %{"status" => "error", "error" => %{"type" => "task_failed", "message" => inspect(reason)}, "task_id" => task_id}
  end
end
