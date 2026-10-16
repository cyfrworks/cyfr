# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RunnerRecoveryTest do
  @moduledoc """
  The boot's recovery of open turns outlasts a database that cannot
  answer: a scan that fails is tried again after a wait, and the runner of
  a thread holding an open turn starts once the store answers. A scan that
  never answers is abandoned with a log line and
  `[:cyfr, :aqua, :recovery, :abandoned]`, recovering nothing, and the
  recovery still ends normally.

  The outage is the real store's: the turns table is renamed inside the
  test's sandbox transaction, so the scan's own query fails as it would
  against a database that cannot answer, and the rename is undone with
  the transaction when the test ends. The waits between scans are the
  production ones, handed to a wait the test supplies so it observes each
  without sleeping through it; the first restores the table.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Aqua.{Runner, Tape}
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Tenancy.Members

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "recovery_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path, arca: :seed_path]
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
    Application.put_env(:arca, :seed_path, @seed_root)

    # The runners run under the paths restored above.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    ctx = %{ctx | origin: :interactive}
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: ctx.athanor_id)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"},
      origins: [:interactive, :programmatic]
    )

    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Arca.ThreadStorage.create(Sanctum.Context.actor(ctx))
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
        message: %{author: ctx.user_id, content: "@aqua carry on"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    assert Runner.whereis(thread.id) == nil
    turn
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
end
