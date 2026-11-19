# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.QuestionProbeTest do
  @moduledoc """
  The question probe (`test_wasm/question_probe`),
  run by the runtime in this VM against a scripted host: a catalyst asks
  through `cyfr:question/ask` and is handed what the host answered, one
  ask number for each call; a reagent and a formula are given no such
  import, so a component that imports it does not instantiate as either;
  and a component waiting on an ask whose process is killed, as the
  runner kills one at its budget, gives its store back: the import runs in
  the component's server process, the kill drops the call's reply channel,
  and the guest's call traps, so nothing of the run is left waiting.

  The last is measured on this VM's mapped memory, which a store's linear
  memory reserves, so the module runs alone.
  """

  use ExUnit.Case, async: false

  alias Locus.Runtime.Test.ScriptedHost

  @probe File.read!(
           Path.expand(
             "../../support/runtime/test_wasm/question_probe/question_probe.wasm",
             __DIR__
           )
         )

  @pending ~s({"v":1,"ok":{"pending":true}})

  defp run(attempt, statements, type \\ :catalyst) do
    Locus.Runtime.Engine.execute_component(
      @probe,
      %{"operation" => "run", "params" => %{"statements" => statements}},
      component_type: type,
      component_ref: "#{type}:local.question-probe:0.1.0",
      host: attempt.client,
      authority: Prima.Authority.zero(),
      limits: Prima.Authority.limits(Prima.Authority.zero())
    )
  end

  defp catalyst do
    host = ScriptedHost.start!()
    {host, ScriptedHost.attempt!(host, component_type: :catalyst)}
  end

  test "each ask is handed to the guest as the host answered it, under its own number" do
    {host, attempt} = catalyst()

    ScriptedHost.script(host, "question_ask", fn args, _caller ->
      case args["ask_no"] do
        1 -> {:answer, ~s({"v":1,"ok":{"answer":"allowed"}})}
        2 -> {:answer, ~s({"v":1,"ok":{"answer":"denied"}})}
        3 -> {:answer, @pending}
        4 -> {:answer, ~s({"v":1,"ok":{"answer":{"none":"invalid"}}})}
      end
    end)

    ScriptedHost.script(
      host,
      "question_wait",
      {:answer, ~s({"v":1,"ok":{"answer":{"none":"unattended"}}})}
    )

    statements = [
      "DROP TABLE users",
      # Two statements joined, a prefix of a word, a clause the probe does
      # not read, another case: each declined, and nobody asked.
      "DELETE FROM users WHERE id = 1; DROP TABLE users",
      "DELETE_PREFIX FROM users WHERE id = 1",
      "DROP TABLE users;",
      "DELETE FROM users WHERE id = 1 OR 1 = 1",
      "drop table users",
      "DELETE FROM logs WHERE id = 7",
      "DROP TABLE orders",
      "DROP TABLE audit"
    ]

    assert {:ok, %{"status" => 200, "data" => %{"results" => results}}} =
             run(attempt, statements)

    assert Enum.map(results, & &1["answer"]) ==
             ~w(allowed declined declined declined declined declined denied unattended invalid)

    asks = ScriptedHost.requests(host, "question_ask")

    assert Enum.map(asks, & &1.args) == [
             %{
               "ask_no" => 1,
               "action" => "delete_table",
               "summary" => "drop the table users",
               "operation" => "DROP TABLE users"
             },
             %{
               "ask_no" => 2,
               "action" => "delete_rows",
               "summary" => "delete the row 7 from the table logs",
               "operation" => "DELETE FROM logs WHERE id = 7"
             },
             %{
               "ask_no" => 3,
               "action" => "delete_table",
               "summary" => "drop the table orders",
               "operation" => "DROP TABLE orders"
             },
             %{
               "ask_no" => 4,
               "action" => "delete_table",
               "summary" => "drop the table audit",
               "operation" => "DROP TABLE audit"
             }
           ]

    assert [%{args: %{"ask_no" => 3}}] = ScriptedHost.requests(host, "question_wait")
  end

  test "a reagent and a formula are given no question import, so the probe does not instantiate as either" do
    for type <- [:reagent, :formula] do
      host = ScriptedHost.start!()
      attempt = ScriptedHost.attempt!(host, component_type: type)
      assert {:error, sentence} = run(attempt, ["DROP TABLE users"], type)
      assert sentence =~ "instantiation failed", inspect(type)
      assert ScriptedHost.requests(host, "question_ask") == []
    end
  end

  # The store is measured by this VM's mapped memory, read from procfs: a
  # host without it cannot run the test, which is skipped there alone.
  @procfs_absent not File.exists?("/proc/self/status")

  @tag skip: @procfs_absent && "no procfs on this host: the VM's mapped memory cannot be read"
  test "a component waiting on an ask gives its store back when its process is killed" do
    {host, attempt} = catalyst()
    test = self()
    ScriptedHost.script(host, "question_ask", {:answer, @pending})

    # Each wait answers at once that the question still waits, so the probe
    # waits for as long as it lives.
    ScriptedHost.script(host, "question_wait", fn _args, _caller ->
      send(test, :waiting)
      Process.sleep(50)
      {:answer, @pending}
    end)

    baseline = mapped_kb()

    component =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        run(attempt, ["DROP TABLE users"])
      end)

    assert_receive :waiting, 10_000
    waiting = mapped_kb()
    # The store reserves its linear memory and guard regions in this VM.
    assert waiting - baseline > 100_000, "#{baseline} kB before, #{waiting} kB waiting"

    Process.exit(component, :kill)

    assert released?(baseline, waiting),
           "the store was not given back: #{baseline} kB before, #{waiting} kB waiting, " <>
             "#{mapped_kb()} kB after the kill"

    # Nothing asks again once the component is gone.
    flush_waiting()
    waits = length(ScriptedHost.requests(host, "question_wait"))
    Process.sleep(300)
    assert length(ScriptedHost.requests(host, "question_wait")) == waits
  end

  defp released?(baseline, waiting, tries \\ 100) do
    now = mapped_kb()

    cond do
      now - baseline < (waiting - baseline) / 2 ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        released?(baseline, waiting, tries - 1)
    end
  end

  defp flush_waiting do
    receive do
      :waiting -> flush_waiting()
    after
      100 -> :ok
    end
  end

  # This VM's mapped memory, in kB.
  defp mapped_kb do
    [_, kb] = Regex.run(~r/VmSize:\s+(\d+) kB/, File.read!("/proc/self/status"))
    String.to_integer(kb)
  end
end
