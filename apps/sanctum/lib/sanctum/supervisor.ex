# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Supervisor do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Sanctum.Network.private_egress_targets()

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
        maybe_proof_memory()
      ]
      |> List.flatten()

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: __MODULE__,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  defp maybe_proof_memory do
    case Sanctum.Consent.Proof.store() do
      Sanctum.Consent.Proof.Memory -> [Sanctum.Consent.Proof.Memory]
      _ -> []
    end
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
