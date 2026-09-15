# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Worker do
  @moduledoc """
  A worker: a task under `Aqua.TaskSupervisor` whose death is answered to
  the process that awaits it rather than taking that process down, and
  which never outlives that process — a runner's loop, a loop's call.
  When the process that started it ends, for any reason, the worker is
  killed, and with it every worker it started in turn: a runner's death
  takes its loop, the loop's calls and any clone loop they run.
  """

  @doc "Start `fun` as a worker of the calling process; await it as any `Task`."
  @spec async((-> term())) :: Task.t()
  def async(fun) when is_function(fun, 0) do
    owner = self()

    Task.Supervisor.async_nolink(Aqua.TaskSupervisor, fn ->
      bind(owner, self())
      fun.()
    end)
  end

  defp bind(owner, worker) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      worker_ref = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_ref, :process, _, _} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_ref, :process, _, _} -> :ok
      end
    end)

    :ok
  end
end
