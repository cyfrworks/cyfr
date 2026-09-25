# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.TaskSupervisor do
  @moduledoc """
  The supervisor of the handlers the gate runs itself: every call made
  with `runner: :supervised` runs its handler as a task here, unlinked
  from the process that called the gate, so a crash, an exit, a timeout
  or a cancellation of the handler comes back to its caller as a refusal
  instead of killing it.

  A surface's own transport work — an MCP request's wrapper, a webhook's
  dispatch, a proxied server's call — runs under that surface's
  supervisor, never here. It starts after `Grimoire.RunningTasks`, whose
  tables a handler registers in, so a shutdown stops the handlers before
  the tables they are registered in go.
  """

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: Task.Supervisor.child_spec(Keyword.put(opts, :name, __MODULE__))
end
