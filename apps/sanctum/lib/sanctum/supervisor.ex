# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Supervisor do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Sanctum.Network.private_egress_targets()

    # The deployment's pinned enrollment directory, refused here whichever
    # configuration wrote it.
    directory_url!(Application.get_env(:sanctum, :directory_url))

    # Who may mint the installation's first person, installed before any
    # child starts and so before any ingress opens: Sanctum starts before
    # the host. A configured restore token reserves the first person for
    # the restore path; without one, the installation admits its first
    # person by an ordinary door.
    Arca.InstallationClaims.install_mode!(
      installation_mode!(Application.get_env(:sanctum, :restore_token))
    )

    # The invoke-budget counters, owned by the application master so they
    # outlive every request that charges them.
    Sanctum.Authority.BudgetCounter.ensure_table()

    children =
      [
        # Advisory counters also serve identity flows before Host starts.
        Prima.RateLimiter,
        # Releases a charged invoke-budget slot when its holder dies
        # without running its `after` (the brutal-kill cancel/timeout
        # paths).
        Sanctum.Authority.BudgetGuard,
        # The auth sliver's own Finch pool for IdP OAuth Device-Flow HTTP
        # calls (GitHub / Google). Caller-selected destinations use
        # Sanctum.Egress's pinned connections instead of this fixed-host pool.
        {Finch, name: Sanctum.Auth.Finch},
        # OAuth refresh single-flight (see `Sanctum.OAuth.RefreshLock`):
        # the registry and the task pool whose leaders register in it
        # restart together.
        group(Sanctum.OAuth.RefreshTree, [
          {Registry, keys: :unique, name: Sanctum.OAuth.RefreshRegistry},
          {Task.Supervisor, name: Sanctum.OAuth.RefreshTaskSupervisor}
        ]),
        # Provisioning retries that must not ride a sign-in (registry
        # pulls), and the keepers that renew their claims' leases.
        {Task.Supervisor, name: Sanctum.ProvisioningSupervisor},
        # This domain's own fire-and-forget writes off a caller's hot path:
        # the session slide an establish triggers (`Sanctum.Caller`). On
        # demand only — nothing is started here.
        {Task.Supervisor, name: Sanctum.TaskSupervisor},
        # Single-use consent authorizations. The shipped store is the DB
        # (config.exs pins Proof.DB); the in-memory GenServer starts only
        # when a deployment explicitly configures it, so production does
        # not carry a live, never-called singleton.
        maybe_proof_memory(),
        # Says once, at boot, which stored grants name a storage path the
        # grammar no longer admits; the loader refuses them regardless.
        # It runs alone and may end, so a failure costs only its notice.
        stored_grants_check()
      ]
      |> List.flatten()

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: __MODULE__,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  # A malformed value refuses the boot naming the key and never the value:
  # the token is a secret, and a URL may carry what an operator did not
  # mean to print.
  @doc false
  @spec installation_mode!(String.t() | nil) :: :ordinary | :restore_reserved
  def installation_mode!(nil), do: :ordinary

  def installation_mode!(token) do
    if Sanctum.restore_token?(token),
      do: :restore_reserved,
      else:
        raise(
          "[Sanctum] FATAL: the restore token (:sanctum, :restore_token, from " <>
            "CYFR_RESTORE_TOKEN) must be exactly 64 lowercase hexadecimal characters"
        )
  end

  defp directory_url!(nil), do: :ok

  defp directory_url!(url) do
    if Sanctum.enrollment_directory?(url),
      do: :ok,
      else:
        raise(
          "[Sanctum] FATAL: the enrollment directory (:sanctum, :directory_url, from " <>
            "CYFR_DIRECTORY_URL) must be an https directory URL: an origin and an " <>
            "optional path, with no user, query or fragment"
        )
  end

  defp maybe_proof_memory do
    case Sanctum.Consent.Proof.store() do
      Sanctum.Consent.Proof.Memory -> [Sanctum.Consent.Proof.Memory]
      _ -> []
    end
  end

  # A one-shot read of every athanor's heads, outside any test's sandbox:
  # the suite turns it off and drives `Sanctum.Consent.StoredGrants`
  # directly.
  defp stored_grants_check do
    if Application.get_env(:sanctum, :stored_grants_check_enabled, true),
      do: [Sanctum.Consent.StoredGrants],
      else: []
  end

  # A registry and the processes that hold references into it restart
  # together: :rest_for_one from the registry down, so a restart never
  # leaves dependents holding a name that resolves to nothing.
  defp group(name, children) do
    %{
      id: name,
      start:
        {Supervisor, :start_link,
         [
           List.flatten(children),
           [strategy: :rest_for_one, name: name, max_restarts: 10, max_seconds: 60]
         ]},
      type: :supervisor
    }
  end
end
