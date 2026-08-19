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

  A refusal the operator can undo leaves a trace: `admit_identity/2` records
  the IdP subject as a pending request, so an issuer that never asserts
  `email_verified` — which no email entry can match — can be admitted by
  `user_id` without the operator having to find that subject some other way.
  """

  require Logger

  alias Sanctum.Door.Store

  # The page the users walk takes; `Users.list/1` caps at 500 either way.
  @page 500

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

        record_request(reason, user_id, email)
        {:error, {:door, reason}}
    end
  end

  @doc """
  Ask the door about everyone it has already let in, and eject whoever it
  would refuse now.

  Removing an allow entry — `*` most of all — closes the door, but the
  sessions and keys it issued outlive it by up to their whole TTL. Rather
  than work out which entry admitted whom, this re-asks `admit/3` for every
  person the server knows: it is the same decision, made by the same
  function, so the door cannot mean one thing at sign-in and another here.

  What it takes is what the door issued: sessions and API keys. What it
  leaves is standing — nothing is archived and no membership is touched.
  That is the difference between closing a door and denying a person
  (`Sanctum.Tenancy.Users.deny/1`, which does both).

  Returns the number of people ejected. Rare and operator-triggered, so the
  full walk is affordable; it is called from a task so a door verb answers
  without waiting.
  """
  @spec reconcile() :: {:ok, non_neg_integer()}
  def reconcile do
    {:ok, eject_refused(0, 0)}
  end

  defp eject_refused(offset, ejected) do
    case Sanctum.Tenancy.Users.list(limit: @page, offset: offset) do
      [] ->
        ejected

      users ->
        ejected = ejected + Enum.count(users, &eject_if_refused/1)

        # A page short of the limit is the last one; anything else and the
        # walk continues, because ejecting does not remove the rows.
        if length(users) < @page,
          do: ejected,
          else: eject_refused(offset + @page, ejected)
    end
  end

  defp eject_if_refused(user) do
    case admit(user.id, user.email, verified_claim(user)) do
      {:ok, _} ->
        false

      {:error, reason} ->
        Logger.info("[Sanctum.Door] #{user.id} no longer admitted (#{reason}) — ejecting")
        Sanctum.Session.revoke_all_for_user(user.id)
        Sanctum.ApiKey.revoke_all_created_by(user.id)
        true
    end
  end

  # `users.email_verified` is a nullable boolean: NULL is the provider that
  # said nothing, which is `admit/3`'s `:unknown`, not `false`. Reading it as
  # `false` here would eject everyone whose issuer omits the claim.
  defp verified_claim(%{email_verified: true}), do: true
  defp verified_claim(%{email_verified: false}), do: false
  defp verified_claim(_user), do: :unknown

  # A refusal the operator can act on. An email entry admits only a proved
  # address, so an issuer that omits `email_verified` is refused even when
  # the operator typed that exact address — and the operator has no way to
  # learn the IdP subject to allow instead, because the sign-in left no
  # trace. It leaves one now, keyed by the subject, which `door.requests`
  # lists and `door.resolve` turns into a real entry.
  #
  # Only `:not_allowed`. A `:denied` refusal already has its answer, and
  # writing a request for it would offer to undo a deny by approving it.
  defp record_request(:not_allowed, user_id, email) do
    note = if email, do: "refused at sign-in (#{email})", else: "refused at sign-in"

    case Store.request("user_id", user_id, user_id, note) do
      {:ok, :created, _} -> Sanctum.Notify.allowlist_request(email || user_id)
      _ -> :ok
    end
  end

  defp record_request(_reason, _user_id, _email), do: :ok

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
