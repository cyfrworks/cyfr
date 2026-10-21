# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.CronSchedule do
  @moduledoc """
  One of an athanor's recurring component executions; `user_id` records
  who created it (attribution), the athanor owns it. The facade is
  `Arca.CronSchedule`.

  A row's `kind` is `schedule` or `feed`. A feed's row id is its binding
  id, and it carries the binding's JSON text (`feed_spec`), the last seq a
  run claimed (`feed_fire_seq`) and the accepted result's JSON text, time
  and seq (`feed_result`, `feed_result_at`, `feed_result_seq`). Only
  `Arca.CronSchedule.create_feed/2` writes a feed; the schedule changesets
  cast none of those fields.

  `missed_runs` is the schedule's declared policy for due times it missed
  (`skip`, the default, or `catch_up`), and `catch_up_limit` how many of
  them one catch-up episode fires: set under `catch_up`, never under
  `skip`. An open episode is `catch_up_left` missed times still to fire,
  up to the horizon `catch_up_until`; only `Arca.ScheduleOccurrences.claim/3`
  opens, walks and closes one, and a write that moves the cursor or the
  policy here closes it. The upper bound of the limit is the scheduler's
  (`Opus.Schedules.Scheduler.max_catch_up/0`), held on each adapter by the
  table's CHECK, which this changeset reads back as a validation error.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active paused deleted needs_consent)
  @concurrency ~w(forbid allow)
  @missed_runs ~w(skip catch_up)
  @kinds ~w(schedule feed)

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  @type t :: %__MODULE__{}
  schema "cron_schedules" do
    field :kind, :string, default: "schedule"
    field :user_id, :string
    field :name, :string
    field :cron_expression, :string
    field :reference, :string
    # The pinned version a fire runs: the reference as resolved when the
    # row was created or last repointed.
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
    # skip | catch_up, and the episode `ScheduleOccurrences.claim/3` walks.
    field :missed_runs, :string, default: "skip"
    field :catch_up_limit, :integer
    field :catch_up_until, :utc_datetime_usec
    field :catch_up_left, :integer, default: 0
    field :feed_spec, :string
    field :feed_fire_seq, :integer, default: 0
    field :feed_result_seq, :integer, default: 0
    field :feed_result, :string
    field :feed_result_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc "The status vocabulary this table's rows may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The kinds a row may be: a schedule, or a feed."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The changeset a new schedule is inserted through: always of kind `schedule`."
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{kind: "schedule"}
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
      :missed_runs,
      :catch_up_limit,
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
      :resolved_reference,
      :profile_id,
      :athanor_id,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:concurrency, @concurrency)
    |> validate_missed_runs()
  end

  @doc """
  The changeset a new feed is inserted through: of kind `feed`, with its
  binding's JSON text, a pinned version to run and a cursor to fire at.
  A live name the athanor's feeds already hold is a unique-constraint
  error, declared in both adapters' spellings: PostgreSQL names the index,
  and ecto_sqlite3 derives a name from the columns SQLite's error lists.
  A feed takes no missed-run policy and stays `skip`: a poll missed is
  covered by the next.
  """
  @spec feed_changeset(map()) :: Ecto.Changeset.t()
  def feed_changeset(attrs) do
    %__MODULE__{kind: "feed"}
    |> cast(Map.new(attrs), [
      :id,
      :user_id,
      :name,
      :cron_expression,
      :reference,
      :resolved_reference,
      :input,
      :profile_id,
      :concurrency,
      :athanor_id,
      :feed_spec,
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
      :resolved_reference,
      :input,
      :profile_id,
      :athanor_id,
      :feed_spec,
      :next_run_at,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:concurrency, @concurrency)
    |> unique_constraint(:name, name: :cron_schedules_athanor_kind_name_active)
    |> unique_constraint(:name, name: :cron_schedules_athanor_id_kind_name_index)
  end

  @doc "The changeset an existing schedule is updated through."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = schedule, attrs) do
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
      :missed_runs,
      :catch_up_limit,
      :next_run_at,
      :last_run_at,
      :last_execution_id,
      :run_count,
      :error_count,
      :updated_at
    ])
    |> validate_required([:resolved_reference])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:concurrency, @concurrency)
    |> validate_missed_runs()
    |> close_episode()
  end

  # The policy and its limit agree: `catch_up` names a limit of at least
  # one, `skip` names none. The limit's ceiling is the CHECK's, read back
  # here rather than raised, so a store refusal crosses as a field error.
  defp validate_missed_runs(changeset) do
    changeset =
      changeset
      |> validate_inclusion(:missed_runs, @missed_runs)
      |> check_constraint(:catch_up_limit, name: :cron_schedules_catch_up_limit_declared)
      |> check_constraint(:catch_up_left, name: :cron_schedules_catch_up_episode)

    case {get_field(changeset, :missed_runs), get_field(changeset, :catch_up_limit)} do
      {"catch_up", nil} ->
        add_error(changeset, :catch_up_limit, "is required when missed_runs is catch_up")

      {"catch_up", limit} when limit < 1 ->
        add_error(changeset, :catch_up_limit, "must be at least 1")

      {"skip", limit} when not is_nil(limit) ->
        add_error(changeset, :catch_up_limit, "must be empty when missed_runs is skip")

      _agreed ->
        changeset
    end
  end

  # A write that moves the cursor or changes the policy ends any catch-up
  # episode the claim had open: the missed times it counted were counted
  # against the old cursor and the old limit.
  defp close_episode(changeset) do
    if Enum.any?(
         [:next_run_at, :missed_runs, :catch_up_limit, :cron_expression],
         &changed?(changeset, &1)
       ),
       do: change(changeset, catch_up_until: nil, catch_up_left: 0),
       else: changeset
  end

  @doc "The changeset a schedule is soft-deleted through."
  @spec delete_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def delete_changeset(%__MODULE__{} = schedule, %DateTime{} = now),
    do: cast(schedule, %{status: "deleted", updated_at: now}, [:status, :updated_at])
end
