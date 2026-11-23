# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RunnerTest do
  @moduledoc """
  The runner owns a thread's turns: a send is admitted in order and
  accepted with the turn it opens or refused with nothing written; a post
  that names no one goes to the soul, which says in the thread why it
  cannot answer when its file is refused; one turn runs at a time, the
  sender's own line steers it and a line to a crew member or under
  another origin waits; a stop cuts the turn and drops the queue; a step
  that does more than read runs at once and does not pause the turn; a page's
  call is a step of the turn that runs, waits with no step while the turn
  is paused around a launch and is a step of it once it runs again, and
  opens work of its own with no turn; a call whose request ended runs
  nothing, its step still proposed skipped; a workspace thread's turn that
  ends without its report leaves the thread stopped when the person's act
  ended it and in error when Aqua could not run; a runner that starts
  finds the open turns and does what their rows say, resuming each under
  the origin its row stores and cancelling one whose stored origin is
  outside the vocabulary. A runner's loop dies with it; a runner starts
  and handles loop events only on a boot that owns the control plane, and
  never takes a turn another process on this boot holds.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Aqua.{Runner, Tape}
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @crash_value "planted-loop-argument-7d4b"

  @unknown_origin "hand-edited"

  setup tags do
    if tags[:prior_runner_crashes] do
      supervisor = restart_runner_supervisor!()
      leave_runner_crashes!(supervisor)
      {:ok, prior_runner_supervisor: supervisor}
    else
      :ok
    end
  end

  setup do
    # Deliberate crashes in other tests must not spend this test's restart budget.
    restart_runner_supervisor!()

    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    # The test's storage is the tree of the person's own athanor, minted
    # for this test alone, under the partition's storage root: nothing else
    # names the tree, and it is removed, and nothing else, when the test ends.
    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    athanor = Sanctum.Test.People.athanor!(user)
    ctx = %{ctx | athanor_id: athanor.id}
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
    Cyfr.Test.SeedBundle.lay!(~w(claude files http))

    # The runners stop before their tree is removed and the seed tree restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    # The sends here are the console's: a person on an interactive surface,
    # the origin `CyfrWeb.ContextGuard` gives the context it establishes.
    ctx = %{ctx | origin: :interactive}

    # Filled now, through the explicit verb, as a person's athanor stands
    # once its fill has run; the soul's consent is among what it minted.
    {:ok, %{provisioned_at: %DateTime{}}} = Sanctum.Provisioning.provision(athanor, ctx)
    {:ok, [_soul]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), @soul)
    # The model catalyst unseals its key when its runner attaches; the key
    # is lent to a script's turns over the API as well as the person's.
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})

    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    :ok = Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, user: user, thread: thread}
  end

  defp restart_runner_supervisor! do
    :ok = Supervisor.terminate_child(Aqua.RunnerTree, Aqua.RunnerSupervisor)
    {:ok, supervisor} = Supervisor.restart_child(Aqua.RunnerTree, Aqua.RunnerSupervisor)
    supervisor
  end

  defp leave_runner_crashes!(supervisor) do
    test = self()

    for _ <- 1..3 do
      tag = make_ref()

      run = fn ->
        send(test, {tag, self()})
        receive do: (:finish -> :ok)
      end

      {:ok, child} =
        DynamicSupervisor.start_child(supervisor, %{
          id: tag,
          start: {Task, :start_link, [run]},
          restart: :transient
        })

      assert_receive {^tag, ^child}, 5_000
      ref = Process.monitor(child)
      Process.exit(child, :kill)
      assert_receive {:DOWN, ^ref, :process, ^child, :killed}, 5_000
      assert_receive {^tag, successor}, 5_000
      :ok = DynamicSupervisor.terminate_child(supervisor, successor)
    end
  end

  # A crew member the athanor made, on the scripted model: it is offered
  # the soul's tools and holds no consent of its own: its model calls run
  # under the model's own grant, whose default profile binds the key.
  # Making it asks nothing.
  defp member!(ctx, name) do
    :ok =
      Arca.put(
        Sanctum.Context.actor(ctx),
        Compendium.AquaPath.crew_file(name),
        "---\ntitle: #{String.capitalize(name)}\ndescription: Plans.\navoid: Building.\n" <>
          "catalyst_ref: #{@model}\nmodel: claude-sonnet-5-5\n---\n"
      )

    {:ok, _} = Compendium.AgentIndex.sync(ctx)
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

  # The tree is removed once the work the test started has stopped: the
  # stop registered after the removal runs before it.
  defp remove_on_exit(tree) do
    on_exit(fn -> File.rm_rf!(tree) end)
    Cyfr.Test.Sandbox.stop_work_on_exit()
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

  # A fetch: followed in the script by `{:crash, :before_response}`, its
  # run's waiter dies and the turn stops on a call whose outcome is unknown.
  defp fetch(id), do: call(id, "http", %{"action" => "get", "url" => "https://example.test/x"})

  defp keep(id, name),
    do: call(id, "notes", %{"action" => "keep", "name" => name, "content" => "x"})

  # A script the model's runs and the fetches' runs play in turn.
  defp script_http!(items),
    do: start_supervised!({ScriptedWorker, ref: [@model, "catalyst:local.http"], script: items})

  # The sender's line over the API: a turn of its own behind the running
  # one, never a steer of it, since a steer keeps its turn's origin.
  defp api_line(ctx), do: %{ctx | origin: :programmatic}

  # Another person, signed in on the console and working in their own
  # athanor, which nothing has filled.
  defp another_person!(label) do
    n = System.unique_integer([:positive])
    local = Sanctum.TestContext.local(:prism)
    {ctx, user} = Sanctum.TestContext.person!(%{local | user_id: "local|local|#{label}-#{n}"})
    %{ctx | athanor_id: Sanctum.Test.People.athanor!(user).id, origin: :interactive}
  end

  # The runner, its loop, and the loop's call that is waiting on the test.
  defp running!(thread) do
    assert_receive {:scripted_probe, call, _}, 60_000
    runner = Runner.whereis(thread.id)
    %{live: %{task: %Aqua.Loop.Worker.Handle{pid: loop}}} = :sys.get_state(runner)
    %{runner: runner, loop: loop, call: call}
  end

  defp kill_and_await!(%{runner: runner, loop: loop} = pids) do
    refs = for {_name, pid} <- pids, into: %{}, do: {Process.monitor(pid), pid}
    # The runner has told the loop all it will of what it had, and the loop
    # has read what it was told.
    _ = :sys.get_state(runner)
    idle!(loop)
    Process.exit(runner, :kill)
    for {ref, _pid} <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 5_000)
    # The supervisor has answered the runner's exit: restarted it or not.
    _ = :sys.get_state(Aqua.RunnerSupervisor)
    :ok
  end

  # The loop's own waits, which read nothing (`Aqua.Loop`).
  @quiet [:harness_wait, :awaiting, :collect]

  # A loop told that its thread moved reads its steps (`Aqua.Loop`): one
  # killed in that read takes the test's one shared connection with it. It
  # is killed only once it sits in one of its own waits, which read
  # nothing, with nothing to read: a process waiting on the store's answer
  # waits too, so its status alone says nothing.
  defp idle!(pid) do
    wait_until(
      fn ->
        case Process.info(pid, [:current_function, :message_queue_len]) do
          nil -> true
          [current_function: {Aqua.Loop, wait, _}, message_queue_len: 0] -> wait in @quiet
          _reading -> false
        end
      end,
      10_000
    )
  end

  defp lose_ownership(loss) do
    ownership =
      case loss do
        :lost -> :lost
        :expired -> {:held, 0}
      end

    Arca.ControlPlane.record(ownership)
    on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
    Cyfr.Test.Sandbox.stop_work_on_exit()
  end

  defp tape_snapshot(ctx, thread_id, turn_ids) do
    turns =
      for id <- turn_ids do
        {:ok, turn} = Tape.turn(ctx, id)
        {:ok, steps} = Tape.steps(ctx, turn)
        {turn, steps}
      end

    %{
      thread: Tape.thread(ctx, thread_id),
      messages: Threads.messages(Sanctum.Context.actor(ctx), thread_id),
      turns: turns
    }
  end

  defp await_retired(runner, ref) do
    assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 5_000
    _ = :sys.get_state(Aqua.RunnerSupervisor)
    refute Process.alive?(runner)
  end

  test "a send is admitted in order, and refused with nothing written", %{
    ctx: ctx,
    thread: thread
  } do
    assert {:error, :empty} = Runner.send_message(ctx, thread.id, "   ")

    assert {:error, :message_too_long} =
             Runner.send_message(ctx, thread.id, String.duplicate("x", 33_000))

    stranger = %{ctx | user_id: "usr_nobody"}
    assert {:error, :not_member} = Runner.send_message(stranger, thread.id, "@aqua hi")

    # An athanor not yet filled refuses an addressed send before any row.
    fresh_ctx = another_person!("fresh")
    # The refused send starts the athanor's fill, which writes its tree.
    remove_on_exit(own_tree!(fresh_ctx))
    {:ok, fresh_thread} = Arca.Test.Days.thread(Sanctum.Context.actor(fresh_ctx))
    # The roster is handed in: reading it would itself start the fill.
    assert {:error, :not_provisioned} =
             Runner.send_message(fresh_ctx, fresh_thread.id, "@aqua hi",
               agents: [%{"name" => "aqua", "title" => "Aqua"}]
             )

    assert [] = Threads.messages(Sanctum.Context.actor(fresh_ctx), fresh_thread.id)

    assert [] = Threads.messages(Sanctum.Context.actor(ctx), thread.id)
  end

  test "an addressed line starts a turn, which completes", %{
    ctx: ctx,
    thread: thread
  } do
    script!([reply("hello back")])

    assert {:ok, %{accepted: true, turn_id: turn_id, admitted: :turn, replayed: false} = sent} =
             Runner.send_message(ctx, thread.id, "@aqua say hello", client_id: "c-1")

    assert_receive %ThreadEvent{kind: :turn_starting, data: user}, 5_000
    assert user == ctx.user_id
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn_id)

    assert_receive %ThreadEvent{kind: :message, data: %{kind: "text", content: "hello back"}},
                   5_000

    # The same client id answers the same identity, and writes nothing new.
    assert {:ok, %{message_id: mid, turn_id: ^turn_id, replayed: true}} =
             Runner.send_message(ctx, thread.id, "@aqua say hello", client_id: "c-1")

    assert mid == sent.message_id
    assert %{running: false, queued: 0} = Runner.state(thread.id, ctx.athanor_id)
  end

  # A crew member stands in the roster behind the soul: a post that missed
  # the soul would reach it.
  describe "a post that names no one in a new day's thread" do
    setup %{ctx: ctx} do
      member!(ctx, "planner")
      :ok
    end

    test "goes to the soul whose file is refused, whose turn writes why as a line in the " <>
           "thread and runs nothing",
         %{ctx: ctx, thread: thread} do
      script!([reply("never asked")])
      actor = Sanctum.Context.actor(ctx)
      {:ok, shipped} = Arca.get(actor, Compendium.AquaPath.soul_file())

      # The file as it stood before `tools:`, still holding `tool_policy:`.
      :ok =
        Arca.put(
          actor,
          Compendium.AquaPath.soul_file(),
          String.replace(
            shipped,
            "\ntools:\n",
            "\ntool_policy:\n  notes.keep: auto\ntools:\n"
          )
        )

      assert {:error, :tool_policy_retired} = Compendium.AgentIndex.snapshot(ctx, "aqua")

      assert {:ok, %{admitted: :turn, turn_id: turn_id}} =
               Runner.send_message(ctx, thread.id, "hello")

      assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
      line = Prima.AgentRef.tool_policy_retired()

      assert {:ok, %{status: "failed", agent: "aqua", error: ^line, root_execution_id: nil}} =
               Tape.turn(ctx, turn_id)

      assert [
               row(thread, %{
                 seq: 1,
                 author: ctx.user_id,
                 kind: "text",
                 content: "hello",
                 turn_id: turn_id,
                 sent_by: "person",
                 addressee: "aqua"
               }),
               row(thread, %{
                 seq: 2,
                 author: Prima.Author.system(),
                 kind: "system",
                 content: line,
                 turn_id: turn_id,
                 sent_by: "aqua"
               })
             ] == rows!(ctx, thread.id)

      # Nothing ran: no model was asked, no step taken, no crew member
      # asked, and no root was claimed, since a soul whose file does not
      # parse has no registry row to root at.
      assert ScriptedWorker.calls() == []
      assert [] = raw_steps!(ctx, turn_id)
      assert [] = Threads.children(actor, thread.id)
      assert nil == Arca.Repo.get_by(Arca.Schemas.Execution, turn_id: turn_id)
    end

    test "goes to the soul whose file is valid, whose turn answers it",
         %{ctx: ctx, thread: thread} do
      script!([reply("hello back")])

      assert {:ok, %{admitted: :turn, turn_id: turn_id}} =
               Runner.send_message(ctx, thread.id, "hello")

      assert_receive %ThreadEvent{kind: :turn_finished}, 60_000

      assert {:ok, %{status: "completed", agent: "aqua", root_execution_id: root}} =
               Tape.turn(ctx, turn_id)

      [%{kind: "model", id: step}] = raw_steps!(ctx, turn_id)

      # The post is carried by the model step whose request held it.
      assert [
               row(thread, %{
                 seq: 1,
                 author: ctx.user_id,
                 kind: "text",
                 content: "hello",
                 turn_id: turn_id,
                 sent_by: "person",
                 addressee: "aqua",
                 carried_by: step
               }),
               row(thread, %{
                 seq: 2,
                 author: Prima.Author.agent(),
                 kind: "text",
                 content: "hello back",
                 payload: Jason.encode!(%{"step_id" => step}),
                 execution_id: root,
                 turn_id: turn_id,
                 sent_by: "aqua"
               })
             ] == rows!(ctx, thread.id)

      assert chats() == 1
      assert [] = Threads.children(Sanctum.Context.actor(ctx), thread.id)
    end
  end

  test "the sender's own line steers the running turn", %{
    ctx: ctx,
    thread: thread
  } do
    script!([{:probe, self()}, reply("first"), reply("steered")])

    {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
    assert_receive {:scripted_probe, worker, _}, 30_000

    assert {:ok, %{admitted: :steer, turn_id: ^first}} =
             Runner.send_message(ctx, thread.id, "@aqua also this")

    assert %{running: true, queued: 0} = Runner.state(thread.id, ctx.athanor_id)

    send(worker, :continue)
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000

    wait_until(fn ->
      match?(%{running: false, queued: 0}, Runner.state(thread.id, ctx.athanor_id))
    end)

    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, first)

    # The steer rode the first turn, which answered it before completing.
    rows = Threads.messages(Sanctum.Context.actor(ctx), thread.id)
    assert %{turn_id: ^first} = Enum.find(rows, &(&1.content == "@aqua also this"))
    assert %{turn_id: ^first} = Enum.find(rows, &(&1.content == "steered"))
  end

  test "the sender's line to a crew member is a request beside the running turn, never a steer of it",
       %{ctx: ctx, thread: thread} do
    member!(ctx, "planner")
    script!([{:probe, self()}, reply("first")])

    {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
    assert_receive {:scripted_probe, worker, _}, 30_000

    assert {:ok, %{admitted: :request, turn_id: nil, message_id: request}} =
             Runner.send_message(ctx, thread.id, "also this", agent: "planner")

    assert %{running: true, queued: 0} = Runner.state(thread.id, ctx.athanor_id)

    send(worker, :continue)
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert {:ok, %{status: "completed", agent: "aqua"}} = Tape.turn(ctx, first)

    assert {:ok, %{addressee: "planner", status: "pending", turn_id: nil}} =
             Tape.message(ctx, request)
  end

  test "a viewer joining mid-answer reads the text streamed so far, until the step's row lands",
       %{ctx: ctx, thread: thread} do
    script!([
      {:emit,
       [
         %{"type" => "text.delta", "text" => "Hel"},
         %{"type" => "text.delta", "text" => "lo"}
       ]},
      {:probe, self()},
      reply("Hello")
    ])

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua go")
    assert_receive {:scripted_probe, worker, _}, 30_000

    wait_until(fn ->
      case Runner.state(thread.id, ctx.athanor_id) do
        %{running: true, turn_id: ^turn_id, partials: partials} ->
          match?([%{text: "Hello", role: nil}], Aqua.Loop.Stream.texts(partials))

        _ ->
          false
      end
    end)

    # A delta under an earlier fence — a loop the turn was taken from — is
    # not kept.
    %{partials: %{fence: fence}} = Runner.state(thread.id, ctx.athanor_id)

    [step_id] =
      for %{step_id: id} <-
            Aqua.Loop.Stream.texts(Runner.state(thread.id, ctx.athanor_id).partials),
          do: id

    Aqua.Tape.announce(ctx, thread.id, :delta, %{
      turn_id: turn_id,
      fence: fence - 1,
      source: turn_id,
      step_id: step_id,
      ordinal: 9,
      seq: {9, 9},
      text: " stale",
      role: nil
    })

    %{partials: partials} = Runner.state(thread.id, ctx.athanor_id)
    assert [%{text: "Hello"}] = Aqua.Loop.Stream.texts(partials)

    send(worker, :continue)
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert Aqua.Loop.Stream.texts(Runner.state(thread.id, ctx.athanor_id).partials) == []
  end

  # A viewer that joins draws what the live thread draws: a thread's pane
  # clears a turn's calls when it hears the turn end, so the turn's calls
  # are no part of what a viewer joining after that end reads.
  test "a viewer joining after a stop reads no call of the stopped turn, as the live thread draws none",
       %{ctx: ctx, thread: thread} do
    start_supervised!(
      {ScriptedWorker,
       ref: [@model, "catalyst:local.http"],
       script: [
         call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
         {:probe, self()},
         reply("never sent")
       ]}
    )

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua fetch")
    assert_receive {:scripted_probe, worker, _}, 30_000

    wait_until(fn ->
      match?(
        %{running: true, turn_id: ^turn_id, tool_activity: [_ | _]},
        Runner.state(thread.id, ctx.athanor_id)
      )
    end)

    assert :ok = Runner.stop_turn(ctx, thread.id)
    assert_receive %ThreadEvent{kind: :turn_finished}, 10_000
    send(worker, :continue)

    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, turn_id)
    assert %{running: false, tool_activity: []} = Runner.state(thread.id, ctx.athanor_id)
  end

  test "a steer offered again is the same steer", %{ctx: ctx, thread: thread} do
    script!([{:probe, self()}, reply("done")])

    {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
    assert_receive {:scripted_probe, worker, _}, 30_000

    assert {:ok, %{admitted: :steer, turn_id: ^first, replayed: false, message_id: mid}} =
             Runner.send_message(ctx, thread.id, "@aqua also this", client_id: "steer-1")

    assert {:ok, %{admitted: :steer, turn_id: ^first, replayed: true, message_id: ^mid}} =
             Runner.send_message(ctx, thread.id, "@aqua also this", client_id: "steer-1")

    assert {:error, :client_id_reused} =
             Runner.send_message(ctx, thread.id, "@aqua something else", client_id: "steer-1")

    send(worker, :continue)
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000

    assert [_] =
             Enum.filter(
               Threads.messages(Sanctum.Context.actor(ctx), thread.id),
               &(&1.content == "@aqua also this")
             )
  end

  test "a runner that starts over a paused row knows it before the first send", %{
    ctx: ctx,
    thread: thread
  } do
    script_http!([fetch("c1"), {:crash, :before_response}])

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua fetch it"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    assert {:paused, :uncertain} =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

    assert nil == Runner.whereis(thread.id)
    other = api_line(ctx)

    assert {:ok, %{admitted: :turn, turn_id: second}} =
             Runner.send_message(other, thread.id, "@aqua me too")

    assert second != turn.id

    assert %{running: false, paused: true, paused_reason: :uncertain, queued: 1} =
             Runner.state(thread.id, ctx.athanor_id)
  end

  test "a call whose outcome is unknown stops the turn; the sender's next line continues it",
       %{ctx: ctx, thread: thread} do
    start_supervised!(
      {ScriptedWorker,
       ref: [@model, "catalyst:local.http"],
       script: [
         call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
         {:crash, :before_response},
         reply("carrying on")
       ]}
    )

    {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")

    assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^first, reason: :uncertain}},
                   60_000

    assert %{running: false, paused: true, paused_reason: :uncertain} =
             Runner.state(thread.id, ctx.athanor_id)

    assert {:ok, %{status: "paused", paused_reason: "uncertain"}} = Tape.turn(ctx, first)

    assert {:ok, %{admitted: :steer, turn_id: ^first}} =
             Runner.send_message(ctx, thread.id, "@aqua go on")

    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, first)
  end

  test "a runner that starts over a stopped turn continues it only on the sender's line past the stop",
       %{ctx: ctx, thread: thread} do
    start_supervised!(
      {ScriptedWorker,
       ref: [@model, "catalyst:local.http"],
       script: [
         call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
         {:crash, :before_response},
         reply("carrying on")
       ]}
    )

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    assert {:paused, :uncertain} =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

    # A runner over the row: it waits.
    assert %{paused: true, paused_reason: :uncertain, running: false} =
             Runner.state(thread.id, ctx.athanor_id)

    # The acknowledging line, and the turn goes on to its end.
    assert {:ok, %{admitted: :steer}} = Runner.send_message(ctx, thread.id, "@aqua go on")
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn.id)
  end

  test "a runner that starts with the acknowledging line already on the tape continues at once",
       %{ctx: ctx, thread: thread} do
    start_supervised!(
      {ScriptedWorker,
       ref: [@model, "catalyst:local.http"],
       script: [
         call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
         {:crash, :before_response},
         reply("carrying on")
       ]}
    )

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    assert {:paused, :uncertain} =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "go on"},
        steer_turn_id: turn.id
      })

    {:ok, _pid} = Runner.ensure(thread.id, ctx.athanor_id)
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn.id)
  end

  test "the opener offered again while its turn runs is the same send, not a steer", %{
    ctx: ctx,
    thread: thread
  } do
    script!([{:probe, self()}, reply("done")])

    {:ok, %{message_id: mid, turn_id: turn_id, admitted: :turn}} =
      Runner.send_message(ctx, thread.id, "@aqua go", client_id: "c-open")

    assert_receive {:scripted_probe, worker, _}, 30_000

    # The sender's own line would steer — but this is the line that opened
    # the turn, retried: the identity it was given, nothing attached.
    assert {:ok, %{message_id: ^mid, turn_id: ^turn_id, admitted: :turn, replayed: true}} =
             Runner.send_message(ctx, thread.id, "@aqua go", client_id: "c-open")

    # A different line under that client id is a reuse, never a steer.
    assert {:error, :client_id_reused} =
             Runner.send_message(ctx, thread.id, "@aqua something else", client_id: "c-open")

    send(worker, :continue)
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000

    assert [_] =
             Enum.filter(
               Threads.messages(Sanctum.Context.actor(ctx), thread.id),
               &(&1.author == ctx.user_id)
             )
  end

  test "a turn that cannot start once its root is claimed ends failed, root and all", %{
    ctx: ctx,
    thread: thread
  } do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    # Ended between acceptance and its run: the root is claimed, the start
    # refuses a turn that is no longer accepted.
    {:ok, _} = Tape.finish(ctx, turn, "cancelled")

    assert {:failed, :not_accepted} = Aqua.Loop.run(ctx: ctx, turn_id: turn.id)
    assert {:ok, %{status: "cancelled", root_execution_id: nil}} = Tape.turn(ctx, turn.id)

    # The root the claim admitted is closed, not left running under a
    # released slot.
    assert %{status: "failed", kind: "turn"} =
             Arca.Repo.get_by(Arca.Schemas.Execution, turn_id: turn.id)
  end

  # The crew has one grant, Aqua's: under it Aqua's turn and a member's
  # run; revoked, it refuses every member's turn as it refuses Aqua's,
  # before a root is claimed or a model is asked, and asks for that one
  # grant.
  test "with the crew's grant revoked, Aqua's turn and every member's claim no root and ask for it",
       %{ctx: ctx, thread: thread} do
    member!(ctx, "planner")
    {:ok, child} = Threads.crew_thread(Sanctum.Context.actor(ctx), thread.id, "planner")
    :ok = Runner.subscribe(child.id, ctx.athanor_id)
    script!([reply("Aqua ran."), reply("The planner ran.")])

    for {room, agent} <- [{thread, "aqua"}, {child, "planner"}] do
      {:ok, %{turn: turn}} =
        Tape.accept(ctx, room.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "first"},
          turn: %{agent: agent, requested_by: ctx.user_id}
        })

      assert :completed = Aqua.Loop.run(ctx: ctx, turn_id: turn.id)
    end

    ran = ScriptedWorker.calls()
    assert Enum.count(ran, &(&1.input["operation"] == "chat")) == 2

    assert {:ok, %{revoked: [_]}} = Sanctum.Consent.revoke_source(ctx, "agent:local.aqua")
    user = ctx.user_id

    for {room, agent} <- [{thread, "aqua"}, {child, "planner"}] do
      {:ok, %{turn: turn}} =
        Tape.accept(ctx, room.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "go"},
          turn: %{agent: agent, requested_by: ctx.user_id}
        })

      assert {:failed, :setup_required} = Aqua.Loop.run(ctx: ctx, turn_id: turn.id)

      assert {:ok, %{status: "failed", root_execution_id: nil, profile_id: nil}} =
               Tape.turn(ctx, turn.id)

      assert nil == Arca.Repo.get_by(Arca.Schemas.Execution, turn_id: turn.id)
      room_id = room.id

      assert_receive %ThreadEvent{
                       thread_id: ^room_id,
                       kind: :consent_required,
                       data: %{ref: "agent:local.aqua", user_id: ^user}
                     },
                     5_000
    end

    assert ScriptedWorker.calls() == ran
  end

  # A brain's own grant that is damaged, or that cannot be read, is the
  # brain's state: a post in a thread that already has posts is refused
  # with the brain's sentence, as a line in the thread and as the turn's
  # error, and nothing is asked.
  test "a post refused because its brain's own grant cannot be read, or is damaged, says so " <>
         "in a thread that already has posts",
       %{ctx: ctx, thread: thread} do
    script!([reply("Aqua ran.")])

    accept = fn content ->
      {:ok, %{turn: turn}} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: content},
          turn: %{agent: "aqua", requested_by: ctx.user_id}
        })

      turn
    end

    assert :completed = Aqua.Loop.run(ctx: ctx, turn_id: accept.("first").id)
    ran = ScriptedWorker.calls()
    {:ok, %{profile_id: brain}} = Opus.authority_for(ctx, :default, @model)

    cases = [
      {:unavailable, fn -> Sanctum.Test.ConsentFixtures.head_outage!(ctx, brain) end,
       &:telemetry.detach/1},
      {:consent_damaged,
       fn -> Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, brain, scope: "sideways") end,
       fn :ok -> :ok end}
    ]

    for {{state, break, mend}, n} <- Enum.with_index(cases, 1) do
      broken = break.()
      turn = accept.("go #{n}")

      assert {:failed, {:crew_unready, _member, ^state} = refusal} =
               Aqua.Loop.run(ctx: ctx, turn_id: turn.id)

      mend.(broken)
      sentence = Prima.Refusal.message(refusal)
      assert {:ok, %{status: "failed", error: ^sentence}} = Tape.turn(ctx, turn.id)
      assert List.last(system_lines(ctx, thread)) == sentence
      assert length(system_lines(ctx, thread)) == n
    end

    assert ScriptedWorker.calls() == ran
  end

  # A turn's brain grant is read as the component index holds it: an index
  # that cannot catch up refuses the turn before its brain is asked, and
  # the failed turn says so in the refusal's own sentence, never its atom.
  test "a turn refused while the component index catches up is told to retry in its sentence",
       %{ctx: ctx, thread: thread} do
    script!([reply("Aqua ran.")])

    accept = fn content ->
      {:ok, %{turn: turn}} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: content},
          turn: %{agent: "aqua", requested_by: ctx.user_id}
        })

      turn
    end

    assert :completed = Aqua.Loop.run(ctx: ctx, turn_id: accept.("first").id)
    ran = ScriptedWorker.calls()

    {:ok, _pending} =
      Arca.StorageProjectionChanges.begin_edit(
        Sanctum.Context.actor(ctx),
        "components",
        "catalysts/local/claude/1.0.0"
      )

    turn = accept.("go")
    refusal = {:unavailable, "The component graph"}
    assert {:failed, ^refusal} = Aqua.Loop.run(ctx: ctx, turn_id: turn.id)
    sentence = Aqua.Ops.render_refusal(refusal)
    assert sentence =~ "retry"
    assert {:ok, %{status: "failed", error: ^sentence}} = Tape.turn(ctx, turn.id)

    assert ScriptedWorker.calls() == ran
  end

  test "a crew member asked by name works in its child thread under the crew's one grant, with its brain's key",
       %{ctx: ctx, thread: thread} do
    entry =
      Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})

    member!(ctx, "planner")

    script!([reply("Step one.")])

    {:ok, %{admitted: :request, message_id: request}} =
      Runner.send_message(ctx, thread.id, "@planner plan")

    assert {:ok, %{"applied" => 1}} = Aqua.Crew.drain(ctx.athanor_id)
    [child] = Threads.children(Sanctum.Context.actor(ctx), thread.id)
    :ok = Runner.subscribe(child.id, ctx.athanor_id)
    [%{turn_id: turn_id} | _] = Threads.messages(Sanctum.Context.actor(ctx), child.id)

    wait_until(fn -> match?({:ok, %{status: "completed"}}, Tape.turn(ctx, turn_id)) end, 60_000)

    assert {:ok, []} =
             Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "agent:local.planner")

    {:ok, [grant]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "agent:local.aqua")

    {:ok, turn} = Tape.turn(ctx, turn_id)
    assert turn.request_id == request and turn.asking_thread_id == thread.id
    assert turn.status == "completed" and turn.agent == "planner"
    assert turn.profile_id == grant.id
    assert {:ok, bytes} = Tape.agent_revision(ctx, turn)
    assert bytes =~ "Planner"

    assert %{authority: authority} =
             Enum.find(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

    # Its model call runs under the brain's own grant, pinned on the turn.
    {:ok, brain} = Opus.authority_for(ctx, :default, @model)
    assert {turn.brain_profile_id, turn.brain_consent_id} == {brain.profile_id, brain.consent_id}
    assert authority.chain == [@model, @model]
    assert authority.profile_id == brain.profile_id
    assert authority.resources.vault.entry_id == entry.id
  end

  test "stop cuts the running turn and drops what waited", %{ctx: ctx, thread: thread} do
    other = api_line(ctx)
    script!([{:probe, self()}])

    {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
    assert_receive {:scripted_probe, _worker, _}, 30_000
    {:ok, %{turn_id: second}} = Runner.send_message(other, thread.id, "@aqua me too")

    assert :ok = Runner.stop_turn(ctx, thread.id)
    assert_receive %ThreadEvent{kind: :turn_finished}, 10_000
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, first)
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, second)
    assert %{running: false, queued: 0} = Runner.state(thread.id, ctx.athanor_id)
    assert Prima.Slots.status(Opus.Slots).root_active == 0

    ScriptedWorker.script([reply("new work")])
    {:ok, %{turn_id: fresh}} = Runner.send_message(ctx, thread.id, "@aqua again")
    refute fresh in [first, second]
    wait_until(fn -> match?({:ok, %{status: "completed"}}, Tape.turn(ctx, fresh)) end, 60_000)
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, fresh)
  end

  test "a step that does more than read runs at once, and does not pause the turn",
       %{ctx: ctx, thread: thread} do
    script!([keep("c1", "first"), reply("kept it")])

    {:ok, %{turn_id: kept}} = Runner.send_message(ctx, thread.id, "@aqua keep it")
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    refute_received %ThreadEvent{kind: :turn_paused}
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, kept)

    assert [
             model_step(ctx, kept, 1, nil),
             call_step(ctx, kept, 2, "notes.keep", "c1", "ok"),
             model_step(ctx, kept, 3, "text")
           ] == steps!(ctx, kept)

    assert {:ok, %{content: "x"}} = Aqua.Notes.read(ctx, "first")
    refute Enum.any?(rows!(ctx, thread.id), &(&1.kind == "system"))
  end

  test "a runner that starts runs the accepted turn it finds and takes over the running one", %{
    ctx: ctx,
    thread: thread
  } do
    script!([reply("picked up"), reply("taken over")])

    # A turn accepted by a runner that is gone.
    {:ok, %{turn: accepted}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua later"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, _pid} = Runner.ensure(thread.id, ctx.athanor_id)
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, accepted.id)

    # The loop writes the turn's end before it answers its runner, and a
    # runner ended while its loop still works ends that loop inside a read
    # on this test's connection.
    wait_until(fn -> match?(%{running: false}, Runner.state(thread.id, ctx.athanor_id)) end)

    # A turn left running by a boot that died: its root row and attempt
    # stand, nobody renews them.
    for {_id, pid, _, _} <- DynamicSupervisor.which_children(Aqua.RunnerSupervisor),
        do: DynamicSupervisor.terminate_child(Aqua.RunnerSupervisor, pid)

    {:ok, other_thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    :ok = Runner.subscribe(other_thread.id, ctx.athanor_id)

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, other_thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua carry on"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, claim} =
      Opus.claim_turn_root(ctx, @soul, turn_id: turn.id, thread_id: other_thread.id)

    {:ok, %{capability_digest: capability, revision_digest: revision} = snapshot} =
      Compendium.AgentIndex.snapshot(ctx, "aqua")

    # Started as the loop starts a turn, its brain pinned with its start.
    {:ok, brain} = Aqua.Loop.Turn.brain_pin(ctx, turn, snapshot.agent, claim.budget_id, true)

    {:ok, running} =
      Tape.start_turn(
        ctx,
        turn,
        Map.merge(brain, %{
          root_execution_id: claim.execution_id,
          attempt: claim.attempt,
          budget_id: claim.budget_id,
          profile_id: claim.authority.profile_id,
          consent_id: claim.authority.consent_id,
          agent_revision_digest: revision,
          agent_capability_digest: capability,
          recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
        })
      )

    # The dead boot's slot and keeper are gone; the rows say running.
    :ok = Opus.release_turn_root(ctx, claim.execution_id, claim: claim)
    assert running.status == "running"

    {:ok, _pid} = Runner.ensure(other_thread.id, ctx.athanor_id)
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert {:ok, %{status: "completed", recovery_attempts: 1} = done} = Tape.turn(ctx, turn.id)
    assert done.attempt != claim.attempt
    rows = Threads.messages(Sanctum.Context.actor(ctx), other_thread.id)
    assert Enum.any?(rows, &(&1.kind == "turn_aborted"))
    assert Enum.any?(rows, &(&1.content == "taken over"))
  end

  test "a pause on an unknown outcome keeps the thread's claim", %{ctx: ctx, thread: thread} do
    script_http!([fetch("c1"), {:crash, :before_response}])

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua fetch it")
    wait_until(fn -> match?({:ok, %{status: "paused"}}, Tape.turn(ctx, turn_id)) end, 60_000)

    # Stopped on its call: still this member's work, so still its thread.
    assert {:ok, %{status: "paused", paused_reason: "uncertain"}} = Tape.turn(ctx, turn_id)
    assert {:ok, %{active_turn_id: ^turn_id}} = Tape.thread(ctx, thread.id)
  end

  # A loop that crashes exits with its stacktrace, whose failing frame
  # holds the arguments it was called with.
  test "a loop that crashes is logged by its frames' arity, never their arguments", %{
    ctx: ctx,
    thread: thread
  } do
    script!([{:probe, self()}, reply("never sent")])

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua go")
    pids = running!(thread)
    frame = {Aqua.Loop, :step, [%{key: @crash_value}], [file: ~c"lib/aqua/loop.ex", line: 1]}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(pids.loop, {:function_clause, [frame]})
        wait_until(fn -> match?({:ok, %{status: "uncertain"}}, Tape.turn(ctx, turn_id)) end)
      end)

    send(pids.call, :continue)

    refute log =~ @crash_value
    assert log =~ "stopped without an answer: {:function_clause, [{Aqua.Loop, :step, 1,"
  end

  describe "a runner that dies" do
    @tag prior_runner_crashes: true
    test "mid model call takes its loop and the call with it; its restart takes the turn over",
         %{ctx: ctx, thread: thread, prior_runner_supervisor: prior_supervisor} do
      refute Process.alive?(prior_supervisor),
             "the fixture kept the preceding tests' crash history"

      supervisor = Process.whereis(Aqua.RunnerSupervisor)
      script!([{:probe, self()}, reply("taken over")])

      {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua go")
      pids = running!(thread)
      :ok = kill_and_await!(pids)
      assert Process.whereis(Aqua.RunnerSupervisor) == supervisor

      assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
      refute Runner.whereis(thread.id) in [nil, pids.runner]

      # Released now, the dead call would have answered with the reply the
      # successor already took.
      send(pids.call, :continue)

      assert {:ok, %{status: "completed", recovery_attempts: 1} = turn} = Tape.turn(ctx, turn_id)
      {:ok, steps} = Tape.steps(ctx, turn)

      assert [%{outcome: "error", error: "not reproducible"}, %{outcome: "ok"}] =
               Enum.filter(steps, &(&1.kind == "model"))

      agent = Arca.Schemas.Message.agent_author()

      assert ["taken over"] =
               for(
                 %{author: ^agent, turn_id: ^turn_id} = row <-
                   Threads.messages(Sanctum.Context.actor(ctx), thread.id),
                 do: row.content
               )

      assert Enum.count(ScriptedWorker.calls(), &(&1.input["operation"] == "chat")) == 2
    end

    test "mid tool dispatch takes its loop and the call with it; its restart stops on the unknown outcome",
         %{ctx: ctx, thread: thread} do
      start_supervised!(
        {ScriptedWorker,
         ref: [@model, "catalyst:local.http"],
         script: [
           call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
           {:probe, self()},
           reply("never sent")
         ]}
      )

      {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua fetch")
      pids = running!(thread)
      :ok = kill_and_await!(pids)

      assert_receive %ThreadEvent{
                       kind: :turn_paused,
                       data: %{turn_id: ^turn_id, reason: :uncertain}
                     },
                     60_000

      send(pids.call, :continue)

      assert {:ok, %{status: "paused", recovery_attempts: 1} = turn} = Tape.turn(ctx, turn_id)
      {:ok, steps} = Tape.steps(ctx, turn)
      assert [%{dispatch_state: "uncertain"}] = Enum.filter(steps, &(&1.action == "get"))

      # One call reached the tool, and nothing after it: no second model
      # round, and the dead call's answer never landed.
      assert ["chat", fetch] =
               ScriptedWorker.calls()
               |> Enum.map(& &1.input["operation"])
               |> Enum.reject(&(&1 == "describe"))

      refute fetch == "chat"
      assert %{running: false, paused: true} = Runner.state(thread.id, ctx.athanor_id)
    end

    test "on a boot that lost the control plane is not restarted; the owner's runner recovers the turn",
         %{ctx: ctx, thread: thread} do
      script!([{:probe, self()}, reply("taken over")])

      {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua go")
      pids = running!(thread)

      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
      :ok = kill_and_await!(pids)

      assert nil == Runner.whereis(thread.id)
      assert %{active: 0} = DynamicSupervisor.count_children(Aqua.RunnerSupervisor)
      assert {:error, :control_plane_lost} = Runner.ensure(thread.id, ctx.athanor_id)

      # The rows stand as the dead runner left them.
      assert {:ok, %{status: "running", fence: 1, recovery_attempts: 0}} =
               Tape.turn(ctx, turn_id)

      refute Enum.any?(
               Threads.messages(Sanctum.Context.actor(ctx), thread.id),
               &(&1.kind == "turn_aborted")
             )

      Arca.ControlPlane.record(:unclaimed)
      {:ok, _runner} = Runner.ensure(thread.id, ctx.athanor_id)
      assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
      assert {:ok, %{status: "completed", recovery_attempts: 1}} = Tape.turn(ctx, turn_id)
    end
  end

  describe "the origin a turn resumes under" do
    test "a programmatic turn queued, the runner restarted before it runs, resumes as programmatic",
         %{ctx: ctx, thread: thread} do
      import Ecto.Query, only: [from: 2]

      script!([{:probe, self()}, reply("taken over"), reply("queued one")])

      {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
      pids = running!(thread)

      # A script's line over the HTTP API, behind the running turn.
      script = api_line(ctx)

      assert {:ok, %{turn_id: queued, admitted: :turn}} =
               Runner.send_message(script, thread.id, "@aqua after that")

      assert %{queued: 1} = Runner.state(thread.id, ctx.athanor_id)
      assert {:ok, %{status: "accepted", origin: "programmatic"}} = Tape.turn(ctx, queued)

      # The runner goes before the queued turn runs; its restart takes the
      # running turn over and then runs the queued one from its row.
      :ok = kill_and_await!(pids)

      wait_until(
        fn -> match?({:ok, %{status: "completed"}}, Tape.turn(ctx, queued)) end,
        60_000
      )

      send(pids.call, :continue)

      # Resumed as its sender, under the origin its row stores: its root
      # and every run under it are programmatic, never the interactive
      # origin of the turn that ran before it.
      {:ok, %{root_execution_id: root}} = Tape.turn(ctx, queued)

      assert %{origin: "programmatic", user_id: sender} =
               Arca.Repo.get!(Arca.Schemas.Execution, root)

      assert sender == script.user_id

      children =
        Arca.Repo.all(
          from(e in Arca.Schemas.Execution,
            where: e.parent_execution_id == ^root,
            select: e.origin
          )
        )

      assert children != []
      assert Enum.all?(children, &(&1 == "programmatic"))

      assert {:ok, %{status: "completed", root_execution_id: first_root}} = Tape.turn(ctx, first)
      assert %{origin: "interactive"} = Arca.Repo.get!(Arca.Schemas.Execution, first_root)
    end

    test "a recovered turn whose stored origin is outside the vocabulary is cancelled with " <>
           "its reason, never resumed",
         %{ctx: ctx, thread: thread} do
      script!([reply("never")])

      # A context no entry gave an origin opens no turn, and writes nothing.
      before = Threads.messages(Sanctum.Context.actor(ctx), thread.id)

      assert {:error, :no_origin} =
               Tape.accept(%{ctx | origin: nil}, thread.id, %{
                 message: %{author: ctx.user_id, sent_by: "person", content: "@aqua never"},
                 turn: %{agent: "aqua", requested_by: ctx.user_id}
               })

      assert Threads.messages(Sanctum.Context.actor(ctx), thread.id) == before

      # Accepted by a runner that is gone; its row then given an origin no
      # writer stores, as a hand edit or a restored row carries it.
      {:ok, %{turn: accepted}} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "@aqua later"},
          turn: %{agent: "aqua", requested_by: ctx.user_id}
        })

      damage_origin!(accepted.id)

      {:ok, _pid} = Runner.ensure(thread.id, ctx.athanor_id)
      assert_receive %ThreadEvent{kind: :turn_finished}, 60_000

      assert {:ok, %{status: "cancelled", error: error, root_execution_id: nil}} =
               Tape.turn(ctx, accepted.id)

      assert error =~ "no_origin"
      assert ScriptedWorker.calls() == []
    end
  end

  describe "a line under another origin" do
    test "a programmatic line from the sender does not steer an interactive turn; its own turn runs on the person's grant",
         %{ctx: ctx, thread: thread} do
      script!([{:probe, self()}, reply("answered"), reply("never")])

      {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
      pids = running!(thread)

      # The same sender, over the API, to the same agent: no steer, a turn
      # of its own, queued behind the running one under its own origin.
      api = %{ctx | origin: :programmatic}

      assert {:ok, %{admitted: :turn, turn_id: queued}} =
               Runner.send_message(api, thread.id, "@aqua do it my way")

      assert queued != first
      refute Tape.steer_pending?(ctx, %{id: first})
      assert {:ok, %{status: "accepted", origin: "programmatic"}} = Tape.turn(ctx, queued)

      send(pids.call, :continue)
      wait_until(fn -> match?({:ok, %{status: "completed"}}, Tape.turn(ctx, first)) end, 60_000)

      # It stands on the person's grant as theirs does, and records that
      # it came over the API.
      wait_until(fn -> match?({:ok, %{status: "completed"}}, Tape.turn(ctx, queued)) end, 60_000)
      assert {:ok, %{status: "completed", origin: "programmatic"}} = Tape.turn(ctx, queued)
    end

    test "a programmatic line does not continue an interactive turn stopped on an unknown outcome",
         %{ctx: ctx, thread: thread} do
      start_supervised!(
        {ScriptedWorker,
         ref: [@model, "catalyst:local.http"],
         script: [
           call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
           {:crash, :before_response},
           reply("carrying on"),
           reply("the API line, done")
         ]}
      )

      {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")

      assert_receive %ThreadEvent{
                       kind: :turn_paused,
                       data: %{turn_id: ^first, reason: :uncertain}
                     },
                     60_000

      # The sender's line over the API neither steers nor continues it: a
      # turn of its own, queued, while the stopped turn stays stopped.
      assert {:ok, %{admitted: :turn, turn_id: api_turn}} =
               Runner.send_message(%{ctx | origin: :programmatic}, thread.id, "@aqua go on")

      assert api_turn != first

      assert %{paused: true, paused_reason: :uncertain, queued: 1} =
               Runner.state(thread.id, ctx.athanor_id)

      assert {:ok, %{status: "paused", paused_reason: "uncertain"}} = Tape.turn(ctx, first)
      assert {:ok, %{status: "accepted", origin: "programmatic"}} = Tape.turn(ctx, api_turn)

      # The sender's line in Prism continues it; the API's turn runs after.
      assert {:ok, %{admitted: :steer, turn_id: ^first}} =
               Runner.send_message(ctx, thread.id, "@aqua go on")

      assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
      assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, first)
      assert {:ok, %{status: "completed", root_execution_id: root}} = Tape.turn(ctx, api_turn)
      assert %{origin: "programmatic"} = Arca.Repo.get!(Arca.Schemas.Execution, root)
    end
  end

  # A turn row's origin cleared past every writer's guard.
  # An origin no writer stores: the damage a hand-edited or restored row
  # can carry, since the column holds any text.
  defp damage_origin!(turn_id) do
    import Ecto.Query, only: [from: 2]

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn_id),
        set: [origin: @unknown_origin]
      )

    :ok
  end

  describe "an existing runner loses control-plane ownership" do
    for loss <- [:lost, :expired], event <- [:result, :down] do
      @tag :ownership_loss
      test "a queued loop #{event} leaves the tape and queued turn unchanged when ownership is #{loss}",
           %{ctx: ctx, thread: thread} do
        other = api_line(ctx)
        script!([{:probe, self()}, reply("first"), reply("second")])
        {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
        pids = running!(thread)
        {:ok, %{turn_id: second}} = Runner.send_message(other, thread.id, "@aqua me too")
        %{live: %{task: %Aqua.Loop.Worker.Handle{ref: task_ref}}} = :sys.get_state(pids.runner)

        :sys.replace_state(pids.runner, fn state ->
          actor = Prima.Actor.in_athanor(ctx.athanor_id)
          :ok = Cyfr.Bus.unsubscribe(actor, Cyfr.Bus.thread(actor, thread.id))
          state
        end)

        runner_ref = Process.monitor(pids.runner)
        loop_ref = Process.monitor(pids.loop)
        :ok = :sys.suspend(pids.runner)

        if unquote(event) == :result do
          send(pids.call, :continue)
          assert_receive {:DOWN, ^loop_ref, :process, _, :normal}, 60_000
          assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
          assert {:ok, %{status: "completed"}} = Tape.turn(ctx, first)
          {:messages, messages} = Process.info(pids.runner, :messages)
          assert Enum.any?(messages, &match?({^task_ref, _result}, &1))
        end

        before = tape_snapshot(ctx, thread.id, [first, second])
        calls = ScriptedWorker.calls()
        lose_ownership(unquote(loss))

        if unquote(event) == :down do
          Process.exit(pids.loop, :kill)
          assert_receive {:DOWN, ^loop_ref, :process, _, :killed}, 5_000
        end

        :ok = :sys.resume(pids.runner)
        await_retired(pids.runner, runner_ref)
        assert tape_snapshot(ctx, thread.id, [first, second]) == before
        assert ScriptedWorker.calls() == calls
        assert {:error, :control_plane_lost} = Runner.ensure(thread.id, ctx.athanor_id)

        Arca.ControlPlane.record(:unclaimed)
        assert {:ok, successor} = Runner.ensure(thread.id, ctx.athanor_id)
        refute successor == pids.runner

        wait_until(
          fn -> match?({:ok, %{status: "completed"}}, Tape.turn(ctx, second)) end,
          60_000
        )

        assert {:ok, %{status: "completed"} = first_turn} = Tape.turn(ctx, first)
        assert first_turn.recovery_attempts == if(unquote(event) == :down, do: 1, else: 0)
        if unquote(event) == :down, do: assert(first_turn.fence > 1)
      end
    end

    for loss <- [:lost, :expired] do
      @tag :ownership_loss
      test "a paused turn's resume leaves the tape unchanged when ownership is #{loss}",
           %{ctx: ctx, thread: thread} do
        start_supervised!(
          {ScriptedWorker,
           ref: [@model, "catalyst:local.http"],
           script: [fetch("c1"), {:crash, :before_response}, reply("carrying on")]}
        )

        {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua fetch")

        assert_receive %ThreadEvent{
                         kind: :turn_paused,
                         data: %{turn_id: ^first, reason: :uncertain}
                       },
                       60_000

        runner = Runner.whereis(thread.id)

        :sys.replace_state(runner, fn state ->
          actor = Prima.Actor.in_athanor(ctx.athanor_id)
          :ok = Cyfr.Bus.unsubscribe(actor, Cyfr.Bus.thread(actor, thread.id))
          state
        end)

        # The sender's next line is on the tape and its runner was never
        # told: only the resume would carry the stopped turn on.
        {:ok, _} =
          Tape.accept(ctx, thread.id, %{
            message: %{author: ctx.user_id, sent_by: "person", content: "@aqua go on"},
            steer_turn_id: first
          })

        assert Tape.steer_pending?(ctx, %{id: first})
        before = tape_snapshot(ctx, thread.id, [first])
        calls = ScriptedWorker.calls()
        runner_ref = Process.monitor(runner)
        lose_ownership(unquote(loss))
        send(runner, {:resume, first})
        await_retired(runner, runner_ref)
        assert tape_snapshot(ctx, thread.id, [first]) == before
        assert ScriptedWorker.calls() == calls

        Arca.ControlPlane.record(:unclaimed)
        assert {:ok, _successor} = Runner.ensure(thread.id, ctx.athanor_id)

        wait_until(
          fn -> match?({:ok, %{status: "completed"}}, Tape.turn(ctx, first)) end,
          60_000
        )

        {:ok, turn} = Tape.turn(ctx, first)
        {:ok, steps} = Tape.steps(ctx, turn)
        assert [%{dispatch_state: "uncertain"}] = Enum.filter(steps, &(&1.action == "get"))
      end
    end

    for loss <- [:lost, :expired] do
      @tag :ownership_loss
      test "a live loop and its call stop without settling an unknown effect when ownership is #{loss}",
           %{ctx: ctx, thread: thread} do
        start_supervised!(
          {ScriptedWorker,
           ref: [@model, "catalyst:local.http"],
           script: [
             call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
             {:probe, self()},
             reply("never sent")
           ]}
        )

        {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua fetch")
        pids = running!(thread)
        runner_ref = Process.monitor(pids.runner)
        worker_refs = for pid <- [pids.loop, pids.call], do: Process.monitor(pid)
        before = tape_snapshot(ctx, thread.id, [turn_id])
        calls = ScriptedWorker.calls()
        lose_ownership(unquote(loss))

        send(
          pids.runner,
          Cyfr.Bus.Notify.new(Prima.Actor.in_athanor(ctx.athanor_id), :athanor_changed)
        )

        await_retired(pids.runner, runner_ref)
        for ref <- worker_refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 5_000)
        assert tape_snapshot(ctx, thread.id, [turn_id]) == before
        assert ScriptedWorker.calls() == calls

        Arca.ControlPlane.record(:unclaimed)
        {:ok, _successor} = Runner.ensure(thread.id, ctx.athanor_id)

        assert_receive %ThreadEvent{
                         kind: :turn_paused,
                         data: %{turn_id: ^turn_id, reason: :uncertain}
                       },
                       60_000

        assert {:ok, %{status: "paused", recovery_attempts: 1, fence: fence} = turn} =
                 Tape.turn(ctx, turn_id)

        assert fence > 1
        {:ok, steps} = Tape.steps(ctx, turn)
        assert [%{dispatch_state: "uncertain"}] = Enum.filter(steps, &(&1.action == "get"))
        send(pids.call, :continue)
        assert ScriptedWorker.calls() == calls
      end
    end
  end

  for dying <- [false, true] do
    @tag :stop_handoff
    test "Stop cancels held and queued work when its holder is dying: #{dying}", %{
      ctx: ctx,
      thread: thread
    } do
      stop_held(ctx, thread, unquote(dying))
    end
  end

  test "a post joined to a turn another process on this boot holds tells that turn's loop",
       %{ctx: ctx, thread: thread} do
    script!([{:probe, self()}, reply("never resumed")])

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua held"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    holder = spawn(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
    assert_receive {:scripted_probe, _call, _}, 60_000
    {:ok, runner} = Runner.ensure(thread.id, ctx.athanor_id)
    turn_id = turn.id
    assert %{held: %{^turn_id => %{pid: ^holder}}} = :sys.get_state(runner)

    assert :erlang.trace(holder, true, [:receive]) == 1

    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "and this"},
        steer_turn_id: turn.id
      })

    assert_receive {:trace, ^holder, :receive, {:moved, ^turn_id}}, 5_000
    assert :erlang.trace(holder, false, [:receive]) == 1
    assert :ok = Runner.stop_turn(ctx, thread.id)
    refute Process.alive?(holder)
  end

  defp stop_held(ctx, thread, dying) do
    script!([{:probe, self()}, reply("never resumed"), reply("never queued")])

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua held"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    holder = spawn(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
    assert_receive {:scripted_probe, call, _}, 60_000
    {:ok, runner} = Runner.ensure(thread.id, ctx.athanor_id)

    {:ok, %{turn_id: queued}} =
      Runner.send_message(api_line(ctx), thread.id, "@aqua queued")

    %{held: held} = :sys.get_state(runner)
    %{ref: held_ref} = Map.fetch!(held, turn.id)
    calls = ScriptedWorker.calls()

    if dying do
      :ok = :sys.suspend(runner)
      idle!(holder)
      tag = make_ref()
      send(runner, {:"$gen_call", {self(), tag}, {:stop, ctx}})
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 5_000
      :ok = :sys.resume(runner)
      # A daily thread's stop names no crew member's turn to stop after.
      assert_receive {^tag, {:ok, []}}, 5_000
    else
      assert :ok = Runner.stop_turn(ctx, thread.id)
    end

    refute Process.alive?(holder)
    refute Process.alive?(call)
    assert {:ok, %{status: "cancelled"} = cancelled} = Tape.turn(ctx, turn.id)
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, queued)
    assert %{live: nil, paused: nil, held: held, queue: []} = :sys.get_state(runner)
    assert held == %{}

    assert Enum.any?(
             Threads.messages(Sanctum.Context.actor(ctx), thread.id),
             &(&1.content == "@aqua held")
           )

    assert Enum.any?(
             Threads.messages(Sanctum.Context.actor(ctx), thread.id),
             &(&1.content == "@aqua queued")
           )

    send(runner, {:DOWN, held_ref, :process, holder, :normal})
    send(runner, {:recover, turn.id})
    send(runner, {:resume, turn.id})

    send(call, :continue)
    assert :ok = Runner.stop_turn(ctx, thread.id)
    assert Tape.turn(ctx, turn.id) == {:ok, cancelled}
    assert ScriptedWorker.calls() == calls
  end

  for loss <- [:lost, :expired],
      operation <- [:send, :stop, :restart_for_consent] do
    @tag :stop_handoff
    test "a queued #{operation} call refuses without mutation after ownership is #{loss}", %{
      ctx: ctx,
      thread: thread
    } do
      script!([{:probe, self()}, reply("first"), reply("queued")])
      {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua first")
      pids = running!(thread)

      {:ok, %{turn_id: queued}} =
        Runner.send_message(api_line(ctx), thread.id, "@aqua queued")

      request =
        case unquote(operation) do
          :send -> {:send, ctx, "@aqua late", [agents: [%{"name" => "aqua"}]]}
          :stop -> {:stop, ctx}
          :restart_for_consent -> {:restart_for_consent, ctx, %{}}
        end

      before = tape_snapshot(ctx, thread.id, [first, queued])
      calls = ScriptedWorker.calls()
      ref = Process.monitor(pids.runner)
      :ok = :sys.suspend(pids.runner)
      tag = make_ref()
      send(pids.runner, {:"$gen_call", {self(), tag}, request})
      lose_ownership(unquote(loss))
      :ok = :sys.resume(pids.runner)
      assert_receive {^tag, {:error, :control_plane_lost}}, 5_000
      await_retired(pids.runner, ref)
      assert tape_snapshot(ctx, thread.id, [first, queued]) == before
      assert ScriptedWorker.calls() == calls
    end
  end

  @tag :stop_handoff
  test "Stop refuses a fence lost during shutdown and does not finish under the successor's fence",
       %{
         ctx: ctx,
         thread: thread
       } do
    script!([{:probe, self()}, reply("never resumed")])
    {:ok, %{turn_id: id}} = Runner.send_message(ctx, thread.id, "@aqua first")
    pids = running!(thread)
    {:ok, running} = Tape.turn(ctx, id)
    :ok = :sys.suspend(Aqua.Loop.Worker)
    on_exit(fn -> :sys.resume(Aqua.Loop.Worker) end)
    stop = Task.async(fn -> Runner.stop_turn(ctx, thread.id) end)

    wait_until(fn ->
      case Tape.turn(ctx, id) do
        {:ok, turn} -> turn.fence > running.fence
        _ -> false
      end
    end)

    {:ok, aborted} = Tape.turn(ctx, id)
    {:ok, successor} = Tape.supersede(ctx, aborted)
    :ok = :sys.resume(Aqua.Loop.Worker)
    assert {:error, :superseded} = Task.await(stop, 10_000)
    assert {:ok, ^successor} = Tape.turn(ctx, id)
    refute Process.alive?(pids.loop)

    refute Enum.any?(
             Threads.messages(Sanctum.Context.actor(ctx), thread.id),
             &(&1.kind == "turn_aborted")
           )
  end

  @tag capture_log: true
  test "a loop that died ends its turn under the fence it acquired, never its successor's",
       %{ctx: ctx, thread: thread} do
    script!([{:probe, self()}, reply("never resumed")])
    {:ok, %{turn_id: id}} = Runner.send_message(ctx, thread.id, "@aqua first")
    pids = running!(thread)

    # The turn is taken between the loop's death and the runner's hearing it.
    :ok = :sys.suspend(pids.runner)
    {:ok, held} = Tape.turn(ctx, id)
    {:ok, taken} = Tape.supersede(ctx, held)
    Process.exit(pids.loop, :kill)
    :ok = :sys.resume(pids.runner)

    wait_until(fn ->
      not Process.alive?(pids.runner) or
        not match?({:ok, %{status: "running"}}, Tape.turn(ctx, id))
    end)

    assert {:ok, ^taken} = Tape.turn(ctx, id)
    send(pids.call, :continue)
  end

  for moved <- [:before, :after] do
    @tag moved: moved
    test "a resume whose turn was taken #{moved} its refusal is not ended under the fence that took it",
         %{ctx: ctx, thread: thread, moved: moved} do
      start_supervised!(
        {ScriptedWorker,
         ref: [@model, "catalyst:local.http"],
         script: [
           call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
           {:crash, :before_response}
         ]}
      )

      {:ok, %{turn_id: id}} = Runner.send_message(ctx, thread.id, "@aqua go")
      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^id}}, 60_000
      wait_until(fn -> match?(%{paused: true}, Runner.state(thread.id, ctx.athanor_id)) end)

      # The consent it pinned moved, so its resume is refused.
      {1, _} =
        Arca.Repo.update_all(
          from(t in Arca.Schemas.Turn, where: t.id == ^id),
          set: [consent_id: "moved"]
        )

      # The resuming loop waits just after it read the turn.
      read = {__MODULE__, :read, id}
      test = self()

      :ok =
        :telemetry.attach(
          read,
          [:arca, :repo, :query],
          fn _event, _measured, %{source: source}, _config ->
            if source == "turns" and Aqua.Loop.holder(id) == self() and
                 Process.put(read, true) == nil do
              send(test, {:read, self()})
              receive do: (:go -> :ok), after: (30_000 -> :ok)
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(read) end)

      assert {:ok, %{admitted: :steer}} = Runner.send_message(ctx, thread.id, "@aqua go on")
      assert_receive {:read, loop}, 10_000
      runner = Runner.whereis(thread.id)
      :ok = :sys.suspend(runner)
      gone = Process.monitor(loop)

      take = fn ->
        {:ok, held} = Tape.turn(ctx, id)
        {:ok, taken} = Tape.supersede(ctx, held)
        taken
      end

      taken =
        if moved == :before do
          taken = take.()
          send(loop, :go)
          assert_receive {:DOWN, ^gone, :process, _pid, _reason}, 30_000
          taken
        else
          send(loop, :go)
          assert_receive {:DOWN, ^gone, :process, _pid, _reason}, 30_000
          take.()
        end

      :ok = :sys.resume(runner)
      # The loop's answer is ahead of this call in the runner's mailbox.
      assert %{running: false} = Runner.state(thread.id, ctx.athanor_id)
      assert {:ok, ^taken} = Tape.turn(ctx, id)
    end
  end

  @tag :stop_handoff
  @tag capture_log: true
  test "a failed queued cancellation refuses and retries without changing an already cancelled turn",
       %{
         ctx: ctx,
         thread: thread
       } do
    script!([{:probe, self()}, {:probe, self()}, reply("never resumed")])
    {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua first")
    %{runner: stopped} = running!(thread)
    watched = Process.monitor(stopped)

    {:ok, %{turn_id: queued}} =
      Runner.send_message(api_line(ctx), thread.id, "@aqua queued")

    refuse_turn_writes(queued)
    assert {:error, :database_error} = Runner.stop_turn(ctx, thread.id)
    assert {:ok, %{status: "cancelled"} = cancelled} = Tape.turn(ctx, first)
    assert {:ok, %{status: "accepted", fence: 1}} = Tape.turn(ctx, queued)
    allow_turn_writes()

    # The runner that stopped on the refusal is gone, and its name with it,
    # before the thread's runner is asked: until then the name still finds
    # the one that is stopping, which answers nothing.
    assert_receive {:DOWN, ^watched, :process, ^stopped, _reason}, 5_000
    wait_until(fn -> Runner.whereis(thread.id) != stopped end)

    # A runner starts again and runs the queued turn until its loop waits
    # on the model's call, so the Stop stops a loop that waits and not one
    # in the middle of a write.
    assert %{running: true} = Runner.state(thread.id, ctx.athanor_id)
    assert_receive {:scripted_probe, _call, _}, 60_000

    assert :ok = Runner.stop_turn(ctx, thread.id)
    assert {:ok, ^cancelled} = Tape.turn(ctx, first)
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, queued)
    assert :ok = Runner.stop_turn(ctx, thread.id)
  end

  for standing <- [:foreign_tenant, :denied_person] do
    @tag :stop_handoff
    test "a queued Stop rechecks #{standing} before cancellation", %{
      ctx: ctx,
      user: user,
      thread: thread
    } do
      script!([{:probe, self()}, reply("never resumed")])
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, thread.id, "@aqua first")
      pids = running!(thread)
      before = tape_snapshot(ctx, thread.id, [id])
      :ok = :sys.suspend(pids.runner)

      caller =
        if unquote(standing) == :foreign_tenant,
          do: %{ctx | athanor_id: "ath_elsewhere"},
          else: ctx

      tag = make_ref()
      send(pids.runner, {:"$gen_call", {self(), tag}, {:stop, caller}})

      if unquote(standing) == :denied_person do
        Arca.Schemas.User
        |> Arca.Repo.get!(user.id)
        |> Ecto.Changeset.change(status: "denied")
        |> Arca.Repo.update!()
      end

      :ok = :sys.resume(pids.runner)
      assert_receive {^tag, {:error, :not_member}}, 5_000
      assert tape_snapshot(ctx, thread.id, [id]) == before
      assert Process.alive?(pids.loop)
    end
  end

  # The trigger and function are transactional test state. The fault is
  # removed before retry; sandbox rollback also removes them on failure.
  defp refuse_turn_writes(id) do
    id = String.replace(id, "'", "''")

    statements = %{
      Ecto.Adapters.Postgres => [
        """
        CREATE FUNCTION stop_refusal() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF OLD.id = '#{id}' THEN RAISE EXCEPTION 'test turn write refused'; END IF;
          RETURN NEW;
        END $$
        """,
        """
        CREATE TRIGGER stop_refusal BEFORE UPDATE ON turns
        FOR EACH ROW EXECUTE FUNCTION stop_refusal()
        """
      ],
      Ecto.Adapters.SQLite3 => [
        """
        CREATE TRIGGER stop_refusal BEFORE UPDATE ON turns WHEN OLD.id = '#{id}'
        BEGIN SELECT RAISE(ABORT, 'test turn write refused'); END
        """
      ]
    }

    Enum.each(
      Map.fetch!(statements, Arca.Repo.__adapter__()),
      &Ecto.Adapters.SQL.query!(Arca.Repo, &1)
    )
  end

  defp allow_turn_writes do
    statements = %{
      Ecto.Adapters.Postgres => [
        "DROP TRIGGER stop_refusal ON turns",
        "DROP FUNCTION stop_refusal()"
      ],
      Ecto.Adapters.SQLite3 => ["DROP TRIGGER stop_refusal"]
    }

    Enum.each(
      Map.fetch!(statements, Arca.Repo.__adapter__()),
      &Ecto.Adapters.SQL.query!(Arca.Repo, &1)
    )
  end

  test "a turn another process on this boot holds is left to it, and recovered once it is gone while this boot owns the control plane",
       %{ctx: ctx, thread: thread} do
    other = api_line(ctx)
    script!([{:probe, self()}, reply("taken over"), reply("second")])

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    holder = spawn(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
    assert_receive {:scripted_probe, call, _}, 60_000
    assert Aqua.Loop.holder(turn.id) == holder

    {:ok, runner} = Runner.ensure(thread.id, ctx.athanor_id)
    assert %{running: false, paused: false} = Runner.state(thread.id, ctx.athanor_id)
    assert {:ok, %{status: "running", fence: 1, recovery_attempts: 0}} = Tape.turn(ctx, turn.id)

    # A second loop over the held turn refuses before it reads anything.
    assert {:error, :held} = Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :adopt)

    # A turn accepted meanwhile waits behind the held one.
    assert {:ok, %{admitted: :turn, turn_id: second}} =
             Runner.send_message(other, thread.id, "@aqua me too")

    assert %{running: false, queued: 1} = Runner.state(thread.id, ctx.athanor_id)
    assert {:ok, %{status: "accepted"}} = Tape.turn(ctx, second)

    # The holder goes after ownership loss. The runner retires, leaving
    # both turns for a runner admitted on the owning boot.
    before = tape_snapshot(ctx, thread.id, [turn.id, second])
    runner_ref = Process.monitor(runner)
    lose_ownership(:lost)

    refs = for pid <- [holder, call], do: Process.monitor(pid)
    Process.exit(holder, :kill)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 5_000)
    await_retired(runner, runner_ref)

    assert tape_snapshot(ctx, thread.id, [turn.id, second]) == before

    Arca.ControlPlane.record(:unclaimed)
    {:ok, successor} = Runner.ensure(thread.id, ctx.athanor_id)
    refute successor == runner

    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert Runner.whereis(thread.id) == successor
    assert {:ok, %{status: "completed", recovery_attempts: 1}} = Tape.turn(ctx, turn.id)
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, second)
  end

  test "a restarted runner stops the surviving catalog handler of its first interrupted call before pausing uncertain",
       %{ctx: ctx, thread: thread} do
    start_supervised!(
      {ScriptedWorker,
       ref: [@model, "catalyst:local.http"],
       script: [
         call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
         {:probe, self()},
         reply("never sent")
       ]}
    )

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua fetch")
    pids = running!(thread)
    {:ok, turn} = Tape.turn(ctx, turn_id)
    {:ok, steps} = Tape.steps(ctx, turn)
    get = Enum.find(steps, &(&1.action == "get"))
    assert get.dispatch_state == "dispatched"
    assert Prima.TurnStep.unresolved(get) == :uncertain
    handle = {turn_id, get.id, get.generation}
    test = self()

    # The gate task is independent of the Aqua worker tree. Plant the
    # same claimed and registered handle a catalog dispatch owns while
    # this real turn is running, under a claimer that outlives the loop
    # (a claimer's death stops its handler on its own), so only the
    # continuation's cancel stops it.
    claimer =
      spawn(fn ->
        receive do
          :claim ->
            :ok = Sanctum.RunningTasks.claim(handle)

            Task.Supervisor.async_nolink(Sanctum.Gate.TaskSupervisor, fn ->
              :ok = Sanctum.RunningTasks.register_handle(handle, self())
              send(test, {:recovery_handler_registered, self()})
              Process.sleep(:infinity)
            end)
        end

        Process.sleep(:infinity)
      end)

    # Registered before the claim starts: even an earlier assertion
    # failure stops our claimer and any registered task before storage
    # and the runner fixture are released.
    on_exit(fn ->
      Process.exit(claimer, :kill)
      Aqua.Ops.cancel_call(handle)
      Aqua.Ops.release_call(handle)
    end)

    send(claimer, :claim)
    assert_receive {:recovery_handler_registered, handler}, 5_000
    handler_ref = Process.monitor(handler)
    assert Process.alive?(handler)

    # Kill the owning Runner itself. Its restart recovers the real
    # dispatched step through takeover/adoption and Loop.settle/1;
    # the dead Runner cannot call its ordinary Loop.abort crash path.
    :ok = kill_and_await!(pids)

    assert_receive %ThreadEvent{
                     kind: :turn_paused,
                     data: %{turn_id: ^turn_id, reason: :uncertain}
                   },
                   60_000

    refute Runner.whereis(thread.id) in [nil, pids.runner]

    assert {:ok, %{status: "paused", paused_reason: "uncertain", recovery_attempts: 1}} =
             Tape.turn(ctx, turn_id)

    assert {:ok, %{dispatch_state: "uncertain", outcome: "uncertain"}} = Tape.step(ctx, get.id)
    assert_receive {:DOWN, ^handler_ref, :process, ^handler, :cancelled}, 1_000
    assert Enum.count(ScriptedWorker.calls(), &(&1.input["operation"] == "chat")) == 1
  end

  # A page Aqua put into the workspace thread's window calls CYFR, and the
  # call reaches the thread's runner as `Aqua.PageCalls` hands it on.
  describe "a page's calls" do
    setup %{ctx: ctx} do
      workspace = workspace!(ctx)
      :ok = Runner.subscribe(workspace.id, ctx.athanor_id)
      {:ok, workspace: workspace}
    end

    test "a call during a running turn is a step of that turn, dispatched once while the " <>
           "model still answers",
         %{ctx: ctx, workspace: ws} do
      script!([reply("put"), {:hold, self()}, reply("done")])
      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua look around")
      assert_receive {:scripted_probe, model, _}, 60_000
      runner = Runner.whereis(ws.id)
      call = page_call(ctx, put, "component.list")
      assert {:ok, ^runner} = Runner.page_call(ws.id, ctx.athanor_id, call)

      # It closes while the model's step is still open: it waited for no answer.
      wait_until(fn -> match?([_, %{dispatch_state: "closed"}], steps!(ctx, id)) end, 30_000)
      assert [%{kind: "model", dispatch_state: "dispatched"}, _page] = steps!(ctx, id)
      send(model, :continue)
      await_ended!(ctx, id)

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, id)
      assert [model_step(ctx, id, 1, "text"), page_step(2, id, call, "ok")] == steps!(ctx, id)
      [carried, answered] = page_rows!(ctx, ws.id)
      assert carried == called(id, call)
      assert answered == answered(ctx, id, call, 200, answered.content)
      assert %{"ok" => true, "result" => _} = Jason.decode!(answered.content)
      assert chats() == 2
    end

    test "a running turn does not end while a page's step in it is open: the call runs " <>
           "once and the turn ends with no model asked again",
         %{ctx: ctx, workspace: ws} do
      script_http!([
        reply("put"),
        {:hold, self()},
        {:hold, self()},
        reply("done"),
        %{"status" => 200, "body" => "x"}
      ])

      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua wait here")
      assert_receive {:scripted_probe, model, _}, 60_000
      call = page_call(ctx, put, "http.get", %{"url" => "https://example.test/x"})
      assert {:ok, _runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      assert_receive {:scripted_probe, http, _}, 30_000

      # The model answers, calling nothing, and the turn waits on the
      # page's step, which is still at work.
      send(model, :continue)
      [%{kind: "model", child_execution_id: chat} | _] = raw_steps!(ctx, id)

      wait_until(
        fn -> match?(%{status: "completed"}, Arca.Repo.get(Arca.Schemas.Execution, chat)) end,
        30_000,
        "the model answers"
      )

      assert {:ok, %{status: "running"}} = Tape.turn(ctx, id)
      assert [_model, page] = steps!(ctx, id)
      assert page == page_step(2, id, call, nil, "dispatched")

      send(http, :continue)
      await_ended!(ctx, id)

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, id)
      assert [model_step(ctx, id, 1, "text"), page_step(2, id, call, "ok")] == steps!(ctx, id)
      [carried, answered] = page_rows!(ctx, ws.id)
      assert carried == called(id, call)
      assert answered == answered(ctx, id, call, 200, answered.content)
      assert chats() == 2
    end

    test "a call while the turn is paused around a launch writes no row and no step, and " <>
           "becomes a step of that turn once it takes its root back",
         %{ctx: ctx, workspace: ws} do
      app = quiet_app!(ctx)

      run =
        call("r1", "execution", %{
          "action" => "run",
          "reference" => app <> ":1.0.0",
          "input" => %{}
        })

      start_supervised!(
        {ScriptedWorker,
         ref: [@model, app],
         script: [
           reply("put"),
           run,
           {:hold, self()},
           %{"answered" => true},
           {:hold, self()},
           reply("ran it")
         ]}
      )

      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua run the app")

      # The app runs, held, with the turn paused around it.
      assert_receive {:scripted_probe, launched, _}, 60_000
      assert {:ok, %{status: "paused", paused_reason: "launch"}} = Tape.turn(ctx, id)
      runner = Runner.whereis(ws.id)
      before = tape_snapshot(ctx, ws.id, [put.id, id])

      call = page_call(ctx, put, "component.list")
      assert {:ok, ^runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      _ = :sys.get_state(runner)
      assert tape_snapshot(ctx, ws.id, [put.id, id]) == before

      # The launch ends and the turn runs again, its model held: the call
      # is a step of it by then, whether it ran before the model's round or
      # beside it.
      send(launched, :continue)
      assert_receive {:scripted_probe, model, _}, 60_000

      wait_until(
        fn -> Enum.any?(steps!(ctx, id), &(&1.purpose == "page")) end,
        30_000,
        "the call is a step of the turn"
      )

      send(model, :continue)
      await_ended!(ctx, id)

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, id)
      [first, launch | rest] = steps!(ctx, id)
      assert first == model_step(ctx, id, 1, nil)
      assert %{seq: 2, kind: "launch", outcome: "ok", dispatch_state: "closed"} = launch

      assert rest in [
               [page_step(3, id, call, "ok"), model_step(ctx, id, 4, "text")],
               [model_step(ctx, id, 3, "text"), page_step(4, id, call, "ok")]
             ]

      # The call waited out the pause: its step started only once the launch had closed.
      raw = raw_steps!(ctx, id)
      [launched_step] = for %{kind: "launch"} = step <- raw, do: step
      [page] = for %{purpose: "page"} = step <- raw, do: step
      assert DateTime.compare(page.started_at, launched_step.ended_at) != :lt

      [carried, answered] = page_rows!(ctx, ws.id)
      assert carried == called(id, call)
      assert answered == answered(ctx, id, call, 200, answered.content)
      assert chats() == 3
    end

    test "with no turn running, a call starts a turn that asks no model, holds the thread's " <>
           "claim, runs as the putting turn's person under that turn's origin and ends " <>
           "completed with the wire's answer",
         %{ctx: ctx, workspace: ws} do
      start_supervised!(
        {ScriptedWorker,
         ref: [@model, "catalyst:local.http"],
         script: [reply("put"), {:hold, self()}, %{"status" => 200, "body" => "x"}]}
      )

      # The page was put by the person's turn over the API, which had read
      # another thread.
      put = put!(api_line(ctx), ws)
      assert %{origin: "programmatic", requested_by: person, agent: "aqua"} = put
      assert person == ctx.user_id
      :ok = Tape.join_threads(ctx, put, ["thr_read"])
      # It asks no model, so its brain is not described for it: with the
      # description the putting turn cached forgotten, none is asked.
      Arca.Cache.delete_match({:model_caps, ctx.athanor_id, :_, :_, :_})
      described = Enum.count(ScriptedWorker.calls(), &(&1.input["operation"] == "describe"))
      call = page_call(ctx, put, "http.get", %{"url" => "https://example.test/x"})
      assert {:ok, runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      assert runner == Runner.whereis(ws.id)
      assert_receive {:scripted_probe, http, _}, 60_000

      assert described ==
               Enum.count(ScriptedWorker.calls(), &(&1.input["operation"] == "describe"))

      assert %{running: true, turn_id: id, turn_user: ^person, queued: 0} =
               Runner.state(ws.id, ctx.athanor_id)

      {:ok, running} = Tape.turn(ctx, id)
      refute id == put.id

      assert %{
               status: "running",
               requested_by: ^person,
               origin: "programmatic",
               agent: "aqua",
               sent_by: "aqua"
             } = running

      assert {:ok, %{kind: "page_call", client_id: request}} =
               Tape.message(ctx, running.message_id)

      assert request == call.request
      assert {:ok, %{turn_id: ^id, live_peer?: false}} = Tape.claim_holder(ctx, ws.id)

      send(http, :continue)
      await_ended!(ctx, id)

      assert {:ok, %{status: "completed", error: nil} = ended} = Tape.turn(ctx, id)
      assert [page_step(1, id, call, "ok")] == steps!(ctx, id)

      # It started with the read threads of the turn that put the page, and
      # its result names them: the fetch's child was seeded with them.
      assert Arca.ThreadStorage.threads_of(ended.read_threads) == ["thr_read"]
      [carried, answered] = page_rows!(ctx, ws.id)
      assert carried == called(id, call)

      expected = answered(ctx, id, call, 200, answered.content)
      assert answered == put_in(expected, [:payload, "threads"], ["thr_read"])

      # The page is answered the fetch's data, as the endpoint answers it.
      assert Jason.decode!(answered.content) ==
               Prima.TinctureWire.result(%{"body" => "x", "status" => 200})

      assert {:ok, %{turn_id: nil}} = Tape.claim_holder(ctx, ws.id)
      # The put's model run is the only one.
      assert chats() == 1
    end

    test "a second turn never runs beside one: a person's message sent while a page's call " <>
           "is at work is queued behind it",
         %{ctx: ctx, workspace: ws} do
      script_http!([
        reply("put"),
        {:hold, self()},
        %{"status" => 200, "body" => "x"},
        reply("hi")
      ])

      put = put!(ctx, ws)
      call = page_call(ctx, put, "http.get", %{"url" => "https://example.test/x"})
      assert {:ok, runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      assert_receive {:scripted_probe, http, _}, 60_000
      assert %{running: true, turn_id: work} = Runner.state(ws.id, ctx.athanor_id)

      assert {:ok, %{admitted: :turn, turn_id: line}} =
               Runner.send_message(ctx, ws.id, "@aqua hi")

      assert ^runner = Runner.whereis(ws.id)

      assert %{running: true, turn_id: ^work, queued: 1} =
               Runner.state(ws.id, ctx.athanor_id)

      assert {:ok, %{status: "accepted"}} = Tape.turn(ctx, line)
      assert [] = steps!(ctx, line)

      send(http, :continue)
      await_ended!(ctx, line)

      assert {:ok, %{status: "completed"} = done} = Tape.turn(ctx, work)
      assert {:ok, %{status: "completed"} = answered} = Tape.turn(ctx, line)
      assert DateTime.compare(answered.accepted_at, done.ended_at) == :lt
      [%{started_at: started}] = raw_steps!(ctx, line)
      assert DateTime.compare(started, done.ended_at) != :lt

      assert [page_step(1, work, call, "ok")] == steps!(ctx, work)
      assert [model_step(ctx, line, 1, "text")] == steps!(ctx, line)
      assert chats() == 2
    end

    test "a full queue of waiting calls refuses the next one :busy, and it never becomes a step",
         %{ctx: ctx, workspace: ws} do
      script!([reply("put"), {:hold, self()}, reply("never recorded")])
      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua look around")
      assert_receive {:scripted_probe, model, _}, 60_000

      # The turn's row ends before its loop's end reaches the runner: the
      # calls wait behind it.
      {:ok, running} = Tape.turn(ctx, id)
      {:ok, _} = Tape.finish(ctx, running, "cancelled", %{error: "stopped"})
      before = tape_snapshot(ctx, ws.id, [put.id, id])

      waiting = for _ <- 1..8, do: page_call(ctx, put, "component.list")
      for call <- waiting, do: assert({:ok, _} = Runner.page_call(ws.id, ctx.athanor_id, call))
      refused = page_call(ctx, put, "component.list")
      assert {:error, :busy} = Runner.page_call(ws.id, ctx.athanor_id, refused)
      assert tape_snapshot(ctx, ws.id, [put.id, id]) == before

      # Once the turn's end reaches the runner the eight run, each once,
      # in work of their own.
      send(model, :continue)

      wait_until(
        fn -> Enum.count(page_rows!(ctx, ws.id), &(&1.kind == "page_result")) == 8 end,
        30_000,
        "the eight are answered"
      )

      works = ctx |> page_rows!(ws.id) |> Enum.map(& &1.turn_id) |> Enum.uniq()
      for work <- works, do: await_ended!(ctx, work)
      refute id in works
      steps = for work <- works, step <- steps!(ctx, work), do: {work, step}
      assert length(steps) == 8

      for call <- waiting do
        assert [{work, step}] =
                 for(
                   {work, %{idempotency_key: key} = step} <- steps,
                   key == "page_call:#{work}:#{call.request}",
                   do: {work, step}
                 )

        assert step == page_step(step.seq, work, call, "ok")
      end

      rows = Threads.messages(Sanctum.Context.actor(ctx), ws.id)
      refute Enum.any?(rows, &(&1.client_id == refused.request))
      refute Enum.any?(rows, &(Tape.payload(&1)["tool_call_id"] == refused.request))
    end

    test "a page's call that does more than read runs at once in work of its own, which " <>
           "leaves its workspace thread as Aqua's work left it",
         %{ctx: ctx, workspace: ws} do
      script!([reply("put")])
      put = put!(ctx, ws)

      # Aqua's own work left the thread done.
      {:ok, %{turn: done}} =
        Arca.TurnStorage.accept_message(Sanctum.Context.actor(ctx), ws.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "and report"},
          turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
        })

      {:ok, _} = Tape.report_workspace(ctx, done, "done", %{summary: "Done."})
      {:ok, _} = Tape.finish(ctx, done, "cancelled", %{error: "stopped"})
      before = thread_state(ctx, ws.id)
      assert before == "done"
      reported = reports(ctx)

      keep = page_call(ctx, put, "notes.keep", %{"name" => "from-page", "content" => "x"})
      assert {:ok, _runner} = Runner.page_call(ws.id, ctx.athanor_id, keep)
      work = work_of!(ctx, ws.id, keep)
      await_ended!(ctx, work)
      refute_received %ThreadEvent{kind: :turn_paused}

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, work)
      assert [page_step(1, work, keep, "ok")] == steps!(ctx, work)
      assert {:ok, %{content: "x"}} = Aqua.Notes.read(ctx, "from-page")
      assert thread_state(ctx, ws.id) == before
      assert reports(ctx) == reported
    end

    test "deleting the thread stops the work: the turn is cancelled, the waiting call " <>
           "dropped and the runner gone",
         %{ctx: ctx, workspace: ws} do
      script_http!([reply("put"), {:crash, :before_response}])
      put = put!(ctx, ws)
      get = page_call(ctx, put, "http.get", %{"url" => "https://example.test/x"})
      assert {:ok, runner} = Runner.page_call(ws.id, ctx.athanor_id, get)

      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: work, reason: :uncertain}},
                     60_000

      waiting = page_call(ctx, put, "component.list")
      assert {:ok, ^runner} = Runner.page_call(ws.id, ctx.athanor_id, waiting)
      watched = Process.monitor(runner)

      assert {:ok, %{deleted: true}} =
               Aqua.Providers.Thread.handle("thread", ctx, %{
                 "action" => "delete",
                 "thread" => ws.id
               })

      await_retired(runner, watched)
      # The registry lets a name go on its own monitor of the runner.
      wait_until(fn -> Runner.whereis(ws.id) == nil end)
      assert {:error, :not_found} = Tape.thread(ctx, ws.id)
      assert {:error, :not_found} = Tape.turn(ctx, work)
      assert [] = Threads.messages(Sanctum.Context.actor(ctx), ws.id)
      assert chats() == 1
    end

    test "a turn that lost its fence writes no step for a page's call", %{
      ctx: ctx,
      workspace: ws
    } do
      script!([reply("put"), {:hold, self()}, reply("never read")])
      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua look around")
      assert_receive {:scripted_probe, _model, _}, 60_000
      runner = Runner.whereis(ws.id)

      # Another holder takes the turn: its fence rises under the loop.
      {:ok, running} = Tape.turn(ctx, id)
      {:ok, taken} = Tape.supersede(ctx, running)
      assert taken.fence > running.fence
      before = tape_snapshot(ctx, ws.id, [put.id, id])

      call = page_call(ctx, put, "component.list")
      assert {:ok, ^runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      _ = :sys.get_state(runner)
      assert tape_snapshot(ctx, ws.id, [put.id, id]) == before
    end

    test "a stop ends the thread's work and refuses the calls waiting behind its turn: none " <>
           "becomes a step of the next one, which is new work",
         %{ctx: ctx, workspace: ws} do
      script_http!([reply("put"), fetch("c1"), {:crash, :before_response}, reply("again")])

      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua fetch it")

      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^id, reason: :uncertain}},
                     60_000

      call = page_call(ctx, put, "component.list")
      assert {:ok, _runner} = Runner.page_call(ws.id, ctx.athanor_id, call)

      # The page's answer goes to the person's browser, which this test
      # stands in for while the stop runs.
      browser = {ctx.athanor_id, ctx.user_id, :person}
      {:ok, _owner} = Registry.register(Opus.Browser.Registry, browser, nil)
      stop = Task.async(fn -> Runner.stop_turn(ctx, ws.id) end)
      request = call.request

      assert_receive {:"$gen_call", from,
                      {:answer, ^request, status, %Opus.Programs.Output{bytes: body}}},
                     30_000

      GenServer.reply(from, :ok)
      assert :ok = Task.await(stop, 30_000)
      :ok = Registry.unregister(Opus.Browser.Registry, browser)

      assert {status, body} ==
               Aqua.PageCalls.answered(%{content: "stopped", payload: %{"skipped" => true}})

      assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, id)
      assert thread_state(ctx, ws.id) == "stopped"
      assert {:ok, []} = Tape.open_turns(ctx, ws.id)
      assert %{running: false, paused: false, queued: 0} = Runner.state(ws.id, ctx.athanor_id)
      assert reports(ctx) == []

      {:ok, %{turn_id: next}} = Runner.send_message(ctx, ws.id, "@aqua again")
      assert thread_state(ctx, ws.id) == "open"
      await_ended!(ctx, next)

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, next)
      assert [model_step(ctx, next, 1, "text")] == steps!(ctx, next)
      assert [] = page_rows!(ctx, ws.id)
      assert thread_state(ctx, ws.id) == "open"
      assert reports(ctx) == []
    end

    test "a call that comes as the running turn ends opens work of its own, which runs it",
         %{ctx: ctx, workspace: ws} do
      script!([reply("put"), {:hold, self()}, reply("never recorded")])
      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua look around")
      assert_receive {:scripted_probe, model, _}, 60_000

      # The turn's row ends before its loop's end reaches the runner.
      {:ok, running} = Tape.turn(ctx, id)
      {:ok, _} = Tape.finish(ctx, running, "cancelled", %{error: "stopped"})
      call = page_call(ctx, put, "notes.keep", %{"name" => "from-page", "content" => "x"})
      assert {:ok, _runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      send(model, :continue)

      work = work_of!(ctx, ws.id, call)
      refute work == id
      await_ended!(ctx, work)
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, work)
      assert [page_step(1, work, call, "ok")] == steps!(ctx, work)
      [carried, answered] = page_rows!(ctx, ws.id)
      assert carried == called(work, call)
      assert answered == answered(ctx, work, call, 200, answered.content)
      assert {:ok, %{content: "x"}} = Aqua.Notes.read(ctx, "from-page")
    end

    test "a request that ended while its call waits drops the call: it never becomes a step",
         %{ctx: ctx, workspace: ws} do
      script_http!([reply("put"), fetch("c1"), {:crash, :before_response}, reply("carried on")])

      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua fetch it")

      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^id, reason: :uncertain}},
                     60_000

      runner = Runner.whereis(ws.id)
      call = page_call(ctx, put, "component.list")
      assert {:ok, ^runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      assert :ok = Runner.page_call_ended(ws.id, ctx.athanor_id, call.request)

      assert {:ok, %{admitted: :steer, turn_id: ^id}} =
               Runner.send_message(ctx, ws.id, "@aqua go on")

      await_ended!(ctx, id)
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, id)

      assert [
               model_step(ctx, id, 1, nil),
               unknown_step(ctx, id, 2, "c1"),
               model_step(ctx, id, 3, "text")
             ] == steps!(ctx, id)

      assert [] = page_rows!(ctx, ws.id)

      # The loop writes the turn's end before it answers its runner.
      wait_until(fn ->
        match?(
          %{running: false, paused: false, queued: 0},
          Runner.state(ws.id, ctx.athanor_id)
        )
      end)
    end

    test "a request that ended while its step is proposed skips the step: it never runs, " <>
           "and the turn goes on",
         %{ctx: ctx, workspace: ws} do
      script_http!([
        reply("put"),
        fetch("c1"),
        {:hold, self()},
        %{"status" => 200, "body" => "x"},
        reply("fetched")
      ])

      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua fetch it")
      assert_receive {:scripted_probe, http, _}, 60_000

      # The turn's own call is held: the page's call is proposed in the
      # turn and waits there for the loop's next round.
      call = page_call(ctx, put, "notes.keep", %{"name" => "from-page", "content" => "x"})
      assert {:ok, _runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      assert [_model, _fetch, page] = steps!(ctx, id)
      assert page == page_step(3, id, call, nil, "proposed")

      assert :ok = Runner.page_call_ended(ws.id, ctx.athanor_id, call.request)
      assert [_model, _fetch, page] = steps!(ctx, id)
      assert page == page_step(3, id, call, "skipped")

      send(http, :continue)
      await_ended!(ctx, id)

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, id)

      assert [
               model_step(ctx, id, 1, nil),
               call_step(ctx, id, 2, "http.get", "c1", "ok"),
               page_step(3, id, call, "skipped"),
               model_step(ctx, id, 4, "text")
             ] == steps!(ctx, id)

      [carried, answered] = page_rows!(ctx, ws.id)
      assert carried == called(id, call)
      [%{id: step_id}] = for %{purpose: "page"} = step <- raw_steps!(ctx, id), do: step

      assert answered == %{
               kind: "page_result",
               author: Prima.Author.system(),
               sent_by: "aqua",
               content: "the page's request ended",
               client_id: nil,
               turn_id: id,
               payload: %{
                 "tool_call_id" => call.request,
                 "name" => call.name,
                 "skipped" => true,
                 "step_id" => step_id
               }
             }

      assert {:error, _} = Aqua.Notes.read(ctx, "from-page")
      assert chats() == 3
    end
  end

  # A workspace thread's turn that ends with no report of its own: the
  # person's act stops its work, and Aqua that could not run there is the
  # server's error, told in one report.
  describe "a workspace thread's turn that ends without its report" do
    setup %{ctx: ctx} do
      workspace = workspace!(ctx)
      :ok = Runner.subscribe(workspace.id, ctx.athanor_id)
      {:ok, workspace: workspace}
    end

    test "the consent restart is the person's act: the thread reads stopped, with no report",
         %{ctx: ctx, workspace: ws} do
      script!([{:probe, self()}, reply("never sent")])
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua go")
      pids = running!(ws)

      assert :ok = Runner.restart_for_consent(ctx, ws.id, %{})
      assert_receive %ThreadEvent{kind: :restart_prompt}, 10_000
      send(pids.call, :continue)

      assert {:ok, %{status: "cancelled", error: "restart required"}} = Tape.turn(ctx, id)
      assert thread_state(ctx, ws.id) == "stopped"
      assert reports(ctx) == []
    end

    test "a turn that ends failed is Aqua that could not run there: the thread reads error, " <>
           "with one report saying why",
         %{ctx: ctx, workspace: ws} do
      script!([{:error, "the model could not be reached"}])
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua go")
      await_ended!(ctx, id)

      assert {:ok, %{status: "failed", error: error}} = Tape.turn(ctx, id)
      assert is_binary(error) and error != ""
      assert thread_state(ctx, ws.id) == "error"
      assert [%{"outcome" => "error", "turn_id" => ^id, "summary" => ^error}] = reports(ctx)
    end

    test "a loop that crashes leaves its turn uncertain: the thread reads error, with one " <>
           "report saying why",
         %{ctx: ctx, workspace: ws} do
      script!([{:probe, self()}, reply("never sent")])
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua go")
      pids = running!(ws)

      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(pids.loop, :crashed)
        wait_until(fn -> match?({:ok, %{status: "uncertain"}}, Tape.turn(ctx, id)) end)
      end)

      send(pids.call, :continue)

      assert {:ok, %{status: "uncertain", error: error}} = Tape.turn(ctx, id)
      assert is_binary(error) and error != ""
      assert thread_state(ctx, ws.id) == "error"
      assert [%{"outcome" => "error", "turn_id" => ^id, "summary" => ^error}] = reports(ctx)
    end
  end

  # A workspace thread of the person's, as a workspace's opening makes one.
  # An app of the person's own with no exit at all, granted with nothing to
  # bind: a launch of it runs on the scripted worker that names it.
  defp quiet_app!(ctx) do
    name = "runner-app-#{System.unique_integer([:positive])}"

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(%{"name" => name, "version" => "1.0.0", "type" => "reagent"})
      })

    ref = "reagent:local." <> name
    decisions = %{ref: ref, bindings: []}
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

    ref
  end

  defp workspace!(ctx) do
    %Arca.Schemas.Thread{}
    |> Arca.Schemas.Thread.changeset(%{
      id: Prima.UUID7.generate_id("thread"),
      athanor_id: ctx.athanor_id,
      kind: "workspace",
      workspace_state: "open",
      title: "Show the page",
      created_by: ctx.user_id
    })
    |> Arca.Repo.insert!()
  end

  # The turn that put the page into the workspace thread's window, ended.
  defp put!(ctx, workspace) do
    {:ok, %{turn_id: id}} = Runner.send_message(ctx, workspace.id, "@aqua put the page")
    await_ended!(ctx, id)
    {:ok, %{status: "completed"} = put} = Tape.turn(ctx, id)
    put
  end

  # A call the page makes, as `Aqua.PageCalls` hands it to the runner,
  # its browser this test, which outlives it.
  defp page_call(ctx, put, name, arguments \\ %{}),
    do: %{
      request: Prima.UUID7.generate_id("pgc"),
      name: name,
      arguments: arguments,
      user_id: ctx.user_id,
      put_turn_id: put.id,
      browser: self()
    }

  # The turn has ended, and the runner has taken its end.
  defp await_ended!(ctx, turn_id) do
    wait_until(
      fn -> match?({:ok, %{ended_at: %DateTime{}}}, Tape.turn(ctx, turn_id)) end,
      60_000,
      "turn #{turn_id} ends"
    )
  end

  defp chats, do: Enum.count(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

  defp raw_steps!(ctx, turn_id) do
    {:ok, turn} = Tape.turn(ctx, turn_id)
    {:ok, steps} = Tape.steps(ctx, turn)
    steps
  end

  # A turn's steps as a case compares them: every field but those minted
  # (ids, clocks, digests, usage), which a case reads where it speaks of
  # them, with the rows a step carries its call and its answer in, by kind.
  defp steps!(ctx, turn_id) do
    for step <- raw_steps!(ctx, turn_id) do
      %{
        seq: step.seq,
        kind: step.kind,
        purpose: step.purpose,
        tool: step.tool,
        action: step.action,
        dispatch_state: step.dispatch_state,
        outcome: step.outcome,
        generation: step.generation,
        recovery: step.recovery,
        idempotency_key: step.idempotency_key && key_of(step),
        error: step.error,
        cancel_requested?: step.cancel_requested_at != nil,
        carried: kind_of(ctx, step.message_id),
        answered: kind_of(ctx, step.result_message_id)
      }
    end
  end

  # A model step's key is its turn's and its step's, which a case does not mint.
  defp key_of(%{kind: "model"}), do: :model
  defp key_of(%{idempotency_key: key}), do: key

  defp kind_of(_ctx, nil), do: nil

  defp kind_of(ctx, id) do
    {:ok, row} = Tape.message(ctx, id)
    row.kind
  end

  # A model step of `turn_id` that answered, on the catalyst the turn
  # pinned; `answered` is the row of its reply, "text", or nil for an
  # answer of calls alone.
  defp model_step(ctx, turn_id, seq, answered) do
    {:ok, %{catalyst_ref: catalyst}} = Tape.turn(ctx, turn_id)

    %{
      seq: seq,
      kind: "model",
      purpose: "chat",
      tool: catalyst,
      action: "chat",
      dispatch_state: "closed",
      outcome: "ok",
      generation: 0,
      recovery: nil,
      idempotency_key: :model,
      error: nil,
      cancel_requested?: false,
      carried: nil,
      answered: answered
    }
  end

  # A step of the model's call `id` of `name` in `turn_id`, the model step
  # before it the one that made it, closed with `outcome` and `error`.
  defp call_step(ctx, turn_id, seq, name, id, outcome, error \\ nil) do
    [tool, action] = String.split(name, ".")
    [model] = for %{seq: at, id: step} <- raw_steps!(ctx, turn_id), at == seq - 1, do: step

    %{
      seq: seq,
      kind: "tool",
      purpose: "chat",
      tool: tool,
      action: action,
      dispatch_state: "closed",
      outcome: outcome,
      generation: 0,
      recovery: nil,
      idempotency_key: "call:#{turn_id}:#{model}:#{id}",
      error: error,
      cancel_requested?: false,
      carried: "tool_call",
      answered: "tool_result"
    }
  end

  # The fetch `id` whose outcome is unknown, its waiter killed, as the
  # turn left it once the sender's next line continued it.
  defp unknown_step(ctx, turn_id, seq, id) do
    %{
      call_step(ctx, turn_id, seq, "http.get", id, "uncertain", "killed")
      | dispatch_state: "uncertain",
        answered: nil
    }
  end

  # The work a page's call opened: the turn its row is carried in.
  defp work_of!(ctx, thread_id, call) do
    wait_until(
      fn ->
        Enum.any?(
          page_rows!(ctx, thread_id),
          &(&1.client_id == call.request and is_binary(&1.turn_id))
        )
      end,
      30_000,
      "the call opens its work"
    )

    [work] =
      for %{client_id: id, turn_id: turn} <- page_rows!(ctx, thread_id),
          id == call.request,
          do: turn

    work
  end

  # The system lines of `thread`, oldest first.
  defp system_lines(ctx, thread) do
    for %{kind: "system", content: text} <-
          Threads.messages(Sanctum.Context.actor(ctx), thread.id),
        do: text
  end

  # The thread's rows, oldest first, each whole but for its id and clock,
  # which are minted.
  defp rows!(ctx, thread_id) do
    for row <- Threads.messages(Sanctum.Context.actor(ctx), thread_id),
        do: Map.drop(row, [:id, :inserted_at])
  end

  # A row of `thread` as `rows!/2` reads it: `fields` over the columns a
  # row leaves empty.
  defp row(thread, fields) do
    Map.merge(
      %{
        thread_id: thread.id,
        athanor_id: thread.athanor_id,
        payload: nil,
        status: nil,
        resolved_by: nil,
        carried_by: nil,
        resolved_at: nil,
        execution_id: nil,
        turn_id: nil,
        client_id: nil,
        addressee: nil,
        reply_to: nil,
        outcome: nil,
        workspace_id: nil
      },
      fields
    )
  end

  # A page's step in `turn_id` for `call`; of the calls here only
  # `component.list` is replay-safe.
  defp page_step(seq, turn_id, call, outcome, state \\ "closed") do
    [tool, action] = String.split(call.name, ".")

    %{
      seq: seq,
      kind: if(call.name == "execution.run", do: "launch", else: "tool"),
      purpose: "page",
      tool: tool,
      action: action,
      dispatch_state: state,
      outcome: outcome,
      generation: 0,
      recovery: if(call.name == "component.list", do: "replay_safe"),
      idempotency_key: "page_call:#{turn_id}:#{call.request}",
      error: nil,
      cancel_requested?: false,
      carried: "page_call",
      answered: if(state == "closed", do: "page_result")
    }
  end

  # The thread's rows of a page's calls and their answers, as a case
  # compares them.
  defp page_rows!(ctx, thread_id) do
    for row <- Threads.messages(Sanctum.Context.actor(ctx), thread_id),
        row.kind in ["page_call", "page_result"] do
      %{
        kind: row.kind,
        author: row.author,
        sent_by: row.sent_by,
        content: row.content,
        client_id: row.client_id,
        turn_id: row.turn_id,
        payload: Tape.payload(row)
      }
    end
  end

  # The row a page's call is carried in.
  defp called(turn_id, call) do
    %{
      kind: "page_call",
      author: Prima.Author.agent(),
      sent_by: "aqua",
      content: call.name,
      client_id: call.request,
      turn_id: turn_id,
      payload: Aqua.PageCalls.row(call)
    }
  end

  # The row a page's call is answered in, with the wire's answer.
  defp answered(ctx, turn_id, call, status, body) do
    [%{id: step_id}] =
      for %{idempotency_key: key} = step <- raw_steps!(ctx, turn_id),
          key == "page_call:#{turn_id}:#{call.request}",
          do: step

    %{
      kind: "page_result",
      author: Prima.Author.system(),
      sent_by: "aqua",
      content: body,
      client_id: nil,
      turn_id: turn_id,
      payload: %{
        "tool_call_id" => call.request,
        "name" => call.name,
        "status" => status,
        "is_error" => false,
        "step_id" => step_id
      }
    }
  end

  defp thread_state(ctx, id) do
    {:ok, thread} = Threads.get(Sanctum.Context.actor(ctx), id)
    thread.workspace_state
  end

  # Every workspace_report the athanor recorded, delivered or not.
  defp reports(ctx) do
    import Ecto.Query, only: [from: 2]

    from(r in Arca.Schemas.OutboxRecord,
      where: r.athanor_id == ^ctx.athanor_id and r.kind == "workspace_report",
      select: r.snapshot
    )
    |> Arca.Repo.all()
    |> Enum.map(&Jason.decode!/1)
  end
end
