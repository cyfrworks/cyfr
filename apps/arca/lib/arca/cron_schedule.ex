# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CronSchedule do
  @moduledoc """
  Ecto schema and row-plane storage for cron schedule records.

  Stores an athanor's recurring schedules for WASM component execution;
  `user_id` records who created a schedule (attribution), the athanor owns it.

  Uses the `Arca.QueryHelpers` return convention: database failures return
  `{:error, :database_error}`, missing rows return `{:error, :not_found}`,
  and validation returns `{:error, {:validation, %{field => [message]}}}`.
  Raw changesets do not leave the storage layer.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, except: [update: 2]
  import Arca.QueryHelpers, only: [where_tenant_unless_platform: 2]
  # Every function that names a tenant takes the `Cyfr.Actor` first and
  # reads a schedule through `get_tenant/2`, whose platform bypass is the
  # shared `where_tenant_unless_platform/2`. A platform-scope actor
  # carries no athanor by design, so these match the actor and leave the
  # refusal to that backstop; `get_for_daemon/1` reads unscoped and says
  # why where it stands.

  alias Arca.Repo.Errors

  @statuses ~w(active paused deleted needs_consent)
  @concurrency ~w(forbid allow)

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  @type t :: %__MODULE__{}
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
    # Whether a due occurrence is claimed while another of this schedule
    # is still open: `forbid` or `allow` (`Arca.ScheduleOccurrences`).
    field :concurrency, :string, default: "forbid"
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc "The status vocabulary this table's rows may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Creates a new cron schedule."
  @spec create(map()) ::
          {:ok, %__MODULE__{}}
          | {:error, {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the athanor arrives in attrs and is validated required before the insert.
  def create(attrs) do
    Errors.with_db_rescue("CronSchedule.create", fn ->
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.put_new(:id, Cyfr.UUID7.generate_id("sched"))
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
        :concurrency,
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
      |> validate_inclusion(:status, @statuses)
      |> validate_inclusion(:concurrency, @concurrency)
      |> Arca.Repo.insert()
      |> mapped_validation()
    end)
  end

  @doc "Updates an existing cron schedule with tenant-scoped lookup."
  @spec update(Cyfr.Actor.t(), String.t(), map()) ::
          {:ok, %__MODULE__{}}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the row was fetched tenant-scoped by get_tenant/2 in the same with.
  def update(%Cyfr.Actor{} = actor, id, attrs) do
    Errors.with_db_rescue("CronSchedule.update", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
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
          :concurrency,
          :next_run_at,
          :last_run_at,
          :last_execution_id,
          :run_count,
          :error_count,
          :updated_at
        ])
        |> validate_inclusion(:status, @statuses)
        |> validate_inclusion(:concurrency, @concurrency)
        |> Arca.Repo.update()
        |> mapped_validation()
      end
    end)
  end

  @doc "Gets a schedule by ID with tenant-scoped lookup."
  @spec get(Cyfr.Actor.t(), String.t()) ::
          {:ok, %__MODULE__{}} | {:error, :not_found | :database_error}
  def get(%Cyfr.Actor{} = actor, id) do
    Errors.with_db_rescue("CronSchedule.get", fn -> get_tenant(actor, id) end)
  end

  @doc """
  Gets a schedule by ID (unscoped).

  Reserved for the scheduler daemon, which needs to load schedules
  before a tenant context can be constructed (chicken-and-egg: we need
  the schedule's user_id/athanor_id to build a context).
  """
  @spec get_for_daemon(String.t()) ::
          {:ok, %__MODULE__{}} | {:error, :not_found | :database_error}
  # arca:unscoped-ok the daemon reads the row to LEARN the athanor it must
  # build a context from — scoping first would need the answer it is asking for.
  def get_for_daemon(id) do
    Errors.with_db_rescue("CronSchedule.get_for_daemon", fn ->
      case Arca.Repo.get(__MODULE__, id) do
        nil -> {:error, :not_found}
        schedule -> {:ok, schedule}
      end
    end)
  end

  @doc "Gets one of the athanor's schedules by either ID or name."
  @spec get_by_id_or_name(Cyfr.Actor.t(), String.t()) ::
          {:ok, %__MODULE__{}} | {:error, :not_found | :database_error}
  def get_by_id_or_name(%Cyfr.Actor{} = actor, id_or_name) do
    Errors.with_db_rescue("CronSchedule.get_by_id_or_name", fn ->
      from(s in __MODULE__,
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
  end

  @doc "Lists the athanor's schedules, newest first."
  @spec list(Cyfr.Actor.t(), keyword()) ::
          {:ok, [%__MODULE__{}]} | {:error, :database_error}
  def list(actor, opts \\ [])

  def list(%Cyfr.Actor{} = actor, opts) do
    Errors.with_db_rescue("CronSchedule.list", fn ->
      limit = Keyword.get(opts, :limit, 50)

      rows =
        from(s in __MODULE__,
          where: s.status != "deleted",
          order_by: [desc: s.created_at],
          limit: ^limit
        )
        |> where_tenant_unless_platform(actor)
        |> Arca.Repo.all()

      {:ok, rows}
    end)
  end

  @doc """
  Returns all active schedules (unscoped).

  Unscoped daemon query. The scheduler constructs a context from each
  schedule's `user_id` and `athanor_id` before executing it.
  """
  @spec active_schedules() :: {:ok, [%__MODULE__{}]} | {:error, :database_error}
  # arca:unscoped-ok the firing loop walks every athanor by design, then runs
  # each schedule inside a context built from its own row.
  def active_schedules do
    Errors.with_db_rescue("CronSchedule.active_schedules", fn ->
      rows =
        from(s in __MODULE__,
          where: s.status == "active",
          order_by: [asc: s.next_run_at]
        )
        |> Arca.Repo.all()

      {:ok, rows}
    end)
  end

  @doc "Records a successful run with tenant-scoped lookup."
  @spec record_run(Cyfr.Actor.t(), String.t(), String.t()) ::
          {:ok, %__MODULE__{}}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok get_tenant/2 in the same with establishes row ownership.
  # Increment atomically; concurrent runs must not overwrite each other’s counts.
  def record_run(%Cyfr.Actor{} = actor, id, execution_id) do
    Errors.with_db_rescue("CronSchedule.record_run", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        now = DateTime.utc_now()

        from(s in __MODULE__, where: s.id == ^schedule.id)
        |> Arca.Repo.update_all(
          set: [last_run_at: now, last_execution_id: execution_id, updated_at: now],
          inc: [run_count: 1]
        )

        get_tenant(actor, id)
      end
    end)
  end

  @doc "Records an error with tenant-scoped lookup."
  @spec record_error(Cyfr.Actor.t(), String.t(), term()) ::
          {:ok, %__MODULE__{}}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the row was fetched tenant-scoped by get_tenant/2 in the same with.
  # Atomic increment, for the reason spelled out at `record_run/3`.
  def record_error(%Cyfr.Actor{} = actor, id, _reason) do
    Errors.with_db_rescue("CronSchedule.record_error", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        from(s in __MODULE__, where: s.id == ^schedule.id)
        |> Arca.Repo.update_all(
          set: [updated_at: DateTime.utc_now()],
          inc: [error_count: 1]
        )

        get_tenant(actor, id)
      end
    end)
  end

  @doc "Soft-deletes a schedule with tenant-scoped lookup."
  @spec soft_delete(Cyfr.Actor.t(), String.t()) ::
          {:ok, %__MODULE__{}}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  def soft_delete(%Cyfr.Actor{} = actor, id) do
    Errors.with_db_rescue("CronSchedule.soft_delete", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        schedule
        |> cast(%{status: "deleted", updated_at: DateTime.utc_now()}, [:status, :updated_at])
        |> Arca.Repo.update()
        |> mapped_validation()
      end
    end)
  end

  @doc """
  Counts non-deleted schedules occupying the athanor’s cap slots.
  Paused schedules retain their slots; resuming does not require a cap check.
  """
  @spec count_active(Cyfr.Actor.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_active(%Cyfr.Actor{} = actor) do
    Errors.with_db_rescue("CronSchedule.count_active", fn ->
      count =
        from(s in __MODULE__,
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
  defp get_tenant(%Cyfr.Actor{} = actor, id) do
    from(s in __MODULE__, where: s.id == ^id)
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
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    {:error, {:validation, errors}}
  end
end
