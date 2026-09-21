# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bootstrap do
  @moduledoc """
  One-shot boot task: reconcile the operator list, and offer new seed media
  to the estates that already exist.

  No athanor is created here. A person's estate is minted at the door and
  filled on first need (`Compendium.Provisioning`), so a server with nobody on
  it provisions nothing and reaches no registry. A failure is logged, never
  fatal — the app keeps serving and the next boot tries again.

  Disabled by `config :cyfr, provisioning_boot_enabled: false` (the test
  environment, where a boot-time write would precede any sandbox checkout).

  ## Two claimed jobs, not one boot's duty

  Both halves are the cell's work rather than each member's, so each is
  taken under its own `job_claims` row (`Arca.JobClaims`, key `"cell"`):
  `bootstrap` for the operator reconcile, `seed_release` for the seed
  offer. The rows they write are shared, so one member doing the work
  covers every other; a member that finds a live peer holding a claim
  does not do it again.

  ## Boot ordering

  This is the last child of the infra tier. The root supervisor starts
  `[infra, web]` in order, so the operator reconcile finishes before the
  endpoint accepts requests: a de-listed operator's live session must not
  outlive the boot that dropped their email.

  In a cell that reconcile is one member's. A member that finds the
  `bootstrap` claim held waits for the holder to give it up — bounded by
  `:wait_ms`, 30 s by default — so its endpoint still opens behind a
  finished reconcile rather than beside a running one. A wait that runs
  out is logged and the boot goes on: a holder that died mid-reconcile
  must not hold every other member's endpoint shut, and its claim lapses
  for the next boot to take.

  Work runs synchronously in `init/1`, which returns `:ignore` without
  leaving a supervised process. Failures are logged and remain non-fatal.
  """

  use GenServer, restart: :temporary
  require Logger
  require Arca.Repo.Errors

  alias Arca.JobClaims
  alias Arca.Schemas.JobClaim
  alias Sanctum.Tenancy.{Members, Users}

  @lease_ms :timer.minutes(5)
  @wait_ms :timer.seconds(30)
  @poll_ms 250

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    if Arca.ControlPlane.held?(), do: run()

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

  @doc """
  Run the boot task's two claimed jobs.

  `opts`: `:key` (the claim key both jobs are taken under, `"cell"` by
  default), `:owner` (the member they are taken for, this boot by
  default), `:lease_ms` and `:wait_ms` (how long a member waits for a
  peer's operator reconcile before opening its own endpoint).
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) when is_list(opts) do
    if Application.get_env(:cyfr, :provisioning_boot_enabled, true) do
      claimed("bootstrap", opts, Keyword.get(opts, :wait_ms, @wait_ms), fn ->
        reconcile_platform_admins()
      end)

      claimed("seed_release", opts, 0, fn -> sync_seed_media() end)
    end

    :ok
  end

  # Take the job's row, do the work, and give the row up so the next boot
  # takes it at once rather than waiting a lease out. A live peer holding
  # it is doing the work: this member waits for it up to `wait_ms` — the
  # whole point for the operator reconcile, which gates this member's
  # endpoint — and then goes on.
  defp claimed(kind, opts, wait_ms, work) do
    key = Keyword.get(opts, :key, JobClaim.cell_key())
    owner = Keyword.get(opts, :owner, Cyfr.Boot.id())
    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)

    case JobClaims.claim(kind, key, owner, lease_ms) do
      {:ok, claim} ->
        try do
          work.()
        after
          JobClaims.release(claim)
        end

      {:busy, %JobClaim{owner: peer}} ->
        Logger.info("[Cyfr.Bootstrap] #{kind} is #{peer}'s this boot")
        wait_out(kind, key, owner, lease_ms, wait_ms, work)

      {:error, :database_error} ->
        Logger.error("[Cyfr.Bootstrap] the #{kind} claim could not be read; skipping it")
        :ok
    end
  end

  defp wait_out(kind, _key, _owner, _lease_ms, wait_ms, _work) when wait_ms <= 0 do
    Logger.debug("[Cyfr.Bootstrap] #{kind} is a peer's and this boot does not wait for it")
    :ok
  end

  defp wait_out(kind, key, owner, lease_ms, wait_ms, work) do
    Process.sleep(min(@poll_ms, wait_ms))

    case JobClaims.claim(kind, key, owner, lease_ms) do
      {:ok, claim} ->
        # The holder gave the row up, or its lease ran out. Either way the
        # work is this member's now: a released row means the peer
        # finished, and re-running the reconcile over its result costs
        # nothing and is what a lapsed row needs.
        try do
          work.()
        after
          JobClaims.release(claim)
        end

      {:busy, _peer} ->
        wait_out(kind, key, owner, lease_ms, wait_ms - @poll_ms, work)

      {:error, :database_error} ->
        Logger.error("[Cyfr.Bootstrap] the #{kind} claim could not be read while waiting")
        :ok
    end
  end

  # A new release may ship new seed media (bundle versions, a new AQUA
  # template); boot is when existing athanors are offered it — additively,
  # never over anything they own. A database outage at boot is tolerated
  # (the next boot and every sign-in retry); anything else raising here is
  # a bug and crashes this one-shot task loudly.
  defp sync_seed_media do
    Compendium.Provisioning.sync_seeds()
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
