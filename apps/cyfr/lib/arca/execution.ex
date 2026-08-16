# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Execution do
  @moduledoc """
  Ecto schema for execution records.

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
    field :athanor_id, :string
    field :request_id, :string
    field :component_type, :string
    field :component_digest, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :status, :string, default: "running"
    field :error_message, :string
    field :input, :string
    field :output, :string
    field :host_policy, :string
    field :parent_execution_id, :string
    field :root_execution_id, :string
    field :resolver_digest, :string
    field :activation_digest, :string
    field :activation_graph, :string
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
      :athanor_id,
      :request_id,
      :component_type,
      :component_digest,
      :started_at,
      :status,
      :input,
      :host_policy,
      :parent_execution_id,
      :root_execution_id,
      :resolver_digest,
      :activation_digest,
      :activation_graph
    ])
    |> validate_required([
      :id,
      :reference,
      :user_id,
      :athanor_id,
      :started_at,
      :status,
      :component_type
    ])
    |> validate_inclusion(:status, ["running", "completed", "failed", "cancelled"])
    # Which component types exist is product vocabulary — sourced from the
    # canonical list rather than re-declared in the persistence layer.
    # Tinctures never execute server-side, hence executable_types.
    |> validate_inclusion(:component_type, Sanctum.ComponentRef.executable_types())
  end

  @doc """
  Creates a changeset for completing an execution.
  """
  def complete_changeset(execution, attrs) do
    execution
    |> cast(attrs, [:completed_at, :duration_ms, :status, :error_message, :output])
    |> validate_required([:completed_at, :duration_ms, :status])
    |> validate_inclusion(:status, ["completed", "failed", "cancelled"])
  end

  @doc """
  Records the start of an execution in the database.
  """
  def record_start(attrs) do
    attrs
    |> start_changeset()
    |> Arca.Repo.insert()
  end

  @doc """
  Records the completion of an execution in the database.

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
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    query =
      from e in __MODULE__,
        where: e.athanor_id == ^athanor_id,
        order_by: [desc: e.started_at],
        limit: ^limit,
        select:
          map(e, [
            :id,
            :reference,
            :input_hash,
            :user_id,
            :athanor_id,
            :request_id,
            :component_type,
            :component_digest,
            :started_at,
            :completed_at,
            :duration_ms,
            :status,
            :error_message,
            :parent_execution_id,
            :root_execution_id,
            :resolver_digest,
            :activation_digest
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

  Platform scope bypasses tenant filtering. Any other context is scoped via
  `where_tenant/2`, which raises for a context without an athanor (fail
  closed).
  """
  @spec get_tenant(Sanctum.Context.t(), String.t()) :: %__MODULE__{} | nil
  def get_tenant(%Sanctum.Context{} = ctx, id) do
    from(e in __MODULE__, where: e.id == ^id)
    |> Arca.QueryHelpers.where_tenant_unless_platform(ctx)
    |> Arca.Repo.one()
  end

  @doc """
  Deletes executions older than the newest `keep` records within an athanor.
  Members are interchangeable, so retention keeps the N most recent
  executions per athanor, not per user.
  """
  def delete_older_than(keep, opts) when is_list(opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    keep_ids_query =
      from e in __MODULE__,
        where: e.athanor_id == ^athanor_id,
        order_by: [desc: e.started_at],
        limit: ^keep,
        select: e.id

    delete_query =
      from e in __MODULE__,
        where: e.athanor_id == ^athanor_id,
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
  Lists IDs that would be deleted within an athanor (for dry_run).
  """
  def ids_to_delete(keep, opts) when is_list(opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    keep_ids_query =
      from e in __MODULE__,
        where: e.athanor_id == ^athanor_id,
        order_by: [desc: e.started_at],
        limit: ^keep,
        select: e.id

    from(e in __MODULE__,
      where: e.athanor_id == ^athanor_id,
      where: e.id not in subquery(keep_ids_query),
      select: e.id
    )
    |> Arca.Repo.all()
  end

  @doc """
  Returns the distinct athanor ids that have execution records, scoped to
  the given context's athanor (every athanor for :platform).
  """
  def distinct_athanors(%Sanctum.Context{} = ctx) do
    import Arca.QueryHelpers, only: [where_tenant: 2]

    query =
      from(e in __MODULE__,
        select: e.athanor_id,
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

  Scoped to the parent's own athanor. Legitimate children always inherit the
  parent's athanor when spawned, so this matches every real child while
  preventing a cross-athanor `parent_execution_id` from grafting a foreign
  execution into the parent's cancellation/failure cascade.
  """
  def list_running_children(parent_execution_id) do
    case Arca.Repo.get(__MODULE__, parent_execution_id) do
      %{athanor_id: athanor_id} ->
        from(e in __MODULE__,
          where: e.parent_execution_id == ^parent_execution_id,
          where: e.athanor_id == ^athanor_id,
          where: e.status == "running"
        )
        |> Arca.Repo.all()

      nil ->
        []
    end
  end

  @doc """
  Marks an execution as failed only if it's still 'running'. Returns {count, nil}.

  System-internal: the `id` originates from trusted runtime state — the
  cancellation cascade (`list_running_children/1`, already tenant-scoped) or the
  `Opus.ExecutionSweeper` GC's own scan — never from caller-supplied input. Do
  not call it with an id taken straight from a request.
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

  Intentionally spans all tenants: the `Opus.ExecutionSweeper` GC must reap
  orphaned 'running' rows left by a crashed BEAM, when no tenant context can be
  reconstructed. System-internal only — not reachable from a tenant request.
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
