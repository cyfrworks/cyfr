# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignIn do
  @moduledoc """
  What happens once, at sign-in, after the door admitted an identity — and
  never per request.

  The person's `users` row is written or refreshed; an operator (verdict
  `:admin`) gets the platform-admin membership and a seat in Home, and a
  person the env list no longer names loses the platform row; every
  `invited` group row for the person's verified email becomes their active
  membership; and — once the cyfr.run namespace is known — the person's own
  athanor is minted and provisioned (`Sanctum.Provisioning.after_sign_in/1`;
  a person still ahead of the claim gate gets theirs when they claim).

  Providers call `admitted/2` between `Sanctum.Door.admit/3` and building
  the context. `Sanctum.Tenancy.resolve_into/2` — which runs per request —
  only ever reads what this wrote.
  """

  require Logger

  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @doc """
  Record the admitted sign-in. `user_info` carries `id`, `provider`,
  `email`, `verified` (`true | false | :unknown`) and `name`.
  """
  @spec admitted(map(), :admin | :allowed) :: {:ok, Arca.Schemas.User.t()} | {:error, term()}
  def admitted(%{id: user_id} = user_info, verdict) when verdict in [:admin, :allowed] do
    with {:ok, user} <- Users.upsert_from_provider(user_info) do
      apply_platform(user_id, verdict)
      {:ok, _n} = Members.activate_invited(user)
      # Provisioning failure is recorded on the athanor and retried on the
      # next sign-in; it never refuses the sign-in itself.
      _ = Sanctum.Provisioning.after_sign_in(user_id)
      Users.get(user_id)
    end
  end

  # An operator's first sign-in mints the platform row and a seat in Home:
  # the out-of-the-box install is one admin with two athanors, Home and
  # their own. Removing an email from CYFR_PLATFORM_ADMIN_EMAILS revokes the
  # platform row on the next sign-in; the Home seat is an ordinary membership
  # and stays.
  defp apply_platform(user_id, :admin) do
    already? = platform_admin?(user_id)

    case Members.ensure_platform(user_id) do
      {:ok, _} ->
        unless already?, do: emit_platform_bootstrap(user_id)
        seat_in_home(user_id)

      {:error, reason} ->
        Logger.error(
          "[Sanctum.SignIn] platform admin bootstrap failed for #{user_id}: #{inspect(reason)}"
        )
    end
  end

  # An email dropped from CYFR_PLATFORM_ADMIN_EMAILS loses the operator bit
  # here. The bit is re-read from the row on every request, so a revoke that
  # fails leaves an operator who should not be one — never silent.
  defp apply_platform(user_id, :allowed) do
    case Members.revoke_platform(user_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[Sanctum.SignIn] platform revoke failed for #{user_id}: #{inspect(reason)}")

        :telemetry.execute([:cyfr, :sanctum, :door, :revoke_failed], %{count: 1}, %{
          user_id: user_id
        })

        :ok
    end
  end

  # A sign-in must not 500 on a broken install: no Home means no seat, loudly.
  defp seat_in_home(user_id) do
    with {:ok, home} <- Athanors.home(),
         {:ok, _} <-
           Members.ensure(user_id, scope: "athanor", athanor_id: home.id, added_by: "system") do
      # Home is provisioned at boot; an operator's sign-in retries a boot
      # that could not reach the registry, with their credential.
      Sanctum.Provisioning.retry_home_async(user_id)
    else
      {:error, reason} ->
        Logger.error("[Sanctum.SignIn] Home seat failed: #{inspect(reason)}")
        :ok
    end
  end

  defp platform_admin?(user_id) do
    case Members.list_by_user(user_id) do
      rows when is_list(rows) -> Enum.any?(rows, &(&1.scope == "platform"))
      _ -> false
    end
  end

  # The widest grant in the system, and its only input is an email address —
  # under a generic OIDC issuer `email_verified` may legitimately be absent,
  # so the address is asserted rather than proven. Minting it is audited.
  defp emit_platform_bootstrap(user_id) do
    Logger.warning(
      "[Sanctum.SignIn] minted platform-scope membership for #{user_id} " <>
        "(matched CYFR_PLATFORM_ADMIN_EMAILS)"
    )

    :telemetry.execute(
      [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
      %{count: 1},
      %{user_id: user_id}
    )
  end
end
