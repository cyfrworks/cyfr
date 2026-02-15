defmodule Opus.Executor do
  @moduledoc """
  High-level execution facade for WASM components.

  This module provides a simplified API for executing WASM components,
  handling reference resolution, signature verification, telemetry,
  and crash-resilient record keeping.

  ## Usage

      ctx = Sanctum.Context.local()
      reference = %{"local" => "components/catalysts/local/my-tool/0.1.0/catalyst.wasm"}
      input = %{"a" => 5, "b" => 10}

      {:ok, result} = Opus.Executor.run(ctx, reference, input)
      # result contains: output, execution_id, duration_ms, etc.

  ## Component Types

  - `:reagent` (default) - Pure sandboxed compute, no I/O
  - `:catalyst` - WASI enabled with HTTP/filesystem access
  - `:formula` - Composition of other components

  ## Reference Types

  - `%{"local" => path}` - Local filesystem path
  - `%{"registry" => "namespace.name:version"}` - Local registry reference (via Compendium.Registry)
  - `%{"arca" => path}` - User's Arca storage
  - `%{"oci" => ref}` - OCI registry reference (requires Compendium)
  """

  require Logger

  alias Sanctum.Context
  alias Opus.ExecutionRecord

  # Default timeouts per component type
  @default_timeout_ms %{catalyst: 180_000, formula: 300_000, reagent: 60_000}

  @doc """
  Execute a WASM component with the given input.

  ## Options

  - `:type` - Component type: `:catalyst`, `:reagent`, or `:formula`. Defaults to `:reagent`.
  - `:verify` - Optional verification requirements: `%{identity: string, issuer: string}`
  - `:max_memory_bytes` - Memory limit for execution. Defaults to 64MB.
  - `:fuel_limit` - Fuel limit for CPU time. Defaults to 100M instructions.

  ## Returns

  - `{:ok, result}` - Execution succeeded with result map
  - `{:error, reason}` - Execution failed with error message
  """
  @spec run(Context.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(%Context{} = ctx, reference, input, opts \\ []) when is_map(reference) and is_map(input) do
    # Extract component reference name for policy/secret lookup.
    # For registry refs, this also calls Compendium inspect (caching the
    # result in resolve_ctx to avoid a redundant MCP call later).
    # The extracted type is the single source of truth — opts[:type] is
    # only a fallback for callers like FormulaHandler that specify type via opts.
    case extract_component_ref(ctx, reference) do
      {:ok, component_ref, extracted_type, resolve_ctx} ->
        raw_type = extracted_type || opts[:type]
        case parse_component_type(raw_type) do
          {:ok, component_type} ->
            do_run_with_ref(ctx, reference, input, opts, component_type, component_ref, resolve_ctx)
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_run_with_ref(ctx, reference, input, opts, component_type, component_ref, resolve_ctx) do

    # Create initial execution record
    record = ExecutionRecord.new(ctx, reference, input,
      component_type: component_type,
      parent_execution_id: opts[:parent_execution_id]
    )

    # Track whether started.json was written
    started_written = :atomics.new(1, signed: false)

    try do
      with {:ok, exec_opts} <- Opus.PolicyEnforcer.build_execution_opts(ctx, component_ref, component_type),
           {:ok, _input_json} <- validate_input_size(input, exec_opts),
           :ok <- check_rate_limit(ctx, component_ref, exec_opts),
           {:ok, wasm_bytes} <- resolve_reference(ctx, reference, resolve_ctx),
           component_digest = compute_digest(wasm_bytes),
           # Capture host policy snapshot for forensic replay (PRD §5.6)
           host_policy = build_host_policy_snapshot(exec_opts),
           record = %{record | component_digest: component_digest, host_policy: host_policy},
           :ok <- maybe_verify_signature(reference, opts[:verify]),
           :ok <- ExecutionRecord.write_started(record),
           _ = :atomics.put(started_written, 1, 1),
           _ = Opus.Telemetry.execute_start(record),
           # Pre-resolve all granted secrets once for this execution (eliminates per-call file I/O)
           {:ok, preloaded_secrets} <- resolve_secrets(ctx, component_ref),
           # Pass policy and ctx for HTTP host function imports
           policy = Keyword.get(exec_opts, :policy),
           exec_opts_final = Keyword.merge(exec_opts, [
             preloaded_secrets: preloaded_secrets,
             component_ref: component_ref,
             policy: policy,
             ctx: ctx,
             execution_id: record.id
           ]),
           {:ok, {output, exec_metadata}} <- execute_wasm(wasm_bytes, input, exec_opts_final, opts) do
        # Mask secrets in output using the already-resolved values (no re-decryption)
        secret_values = Map.values(preloaded_secrets)
        masked_output = Opus.SecretMasker.mask(output, secret_values)

        # Complete the record with masked output
        completed_record = ExecutionRecord.complete(record, masked_output)
        case ExecutionRecord.write_completed(completed_record) do
          :ok -> :ok
          {:error, reason} ->
            Logger.error("[Opus.Executor] Failed to write completed record #{completed_record.id}: #{inspect(reason)}. " <>
              "Audit trail is incomplete — this execution will appear as 'running' in logs.")
        end
        # Pass execution metadata (memory_bytes) to telemetry
        Opus.Telemetry.execute_stop(completed_record, exec_metadata)

        {:ok,
         %{
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
             signature_verified: Opus.SignatureVerifier.enforce_signatures?()
           }
         }}
      else
        {:error, reason} when is_binary(reason) ->
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
  # Private Helpers
  # ===========================================================================

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

  # Check rate limit before execution (via MCP boundary)
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

  # Registry refs: call Compendium inspect to get component_ref and cache
  # the result so resolve_reference can skip the redundant inspect call.
  # Returns {:ok, component_ref, component_type, resolve_ctx}.
  defp extract_component_ref(ctx, %{"registry" => ref}) do
    case Compendium.MCP.handle("component", ctx, %{"action" => "inspect", "reference" => ref}) do
      {:ok, component} ->
        {:ok, component["component_ref"], component["type"], {:registry_inspected, component}}
      {:error, reason} ->
        if is_binary(reason) and String.contains?(reason, "not found") do
          {:error, "Component not found in local registry: #{ref}"}
        else
          {:error, "Failed to resolve registry reference: #{reason}"}
        end
    end
  end

  defp extract_component_ref(_ctx, %{"local" => path}) do
    case Sanctum.ComponentRef.from_path(path) do
      {:ok, parsed} -> {:ok, Sanctum.ComponentRef.to_string(parsed), parsed.type, nil}
      {:error, _} = error -> error
    end
  end

  defp extract_component_ref(_ctx, %{"arca" => path}) do
    case Sanctum.ComponentRef.from_path(path) do
      {:ok, parsed} -> {:ok, Sanctum.ComponentRef.to_string(parsed), parsed.type, nil}
      {:error, _} = error -> error
    end
  end

  defp extract_component_ref(_ctx, %{"oci" => ref}) do
    case Sanctum.ComponentRef.normalize(ref) do
      {:ok, normalized} ->
        # Parse the normalized ref to extract the type
        case Sanctum.ComponentRef.parse(normalized) do
          {:ok, parsed} -> {:ok, normalized, parsed.type, nil}
          {:error, reason} ->
            {:error, "Could not parse component type from OCI ref '#{normalized}': #{reason}"}
        end
      {:error, _} = error -> error
    end
  end

  defp extract_component_ref(_ctx, ref) do
    {:error, "Cannot extract component ref from: #{inspect(ref)}"}
  end

  defp resolve_reference(_ctx, %{"local" => path}, _resolve_ctx) when is_binary(path) do
    expanded_path = expand_local_path(path)

    case validate_local_path(expanded_path) do
      :ok ->
        cond do
          File.exists?(expanded_path) ->
            File.read(expanded_path)

          File.exists?(resolve_artifact_path(path)) ->
            case validate_local_path(resolve_artifact_path(path)) do
              :ok -> File.read(resolve_artifact_path(path))
              {:error, _} = err -> err
            end

          true ->
            {:error, "Local file not found: #{expanded_path}"}
        end

      {:error, _} = err ->
        err
    end
  end

  defp resolve_reference(ctx, %{"arca" => path}, _resolve_ctx) when is_binary(path) do
    arca_path = "artifacts/" <> String.trim_leading(path, "/")

    case Arca.MCP.handle("storage", ctx, %{"action" => "read", "path" => arca_path}) do
      {:ok, %{content: b64_content}} ->
        Base.decode64(b64_content)

      {:error, reason} ->
        if is_binary(reason) and String.contains?(reason, "not found") do
          {:error, "Arca artifact not found: #{arca_path}"}
        else
          {:error, "Failed to read from Arca: #{reason}"}
        end
    end
  end

  defp resolve_reference(_ctx, %{"oci" => oci_ref}, _resolve_ctx) when is_binary(oci_ref) do
    {:error, "OCI registry pull not yet implemented. Reference: #{oci_ref}. Use Compendium to pull first."}
  end

  # Registry ref with cached inspect result — skip the redundant inspect call.
  defp resolve_reference(ctx, %{"registry" => ref}, {:registry_inspected, component}) when is_binary(ref) do
    expected_digest = component[:digest] || component["digest"]
    case Compendium.MCP.handle("component", ctx, %{"action" => "pull", "reference" => ref}) do
      {:ok, _} ->
        # Fetch blob and verify digest matches what inspect reported (TOCTOU prevention)
        case fetch_blob_via_mcp(ctx, expected_digest) do
          {:ok, bytes} ->
            actual_digest = compute_digest(bytes)
            if expected_digest && actual_digest != "sha256:" <> expected_digest and actual_digest != expected_digest do
              {:error,
               "Registry digest mismatch for #{ref}. " <>
                 "Expected: #{expected_digest}, Got: #{actual_digest}. " <>
                 "Component may have been modified between inspect and fetch."}
            else
              {:ok, bytes}
            end

          error ->
            error
        end

      {:error, reason} ->
        {:error, "Failed to pull component: #{reason}"}
    end
  end

  defp resolve_reference(_ctx, reference, _resolve_ctx) do
    {:error, "Invalid reference format. Expected {local: path}, {registry: name:version}, {arca: path}, or {oci: ref}. Got: #{inspect(reference)}"}
  end


  defp fetch_blob_via_mcp(ctx, digest) do
    case Compendium.MCP.handle("component", ctx, %{"action" => "get_blob", "digest" => digest}) do
      {:ok, %{bytes: b64_bytes}} -> {:ok, Base.decode64!(b64_bytes)}
      {:error, reason} -> {:error, "Failed to get blob: #{reason}"}
    end
  end

  defp expand_local_path(path) do
    path
    |> String.replace("~", System.user_home!())
    |> Path.expand()
  end

  defp resolve_artifact_path(path) do
    # Path is already a canonical component path or a direct filesystem path
    Path.expand(path)
  end

  # Validate that a local path is within allowed directories.
  # Prevents arbitrary filesystem reads (e.g., /etc/passwd, ~/.ssh/id_rsa).
  defp validate_local_path(expanded_path) do
    allowed_dirs = allowed_local_paths()

    if Enum.any?(allowed_dirs, fn dir ->
         String.starts_with?(expanded_path, Path.expand(dir) <> "/") or
           expanded_path == Path.expand(dir)
       end) do
      :ok
    else
      {:error,
       "Local path #{expanded_path} is outside allowed directories. " <>
         "Allowed: #{Enum.join(allowed_dirs, ", ")}. " <>
         "Configure `config :opus, :allowed_local_paths` to add directories."}
    end
  end

  defp allowed_local_paths do
    configured = Application.get_env(:opus, :allowed_local_paths, nil)

    case configured do
      nil ->
        # Default: project root (cwd), components/ in project root, ~/.cyfr/components/
        cwd = File.cwd!()
        defaults = [
          cwd,
          Path.join(cwd, "components"),
          Path.join(System.user_home!(), ".cyfr/components")
        ]

        # Also allow System.tmp_dir for testing
        case System.tmp_dir() do
          nil -> defaults
          tmp -> [tmp | defaults]
        end

      paths when is_list(paths) ->
        Enum.map(paths, &Path.expand/1)
    end
  end

  defp compute_digest(wasm_bytes) when is_binary(wasm_bytes) do
    hash = :crypto.hash(:sha256, wasm_bytes)
    hex = Base.encode16(hash, case: :lower)
    "sha256:#{hex}"
  end

  defp maybe_verify_signature(reference, nil) do
    # Even without explicit verify opts, check refs that require verification
    if Opus.SignatureVerifier.requires_verification?(reference) do
      case Opus.SignatureVerifier.verify(reference, nil, nil) do
        :ok -> :ok
        {:error, reason} -> {:error, "Signature verification failed: #{reason}"}
      end
    else
      :ok
    end
  end
  defp maybe_verify_signature(reference, verify) when is_map(verify) do
    identity = verify["identity"] || verify[:identity]
    issuer = verify["issuer"] || verify[:issuer]

    case Opus.SignatureVerifier.verify(reference, identity, issuer) do
      :ok -> :ok
      {:error, reason} -> {:error, "Signature verification failed: #{reason}"}
    end
  end

  defp execute_wasm(wasm_bytes, input, exec_opts, opts) do
    runtime_opts =
      exec_opts
      |> Keyword.merge(opts)
      |> Keyword.take([:component_type, :max_memory_bytes, :fuel_limit, :preloaded_secrets, :component_ref, :policy, :ctx, :execution_id])

    # Get timeout from policy options or use type-aware default
    component_type = Keyword.get(exec_opts, :component_type, :reagent)
    type_default = Map.get(@default_timeout_ms, component_type, 60_000)
    timeout_ms = exec_opts[:timeout_ms] || opts[:timeout_ms] || type_default

    execute_with_timeout(wasm_bytes, input, runtime_opts, timeout_ms)
  end

  # Execute WASM with wall-clock timeout enforcement.
  # This ensures long-running or stuck executions are terminated.
  # Uses spawn-based execution to avoid crashes propagating to caller.
  # Returns {:ok, {output, metadata}} or {:error, reason}
  defp execute_with_timeout(wasm_bytes, input, runtime_opts, timeout_ms) do
    caller = self()
    ref = make_ref()

    # Spawn a process that won't crash the caller on exception
    pid = spawn(fn ->
      result = try do
        Opus.Runtime.execute_component(wasm_bytes, input, runtime_opts)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, "Exit: #{inspect(reason)}"}
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end
      send(caller, {ref, result})
    end)

    receive do
      # Handle new 3-tuple format from Runtime (with execution metadata)
      {^ref, {:ok, output, metadata}} ->
        {:ok, {output, metadata}}

      # Handle legacy 2-tuple format
      {^ref, {:ok, output}} ->
        {:ok, {output, %{memory_bytes: 0}}}

      {^ref, {:error, _} = error} ->
        error
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        {:error, "Execution timeout after #{timeout_ms}ms"}
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
    end

    case ExecutionRecord.write_failed(failed_record) do
      :ok -> :ok
      {:error, reason} ->
        Logger.error("[Opus.Executor] Failed to write failed record #{record.id}: #{inspect(reason)}. " <>
          "Audit trail is incomplete — this execution will appear as 'running' in logs.")
    end

    Opus.Telemetry.execute_exception(failed_record, error_msg)

    {:error, error_msg}
  end

  # Build a snapshot of the host policy for forensic replay (PRD §5.6)
  # This captures the policy that was enforced at execution time.
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
          allowed_storage_paths: policy.allowed_storage_paths
        }
    end
  end
end
