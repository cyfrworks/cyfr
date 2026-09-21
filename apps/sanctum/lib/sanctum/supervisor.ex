# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Supervisor do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The invoke-budget counters, owned by the application master so they
    # outlive every request that charges them.
    Sanctum.Authority.BudgetCounter.ensure_table()

    children =
      [
        # Releases a charged invoke-budget slot when its holder dies
        # without running its `after` (the brutal-kill cancel/timeout
        # paths).
        Sanctum.Authority.BudgetGuard,
        # The auth sliver's own Finch pool for IdP OAuth Device-Flow HTTP
        # calls (GitHub / Google). Registry and OCI traffic goes through
        # `Cyfr.Egress.pinned_request/5`, which owns its own connections;
        # this pool keeps OAuth userinfo HTTP off that path and reinforces
        # the sliver boundary at the supervision level.
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
