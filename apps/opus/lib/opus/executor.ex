defmodule Opus.Executor do
  @moduledoc """
  High-level execution facade for WASM components.

  This module provides a simplified API for executing WASM components,
  handling reference resolution, signature verification, telemetry,
  and crash-resilient record keeping.

  ## Usage

      ctx = Sanctum.Context.local()
      reference = "reagent:local.my-tool:0.1.0"
      input = %{"a" => 5, "b" => 10}

      {:ok, result} = Opus.Executor.run(ctx, reference, input)
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

  alias Sanctum.Context
  alias Opus.ExecutionRecord
  alias Opus.ExecutionEventBuffer

  # Default timeouts per component type
  @default_timeout_ms %{catalyst: 180_000, formula: 300_000, reagent: 60_000}

  @doc """
  Execute a WASM component with the given input.

  ## Parameters

  - `ctx` - Sanctum execution context
  - `reference` - Component reference string (e.g., "catalyst:local.claude:0.2.0")
  - `input` - Input data map to pass to the component
  - `opts` - Execution options

  ## Options

  - `:type` - Component type: `:catalyst`, `:reagent`, or `:formula`. Defaults to `:reagent`.
  - `:verify` - Optional verification requirements: `%{identity: string, issuer: string}`
  - `:max_memory_bytes` - Memory limit for execution. Defaults to 64MB.
  - `:fuel_limit` - Fuel limit for CPU time. Defaults to 100M instructions.

  ## Returns

  - `{:ok, result}` - Execution succeeded with result map
  - `{:error, reason}` - Execution failed with error message
  """
  @spec run(Context.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(%Context{} = ctx, reference, input, opts \\ []) when is_binary(reference) and is_map(input) do
    # Resolve the reference via Compendium inspect to get component_ref,
    # type, digest, and cache the result for blob fetching.
    case inspect_component(ctx, reference) do
      {:ok, component_ref, extracted_type, component} ->
        raw_type = extracted_type || opts[:type]
        case parse_component_type(raw_type) do
          {:ok, component_type} ->
            do_run(ctx, reference, input, opts, component_type, component_ref, component)
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_run(ctx, reference, input, opts, component_type, component_ref, component) do

    # Create initial execution record
    record_opts = [
      component_type: component_type,
      parent_execution_id: opts[:parent_execution_id]
    ]
    record_opts = if opts[:execution_id], do: [{:execution_id, opts[:execution_id]} | record_opts], else: record_opts
    record = ExecutionRecord.new(ctx, reference, input, record_opts)

    # Track whether started.json was written
    started_written = :atomics.new(1, signed: false)

    try do
      with {:ok, exec_opts} <- Opus.PolicyEnforcer.build_execution_opts(ctx, component_ref, component_type),
           :ok <- check_dependency_satisfaction(ctx, component_type, component),
           {:ok, _input_json} <- validate_input_size(input, exec_opts),
           :ok <- check_rate_limit_with_retry(ctx, component_ref, exec_opts),
           {:ok, wasm_bytes} <- fetch_component_bytes(ctx, component),
           component_digest = compute_digest(wasm_bytes),
           # Optional integrity check: verify fetched bytes match registry digest
           :ok <- verify_integrity(component, component_digest, reference),
           # Capture host policy snapshot for forensic replay (PRD §5.6)
           host_policy = build_host_policy_snapshot(exec_opts),
           record = %{record | component_digest: component_digest, host_policy: host_policy},
           :ok <- maybe_verify_signature(reference, opts[:verify], component),
           :ok <- ExecutionRecord.write_started(record),
           _ = :atomics.put(started_written, 1, 1),
           _ = Opus.Telemetry.execute_start(record),
           # Pre-resolve all granted secrets once for this execution (eliminates per-call file I/O)
           {:ok, preloaded_secrets} <- resolve_secrets(ctx, component_ref),
           # Pass policy, ctx, reference, and digest for runtime
           policy = Keyword.get(exec_opts, :policy),
           digest = component[:digest] || component["digest"],
           exec_opts_final = Keyword.merge(exec_opts, [
             preloaded_secrets: preloaded_secrets,
             component_ref: component_ref,
             policy: policy,
             ctx: ctx,
             execution_id: record.id,
             reference: reference,
             digest: digest
           ]),
           {:ok, {output, exec_metadata}} <- execute_wasm(wasm_bytes, input, exec_opts_final, opts) do
        finalize_execution(
          record, output, preloaded_secrets, exec_metadata,
          component_type, component_digest, reference, ctx,
          host_policy, component, started_written, policy
        )
      else
        {:error, reason} when is_binary(reason) ->
          maybe_emit_setup_event(ctx, reason, opts)
          handle_failure(record, reason, started_written)

        {:error, reason} ->
          handle_failure(record, "Execution failed: #{inspect(reason)}", started_written)
      end
    rescue
      e ->
        handle_failure(record, "Execution error: #{Exception.message(e)}", started_written)
    end
  end

  # ===========================================================================
  # Finalization
  # ===========================================================================

  defp finalize_execution(record, output, preloaded_secrets, exec_metadata,
         component_type, component_digest, reference, ctx,
         host_policy, component, started_written, policy) do
    # Mask secrets in output using the already-resolved values (no re-decryption)
    secret_values = Map.values(preloaded_secrets)
    masked_output = Opus.SecretMasker.mask(output, secret_values)

    # Detect application-level errors in output (e.g. formula returning {"error": {...}})
    app_error = detect_application_error(masked_output)

    if app_error do
      handle_failure(record, app_error, started_written)
    else

    # Validate output size against policy limits
    output_json = Jason.encode!(masked_output)
    max_response = if policy, do: policy.max_response_size, else: 5_242_880

    if byte_size(output_json) > max_response do
      handle_failure(record, "Output size (#{byte_size(output_json)} bytes) exceeds maximum (#{max_response} bytes)", started_written)
    else
      # Complete the record with masked output
      completed_record = ExecutionRecord.complete(record, masked_output)
      audit_error = case ExecutionRecord.write_completed(completed_record) do
        :ok -> nil
        {:error, reason} ->
          Logger.error("[Opus.Executor] Failed to write completed record #{completed_record.id}: #{inspect(reason)}. " <>
            "Audit trail is incomplete — this execution will appear as 'running' in logs.")
          :telemetry.execute(
            [:cyfr, :opus, :audit_error],
            %{system_time: System.system_time()},
            %{execution_id: completed_record.id, phase: :completed, reason: inspect(reason)}
          )
          inspect(reason)
      end
      # Pass execution metadata (memory_bytes) to telemetry
      Opus.Telemetry.execute_stop(completed_record, exec_metadata)

      # Push terminal event so SSE/LiveView subscribers know execution is done
      Opus.ExecutionEventBuffer.push_terminal(completed_record.id, "complete",
        %{status: "completed", duration_ms: completed_record.duration_ms}, 999_999_999)

      result = %{
         status: :completed,
         output: output,
         metadata: %{
           execution_id: completed_record.id,
           duration_ms: completed_record.duration_ms,
           component_type: component_type,
           component_digest: component_digest,
           user_id: ctx.user_id,
           reference: reference,
           policy_applied: host_policy,
           signature_verified: component["signature_verified"] || false
         }
       }

      result = if audit_error, do: put_in(result, [:metadata, :audit_error], audit_error), else: result
      {:ok, result}
    end
    end # app_error check
  end

  # Detect application-level errors in component output.
  # Returns error message string if output indicates failure, nil otherwise.
  defp detect_application_error(output) when is_map(output) do
    case output do
      %{"error" => %{"message" => msg}} when is_binary(msg) -> msg
      %{"error" => %{"message" => msg}} -> inspect(msg)
      %{"error" => msg} when is_binary(msg) -> msg
      %{"error" => err} when is_map(err) -> inspect(err)
      _ -> nil
    end
  end

  defp detect_application_error(_), do: nil

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # Resolve a component reference string via Compendium inspect.
  # Returns {:ok, component_ref, component_type, component_map}.
  # Results are cached for 5 minutes to avoid repeated MCP roundtrips.
  defp inspect_component(ctx, reference) do
    cache_key = {:component_meta, reference}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} ->
        {:ok, cached["component_ref"], cached["type"], cached}

      :miss ->
        case Compendium.MCP.handle("component", ctx, %{"action" => "inspect", "reference" => reference}) do
          {:ok, component} ->
            Arca.Cache.put(cache_key, component, :timer.minutes(5))
            {:ok, component["component_ref"], component["type"], component}
          {:error, reason} ->
            {:error, "Failed to resolve component '#{reference}': #{reason}"}
        end
    end
  end

  # Fetch WASM bytes from Compendium blob store using the digest from inspect.
  # Bytes are content-addressed by digest — immutable, no invalidation needed.
  # Cached for 10 minutes to avoid repeated MCP roundtrips and base64 decoding.
  defp fetch_component_bytes(ctx, component) do
    digest = component[:digest] || component["digest"]
    Logger.debug("[fetch_component_bytes] digest=#{inspect(digest)}, component_keys=#{inspect(Map.keys(component))}")
    cache_key = {:wasm_bytes, digest}

    case Arca.Cache.get(cache_key) do
      {:ok, bytes} ->
        {:ok, bytes}

      :miss ->
        case Compendium.MCP.handle("component", ctx, %{"action" => "get_blob", "digest" => digest}) do
          {:ok, %{bytes: b64_bytes}} ->
            bytes = Base.decode64!(b64_bytes)
            Arca.Cache.put(cache_key, bytes, :timer.minutes(10))
            {:ok, bytes}
          {:error, reason} ->
            {:error, "Failed to fetch component bytes: #{reason}"}
        end
    end
  end

  # Verify that fetched bytes match the digest from the registry.
  defp verify_integrity(component, actual_digest, reference) do
    expected_digest = component[:digest] || component["digest"]

    cond do
      is_nil(expected_digest) ->
        # No digest in registry — skip integrity check
        :ok

      actual_digest == "sha256:" <> expected_digest ->
        :ok

      actual_digest == expected_digest ->
        :ok

      true ->
        {:error,
         "Integrity check failed for #{reference}. " <>
           "Expected: #{expected_digest}, Got: #{actual_digest}. " <>
           "Component may have been modified. Re-register with `cyfr register`."}
    end
  end

  # Validate input size against policy limits.
  # Returns {:ok, encoded_json} on success so callers can reuse the encoded form.
  defp validate_input_size(input, exec_opts) do
    policy = Keyword.get(exec_opts, :policy)
    max_size = if policy, do: policy.max_request_size, else: 1_048_576

    case Jason.encode(input) do
      {:ok, input_json} ->
        size = byte_size(input_json)

        if size > max_size do
          {:error, "Input size (#{size} bytes) exceeds maximum (#{max_size} bytes)"}
        else
          {:ok, input_json}
        end

      {:error, reason} ->
        {:error, "Input encoding failed: #{inspect(reason)}. Input must be JSON-serializable."}
    end
  end

  # Check that all required static dependencies are satisfied for formula components.
  # Non-formula types skip this check. Formulas with no static deps declared also pass
  # (supports dynamic-discovery pattern).
  defp check_dependency_satisfaction(_ctx, component_type, _component)
       when component_type != :formula,
       do: :ok

  defp check_dependency_satisfaction(_ctx, :formula, nil), do: :ok

  defp check_dependency_satisfaction(ctx, :formula, component) do
    manifest = component[:manifest] || component["manifest"]

    manifest =
      case manifest do
        nil -> %{}
        m when is_map(m) -> m
        m when is_binary(m) ->
          case Jason.decode(m) do
            {:ok, decoded} -> decoded
            _ -> %{}
          end
      end

    case Compendium.DependencyResolver.extract_from_manifest(manifest, component[:id] || "") do
      {:ok, []} ->
        :ok

      {:ok, deps} ->
        availability = Compendium.DependencyResolver.classify_availability(ctx, deps)

        if availability.all_satisfied do
          :ok
        else
          missing_refs = Enum.map(availability.missing, & &1[:dependency_ref])

          {:error,
           "Missing required dependencies: #{Enum.join(missing_refs, ", ")}. " <>
             "Run 'cyfr pull <ref>' to resolve."}
        end

      {:error, reason} ->
        {:error, "Failed to parse formula dependencies: #{inspect(reason)}"}
    end
  end

  # Check rate limit before execution (via MCP boundary)
  @max_rate_limit_retries 3

  defp check_rate_limit_with_retry(ctx, component_ref, exec_opts, attempt \\ 1) do
    case check_rate_limit(ctx, component_ref, exec_opts) do
      :ok ->
        :ok

      {:error, msg} = error when attempt <= @max_rate_limit_retries ->
        case Regex.run(~r/Retry in (\d+)s/, msg) do
          [_, seconds] ->
            wait_ms = min(String.to_integer(seconds) * 1000, 30_000)
            Logger.debug("[Opus.Executor] Rate limited (attempt #{attempt}/#{@max_rate_limit_retries}), waiting #{wait_ms}ms")
            Process.sleep(wait_ms)
            check_rate_limit_with_retry(ctx, component_ref, exec_opts, attempt + 1)

          _ ->
            error
        end

      error ->
        error
    end
  end

  defp check_rate_limit(ctx, component_ref, _exec_opts) do
    case Sanctum.MCP.handle("policy", ctx, %{"action" => "check_rate_limit", "component_ref" => component_ref}) do
      {:ok, %{allowed: true}} -> :ok
      {:ok, %{allowed: false, retry_after: retry_after}} -> {:error, "Rate limit exceeded. Retry in #{div(retry_after, 1000)}s"}
      {:error, reason} -> {:error, "Rate limit check failed for #{component_ref}: #{reason}. Check policy configuration."}
    end
  end

  # Resolve all granted secrets for a component into a map (via MCP boundary),
  # or return empty map if component_ref is unavailable (reagents without secrets).
  defp resolve_secrets(_ctx, nil), do: {:ok, %{}}
  defp resolve_secrets(ctx, component_ref) do
    case Sanctum.MCP.handle("secret", ctx, %{"action" => "resolve_granted", "component_ref" => component_ref}) do
      {:ok, %{secrets: _secrets, failed: failed}} when failed != [] ->
        {:error, "Failed to resolve #{length(failed)} secret(s) for #{component_ref}: #{Enum.join(failed, ", ")}. " <>
          "Grant access with: cyfr secret grant <secret-name> #{component_ref}"}
      {:ok, %{secrets: secrets}} -> {:ok, secrets}
      {:error, reason} -> {:error, "Failed to resolve secrets: #{reason}"}
    end
  end

  defp parse_component_type(nil), do: {:ok, :reagent}
  defp parse_component_type(type) when is_atom(type) do
    if Opus.ComponentType.valid?(type) do
      {:ok, type}
    else
      {:error, "Invalid component type: #{inspect(type)}. Must be one of: catalyst, reagent, formula"}
    end
  end
  defp parse_component_type(type) when is_binary(type) do
    Opus.ComponentType.parse(type)
  end

  defp compute_digest(wasm_bytes) when is_binary(wasm_bytes) do
    hash = :crypto.hash(:sha256, wasm_bytes)
    hex = Base.encode16(hash, case: :lower)
    "sha256:#{hex}"
  end

  defp maybe_verify_signature(_reference, nil, _component), do: :ok

  defp maybe_verify_signature(_reference, verify, component) when is_map(verify) do
    identity = verify["identity"] || verify[:identity]
    issuer = verify["issuer"] || verify[:issuer]

    case Opus.SignatureVerifier.verify(component, identity, issuer) do
      :ok -> :ok
      {:error, reason} -> {:error, "Signature verification failed: #{reason}"}
    end
  end

  defp execute_wasm(wasm_bytes, input, exec_opts, opts) do
    component_type = Keyword.get(exec_opts, :component_type, :reagent)
    priority = if component_type == :catalyst, do: :normal, else: :high

    type_default = Map.get(@default_timeout_ms, component_type, 60_000)
    timeout_ms = exec_opts[:timeout_ms] || opts[:timeout_ms] || type_default
    semaphore_timeout = min(timeout_ms, 30_000)

    case Opus.ExecutionSemaphore.acquire(semaphore_timeout, priority) do
      :ok ->
        try do
          runtime_opts =
            exec_opts
            |> Keyword.merge(opts)
            |> Keyword.take([:component_type, :max_memory_bytes, :preloaded_secrets, :component_ref, :policy, :ctx, :execution_id, :reference, :digest])

          execute_with_timeout(wasm_bytes, input, runtime_opts, timeout_ms)
        after
          Opus.ExecutionSemaphore.release()
        end

      {:error, :queue_full} ->
        {:error, "Server at maximum concurrent executions. Retry later."}
    end
  end

  # Execute WASM with wall-clock timeout enforcement.
  # This ensures long-running or stuck executions are terminated.
  # Uses spawn-based execution to avoid crashes propagating to caller.
  # Returns {:ok, {output, metadata}} or {:error, reason}
  defp execute_with_timeout(wasm_bytes, input, runtime_opts, timeout_ms) do
    caller = self()
    ref = make_ref()
    start_time = System.monotonic_time(:millisecond)

    # Pass notify_cleanup_refs so Runtime sends us cleanup refs before executing.
    # On timeout kill, we use these to clean up orphaned Agent processes.
    runtime_opts_with_notify = Keyword.put(runtime_opts, :notify_cleanup_refs, {caller, ref})

    # Spawn-link so killing the task cascades to this process (and its linked AsyncTracker)
    pid = spawn_link(fn ->
      result = try do
        Opus.Runtime.execute_component(wasm_bytes, input, runtime_opts_with_notify)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, "Exit: #{inspect(reason)}"}
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end
      send(caller, {ref, result})
    end)

    # Collect cleanup_refs sent by Runtime early in setup (before WASM execution starts).
    # Use the full timeout — if setup itself takes this long, we should timeout anyway.
    cleanup_refs = receive do
      {:cleanup_refs, ^ref, refs} -> refs
    after
      timeout_ms -> nil
    end

    remaining_ms = max(timeout_ms - (System.monotonic_time(:millisecond) - start_time), 0)

    # If we consumed the full timeout waiting for cleanup_refs, kill immediately
    if is_nil(cleanup_refs) do
      Process.exit(pid, :kill)
      {:error, "Execution timeout after #{timeout_ms}ms"}
    else
      receive do
        # Runtime.execute_component always returns 3-tuple {:ok, output, metadata}
        {^ref, {:ok, output, metadata}} ->
          {:ok, {output, metadata}}

        {^ref, {:error, _} = error} ->
          error
      after
        remaining_ms ->
          Process.exit(pid, :kill)
          # Clean up resources the dead process can't clean up
          if cleanup_refs[:stream_exec_ref], do: Opus.HttpStreamHandler.cleanup_registry(cleanup_refs.stream_exec_ref)
          if cleanup_refs[:formula_tracker_pid], do: Opus.FormulaHandler.cleanup_registry(cleanup_refs.formula_tracker_pid)
          {:error, "Execution timeout after #{timeout_ms}ms"}
      end
    end
  end

  # Emit a setup_required event on the parent execution's event stream
  # when a sub-execution fails due to a setup issue. This allows Prism/SSE
  # subscribers to see it even if FormulaHandler can't detect it.
  defp maybe_emit_setup_event(ctx, reason, opts) do
    parent_id = opts[:parent_execution_id]

    if parent_id do
      case Opus.Remediation.analyze(ctx, reason) do
        {:setup_required, remediation} ->
          Opus.ExecutionEventBuffer.push(parent_id, %{
            "kind" => "setup_required",
            "component_ref" => remediation["component_ref"],
            "issues" => remediation["issues"],
            "setup_command" => remediation["setup_command"],
            "message" => reason
          }, System.unique_integer([:positive]))

        :not_setup_error ->
          :ok
      end
    end
  end

  defp handle_failure(record, error_msg, started_written) do
    failed_record = ExecutionRecord.fail(record, error_msg)

    if :atomics.get(started_written, 1) == 0 do
      case ExecutionRecord.write_started(record) do
        :ok -> :ok
        {:error, reason} ->
          Logger.error("[Opus.Executor] Failed to write started record #{record.id}: #{inspect(reason)}. " <>
            "Audit trail is incomplete — this execution will not appear in logs.")
      end

      Opus.Telemetry.execute_start(record)
    end

    case ExecutionRecord.write_failed(failed_record) do
      :ok -> :ok
      {:error, reason} ->
        Logger.error("[Opus.Executor] Failed to write failed record #{record.id}: #{inspect(reason)}. " <>
          "Audit trail is incomplete — this execution will appear as 'running' in logs.")
    end

    Opus.Telemetry.execute_exception(failed_record, error_msg)

    # Push terminal error event so SSE/LiveView subscribers know execution failed
    Opus.ExecutionEventBuffer.push_terminal(record.id, "error",
      %{error: error_msg}, 999_999_999)

    {:error, error_msg}
  end

  # Build a snapshot of the host policy for forensic replay (PRD §5.6)
  # This captures the policy that was enforced at execution time.
  @doc """
  Cancel a running execution by killing its process.

  Looks up the task PID in the ExecutionRegistry and kills it. The kill cascades
  to the inner WASM process (via spawn_link) and AsyncTracker (via OTP links).
  The semaphore auto-releases via its :DOWN monitor.
  """
  @spec cancel(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(%Context{} = ctx, execution_id) do
    case Registry.lookup(Opus.ExecutionRegistry, execution_id) do
      [{pid, _}] ->
        Process.exit(pid, :kill)
        ExecutionRecord.cancel(ctx, execution_id)
        ExecutionEventBuffer.push_terminal(execution_id, "cancelled", %{}, System.unique_integer([:positive]))
        emit_cancel_telemetry(ctx, execution_id)
        {:ok, %{cancelled: true, execution_id: execution_id}}

      [] ->
        case ExecutionRecord.cancel(ctx, execution_id) do
          {:ok, _} ->
            ExecutionEventBuffer.push_terminal(execution_id, "cancelled", %{}, System.unique_integer([:positive]))
            emit_cancel_telemetry(ctx, execution_id)
            {:ok, %{cancelled: true, execution_id: execution_id}}
          error -> error
        end
    end
  end

  defp emit_cancel_telemetry(ctx, execution_id) do
    :telemetry.execute(
      [:cyfr, :opus, :execute, :exception],
      %{duration: 0, system_time: System.system_time()},
      %{execution_id: execution_id, user_id: ctx.user_id, error: "cancelled", status: :cancelled}
    )
  end

  defp build_host_policy_snapshot(exec_opts) do
    case Keyword.get(exec_opts, :policy) do
      nil ->
        nil

      policy ->
        %{
          allowed_domains: policy.allowed_domains,
          rate_limit: policy.rate_limit,
          max_memory_bytes: policy.max_memory_bytes,
          timeout: policy.timeout,
          allowed_tools: policy.allowed_tools,
          allowed_paths: policy.allowed_paths,
          allowed_actions: policy.allowed_actions
        }
    end
  end
end
