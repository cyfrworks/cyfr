# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.CrewTest do
  @moduledoc """
  The crew on the thread layer: a request in a room is delivered into its
  member's child thread, the member's turn there replies on the room on
  every exit, and who may post where is the admission rule's. The
  delivery consumer is off in the suite (`:crew_delivery_enabled`), so
  each case drains by hand, which is what its wake and its tick do.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Aqua.{Approvals, Crew, Runner, Tape}
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @seed_root Path.expand("../../../../seed", __DIR__)
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    ctx = %{ctx | athanor_id: Sanctum.Test.People.athanor!(user).id, origin: :interactive}
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    on_exit(fn -> File.rm_rf!(tree) end)

    # The shipped catalysts the turns run are read from the repository's
    # seed tree; the suite's own carries none.
    Prima.Test.Env.put_app_env(:arca, :seed_path, @seed_root)
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, _} = Bootstrap.run(ctx)

    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"},
      origins: [:interactive, :programmatic]
    )

    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, room} = Threads.create(Sanctum.Context.actor(ctx))
    :ok = Runner.subscribe(room.id, ctx.athanor_id)
    {:ok, ctx: ctx, room: room}
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @model, script: items})

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  defp call(id, name, args),
    do: %{
      "content" => [%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}],
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  defp actor(ctx), do: Sanctum.Context.actor(ctx)
  defp drain(ctx), do: Crew.drain(ctx.athanor_id)
  defp rows(ctx, thread_id), do: Threads.messages(actor(ctx), thread_id)
  defp row(ctx, id), do: elem(Tape.message(ctx, id), 1)

  defp child!(ctx, room, member) do
    [child] = Enum.filter(Threads.children(actor(ctx), room.id), &(&1.agent == member))
    child
  end

  # The turn a delivered request opened or joined, by the request it carries.
  defp delivered_turn(ctx, child, request_id) do
    row =
      Enum.find(rows(ctx, child.id), &(Tape.payload(&1)["request_id"] == request_id))

    row && row.turn_id
  end

  # A turn that ends otherwise is named with the status and error it has.
  defp await_status(ctx, turn_id, status) do
    wait_until(
      fn -> match?({:ok, %{status: ^status}}, Tape.turn(ctx, turn_id)) end,
      45_000,
      "turn #{turn_id} to be #{status}"
    )
  rescue
    error in ExUnit.AssertionError ->
      {:ok, turn} = Tape.turn(ctx, turn_id)
      flunk("#{error.message}; it is #{turn.status} (#{inspect(turn.error)})")
  end

  # A request as `crew.ask` writes it, committed and never broadcast.
  defp soul_request!(ctx, room, member, task, job \\ %{}) do
    {:ok, %{message: row}} =
      TurnStorage.accept_message(actor(ctx), room.id, %{
        message: %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          addressee: member,
          status: "pending",
          content: task
        },
        request: %{
          member: member,
          task: task,
          tools: Map.get(job, :tools),
          options: Map.get(job, :options, %{}),
          person_id: ctx.user_id,
          origin: :interactive
        }
      })

    row
  end

  defp replies_of(ctx, turn_id) do
    {:ok, records} = Arca.Outbox.pending(actor(ctx), "crew_delivery", "crew_reply")
    Enum.filter(records, &(&1.source_id == turn_id))
  end

  defp room_turns(ctx, room) do
    Arca.Repo.all(
      from(t in Arca.Schemas.Turn,
        where: t.athanor_id == ^ctx.athanor_id and t.thread_id == ^room.id,
        order_by: [asc: t.accepted_at]
      )
    )
  end

  defp pending_records(ctx) do
    for kind <- ~w(crew_request crew_reply),
        record <- elem(Arca.Outbox.pending(actor(ctx), "crew_delivery", kind), 1),
        do: record
  end

  # The planner asks before it keeps a note, so its turn raises a card.
  defp planner_asks!(ctx) do
    {:ok, agent} = Compendium.AquaAgent.get(ctx, "planner")

    :ok =
      Arca.put(
        actor(ctx),
        Compendium.AquaPath.agent_file("planner"),
        Compendium.AquaAgent.serialize(%{
          agent
          | tool_policy: Map.put(agent.tool_policy, "notes.keep", "ask")
        })
      )

    {:ok, _} = Compendium.AgentIndex.sync(ctx)

    # An edited file is the person's to consent to again.
    ref = "agent:local.planner"
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, %{ref: ref})

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: %{ref: ref},
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
  end

  test "a person's @name is a request their member answers in its own thread, and the reply lands under it, waking nobody",
       %{ctx: ctx, room: room} do
    script!([reply("Plan: read, then write.")])

    assert {:ok, %{admitted: :request, turn_id: nil, message_id: request_id}} =
             Runner.send_message(ctx, room.id, "@planner plan the move")

    assert %{addressee: "planner", sent_by: "person", status: "pending"} = row(ctx, request_id)

    assert {:ok, %{"applied" => 1}} = drain(ctx)
    child = child!(ctx, room, "planner")
    assert %{kind: "crew", parent_id: parent} = child
    assert parent == room.id

    turn_id = delivered_turn(ctx, child, request_id)
    await_status(ctx, turn_id, "completed")

    assert {:ok, %{sent_by: "person", asking_thread_id: asking, request_id: ^request_id}} =
             Tape.turn(ctx, turn_id)

    assert asking == room.id

    assert {:ok, %{"applied" => 1}} = drain(ctx)
    reply = Enum.find(rows(ctx, room.id), &(&1.reply_to == request_id))

    assert %{
             sent_by: "planner",
             addressee: "person",
             outcome: "done",
             content: "Plan: read, then write."
           } = reply

    assert %{status: "answered", resolved_by: resolved_by} = row(ctx, request_id)
    assert resolved_by == reply.id
    assert_receive %ThreadEvent{kind: :reply, data: %{id: reply_id}}, 5_000
    assert reply_id == reply.id

    # Room content: the person's own request's answer opens no turn.
    assert room_turns(ctx, room) == []
    assert pending_records(ctx) == []
  end

  test "a request committed by a runner that died before it broadcast is delivered by the tick",
       %{ctx: ctx, room: room} do
    script!([reply("done here"), reply("noted")])
    request = soul_request!(ctx, room, "planner", "check the logs")

    assert %{} = Map.new(Crew.drain_all())
    assert {:ok, "applied"} = outcome(ctx, "message", request.id)

    child = child!(ctx, room, "planner")
    await_status(ctx, delivered_turn(ctx, child, request.id), "completed")

    # The reply to the soul's request opens the soul's turn on the room.
    assert %{} = Crew.drain_all()
    reply = Enum.find(rows(ctx, room.id), &(&1.reply_to == request.id))
    assert %{sent_by: "planner", addressee: "aqua", outcome: "done", turn_id: soul} = reply
    await_status(ctx, soul, "completed")

    assert {:ok, %{agent: "aqua", sent_by: "planner", message_id: opened_by}} =
             Tape.turn(ctx, soul)

    assert opened_by == reply.id
  end

  test "the soul's crew.ask writes the request in its turn and answers its id; the turn goes on",
       %{ctx: ctx, room: room} do
    script!([
      call("c1", "crew", %{
        "action" => "ask",
        "member" => "planner",
        "task" => "list the risks",
        "tools" => ["files.read"]
      }),
      reply("Asked the planner."),
      reply("Two risks."),
      reply("The planner found two risks.")
    ])

    {:ok, %{turn_id: soul}} = Runner.send_message(ctx, room.id, "what could go wrong?")
    await_status(ctx, soul, "completed")

    request = Enum.find(rows(ctx, room.id), &(&1.addressee == "planner" and &1.status))

    assert %{sent_by: "aqua", author: "aqua", status: "pending", content: "list the risks"} =
             request

    assert %{"from_turn" => ^soul} = Tape.payload(request)

    {:ok, steps} = Tape.steps(ctx, elem(Tape.turn(ctx, soul), 1))
    assert %{outcome: "ok"} = Enum.find(steps, &(&1.tool == "crew" and &1.action == "ask"))

    assert {:ok, %{"applied" => 1}} = drain(ctx)
    child = child!(ctx, room, "planner")
    await_status(ctx, delivered_turn(ctx, child, request.id), "completed")

    # The job was narrowed to what the request named, under the member's
    # own policy.
    %{input: %{"params" => %{"tools" => tools}}} =
      Enum.find(
        ScriptedWorker.calls(),
        &(&1.input["operation"] == "chat" and hd(&1.authority.chain) == "agent:local.planner")
      )

    assert [%{"name" => "files"} = files | _] = tools
    assert files["parameters"]["properties"]["action"]["enum"] == ["read"]
    refute Enum.any?(tools, &(&1["name"] in ["storage", "aqua", "component"]))

    assert {:ok, %{"applied" => 1}} = drain(ctx)
    reply = Enum.find(rows(ctx, room.id), &(&1.reply_to == request.id))
    await_status(ctx, reply.turn_id, "completed")
    assert reply.turn_id != soul
  end

  test "an option the member's brain does not declare fails its turn, and the reply says why",
       %{ctx: ctx, room: room} do
    script!([
      call("c1", "crew", %{
        "action" => "ask",
        "member" => "planner",
        "task" => "think hard",
        "options" => %{"effort" => "high"}
      }),
      reply("Asked.")
    ])

    {:ok, %{turn_id: soul}} = Runner.send_message(ctx, room.id, "think about it")
    await_status(ctx, soul, "completed")
    request = Enum.find(rows(ctx, room.id), &(&1.addressee == "planner" and &1.status))

    assert {:ok, %{"applied" => 1}} = drain(ctx)
    child = child!(ctx, room, "planner")
    await_status(ctx, delivered_turn(ctx, child, request.id), "failed")

    # The reply opens the soul's next turn, which has no script left and
    # fails; the reply itself is what is asserted.
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    reply = Enum.find(rows(ctx, room.id), &(&1.reply_to == request.id))
    assert %{outcome: "failed", content: content} = reply
    assert content =~ "options.effort"
  end

  test "a request from another sender queues as its own turn while the same sender steers, and one reply answers every request it steered",
       %{ctx: ctx, room: room} do
    # The steer lands while the first model call runs, so the turn takes
    # one more round to answer it before it ends.
    script!([
      {:probe, self()},
      reply("first"),
      reply("first, and also"),
      reply("the soul's")
    ])

    {:ok, %{message_id: first}} = Runner.send_message(ctx, room.id, "@planner first")
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    assert_receive {:scripted_probe, worker, _}, 60_000

    child = child!(ctx, room, "planner")
    opened = delivered_turn(ctx, child, first)

    soul = soul_request!(ctx, room, "planner", "from the soul")
    {:ok, %{message_id: also}} = Runner.send_message(ctx, room.id, "@planner also")
    assert {:ok, %{"applied" => 2}} = drain(ctx)

    queued = delivered_turn(ctx, child, soul.id)
    assert queued != opened
    assert delivered_turn(ctx, child, also) == opened
    assert %{running: true, queued: 1} = Runner.state(child.id, ctx.athanor_id)

    send(worker, :continue)
    await_status(ctx, opened, "completed")
    await_status(ctx, queued, "completed")

    assert {:ok, %{"applied" => 2}} = drain(ctx)
    room_rows = rows(ctx, room.id)
    one = Enum.find(room_rows, &(&1.reply_to == first))
    assert %{outcome: "done", content: "first, and also"} = one
    assert Tape.payload(one)["answers"] == [first, also]
    assert %{status: "answered", resolved_by: by_one} = row(ctx, first)
    assert %{status: "answered", resolved_by: ^by_one} = row(ctx, also)
    assert by_one == one.id
    refute Enum.any?(room_rows, &(&1.reply_to == also))

    assert %{status: "answered"} = row(ctx, soul.id)
  end

  test "a card in a child turn writes a notice on the room; its sender steers the paused turn, and the person's decision continues it",
       %{ctx: ctx, room: room} do
    planner_asks!(ctx)

    script!([
      call("k1", "notes", %{"action" => "keep", "name" => "plan", "content" => "x"}),
      reply("kept, and the rest")
    ])

    {:ok, %{message_id: first}} = Runner.send_message(ctx, room.id, "@planner keep the plan")
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    child = child!(ctx, room, "planner")
    turn_id = delivered_turn(ctx, child, first)
    await_status(ctx, turn_id, "paused")

    assert {:ok, %{"applied" => 1}} = drain(ctx)
    notice = Enum.find(rows(ctx, room.id), &(&1.reply_to == first))
    assert %{outcome: "needs_you", sent_by: "planner", addressee: "person"} = notice
    assert %{"from_thread" => from, "approval_id" => approval_id} = Tape.payload(notice)
    assert from == child.id
    assert %{status: "pending"} = row(ctx, first)

    {:ok, %{message_id: more}} = Runner.send_message(ctx, room.id, "@planner and the rest")
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    assert delivered_turn(ctx, child, more) == turn_id

    assert {:ok, %{decision: "approved"}} =
             Approvals.resolve(ctx, approval_id, %{decision: :approved})

    await_status(ctx, turn_id, "completed")
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    reply = Enum.find(rows(ctx, room.id), &(&1.reply_to == first and &1.outcome == "done"))
    assert Tape.payload(reply)["answers"] == [first, more]
    assert %{status: "answered"} = row(ctx, more)
  end

  test "a busy child thread leaves the request pending, and the next tick delivers it",
       %{ctx: ctx, room: room} do
    # The soul's request holds the member's thread on a card; the
    # person's requests, another sender's, queue behind it until the queue
    # is full. Every model call here is a plain answer but the card's.
    planner_asks!(ctx)

    script!([
      call("k1", "notes", %{"action" => "keep", "name" => "plan", "content" => "x"})
      | for(n <- 1..16, do: reply("answer #{n}"))
    ])

    held = soul_request!(ctx, room, "planner", "hold the floor")
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    child = child!(ctx, room, "planner")
    held_turn = delivered_turn(ctx, child, held.id)
    await_status(ctx, held_turn, "paused")

    asks =
      for n <- 1..9 do
        {:ok, %{admitted: :request, message_id: id}} =
          Runner.send_message(ctx, room.id, "@planner wait #{n}")

        id
      end

    {waiting, [last]} = Enum.split(asks, 8)
    assert {:ok, %{"pending" => 1}} = drain(ctx)
    assert %{paused: true, queued: 8} = Runner.state(child.id, ctx.athanor_id)
    assert :none = outcome(ctx, "message", last)
    assert delivered_turn(ctx, child, last) == nil
    for id <- waiting, do: assert({:ok, "applied"} = outcome(ctx, "message", id))

    {:ok, paused} = Tape.turn(ctx, held_turn)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    assert {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})

    for id <- [held.id | waiting],
        do: await_status(ctx, delivered_turn(ctx, child, id), "completed")

    assert {:ok, _} = drain(ctx)
    assert {:ok, "applied"} = outcome(ctx, "message", last)
    await_status(ctx, delivered_turn(ctx, child, last), "completed")
  end

  describe "a delivery that steers a turn a direct post opened" do
    test "gives the running turn its reply address, and the turn's end answers it",
         %{ctx: ctx, room: room} do
      script!([{:probe, self()}, reply("started"), reply("started, and more")])
      {:ok, child} = Threads.crew_thread(actor(ctx), room.id, "planner")
      {:ok, %{turn_id: direct}} = Runner.send_message(ctx, child.id, "start on the plan")
      assert_receive {:scripted_probe, worker, _}, 60_000

      {:ok, %{message_id: request}} = Runner.send_message(ctx, room.id, "@planner and more")
      assert {:ok, %{"applied" => 1}} = drain(ctx)
      assert delivered_turn(ctx, child, request) == direct

      assert {:ok, %{asking_thread_id: asking, request_id: ^request}} = Tape.turn(ctx, direct)
      assert asking == room.id

      send(worker, :continue)
      await_status(ctx, direct, "completed")
      assert {:ok, %{"applied" => 1}} = drain(ctx)
      reply = Enum.find(rows(ctx, room.id), &(&1.reply_to == request))
      assert %{outcome: "done", content: "started, and more"} = reply
      assert %{status: "answered"} = row(ctx, request)
    end

    test "gives the paused turn its reply address, and the turn's end answers it",
         %{ctx: ctx, room: room} do
      planner_asks!(ctx)

      script!([
        call("k1", "notes", %{"action" => "keep", "name" => "plan", "content" => "x"}),
        reply("kept, and more")
      ])

      {:ok, child} = Threads.crew_thread(actor(ctx), room.id, "planner")
      {:ok, %{turn_id: direct}} = Runner.send_message(ctx, child.id, "keep the plan")
      await_status(ctx, direct, "paused")

      {:ok, %{message_id: request}} = Runner.send_message(ctx, room.id, "@planner and more")
      assert {:ok, %{"applied" => _}} = drain(ctx)
      assert delivered_turn(ctx, child, request) == direct

      {:ok, paused} = Tape.turn(ctx, direct)
      {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
      assert {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})
      await_status(ctx, direct, "completed")

      assert {:ok, %{"applied" => _}} = drain(ctx)
      reply = Enum.find(rows(ctx, room.id), &(&1.reply_to == request and &1.outcome == "done"))
      assert %{content: "kept, and more"} = reply
      assert %{status: "answered"} = row(ctx, request)
    end
  end

  test "a request with other tools or brain options queues as its own turn, never steering one with another job",
       %{ctx: ctx, room: room} do
    script!([{:probe, self()}, reply("open"), reply("narrowed")])

    open = soul_request!(ctx, room, "planner", "look at everything")
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    assert_receive {:scripted_probe, worker, _}, 60_000
    child = child!(ctx, room, "planner")
    first = delivered_turn(ctx, child, open.id)

    narrowed = soul_request!(ctx, room, "planner", "read only", %{tools: ["files.read"]})
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    second = delivered_turn(ctx, child, narrowed.id)
    assert second != first
    assert %{running: true, queued: 1} = Runner.state(child.id, ctx.athanor_id)

    send(worker, :continue)
    await_status(ctx, first, "completed")
    await_status(ctx, second, "completed")
    assert {:ok, %{options: options}} = Tape.turn(ctx, second)
    assert %{"tools" => ["files.read"]} = Jason.decode!(options)
  end

  test "a narrowed job is refused a call outside its tools before any card, and goes on",
       %{ctx: ctx, room: room} do
    planner_asks!(ctx)

    script!([
      call("k1", "notes", %{"action" => "keep", "name" => "plan", "content" => "x"}),
      reply("read only, as asked")
    ])

    request = soul_request!(ctx, room, "planner", "read the plan", %{tools: ["files.read"]})
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    turn_id = delivered_turn(ctx, child!(ctx, room, "planner"), request.id)
    await_status(ctx, turn_id, "completed")

    {:ok, turn} = Tape.turn(ctx, turn_id)
    {:ok, steps} = Tape.steps(ctx, turn)
    assert %{outcome: "denied", approval_id: nil} = Enum.find(steps, &(&1.action == "keep"))
    assert {:ok, []} = Tape.pending_approvals(ctx, turn)
  end

  test "archiving cancels every open turn in its own transaction, the suspended one included, and leaves none to recover",
       %{ctx: ctx, room: room} do
    script!([{:probe, self()}])
    request = soul_request!(ctx, room, "planner", "take a while")
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    assert_receive {:scripted_probe, _worker, _}, 60_000
    child = child!(ctx, room, "planner")
    turn_id = delivered_turn(ctx, child, request.id)

    assert {:ok, %{suspended: true}} = Runner.suspend_turn(ctx, child.id, turn: turn_id)
    assert {:ok, %{status: "paused", paused_reason: "suspended"}} = Tape.turn(ctx, turn_id)

    # The store's write alone, as a crash before the runner's stop leaves it.
    assert {:ok, %{thread: %{archived_at: %DateTime{}}}} = Tape.archive(ctx, child.id)
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, turn_id)
    assert {:ok, []} = Tape.open_turns(ctx, child.id)
    assert [%{snapshot: %{"outcome" => "cancelled"}}] = replies_of(ctx, turn_id)
    assert {:error, :not_open} = Runner.recover_turn(ctx, child.id, turn_id)

    assert {:ok, %{"applied" => 1}} = drain(ctx)
    assert %{status: "answered"} = row(ctx, request.id)
  end

  test "archiving a working member's thread aborts its loop through the runner, the call's independent catalog handler with it",
       %{ctx: ctx, room: room} do
    start_supervised!(
      {ScriptedWorker,
       ref: [@model, "catalyst:local.http"],
       script: [
         call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
         {:probe, self()},
         reply("never sent")
       ]}
    )

    request = soul_request!(ctx, room, "web", "fetch x")
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    assert_receive {:scripted_probe, _call, _}, 60_000
    child = child!(ctx, room, "web")
    turn_id = delivered_turn(ctx, child, request.id)
    runner = Runner.whereis(child.id)
    %{live: %{task: %Aqua.Loop.Worker.Handle{pid: loop}}} = :sys.get_state(runner)
    {:ok, turn} = Tape.turn(ctx, turn_id)
    {:ok, steps} = Tape.steps(ctx, turn)
    get = Enum.find(steps, &(&1.action == "get"))
    assert get.dispatch_state == "dispatched"
    handle = {turn_id, get.id, get.generation}
    test = self()

    # The handler is independent of the Aqua worker tree, claimed and
    # registered under the call's handle as a catalog dispatch's is
    # (`Aqua.RunnerTest`'s restarted-runner case): only the handle's
    # cancel stops it.
    claimer =
      spawn(fn ->
        :ok = Sanctum.RunningTasks.claim(handle)

        Task.Supervisor.async_nolink(Sanctum.Gate.TaskSupervisor, fn ->
          :ok = Sanctum.RunningTasks.register_handle(handle, self())
          send(test, {:handler_registered, self()})
          Process.sleep(:infinity)
        end)

        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      Process.exit(claimer, :kill)
      Aqua.Ops.cancel_call(handle)
      Aqua.Ops.release_call(handle)
    end)

    assert_receive {:handler_registered, handler}, 5_000
    handler_ref = Process.monitor(handler)
    loop_ref = Process.monitor(loop)

    assert {:ok, %{archived: true}} =
             Aqua.Providers.Thread.handle("thread", ctx, %{
               "action" => "archive",
               "thread" => child.id
             })

    assert_receive {:DOWN, ^handler_ref, :process, ^handler, :cancelled}, 5_000
    assert_receive {:DOWN, ^loop_ref, :process, ^loop, _}, 5_000
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, turn_id)
    assert %{running: false} = Runner.state(child.id, ctx.athanor_id)
    assert [%{snapshot: %{"outcome" => "cancelled"}}] = replies_of(ctx, turn_id)
  end

  test "a delivered request carries the request's attachments to the member's turn",
       %{ctx: ctx, room: room} do
    script!([reply("I see a square.")])
    message_id = Prima.UUID7.generate_id("msg")

    {:ok, refs} =
      Aqua.Attachments.store(ctx, room.id, message_id, [
        %{"filename" => "square.png", "media_type" => "image/png", "bytes" => "PNGBYTES"}
      ])

    {:ok, %{admitted: :request}} =
      Runner.send_message(ctx, room.id, "@planner what is this?",
        id: message_id,
        attachments: refs
      )

    assert {:ok, %{"applied" => 1}} = drain(ctx)
    child = child!(ctx, room, "planner")
    await_status(ctx, delivered_turn(ctx, child, message_id), "completed")

    [delivered | _] = rows(ctx, child.id)
    assert Tape.payload(delivered)["attachments"] == refs

    %{input: %{"params" => %{"messages" => messages}}} =
      Enum.find(
        ScriptedWorker.calls(),
        &(&1.input["operation"] == "chat" and hd(&1.authority.chain) == "agent:local.planner")
      )

    blocks = Enum.flat_map(messages, &List.wrap(&1["content"]))

    assert Enum.any?(
             blocks,
             &(&1["type"] == "image" and &1["data"] == Base.encode64("PNGBYTES"))
           )
  end

  test "crew.ask refuses brain options that are not named scalars", %{ctx: ctx} do
    assert {:error, {:invalid_argument, _}} =
             Crew.ask(ctx, %{"member" => "planner", "task" => "x", "options" => %{"a" => %{}}})

    assert {:error, {:invalid_argument, _}} =
             Crew.ask(ctx, %{"member" => "planner", "task" => "x", "options" => %{"" => 1}})
  end

  test "a dead member's claim is taken over once its lease lapsed", %{ctx: ctx, room: room} do
    script!([reply("taken over")])
    request = soul_request!(ctx, room, "planner", "go")

    {:ok, _} = Arca.JobClaims.claim("crew_delivery", ctx.athanor_id, "boot_dead", 60_000)
    assert :busy = drain(ctx)

    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.JobClaim,
          where: c.kind == "crew_delivery" and c.key == ^ctx.athanor_id
        ),
        set: [lease_until: past]
      )

    assert {:ok, %{"applied" => 1}} = drain(ctx)
    assert {:ok, "applied"} = outcome(ctx, "message", request.id)
    assert {:ok, %{owner: owner}} = Arca.JobClaims.read("crew_delivery", ctx.athanor_id)
    assert owner == Prima.Boot.id()
  end

  test "the admission rule refuses a member posting anywhere but the thread and request that asked it",
       %{ctx: ctx, room: room} do
    request = soul_request!(ctx, room, "planner", "go")
    {:ok, elsewhere} = Threads.create(actor(ctx))

    assert {:error, :not_addressable} =
             Runner.send_message(ctx, elsewhere.id, "posted elsewhere",
               sent_by: "planner",
               reply: %{request: request, outcome: "done", answers: [request.id]}
             )

    assert {:error, :not_addressable} =
             Runner.send_message(ctx, room.id, "posted as another",
               sent_by: "builder",
               reply: %{request: request, outcome: "done", answers: [request.id]}
             )

    {:ok, child} = Threads.crew_thread(actor(ctx), room.id, "planner")

    assert {:error, :not_addressable} =
             Runner.send_message(ctx, child.id, "@builder over there")

    # A member's turn asks nobody: crew.ask from a child thread is refused.
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor(ctx), child.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "hi"},
        turn: %{agent: "planner", requested_by: ctx.user_id, origin: :interactive}
      })

    assert {:error, :not_addressable} =
             Crew.ask(ctx, %{
               "member" => "builder",
               "task" => "help",
               "thread_id" => child.id,
               "root_execution_id" => turn.root_execution_id || "none"
             })

    assert [%{id: id}] = Threads.pending_requests(actor(ctx), thread_id: room.id)
    assert id == request.id
    refute Enum.any?(rows(ctx, elsewhere.id), &(&1.content == "posted elsewhere"))
  end

  test "an archived child thread admits nothing, and the next request opens a new one",
       %{ctx: ctx, room: room} do
    script!([reply("in the new thread")])
    {:ok, old} = Threads.crew_thread(actor(ctx), room.id, "planner")
    {:ok, _} = Tape.archive(ctx, old.id)

    assert {:error, :thread_archived} = Runner.send_message(ctx, old.id, "still there?")

    request = soul_request!(ctx, room, "planner", "anew")
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    [_old, new] = Threads.children(actor(ctx), room.id)
    assert new.id != old.id and is_nil(new.archived_at)
    await_status(ctx, delivered_turn(ctx, new, request.id), "completed")
  end

  defp outcome(ctx, source_kind, source_id) do
    from(c in Arca.Schemas.ConsumerReceipt,
      where: c.athanor_id == ^ctx.athanor_id and c.consumer == "crew_delivery",
      where: c.source_kind == ^source_kind and c.source_id == ^source_id,
      select: c.outcome
    )
    |> Arca.Repo.one()
    |> case do
      nil -> :none
      outcome -> {:ok, outcome}
    end
  end
end
