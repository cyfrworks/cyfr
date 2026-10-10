# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.McpLog do
  @moduledoc """
  The `mcp_log` tool over the request log (`Arca.McpLog`): one row per
  recorded call, each the projection of its admission decision. The rows
  are security rows, so Sanctum is their one reader.

  The provider declares `context_kind: :actor`: the gate authorizes every
  call with the caller's full context and hands these handlers the
  `Prima.Actor` it projects, and nothing else. What remains here is the
  residual the annotations cannot express: the log is tenant-scoped, so an
  actor with no athanor is refused before any row is read (an actor of
  `:platform` scope reads across athanors and is not).

  `correlate` answers what a request left behind: its request-log rows,
  the executions it started and its policy logs (`correlation/2`, which
  the `decision` tool's `correlate` joins its own decisions to), beside
  its decisions, rendered by `Sanctum.Providers.Decision`.
  """

  @behaviour Prima.Provider

  require Logger

  alias Sanctum.Providers.Decision

  @impl true
  def service, do: "sanctum"

  @impl true
  def context_kind, do: :actor

  @impl true
  def tools do
    alias Prima.{Arg, Operation}

    [
      Operation.tool(
        [
          Operation.new(
            "mcp_log",
            "list",
            "List mcp log",
            [
              Arg.new("request_id", :string,
                description:
                  "The ingress request. Groups a whole chain: the call an ingress received and every tool a running component reached beneath it."
              ),
              Arg.new("tool", :string, description: "Tool name filter"),
              Arg.new("since", :string,
                description: "ISO8601 timestamp — return logs after this time"
              ),
              Arg.new("user_id", :string, description: "Filter by user ID"),
              Arg.new("status", :string, description: "Filter by status"),
              Arg.new("limit", :integer, description: "Max results (default: 20)")
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "mcp_log",
            "get",
            "Get mcp log",
            [Arg.new("id", :string, required: true, description: "Request ID")],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "mcp_log",
            "correlate",
            "Correlate mcp log",
            [
              Arg.new("request_id", :string,
                required: true,
                description:
                  "The ingress request. Groups a whole chain: the call an ingress received and every tool a running component reached beneath it."
              )
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "mcp_log",
            "fan_outs",
            "Fan outs mcp log",
            [
              Arg.new("request_ids", {:array, Arg.new(nil, :string)},
                required: true,
                description: "Batch of request IDs for fan_outs action"
              )
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "mcp_log",
            "stats",
            "Stats mcp log",
            [
              Arg.new("since_hours", :integer,
                description: "Number of hours of request statistics (default: 1)"
              )
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          )
        ],
        description: "Query MCP request logs - list, get, correlate, fan_outs, or view stats",
        title: "MCP Request Logs"
      )
    ]
  end

  # ============================================================================
  # Handlers
  # ============================================================================

  @impl true
  def handle("mcp_log", %Prima.Actor{} = actor, %{"action" => "get", "id" => id}) do
    with :ok <- tenant_ok(actor) do
      case Arca.McpLog.get_tenant(actor, id) do
        nil ->
          {:error, {:not_found, "MCP log", id}}

        # get_tenant is db-rescued and answers a tuple on an outage, the
        # storage refusal here rather than a row.
        {:error, :database_error} ->
          {:error, {:unavailable, "Storage"}}

        record ->
          {:ok, mcp_log_to_map(record)}
      end
    end
  end

  def handle("mcp_log", %Prima.Actor{}, %{"action" => "get"}) do
    {:error, {:invalid_argument, "Missing required argument: id"}}
  end

  def handle("mcp_log", %Prima.Actor{} = actor, %{"action" => "list"} = args) do
    with :ok <- tenant_ok(actor) do
      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          athanor_id: actor.athanor_id
        ]
        |> maybe_put(:user_id, args["user_id"])
        |> maybe_put(:status, args["status"])
        |> maybe_put(:request_id, args["request_id"])
        |> maybe_put(:tool, args["tool"])

      with {:ok, opts} <- since_opt(opts, args["since"]),
           {:ok, records} <- Arca.McpLog.list(opts) do
        {:ok, %{logs: Enum.map(records, &mcp_log_to_map/1)}}
      else
        {:error, :database_error} -> {:error, {:unavailable, "Storage"}}
        {:error, _} = err -> err
      end
    end
  end

  def handle("mcp_log", %Prima.Actor{} = actor, %{
        "action" => "correlate",
        "request_id" => request_id
      }) do
    with :ok <- tenant_ok(actor) do
      decisions =
        case Arca.DecisionLog.correlate(actor, request_id) do
          {:ok, rows} -> Enum.map(rows, &Decision.decision_to_map/1)
          {:error, _} -> []
        end

      {:ok, Map.put(correlation(actor, request_id), :decisions, decisions)}
    end
  end

  def handle("mcp_log", %Prima.Actor{}, %{"action" => "correlate"}) do
    {:error, {:invalid_argument, "Missing required argument: request_id"}}
  end

  # Batched fan-out counts: for each request_id, how many executions were
  # recorded against it? Used by ActivitiesLive to render the EXECS column
  # for a page of MCP log rows in a single GROUP BY instead of N correlate
  # queries.
  def handle("mcp_log", %Prima.Actor{} = actor, %{"action" => "fan_outs", "request_ids" => ids})
      when is_list(ids) do
    with :ok <- tenant_ok(actor) do
      ids = Enum.filter(ids, &is_binary/1)

      # `count_by_request/2` refuses rather than defaulting, so an outage
      # answers `{:error, :database_error}` — which was being wrapped and
      # shipped as `counts: ["error", "database_error"]`, a structured
      # falsehood a client would render as a fan-out count. Same refusal
      # the other arms give.
      case Arca.Execution.count_by_request(actor, ids) do
        counts when is_map(counts) -> {:ok, %{counts: counts}}
        {:error, :database_error} -> {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle("mcp_log", %Prima.Actor{}, %{"action" => "fan_outs"}) do
    {:error,
     {:invalid_argument, "Missing or invalid argument: request_ids (must be a list of strings)"}}
  end

  def handle("mcp_log", %Prima.Actor{} = actor, %{"action" => "stats"} = args) do
    with :ok <- tenant_ok(actor) do
      since_hours = args["since_hours"] || 1

      since = DateTime.utc_now() |> DateTime.add(-since_hours * 3600, :second)

      opts = [since: since, athanor_id: actor.athanor_id]

      case Arca.McpLog.stats(opts) do
        {:ok, stats} ->
          {:ok,
           %{
             since: DateTime.to_iso8601(since),
             total: stats.total,
             errors: stats.errors,
             avg_duration_ms: stats.avg_duration_ms,
             error_rate:
               if(stats.total > 0,
                 do: Float.round(stats.errors / stats.total * 100, 1),
                 else: 0.0
               )
           }}

        {:error, :database_error} ->
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle("mcp_log", %Prima.Actor{}, _args) do
    {:error, Prima.Provider.invalid_action("mcp_log", action_enum("mcp_log"))}
  end

  def handle(tool, %Prima.Actor{}, _args), do: {:error, {:not_found, "tool", tool}}

  # ============================================================================
  # The correlation
  # ============================================================================

  @doc false
  # What a request left behind besides its decisions, joined best-effort:
  # a storage outage on one leg leaves that leg empty rather than raising
  # on the error tuple. The executions and policy logs are rendered by the
  # records door, which owns their projections.
  @spec correlation(Prima.Actor.t(), String.t()) :: map()
  def correlation(%Prima.Actor{} = actor, request_id) do
    mcp_logs =
      case Arca.McpLog.list(request_id: request_id, limit: 100, athanor_id: actor.athanor_id) do
        {:ok, rows} -> Enum.map(rows, &mcp_log_to_map/1)
        {:error, _} -> []
      end

    executions =
      case Arca.Execution.list_by_request(actor, request_id) do
        rows when is_list(rows) -> Enum.map(rows, &Arca.Providers.Records.execution_to_map/1)
        {:error, _} -> []
      end

    policy_logs =
      case Arca.PolicyLog.list(request_id: request_id, limit: 100, athanor_id: actor.athanor_id) do
        {:ok, rows} -> Enum.map(rows, &Arca.Providers.Records.policy_log_to_map/1)
        {:error, _} -> []
      end

    %{
      request_id: request_id,
      mcp_logs: mcp_logs,
      executions: executions,
      policy_logs: policy_logs
    }
  end

  @doc false
  # A `since` argument as the stores filter on it: an ISO8601 timestamp,
  # or the caller's error. The `decision` tool's filters read it too.
  @spec since_opt(keyword(), String.t() | nil) :: {:ok, keyword()} | {:error, term()}
  def since_opt(opts, nil), do: {:ok, opts}

  def since_opt(opts, since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, dt, _} -> {:ok, Keyword.put(opts, :since, dt)}
      _ -> {:error, {:invalid_argument, "Invalid ISO8601 timestamp for 'since': #{since_str}"}}
    end
  end

  # ============================================================================
  # Tenancy
  # ============================================================================

  # The log is tenant-scoped: an actor with no athanor is refused before it
  # can reach any athanor's rows. A `:platform` scope actor reads across
  # athanors and needs none.
  defp tenant_ok(%Prima.Actor{scope: :platform}), do: :ok
  defp tenant_ok(%Prima.Actor{athanor_id: id}) when is_binary(id) and id != "", do: :ok
  defp tenant_ok(%Prima.Actor{}), do: {:error, :missing_tenant}

  # ============================================================================
  # Internal
  # ============================================================================

  defp mcp_log_to_map(%{id: _} = log) do
    %{
      id: log.id,
      request_id: log.request_id,
      user_id: log.user_id,
      timestamp: format_datetime(log.timestamp),
      tool: log.tool,
      action: log.action,
      method: log.method,
      status: log.status,
      duration_ms: log.duration_ms,
      routed_to: log.routed_to,
      # The row's meaning: a refused call's class. A JSON-RPC code is a
      # transport's rendering of it, and the rows carry none.
      refusal_class: log.refusal_class,
      input: decode_json(log.input, "input"),
      output: decode_json(log.output, "output"),
      error: log.error
    }
  end

  defp format_datetime(value), do: Prima.Time.iso8601(value)

  defp decode_json(nil, _field), do: nil

  # An audit field: corrupt JSON must read AS corruption, never silently
  # pass through as a string where a map was recorded.
  defp decode_json(str, field) when is_binary(str),
    do: decode_stored(str, %{"_decode_error" => "stored snapshot was not valid JSON"}, field)

  defp decode_json(val, _field), do: val

  # A stored JSON column that does not decode reads as its default. The
  # line names the column and its size, never its bytes. `decode_json/2`
  # answers nil itself.
  defp decode_stored("", default, _field), do: default

  defp decode_stored(json, default, field) when is_binary(json) do
    case Prima.Json.decode(json) do
      {:ok, value} ->
        value

      {:error, :invalid_json} ->
        Logger.warning(
          "[Sanctum.Providers.McpLog] stored #{field} is not valid JSON (#{byte_size(json)} bytes)"
        )

        default
    end
  end

  # `Arca.QueryHelpers.maybe_put/3`, which Arca does not export.
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp action_enum(tool) do
    [tool_def] = for t <- tools(), t.name == tool, do: t
    get_in(tool_def, [:input_schema, "properties", "action", "enum"])
  end
end
