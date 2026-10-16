# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.McpLog do
  @moduledoc """
  The MCP request log: the tenant-scoped readers and the retention
  primitives over `Arca.Schemas.McpLog`. Every row a function here
  answers is a plain map (`Arca.Data`).

  A row is written only as the projection of an admission decision, in
  the decision's own transaction (`Arca.DecisionLog.append/3` and
  `finish/4`, option `mcp_log:`); nothing here writes one.
  """

  import Ecto.Query

  alias Arca.Schemas.McpLog, as: Row

  @doc "Every status a log row can carry."
  @spec statuses() :: [String.t()]
  def statuses, do: Row.statuses()

  @doc """
  The actor's athanor's MCP logs, newest first, with optional filters.
  The athanor is the actor's: an `:athanor_id` among the options names
  nothing. An actor with no athanor is `{:error, :no_athanor}` before any
  row is read, whatever its scope.

  Options:
  - `:limit` - Maximum records to return (default: 20)
  - `:user_id` - Filter by user ID
  - `:status` - Filter by status
  - `:request_id` - Filter by ingress request (returns a whole chain)
  - `:tool` - Filter by tool name
  - `:since` - Filter logs after this DateTime
  """
  @spec list(Prima.Actor.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_athanor | :database_error}
  def list(%Prima.Actor{athanor_id: athanor_id}, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("McpLog.list", fn -> {:ok, do_list(athanor_id, opts)} end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, opts) when is_list(opts), do: {:error, :no_athanor}

  defp do_list(athanor_id, opts) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    status = Keyword.get(opts, :status)
    request_id = Keyword.get(opts, :request_id)
    tool = Keyword.get(opts, :tool)
    since = Keyword.get(opts, :since)

    query =
      from(l in Row,
        order_by: [desc: l.timestamp],
        limit: ^limit
      )
      |> Arca.QueryHelpers.where_athanor(athanor_id)

    query = if user_id, do: where(query, [l], l.user_id == ^user_id), else: query
    query = if status, do: where(query, [l], l.status == ^status), else: query
    query = if request_id, do: where(query, [l], l.request_id == ^request_id), else: query
    query = if tool, do: where(query, [l], l.tool == ^tool), else: query
    query = if since, do: where(query, [l], l.timestamp >= ^since), else: query

    Arca.Repo.all(query)
  end

  @doc """
  Gets an MCP log by ID, scoped to the given tenant context.

  Platform scope bypasses tenant filtering.
  """
  @spec get_tenant(Prima.Actor.t(), String.t()) :: map() | nil | {:error, :database_error}
  def get_tenant(%Prima.Actor{} = actor, id) do
    Arca.Repo.Errors.with_db_rescue("McpLog.get_tenant", fn -> row_of(actor, id) end)
    |> Arca.Data.project()
  end

  # arca:db-raise-ok inside the caller's rescue.
  defp row_of(actor, id) do
    from(l in Row, where: l.id == ^id)
    |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
    |> Arca.Repo.one()
  end

  @doc """
  Deletes all MCP logs with timestamps before the given datetime.

  Requires `:athanor_id` — deletion is always scoped to one athanor.

  Returns `{:ok, count}` — or `{:error, :database_error}` when the store cannot answer.
  """
  @spec delete_before(DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_before(%DateTime{} = datetime, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    Arca.Repo.Errors.with_db_rescue("Arca.McpLog.delete_before", fn ->
      {count, _} =
        Row
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.QueryHelpers.where_before(:timestamp, datetime)
        |> Arca.Repo.delete_all()

      {:ok, count}
    end)
  end

  @doc "How many rows `delete_before/2` would remove — the dry-run count."
  @spec count_before(DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_before(%DateTime{} = datetime, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    Arca.Repo.Errors.with_db_rescue("Arca.McpLog.count_before", fn ->
      count =
        Row
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.QueryHelpers.where_before(:timestamp, datetime)
        |> Arca.Repo.aggregate(:count)

      {:ok, count}
    end)
  end

  @doc """
  Aggregates the actor's athanor's log statistics. The athanor is the
  actor's: an `:athanor_id` among the options names nothing. An actor with
  no athanor is `{:error, :no_athanor}` before any row is read, whatever
  its scope.

  Options:
  - `:since` - Only include logs after this DateTime
  - `:user_id` - Scope stats to a specific user

  Returns a map with `:total`, `:errors`, and `:avg_duration_ms`.
  """
  @spec stats(Prima.Actor.t(), keyword()) ::
          {:ok, %{total: non_neg_integer(), errors: non_neg_integer(), avg_duration_ms: number()}}
          | {:error, :no_athanor | :database_error}
  def stats(%Prima.Actor{athanor_id: athanor_id}, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("McpLog.stats", fn ->
      since = Keyword.get(opts, :since)
      user_id = Keyword.get(opts, :user_id)

      query = Arca.QueryHelpers.where_athanor(Row, athanor_id)

      query = if since, do: where(query, [l], l.timestamp >= ^since), else: query
      query = if user_id, do: where(query, [l], l.user_id == ^user_id), else: query

      row =
        query
        |> select([l], %{
          total: count(l.id),
          errors: fragment("SUM(CASE WHEN ? = 'error' THEN 1 ELSE 0 END)", l.status),
          avg_duration: avg(l.duration_ms)
        })
        |> Arca.Repo.one()

      avg_duration =
        case row.avg_duration do
          nil -> 0
          # Postgres returns a Decimal for AVG(); SQLite returns a float.
          %Decimal{} = avg -> avg |> Decimal.to_float() |> round()
          avg -> round(avg)
        end

      {:ok,
       %{total: row.total, errors: normalize_count(row.errors), avg_duration_ms: avg_duration}}
    end)
  end

  def stats(%Prima.Actor{}, opts) when is_list(opts), do: {:error, :no_athanor}

  defp normalize_count(nil), do: 0
  defp normalize_count(%Decimal{} = d), do: Decimal.to_integer(d)
  defp normalize_count(n) when is_integer(n), do: n
  defp normalize_count(n) when is_float(n), do: round(n)
end
