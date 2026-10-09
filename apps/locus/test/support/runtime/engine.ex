# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Test.Engine do
  @moduledoc """
  The engine a runner's VM runs guest code with (`Locus.Runtime.engine/0`:
  the shared Wasmex engine, its cache and its task supervisor), started in
  the test VM for the suite, so a test of runner code (the runtime, the
  handlers, `Locus.Runtime.Runner` itself) runs it here against a scripted host. The
  worker service of this VM loads no component: its runners are OS
  processes of their own, and their engine is theirs.
  """

  @doc "Start the engine for the rest of the run, unless this VM already runs one."
  @spec start!() :: :ok
  def start! do
    if Process.whereis(Locus.Runtime.SharedEngine) == nil do
      {:ok, pid} =
        Supervisor.start_link(Locus.Runtime.engine(),
          strategy: :one_for_one,
          name: __MODULE__
        )

      # Held by no test process: the engine outlives every test.
      Process.unlink(pid)
    end

    :ok
  end
end
