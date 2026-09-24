# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ScheduleNotes do
  @moduledoc """
  A schedule that asked to keep what it did. `keep_outcome: true` in a
  schedule's metadata (`Cyfr.Schedules.Provider`) files every completed run's
  output as a note in the schedule's estate (`Aqua.Notes`) — named by the
  metadata's `note_name`, else by the schedule's id — with the schedule and
  the execution as provenance, capped so one run cannot fill a ledger. Each
  run replaces the note before it.

  One process per member, subscribed to the committed completions
  (`Cyfr.Bus.schedule_completions/0`, `Cyfr.Bus.ScheduleCompleted`). Every
  member hears every completion; this one acts only when its own member
  holds its slot and that slot is the completion's issuer
  (`Arca.ControlPlane.held?/0`, `held/0`), so a peer's delivery writes
  nothing. The slot is asked again just before the write, and a note that
  already records the completion's execution is not written again, which
  bounds a duplicate delivery to no second note.

  The write runs under the server's own context, able to read and write
  storage and nothing more, refocused on the schedule's athanor — the
  estate the run itself ran in — and an archived athanor's schedule writes
  nothing. Keeping a note is best effort: one that cannot be kept is
  logged, and the run stands. No takeover and no guaranteed delivery is
  promised.
  """

  use GenServer

  require Logger

  alias Cyfr.Bus.ScheduleCompleted
  alias Sanctum.Context

  @marker "\n\n[cut — the outcome was longer than 64 KiB]"

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.schedule_completions())
    {:ok, %{}}
  end

  @impl true
  def handle_info(%ScheduleCompleted{} = completed, state) do
    _ = keep(completed)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @doc """
  What this member does with `completed`: `:kept` when it filed the note,
  `:duplicate` when the note already records that execution, `:skipped`
  when the run asked for nothing or another member issued it, and
  `:not_kept` when the write failed or the slot was lost before it. Never
  raises.
  """
  @spec keep(ScheduleCompleted.t()) :: :kept | :duplicate | :skipped | :not_kept
  def keep(%ScheduleCompleted{keep_outcome: false}), do: :skipped

  def keep(%ScheduleCompleted{} = completed) do
    if issuer?(completed.issuer_member), do: write(completed), else: :skipped
  catch
    kind, reason ->
      Logger.warning(
        "[ScheduleNotes] note not kept for schedule #{completed.schedule_id}: " <>
          Exception.format_banner(kind, reason)
      )

      :not_kept
  end

  # This member holds its slot, and it is the slot that published: taken
  # the same way on both sides (`ScheduleCompleted.issuer/1`).
  defp issuer?(issuer) do
    Arca.ControlPlane.held?() and ScheduleCompleted.issuer(Arca.ControlPlane.held()) == issuer
  end

  defp write(%ScheduleCompleted{} = completed) do
    name = completed.note_name || completed.schedule_id

    internal =
      Context.internal(
        user_id: completed.actor.user_id || "system",
        permissions: [:storage_read, :storage_write]
      )

    with {:ok, ctx} <- Context.refocus(internal, completed.athanor_id),
         :fresh <- recorded(ctx, name, completed.execution_id),
         true <- Arca.ControlPlane.held?() || :lost,
         {:ok, _} <-
           Aqua.Notes.keep(ctx, name, body(completed),
             kept_by: "schedule:" <> completed.schedule_id,
             execution: completed.execution_id
           ) do
      :kept
    else
      :recorded ->
        :duplicate

      :lost ->
        Logger.info(
          "[ScheduleNotes] slot lost before the note of schedule #{completed.schedule_id} " <>
            "was kept; nothing written"
        )

        :not_kept

      # The furnace closed between the fire and the finish: nothing to keep.
      {:error, :archived} ->
        :skipped

      {:error, reason} ->
        Logger.warning(
          "[ScheduleNotes] note not kept for schedule #{completed.schedule_id}: " <>
            inspect(reason)
        )

        :not_kept
    end
  end

  # Whether the note already records this execution — the one question a
  # second delivery of the same completion must answer before it writes.
  defp recorded(ctx, name, execution_id) do
    case Aqua.Notes.read(ctx, name) do
      {:ok, %{execution: ^execution_id}} -> :recorded
      _ -> :fresh
    end
  end

  defp body(%ScheduleCompleted{output: nil}), do: "null"
  defp body(%ScheduleCompleted{output: output, truncated: true}), do: output <> @marker
  defp body(%ScheduleCompleted{output: output}), do: output
end
