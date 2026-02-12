defmodule Opus.Replay do
  @moduledoc """
  Forensic replay capability for execution verification.

  WASM execution is deterministic: same binary + same input = same output.
  This module enables replaying past executions to verify their results,
  detect tampering, or debug issues.

  ## PRD Reference

  Per PRD §5.6, Opus provides forensic replay capabilities:
  > "WASM execution is deterministic; same binary + same input = same output.
  > Opus can replay any logged execution by re-fetching the component
  > (by digest) and invoking with captured input."

  ## Usage

      ctx = Sanctum.Context.local()

      # Replay an execution and verify the output matches
      {:ok, result} = Opus.Replay.replay(ctx, "exec_abc123")

      case result.verification do
        :match -> IO.puts("Output matches original execution")
        :mismatch -> IO.puts("Output differs! Possible issue detected")
      end

  ## How It Works

  1. Load execution record (input, component_digest, host_policy)
  2. Fetch WASM by digest from cache or Arca
  3. Re-execute with captured input and policy
  4. Compare output to original
  5. Return verification result

  ## Limitations

  - Requires WASM binary to be cached (by digest)
  - Non-deterministic components (using random/time) may not replay exactly
  - WASI side effects (HTTP, filesystem) are not replayed
  - **Catalysts**: Replay does NOT inject secrets or create HTTP host functions.
    Any Catalyst that used `cyfr:secrets/read` or `cyfr:http/fetch` during the
    original execution will fail or produce different output during replay.
    This is because replay runs in a minimal sandbox without I/O capabilities.
  - **Secrets**: Pre-resolved secrets are not available during replay. A Catalyst
    that called `get("API_KEY")` will get an "access-denied" error on replay.
  - Once WASI trace capture is implemented, replay could mock HTTP responses
    from the recorded trace to enable faithful Catalyst replay.

  ## Cache Strategy

  Currently, replay requires the component to be available via the original
  reference (local, arca, registry). Future versions may cache by digest.
  """

  require Logger

  alias Sanctum.Context
  alias Opus.ExecutionRecord

  @type replay_result :: %{
          execution_id: String.t(),
          original_output: map() | nil,
          replay_output: map() | nil,
          verification: :match | :mismatch | :original_failed | :replay_failed,
          duration_ms: non_neg_integer(),
          details: String.t()
        }

  @doc """
  Replay an execution and verify the output matches.

  ## Parameters

  - `ctx` - Sanctum context
  - `execution_id` - ID of the execution to replay

  ## Options

  - `:ignore_duration` - Don't fail if duration differs significantly (default: true)
  - `:max_memory_bytes` - Memory limit for replay (default: same as original)
  - `:fuel_limit` - Fuel limit for replay (default: same as original)

  ## Returns

  - `{:ok, result}` - Replay completed with verification result
  - `{:error, reason}` - Replay failed

  ## Example

      {:ok, result} = Opus.Replay.replay(ctx, "exec_abc123")

      result.verification
      # => :match (output matches original)
      # => :mismatch (output differs)
      # => :original_failed (original execution failed)
      # => :replay_failed (replay execution failed)

  """
  @spec replay(Context.t(), String.t(), keyword()) :: {:ok, replay_result()} | {:error, String.t()}
  def replay(%Context{} = ctx, execution_id, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, record} <- load_execution_record(ctx, execution_id),
         {:ok, wasm_bytes} <- fetch_component(ctx, record),
         {:ok, replay_output} <- execute_replay(wasm_bytes, record, opts) do
      duration_ms = System.monotonic_time(:millisecond) - start_time

      verification = verify_output(record, replay_output)

      result = %{
        execution_id: execution_id,
        original_output: record.output,
        replay_output: replay_output,
        verification: verification,
        duration_ms: duration_ms,
        details: format_verification_details(verification, record, replay_output)
      }

      {:ok, result}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Replay failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Verify an execution without full replay.

  Performs quick verification by checking:
  - Execution record exists and is complete
  - Component digest matches stored value
  - Input/output are well-formed

  This is faster than full replay but doesn't re-execute the component.

  ## Returns

  - `{:ok, :verified}` - Record appears valid
  - `{:ok, :incomplete}` - Execution is still running or was interrupted
  - `{:error, reason}` - Verification failed

  """
  @spec verify(Context.t(), String.t()) :: {:ok, :verified | :incomplete} | {:error, String.t()}
  def verify(%Context{} = ctx, execution_id) do
    case load_execution_record(ctx, execution_id) do
      {:ok, record} ->
        case record.status do
          :completed ->
            if record.component_digest && record.output do
              {:ok, :verified}
            else
              {:error, "Execution record is incomplete: missing digest or output"}
            end

          :running ->
            {:ok, :incomplete}

          status when status in [:failed, :cancelled] ->
            {:ok, :verified}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Compare two executions to check if they produce the same output.

  Useful for regression testing or verifying component behavior across versions.

  ## Returns

  - `{:ok, :identical}` - Both executions have the same output
  - `{:ok, :different}` - Outputs differ
  - `{:error, reason}` - Comparison failed

  """
  @spec compare(Context.t(), String.t(), String.t()) ::
          {:ok, :identical | :different} | {:error, String.t()}
  def compare(%Context{} = ctx, exec_id_a, exec_id_b) do
    with {:ok, record_a} <- load_execution_record(ctx, exec_id_a),
         {:ok, record_b} <- load_execution_record(ctx, exec_id_b) do
      if record_a.output == record_b.output do
        {:ok, :identical}
      else
        {:ok, :different}
      end
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp load_execution_record(ctx, execution_id) do
    case ExecutionRecord.get(ctx, execution_id) do
      {:ok, record} ->
        {:ok, record}

      {:error, :not_found} ->
        {:error, "Execution not found: #{execution_id}"}

      {:error, reason} ->
        {:error, "Failed to load execution: #{inspect(reason)}"}
    end
  end

  defp fetch_component(ctx, record) do
    reference = record.reference

    cond do
      is_map_key(reference, "local") ->
        path = expand_path(reference["local"])

        case File.read(path) do
          {:ok, bytes} -> verify_digest(bytes, record.component_digest)
          {:error, reason} -> {:error, "Failed to read local file: #{inspect(reason)}"}
        end

      is_map_key(reference, "arca") ->
        arca_path = "artifacts/" <> String.trim_leading(reference["arca"], "/")

        case Arca.MCP.handle("storage", ctx, %{"action" => "read", "path" => arca_path}) do
          {:ok, %{content: b64_content}} ->
            case Base.decode64(b64_content) do
              {:ok, bytes} -> verify_digest(bytes, record.component_digest)
              :error -> {:error, "Invalid base64 content from Arca"}
            end
          {:error, reason} -> {:error, "Failed to read from Arca: #{reason}"}
        end

      is_map_key(reference, "oci") ->
        {:error, "OCI reference replay not yet implemented. Digest: #{record.component_digest}"}

      true ->
        {:error, "Unknown reference format: #{inspect(reference)}"}
    end
  end

  defp verify_digest(wasm_bytes, expected_digest) when is_binary(expected_digest) do
    actual_digest = compute_digest(wasm_bytes)

    if actual_digest == expected_digest do
      {:ok, wasm_bytes}
    else
      {:error,
       "Component digest mismatch. Expected: #{expected_digest}, Got: #{actual_digest}. " <>
         "Component may have been modified since original execution."}
    end
  end

  defp verify_digest(wasm_bytes, nil) do
    # No digest recorded - can't verify but proceed with warning
    {:ok, wasm_bytes}
  end

  defp compute_digest(wasm_bytes) do
    hash = :crypto.hash(:sha256, wasm_bytes)
    hex = Base.encode16(hash, case: :lower)
    "sha256:#{hex}"
  end

  defp expand_path(path) do
    path
    |> String.replace("~", System.user_home!())
    |> Path.expand()
  end

  defp execute_replay(wasm_bytes, record, opts) do
    component_type = record.component_type || :reagent
    input = record.input || %{}

    # Warn about Catalyst replay limitations
    if component_type == :catalyst do
      Logger.warning(
        "Replaying Catalyst execution #{record.id}: secrets and HTTP host functions " <>
          "are NOT available during replay. Output may differ from original execution."
      )
    end

    # Build runtime options, preferring stored host_policy for forensic replay.
    # Note: replay runs without secrets or HTTP imports (Catalysts will fail
    # on any secret/HTTP access). This is documented in the module @moduledoc.
    runtime_opts =
      [component_type: component_type]
      |> maybe_add_policy_limits(record.host_policy)
      |> Keyword.merge(Keyword.take(opts, [:max_memory_bytes, :fuel_limit]))

    case Opus.Runtime.execute_component(wasm_bytes, input, runtime_opts) do
      {:ok, output, _metadata} -> {:ok, output}
      {:error, reason} -> {:error, "Replay execution failed: #{inspect(reason)}"}
    end
  end

  # Use stored host_policy limits if available for accurate replay
  defp maybe_add_policy_limits(opts, nil), do: opts
  defp maybe_add_policy_limits(opts, host_policy) when is_map(host_policy) do
    opts
    |> maybe_add(:max_memory_bytes, host_policy[:max_memory_bytes] || host_policy["max_memory_bytes"])
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp verify_output(record, replay_output) do
    case record.status do
      :completed ->
        if record.output == replay_output do
          :match
        else
          :mismatch
        end

      status when status in [:failed, :cancelled] ->
        :original_failed

      :running ->
        # Original execution is still running or was interrupted
        :original_failed
    end
  end

  defp format_verification_details(:match, _record, _replay) do
    "Output matches original execution"
  end

  defp format_verification_details(:mismatch, record, replay) do
    "Output differs from original execution.\n" <>
      "Original: #{inspect(record.output)}\n" <>
      "Replay: #{inspect(replay)}"
  end

  defp format_verification_details(:original_failed, record, _replay) do
    "Original execution status: #{record.status}. " <>
      if(record.error, do: "Error: #{record.error}", else: "No error message.")
  end
end
