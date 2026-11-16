# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RunnerTest do
  @moduledoc """
  The runner owns a thread's turns: a send is admitted in order
  and accepted with the turn it opens or refused with nothing written;
  one turn runs at a time, the sender's own line steers it and a line to
  another agent or under another origin waits; a stop cuts the turn and drops the queue; a card pauses
  the turn and its decision continues it; a runner that starts finds the
  open turns and does what their rows say, resuming each under the origin
  its row stores and cancelling one whose stored origin is outside the
  vocabulary. A runner's loop dies with it;
  a runner starts and handles loop events only on a boot that owns the
  control plane, and never takes a turn another process on this boot holds.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Aqua.{Approvals, Runner, Tape}
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

  # A crew member the athanor made, on the scripted model, consented as a
  # person consents one: it runs under the soul's policy as a source of its
  # own, its edge into the model selecting the key bound on the model's
  # default profile.
  defp member!(ctx, name) do
    :ok =
      Arca.put(
        Sanctum.Context.actor(ctx),
        Compendium.AquaPath.crew_file(name),
        "---\ntitle: #{String.capitalize(name)}\ndescription: Plans.\navoid: Building.\n" <>
          "catalyst_ref: #{@model}\nmodel: claude-sonnet-5-5\n---\n\nYou are the #{name}.\n"
      )

    {:ok, _} = Compendium.AgentIndex.sync(ctx)

    ref = Prima.AgentRef.ref(name)
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, selections: [%{dep: @model, label: "default"}]}
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

  defp kill_and_await!(%{runner: runner} = pids) do
    refs = for {_name, pid} <- pids, into: %{}, do: {Process.monitor(pid), pid}
    Process.exit(runner, :kill)
    for {ref, _pid} <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 5_000)
    # The supervisor has answered the runner's exit: restarted it or not.
    _ = :sys.get_state(Aqua.RunnerSupervisor)
    :ok
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

  defp tape_snapshot(ctx, thread_id, turn_ids, approval_ids \\ []) do
    turns =
      for id <- turn_ids do
        {:ok, turn} = Tape.turn(ctx, id)
        {:ok, steps} = Tape.steps(ctx, turn)
        {turn, steps}
      end

    %{
      thread: Tape.thread(ctx, thread_id),
      messages: Threads.messages(Sanctum.Context.actor(ctx), thread_id),
      turns: turns,
      approvals: Enum.map(approval_ids, &Tape.approval(ctx, &1))
    }
  end

  # The card's expiry lies in the past, as a day's wait puts it there.
  defp lapse!(approval) do
    import Ecto.Query, only: [from: 2]
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      from(a in Arca.Schemas.Approval, where: a.id == ^approval.id)
      |> Arca.Repo.update_all(set: [expires_at: past])
  end

  # A trigger that refuses every write of `error` as a step's error, spelled
  # per adapter. The sandbox rolls it back with the test.
  defp refuse_step_error!(error) do
    name = "runner_test_refused_step_error"

    if Arca.Test.Adapter.sqlite?() do
      Arca.Repo.query!(
        "CREATE TRIGGER #{name} BEFORE UPDATE ON turn_steps WHEN NEW.error = '#{error}' " <>
          "BEGIN SELECT RAISE(ABORT, 'the step write is refused'); END"
      )
    else
      Arca.Repo.query!(
        "CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS " <>
          "$$ BEGIN RAISE EXCEPTION 'the step write is refused'; END $$"
      )

      Arca.Repo.query!(
        "CREATE TRIGGER #{name} BEFORE UPDATE ON turn_steps FOR EACH ROW " <>
          "WHEN (NEW.error = '#{error}') EXECUTE FUNCTION #{name}()"
      )
    end

    name
  end

  defp allow_step_errors!(name) do
    if Arca.Test.Adapter.sqlite?(),
      do: Arca.Repo.query!("DROP TRIGGER #{name}"),
      else: Arca.Repo.query!("DROP TRIGGER #{name} ON turn_steps")
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

  test "the sender's line while the turn is paused on a card steers it, drained on resume", %{
    ctx: ctx,
    thread: thread
  } do
    script!([call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})])

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua keep it")
    # The runner holds the pause once it announces it, after the loop's row.
    assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^turn_id}}, 60_000

    assert {:ok, %{admitted: :steer, turn_id: ^turn_id}} =
             Runner.send_message(ctx, thread.id, "@aqua never mind")

    assert %{running: false, paused: true, queued: 0} = Runner.state(thread.id, ctx.athanor_id)

    {:ok, paused} = Tape.turn(ctx, turn_id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    ScriptedWorker.script([reply("never minded")])

    assert {:ok, %{decision: "approved"}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn_id)

    # The steer rode the paused turn and displaced the card's step.
    {:ok, steps} = Tape.steps(ctx, paused)
    assert %{action: "keep", outcome: "skipped"} = Enum.find(steps, &(&1.action == "keep"))

    assert %{turn_id: ^turn_id} =
             Enum.find(
               Threads.messages(Sanctum.Context.actor(ctx), thread.id),
               &(&1.content == "@aqua never mind")
             )
  end

  test "a runner that starts over a paused row knows it before the first send", %{
    ctx: ctx,
    thread: thread
  } do
    script!([call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})])

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua keep it"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    assert {:paused, :approval} =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

    assert nil == Runner.whereis(thread.id)
    other = api_line(ctx)

    assert {:ok, %{admitted: :turn, turn_id: second}} =
             Runner.send_message(other, thread.id, "@aqua me too")

    assert second != turn.id
    assert %{running: false, paused: true, queued: 1} = Runner.state(thread.id, ctx.athanor_id)
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

  test "a turn addressed to a source with no consent claims no root and asks for setup", %{
    ctx: ctx,
    thread: thread
  } do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@ghost go"},
        turn: %{agent: "ghost", requested_by: ctx.user_id}
      })

    assert {:failed, :setup_required} = Aqua.Loop.run(ctx: ctx, turn_id: turn.id)

    assert {:ok, %{status: "failed", root_execution_id: nil, profile_id: nil}} =
             Tape.turn(ctx, turn.id)

    assert nil == Arca.Repo.get_by(Arca.Schemas.Execution, turn_id: turn.id)
    user = ctx.user_id

    assert_receive %ThreadEvent{
                     kind: :consent_required,
                     data: %{ref: "agent:local.ghost", user_id: ^user}
                   },
                   5_000
  end

  test "a crew member asked by name works in its child thread as its own source, with its own consent and key",
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

    {:ok, [planner_profile]} =
      Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "agent:local.planner")

    {:ok, turn} = Tape.turn(ctx, turn_id)
    assert turn.request_id == request and turn.asking_thread_id == thread.id
    assert turn.status == "completed" and turn.agent == "planner"
    assert turn.profile_id == planner_profile.id
    assert {:ok, bytes} = Tape.agent_revision(ctx, turn)
    assert bytes =~ "Planner"

    assert %{authority: authority} =
             Enum.find(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

    assert authority.chain == ["agent:local.planner", @model]
    assert authority.profile_id == planner_profile.id
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

  test "a card pauses the turn, and the decision continues it", %{ctx: ctx, thread: thread} do
    script!([call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})])

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua keep it")
    # The loop writes the paused row before it answers the runner; the
    # runner announces the pause once its own state holds it.
    assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^turn_id}}, 60_000
    assert %{running: false, paused: true} = Runner.state(thread.id, ctx.athanor_id)

    {:ok, paused} = Tape.turn(ctx, turn_id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    ScriptedWorker.script([reply("kept it")])

    assert {:ok, %{decision: "approved"}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn_id)
    {:ok, steps} = Tape.steps(ctx, paused)
    assert %{action: "keep", outcome: "ok"} = Enum.find(steps, &(&1.action == "keep"))
  end

  # A card that expires continues its turn with no decision of a person's
  # and no restart recovery spent. The turn forgot its thread's session
  # before the pause, so a session the brain no longer holds after it ends
  # the turn: a turn forgets once, across its continuations.
  test "a turn that forgot its thread's session and went on from an expired card forgets no second",
       %{ctx: ctx, thread: thread} do
    actor = Sanctum.Context.actor(ctx)
    gone = %{"type" => "unknown_session", "message" => "The brain no longer holds this session."}
    keep = call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})

    script!([
      Map.put(reply("hello"), "session", "brain-1"),
      {:refuse, gone},
      Map.put(keep, "session", "brain-2"),
      {:refuse, gone},
      reply("never asked")
    ])

    {:ok, _} = Runner.send_message(ctx, thread.id, "@aqua hello")
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000

    assert {:ok, %{brain_session: "brain-1", brain_generation: generation}} =
             Threads.get(actor, thread.id)

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua keep it")
    assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^turn_id}}, 60_000

    assert {:ok, %{brain_session: "brain-2", brain_generation: forgotten}} =
             Threads.get(actor, thread.id)

    assert forgotten == generation + 1

    {:ok, paused} = Tape.turn(ctx, turn_id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    lapse!(approval)
    send(Runner.whereis(thread.id), {:expire, turn_id})

    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    assert {:ok, %{status: "expired"}} = Tape.approval(ctx, approval.id)

    assert {:ok, %{status: "failed", error: error, recovery_attempts: 0}} =
             Tape.turn(ctx, turn_id)

    assert error == gone["message"]

    assert {:ok, %{brain_session: "brain-2", brain_generation: ^forgotten}} =
             Threads.get(actor, thread.id)

    sessions =
      for %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
          do: params["session"]

    assert sessions == [nil, "brain-1", nil, "brain-2"]
  end

  # The store refuses the write of the mark that the turn forgot a session.
  # Nothing is forgotten and nothing is asked again, since a continued turn
  # would find no mark and forget a second time. Whichever way the turn
  # goes on, to its end or to a card that then expires, the thread's
  # session and generation are as they were and no request follows the
  # refused one.
  test "a refused write of the forget's mark leaves the thread's session and asks nothing again",
       %{ctx: ctx, thread: thread} do
    actor = Sanctum.Context.actor(ctx)
    gone = %{"type" => "unknown_session", "message" => "The brain no longer holds this session."}
    keep = call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})

    script!([
      Map.put(reply("hello"), "session", "brain-1"),
      {:refuse, gone},
      Map.put(keep, "session", "brain-2"),
      {:refuse, gone},
      reply("never asked")
    ])

    {:ok, _} = Runner.send_message(ctx, thread.id, "@aqua hello")
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000

    assert {:ok, %{brain_session: "brain-1", brain_generation: generation}} =
             Threads.get(actor, thread.id)

    refused = refuse_step_error!("unknown_session")
    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua keep it")

    reached =
      receive do
        %ThreadEvent{kind: kind} when kind in [:turn_finished, :turn_paused] -> kind
      after
        60_000 -> flunk("the turn neither finished nor paused")
      end

    allow_step_errors!(refused)

    if reached == :turn_paused do
      {:ok, paused} = Tape.turn(ctx, turn_id)
      {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
      lapse!(approval)
      send(Runner.whereis(thread.id), {:expire, turn_id})
      assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
      assert {:ok, %{status: "expired"}} = Tape.approval(ctx, approval.id)
    end

    {:ok, stored} = Threads.get(actor, thread.id)
    {:ok, ended} = Tape.turn(ctx, turn_id)

    sessions =
      for %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
          do: params["session"]

    assert stored.brain_generation == generation
    assert stored.brain_session == "brain-1"
    assert ended.status == "failed"
    assert ended.recovery_attempts == 0
    assert sessions == [nil, "brain-1"]
  end

  @tag :stop_handoff
  test "Stop invalidates a paused approval and a late decision cannot continue the turn", %{
    ctx: ctx,
    thread: thread
  } do
    script!([
      call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}),
      reply("never resumed")
    ])

    {:ok, %{turn_id: id}} = Runner.send_message(ctx, thread.id, "@aqua keep it")
    runner = Runner.whereis(thread.id)
    wait_until(fn -> match?(%{paused: %{}}, :sys.get_state(runner)) end, 60_000)
    {:ok, turn} = Tape.turn(ctx, id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, turn)
    {:ok, %{turn_id: queued}} = Runner.send_message(api_line(ctx), thread.id, "@aqua queued")
    calls = ScriptedWorker.calls()

    assert :ok = Runner.stop_turn(ctx, thread.id)
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, id)
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, queued)
    assert {:ok, %{status: "invalidated"}} = Tape.approval(ctx, approval.id)

    assert {:ok, %{decision: "invalidated", replayed: true}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    send(runner, %ThreadEvent{
      athanor_id: ctx.athanor_id,
      thread_id: thread.id,
      kind: :approval_resolved,
      data: %{turn_id: id}
    })

    _ = :sys.get_state(runner)
    assert ScriptedWorker.calls() == calls
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

    {:ok, %{capability_digest: capability, revision_digest: revision}} =
      Compendium.AgentIndex.snapshot(ctx, "aqua")

    {:ok, running} =
      Tape.start_turn(ctx, turn, %{
        root_execution_id: claim.execution_id,
        attempt: claim.attempt,
        budget_id: claim.budget_id,
        profile_id: claim.authority.profile_id,
        consent_id: claim.authority.consent_id,
        agent_revision_digest: revision,
        agent_capability_digest: capability,
        recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
      })

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

  test "an approval pause keeps the thread's claim", %{ctx: ctx, thread: thread} do
    script!([call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})])

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua keep it")
    wait_until(fn -> match?({:ok, %{status: "paused"}}, Tape.turn(ctx, turn_id)) end, 60_000)

    # Paused on a card: still this member's work, so still its thread.
    assert {:ok, %{status: "paused", paused_reason: "approval"}} = Tape.turn(ctx, turn_id)
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

    test "a card on a turn whose stored origin is outside the vocabulary is refused, and the " <>
           "turn ends, never resumed",
         %{ctx: ctx, thread: thread} do
      script!([call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})])

      # Paused on its card by a loop no runner holds; its row then given an
      # origin no writer stores. Continuing it from its row needs an origin
      # the vocabulary holds.
      {:ok, %{turn: turn}} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "@aqua keep it"},
          turn: %{agent: "aqua", requested_by: ctx.user_id}
        })

      assert {:paused, :approval} =
               Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

      turn_id = turn.id
      damage_origin!(turn_id)
      {:ok, _pid} = Runner.ensure(thread.id, ctx.athanor_id)
      assert %{paused: true} = Runner.state(thread.id, ctx.athanor_id)
      {:ok, paused} = Tape.turn(ctx, turn_id)
      assert paused.origin == @unknown_origin
      {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
      calls = ScriptedWorker.calls()

      # The pin check reads the turn's grant under the origin its row
      # stores, never the approver's: with none it names, the card cannot hold.
      assert {:error, :turn_superseded} =
               Approvals.resolve(ctx, approval.id, %{decision: :approved})

      # The card settles refused and the turn ends: failed by the refusal, or
      # cancelled by the runner that met the damaged origin first.
      assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
      assert {:ok, %{status: status}} = Tape.turn(ctx, turn_id)
      assert status in ["failed", "cancelled"]

      # Nothing ran past the card.
      {:ok, steps} = Tape.steps(ctx, paused)
      refute Enum.any?(steps, &(&1.action == "keep" and &1.outcome == "ok"))
      assert ScriptedWorker.calls() == calls
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

    for loss <- [:lost, :expired], event <- [:approval, :resume, :expire] do
      @tag :ownership_loss
      test "a resolved approval cannot resume on #{event} when ownership is #{loss}",
           %{ctx: ctx, thread: thread} do
        script!([
          call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}),
          reply("kept it"),
          reply("second")
        ])

        {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua keep it")
        runner = Runner.whereis(thread.id)

        wait_until(fn -> match?(%{paused: %{}}, :sys.get_state(runner)) end, 60_000)
        {:ok, turn} = Tape.turn(ctx, first)
        {:ok, [approval]} = Tape.pending_approvals(ctx, turn)

        {:ok, %{turn_id: second}} =
          Runner.send_message(api_line(ctx), thread.id, "@aqua me too")

        # Resolve with delivery held back: the timer also has to recover a
        # committed decision whose PubSub notification never arrived.
        %{paused: %{expiry: expiry}, idle_ref: idle} =
          :sys.replace_state(runner, fn state ->
            actor = Prima.Actor.in_athanor(ctx.athanor_id)
            :ok = Cyfr.Bus.unsubscribe(actor, Cyfr.Bus.thread(actor, thread.id))
            state
          end)

        assert {:ok, %{decision: "approved", replayed: false}} =
                 Approvals.resolve(ctx, approval.id, %{decision: :approved})

        before = tape_snapshot(ctx, thread.id, [first, second], [approval.id])
        calls = ScriptedWorker.calls()
        runner_ref = Process.monitor(runner)
        lose_ownership(unquote(loss))

        message =
          case unquote(event) do
            :approval ->
              %ThreadEvent{
                athanor_id: ctx.athanor_id,
                thread_id: thread.id,
                kind: :approval_resolved,
                data: %{turn_id: first}
              }

            :resume ->
              {:resume, first}

            :expire ->
              {:expire, first}
          end

        send(runner, message)
        await_retired(runner, runner_ref)
        assert Process.read_timer(expiry) == false
        assert Process.read_timer(idle) == false
        assert tape_snapshot(ctx, thread.id, [first, second], [approval.id]) == before
        assert ScriptedWorker.calls() == calls

        Arca.ControlPlane.record(:unclaimed)
        assert {:ok, _successor} = Runner.ensure(thread.id, ctx.athanor_id)

        wait_until(
          fn -> match?({:ok, %{status: "completed"}}, Tape.turn(ctx, second)) end,
          60_000
        )

        assert {:ok, %{status: "completed"} = resumed} = Tape.turn(ctx, first)
        {:ok, steps} = Tape.steps(ctx, resumed)
        assert [%{outcome: "ok"}] = Enum.filter(steps, &(&1.action == "keep"))

        assert {:ok, %{decision: "approved", replayed: true}} =
                 Approvals.resolve(ctx, approval.id, %{decision: :approved})
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
      tag = make_ref()
      send(runner, {:"$gen_call", {self(), tag}, {:stop, ctx}})
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 5_000
      :ok = :sys.resume(runner)
      assert_receive {^tag, :ok}, 5_000
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

    send(runner, %ThreadEvent{
      athanor_id: ctx.athanor_id,
      thread_id: thread.id,
      kind: :approval_resolved,
      data: %{turn_id: turn.id}
    })

    send(call, :continue)
    assert :ok = Runner.stop_turn(ctx, thread.id)
    assert Tape.turn(ctx, turn.id) == {:ok, cancelled}
    assert ScriptedWorker.calls() == calls
  end

  for loss <- [:lost, :expired],
      operation <- [:send, :stop, :revoke_grant, :restart_for_consent] do
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
          :revoke_grant -> {:revoke_grant, ctx, "aqua", "notes", "keep", nil}
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
      script!([reply("put"), {:probe, self()}, reply("done")])
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

    test "a running turn does not end while a page's step in it is open: its card pauses " <>
           "the turn, and the yes runs the call once with no model asked again",
         %{ctx: ctx, workspace: ws} do
      script!([reply("put"), {:probe, self()}, reply("done")])
      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua wait here")
      assert_receive {:scripted_probe, model, _}, 60_000
      call = page_call(ctx, put, "notes.keep", %{"name" => "from-page", "content" => "x"})
      assert {:ok, _runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      {:ok, turn} = Tape.turn(ctx, id)
      wait_until(fn -> match?({:ok, [_]}, Tape.pending_approvals(ctx, turn)) end, 30_000)

      # The model's answer calls nothing, and the turn waits on the page's card.
      send(model, :continue)

      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^id, reason: :approval}},
                     60_000

      assert {:ok, %{status: "paused", paused_reason: "approval"}} = Tape.turn(ctx, id)

      assert [model_step(ctx, id, 1, "text"), page_step(2, id, call, nil, "proposed", "pending")] ==
               steps!(ctx, id)

      {:ok, [approval]} = Tape.pending_approvals(ctx, turn)
      {:ok, %{decision: "approved"}} = Approvals.resolve(ctx, approval.id, %{decision: :approved})
      await_ended!(ctx, id)

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, id)

      assert [model_step(ctx, id, 1, "text"), page_step(2, id, call, "ok", "closed", "approved")] ==
               steps!(ctx, id)

      [carried, answered] = page_rows!(ctx, ws.id)
      assert carried == called(id, call)
      assert answered == answered(ctx, id, call, 200, answered.content)
      assert {:ok, %{content: "x"}} = Aqua.Notes.read(ctx, "from-page")
      assert chats() == 2
    end

    test "a call while the turn waits on a card writes no row and no step, and becomes a " <>
           "step of that turn when it runs again after the decision",
         %{ctx: ctx, workspace: ws} do
      script!([
        reply("put"),
        call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}),
        {:probe, self()},
        reply("kept")
      ])

      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua keep it")
      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^id}}, 60_000
      runner = Runner.whereis(ws.id)
      before = tape_snapshot(ctx, ws.id, [put.id, id])

      call = page_call(ctx, put, "component.list")
      assert {:ok, ^runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      _ = :sys.get_state(runner)
      assert tape_snapshot(ctx, ws.id, [put.id, id]) == before

      {:ok, turn} = Tape.turn(ctx, id)
      {:ok, [approval]} = Tape.pending_approvals(ctx, turn)
      {:ok, %{decision: "approved"}} = Approvals.resolve(ctx, approval.id, %{decision: :approved})

      # The turn runs again and its model answers: the call is a step of it
      # by then, whether it ran before the model's round or beside it.
      assert_receive {:scripted_probe, model, _}, 60_000
      wait_until(fn -> Enum.any?(steps!(ctx, id), &(&1.purpose == "page")) end, 30_000)
      send(model, :continue)
      await_ended!(ctx, id)

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, id)
      [first, keep | rest] = steps!(ctx, id)
      assert first == model_step(ctx, id, 1, nil)
      assert %{tool: "notes", action: "keep", outcome: "ok", card: "approved"} = keep
      [page_seq] = for %{purpose: "page", seq: seq} <- rest, do: seq
      [model_seq] = for %{kind: "model", seq: seq} <- rest, do: seq
      assert Enum.sort([page_seq, model_seq]) == [3, 4]
      assert page_step(page_seq, id, call, "ok") in rest
      assert model_step(ctx, id, model_seq, "text") in rest

      {:ok, decided} = Tape.approval(ctx, approval.id)
      [page] = for %{purpose: "page"} = step <- raw_steps!(ctx, id), do: step
      assert DateTime.compare(page.started_at, decided.decided_at) != :lt
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
         script: [reply("put"), {:probe, self()}, %{"status" => 200, "body" => "x"}]}
      )

      # The page was put by the person's turn over the API.
      put = put!(api_line(ctx), ws)
      assert %{origin: "programmatic", requested_by: person, agent: "aqua"} = put
      assert person == ctx.user_id
      call = page_call(ctx, put, "http.get", %{"url" => "https://example.test/x"})
      assert {:ok, runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      assert runner == Runner.whereis(ws.id)
      assert_receive {:scripted_probe, http, _}, 60_000

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

      # It started with the sources of the turn that put the page, and the
      # page's own.
      {:ok, put} = Tape.turn(ctx, call.put_turn_id)
      held = Jason.decode!(ended.sources)
      assert [_ | _] = Jason.decode!(put.sources)
      assert Jason.decode!(put.sources) -- held == []
      assert %{"class" => "outside", "name" => "browser"} in held
      [carried, answered] = page_rows!(ctx, ws.id)
      assert carried == called(id, call)
      assert answered == answered(ctx, id, call, 200, answered.content)

      # The page is answered the fetch's data, as the endpoint answers it.
      assert Jason.decode!(answered.content) ==
               Prima.TinctureWire.result(%{"body" => "x", "status" => 200})

      assert {:ok, %{turn_id: nil}} = Tape.claim_holder(ctx, ws.id)
      # The put's model run is the only one.
      assert chats() == 1
    end

    test "a second turn never runs beside one: a person's message sent while that work " <>
           "waits on a card is queued behind it",
         %{ctx: ctx, workspace: ws} do
      script!([reply("put"), reply("hi")])
      put = put!(ctx, ws)
      call = page_call(ctx, put, "notes.keep", %{"name" => "from-page", "content" => "x"})
      assert {:ok, runner} = Runner.page_call(ws.id, ctx.athanor_id, call)

      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: work, reason: :approval}},
                     60_000

      assert {:ok, %{admitted: :turn, turn_id: line}} =
               Runner.send_message(ctx, ws.id, "@aqua hi")

      assert ^runner = Runner.whereis(ws.id)

      assert %{running: false, paused: true, turn_id: ^work, queued: 1} =
               Runner.state(ws.id, ctx.athanor_id)

      assert {:ok, %{status: "accepted"}} = Tape.turn(ctx, line)
      assert [] = steps!(ctx, line)

      {:ok, paused} = Tape.turn(ctx, work)
      {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
      {:ok, %{decision: "approved"}} = Approvals.resolve(ctx, approval.id, %{decision: :approved})
      await_ended!(ctx, line)

      assert {:ok, %{status: "completed"} = done} = Tape.turn(ctx, work)
      assert {:ok, %{status: "completed"} = answered} = Tape.turn(ctx, line)
      assert DateTime.compare(answered.accepted_at, done.ended_at) == :lt
      [%{started_at: started}] = raw_steps!(ctx, line)
      assert DateTime.compare(started, done.ended_at) != :lt

      assert [page_step(1, work, call, "ok", "closed", "approved")] == steps!(ctx, work)

      assert [model_step(ctx, line, 1, "text")] == steps!(ctx, line)
      assert {:ok, %{content: "x"}} = Aqua.Notes.read(ctx, "from-page")
      assert chats() == 2
    end

    test "a full queue of waiting calls refuses the next one :busy, and it never becomes a step",
         %{ctx: ctx, workspace: ws} do
      script!([
        reply("put"),
        call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}),
        reply("kept")
      ])

      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua keep it")
      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^id}}, 60_000
      before = tape_snapshot(ctx, ws.id, [put.id, id])

      waiting = for _ <- 1..8, do: page_call(ctx, put, "component.list")
      for call <- waiting, do: assert({:ok, _} = Runner.page_call(ws.id, ctx.athanor_id, call))
      refused = page_call(ctx, put, "component.list")
      assert {:error, :busy} = Runner.page_call(ws.id, ctx.athanor_id, refused)
      assert tape_snapshot(ctx, ws.id, [put.id, id]) == before

      {:ok, turn} = Tape.turn(ctx, id)
      {:ok, [approval]} = Tape.pending_approvals(ctx, turn)
      {:ok, %{decision: "approved"}} = Approvals.resolve(ctx, approval.id, %{decision: :approved})
      await_ended!(ctx, id)

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, id)

      # The eight ran in the turn that runs again, each once, beside its
      # model's answer or before it.
      {pages, [first, keep, last]} = Enum.split_with(steps!(ctx, id), &(&1.purpose == "page"))
      assert first == model_step(ctx, id, 1, nil)
      assert %{seq: 2, tool: "notes", action: "keep", outcome: "ok", card: "approved"} = keep
      assert last == model_step(ctx, id, last.seq, "text")
      by_key = Map.new(pages, &{&1.idempotency_key, &1})
      assert map_size(by_key) == 8

      for call <- waiting do
        step = Map.fetch!(by_key, "page_call:#{id}:#{call.request}")
        assert step == page_step(step.seq, id, call, "ok")
      end

      rows = Threads.messages(Sanctum.Context.actor(ctx), ws.id)
      refute Enum.any?(rows, &(&1.client_id == refused.request))
      refute Enum.any?(rows, &(Tape.payload(&1)["tool_call_id"] == refused.request))
    end

    test "deleting the thread stops the work: the turn is cancelled, its card withdrawn, the " <>
           "waiting call dropped and the runner gone",
         %{ctx: ctx, workspace: ws} do
      script!([reply("put")])
      put = put!(ctx, ws)
      keep = page_call(ctx, put, "notes.keep", %{"name" => "from-page", "content" => "x"})
      assert {:ok, runner} = Runner.page_call(ws.id, ctx.athanor_id, keep)
      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: work}}, 60_000
      waiting = page_call(ctx, put, "component.list")
      assert {:ok, ^runner} = Runner.page_call(ws.id, ctx.athanor_id, waiting)
      {:ok, paused} = Tape.turn(ctx, work)
      {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
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
      assert {:error, _gone} = Approvals.resolve(ctx, approval.id, %{decision: :approved})
      assert {:error, _} = Aqua.Notes.read(ctx, "from-page")
      assert chats() == 1
    end

    test "a turn that lost its fence writes no step for a page's call", %{
      ctx: ctx,
      workspace: ws
    } do
      script!([reply("put"), {:probe, self()}, reply("never read")])
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

    test "a stop drops the calls waiting behind the turn: none becomes a step of the next one",
         %{ctx: ctx, workspace: ws} do
      script!([
        reply("put"),
        call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}),
        reply("again")
      ])

      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua keep it")
      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^id}}, 60_000
      call = page_call(ctx, put, "component.list")
      assert {:ok, _runner} = Runner.page_call(ws.id, ctx.athanor_id, call)

      assert :ok = Runner.stop_turn(ctx, ws.id)
      assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, id)

      {:ok, %{turn_id: next}} = Runner.send_message(ctx, ws.id, "@aqua again")
      await_ended!(ctx, next)

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, next)
      assert [model_step(ctx, next, 1, "text")] == steps!(ctx, next)
      assert [] = page_rows!(ctx, ws.id)
    end

    test "a call that comes as the running turn ends opens work of its own, which still " <>
           "holds it: its request ending withdraws its card",
         %{ctx: ctx, workspace: ws} do
      script!([reply("put"), {:probe, self()}, reply("never recorded")])
      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua look around")
      assert_receive {:scripted_probe, model, _}, 60_000

      # The turn's row ends before its loop's end reaches the runner.
      {:ok, running} = Tape.turn(ctx, id)
      {:ok, _} = Tape.finish(ctx, running, "cancelled", %{error: "stopped"})
      call = page_call(ctx, put, "notes.keep", %{"name" => "from-page", "content" => "x"})
      assert {:ok, _runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      send(model, :continue)

      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: work}}, 60_000
      refute work == id
      assert [page_step(1, work, call, nil, "proposed", "pending")] == steps!(ctx, work)
      {:ok, paused} = Tape.turn(ctx, work)
      {:ok, [approval]} = Tape.pending_approvals(ctx, paused)

      assert :ok = Runner.page_call_ended(ws.id, ctx.athanor_id, call.request)
      assert {:ok, %{status: "invalidated"}} = Tape.approval(ctx, approval.id)
      await_ended!(ctx, work)
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, work)
      assert [page_step(1, work, call, "skipped", "closed", "invalidated")] == steps!(ctx, work)
      assert {:error, _} = Aqua.Notes.read(ctx, "from-page")
    end

    test "a request that ended while its call waits drops the call: it never becomes a step",
         %{ctx: ctx, workspace: ws} do
      script!([
        reply("put"),
        call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"}),
        reply("kept")
      ])

      put = put!(ctx, ws)
      {:ok, %{turn_id: id}} = Runner.send_message(ctx, ws.id, "@aqua keep it")
      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: ^id}}, 60_000
      runner = Runner.whereis(ws.id)
      call = page_call(ctx, put, "component.list")
      assert {:ok, ^runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      assert :ok = Runner.page_call_ended(ws.id, ctx.athanor_id, call.request)

      {:ok, turn} = Tape.turn(ctx, id)
      {:ok, [approval]} = Tape.pending_approvals(ctx, turn)
      {:ok, %{decision: "approved"}} = Approvals.resolve(ctx, approval.id, %{decision: :approved})
      await_ended!(ctx, id)

      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, id)

      [first, keep, last] = steps!(ctx, id)
      assert first == model_step(ctx, id, 1, nil)
      assert %{seq: 2, tool: "notes", action: "keep", outcome: "ok", card: "approved"} = keep
      assert last == model_step(ctx, id, 3, "text")
      assert [] = page_rows!(ctx, ws.id)
      assert %{running: false, paused: false, queued: 0} = Runner.state(ws.id, ctx.athanor_id)
    end

    test "a request that ended while its step is proposed skips the step, withdraws its " <>
           "card, and a late yes runs nothing",
         %{ctx: ctx, workspace: ws} do
      script!([reply("put")])
      put = put!(ctx, ws)
      call = page_call(ctx, put, "notes.keep", %{"name" => "from-page", "content" => "x"})
      assert {:ok, _runner} = Runner.page_call(ws.id, ctx.athanor_id, call)
      assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: work}}, 60_000
      {:ok, paused} = Tape.turn(ctx, work)
      {:ok, [approval]} = Tape.pending_approvals(ctx, paused)

      assert :ok = Runner.page_call_ended(ws.id, ctx.athanor_id, call.request)
      assert {:ok, %{status: "invalidated"}} = Tape.approval(ctx, approval.id)

      # Its last step closed: the work ends.
      await_ended!(ctx, work)
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, work)

      assert [page_step(1, work, call, "skipped", "closed", "invalidated")] == steps!(ctx, work)

      assert {:ok, %{decision: "invalidated", replayed: true}} =
               Approvals.resolve(ctx, approval.id, %{decision: :approved})

      [carried, answered] = page_rows!(ctx, ws.id)
      assert carried == called(work, call)
      assert %{kind: "page_result", content: "the page's request ended"} = answered
      assert {:error, _} = Aqua.Notes.read(ctx, "from-page")
      assert chats() == 1
    end
  end

  # A workspace thread of the person's, as a workspace's opening makes one.
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

  # A call the page makes, as `Aqua.PageCalls` hands it to the runner.
  defp page_call(ctx, put, name, arguments \\ %{}),
    do: %{
      request: Prima.UUID7.generate_id("pgc"),
      name: name,
      arguments: arguments,
      user_id: ctx.user_id,
      put_turn_id: put.id
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
  # them, with the rows a step carries its call and its answer in, by kind,
  # and its card's state.
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
        answered: kind_of(ctx, step.result_message_id),
        card: card_of(ctx, step.approval_id)
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

  defp card_of(_ctx, nil), do: nil

  defp card_of(ctx, id) do
    {:ok, approval} = Tape.approval(ctx, id)
    approval.status
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
      answered: answered,
      card: nil
    }
  end

  # A page's step in `turn_id` for `call`; of the calls here only
  # `component.list` is replay-safe.
  defp page_step(seq, turn_id, call, outcome, state \\ "closed", card \\ nil) do
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
      answered: if(state == "closed", do: "page_result"),
      card: card
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
end
