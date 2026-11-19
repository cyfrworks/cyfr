# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ProgramToolTest do
  @moduledoc """
  Aqua's own program tool through the real loop, a model's start a call
  like any other of its mode: in auto it runs at once, and its answer is
  what the program printed, which joins no thread to the turn; in
  read-only every start is refused in the read-only sentence, which the
  thread is told once, while the tool's list runs; a start whose words
  are not readable text, too many or too long, or whose row changed
  since it was listed or is gone, is refused as it dispatches and opens
  nothing; a schedule's turn starts one as any turn of its mode; and the
  turn's end ends what it started.

  The model is scripted and the backends service is the scripted one;
  the loop, the gate and the session owner are real.
  """

  use PrismWeb.ConnCase, async: false

  alias Aqua.Tape
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Cyfr.Test.ScriptedWorker

  @model "catalyst:local.claude"
  @model_id "scripted-small"
  @root :crypto.strong_rand_bytes(32)

  setup %{conn: conn} do
    Arca.Cache.init()
    fake = Scripted.start(self(), @root)
    Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _message, _fields}, 2_000

    user = test_user()
    own = Sanctum.Test.People.athanor!(user.user_id)
    conn = log_in_user(conn, user, athanor_id: own.id)
    {:ok, _} = Sanctum.TestContext.mark_provisioned(own)
    ctx = ready_athanor!(own.id, user.user_id)
    Cyfr.Test.Sandbox.stop_work_on_exit()
    ScriptedWorker.fresh_limits!(ctx, [@model])

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))

    {:ok,
     conn: conn,
     ctx: ctx,
     fake: fake,
     thread: thread,
     gh: program!(ctx, "gh"),
     jq: program!(ctx, "jq")}
  end

  defp program!(ctx, name) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        config_json: Jason.encode!(%{"command" => name, "env" => %{}})
      })

    row
  end

  describe "in auto" do
    test "asked to run gh on a repository, Aqua starts it at once and answers from the output",
         %{ctx: ctx, thread: thread, gh: gh, fake: fake} do
      turn = accept!(ctx, thread, "@aqua how many stars has cyfr/cyfr? use gh")

      script!([
        calls([
          start("c1", gh, ["repo", "view", "cyfr/cyfr", "--json", "stargazerCount"], 10_000)
        ]),
        reply("cyfr/cyfr has 3 stars.")
      ])

      prints(fake, gh, ~s({"stargazerCount":3}), exit: 0)
      assert :completed = run(ctx, turn)

      assert {:ok, %{status: "completed", agent_mode: "auto", paused_at: nil}} =
               Tape.turn(ctx, turn.id)

      assert_received {:session, "open",
                       %{"argv" => ["repo", "view", "cyfr/cyfr", "--json", "stargazerCount"]},
                       _fields}

      # The program's output is the step's result, and what the model read
      # next; it carries no thread's posts, so the turn read no thread.
      assert %{outcome: "ok"} = step(ctx, turn, "c1")

      assert %{"output" => ~s({"stargazerCount":3}\n), "ended" => "exited", "program" => "gh"} =
               last_tool_result()

      assert read_threads(ctx, turn) == []

      # Its session ended with the turn, at the latest.
      assert {:ok, []} = Opus.Programs.running(ctx)
    end
  end

  describe "in read-only" do
    test "every start is refused in the read-only sentence while the list runs; the thread is told once, and nothing opens",
         %{ctx: ctx, thread: thread, gh: gh, jq: jq} do
      read_only!(ctx)
      turn = accept!(ctx, thread, "@aqua run gh, then jq")

      script!([
        calls([{"l1", "program", %{"action" => "list"}}]),
        calls([start("c1", gh, ["--version"])]),
        calls([start("c2", jq, ["--version"])]),
        reply("Neither ran.")
      ])

      assert :completed = run(ctx, turn)
      said = Aqua.Loop.Policy.read_only_sentence("Aqua")

      assert {:ok, %{status: "completed", agent_mode: "read-only", paused_at: nil}} =
               Tape.turn(ctx, turn.id)

      # The list is a read and runs; each start, the same call auto runs,
      # is refused before it dispatches, in the sentence.
      assert %{outcome: "ok"} = step(ctx, turn, "l1")

      for id <- ~w(c1 c2) do
        assert %{outcome: "denied", error: ^said, started_at: nil} =
                 step(ctx, turn, id)
      end

      refute_received {:session, "open", _message, _fields}
      assert {:ok, []} = Opus.Programs.running(ctx)

      # The thread is told once, though two starts were refused.
      assert [%{kind: "system", content: ^said, turn_id: turn_id}] =
               Enum.filter(
                 Arca.ThreadStorage.messages(Sanctum.Context.actor(ctx), thread.id),
                 &(&1.client_id == "read-only:" <> turn.id)
               )

      assert turn_id == turn.id
    end
  end

  describe "refused as it dispatches" do
    test "words that are not readable text, too many or too long, a row changed since it was listed, or one that is gone: nothing of them opens",
         %{ctx: ctx, thread: thread, gh: gh} do
      actor = Sanctum.Context.actor(ctx)

      # gh changes after the turn listed it at its first epoch; rg is gone.
      {:ok, changed} =
        Arca.McpServerStorage.update(actor, "gh", %{
          config_json: Jason.encode!(%{"command" => "gh", "env" => %{"NO_COLOR" => "1"}})
        })

      assert changed.epoch == gh.epoch + 1
      gone = program!(ctx, "rg")
      {:ok, _} = Arca.McpServerStorage.delete(actor, "rg")

      turn = accept!(ctx, thread, "@aqua run gh")
      long = String.duplicate("a", 257)
      many = Enum.map(1..33, &"w#{&1}")
      # Within the count and size, but not text a person reads whole.
      control = String.duplicate("a", 250) <> <<1>> <> "TAIL"

      script!([
        calls([start("c1", changed, [long])]),
        calls([start("c2", changed, many)]),
        calls([start("c4", changed, ["ok", control])]),
        calls([start("c5", changed, ["ok", <<0xC2, 0x85>>])]),
        calls([start("c3", gh, ["--version"])]),
        calls([start("c6", gone, ["--version"])]),
        # The one start that differs from c3 by its epoch alone runs.
        calls([start("c7", changed, ["--version"])]),
        reply("could not")
      ])

      assert :completed = run(ctx, turn)

      unreadable = "Error: The words to follow the command are not valid"

      assert Map.new(~w(c1 c2 c3 c4 c5 c6 c7), fn id ->
               {id, Map.take(step(ctx, turn, id), [:outcome, :error])}
             end) == %{
               "c1" => refused("Error: Field 'terminal_args[0]' must be at most 256"),
               "c2" => refused("Error: Field 'terminal_args' must be at most 32"),
               "c4" => refused(unreadable),
               "c5" => refused(unreadable),
               "c3" => refused("Error: The program changed since it was shown; ask again"),
               "c6" => refused("Error: Program or session not found: that"),
               "c7" => %{outcome: "ok", error: nil}
             }

      assert_received {:session, "open", %{"argv" => ["--version"]}, _fields}
      refute_received {:session, "open", _message, _fields}
      assert {:ok, []} = Opus.Programs.running(ctx)
    end
  end

  describe "a schedule's turn" do
    test "starts a program as any turn of its mode: in auto the start runs, and the turn's end ends it",
         %{ctx: ctx, thread: thread, gh: gh, fake: fake} do
      ctx = %{ctx | origin: :schedule}

      {:ok, %{turn: turn}} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "@aqua run gh"},
          turn: %{agent: "aqua", requested_by: ctx.user_id, model: @model_id, origin: :schedule}
        })

      script!([calls([start("c1", gh, ["--version"], 10_000)]), reply("gh is version 2.")])
      prints(fake, gh, "gh version 2", exit: 0)
      assert :completed = run(ctx, turn)

      assert {:ok, %{status: "completed", origin: "schedule", agent_mode: "auto", error: nil}} =
               Tape.turn(ctx, turn.id)

      assert %{outcome: "ok"} = step(ctx, turn, "c1")
      assert_received {:session, "open", %{"argv" => ["--version"]}, _fields}
      assert %{"output" => "gh version 2\n", "program" => "gh"} = last_tool_result()
      assert {:ok, []} = Opus.Programs.running(ctx)
    end
  end

  # ---------------------------------------------------------------------------

  defp start(id, row, words, wait_ms \\ 0),
    do:
      {id, "program",
       %{
         "action" => "start",
         "program" => row.id,
         "epoch" => row.epoch,
         "terminal_args" => words,
         "wait_ms" => wait_ms
       }}

  # The program prints `text` once its session opens, and exits with
  # `exit` when given, as the backends service would run it.
  defp prints(fake, row, text, opts) do
    Task.start(fn ->
      Prima.Test.Wait.wait_until(
        fn -> Enum.any?(Scripted.sessions(fake, row.id), fn {_id, s} -> s.running end) end,
        30_000
      )

      Scripted.write(fake, row.id, text)

      if exit = opts[:exit] do
        # sleep-ok: no event for the tool having read the printed text yet; 200 ms between the
        # write and the exit
        Process.sleep(200)
        Scripted.end_sessions(fake, row.id, exit)
      end
    end)
  end

  # A start refused as it dispatched, in the words the turn read.
  defp refused(error), do: %{outcome: "error", error: error}

  # The soul switched to read-only, as the Aqua page switches it.
  defp read_only!(ctx) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => Compendium.AquaPath.soul_name(),
        "mode" => "read-only"
      })
  end

  defp script!(items) do
    start_supervised!({ScriptedWorker, ref: @model, script: items, window: 40_000}, id: :script)
  end

  defp run(ctx, turn),
    do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end) |> Task.await(60_000)

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id, model: @model_id}
      })

    turn
  end

  defp read_threads(ctx, turn) do
    {:ok, %{read_threads: read}} = Tape.turn(ctx, turn.id)
    Arca.ThreadStorage.threads_of(read)
  end

  defp step(ctx, turn, call_id) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.find(steps, &String.ends_with?(&1.idempotency_key || "", ":" <> call_id))
  end

  # What the model was handed last as a tool's result, decoded.
  defp last_tool_result do
    %{"messages" => messages} =
      List.last(
        for %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
            do: params
      )

    [%{"content" => content} | _] =
      for %{"role" => "tool", "content" => results} <- Enum.reverse(messages),
          %{"type" => "tool_result"} = result <- results,
          do: result

    Jason.decode!(content)
  end

  defp calls(blocks),
    do: %{
      "content" =>
        Enum.map(blocks, fn {id, name, args} ->
          %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}
        end),
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 8}
    }

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
end
