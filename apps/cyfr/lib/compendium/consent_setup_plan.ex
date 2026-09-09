# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ConsentSetupPlan do
  @moduledoc """
  The consent-sourced half of `Compendium.Component.setup_plan/2`.

  A profile is ready only when every required need has a live vault binding
  whose digest matches the consent. Rebinding or revocation can make it
  unready without changing the manifest.

  `Compendium.Component.setup_plan/2` embeds this as the `consent` section
  of its response and derives the top-level `ready` from it — the consent
  state is the only thing that answers "is this component set up".
  """

  alias Sanctum.Consent.Source
  alias Sanctum.Context
  alias Sanctum.VaultReader

  @doc """
  The consent section for a source ref, or `nil` when no profile exists
  (the component then reads ready only if it requires nothing).
  """
  @spec section(Context.t(), String.t()) :: map() | nil
  def section(%Context{} = ctx, source_ref) do
    with {:ok, name_ref} <- name_ref(source_ref),
         {:ok, [_ | _] = profiles} <- Source.impl().profiles(ctx, name_ref),
         profile <- pick_profile(profiles) do
      describe(ctx, profile)
    else
      _ -> nil
    end
  end

  defp name_ref(ref) do
    case Compendium.Activation.key_for_ref(ref) do
      {:ok, name_ref} -> {:ok, name_ref}
      _ -> :error
    end
  end

  # The owner profile is what "is this set up" asks about; a public twin
  # is a separate, deliberately narrower grant.
  defp pick_profile(profiles) do
    Enum.find(profiles, &(&1.kind == :owner)) || hd(profiles)
  end

  defp describe(ctx, profile) do
    case Source.impl().head_consent(ctx, profile.id) do
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

  # One row per vault reference the head consent carries: live, bound,
  # and still matching the digest the operator approved.
  defp check_needs(ctx, consent) do
    Enum.map(consent.vault_refs, fn ref ->
      {satisfied, detail} = check_ref(ctx, ref)

      %{
        entry_id: ref.vault_entry_id,
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

  defp check_ref(ctx, ref) do
    # Use the shared vault resolution check for status and binding validity.
    case VaultReader.usable(ctx.athanor_id, ref.vault_entry_id, ref.binding_digest) do
      {:ok, entry} ->
        {true, "bound to #{entry.name}"}

      {:error, {:binding_mismatch, name}} ->
        {false, "#{name} was rebound since this consent — re-approve to continue"}

      {:error, {:entry_unavailable, name, status}} ->
        {false, "#{name} is #{status}"}

      {:error, :not_found} ->
        {false, "the bound vault entry no longer exists"}
    end
  end
end
