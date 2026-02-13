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
  executes each invocation synchronously.

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

      imports = Opus.FormulaHandler.build_formula_imports(ctx, parent_execution_id)
      # Merge with other imports and pass to Wasmex.Components.start_link
  """

  require Logger

  alias Sanctum.Context

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:formula/invoke@0.1.0` host function.

  Returns a map suitable for merging into `Wasmex.Components.start_link` opts.
  When the component calls `cyfr:formula/invoke.call(json)`, the host function
  parses the request, invokes the sub-component via `Executor.run/4`, and
  returns the JSON result.

  ## Parameters

  - `ctx` - The execution `Sanctum.Context` (shared with sub-executions)
  - `parent_execution_id` - The formula's own execution ID for lineage tracking

  ## Returns

  A map with the `"cyfr:formula/invoke@0.1.0"` namespace containing a `"call"` function.
  """
  @spec build_formula_imports(Context.t(), String.t()) :: map()
  def build_formula_imports(%Context{} = ctx, parent_execution_id) do
    %{
      "cyfr:formula/invoke@0.1.0" => %{
        "call" => {:fn, fn json_request ->
          execute(json_request, ctx, parent_execution_id)
        end}
      }
    }
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
      {:ok, %{reference: reference, input: input, type: type, component_ref: component_ref}} ->
        invoke_component(ctx, reference, input, type, parent_execution_id, component_ref)

      {:error, type, message} ->
        encode_error(type, message)
    end
  end

  # ============================================================================
  # Private: Request Parsing
  # ============================================================================

  defp parse_request(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"reference" => reference, "input" => input} = req} when is_map(reference) and is_map(input) ->
        type = req["type"] || "reagent"

        with {:ok, component_type} <- Opus.ComponentType.parse(type),
             {:ok, component_ref} <- extract_component_ref(reference) do
          {:ok, %{reference: reference, input: input, type: component_type, component_ref: component_ref}}
        else
          {:error, reason} -> {:error, :invalid_request, to_string(reason)}
        end

      {:ok, %{"reference" => _}} ->
        {:error, :invalid_request, "Request must include 'reference' (map) and 'input' (map)"}

      {:ok, _} ->
        {:error, :invalid_request, "Request must include 'reference' and 'input'"}

      {:error, _} ->
        {:error, :invalid_json, "Invalid JSON request"}
    end
  end

  defp extract_component_ref(%{"registry" => ref}), do: normalize_ref(ref)
  defp extract_component_ref(%{"local" => path}), do: ref_from_path(path)
  defp extract_component_ref(%{"arca" => path}), do: ref_from_path(path)
  defp extract_component_ref(%{"oci" => ref}), do: normalize_ref(ref)
  defp extract_component_ref(ref), do: {:error, "Cannot extract component ref from: #{inspect(ref)}"}

  defp ref_from_path(path) do
    case Sanctum.ComponentRef.from_path(path) do
      {:ok, parsed} -> {:ok, Sanctum.ComponentRef.to_string(parsed)}
      {:error, _} = error -> error
    end
  end

  defp normalize_ref(ref) do
    Sanctum.ComponentRef.normalize(ref)
  end

  # ============================================================================
  # Private: Component Invocation
  # ============================================================================

  defp invoke_component(ctx, reference, input, type, parent_execution_id, component_ref) do
    case Opus.Executor.run(ctx, reference, input,
           type: type,
           parent_execution_id: parent_execution_id) do
      {:ok, %{output: output, metadata: %{execution_id: child_execution_id}}} ->
        Opus.Telemetry.formula_invoke(parent_execution_id, child_execution_id, component_ref, :ok)
        encode_success(output)

      {:error, reason} ->
        Opus.Telemetry.formula_invoke(parent_execution_id, nil, component_ref, :error)
        encode_error(:execution_failed, reason)
    end
  end

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
