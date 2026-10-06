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
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.{Bootstrap}

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "loop_#{System.unique_integer([:positive])}")
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

    ctx = Sanctum.TestContext.local(:prism)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    # The model catalyst unseals its key when its runner attaches.
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    :ok = Aqua.Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, thread: thread}
  end

  test "the catalyst's consented cap answers to a name, not to the ref the spec carries", %{
    ctx: ctx
  } do
    {:ok, authority} = Crucible.authority_for(ctx, :default, @soul)

    # What `Aqua.AgentConfig` resolves, and so what the spec holds.
    versioned = @model <> ":1.3.1"
    {:ok, name_ref} = Prima.ComponentRef.to_name_ref(versioned)

    # The graph is keyed the way `Crucible.Admission` steps: by name. Asking with
    # the version answers nothing, and a cap of nil is a size check that
    # never fires — which is what the loop did while it asked that way.
    assert {:error, :unknown_node} = Prima.Authority.node_limits(authority, versioned)

    assert {:ok, %Prima.Limits{max_request_size: cap}} =
             Prima.Authority.node_limits(authority, name_ref)

    assert is_integer(cap) and cap > 0
  end

  test "the loop resolves a cap for the spec it actually holds", %{ctx: ctx, thread: thread} do
    start_supervised!({ScriptedWorker, ref: @model, script: []})
    turn = accept!(ctx, thread, "hello")
    {:ok, authority} = Crucible.authority_for(ctx, :default, @soul)
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
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @model, script: items})

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
      {:turn_fence, %{turn_id: _, fence: fence}}, kept -> Aqua.Loop.Stream.advance(kept, fence)
      {:delta, delta}, kept -> Aqua.Loop.Stream.add(kept, delta)
      {:delta_abandoned, marker}, kept -> Aqua.Loop.Stream.abandoned(kept, marker)
      {:message, row}, kept -> Aqua.Loop.Stream.landed(kept, row)
      _event, kept -> kept
    end)
  end

  # What a viewer of the thread heard, as `{kind, data}` pairs.
  defp thread_events(messages),
    do: for(%ThreadEvent{kind: kind, data: data} <- messages, do: {kind, data})

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

  defp roots, do: Prima.Slots.status(Crucible.Slots).root_active

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
    holders = Prima.Slots.status(Crucible.Slots).holders
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
    assert_receive %ThreadEvent{kind: :message, data: %{kind: "text", content: "hi there"}}, 5_000
    assert_receive %ThreadEvent{kind: :usage, data: %{input: 10, output: 5}}, 5_000
    assert_receive %ThreadEvent{kind: :turn_finished}, 5_000

    assert {:ok, [%{kind: "model", dispatch_state: "closed", outcome: "ok"}]} =
             Tape.steps(ctx, turn)

    assert %{status: "completed"} = Arca.Repo.get(Arca.Schemas.Execution, root)

    assert [%{execution_id: child}] =
             Enum.filter(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

    assert %{status: "completed", parent_execution_id: ^root} =
             Arca.Repo.get(Arca.Schemas.Execution, child)
  end

  # The files hand is not scripted: it runs on the opus worker service.
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
               Arca.Repo.get(Arca.Schemas.Execution, step.child_execution_id)

      assert root == turn_root(ctx, turn)
    end

    # The response's rows: the text, one tool_call per call, then results.
    rows = Threads.messages(Sanctum.Context.actor(ctx), thread.id)
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
    assert {:ok, []} = Arca.BudgetReservations.charges(Sanctum.Context.actor(ctx), budget_id)
    assert_receive %ThreadEvent{kind: :tool_activity, data: [_ | _]}, 5_000
  end

  # The files hand is not scripted: it runs on the opus worker service.
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
    assert %{status: "paused"} = Arca.Repo.get(Arca.Schemas.Execution, root)
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

    ScriptedWorker.script([reply("kept")])

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

    ScriptedWorker.script([reply("done")])

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
             Arca.TurnStorage.pin_catalyst(
               Sanctum.Context.actor(ctx),
               turn.id,
               "catalyst:local.openai:1.3.1",
               %{
                 fence: paused.fence
               }
             )

    # A spec is built on the pinned release alone, and only on one that
    # speaks the chat contract.
    {:ok, authority} = Crucible.authority_for(ctx, :default, @soul)

    for {ref, refusal} <- [
          {"catalyst:local.claude:0.0.1", :catalyst_not_in_athanor},
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
    ScriptedWorker.script([reply("done")])

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

  describe "a bounded standing allow" do
    # A standing allow bound to a lifecycle, a deadline or some paths: the
    # guest reads its pair as a question, and each call runs at once only
    # when the rows as they stand when it is decided cover it.

    defp bounded!(ctx, thread, pair, bounds) do
      {:ok, _} =
        Aqua.ToolGrants.put(
          ctx,
          Map.merge(
            %{scope: "thread", effect: "allow", thread_id: thread.id, agent_name: "aqua"},
            Map.merge(pair, bounds)
          )
        )
    end

    defp other_execution!(ctx) do
      id = "exec_bounded_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Arca.Execution.admit(
          %{
            id: id,
            reference: "catalyst:local.files:0.5.2",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            component_type: "catalyst",
            origin: :interactive
          },
          grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
          verify: &Sanctum.ExecutionStanding.verify/1
        )

      id
    end

    @keep_pair %{tool: "notes", action: "keep"}

    # The files hand is not scripted: it runs on the opus worker service.
    test "an allow for this execution and data/notes/ runs a write there and asks for one elsewhere",
         %{ctx: ctx, thread: thread} do
      notes = %{kind: "storage_path", patterns: ["data/notes/"]}

      # An answer given for another run, still going: it puts files.write
      # in the turn's policy as a question, and covers none of this turn's
      # calls.
      a = other_execution!(ctx)

      {:ok, _} =
        Aqua.ToolGrants.put(ctx, %{
          scope: "agent",
          effect: "allow",
          agent_name: "aqua",
          tool: "files",
          action: "write",
          lifecycle_kind: "execution",
          lifecycle_id: a,
          constraint: notes
        })

      turn = accept!(ctx, thread, "@aqua write two files")

      script!([
        {:probe, self()},
        calls([
          {"c1", "files",
           %{"action" => "write", "path" => "data/notes/a.md", "content" => "inside"}},
          {"c2", "files",
           %{"action" => "write", "path" => "data/other/b.md", "content" => "outside"}}
        ])
      ])

      task = run(ctx, turn)

      # The answer for this turn's own execution, given once it runs.
      assert_receive {:scripted_probe, worker, _}, 10_000

      bounded!(ctx, thread, %{tool: "files", action: "write"}, %{
        lifecycle_kind: "execution",
        lifecycle_id: turn_root(ctx, turn),
        constraint: notes
      })

      send(worker, :continue)
      assert {:paused, :approval} = Task.await(task, 60_000)

      {:ok, paused} = Tape.turn(ctx, turn.id)
      {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
      {:ok, steps} = Tape.steps(ctx, paused)

      inside = Enum.find(steps, &(&1.kind == "tool" and &1.approval_id == nil))
      outside = Enum.find(steps, &(&1.approval_id == approval.id))

      assert %{action: "write", dispatch_state: "closed", outcome: "ok"} = inside
      assert %{action: "write", dispatch_state: "proposed"} = outside
      assert {:ok, card} = Tape.message(ctx, approval.message_id)

      assert get_in(Threads.payload(card), ["intent", "proposal", "args", "path"]) ==
               "data/other/b.md"
    end

    test "an allow for another execution asks while that execution still runs",
         %{ctx: ctx, thread: thread} do
      a = other_execution!(ctx)
      bounded!(ctx, thread, @keep_pair, %{lifecycle_kind: "execution", lifecycle_id: a})

      turn = accept!(ctx, thread, "@aqua keep a note")
      script!([calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}}])])

      assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
      {:ok, paused} = Tape.turn(ctx, turn.id)
      assert {:ok, [_card]} = Tape.pending_approvals(ctx, paused)
      assert %{status: "running"} = Arca.Repo.get(Arca.Schemas.Execution, a)
    end

    test "an allow for this execution, given after the turn began, is read as the call is made",
         %{ctx: ctx, thread: thread} do
      turn = accept!(ctx, thread, "@aqua keep a note")

      script!([
        {:probe, self()},
        calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}}]),
        reply("kept")
      ])

      task = run(ctx, turn)

      # The turn's policy was composed before this allow existed; the call
      # is decided from the rows as they stand when it is made.
      assert_receive {:scripted_probe, worker, _}, 10_000

      bounded!(ctx, thread, @keep_pair, %{
        lifecycle_kind: "execution",
        lifecycle_id: turn_root(ctx, turn),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

      send(worker, :continue)
      assert :completed = Task.await(task, 60_000)

      {:ok, steps} = Tape.steps(ctx, turn)

      assert %{dispatch_state: "closed", outcome: "ok", approval_id: nil} =
               Enum.find(steps, &(&1.action == "keep"))
    end

    test "a call after the allow's deadline asks", %{ctx: ctx, thread: thread} do
      turn = accept!(ctx, thread, "@aqua keep a note")

      bounded!(ctx, thread, @keep_pair, %{
        lifecycle_kind: "turn",
        lifecycle_id: turn.id,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

      # The deadline passes before the call is made.
      {1, _} =
        Arca.Repo.update_all(
          from(g in Arca.Schemas.ToolGrant, where: g.thread_id == ^thread.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      script!([calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}}])])

      assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
      {:ok, paused} = Tape.turn(ctx, turn.id)
      assert {:ok, [_card]} = Tape.pending_approvals(ctx, paused)
    end

    test "the decision and the dispatch recheck read the rows as they stand, and a deny stands",
         %{ctx: ctx, thread: thread} do
      turn = accept!(ctx, thread, "@aqua keep a note")
      a = other_execution!(ctx)

      {:ok, call} =
        Aqua.Loop.Binding.resolve("files", %{
          "action" => "write",
          "path" => "data/notes/a.md",
          "content" => "x"
        })

      policy = %{"files.write" => "ask"}

      place = [
        ctx: ctx,
        agent: "aqua",
        thread_id: thread.id,
        turn_id: turn.id,
        execution_id: a
      ]

      assert :ask = Aqua.Loop.Policy.decide(call, policy, place)
      refute Aqua.Loop.Policy.auto?(call, policy, place)

      bounded!(ctx, thread, %{tool: "files", action: "write"}, %{
        lifecycle_kind: "execution",
        lifecycle_id: a,
        constraint: %{kind: "storage_path", patterns: ["data/notes/"]}
      })

      assert :auto = Aqua.Loop.Policy.decide(call, policy, place)
      assert Aqua.Loop.Policy.auto?(call, policy, place)

      # Without its place a call is judged by no allow at all, and a
      # bounded allow never answers for a key the policy denies.
      assert :ask = Aqua.Loop.Policy.decide(call, policy, [])
      refute Aqua.Loop.Policy.auto?(call, policy, [])
      assert {:deny, _} = Aqua.Loop.Policy.decide(call, %{}, place)

      # Another agent's call, or this one once the execution ends, asks.
      assert :ask = Aqua.Loop.Policy.decide(call, policy, Keyword.put(place, :agent, "planner"))

      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.Execution, where: e.id == ^a),
          set: [status: "completed", completed_at: DateTime.utc_now(), duration_ms: 1]
        )

      refute Aqua.Loop.Policy.auto?(call, policy, place)

      # A standing deny outranks everything, whatever time passes.
      b = other_execution!(ctx)
      place = Keyword.put(place, :execution_id, b)

      bounded!(ctx, thread, %{tool: "files", action: "write"}, %{
        lifecycle_kind: "execution",
        lifecycle_id: b
      })

      assert :auto = Aqua.Loop.Policy.decide(call, policy, place)

      {:ok, _} =
        Aqua.ToolGrants.put(ctx, %{
          scope: "agent",
          effect: "deny",
          agent_name: "aqua",
          tool: "files",
          action: "write"
        })

      assert :ask = Aqua.Loop.Policy.decide(call, policy, place)
      refute Aqua.Loop.Policy.auto?(call, policy, place)

      {:ok, rows} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")
      assert Aqua.ToolGrants.resolve(%{"files.write" => "auto"}, rows)["files.write"] == "deny"
    end
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

    ScriptedWorker.script([{:probe, self()}, reply("ok, dropped")])

    resumed =
      Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end)

    assert_receive {:scripted_probe, worker, _}, 10_000

    %{input: %{"params" => %{"messages" => messages}}} =
      ScriptedWorker.calls() |> Enum.filter(&(&1.input["operation"] == "chat")) |> List.last()

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
      Enum.filter(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

    assert Jason.encode!(messages) =~ "one more thing"

    assert Enum.any?(
             Threads.messages(Sanctum.Context.actor(ctx), thread.id),
             &(&1.content == "and hi again")
           )
  end

  test "a steer names an open turn of its own thread", %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua hello")
    {:ok, elsewhere} = Threads.create(Sanctum.Context.actor(ctx))

    assert {:error, :turn_over} =
             Tape.accept(ctx, elsewhere.id, %{
               message: %{author: ctx.user_id, content: "wrong room"},
               steer_turn_id: turn.id
             })

    assert Threads.messages(Sanctum.Context.actor(ctx), elsewhere.id) == []
  end

  test "a policy refusal is the call's own result; a dead worker stops the turn, and the sender's next line continues it with reads only",
       %{ctx: ctx, thread: thread} do
    before = roots()
    turn = accept!(ctx, thread, "@aqua do things")

    start_supervised!(
      {ScriptedWorker, ref: [@model, "catalyst:local.http", "catalyst:local.files"], script: []}
    )

    ScriptedWorker.script([
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

    [row] =
      Enum.filter(
        Threads.messages(Sanctum.Context.actor(ctx), thread.id),
        &(&1.kind == "turn_aborted")
      )

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

    ScriptedWorker.script([
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

    {:ok, room} = Threads.create(Sanctum.Context.actor(ctx))

    {:ok, _} =
      Threads.append(Sanctum.Context.actor(ctx), room.id, %{
        author: ctx.user_id,
        content: "ROOM-ONLY-LINE"
      })

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua what did they say?"},
        turn: %{
          agent: "aqua",
          requested_by: ctx.user_id,
          options: %{"room" => %{"athanor_id" => ctx.athanor_id, "thread_id" => room.id}}
        }
      })

    script!([reply("They said hello.")])
    assert :completed = Task.await(run(ctx, turn), 60_000)

    assert %{execution_id: id, input: sent} =
             Enum.find(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

    assert Jason.encode!(sent) =~ "ROOM-ONLY-LINE"

    assert {:ok, %{retention_class: "chat_step"}, kept} =
             Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "input")

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
    start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.files"], script: []})

    # Two rounds, a retried third, then a card.
    ScriptedWorker.script([
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

    ScriptedWorker.script(
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

  test "a card expires when the athanor says, not after a day", %{ctx: ctx, thread: thread} do
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
    start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: []})

    ScriptedWorker.script([
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
        Threads.messages(Sanctum.Context.actor(ctx), thread.id),
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
    start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: []})

    ScriptedWorker.script([
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

    [row] =
      Enum.filter(
        Threads.messages(Sanctum.Context.actor(ctx), thread.id),
        &(&1.kind == "turn_aborted")
      )

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
    ScriptedWorker.script([{:refuse, %{"type" => "authentication", "message" => "no key"}}])
    result = Task.await(run(ctx, other), 60_000)

    assert {:failed, :setup_required} = result
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, other.id)
    assert_receive %ThreadEvent{kind: :consent_required, data: %{ref: ref, user_id: user}}, 5_000
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
    assert_receive %ThreadEvent{kind: :turn_finished}, 5_000

    {:ok, %{fence: fence}} = Tape.turn(ctx, turn.id)

    streamed =
      for event <- thread_events(drain()),
          match?({:turn_fence, %{turn_id: _, fence: _}}, event) or match?({:delta, _}, event) or
            match?({:delta_abandoned, _}, event) or
            match?({:message, %{kind: "text", author: "aqua"}}, event),
          do: event

    assert [
             {:turn_fence, %{turn_id: ^turn_id, fence: ^fence}},
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

    events = for event <- thread_events(drain()), do: event
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

  test "a stream cut short is retried, and the thread and its answer hold the retry's text once",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua hello")

    script!([
      {:emit, [%{"type" => "text.delta", "text" => "the ans"}]},
      {:refuse, %{"type" => "incomplete_stream", "message" => "the stream ended early"}},
      {:emit,
       [
         %{"type" => "text.delta", "text" => "the "},
         %{"type" => "text.delta", "text" => "answer"}
       ]},
      reply("the answer")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)

    assert {:ok,
            [
              %{kind: "model", outcome: "error", error: "incomplete_stream"} = cut,
              %{kind: "model", outcome: "ok"} = retried
            ]} = Tape.steps(ctx, turn)

    events = for event <- thread_events(drain()), do: event
    deltas = for {:delta, delta} <- events, do: delta

    # The attempt's masking holdback may re-chunk a step's text; each step's
    # deltas arrive together, the cut step's first.
    assert [{cut_step, cut_deltas}, {retry_step, retry_deltas}] =
             Enum.chunk_by(deltas, & &1.step_id) |> Enum.map(&{hd(&1).step_id, &1})

    assert Enum.map_join(cut_deltas, & &1.text) == "the ans"
    assert Enum.map_join(retry_deltas, & &1.text) == "the answer"
    assert cut_step == cut.id and retry_step == retried.id
    assert hd(retry_deltas).ordinal > hd(cut_deltas).ordinal
    assert [%{step_id: ^cut_step}] = for({:delta_abandoned, marker} <- events, do: marker)

    # A viewer following the thread keeps only the retry's answer while it
    # streams, and nothing once its row lands.
    {streaming, [landed | _]} =
      Enum.split_while(events, &(not match?({:message, %{kind: "text", author: "aqua"}}, &1)))

    assert [%{step_id: ^retry_step, text: "the answer"}] =
             Aqua.Loop.Stream.texts(keep(streaming))

    assert Aqua.Loop.Stream.texts(keep(streaming ++ [landed])) == []

    assert [%{content: "the answer"} = row] =
             Enum.filter(
               Threads.messages(Sanctum.Context.actor(ctx), thread.id),
               &(&1.kind == "text" and &1.author == "aqua")
             )

    assert Tape.payload(row)["step_id"] == retry_step
  end

  test "a model its catalyst does not know ends the turn before any request, and a missing key asks for setup",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua hello")

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [],
       describe: {:refuse, %{"type" => "unknown_model", "message" => "not a model"}}}
    )

    assert {:failed, {:unknown_model, _}} = Task.await(run(ctx, turn), 30_000)
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, turn.id)
    refute Enum.any?(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

    stop_supervised!(ScriptedWorker)

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [],
       describe: {:refuse, %{"type" => "secret_denied", "message" => "no key"}}}
    )

    other = accept!(ctx, thread, "@aqua again")
    assert {:failed, :setup_required} = Task.await(run(ctx, other), 30_000)
    assert_receive %ThreadEvent{kind: :consent_required, data: %{ref: ref, user_id: user}}, 5_000
    assert ref =~ @model and user == ctx.user_id
  end

  test "the step cap ends a turn that never stops calling", %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua loop forever")
    script!(List.duplicate(calls([{"u", "ui", %{"kind" => "ui.overlay.close"}}]), 40))
    assert {:failed, :step_cap} = Task.await(run(ctx, turn), 120_000)
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, turn.id)

    assert_receive %ThreadEvent{
                     kind: :intents,
                     data: %{intents: [%{kind: "overlay_close"}], user_id: _}
                   },
                   5_000
  end

  defp turn_root(ctx, turn) do
    {:ok, %{root_execution_id: root}} = Tape.turn(ctx, turn.id)
    root
  end

  # ---------------------------------------------------------------------------
  # Launches
  # ---------------------------------------------------------------------------

  @math_wasm Path.expand("../../support/test_wasm/math.wasm", __DIR__)

  # An app of the person's own whose own calls carry one credential need,
  # disclosed to it, granted with a default entry alone.
  defp launchable_app!(ctx) do
    name = "named-app-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "reagent",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API",
          "fields" => ["KEY"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    ref = "reagent:local." <> name
    default = disclosed_entry!(ctx, "#{name} default")
    profile_id = walk!(ctx, %{ref: ref, bindings: [%{need: "api_key", entry_id: default.id}]})
    %{ref: ref, profile_id: profile_id, default: default}
  end

  defp disclosed_entry!(ctx, name) do
    {:ok, view} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: name,
        kind: "api_key",
        provider_hint: "example.com",
        fields: %{"KEY" => "k-#{name}"},
        destination: %{"hosts" => ["api.example.com"]},
        disclose: true
      })

    view
  end

  # A grant through the consent walk, as a person makes it.
  defp walk!(ctx, decisions) do
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, Map.take(decisions, [:ref, :label]))
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, %{profile_id: profile_id}} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    profile_id
  end

  # A seated member other than the sender, whose approval a launch runs as.
  defp approver!(ctx) do
    n = System.unique_integer([:positive])

    {:ok, approver} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|launch-approver#{n}",
        provider: "github",
        email: "launch-approver#{n}@example.com",
        verified: true,
        name: "Approver"
      })

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(approver.id, scope: "athanor", athanor_id: ctx.athanor_id)

    %{ctx | user_id: approver.id}
  end

  defp pins(turn),
    do: Map.take(turn, [:profile_id, :consent_id, :agent_capability_digest, :root_execution_id])

  test "a named-account grant leaves the running turn pinned and only a new turn uses it", %{
    ctx: ctx,
    thread: thread
  } do
    %{ref: app, default: default} = launchable_app!(ctx)
    versioned = app <> ":1.0.0"
    {:ok, app_name} = Prima.ComponentRef.to_name_ref(app)

    launch = fn id ->
      calls([
        {id, "execution.run",
         %{"reference" => versioned, "input" => %{}, "connection" => "Supabase 2"}}
      ])
    end

    start_supervised!(
      {ScriptedWorker,
       ref: [@model, app],
       script: [launch.("c1"), launch.("c2"), %{"answered" => true}, reply("launched")]}
    )

    # The app's profile binds no "Supabase 2": the launch ends its turn as
    # setup required, naming the app and the account, never an entry.
    first = accept!(ctx, thread, "@aqua run it as Supabase 2")

    assert {:failed, {:setup_required, {^versioned, nil, "Supabase 2"}}} =
             Task.await(run(ctx, first), 60_000)

    # It names the ended turn's own message, the one a retry sends again.
    first_message = first.message_id

    assert_receive %ThreadEvent{
                     kind: :consent_required,
                     data: %{
                       ref: ^versioned,
                       account: %{name: "Supabase 2", need: nil},
                       message_id: ^first_message
                     }
                   },
                   5_000

    assert is_binary(first_message)

    {:ok, ended} = Tape.turn(ctx, first.id)
    assert %{status: "failed", error: error} = ended
    assert error =~ "Supabase 2" and error =~ app

    {:ok, steps} = Tape.steps(ctx, ended)

    assert %{dispatch_state: "closed", outcome: "denied", error: said} =
             Enum.find(steps, &(&1.kind == "launch"))

    assert said =~ "Supabase 2"
    refute said =~ default.id
    refute Enum.any?(ScriptedWorker.calls(), &(&1.input == %{}))

    pinned = pins(ended)
    {:ok, soul_before} = Crucible.authority_for(ctx, {:id, ended.profile_id}, @soul)

    # The person grants "Supabase 2" on the app's own profile.
    supabase = disclosed_entry!(ctx, "#{app} supabase 2")

    walk!(ctx, %{
      ref: app,
      bindings: [
        %{need: "api_key", entry_id: default.id},
        %{need: "api_key", name: "Supabase 2", entry_id: supabase.id}
      ]
    })

    # The ended turn's pinned authority is what it was: the grant is the
    # app's, never the turn's.
    {:ok, after_grant} = Tape.turn(ctx, first.id)
    assert pins(after_grant) == pinned
    assert after_grant.status == "failed"
    {:ok, soul_after} = Crucible.authority_for(ctx, {:id, ended.profile_id}, @soul)
    assert soul_before.consent_id == ended.consent_id
    assert soul_after.consent_id == ended.consent_id
    assert soul_after.resources == soul_before.resources

    # The retry is a new turn: its launch asks, its card binding the entry
    # "Supabase 2" resolves to now.
    second = accept!(ctx, thread, "@aqua run it as Supabase 2 again")
    refute second.id == first.id
    assert {:paused, :approval} = Task.await(run(ctx, second), 60_000)

    {:ok, paused} = Tape.turn(ctx, second.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, card} = Tape.message(ctx, approval.message_id)

    assert %{
             "standing" => false,
             "proposal" => %{
               "args" => %{"connection" => "Supabase 2"},
               "vault_entry" => vault_entry
             }
           } = Tape.payload(card)["intent"]

    assert vault_entry == supabase.id

    assert {:ok, %{decision: "approved", resolution_kind: "launch"}} =
             Approvals.resolve(approver!(ctx), approval.id, %{decision: :approved})

    assert :completed =
             Task.await(
               Task.async(fn ->
                 Aqua.Loop.run_nested(ctx: ctx, turn_id: second.id, mode: :resume)
               end),
               60_000
             )

    # The new turn's launch rooted the app under the named binding, by its
    # own key.
    assert [%{authority: launched}] = Enum.filter(ScriptedWorker.calls(), &(&1.input == %{}))
    assert launched.resources.vault.entry_id == supabase.id

    assert launched.resources.vault.binding_key ==
             Prima.Authority.Blob.binding_key(app_name, "@ingress", "Supabase 2")

    {:ok, steps} = Tape.steps(ctx, second)
    assert %{dispatch_state: "closed", outcome: "ok"} = Enum.find(steps, &(&1.kind == "launch"))
  end

  # The account a card bound is read again before the launch runs. A head
  # stored damaged since the card was drawn closes the launch's step in the
  # damaged head's sentence, never a stale approval and never an outcome
  # that could not be confirmed: the thread's row the pane draws, and what
  # an MCP client reads of the thread (`thread.messages`, since no tool
  # dispatches a launch), carry it. Nothing of the app starts.
  test "a launch whose app's own head is stored damaged after its card was drawn says so in " <>
         "the thread, and starts nothing",
       %{ctx: ctx, thread: thread} do
    %{ref: app, profile_id: profile_id, default: default} = launchable_app!(ctx)
    work = disclosed_entry!(ctx, "#{app} work")

    walk!(ctx, %{
      ref: app,
      bindings: [
        %{need: "api_key", entry_id: default.id},
        %{need: "api_key", name: "Work", entry_id: work.id}
      ]
    })

    start_supervised!(
      {ScriptedWorker,
       ref: [@model, app],
       script: [
         calls([
           {"c1", "execution.run",
            %{"reference" => app <> ":1.0.0", "input" => %{}, "connection" => "Work"}}
         ]),
         reply("not launched")
       ]}
    )

    turn = accept!(ctx, thread, "@aqua run it as Work")
    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
    {:ok, paused} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)

    :ok =
      Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile_id,
        blob_digest: "sha256:" <> String.duplicate("0", 64)
      )

    assert {:ok, %{decision: "approved", resolution_kind: "launch"}} =
             Approvals.resolve(approver!(ctx), approval.id, %{decision: :approved})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :completed =
                 Task.await(
                   Task.async(fn ->
                     Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume)
                   end),
                   60_000
                 )
      end)

    sentence =
      "This app's consent is damaged and cannot be used — revoke profile #{profile_id} " <>
        "and grant it again."

    # Nothing of the app started: no run of it, and no row.
    refute Enum.any?(ScriptedWorker.calls(), &(&1.input == %{}))

    assert Arca.Repo.all(
             from(e in Arca.Schemas.Execution,
               where: e.athanor_id == ^ctx.athanor_id and like(e.reference, ^"#{app}%"),
               select: e.id
             )
           ) == []

    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{dispatch_state: "closed", outcome: "error", result_message_id: result} =
             Enum.find(steps, &(&1.kind == "launch"))

    # The thread's row the pane draws, and what an MCP client reads of the
    # same row, say the damaged head in the same words.
    assert {:ok, %{kind: "tool_result", content: shown}} = Tape.message(ctx, result)

    assert %{"kind" => "tool_result", "content" => read} =
             mcp_thread_messages(ctx, thread) |> Enum.find(&(&1["id"] == result))

    assert {shown, read} == {sentence, sentence}

    # Nothing read the refusal as a reason the refusal table does not know.
    refute log =~ "Prima.Refusal"
  end

  # What an MCP client reads of `thread` (`thread.messages`, through the
  # router as the transport dispatches it): its rows, decoded from the
  # tool result's one text block.
  defp mcp_thread_messages(ctx, thread) do
    message = %Prima.MCP.Message{
      type: :request,
      id: 1,
      method: "tools/call",
      params: %{
        "name" => "thread",
        "arguments" => %{"action" => "messages", "thread" => thread.id}
      }
    }

    assert {:ok, %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]}} =
             Emissary.MCP.Router.dispatch(ctx, message)

    Jason.decode!(text)["messages"]
  end

  test "a launch the soul's own policy runs at once still asks, and never answers not approved",
       %{ctx: ctx, thread: thread} do
    # The soul's own definition says execution.run runs at once, and its
    # grant is walked again for the shape that moved.
    {:ok, _} =
      Aqua.AgentConfig.call_aqua(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "tool_policy_patch" => %{"execution.run" => "auto"}
      })

    walk!(ctx, %{ref: @soul, selections: [%{dep: "catalyst:local.claude", label: "default"}]})

    turn = accept!(ctx, thread, "@aqua launch the model")

    # The model's catalyst is on the soul's own edge: consented and untouched.
    script!([
      calls([{"c1", "execution.run", %{"reference" => @model, "input" => %{}}}]),
      reply("done")
    ])

    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
    {:ok, paused} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, steps} = Tape.steps(ctx, paused)

    assert %{dispatch_state: "proposed", approval_id: approval_id} =
             Enum.find(steps, &(&1.kind == "launch"))

    assert approval_id == approval.id
  end

  test "a standing allow on execution.run stored for the thread still asks before a launch",
       %{ctx: ctx, thread: thread} do
    # A row written past the rule that now refuses it, as one written
    # before execution.run declared it takes no standing answer.
    {:ok, _} =
      Arca.ToolGrantStorage.put(%{
        athanor_id: ctx.athanor_id,
        scope: "thread",
        effect: "allow",
        thread_id: thread.id,
        agent_name: "aqua",
        tool: "execution",
        action: "run",
        granted_by: ctx.user_id
      })

    turn = accept!(ctx, thread, "@aqua launch the model")

    script!([
      calls([{"c1", "execution.run", %{"reference" => @model, "input" => %{}}}]),
      reply("done")
    ])

    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
    {:ok, paused} = Tape.turn(ctx, turn.id)
    assert {:ok, [_card]} = Tape.pending_approvals(ctx, paused)
    {:ok, steps} = Tape.steps(ctx, paused)
    assert %{dispatch_state: "proposed"} = Enum.find(steps, &(&1.kind == "launch"))
  end

  test "a launch by an agent whose policy names no execution.run is denied, and opens no card",
       %{ctx: ctx, thread: thread} do
    # The soul's own definition stops naming execution.run, and its grant
    # is walked again for the shape that moved.
    {:ok, _} =
      Aqua.AgentConfig.call_aqua(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "tool_policy_patch" => %{"execution.run" => nil}
      })

    walk!(ctx, %{ref: @soul, selections: [%{dep: "catalyst:local.claude", label: "default"}]})

    turn = accept!(ctx, thread, "@aqua launch the model")

    script!([
      calls([{"c1", "execution.run", %{"reference" => @model, "input" => %{}}}]),
      reply("not launched")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)
    {:ok, ended} = Tape.turn(ctx, turn.id)
    assert {:ok, []} = Tape.pending_approvals(ctx, ended)
    {:ok, steps} = Tape.steps(ctx, ended)

    assert %{dispatch_state: "closed", outcome: "denied", approval_id: nil} =
             launch = Enum.find(steps, &(&1.kind == "launch"))

    assert {:ok, %{content: said}} = Tape.message(ctx, launch.result_message_id)
    assert said =~ "execution.run is not in the agent's policy"
    refute Enum.any?(ScriptedWorker.calls(), &(&1.input == %{}))
  end
end
