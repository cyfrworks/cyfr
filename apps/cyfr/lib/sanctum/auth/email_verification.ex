defmodule Sanctum.Auth.EmailVerification do
  @moduledoc """
  Provider-specific email-verification guard shared by the web OAuth paths
  (`Sanctum.Auth.SimpleOAuth` on Core, `Arx.Auth.OIDC` on Arx Lane 1).

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

  # Lane 2 enterprise OIDC: respect the claim when present, accept its
  # absence. Enterprise issuers don't always emit `email_verified`, and a
  # missing-claim rejection would break valid deployments; an issuer that
  # explicitly says `false` is still a real signal and is rejected.
  def verify(:oidcc, _email, extra) do
    case email_verified_claim(extra) do
      false -> {:error, :email_not_verified}
      _ -> :ok
    end
  end

  def verify(_other, _email, _extra), do: :ok

  defp email_verified_claim(%{raw_info: %{user: %{"email_verified" => v}}}), do: v
  defp email_verified_claim(%{raw_info: %{user: %{email_verified: v}}}), do: v
  defp email_verified_claim(%{raw_info: %{"user" => %{"email_verified" => v}}}), do: v
  defp email_verified_claim(_), do: :unknown
end
