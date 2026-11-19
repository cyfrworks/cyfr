# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.CatalogThreadsTest do
  @moduledoc """
  The catalogued reads whose answers may carry a thread's posts declare
  `threads:` (`Prima.Operation`), and each declaration's function answers
  the ids of the threads its answer carries, so that deleting a thread
  finds every run and turn that read it. Every other operation carries
  none.
  """

  # An admitted run's started event is buffered by a process the test
  # does not own, which reads the shared sandbox.
  use ExUnit.Case, async: false

  alias Opus.Record

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    ctx = Sanctum.TestContext.local(:prism)
    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx)}
  end

  test "exactly five catalogued reads declare the threads their answers carry" do
    declared =
      for {_tool, {_provider, %{operations: operations}}} <- Sanctum.Catalog.operations(),
          %Prima.Operation{threads: {_module, _function} = threads} = op <- operations,
          do: {"#{op.tool}.#{op.action}", threads}

    assert Enum.sort(declared) == [
             {"execution.list", {Opus.Provider, :read_threads}},
             {"execution.logs", {Opus.Provider, :read_threads}},
             {"file.read", {Arca.Providers.Files, :read_threads}},
             {"thread.events", {Aqua.Providers.Thread, :read_threads}},
             {"thread.search", {Aqua.Providers.Thread, :read_threads}}
           ]
  end

  test "a thread read answers the threads it joined, and none when it names none",
       %{actor: actor} do
    for name <- ["thread.events", "thread.search"] do
      op = operation(name)

      assert Prima.Operation.read_threads(
               op,
               actor,
               {:ok, %{results: [], count: 0, read_threads: ["thr_b", "thr_a"]}}
             ) == ["thr_a", "thr_b"],
             name

      assert Prima.Operation.read_threads(op, actor, {:ok, %{results: [], count: 0}}) == [],
             name
    end
  end

  test "a file read answers the threads its guest object holds, and none for any other file",
       %{actor: actor} do
    op = operation("file.read")
    guest = %{path: "data/q3.csv", size: 4, content: "a,b\n", encoding: "utf8"}

    assert Prima.Operation.read_threads(
             op,
             actor,
             {:ok, Map.put(guest, :read_threads, ["thr_b", "thr_a"])}
           ) == ["thr_a", "thr_b"]

    assert Prima.Operation.read_threads(op, actor, {:ok, Map.put(guest, :read_threads, [])}) ==
             []

    assert Prima.Operation.read_threads(
             op,
             actor,
             {:ok, %{path: "aqua/aqua.md", size: 4, content: "soul", encoding: "utf8"}}
           ) == []
  end

  test "an execution read answers the threads of every run it answers, and none for a run " <>
         "that read none",
       %{ctx: ctx, actor: actor} do
    first = started!(ctx, ["thr_b", "thr_a"])
    second = started!(ctx, ["thr_c", "thr_a"])
    bare = started!(ctx, [])

    logs = operation("execution.logs")
    list = operation("execution.list")

    assert Prima.Operation.read_threads(logs, actor, logs(ctx, first)) == ["thr_a", "thr_b"]
    assert Prima.Operation.read_threads(logs, actor, logs(ctx, second)) == ["thr_a", "thr_c"]
    assert Prima.Operation.read_threads(logs, actor, logs(ctx, bare)) == []

    assert {:ok, %{executions: listed}} = listing = list(ctx)

    assert Enum.sort(Enum.map(listed, & &1.execution_id)) == Enum.sort([first, second, bare])
    assert Prima.Operation.read_threads(list, actor, listing) == ["thr_a", "thr_b", "thr_c"]

    assert Prima.Operation.read_threads(list, actor, {:ok, %{executions: [], count: 0}}) == []
  end

  # A root a turn's launch stamped with `threads`, admitted as it is.
  defp started!(ctx, threads) do
    id = Record.generate_id()

    record =
      Record.new(ctx, "formula:local.read-threads:0.1.0", %{},
        component_type: :formula,
        execution_id: id,
        launch: %{read_threads: threads, execution_id: id, agent: "aqua"}
      )

    :ok = Record.write_started(ctx, record)
    id
  end

  defp logs(ctx, id),
    do: Opus.Provider.handle("execution", ctx, %{"action" => "logs", "execution_id" => id})

  defp list(ctx), do: Opus.Provider.handle("execution", ctx, %{"action" => "list"})

  defp operation(name) do
    [tool, action] = String.split(name, ".", parts: 2)
    {:ok, {_module, %{operations: operations}}} = Sanctum.Catalog.lookup(tool)
    Enum.find(operations, &(&1.action == action)) || flunk(name)
  end
end
