defmodule Arca.Execution do
  @moduledoc """
  Ecto schema for execution records stored in SQLite.

  Stores the complete execution lifecycle including input/output payloads,
  WASI traces, and host policy snapshots.

  ## Schema

  - `id` - Execution ID (exec_<uuid7>)
  - `request_id` - MCP request ID (req_<uuid7>) for cross-entity correlation
  - `reference` - JSON-encoded component reference
  - `input_hash` - SHA256 hash of input JSON (for deduplication)
  - `user_id` - User who initiated the execution
  - `component_type` - catalyst, reagent, or formula
  - `component_digest` - SHA256 digest of the WASM component
  - `started_at` - When execution started
  - `completed_at` - When execution finished (nil if running)
  - `duration_ms` - Execution duration in milliseconds
  - `status` - running, completed, failed, or cancelled
  - `error_message` - Error message if failed
  - `input` - JSON-encoded execution input
  - `output` - JSON-encoded execution output
  - `wasi_trace` - JSON-encoded WASI call trace
  - `host_policy` - JSON-encoded host policy snapshot
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "executions" do
    field :reference, :string
    field :input_hash, :string
    field :user_id, :string
    field :request_id, :string
    field :component_type, :string, default: "reagent"
    field :component_digest, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :status, :string, default: "running"
    field :error_message, :string
    field :input, :string
    field :output, :string
    field :wasi_trace, :string
    field :host_policy, :string
    field :parent_execution_id, :string
  end

  @doc """
  Creates a changeset for inserting a new execution record when starting.
  """
  def start_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:id, :reference, :input_hash, :user_id, :request_id,
                    :component_type, :component_digest, :started_at, :status,
                    :input, :host_policy, :parent_execution_id])
    |> validate_required([:id, :reference, :user_id, :started_at, :status])
    |> validate_inclusion(:status, ["running", "completed", "failed", "cancelled"])
    |> validate_inclusion(:component_type, ["catalyst", "reagent", "formula"])
  end

  @doc """
  Creates a changeset for completing an execution.
  """
  def complete_changeset(execution, attrs) do
    execution
    |> cast(attrs, [:completed_at, :duration_ms, :status, :error_message, :output, :wasi_trace])
    |> validate_required([:completed_at, :duration_ms, :status])
    |> validate_inclusion(:status, ["completed", "failed", "cancelled"])
  end

  @doc """
  Records the start of an execution in SQLite.
  """
  def record_start(attrs) do
    attrs
    |> start_changeset()
    |> Arca.Repo.insert()
  end

  @doc """
  Records the completion of an execution in SQLite.
  """
  def record_complete(id, attrs) do
    case Arca.Repo.get(__MODULE__, id) do
      nil ->
        {:error, :not_found}

      execution ->
        execution
        |> complete_changeset(attrs)
        |> Arca.Repo.update()
    end
  end

  @doc """
  Lists recent executions with optional filters.

  Options:
  - `:limit` - Maximum records to return (default: 20)
  - `:user_id` - Filter by user ID
  - `:status` - Filter by status
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    status = Keyword.get(opts, :status)

    query =
      from e in __MODULE__,
        order_by: [desc: e.started_at],
        limit: ^limit

    query = if user_id, do: where(query, [e], e.user_id == ^user_id), else: query
    query = if status && status != :all, do: where(query, [e], e.status == ^to_string(status)), else: query
    parent_id = Keyword.get(opts, :parent_execution_id)
    query = if parent_id, do: where(query, [e], e.parent_execution_id == ^parent_id), else: query

    Arca.Repo.all(query)
  end

  @doc """
  Gets an execution by ID.
  """
  def get(id) do
    Arca.Repo.get(__MODULE__, id)
  end

  @doc """
  Deletes executions older than the newest `keep` records for a given user.

  Returns the count of deleted records.
  """
  def delete_older_than(user_id, keep) do
    # Get IDs to keep (newest N)
    keep_ids_query =
      from e in __MODULE__,
        where: e.user_id == ^user_id,
        order_by: [desc: e.started_at],
        limit: ^keep,
        select: e.id

    # Delete all others for this user
    delete_query =
      from e in __MODULE__,
        where: e.user_id == ^user_id,
        where: e.id not in subquery(keep_ids_query)

    Arca.Repo.delete_all(delete_query)
  end

  @doc """
  Lists IDs that would be deleted (for dry_run).
  """
  def ids_to_delete(user_id, keep) do
    keep_ids_query =
      from e in __MODULE__,
        where: e.user_id == ^user_id,
        order_by: [desc: e.started_at],
        limit: ^keep,
        select: e.id

    from(e in __MODULE__,
      where: e.user_id == ^user_id,
      where: e.id not in subquery(keep_ids_query),
      select: e.id
    )
    |> Arca.Repo.all()
  end

  @doc """
  Returns distinct user_ids that have execution records.
  """
  def distinct_user_ids do
    from(e in __MODULE__, select: e.user_id, distinct: true)
    |> Arca.Repo.all()
  end

  @doc """
  Computes SHA256 hash of input for deduplication.
  """
  def hash_input(input) when is_map(input) do
    input
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def hash_input(_), do: nil
end
