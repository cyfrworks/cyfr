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
  alias Sanctum.Consent.Source
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
    source = Source.impl()

    with {:ok, name_ref} <- name_level(target_ref),
         {:ok, candidates} <- source.profiles(ctx, name_ref),
         :ok <- check_profile_for_target(candidates, profile_id),
         {:ok, consent} <- head_consent(source, ctx, profile_id),
         {:ok, _via} <-
           check_authz(ctx, %Authz.Request{commit_digest: consent.commit_digest}) do
      :ok
    end
  end

  defp name_level(target_ref) do
    case Sanctum.ComponentRef.to_name_ref(target_ref) do
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

  defp head_consent(source, ctx, profile_id) do
    case source.head_consent(ctx, profile_id) do
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
