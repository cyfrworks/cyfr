defmodule Arca.AuditEvent do
  @moduledoc """
  Ecto schema for audit events stored in SQLite.

  Stores complete audit events including event data payloads.

  ## Schema

  - `id` (PK) - Auto-generated ID
  - `request_id` - MCP request ID for correlation
  - `session_id` - MCP session ID
  - `user_id` - User who triggered the event
  - `timestamp` - When the event occurred
  - `event_type` - execution/auth/policy/secret_access
  - `data` - JSON-encoded event data
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "audit_events" do
    field :request_id, :string
    field :session_id, :string
    field :user_id, :string
    field :timestamp, :utc_datetime_usec
    field :event_type, :string
    field :data, :string
  end

  @required_fields [:id, :user_id, :timestamp, :event_type]
  @optional_fields [:request_id, :session_id, :data]

  @doc """
  Creates a changeset for inserting a new audit event entry.
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Inserts a new audit event entry.
  """
  def record(attrs) do
    attrs
    |> create_changeset()
    |> Arca.Repo.insert()
  end

  @doc """
  Lists recent audit events with optional filters.

  Options:
  - `:limit` - Maximum records to return (default: 20)
  - `:user_id` - Filter by user ID
  - `:request_id` - Filter by request ID
  - `:event_type` - Filter by event type
  - `:start_date` - Filter events after this date
  - `:end_date` - Filter events before this date
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    request_id = Keyword.get(opts, :request_id)
    event_type = Keyword.get(opts, :event_type)
    start_date = Keyword.get(opts, :start_date)
    end_date = Keyword.get(opts, :end_date)

    query =
      from e in __MODULE__,
        order_by: [desc: e.timestamp]

    query = if limit != :infinity, do: limit(query, ^limit), else: query
    query = if user_id, do: where(query, [e], e.user_id == ^user_id), else: query
    query = if request_id, do: where(query, [e], e.request_id == ^request_id), else: query
    query = if event_type, do: where(query, [e], e.event_type == ^event_type), else: query
    query = if start_date, do: where(query, [e], e.timestamp >= ^parse_date_start(start_date)), else: query
    query = if end_date, do: where(query, [e], e.timestamp <= ^parse_date_end(end_date)), else: query

    Arca.Repo.all(query)
  end

  @doc """
  Deletes audit events older than the given cutoff datetime.

  Returns `{count, nil}` where count is the number of deleted rows.
  """
  def delete_before(cutoff) do
    from(e in __MODULE__, where: e.timestamp < ^cutoff)
    |> Arca.Repo.delete_all()
  end

  @doc """
  Gets an audit event by ID.
  """
  def get(id) do
    Arca.Repo.get(__MODULE__, id)
  end

  # Parse a date string or Date to the start of day DateTime
  defp parse_date_start(%DateTime{} = dt), do: dt
  defp parse_date_start(%Date{} = d), do: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
  defp parse_date_start(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ ->
        case Date.from_iso8601(str) do
          {:ok, d} -> DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
          _ -> str
        end
    end
  end

  # Parse a date string or Date to the end of day DateTime
  defp parse_date_end(%DateTime{} = dt), do: dt
  defp parse_date_end(%Date{} = d), do: DateTime.new!(d, ~T[23:59:59.999999], "Etc/UTC")
  defp parse_date_end(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ ->
        case Date.from_iso8601(str) do
          {:ok, d} -> DateTime.new!(d, ~T[23:59:59.999999], "Etc/UTC")
          _ -> str
        end
    end
  end
end
