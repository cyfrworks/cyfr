# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.LoopTest do
  @moduledoc """
  The loop against the real root, the real hands and a scripted model:
  the response lands before any call runs; hands run as children in
  workers while the loop holds the root; a call that asks pauses the
  turn once the auto steps close and a decision resumes it, the steer
  drained first; a worker that dies leaves an uncertain step; typed
  model errors are retried or end the turn; the step cap ends a turn
  that never stops calling.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Aqua.{Approvals, Tape}
  alias Arca.ConversationStorage, as: Conversations
  alias Cyfr.Test.ScriptedExecution
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag :requires_opus_modules

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "loop_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source, :execution_impl]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :seed_path, @seed_root)
    Application.put_env(:cyfr, :consent_source, Source.DB)
    Application.put_env(:cyfr, :execution_impl, ScriptedExecution)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    {:ok, conv} = Conversations.create(ctx)
    :ok = Phoenix.PubSub.subscribe(Emissary.PubSub, Tape.topic(ctx, conv.id))
    {:ok, ctx: ctx, conv: conv}
  end

  defp accept!(ctx, conv, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, conv.id, %{
        message: %{author: ctx.user_id, content: text},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  defp script!(items), do: start_supervised!({ScriptedExecution, ref: @model, script: items})

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

  defp calls(blocks, text \\ nil) do
    content =
      if(text, do: [%{"type" => "text", "text" => text}], else: []) ++
        Enum.map(blocks, fn {id, name, args} ->
          %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}
        end)

    %{
      "content" => content,
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 20, "output_tokens" => 8}
    }
  end

  defp run(ctx, turn), do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

  defp roots, do: Opus.ExecutionSemaphore.status().root_active

  test "a reply lands as rows before the turn ends, and the root is let go", %{
    ctx: ctx,
    conv: conv
  } do
    turn = accept!(ctx, conv, "@aqua hello")
    script!([{:probe, self()}, reply("hi there")])
    before = roots()

    task = run(ctx, turn)

    # While the model answers, the loop holds the root on its own process.
    assert_receive {:scripted_probe, worker, _child}, 10_000

    assert roots() == before + 1
    holders = Opus.ExecutionSemaphore.status().holders
    assert Enum.any?(holders, &(&1.pid == inspect(task.pid) and &1.class == :root))
    refute Enum.any?(holders, &(&1.pid == inspect(task.pid) and &1.class == :child))
    assert {:ok, %{status: "running", root_execution_id: root}} = Tape.turn(ctx, turn.id)
    assert is_binary(root)
    send(worker, :continue)

    assert :completed = Task.await(task, 30_000)

    assert {:ok, %{status: "completed", agent_capability_digest: digest}} =
             Tape.turn(ctx, turn.id)

    assert is_binary(digest)
    assert roots() == before
    assert_receive {:conversation, _, {:message, %{kind: "text", content: "hi there"}}}, 5_000
    assert_receive {:conversation, _, {:usage, %{input: 10, output: 5}}}, 5_000
    assert_receive {:conversation, _, {:turn_finished}}, 5_000

    assert {:ok, [%{kind: "model", dispatch_state: "closed", outcome: "ok"}]} =
             Tape.steps(ctx, turn)

    assert %{status: "completed"} = Arca.Repo.get(Arca.Execution, root)

    assert [%{execution_id: child}] =
             Enum.filter(ScriptedExecution.calls(), &(&1.input["operation"] == "chat"))

    assert %{status: "completed", parent_execution_id: ^root} =
             Arca.Repo.get(Arca.Execution, child)
  end

  test "hands run as children in workers, reads beside each other, and the response is persisted before they run",
       %{
         ctx: ctx,
         conv: conv
       } do
    turn = accept!(ctx, conv, "@aqua look around")

    script!([
      calls(
        [
          {"c1", "files", %{"action" => "list", "path" => "data"}},
          {"c2", "files", %{"action" => "tree", "path" => "data"}}
        ],
        "looking"
      ),
      reply("done looking")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)

    {:ok, steps} = Tape.steps(ctx, turn)

    assert [
             %{kind: "model"},
             %{kind: "tool", tool: "files", action: "list"} = list,
             %{kind: "tool", action: "tree"} = tree,
             %{kind: "model"}
           ] = steps

    for step <- [list, tree] do
      assert step.dispatch_state == "closed"
      assert step.outcome == "ok"
      assert is_binary(step.result_message_id)
      assert is_binary(step.child_execution_id)

      assert %{status: "completed", parent_execution_id: root} =
               Arca.Repo.get(Arca.Execution, step.child_execution_id)

      assert root == turn_root(ctx, turn)
    end

    # The response's rows: the text, one tool_call per call, then results.
    rows = Conversations.messages(ctx, conv.id)
    kinds = Enum.map(rows, & &1.kind)

    assert kinds == [
             "text",
             "text",
             "tool_call",
             "tool_call",
             "tool_result",
             "tool_result",
             "text"
           ]

    # Nothing stays charged against the turn's reservation.
    {:ok, %{budget_id: budget_id}} = Tape.turn(ctx, turn.id)
    assert {:ok, []} = Arca.BudgetReservations.charges(ctx.athanor_id, budget_id)
    assert_receive {:conversation, _, {:tool_activity, [_ | _]}}, 5_000
  end

  test "a call that asks pauses the turn after the auto steps close, and a decision resumes it",
       %{
         ctx: ctx,
         conv: conv
       } do
    turn = accept!(ctx, conv, "@aqua keep a note")
    before = roots()

    script!([
      calls([
        {"c1", "files", %{"action" => "list", "path" => "data"}},
        {"c2", "notes", %{"action" => "keep", "name" => "n", "content" => "remember"}}
      ])
    ])

    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)

    assert {:ok, %{status: "paused", paused_reason: "approval", root_execution_id: root} = paused} =
             Tape.turn(ctx, turn.id)

    assert roots() == before
    assert %{status: "paused"} = Arca.Repo.get(Arca.Execution, root)
    assert {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, steps} = Tape.steps(ctx, paused)

    assert [
             %{kind: "model", outcome: "ok"},
             %{action: "list", outcome: "ok"},
             %{action: "keep", dispatch_state: "proposed"} = keep
           ] = steps

    assert keep.approval_id == approval.id

    assert {:ok, %{decision: "approved"}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    ScriptedExecution.script([reply("kept")])

    resumed =
      Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end)

    assert :completed = Task.await(resumed, 60_000)

    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn.id)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{action: "keep", dispatch_state: "closed", outcome: "ok"} =
             Enum.find(steps, &(&1.action == "keep"))

    assert roots() == before
  end

  test "a steer that arrived while the turn waited skips the approved step and reaches the model",
       %{
         ctx: ctx,
         conv: conv
       } do
    turn = accept!(ctx, conv, "@aqua keep a note")
    script!([calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}}])])
    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
    {:ok, paused} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})

    {:ok, _} =
      Tape.accept(ctx, conv.id, %{
        message: %{author: ctx.user_id, content: "actually, never mind"},
        steer_turn_id: turn.id
      })

    ScriptedExecution.script([{:probe, self()}, reply("ok, dropped")])

    resumed =
      Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end)

    assert_receive {:scripted_probe, worker, _}, 10_000

    %{input: %{"params" => %{"messages" => messages}}} =
      ScriptedExecution.calls() |> Enum.filter(&(&1.input["operation"] == "chat")) |> List.last()

    texts =
      messages
      |> Enum.flat_map(& &1["content"])
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])

    assert Enum.any?(texts, &(&1 =~ "never mind"))
    send(worker, :continue)
    assert :completed = Task.await(resumed, 60_000)

    {:ok, steps} = Tape.steps(ctx, turn)
    assert %{action: "keep", outcome: "skipped"} = Enum.find(steps, &(&1.action == "keep"))
    # The decision stands as made; the work it unblocked was skipped.
    assert {:ok, %{status: "approved"}} = Tape.approval(ctx, approval.id)
  end

  test "a policy refusal is the call's own result; a dead worker stops the turn, and the sender's next line continues it with reads only",
       %{ctx: ctx, conv: conv} do
    before = roots()
    turn = accept!(ctx, conv, "@aqua do things")

    start_supervised!(
      {ScriptedExecution,
       ref: [@model, "catalyst:local.http", "catalyst:local.files"], script: []}
    )

    ScriptedExecution.script([
      calls([
        {"c1", "component", %{"action" => "delete", "name" => "x"}},
        {"c2", "http", %{"action" => "get", "url" => "https://example.test/x"}}
      ]),
      {:crash, :before_response}
    ])

    assert {:paused, :uncertain} = Task.await(run(ctx, turn), 60_000)

    assert {:ok, %{status: "paused", paused_reason: "uncertain"} = paused} =
             Tape.turn(ctx, turn.id)

    assert roots() == before

    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{outcome: "denied", dispatch_state: "closed"} =
             Enum.find(steps, &(&1.tool == "component"))

    assert %{dispatch_state: "uncertain", outcome: "uncertain"} =
             get = Enum.find(steps, &(&1.action == "get"))

    [row] = Enum.filter(Conversations.messages(ctx, conv.id), &(&1.kind == "turn_aborted"))
    assert %{"covers" => [%{"step_id" => step_id}]} = Conversations.payload(row)
    assert step_id == get.id
    assert paused.window_upto_seq == row.seq

    # The sender's line past the stop continues the turn: a read runs, a
    # write is refused until a new turn starts.
    {:ok, _} =
      Tape.accept(ctx, conv.id, %{
        message: %{author: ctx.user_id, content: "carry on, carefully"},
        steer_turn_id: turn.id
      })

    ScriptedExecution.script([
      calls([
        {"c3", "files", %{"action" => "list", "path" => "data"}},
        {"c4", "files", %{"action" => "write", "path" => "data/x", "content" => "y"}}
      ]),
      %{"entries" => []},
      reply("read only, then")
    ])

    assert :completed =
             Task.await(
               Task.async(fn ->
                 Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume)
               end),
               60_000
             )

    {:ok, steps} = Tape.steps(ctx, turn)
    assert %{action: "list", outcome: "ok"} = Enum.find(steps, &(&1.action == "list"))

    assert %{action: "write", outcome: "denied"} =
             write = Enum.find(steps, &(&1.action == "write"))

    assert {:ok, %{content: content}} = Tape.message(ctx, write.result_message_id)
    assert content =~ "outcome is unknown"
    assert roots() == before
  end

  test "the room excerpt reaches the model and never the retained input", %{ctx: ctx, conv: conv} do
    # The room is read under the person's own seat.
    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: ctx.athanor_id)

    {:ok, room} = Conversations.create(ctx)

    {:ok, _} =
      Conversations.append(ctx, room.id, %{author: ctx.user_id, content: "ROOM-ONLY-LINE"})

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, conv.id, %{
        message: %{author: ctx.user_id, content: "@aqua what did they say?"},
        turn: %{
          orchestrator: "aqua",
          requested_by: ctx.user_id,
          options: %{"room" => %{"athanor_id" => ctx.athanor_id, "conversation_id" => room.id}}
        }
      })

    script!([reply("They said hello.")])
    assert :completed = Task.await(run(ctx, turn), 60_000)

    assert %{execution_id: id, input: sent} =
             Enum.find(ScriptedExecution.calls(), &(&1.input["operation"] == "chat"))

    assert Jason.encode!(sent) =~ "ROOM-ONLY-LINE"

    assert {:ok, %{retention_class: "chat_step"}, kept} =
             Arca.ExecutionPayloads.get(ctx, id, "input")

    refute kept =~ "ROOM-ONLY-LINE"
    assert kept =~ "what did they say?"

    {:ok, [%{kind: "model"} = step | _]} = Tape.steps(ctx, turn)
    assert Jason.decode!(step.excluded) == ["room_excerpt"]
  end

  test "a role's unknown outcome stops the soul", %{ctx: ctx, conv: conv} do
    turn = accept!(ctx, conv, "@aqua fetch it")
    start_supervised!({ScriptedExecution, ref: [@model, "catalyst:local.http"], script: []})

    ScriptedExecution.script([
      calls([{"r1", "web", %{"task" => "read the page"}}]),
      # The clone's own round, and the hand that dies under it.
      calls([{"w1", "http", %{"action" => "get", "url" => "https://example.test/x"}}]),
      {:crash, :before_response}
    ])

    assert {:paused, :uncertain} = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{kind: "clone", dispatch_state: "uncertain"} =
             clone_step = Enum.find(steps, &(&1.kind == "clone"))

    [clone] = Arca.Repo.all(from(t in Arca.Schemas.Turn, where: t.parent_turn_id == ^turn.id))
    assert clone.status == "uncertain"
    {:ok, clone_steps} = Tape.steps(ctx, clone)

    assert %{action: "get", dispatch_state: "uncertain"} =
             Enum.find(clone_steps, &(&1.action == "get"))

    [row] =
      Enum.filter(
        Conversations.messages(ctx, conv.id),
        &(&1.kind == "turn_aborted" and &1.turn_id == turn.id)
      )

    assert %{"covers" => [%{"step_id" => covered}]} = Conversations.payload(row)
    assert covered == clone_step.id
  end

  test "the first unknown outcome stops the group; what still runs is cancelled and covered", %{
    ctx: ctx,
    conv: conv
  } do
    turn = accept!(ctx, conv, "@aqua fetch both")
    start_supervised!({ScriptedExecution, ref: [@model, "catalyst:local.http"], script: []})

    ScriptedExecution.script([
      calls([
        {"c1", "http", %{"action" => "get", "url" => "https://example.test/a"}},
        {"c2", "http", %{"action" => "get", "url" => "https://example.test/b"}}
      ]),
      :hang,
      {:crash, :before_response}
    ])

    assert {:paused, :uncertain} = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)
    gets = Enum.filter(steps, &(&1.action == "get"))
    assert length(gets) == 2
    assert Enum.all?(gets, &(&1.dispatch_state == "uncertain"))

    [row] = Enum.filter(Conversations.messages(ctx, conv.id), &(&1.kind == "turn_aborted"))
    covered = row |> Conversations.payload() |> Map.fetch!("covers") |> Enum.map(& &1["step_id"])
    assert Enum.sort(covered) == Enum.sort(Enum.map(gets, & &1.id))
  end

  test "a rate limit is retried and an authentication refusal ends the turn asking for setup", %{
    ctx: ctx,
    conv: conv
  } do
    turn = accept!(ctx, conv, "@aqua hi")
    # A typed refusal rides the envelope's error, not the engine's.
    script!([
      {:refuse, %{"type" => "rate_limited", "message" => "slow down"}},
      reply("after the retry")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert [
             %{kind: "model", outcome: "error", error: "rate_limited"},
             %{kind: "model", outcome: "ok"}
           ] = steps

    other = accept!(ctx, conv, "@aqua again")
    ScriptedExecution.script([{:refuse, %{"type" => "authentication", "message" => "no key"}}])
    result = Task.await(run(ctx, other), 60_000)

    assert {:failed, :setup_required} = result
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, other.id)
    assert_receive {:conversation, _, {:consent_required, ref, user}}, 5_000
    assert ref =~ @model and user == ctx.user_id
  end

  test "the step cap ends a turn that never stops calling", %{ctx: ctx, conv: conv} do
    turn = accept!(ctx, conv, "@aqua loop forever")
    script!(List.duplicate(calls([{"u", "ui", %{"kind" => "ui.overlay.close"}}]), 40))
    assert {:failed, :step_cap} = Task.await(run(ctx, turn), 120_000)
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, turn.id)
    assert_receive {:conversation, _, {:intents, [%{kind: "overlay_close"}], _}}, 5_000
  end

  defp turn_root(ctx, turn) do
    {:ok, %{root_execution_id: root}} = Tape.turn(ctx, turn.id)
    root
  end
end
