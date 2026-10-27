# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Schedules.Changes do
  @moduledoc """
  The schedules' publisher of `Cyfr.Bus.Schedules`: a schedule row as a
  committed write left it, on the athanor's schedules topic.

  `changed/2` follows every write that moves what the row shows (a create,
  an edit, a pause, a resume, a re-resolve, a cursor move, a run or an
  error recorded, an occurrence's start and its run's end) and reads the
  row again rather than trusting what the write answered, which was read
  before its commit. A row of kind `feed`, a deleted row and a row that
  no longer reads announce nothing. `removed/2` follows the one delete
  whose write removed the live row (`Arca.CronSchedule.soft_delete/2`
  answers any other `:not_found`), with the row as it was. Both run under
  the schedule's lock (`Cyfr.Bus.Schedules.serialized/2`), so once
  `removed` has left, a later `changed` reads the deleted row and
  announces nothing. Under the lock the row is read only while this
  member holds its slot (`Arca.CronSchedule.get_held/2`): a member that
  lost it announces nothing, whatever it wrote before.
  """

  require Logger

  alias Cyfr.Bus.Schedules

  @doc "The row `schedule_id` as it reads now, announced as `changed`."
  @spec changed(Prima.Actor.t(), String.t()) :: :ok
  def changed(%Prima.Actor{} = actor, schedule_id) when is_binary(schedule_id) do
    Schedules.serialized(schedule_id, fn ->
      case Arca.CronSchedule.get_held(actor, schedule_id) do
        {:ok, %{kind: "schedule", status: status} = row} when status != "deleted" ->
          broadcast(actor, payload(actor, :changed, row))

        {:ok, _feed_or_deleted} ->
          :ok

        {:error, :not_owner} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Opus.Schedules.Changes] schedule #{schedule_id} not announced: " <>
              "its row did not read (#{inspect(reason)})"
          )
      end
    end)
  end

  @doc """
  The schedule a committed delete removed, announced as `removed` with the
  row as it was: `row`, the row the delete's own locked read found
  (`Arca.CronSchedule.soft_delete/2`), never an earlier read.
  """
  @spec removed(Prima.Actor.t(), map()) :: :ok
  def removed(%Prima.Actor{} = actor, %{id: id, kind: "schedule"} = row) do
    Schedules.serialized(id, fn ->
      case Arca.CronSchedule.get_held(actor, id) do
        {:ok, _held} ->
          broadcast(actor, payload(actor, :removed, row))

        {:error, reason} ->
          Logger.warning(
            "[Opus.Schedules.Changes] removal of #{id} not announced: #{inspect(reason)}"
          )
      end
    end)
  end

  def removed(%Prima.Actor{}, %{kind: _feed}), do: :ok

  @doc "The payload a stored schedule row reads as (`Cyfr.Bus.Schedules.row_fields/1`)."
  @spec payload(Prima.Actor.t(), Schedules.kind(), map()) :: Schedules.t()
  def payload(%Prima.Actor{} = actor, kind, row),
    do: Schedules.new(actor, kind, Schedules.row_fields(row))

  defp broadcast(actor, payload) do
    case Cyfr.Bus.broadcast(actor, Cyfr.Bus.schedules(actor), payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Opus.Schedules.Changes] schedule #{payload.schedule_id} not announced: " <>
            inspect(reason)
        )
    end
  end
end
