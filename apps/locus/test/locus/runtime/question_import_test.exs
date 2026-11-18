# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.QuestionImportTest do
  @moduledoc """
  A catalyst's `cyfr:question/ask` import carries each call of `ask` to
  the host as `question_ask` under the run's next ask number, and loops
  itself: an ask past its root's allowance sleeps as long as CYFR says and
  is sent again with the same arguments under a fresh header; an open
  question is waited on in `question_wait` calls of the longest wait
  until it is decided; a lost opening answer is asked once more as the
  same body; and CYFR's `lost`, or an answer lost twice, ends the ask
  `none(unavailable)`, which is all the guest is told. The answers are
  `tests/fixtures/host_api.json`'s `question_cases`, as CYFR writes them.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Locus.Runtime.{Engine, HostClient}
  alias Locus.Runtime.Test.ScriptedHost

  @host_api Path.expand("../../../../../tests/fixtures/host_api.json", __DIR__)
            |> File.read!()
            |> Jason.decode!()

  @cases Map.new(@host_api["question_cases"]["cases"], &{&1["name"], &1})

  @request %{
    action: "delete_table",
    summary: "Drop the table users in the project acme",
    operation: "DROP TABLE users;"
  }

  setup do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host)
    {:ok, host: host, client: attempt.client}
  end

  defp answer(name), do: {:answer, @cases[name]["answer"]}

  defp args(name), do: Jason.decode!(@cases[name]["body"])["args"]

  test "every case's answer reads as the client answers it", %{host: host, client: client} do
    expected = %{
      "opened" => {:ok, :pending},
      "keyed_replay" => {:ok, :pending},
      "changed" => {:ok, {:answer, {:none, :invalid}}},
      "paced" => {:ok, {:retry_after_ms, 1000}},
      "paced_admitted" => {:ok, {:answer, :allowed}},
      "unattended" => {:ok, {:answer, {:none, :unattended}}},
      "invalid" => {:ok, {:answer, {:none, :invalid}}},
      "wait_timed_out" => {:ok, :pending},
      "allowed" => {:ok, {:answer, :allowed}},
      "denied" => {:ok, {:answer, :denied}},
      "unavailable" => {:ok, {:answer, {:none, :unavailable}}}
    }

    assert Enum.sort(Map.keys(expected)) == Enum.sort(Map.keys(@cases))

    for {name, read} <- expected do
      %{"callback" => callback} = @cases[name]
      ScriptedHost.script(host, callback, answer(name))
      args = args(name)

      got =
        case callback do
          "question_ask" ->
            HostClient.question_ask(
              client,
              args["ask_no"],
              args["action"],
              args["summary"],
              args["operation"]
            )

          "question_wait" ->
            HostClient.question_wait(client, args["ask_no"], args["max_wait_ms"])
        end

      assert got == read, name
      [sent] = ScriptedHost.requests(host, callback) |> Enum.take(-1)
      assert sent.args == args, name
    end
  end

  test "an answer of no shape the wire knows is lost", %{host: host, client: client} do
    for wire <- [
          ~s({"v":1,"ok":{"answer":"maybe"}}),
          ~s({"v":1,"ok":{"answer":{"none":"bored"}}}),
          ~s({"v":1,"ok":{"pending":true,"answer":"allowed"}}),
          ~s({"v":1,"ok":{"retry_after_ms":0}})
        ] do
      ScriptedHost.script(host, "question_ask", {:answer, wire})
      assert {:error, :lost} = HostClient.question_ask(client, 1, "a", "s", "o"), wire
    end
  end

  test "an ask whose question opened waits until it is decided", %{host: host, client: client} do
    ScriptedHost.script(host, "question_ask", answer("opened"))

    ScriptedHost.script(host, "question_wait", [
      answer("wait_timed_out"),
      answer("wait_timed_out"),
      answer("denied")
    ])

    assert Engine.question_ask(client, 1, @request) == :denied

    waits = ScriptedHost.requests(host, "question_wait")
    assert length(waits) == 3

    for wait <- waits,
        do:
          assert(
            wait.args == %{"ask_no" => 1, "max_wait_ms" => Prima.HostAPI.max_question_wait_ms()}
          )

    [ask] = ScriptedHost.requests(host, "question_ask")

    assert ask.args == %{
             "ask_no" => 1,
             "action" => @request.action,
             "summary" => @request.summary,
             "operation" => @request.operation
           }
  end

  test "a paced ask sleeps as long as CYFR says and is sent again, the same ask signed afresh",
       %{host: host, client: client} do
    paced = ~s({"v":1,"ok":{"retry_after_ms":150}})
    ScriptedHost.script(host, "question_ask", [{:answer, paced}, answer("paced_admitted")])

    started = System.monotonic_time(:millisecond)
    assert Engine.question_ask(client, 2, @request) == :allowed
    assert System.monotonic_time(:millisecond) - started >= 150

    [first, second] = ScriptedHost.requests(host, "question_ask")
    assert first.body == second.body
    assert first.args["ask_no"] == 2
    refute first.header == second.header
  end

  test "a lost opening answer is asked once more as the same body", %{host: host, client: client} do
    ScriptedHost.script(host, "question_ask", [:drop, answer("opened")])
    ScriptedHost.script(host, "question_wait", answer("allowed"))

    capture_log(fn -> assert Engine.question_ask(client, 1, @request) == :allowed end)

    [first, second] = ScriptedHost.requests(host, "question_ask")
    assert first.body == second.body
    refute first.header == second.header
  end

  test "an answer lost twice tells the guest none(unavailable), and asks no more",
       %{host: host, client: client} do
    ScriptedHost.script(host, "question_ask", answer("opened"))
    ScriptedHost.script(host, "question_wait", :drop)

    capture_log(fn ->
      assert Engine.question_ask(client, 1, @request) == {:none, :unavailable}
    end)

    assert length(ScriptedHost.requests(host, "question_wait")) == 2
  end

  test "CYFR's lost ends the ask none(unavailable)", %{host: host, client: client} do
    ScriptedHost.script(host, "question_ask", answer("opened"))
    ScriptedHost.script(host, "question_wait", {:error, :lost})

    assert Engine.question_ask(client, 1, @request) == {:none, :unavailable}
    assert length(ScriptedHost.requests(host, "question_wait")) == 1

    ScriptedHost.script(host, "question_ask", {:error, :lost})
    assert Engine.question_ask(client, 2, @request) == {:none, :unavailable}
  end
end
