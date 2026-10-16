# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.PolicyLog do
  @moduledoc """
  The `policy_log` tool over the policy consultation log
  (`Arca.PolicyLog`): one row per consultation of a policy, its decision
  and why. The rows are security rows, so Sanctum is their one reader.

  The provider declares `context_kind: :actor`: the gate authorizes every
  call with the caller's full context and hands these handlers the
  `Prima.Actor` it projects, and nothing else. What remains here is the
  residual the annotations cannot express: the log is tenant-scoped, so an
  actor with no athanor is refused before any row is read. An actor of
  `:platform` scope passes that check, and the log's readers decide what it
  reads: `get` finds a row in any athanor, and `list` and `correlate` read
  one athanor's rows, the actor's.

  The request log's correlation (`Sanctum.Providers.McpLog`) renders a
  request's policy logs through this door's projection
  (`policy_log_to_map/1`).
  """

  @behaviour Prima.Provider

  require Logger

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
            "policy_log",
            "list",
            "List policy log",
            [
              Arg.new("request_id", :string, description: "Filter by request ID"),
              Arg.new("execution_id", :string, description: "Filter by execution ID"),
              Arg.new("user_id", :string, description: "Filter by user ID"),
              Arg.new("event_type", :string, description: "Filter by event type"),
              Arg.new("limit", :integer, description: "Max results (default: 20)")
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "policy_log",
            "get",
            "Get policy log",
            [Arg.new("id", :string, required: true, description: "Policy log ID")],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "policy_log",
            "correlate",
            "Correlate policy log",
            [Arg.new("request_id", :string, required: true, description: "Filter by request ID")],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          )
        ],
        description: "Query policy consultation logs - list, get, or correlate logs",
        title: "Policy Logs"
      )
    ]
  end

  # ============================================================================
  # Handlers
  # ============================================================================

  @impl true
  def handle("policy_log", %Prima.Actor{} = actor, %{"action" => "get", "id" => id}) do
    with :ok <- tenant_ok(actor) do
      # A log is found by its own id, or by the request it was made under.
      # Both reads are db-rescued and answer a tuple on an outage: the
      # storage refusal here rather than a row.
      case Arca.PolicyLog.get_tenant(actor, id) do
        nil -> by_request(actor, id)
        found -> answer(found, id)
      end
    end
  end

  def handle("policy_log", %Prima.Actor{}, %{"action" => "get"}) do
    {:error, {:invalid_argument, "Missing required argument: id"}}
  end

  def handle("policy_log", %Prima.Actor{} = actor, %{"action" => "list"} = args) do
    with :ok <- tenant_ok(actor) do
      opts =
        [limit: min(args["limit"] || 20, 1000)]
        |> maybe_put(:user_id, args["user_id"])
        |> maybe_put(:request_id, args["request_id"])
        |> maybe_put(:execution_id, args["execution_id"])
        |> maybe_put(:event_type, args["event_type"])

      case Arca.PolicyLog.list(actor, opts) do
        {:ok, records} -> {:ok, %{logs: Enum.map(records, &policy_log_to_map/1)}}
        {:error, :no_athanor} -> {:error, :missing_tenant}
        {:error, :database_error} -> {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle("policy_log", %Prima.Actor{} = actor, %{
        "action" => "correlate",
        "request_id" => request_id
      }) do
    with :ok <- tenant_ok(actor) do
      policy_logs =
        case Arca.PolicyLog.list(actor, request_id: request_id, limit: 100) do
          {:ok, rows} -> Enum.map(rows, &policy_log_to_map/1)
          {:error, _} -> []
        end

      {:ok, %{request_id: request_id, policy_logs: policy_logs}}
    end
  end

  def handle("policy_log", %Prima.Actor{}, %{"action" => "correlate"}) do
    {:error, {:invalid_argument, "Missing required argument: request_id"}}
  end

  def handle("policy_log", %Prima.Actor{}, _args) do
    {:error, Prima.Provider.invalid_action("policy_log", action_enum("policy_log"))}
  end

  def handle(tool, %Prima.Actor{}, _args), do: {:error, {:not_found, "tool", tool}}

  defp by_request(actor, id), do: answer(Arca.PolicyLog.get_by_request_id_tenant(actor, id), id)

  defp answer(nil, id), do: {:error, {:not_found, "Policy log", id}}
  defp answer({:error, :database_error}, _id), do: {:error, {:unavailable, "Storage"}}
  defp answer(record, _id), do: {:ok, policy_log_to_map(record)}

  # ============================================================================
  # Tenancy
  # ============================================================================

  # The log is tenant-scoped: an actor with no athanor is refused before it
  # can reach any athanor's rows. A `:platform` scope actor passes here;
  # the log's own readers decide what it reads.
  defp tenant_ok(%Prima.Actor{scope: :platform}), do: :ok
  defp tenant_ok(%Prima.Actor{athanor_id: id}) when is_binary(id) and id != "", do: :ok
  defp tenant_ok(%Prima.Actor{}), do: {:error, :missing_tenant}

  # ============================================================================
  # The projection
  # ============================================================================

  @doc false
  # A policy log as the wire carries it. The request log's correlation
  # renders a request's policy logs through it.
  @spec policy_log_to_map(map()) :: map()
  def policy_log_to_map(%{id: _} = log) do
    %{
      id: log.id,
      request_id: log.request_id,
      execution_id: log.execution_id,
      user_id: log.user_id,
      timestamp: Prima.Time.iso8601(log.timestamp),
      event_type: log.event_type,
      component_ref: log.component_ref,
      component_type: log.component_type,
      decision: log.decision,
      host_policy_snapshot: decode_json(log.host_policy_snapshot, "host_policy_snapshot"),
      decision_reason: log.decision_reason
    }
  end

  defp decode_json(nil, _field), do: nil

  # An audit field: corrupt JSON must read AS corruption, never silently
  # pass through as a string where a map was recorded.
  defp decode_json(str, field) when is_binary(str),
    do: decode_stored(str, %{"_decode_error" => "stored snapshot was not valid JSON"}, field)

  defp decode_json(val, _field), do: val

  # A stored JSON column that does not decode reads as its default. The
  # line names the column and its size, never its bytes. `decode_json/2`
  # answers nil itself.
  defp decode_stored(json, default, field) do
    case Prima.Json.decode_stored(json, default) do
      {:ok, value} ->
        value

      {:error, :invalid_json} ->
        Logger.warning(
          "[Sanctum.Providers.PolicyLog] stored #{field} is not valid JSON (#{byte_size(json)} bytes)"
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
