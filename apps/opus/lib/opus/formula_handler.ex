# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.FormulaHandler do
  @moduledoc """
  Host function handler for Formula component composition.

  Provides the `cyfr:formula/invoke@0.1.0` WASI host function import that
  enables Formula components to call MCP tools and invoke sub-components
  from within WASM execution.

  ## Unified MCP Dispatch

  All formula capabilities go through `Emissary.MCP.ToolRegistry`. Component
  execution, registry search, build, guides — everything is an MCP tool call.
  Policy enforcement uses `allowed_tools` from the formula's policy.

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

      {imports, tracker_pid} = Opus.FormulaHandler.build_formula_imports(ctx, parent_execution_id,
        root_execution_id: root_execution_id, policy: policy)
      # Merge imports and pass to Wasmex.Components.start_link
      # Call Opus.FormulaHandler.cleanup_registry(tracker_pid) after execution
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Policy
  alias Sanctum.Policy.RestrictedTools

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

  ## Options

  - `:root_execution_id` - The top-level execution ID for routing emit events to the root SSE stream (falls back to `parent_execution_id`)
  - `:policy` - The `Sanctum.Policy` struct for the formula (for limits and allowed_tools)
  - `:authority` - The `Sanctum.Authority` the chain runs under. When present,
    execution dispatch goes through `Opus.Chain` and every other tool through
    `ToolRegistry.call_in_chain/5`; when absent the legacy path runs unchanged.
  - `:declared_needs` / `:activation_digest` - host-derived transition inputs
    for this node's onward invocations
  """
  @spec build_formula_imports(Context.t(), String.t(), keyword()) :: {map(), pid()}
  def build_formula_imports(%Context{} = ctx, parent_execution_id, opts \\ []) do
    root_execution_id = opts[:root_execution_id] || parent_execution_id
    policy = opts[:policy]

    # Parse batch_timeout from policy
    batch_timeout_ms =
      if policy do
        case Policy.parse_duration(policy.batch_timeout) do
          {:ok, ms} -> ms
          {:error, _} -> 300_000
        end
      else
        300_000
      end

    max_tasks = if policy, do: policy.max_concurrent_tasks, else: 10

    {:ok, tracker} =
      Opus.AsyncTracker.start_link(
        parent_execution_id: parent_execution_id,
        max_tasks: max_tasks,
        batch_timeout_ms: batch_timeout_ms
      )

    # Atomics counter for emit sequence numbers
    emit_counter = :atomics.new(1, signed: false)

    authority_opts = [
      authority: opts[:authority],
      declared_needs: opts[:declared_needs],
      activation_digest: opts[:activation_digest]
    ]

    exec_opts =
      [
        parent_execution_id: parent_execution_id,
        root_execution_id: root_execution_id,
        policy: policy,
        emit_counter: emit_counter
      ] ++ authority_opts

    spawn_opts =
      [
        parent_execution_id: parent_execution_id,
        root_execution_id: root_execution_id,
        policy: policy
      ] ++ authority_opts

    imports = %{
      "cyfr:formula/invoke@0.1.0" => %{
        "call" =>
          {:fn,
           fn json_request ->
             execute(json_request, ctx, exec_opts)
           end},
        "spawn" =>
          {:fn,
           fn json_request ->
             handle_spawn(json_request, ctx, tracker, spawn_opts)
           end},
        "await" =>
          {:fn,
           fn task_id ->
             handle_await(task_id, tracker, batch_timeout_ms)
           end},
        "await-all" =>
          {:fn,
           fn json_request ->
             handle_await_all(json_request, tracker, batch_timeout_ms, parent_execution_id)
           end},
        "await-any" =>
          {:fn,
           fn json_request ->
             handle_await_any(json_request, tracker, batch_timeout_ms, parent_execution_id)
           end},
        "poll" =>
          {:fn,
           fn task_id ->
             handle_poll(task_id, tracker)
           end},
        "cancel" =>
          {:fn,
           fn task_id ->
             handle_cancel(task_id, tracker, parent_execution_id)
           end},
        "emit" =>
          {:fn,
           fn json_event ->
             handle_emit(json_event, root_execution_id, emit_counter, ctx)
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
    e in [ArgumentError, RuntimeError] ->
      Logger.warning("[FormulaHandler] cleanup_registry failed: #{inspect(e)}")
      :ok
  end

  def cleanup_registry(_), do: :ok

  @doc """
  Execute an MCP tool call from a formula (synchronous).

  Parses the JSON request, validates against policy, dispatches to
  `Emissary.MCP.ToolRegistry`, and returns a JSON response string.

  When a sub-component call fails due to a setup issue (missing policy,
  missing secret grant), the error is enriched with a `remediation` field
  and a `setup_required` event is emitted to the ExecutionEventBuffer.

  ## Options

  - `:parent_execution_id` (required) - The formula's own execution ID for lineage tracking
  - `:root_execution_id` - The top-level execution ID for routing emit events (falls back to `parent_execution_id`)
  - `:policy` - The `Sanctum.Policy` struct for the formula
  - `:emit_counter` - Atomics ref for emit sequence numbers
  """
  @spec execute(String.t(), Context.t(), keyword()) :: String.t()
  def execute(json_request, %Context{} = ctx, opts \\ []) do
    case authority_execution_request(json_request, opts) do
      {:intercept, action, args} -> dispatch_child_call(action, args, ctx, opts)
      :legacy -> execute_legacy(json_request, ctx, opts)
    end
  end

  # Under an authority, execution dispatch never rides the tool registry:
  # the invocation is decided by the transition relation and executed by
  # Opus.Chain with host-threaded lineage. Everything else — including a
  # parse failure — falls through to the legacy body, whose guest-planed
  # context fails closed at every provider permission gate until the
  # in-chain dispatch entry exists.
  defp authority_execution_request(json_request, opts) do
    with authority when not is_nil(authority) <- opts[:authority],
         {:ok, %{tool: "execution", action: action, args: args}}
         when action in ["run", "run_stream"] <- parse_mcp_request(json_request) do
      {:intercept, action, args}
    else
      _ -> :legacy
    end
  end

  defp dispatch_child_call(action, args, ctx, opts) do
    authority = Keyword.fetch!(opts, :authority)
    parent_execution_id = Keyword.fetch!(opts, :parent_execution_id)
    start_time = System.monotonic_time(:millisecond)

    case Map.get(args, "reference") do
      reference when is_binary(reference) and reference != "" ->
        # Guest-supplied lineage keys never survive: the child's parent and
        # root ids come from this closure, and the input is only what the
        # request's own "input" carried.
        child_opts = child_opts(ctx, opts)
        need = Map.get(args, "need")
        input = Map.get(args, "input") || %{}

        result =
          case action do
            "run" ->
              Opus.Chain.run_child(authority, reference, need, input, child_opts)

            "run_stream" ->
              Opus.Chain.run_child_stream(authority, reference, need, input, child_opts)
          end

        case result do
          {:ok, output} ->
            emit_telemetry(parent_execution_id, "execution.#{action}", :ok, start_time)
            encode_success(normalize_keys(output))

          {:error, reason} ->
            emit_telemetry(parent_execution_id, "execution.#{action}", :error, start_time)
            encode_child_error(reason)
        end

      _ ->
        encode_error(:invalid_request, "execution.#{action} requires a 'reference'")
    end
  end

  defp child_opts(ctx, opts) do
    [
      ctx: ctx,
      parent_execution_id: Keyword.fetch!(opts, :parent_execution_id),
      root_execution_id: opts[:root_execution_id],
      declared_needs: opts[:declared_needs] || [],
      activation_digest: opts[:activation_digest]
    ]
  end

  # Deny reasons map onto the guest error vocabulary the legacy path
  # already speaks, so guests need no second taxonomy.
  defp encode_child_error({:invoke_denied, reason})
       when reason in [:depth_cap, :invoke_budget_exhausted],
       do: encode_error(:resource_limit, "Invocation denied: #{reason}")

  defp encode_child_error({:invoke_denied, {:need, why}}),
    do: encode_error(:invalid_request, "Invocation denied: need #{why}")

  defp encode_child_error({:invoke_denied, reason}),
    do: encode_error(:tool_denied, "Invocation denied: #{inspect(reason)}")

  defp encode_child_error({:invoke_invalid, reason}),
    do: encode_error(:invalid_request, "Invalid invocation: #{inspect(reason)}")

  defp encode_child_error({:invalid_need, need}),
    do: encode_error(:invalid_request, "Invalid need: #{inspect(need)}")

  defp encode_child_error({:invalid_reference, reason}),
    do: encode_error(:invalid_request, "Invalid reference: #{inspect(reason)}")

  defp encode_child_error({:setup_required, payload}) do
    encode_error_with_remediation(
      :setup_required,
      "Dependency cannot be satisfied: #{payload.node_ref}",
      %{
        "issue" => "The consent names a dependency the installed world cannot satisfy",
        "node_ref" => payload.node_ref,
        "need" => payload.need,
        "reason" => to_string(payload.reason)
      }
    )
  end

  defp encode_child_error(reason),
    do: encode_error(:dispatch_error, stringify_reason(reason))

  defp execute_legacy(json_request, %Context{} = ctx, opts) do
    parent_execution_id = Keyword.fetch!(opts, :parent_execution_id)
    root_execution_id = opts[:root_execution_id] || parent_execution_id
    policy = opts[:policy]
    emit_counter = opts[:emit_counter]

    start_time = System.monotonic_time(:millisecond)

    case parse_mcp_request(json_request) do
      {:ok, %{tool: tool, action: action, args: args}} ->
        tool_action =
          if String.contains?(tool, ":"), do: "external.call", else: "#{tool}.#{action}"

        case check_tool_access(policy, tool_action) do
          :allowed ->
            args_with_context =
              maybe_add_parent_id(tool, args, parent_execution_id, root_execution_id)

            args_with_action = Map.put(args_with_context, "action", action)

            case dispatch_tool(tool, ctx, args_with_action, opts, :call) do
              {:ok, result} ->
                emit_telemetry(parent_execution_id, tool_action, :ok, start_time)
                result = maybe_filter_tools_list(tool_action, result, policy)
                encode_success(normalize_keys(result))

              {:error, reason} ->
                emit_telemetry(parent_execution_id, tool_action, :error, start_time)
                reason_str = stringify_reason(reason)

                case Opus.Remediation.analyze(ctx, reason_str) do
                  {:setup_required, remediation} ->
                    maybe_emit_setup_event(
                      root_execution_id,
                      emit_counter,
                      remediation,
                      reason_str,
                      ctx
                    )

                    encode_error_with_remediation(:setup_required, reason_str, remediation)

                  :not_setup_error ->
                    encode_error(:dispatch_error, reason_str)
                end
            end

          {:denied, reason} ->
            emit_telemetry(parent_execution_id, tool_action, :error, start_time)
            encode_error(:tool_denied, reason)
        end

      {:error, type, message} ->
        emit_telemetry(parent_execution_id, "unknown", :error, start_time)
        encode_error(type, message)
    end
  end

  # ============================================================================
  # Host Function Implementations
  # ============================================================================

  defp handle_spawn(json_request, ctx, tracker, opts) do
    case authority_execution_request(json_request, opts) do
      {:intercept, "run", args} -> spawn_child_async(args, ctx, tracker, opts)
      {:intercept, "run_stream", args} -> dispatch_child_call("run_stream", args, ctx, opts)
      :legacy -> handle_spawn_legacy(json_request, ctx, tracker, opts)
    end
  end

  # An async spawn of a child: the transition decision (and its budget
  # charge) happens before the tracker task exists, so a denial consumes
  # no task slot; a tracker refusal after the charge releases it, and the
  # task's own after releases it on completion. A spawned run_stream is
  # already stream-shaped — it returns stream info directly, no task.
  defp spawn_child_async(args, ctx, tracker, opts) do
    authority = Keyword.fetch!(opts, :authority)
    parent_execution_id = Keyword.fetch!(opts, :parent_execution_id)

    case Map.get(args, "reference") do
      reference when is_binary(reference) and reference != "" ->
        child_opts = Keyword.put(child_opts(ctx, opts), :guest_fn, :spawn)
        need = Map.get(args, "need")
        input = Map.get(args, "input") || %{}

        case Opus.Chain.step_invoke(authority, reference, need, child_opts) do
          {:ok, decision} ->
            fun = fn ->
              start_time = System.monotonic_time(:millisecond)

              try do
                case Opus.Chain.execute_child(decision, input, child_opts) do
                  {:ok, output} ->
                    emit_telemetry(parent_execution_id, "execution.run", :ok, start_time)

                    {encode_success(normalize_keys(output)), %{tool: "execution", action: "run"}}

                  {:error, reason} ->
                    emit_telemetry(parent_execution_id, "execution.run", :error, start_time)
                    {encode_child_error(reason), %{tool: "execution", action: "run"}}
                end
              after
                Sanctum.Authority.release_invoke(decision.authority)
              end
            end

            case Opus.AsyncTracker.spawn_task(tracker, fun, "execution.run") do
              {:ok, task_id} ->
                Opus.Telemetry.formula_spawn(parent_execution_id, task_id, "execution.run")
                safe_encode(%{"task_id" => task_id})

              {:error, :max_tasks_exceeded} ->
                Sanctum.Authority.release_invoke(decision.authority)
                encode_error(:resource_limit, "Maximum concurrent tasks exceeded")

              {:error, reason} ->
                Sanctum.Authority.release_invoke(decision.authority)
                encode_error(:spawn_failed, inspect(reason))
            end

          {:error, reason} ->
            encode_child_error(reason)
        end

      _ ->
        encode_error(:invalid_request, "execution.run requires a 'reference'")
    end
  end

  # Non-execution tools from the shared legacy body: under an authority they
  # go through the in-chain chokepoint (plane annotation + transition step +
  # identity conjunct); without one, through the shim's legacy dispatch.
  defp dispatch_tool(tool, ctx, args, opts, guest_fn) do
    case opts[:authority] do
      nil ->
        Opus.AuthorityShim.legacy_tool_call(tool, ctx, args)

      authority ->
        Emissary.MCP.ToolRegistry.call_in_chain(tool, ctx, args, authority, guest_fn: guest_fn)
    end
  end

  defp handle_spawn_legacy(json_request, ctx, tracker, opts) do
    parent_execution_id = Keyword.fetch!(opts, :parent_execution_id)
    root_execution_id = opts[:root_execution_id] || parent_execution_id
    policy = opts[:policy]

    case parse_mcp_request(json_request) do
      {:ok, %{tool: tool, action: action, args: args}} ->
        tool_action =
          if String.contains?(tool, ":"), do: "external.call", else: "#{tool}.#{action}"

        case check_tool_access(policy, tool_action) do
          {:denied, reason} ->
            encode_error(:tool_denied, reason)

          :allowed ->
            fun = fn ->
              start_time = System.monotonic_time(:millisecond)

              args_with_context =
                maybe_add_parent_id(tool, args, parent_execution_id, root_execution_id)

              args_with_action = Map.put(args_with_context, "action", action)

              case dispatch_tool(tool, ctx, args_with_action, opts, :spawn) do
                {:ok, result} ->
                  emit_telemetry(parent_execution_id, tool_action, :ok, start_time)
                  {encode_success(normalize_keys(result)), %{tool: tool, action: action}}

                {:error, reason} ->
                  emit_telemetry(parent_execution_id, tool_action, :error, start_time)

                  {encode_error(:dispatch_error, stringify_reason(reason)),
                   %{tool: tool, action: action}}
              end
            end

            case Opus.AsyncTracker.spawn_task(tracker, fun, tool_action) do
              {:ok, task_id} ->
                Opus.Telemetry.formula_spawn(parent_execution_id, task_id, tool_action)
                safe_encode(%{"task_id" => task_id})

              {:error, :max_tasks_exceeded} ->
                encode_error(:resource_limit, "Maximum concurrent tasks exceeded")

              {:error, reason} ->
                encode_error(:spawn_failed, inspect(reason))
            end
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

  defp handle_await_all(json_request, tracker, timeout_ms, parent_execution_id) do
    case Jason.decode(json_request) do
      {:ok, %{"task_ids" => task_ids}} when is_list(task_ids) and task_ids != [] ->
        start = System.monotonic_time(:millisecond)

        case Opus.AsyncTracker.await_all(tracker, task_ids, timeout_ms) do
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

  defp handle_await_any(json_request, tracker, timeout_ms, parent_execution_id) do
    case Jason.decode(json_request) do
      {:ok, %{"task_ids" => task_ids}} when is_list(task_ids) and task_ids != [] ->
        start = System.monotonic_time(:millisecond)

        case Opus.AsyncTracker.await_any(tracker, task_ids, timeout_ms) do
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
    case Opus.AsyncTracker.poll(tracker, task_id) do
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
    case Opus.AsyncTracker.cancel_task(tracker, task_id) do
      :ok ->
        Opus.Telemetry.formula_cancel(parent_execution_id, task_id)
        safe_encode(%{"cancelled" => true, "task_id" => task_id})

      {:error, :already_completed} ->
        encode_error(:invalid_request, "Task #{task_id} already completed")

      {:error, :unknown_task} ->
        encode_error(:invalid_request, "Unknown task_id: #{task_id}")

      {:error, reason} ->
        encode_error(:cancel_failed, inspect(reason))
    end
  end

  defp handle_emit(json_event, execution_id, counter, ctx) do
    case Jason.decode(json_event) do
      {:ok, data} ->
        seq = :atomics.add_get(counter, 1, 1)
        Opus.ExecutionEventBuffer.push(execution_id, data, seq, ctx)
        Opus.Telemetry.formula_emit(execution_id, seq)
        safe_encode(%{"ok" => true, "sequence" => seq})

      {:error, _} ->
        safe_encode(%{"ok" => true})
    end
  end

  # ============================================================================
  # Private: Tools List Filtering
  # ============================================================================

  # When a formula calls tools.list, filter the result to only show
  # tools and actions that the formula can actually use.
  defp maybe_filter_tools_list("tools.list", %{tools: tools} = result, policy)
       when is_list(tools) do
    %{result | tools: RestrictedTools.filter_tool_list(:formula, tools, policy)}
  end

  defp maybe_filter_tools_list(_tool_action, result, _policy), do: result

  # ============================================================================
  # Private: Tool Access Check
  # ============================================================================

  defp check_tool_access(policy, tool_action) do
    # Hard block: restricted tools are never allowed for formulas
    case RestrictedTools.check(:formula, tool_action) do
      {:restricted, pattern} ->
        {:denied,
         "Tool '#{tool_action}' is restricted for formula components (matches '#{pattern}')"}

      :allowed ->
        # Soft check: policy allowlist (nil policy = allow all)
        if policy == nil or Policy.allows_tool?(policy, tool_action) do
          :allowed
        else
          {:denied, "Tool '#{tool_action}' not in allowed_tools"}
        end
    end
  end

  # ============================================================================
  # Private: Request Parsing (MCP format)
  # ============================================================================

  defp parse_mcp_request(json_string) do
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

  # ============================================================================
  # Private: Context Threading
  # ============================================================================

  defp maybe_add_parent_id("execution", args, parent_id, root_id) do
    args = Map.put(args, "parent_execution_id", parent_id)
    if root_id, do: Map.put(args, "root_execution_id", root_id), else: args
  end

  defp maybe_add_parent_id(_tool, args, _parent_id, _root_id), do: args

  # ============================================================================
  # Private: Response Encoding
  # ============================================================================

  defp safe_encode(data) do
    case Jason.encode(data) do
      {:ok, json} -> json
      {:error, _} -> ~s({"error":{"type":"encoding_error","message":"Failed to encode response"}})
    end
  end

  defp encode_success(output) do
    safe_encode(%{
      "status" => "completed",
      "output" => output
    })
  end

  @doc false
  def encode_error(type, message) do
    safe_encode(%{
      "error" => %{
        "type" => to_string(type),
        "message" => stringify_reason(message)
      }
    })
  end

  defp encode_error_with_remediation(type, message, remediation) do
    safe_encode(%{
      "error" => %{
        "type" => to_string(type),
        "message" => stringify_reason(message),
        "remediation" => remediation
      }
    })
  end

  defp maybe_emit_setup_event(target_id, emit_counter, remediation, message, ctx) do
    seq =
      if emit_counter do
        :atomics.add_get(emit_counter, 1, 1)
      else
        System.unique_integer([:positive])
      end

    Opus.ExecutionEventBuffer.push(
      target_id,
      %{
        "kind" => "setup_required",
        "component_ref" => remediation["component_ref"],
        "issues" => remediation["issues"],
        "setup_command" => remediation["setup_command"],
        "message" => message
      },
      seq,
      ctx
    )
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
      "error" => %{"type" => "task_failed", "message" => inspect(reason)},
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

  # ============================================================================
  # Private: Key Normalization
  # ============================================================================

  # Normalize atom keys to strings for JSON encoding back to WASM
  # Structs (DateTime, URI, etc.) must pass through unchanged — they are not
  # plain maps and don't implement Enumerable.
  defp normalize_keys(%_{} = struct), do: struct

  defp normalize_keys(data) when is_map(data) do
    data
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_keys(v)}
      {k, v} -> {k, normalize_keys(v)}
    end)
    |> Map.new()
  end

  defp normalize_keys(data) when is_list(data) do
    Enum.map(data, &normalize_keys/1)
  end

  defp normalize_keys(data), do: data

  defp stringify_reason(reason) when is_binary(reason), do: reason
  defp stringify_reason(reason), do: inspect(reason)
end
