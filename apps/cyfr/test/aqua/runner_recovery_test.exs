# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RunnerRecoveryTest do
  @moduledoc """
  The boot's recovery of open turns outlasts a database that cannot
  answer: a scan that fails is tried again after a wait, and the runner of
  a thread holding an open turn starts once the store answers. A scan that
  never answers is abandoned with a log line and
  `[:cyfr, :aqua, :recovery, :abandoned]`, recovering nothing, and the
  recovery still ends normally. A workspace thread's turn the recovery
  can neither resume nor start for its sender leaves the thread in error,
  with one report saying why.

  The outage is the real store's: the turns table is renamed inside the
  test's sandbox transaction, so the scan's own query fails as it would
  against a database that cannot answer, and the rename is undone with
  the transaction when the test ends. The waits between scans are the
  production ones, handed to a wait the test supplies so it observes each
  without sleeping through it; the first restores the table.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Aqua.{Runner, Tape}
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @orphaned "the page's request ended with the runner that held it"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "recovery_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    Application.put_env(:arca, :base_path, test_path)
    Cyfr.Test.SeedBundle.lay!(~w(claude files http))

    # The runners run under the paths restored above.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    # The turns are a person's, in their own athanor.
    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    ctx = %{ctx | origin: :interactive, athanor_id: Sanctum.Test.People.athanor!(user).id}
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})

    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    :ok = Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, thread: thread}
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  # An open turn no runner holds: accepted by a runner that is gone.
  defp open_turn!(ctx, thread) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua carry on"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    assert Runner.whereis(thread.id) == nil
    turn
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

  # A call a page in the workspace thread's window makes, as
  # `Aqua.PageCalls` hands it to the runner, `put_turn_id` naming the turn
  # that put the page, its browser this test, which outlives it.
  defp page_call(ctx, put_turn_id, name, arguments),
    do: %{
      request: Prima.UUID7.generate_id("pgc"),
      name: name,
      arguments: arguments,
      user_id: ctx.user_id,
      put_turn_id: put_turn_id,
      browser: self()
    }

  defp ended?(ctx, turn_id), do: match?({:ok, %{ended_at: %DateTime{}}}, Tape.turn(ctx, turn_id))

  # The recovery starts the thread's runner, whose start does what the
  # thread's rows say before it answers a call.
  defp recovered!(ctx, ws) do
    assert Runner.recover_all(wait_reported()) == :ok
    wait_until(fn -> is_pid(Runner.whereis(ws.id)) end, 30_000, "the recovered runner starts")
    assert %{running: false, queued: 0} = Runner.state(ws.id, ctx.athanor_id)
  end

  # The turn's row as a hand edit or a restored row leaves it.
  defp stored!(turn, fields) do
    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id), set: fields)

    :ok
  end

  defp workspace_state(ctx, id),
    do: elem(Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id), 1).workspace_state

  # Every workspace_report the athanor recorded, delivered or not.
  defp reports(ctx) do
    from(r in Arca.Schemas.OutboxRecord,
      where: r.athanor_id == ^ctx.athanor_id and r.kind == "workspace_report",
      select: r.snapshot
    )
    |> Arca.Repo.all()
    |> Enum.map(&Jason.decode!/1)
  end

  defp steps!(ctx, turn_id) do
    {:ok, turn} = Tape.turn(ctx, turn_id)
    {:ok, steps} = Tape.steps(ctx, turn)
    steps
  end

  # The store stops answering the scan: its table is gone until `restore!/0`.
  defp outage!, do: Arca.Repo.query!("ALTER TABLE turns RENAME TO turns_unavailable")
  defp restore!, do: Arca.Repo.query!("ALTER TABLE turns_unavailable RENAME TO turns")

  # A wait that spends no time: it tells the test which wait it was asked
  # for, then does what `then` says, in the recovering process.
  defp wait_reported(then \\ fn -> :ok end) do
    test = self()

    fn ms ->
      send(test, {:waited, ms})
      then.()
    end
  end

  defp watch_abandoned! do
    test = self()
    id = {__MODULE__, :abandoned, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:cyfr, :aqua, :recovery, :abandoned],
        fn _event, measurements, _metadata, _config ->
          send(test, {:abandoned, measurements})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp waits do
    receive do
      {:waited, ms} -> [ms | waits()]
    after
      0 -> []
    end
  end

  test "a first scan the database cannot answer is tried again, and the runner starts once it answers",
       %{ctx: ctx, thread: thread} do
    start_supervised!({ScriptedWorker, ref: @model, script: [reply("recovered")]})
    turn_id = open_turn!(ctx, thread).id

    watch_abandoned!()
    outage!()

    # The store answers again during the first wait.
    log = capture_log(fn -> assert Runner.recover_all(wait_reported(&restore!/0)) == :ok end)

    assert waits() == [1_000]
    assert log =~ "[Arca.TurnStorage.with_open_turns] database error"
    refute log =~ "boot recovery abandoned"
    refute_received {:abandoned, _}

    wait_until(
      fn -> is_pid(Runner.whereis(thread.id)) end,
      30_000,
      "the recovered thread's runner starts"
    )

    wait_until(
      fn ->
        match?({:ok, %{status: s}} when s not in ["accepted", "running"], Tape.turn(ctx, turn_id))
      end,
      45_000,
      "the recovered turn ends"
    )

    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn_id)
    assert is_pid(Runner.whereis(thread.id))
    assert %{active: 1} = DynamicSupervisor.count_children(Aqua.RunnerSupervisor)
    assert Enum.count(ScriptedWorker.calls(), &(&1.input["operation"] == "chat")) == 1
  end

  test "a scan that never answers is retried after 1, 4 and 16 seconds, then abandoned aloud",
       %{ctx: ctx, thread: thread} do
    turn = open_turn!(ctx, thread)

    watch_abandoned!()
    outage!()

    log = capture_log(fn -> assert Runner.recover_all(wait_reported()) == :ok end)

    assert waits() == [1_000, 4_000, 16_000]
    assert_received {:abandoned, %{attempts: 4}}
    assert log =~ "[Aqua.Runner] boot recovery abandoned"
    assert log =~ "in 4 attempts"

    restore!()
    assert Runner.whereis(thread.id) == nil
    assert {:ok, %{status: "accepted"}} = Tape.turn(ctx, turn.id)
  end

  test "an abandoned recovery ends its process normally", %{thread: thread} do
    watch_abandoned!()
    outage!()
    wait = wait_reported()

    capture_log(fn ->
      {:ok, pid} = Task.start(fn -> Runner.recover_all(wait) end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000
    end)

    assert_received {:abandoned, %{attempts: 4}}
    restore!()
    assert Runner.whereis(thread.id) == nil
  end

  test "a boot that does not hold the control plane scans nothing", %{ctx: ctx, thread: thread} do
    turn = open_turn!(ctx, thread)
    watch_abandoned!()

    on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
    Arca.ControlPlane.record(:lost)

    assert Runner.recover_all(wait_reported()) == :ok
    Arca.ControlPlane.record(:unclaimed)

    assert waits() == []
    refute_received {:abandoned, _}
    assert Runner.whereis(thread.id) == nil
    assert {:ok, %{status: "accepted"}} = Tape.turn(ctx, turn.id)
  end

  # A workspace thread's turn the recovery can neither resume nor start
  # for its sender is Aqua that could not run there: the thread reads
  # error, with one report saying why, unless the turn's stored origin
  # reads as none, under which no report could be delivered.
  describe "a workspace thread's turn a runner cannot recover" do
    test "whose stored origin names none", %{ctx: ctx} do
      start_supervised!({ScriptedWorker, ref: @model, script: []})
      ws = workspace!(ctx)
      turn = open_turn!(ctx, ws)
      stored!(turn, origin: "hand-edited")

      recovered!(ctx, ws)

      assert {:ok, %{status: "cancelled", error: error}} = Tape.turn(ctx, turn.id)

      assert error ==
               "the turn's stored origin is outside the vocabulary, nothing to resume under " <>
                 "(no_origin)"

      assert workspace_state(ctx, ws.id) == "error"
      assert reports(ctx) == []
      assert ScriptedWorker.calls() == []
    end

    test "whose sender the athanor is no longer", %{ctx: ctx} do
      start_supervised!({ScriptedWorker, ref: @model, script: []})
      ws = workspace!(ctx)
      turn = open_turn!(ctx, ws)
      # Its sender, as its row names it, is another person.
      local = Sanctum.TestContext.local(:prism)
      label = "local|local|sender-#{System.unique_integer([:positive])}"
      {other, _user} = Sanctum.TestContext.person!(%{local | user_id: label})
      refute other.user_id == ctx.user_id
      stored!(turn, requested_by: other.user_id)

      recovered!(ctx, ws)

      assert {:ok, %{status: "cancelled", error: error}} = Tape.turn(ctx, turn.id)
      assert error == "the athanor is no longer the sender's (not_member)"
      assert workspace_state(ctx, ws.id) == "error"
      assert [%{"outcome" => "error", "summary" => ^error, "turn_id" => turn_id}] = reports(ctx)
      assert turn_id == turn.id
      assert ScriptedWorker.calls() == []
    end
  end

  describe "a page's calls a runner recovers" do
    test "its predecessor's proposed page step is skipped, and the turn opened on it goes on " <>
           "to its end with no model asked: the call never runs",
         %{ctx: ctx} do
      start_supervised!({ScriptedWorker, ref: @model, script: [reply("put")]})
      ws = workspace!(ctx)
      :ok = Runner.subscribe(ws.id, ctx.athanor_id)
      # The turn that put the page, run by a runner the recovery starts,
      # which then goes.
      put = open_turn!(ctx, ws).id
      assert Runner.recover_all(wait_reported()) == :ok
      wait_until(fn -> ended?(ctx, put) end, 60_000, "the put ends")
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, put)
      wait_until(fn -> match?(%{running: false}, Runner.state(ws.id, ctx.athanor_id)) end)
      runner = Runner.whereis(ws.id)
      _ = :sys.get_state(runner)
      :ok = DynamicSupervisor.terminate_child(Aqua.RunnerSupervisor, runner)

      # A runner that is gone opened a turn on a page's call, ran it, and
      # proposed the call as its step; its boot's slot and keeper went with
      # it, and the rows say running.
      call = page_call(ctx, put, "notes.keep", %{"name" => "from-page", "content" => "x"})

      {:ok, %{turn: opened}} =
        Tape.accept(ctx, ws.id, %{
          message: %{
            author: Prima.Author.agent(),
            sent_by: "aqua",
            kind: "page_call",
            content: call.name,
            payload: Aqua.PageCalls.row(call),
            client_id: call.request
          },
          turn: %{agent: "aqua", requested_by: ctx.user_id}
        })

      {:ok, claim} = Opus.claim_turn_root(ctx, @soul, turn_id: opened.id, thread_id: ws.id)

      {:ok, %{capability_digest: capability, revision_digest: revision}} =
        Compendium.AgentIndex.snapshot(ctx, "aqua")

      {:ok, running} =
        Tape.start_turn(ctx, opened, %{
          root_execution_id: claim.execution_id,
          attempt: claim.attempt,
          budget_id: claim.budget_id,
          profile_id: claim.authority.profile_id,
          consent_id: claim.authority.consent_id,
          agent_revision_digest: revision,
          agent_capability_digest: capability,
          agent_mode: "auto",
          recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
        })

      proposal =
        Aqua.PageCalls.proposal(running, Aqua.PageCalls.row(call), message_id: opened.message_id)

      {:ok, %{id: step_id, dispatch_state: "proposed"}} =
        Tape.propose_call(ctx, running, proposal)

      :ok = Opus.release_turn_root(ctx, claim.execution_id, claim: claim)
      assert Runner.whereis(ws.id) == nil

      assert Runner.recover_all(wait_reported()) == :ok
      wait_until(fn -> ended?(ctx, opened.id) end, 60_000, "the work ends")

      assert {:ok, %{status: "completed", error: nil}} = Tape.turn(ctx, opened.id)

      assert [
               %{
                 id: ^step_id,
                 purpose: "page",
                 tool: "notes",
                 action: "keep",
                 dispatch_state: "closed",
                 outcome: "skipped",
                 error: nil,
                 generation: 0,
                 result_message_id: result
               }
             ] = steps!(ctx, opened.id)

      assert {:ok, %{kind: "page_result", content: @orphaned, turn_id: turn_id}} =
               Tape.message(ctx, result)

      assert turn_id == opened.id
      assert {:error, _} = Aqua.Notes.read(ctx, "from-page")
      assert Enum.count(ScriptedWorker.calls(), &(&1.input["operation"] == "chat")) == 1
    end

    test "a turn opened on a page's call that never ran is cancelled, and the turn behind it runs",
         %{ctx: ctx} do
      start_supervised!({ScriptedWorker, ref: @model, script: [reply("recovered")]})
      ws = workspace!(ctx)
      :ok = Runner.subscribe(ws.id, ctx.athanor_id)

      # A runner that is gone opened a turn on a page's call, and a person's
      # turn waits behind it.
      call = page_call(ctx, nil, "component.list", %{})

      {:ok, %{turn: opened}} =
        Tape.accept(ctx, ws.id, %{
          message: %{
            author: Prima.Author.agent(),
            sent_by: "aqua",
            kind: "page_call",
            content: call.name,
            payload: Aqua.PageCalls.row(call),
            client_id: call.request
          },
          turn: %{agent: "aqua", requested_by: ctx.user_id}
        })

      behind = open_turn!(ctx, ws)

      assert Runner.recover_all(wait_reported()) == :ok
      assert waits() == []
      wait_until(fn -> ended?(ctx, behind.id) end, 60_000, "the turn behind it ends")

      assert {:ok, %{status: "cancelled", error: @orphaned}} = Tape.turn(ctx, opened.id)
      assert [] = steps!(ctx, opened.id)
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, behind.id)
      assert [%{kind: "model", outcome: "ok"}] = steps!(ctx, behind.id)

      assert [%{kind: "page_call", client_id: request}] =
               ctx
               |> Sanctum.Context.actor()
               |> Arca.ThreadStorage.messages(ws.id)
               |> Enum.filter(&(&1.kind in ["page_call", "page_result"]))

      assert request == call.request
      assert Enum.count(ScriptedWorker.calls(), &(&1.input["operation"] == "chat")) == 1
    end
  end
end
