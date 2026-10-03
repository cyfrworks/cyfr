# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ConsentSetupPlan do
  @moduledoc """
  The consent-sourced half of `Compendium.Component.setup_plan/2`.

  A profile is ready only when every required need has a live vault binding
  whose digest matches the consent. Rebinding or revocation can make it
  unready without changing the manifest.

  Each row of the head revision is read by what it names
  (`Sanctum.Consent.row_binding/3`): the athanor's own entry, held
  to the digest the person approved; a selection of another profile's
  key, resolved as a run resolves it and its lender's entry held to the
  same check, or reported not ready with the reason it resolves to
  nothing; and an instance entry, which this check does not read and
  reports not ready.

  `Compendium.Component.setup_plan/2` embeds this as the `consent` section
  of its response and derives the top-level `ready` from it — the consent
  state is the only thing that answers "is this component set up".
  """

  alias Sanctum.Context
  alias Sanctum.VaultReader

  @doc """
  The consent section for a source ref, or `nil` when no profile exists
  (the component then reads ready only if it requires nothing).

  A store that cannot be read, or a profile row that cannot be decoded
  where the one asked about would be, is a section that is not ready
  (`profile_status: :unavailable` or `:corrupt`) — never `nil`, which
  would read "nothing granted" and let a component that needs nothing
  report ready on a store nobody could read.
  """
  @spec section(Context.t(), String.t()) :: map() | nil
  def section(%Context{} = ctx, source_ref) do
    with {:ok, name_ref} <- name_ref(source_ref),
         {:ok, [_ | _] = entries} <- read_profiles(ctx, name_ref) do
      case pick_profile(entries) do
        %{status: :corrupt} = corrupt -> not_ready(corrupt.id, :corrupt)
        profile -> describe(ctx, profile)
      end
    else
      {:error, :unavailable} -> not_ready(nil, :unavailable)
      _ -> nil
    end
  end

  defp read_profiles(ctx, name_ref) do
    case Sanctum.Consent.profiles(ctx, name_ref) do
      {:ok, entries} -> {:ok, entries}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _no_tenant} -> :none
    end
  end

  defp not_ready(profile_id, status) do
    %{
      profile_id: profile_id,
      profile_kind: nil,
      profile_status: status,
      revision: nil,
      scope: nil,
      needs: [],
      ready: false
    }
  end

  defp name_ref(ref) do
    case Prima.ComponentRef.to_name_ref(ref) do
      {:ok, name_ref} -> {:ok, name_ref}
      _ -> :error
    end
  end

  # The owner profile is what "is this set up" asks about; a public twin
  # is a separate, deliberately narrower grant. A row that cannot be
  # decoded may be the owner, so it is what the section reports whenever
  # no decoded owner answers.
  defp pick_profile(entries) do
    Enum.find(entries, &(Map.get(&1, :kind) == :owner)) ||
      Enum.find(entries, &(&1.status == :corrupt)) || hd(entries)
  end

  defp describe(ctx, profile) do
    case Sanctum.Consent.head_consent(ctx, profile.id) do
      {:ok, consent} ->
        bound = check_needs(ctx, consent)
        needs = bound ++ unbound_required(ctx, profile.source_ref, bound)

        %{
          profile_id: profile.id,
          profile_kind: profile.kind,
          profile_status: profile.status,
          revision: consent.revision,
          scope: consent.scope,
          needs: needs,
          ready: profile.status == :active and Enum.all?(needs, & &1.satisfied)
        }

      _ ->
        %{
          profile_id: profile.id,
          profile_kind: profile.kind,
          profile_status: profile.status,
          revision: nil,
          scope: nil,
          needs: [],
          ready: false
        }
    end
  end

  # One row per binding the head consent carries, read by what it names.
  defp check_needs(ctx, consent) do
    Enum.map(consent.vault_refs, fn ref ->
      {entry_id, satisfied, detail} =
        check_ref(ctx, Sanctum.Consent.row_binding(ctx, consent, ref))

      %{
        entry_id: entry_id,
        satisfied: satisfied,
        detail: detail
      }
    end)
  end

  # Check each required need for a binding. Commit validation ensures each
  # binding names a declared need and that no need has duplicate bindings.
  defp unbound_required(ctx, source_ref, bound) do
    with [] <- bound,
         {:ok, declared, _caps} when is_list(declared) <-
           Sanctum.Consent.ShapeDerivation.manifest_blocks(ctx, source_ref) do
      for need <- declared, need.required do
        %{
          need: need.name,
          satisfied: false,
          detail: "no vault entry bound for '#{need.name}' — grant one to continue"
        }
      end
    else
      _ -> []
    end
  end

  # The athanor's own entry, live and still at the digest approved.
  defp check_ref(ctx, {:entry, entry_id, digest}), do: usable(ctx, entry_id, digest, "")

  # A selection resolved to its lender's entry is held to the same check.
  defp check_ref(ctx, {:selection, label, {:ok, %{scope: "athanor"} = vault}}),
    do: usable(ctx, vault.entry_id, vault.binding_digest, " (lent by its #{label} profile)")

  defp check_ref(_ctx, {:selection, label, {:ok, _instance}}),
    do:
      {nil, false, "the #{label} profile lends an instance entry, which this check does not read"}

  defp check_ref(_ctx, {:selection, label, {:error, reason}}),
    do: {nil, false, unresolved(label, reason)}

  defp check_ref(_ctx, {:instance, _instance_entry_id}),
    do: {nil, false, "bound to an instance entry, which this check does not read"}

  defp check_ref(_ctx, :malformed), do: {nil, false, "the binding names no entry"}

  defp usable(ctx, entry_id, digest, lent) do
    # Use the shared vault resolution check for status and binding validity.
    case VaultReader.usable(ctx.athanor_id, entry_id, digest) do
      {:ok, entry} ->
        {entry_id, true, "bound to #{entry.name}#{lent}"}

      {:error, {:binding_mismatch, name}} ->
        {entry_id, false,
         "#{name}#{lent} was rebound since this consent — re-approve to continue"}

      {:error, {:entry_unavailable, name, status}} ->
        {entry_id, false, "#{name}#{lent} is #{status}"}

      {:error, :not_found} ->
        {entry_id, false, "the bound vault entry no longer exists"}
    end
  end

  # Why a selection resolves to nothing, in the person's words.
  defp unresolved(label, {:profile_unavailable, status}),
    do: "the #{label} profile it borrows from is #{status} — re-approve that profile to continue"

  defp unresolved(label, {:no_such_profile, _target, _label}),
    do: "no #{label} profile lends a key here — grant one to continue"

  defp unresolved(label, :binding_moved),
    do: "the #{label} profile's key was rebound since this consent — re-approve to continue"

  defp unresolved(label, :nothing_bound), do: "the #{label} profile binds no key"

  defp unresolved(label, {:consent_required, _payload}),
    do: "the #{label} profile's grant does not admit this origin"

  defp unresolved(label, _reason), do: "the selection of the #{label} profile resolves to nothing"
end
