# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PolicyLog do
  @moduledoc """
  Ecto schema for policy consultation logs.

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
    field :org_id, :string, default: "local"
    field :project_id, :string, default: "default"
    field :timestamp, :utc_datetime_usec
    field :event_type, :string
    field :component_ref, :string
    field :component_type, :string
    field :decision, :string
    field :host_policy_snapshot, :string
    field :decision_reason, :string
  end

  @required_fields [:id, :user_id, :timestamp, :event_type]
  @optional_fields [
    :request_id,
    :execution_id,
    :session_id,
    :org_id,
    :project_id,
    :component_ref,
    :component_type,
    :decision,
    :host_policy_snapshot,
    :decision_reason
  ]

  @doc """
  Creates a changeset for inserting a new policy log entry.
  """
  def create_changeset(attrs) do
    changeset =
      %__MODULE__{}
      |> cast(attrs, @required_fields ++ @optional_fields)
      |> validate_required(@required_fields)

    changeset
    |> force_change(:org_id, Arca.QueryHelpers.normalize_org_id(get_field(changeset, :org_id)))
    |> force_change(
      :project_id,
      Arca.QueryHelpers.normalize_project_id(get_field(changeset, :project_id))
    )
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
  def list(opts) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    request_id = Keyword.get(opts, :request_id)
    execution_id = Keyword.get(opts, :execution_id)
    event_type = Keyword.get(opts, :event_type)
    org_id = Keyword.fetch!(opts, :org_id)
    project_id = Keyword.fetch!(opts, :project_id)

    query =
      from l in __MODULE__,
        where: l.org_id == ^org_id,
        where: l.project_id == ^project_id,
        order_by: [desc: l.timestamp],
        limit: ^limit

    query = if user_id, do: where(query, [l], l.user_id == ^user_id), else: query
    query = if request_id, do: where(query, [l], l.request_id == ^request_id), else: query
    query = if execution_id, do: where(query, [l], l.execution_id == ^execution_id), else: query
    query = if event_type, do: where(query, [l], l.event_type == ^event_type), else: query

    Arca.Repo.all(query)
  end

  @doc """
  Gets a policy log by ID, scoped to the given tenant context.

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
  Gets a policy log by request_id, scoped to the given tenant context.

  Platform scope bypasses tenant filtering.
  """
  @spec get_by_request_id_tenant(Sanctum.Context.t(), String.t()) :: %__MODULE__{} | nil
  def get_by_request_id_tenant(%Sanctum.Context{scope: :platform}, request_id) do
    from(l in __MODULE__, where: l.request_id == ^request_id, limit: 1)
    |> Arca.Repo.one()
  end

  def get_by_request_id_tenant(%Sanctum.Context{} = ctx, request_id) do
    import Arca.QueryHelpers, only: [where_tenant: 2]

    from(l in __MODULE__, where: l.request_id == ^request_id, limit: 1)
    |> where_tenant(ctx)
    |> Arca.Repo.one()
  end
end