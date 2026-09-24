# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PolicyLog do
  @moduledoc """
  The policy consultation log: recording a consultation, the
  tenant-scoped readers and the retention primitives over
  `Arca.Schemas.PolicyLog`. Every row a function here answers is a plain
  map (`Arca.Data`).
  """

  import Ecto.Query

  alias Arca.Schemas.PolicyLog, as: Row

  @doc """
  Inserts a new policy log entry.
  """
  @spec record(map()) :: {:ok, map()} | {:error, term()}
  def record(attrs) do
    Arca.Repo.Errors.with_db_rescue("PolicyLog.record", fn ->
      attrs
      |> Row.create_changeset()
      |> Arca.Repo.insert()
    end)
    |> Arca.Data.project()
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
  @spec list(keyword()) :: {:ok, [map()]} | {:error, :database_error}
  def list(opts) do
    Arca.Repo.Errors.with_db_rescue("PolicyLog.list", fn -> {:ok, do_list(opts)} end)
    |> Arca.Data.project()
  end

  defp do_list(opts) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    request_id = Keyword.get(opts, :request_id)
    execution_id = Keyword.get(opts, :execution_id)
    event_type = Keyword.get(opts, :event_type)
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    query =
      from(l in Row,
        where: l.athanor_id == ^athanor_id,
        order_by: [desc: l.timestamp],
        limit: ^limit
      )

    query = if user_id, do: where(query, [l], l.user_id == ^user_id), else: query
    query = if request_id, do: where(query, [l], l.request_id == ^request_id), else: query
    query = if execution_id, do: where(query, [l], l.execution_id == ^execution_id), else: query
    query = if event_type, do: where(query, [l], l.event_type == ^event_type), else: query

    rows = Arca.Repo.all(query)

    if Keyword.get(opts, :with_consent, false), do: join_consents(rows, athanor_id), else: rows
  end

  # Join attribution from immutable consent rows. Rows without consent_id
  # are returned unchanged.
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
        Row
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
        Row
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
  @spec get_tenant(Prima.Actor.t(), String.t()) :: map() | nil | {:error, :database_error}
  def get_tenant(%Prima.Actor{} = actor, id) do
    Arca.Repo.Errors.with_db_rescue("PolicyLog.get_tenant", fn ->
      from(l in Row, where: l.id == ^id)
      |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
      |> Arca.Repo.one()
    end)
    |> Arca.Data.project()
  end

  @doc """
  Gets a policy log by request_id, scoped to the given tenant context.

  Platform scope bypasses tenant filtering.
  """
  @spec get_by_request_id_tenant(Prima.Actor.t(), String.t()) ::
          map() | nil | {:error, :database_error}
  def get_by_request_id_tenant(%Prima.Actor{} = actor, request_id) do
    Arca.Repo.Errors.with_db_rescue("PolicyLog.get_by_request_id_tenant", fn ->
      from(l in Row, where: l.request_id == ^request_id, limit: 1)
      |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
      |> Arca.Repo.one()
    end)
    |> Arca.Data.project()
  end
end
