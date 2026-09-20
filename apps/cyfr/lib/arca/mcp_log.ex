# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.McpLog do
  @moduledoc """
  Ecto schema for MCP request logs.

  Stores the complete MCP request lifecycle including input/output payloads.

  ## Schema

  - `id` (PK) - This call. For the request an ingress received, it is the
    request id; an in-chain call minted during that request has its own.
  - `request_id` - The ingress request every call in one chain shares. Group by
    this to see a formula's whole run: the `execution.run` that started it and
    each tool it reached from inside the sandbox.
  - `user_id` - User who made the request
  - `timestamp` - When the request was received
  - `tool` - Tool name (e.g., "execution", "storage")
  - `action` - Action within tool (e.g., "run", "get")
  - `method` - MCP method (e.g., "tools/call")
  - `status` - pending/success/error
  - `duration_ms` - Request duration in milliseconds
  - `routed_to` - Service that handled the request
  - `error_code` - JSON-RPC error code if failed
  - `input` - JSON-encoded request input
  - `output` - JSON-encoded response output
  - `error` - Error message if failed
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  # The request-log status vocabulary, in one place like its sibling stores.
  @statuses ~w(pending success error)

  @doc "Every status a log row can carry."
  def statuses, do: @statuses

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "mcp_logs" do
    field :request_id, :string
    field :user_id, :string
    field :athanor_id, :string
    field :timestamp, :utc_datetime_usec
    field :tool, :string
    field :action, :string
    field :method, :string
    field :status, :string, default: "pending"
    field :duration_ms, :integer
    field :routed_to, :string
    field :error_code, :integer
    field :input, :string
    field :output, :string
    field :error, :string
  end

  @required_fields [:id, :user_id, :athanor_id, :timestamp, :status]
  @optional_fields [
    :request_id,
    :tool,
    :action,
    :method,
    :duration_ms,
    :routed_to,
    :error_code,
    :input,
    :output,
    :error
  ]

  @doc """
  Creates a changeset for inserting a new MCP log entry.
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Creates a changeset for updating an existing MCP log entry.
  """
  def update_changeset(log, attrs) do
    log
    |> cast(attrs, [:status, :duration_ms, :routed_to, :error_code, :output, :error])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Inserts a new MCP log entry.
  """
  def record(attrs) do
    Arca.Repo.Errors.with_db_rescue("McpLog.record", fn ->
      attrs
      |> create_changeset()
      |> Arca.Repo.insert()
    end)
  end

  @doc """
  Inserts a started row only if none exists: the write-behind may land the
  call's close first, and a close carries the whole row.
  """
  def record_started(attrs) do
    Arca.Repo.Errors.with_db_rescue("McpLog.record_started", fn ->
      attrs
      |> create_changeset()
      |> Arca.Repo.insert(on_conflict: :nothing, conflict_target: :id)
    end)
  end

  @doc """
  Closes a call whose started row may or may not have landed: the whole
  row is written, and an existing row takes the close's fields.
  """
  def record_close(started, close) when is_map(started) and is_map(close) do
    Arca.Repo.Errors.with_db_rescue("McpLog.record_close", fn ->
      started
      |> Map.merge(close)
      |> create_changeset()
      |> Arca.Repo.insert(
        on_conflict:
          {:replace, [:status, :duration_ms, :routed_to, :error_code, :output, :error]},
        conflict_target: :id
      )
    end)
  end

  @doc """
  Updates an existing MCP log entry (e.g., on completion or failure).

  Uses tenant-scoped lookup when a context is provided.
  """
  # arca:unscoped-ok the row was fetched tenant-scoped by get_tenant/2 one line above.
  def record_update(%Cyfr.Actor{} = actor, id, attrs) do
    Arca.Repo.Errors.with_db_rescue("McpLog.record_update", fn ->
      case get_tenant(actor, id) do
        nil ->
          {:error, :not_found}

        # get_tenant is itself db-rescued: an outage answers a tuple here,
        # and binding it as the row would raise a non-DB error straight
        # through this rescue — crashing the RecordSink's whole batch.
        {:error, _} = err ->
          err

        log ->
          log |> update_changeset(attrs) |> Arca.Repo.update()
      end
    end)
  end

  @doc """
  Lists recent MCP logs with optional filters.

  Options:
  - `:limit` - Maximum records to return (default: 20)
  - `:user_id` - Filter by user ID
  - `:status` - Filter by status
  - `:request_id` - Filter by ingress request (returns a whole chain)
  - `:tool` - Filter by tool name
  - `:since` - Filter logs after this DateTime
  """
  @spec list(keyword()) :: {:ok, [%__MODULE__{}]} | {:error, :database_error}
  def list(opts) do
    Arca.Repo.Errors.with_db_rescue("McpLog.list", fn -> {:ok, do_list(opts)} end)
  end

  defp do_list(opts) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    status = Keyword.get(opts, :status)
    request_id = Keyword.get(opts, :request_id)
    tool = Keyword.get(opts, :tool)
    since = Keyword.get(opts, :since)
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    query =
      from(l in __MODULE__,
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
  @spec get_tenant(Cyfr.Actor.t(), String.t()) ::
          %__MODULE__{} | nil | {:error, :database_error}
  def get_tenant(%Cyfr.Actor{} = actor, id) do
    Arca.Repo.Errors.with_db_rescue("McpLog.get_tenant", fn ->
      from(l in __MODULE__, where: l.id == ^id)
      |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
      |> Arca.Repo.one()
    end)
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
        __MODULE__
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
        __MODULE__
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.QueryHelpers.where_before(:timestamp, datetime)
        |> Arca.Repo.aggregate(:count)

      {:ok, count}
    end)
  end

  @doc """
  Aggregates log statistics for logs since the given datetime.

  Options:
  - `:since` - Only include logs after this DateTime
  - `:user_id` - Scope stats to a specific user

  Returns a map with `:total`, `:errors`, and `:avg_duration_ms`.
  """
  @spec stats(keyword()) ::
          {:ok, %{total: non_neg_integer(), errors: non_neg_integer(), avg_duration_ms: number()}}
          | {:error, :database_error}
  def stats(opts) do
    Arca.Repo.Errors.with_db_rescue("McpLog.stats", fn ->
      since = Keyword.get(opts, :since)
      user_id = Keyword.get(opts, :user_id)
      athanor_id = Keyword.fetch!(opts, :athanor_id)

      query = Arca.QueryHelpers.where_athanor(__MODULE__, athanor_id)

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

  defp normalize_count(nil), do: 0
  defp normalize_count(%Decimal{} = d), do: Decimal.to_integer(d)
  defp normalize_count(n) when is_integer(n), do: n
  defp normalize_count(n) when is_float(n), do: round(n)
end
