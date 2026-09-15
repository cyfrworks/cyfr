# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RunnerTest do
  @moduledoc """
  The runner owns a thread's turns: a send is admitted in order
  and accepted with the turn it opens or refused with nothing written;
  one turn runs at a time, the sender's own line steers it and another
  member's waits; a stop cuts the turn and drops the queue; a card pauses
  the turn and its decision continues it; a runner that starts finds the
  open turns and does what their rows say. A runner's loop dies with it;
  a runner starts and handles loop events only on a boot that owns the
  control plane, and never takes a turn another process on this boot holds.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Aqua.{Approvals, Runner, Tape}
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.{Bootstrap, Source}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "runner_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source, :workers]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :seed_path, @seed_root)
    Application.put_env(:cyfr, :consent_source, Source.DB)
    Application.put_env(:cyfr, :workers, [ScriptedWorker])

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    # The runners run under the paths restored above.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local())
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: ctx.athanor_id)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    # The model catalyst unseals its key when its runner attaches.
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Threads.create(ctx)
    :ok = Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, user: user, thread: thread}
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

  defp second_member(ctx) do
    n = System.unique_integer([:positive])

    {:ok, other} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|other#{n}",
        provider: "github",
        email: "other#{n}@example.com",
        verified: true,
        name: "Other"
      })

    {:ok, _} = Members.ensure(other.id, scope: "athanor", athanor_id: ctx.athanor_id)
    %{ctx | user_id: other.id}
  end

  # The runner, its loop, and the loop's call that is waiting on the test.
  defp running!(thread) do
    assert_receive {:scripted_probe, call, _}, 60_000
    runner = Runner.whereis(thread.id)
    %{live: %{task: %Task{pid: loop}}} = :sys.get_state(runner)
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
        :expired -> {:held, DateTime.add(DateTime.utc_now(), -1, :second)}
      end

    Cyfr.ControlPlane.mark(ownership)
    on_exit(fn -> Cyfr.ControlPlane.mark(:unclaimed) end)
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
      messages: Threads.messages(ctx, thread_id),
      turns: turns,
      approvals: Enum.map(approval_ids, &Tape.approval(ctx, &1))
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

    # An estate not yet filled refuses an addressed send before any row.
    {:ok, fresh} =
      Athanors.create_group(ctx.user_id, "Fresh #{System.unique_integer([:positive])}")

    {:ok, _} = Members.ensure(ctx.user_id, scope: "athanor", athanor_id: fresh.id)
    {:ok, fresh_ctx} = Sanctum.Context.focus(ctx, fresh.id)
    {:ok, fresh_thread} = Threads.create(fresh_ctx)
    # The roster is handed in: reading it would itself start the fill.
    assert {:error, :not_provisioned} =
             Runner.send_message(fresh_ctx, fresh_thread.id, "@aqua hi",
               orchestrators: [%{"name" => "aqua", "title" => "AQUA"}]
             )

    assert [] = Threads.messages(fresh_ctx, fresh_thread.id)

    assert [] = Threads.messages(ctx, thread.id)
  end

  test "people talking is a row and no turn; an addressed line starts one and completes", %{
    ctx: ctx,
    thread: thread
  } do
    other = second_member(ctx)
    script!([reply("hello back")])

    assert {:ok, %{accepted: true, turn_id: nil, admitted: :post}} =
             Runner.send_message(other, thread.id, "morning everyone")

    assert {:ok, %{accepted: true, turn_id: turn_id, admitted: :turn, replayed: false} = sent} =
             Runner.send_message(ctx, thread.id, "@aqua say hello", client_id: "c-1")

    assert_receive {:thread, _, {:turn_starting, user}}, 5_000
    assert user == ctx.user_id
    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn_id)
    assert_receive {:thread, _, {:message, %{kind: "text", content: "hello back"}}}, 5_000

    # The same client id answers the same identity, and writes nothing new.
    assert {:ok, %{message_id: mid, turn_id: ^turn_id, replayed: true}} =
             Runner.send_message(ctx, thread.id, "@aqua say hello", client_id: "c-1")

    assert mid == sent.message_id
    assert %{running: false, queued: 0} = Runner.state(thread.id, ctx.athanor_id)
  end

  test "the sender's own line steers the running turn; another member's waits behind it", %{
    ctx: ctx,
    thread: thread
  } do
    other = second_member(ctx)
    script!([{:probe, self()}, reply("first"), reply("steered"), reply("second")])

    {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
    assert_receive {:scripted_probe, worker, _}, 30_000

    assert {:ok, %{admitted: :steer, turn_id: ^first}} =
             Runner.send_message(ctx, thread.id, "@aqua also this")

    assert {:ok, %{admitted: :turn, turn_id: second}} =
             Runner.send_message(other, thread.id, "@aqua me too")

    assert second != first
    assert %{running: true, queued: 1} = Runner.state(thread.id, ctx.athanor_id)
    assert_receive {:thread, _, {:queued, 1}}, 5_000

    send(worker, :continue)
    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert_receive {:thread, _, {:turn_finished}}, 60_000

    wait_until(fn ->
      match?(%{running: false, queued: 0}, Runner.state(thread.id, ctx.athanor_id))
    end)

    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, first)
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, second)

    # The steer rode the first turn, which answered it before completing.
    rows = Threads.messages(ctx, thread.id)
    assert %{turn_id: ^first} = Enum.find(rows, &(&1.content == "@aqua also this"))
    assert %{turn_id: ^first} = Enum.find(rows, &(&1.content == "steered"))
    assert %{turn_id: ^second} = Enum.find(rows, &(&1.content == "second"))
  end

  test "the sender's line to another agent waits behind the running turn", %{
    ctx: ctx,
    thread: thread
  } do
    script!([{:probe, self()}, reply("first"), reply("second")])

    {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
    assert_receive {:scripted_probe, worker, _}, 30_000

    assert {:ok, %{admitted: :turn, turn_id: second}} =
             Runner.send_message(ctx, thread.id, "also this", orchestrator: "planner")

    assert second != first
    assert %{running: true, queued: 1} = Runner.state(thread.id, ctx.athanor_id)

    send(worker, :continue)
    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert_receive {:thread, _, {:turn_finished}}, 60_000

    assert {:ok, %{status: "completed", orchestrator: "aqua"}} = Tape.turn(ctx, first)
    assert {:ok, %{status: "completed", orchestrator: "planner"}} = Tape.turn(ctx, second)
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

    Aqua.Tape.announce(
      ctx,
      thread.id,
      {:delta,
       %{
         turn_id: turn_id,
         fence: fence - 1,
         source: turn_id,
         step_id: step_id,
         ordinal: 9,
         seq: {9, 9},
         text: " stale",
         role: nil
       }}
    )

    %{partials: partials} = Runner.state(thread.id, ctx.athanor_id)
    assert [%{text: "Hello"}] = Aqua.Loop.Stream.texts(partials)

    send(worker, :continue)
    assert_receive {:thread, _, {:turn_finished}}, 60_000
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
    assert_receive {:thread, _, {:turn_finished}}, 60_000

    assert [_] =
             Enum.filter(Threads.messages(ctx, thread.id), &(&1.content == "@aqua also this"))
  end

  test "the sender's line while the turn is paused on a card steers it, drained on resume", %{
    ctx: ctx,
    thread: thread
  } do
    script!([call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})])

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua keep it")
    wait_until(fn -> match?({:ok, %{status: "paused"}}, Tape.turn(ctx, turn_id)) end, 60_000)

    assert {:ok, %{admitted: :steer, turn_id: ^turn_id}} =
             Runner.send_message(ctx, thread.id, "@aqua never mind")

    assert %{running: false, paused: true, queued: 0} = Runner.state(thread.id, ctx.athanor_id)

    {:ok, paused} = Tape.turn(ctx, turn_id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    ScriptedWorker.script([reply("never minded")])

    assert {:ok, %{decision: "approved"}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn_id)

    # The steer rode the paused turn and displaced the card's step.
    {:ok, steps} = Tape.steps(ctx, paused)
    assert %{action: "keep", outcome: "skipped"} = Enum.find(steps, &(&1.action == "keep"))

    assert %{turn_id: ^turn_id} =
             Enum.find(Threads.messages(ctx, thread.id), &(&1.content == "@aqua never mind"))
  end

  test "a runner that starts over a paused row knows it before the first send", %{
    ctx: ctx,
    thread: thread
  } do
    script!([call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})])

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua keep it"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    assert {:paused, :approval} =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

    assert nil == Runner.whereis(thread.id)
    other = second_member(ctx)

    assert {:ok, %{admitted: :turn, turn_id: second}} =
             Runner.send_message(other, thread.id, "@aqua me too")

    assert second != turn.id
    assert %{running: false, paused: true, queued: 1} = Runner.state(thread.id, ctx.athanor_id)
  end

  test "a call whose outcome is unknown stops the turn; the sender's next line continues it, others wait",
       %{ctx: ctx, thread: thread} do
    other = second_member(ctx)

    start_supervised!(
      {ScriptedWorker,
       ref: [@model, "catalyst:local.http"],
       script: [
         call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
         {:crash, :before_response},
         reply("carrying on"),
         reply("me too, done")
       ]}
    )

    {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
    assert_receive {:thread, _, {:turn_paused, ^first, :uncertain}}, 60_000

    assert %{running: false, paused: true, paused_reason: :uncertain} =
             Runner.state(thread.id, ctx.athanor_id)

    assert {:ok, %{status: "paused", paused_reason: "uncertain"}} = Tape.turn(ctx, first)

    assert {:ok, %{admitted: :turn, turn_id: second}} =
             Runner.send_message(other, thread.id, "@aqua me too")

    assert %{paused: true, queued: 1} = Runner.state(thread.id, ctx.athanor_id)

    assert {:ok, %{admitted: :steer, turn_id: ^first}} =
             Runner.send_message(ctx, thread.id, "@aqua go on")

    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, first)
    assert {:ok, %{status: "completed", requested_by: requested}} = Tape.turn(ctx, second)
    assert requested == other.user_id
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
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    assert {:paused, :uncertain} =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

    # A runner over the row: it waits.
    assert %{paused: true, paused_reason: :uncertain, running: false} =
             Runner.state(thread.id, ctx.athanor_id)

    # The acknowledging line, and the turn goes on to its end.
    assert {:ok, %{admitted: :steer}} = Runner.send_message(ctx, thread.id, "@aqua go on")
    assert_receive {:thread, _, {:turn_finished}}, 60_000
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
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    assert {:paused, :uncertain} =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "go on"},
        steer_turn_id: turn.id
      })

    {:ok, _pid} = Runner.ensure(thread.id, ctx.athanor_id)
    assert_receive {:thread, _, {:turn_finished}}, 60_000
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
    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert [_] = Enum.filter(Threads.messages(ctx, thread.id), &(&1.author == ctx.user_id))
  end

  test "a turn that cannot start once its root is claimed ends failed, root and all", %{
    ctx: ctx,
    thread: thread
  } do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    # Ended between acceptance and its run: the root is claimed, the start
    # refuses a turn that is no longer accepted.
    {:ok, _} = Tape.finish(ctx, turn, "cancelled")

    assert {:failed, :not_accepted} = Aqua.Loop.run(ctx: ctx, turn_id: turn.id)
    assert {:ok, %{status: "cancelled", root_execution_id: nil}} = Tape.turn(ctx, turn.id)

    # The root the claim admitted is closed, not left running under a
    # released slot.
    assert %{status: "failed", kind: "turn"} = Arca.Repo.get_by(Arca.Execution, turn_id: turn.id)
  end

  test "a turn addressed to a source with no consent claims no root and asks for setup", %{
    ctx: ctx,
    thread: thread
  } do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@ghost go"},
        turn: %{orchestrator: "ghost", requested_by: ctx.user_id}
      })

    assert {:failed, :setup_required} = Aqua.Loop.run(ctx: ctx, turn_id: turn.id)

    assert {:ok, %{status: "failed", root_execution_id: nil, profile_id: nil}} =
             Tape.turn(ctx, turn.id)

    assert nil == Arca.Repo.get_by(Arca.Execution, turn_id: turn.id)
    user = ctx.user_id
    assert_receive {:thread, _, {:consent_required, "agent:local.ghost", ^user}}, 5_000
  end

  test "a role addressed directly runs as its own source, with its own consent and key", %{
    ctx: ctx,
    thread: thread
  } do
    entry =
      Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})

    script!([reply("Step one.")])

    {:ok, %{admitted: :turn, turn_id: turn_id}} =
      Runner.send_message(ctx, thread.id, "@planner plan")

    assert_receive {:thread, _, {:turn_finished}}, 60_000

    {:ok, [planner_profile]} = Source.DB.profiles(ctx, "agent:local.planner")
    {:ok, turn} = Tape.turn(ctx, turn_id)
    assert turn.status == "completed" and turn.orchestrator == "planner"
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
    other = second_member(ctx)
    script!([{:probe, self()}])

    {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
    assert_receive {:scripted_probe, _worker, _}, 30_000
    {:ok, %{turn_id: second}} = Runner.send_message(other, thread.id, "@aqua me too")

    assert :ok = Runner.stop_turn(ctx, thread.id)
    assert_receive {:thread, _, {:turn_finished}}, 10_000
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, first)
    assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, second)
    assert %{running: false, queued: 0} = Runner.state(thread.id, ctx.athanor_id)
    assert Cyfr.Execution.Semaphore.status().root_active == 0
  end

  test "a card pauses the turn, and the decision continues it", %{ctx: ctx, thread: thread} do
    script!([call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})])

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua keep it")
    wait_until(fn -> match?({:ok, %{status: "paused"}}, Tape.turn(ctx, turn_id)) end, 60_000)
    assert %{running: false, paused: true} = Runner.state(thread.id, ctx.athanor_id)

    {:ok, paused} = Tape.turn(ctx, turn_id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    ScriptedWorker.script([reply("kept it")])

    assert {:ok, %{decision: "approved"}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn_id)
    {:ok, steps} = Tape.steps(ctx, paused)
    assert %{action: "keep", outcome: "ok"} = Enum.find(steps, &(&1.action == "keep"))
  end

  test "a runner that starts runs the accepted turn it finds and takes over the running one", %{
    ctx: ctx,
    thread: thread
  } do
    script!([reply("picked up"), reply("taken over")])

    # A turn accepted by a runner that is gone.
    {:ok, %{turn: accepted}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua later"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    {:ok, _pid} = Runner.ensure(thread.id, ctx.athanor_id)
    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, accepted.id)

    # A turn left running by a boot that died: its root row and attempt
    # stand, nobody renews them.
    for {_id, pid, _, _} <- DynamicSupervisor.which_children(Aqua.RunnerSupervisor),
        do: DynamicSupervisor.terminate_child(Aqua.RunnerSupervisor, pid)

    {:ok, other_thread} = Threads.create(ctx)
    :ok = Runner.subscribe(other_thread.id, ctx.athanor_id)

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, other_thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua carry on"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    {:ok, claim} =
      Cyfr.Execution.claim_turn_root(ctx, @soul, turn_id: turn.id, thread_id: other_thread.id)

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
        agent_capability_digest: capability
      })

    # The dead boot's slot and keeper are gone; the rows say running.
    :ok = Cyfr.Execution.release_turn_root(ctx, claim.execution_id, claim: claim)
    assert running.status == "running"

    {:ok, _pid} = Runner.ensure(other_thread.id, ctx.athanor_id)
    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert {:ok, %{status: "completed", recovery_attempts: 1} = done} = Tape.turn(ctx, turn.id)
    assert done.attempt != claim.attempt
    rows = Threads.messages(ctx, other_thread.id)
    assert Enum.any?(rows, &(&1.kind == "turn_aborted"))
    assert Enum.any?(rows, &(&1.content == "taken over"))
  end

  describe "a runner that dies" do
    test "mid model call takes its loop and the call with it; its restart takes the turn over",
         %{ctx: ctx, thread: thread} do
      script!([{:probe, self()}, reply("taken over")])

      {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua go")
      pids = running!(thread)
      :ok = kill_and_await!(pids)

      assert_receive {:thread, _, {:turn_finished}}, 60_000
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
                 %{author: ^agent, turn_id: ^turn_id} = row <- Threads.messages(ctx, thread.id),
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

      assert_receive {:thread, _, {:turn_paused, ^turn_id, :uncertain}}, 60_000
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

      Cyfr.ControlPlane.mark(:lost)
      on_exit(fn -> Cyfr.ControlPlane.mark(:unclaimed) end)
      :ok = kill_and_await!(pids)

      assert nil == Runner.whereis(thread.id)
      assert %{active: 0} = DynamicSupervisor.count_children(Aqua.RunnerSupervisor)
      assert {:error, :control_plane_lost} = Runner.ensure(thread.id, ctx.athanor_id)

      # The rows stand as the dead runner left them.
      assert {:ok, %{status: "running", fence: 1, recovery_attempts: 0}} =
               Tape.turn(ctx, turn_id)

      refute Enum.any?(Threads.messages(ctx, thread.id), &(&1.kind == "turn_aborted"))

      Cyfr.ControlPlane.mark(:unclaimed)
      {:ok, _runner} = Runner.ensure(thread.id, ctx.athanor_id)
      assert_receive {:thread, _, {:turn_finished}}, 60_000
      assert {:ok, %{status: "completed", recovery_attempts: 1}} = Tape.turn(ctx, turn_id)
    end
  end

  describe "an existing runner loses control-plane ownership" do
    for loss <- [:lost, :expired], event <- [:result, :down] do
      @tag :ownership_loss
      test "a queued loop #{event} leaves the tape and queued turn unchanged when ownership is #{loss}",
           %{ctx: ctx, thread: thread} do
        other = second_member(ctx)
        script!([{:probe, self()}, reply("first"), reply("second")])
        {:ok, %{turn_id: first}} = Runner.send_message(ctx, thread.id, "@aqua go")
        pids = running!(thread)
        {:ok, %{turn_id: second}} = Runner.send_message(other, thread.id, "@aqua me too")
        %{live: %{task: %Task{ref: task_ref}}} = :sys.get_state(pids.runner)

        :sys.replace_state(pids.runner, fn state ->
          :ok = Runner.unsubscribe(thread.id, ctx.athanor_id)
          state
        end)

        runner_ref = Process.monitor(pids.runner)
        loop_ref = Process.monitor(pids.loop)
        :ok = :sys.suspend(pids.runner)

        if unquote(event) == :result do
          send(pids.call, :continue)
          assert_receive {:DOWN, ^loop_ref, :process, _, :normal}, 60_000
          assert_receive {:thread, _, {:turn_finished}}, 60_000
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

        Cyfr.ControlPlane.mark(:unclaimed)
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
          Runner.send_message(second_member(ctx), thread.id, "@aqua me too")

        # Resolve with delivery held back: the timer also has to recover a
        # committed decision whose PubSub notification never arrived.
        %{paused: %{expiry: expiry}, idle_ref: idle} =
          :sys.replace_state(runner, fn state ->
            :ok = Runner.unsubscribe(thread.id, ctx.athanor_id)
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
            :approval -> {:thread, thread.id, {:approval_resolved, %{turn_id: first}}}
            :resume -> {:resume, first}
            :expire -> {:expire, first}
          end

        send(runner, message)
        await_retired(runner, runner_ref)
        assert Process.read_timer(expiry) == false
        assert Process.read_timer(idle) == false
        assert tape_snapshot(ctx, thread.id, [first, second], [approval.id]) == before
        assert ScriptedWorker.calls() == calls

        Cyfr.ControlPlane.mark(:unclaimed)
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
        send(pids.runner, {:notify, ctx.athanor_id, :athanor_changed, %{}})

        await_retired(pids.runner, runner_ref)
        for ref <- worker_refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 5_000)
        assert tape_snapshot(ctx, thread.id, [turn_id]) == before
        assert ScriptedWorker.calls() == calls

        Cyfr.ControlPlane.mark(:unclaimed)
        {:ok, _successor} = Runner.ensure(thread.id, ctx.athanor_id)
        assert_receive {:thread, _, {:turn_paused, ^turn_id, :uncertain}}, 60_000

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

  test "a turn another process on this boot holds is left to it, and recovered once it is gone while this boot owns the control plane",
       %{ctx: ctx, thread: thread} do
    other = second_member(ctx)
    script!([{:probe, self()}, reply("taken over"), reply("second")])

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
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

    Cyfr.ControlPlane.mark(:unclaimed)
    {:ok, successor} = Runner.ensure(thread.id, ctx.athanor_id)
    refute successor == runner

    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert Runner.whereis(thread.id) == successor
    assert {:ok, %{status: "completed", recovery_attempts: 1}} = Tape.turn(ctx, turn.id)
    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, second)
  end
end
