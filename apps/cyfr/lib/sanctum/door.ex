# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Door do
  @moduledoc """
  The door: who may sign in to this server at all.

  Every auth provider asks here **before** it creates a session, and before
  anything is said to cyfr.run about the identity. Two lists, two jobs:
  `CYFR_PLATFORM_ADMIN_EMAILS` names the operators — always admitted, and
  admitted as platform admins; the server allowlist (`Sanctum.Door.Store`)
  names everyone else, by email, by IdP subject, or as `*` (any identity the
  configured provider authenticates). A specific deny wins over everything —
  including `*` — so a public door still has an eject; allowing that
  identity again is an explicit operator act.

  Emails admit only what the provider proved: an exact email entry needs
  `verified == true` (a provider that does not assert verification is
  matched by a `user_id` entry instead), and `*` admits any identity whose
  email is not known to be unverified. The operator's own list is trusted as
  typed — an absent claim admits (audited by `Sanctum.SignIn`), a provider
  that positively says the address is unverified does not. Refusals carry no
  detail a stranger could use to enumerate the list.
  """

  alias Sanctum.Door.Store

  @type verdict :: {:ok, :admin | :allowed} | {:error, :denied | :not_allowed}

  @doc """
  Decide whether the identity may sign in.

  `verified` is what the provider asserted about `email`: `true`, `false`,
  or `:unknown` when it said nothing.
  """
  @spec admit(String.t(), String.t() | nil, boolean() | :unknown) :: verdict()
  def admit(user_id, email, verified) when is_binary(user_id) do
    email = normalize_email(email)

    cond do
      Store.denied?(user_id, email) -> {:error, :denied}
      platform_admin_email?(email) and verified != false -> {:ok, :admin}
      Store.wildcard?() and verified != false -> {:ok, :allowed}
      Store.allowed?("user_id", user_id) -> {:ok, :allowed}
      verified == true and Store.allowed?("email", email) -> {:ok, :allowed}
      true -> {:error, :not_allowed}
    end
  end

  @doc """
  `admit/3` for an auth provider: takes the extracted user info (`email`,
  `verified`), audits a refusal and returns it as `{:error, {:door, reason}}`
  so it can travel through the provider's `authenticate/1` contract.
  """
  @spec admit_identity(String.t(), map()) :: {:ok, :admin | :allowed} | {:error, {:door, atom()}}
  def admit_identity(user_id, user_info) when is_binary(user_id) and is_map(user_info) do
    email = Map.get(user_info, :email)

    case admit(user_id, email, Map.get(user_info, :verified, :unknown)) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        :telemetry.execute([:cyfr, :sanctum, :door, :refused], %{count: 1}, %{
          user_id: user_id,
          email: email,
          reason: reason
        })

        {:error, {:door, reason}}
    end
  end

  @doc "Is this email one of the operators named in `CYFR_PLATFORM_ADMIN_EMAILS`?"
  @spec platform_admin_email?(String.t() | nil) :: boolean()
  def platform_admin_email?(email) when is_binary(email) do
    String.downcase(email) in Application.get_env(:cyfr, :platform_admin_emails, [])
  end

  def platform_admin_email?(_), do: false

  @doc """
  Would an invite of `email` admit that person on their first sign-in? True
  when the door is `*` or names the address; a request is queued otherwise
  (`Sanctum.Door.Store.request/2`).
  """
  @spec email_admitted?(String.t()) :: boolean()
  def email_admitted?(email) when is_binary(email) do
    email = normalize_email(email)

    not Store.denied?(nil, email) and
      (platform_admin_email?(email) or Store.wildcard?() or Store.allowed?("email", email))
  end

  @doc "The one refusal a stranger sees, whichever branch refused."
  @spec refusal_message() :: String.t()
  def refusal_message, do: "not allowed on this server — ask the operator"

  defp normalize_email(nil), do: nil
  defp normalize_email(""), do: nil
  defp normalize_email(email) when is_binary(email), do: String.downcase(email)
end
