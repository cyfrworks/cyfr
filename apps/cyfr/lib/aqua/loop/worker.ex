# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Worker do
  @moduledoc """
  A loop's worker: a task under `Aqua.TaskSupervisor` whose death is
  answered to the loop that awaits it rather than taking the loop down,
  and which never outlives that loop. When the process that started it
  ends, for any reason, the worker is killed — and with it any clone loop
  it runs, whose own workers follow.
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
