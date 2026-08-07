# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ConsentSetupPlan do
  @moduledoc """
  The consent-sourced half of `Compendium.Component.setup_plan/2`.

  When a component has a profile, "is it ready" stops being a question
  about declared secrets and stored policy and becomes the §4.3 one:
  does every bound need still have a live vault entry whose derived
  binding digest matches what the consent recorded? A rebind or a
  revocation makes a profile not-ready without touching the manifest.

  The legacy manifest-sourced fields stay in the response — surfaces
  still read them, and their truthfulness is what keeps the old setup
  paths from looping — so this adds a `consent` section and takes over
  `ready` rather than replacing the shape.
  """

  alias Sanctum.Consent.Source
  alias Sanctum.Context
  alias Sanctum.VaultReader

  @doc """
  The consent section for a source ref, or `nil` when no profile exists
  (the caller keeps the legacy plan verbatim).
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
        needs = check_needs(ctx, consent)

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

  defp check_ref(ctx, ref) do
    case Arca.VaultStorage.get(ctx.org_id, ref.vault_entry_id) do
      {:ok, %{status: "active"} = entry} ->
        case VaultReader.binding_digest(entry) do
          {:ok, digest} ->
            if Plug.Crypto.secure_compare(digest, ref.binding_digest) do
              {true, "bound to #{entry.name}"}
            else
              {false, "#{entry.name} was rebound since this consent — re-approve to continue"}
            end

          _ ->
            {false, "the connection's binding could not be derived"}
        end

      {:ok, %{status: status, name: name}} ->
        {false, "#{name} is #{status}"}

      _ ->
        {false, "the bound connection no longer exists"}
    end
  end
end
