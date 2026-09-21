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
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()

    {:ok, %{execution: execution}} =
      Arca.Execution.admit(%{
        id: "exec_evt_#{System.unique_integer([:positive])}",
        reference: "catalyst:local.files:0.1.0",
        user_id: actor.user_id,
        athanor_id: actor.athanor_id,
        component_type: "catalyst"
      })

    {:ok, actor: actor, exec: execution}
  end

  test "events take the next number from the row, in order, under concurrent writers", %{
    actor: actor,
    exec: exec
  } do
    1..12
    |> Task.async_stream(
      fn i ->
        {:ok, _} =
          ExecutionEvents.append(actor, exec.id, "step.closed", data: %{"i" => i})
      end,
      max_concurrency: 6,
      ordered: false
    )
    |> Stream.run()

    # Admission appended `execution.started` as 1; the twelve follow it.
    assert {:ok, [%{seq: 1, type: "execution.started"} | rows]} =
             ExecutionEvents.since(actor, exec.id, 0)

    assert Enum.map(rows, & &1.seq) == Enum.to_list(2..13)
    assert Arca.Repo.get!(Arca.Execution, exec.id).event_seq == 13

    assert {:ok, tail} = ExecutionEvents.since(actor, exec.id, 11)
    assert Enum.map(tail, & &1.seq) == [12, 13]
    assert Enum.all?(rows, &is_integer(ExecutionEvents.data(&1)["i"]))
  end

  test "an execution of another estate takes no event", %{actor: actor, exec: exec} do
    assert {:error, _} =
             ExecutionEvents.append(
               Cyfr.Actor.in_athanor("ath_elsewhere"),
               exec.id,
               "step.closed"
             )

    assert {:ok, []} = ExecutionEvents.since(actor, exec.id, 1)
  end
end
