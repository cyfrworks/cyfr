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
    field :user_id, :string
    field :athanor_id, :string
    field :timestamp, :utc_datetime_usec
    field :event_type, :string
    field :component_ref, :string
    field :component_type, :string
    field :decision, :string
    field :host_policy_snapshot, :string
    field :decision_reason, :string
    field :consent_id, :string
    field :activation_digest, :string
    field :dep_ref, :string
    field :need, :string
    field :cursor_state, :string
    field :chain, :string
    field :value_source, :string
  end

  @required_fields [:id, :user_id, :athanor_id, :timestamp, :event_type]
  @optional_fields [
    :request_id,
    :execution_id,
    :component_ref,
    :component_type,
    :decision,
    :host_policy_snapshot,
    :decision_reason,
    :consent_id,
    :activation_digest,
    :dep_ref,
    :need,
    :cursor_state,
    :chain,
    :value_source
  ]

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
  def list(opts) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    request_id = Keyword.get(opts, :request_id)
    execution_id = Keyword.get(opts, :execution_id)
    event_type = Keyword.get(opts, :event_type)
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    query =
      from l in __MODULE__,
        where: l.athanor_id == ^athanor_id,
        order_by: [desc: l.timestamp],
        limit: ^limit

    query = if user_id, do: where(query, [l], l.user_id == ^user_id), else: query
    query = if request_id, do: where(query, [l], l.request_id == ^request_id), else: query
    query = if execution_id, do: where(query, [l], l.execution_id == ^execution_id), else: query
    query = if event_type, do: where(query, [l], l.event_type == ^event_type), else: query

    rows = Arca.Repo.all(query)

    if Keyword.get(opts, :with_consent, false), do: join_consents(rows, athanor_id), else: rows
  end

  # §4.5 stored-vs-derived: attribution is JOINED from the consent, never
  # copied onto the row. Consents are immutable, so the join is stable —
  # and a hot-path write stays small. Rows with no consent_id come back
  # untouched.
  defp join_consents(rows, athanor_id) do
    consent_ids = rows |> Enum.map(& &1.consent_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if consent_ids == [] do
      rows
    else
      attribution =
        from(c in Arca.Schemas.Consent,
          join: p in Arca.Schemas.Profile,
          on: p.id == c.profile_id and p.athanor_id == c.athanor_id,
          where: c.id in ^consent_ids and c.athanor_id == ^athanor_id,
          select:
            {c.id,
             %{
               granted_by: c.granted_by,
               granted_via: c.granted_via,
               granted_at: c.granted_at,
               revision: c.revision,
               scope: c.scope,
               profile_kind: p.kind,
               source_ref: p.source_ref
             }}
        )
        |> Arca.Repo.all()
        |> Map.new()

      Enum.map(rows, fn row ->
        case Map.get(attribution, row.consent_id) do
          nil -> row
          consent -> Map.put(row, :consent, consent)
        end
      end)
    end
  end

  @doc """
  Deletes all policy logs with timestamps before the given datetime.

  Requires `:athanor_id` — deletion is always scoped to one athanor.

  Returns `{:ok, count}` — or `{:error, :database_error}` when the store cannot answer.
  """
  @spec delete_before(DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_before(%DateTime{} = datetime, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    Arca.Repo.Errors.with_db_rescue("Arca.PolicyLog.delete_before", fn ->
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

    Arca.Repo.Errors.with_db_rescue("Arca.PolicyLog.count_before", fn ->
      count =
        __MODULE__
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.QueryHelpers.where_before(:timestamp, datetime)
        |> Arca.Repo.aggregate(:count)

      {:ok, count}
    end)
  end

  @doc """
  Gets a policy log by ID, scoped to the given tenant context.

  Platform scope bypasses tenant filtering.
  """
  @spec get_tenant(Sanctum.Context.t(), String.t()) :: %__MODULE__{} | nil
  def get_tenant(%Sanctum.Context{} = ctx, id) do
    from(l in __MODULE__, where: l.id == ^id)
    |> Arca.QueryHelpers.where_tenant_unless_platform(ctx)
    |> Arca.Repo.one()
  end

  @doc """
  Gets a policy log by request_id, scoped to the given tenant context.

  Platform scope bypasses tenant filtering.
  """
  @spec get_by_request_id_tenant(Sanctum.Context.t(), String.t()) :: %__MODULE__{} | nil
  def get_by_request_id_tenant(%Sanctum.Context{} = ctx, request_id) do
    from(l in __MODULE__, where: l.request_id == ^request_id, limit: 1)
    |> Arca.QueryHelpers.where_tenant_unless_platform(ctx)
    |> Arca.Repo.one()
  end
end
