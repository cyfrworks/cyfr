# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CronSchedule do
  @moduledoc """
  Ecto schema and row-plane storage for cron schedule records.

  Stores an athanor's recurring schedules for WASM component execution;
  `user_id` records who created a schedule (attribution), the athanor owns it.

  Speaks the row-plane convention (`Arca.QueryHelpers`): every entry point
  is rescued to `{:error, :database_error}`, absence is `{:error, :not_found}`
  (never `nil`), and validation failures cross as
  `{:error, {:validation, %{field => [message]}}}` — a raw changeset never
  escapes the storage layer. This module once spoke five return conventions
  and rescued nothing, so a SQLite hiccup raised straight into the scheduler.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, except: [update: 2]
  import Arca.QueryHelpers, only: [where_tenant_unless_platform: 2]

  alias Arca.Repo.Errors
  alias Sanctum.Context

  @statuses ~w(active paused deleted needs_consent)

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
      |> Arca.Repo.insert()
      |> mapped_validation()
    end)
  end

  @doc "Updates an existing cron schedule with tenant-scoped lookup."
  @spec update(Context.t(), String.t(), map()) ::
          {:ok, %__MODULE__{}}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the row was fetched tenant-scoped by get_tenant/2 in the same with.
  def update(%Context{} = ctx, id, attrs) do
    Errors.with_db_rescue("CronSchedule.update", fn ->
      with {:ok, schedule} <- get_tenant(ctx, id) do
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
        |> validate_inclusion(:status, @statuses)
        |> Arca.Repo.update()
        |> mapped_validation()
      end
    end)
  end

  @doc "Gets a schedule by ID with tenant-scoped lookup."
  @spec get(Context.t(), String.t()) ::
          {:ok, %__MODULE__{}} | {:error, :not_found | :database_error}
  def get(%Context{} = ctx, id) do
    Errors.with_db_rescue("CronSchedule.get", fn -> get_tenant(ctx, id) end)
  end

  @doc """
  Gets a schedule by ID (unscoped).

  Reserved for the CronScheduler daemon which needs to load schedules
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
  @spec get_by_id_or_name(Context.t(), String.t()) ::
          {:ok, %__MODULE__{}} | {:error, :not_found | :database_error}
  def get_by_id_or_name(%Context{} = ctx, id_or_name) do
    Errors.with_db_rescue("CronSchedule.get_by_id_or_name", fn ->
      from(s in __MODULE__,
        where: s.status != "deleted",
        where: s.id == ^id_or_name or s.name == ^id_or_name
      )
      |> where_tenant_unless_platform(ctx)
      |> Arca.Repo.one()
      |> case do
        nil -> {:error, :not_found}
        schedule -> {:ok, schedule}
      end
    end)
  end

  @doc "Lists the athanor's schedules, newest first."
  @spec list(Context.t(), keyword()) ::
          {:ok, [%__MODULE__{}]} | {:error, :database_error}
  def list(%Context{} = ctx, opts \\ []) do
    Errors.with_db_rescue("CronSchedule.list", fn ->
      limit = Keyword.get(opts, :limit, 50)

      rows =
        from(s in __MODULE__,
          where: s.status != "deleted",
          order_by: [desc: s.created_at],
          limit: ^limit
        )
        |> where_tenant_unless_platform(ctx)
        |> Arca.Repo.all()

      {:ok, rows}
    end)
  end

  @doc """
  Returns all active schedules (unscoped).

  Intentionally unscoped — called by the CronScheduler daemon which iterates
  all tenants' schedules to determine what needs firing. The daemon constructs
  a per-schedule `Context` from `user_id`/`athanor_id` before executing, same
  rationale as `get_for_daemon/1`.
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

  @doc """
  Take the schedule for one OCCURRENCE: a compare-and-set that advances
  `next_run_at` in the same statement that records the claim. Several nodes
  sharing the database race here and exactly one wins. Returns `:claimed` or
  `:held`.

  `next_run` is the occurrence after the one being taken — the caller
  computes it from the cron expression.

  ## Why the advance is part of the CAS

  It used to set only `claimed_by`/`claim_expires_at`, and `next_run_at`
  moved later in a separate `update/3` from the scheduler. So the claim
  guarded the EXECUTION, not the occurrence: node A could claim, fire,
  finish and release inside a second, and node B's jittered timer for the
  SAME occurrence then found a free claim and ran it again. Only the
  per-node `running` MapSet stood in the way, and that is per node.

  With `next_run_at <= now` in the `where` and the advance in the `set`,
  the loser's CAS matches nothing and answers `:held`.

  ## The trade this makes: at-least-once becomes at-most-once

  The occurrence is consumed at claim time, so a node that claims and
  advances and then dies before its task runs SKIPS that occurrence rather
  than having another node repeat it. That is the deliberate choice — a
  duplicate side effect is worse here than a missed one — and it is why
  `Opus.CronScheduler` releases claims in `terminate/2`: a clean shutdown
  should not leave a stale claimant behind, even though the occurrence
  itself has already moved on.

  A run that outlives its own interval can still overlap the next
  occurrence on ANOTHER node; the per-node `running` set prevents it on
  the same one. Serialising across nodes would mean holding the claim for
  the whole run, which trades the overlap for a stall whenever a node dies
  mid-execution.

  That is not hypothetical bookkeeping: `Opus.CronScheduler` gives the
  marker back in `run_claimed_schedule/6`, immediately after this returns
  `:claimed` and before the task is spawned. Held for the run instead, the
  `claim_expires_at` guard above would make every LATER occurrence answer
  `:held` cluster-wide until the run finished — the stall this paragraph
  says was declined — so the release point is what keeps it honest.
  """
  @spec claim(String.t(), String.t(), pos_integer(), DateTime.t()) ::
          :claimed | :held | {:error, :database_error}
  # arca:unscoped-ok a claim races nodes over one known schedule id, before
  # any context exists; the id came from `active_schedules/0`.
  def claim(id, node_name, ttl_seconds, %DateTime{} = next_run)
      when is_binary(id) and is_binary(node_name) do
    Errors.with_db_rescue("CronSchedule.claim", fn ->
      now = DateTime.utc_now()
      expires = DateTime.add(now, ttl_seconds, :second)

      {count, _} =
        from(s in __MODULE__,
          where: s.id == ^id and s.status == "active",
          where: is_nil(s.claim_expires_at) or s.claim_expires_at < ^now,
          # The occurrence itself. Whoever advances it first has taken it.
          where: not is_nil(s.next_run_at) and s.next_run_at <= ^now
        )
        |> Arca.Repo.update_all(
          set: [claimed_by: node_name, claim_expires_at: expires, next_run_at: next_run]
        )

      if count == 1, do: :claimed, else: :held
    end)
  end

  @doc "Give a claim back once the firing is over (only the claimant's own)."
  @spec release_claim(String.t(), String.t()) :: :ok
  # arca:unscoped-ok the claimant gives back its own claim, matched on
  # `claimed_by` — a node can only release what it holds.
  #
  # Fail-open on a DB error (default :ok): a claim that could not be
  # released lapses on its own TTL; the release is best-effort cleanup.
  def release_claim(id, node_name) when is_binary(id) and is_binary(node_name) do
    Errors.with_db_rescue("CronSchedule.release_claim", :ok, fn ->
      from(s in __MODULE__, where: s.id == ^id and s.claimed_by == ^node_name)
      |> Arca.Repo.update_all(set: [claimed_by: nil, claim_expires_at: nil])

      :ok
    end)
  end

  @doc "Records a successful run with tenant-scoped lookup."
  @spec record_run(Context.t(), String.t(), String.t()) ::
          {:ok, %__MODULE__{}}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the row was fetched tenant-scoped by get_tenant/2 in the same with.
  #
  # `inc:` rather than read-then-write. `schedule.run_count + 1` over a row
  # read a moment earlier is a lost update whenever two nodes fire two
  # schedules' runs concurrently — and this file already argues the
  # pattern: `claim/4` above is a compare-and-set precisely because
  # "several nodes sharing the database race here". There are no row locks
  # anywhere in this repo (a deliberate SQLite+Postgres choice), so
  # read-then-write is never safe; `update_all` with `inc:` is atomic in
  # one round-trip and drops the SELECT.
  def record_run(%Context{} = ctx, id, execution_id) do
    Errors.with_db_rescue("CronSchedule.record_run", fn ->
      with {:ok, schedule} <- get_tenant(ctx, id) do
        now = DateTime.utc_now()

        from(s in __MODULE__, where: s.id == ^schedule.id)
        |> Arca.Repo.update_all(
          set: [last_run_at: now, last_execution_id: execution_id, updated_at: now],
          inc: [run_count: 1]
        )

        get_tenant(ctx, id)
      end
    end)
  end

  @doc "Records an error with tenant-scoped lookup."
  @spec record_error(Context.t(), String.t(), term()) ::
          {:ok, %__MODULE__{}}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the row was fetched tenant-scoped by get_tenant/2 in the same with.
  # Atomic increment, for the reason spelled out at `record_run/3`.
  def record_error(%Context{} = ctx, id, _reason) do
    Errors.with_db_rescue("CronSchedule.record_error", fn ->
      with {:ok, schedule} <- get_tenant(ctx, id) do
        from(s in __MODULE__, where: s.id == ^schedule.id)
        |> Arca.Repo.update_all(
          set: [updated_at: DateTime.utc_now()],
          inc: [error_count: 1]
        )

        get_tenant(ctx, id)
      end
    end)
  end

  @doc "Soft-deletes a schedule with tenant-scoped lookup."
  @spec soft_delete(Context.t(), String.t()) ::
          {:ok, %__MODULE__{}}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  def soft_delete(%Context{} = ctx, id) do
    Errors.with_db_rescue("CronSchedule.soft_delete", fn ->
      with {:ok, schedule} <- get_tenant(ctx, id) do
        schedule
        |> cast(%{status: "deleted", updated_at: DateTime.utc_now()}, [:status, :updated_at])
        |> Arca.Repo.update()
        |> mapped_validation()
      end
    end)
  end

  @doc """
  Counts the athanor's schedules that occupy a cap slot — everything not
  deleted. A paused schedule keeps its seat, which is why `resume` needs
  no cap check of its own.
  """
  @spec count_active(Context.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  def count_active(%Context{} = ctx) do
    Errors.with_db_rescue("CronSchedule.count_active", fn ->
      count =
        from(s in __MODULE__,
          where: s.status != "deleted",
          select: count(s.id)
        )
        |> where_tenant_unless_platform(ctx)
        |> Arca.Repo.one()

      {:ok, count || 0}
    end)
  end

  # The tenant-scoped single-row read every mutation goes through. The
  # platform bypass is the shared `where_tenant_unless_platform/2` — the
  # one spelling the other record readers use, not a hand-rolled fourth.
  defp get_tenant(%Context{} = ctx, id) do
    from(s in __MODULE__, where: s.id == ^id)
    |> where_tenant_unless_platform(ctx)
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
