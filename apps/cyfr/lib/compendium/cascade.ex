# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Cascade do
  @moduledoc """
  Revokes profiles and disables webhook and cron registrations when the
  last version of a component name is removed. Consent history and vault
  entries remain. Called by registry deletion and pruning; the registry
  owns removal of the component's bytes and row.
  """

  require Logger

  alias Compendium.ComponentPath
  alias Sanctum.Context

  @doc """
  Run the name-level cascade for a just-deleted component row: a no-op
  while other versions of the name remain; when none do, revoke the
  name's profiles and disable its registrations.
  """
  @spec name_removed(Context.t(), map()) :: :ok
  def name_removed(%Context{} = ctx, comp) do
    publisher = ComponentPath.normalize_publisher(Map.get(comp, :publisher))

    unless Arca.ComponentStorage.has_remaining_versions?(ctx, comp.name, publisher) do
      component_type = Map.get(comp, :component_type, "")
      name_ref = Cyfr.ComponentRef.build(component_type, publisher, comp.name)

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
    case Arca.ProfileStorage.list_for_source(ctx.athanor_id, name_ref) do
      {:ok, profiles} ->
        Enum.each(profiles, fn profile ->
          Arca.ProfileStorage.set_status(ctx.athanor_id, profile.id, "revoked")
        end)

      _ ->
        :ok
    end
  end

  defp disable_registrations(ctx, name_ref) do
    disable_webhooks(ctx, name_ref)
    disable_schedules(ctx, name_ref)
  end

  defp disable_webhooks(ctx, name_ref) do
    athanor_id = ctx.athanor_id

    case Arca.WebhookStorage.list_webhooks(athanor_id) do
      {:ok, webhooks} ->
        webhooks
        |> Enum.filter(&targets?(&1.target_ref, name_ref))
        |> Enum.each(fn webhook ->
          Arca.WebhookStorage.set_disabled(athanor_id, webhook.name)
        end)

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[Compendium.Cascade] webhook cascade failed for #{name_ref}: #{Exception.message(error)}"
      )

      :ok
  end

  defp disable_schedules(ctx, name_ref) do
    case Arca.CronSchedule.list(ctx, limit: 1000) do
      {:ok, schedules} ->
        schedules
        |> Enum.filter(fn schedule ->
          targets?(schedule.resolved_reference, name_ref) or
            targets?(Map.get(schedule, :reference), name_ref)
        end)
        |> Enum.each(fn schedule -> Arca.CronSchedule.soft_delete(ctx, schedule.id) end)

      {:error, reason} ->
        Logger.warning("[Compendium.Cascade] schedule sweep skipped: #{inspect(reason)}")
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "[Compendium.Cascade] schedule cascade failed for #{name_ref}: #{Exception.message(error)}"
      )

      :ok
  end

  # Registrations may name a versioned or a name-level ref; both point at
  # the component that just went away.
  defp targets?(nil, _name_ref), do: false

  defp targets?(target_ref, name_ref) when is_binary(target_ref) do
    case Compendium.Activation.key_for_ref(target_ref) do
      {:ok, ^name_ref} -> true
      _ -> false
    end
  end

  defp targets?(_target_ref, _name_ref), do: false
end
