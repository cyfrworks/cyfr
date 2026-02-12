defmodule Arca.PolicyLog do
  @moduledoc """
  Ecto schema for policy consultation logs stored in SQLite.

  Stores complete policy consultation records including policy snapshots
  and decision reasons.

  ## Schema

  - `id` (PK) - Auto-generated ID
  - `request_id` - MCP request ID for correlation
  - `execution_id` - Execution ID if triggered by an execution
  - `session_id` - MCP session ID
  - `user_id` - User whose policy was consulted
  - `timestamp` - When the consultation occurred
  - `event_type` - policy_consultation/denied/violation
  - `component_ref` - Component being evaluated
  - `component_type` - catalyst/reagent/formula
  - `decision` - allowed/denied/default
  - `host_policy_snapshot` - JSON-encoded policy snapshot
  - `decision_reason` - Reason for the policy decision
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "policy_logs" do
    field :request_id, :string
    field :execution_id, :string
    field :session_id, :string
    field :user_id, :string
    field :timestamp, :utc_datetime_usec
    field :event_type, :string
    field :component_ref, :string
    field :component_type, :string
    field :decision, :string
    field :host_policy_snapshot, :string
    field :decision_reason, :string
  end

  @required_fields [:id, :user_id, :timestamp, :event_type]
  @optional_fields [:request_id, :execution_id, :session_id, :component_ref, :component_type, :decision, :host_policy_snapshot, :decision_reason]

  @doc """
  Creates a changeset for inserting a new policy log entry.
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Inserts a new policy log entry.
  """
  def record(attrs) do
    attrs
    |> create_changeset()
    |> Arca.Repo.insert()
  end

  @doc """
  Lists recent policy logs with optional filters.

  Options:
  - `:limit` - Maximum records to return (default: 20)
  - `:user_id` - Filter by user ID
  - `:request_id` - Filter by request ID
  - `:execution_id` - Filter by execution ID
  - `:event_type` - Filter by event type
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    request_id = Keyword.get(opts, :request_id)
    execution_id = Keyword.get(opts, :execution_id)
    event_type = Keyword.get(opts, :event_type)

    query =
      from l in __MODULE__,
        order_by: [desc: l.timestamp],
        limit: ^limit

    query = if user_id, do: where(query, [l], l.user_id == ^user_id), else: query
    query = if request_id, do: where(query, [l], l.request_id == ^request_id), else: query
    query = if execution_id, do: where(query, [l], l.execution_id == ^execution_id), else: query
    query = if event_type, do: where(query, [l], l.event_type == ^event_type), else: query

    Arca.Repo.all(query)
  end

  @doc """
  Gets a policy log by ID.
  """
  def get(id) do
    Arca.Repo.get(__MODULE__, id)
  end

  @doc """
  Gets a policy log by request_id.
  """
  def get_by_request_id(request_id) do
    from(l in __MODULE__, where: l.request_id == ^request_id, limit: 1)
    |> Arca.Repo.one()
  end
end
