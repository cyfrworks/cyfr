# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ScheduleNotes do
  @moduledoc """
  A schedule that asked to keep what it did. `keep_outcome: true` in a
  schedule's metadata (`Cyfr.Schedules.Provider`) files every completed run's output
  as a note in the schedule's estate (`Aqua.Notes`) — named by the
  metadata's `note_name`, else by the schedule's id — with the schedule
  and the execution as provenance, capped so one run cannot fill a
  ledger. Each run replaces the note before it.

  A telemetry consumer of `[:cyfr, :schedules, :completed]`,
  attached at boot. The write runs under the server's own context
  refocused on the schedule's athanor — the estate the run itself ran
  in — and an archived athanor's schedule writes nothing. The handler
  runs inside the scheduler and never raises into it: a note that cannot
  be kept is logged, and the run stands.
  """

  require Logger

  alias Sanctum.Context

  @event [:cyfr, :schedules, :completed]
  @handler_id "notes-schedule-completed"
  @max_bytes 64 * 1024
  @marker "\n\n[cut — the outcome was longer than 64 KiB]"

  @doc "The event this module consumes."
  @spec event() :: [atom()]
  def event, do: @event

  @doc "Attach at boot; detaching first keeps a restart from attaching twice."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    _ = :telemetry.detach(@handler_id)
    :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)
  end

  # `:telemetry` detaches a handler that fails in ANY way — a raise, an
  # exit (a store checkout timing out arrives as one), a throw — for the
  # life of the node, silently. Every class is caught, so one bad run
  # costs one note and not every note after it.
  @doc false
  def handle_event(@event, _measurements, metadata, _config) do
    case wanted(metadata) do
      {:ok, name} -> keep(metadata, name)
      :skip -> :ok
    end
  catch
    kind, reason ->
      Logger.warning(
        "[ScheduleNotes] note not kept for schedule #{inspect(metadata[:schedule_id])}: " <>
          Exception.format_banner(kind, reason)
      )

      :ok
  end

  # `keep_outcome` true in the row's metadata, which rides the event as the
  # JSON the row holds. Anything else — absent, false, unreadable — is a
  # run nobody asked to keep.
  defp wanted(metadata) do
    case decode(metadata[:metadata]) do
      %{"keep_outcome" => true} = wants ->
        case name(wants["note_name"], metadata) do
          nil ->
            Logger.warning("[ScheduleNotes] a completed run named no schedule; nothing kept")
            :skip

          name ->
            {:ok, name}
        end

      _ ->
        :skip
    end
  end

  defp decode(%{} = decoded), do: decoded

  defp decode(raw) do
    case decode_stored(raw, %{}, "metadata") do
      %{} = decoded -> decoded
      _ -> %{}
    end
  end

  # A stored JSON column that does not decode reads as its default. The
  # line names the column and its size, never its bytes.
  defp decode_stored(nil, default, _field), do: default
  defp decode_stored("", default, _field), do: default

  defp decode_stored(json, default, field) when is_binary(json) do
    case Cyfr.Json.decode(json) do
      {:ok, value} ->
        value

      {:error, :invalid_json} ->
        Logger.warning(
          "[Cyfr.ScheduleNotes] stored #{field} is not valid JSON (#{byte_size(json)} bytes)"
        )

        default
    end
  end

  # The operator's `note_name` when set (the ledger's grammar judges it),
  # else the schedule's own id — grammar-safe and unique, where a
  # component reference is neither.
  defp name(note_name, _metadata) when is_binary(note_name) and note_name != "", do: note_name
  defp name(_none, %{schedule_id: id}) when is_binary(id) and id != "", do: id
  defp name(_none, _metadata), do: nil

  defp keep(metadata, name) do
    internal = Context.internal(user_id: metadata[:user_id] || "system")

    with {:ok, ctx} <- Context.refocus(internal, metadata[:athanor_id]),
         {:ok, _} <-
           Aqua.Notes.keep(ctx, name, body(metadata[:output]),
             kept_by: "schedule:" <> to_string(metadata[:schedule_id]),
             execution: metadata[:execution_id]
           ) do
      :ok
    else
      # The furnace closed between the fire and the finish: nothing to keep.
      {:error, :archived} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[ScheduleNotes] note not kept for schedule #{inspect(metadata[:schedule_id])}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp body(output) when is_binary(output), do: Cyfr.Text.cut(output, @max_bytes, @marker)

  defp body(output), do: output |> Cyfr.Json.safe_encode() |> Cyfr.Text.cut(@max_bytes, @marker)
end
