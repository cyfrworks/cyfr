# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bootstrap do
  @moduledoc """
  One-shot boot task: make sure the server's Home athanor is provisioned.

  Home is seeded by the baseline migration as a bare row; this task fills it
  (`Sanctum.Provisioning.provision/2`, as the server — the registry pull is
  anonymous) the first time the server boots. When the last Home was retired
  by its final member leaving, `ensure_home/0` mints its successor here. A
  failure is logged, never fatal — the app keeps serving, the operator's
  first sign-in retries, and so does the next boot.

  Disabled by `config :cyfr, provisioning_boot_enabled: false` (the test
  environment, where a boot-time write would precede any sandbox checkout).
  """

  use Task, restart: :temporary
  require Logger
  require Arca.Repo.Errors

  alias Sanctum.Tenancy.{Athanors, Members, Users}

  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  @doc false
  def run do
    if Application.get_env(:cyfr, :provisioning_boot_enabled, true) do
      reconcile_platform_admins()
      ensure_home_seeded()
      sync_seed_media()
    end

    :ok
  end

  # A new release may ship new seed media (bundle versions, a new AQUA
  # template); boot is when existing athanors are offered it — additively,
  # never over anything they own. A database outage at boot is tolerated
  # (the next boot and every sign-in retry); anything else raising here is
  # a bug and crashes this one-shot task loudly.
  defp sync_seed_media do
    Sanctum.Provisioning.sync_seeds()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Cyfr.Bootstrap] seed sync raised: #{Exception.message(e)}")
  end

  # `CYFR_PLATFORM_ADMIN_EMAILS` is the operator list, and a sign-in is what
  # normally reconciles a row against it. That only reaches people the door
  # still admits: drop an operator's email from the env *and* from the
  # allowlist and their row — and the session holding its capability —
  # survived until it expired. Boot is the other moment the env is read.
  defp reconcile_platform_admins do
    case Members.list_platform() do
      {:ok, platform_rows} ->
        for %{user_id: user_id} <- platform_rows, is_binary(user_id) do
          case Users.get(user_id) do
            {:ok, %{email: email}} ->
              unless Sanctum.Door.platform_admin_email?(email) do
                Logger.warning(
                  "[Cyfr.Bootstrap] #{user_id} is no longer in CYFR_PLATFORM_ADMIN_EMAILS — " <>
                    "revoking platform scope and its sessions"
                )

                # revoke_platform/1 revokes the person's sessions with the row.
                Members.revoke_platform(user_id)
              end

            _ ->
              :ok
          end
        end

      {:error, reason} ->
        Logger.error("[Cyfr.Bootstrap] platform reconcile skipped: #{inspect(reason)}")
    end

    :ok
  rescue
    # A database outage at boot is tolerated (the row layer answers most of
    # them as tuples handled above; the next boot or sign-in reconciles).
    # Any other raise is a bug and crashes this one-shot task loudly.
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Cyfr.Bootstrap] platform reconcile raised: #{Exception.message(e)}")
      :ok
  end

  defp ensure_home_seeded do
    case Athanors.ensure_home() do
      {:ok, %{provisioned_at: nil} = home} ->
        case Sanctum.Provisioning.provision(home, nil) do
          {:ok, _} ->
            Logger.info("[Cyfr.Bootstrap] Home athanor #{home.id} provisioned")

          {:error, reason} ->
            Logger.error(
              "[Cyfr.Bootstrap] Home athanor #{home.id} not provisioned: #{inspect(reason)}"
            )
        end

      {:ok, _already_provisioned} ->
        :ok

      {:error, reason} ->
        Logger.error("[Cyfr.Bootstrap] Home seeding skipped: #{inspect(reason)}")
    end
  rescue
    # Same shape as the reconcile above: a database outage logs and lets
    # the rest of boot proceed; a bug crashes loudly.
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Cyfr.Bootstrap] Home seeding raised: #{Exception.message(e)}")
  end
end
