# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionEventsTest do
  @moduledoc """
  Durable events are numbered from the execution's own counter inside
  the writer's transaction, so the sequence is strictly increasing across
  concurrent writers and commit order is seq order.
  """

  use ExUnit.Case, async: false

  alias Arca.ExecutionEvents

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Sanctum.TestContext.athanor!()
    ctx = Sanctum.TestContext.local()

    {:ok, %{execution: execution}} =
      Arca.Execution.admit(%{
        id: "exec_evt_#{System.unique_integer([:positive])}",
        reference: "catalyst:local.files:0.1.0",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        component_type: "catalyst"
      })

    {:ok, ctx: ctx, exec: execution}
  end

  test "events take the next number from the row, in order, under concurrent writers", %{
    ctx: ctx,
    exec: exec
  } do
    1..12
    |> Task.async_stream(
      fn i ->
        {:ok, _} =
          ExecutionEvents.append(ctx.athanor_id, exec.id, "step.closed", data: %{"i" => i})
      end,
      max_concurrency: 6,
      ordered: false
    )
    |> Stream.run()

    assert {:ok, rows} = ExecutionEvents.since(ctx.athanor_id, exec.id, 0)
    assert Enum.map(rows, & &1.seq) == Enum.to_list(1..12)
    assert Arca.Repo.get!(Arca.Execution, exec.id).event_seq == 12

    assert {:ok, tail} = ExecutionEvents.since(ctx.athanor_id, exec.id, 10)
    assert Enum.map(tail, & &1.seq) == [11, 12]
    assert Enum.all?(rows, &is_integer(ExecutionEvents.data(&1)["i"]))
  end

  test "an execution of another estate takes no event", %{ctx: ctx, exec: exec} do
    assert {:error, _} = ExecutionEvents.append("ath_elsewhere", exec.id, "step.closed")
    assert {:ok, []} = ExecutionEvents.since(ctx.athanor_id, exec.id, 0)
  end
end
