# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The execution implementation is configured before boot; this application manages readiness.
    children = [
      # Sliding-window rate limiter for policy enforcement.
      Opus.RateLimiter,
      # Shared Wasmex engine for compile-once/instantiate-many
      Opus.SharedEngine,
      # Counting semaphore to guard concurrent WASM execution memory
      {Opus.ExecutionSemaphore,
       max:
         Application.get_env(
           :cyfr,
           :max_concurrent_executions,
           Opus.ExecutionSemaphore.default_slots()
         ),
       tenant_max:
         Application.get_env(
           :cyfr,
           :max_concurrent_executions_per_tenant,
           Opus.ExecutionSemaphore.default_tenant_slots()
         )},
      # Execution bookkeeping: the execution_id → task registry and the
      # per-execution event-buffer pair. :rest_for_one, so a dead registry
      # restarts the buffers that register in it rather than stranding them.
      %{
        id: Opus.ExecutionTree,
        start:
          {Supervisor, :start_link,
           [
             [
               {Registry, keys: :unique, name: Opus.ExecutionRegistry},
               {Registry, keys: :unique, name: Opus.ExecutionEventBuffer.Registry},
               # Owns the per-stream emit counter. Before the buffers, so a
               # restart of this group rebuilds the numbering source first —
               # `:rest_for_one` then restarts the buffers that read it.
               Opus.ExecutionEventBuffer.Sequence,
               {DynamicSupervisor,
                name: Opus.ExecutionEventBuffer.Supervisor, strategy: :one_for_one}
             ],
             [
               strategy: :rest_for_one,
               name: Opus.ExecutionTree,
               max_restarts: 10,
               max_seconds: 60
             ]
           ]},
        type: :supervisor
      },
      # Supervised fire-and-forget tasks (run_stream)
      Supervisor.child_spec({Task.Supervisor, name: Opus.TaskSupervisor}, shutdown: 30_000),
      # Periodic sweep to mark stale "running" executions as failed (replaces one-shot startup sweep)
      Opus.ExecutionSweeper,
      # Owns the :protected ETS table of OAuth tokens dispensed to guests (for
      # SecretMasker); sweeps tokens from runs that never drained.
      Opus.OAuthTokenTracker
    ]

    opts = [strategy: :one_for_one, name: Opus.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end
end
