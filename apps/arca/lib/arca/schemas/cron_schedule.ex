# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.CronSchedule do
  @moduledoc """
  One of an athanor's recurring schedules for WASM component execution;
  `user_id` records who created it (attribution), the athanor owns it.
  The facade is `Arca.CronSchedule`.
  """

  use Ecto.Schema
  import Ecto.Changeset

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

  @doc "The changeset a new schedule is inserted through."
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
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
      :next_run_at,
      :last_run_at,
      :last_execution_id,
      :run_count,
      :error_count,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:concurrency, @concurrency)
  end

  @doc "The changeset a schedule is soft-deleted through."
  @spec delete_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def delete_changeset(%__MODULE__{} = schedule, %DateTime{} = now),
    do: cast(schedule, %{status: "deleted", updated_at: now}, [:status, :updated_at])
end
