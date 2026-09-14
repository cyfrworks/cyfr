# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RunnerTest do
  @moduledoc """
  The runner owns a thread's turns: a send is admitted in order
  and accepted with the turn it opens or refused with nothing written;
  one turn runs at a time, the sender's own line steers it and another
  member's waits; a stop cuts the turn and drops the queue; a card pauses
  the turn and its decision continues it; a runner that starts finds the
  open turns and does what their rows say.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Aqua.{Approvals, Runner, Tape}
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedExecution
  alias Sanctum.Consent.{Bootstrap, Source}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @moduletag :requires_opus_modules

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "runner_#{System.unique_integer([:positive])}")
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

    # The runners run under the paths restored above.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local())
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: ctx.athanor_id)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    {:ok, thread} = Threads.create(ctx)
    :ok = Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, user: user, thread: thread}
  end

  defp script!(items), do: start_supervised!({ScriptedExecution, ref: @model, script: items})

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

  defp bind_claude!(ctx) do
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: "claude key",
        kind: "api_key",
        fields: %{"ANTHROPIC_API_KEY" => "sk-test"}
      })

    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: @model, label: "default"})

    decisions = %{
      ref: @model,
      label: "default",
      bindings: [%{need: "api_key", entry_id: entry.id}]
    }

    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    entry
  end

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
    script!([{:probe, self()}, reply("first"), reply("second")])

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

    # The steer rode the first turn.
    rows = Threads.messages(ctx, thread.id)
    assert %{turn_id: ^first} = Enum.find(rows, &(&1.content == "@aqua also this"))
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
      match?(
        %{running: true, turn_id: ^turn_id, partials: [%{text: "Hello", role: nil}]},
        Runner.state(thread.id, ctx.athanor_id)
      )
    end)

    send(worker, :continue)
    assert_receive {:thread, _, {:turn_finished}}, 60_000
    assert %{partials: []} = Runner.state(thread.id, ctx.athanor_id)
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
    ScriptedExecution.script([reply("never minded")])

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
      {ScriptedExecution,
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
      {ScriptedExecution,
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
      {ScriptedExecution,
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
    entry = bind_claude!(ctx)
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
             Enum.find(ScriptedExecution.calls(), &(&1.input["operation"] == "chat"))

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
    assert Opus.ExecutionSemaphore.status().root_active == 0
  end

  test "a card pauses the turn, and the decision continues it", %{ctx: ctx, thread: thread} do
    script!([call("c1", "notes", %{"action" => "keep", "name" => "n", "content" => "x"})])

    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua keep it")
    wait_until(fn -> match?({:ok, %{status: "paused"}}, Tape.turn(ctx, turn_id)) end, 60_000)
    assert %{running: false, paused: true} = Runner.state(thread.id, ctx.athanor_id)

    {:ok, paused} = Tape.turn(ctx, turn_id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, paused)
    ScriptedExecution.script([reply("kept it")])

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
end
