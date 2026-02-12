defmodule Arca.McpLog do
  @moduledoc """
  Ecto schema for MCP request logs stored in SQLite.

  Stores the complete MCP request lifecycle including input/output payloads.

  ## Schema

  - `id` (PK) - Request ID (req_<uuid7>)
  - `session_id` - MCP session ID
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
    field :session_id, :string
    field :user_id, :string
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
  @optional_fields [:session_id, :tool, :action, :method, :duration_ms, :routed_to, :error_code, :input, :output, :error]

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
  """
  def record_update(id, attrs) do
    case Arca.Repo.get(__MODULE__, id) do
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
  - `:session_id` - Filter by session ID
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    status = Keyword.get(opts, :status)
    session_id = Keyword.get(opts, :session_id)

    query =
      from l in __MODULE__,
        order_by: [desc: l.timestamp],
        limit: ^limit

    query = if user_id, do: where(query, [l], l.user_id == ^user_id), else: query
    query = if status, do: where(query, [l], l.status == ^status), else: query
    query = if session_id, do: where(query, [l], l.session_id == ^session_id), else: query

    Arca.Repo.all(query)
  end

  @doc """
  Gets an MCP log by ID.
  """
  def get(id) do
    Arca.Repo.get(__MODULE__, id)
  end
end
