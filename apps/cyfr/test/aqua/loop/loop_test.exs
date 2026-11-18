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
  workers while the loop holds the root; every call is decided under the
  member's mode and nothing is asked: auto runs what the member is
  offered, read-only runs its reads and refuses the rest, saying so once
  in the thread; a worker that dies leaves an uncertain step, and the
  sender's next line continues the turn with reads only; a turn taken
  over with a post waiting skips what its response still proposed; typed
  model errors are retried or end the turn; the step cap ends a turn that
  never stops calling.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait, only: [wait_until: 3]

  alias Aqua.Tape
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
    # its person's own, who sends the turns.
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

  # ---------------------------------------------------------------------------
  # The member's mode
  # ---------------------------------------------------------------------------

  # The same calls for the soul and for a crew member of the athanor's own
  # on the soul's brain, which is offered the soul's tools: a read, a write
  # the catalog makes and a write a hand makes, each of which runs in auto,
  # so a refusal of one can come from the mode alone.
  @list %{"action" => "list", "path" => "data"}
  @keep %{"action" => "keep", "name" => "status", "content" => "all well"}
  @write %{"action" => "write", "path" => "data/x.md", "content" => "y"}

  for {name, title} <- [{"aqua", "Aqua"}, {"reader", "Reader"}] do
    test "#{title} in read-only runs a read and refuses each write in its own sentence, which " <>
           "the thread is given once, a turn continued after its runner died included",
         %{ctx: ctx, thread: daily} do
      name = unquote(name)
      title = unquote(title)
      room = room!(ctx, daily, name, title, "read-only")
      sentence = Aqua.Loop.Policy.read_only_sentence(title)
      start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.files"], script: []})

      ScriptedWorker.script([
        calls([{"c1", "files", @list}, {"c2", "notes", @keep}]),
        %{"entries" => []},
        calls([{"c3", "files", @write}]),
        {:probe, self()},
        calls([{"c4", "notes", @keep}]),
        reply("I only looked")
      ])

      turn_id = send!(ctx, room, "tidy up")

      # The runner holding the turn dies while its third model run answers,
      # that run with it; the runner started after it takes the turn over
      # and continues it from its rows.
      assert_receive {:scripted_probe, player, _child}, 30_000
      Process.exit(Aqua.Runner.whereis(room.id), :kill)
      Process.exit(player, :kill)
      turn = ended!(ctx, turn_id)

      assert %{status: "completed", agent: ^name, agent_mode: "read-only", recovery_attempts: 1} =
               turn

      assert step_rows(ctx, turn) == [
               model_row("ok"),
               call_row("files", "list", "ok", nil),
               call_row("notes", "keep", "denied", sentence),
               model_row("ok"),
               call_row("files", "write", "denied", sentence),
               model_row("error", "not reproducible"),
               model_row("ok"),
               call_row("notes", "keep", "denied", sentence),
               model_row("ok")
             ]

      # Each refused step shows refused, in its own words.
      {:ok, shown} = Aqua.Steps.steps(ctx, room.id)

      assert Enum.map(shown, &Map.take(&1, [:sentence, :status])) == [
               %{sentence: "Kept a note", status: :refused},
               %{sentence: "Wrote a file", status: :refused},
               %{sentence: "Kept a note", status: :refused},
               %{sentence: "Looked through the files", status: :done}
             ]

      # The thread is told once, at the first refusal: neither the second
      # refusal of the turn nor the one its continuation made says it again.
      person = ctx.user_id
      agent = Prima.Author.agent()
      system = Prima.Author.system()
      list_result = Jason.encode!(%{"entries" => []}, pretty: true)

      assert lines(ctx, room.id) == [
               line("text", person, "person", "tidy up", turn_id),
               line("tool_call", agent, name, "files", turn_id),
               line("tool_call", agent, name, "notes", turn_id),
               line("tool_result", system, name, sentence, turn_id),
               %{
                 line("system", system, name, sentence, turn_id)
                 | client_id: "read-only:" <> turn_id
               },
               line("tool_result", system, name, list_result, turn_id),
               line("tool_call", agent, name, "files", turn_id),
               line("tool_result", system, name, sentence, turn_id),
               line(
                 "turn_aborted",
                 system,
                 name,
                 "the server restarted while the assistant was working",
                 turn_id
               ),
               line("tool_call", agent, name, "notes", turn_id),
               line("tool_result", system, name, sentence, turn_id),
               line("text", agent, name, "I only looked", turn_id)
             ]

      # The model is answered the refusal as the call's own result, where
      # its row stands: before the read's, which closed after it.
      [_first, second | _] = chat_messages()

      assert second == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "tidy up"}]},
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "tool_call",
                     "id" => "c1",
                     "name" => "files",
                     "arguments" => @list
                   },
                   %{"type" => "tool_call", "id" => "c2", "name" => "notes", "arguments" => @keep}
                 ]
               },
               %{
                 "role" => "tool",
                 "content" => [
                   tool_result("c2", "notes", sentence, true),
                   tool_result("c1", "files", list_result, false)
                 ]
               }
             ]

      # Neither write happened: no note, and the hand's child never ran.
      assert {:error, {:not_found, "note", "status"}} = Aqua.Notes.read(ctx, "status")
      {:ok, steps} = Tape.steps(ctx, turn)
      write = Enum.find(steps, &(&1.action == "write"))
      refute Enum.any?(ScriptedWorker.calls(), &(&1.execution_id == write.child_execution_id))
      assert Arca.Repo.get(Arca.Schemas.Execution, write.child_execution_id) == nil
    end

    test "#{title} in auto runs the same calls, and the thread is told of no mode",
         %{ctx: ctx, thread: daily} do
      name = unquote(name)
      room = room!(ctx, daily, name, unquote(title), "auto")
      start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.files"], script: []})

      ScriptedWorker.script([
        calls([{"c1", "files", @list}, {"c2", "notes", @keep}]),
        %{"entries" => []},
        calls([{"c3", "files", @write}]),
        %{"written" => "data/x.md"},
        reply("tidied")
      ])

      turn = post!(ctx, room, "tidy up")
      assert %{status: "completed", agent: ^name, agent_mode: "auto"} = turn

      assert step_rows(ctx, turn) == [
               model_row("ok"),
               call_row("files", "list", "ok", nil),
               call_row("notes", "keep", "ok", nil),
               model_row("ok"),
               call_row("files", "write", "ok", nil),
               model_row("ok")
             ]

      # Every call ran, and the thread is told nothing of a mode.
      turn_id = turn.id
      agent = Prima.Author.agent()
      system = Prima.Author.system()
      list_result = Jason.encode!(%{"entries" => []}, pretty: true)
      write_result = Jason.encode!(%{"written" => "data/x.md"}, pretty: true)

      keep_result =
        Jason.encode!(%{"athanor_id" => ctx.athanor_id, "kept" => "status", "replaced" => false},
          pretty: true
        )

      assert lines(ctx, room.id) == [
               line("text", ctx.user_id, "person", "tidy up", turn_id),
               line("tool_call", agent, name, "files", turn_id),
               line("tool_call", agent, name, "notes", turn_id),
               line("tool_result", system, name, list_result, turn_id),
               line("tool_result", system, name, keep_result, turn_id),
               line("tool_call", agent, name, "files", turn_id),
               line("tool_result", system, name, write_result, turn_id),
               line("text", agent, name, "tidied", turn_id)
             ]

      # The note was kept in the turn's chain, on the guest plane: its
      # provenance comes from the host's lineage, never from the call's
      # own arguments, and it names Aqua as its keeper.
      room_id = room.id
      root = turn.root_execution_id

      assert {:ok, %{content: "all well", thread: ^room_id, execution: ^root, kept_by: ^agent}} =
               Aqua.Notes.read(ctx, "status")

      # The hand's child ran the write.
      {:ok, steps} = Tape.steps(ctx, turn)
      write = Enum.find(steps, &(&1.action == "write"))

      assert [_ran] =
               Enum.filter(ScriptedWorker.calls(), &(&1.execution_id == write.child_execution_id))
    end
  end

  # A soul whose file still lists its tools under `tool_policy:` is refused
  # whole: posted to in the thread it last answered, its turn never runs and
  # says why where the person reads it.
  test "a soul whose file holds tool_policy, posted to where it last answered, ends its turn " <>
         "unrun with the line that says what to change, and dispatches nothing",
       %{ctx: ctx, thread: thread} do
    script!([reply("hi")])
    answered = post!(ctx, thread, "hello")
    assert %{status: "completed", agent: "aqua"} = answered

    # The file as it stood before `tools:`, still holding `tool_policy:`.
    actor = Sanctum.Context.actor(ctx)
    {:ok, bytes} = Arca.get(actor, Compendium.AquaPath.soul_file())
    held = String.replace(bytes, "mode: auto\n", "mode: auto\ntool_policy:\n  notes.keep: auto\n")
    refute held == bytes
    :ok = Arca.put(actor, Compendium.AquaPath.soul_file(), held)
    assert {:error, :tool_policy_retired} = Compendium.AgentIndex.snapshot(ctx, "aqua")

    unrun = post!(ctx, thread, "and now?")
    line = Prima.AgentRef.tool_policy_retired()
    assert %{status: "failed", agent: "aqua", error: ^line, root_execution_id: nil} = unrun
    turn_id = unrun.id

    assert for(%{turn_id: ^turn_id} = line <- lines(ctx, thread.id), do: line) == [
             line("text", ctx.user_id, "person", "and now?", turn_id),
             line(
               "system",
               Prima.Author.system(),
               "aqua",
               Prima.AgentRef.tool_policy_retired(),
               turn_id
             )
           ]

    assert step_rows(ctx, unrun) == []
    assert [_answered] = chat_messages()
  end

  test "a soul whose file names no tools offers nothing: its request carries only the ui event " <>
         "and request_setup",
       %{ctx: ctx, thread: thread} do
    script!([reply("hi"), reply("hi again")])

    # The shipped soul is offered its list.
    turn = accept!(ctx, thread, "@aqua hello")
    assert :completed = Task.await(run(ctx, turn), 30_000)

    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "tools" => nil})

    consent!(ctx, "aqua")
    {:ok, bytes} = Arca.get(Sanctum.Context.actor(ctx), Compendium.AquaPath.soul_file())
    refute bytes =~ "tools:"

    bare = accept!(ctx, thread, "@aqua hello again")
    assert :completed = Task.await(run(ctx, bare), 30_000)

    [shipped, offered_nothing] =
      for %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
          do: Map.take(params, ["tools", "provider_tools"])

    assert "files" in Enum.map(shipped["tools"], & &1["name"])

    assert offered_nothing == %{
             "tools" => Aqua.Loop.Request.tool_definitions(%{}),
             "provider_tools" => []
           }

    assert Enum.map(offered_nothing["tools"], & &1["name"]) == ["ui", "request_setup"]
  end

  test "the person's browser setting turned off while the model answers refuses a browser " <>
         "call the turn was offered as it began, in the browser's own words",
       %{ctx: ctx, thread: thread} do
    assert {:ok, true} = Aqua.BrowserSetting.allowed?(ctx)

    script!([
      {:hold, self()},
      calls([{"c1", "browser", %{"action" => "read"}}]),
      reply("the browser is off")
    ])

    turn = accept!(ctx, thread, "@aqua read the page")
    task = run(ctx, turn)
    assert_receive {:scripted_probe, worker, _}, 30_000
    assert {:ok, false} = Aqua.BrowserSetting.put(ctx, false)
    send(worker, :continue)
    assert :completed = Task.await(task, 60_000)

    # It was offered: the request the call answered named the browser.
    [%{"tools" => tools} | _] =
      for %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
          do: params

    assert "browser" in Enum.map(tools, & &1["name"])

    assert step_rows(ctx, turn) == [
             model_row("ok"),
             call_row(
               "browser",
               "read",
               "denied",
               Aqua.Providers.Browser.turned_off(),
               "replay_safe"
             ),
             model_row("ok")
           ]

    agent = Prima.Author.agent()
    off = Aqua.Providers.Browser.turned_off()

    assert lines(ctx, thread.id) == [
             line("text", ctx.user_id, "person", "@aqua read the page", turn.id),
             line("tool_call", agent, "aqua", "browser", turn.id),
             line("tool_result", Prima.Author.system(), "aqua", off, turn.id),
             line("text", agent, "aqua", "the browser is off", turn.id)
           ]

    # Refused before it was dispatched: the gate never saw it.
    assert {:ok, []} = Arca.DecisionLog.list(Sanctum.Context.actor(ctx), tool: "browser")
  end

  test "a mode switched while a turn runs does not reach that turn; the member's next turn " <>
         "runs in the new mode",
       %{ctx: ctx, thread: thread} do
    keep = fn name -> %{"action" => "keep", "name" => name, "content" => "x"} end
    sentence = Aqua.Loop.Policy.read_only_sentence("Aqua")

    script!([
      {:hold, self()},
      calls([{"c1", "notes", keep.("first")}]),
      reply("kept"),
      calls([{"c2", "notes", keep.("second")}]),
      reply("not kept")
    ])

    first = accept!(ctx, thread, "@aqua keep a note")
    task = run(ctx, first)
    assert_receive {:scripted_probe, worker, _}, 30_000

    # The person switches Aqua to read-only while the model answers.
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "mode" => "read-only"
      })

    # The switch landed while the turn's first model call is still held:
    # its one step is that call, open.
    assert step_rows(ctx, first) == [%{model_row(nil) | dispatch_state: "dispatched"}]
    send(worker, :continue)
    assert :completed = Task.await(task, 60_000)
    assert {:ok, %{agent_mode: "auto"}} = Tape.turn(ctx, first.id)

    assert step_rows(ctx, first) == [
             model_row("ok"),
             call_row("notes", "keep", "ok", nil),
             model_row("ok")
           ]

    assert {:ok, %{content: "x"}} = Aqua.Notes.read(ctx, "first")
    refute Enum.any?(lines(ctx, thread.id), &(&1.kind == "system"))

    consent!(ctx, "aqua")
    second = accept!(ctx, thread, "@aqua keep another")
    assert :completed = Task.await(run(ctx, second), 60_000)
    assert {:ok, %{agent_mode: "read-only"}} = Tape.turn(ctx, second.id)

    assert step_rows(ctx, second) == [
             model_row("ok"),
             call_row("notes", "keep", "denied", sentence),
             model_row("ok")
           ]

    assert {:error, {:not_found, "note", "second"}} = Aqua.Notes.read(ctx, "second")

    assert [%{content: ^sentence, client_id: client_id}] =
             Enum.filter(lines(ctx, thread.id), &(&1.kind == "system"))

    assert client_id == "read-only:" <> second.id
  end

  # The member's thread, with the member in `mode`: for the soul, the daily
  # thread, its mode switched as the Aqua page switches it; for a crew
  # member of the athanor's own, its thread under the daily one.
  defp room!(ctx, daily, "aqua", _title, mode) do
    if mode != "auto", do: mode!(ctx, "aqua", mode)
    daily
  end

  defp room!(ctx, daily, name, title, mode) do
    member!(ctx, name, title, mode)
    {:ok, child} = Threads.crew_thread(Sanctum.Context.actor(ctx), daily.id, name)
    child
  end

  # The member `name` switched to `mode` through the `aqua` tool, as the
  # Aqua page switches it, and its grant walked again for its file's move.
  defp mode!(ctx, name, mode) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => name, "mode" => mode})

    consent!(ctx, name)
  end

  # The member's grant walked again as a person walks it, its brain's key
  # the one the model's own profile binds.
  defp consent!(ctx, name) do
    ref = if Prima.AgentRef.soul?(name), do: @soul, else: Prima.AgentRef.ref(name)
    walk!(ctx, %{ref: ref, selections: [%{dep: @model, label: "default"}]})
  end

  # A crew member of the athanor's own, on the soul's brain, in `mode`.
  defp member!(ctx, name, title, mode) do
    :ok =
      Arca.put(
        Sanctum.Context.actor(ctx),
        Compendium.AquaPath.crew_file(name),
        "---\ntitle: #{title}\ndescription: Reads and tidies.\ncatalyst_ref: #{@model}\n" <>
          "model: claude-sonnet-5-5\nmode: #{mode}\n---\n\nYou are the #{title}.\n"
      )

    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    consent!(ctx, name)
  end

  # A person's post into `room` through its runner, as the console sends
  # it, in a filled athanor (`Sanctum.Provisioning.ready/1`): the turn it
  # opened, once that turn has ended.
  defp post!(ctx, room, text), do: ended!(ctx, send!(ctx, room, text))

  defp send!(ctx, room, text) do
    Sanctum.TestContext.ready!(ctx.athanor_id)
    {:ok, %{turn_id: turn_id}} = Aqua.Runner.send_message(ctx, room.id, text)
    turn_id
  end

  defp ended!(ctx, turn_id) do
    wait_until(
      fn -> ended?(ctx, turn_id) end,
      60_000,
      "turn #{turn_id} to end"
    )

    {:ok, turn} = Tape.turn(ctx, turn_id)
    turn
  end

  defp ended?(ctx, turn_id) do
    case Tape.turn(ctx, turn_id) do
      {:ok, turn} -> Tape.terminal?(turn)
      _unread -> false
    end
  end

  # A turn's steps whole, but for what a run mints for each: its ids, its
  # times, the digests of its request and its proposal, and its usage. A
  # model step names the catalyst release the turn pinned.
  defp step_rows(ctx, turn) do
    {:ok, %{catalyst_ref: pinned}} = Tape.turn(ctx, turn.id)
    {:ok, steps} = Tape.steps(ctx, turn)

    for step <- steps do
      step =
        if step.kind == "model" and step.tool == pinned, do: %{step | tool: :pinned}, else: step

      Map.take(step, [
        :kind,
        :purpose,
        :tool,
        :action,
        :dispatch_state,
        :outcome,
        :error,
        :approval_id,
        :recovery,
        :generation,
        :cancel_requested_at
      ])
    end
  end

  defp model_row(outcome, error \\ nil),
    do: %{
      kind: "model",
      purpose: "chat",
      tool: :pinned,
      action: "chat",
      dispatch_state: "closed",
      outcome: outcome,
      error: error,
      approval_id: nil,
      recovery: nil,
      generation: 0,
      cancel_requested_at: nil
    }

  # A call's step: a read reviewed replay-safe says so.
  defp call_row(tool, action, outcome, error, recovery \\ :by_kind) do
    recovery =
      if recovery == :by_kind,
        do: if(Aqua.Kinds.kind_for(tool, action) == :read, do: "replay_safe"),
        else: recovery

    %{
      kind: "tool",
      purpose: "chat",
      tool: tool,
      action: action,
      dispatch_state: "closed",
      outcome: outcome,
      error: error,
      approval_id: nil,
      recovery: recovery,
      generation: 0,
      cancel_requested_at: nil
    }
  end

  # The thread's lines whole, as a person reads them: their kind, who wrote
  # each and for whom, its words, the id its sender gave it and its turn.
  defp lines(ctx, thread_id) do
    for row <- Threads.messages(Sanctum.Context.actor(ctx), thread_id),
        do: Map.take(row, [:kind, :author, :sent_by, :content, :client_id, :turn_id])
  end

  defp line(kind, author, sent_by, content, turn_id),
    do: %{
      kind: kind,
      author: author,
      sent_by: sent_by,
      content: content,
      client_id: nil,
      turn_id: turn_id
    }

  # The messages of each chat request the model was sent, in order.
  defp chat_messages do
    for %{input: %{"operation" => "chat", "params" => %{"messages" => messages}}} <-
          ScriptedWorker.calls(),
        do: messages
  end

  defp tool_result(id, name, content, error?),
    do: %{
      "type" => "tool_result",
      "tool_call_id" => id,
      "name" => name,
      "content" => content,
      "is_error" => error?
    }

  test "an outside server's tool the soul is not offered is refused as its result, and one " <>
         "with a null or a decimal argument is refused before it is decided",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua search for it")

    script!([
      calls([
        {"c1", "github__search", %{"q" => "x"}},
        {"c2", "github__search", %{"q" => nil}},
        {"c3", "github__search", %{"q" => "x", "limit" => 1.5}}
      ]),
      reply("not searched")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)
    [search, null, decimal] = Enum.filter(steps, &(&1.kind == "tool"))

    digest =
      Aqua.Loop.Policy.proposal_digest(%{"tool" => "github:search", "args" => %{"q" => "x"}})

    assert {search.tool, search.action, search.dispatch_state, search.outcome, search.error,
            search.proposal_digest} ==
             {"github:search", nil, "closed", "denied",
              "github:search is not among the tools Aqua is offered", digest}

    assert {null.dispatch_state, null.outcome, null.error, null.proposal_digest} ==
             {"closed", "denied",
              "github__search: the argument q is null; leave it out or give it a value", nil}

    assert {decimal.dispatch_state, decimal.outcome, decimal.error, decimal.proposal_digest} ==
             {"closed", "denied",
              "github__search: the argument limit is a decimal number; give a whole number, " <>
                "or the number as text", nil}
  end

  test "an outside server's tool the soul is offered runs in auto, through the gate under the " <>
         "turn's authority",
       %{ctx: ctx, thread: thread} do
    tool = "ghserver:issues.list"

    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "tools_add" => [tool]
      })

    consent!(ctx, "aqua")
    turn = accept!(ctx, thread, "@aqua list the issues")
    script!([calls([{"c1", "ghserver__issues.list", %{"q" => "x"}}]), reply("done")])
    assert :completed = Task.await(run(ctx, turn), 60_000)

    {:ok, steps} = Tape.steps(ctx, turn)
    listed = Enum.find(steps, &(&1.tool == tool))

    # Dispatched, not refused by the mode or the offered set: the gate
    # decided it.
    assert {listed.dispatch_state, listed.approval_id} == {"closed", nil}
    refute listed.error =~ "among the tools"
    assert {:ok, [_ | _]} = Arca.DecisionLog.list(Sanctum.Context.actor(ctx), tool: tool)
  end

  # A call that runs is still the chain's to admit (§5.4): it goes through
  # the gate, in the chain, under the authority as it stands when the call
  # is made, whatever the turn's mode let run.
  test "a call whose authority was withdrawn while the model answered is refused at the gate",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua keep a note")

    script!([
      {:hold, self()},
      calls([{"c1", "notes", %{"action" => "keep", "name" => "n", "content" => "remember"}}]),
      reply("not kept")
    ])

    task = run(ctx, turn)
    assert_receive {:scripted_probe, worker, _}, 30_000
    {:ok, running} = Tape.turn(ctx, turn.id)
    actor = Sanctum.Context.actor(ctx)
    {:ok, refused_before} = Arca.DecisionLog.list(actor, tool: "notes", admission: :refused)

    # The invoke budget the call needs is withdrawn: the turn's
    # reservation admits no further charge.
    {1, _} =
      Arca.Repo.update_all(
        from(r in Arca.Schemas.BudgetReservation, where: r.id == ^running.budget_id),
        set: [cap: 0]
      )

    send(worker, :continue)
    _ = Task.await(task, 60_000)

    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{dispatch_state: "closed", outcome: "denied"} =
             Enum.find(steps, &(&1.action == "keep"))

    assert {:error, _} = Aqua.Notes.read(ctx, "n")

    # The refusal is the chain's: the one authority refusal of a notes call
    # the turn made, decided in the chain. The turn's root records no
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

    root = running.root_execution_id
    thread_id = thread.id
    assert is_binary(root) and is_binary(thread_id)
    %Arca.Schemas.McpLog{input: input} = Arca.Repo.get(Arca.Schemas.McpLog, call_id)

    assert %{"root_execution_id" => ^root, "thread_id" => ^thread_id} = Jason.decode!(input)
  end

  test "a turn pins the catalyst release it runs on; its continuation runs only that release, and only one speaking model/chat@1",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua fetch it")
    start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: []})

    ScriptedWorker.script([
      calls([{"c1", "http", %{"action" => "get", "url" => "https://example.test/x"}}]),
      {:crash, :before_response}
    ])

    assert {:paused, :uncertain} = Task.await(run(ctx, turn), 60_000)

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

    # The sender's next line continues it.
    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "go on"},
        steer_turn_id: turn.id
      })

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

  # A post lands while a call runs; the calls after it are skipped, and the
  # model is asked again. Each skipped call is answered by its own skipped
  # result, which names it, after the post, where the rows stand: no
  # made-up unknown outcome, and no result that names no call. Both shipped
  # adapters take that request, since each pairs the last message's result
  # with a call of the assistant message nearest before it.
  test "a post that lands while a call runs skips the calls after it, each answered by its own " <>
         "skipped result after the post in the next request",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua keep a note")
    write = %{"action" => "write", "path" => "data/x.md", "content" => "y"}
    keep = %{"action" => "keep", "name" => "n", "content" => "x"}
    start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.files"], script: []})

    ScriptedWorker.script([
      calls([{"c1", "files", write}, {"c2", "notes", keep}]),
      {:hold, self()},
      %{"written" => "data/x.md"},
      reply("ok, dropped")
    ])

    task = run(ctx, turn)

    # The write runs: the person posts.
    assert_receive {:scripted_probe, worker, _}, 30_000

    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "actually, never mind"},
        steer_turn_id: turn.id
      })

    send(worker, :continue)
    assert :completed = Task.await(task, 60_000)

    assert [_first, messages] = chat_messages()

    assert messages == [
             %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "@aqua keep a note"}]
             },
             %{
               "role" => "assistant",
               "content" => [
                 %{"type" => "tool_call", "id" => "c1", "name" => "files", "arguments" => write},
                 %{"type" => "tool_call", "id" => "c2", "name" => "notes", "arguments" => keep}
               ]
             },
             %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "actually, never mind"}]
             },
             %{
               "role" => "tool",
               "content" => [
                 tool_result(
                   "c1",
                   "files",
                   Jason.encode!(%{"written" => "data/x.md"}, pretty: true),
                   false
                 ),
                 tool_result("c2", "notes", "a newer message arrived", false)
               ]
             }
           ]

    {:ok, steps} = Tape.steps(ctx, turn)
    assert %{action: "keep", outcome: "skipped"} = Enum.find(steps, &(&1.action == "keep"))
    assert {:error, _} = Aqua.Notes.read(ctx, "n")
  end

  # A turn continued from its rows with a post waiting skips what its
  # response still proposed, undecided, and asks the model again
  # (`Aqua.Loop`'s settle). The runner dies while the turn's read runs,
  # the click after it still proposed, and the person has posted; the
  # runner started after it takes the turn over. The browser is turned off
  # too: a click decided again would be refused in the browser's words,
  # where a skipped one is never decided.
  test "a turn taken over with a post waiting skips the calls its response still proposed, " <>
         "and its model answers the post",
       %{ctx: ctx, thread: thread} do
    list = %{"action" => "list", "path" => "data"}
    click = %{"action" => "click", "ref" => "e1"}
    start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.files"], script: []})

    ScriptedWorker.script([
      calls([{"c1", "files", list}, {"c2", "browser", click}]),
      {:hold, self()},
      reply("left it")
    ])

    turn_id = send!(ctx, thread, "tidy up")
    assert_receive {:scripted_probe, _held_read, _child}, 30_000

    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "actually, leave it"},
        steer_turn_id: turn_id
      })

    assert {:ok, false} = Aqua.BrowserSetting.put(ctx, false)
    Process.exit(Aqua.Runner.whereis(thread.id), :kill)
    turn = ended!(ctx, turn_id)

    assert %{status: "completed", error: nil, recovery_attempts: 1} = turn

    # The read, opened again for its replay, and the click are skipped,
    # neither run nor decided again.
    assert step_rows(ctx, turn) == [
             model_row("ok"),
             %{call_row("files", "list", "skipped", nil) | generation: 1},
             call_row("browser", "click", "skipped", nil),
             model_row("ok")
           ]

    # The model is asked again with the post, the restart the takeover
    # wrote, and each skipped call answered by its own skipped result.
    skipped = "a newer message arrived"

    restarted =
      "[The server restarted while the assistant was working; tools may have partially " <>
        "executed. the server restarted while the assistant was working]"

    assert [_first, second] = chat_messages()

    assert second == [
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "tidy up"}]},
             %{
               "role" => "assistant",
               "content" => [
                 %{"type" => "tool_call", "id" => "c1", "name" => "files", "arguments" => list},
                 %{"type" => "tool_call", "id" => "c2", "name" => "browser", "arguments" => click}
               ]
             },
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "actually, leave it"},
                 %{"type" => "text", "text" => restarted}
               ]
             },
             %{
               "role" => "tool",
               "content" => [
                 tool_result("c1", "files", skipped, false),
                 tool_result("c2", "browser", skipped, false)
               ]
             }
           ]

    assert %{kind: "text", content: "left it"} = List.last(lines(ctx, thread.id))
  end

  # The user's #7342: a file in a post sent while Aqua works reaches the
  # model as the first post's does, made by the same encoder under the same
  # media types, on its own post where that post stands, and with every
  # round after; a post that is only a file is handed its files. A copied
  # file's sources join the turn before the request that carries it is sent.
  test "a later post's files reach the model as the first post's do, in every round after",
       %{ctx: ctx, thread: thread} do
    outside = Prima.Source.outside("moon.example")
    moon = %{"filename" => "moon.png", "media_type" => "image/png", "bytes" => "MOON"}
    sun = %{"filename" => "sun.png", "media_type" => "image/png", "bytes" => "SUN"}
    notes = %{"filename" => "notes.txt", "media_type" => "text/plain", "bytes" => "two stars"}
    art = %{"filename" => "art.bmp", "media_type" => "image/bmp", "bytes" => <<66, 77, 0>>}

    {first_id, first_refs} = stored!(ctx, thread, [moon])

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{
          id: first_id,
          author: ctx.user_id,
          sent_by: "person",
          content: "@aqua keep a note of this",
          payload: %{"attachments" => first_refs}
        },
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    args = %{"action" => "write", "path" => "data/note.md", "content" => "x"}
    list = %{"action" => "list", "path" => "data"}
    start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.files"], script: []})

    ScriptedWorker.script([
      calls([{"c1", "files", args}]),
      {:hold, self()},
      %{"written" => "data/note.md"},
      {:hold, self()},
      calls([{"c2", "files", list}]),
      %{"entries" => []},
      reply("ok")
    ])

    task = run(ctx, turn)
    assert_receive {:scripted_probe, worker, _}, 30_000

    # The person posts while the call runs: words with a picture, then
    # files alone, one of them a copy that carries where it came from.
    {later_id, later_refs} = stored!(ctx, thread, [sun])
    steer!(ctx, thread, turn, later_id, "make it look like this", later_refs)
    {only_id, [notes_ref, art_ref]} = stored!(ctx, thread, [notes, art])
    sourced = Map.put(notes_ref, "sources", Prima.Source.to_json_list([outside]))
    steer!(ctx, thread, turn, only_id, "", [sourced, art_ref])

    refute outside in turn_sources(ctx, turn)
    send(worker, :continue)

    # The next request is about to be answered: the copy's sources are the
    # turn's.
    assert_receive {:scripted_probe, worker, _}, 30_000
    assert outside in turn_sources(ctx, turn)
    send(worker, :continue)
    assert :completed = Task.await(task, 60_000)

    [_first, second, third] =
      for %{input: %{"operation" => "chat", "params" => %{"messages" => m}}} <-
            ScriptedWorker.calls(),
          do: m

    image = fn name, bytes ->
      %{
        "type" => "image",
        "media_type" => "image/png",
        "data" => Base.encode64(bytes),
        "filename" => name
      }
    end

    text = &%{"type" => "text", "text" => &1}

    carried = [
      %{
        "role" => "user",
        "content" => [text.("@aqua keep a note of this"), image.("moon.png", "MOON")]
      },
      %{
        "role" => "assistant",
        "content" => [
          %{"type" => "tool_call", "id" => "c1", "name" => "files", "arguments" => args}
        ]
      },
      %{
        "role" => "user",
        "content" => [
          text.("make it look like this"),
          image.("sun.png", "SUN"),
          text.(""),
          text.("The attached file notes.txt:\n\ntwo stars"),
          text.("The file art.bmp (image/bmp) is attached, and this brain cannot read it.")
        ]
      },
      %{
        "role" => "tool",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_call_id" => "c1",
            "name" => "files",
            "content" => Jason.encode!(%{"written" => "data/note.md"}, pretty: true),
            "is_error" => false
          }
        ]
      }
    ]

    assert second == carried

    assert third ==
             carried ++
               [
                 %{
                   "role" => "assistant",
                   "content" => [
                     %{
                       "type" => "tool_call",
                       "id" => "c2",
                       "name" => "files",
                       "arguments" => list
                     }
                   ]
                 },
                 %{
                   "role" => "tool",
                   "content" => [
                     %{
                       "type" => "tool_result",
                       "tool_call_id" => "c2",
                       "name" => "files",
                       "content" => Jason.encode!(%{"entries" => []}, pretty: true),
                       "is_error" => false
                     }
                   ]
                 }
               ]
  end

  defp stored!(ctx, thread, files) do
    id = Prima.UUID7.generate_id("msg")
    {:ok, refs} = Aqua.Attachments.store(ctx, thread.id, id, files)
    {id, refs}
  end

  defp steer!(ctx, thread, turn, id, text, refs) do
    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{
          id: id,
          author: ctx.user_id,
          sent_by: "person",
          content: text,
          payload: %{"attachments" => refs}
        },
        steer_turn_id: turn.id
      })
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

    start_supervised!(
      {ScriptedWorker, ref: [@model, "catalyst:local.files", "catalyst:local.http"], script: []}
    )

    # Two rounds, a retried third, then a call whose outcome is unknown.
    ScriptedWorker.script([
      calls([{"c1", "files", %{"action" => "list", "path" => "data"}}]),
      %{"entries" => []},
      calls([{"c2", "files", %{"action" => "list", "path" => "data"}}]),
      %{"entries" => []},
      {:refuse, %{"type" => "rate_limited", "message" => "slow down"}},
      calls([{"c3", "http", %{"action" => "get", "url" => "https://example.test/x"}}]),
      {:crash, :before_response}
    ])

    assert {:paused, :uncertain} = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)
    opened = Enum.count(steps, &(&1.kind == "model"))
    assert opened == 4

    # Continued by the sender's next line: reads until the cap, which
    # counts what came before.
    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "keep going"},
        steer_turn_id: turn.id
      })

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

    # The person narrows the soul's grant to every tool but the search; the
    # soul's file, its mode and its tools, is left as it was.
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
  # disclosed to it, granted with a default entry alone. A root runs only in
  # a filled athanor (`Sanctum.Provisioning.ready/1`), and a launch decided
  # in auto starts at once.
  defp launchable_app!(ctx) do
    Sanctum.TestContext.ready!(ctx.athanor_id)
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

    # The retry is a new turn: its launch is decided on the entry
    # "Supabase 2" resolves to now, and runs at once.
    second = accept!(ctx, thread, "@aqua run it as Supabase 2 again")
    refute second.id == first.id
    assert :completed = Task.await(run(ctx, second), 60_000)

    # The new turn's launch rooted the app under the named binding, by its
    # own key.
    assert [%{authority: launched}] = Enum.filter(ScriptedWorker.calls(), &(&1.input == %{}))
    assert launched.resources.vault.entry_id == supabase.id

    assert launched.resources.vault.binding_key ==
             Prima.Authority.Blob.binding_key(app_name, "@ingress", "Supabase 2")

    {:ok, steps} = Tape.steps(ctx, second)
    assert %{dispatch_state: "closed", outcome: "ok"} = Enum.find(steps, &(&1.kind == "launch"))
  end

  # The account a launch's decision bound is read again as the launch is
  # decided again at its dispatch. A head stored damaged since the decision
  # refuses the launch in the damaged head's sentence, never a stale
  # decision and never an outcome that could not be confirmed: the thread's
  # row the pane draws, and what an MCP client reads of the thread
  # (`thread.events`, since no tool dispatches a launch), carry it. Nothing
  # of the app starts.
  test "a launch whose app's own head is stored damaged after its decision says so in " <>
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

    # The head is damaged while the read decided beside the launch is
    # admitted: after the launch's decision, before its dispatch.
    handler = {__MODULE__, make_ref()}
    {:ok, once} = Agent.start_link(fn -> false end)

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :decision, :admitted],
        fn _event, _measurements, %{tool: tool, action: action}, _config ->
          if {tool, action} == {"crew", "list"} and not Agent.get_and_update(once, &{&1, true}) do
            :ok =
              Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile_id,
                blob_digest: "sha256:" <> String.duplicate("0", 64)
              )
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
           {"c1", "execution.run",
            %{"reference" => app <> ":1.0.0", "input" => %{}, "connection" => "Work"}}
         ]),
         reply("not launched")
       ]}
    )

    turn = accept!(ctx, thread, "@aqua look, then run it as Work")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :completed = Task.await(run(ctx, turn), 60_000)
      end)

    assert Agent.get(once, & &1)

    sentence =
      "the account \"Work\" of #{app}:1.0.0 could not be read: This app's consent is " <>
        "damaged and cannot be used — revoke profile #{profile_id} and grant it again."

    # Nothing of the app started: no run of it, and no row.
    refute Enum.any?(ScriptedWorker.calls(), &(&1.input == %{}))

    assert Arca.Repo.all(
             from(e in Arca.Schemas.Execution,
               where: e.athanor_id == ^ctx.athanor_id and like(e.reference, ^"#{app}%"),
               select: e.id
             )
           ) == []

    {:ok, steps} = Tape.steps(ctx, turn)

    # Decided again as it dispatched, it was refused on the head as it
    # stood then.
    assert %{dispatch_state: "closed", outcome: "denied", result_message_id: result} =
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
  # that read the pinned page: decided in auto and run at once, its run
  # stopping at `{:probe, self()}` for `on_probe` to act on its root, by id.
  # Answers the app, the turn, the turn's sources as the app ran, the
  # root's id and the loop's result.
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
    task = run(ctx, turn)
    assert_receive {:scripted_probe, runner, root_id}, 30_000
    at_launch = turn_sources(ctx, turn)
    on_probe.(root_id)
    send(runner, :continue)

    %{
      app: app,
      turn: turn,
      at_launch: at_launch,
      root_id: root_id,
      result: Task.await(task, 60_000)
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

  test "a launch decided in auto binds the turn's sources, no grant revision and no class: the " <>
         "app roots on them under its step's own id, and its tree's ledger joins the turn by its " <>
         "completion result",
       %{ctx: ctx, thread: thread} do
    %{turn: turn, at_launch: shown, root_id: root_id, result: result} =
      launch_through_loop!(ctx, thread, %{"answered" => true}, &app_read!(ctx, &1))

    assert result == :completed

    # The decision bound the turn's sources as they stood, the pinned page
    # among them, and nothing the app read.
    assert Prima.Source.new(:pinned) in shown
    refute @app_read in shown

    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{child_execution_id: ^root_id, outcome: "ok", approval_id: nil} =
             Enum.find(steps, &(&1.kind == "launch"))

    # The app rooted under the launch step's own id, seeded with what the
    # decision bound, letting no class flow.
    actor = Sanctum.Context.actor(ctx)
    assert {:ok, %{launch_classes: []}} = Arca.Execution.flow_state(actor, root_id)
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

  # An app of the person's own with no exit at all, granted, which the
  # soul in `auto` runs at once.
  defp quiet_app!(ctx) do
    # A root runs only in a filled athanor (`Sanctum.Provisioning.ready/1`),
    # and a launch decided in auto starts at once.
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

  test "a launch in auto runs at once, on the daily thread and in a workspace thread: " <>
         "dispatched once, its step closed with the run's result, the root let go and taken " <>
         "back around it",
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
      {:ok, steps} = Tape.steps(ctx, turn)
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

  test "a launch whose run's outcome is not known stops the turn on it, and is never run again",
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

  test "a read-only member's launch is refused in the read-only sentence, and starts nothing",
       %{ctx: ctx, thread: thread} do
    # The app a launch in auto runs at once.
    app = quiet_app!(ctx)
    mode!(ctx, "aqua", "read-only")
    sentence = Aqua.Loop.Policy.read_only_sentence("Aqua")

    start_supervised!(
      {ScriptedWorker,
       ref: [@model, app],
       script: [
         calls([{"c1", "execution.run", %{"reference" => app <> ":1.0.0", "input" => %{}}}]),
         reply("not launched")
       ]}
    )

    turn = accept!(ctx, thread, "@aqua run it")
    assert :completed = Task.await(run(ctx, turn), 60_000)

    assert step_rows(ctx, turn) == [
             model_row("ok"),
             %{call_row("execution", "run", "denied", sentence) | kind: "launch"},
             model_row("ok")
           ]

    assert [%{content: ^sentence}] = Enum.filter(lines(ctx, thread.id), &(&1.kind == "system"))
    assert runs_of(ctx, app) == []
  end

  test "a launch by a soul whose tools name no execution.run is refused as not offered",
       %{ctx: ctx, thread: thread} do
    # The soul's own definition stops naming execution.run, and its grant
    # is walked again for the shape that moved.
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "tools_remove" => ["execution.run"]
      })

    consent!(ctx, "aqua")
    turn = accept!(ctx, thread, "@aqua launch the model")

    script!([
      calls([{"c1", "execution.run", %{"reference" => @model, "input" => %{}}}]),
      reply("not launched")
    ])

    assert :completed = Task.await(run(ctx, turn), 60_000)
    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{dispatch_state: "closed", outcome: "denied", approval_id: nil} =
             launch = Enum.find(steps, &(&1.kind == "launch"))

    assert {:ok, %{content: said}} = Tape.message(ctx, launch.result_message_id)
    assert said == "execution.run is not among the tools Aqua is offered"
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
      request = Prima.UUID7.generate_id("pgc")

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

    test "a page's read proposed while the model answers, with no word to the loop, runs " <>
           "with the round's own read after the answer and before the next round asks, " <>
           "and no model's request carries the page's call",
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
               %{tool: "component", purpose: "chat", outcome: "ok"} = own,
               %{kind: "model", outcome: "ok"} = second
             ] = steps

      assert page_id == page.id
      closed = step!(ctx, turn, page.id)

      for read <- [closed, own] do
        assert DateTime.compare(first.ended_at, read.started_at) != :gt
        assert DateTime.compare(read.ended_at, second.started_at) != :gt
      end

      # Its call and its answer are rows of their own, and the wire's answer.
      assert [%{kind: "page_call"}, %{kind: "page_result", content: body}] =
               page_rows(ctx, thread)

      assert %{"ok" => true} = Jason.decode!(body)

      # The second round's request carries the component call, not the page's.
      [_, %{input: %{"params" => %{"messages" => messages}}}] = requests = chats()
      sent = Jason.encode!(messages)
      [%{payload: call} | _] = page_rows(ctx, thread)
      assert sent =~ "c1"

      for request <- requests do
        refute Jason.encode!(request.input) =~ Jason.decode!(call)["tool_call_id"]
      end
    end

    test "a page's waiting launch runs before the round's own write",
         %{ctx: ctx, thread: thread} do
      app = quiet_app!(ctx)
      start_supervised!({ScriptedWorker, ref: [@model, app], script: []})

      ScriptedWorker.script([
        {:probe, self()},
        calls([
          {"c1", "notes", %{"action" => "keep", "name" => "after-page", "content" => "kept"}}
        ]),
        {:probe, self()},
        {:output, %{"answered" => true}},
        reply("done")
      ])

      turn = accept!(ctx, thread, "@aqua show it and keep a note")
      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000

      launch =
        page!(
          ctx,
          turn,
          "execution.run",
          %{
            "reference" => app <> ":1.0.0",
            "input" => %{"operation" => "go", "params" => %{}}
          },
          false
        )

      send(model, :continue)
      assert_receive {:scripted_probe, runner, _child}, 30_000
      assert {:error, {:not_found, "note", "after-page"}} = Aqua.Notes.read(ctx, "after-page")
      send(runner, :continue)

      assert :completed = Task.await(task, 60_000)
      assert %{outcome: "ok", kind: "launch"} = step!(ctx, turn, launch.id)
      assert {:ok, %{content: "kept"}} = Aqua.Notes.read(ctx, "after-page")
    end

    test "told while the model answers, it runs at once beside the model, once, and a " <>
           "continuation does not dispatch it again",
         %{ctx: ctx, thread: thread} do
      turn = accept!(ctx, thread, "@aqua fetch it")
      start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: []})

      ScriptedWorker.script([
        {:probe, self()},
        calls([{"c1", "http", %{"action" => "get", "url" => "https://example.test/x"}}]),
        {:crash, :before_response}
      ])

      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000
      page = page!(ctx, turn, "component.list", %{})

      # It closes while the model's step is still open, with no answer.
      until!(fn -> step!(ctx, turn, page.id).dispatch_state == "closed" end)
      {:ok, [%{kind: "model", dispatch_state: "dispatched"} | _]} = Tape.steps(ctx, turn)
      send(model, :continue)

      # The round's own call's outcome is unknown: the turn stops on it, and
      # the sender's next line continues it.
      assert {:paused, :uncertain} = Task.await(task, 60_000)

      {:ok, _} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "go on"},
          steer_turn_id: turn.id
        })

      ScriptedWorker.script([reply("went on")])

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

      assert %{outcome: "ok", kind: "launch", result_message_id: result} =
               step!(ctx, turn, launch.id)

      assert {:ok, %{kind: "page_result", content: body}} = Tape.message(ctx, result)
      assert %{"ok" => true, "result" => %{"answered" => true}} = Jason.decode!(body)

      # The model's answer called nothing: it is not asked again.
      assert [_one] = chats()
    end

    test "a page's write told while the model answers runs at once beside it in auto, once, " <>
           "and the model is not asked again",
         %{ctx: ctx, thread: thread} do
      turn = accept!(ctx, thread, "@aqua wait")
      script!([{:probe, self()}, reply("done")])
      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000

      page = page!(ctx, turn, "notes.keep", %{"name" => "from-page", "content" => "x"})

      # It closes while the model's step is still open, with no answer.
      until!(fn -> step!(ctx, turn, page.id).dispatch_state == "closed" end)
      {:ok, [%{kind: "model", dispatch_state: "dispatched"} | _]} = Tape.steps(ctx, turn)
      send(model, :continue)
      assert :completed = Task.await(task, 60_000)

      assert %{outcome: "ok", generation: 0, approval_id: nil} = step!(ctx, turn, page.id)
      assert {:ok, %{content: "x"}} = Aqua.Notes.read(ctx, "from-page")
      assert [_one] = chats()
    end

    test "in read-only, a page's write told while the model answers waits for the answer and " <>
           "is refused with the round's calls, the thread told once",
         %{ctx: ctx, thread: thread} do
      mode!(ctx, "aqua", "read-only")
      sentence = Aqua.Loop.Policy.read_only_sentence("Aqua")
      turn = accept!(ctx, thread, "@aqua wait")
      script!([{:probe, self()}, reply("done")])
      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000

      write = page!(ctx, turn, "notes.keep", %{"name" => "from-page", "content" => "x"})
      read = page!(ctx, turn, "component.list", %{})

      # The loop took the notice: the read ran, the write waits for the
      # model's answer.
      until!(fn -> step!(ctx, turn, read.id).dispatch_state == "closed" end)
      assert %{dispatch_state: "proposed"} = step!(ctx, turn, write.id)
      send(model, :continue)
      assert :completed = Task.await(task, 60_000)

      assert %{dispatch_state: "closed", outcome: "denied", error: ^sentence} =
               step!(ctx, turn, write.id)

      assert {:error, {:not_found, "note", "from-page"}} = Aqua.Notes.read(ctx, "from-page")
      assert [%{content: ^sentence}] = Enum.filter(lines(ctx, thread.id), &(&1.kind == "system"))
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

    test "a hand a page calls answers it with its contract's data, as the endpoint would",
         %{ctx: ctx, thread: thread} do
      start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: []})

      ScriptedWorker.script([
        {:probe, self()},
        {:output, %{"status" => 200, "data" => %{"body" => "x", "status" => 200}}},
        reply("done")
      ])

      turn = accept!(ctx, thread, "@aqua fetch")
      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000
      page = page!(ctx, turn, "http.get", %{"url" => "https://example.test/x"})
      until!(fn -> step!(ctx, turn, page.id).dispatch_state == "closed" end)
      send(model, :continue)
      assert :completed = Task.await(task, 60_000)

      %{result_message_id: result} = step!(ctx, turn, page.id)
      assert {:ok, %{content: body}} = Tape.message(ctx, result)

      assert %{"v" => 1, "ok" => true, "result" => %{"body" => "x", "status" => 200}} ==
               Jason.decode!(body)
    end

    test "a page's call with a null or a decimal argument is answered invalid_argument and " <>
           "runs nothing",
         %{ctx: ctx, thread: thread} do
      start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: []})
      ScriptedWorker.script([{:probe, self()}, reply("done")])

      turn = accept!(ctx, thread, "@aqua fetch")
      task = run(ctx, turn)
      assert_receive {:scripted_probe, model, _child}, 30_000

      null =
        page!(
          ctx,
          turn,
          "http.get",
          %{"url" => "https://example.test/x", "headers" => nil},
          false
        )

      decimal = page!(ctx, turn, "http.get", %{"url" => "https://example.test/x", "wait" => 0.5})

      until!(fn ->
        Enum.all?([null, decimal], &(step!(ctx, turn, &1.id).dispatch_state == "closed"))
      end)

      send(model, :continue)
      assert :completed = Task.await(task, 60_000)

      answers =
        for page <- [null, decimal] do
          %{result_message_id: result, outcome: "denied", proposal_digest: nil} =
            step!(ctx, turn, page.id)

          {:ok, %{content: body} = row} = Tape.message(ctx, result)
          {Tape.payload(row)["status"], Jason.decode!(body)}
        end

      assert answers == [
               {400,
                %{
                  "v" => 1,
                  "ok" => false,
                  "error" => %{
                    "class" => "invalid_argument",
                    "message" =>
                      "http.get: the argument headers is null; leave it out or give it a value",
                    "stage" => "execution"
                  }
                }},
               {400,
                %{
                  "v" => 1,
                  "ok" => false,
                  "error" => %{
                    "class" => "invalid_argument",
                    "message" =>
                      "http.get: the argument wait is a decimal number; give a whole number, " <>
                        "or the number as text",
                    "stage" => "execution"
                  }
                }}
             ]

      assert Enum.all?(ScriptedWorker.calls(), &(&1.input["operation"] in ["describe", "chat"]))
    end

    test "a page's launch whose request ends while it waits for the model's answer is " <>
           "skipped and runs nothing",
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

      {:ok, %{client_id: request}} = Tape.message(ctx, launch.message_id)
      assert {:ok, %{turn_id: turn_id}} = Tape.end_call(ctx, thread.id, request, "ended")
      assert turn_id == turn.id
      send(model, :continue)

      assert :completed = Task.await(task, 60_000)
      assert %{dispatch_state: "closed", outcome: "skipped"} = step!(ctx, turn, launch.id)
      refute Enum.any?(ScriptedWorker.calls(), &(&1.input["operation"] == "go"))
    end

    test "a turn opened on a page's call whose request ended before the turn ran records no " <>
           "step, runs nothing and completes",
         %{ctx: ctx, thread: thread} do
      app = quiet_app!(ctx)
      start_supervised!({ScriptedWorker, ref: [@model, app], script: []})
      ScriptedWorker.script([reply("put"), {:output, %{"ran" => true}}])
      put = accept!(ctx, thread, "@aqua put the page")
      assert :completed = Task.await(run(ctx, put), 60_000)

      # The turn the runner opens on a call with no turn running.
      request = Prima.UUID7.generate_id("pgc")

      call = %{
        request: request,
        name: "execution.run",
        arguments: %{"reference" => app <> ":1.0.0", "input" => %{"operation" => "go"}},
        user_id: ctx.user_id,
        put_turn_id: put.id
      }

      {:ok, %{turn: turn}} =
        Tape.accept(ctx, thread.id, %{
          message: %{
            author: Prima.Author.agent(),
            sent_by: "aqua",
            kind: "page_call",
            content: call.name,
            payload: Aqua.PageCalls.row(call),
            client_id: request
          },
          turn: %{agent: "aqua", requested_by: ctx.user_id}
        })

      assert {:ok, %{turn_id: turn_id, skipped: []}} =
               Tape.end_call(ctx, thread.id, request, "ended")

      assert turn_id == turn.id
      assert :completed = Task.await(run(ctx, turn), 60_000)
      assert {:ok, %{status: "completed"} = ended} = Tape.turn(ctx, turn.id)
      assert {:ok, []} = Tape.steps(ctx, ended)
      refute Enum.any?(ScriptedWorker.calls(), &(&1.input["operation"] == "go"))
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
