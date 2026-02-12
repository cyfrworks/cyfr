defmodule Opus.McpHandler do
  @moduledoc """
  Host function handler for Formula MCP tool access.

  Provides the `cyfr:mcp/tools@0.1.0` WASI host function import that
  enables Formula components to call MCP tools (like `component.search`,
  `storage.read`, `build.compile`) from within WASM execution.

  ## Security Model

  All tool calls are deny-by-default. A Formula's policy must explicitly
  list allowed tools in `allowed_tools` (supports exact match and wildcards).
  Storage writes are further scoped to the `agent/` namespace prefix, and
  `allowed_storage_paths` can restrict which paths are accessible.

  ## Architecture

  Follows the same pattern as `FormulaHandler` (`cyfr:formula/invoke@0.1.0`)
  and `HttpHandler` (`cyfr:http/fetch@0.1.0`). The host function is
  registered as a Wasmex import that the WASM component calls synchronously.
  All errors are caught and returned as JSON (never raised into WASM).

  ## Request Format (JSON string from WASM)

      {"tool": "component", "action": "search", "args": {"query": "http-client"}}

  ## Response Format (JSON string returned to WASM)

  On success:

      {"status": "ok", "result": {...}}

  On error:

      {"error": {"type": "tool_denied", "message": "..."}}

  ## Usage

      imports = Opus.McpHandler.build_mcp_imports(policy, ctx, execution_id)
      # Merge with other imports and pass to Wasmex.Components.start_link
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Policy

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:mcp/tools@0.1.0` host function.

  Returns a map suitable for merging into `Wasmex.Components.start_link` opts.
  When the component calls `cyfr:mcp/tools.call(json)`, the host function
  parses the request, validates against the policy, dispatches to the
  appropriate MCP handler, and returns the JSON result.

  ## Parameters

  - `policy` - The `Sanctum.Policy` with `allowed_tools` configured
  - `ctx` - The execution `Sanctum.Context`
  - `execution_id` - The formula's own execution ID for telemetry

  ## Returns

  A map with the `"cyfr:mcp/tools@0.1.0"` namespace containing a `"call"` function.
  """
  @spec build_mcp_imports(Policy.t(), Context.t(), String.t()) :: map()
  def build_mcp_imports(%Policy{} = policy, %Context{} = ctx, execution_id) do
    %{
      "cyfr:mcp/tools@0.1.0" => %{
        "call" => {:fn, fn json_request ->
          execute(json_request, policy, ctx, execution_id)
        end}
      }
    }
  end

  @doc """
  Execute an MCP tool call from a formula.

  Parses the JSON request, validates against policy, dispatches to the
  appropriate MCP handler, and returns a JSON response string. All errors
  are caught and returned as JSON (never raised into WASM).

  ## Parameters

  - `json_request` - JSON string with tool, action, and args
  - `policy` - The formula's policy for tool access validation
  - `ctx` - The parent formula's execution context
  - `execution_id` - The parent formula's execution ID
  """
  @spec execute(String.t(), Policy.t(), Context.t(), String.t()) :: String.t()
  def execute(json_request, %Policy{} = policy, %Context{} = ctx, execution_id) do
    start_time = System.monotonic_time(:millisecond)

    result =
      case parse_request(json_request) do
        {:ok, %{tool: tool, action: action, args: args}} ->
          tool_action = "#{tool}.#{action}"

          case validate_and_dispatch(tool, action, tool_action, args, policy, ctx) do
            {:ok, result} ->
              emit_telemetry(execution_id, tool_action, :ok, start_time)
              encode_success(result)

            {:error, type, message} ->
              emit_telemetry(execution_id, tool_action, :error, start_time)
              encode_error(type, message)
          end

        {:error, type, message} ->
          emit_telemetry(execution_id, "unknown", :error, start_time)
          encode_error(type, message)
      end

    result
  end

  # ============================================================================
  # Private: Request Parsing
  # ============================================================================

  defp parse_request(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"tool" => tool, "action" => action} = req} when is_binary(tool) and is_binary(action) ->
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
  # Private: Validation & Dispatch
  # ============================================================================

  defp validate_and_dispatch(tool, action, tool_action, args, policy, ctx) do
    with :ok <- validate_tool_allowed(policy, tool_action),
         :ok <- validate_storage_constraints(tool, action, args, policy) do
      dispatch(tool, ctx, Map.put(args, "action", action))
    end
  end

  defp validate_tool_allowed(policy, tool_action) do
    if Policy.allows_tool?(policy, tool_action) do
      :ok
    else
      {:error, :tool_denied, "Tool '#{tool_action}' is not allowed by policy. Add it to allowed_tools."}
    end
  end

  defp validate_storage_constraints(tool, action, args, policy) do
    if tool == "storage" do
      path = Map.get(args, "path", "")

      # Enforce agent/ namespace prefix for writes
      if action == "write" and not String.starts_with?(path, "agent/") do
        {:error, :storage_path_denied, "Storage writes from formulas must use the 'agent/' namespace prefix. Got: '#{path}'"}
      else
        # Validate against allowed_storage_paths for read/write
        if action in ["read", "write"] and not Policy.allows_storage_path?(policy, path) do
          {:error, :storage_path_denied, "Storage path '#{path}' is not allowed by policy."}
        else
          :ok
        end
      end
    else
      :ok
    end
  end

  defp dispatch(tool, ctx, args) do
    result =
      case tool do
        "component" -> Compendium.MCP.handle("component", ctx, args)
        "storage" -> Arca.MCP.handle("storage", ctx, args)
        "policy" -> Sanctum.MCP.handle("policy", ctx, args)
        "build" -> Locus.MCP.handle("build", ctx, args)
        "secret" -> Sanctum.MCP.handle("secret", ctx, args)
        "execution" -> Opus.MCP.handle("execution", ctx, args)
        "audit" -> Sanctum.MCP.handle("audit", ctx, args)
        "config" -> Sanctum.MCP.handle("config", ctx, args)
        _ -> {:error, "Unknown tool: #{tool}"}
      end

    case result do
      {:ok, data} -> {:ok, normalize_keys(data)}
      {:error, reason} -> {:error, :dispatch_error, to_string(reason)}
    end
  end

  # ============================================================================
  # Private: Response Encoding
  # ============================================================================

  defp encode_success(result) do
    Jason.encode!(%{"status" => "ok", "result" => result})
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
end
