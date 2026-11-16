# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.LoopTest.CountStore do
  @moduledoc false
  # The local adapter, telling the process `observer/0` names of every
  # listing of a post's folder (`threads/<thread>/<message>`).
  use Arca.Storage.TestDouble

  @observer {__MODULE__, :observer}

  def observer, do: @observer

  def list_typed(actor, ["threads", _thread, _message] = path) do
    send(:persistent_term.get(@observer), {:listed, path})
    Arca.Adapters.Local.list_typed(actor, path)
  end

  def list_typed(actor, path), do: Arca.Adapters.Local.list_typed(actor, path)
end

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
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aqua.{Approvals, Tape}
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.{Bootstrap}

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    # The test's storage is the tree of an athanor minted for it alone,
    # under the partition's storage root: nothing else names the tree, and
    # it is removed, and nothing else, when the test ends. The athanor is
    # its person's own, who sends the turns and decides their cards.
    ctx = person!()
    tree = own_tree!(ctx)
    keys = [cyfr: :locus_runtime_workers]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    on_exit(fn ->
      File.rm_rf!(tree)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    # The shipped catalysts the turns run on, in a seed of this test's own;
    # the suite's own carries none.
    Cyfr.Test.SeedBundle.lay!(~w(claude files http openai claude-code openai-codex))

    # The loops' work stops before their tree is removed and the seed tree restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    # The model catalyst unseals its key when its runner attaches.
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    :ok = Aqua.Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, thread: thread}
  end

  # A person minted for the test with their own athanor, signed in
  # through Prism.
  defp person! do
    n = System.unique_integer([:positive])

    {:ok, person} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|loop#{n}",
        provider: "github",
        email: "loop#{n}@example.com",
        verified: true,
        name: "Loop"
      })

    %{
      Sanctum.TestContext.local(:prism)
      | user_id: person.id,
        athanor_id: Sanctum.Test.People.athanor!(person).id
    }
  end

  # The athanor's tree under the partition's storage root, which no earlier
  # test may have left behind: an athanor whose tree already exists is not
  # this test's alone.
  defp own_tree!(ctx) do
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    refute File.exists?(tree), "#{ctx.athanor_id}'s tree is left from another test"
    tree
  end

  test "a turn refused its root for ownership reads the retry sentence and can be sent again",
       %{ctx: ctx, thread: thread} do
    # This server has lost its slot: the root's admission is refused.
    Arca.ControlPlane.record(:lost)
    on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)

    turn = accept!(ctx, thread, "hello")
    assert {:failed, :not_owner} = Aqua.Loop.run(ctx: ctx, turn_id: turn.id)
    {:ok, ended} = Tape.turn(ctx, turn.id)
    assert %{status: "failed", error: error} = ended
    assert error == Prima.Refusal.message(:not_owner)
    assert error =~ "retry shortly"

    # The slot is back: the same message, sent again, runs.
    Arca.ControlPlane.record(:unclaimed)
    script!([reply("hi")])
    again = accept!(ctx, thread, "hello")
    assert :completed = Task.await(run(ctx, again), 30_000)
  end

  test "the catalyst's consented cap answers to a name, not to the ref the spec carries", %{
    ctx: ctx
  } do
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)

    # What `Aqua.AgentConfig` resolves, and so what the spec holds.
    versioned = @model <> ":1.4.3"
    {:ok, name_ref} = Prima.ComponentRef.to_name_ref(versioned)

    # The graph is keyed the way `Opus.Admission` steps: by name. Asking with
    # the version answers nothing, and a cap of nil is a size check that
    # never fires.
    assert {:error, :unknown_node} = Prima.Authority.node_limits(authority, versioned)

    assert {:ok, %Prima.Limits{max_request_size: cap}} =
             Prima.Authority.node_limits(authority, name_ref)

    assert is_integer(cap) and cap > 0
  end

  test "the spec a turn runs on carries the cap its catalyst is consented at", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept!(ctx, thread, "hello")
    script!([reply("hi")])
    assert :completed = Task.await(run(ctx, turn), 30_000)

    {:ok, pinned} = Tape.turn(ctx, turn.id)
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)
    {:ok, spec} = Aqua.Loop.Turn.build(ctx, pinned, authority: authority, excerpt?: false)

    # The spec holds a versioned ref, and the graph is keyed by name. Read
    # with what the spec holds, the cap is nil and the size trigger never
    # fires, which from outside looks like a request that fits.
    assert String.starts_with?(spec.catalyst, @model <> ":")
    assert is_integer(spec.request_cap) and spec.request_cap > 0
  end

  test "the spec a turn runs on names its root run's admission as the parent call of its calls",
       %{ctx: ctx, thread: thread} do
    # The gate names the admission a run starts under in its context; the
    # turn's root row takes it from there.
    ctx = %{ctx | call_id: "call_turn_root_admission"}
    turn = accept!(ctx, thread, "hello")
    script!([reply("hi")])
    assert :completed = Task.await(run(ctx, turn), 30_000)

    {:ok, pinned} = Tape.turn(ctx, turn.id)
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)
    {:ok, spec} = Aqua.Loop.Turn.build(ctx, pinned, authority: authority, excerpt?: false)

    root =
      Arca.Repo.one!(
        from(e in "executions", where: e.id == ^pinned.root_execution_id, select: e.call_id)
      )

    assert {root, spec.call_id} == {"call_turn_root_admission", "call_turn_root_admission"}
  end

  test "a turn lasts at least one answer of its brain, at the time the brain's node is consented",
       %{ctx: ctx, thread: thread} do
    # The soul's brain is consented three minutes, under the agent's own
    # time: the turn keeps the agent's.
    turn = accept!(ctx, thread, "hello")
    script!([reply("hi")])
    assert :completed = Task.await(run(ctx, turn), 30_000)

    {:ok, pinned} = Tape.turn(ctx, turn.id)
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)
    {:ok, spec} = Aqua.Loop.Turn.build(ctx, pinned, authority: authority, excerpt?: false)
    {:ok, own} = Prima.Limits.timeout_ms(Prima.Authority.limits(authority))
    {:ok, name_ref} = Prima.ComponentRef.to_name_ref(spec.catalyst)
    {:ok, brain} = Prima.Authority.node_limits(authority, name_ref)
    assert Prima.Limits.timeout_ms(brain) == {:ok, 3 * 60_000}
    assert own > 3 * 60_000
    assert spec.deadline_ms == own

    # A harness's brain ships consented thirty minutes, past its member's
    # own time: the deadline its member's runs are admitted at, which its
    # turns last at least as long as (a turn of the member itself needs its
    # sign-in, which no test holds; `Aqua.Loop.ModelWaitTest` runs a turn on
    # a brain consented as long).
    for harness <- ~w(claude-code openai-codex) do
      {:ok, authority} = Opus.authority_for(ctx, :default, "agent:local.#{harness}")
      {:ok, own} = Prima.Limits.timeout_ms(Prima.Authority.limits(authority))
      {:ok, brain} = Prima.Authority.node_limits(authority, "catalyst:local.#{harness}")
      assert own < 30 * 60_000
      assert Prima.Limits.timeout_ms(brain) == {:ok, 30 * 60_000}
    end
  end

  test "a turn that pins no agent revision is refused, never run on the roster's entry", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept!(ctx, thread, "hello")
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)

    assert {:error, :no_pin} =
             Aqua.Loop.Turn.build(ctx, turn, authority: authority, excerpt?: false)
  end

  test "a daily and a workspace thread's prompt lists the requests still waiting in it, and no other's",
       %{ctx: ctx, thread: daily} do
    workspace =
      %Arca.Schemas.Thread{}
      |> Arca.Schemas.Thread.changeset(%{
        id: Prima.UUID7.generate_id("thread"),
        athanor_id: ctx.athanor_id,
        kind: "workspace",
        workspace_state: "open",
        title: "Book the trip",
        created_by: ctx.user_id
      })
      |> Arca.Repo.insert!()

    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)
    script!([reply("one"), reply("two")])

    asked =
      for {room, task} <- [{daily, "Weigh the daily risks"}, {workspace, "Price the flights"}] do
        turn = accept!(ctx, room, "hello")
        assert :completed = Task.await(run(ctx, turn), 30_000)

        # The soul's request to a crew member, still waiting on its reply.
        {:ok, %{message: request}} =
          Tape.accept(ctx, room.id, %{
            message: %{
              author: Prima.Author.agent(),
              sent_by: "aqua",
              addressee: "planner",
              status: "pending",
              content: task
            }
          })

        {turn, request, task}
      end

    # Each room's prompt, read once both requests wait, lists its own.
    for {turn, request, task} <- asked do
      {:ok, pinned} = Tape.turn(ctx, turn.id)
      {:ok, spec} = Aqua.Loop.Turn.build(ctx, pinned, authority: authority, excerpt?: false)

      assert spec.system =~ "## Open requests"
      assert spec.system =~ "- #{request.id} to planner, asked by aqua"
      assert spec.system =~ task

      for {_turn, other, other_task} <- asked, other.id != request.id do
        refute spec.system =~ other.id
        refute spec.system =~ other_task
      end
    end
  end

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
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

  defp roots, do: Prima.Slots.status(Opus.Slots).root_active

  test "request_setup.open opens the setup form for its component and the turn goes on",
       %{ctx: ctx, thread: thread} do
    ref = "catalyst:local.claude:1.4.3"

    script!([
      calls([{"c1", "request_setup", %{"action" => "open", "component_ref" => ref}}]),
      reply("ok")
    ])

    turn = accept!(ctx, thread, "set up the model")
    assert :completed = Task.await(run(ctx, turn), 30_000)
    user = ctx.user_id

    assert_receive %ThreadEvent{kind: :consent_required, data: %{ref: ^ref, user_id: ^user}},
                   5_000

    {:ok, steps} = Tape.steps(ctx, turn)
    assert %{outcome: "ok"} = Enum.find(steps, &(&1.kind == "ui"))
  end

  test "a later turn reads that a file of an earlier post was deleted from Files, and runs",
       %{ctx: ctx, thread: thread} do
    id = Prima.UUID7.generate_id("msg")

    {:ok, refs} =
      Aqua.Attachments.store(ctx, thread.id, id, [
        %{"filename" => "moon.png", "media_type" => "image/png", "bytes" => "PNG"},
        %{"filename" => "notes.txt", "media_type" => "text/plain", "bytes" => "notes"}
      ])

    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{
          id: id,
          author: ctx.user_id,
          sent_by: "person",
          content: "the moon tonight",
          payload: %{"attachments" => refs}
        }
      })

    [moon, _notes] = refs

    {:ok, _} =
      Arca.Files.delete(
        Sanctum.Context.actor(ctx),
        "threads/#{thread.id}/#{id}/#{moon["stored_name"]}"
      )

    script!([reply("noted")])
    turn = accept!(ctx, thread, "what did I send?")
    assert :completed = Task.await(run(ctx, turn), 30_000)

    %{input: %{"params" => %{"messages" => messages}}} =
      Enum.find(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

    texts = for m <- messages, b <- List.wrap(m["content"]), is_binary(b["text"]), do: b["text"]

    assert Enum.filter(texts, &(&1 =~ "can no longer be read")) == [
             "[The person deleted these files of posts in this thread; they can no longer " <>
               "be read: moon.png]"
           ]

    refute Enum.any?(texts, &(&1 =~ "notes.txt"))
  end

  # Astra's cost probe (#4046): what a round reads of storage for the files
  # of the posts its request carries, and none for those it does not.
  describe "the listings a model round makes" do
    setup %{ctx: ctx, thread: thread} do
      actor = Sanctum.Context.actor(ctx)

      for n <- 1..50 do
        id = Prima.UUID7.generate_id("msg")
        file = %{"filename" => "old.txt", "media_type" => "text/plain", "bytes" => "old"}
        {:ok, refs} = Aqua.Attachments.store(ctx, thread.id, id, [file])

        {:ok, _} =
          Threads.append(actor, thread.id, %{
            id: id,
            author: ctx.user_id,
            sent_by: "person",
            content: "old-post-#{n}",
            payload: %{"attachments" => refs}
          })
      end

      :ok
    end

    test "fifty posts the request carries are each listed once", %{ctx: ctx, thread: thread} do
      count_listings!()
      script!([reply("done")])
      turn = accept!(ctx, thread, "continue")
      assert :completed = Task.await(run(ctx, turn), 30_000)
      assert [_one] = Enum.filter(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))
      assert listings() == 50
    end

    test "fifty posts behind a compaction are not listed", %{ctx: ctx, thread: thread} do
      {:ok, _} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: Prima.Author.system(),
          sent_by: "aqua",
          kind: "compaction",
          content: "Earlier posts summarized",
          payload: %{"first_kept_seq" => 52, "summarized_through_seq" => 50}
        })

      count_listings!()
      script!([reply("done")])
      turn = accept!(ctx, thread, "continue")
      assert :completed = Task.await(run(ctx, turn), 30_000)

      %{input: %{"params" => %{"messages" => messages}}} =
        Enum.find(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

      refute Jason.encode!(messages) =~ "old-post-"
      assert listings() == 0
    end
  end

  defp count_listings! do
    Prima.Test.Env.put_app_env(:arca, :storage_adapter, Aqua.LoopTest.CountStore)
    Prima.Test.Env.put_persistent_term(Aqua.LoopTest.CountStore.observer(), self())
  end

  defp listings(n \\ 0) do
    receive do
      {:listed, _path} -> listings(n + 1)
    after
      0 -> n
    end
  end

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
    holders = Prima.Slots.status(Opus.Slots).holders
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

  test "the keeper renews nothing from the turn's terminal write until the release stops it", %{
    ctx: ctx,
    thread: thread
  } do
    script!([])
    Cyfr.Test.KeeperProbe.watch()

    keeper_suspended_at_end!(fn ->
      turn = accept!(ctx, thread, "@aqua hello")
      ScriptedWorker.script([reply("hi there")])
      assert :completed = Task.await(run(ctx, turn), 30_000)
    end)
  end

  test "a turn that never ran ends with its keeper suspended too", %{ctx: ctx, thread: thread} do
    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [],
       describe: {:refuse, %{"type" => "unknown_model", "message" => "not a model"}}}
    )

    Cyfr.Test.KeeperProbe.watch()

    keeper_suspended_at_end!(fn ->
      turn = accept!(ctx, thread, "@aqua hello")
      assert {:failed, {:unknown_model, _}} = Task.await(run(ctx, turn), 30_000)
    end)
  end

  @keeper_runs 5

  # Runs `scenario`, a fresh turn each time, until the probe reads the one
  # attempt-ending write's keeper as suspended. The probe answers `:unknown`
  # when its look ran out before the keeper settled, which says neither, so
  # the scenario runs again, at most `@keeper_runs` times; `:renewing`, or
  # any other count of writes, fails at once.
  defp keeper_suspended_at_end!(scenario, seen \\ []) do
    scenario.()

    case attempt_endings() do
      [:suspended] ->
        :ok

      [:unknown] = observed when length(seen) + 1 < @keeper_runs ->
        keeper_suspended_at_end!(scenario, [observed | seen])

      [:unknown] = observed ->
        flunk(
          "the keeper's state at the attempt's end stayed inconclusive over " <>
            "#{@keeper_runs} runs: #{inspect(Enum.reverse([observed | seen]))}"
        )

      observed ->
        flunk(
          "expected one attempt-ending write with its keeper suspended, read #{inspect(observed)}"
        )
    end
  end

  defp attempt_endings do
    receive do
      {:attempt_ended, state} -> [state | attempt_endings()]
    after
      0 -> []
    end
  end

  # The files hand is not scripted: it runs on the runtime's worker service.
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

  # The files hand is not scripted: it runs on the runtime's worker service.
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

    # The approved call ran on the guest plane, the one way into it: only
    # there does a kept note's provenance come from the host's lineage,
    # never from the call's own arguments.
    thread_id = thread.id
    assert {:ok, %{thread: ^thread_id, execution: ^root}} = Aqua.Notes.read(ctx, "n")

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

  # An approval unblocks a call the chain's authority allows and grants
  # nothing more (§5.4): the approved call still goes through the gate, in
  # the chain, under the authority as it stands when the call is made.
  test "an approved call whose authority was withdrawn before the resume is refused at the gate",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua keep a note")

    script!([
      calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "remember"}}])
    ])

    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
    {:ok, paused} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})

    # The invoke budget the call needs is withdrawn: the turn's
    # reservation admits no further charge.
    {1, _} =
      Arca.Repo.update_all(
        from(r in Arca.Schemas.BudgetReservation, where: r.id == ^paused.budget_id),
        set: [cap: 0]
      )

    actor = Sanctum.Context.actor(ctx)
    {:ok, refused_before} = Arca.DecisionLog.list(actor, tool: "notes", admission: :refused)

    Task.await(
      Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end),
      60_000
    )

    {:ok, steps} = Tape.steps(ctx, paused)

    assert %{dispatch_state: "closed", outcome: "denied"} =
             Enum.find(steps, &(&1.action == "keep"))

    assert {:error, _} = Aqua.Notes.read(ctx, "n")

    # The refusal is the chain's: the one authority refusal of a notes call
    # the resume made, decided in the chain. The turn's root records no
    # admission call here, so the decision's parent is nil and names
    # nothing; the call's request-log row carries the host-stamped lineage
    # the gate judged it under, which names this turn's root and thread.
    {:ok, refused} = Arca.DecisionLog.list(actor, tool: "notes", admission: :refused)
    user_id = ctx.user_id

    assert [
             %Prima.Decision{
               call_id: call_id,
               plane: :in_chain,
               action: "keep",
               user_id: ^user_id,
               refusal_class: :forbidden
             }
           ] = refused -- refused_before

    root = paused.root_execution_id
    thread_id = thread.id
    assert is_binary(root) and is_binary(thread_id)
    %Arca.Schemas.McpLog{input: input} = Arca.Repo.get(Arca.Schemas.McpLog, call_id)

    assert %{"root_execution_id" => ^root, "thread_id" => ^thread_id} = Jason.decode!(input)
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
               "catalyst:local.openai:1.4.3",
               %{
                 fence: paused.fence
               }
             )

    # A spec is built on the pinned release alone, and only on one that
    # speaks the chat contract.
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)

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

    {:ok, _} = Sanctum.ToolGrants.put(ctx, Map.put(grant, :effect, "allow"))

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

    assert {:paused, :approval} = Task.await(task, 60_000)

    {:ok, steps} = Tape.steps(ctx, turn)
    assert %{outcome: outcome} = Enum.find(steps, &(&1.kind == "tool"))
    refute outcome == "ok"
  end

  describe "a bounded standing allow" do
    # A standing allow bound to a lifecycle, a deadline or some paths: the
    # guest reads its pair as a question, and each call runs at once only
    # when the rows as they stand when it is decided cover it.

    defp bounded!(ctx, thread, pair, bounds) do
      {:ok, _} =
        Sanctum.ToolGrants.put(
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

    # The files hand is not scripted: it runs on the runtime's worker service.
    test "an allow for this execution and data/notes/ runs a write there and asks for one elsewhere",
         %{ctx: ctx, thread: thread} do
      notes = %{kind: "storage_path", patterns: ["data/notes/"]}

      # An answer given for another run, still going: it puts files.write
      # in the turn's policy as a question, and covers none of this turn's
      # calls.
      a = other_execution!(ctx)

      {:ok, _} =
        Sanctum.ToolGrants.put(ctx, %{
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
        Sanctum.ToolGrants.put(ctx, %{
          scope: "agent",
          effect: "deny",
          agent_name: "aqua",
          tool: "files",
          action: "write"
        })

      assert :ask = Aqua.Loop.Policy.decide(call, policy, place)
      refute Aqua.Loop.Policy.auto?(call, policy, place)

      {:ok, rows} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

      assert Aqua.ToolGrants.resolve(%{"files.write" => "auto"}, rows, {:ok, true})["files.write"] ==
               "deny"
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
        message: %{author: ctx.user_id, sent_by: "person", content: "actually, never mind"},
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
        message: %{author: ctx.user_id, sent_by: "person", content: "one more thing"},
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
    {:ok, elsewhere} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))

    assert {:error, :turn_over} =
             Tape.accept(ctx, elsewhere.id, %{
               message: %{author: ctx.user_id, sent_by: "person", content: "wrong room"},
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
        message: %{author: ctx.user_id, sent_by: "person", content: "carry on, carefully"},
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

  test "the shared thread's excerpt reaches the model and never the retained input", %{
    ctx: ctx,
    thread: thread
  } do
    # The shared thread is read under the person's own seat in it.
    {:ok, beside} = Sanctum.SharedThreads.create(ctx.user_id, "Beside")
    {:ok, _} = Sanctum.SharedThreads.post(ctx.user_id, beside.id, "ROOM-ONLY-LINE")

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua what did they say?"},
        turn: %{
          agent: "aqua",
          requested_by: ctx.user_id,
          options: %{"room" => %{"shared_thread_id" => beside.id, "title" => "Beside"}}
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

  test "a rate limit is retried; a refused key is a line in the provider's words and asks " <>
         "for no grant, while a key not bound asks for setup",
       %{
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

    _ = drain()
    refused = accept!(ctx, thread, "@aqua again")

    ScriptedWorker.script([
      {:refuse, %{"type" => "authentication", "message" => "invalid x-api-key"}}
    ])

    line = "The model refused its key: invalid x-api-key"
    assert {:failed, ^line} = Task.await(run(ctx, refused), 60_000)
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, refused.id)

    assert [%{kind: "system", content: ^line}] =
             for(
               %{turn_id: turn_id, kind: "system"} = row <-
                 Threads.messages(Sanctum.Context.actor(ctx), thread.id),
               turn_id == refused.id,
               do: row
             )

    # The turn's end is announced after anything it asked for.
    assert_receive %ThreadEvent{kind: :turn_finished}, 5_000
    refute Enum.any?(thread_events(drain()), &match?({:consent_required, _}, &1))

    unbound = accept!(ctx, thread, "@aqua once more")
    ScriptedWorker.script([{:refuse, %{"type" => "secret_denied", "message" => "no key"}}])
    assert {:failed, :setup_required} = Task.await(run(ctx, unbound), 60_000)
    assert {:ok, %{status: "failed"}} = Tape.turn(ctx, unbound.id)
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

    stop_supervised!(ScriptedWorker)

    # A brain whose provider refused its key while describing the model
    # says so in the thread, and asks for no grant.
    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [],
       describe: {:refuse, %{"type" => "authentication", "message" => "invalid x-api-key"}}}
    )

    _ = drain()
    refused = accept!(ctx, thread, "@aqua and again")
    assert {:failed, {:model_refused, _, _}} = Task.await(run(ctx, refused), 30_000)

    assert [%{kind: "system", content: "The model refused its key: invalid x-api-key"}] =
             for(
               %{turn_id: turn_id, kind: "system"} = row <-
                 Threads.messages(Sanctum.Context.actor(ctx), thread.id),
               turn_id == refused.id,
               do: row
             )

    # The turn's end is announced after anything it asked for.
    assert_receive %ThreadEvent{kind: :turn_finished}, 5_000
    refute Enum.any?(thread_events(drain()), &match?({:consent_required, _}, &1))
  end

  test "a turn offers the provider's search, and records the open web, only when its grant " <>
         "carries it",
       %{ctx: ctx, thread: thread} do
    start_supervised!(
      {ScriptedWorker,
       ref: @model, script: [reply("searched"), reply("kept")], provider_tools: ["web_search"]}
    )

    # The shipped soul turns search on, and its first fill's grant carries it.
    searched = accept!(ctx, thread, "@aqua look it up")
    assert :completed = Task.await(run(ctx, searched), 30_000)
    assert chat_provider_tools() == [["web_search"]]
    assert web_source?(ctx, searched)

    # The person narrows the soul's grant to every tool but the search; its
    # policy still says auto.
    {_, head, _} = consent_head!(ctx, @soul)
    {:ok, blob} = Prima.Authority.Blob.parse(head.resolved_policy)
    {:ok, ingress} = Prima.Authority.Blob.ingress(blob, @soul)
    assert "native_search" in ingress.tools
    commit_soul!(ctx, ingress.tools -- ["native_search"])

    # A thread of its own, so nothing the first turn read is carried in.
    {:ok, fresh} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    kept = accept!(ctx, fresh, "@aqua again")
    assert :completed = Task.await(run(ctx, kept), 30_000)
    assert chat_provider_tools() == [["web_search"], []]
    refute web_source?(ctx, kept)
  end

  defp chat_provider_tools do
    for %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
        do: params["provider_tools"]
  end

  defp web_source?(ctx, turn) do
    {:ok, %{sources: sources}} = Tape.turn(ctx, turn.id)

    Prima.Source.outside("web_search") in Enum.map(
      Jason.decode!(sources),
      &Prima.Source.from_json/1
    )
  end

  defp consent_head!(ctx, ref) do
    {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)
    {:ok, row, refs} = Arca.ConsentStorage.get_head(Sanctum.Context.actor(ctx), profile.id)
    {profile, row, refs}
  end

  # The soul's grant committed again, its ingress narrowed to `tools`, its
  # edge into the model still lending the model's default profile.
  defp commit_soul!(ctx, tools) do
    decisions = %{
      ref: @soul,
      selections: [%{dep: @model, label: "default"}],
      subset: %{@soul => %{"tools" => tools}}
    }

    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: @soul})
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
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
          "fields" => ["KEY"],
          "hosts" => ["api.example.com"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
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
    {:ok, soul_before} = Opus.authority_for(ctx, {:id, ended.profile_id}, @soul)

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
    {:ok, soul_after} = Opus.authority_for(ctx, {:id, ended.profile_id}, @soul)
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
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

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
  # an MCP client reads of the thread (`thread.events`, since no tool
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
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

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

    # Refused before its run was asked for, the launch brought nothing into
    # the turn: no unnamed outside source stands for a row that never was.
    refute Prima.Source.outside(nil) in turn_sources(ctx, turn)
  end

  # A launch of `launchable_app!/1`'s app through the loop, after a turn
  # that read the pinned page: the card the loop drew, approved by the
  # athanor's person, and the run resumed in a task while the app's script
  # runs. The app's run stops at `{:probe, self()}` for `on_probe` to act
  # on its root, by id. Answers the turn, the card's intent, the turn's
  # sources when the card was drawn, the root's id and the loop's result.
  defp launch_through_loop!(ctx, thread, app_answer, on_probe) do
    %{ref: app} = launchable_app!(ctx)
    {:ok, _} = Aqua.Notes.pin(ctx, "about-you", "We are planning a trip.")

    start_supervised!(
      {ScriptedWorker,
       ref: [@model, app],
       script: [
         calls([{"c1", "execution.run", %{"reference" => app <> ":1.0.0", "input" => %{}}}]),
         {:probe, self()},
         app_answer,
         reply("after the launch")
       ]}
    )

    turn = accept!(ctx, thread, "@aqua launch it")
    assert {:paused, :approval} = Task.await(run(ctx, turn), 60_000)
    {:ok, paused} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    {:ok, card} = Tape.message(ctx, approval.message_id)
    intent = Tape.payload(card)["intent"]
    at_card = turn_sources(ctx, turn)

    assert {:ok, %{decision: "approved", resolution_kind: "launch"}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    resumed =
      Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end)

    assert_receive {:scripted_probe, runner, root_id}, 30_000
    on_probe.(root_id)
    send(runner, :continue)

    %{
      app: app,
      turn: paused,
      intent: intent,
      at_card: at_card,
      root_id: root_id,
      result: Task.await(resumed, 60_000)
    }
  end

  # What the launched app reads: a source no other step of the turn holds
  # (the model's own key is a disclosed vault field, so the turn holds
  # `vault_disclosed` already), so the turn holding it is the app's doing.
  @app_read Prima.Source.outside("app-read.example")

  defp app_read!(ctx, execution_id),
    do: :ok = Opus.Ledger.join(Sanctum.Context.actor(ctx), execution_id, [@app_read])

  defp turn_sources(ctx, turn) do
    {:ok, %{sources: sources}} = Tape.turn(ctx, turn.id)
    Prima.Source.decode(sources)
  end

  test "a launch's card binds the turn's sources, the app's grant and the classes it lets flow, " <>
         "and names them; approved, the app roots on them and its tree's ledger joins the turn " <>
         "by its completion result",
       %{ctx: ctx, thread: thread} do
    %{app: app, turn: turn, intent: intent, at_card: shown, root_id: root_id, result: result} =
      launch_through_loop!(ctx, thread, %{"answered" => true}, &app_read!(ctx, &1))

    assert result == :completed

    # The card bound the turn's sources as they stood, the app's grant at
    # its head and every class of them, the grant's one exit declaring no
    # flow of any.
    assert Prima.Source.new(:pinned) in shown
    refute @app_read in shown
    classes = Prima.Source.classes_of(shown)
    {:ok, %{consent_id: consent_id}} = Opus.authority_for(ctx, :default, app)

    assert %{"consent_id" => ^consent_id, "lets_flow" => lets_flow} = intent["proposal"]
    assert Aqua.Launch.bound(intent["proposal"]).sources == shown
    assert intent["sources"] == Prima.Source.to_json_list(shown)
    assert lets_flow == Enum.map(classes, &Atom.to_string/1)

    html =
      render_component(PrismWeb.AquaApprovalCard,
        id: "card",
        message_id: "msg",
        approval_id: "apr",
        status: "pending",
        payload: intent
      )

    assert [named] = Regex.run(~r/data-test="approval-lets-flow".*?<\/div>/s, html)
    assert named =~ "this app will be allowed to send:"
    assert named =~ "the pinned page"

    # The app rooted under the launch step's own id, seeded with what the
    # card bound and letting flow the classes it named.
    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{child_execution_id: ^root_id, outcome: "ok"} =
             Enum.find(steps, &(&1.kind == "launch"))

    actor = Sanctum.Context.actor(ctx)
    assert {:ok, %{launch_classes: ^classes}} = Arca.Execution.flow_state(actor, root_id)
    {:ok, [started | _]} = Arca.ExecutionEvents.since(actor, root_id, 0)
    assert Arca.ExecutionEvents.data(started)["sources"] == Prima.Source.to_json_list(shown)

    # What the app read reached the turn by its completion result.
    assert @app_read in turn_sources(ctx, turn)
  end

  test "a launched app that fails brings its tree's ledger into the turn from its root's row",
       %{ctx: ctx, thread: thread} do
    %{turn: turn, root_id: root_id, result: result} =
      launch_through_loop!(ctx, thread, {:error, "the app failed"}, &app_read!(ctx, &1))

    assert result == :completed
    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{child_execution_id: ^root_id, outcome: "error"} =
             Enum.find(steps, &(&1.kind == "launch"))

    assert @app_read in turn_sources(ctx, turn)
  end

  # What an MCP client reads of `thread` (`thread.events`, through the
  # router as the transport dispatches it): its rows, decoded from the
  # tool result's one text block.
  defp mcp_thread_messages(ctx, thread) do
    message = %Prima.MCP.Message{
      type: :request,
      id: 1,
      method: "tools/call",
      params: %{
        "name" => "thread",
        "arguments" => %{"action" => "events", "thread" => thread.id}
      }
    }

    assert {:ok, %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]}} =
             Emissary.MCP.Router.dispatch(ctx, message)

    Jason.decode!(text)["messages"]
  end

  # An app of the person's own with no exit at all, granted: its grant
  # covers whatever the turn has read, so the soul's `auto` runs it with no
  # card.
  defp quiet_app!(ctx) do
    # A root runs only in a filled athanor (`Sanctum.Provisioning.ready/1`),
    # and a launch with no card starts at once.
    Sanctum.TestContext.ready!(ctx.athanor_id)
    name = "quiet-app-#{System.unique_integer([:positive])}"

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(%{"name" => name, "version" => "1.0.0", "type" => "reagent"})
      })

    ref = "reagent:local." <> name
    walk!(ctx, %{ref: ref, bindings: []})
    ref
  end

  defp workspace!(ctx) do
    %Arca.Schemas.Thread{}
    |> Arca.Schemas.Thread.changeset(%{
      id: Prima.UUID7.generate_id("thread"),
      athanor_id: ctx.athanor_id,
      kind: "workspace",
      workspace_state: "open",
      title: "Run the app",
      created_by: ctx.user_id
    })
    |> Arca.Repo.insert!()
  end

  defp runs_of(ctx, ref) do
    Arca.Repo.all(
      from(e in Arca.Schemas.Execution,
        where: e.athanor_id == ^ctx.athanor_id and like(e.reference, ^"#{ref}%"),
        select: %{id: e.id, user_id: e.user_id, origin: e.origin, parent: e.parent_execution_id}
      )
    )
  end

  test "a launch of an app whose grant covers what the turn has read runs with no card, on the " <>
         "daily thread and in a workspace thread: dispatched once, its step closed with the " <>
         "run's result, the root let go and taken back around it",
       %{ctx: ctx, thread: daily} do
    app = quiet_app!(ctx)
    {:ok, _} = Aqua.Notes.pin(ctx, "about-you", "We are planning a trip.")
    start_supervised!({ScriptedWorker, ref: [@model, app], script: []})

    for room <- [daily, workspace!(ctx)] do
      ScriptedWorker.script([
        calls([{"c1", "execution.run", %{"reference" => app <> ":1.0.0", "input" => %{}}}]),
        {:probe, self()},
        %{"answered" => true},
        reply("after the launch")
      ])

      before = runs_of(ctx, app)
      turn = accept!(ctx, room, "@aqua run it")
      task = run(ctx, turn)

      # While the app runs, the turn's root is let go around it.
      assert_receive {:scripted_probe, runner, root_id}, 30_000
      assert {:ok, %{status: "paused", paused_reason: "launch"}} = Tape.turn(ctx, turn.id)
      send(runner, :continue)

      # Taken back, the turn asks its model again and ends.
      assert :completed = Task.await(task, 60_000)
      {:ok, ended} = Tape.turn(ctx, turn.id)
      assert {:ok, []} = Tape.pending_approvals(ctx, ended)
      {:ok, steps} = Tape.steps(ctx, ended)
      assert Enum.count(steps, &(&1.kind == "model")) == 2

      assert %{
               dispatch_state: "closed",
               outcome: "ok",
               approval_id: nil,
               child_execution_id: ^root_id,
               result_message_id: result
             } = Enum.find(steps, &(&1.kind == "launch"))

      assert {:ok, %{content: content}} = Tape.message(ctx, result)
      assert content =~ "answered"

      # Dispatched once, as the turn's person under its own origin.
      assert runs_of(ctx, app) -- before == [
               %{id: root_id, user_id: ctx.user_id, origin: "interactive", parent: nil}
             ]
    end
  end

  test "a launch with no card is decided again on the person's answers as it dispatches: a " <>
         "never given since its decision runs nothing",
       %{ctx: ctx, thread: thread} do
    app = quiet_app!(ctx)
    test = self()
    handler = {__MODULE__, make_ref()}
    {:ok, once} = Agent.start_link(fn -> false end)

    # The person answers never on execution.run while the read decided
    # beside the launch is admitted: after the launch's decision, before
    # its dispatch.
    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :decision, :admitted],
        fn _event, _measurements, %{tool: tool, action: action}, _config ->
          if {tool, action} == {"crew", "list"} and not Agent.get_and_update(once, &{&1, true}) do
            {:ok, _} =
              Arca.ToolGrantStorage.put(%{
                athanor_id: ctx.athanor_id,
                scope: "agent",
                effect: "deny",
                agent_name: "aqua",
                tool: "execution",
                action: "run",
                granted_by: ctx.user_id
              })

            send(test, :never)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    start_supervised!(
      {ScriptedWorker,
       ref: [@model, app],
       script: [
         calls([
           {"c0", "crew", %{"action" => "list"}},
           {"c1", "execution.run", %{"reference" => app <> ":1.0.0", "input" => %{}}}
         ]),
         reply("not run")
       ]}
    )

    turn = accept!(ctx, thread, "@aqua look, then run it")
    assert :completed = Task.await(run(ctx, turn), 60_000)
    assert_received :never
    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{dispatch_state: "closed", outcome: "denied", approval_id: nil, error: said} =
             Enum.find(steps, &(&1.kind == "launch"))

    assert said == "execution.run is not in the agent's policy"
    assert runs_of(ctx, app) == []
  end

  test "a launch with no card whose run's outcome is not known stops the turn on it, and is " <>
         "never run again",
       %{ctx: ctx, thread: thread} do
    app = quiet_app!(ctx)

    start_supervised!(
      {ScriptedWorker,
       ref: [@model, app],
       script: [
         calls([{"c1", "execution.run", %{"reference" => app <> ":1.0.0", "input" => %{}}}]),
         {:probe, self()},
         reply("never sent")
       ]}
    )

    turn = accept!(ctx, thread, "@aqua run it")
    task = run(ctx, turn)
    assert_receive {:scripted_probe, runner, _root_id}, 30_000

    # The app's runner ends while it holds the run.
    Process.exit(runner, :kill)

    assert {:paused, :uncertain} = Task.await(task, 60_000)
    assert {:ok, %{status: "paused", paused_reason: "uncertain"}} = Tape.turn(ctx, turn.id)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{dispatch_state: "uncertain", approval_id: nil} =
             Enum.find(steps, &(&1.kind == "launch"))

    assert Enum.count(steps, &(&1.kind == "model")) == 1
    assert [_once] = runs_of(ctx, app)
  end

  test "under ask, a standing allow on execution.run stored for the thread still asks before a " <>
         "launch, as before every one",
       %{ctx: ctx, thread: thread} do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "tool_policy_patch" => %{"execution.run" => "ask"}
      })

    walk!(ctx, %{ref: @soul, selections: [%{dep: "catalyst:local.claude", label: "default"}]})

    # A row the store refuses, since no answer stands for a launch,
    # written past it all the same.
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
      Cyfr.Test.AquaTool.call(ctx, %{
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

  # What a hand's child read before its runner was lost: a source no other
  # step of the turn holds.
  @lost_read Prima.Source.outside("lost-read.example")

  test "a hand whose runner is lost answers its outcome unknown: the turn stops on it, and what the child read joins the turn",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua fetch it")
    start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: []})

    ScriptedWorker.script([
      calls([{"c1", "http", %{"action" => "get", "url" => "https://example.test/x"}}]),
      {:probe, self()},
      reply("fetched")
    ])

    task = run(ctx, turn)
    assert_receive {:scripted_probe, runner, child}, 30_000
    :ok = Opus.Ledger.join(Sanctum.Context.actor(ctx), child, [@lost_read])

    # The runner ends while it holds the run: its worker service reports
    # the exit, the attempt lapses, and the waiting worker is answered.
    Process.exit(runner, :kill)

    assert {:paused, :uncertain} = Task.await(task, 60_000)
    assert {:ok, %{status: "paused", paused_reason: "uncertain"}} = Tape.turn(ctx, turn.id)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{dispatch_state: "uncertain", outcome: "uncertain"} =
             Enum.find(steps, &(&1.action == "get"))

    # No model round follows the lost call: the model never hears an
    # ordinary error it could answer by calling again.
    assert Enum.count(steps, &(&1.kind == "model")) == 1
    assert @lost_read in turn_sources(ctx, turn)
  end

  test "a worker that dies with its call's in-process handler still running stops the handler before the step settles",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua fetch it")
    start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: []})

    ScriptedWorker.script([
      calls([{"c1", "http", %{"action" => "get", "url" => "https://example.test/x"}}]),
      {:probe, self()},
      reply("fetched")
    ])

    task = run(ctx, turn)
    assert_receive {:scripted_probe, _runner, child}, 30_000
    {:ok, steps} = Tape.steps(ctx, turn)
    get = Enum.find(steps, &(&1.action == "get"))

    # A handler the gate runs under the step's handle, registered under a
    # claimer that stays alive: only the loop's own settlement of the dead
    # worker's step stops it.
    handle = {turn.id, get.id, get.generation}
    test = self()

    claimer =
      spawn(fn ->
        send(test, {:claimed, Sanctum.RunningTasks.claim(handle)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(claimer, :kill) end)
    assert_receive {:claimed, :ok}, 5_000
    handler = spawn(fn -> Process.sleep(:infinity) end)
    handler_ref = Process.monitor(handler)
    assert :ok = Sanctum.RunningTasks.register_handle(handle, handler)

    # The loop's worker waits on the call's child: it dies.
    %{waiter: worker} = :sys.get_state(Opus.Attempt.whereis(child))
    Process.exit(worker, :kill)

    assert_receive {:DOWN, ^handler_ref, :process, ^handler, :cancelled}, 10_000
    assert {:paused, :uncertain} = Task.await(task, 60_000)
    assert {:ok, %{dispatch_state: "uncertain"}} = Tape.step(ctx, get.id)

    Prima.Test.Wait.wait_until(
      fn -> :ets.lookup(Sanctum.RunningTasks.Handles, handle) == [] end,
      5_000,
      "the handle's row to go with its handler"
    )
  end

  test "a launch whose root cannot be taken back stops the turn paused around it, and nothing after it runs",
       %{ctx: ctx, thread: thread} do
    # The athanor is archived while the launched app runs, and the app then
    # fails on its own: its failure is known, and the turn's root no longer
    # stands, so no try takes it back.
    %{turn: turn, result: result} =
      launch_through_loop!(ctx, thread, {:error, "the app failed"}, fn _root_id ->
        assert %{status: "archived"} = Sanctum.TestContext.archive!(ctx.athanor_id)
      end)

    assert result == {:paused, :launch}
    assert {:ok, %{status: "paused", paused_reason: "launch"}} = Tape.turn(ctx, turn.id)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{dispatch_state: "closed", outcome: "error"} =
             Enum.find(steps, &(&1.kind == "launch"))

    assert Enum.count(steps, &(&1.kind == "model")) == 1

    assert [_proposed_the_launch] =
             Enum.filter(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))
  end

  describe "a page's call the host proposes" do
    # What the runner does for a page's call while a turn runs
    # (`Aqua.Runner`): the step proposed into the running turn, and, with
    # `notify`, the loop told of it.
    defp page!(ctx, turn, name, args, notify \\ true) do
      {:ok, running} = Tape.turn(ctx, turn.id)
      request = Prima.UUID7.generate_id("pcl")

      call = %{
        request: request,
        name: name,
        arguments: args,
        user_id: ctx.user_id,
        put_turn_id: turn.id
      }

      proposal = Aqua.PageCalls.proposal(running, Aqua.PageCalls.row(call))
      {:ok, step} = Tape.propose_call(ctx, running, proposal)
      if notify, do: send(Aqua.Loop.holder(turn.id), {:page_call, turn.id})
      step
    end

    defp step!(ctx, turn, id) do
      {:ok, steps} = Tape.steps(ctx, turn)
      Enum.find(steps, &(&1.id == id))
    end

    # A bounded wait on what the rows show.
    defp until!(fun, tries \\ 200) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("the rows never showed it")
        true -> Process.sleep(50) && until!(fun, tries - 1)
      end
    end

    defp chats, do: Enum.filter(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

    defp page_rows(ctx, thread),
      do:
        ctx
        |> Sanctum.Context.actor()
        |> Threads.messages(thread.id)
        |> Enum.filter(&(&1.kind in ["page_call", "page_result"]))

    test "proposed while the model answers, with no word to the loop, it runs once the model " <>
           "has answered, before the round's own calls and before the next round asks, and " <>
           "no model's request carries it",
         %{ctx: ctx, thread: thread} do
      turn = accept!(ctx, thread, "@aqua look around")

      script!([
        {:probe, self()},
        calls([{"c1", "component", %{"action" => "list"}}]),
        reply("done")
      ])

      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000
      page = page!(ctx, turn, "component.list", %{}, false)
      send(model, :continue)
      assert :completed = Task.await(task, 60_000)

      {:ok, steps} = Tape.steps(ctx, turn)

      assert [
               %{kind: "model", outcome: "ok"} = first,
               %{id: page_id, purpose: "page", outcome: "ok"},
               %{tool: "component", purpose: "chat", outcome: "ok"},
               %{kind: "model", outcome: "ok"} = second
             ] = steps

      assert page_id == page.id
      closed = step!(ctx, turn, page.id)
      assert DateTime.compare(closed.ended_at, second.started_at) != :gt
      assert DateTime.compare(first.ended_at, closed.started_at) != :gt

      # Its call and its answer are rows of their own, and the wire's answer.
      assert [%{kind: "page_call"}, %{kind: "page_result", content: body}] =
               page_rows(ctx, thread)

      assert %{"ok" => true} = Jason.decode!(body)

      # The second round's request carries the component call, not the page's.
      [_first, %{input: %{"params" => %{"messages" => messages}}}] = chats()
      sent = Jason.encode!(messages)
      [%{payload: call} | _] = page_rows(ctx, thread)
      assert sent =~ "c1"
      refute sent =~ Jason.decode!(call)["tool_call_id"]
    end

    test "told while the model answers, it runs at once beside the model, once, and a " <>
           "continuation does not dispatch it again",
         %{ctx: ctx, thread: thread} do
      turn = accept!(ctx, thread, "@aqua keep a note")

      script!([
        {:probe, self()},
        calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "kept"}}])
      ])

      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000
      page = page!(ctx, turn, "component.list", %{})

      # It closes while the model's step is still open, with no answer.
      until!(fn -> step!(ctx, turn, page.id).dispatch_state == "closed" end)
      {:ok, [%{kind: "model", dispatch_state: "dispatched"} | _]} = Tape.steps(ctx, turn)
      send(model, :continue)

      assert {:paused, :approval} = Task.await(task, 60_000)
      {:ok, paused} = Tape.turn(ctx, turn.id)
      {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
      {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})
      ScriptedWorker.script([reply("kept it")])

      assert :completed =
               Task.await(
                 Task.async(fn ->
                   Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume)
                 end),
                 60_000
               )

      assert %{outcome: "ok", generation: 0} = step!(ctx, turn, page.id)
      assert [%{kind: "page_call"}, %{kind: "page_result"}] = page_rows(ctx, thread)
    end

    test "a page's launch told while the model answers waits for that answer, then runs " <>
           "before the round's own calls with the root let go and taken back around it",
         %{ctx: ctx, thread: thread} do
      app = quiet_app!(ctx)
      start_supervised!({ScriptedWorker, ref: [@model, app], script: []})
      ScriptedWorker.script([{:probe, self()}, reply("done"), {:output, %{"answered" => true}}])

      turn = accept!(ctx, thread, "@aqua show it")
      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000

      launch =
        page!(ctx, turn, "execution.run", %{
          "reference" => app <> ":1.0.0",
          "input" => %{"operation" => "go", "params" => %{}}
        })

      read = page!(ctx, turn, "component.list", %{})

      # The loop took the notice: the read ran, the launch did not, and
      # the root was never let go under the model's run.
      until!(fn -> step!(ctx, turn, read.id).dispatch_state == "closed" end)
      assert %{dispatch_state: "proposed"} = step!(ctx, turn, launch.id)
      assert {:ok, %{status: "running"}} = Tape.turn(ctx, turn.id)
      send(model, :continue)

      assert :completed = Task.await(task, 60_000)
      assert %{outcome: "ok", kind: "launch", result_message_id: result} = step!(ctx, turn, launch.id)
      assert {:ok, %{kind: "page_result", content: body}} = Tape.message(ctx, result)
      assert %{"ok" => true, "result" => %{"answered" => true}} = Jason.decode!(body)

      # The model's answer called nothing: it is not asked again.
      assert [_one] = chats()
    end

    test "a card a page's call raises while the model answers pauses the turn only once the " <>
           "model has answered, and the yes runs it once without asking the model again",
         %{ctx: ctx, thread: thread} do
      turn = accept!(ctx, thread, "@aqua wait")
      script!([{:probe, self()}, reply("done")])
      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000

      page = page!(ctx, turn, "notes.keep", %{"name" => "from-page", "content" => "x"})

      until!(fn -> match?({:ok, [_]}, Tape.pending_approvals(ctx, turn)) end)

      assert {:ok, %{status: "running"}} = Tape.turn(ctx, turn.id)
      send(model, :continue)
      assert {:paused, :approval} = Task.await(task, 60_000)

      {:ok, paused} = Tape.turn(ctx, turn.id)
      {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
      assert approval.id == step!(ctx, turn, page.id).approval_id
      {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})

      assert :completed =
               Task.await(
                 Task.async(fn ->
                   Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume)
                 end),
                 60_000
               )

      assert %{outcome: "ok", generation: 0} = step!(ctx, turn, page.id)
      assert {:ok, %{content: "x"}} = Aqua.Notes.read(ctx, "from-page")
      assert [_one] = chats()
    end

    test "a page's call whose outcome is unknown while the model answers stops the turn at " <>
           "once: the model's worker is stopped, its step closed, and no round follows",
         %{ctx: ctx, thread: thread} do
      start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: []})
      # Items are taken as each run plays: the model's run holds at the
      # first probe, and the page's call's run takes the second.
      ScriptedWorker.script([{:probe, self()}, {:probe, self()}, reply("never read")])

      turn = accept!(ctx, thread, "@aqua fetch")
      task = run(ctx, turn)
      assert_receive {:scripted_probe, _model, model_child}, 30_000
      page = page!(ctx, turn, "http.get", %{"url" => "https://example.test/x"})
      assert_receive {:scripted_probe, runner, _child}, 30_000
      Process.exit(runner, :kill)

      assert {:paused, :uncertain} = Task.await(task, 60_000)
      assert {:ok, %{status: "paused", paused_reason: "uncertain"}} = Tape.turn(ctx, turn.id)
      {:ok, steps} = Tape.steps(ctx, turn)

      assert [%{kind: "model", dispatch_state: "closed", outcome: "error"} = model, _page] =
               steps

      assert model.child_execution_id == model_child
      assert %{dispatch_state: "uncertain"} = step!(ctx, turn, page.id)
      assert [_one] = chats()
    end

    test "with the model's last answer given, a page's call proposed between the steps runs " <>
           "before the turn ends, and the model is not asked again",
         %{ctx: ctx, thread: thread} do
      start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: []})

      ScriptedWorker.script([
        calls([{"c1", "http", %{"action" => "get", "url" => "https://example.test/x"}}]),
        {:probe, self()},
        %{"status" => 200, "body" => "x"},
        reply("done")
      ])

      turn = accept!(ctx, thread, "@aqua fetch")
      task = run(ctx, turn)

      # The loop waits on the round's own call, not on its model: the page's
      # call waits for the next round's start.
      assert_receive {:scripted_probe, runner, _child}, 30_000
      page = page!(ctx, turn, "component.list", %{})
      assert %{dispatch_state: "proposed"} = step!(ctx, turn, page.id)
      send(runner, :continue)

      assert :completed = Task.await(task, 60_000)
      {:ok, steps} = Tape.steps(ctx, turn)
      [_, _, closed, second] = steps
      assert closed.id == page.id and closed.outcome == "ok"
      assert DateTime.compare(closed.ended_at, second.started_at) != :gt
    end

    test "a turn completes only once no page's call is still proposed in it",
         %{ctx: ctx, thread: thread} do
      turn = accept!(ctx, thread, "@aqua hello")
      script!([{:probe, self()}, reply("hi")])
      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000
      {:ok, running} = Tape.turn(ctx, turn.id)
      page = page!(ctx, turn, "component.list", %{}, false)
      assert {:error, :call_pending} = Tape.finish(ctx, running, "completed")

      send(model, :continue)
      assert :completed = Task.await(task, 60_000)
      assert %{outcome: "ok"} = step!(ctx, turn, page.id)
    end
  end
end
