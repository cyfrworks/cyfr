# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CronSchedule do
  @moduledoc """
  Row-plane storage for an athanor's cron schedules
  (`Arca.Schemas.CronSchedule`); `user_id` records who created a schedule
  (attribution), the athanor owns it.

  Uses the `Arca.QueryHelpers` return convention: database failures return
  `{:error, :database_error}`, missing rows return `{:error, :not_found}`,
  and validation returns `{:error, {:validation, %{field => [message]}}}`.
  Every schedule a function here answers is a plain map (`Arca.Data`);
  raw changesets do not leave the storage layer.
  """

  import Ecto.Query, except: [update: 2]
  import Arca.QueryHelpers, only: [where_tenant_unless_platform: 2]
  # Every function that names a tenant takes the `Prima.Actor` first and
  # reads a schedule through `get_tenant/2`, whose platform bypass is the
  # shared `where_tenant_unless_platform/2`. A platform-scope actor
  # carries no athanor by design, so these match the actor and leave the
  # refusal to that backstop; `get_for_daemon/1` reads unscoped and says
  # why where it stands.

  alias Arca.Repo.Errors
  alias Arca.Schemas.CronSchedule, as: Row

  @doc "The status vocabulary this table's rows may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: Row.statuses()

  @doc "Creates a new cron schedule."
  @spec create(map()) ::
          {:ok, map()}
          | {:error, {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the athanor arrives in attrs and is validated required before the insert.
  def create(attrs) do
    Errors.with_db_rescue("CronSchedule.create", fn ->
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.put_new(:id, Prima.UUID7.generate_id("sched"))
        |> Map.put_new(:created_at, now)
        |> Map.put_new(:updated_at, now)

      attrs
      |> Row.create_changeset()
      |> Arca.Repo.insert()
      |> mapped_validation()
    end)
    |> Arca.Data.project()
  end

  @doc "Updates an existing cron schedule with tenant-scoped lookup."
  @spec update(Prima.Actor.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the row was fetched tenant-scoped by get_tenant/2 in the same with.
  def update(%Prima.Actor{} = actor, id, attrs) do
    Errors.with_db_rescue("CronSchedule.update", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        attrs = Map.put(attrs, :updated_at, DateTime.utc_now())

        schedule
        |> Row.update_changeset(attrs)
        |> Arca.Repo.update()
        |> mapped_validation()
      end
    end)
    |> Arca.Data.project()
  end

  @doc "Gets a schedule by ID with tenant-scoped lookup."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
  def get(%Prima.Actor{} = actor, id) do
    Errors.with_db_rescue("CronSchedule.get", fn -> get_tenant(actor, id) end)
    |> Arca.Data.project()
  end

  @doc """
  Gets a schedule by ID (unscoped).

  Reserved for the scheduler daemon, which needs to load schedules
  before a tenant context can be constructed (chicken-and-egg: we need
  the schedule's user_id/athanor_id to build a context).
  """
  @spec get_for_daemon(String.t()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
  # arca:unscoped-ok the daemon reads the row to LEARN the athanor it must
  # build a context from — scoping first would need the answer it is asking for.
  def get_for_daemon(id) do
    Errors.with_db_rescue("CronSchedule.get_for_daemon", fn ->
      case Arca.Repo.get(Row, id) do
        nil -> {:error, :not_found}
        schedule -> {:ok, schedule}
      end
    end)
    |> Arca.Data.project()
  end

  @doc "Gets one of the athanor's schedules by either ID or name."
  @spec get_by_id_or_name(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
  def get_by_id_or_name(%Prima.Actor{} = actor, id_or_name) do
    Errors.with_db_rescue("CronSchedule.get_by_id_or_name", fn ->
      from(s in Row,
        where: s.status != "deleted",
        where: s.id == ^id_or_name or s.name == ^id_or_name
      )
      |> where_tenant_unless_platform(actor)
      |> Arca.Repo.one()
      |> case do
        nil -> {:error, :not_found}
        schedule -> {:ok, schedule}
      end
    end)
    |> Arca.Data.project()
  end

  @doc "Lists the athanor's schedules, newest first."
  @spec list(Prima.Actor.t(), keyword()) ::
          {:ok, [map()]} | {:error, :database_error}
  def list(actor, opts \\ [])

  def list(%Prima.Actor{} = actor, opts) do
    Errors.with_db_rescue("CronSchedule.list", fn ->
      limit = Keyword.get(opts, :limit, 50)

      rows =
        from(s in Row,
          where: s.status != "deleted",
          order_by: [desc: s.created_at],
          limit: ^limit
        )
        |> where_tenant_unless_platform(actor)
        |> Arca.Repo.all()

      {:ok, rows}
    end)
    |> Arca.Data.project()
  end

  @doc """
  Returns all active schedules (unscoped).

  Unscoped daemon query. The scheduler constructs a context from each
  schedule's `user_id` and `athanor_id` before executing it.
  """
  @spec active_schedules() :: {:ok, [map()]} | {:error, :database_error}
  # arca:unscoped-ok the firing loop walks every athanor by design, then runs
  # each schedule inside a context built from its own row.
  def active_schedules do
    Errors.with_db_rescue("CronSchedule.active_schedules", fn ->
      rows =
        from(s in Row,
          where: s.status == "active",
          order_by: [asc: s.next_run_at]
        )
        |> Arca.Repo.all()

      {:ok, rows}
    end)
    |> Arca.Data.project()
  end

  @doc "Records a successful run with tenant-scoped lookup."
  @spec record_run(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok get_tenant/2 in the same with establishes row ownership.
  # Increment atomically; concurrent runs must not overwrite each other’s counts.
  def record_run(%Prima.Actor{} = actor, id, execution_id) do
    Errors.with_db_rescue("CronSchedule.record_run", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        now = DateTime.utc_now()

        from(s in Row, where: s.id == ^schedule.id)
        |> Arca.Repo.update_all(
          set: [last_run_at: now, last_execution_id: execution_id, updated_at: now],
          inc: [run_count: 1]
        )

        get_tenant(actor, id)
      end
    end)
    |> Arca.Data.project()
  end

  @doc "Records an error with tenant-scoped lookup."
  @spec record_error(Prima.Actor.t(), String.t(), term()) ::
          {:ok, map()}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the row was fetched tenant-scoped by get_tenant/2 in the same with.
  # Atomic increment, for the reason spelled out at `record_run/3`.
  def record_error(%Prima.Actor{} = actor, id, _reason) do
    Errors.with_db_rescue("CronSchedule.record_error", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        from(s in Row, where: s.id == ^schedule.id)
        |> Arca.Repo.update_all(
          set: [updated_at: DateTime.utc_now()],
          inc: [error_count: 1]
        )

        get_tenant(actor, id)
      end
    end)
    |> Arca.Data.project()
  end

  @doc "Soft-deletes a schedule with tenant-scoped lookup."
  @spec soft_delete(Prima.Actor.t(), String.t()) ::
          {:ok, map()}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  def soft_delete(%Prima.Actor{} = actor, id) do
    Errors.with_db_rescue("CronSchedule.soft_delete", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        schedule
        |> Row.delete_changeset(DateTime.utc_now())
        |> Arca.Repo.update()
        |> mapped_validation()
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Counts non-deleted schedules occupying the athanor’s cap slots.
  Paused schedules retain their slots; resuming does not require a cap check.
  """
  @spec count_active(Prima.Actor.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_active(%Prima.Actor{} = actor) do
    Errors.with_db_rescue("CronSchedule.count_active", fn ->
      count =
        from(s in Row,
          where: s.status != "deleted",
          select: count(s.id)
        )
        |> where_tenant_unless_platform(actor)
        |> Arca.Repo.one()

      {:ok, count || 0}
    end)
  end

  # The tenant-scoped single-row read every mutation goes through. The
  # platform bypass is the shared `where_tenant_unless_platform/2` — the
  # one spelling the other record readers use, not a hand-rolled fourth.
  defp get_tenant(%Prima.Actor{} = actor, id) do
    from(s in Row, where: s.id == ^id)
    |> where_tenant_unless_platform(actor)
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :not_found}
      schedule -> {:ok, schedule}
    end
  end

  # A raw changeset never escapes the storage layer: validation failures
  # cross as a plain field=>messages map a seam can render with no Ecto
  # knowledge.
  defp mapped_validation({:ok, _} = ok), do: ok

  defp mapped_validation({:error, %Ecto.Changeset{} = changeset}) do
    {:invalid, errors} = Arca.Data.invalid(changeset)
    {:error, {:validation, errors}}
  end
end
