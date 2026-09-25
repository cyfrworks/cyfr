# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.RegistrationBinding do
  @moduledoc """
  The gate on binding a standing registration (webhook, schedule) to a
  profile.

  Creating or re-pointing such a binding mints an attacker-timed
  invocation channel carrying the profile's full consented resources, so
  it demands the consent authorization class — not a permission atom,
  which a wildcard key would satisfy. Three checks, fail-closed:

  1. the profile exists in the caller's tenant **and** belongs to the
     registration's target component — a conduit cannot aim one
     component's authority at another;
  2. the profile has a live head consent;
  3. the caller passes `Sanctum.Consent.Authz` bound to that head's
     commit digest — interactive by default, guest-planed contexts and
     plain keys refused.
  """

  alias Sanctum.Consent.Authz
  alias Sanctum.Context

  @type error ::
          {:invalid_target, term()}
          | :profile_not_for_target
          | {:no_head_consent, String.t()}
          | {:consent_refused, Authz.refusal()}
          | term()

  @spec authorize(Context.t(), String.t(), String.t()) :: :ok | {:error, error()}
  def authorize(%Context{} = ctx, target_ref, profile_id)
      when is_binary(target_ref) and is_binary(profile_id) do
    actor = Context.actor(ctx)

    with {:ok, name_ref} <- name_level(target_ref),
         {:ok, candidates} <- Arca.ConsentStorage.profiles(actor, name_ref),
         :ok <- check_profile_for_target(candidates, profile_id),
         {:ok, consent} <- head_consent(actor, profile_id),
         {:ok, _via} <-
           check_authz(ctx, %Authz.Request{commit_digest: consent.commit_digest}) do
      :ok
    end
  end

  @doc """
  The sentence a refusal of `authorize/3` reads as: the consent class's
  own for a caller the class refused, and a plain account of which check
  failed otherwise.
  """
  @spec message(error()) :: String.t()
  def message({:consent_refused, refusal}),
    do: Sanctum.Unauthorized.message({:consent_class_required, refusal})

  def message({:invalid_target, _reason}), do: "the target reference is not valid"
  def message(:profile_not_for_target), do: "the profile belongs to another component"
  def message({:no_head_consent, _profile_id}), do: "the profile has no live consent"
  def message(reason), do: Prima.Refusal.message(reason)

  defp name_level(target_ref) do
    case Prima.ComponentRef.to_name_ref(target_ref) do
      {:ok, name_ref} -> {:ok, name_ref}
      {:error, reason} -> {:error, {:invalid_target, reason}}
    end
  end

  defp check_profile_for_target(candidates, profile_id) do
    if Enum.any?(candidates, &(&1.id == profile_id)) do
      :ok
    else
      {:error, :profile_not_for_target}
    end
  end

  defp head_consent(actor, profile_id) do
    case Arca.ConsentStorage.head_consent(actor, profile_id) do
      {:ok, consent} -> {:ok, consent}
      {:error, _} -> {:error, {:no_head_consent, profile_id}}
    end
  end

  defp check_authz(ctx, request) do
    case Authz.authorize(ctx, request) do
      {:ok, via} -> {:ok, via}
      {:error, refusal} -> {:error, {:consent_refused, refusal}}
    end
  end
end
