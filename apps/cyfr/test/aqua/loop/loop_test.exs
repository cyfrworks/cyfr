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

  import Ecto.Query, only: [from: 2]

  alias Aqua.{Approvals, Tape}
  alias Arca.ThreadStorage, as: Threads
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

    {:ok, thread} = Threads.create(ctx)
    :ok = Phoenix.PubSub.subscribe(Emissary.PubSub, Tape.topic(ctx, thread.id))
    {:ok, ctx: ctx, thread: thread}
  end

  test "the catalyst's consented cap answers to a name, not to the ref the spec carries", %{
    ctx: ctx
  } do
    {:ok, authority} = Opus.Chain.authority_for(ctx, :default, @soul)

    # What `Aqua.AgentConfig` resolves, and so what the spec holds.
    versioned = @model <> ":1.3.0"
    {:ok, name_ref} = Cyfr.ComponentRef.to_name_ref(versioned)

    # The graph is keyed the way `Opus.Chain` steps: by name. Asking with
    # the version answers nothing, and a cap of nil is a size check that
    # never fires — which is what the loop did while it asked that way.
    assert {:error, :unknown_node} = Cyfr.Authority.node_limits(authority, versioned)

    assert {:ok, %Cyfr.Limits{max_request_size: cap}} =
             Cyfr.Authority.node_limits(authority, name_ref)

    assert is_integer(cap) and cap > 0
  end

  test "the loop resolves a cap for the spec it actually holds", %{ctx: ctx, thread: thread} do
    start_supervised!({ScriptedExecution, ref: @model, script: []})
    turn = accept!(ctx, thread, "hello")
    {:ok, authority} = Opus.Chain.authority_for(ctx, :default, @soul)
    {:ok, spec} = Aqua.Loop.Turn.build(ctx, turn, authority: authority, excerpt?: false)

    # The spec holds a versioned ref, and the graph is keyed by name. Asking
    # with what the spec holds answers nothing, and the size trigger then
    # never fires — indistinguishable, from outside, from a request that fits.
    assert String.starts_with?(spec.catalyst, @model <> ":")
    assert is_integer(Aqua.Loop.catalyst_request_cap(spec))
  end

  describe "summary_text/1" do
    test "a summary with words is committed" do
      assert {:ok, "what was said"} = Aqua.Loop.summary_text("what was said")
    end

    test "a reply carrying no text is refused, so the boundary does not advance" do
      # The loop filters the reply to text blocks and joins them, so a
      # reply of only tool calls — or of no content at all — arrives here as
      # "". Committing it would render an empty summary in place of every row
      # before `first_kept_seq`.
      assert {:error, :empty_summary} = Aqua.Loop.summary_text("")
      assert {:error, :empty_summary} = Aqua.Loop.summary_text("   \n\t ")
    end
  end

  describe "group/1" do
    test "a write between reads runs alone, and the reads on either side do not join it" do
      read1 = item("files", %{"action" => "read", "path" => "a"})
      write = item("files", %{"action" => "write", "path" => "b", "content" => "x"})
      read2 = item("files", %{"action" => "read", "path" => "c"})

      assert [{:concurrent, [^read1]}, {:exclusive, ^write}, {:concurrent, [^read2]}] =
               Aqua.Loop.group([read1, write, read2])
    end

    test "consecutive reads share a group and consecutive writes do not" do
      r1 = item("files", %{"action" => "read", "path" => "a"})
      r2 = item("files", %{"action" => "read", "path" => "b"})
      w1 = item("files", %{"action" => "write", "path" => "c", "content" => "x"})
      w2 = item("files", %{"action" => "write", "path" => "d", "content" => "y"})

      assert [{:concurrent, [^r1, ^r2]}, {:exclusive, ^w1}, {:exclusive, ^w2}] =
               Aqua.Loop.group([r1, r2, w1, w2])
    end

    test "a write last, and a write first, each stand alone" do
      read = item("files", %{"action" => "read", "path" => "a"})
      write = item("files", %{"action" => "write", "path" => "b", "content" => "x"})

      assert [{:concurrent, [^read]}, {:exclusive, ^write}] = Aqua.Loop.group([read, write])
      assert [{:exclusive, ^write}, {:concurrent, [^read]}] = Aqua.Loop.group([write, read])
    end
  end

  defp item(name, args) do
    {:ok, call} = Aqua.Loop.Binding.resolve(name, args)
    %{step: %{kind: "tool"}, call: {:ok, call}}
  end

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
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

  defp keep(events) do
    Enum.reduce(events, Aqua.Loop.Stream.new(), fn
      {:turn_fence, _, fence}, kept -> Aqua.Loop.Stream.advance(kept, fence)
      {:delta, delta}, kept -> Aqua.Loop.Stream.add(kept, delta)
      {:delta_abandoned, marker}, kept -> Aqua.Loop.Stream.abandoned(kept, marker)
      {:message, row}, kept -> Aqua.Loop.Stream.landed(kept, row)
      _event, kept -> kept
    end)
  end

  defp drain do
    receive do
      message -> [message | drain()]
    after
      0 -> []
    end
  end

  defp files_catalyst(ctx) do
    {:ok, listing} = Aqua.AgentConfig.catalyst_listing(ctx)
    {:ok, ref} = Aqua.AgentConfig.resolve_catalyst(listing, "catalyst:local.files")
    ref
  end

  defp roots, do: Opus.ExecutionSemaphore.status().root_active

  test "a reply lands as rows before the turn ends, and the root is let go", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept!(ctx, thread, "@aqua hello")
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
    assert_receive {:thread, _, {:message, %{kind: "text", content: "hi there"}}}, 5_000
    assert_receive {:thread, _, {:usage, %{input: 10, output: 5}}}, 5_000
    assert_receive {:thread, _, {:turn_finished}}, 5_000

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
         thread: thread
       } do
    turn = accept!(ctx, thread, "@aqua look around")

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
    rows = Threads.messages(ctx, thread.id)
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
    assert_receive {:thread, _, {:tool_activity, [_ | _]}}, 5_000
  end

  test "a call that asks pauses the turn after the auto steps close, and a decision resumes it",
       %{
         ctx: ctx,
         thread: thread
       } do
    turn = accept!(ctx, thread, "@aqua keep a note")
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

  test "an approved call whose row no longer matches its approval runs nothing", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept!(ctx, thread, "@aqua keep a note")

    script!([
      calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "remember"}}])
    ])

    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
    {:ok, paused} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})

    # The call's row now says something other than what was approved.
    {:ok, steps} = Tape.steps(ctx, paused)
    keep = Enum.find(steps, &(&1.action == "keep"))
    {:ok, row} = Tape.message(ctx, keep.message_id)

    payload =
      row
      |> Tape.payload()
      |> put_in(["arguments", "content"], "something else")
      |> Jason.encode!()

    {1, _} =
      Arca.Repo.update_all(
        from(m in Arca.Schemas.Message, where: m.id == ^row.id),
        set: [payload: payload]
      )

    ScriptedExecution.script([reply("done")])

    assert :completed =
             Task.await(
               Task.async(fn ->
                 Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume)
               end),
               60_000
             )

    assert {:ok, %{dispatch_state: "closed", outcome: "denied"}} = Tape.step(ctx, keep.id)
    assert {:error, _} = Aqua.Notes.read(ctx, "n")
  end

  test "a turn pins the catalyst release it runs on; a resume runs only that release, and only one speaking model/chat@1",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua keep a note")

    script!([
      calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}}])
    ])

    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)

    assert {:ok, %{catalyst_ref: "catalyst:local.claude:" <> _ = pinned} = paused} =
             Tape.turn(ctx, turn.id)

    assert {:error, :catalyst_pinned} =
             Arca.TurnStorage.pin_catalyst(ctx, turn.id, "catalyst:local.openai:1.3.0", %{
               fence: paused.fence
             })

    # A spec is built on the pinned release alone, and only on one that
    # speaks the chat contract.
    {:ok, authority} = Opus.Chain.authority_for(ctx, :default, @soul)

    for {ref, refusal} <- [
          {"catalyst:local.claude:0.0.1", :catalyst_not_in_estate},
          {files_catalyst(ctx), :catalyst_not_chat}
        ] do
      assert {:error, {^refusal, ^ref}} =
               Aqua.Loop.Turn.build(ctx, %{paused | catalyst_ref: ref},
                 authority: authority,
                 excerpt?: false
               )
    end

    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :declined})
    ScriptedExecution.script([reply("done")])

    assert :completed =
             Task.await(
               Task.async(fn ->
                 Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume)
               end),
               60_000
             )

    assert {:ok, %{catalyst_ref: ^pinned}} = Tape.turn(ctx, turn.id)
  end

  test "a grant withdrawn while the model answers does not run the call it used to allow",
       %{ctx: ctx, thread: thread} do
    grant = %{
      scope: "thread",
      thread_id: thread.id,
      agent_name: "aqua",
      tool: "notes",
      action: "keep"
    }

    {:ok, _} = Aqua.ToolGrants.put(ctx, Map.put(grant, :effect, "allow"))

    turn = accept!(ctx, thread, "@aqua keep a note")

    script!([
      {:probe, self()},
      calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}}]),
      reply("understood")
    ])

    task = run(ctx, turn)

    # The turn's policy was snapshotted at `Turn.build/3` with the grant in
    # it. Withdrawing it now reaches no loop already running — the call must
    # ask again as it dispatches.
    assert_receive {:scripted_probe, worker, _}, 10_000
    :ok = Aqua.ToolGrants.revoke(ctx, grant)
    send(worker, :continue)

    assert :completed = Task.await(task, 60_000)

    {:ok, steps} = Tape.steps(ctx, turn)
    assert %{dispatch_state: "closed", outcome: outcome} = Enum.find(steps, &(&1.kind == "tool"))
    refute outcome == "ok"
  end

  test "a steer that arrived while the turn waited skips the approved step and reaches the model",
       %{
         ctx: ctx,
         thread: thread
       } do
    turn = accept!(ctx, thread, "@aqua keep a note")
    script!([calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}}])])
    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
    {:ok, paused} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})

    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
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

  test "a steer that lands while the last answer is written is answered before the turn completes",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua hello")
    script!([{:probe, self()}, reply("hello"), reply("and hi again")])

    running = run(ctx, turn)
    assert_receive {:scripted_probe, worker, _}, 30_000

    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "one more thing"},
        steer_turn_id: turn.id
      })

    send(worker, :continue)
    assert :completed = Task.await(running, 60_000)

    [_first, %{input: %{"params" => %{"messages" => messages}}}] =
      Enum.filter(ScriptedExecution.calls(), &(&1.input["operation"] == "chat"))

    assert Jason.encode!(messages) =~ "one more thing"
    assert Enum.any?(Threads.messages(ctx, thread.id), &(&1.content == "and hi again"))
  end

  test "a steer names an open turn of its own thread", %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua hello")
    {:ok, elsewhere} = Threads.create(ctx)

    assert {:error, :turn_over} =
             Tape.accept(ctx, elsewhere.id, %{
               message: %{author: ctx.user_id, content: "wrong room"},
               steer_turn_id: turn.id
             })

    assert Threads.messages(ctx, elsewhere.id) == []
  end

  test "a policy refusal is the call's own result; a dead worker stops the turn, and the sender's next line continues it with reads only",
       %{ctx: ctx, thread: thread} do
    before = roots()
    turn = accept!(ctx, thread, "@aqua do things")

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

    [row] = Enum.filter(Threads.messages(ctx, thread.id), &(&1.kind == "turn_aborted"))
    assert %{"covers" => [%{"step_id" => step_id}]} = Threads.payload(row)
    assert step_id == get.id
    assert paused.window_upto_seq == row.seq

    # The sender's line past the stop continues the turn: a read runs, a
    # write is refused until a new turn starts.
    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
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

  test "the room excerpt reaches the model and never the retained input", %{
    ctx: ctx,
    thread: thread
  } do
    # The room is read under the person's own seat.
    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: ctx.athanor_id)

    {:ok, room} = Threads.create(ctx)

    {:ok, _} =
      Threads.append(ctx, room.id, %{author: ctx.user_id, content: "ROOM-ONLY-LINE"})

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua what did they say?"},
        turn: %{
          orchestrator: "aqua",
          requested_by: ctx.user_id,
          options: %{"room" => %{"athanor_id" => ctx.athanor_id, "thread_id" => room.id}}
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

  test "the step cap counts every model step of the turn, across a pause and a retry", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept!(ctx, thread, "@aqua keep going")
    start_supervised!({ScriptedExecution, ref: [@model, "catalyst:local.files"], script: []})

    # Two rounds, a retried third, then a card.
    ScriptedExecution.script([
      calls([{"c1", "files", %{"action" => "list", "path" => "data"}}]),
      %{"entries" => []},
      calls([{"c2", "files", %{"action" => "list", "path" => "data"}}]),
      %{"entries" => []},
      {:refuse, %{"type" => "rate_limited", "message" => "slow down"}},
      calls([{"c3", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}}])
    ])

    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)
    opened = Enum.count(steps, &(&1.kind == "model"))
    assert opened == 4

    # Resumed: reads until the cap, which counts what came before.
    {:ok, paused} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, _} = Aqua.Approvals.resolve(ctx, approval.id, %{decision: :declined})

    ScriptedExecution.script(
      List.flatten(
        for _ <- 1..40 do
          [calls([{"cx", "files", %{"action" => "list", "path" => "data"}}]), %{"entries" => []}]
        end
      )
    )

    assert {:failed, :step_cap} =
             Task.await(
               Task.async(fn ->
                 Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume)
               end),
               120_000
             )

    {:ok, steps} = Tape.steps(ctx, turn)
    assert Enum.count(steps, &(&1.kind == "model")) == 30
  end

  test "a card expires when the estate says, not after a day", %{ctx: ctx, thread: thread} do
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)

    {:ok, _} =
      Sanctum.Tenancy.Athanors.put_settings(athanor, %{"approvals" => %{"expiry_hours" => 1}})

    turn = accept!(ctx, thread, "@aqua keep it")
    script!([calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}}])])
    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)

    {:ok, paused} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    left = DateTime.diff(approval.expires_at, DateTime.utc_now(), :second)
    assert left in 3500..3600
  end

  test "a role's unknown outcome stops the soul", %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua fetch it")
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
        Threads.messages(ctx, thread.id),
        &(&1.kind == "turn_aborted" and &1.turn_id == turn.id)
      )

    assert %{"covers" => [%{"step_id" => covered}]} = Threads.payload(row)
    assert covered == clone_step.id
  end

  test "the first unknown outcome stops the group; what still runs is cancelled and covered", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept!(ctx, thread, "@aqua fetch both")
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

    [row] = Enum.filter(Threads.messages(ctx, thread.id), &(&1.kind == "turn_aborted"))
    covered = row |> Threads.payload() |> Map.fetch!("covers") |> Enum.map(& &1["step_id"])
    assert Enum.sort(covered) == Enum.sort(Enum.map(gets, & &1.id))
  end

  test "a rate limit is retried and an authentication refusal ends the turn asking for setup", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept!(ctx, thread, "@aqua hi")
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

    other = accept!(ctx, thread, "@aqua again")
    ScriptedExecution.script([{:refuse, %{"type" => "authentication", "message" => "no key"}}])
    result = Task.await(run(ctx, other), 60_000)

    assert {:failed, :setup_required} = result
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, other.id)
    assert_receive {:thread, _, {:consent_required, ref, user}}, 5_000
    assert ref =~ @model and user == ctx.user_id
  end

  test "a chat step's text streams to the thread in order, once, under its turn's fence, before its row lands",
       %{
         ctx: ctx,
         thread: thread
       } do
    turn = accept!(ctx, thread, "@aqua hello")
    turn_id = turn.id

    script!([
      {:emit,
       [
         %{"type" => "text.delta", "text" => "hi "},
         %{"type" => "tool_call.delta", "index" => 0, "arguments" => "{}"},
         %{"type" => "text.delta", "text" => "there"},
         %{"type" => "stop", "stop_reason" => "end_turn"}
       ]},
      reply("hi there")
    ])

    assert :completed = Task.await(run(ctx, turn), 30_000)
    assert_receive {:thread, _, {:turn_finished}}, 5_000

    {:ok, %{fence: fence}} = Tape.turn(ctx, turn.id)

    streamed =
      for {:thread, _, event} <- drain(),
          match?({:turn_fence, _, _}, event) or match?({:delta, _}, event) or
            match?({:delta_abandoned, _}, event) or
            match?({:message, %{kind: "text", author: "aqua"}}, event),
          do: event

    assert [
             {:turn_fence, ^turn_id, ^fence},
             {:delta,
              %{
                turn_id: ^turn_id,
                fence: ^fence,
                source: ^turn_id,
                step_id: step_id,
                text: "hi ",
                role: nil,
                seq: first
              }},
             {:delta, %{step_id: step_id, text: "there", seq: second}},
             {:message, %{content: "hi there"} = row}
           ] = streamed

    assert second > first
    assert Tape.payload(row)["step_id"] == step_id
  end

  test "a refused chat step's text is withdrawn, and no earlier step's late text returns once the retry lands",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua hello")

    script!([
      {:emit, [%{"type" => "text.delta", "text" => "partial answer"}]},
      {:refuse, %{"type" => "rate_limited", "message" => "slow down"}},
      {:emit, [%{"type" => "text.delta", "text" => "the answer"}]},
      reply("the answer")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)

    events = for {:thread, _, event} <- drain(), do: event
    deltas = for {:delta, delta} <- events, do: delta

    assert [
             %{text: "partial answer", ordinal: refused} = first,
             %{text: "the answer", ordinal: retried}
           ] = deltas

    assert retried > refused
    assert [%{step_id: abandoned}] = for({:delta_abandoned, marker} <- events, do: marker)
    assert abandoned == first.step_id

    kept = keep(events)
    assert Aqua.Loop.Stream.texts(kept) == []

    late = %{first | seq: {99, 99}, text: " and more"}
    assert Aqua.Loop.Stream.texts(Aqua.Loop.Stream.add(kept, late)) == []
    assert Aqua.Loop.Stream.texts(Aqua.Loop.Stream.add(kept, %{late | step_id: "older"})) == []
  end

  test "a model its catalyst does not know ends the turn before any request, and a missing key asks for setup",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua hello")

    start_supervised!(
      {ScriptedExecution,
       ref: @model,
       script: [],
       describe: {:refuse, %{"type" => "unknown_model", "message" => "not a model"}}}
    )

    assert {:failed, {:unknown_model, _}} = Task.await(run(ctx, turn), 30_000)
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, turn.id)
    refute Enum.any?(ScriptedExecution.calls(), &(&1.input["operation"] == "chat"))

    stop_supervised!(ScriptedExecution)

    start_supervised!(
      {ScriptedExecution,
       ref: @model,
       script: [],
       describe: {:refuse, %{"type" => "secret_denied", "message" => "no key"}}}
    )

    other = accept!(ctx, thread, "@aqua again")
    assert {:failed, :setup_required} = Task.await(run(ctx, other), 30_000)
    assert_receive {:thread, _, {:consent_required, ref, user}}, 5_000
    assert ref =~ @model and user == ctx.user_id
  end

  test "the step cap ends a turn that never stops calling", %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua loop forever")
    script!(List.duplicate(calls([{"u", "ui", %{"kind" => "ui.overlay.close"}}]), 40))
    assert {:failed, :step_cap} = Task.await(run(ctx, turn), 120_000)
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, turn.id)
    assert_receive {:thread, _, {:intents, [%{kind: "overlay_close"}], _}}, 5_000
  end

  defp turn_root(ctx, turn) do
    {:ok, %{root_execution_id: root}} = Tape.turn(ctx, turn.id)
    root
  end
end
