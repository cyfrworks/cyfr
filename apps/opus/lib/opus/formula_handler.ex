defmodule Opus.FormulaHandler do
  @moduledoc """
  Host function handler for Formula component composition.

  Provides the `cyfr:formula/invoke@0.1.0` WASI host function import that
  enables Formula components to invoke sub-components (Reagents, Catalysts,
  or other Formulas) from within WASM execution.

  ## Concurrency Model

  WASM is single-threaded. When a Formula's WASM calls the `invoke` host
  function, it blocks until Opus runs the sub-component via `Executor.run/4`
  and returns the result. The formula controls orchestration logic; Opus
  executes each invocation synchronously via `call` or in parallel via
  `call-batch` + `poll` + `close`.

  For parallel invocation, `call-batch` spawns all sub-invocations concurrently,
  returning a batch handle. The formula polls for results via `poll` or `poll-all`,
  and cleans up with `close`. This follows the same spawn + Agent + Arca.Cache
  pattern proven by `HttpStreamHandler`.

  ## Logging Model

  Sub-invocations go through `Executor.run/4` which writes execution records
  via `Arca.MCP.handle("execution", ...)` → SQLite. Every sub-execution gets
  its own `exec_<uuid7>` ID, shares the parent's `request_id` for correlation,
  and stores `parent_execution_id` for direct lineage.

  ## Architecture

  Follows the same pattern as `HttpHandler` (`cyfr:http/fetch@0.1.0`) and
  the secrets import (`cyfr:secrets/read@0.1.0`). The host function is
  registered as a Wasmex import that the WASM component calls synchronously.
  All errors are caught and returned as JSON (never raised into WASM).

  ## Request Format (JSON string from WASM)

      {
        "reference": {"registry": "name:version"} | {"local": "path"} | {"arca": "path"} | {"oci": "ref"},
        "input": {...},
        "type": "reagent" | "catalyst" | "formula"
      }

  ## Response Format (JSON string returned to WASM)

  On success:
      {"status": "completed", "output": {...}}

  On error:
      {"error": {"type": "...", "message": "..."}}

  ## Usage

      {imports, exec_ref} = Opus.FormulaHandler.build_formula_imports(ctx, parent_execution_id)
      # Merge imports with other imports and pass to Wasmex.Components.start_link
      # Call Opus.FormulaHandler.cleanup_registry(exec_ref) after execution
  """

  require Logger

  alias Sanctum.Context

  # 5 minutes — safety net for cache TTL on batch state
  @batch_timeout_ms 300_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:formula/invoke@0.1.0` host function.

  Returns a map suitable for merging into `Wasmex.Components.start_link` opts.
  Registers all five invoke functions: `call`, `call-batch`, `poll`, `poll-all`, `close`.

  ## Parameters

  - `ctx` - The execution `Sanctum.Context` (shared with sub-executions)
  - `parent_execution_id` - The formula's own execution ID for lineage tracking

  ## Returns

  A `{imports_map, exec_ref}` tuple. The imports map contains the
  `"cyfr:formula/invoke@0.1.0"` namespace with all invoke functions.
  The `exec_ref` must be passed to `cleanup_registry/1` after WASM
  execution completes to prevent Agent process leaks.
  """
  @spec build_formula_imports(Context.t(), String.t()) :: {map(), String.t()}
  def build_formula_imports(%Context{} = ctx, parent_execution_id) do
    exec_ref = create_exec_ref()

    imports = %{
      "cyfr:formula/invoke@0.1.0" => %{
        "call" => {:fn, fn json_request ->
          execute(json_request, ctx, parent_execution_id)
        end},
        "call-batch" => {:fn, fn json_request ->
          call_batch(json_request, ctx, parent_execution_id, exec_ref)
        end},
        "poll" => {:fn, fn json_request ->
          poll(json_request, exec_ref)
        end},
        "poll-all" => {:fn, fn json_request ->
          poll_all(json_request, exec_ref)
        end},
        "close" => {:fn, fn json_request ->
          close(json_request, exec_ref)
        end}
      }
    }

    {imports, exec_ref}
  end

  @doc """
  Clean up all batch state for a given exec_ref.

  Matches the `HttpStreamHandler.cleanup_registry/1` pattern. Finds all
  batch cache entries for the exec_ref and cleans up each one. Called as
  a safety net if WASM never calls `close`.
  """
  @spec cleanup_registry(String.t()) :: :ok
  def cleanup_registry(exec_ref) do
    batches = Arca.Cache.match({:formula_batch, exec_ref, :_})

    for {{:formula_batch, ^exec_ref, _handle} = key, batch_state} <- batches do
      cleanup_batch(batch_state)
      Arca.Cache.invalidate(key)
    end

    :ok
  end

  @doc """
  Execute a sub-component invocation from a formula.

  Parses the JSON request, invokes via `Opus.Executor.run/4`, and returns
  a JSON response string. All errors are caught and returned as JSON
  (never raised into WASM), matching the `HttpHandler.execute/4` pattern.

  ## Parameters

  - `json_request` - JSON string with reference, input, and type
  - `ctx` - The parent formula's execution context
  - `parent_execution_id` - The parent formula's execution ID
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
  # Parallel Invocation: call-batch / poll / poll-all / close
  # ============================================================================

  @doc false
  def call_batch(json_request, %Context{} = ctx, parent_execution_id, exec_ref) do
    case Jason.decode(json_request) do
      {:ok, %{"invocations" => invocations}} when is_list(invocations) and invocations != [] ->
        # Parse and validate each invocation
        parsed = Enum.map(invocations, fn inv ->
          inv_json = Jason.encode!(inv)
          parse_request(inv_json)
        end)

        case Enum.find(parsed, fn
          {:error, _, _} -> true
          _ -> false
        end) do
          {:error, type, message} ->
            encode_error(type, message)

          nil ->
            # All parsed successfully — launch batch
            count = length(parsed)
            handle = create_exec_ref()

            # Agent holds results: list of :pending | {:done, json_string}
            {:ok, agent} = Agent.start_link(fn ->
              List.duplicate(:pending, count)
            end)

            # Spawn each invocation — must use spawn/1 not Task.async
            # (Task.async crashes the Wasmex.Components GenServer)
            pids = parsed
              |> Enum.with_index()
              |> Enum.map(fn {{:ok, %{reference: reference, input: input, type: type}}, index} ->
                spawn(fn ->
                  result = invoke_component(ctx, reference, input, type, parent_execution_id)
                  Agent.update(agent, fn results ->
                    List.replace_at(results, index, {:done, result})
                  end)
                end)
              end)

            # Store batch state in cache (poll_count tracks poll calls to prevent infinite loops)
            batch_state = %{
              agent: agent,
              pids: pids,
              started_at: System.monotonic_time(:millisecond),
              poll_count: :counters.new(1, [])
            }
            Arca.Cache.put({:formula_batch, exec_ref, handle}, batch_state, @batch_timeout_ms)

            # Emit telemetry
            Opus.Telemetry.formula_batch(parent_execution_id, handle, count)

            Jason.encode!(%{"batch" => handle, "count" => count})
        end

      {:ok, %{"invocations" => []}} ->
        encode_error(:invalid_request, "invocations array must be non-empty")

      {:ok, %{"invocations" => _}} ->
        encode_error(:invalid_request, "invocations must be an array")

      {:ok, _} ->
        encode_error(:invalid_request, "Request must include 'invocations' array")

      {:error, _} ->
        encode_error(:invalid_json, "Invalid JSON request")
    end
  end

  @doc false
  def poll(json_request, exec_ref) do
    case Jason.decode(json_request) do
      {:ok, %{"batch" => handle, "index" => index}} when is_integer(index) ->
        case lookup_batch(exec_ref, handle) do
          {:ok, batch_state} ->
            cond do
              batch_expired?(batch_state) ->
                cleanup_batch(batch_state)
                Arca.Cache.invalidate({:formula_batch, exec_ref, handle})
                encode_error(:timeout, "Batch exceeded #{@batch_timeout_ms}ms timeout")

              poll_limit_exceeded?(batch_state) ->
                cleanup_batch(batch_state)
                Arca.Cache.invalidate({:formula_batch, exec_ref, handle})
                encode_error(:poll_limit_exceeded, "Maximum poll calls exceeded. Ensure your polling loop has a termination condition (check 'all_done' field).")

              true ->
                increment_poll_count(batch_state)
                results = Agent.get(batch_state.agent, & &1)

                if index < 0 or index >= length(results) do
                  encode_error(:invalid_index, "Index #{index} out of range (0..#{length(results) - 1})")
                else
                  format_single_result(Enum.at(results, index))
                end
            end

          {:error, reason} ->
            encode_error(:invalid_handle, reason)
        end

      {:ok, _} ->
        encode_error(:invalid_request, "Request must include 'batch' (string) and 'index' (integer)")

      {:error, _} ->
        encode_error(:invalid_json, "Invalid JSON request")
    end
  end

  @doc false
  def poll_all(json_request, exec_ref) do
    case Jason.decode(json_request) do
      {:ok, %{"batch" => handle}} ->
        case lookup_batch(exec_ref, handle) do
          {:ok, batch_state} ->
            cond do
              batch_expired?(batch_state) ->
                cleanup_batch(batch_state)
                Arca.Cache.invalidate({:formula_batch, exec_ref, handle})
                encode_error(:timeout, "Batch exceeded #{@batch_timeout_ms}ms timeout")

              poll_limit_exceeded?(batch_state) ->
                cleanup_batch(batch_state)
                Arca.Cache.invalidate({:formula_batch, exec_ref, handle})
                encode_error(:poll_limit_exceeded, "Maximum poll calls exceeded. Ensure your polling loop has a termination condition (check 'all_done' field).")

              true ->
                increment_poll_count(batch_state)
                results = Agent.get(batch_state.agent, & &1)

                formatted = results
                  |> Enum.with_index()
                  |> Enum.map(fn {result, index} ->
                    parsed = Jason.decode!(format_single_result(result))
                    Map.put(parsed, "index", index)
                  end)

                all_done = Enum.all?(results, fn
                  {:done, _} -> true
                  _ -> false
                end)

                Jason.encode!(%{"results" => formatted, "all_done" => all_done})
            end

          {:error, reason} ->
            encode_error(:invalid_handle, reason)
        end

      {:ok, _} ->
        encode_error(:invalid_request, "Request must include 'batch' (string)")

      {:error, _} ->
        encode_error(:invalid_json, "Invalid JSON request")
    end
  end

  @doc false
  def close(json_request, exec_ref) do
    case Jason.decode(json_request) do
      {:ok, %{"batch" => handle}} ->
        case Arca.Cache.get({:formula_batch, exec_ref, handle}) do
          {:ok, batch_state} ->
            cleanup_batch(batch_state)
            Arca.Cache.invalidate({:formula_batch, exec_ref, handle})
            Jason.encode!(%{"ok" => true})

          :miss ->
            # Idempotent — unknown handle is OK
            Jason.encode!(%{"ok" => true})
        end

      {:ok, _} ->
        # Still return ok for malformed requests — close is idempotent
        Jason.encode!(%{"ok" => true})

      {:error, _} ->
        Jason.encode!(%{"ok" => true})
    end
  end

  # ============================================================================
  # Private: Batch Helpers
  # ============================================================================

  defp create_exec_ref do
    Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end

  defp lookup_batch(exec_ref, handle) do
    case Arca.Cache.get({:formula_batch, exec_ref, handle}) do
      {:ok, batch_state} -> {:ok, batch_state}
      :miss -> {:error, "Batch handle not found"}
    end
  end

  defp batch_expired?(%{started_at: started_at}) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    elapsed > @batch_timeout_ms
  end

  defp poll_limit_exceeded?(%{poll_count: poll_count}) do
    max = Application.get_env(:opus, :max_poll_calls, 10_000)
    :counters.get(poll_count, 1) >= max
  end

  # Handles batch state from before poll_count was added (e.g., in-flight batches during upgrade)
  defp poll_limit_exceeded?(_batch_state), do: false

  defp increment_poll_count(%{poll_count: poll_count}) do
    :counters.add(poll_count, 1, 1)
  end

  defp increment_poll_count(_batch_state), do: :ok

  defp cleanup_batch(%{agent: agent, pids: pids}) do
    # Kill any still-running spawned processes
    for pid <- pids, Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    # Stop the results Agent
    if Process.alive?(agent), do: Agent.stop(agent)
  end

  defp format_single_result(:pending) do
    Jason.encode!(%{"status" => "pending"})
  end

  defp format_single_result({:done, json_string}) do
    case Jason.decode(json_string) do
      {:ok, %{"error" => error}} ->
        Jason.encode!(%{"status" => "error", "error" => error})

      {:ok, %{"status" => "completed", "output" => output}} ->
        Jason.encode!(%{"status" => "completed", "output" => output})

      _ ->
        Jason.encode!(%{"status" => "error", "error" => %{"type" => "unknown", "message" => "Unexpected result format"}})
    end
  end

  # ============================================================================
  # Private: Request Parsing
  # ============================================================================

  defp parse_request(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"reference" => reference, "input" => input} = req} when is_map(reference) and is_map(input) ->
        type = req["type"] || "reagent"

        case Opus.ComponentType.parse(type) do
          {:ok, component_type} ->
            {:ok, %{reference: reference, input: input, type: component_type}}
          {:error, reason} ->
            {:error, :invalid_request, to_string(reason)}
        end

      {:ok, %{"reference" => _}} ->
        {:error, :invalid_request, "Request must include 'reference' (map) and 'input' (map)"}

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
    # Derive a display ref for telemetry (best-effort, no parsing needed)
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

  defp telemetry_ref(%{"registry" => ref}), do: ref
  defp telemetry_ref(%{"local" => path}), do: path
  defp telemetry_ref(%{"arca" => path}), do: path
  defp telemetry_ref(%{"oci" => ref}), do: ref
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
end
