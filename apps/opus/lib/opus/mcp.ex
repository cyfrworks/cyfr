defmodule Opus.MCP do
  @moduledoc """
  MCP tool provider for Opus execution engine.

  Provides a single `execution` tool with action-based dispatch:
  - `run` - Execute a Catalyst, Reagent, or Formula
  - `list` - List execution instances
  - `logs` - Retrieve execution record and logs
  - `cancel` - Cancel a running execution

  ## Architecture Note

  This module lives in the `opus` app, keeping tool definitions
  close to their implementation. WASM execution is implemented
  via Wasmex (Wasmtime backend).

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Emissary.MCP.ToolRegistry.

  ## Simplified Lifecycle

  Components are developed directly on the filesystem and executed
  via `{"local" => path}` references. The simplified workflow is:

      Develop in components/local/ → Execute via {"local" => path} → Publish
  """

  alias Sanctum.Context

  # ============================================================================
  # ResourceProvider Protocol
  # ============================================================================

  def resources do
    [
      %{
        uri: "opus://executions/{id}",
        name: "Execution State",
        description: "Get execution state by ID",
        mimeType: "application/json"
      },
      %{
        uri: "opus://executions/{id}/logs",
        name: "Execution Logs",
        description: "Get execution logs by ID",
        mimeType: "text/plain"
      }
    ]
  end

  def read(%Context{} = ctx, "opus://executions/" <> rest) do
    case parse_execution_uri(rest) do
      {:execution, exec_id} ->
        get_execution_resource(ctx, exec_id)

      {:execution_logs, exec_id} ->
        get_execution_logs_resource(ctx, exec_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read(_ctx, uri) do
    {:error, "Unknown resource URI: #{uri}"}
  end

  # Parse the URI path after "opus://executions/"
  # Supports: {id} -> execution state, {id}/logs -> execution logs
  defp parse_execution_uri(path) do
    case String.split(path, "/", parts: 2) do
      [exec_id, "logs"] when byte_size(exec_id) > 0 ->
        {:execution_logs, exec_id}

      [exec_id] when byte_size(exec_id) > 0 ->
        {:execution, exec_id}

      _ ->
        {:error, "Invalid execution URI format. Expected: opus://executions/{id} or opus://executions/{id}/logs"}
    end
  end

  # Get execution state as JSON resource
  defp get_execution_resource(ctx, exec_id) do
    case Opus.ExecutionRecord.get(ctx, exec_id) do
      {:ok, record} ->
        content = %{
          execution_id: record.id,
          request_id: record.request_id,
          status: Atom.to_string(record.status),
          reference: record.reference,
          component_type: Atom.to_string(record.component_type || :reagent),
          component_digest: record.component_digest,
          started_at: record.started_at && DateTime.to_iso8601(record.started_at),
          completed_at: record.completed_at && DateTime.to_iso8601(record.completed_at),
          duration_ms: record.duration_ms,
          error: record.error,
          input: record.input,
          output: record.output
        }

        {:ok, Jason.encode!(content, pretty: true)}

      {:error, :not_found} ->
        {:error, "Execution not found: #{exec_id}"}

      {:error, reason} ->
        {:error, "Failed to get execution: #{inspect(reason)}"}
    end
  end

  # Get execution logs as text resource
  defp get_execution_logs_resource(ctx, exec_id) do
    case Opus.ExecutionRecord.get(ctx, exec_id) do
      {:ok, record} ->
        # Format execution record as logs
        # In the future, this will include WASI logging output
        logs = format_execution_logs(record)
        {:ok, logs}

      {:error, :not_found} ->
        {:error, "Execution not found: #{exec_id}"}

      {:error, reason} ->
        {:error, "Failed to get execution logs: #{inspect(reason)}"}
    end
  end

  # Format execution record as human-readable logs
  defp format_execution_logs(record) do
    lines = [
      "=== Execution #{record.id} ===",
      "Status: #{record.status}",
      "Component Type: #{record.component_type || :reagent}",
      "Component Digest: #{record.component_digest || "unknown"}",
      "Started: #{format_datetime(record.started_at)}",
      "Completed: #{format_datetime(record.completed_at)}",
      "Duration: #{record.duration_ms || 0}ms",
      "",
      "Reference: #{inspect(record.reference)}",
      "",
      "Input:",
      inspect(record.input, pretty: true),
      ""
    ]

    lines = if record.status == :completed do
      lines ++ [
        "Output:",
        inspect(record.output, pretty: true),
        ""
      ]
    else
      lines
    end

    lines = if record.error do
      lines ++ [
        "Error:",
        record.error,
        ""
      ]
    else
      lines
    end

    lines = lines ++ [
      "[WASI logging interface not yet implemented]"
    ]

    Enum.join(lines, "\n")
  end

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ============================================================================
  # ToolProvider Protocol (validated at runtime)
  # ============================================================================

  def tools do
    [
      %{
        name: "execution",
        title: "Execution",
        description: "Execute WASM components and manage execution instances",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["run", "list", "logs", "cancel"],
              "description" => "Action to perform"
            },
            # run action params
            "reference" => %{
              "type" => "object",
              "description" => "Component reference: {local: string} | {registry: string} | {arca: string} | {oci: string}",
              "oneOf" => [
                %{"properties" => %{"local" => %{"type" => "string"}}},
                %{"properties" => %{"registry" => %{"type" => "string"}}},
                %{"properties" => %{"arca" => %{"type" => "string"}}},
                %{"properties" => %{"oci" => %{"type" => "string"}}}
              ]
            },
            "input" => %{
              "type" => "object",
              "description" => "Input data to pass to the component (run action)"
            },
            "type" => %{
              "type" => "string",
              "enum" => ["catalyst", "reagent", "formula"],
              "default" => "reagent",
              "description" => "Component type determines WASI capabilities (run action)"
            },
            # list action params
            "status" => %{
              "type" => "string",
              "enum" => ["running", "completed", "failed", "cancelled", "all"],
              "default" => "all",
              "description" => "Filter by status (list action)"
            },
            "limit" => %{
              "type" => "integer",
              "default" => 20,
              "description" => "Maximum results to return (list action)"
            },
            # logs/cancel action params
            "execution_id" => %{
              "type" => "string",
              "description" => "Execution ID (logs/cancel actions)"
            },
            # verify block (optional signer validation)
            "verify" => %{
              "type" => "object",
              "description" => "Optional signature verification requirements (run action)",
              "properties" => %{
                "identity" => %{
                  "type" => "string",
                  "description" => "Required signer identity (e.g., 'alice@example.com')"
                },
                "issuer" => %{
                  "type" => "string",
                  "description" => "Required OIDC issuer (e.g., 'https://github.com/login/oauth')"
                }
              }
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  # ============================================================================
  # Tool Handlers - Action-based dispatch
  # ============================================================================

  # Run action - execute a WASM component
  # Delegates to Opus.run/4 (via Opus.Executor) to avoid duplication
  def handle("execution", %Context{} = ctx, %{"action" => "run"} = args) do
    reference = args["reference"] || %{}
    input = args["input"] || %{}

    # Build options for Opus.run/4
    opts = build_run_opts(args)

    case Opus.run(ctx, reference, input, opts) do
      {:ok, result} ->
        # Format response for MCP (convert atoms to strings for JSON)
        {:ok, format_run_result(result, reference)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # List action - list execution instances
  def handle("execution", %Context{} = ctx, %{"action" => "list"} = args) do
    limit = args["limit"] || 20
    status_filter = parse_status_filter(args["status"])

    case Opus.ExecutionRecord.list(ctx, limit: limit, status: status_filter) do
      {:ok, records} ->
        executions =
          Enum.map(records, fn record ->
            %{
              execution_id: record.id,
              status: Atom.to_string(record.status),
              reference: record.reference,
              started_at: DateTime.to_iso8601(record.started_at),
              completed_at: record.completed_at && DateTime.to_iso8601(record.completed_at),
              duration_ms: record.duration_ms,
              error: record.error
            }
          end)

        {:ok, %{executions: executions, count: length(executions), user_id: ctx.user_id}}

      {:error, reason} ->
        {:error, "Failed to list executions: #{inspect(reason)}"}
    end
  end

  # Logs action - retrieve execution record and logs
  # Note: WASI stdout/stderr capture is not yet implemented. This returns the
  # execution record metadata. When WASI trace capture is added, actual
  # stdout/stderr output will be included in the `logs` field.
  def handle("execution", %Context{} = ctx, %{"action" => "logs", "execution_id" => execution_id}) do
    case Opus.ExecutionRecord.get(ctx, execution_id) do
      {:ok, record} ->
        {:ok,
         %{
           execution_id: record.id,
           status: Atom.to_string(record.status),
           started_at: DateTime.to_iso8601(record.started_at),
           completed_at: record.completed_at && DateTime.to_iso8601(record.completed_at),
           duration_ms: record.duration_ms,
           error: record.error,
           component_type: Atom.to_string(record.component_type || :reagent),
           component_digest: record.component_digest,
           reference: record.reference,
           logs: "[WASI stdout/stderr capture not yet implemented]"
         }}

      {:error, :not_found} ->
        {:error, "Execution not found: #{execution_id}"}

      {:error, reason} ->
        {:error, "Failed to get execution: #{inspect(reason)}"}
    end
  end

  def handle("execution", _ctx, %{"action" => "logs"}) do
    {:error, "Missing required argument: execution_id"}
  end

  # Cancel action - cancel a running execution
  def handle("execution", %Context{} = ctx, %{"action" => "cancel", "execution_id" => execution_id}) do
    case Opus.ExecutionRecord.cancel(ctx, execution_id) do
      {:ok, record} ->
        {:ok, %{cancelled: true, execution_id: record.id}}

      {:error, :not_found} ->
        {:error, "Execution not found: #{execution_id}"}

      {:error, :not_cancellable} ->
        {:error, "Execution already completed, failed, or cancelled"}

      {:error, reason} ->
        {:error, "Failed to cancel execution: #{inspect(reason)}"}
    end
  end

  def handle("execution", _ctx, %{"action" => "cancel"}) do
    {:error, "Missing required argument: execution_id"}
  end

  # Invalid action
  def handle("execution", _ctx, %{"action" => action}) do
    {:error, "Invalid execution action: #{action}"}
  end

  # Missing action
  def handle("execution", _ctx, _args) do
    {:error, "Missing required argument: action"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Build options for Opus.run/4 from MCP args
  defp build_run_opts(args) do
    opts = []

    # Add component type if specified
    opts = if args["type"], do: [{:type, args["type"]} | opts], else: opts

    # Add verify block if specified
    opts = if args["verify"], do: [{:verify, args["verify"]} | opts], else: opts

    opts
  end

  # Format the result from Opus.run/4 for MCP response
  # Converts atoms to strings for JSON serialization
  defp format_run_result(result, reference) do
    meta = result.metadata

    %{
      status: to_string(result.status),
      execution_id: meta.execution_id,
      result: result.output,
      duration_ms: meta.duration_ms,
      component_type: to_string(meta.component_type),
      component_digest: meta.component_digest,
      user_id: meta.user_id,
      reference: reference,
      policy_applied: meta.policy_applied
    }
  end

  defp parse_status_filter(nil), do: :all
  defp parse_status_filter("all"), do: :all
  defp parse_status_filter("running"), do: :running
  defp parse_status_filter("completed"), do: :completed
  defp parse_status_filter("failed"), do: :failed
  defp parse_status_filter("cancelled"), do: :cancelled
  defp parse_status_filter(_), do: :all
end
