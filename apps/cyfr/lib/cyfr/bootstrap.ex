# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bootstrap do
  @moduledoc """
  One-shot boot task: reconcile the operator list, and offer new seed media
  to the estates that already exist.

  No athanor is created here. A person's estate is minted at the door and
  filled on first need (`Sanctum.Provisioning`), so a server with nobody on
  it provisions nothing and reaches no registry. A failure is logged, never
  fatal — the app keeps serving and the next boot tries again.

  Disabled by `config :cyfr, provisioning_boot_enabled: false` (the test
  environment, where a boot-time write would precede any sandbox checkout).

  ## Boot ordering

  This is the last child of the infra tier. The root supervisor starts
  `[infra, web]` in order, so the operator reconcile finishes before the
  endpoint accepts requests: a de-listed operator's live session must not
  outlive the boot that dropped their email.

  Work runs synchronously in `init/1`, which returns `:ignore` without
  leaving a supervised process. Failures are logged and remain non-fatal.
  """

  use GenServer, restart: :temporary
  require Logger
  require Arca.Repo.Errors

  alias Sanctum.Tenancy.{Members, Users}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    _ = Cyfr.ControlPlane.when_owner(&run/0)

    # No process remains after synchronous initialization.
    :ignore
  rescue
    # Log bootstrap failures without preventing the application from serving.
    e ->
      Logger.error(
        "[Cyfr.Bootstrap] boot task raised: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      :ignore
  end

  @doc false
  def run do
    if Application.get_env(:cyfr, :provisioning_boot_enabled, true) do
      reconcile_platform_admins()
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
end
