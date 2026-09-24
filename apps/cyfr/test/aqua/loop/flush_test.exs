# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.FlushTest do
  @moduledoc """
  The note flush before a compaction: one silent request offering
  `notes.keep` alone, made only under a standing `auto` for it, whose
  calls run without a card and whose unknown outcomes are recorded without
  a replay and without restricting the turn.

  The scripted model lists a small window, so a large message fills it: the
  first round fits nothing older to summarize, and the second compacts.
  """

  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.{Bootstrap}

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @model_id "scripted-small"
  @window 40_000
  @full 21_000

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "flush_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path, arca: :seed_path, cyfr: :opus_workers]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, test_path)
    Application.put_env(:arca, :seed_path, @seed_root)

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

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    # The model catalyst unseals its key when its runner attaches.
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread}
  end

  describe "the gate before the grant store is asked" do
    test "room for the flush, the summary and the next request under the cap" do
      assert Aqua.Loop.flush_room?(0, false)
      assert Aqua.Loop.flush_room?(27, false)
      refute Aqua.Loop.flush_room?(28, false)
      refute Aqua.Loop.flush_room?(29, false)
    end

    test "a turn an unknown outcome restricts flushes nothing" do
      refute Aqua.Loop.flush_room?(0, true)
    end
  end

  test "under a standing auto, the model keeps a note before the summary, and says nothing", %{
    ctx: ctx,
    thread: thread
  } do
    allow_keep!(ctx, thread)
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
    ctx: ctx,
    thread: thread
  } do
    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: ctx.athanor_id)

    {:ok, room} = Threads.create(Sanctum.Context.actor(ctx))

    {:ok, _} =
      Threads.append(Sanctum.Context.actor(ctx), room.id, %{
        author: ctx.user_id,
        content: "ROOM-ONLY-LINE"
      })

    {:ok, _} =
      Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
        author: ctx.user_id,
        content: String.duplicate("lorem ipsum ", 7_000)
      })

    allow_keep!(ctx, thread)

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua what did they say?"},
        turn: %{
          agent: "aqua",
          requested_by: ctx.user_id,
          model: @model_id,
          options: %{"room" => %{"athanor_id" => ctx.athanor_id, "thread_id" => room.id}}
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

  test "when keeping a note asks, no flush request is made and the summary still lands", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept_large!(ctx, thread)

    script!([round_one(), %{"entries" => []}, reply("the story so far"), reply("done")])

    assert :completed = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert ["chat", "compaction", "chat"] =
             for(%{kind: "model", purpose: purpose} <- steps, do: purpose)

    assert Enum.any?(
             Threads.messages(Sanctum.Context.actor(ctx), thread.id),
             &(&1.kind == "compaction")
           )
  end

  test "a flush runs notes.keep alone, never past its size, and never as a card", %{
    ctx: ctx,
    thread: thread
  } do
    allow_keep!(ctx, thread)
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
    assert {:ok, []} = Tape.pending_approvals(ctx, turn)
  end

  test "a grant withdrawn while the flush request runs keeps no note", %{
    ctx: ctx,
    thread: thread
  } do
    grant = allow_keep!(ctx, thread)
    turn = accept_large!(ctx, thread)

    script!([
      round_one(),
      %{"entries" => []},
      {:probe, self()},
      flush_reply([keep("n1", "plan", "the plan")]),
      reply("the story so far"),
      reply("done")
    ])

    task = run(ctx, turn)
    assert_receive {:scripted_probe, worker, _}, 30_000
    :ok = Aqua.ToolGrants.revoke(ctx, grant)
    send(worker, :continue)

    assert :completed = Task.await(task, 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)
    assert %{purpose: "flush", outcome: "denied"} = Enum.find(steps, &(&1.action == "keep"))
    assert {:error, _} = Aqua.Notes.read(ctx, "plan")

    assert Enum.any?(
             Threads.messages(Sanctum.Context.actor(ctx), thread.id),
             &(&1.kind == "compaction")
           )
  end

  test "a grant store that cannot answer makes no flush request", %{ctx: ctx, thread: thread} do
    allow_keep!(ctx, thread)
    turn = accept_large!(ctx, thread)

    # The first round's call asks the store as it dispatches and is denied
    # there too, so no child answers it.
    script!([{:probe, self()}, round_one(), reply("the story so far"), reply("done")])

    task = run(ctx, turn)
    assert_receive {:scripted_probe, worker, _}, 30_000
    drop_grants!()
    send(worker, :continue)

    assert :completed = Task.await(task, 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)
    refute Enum.any?(steps, &(&1.purpose == "flush"))

    assert Enum.any?(
             Threads.messages(Sanctum.Context.actor(ctx), thread.id),
             &(&1.kind == "compaction")
           )
  end

  test "a summary that fails after a flush keeps the note and the turn goes on", %{
    ctx: ctx,
    thread: thread
  } do
    allow_keep!(ctx, thread)
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
      paused = paused_on_card!(ctx, thread)

      a = model_step!(ctx, paused, "flush")

      {:ok, %{calls: [%{step: n1}, %{step: n2}]}} =
        Tape.record_response(ctx, paused, a, %{
          text: nil,
          tool_calls: [call_attrs(paused, a, "n1", "plan"), call_attrs(paused, a, "n2", "later")]
        })

      {:ok, _} = Tape.mark_dispatched(ctx, paused, n1)
      # The note landed; the process died before its outcome was written.
      {:ok, _} = Aqua.Notes.keep(ctx, "plan", "the plan")
      b = model_step!(ctx, paused, "flush")

      resolve_card!(ctx, paused)
      script!([reply("done")])
      assert :completed = resume(ctx, paused)

      {:ok, steps} = Tape.steps(ctx, paused)
      assert %{dispatch_state: "closed", outcome: "uncertain"} = step(steps, n1.id)
      assert %{dispatch_state: "closed", outcome: "skipped"} = step(steps, n2.id)
      assert %{dispatch_state: "closed", outcome: "error"} = step(steps, b.id)
      refute Tape.restricted?(ctx, paused)
      assert {:error, _} = Aqua.Notes.read(ctx, "later")
    end

    test "an ordinary call whose outcome is unknown beside it still stops and restricts the turn",
         %{ctx: ctx, thread: thread} do
      paused = paused_on_card!(ctx, thread)

      flush = model_step!(ctx, paused, "flush")

      {:ok, %{calls: [%{step: note}]}} =
        Tape.record_response(ctx, paused, flush, %{
          text: nil,
          tool_calls: [call_attrs(paused, flush, "n1", "plan")]
        })

      {:ok, _} = Tape.mark_dispatched(ctx, paused, note)

      chat = model_step!(ctx, paused, "chat")

      {:ok, %{calls: [%{step: write}]}} =
        Tape.record_response(ctx, paused, chat, %{
          text: nil,
          tool_calls: [call_attrs(paused, chat, "w1", "draft")]
        })

      {:ok, _} = Tape.mark_dispatched(ctx, paused, write)

      resolve_card!(ctx, paused)
      assert {:paused, :uncertain} = resume(ctx, paused)

      {:ok, steps} = Tape.steps(ctx, paused)
      assert %{dispatch_state: "closed", outcome: "uncertain"} = step(steps, note.id)
      assert %{dispatch_state: "uncertain"} = step(steps, write.id)
      assert Tape.restricted?(ctx, paused)
    end
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

  defp resume(ctx, turn) do
    Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end)
    |> Task.await(60_000)
  end

  defp allow_keep!(ctx, thread) do
    grant = %{
      scope: "thread",
      thread_id: thread.id,
      agent_name: "aqua",
      tool: "notes",
      action: "keep"
    }

    {:ok, _} = Aqua.ToolGrants.put(ctx, Map.put(grant, :effect, "allow"))
    grant
  end

  # A message past the window's fill: the first round has nothing older to
  # summarize; once a round follows it, the message is older than the
  # boundary.
  defp accept_large!(ctx, thread) do
    accept!(ctx, thread, "@aqua read this\n" <> String.duplicate("lorem ipsum ", 7_000))
  end

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id, model: @model_id}
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

  defp drop_grants! do
    if Cyfr.RuntimeConfig.repo_adapter() == Ecto.Adapters.Postgres,
      do: Arca.Repo.query!("DROP TABLE tool_grants CASCADE"),
      else: Arca.Repo.query!("DROP TABLE tool_grants")
  end

  # A turn paused on a card, so rows can be laid on it before it resumes.
  defp paused_on_card!(ctx, thread) do
    turn = accept!(ctx, thread, "@aqua keep it")

    start_supervised!(
      {ScriptedWorker,
       ref: [@model],
       script: [
         response(
           [{"c0", "notes", %{"action" => "keep", "name" => "asked", "content" => "x"}}],
           nil,
           10
         )
       ]},
      id: :card
    )

    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
    stop_supervised!(:card)
    {:ok, paused} = Tape.turn(ctx, turn.id)
    paused
  end

  defp resolve_card!(ctx, paused) do
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, _} = Aqua.Approvals.resolve(ctx, approval.id, %{decision: :declined})
  end

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
      proposal_digest:
        Aqua.Loop.Policy.proposal_digest(%{"tool" => "notes", "action" => "keep", "args" => args}),
      step_kind: "tool"
    }
  end

  defp step(steps, id), do: Enum.find(steps, &(&1.id == id))
end
