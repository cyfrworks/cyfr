# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.FlushTest do
  @moduledoc """
  The note flush before a compaction: one silent request offering
  `notes.keep` alone, made only where a kept note would run (the member
  is offered `notes.keep` and is in `auto`), whose unknown outcomes are
  recorded without a replay and without restricting the turn.

  The scripted model lists a small window, so a large message fills it: the
  first round fits nothing older to summarize, and the second compacts.
  """

  use ExUnit.Case, async: false

  alias Aqua.Runner.RecoveryTable
  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.{Bootstrap}

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @model_id "scripted-small"
  @window 40_000
  @full 21_000

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "flush_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path, cyfr: :locus_runtime_workers]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, test_path)
    Cyfr.Test.SeedBundle.lay!(~w(claude files http))

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    # The loops' work stops before the paths it runs under are restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    ctx = Sanctum.TestContext.local(:prism)
    {:ok, ctx: ctx, thread: ready!(ctx)}
  end

  # The athanor `ctx` works in, made one the soul's turns run in: the
  # shipped tree indexed, the soul's consent minted and the model's key
  # bound. Answers a thread there.
  defp ready!(ctx) do
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    # The model catalyst unseals its key when its runner attaches.
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    thread
  end

  test "in auto and offered notes.keep, the model keeps a note before the summary, and says nothing",
       %{ctx: ctx, thread: thread} do
    turn = accept_large!(ctx, thread)

    :ok = Aqua.Runner.subscribe(thread.id, ctx.athanor_id)

    script!([
      round_one(),
      %{"entries" => []},
      {:emit, [%{"type" => "text.delta", "text" => "Keeping a note."}]},
      flush_reply([keep("n1", "plan", "the plan is to ship")], "Keeping a note."),
      {:emit, [%{"type" => "text.delta", "text" => "the story so far"}]},
      reply("the story so far"),
      {:emit, [%{"type" => "text.delta", "text" => "done"}]},
      reply("done")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)

    # Only the chat step's text streams; the flush and the summary say nothing.
    assert_receive %ThreadEvent{kind: :delta, data: %{text: "done"}}, 5_000
    refute_received %ThreadEvent{kind: :delta, data: %{text: "Keeping a note."}}
    refute_received %ThreadEvent{kind: :delta, data: %{text: "the story so far"}}

    {:ok, steps} = Tape.steps(ctx, turn)

    assert ["chat", "flush", "compaction", "chat"] =
             for(%{kind: "model", purpose: purpose} <- steps, do: purpose)

    assert %{purpose: "flush", outcome: "ok"} = Enum.find(steps, &(&1.action == "keep"))
    assert {:ok, _} = Aqua.Notes.read(ctx, "plan")

    rows = Threads.messages(Sanctum.Context.actor(ctx), thread.id)
    assert Enum.any?(rows, &(&1.kind == "compaction"))
    refute Enum.any?(rows, &(&1.content == "Keeping a note."))

    flush = Enum.at(chat_requests(), 1)
    assert [%{"name" => "notes"} = tool] = flush["tools"]
    assert get_in(tool, ["parameters", "properties", "action", "enum"]) == ["keep"]
    assert flush["provider_tools"] == []
    last = flush["messages"] |> List.last() |> Map.fetch!("content") |> List.last()
    assert last["text"] =~ "notes.keep"
  end

  test "a flush in the round that reads the room neither sends nor keeps the room's lines", %{
    ctx: ctx
  } do
    # The sender is a person, in their own athanor and in a shared thread
    # beside their own thread.
    {ctx, user} = Sanctum.TestContext.person!(ctx)
    ctx = %{ctx | athanor_id: Sanctum.Test.People.athanor!(user).id}
    thread = ready!(ctx)

    {:ok, beside} = Sanctum.SharedThreads.create(ctx.user_id, "Beside")
    {:ok, _} = Sanctum.SharedThreads.post(ctx.user_id, beside.id, "ROOM-ONLY-LINE")

    {:ok, _} =
      Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
        author: ctx.user_id,
        sent_by: "person",
        content: String.duplicate("lorem ipsum ", 7_000)
      })

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua what did they say?"},
        turn: %{
          agent: "aqua",
          requested_by: ctx.user_id,
          model: @model_id,
          options: %{"room" => %{"shared_thread_id" => beside.id, "title" => "Beside"}}
        }
      })

    script!([
      flush_reply([keep("n1", "plan", "a note")]),
      reply("the story so far"),
      reply("They said hello.")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert ["flush", "compaction", "chat"] =
             for(%{kind: "model", purpose: purpose} <- steps, do: purpose)

    [flush, _summary, chat] =
      for %{input: %{"operation" => "chat"}} = call <- ScriptedWorker.calls(), do: call

    refute Jason.encode!(flush.input) =~ "ROOM-ONLY-LINE"
    assert Jason.encode!(chat.input) =~ "ROOM-ONLY-LINE"

    assert {:ok, _record, kept} =
             Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), flush.execution_id, "input")

    refute kept =~ "ROOM-ONLY-LINE"
  end

  # Each differs from an auto member offered notes.keep, whose flush runs
  # above, in one thing alone: its mode, or a job narrowed to the round's
  # own read.
  for {shape, mode, tools} <- [
        {"a read-only member", "read-only", nil},
        {"a job narrowed away from notes.keep", "auto", ["files.list"]}
      ] do
    test "#{shape} makes no flush request and keeps no note, and the summary still lands", %{
      ctx: ctx,
      thread: thread
    } do
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => Cyfr.Test.SeedBundle.seat_member(),
          "mode" => unquote(mode)
        })

      turn = accept_large!(ctx, thread, unquote(tools))
      script!([round_one(), %{"entries" => []}, reply("the story so far"), reply("done")])

      assert :completed = Task.await(run(ctx, turn), 60_000)
      {:ok, steps} = Tape.steps(ctx, turn)

      assert ["chat", "compaction", "chat"] =
               for(%{kind: "model", purpose: purpose} <- steps, do: purpose)

      refute Enum.any?(steps, &(&1.purpose == "flush"))
      assert [_first, _summary, _last] = chat_requests()

      assert Enum.any?(
               Threads.messages(Sanctum.Context.actor(ctx), thread.id),
               &(&1.kind == "compaction")
             )
    end
  end

  test "a flush runs notes.keep alone, and never past its size", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept_large!(ctx, thread)
    oversized = String.duplicate("x", 64 * 1024 + 1)

    script!([
      round_one(),
      %{"entries" => []},
      flush_reply([
        keep("n1", "big", oversized),
        {"n2", "files", %{"action" => "list", "path" => "data"}},
        keep("n3", "small", "kept")
      ]),
      reply("the story so far"),
      reply("done")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)
    flush_calls = Enum.filter(steps, &(&1.purpose == "flush" and &1.kind != "model"))

    assert ["denied", "denied", "ok"] = Enum.map(flush_calls, & &1.outcome)
    assert {:ok, _} = Aqua.Notes.read(ctx, "small")
    assert {:error, _} = Aqua.Notes.read(ctx, "big")
  end

  test "a flush never keeps onto a pinned page", %{ctx: ctx, thread: thread} do
    turn = accept_large!(ctx, thread)

    script!([
      round_one(),
      %{"entries" => []},
      flush_reply([keep("n1", "about-you", "they like trains")]),
      reply("the story so far"),
      reply("done")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)
    flush_calls = Enum.filter(steps, &(&1.purpose == "flush" and &1.kind != "model"))

    assert ["error"] = Enum.map(flush_calls, & &1.outcome)
    assert :none = Aqua.Notes.pinned(ctx)
    assert {:error, _} = Aqua.Notes.read(ctx, "about-you")
  end

  test "a summary that fails after a flush keeps the note and the turn goes on", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept_large!(ctx, thread)

    script!([
      round_one(),
      %{"entries" => []},
      flush_reply([keep("n1", "plan", "the plan")]),
      {:refuse, %{"type" => "invalid_request", "message" => "too long"}},
      reply("done")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{dispatch_state: "closed", outcome: "error"} =
             Enum.find(steps, &(&1.purpose == "compaction"))

    assert {:ok, _} = Aqua.Notes.read(ctx, "plan")

    refute Enum.any?(
             Threads.messages(Sanctum.Context.actor(ctx), thread.id),
             &(&1.kind == "compaction")
           )
  end

  describe "a flush interrupted before its outcomes were recorded" do
    test "its written note closes unknown, its unstarted call is skipped, and nothing restricts the turn",
         %{ctx: ctx, thread: thread} do
      turn = interrupted!(ctx, thread)

      a = model_step!(ctx, turn, "flush")

      {:ok, %{calls: [%{step: n1}, %{step: n2}]}} =
        Tape.record_response(ctx, turn, a, %{
          text: nil,
          tool_calls: [call_attrs(turn, a, "n1", "plan"), call_attrs(turn, a, "n2", "later")]
        })

      {:ok, _} = Tape.mark_dispatched(ctx, turn, n1)
      # The note landed; the process died before its outcome was written.
      {:ok, _} = Aqua.Notes.keep(ctx, "plan", "the plan")
      b = model_step!(ctx, turn, "flush")

      script!([reply("done")])
      assert :completed = adopt(ctx, turn)

      {:ok, steps} = Tape.steps(ctx, turn)
      assert %{dispatch_state: "closed", outcome: "uncertain"} = step(steps, n1.id)
      assert %{dispatch_state: "closed", outcome: "skipped"} = step(steps, n2.id)
      assert %{dispatch_state: "closed", outcome: "error"} = step(steps, b.id)
      refute Tape.restricted?(ctx, turn)
      assert {:error, _} = Aqua.Notes.read(ctx, "later")
    end

    test "an ordinary call whose outcome is unknown beside it still stops and restricts the turn",
         %{ctx: ctx, thread: thread} do
      turn = interrupted!(ctx, thread)

      flush = model_step!(ctx, turn, "flush")

      {:ok, %{calls: [%{step: note}]}} =
        Tape.record_response(ctx, turn, flush, %{
          text: nil,
          tool_calls: [call_attrs(turn, flush, "n1", "plan")]
        })

      {:ok, _} = Tape.mark_dispatched(ctx, turn, note)

      chat = model_step!(ctx, turn, "chat")

      {:ok, %{calls: [%{step: write}]}} =
        Tape.record_response(ctx, turn, chat, %{
          text: nil,
          tool_calls: [call_attrs(turn, chat, "w1", "draft")]
        })

      {:ok, _} = Tape.mark_dispatched(ctx, turn, write)

      assert {:paused, :uncertain} = adopt(ctx, turn)

      {:ok, steps} = Tape.steps(ctx, turn)
      assert %{dispatch_state: "closed", outcome: "uncertain"} = step(steps, note.id)
      assert %{dispatch_state: "uncertain"} = step(steps, write.id)
      assert Tape.restricted?(ctx, turn)
    end
  end

  # Astra's probe (#4163): the post a compaction summarises names the file
  # the person deleted, as the round's own request does.
  test "a compaction request tells its model that the carried post lost its file", %{
    ctx: ctx,
    thread: thread
  } do
    id = Prima.UUID7.generate_id("msg")

    {:ok, refs} =
      Aqua.Attachments.store(ctx, thread.id, id, [
        %{"filename" => "gone.png", "media_type" => "image/png", "bytes" => "PNG"}
      ])

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{
          id: id,
          author: ctx.user_id,
          sent_by: "person",
          content: "@aqua summarize the picture\n" <> String.duplicate("lorem ipsum ", 7_000),
          payload: %{"attachments" => refs}
        },
        turn: %{agent: "aqua", requested_by: ctx.user_id, model: @model_id}
      })

    {:ok, _} = Arca.Files.delete(Sanctum.Context.actor(ctx), "threads/#{thread.id}/#{id}")

    script!([
      round_one(),
      %{"entries" => []},
      flush_reply([]),
      reply("the story so far"),
      reply("done")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert ["chat", "flush", "compaction", "chat"] =
             for(%{kind: "model", purpose: purpose} <- steps, do: purpose)

    [first, _flush, summary, _last] = chat_requests()
    first_text = Jason.encode!(first["messages"])
    summary_text = Jason.encode!(summary["messages"])
    assert first_text =~ "they can no longer be read: gone.png"
    assert summary_text =~ "summarize the picture"
    assert summary_text =~ "they can no longer be read: gone.png"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp script!(items) do
    start_supervised!(
      {ScriptedWorker, ref: [@model, "catalyst:local.files"], script: items, window: @window}
    )
  end

  defp run(ctx, turn), do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

  # A message past the window's fill: the first round has nothing older to
  # summarize; once a round follows it, the message is older than the
  # boundary. `tools` narrows the turn's job to them.
  defp accept_large!(ctx, thread, tools \\ nil) do
    accept!(ctx, thread, "@aqua read this\n" <> String.duplicate("lorem ipsum ", 7_000), tools)
  end

  defp accept!(ctx, thread, text, tools \\ nil) do
    turn = %{agent: "aqua", requested_by: ctx.user_id, model: @model_id}

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: if(tools, do: Map.put(turn, :options, %{"tools" => tools}), else: turn)
      })

    turn
  end

  defp round_one,
    do: response([{"c1", "files", %{"action" => "list", "path" => "data"}}], nil, @full)

  defp flush_reply(blocks, text \\ nil), do: response(blocks, text, @full)

  defp keep(id, name, content),
    do: {id, "notes", %{"action" => "keep", "name" => name, "content" => content}}

  defp response(blocks, text, input_tokens) do
    content =
      if(text, do: [%{"type" => "text", "text" => text}], else: []) ++
        Enum.map(blocks, fn {id, name, args} ->
          %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}
        end)

    %{
      "content" => content,
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => input_tokens, "output_tokens" => 8}
    }
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

  defp chat_requests do
    for %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
        do: params
  end

  # A turn whose loop died while it waited on its first model request,
  # left running with no holder, so rows can be laid on it as a loop
  # writes them before `adopt/2` continues it.
  defp interrupted!(ctx, thread) do
    turn = accept!(ctx, thread, "@aqua keep it")
    start_supervised!({ScriptedWorker, ref: [@model], script: [{:probe, self()}]}, id: :died)
    loop = spawn(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
    assert_receive {:scripted_probe, _player, _}, 60_000

    ref = Process.monitor(loop)
    Process.exit(loop, :kill)
    assert_receive {:DOWN, ^ref, :process, ^loop, :killed}, 5_000
    stop_supervised!(:died)

    assert {:ok, %{status: "running"} = running} = Tape.turn(ctx, turn.id)
    running
  end

  # The turn taken over and continued as a runner's recovery does.
  defp adopt(ctx, turn) do
    assert {:ok, [{:adopt, _taken}]} = RecoveryTable.plan_turn(ctx, turn.thread_id, turn.id)

    Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :adopt) end)
    |> Task.await(60_000)
  end

  # A model request the interrupted turn's loop recorded and dispatched.
  defp model_step!(ctx, turn, purpose) do
    {:ok, step} =
      Tape.record_model_intent(ctx, turn, %{
        idempotency_key: "model:#{turn.id}:#{System.unique_integer([:positive])}",
        tool: @model,
        action: "chat",
        purpose: purpose
      })

    {:ok, step} = Tape.mark_dispatched(ctx, turn, step)
    step
  end

  defp call_attrs(turn, model_step, id, name) do
    args = %{"action" => "keep", "name" => name, "content" => "the #{name}"}

    %{
      tool_call_id: id,
      name: "notes",
      tool: "notes",
      action: "keep",
      arguments: args,
      kind: "write",
      idempotency_key: "call:#{turn.id}:#{model_step.id}:#{id}",
      step_kind: "tool"
    }
  end

  defp step(steps, id), do: Enum.find(steps, &(&1.id == id))
end
