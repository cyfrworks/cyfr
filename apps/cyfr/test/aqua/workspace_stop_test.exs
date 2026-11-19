# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.WorkspaceStopTest do
  @moduledoc """
  The person's stop of a workspace thread, through its runner
  (`Aqua.Runner.stop_turn/2`, the `thread` tool's `stop`): all of the
  thread's work ends at once, Aqua's turn there and each crew member's in
  its own thread under it, with the opening still waiting for its turn,
  and the thread reads `stopped` with no report of the stop's; a stop
  that finds nothing running moves nothing, and the person's next post
  is new work there. A daily thread's stop ends that thread's own turns
  alone. The crew's delivery consumer is off in the suite
  (`:crew_delivery_enabled`), so each case drains by hand.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Aqua.{Crew, Runner, Tape}
  alias Aqua.Providers.Workspace
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Cyfr.Test.ScriptedWorker

  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    athanor = Sanctum.Test.People.athanor!(user)
    ctx = %{ctx | athanor_id: athanor.id, origin: :interactive}
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    on_exit(fn -> File.rm_rf!(tree) end)

    # The shipped brains, in a seed of this test's own; the suite's own
    # carries none. The runners stop before the tree is removed.
    Cyfr.Test.SeedBundle.lay!(~w(claude files http))
    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, %{provisioned_at: %DateTime{}}} = Sanctum.Provisioning.provision(athanor, ctx)
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])
    member!(ctx, "planner")

    {:ok, daily} = Arca.Test.Days.thread(actor(ctx))
    {:ok, ctx: ctx, daily: daily}
  end

  # A crew member the athanor made, on the scripted model, consented as a
  # person consents one.
  defp member!(ctx, name) do
    :ok =
      Arca.put(
        actor(ctx),
        Compendium.AquaPath.crew_file(name),
        "---\ntitle: #{name}\ndescription: Plans.\navoid: Building.\n" <>
          "catalyst_ref: #{@model}\nmodel: claude-sonnet-5-5\n---\n\nYou are the #{name}.\n"
      )

    {:ok, _} = Compendium.AgentIndex.sync(ctx)

    ref = Prima.AgentRef.ref(name)
    decisions = %{ref: ref, selections: [%{dep: @model, label: "default"}]}
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
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

  # Aqua's model asks the planner from its turn.
  defp ask_planner,
    do: call("a1", "crew", %{"action" => "ask", "member" => "planner", "task" => "plan it"})

  defp actor(ctx), do: Sanctum.Context.actor(ctx)
  defp rows(ctx, thread_id), do: Threads.messages(actor(ctx), thread_id)
  defp row(ctx, id), do: elem(Tape.message(ctx, id), 1)
  defp state(ctx, id), do: elem(Threads.get(actor(ctx), id), 1).workspace_state
  defp drain(ctx), do: Crew.drain(ctx.athanor_id)

  defp pending(ctx, kind) do
    {:ok, records} = Arca.Outbox.pending(actor(ctx), "crew_delivery", kind)
    records
  end

  # Every workspace_report the athanor recorded, delivered or not.
  defp reports(ctx) do
    from(r in Arca.Schemas.OutboxRecord,
      where: r.athanor_id == ^ctx.athanor_id and r.kind == "workspace_report",
      select: r.snapshot
    )
    |> Arca.Repo.all()
    |> Enum.map(&Jason.decode!/1)
  end

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

  # A model call's run is with the scripted worker, playing its script
  # (`{:probe, self()}`), and goes on to the item after it: its turn is at
  # work on it.
  defp playing! do
    assert_receive {:scripted_probe, player, _execution}, 60_000
    send(player, :continue)
  end

  defp at_work, do: [{:probe, self()}, :hang]

  # A post of the person's on a thread, which opens nothing.
  defp post!(ctx, thread, text) do
    {:ok, %{message: row}} =
      TurnStorage.accept_message(actor(ctx), thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text}
      })

    row
  end

  # The person opens a workspace thread from a post of the daily thread,
  # or sends a further ask to `workspace`.
  defp open!(ctx, daily, workspace \\ nil) do
    asked = post!(ctx, daily, "please write the moon report")

    target =
      if workspace, do: %{"workspace" => workspace.id}, else: %{"title" => "Moon report"}

    {:ok, %{workspace: id}} =
      Workspace.handle(
        "workspace",
        ctx,
        Map.merge(target, %{
          "action" => "open",
          "thread" => daily.id,
          "refs" => [asked.id],
          "ask" => "write the moon report"
        })
      )

    elem(Threads.get(actor(ctx), id), 1)
  end

  # The opening's delivery starts Aqua's turn there, on the opening row.
  defp opening_turn!(ctx, workspace) do
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    %{turn_id: id} = Enum.find(rows(ctx, workspace.id), &(&1.kind == "opening" and &1.turn_id))
    id
  end

  # The request Aqua's turn asked the planner, once its row is written.
  defp asked!(ctx, workspace) do
    wait_until(fn -> Tape.pending_requests(ctx, workspace.id) != [] end, 45_000)
    [request] = Tape.pending_requests(ctx, workspace.id)
    request
  end

  # The planner's thread under `workspace` and the turn the request's
  # delivery opened there.
  defp member_turn!(ctx, workspace, request) do
    [child] = Threads.children(actor(ctx), workspace.id)
    row = Enum.find(rows(ctx, child.id), &(Tape.payload(&1)["request_id"] == request.id))
    {child, row.turn_id}
  end

  # The thread reads stopped and nothing of its work is left: no open turn
  # in it or in a crew member's thread under it, and no runner holds any.
  defp assert_stopped(ctx, workspace) do
    assert state(ctx, workspace.id) == "stopped"

    for id <- [workspace.id | Enum.map(Threads.children(actor(ctx), workspace.id), & &1.id)] do
      assert {:ok, []} = Tape.open_turns(ctx, id)

      if Runner.whereis(id),
        do: assert(%{running: false, paused: false, queued: 0} = Runner.state(id, ctx.athanor_id))
    end
  end

  test "with Aqua at work: its turn ends, the thread reads stopped, and nothing is reported",
       %{ctx: ctx, daily: daily} do
    script!(at_work())
    workspace = open!(ctx, daily)
    aqua = opening_turn!(ctx, workspace)
    playing!()
    assert state(ctx, workspace.id) == "open"

    assert :ok = Runner.stop_turn(ctx, workspace.id)

    assert {:ok, %{status: "cancelled", error: "stopped"}} = Tape.turn(ctx, aqua)
    assert_stopped(ctx, workspace)
    assert reports(ctx) == []
  end

  test "a turn that reported its work done and still runs: the stop ends it, and the thread " <>
         "reads stopped, its report the only one",
       %{ctx: ctx, daily: daily} do
    script!([
      call("r1", "workspace", %{"action" => "report", "outcome" => "done", "summary" => "Done."})
      | at_work()
    ])

    workspace = open!(ctx, daily)
    aqua = opening_turn!(ctx, workspace)
    playing!()
    assert state(ctx, workspace.id) == "done"

    assert :ok = Runner.stop_turn(ctx, workspace.id)

    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, aqua)
    assert_stopped(ctx, workspace)
    assert [%{"outcome" => "done", "summary" => "Done.", "turn_id" => ^aqua}] = reports(ctx)
  end

  test "with a crew member at work in its thread and Aqua idle: the member's turn ends with " <>
         "no reply, and its request with it",
       %{ctx: ctx, daily: daily} do
    script!([ask_planner(), reply("Asked the planner.") | at_work()])
    workspace = open!(ctx, daily)
    aqua = opening_turn!(ctx, workspace)
    await_status(ctx, aqua, "completed")
    request = asked!(ctx, workspace)
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    {_child, planner} = member_turn!(ctx, workspace, request)
    playing!()
    assert state(ctx, workspace.id) == "open"

    assert :ok = Runner.stop_turn(ctx, workspace.id)

    assert {:ok, %{status: "cancelled", error: "stopped"}} = Tape.turn(ctx, planner)
    assert %{status: "expired"} = row(ctx, request.id)
    assert pending(ctx, "crew_reply") == []
    assert_stopped(ctx, workspace)
    assert reports(ctx) == []
  end

  test "with Aqua and a crew member both at work, through the thread tool: both turns end",
       %{ctx: ctx, daily: daily} do
    # Aqua's turn asks the planner and its next model call waits, and then
    # the planner's does.
    script!([ask_planner() | at_work() ++ at_work()])
    workspace = open!(ctx, daily)
    aqua = opening_turn!(ctx, workspace)
    request = asked!(ctx, workspace)
    playing!()
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    {_child, planner} = member_turn!(ctx, workspace, request)
    playing!()

    assert {:ok, %{stopped: true}} =
             Aqua.Providers.Thread.handle("thread", ctx, %{
               "action" => "stop",
               "thread" => workspace.id
             })

    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, aqua)
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, planner)
    assert %{status: "expired"} = row(ctx, request.id)
    assert pending(ctx, "crew_reply") == []
    assert_stopped(ctx, workspace)
    assert reports(ctx) == []
  end

  test "with an opening waiting behind Aqua's work: the stop ends both, and the opening's " <>
         "delivery after starts nothing and tells nobody",
       %{ctx: ctx, daily: daily} do
    script!(at_work())
    workspace = open!(ctx, daily)
    aqua = opening_turn!(ctx, workspace)
    playing!()
    _again = open!(ctx, daily, workspace)

    [again] =
      Enum.filter(rows(ctx, workspace.id), &(&1.kind == "opening" and is_nil(&1.turn_id)))

    assert :ok = Runner.stop_turn(ctx, workspace.id)

    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, aqua)
    assert %{status: "expired", turn_id: nil} = row(ctx, again.id)
    assert_stopped(ctx, workspace)

    # Its delivery is refused with its receipt alone: the person stopped
    # the work before it started, which is no refusal to tell of.
    assert {:ok, %{"refused" => 1}} = drain(ctx)
    assert pending(ctx, "workspace_open") == []
    assert %{status: "expired", turn_id: nil} = row(ctx, again.id)
    assert_stopped(ctx, workspace)
    assert reports(ctx) == []
    {:ok, today} = Aqua.Day.current(ctx)
    refute Enum.any?(rows(ctx, today.id), &(&1.kind == "report"))
  end

  test "a stop that finds nothing running leaves a finished thread as its report left it",
       %{ctx: ctx, daily: daily} do
    script!([
      call("r1", "workspace", %{"action" => "report", "outcome" => "done", "summary" => "Done."}),
      reply("Reported.")
    ])

    workspace = open!(ctx, daily)
    aqua = opening_turn!(ctx, workspace)
    await_status(ctx, aqua, "completed")
    assert state(ctx, workspace.id) == "done"
    reported = reports(ctx)

    assert :ok = Runner.stop_turn(ctx, workspace.id)

    assert state(ctx, workspace.id) == "done"
    assert reports(ctx) == reported
  end

  test "the person's post after a stop is new work: the thread is at work again",
       %{ctx: ctx, daily: daily} do
    script!(at_work() ++ [reply("Back at it.")])
    workspace = open!(ctx, daily)
    _aqua = opening_turn!(ctx, workspace)
    playing!()
    assert :ok = Runner.stop_turn(ctx, workspace.id)
    assert state(ctx, workspace.id) == "stopped"

    assert {:ok, %{admitted: :turn, turn_id: again}} =
             Runner.send_message(ctx, workspace.id, "carry on")

    assert state(ctx, workspace.id) == "open"
    await_status(ctx, again, "completed")

    # Nothing ended the new work: the thread stays at work, and the stop
    # reported nothing.
    assert state(ctx, workspace.id) == "open"
    assert reports(ctx) == []
  end

  test "a daily thread's stop ends its own turns alone: a crew member at work under it goes on",
       %{ctx: ctx, daily: daily} do
    script!([ask_planner() | at_work() ++ at_work()])
    {:ok, %{turn_id: aqua}} = Runner.send_message(ctx, daily.id, "plan the moon report")
    request = asked!(ctx, daily)
    playing!()
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    {child, planner} = member_turn!(ctx, daily, request)
    playing!()

    assert :ok = Runner.stop_turn(ctx, daily.id)

    assert {:ok, %{status: "cancelled", error: "stopped"}} = Tape.turn(ctx, aqua)
    assert {:ok, %{status: "running"}} = Tape.turn(ctx, planner)
    assert %{running: true, turn_id: ^planner} = Runner.state(child.id, ctx.athanor_id)
    assert %{status: "pending"} = row(ctx, request.id)
    assert %{workspace_state: nil} = elem(Threads.get(actor(ctx), daily.id), 1)
    assert reports(ctx) == []
  end

  test "a deletion of the room ends a crew holder absent from this node's registry, on hearing it",
       %{ctx: ctx, daily: daily} do
    script!([ask_planner(), reply("Asked the planner.") | at_work()])
    workspace = open!(ctx, daily)
    aqua = opening_turn!(ctx, workspace)
    await_status(ctx, aqua, "completed")
    request = asked!(ctx, workspace)
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    {child, planner} = member_turn!(ctx, workspace, request)
    playing!()
    runner = Runner.whereis(child.id)
    holder = :sys.get_state(runner).live.task.pid
    holding = Process.monitor(holder)
    running = Process.monitor(runner)

    on_exit(fn ->
      Aqua.Loop.Worker.stop(holder)
      if Process.alive?(runner), do: GenServer.stop(runner, :normal)
    end)

    # As a peer's runner reads to the deleting member: no entry in its
    # registry, its processes and subscription alive.
    :sys.replace_state(runner, fn state ->
      Registry.unregister(Aqua.RunnerRegistry, child.id)
      state
    end)

    assert {:ok, %{cancelled: cancelled}} = Tape.delete_thread(ctx, workspace.id)
    assert Enum.any?(cancelled, &(&1.turn_id == planner))
    assert :ok = Runner.stop_cancelled(cancelled)
    assert {:error, :not_found} = Tape.turn(ctx, planner)

    assert_receive {:DOWN, ^holding, :process, ^holder, _}, 5_000
    assert_receive {:DOWN, ^running, :process, ^runner, :normal}, 5_000
  end

  test "the stop ends a crew holder absent from this node's registry, on hearing it", %{
    ctx: ctx,
    daily: daily
  } do
    script!([ask_planner(), reply("Asked the planner.") | at_work()])
    workspace = open!(ctx, daily)
    aqua = opening_turn!(ctx, workspace)
    await_status(ctx, aqua, "completed")
    request = asked!(ctx, workspace)
    assert {:ok, %{"applied" => 1}} = drain(ctx)
    {child, planner} = member_turn!(ctx, workspace, request)
    playing!()
    runner = Runner.whereis(child.id)
    holder = :sys.get_state(runner).live.task.pid
    monitor = Process.monitor(holder)
    # Model the one condition stop_cancelled sees for a peer's runner:
    # no entry in this node's registry. Leave its processes and bus subscription alive.
    on_exit(fn ->
      Aqua.Loop.Worker.stop(holder)
      if Process.alive?(runner), do: GenServer.stop(runner, :normal)
    end)

    :sys.replace_state(runner, fn state ->
      Registry.unregister(Aqua.RunnerRegistry, child.id)
      state
    end)

    assert Runner.whereis(child.id) == nil
    assert :ok = Runner.stop_turn(ctx, workspace.id)
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, planner)
    assert state(ctx, workspace.id) == "stopped"
    # A round trip ensures the cancellation broadcasts have been handled.
    _ = :sys.get_state(runner)
    assert_receive {:DOWN, ^monitor, :process, ^holder, _}, 1_000
  end
end
