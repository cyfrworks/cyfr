# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.EmailVerification do
  @moduledoc """
  Provider-specific email-verification guard shared by the web OAuth paths
  (`Sanctum.Auth.OAuth` by default, or a configured auth provider).

  The CLI path (`Sanctum.Auth.DeviceFlow.fetch_user_info/2`) applies the same
  rule directly on the userinfo JSON it fetches — this module mirrors that
  rule for the Ueberauth.Auth struct.

  Rule: reject missing email; reject explicitly-unverified email. Missing
  `email_verified` claim is treated per-provider — GitHub's verified-primary
  is surfaced by Ueberauth itself, so absence of the flag is accepted;
  Google always emits the flag in userinfo, so its absence is treated as
  unverified and rejected.
  """

  @type result :: :ok | {:error, :missing_email | :email_not_verified}
  @type claim :: true | false | :unknown

  @doc """
  Verify the email on a Ueberauth.Auth struct for the given provider.

  Reads `auth.extra.raw_info.user["email_verified"]` (Ueberauth stashes the
  provider's raw userinfo there for both GitHub and Google).
  """
  @spec verify(atom(), String.t() | nil, map() | any()) :: result()
  def verify(_provider, email, _extra) when email in [nil, ""], do: {:error, :missing_email}

  def verify(:github, _email, extra) do
    case email_verified_claim(extra) do
      false -> {:error, :email_not_verified}
      _ -> :ok
    end
  end

  def verify(:google, _email, extra) do
    case email_verified_claim(extra) do
      true -> :ok
      _ -> {:error, :email_not_verified}
    end
  end

  # Generic OIDC (ueberauth_oidcc): respect the claim when present, accept its
  # absence. OIDC issuers don't always emit `email_verified`, and a
  # missing-claim rejection would break valid deployments; an issuer that
  # explicitly says `false` is still a real signal and is rejected.
  def verify(:oidcc, _email, extra) do
    case email_verified_claim(extra) do
      false -> {:error, :email_not_verified}
      _ -> :ok
    end
  end

  # Unknown provider: fail closed. We have no basis to trust the address, so
  # require an explicit `email_verified == true` (same posture as Google).
  # An absent or false claim is rejected rather than silently accepted.
  def verify(_other, _email, extra) do
    case email_verified_claim(extra) do
      true -> :ok
      _ -> {:error, :email_not_verified}
    end
  end

  @doc """
  `verify/3`, and what the provider actually asserted: `{:ok, true}` when
  it proved the address, `{:ok, false}` never (that is a refusal), and
  `{:ok, :unknown}` when it said nothing. The door admits an exact email
  entry only on `true`; GitHub's primary email is verified by the strategy
  itself, so its silence counts as `true`.
  """
  @spec verify_with_claim(atom(), String.t() | nil, map() | any()) ::
          {:ok, claim()} | {:error, :missing_email | :email_not_verified}
  def verify_with_claim(provider, email, extra) do
    with :ok <- verify(provider, email, extra) do
      case {provider, email_verified_claim(extra)} do
        {_, true} -> {:ok, true}
        {:github, :unknown} -> {:ok, true}
        {_, _} -> {:ok, :unknown}
      end
    end
  end

  defp email_verified_claim(%{raw_info: %{user: %{"email_verified" => v}}}), do: v
  defp email_verified_claim(%{raw_info: %{user: %{email_verified: v}}}), do: v
  defp email_verified_claim(%{raw_info: %{"user" => %{"email_verified" => v}}}), do: v
  defp email_verified_claim(_), do: :unknown
end
