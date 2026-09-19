# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RunnerPoolTest do
  @moduledoc """
  The pool's accounting over the real handles and codec, with runners a
  scripted keeper hands the test: the configured number of fresh runners
  spawned ahead and refilled; an idle runner reused for its athanor only,
  a fresh one for another; an idle runner retired at its TTL; a clean
  completion to idle, an unclean one, an exit, a closed channel and a
  kill to tainted, released and gone; every busy runner offered a
  `cancel_child`; a frame from a runner already ended ignored; a keeper
  that refuses runners leaving none in the pool, tainted or otherwise,
  with the pool backing off, refusing a take with the keeper's account
  and filling again once a runner starts; and the keeper's loss ending
  every runner.
  """

  use ExUnit.Case, async: true

  import Opus.Test.Wait

  alias Cyfr.RunnerControl
  alias Opus.{RunnerPool, RunnerProcess}
  alias Opus.Test.ScriptedKeeper

  @service %{service_id: "wrk_local", boot: "boot_pool", host_url: "http://127.0.0.1:9"}
  @keys %{
    attempt: %{
      athanor_id: "ath_a",
      execution_id: "exec_a",
      attempt: "att_a",
      fence: 1,
      generation: 1,
      service: "wrk_local"
    },
    call: :binary.copy(<<1>>, 32),
    seal: :binary.copy(<<2>>, 32)
  }

  defp start_pool!(keeper, overrides) do
    {:ok, defaults} = Opus.Settings.pool([], %{})
    {keeper_opts, overrides} = Keyword.pop(overrides, :keeper_opts, [])
    settings = Map.merge(defaults, Map.new(overrides))
    unique = System.unique_integer([:positive])
    supervisor = :"pool_runners_#{unique}"
    start_supervised!({DynamicSupervisor, name: supervisor, strategy: :one_for_one})

    # The command's env carries the keeper's name to the scripted keeper.
    start_supervised!(
      {RunnerPool,
       name: :"pool_#{unique}",
       settings: settings,
       keeper: ScriptedKeeper,
       keeper_opts: keeper_opts,
       supervisor: supervisor,
       command: %{argv: ["runner"], env: %{"KEEPER" => Atom.to_string(keeper)}}}
    )
  end

  defp serve!(pool), do: :ok = RunnerPool.serve(pool, @service, self())

  defp spawns(keeper), do: ScriptedKeeper.spawns(keeper)

  defp counts(pool), do: RunnerPool.status(pool).runners

  defp assign(pid, execution_id) do
    keys = put_in(@keys, [:attempt, :execution_id], execution_id)

    RunnerProcess.send_message(pid, %{
      type: :assign,
      assignment: "token-" <> execution_id,
      input: "{}",
      keys: keys
    })
  end

  defp complete(spawn, execution_id, clean),
    do:
      ScriptedKeeper.write(
        spawn,
        RunnerControl.encode(%{type: :complete, execution_id: execution_id, clean: clean})
      )

  defp spawn_of(keeper, pid), do: Enum.find(spawns(keeper), &(&1.owner == pid))

  # The pool's status read once the keeper has refused `refused` spawns
  # and the pool has heard of every one: it holds no runner, fresh, idle,
  # busy or tainted, until its next try. Flunks if that never holds.
  defp emptied!(pool, keeper, refused) do
    none = %{fresh: 0, idle: 0, busy: 0, tainted: 0}
    parent = self()

    wait_until(
      fn ->
        if ScriptedKeeper.refused(keeper) == refused do
          status = RunnerPool.status(pool)
          if status.runners == none, do: send(parent, {:emptied, status})
        end
      end,
      5_000,
      "the pool to hear of #{refused} refusals and hold no runner"
    )

    assert_received {:emptied, status}
    status
  end

  # When the keeper's refusal count reached `count`, in monotonic
  # milliseconds: a time before it did (the start of the last reading
  # below it, or `since` when the first reading was not below it) and the
  # end of the first reading at or past it.
  defp refused_at(keeper, count, since, timeout_ms),
    do: poll_refused(keeper, count, since, System.monotonic_time(:millisecond) + timeout_ms)

  defp poll_refused(keeper, count, before, deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      ScriptedKeeper.refused(keeper) >= count ->
        {before, System.monotonic_time(:millisecond)}

      now > deadline ->
        flunk("the keeper never refused #{count} spawns")

      true ->
        Process.sleep(10)
        poll_refused(keeper, count, now, deadline)
    end
  end

  setup do
    keeper = ScriptedKeeper.start!()
    {:ok, keeper: keeper}
  end

  test "nothing is spawned before the pool serves, then the fresh runners are spawned ahead", %{
    keeper: keeper
  } do
    pool = start_pool!(keeper, pool_size: 3)
    Process.sleep(50)
    assert spawns(keeper) == []
    assert counts(pool) == %{fresh: 0, idle: 0, busy: 0, tainted: 0}

    serve!(pool)
    wait_until(fn -> counts(pool).fresh == 3 end)
    assert length(spawns(keeper)) == 3

    for spawn <- spawns(keeper) do
      assert %{
               "OPUS_ROLE" => "runner",
               "OPUS_SERVICE_ID" => "wrk_local",
               "OPUS_BOOT_ID" => "boot_pool"
             } =
               spawn.spec.env

      assert spawn.spec.env["OPUS_RUNNER_ID"] == spawn.spec.runner
      refute Map.has_key?(spawn.spec.env, "OPUS_SERVICE_KEY")
      assert spawn.spec.argv == ["runner"]
    end
  end

  test "a take uses an idle runner of the athanor first, a fresh one otherwise, and refills", %{
    keeper: keeper
  } do
    pool = start_pool!(keeper, pool_size: 1)
    serve!(pool)
    wait_until(fn -> counts(pool).fresh == 1 end)

    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    assert :ok = assign(pid, "exec_1")
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 0, busy: 1, tainted: 0} end)

    spawn = spawn_of(keeper, pid)
    assert spawn.spec.runner == id
    wait_until(fn -> ScriptedKeeper.read(spawn) != "" end)

    assert {:ok, %{type: :assign, assignment: "token-exec_1"}} =
             RunnerControl.decode(ScriptedKeeper.read(spawn))

    complete(spawn, "exec_1", true)
    assert_receive {RunnerPool, ^pid, {:complete, "exec_1", true}}
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 1, busy: 0, tainted: 0} end)

    # The same athanor gets the idle runner back; another gets a fresh one.
    assert {:ok, ^pid, ^id} = RunnerPool.take(pool, "ath_a", "exec_2")
    complete(spawn, "exec_2", true)
    assert_receive {RunnerPool, ^pid, {:complete, "exec_2", true}}
    wait_until(fn -> counts(pool).idle == 1 end)

    {:ok, other, other_id} = RunnerPool.take(pool, "ath_b", "exec_3")
    assert other != pid and other_id != id
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 1, busy: 1, tainted: 0} end)
  end

  test "an idle runner is retired at its TTL and the pool refills", %{keeper: keeper} do
    pool = start_pool!(keeper, pool_size: 1, idle_ttl_ms: 100)
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)
    complete(spawn, "exec_1", true)
    assert_receive {RunnerPool, ^pid, {:complete, "exec_1", true}}
    wait_until(fn -> counts(pool).idle == 1 end)

    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 0, busy: 0, tainted: 0} end, 2_000)
    wait_until(fn -> Enum.count(RunnerPool.runners(pool)) == 1 end)
    assert [{^id, 0}] = ScriptedKeeper.releases(keeper)
    refute Process.alive?(pid)
  end

  test "an unclean completion, an exit and a kill taint the runner, which is released and gone",
       %{
         keeper: keeper
       } do
    pool = start_pool!(keeper, pool_size: 0)
    serve!(pool)

    {:ok, unclean, unclean_id} = RunnerPool.take(pool, "ath_a", "exec_1")
    complete(spawn_of(keeper, unclean), "exec_1", false)
    assert_receive {RunnerPool, ^unclean, {:complete, "exec_1", false}}
    wait_until(fn -> Enum.empty?(RunnerPool.runners(pool)) end)
    assert {unclean_id, 0} in ScriptedKeeper.releases(keeper)

    {:ok, exited, exited_id} = RunnerPool.take(pool, "ath_a", "exec_2")

    ScriptedKeeper.write(
      spawn_of(keeper, exited),
      RunnerControl.encode(%{type: :exit, runner: exited_id, open: ["att_2", "att_child"]})
    )

    assert_receive {RunnerPool, ^exited, {:exit, ^exited_id, ["att_2", "att_child"]}}
    wait_until(fn -> Enum.empty?(RunnerPool.runners(pool)) end)
    assert {exited_id, 0} in ScriptedKeeper.releases(keeper)

    {:ok, killed, killed_id} = RunnerPool.take(pool, "ath_a", "exec_3")
    assert :ok = RunnerPool.taint(pool, killed, 250)
    assert counts(pool) == %{fresh: 0, idle: 0, busy: 0, tainted: 1}
    wait_until(fn -> {killed_id, 250} in ScriptedKeeper.releases(keeper) end)

    # Ended by the keeper after its grace, without a frame of its own.
    assert_receive {RunnerPool, ^killed, {:gone, _reason}}, 2_000
    wait_until(fn -> Enum.empty?(RunnerPool.runners(pool)) end)
  end

  test "a killed runner's own exit frame still reaches the assignee, once", %{keeper: keeper} do
    pool = start_pool!(keeper, pool_size: 0)
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    assert :ok = RunnerPool.taint(pool, pid, 1_000)

    ScriptedKeeper.write(
      spawn_of(keeper, pid),
      RunnerControl.encode(%{type: :exit, runner: id, open: ["att_1", "att_child"]})
    )

    assert_receive {RunnerPool, ^pid, {:exit, ^id, ["att_1", "att_child"]}}
    assert counts(pool).tainted == 1
    # Its end after the grace is not a second event.
    refute_receive {RunnerPool, ^pid, _}, 1_500
    wait_until(fn -> Enum.empty?(RunnerPool.runners(pool)) end)
  end

  test "a closed channel or an exited process with the subtree assigned is reported gone", %{
    keeper: keeper
  } do
    pool = start_pool!(keeper, pool_size: 0)
    serve!(pool)

    {:ok, closed, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
    ScriptedKeeper.close(spawn_of(keeper, closed))
    assert_receive {RunnerPool, ^closed, {:gone, :closed}}

    {:ok, exited, _id} = RunnerPool.take(pool, "ath_a", "exec_2")
    ScriptedKeeper.exit(spawn_of(keeper, exited), 1)
    assert_receive {RunnerPool, ^exited, {:gone, _}}
    wait_until(fn -> Enum.empty?(RunnerPool.runners(pool)) end)

    # Reported once: the exit that follows the close is not a second event.
    refute_receive {RunnerPool, ^closed, _}, 100
  end

  test "a killed runner that still completes is heard once and never returns to the pool", %{
    keeper: keeper
  } do
    pool = start_pool!(keeper, pool_size: 0)
    serve!(pool)

    {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)
    assert :ok = RunnerPool.taint(pool, pid, 300)
    complete(spawn, "exec_1", true)
    assert_receive {RunnerPool, ^pid, {:complete, "exec_1", true}}
    assert counts(pool) == %{fresh: 0, idle: 0, busy: 0, tainted: 1}

    # Its end after the grace is not a second event, and it is gone.
    wait_until(fn -> Enum.empty?(RunnerPool.runners(pool)) end, 2_000)
    refute_received {RunnerPool, ^pid, _}
  end

  test "every busy runner is offered a cancel_child", %{keeper: keeper} do
    pool = start_pool!(keeper, pool_size: 1)
    serve!(pool)
    {:ok, a, _} = RunnerPool.take(pool, "ath_a", "exec_1")
    {:ok, b, _} = RunnerPool.take(pool, "ath_b", "exec_2")
    assert :ok = assign(a, "exec_1")
    assert :ok = assign(b, "exec_2")
    wait_until(fn -> counts(pool).fresh == 1 end)

    assert :ok = RunnerPool.cancel_child(pool, "exec_child")

    for pid <- [a, b] do
      spawn = spawn_of(keeper, pid)
      wait_until(fn -> String.contains?(ScriptedKeeper.read(spawn), "cancel_child") end)
      [_assign, cancel] = ScriptedKeeper.read(spawn) |> String.split("\n", trim: true)

      assert {:ok, %{type: :cancel_child, execution_id: "exec_child"}} =
               RunnerControl.decode(cancel)
    end

    # The fresh runner heard nothing.
    fresh = Enum.find(RunnerPool.runners(pool), &(&1.state == :fresh))
    assert ScriptedKeeper.read(spawn_of(keeper, fresh.pid)) == ""
  end

  test "a line that is not a runner's frame taints the runner", %{keeper: keeper} do
    pool = start_pool!(keeper, pool_size: 0)
    serve!(pool)
    {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)

    ScriptedKeeper.write(
      spawn,
      RunnerControl.encode(%{type: :cancel_child, execution_id: "exec_x"})
    )

    assert_receive {RunnerPool, ^pid, {:gone, {:protocol, {:not_a_runner_frame, :cancel_child}}}}
    wait_until(fn -> Enum.empty?(RunnerPool.runners(pool)) end)

    {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_2")
    ScriptedKeeper.write(spawn_of(keeper, pid), "not json\n")
    assert_receive {RunnerPool, ^pid, {:gone, {:protocol, :malformed}}}
  end

  test "retiring the busy runners ends each at once and answers once they are gone, keeping the fresh and idle",
       %{keeper: keeper} do
    pool = start_pool!(keeper, pool_size: 1)
    serve!(pool)
    wait_until(fn -> counts(pool).fresh == 1 end)

    {:ok, idle, _} = RunnerPool.take(pool, "ath_a", "exec_idle")
    complete(spawn_of(keeper, idle), "exec_idle", true)
    assert_receive {RunnerPool, ^idle, {:complete, "exec_idle", true}}
    {:ok, a, a_id} = RunnerPool.take(pool, "ath_b", "exec_1")
    {:ok, b, b_id} = RunnerPool.take(pool, "ath_c", "exec_2")
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 1, busy: 2, tainted: 0} end)

    assert :ok = RunnerPool.retire_busy(pool)

    assert counts(pool) == %{fresh: 1, idle: 1, busy: 0, tainted: 0}
    assert {a_id, 0} in ScriptedKeeper.releases(keeper)
    assert {b_id, 0} in ScriptedKeeper.releases(keeper)
    refute Enum.any?(RunnerPool.runners(pool), &(&1.pid in [a, b]))
    assert_received {RunnerPool, ^a, {:gone, _}}
    assert_received {RunnerPool, ^b, {:gone, _}}

    # Nothing busy: answered at once.
    assert :ok = RunnerPool.retire_busy(pool)
  end

  describe "a keeper that refuses runners" do
    test "leaves no runner in the pool, which backs off, refuses a take with the keeper's account and says so",
         %{keeper: keeper} do
      :ok = ScriptedKeeper.refuse(keeper, :memory_unavailable)
      pool = start_pool!(keeper, pool_size: 3, keeper_opts: [memory_bytes: 402_653_184])
      started = System.monotonic_time(:millisecond)
      serve!(pool)

      # The keeper counts a refusal as it answers a spawn, and the pool
      # hears of it through the runner's handle after that, so the pool is
      # read once it has heard of all three: then, and until the wait it
      # starts has run out, it holds no runner.
      assert %{
               runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0},
               memory_bytes: 402_653_184,
               refusal: %{reason: "memory_unavailable", message: message}
             } = emptied!(pool, keeper, 3)

      assert message =~ "refuses"

      assert {:error, {:refused, %{reason: "memory_unavailable"}}} =
               RunnerPool.take(pool, "ath_a", "exec_1")

      # One runner is tried again at a time, the wait doubling from a
      # second. A wait starts once the pool has heard of the refusal
      # before it, after the keeper counted that refusal, so each is
      # measured from a reading taken before the count it follows moved
      # to one taken after the count it ends moved: never shorter than
      # the wait, and a second or so if the wait did not double.
      {before_first, first_retry} = refused_at(keeper, 4, started, 3_000)
      assert first_retry - started >= 900

      {_before_second, second_retry} = refused_at(keeper, 5, first_retry, 4_000)
      assert second_retry - before_first >= 1_900

      assert %{runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0}} = emptied!(pool, keeper, 5)

      # The keeper starts runners again: the next one tried ends the refusal
      # and the pool fills.
      :ok = ScriptedKeeper.refuse(keeper, nil)
      wait_until(fn -> counts(pool).fresh == 3 end, 10_000)
      assert %{refusal: nil} = RunnerPool.status(pool)
      assert {:ok, _pid, _id} = RunnerPool.take(pool, "ath_a", "exec_2")
    end

    test "a runner taken while spawning and then refused is gone for its assignee, never tainted",
         %{keeper: keeper} do
      :ok = ScriptedKeeper.refuse(keeper, :memory_unavailable)
      pool = start_pool!(keeper, pool_size: 0)
      serve!(pool)

      {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
      assert_receive {RunnerPool, ^pid, {:gone, {:refused, :memory_unavailable}}}
      assert counts(pool) == %{fresh: 0, idle: 0, busy: 0, tainted: 0}
      assert RunnerPool.runners(pool) == []

      assert {:error, {:refused, %{reason: "memory_unavailable"}}} =
               RunnerPool.take(pool, "ath_a", "exec_2")
    end
  end

  test "the keeper's loss ends every runner, the busy ones reported gone", %{keeper: keeper} do
    pool = start_pool!(keeper, pool_size: 1)
    serve!(pool)
    {:ok, busy, _} = RunnerPool.take(pool, "ath_a", "exec_1")
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 0, busy: 1, tainted: 0} end)

    ScriptedKeeper.kill!(keeper)

    assert_receive {RunnerPool, ^busy, {:gone, :channel_lost}}
    wait_until(fn -> counts(pool).busy == 0 end)
    refute_receive {RunnerPool, _, {:gone, _}}, 100
  end
end
