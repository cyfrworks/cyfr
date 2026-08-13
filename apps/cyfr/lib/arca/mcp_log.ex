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
  require Logger
  require Arca.Repo.Errors

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "mcp_logs" do
    field :request_id, :string
    field :user_id, :string
    field :org_id, :string, default: ""
    field :project_id, :string, default: "default"
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

  @required_fields [:id, :user_id, :timestamp, :status]
  @optional_fields [
    :request_id,
    :org_id,
    :project_id,
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
    |> normalize_tenant_fields()
  end

  # Canonicalize to the seeded sentinels so the tenant-scoped record_update
  # (via where_tenant/2) matches: nil/"" org → "local".
  defp normalize_tenant_fields(changeset) do
    changeset
    |> force_change(:org_id, Arca.QueryHelpers.normalize_org_id(get_field(changeset, :org_id)))
    |> force_change(
      :project_id,
      Arca.QueryHelpers.normalize_project_id(get_field(changeset, :project_id))
    )
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
    org_id = Arca.QueryHelpers.normalize_org_id(Keyword.fetch!(opts, :org_id))
    project_id = Arca.QueryHelpers.normalize_project_id(Keyword.fetch!(opts, :project_id))

    query =
      from l in __MODULE__,
        order_by: [desc: l.timestamp],
        limit: ^limit

    query = if user_id, do: where(query, [l], l.user_id == ^user_id), else: query
    query = if status, do: where(query, [l], l.status == ^status), else: query
    query = if request_id, do: where(query, [l], l.request_id == ^request_id), else: query
    query = if tool, do: where(query, [l], l.tool == ^tool), else: query
    query = if since, do: where(query, [l], l.timestamp >= ^since), else: query
    query = where(query, [l], l.org_id == ^org_id)
    query = where(query, [l], l.project_id == ^project_id)

    Arca.Repo.all(query)
  end

  @doc """
  Gets an MCP log by ID, scoped to the given tenant context.

  Platform scope bypasses tenant filtering.
  """
  @spec get_tenant(Sanctum.Context.t(), String.t()) :: %__MODULE__{} | nil
  def get_tenant(%Sanctum.Context{scope: :platform}, id) do
    Arca.Repo.get(__MODULE__, id)
  end

  def get_tenant(%Sanctum.Context{} = ctx, id) do
    import Arca.QueryHelpers, only: [where_tenant: 2]

    from(l in __MODULE__, where: l.id == ^id)
    |> where_tenant(ctx)
    |> Arca.Repo.one()
  end

  @doc """
  Deletes all MCP logs with timestamps before the given datetime.

  Accepts optional tenant filters:
  - `:org_id` - Scope deletion to a specific org
  - `:project_id` - Scope deletion to a specific project

  Returns `{count, nil}` where count is the number of deleted records.
  """
  def delete_before(%DateTime{} = datetime, opts) do
    org_id = Arca.QueryHelpers.normalize_org_id(Keyword.fetch!(opts, :org_id))
    project_id = Arca.QueryHelpers.normalize_project_id(Keyword.fetch!(opts, :project_id))

    query =
      from(l in __MODULE__,
        where: l.timestamp < ^datetime,
        where: l.org_id == ^org_id,
        where: l.project_id == ^project_id
      )

    Arca.Repo.delete_all(query)
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.McpLog] Database error in delete_before: #{Exception.message(e)}")
      {:error, :database_error}
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
    org_id = Arca.QueryHelpers.normalize_org_id(Keyword.fetch!(opts, :org_id))
    project_id = Arca.QueryHelpers.normalize_project_id(Keyword.fetch!(opts, :project_id))

    query =
      from(l in __MODULE__,
        where: l.org_id == ^org_id,
        where: l.project_id == ^project_id
      )

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
