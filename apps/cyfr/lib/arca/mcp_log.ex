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
    |> validate_inclusion(:status, ["pending", "success", "error"])
  end

  @doc """
  Creates a changeset for updating an existing MCP log entry.
  """
  def update_changeset(log, attrs) do
    log
    |> cast(attrs, [:status, :duration_ms, :routed_to, :error_code, :output, :error])
    |> validate_inclusion(:status, ["pending", "success", "error"])
  end

  @doc """
  Inserts a new MCP log entry.
  """
  def record(attrs) do
    attrs
    |> create_changeset()
    |> Arca.Repo.insert()
  end

  @doc """
  Updates an existing MCP log entry (e.g., on completion or failure).

  Uses tenant-scoped lookup when a context is provided.
  """
  def record_update(%Sanctum.Context{} = ctx, id, attrs) do
    case get_tenant(ctx, id) do
      nil -> {:error, :not_found}
      log -> log |> update_changeset(attrs) |> Arca.Repo.update()
    end
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
  def list(opts) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    status = Keyword.get(opts, :status)
    request_id = Keyword.get(opts, :request_id)
    tool = Keyword.get(opts, :tool)
    since = Keyword.get(opts, :since)
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    query =
      from l in __MODULE__,
        where: l.athanor_id == ^athanor_id,
        order_by: [desc: l.timestamp],
        limit: ^limit

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
  @spec get_tenant(Sanctum.Context.t(), String.t()) :: %__MODULE__{} | nil
  def get_tenant(%Sanctum.Context{} = ctx, id) do
    from(l in __MODULE__, where: l.id == ^id)
    |> Arca.QueryHelpers.where_tenant_unless_platform(ctx)
    |> Arca.Repo.one()
  end

  @doc """
  The distinct athanor ids that have log rows. Unscoped by design: the
  retention scheduler iterates every athanor and cleans each inside its own
  context.
  """
  @spec distinct_athanors() :: [String.t()]
  def distinct_athanors, do: Arca.QueryHelpers.distinct_athanors(__MODULE__)

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
  def stats(opts) do
    since = Keyword.get(opts, :since)
    user_id = Keyword.get(opts, :user_id)
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    query = from(l in __MODULE__, where: l.athanor_id == ^athanor_id)

    query = if since, do: where(query, [l], l.timestamp >= ^since), else: query
    query = if user_id, do: where(query, [l], l.user_id == ^user_id), else: query

    total = Arca.Repo.aggregate(query, :count)

    errors =
      query
      |> where([l], l.status == "error")
      |> Arca.Repo.aggregate(:count)

    avg_duration =
      case Arca.Repo.aggregate(query, :avg, :duration_ms) do
        nil -> 0
        # Postgres returns a Decimal for AVG(); SQLite returns a float.
        %Decimal{} = avg -> avg |> Decimal.to_float() |> round()
        avg -> round(avg)
      end

    %{total: total, errors: errors, avg_duration_ms: avg_duration}
  end
end
