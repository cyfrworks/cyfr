# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Cascade do
  @moduledoc """
  What follows a component name out of the registry: when the LAST
  version of a name is removed, its profiles are revoked (§3.10 — consent
  rows stay, insert-only history; vault entries stay, the operator's) and
  its standing registrations are disabled (webhooks, cron schedules — a
  registration outliving its target is an invocation channel pointed at
  nothing, and one that would go live again the moment anyone republished
  the name). `Compendium.Registry.delete/4` and the prune path call this;
  the byte/row deletion itself stays the registry's.
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
      name_ref = "#{component_type}:#{publisher}.#{comp.name}"

      revoke_profiles(ctx, name_ref)
      disable_registrations(ctx, name_ref)

      Logger.debug(
        "[Compendium.Cascade] Cleaned up name-level state for #{name_ref} (last version removed)"
      )
    end

    :ok
  end

  # §3.10: removing a component revokes its profiles. Consent rows stay —
  # they are insert-only history, and the revoked profile status is the
  # live gate. Vault entries stay too: they are the operator's, and they
  # outlive any component that borrowed them.
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
          Arca.WebhookStorage.set_disabled(webhook.name, athanor_id)
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
    ctx
    |> Arca.CronSchedule.list(limit: 1000)
    |> Enum.filter(fn schedule ->
      targets?(schedule.resolved_reference, name_ref) or
        targets?(Map.get(schedule, :reference), name_ref)
    end)
    |> Enum.each(fn schedule -> Arca.CronSchedule.soft_delete(ctx, schedule.id) end)

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
