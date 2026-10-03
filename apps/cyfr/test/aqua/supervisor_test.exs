# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.SupervisorTest do
  @moduledoc """
  The recovery of the threads holding an open turn is a one-shot task the
  runner group keeps listed once it has run, so a restart of the group
  runs it again over the fresh, empty runner supervisor.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  test "the recovery is transient, and listed without a process once it has run" do
    {:ok, {_flags, children}} = Aqua.Supervisor.init(thread_recovery: true)

    %{start: {Supervisor, :start_link, [group, _opts]}} =
      Enum.find(children, &(&1.id == Aqua.RunnerTree))

    recovery =
      group
      |> Enum.map(&Supervisor.child_spec(&1, []))
      |> Enum.find(&(&1.id == Aqua.RunnerRecovery))

    assert %{restart: :transient} = recovery

    # Under a supervisor of the test's own: the suite's runner group holds
    # the registry's and the runner supervisor's names.
    {:ok, supervisor} = Supervisor.start_link([recovery], strategy: :one_for_one)

    wait_until(
      fn ->
        Supervisor.which_children(supervisor) == [
          {Aqua.RunnerRecovery, :undefined, :worker, [Task]}
        ]
      end,
      5_000,
      "the recovery ran and stayed listed"
    )

    Supervisor.stop(supervisor)
  end
end
