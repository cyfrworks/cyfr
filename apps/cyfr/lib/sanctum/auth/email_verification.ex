# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.EmailVerification do
  @moduledoc """
  The email-verification guard for the browser callback (`ueberauth_oidcc`).

  The device-flow path (`Sanctum.Auth.DeviceFlow.fetch_user_info/2`) applies
  its own per-provider rule directly on the userinfo JSON it fetches.

  Rule: reject a missing email; reject an explicitly unverified one. Generic
  OIDC issuers do not always emit `email_verified`, so its absence is
  accepted for `:oidcc`; any other provider must assert `true`.
  """

  @type result :: :ok | {:error, :missing_email | :email_not_verified}
  @type claim :: true | false | :unknown

  @doc """
  Verify the email on a Ueberauth.Auth struct for the given provider.

  Reads the claim wherever the strategy put it: `raw_info.userinfo`, then
  `raw_info.claims`.
  """
  @spec verify(atom(), String.t() | nil, map() | any()) :: result()
  def verify(_provider, email, _extra) when email in [nil, ""], do: {:error, :missing_email}

  # Respect the claim when present, accept its absence: a missing-claim
  # rejection would break valid deployments, while an issuer that explicitly
  # says `false` is a real signal.
  def verify(:oidcc, _email, extra) do
    case email_verified_claim(extra) do
      false -> {:error, :email_not_verified}
      _ -> :ok
    end
  end

  # Unknown provider: fail closed — only an explicit `email_verified == true`
  # is trusted.
  def verify(_other, _email, extra) do
    case email_verified_claim(extra) do
      true -> :ok
      _ -> {:error, :email_not_verified}
    end
  end

  @doc """
  `verify/3`, and what the provider actually asserted: `{:ok, true}` when
  it proved the address and `{:ok, :unknown}` when it said nothing. An
  explicit `false` is a refusal. The door admits an exact email entry only
  on `true`.
  """
  @spec verify_with_claim(atom(), String.t() | nil, map() | any()) ::
          {:ok, claim()} | {:error, :missing_email | :email_not_verified}
  def verify_with_claim(provider, email, extra) do
    with :ok <- verify(provider, email, extra) do
      case email_verified_claim(extra) do
        true -> {:ok, true}
        _ -> {:ok, :unknown}
      end
    end
  end

  # Userinfo takes precedence over id-token claims.
  defp email_verified_claim(%{raw_info: %{userinfo: %{"email_verified" => v}}}), do: v
  defp email_verified_claim(%{raw_info: %{claims: %{"email_verified" => v}}}), do: v
  defp email_verified_claim(_), do: :unknown
end
