# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Cascade do
  @moduledoc """
  Revokes profiles and disables webhook and cron registrations (schedules
  and feeds) when the last version of a component name is removed.
  Consent history and vault entries remain. A registration whose removal
  is refused is logged by its id and the reason, and the uninstall still
  completes. Called by registry deletion and pruning; the registry owns
  removal of the component's bytes and row.
  """

  require Logger

  alias Compendium.ComponentPath
  alias Cyfr.Bus.Schedules
  alias Sanctum.Context

  @doc """
  Run the name-level cascade for a just-deleted component row: a no-op
  while other versions of the name remain; when none do, revoke the
  name's profiles and disable its registrations.
  """
  @spec name_removed(Context.t(), map()) :: :ok
  def name_removed(%Context{} = ctx, comp) do
    publisher = ComponentPath.normalize_publisher(Map.get(comp, :publisher))

    unless Arca.ComponentStorage.has_remaining_versions?(
             Sanctum.Context.actor(ctx),
             comp.name,
             publisher
           ) do
      component_type = Map.get(comp, :component_type, "")
      name_ref = Prima.ComponentRef.build(component_type, publisher, comp.name)

      revoke_profiles(ctx, name_ref)
      disable_registrations(ctx, name_ref)

      Logger.debug(
        "[Compendium.Cascade] Cleaned up name-level state for #{name_ref} (last version removed)"
      )
    end

    :ok
  end

  # Revoke profiles while retaining consent history and vault entries.
  defp revoke_profiles(ctx, name_ref) do
    case Sanctum.Consent.revoke_source(ctx, name_ref) do
      {:ok, _revoked} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Compendium.Cascade] profile revocation skipped for #{name_ref}: #{inspect(reason)}"
        )
    end
  end

  defp disable_registrations(ctx, name_ref) do
    disable_webhooks(ctx, name_ref)
    disable_schedules(ctx, name_ref)
  end

  defp disable_webhooks(ctx, name_ref) do
    case Sanctum.Webhook.disable_for_component(ctx, name_ref) do
      {:ok, _disabled} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Compendium.Cascade] webhook cascade skipped for #{name_ref}: #{inspect(reason)}"
        )
    end
  end

  defp disable_schedules(ctx, name_ref) do
    case Arca.CronSchedule.list(Sanctum.Context.actor(ctx), limit: 1000) do
      {:ok, schedules} ->
        schedules
        |> Enum.filter(fn schedule ->
          targets?(schedule.resolved_reference, name_ref) or
            targets?(Map.get(schedule, :reference), name_ref)
        end)
        |> Enum.each(&remove_registration(ctx, &1))

      {:error, reason} ->
        Logger.warning("[Compendium.Cascade] schedule sweep skipped: #{inspect(reason)}")
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "[Compendium.Cascade] schedule cascade failed for #{name_ref}: #{Prima.LogFilter.exception_message(error)}"
      )

      :ok
  end

  # A schedule or feed of the removed component. A refused removal (a feed's
  # on a member that lost its slot answers `:not_owner`) leaves the row
  # behind, so it is said by the row's id and the reason, never its
  # content, and the uninstall goes on.
  defp remove_registration(ctx, schedule) do
    actor = Sanctum.Context.actor(ctx)

    case Arca.CronSchedule.soft_delete(actor, schedule.id) do
      {:ok, removed} ->
        announce_removed(actor, removed, schedule.status)

      {:error, reason} ->
        Logger.warning(
          "[Compendium.Cascade] registration #{schedule.id} was not removed: " <>
            refusal_word(reason)
        )
    end
  end

  # A schedule's removal is announced as the schedule tool's delete
  # announces one (`Opus.Schedules.Changes`, which this layer cannot
  # reach): once, after the commit, with the row as it was, under the
  # schedule's lock. A feed's row is not a schedule's.
  defp announce_removed(actor, %{kind: "schedule"} = removed, status_before) do
    Schedules.serialized(removed.id, fn ->
      payload =
        Schedules.new(actor, :removed, Schedules.row_fields(%{removed | status: status_before}))

      case Cyfr.Bus.broadcast(actor, Cyfr.Bus.schedules(actor), payload) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Compendium.Cascade] removal of #{removed.id} not announced: #{inspect(reason)}"
          )
      end
    end)
  end

  defp announce_removed(_actor, _feed, _status_before), do: :ok

  # The reason's name alone: a validation's map would carry its messages.
  defp refusal_word({:validation, _errors}), do: "validation"
  defp refusal_word(reason) when is_atom(reason), do: Atom.to_string(reason)

  # Registrations may name a versioned or a name-level ref; both point at
  # the component that just went away.
  defp targets?(nil, _name_ref), do: false

  defp targets?(target_ref, name_ref) when is_binary(target_ref) do
    case Prima.ComponentRef.to_name_ref(target_ref) do
      {:ok, ^name_ref} -> true
      _ -> false
    end
  end

  defp targets?(_target_ref, _name_ref), do: false
end
