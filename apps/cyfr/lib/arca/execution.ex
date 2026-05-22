# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
  require Logger
  require Arca.Repo.Errors

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "executions" do
    field :reference, :string
    field :input_hash, :string
    field :user_id, :string
    field :org_id, :string
    field :project_id, :string
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
    field :resolver_digest, :string
  end

  @doc """
  Creates a changeset for inserting a new execution record when starting.
  """
  def start_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :reference,
      :input_hash,
      :user_id,
      :org_id,
      :project_id,
      :request_id,
      :component_type,
      :component_digest,
      :started_at,
      :status,
      :input,
      :host_policy,
      :parent_execution_id,
      :resolver_digest
    ])
    |> validate_required([:id, :reference, :user_id, :started_at, :status])
    |> validate_inclusion(:status, ["running", "completed", "failed", "cancelled"])
    |> validate_inclusion(:component_type, ["catalyst", "reagent", "formula"])
    |> normalize_tenant_fields()
  end

  defp normalize_tenant_fields(changeset) do
    # Canonicalize to the seeded sentinels (nil/"" org → "local"), matching
    # how every query and the storage layer partition rows.
    changeset
    |> force_change(:org_id, Arca.QueryHelpers.normalize_org_id(get_field(changeset, :org_id)))
    |> force_change(
      :project_id,
      Arca.QueryHelpers.normalize_project_id(get_field(changeset, :project_id))
    )
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

  Uses tenant-scoped lookup when a context is provided.
  """
  def record_complete(%Sanctum.Context{} = ctx, id, attrs) do
    case get_tenant(ctx, id) do
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
  def list(opts) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    status = Keyword.get(opts, :status)
    org_id = Keyword.fetch!(opts, :org_id)
    project_id = Keyword.fetch!(opts, :project_id)

    query =
      from e in __MODULE__,
        where: e.org_id == ^org_id,
        where: e.project_id == ^project_id,
        order_by: [desc: e.started_at],
        limit: ^limit,
        select: map(e, [
          :id, :reference, :input_hash, :user_id, :org_id, :project_id,
          :request_id, :component_type, :component_digest,
          :started_at, :completed_at, :duration_ms, :status,
          :error_message, :parent_execution_id, :resolver_digest
        ])

    query = if user_id, do: where(query, [e], e.user_id == ^user_id), else: query

    query =
      if status && status != :all,
        do: where(query, [e], e.status == ^to_string(status)),
        else: query

    parent_id = Keyword.get(opts, :parent_execution_id)
    query = if parent_id, do: where(query, [e], e.parent_execution_id == ^parent_id), else: query

    Arca.Repo.all(query)
  end

  @doc """
  Gets an execution by ID, scoped to the given tenant context.

  Platform scope bypasses tenant filtering. A single-user context (nil org_id)
  matches the empty-string sentinel used by `normalize_tenant_fields/1`.
  """
  @spec get_tenant(Sanctum.Context.t(), String.t()) :: %__MODULE__{} | nil
  def get_tenant(%Sanctum.Context{scope: :platform}, id) do
    Arca.Repo.get(__MODULE__, id)
  end

  def get_tenant(%Sanctum.Context{} = ctx, id) do
    import Arca.QueryHelpers, only: [where_tenant: 2]

    from(e in __MODULE__, where: e.id == ^id)
    |> where_tenant(ctx)
    |> Arca.Repo.one()
  end

  @doc """
  Deletes executions older than the newest `keep` records for a user within a tenant.
  """
  def delete_older_than(user_id, keep, opts) when is_list(opts) do
    org_id = Keyword.fetch!(opts, :org_id)
    project_id = Keyword.fetch!(opts, :project_id)

    keep_ids_query =
      from e in __MODULE__,
        where: e.user_id == ^user_id,
        where: e.org_id == ^org_id,
        where: e.project_id == ^project_id,
        order_by: [desc: e.started_at],
        limit: ^keep,
        select: e.id

    delete_query =
      from e in __MODULE__,
        where: e.user_id == ^user_id,
        where: e.org_id == ^org_id,
        where: e.project_id == ^project_id,
        where: e.id not in subquery(keep_ids_query)

    Arca.Repo.delete_all(delete_query)
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[Arca.Execution] Database error in delete_older_than: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Lists IDs that would be deleted within a tenant (for dry_run).
  """
  def ids_to_delete(user_id, keep, opts) when is_list(opts) do
    org_id = Keyword.fetch!(opts, :org_id)
    project_id = Keyword.fetch!(opts, :project_id)

    keep_ids_query =
      from e in __MODULE__,
        where: e.user_id == ^user_id,
        where: e.org_id == ^org_id,
        where: e.project_id == ^project_id,
        order_by: [desc: e.started_at],
        limit: ^keep,
        select: e.id

    from(e in __MODULE__,
      where: e.user_id == ^user_id,
      where: e.org_id == ^org_id,
      where: e.project_id == ^project_id,
      where: e.id not in subquery(keep_ids_query),
      select: e.id
    )
    |> Arca.Repo.all()
  end

  @doc """
  Returns distinct {user_id, org_id, project_id} tuples for execution records,
  scoped to the given context's tenant.
  """
  def distinct_tenant_user_ids(%Sanctum.Context{} = ctx) do
    import Arca.QueryHelpers, only: [where_tenant: 2]

    query =
      from(e in __MODULE__,
        select: {e.user_id, e.org_id, e.project_id},
        distinct: true
      )

    query =
      case ctx.scope do
        :platform -> query
        _ -> where_tenant(query, ctx)
      end

    Arca.Repo.all(query)
  end

  @doc """
  Lists child executions still in 'running' state for a given parent.
  """
  def list_running_children(parent_execution_id) do
    from(e in __MODULE__,
      where: e.parent_execution_id == ^parent_execution_id,
      where: e.status == "running"
    )
    |> Arca.Repo.all()
  end

  @doc """
  Marks an execution as failed only if it's still 'running'. Returns {count, nil}.
  """
  def mark_failed_if_running(id, attrs) do
    from(e in __MODULE__,
      where: e.id == ^id,
      where: e.status == "running"
    )
    |> Arca.Repo.update_all(
      set: [
        status: "failed",
        completed_at: attrs[:completed_at],
        duration_ms: attrs[:duration_ms],
        error_message: attrs[:error_message]
      ]
    )
  end

  @doc """
  Lists executions stuck in 'running' older than cutoff (for startup sweep).
  """
  def list_stale_running(cutoff, limit \\ 50) do
    from(e in __MODULE__,
      where: e.status == "running",
      where: e.started_at < ^cutoff,
      order_by: [asc: e.started_at],
      limit: ^limit
    )
    |> Arca.Repo.all()
  end

  @doc """
  Computes SHA256 hash of input for deduplication.
  """
  def hash_input(input) when is_map(input) do
    case Jason.encode(input) do
      {:ok, json} ->
        json
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:error, _} ->
        nil
    end
  end

  def hash_input(_), do: nil
end