# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CronSchedule do
  @moduledoc """
  Ecto schema for cron schedule records.

  Stores an athanor's recurring schedules for WASM component execution;
  `user_id` records who created a schedule (attribution), the athanor owns it.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, except: [update: 2]
  import Arca.QueryHelpers, only: [where_tenant: 2]

  alias Sanctum.Context

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "cron_schedules" do
    field :user_id, :string
    field :name, :string
    field :cron_expression, :string
    field :reference, :string
    field :resolved_reference, :string
    field :input, :string
    field :metadata, :string
    field :status, :string, default: "active"
    field :profile_id, :string
    field :athanor_id, :string
    field :last_run_at, :utc_datetime_usec
    field :next_run_at, :utc_datetime_usec
    field :last_execution_id, :string
    field :run_count, :integer, default: 0
    field :error_count, :integer, default: 0
    field :claimed_by, :string
    field :claim_expires_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc "Creates a new cron schedule."
  def create(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)

    %__MODULE__{}
    |> cast(Map.new(attrs), [
      :id,
      :user_id,
      :name,
      :cron_expression,
      :reference,
      :resolved_reference,
      :input,
      :metadata,
      :profile_id,
      :status,
      :athanor_id,
      :next_run_at,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :id,
      :user_id,
      :name,
      :cron_expression,
      :reference,
      :profile_id,
      :athanor_id,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:status, ["active", "paused", "deleted", "needs_consent"])
    |> Arca.Repo.insert()
  end

  @doc "Updates an existing cron schedule with tenant-scoped lookup."
  def update(%Context{} = ctx, id, attrs) do
    case get_tenant(ctx, id) do
      nil ->
        {:error, :not_found}

      schedule ->
        attrs = Map.put(attrs, :updated_at, DateTime.utc_now())

        schedule
        |> cast(Map.new(attrs), [
          :name,
          :cron_expression,
          :reference,
          :resolved_reference,
          :input,
          :metadata,
          :profile_id,
          :status,
          :next_run_at,
          :last_run_at,
          :last_execution_id,
          :run_count,
          :error_count,
          :updated_at
        ])
        |> Arca.Repo.update()
    end
  end

  @doc "Gets a schedule by ID with tenant-scoped lookup."
  def get(%Context{} = ctx, id) do
    get_tenant(ctx, id)
  end

  @doc """
  Gets a schedule by ID (unscoped).

  Reserved for the CronScheduler daemon which needs to load schedules
  before a tenant context can be constructed (chicken-and-egg: we need
  the schedule's user_id/athanor_id to build a context).
  """
  def get_for_daemon(id) do
    Arca.Repo.get(__MODULE__, id)
  end

  @doc "Gets one of the athanor's schedules by either ID or name."
  def get_by_id_or_name(%Context{} = ctx, id_or_name) do
    from(s in __MODULE__,
      where: s.status != "deleted",
      where: s.id == ^id_or_name or s.name == ^id_or_name
    )
    |> where_tenant(ctx)
    |> Arca.Repo.one()
  end

  @doc "Lists the athanor's schedules, newest first."
  def list(%Context{} = ctx, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(s in __MODULE__,
      where: s.status != "deleted",
      order_by: [desc: s.created_at],
      limit: ^limit
    )
    |> where_tenant(ctx)
    |> Arca.Repo.all()
  end

  @doc """
  Returns all active schedules (unscoped).

  Intentionally unscoped — called by the CronScheduler daemon which iterates
  all tenants' schedules to determine what needs firing. The daemon constructs
  a per-schedule `Context` from `user_id`/`athanor_id` before executing, same
  rationale as `get_for_daemon/1`.
  """
  def active_schedules do
    from(s in __MODULE__,
      where: s.status == "active",
      order_by: [asc: s.next_run_at]
    )
    |> Arca.Repo.all()
  end

  @doc """
  Take the schedule for one firing: a compare-and-set that succeeds only when
  no live claim is held. Several nodes sharing the database race here and
  exactly one wins; a claimant that dies is superseded once its claim lapses.
  Returns `:claimed` or `:held`.
  """
  @spec claim(String.t(), String.t(), pos_integer()) :: :claimed | :held
  def claim(id, node_name, ttl_seconds) when is_binary(id) and is_binary(node_name) do
    now = DateTime.utc_now()
    expires = DateTime.add(now, ttl_seconds, :second)

    {count, _} =
      from(s in __MODULE__,
        where: s.id == ^id and s.status == "active",
        where: is_nil(s.claim_expires_at) or s.claim_expires_at < ^now
      )
      |> Arca.Repo.update_all(set: [claimed_by: node_name, claim_expires_at: expires])

    if count == 1, do: :claimed, else: :held
  end

  @doc "Give a claim back once the firing is over (only the claimant's own)."
  @spec release_claim(String.t(), String.t()) :: :ok
  def release_claim(id, node_name) when is_binary(id) and is_binary(node_name) do
    from(s in __MODULE__, where: s.id == ^id and s.claimed_by == ^node_name)
    |> Arca.Repo.update_all(set: [claimed_by: nil, claim_expires_at: nil])

    :ok
  end

  @doc "Records a successful run with tenant-scoped lookup."
  def record_run(%Context{} = ctx, id, execution_id) do
    case get_tenant(ctx, id) do
      nil -> {:error, :not_found}
      schedule -> do_record_run(schedule, execution_id)
    end
  end

  defp do_record_run(schedule, execution_id) do
    schedule
    |> cast(
      %{
        last_run_at: DateTime.utc_now(),
        last_execution_id: execution_id,
        run_count: schedule.run_count + 1,
        updated_at: DateTime.utc_now()
      },
      [:last_run_at, :last_execution_id, :run_count, :updated_at]
    )
    |> Arca.Repo.update()
  end

  @doc "Records an error with tenant-scoped lookup."
  def record_error(%Context{} = ctx, id, reason) do
    case get_tenant(ctx, id) do
      nil -> {:error, :not_found}
      schedule -> do_record_error(schedule, reason)
    end
  end

  defp do_record_error(schedule, _reason) do
    schedule
    |> cast(
      %{
        error_count: schedule.error_count + 1,
        updated_at: DateTime.utc_now()
      },
      [:error_count, :updated_at]
    )
    |> Arca.Repo.update()
  end

  @doc "Soft-deletes a schedule with tenant-scoped lookup."
  def soft_delete(%Context{} = ctx, id) do
    case get_tenant(ctx, id) do
      nil -> {:error, :not_found}
      schedule -> do_soft_delete(schedule)
    end
  end

  defp do_soft_delete(schedule) do
    schedule
    |> cast(%{status: "deleted", updated_at: DateTime.utc_now()}, [:status, :updated_at])
    |> Arca.Repo.update()
  end

  @doc "Counts the athanor's active schedules."
  def count_active(%Context{} = ctx) do
    from(s in __MODULE__,
      where: s.status != "deleted",
      select: count(s.id)
    )
    |> where_tenant(ctx)
    |> Arca.Repo.one()
  end

  @doc "Gets a schedule by ID, scoped to the given tenant context."
  @spec get_tenant(Context.t(), String.t()) :: %__MODULE__{} | nil
  def get_tenant(%Context{scope: :platform}, id) do
    Arca.Repo.get(__MODULE__, id)
  end

  def get_tenant(%Context{} = ctx, id) do
    from(s in __MODULE__, where: s.id == ^id)
    |> where_tenant(ctx)
    |> Arca.Repo.one()
  end

  defp generate_id do
    "sched_" <> Ecto.UUID.generate()
  end
end
