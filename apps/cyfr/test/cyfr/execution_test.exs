# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ExecutionTest do
  @moduledoc """
  CYFR runs a component only on a worker service: with none configured, or
  one that does not answer, execution is unavailable and a run is refused
  before it is admitted; a configured worker service that answers makes it
  available.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Test.{AuthorityFixtures, ScriptedWorker}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    previous = Application.get_env(:cyfr, :workers)
    on_exit(fn -> Application.put_env(:cyfr, :workers, previous) end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp run(ctx) do
    Cyfr.Execution.run_child(AuthorityFixtures.root!(), "reagent:local.off-graph:1.0.0", nil, %{},
      ctx: ctx
    )
  end

  test "with no worker service configured, execution is unavailable and a run is refused", %{
    ctx: ctx
  } do
    Application.put_env(:cyfr, :workers, [])

    refute Cyfr.Execution.available?()
    assert {:error, :execution_unavailable} = run(ctx)
    assert Arca.Repo.all(Arca.Execution) == []
    assert Cyfr.Execution.events_since("exec_1", {0, 0}, ctx.athanor_id) == []
  end

  test "a configured worker service that does not answer leaves execution unavailable", %{
    ctx: ctx
  } do
    Application.put_env(:cyfr, :workers, [ScriptedWorker])

    refute Cyfr.Execution.available?()
    assert {:error, :execution_unavailable} = run(ctx)
  end

  test "a configured worker service that answers makes execution available" do
    Application.put_env(:cyfr, :workers, [ScriptedWorker])
    start_supervised!({ScriptedWorker, ref: "reagent:local.ta", script: []})

    assert Cyfr.Execution.available?()
  end

  @tag :requires_opus
  test "the opus worker service is the one configured, and it answers" do
    assert Application.get_env(:cyfr, :workers) == [Opus.WorkerService]
    assert Cyfr.Execution.available?()
  end
end
