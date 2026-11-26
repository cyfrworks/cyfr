# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RunnerPoolTest do
  @moduledoc """
  The pool's accounting over the real handles and codec, with runners a
  scripted keeper hands the test: the warm floor's one fresh runner
  spawned ahead and refilled; an idle runner reused for its athanor only,
  a fresh one for another; an idle runner retired at its TTL, and one the
  keeper asks to give way retired at once, while a busy or taken one is
  left alone, as is a runner a taint names another execution of; a clean
  completion to idle, an unclean one, an exit, a closed channel, a closed
  relay and a kill to tainted, released and gone, and a clean completion
  whose place the keeper did not make warm again to tainted as it is
  heard, never handed to a take queued right after it; a runner its keeper
  has not retired, busy or idle, said so once at the retirement bound and
  held, tainted, until its keeper retires it, one retired in time left
  alone by the bound's timer, and one whose handle died held until its
  keeper's release reaches the pool as the runner's heir, and one tainted
  while its place waits for room giving the place up at once, never said
  unretired; every busy
  runner offered a
  `cancel_child`; a frame from a runner already ended ignored; a keeper
  that refuses runners leaving none in the pool, tainted or otherwise,
  with the pool backing off, a take still asking the keeper and refused
  with its reason of that moment, a release ending the refusal at once,
  and the pool filling again once a runner starts, and a runner it
  refused after making it held in its place among those ahead until its
  release, one a start; and the keeper's loss ending every runner.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Prima.RunnerControl
  alias Locus.Runtime.{RunnerPool, RunnerProcess}
  alias Locus.Runtime.Test.{Runners, ScriptedHost, ScriptedKeeper}

  @service %{service_id: "wrk_local", boot: "boot_pool"}
  # The address an assignment names for its member's host API.
  @host_url "http://127.0.0.1:9"

  defp start_pool!(keeper, overrides) do
    {:ok, defaults} = Locus.Runtime.Settings.pool([], %{})
    {keeper_opts, overrides} = Keyword.pop(overrides, :keeper_opts, [])
    # The scripted keeper keeps the runners' places under its name.
    keeper_opts = Keyword.put_new(keeper_opts, :name, keeper)
    {pool_opts, overrides} = Keyword.split(overrides, [:retire_bound_ms])
    settings = Map.merge(defaults, Map.new(overrides))
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    # The command's env carries the keeper's name to the scripted keeper.
    start_supervised!(
      {RunnerPool,
       [
         name: nil,
         settings: settings,
         keeper: ScriptedKeeper,
         keeper_opts: keeper_opts,
         supervisor: supervisor,
         command: %{argv: ["runner"], env: %{"KEEPER" => Atom.to_string(keeper)}}
       ] ++ pool_opts}
    )
  end

  defp serve!(pool), do: :ok = RunnerPool.serve(pool, @service, self())

  defp spawns(keeper), do: ScriptedKeeper.spawns(keeper)

  defp wait_for_spawns(keeper, count) do
    wait_until(fn -> length(spawns(keeper)) == count end)
    spawns(keeper)
  end

  defp counts(pool), do: RunnerPool.status(pool).runners

  # The runner `pid` has left the pool, the floor's runner staying.
  defp left!(pool, pid, timeout_ms \\ 2_000),
    do: wait_until(fn -> not Enum.any?(Runners.runners(pool), &(&1.pid == pid)) end, timeout_ms)

  # A start's deadline far enough off for an answer that comes at once.
  defp soon, do: System.monotonic_time(:millisecond) + 5_000

  # An assign as the service sends one, of an attempt of `athanor` a
  # scripted host minted, so the runner's relay binds to it: the handle's
  # answer and the assignment's token.
  defp assign(pid, athanor \\ "ath_test") do
    attempt = ScriptedHost.attempt!(ScriptedHost.start!(), athanor_id: athanor)

    {RunnerProcess.assign(pid, attempt.assignment, "{}", attempt.keys, @host_url, soon()),
     attempt.assignment}
  end

  defp complete(spawn, execution_id, clean),
    do:
      ScriptedKeeper.write(
        spawn,
        RunnerControl.encode(%{type: :complete, execution_id: execution_id, clean: clean})
      )

  # The keeper records a spawn as the runner's owner starts; a take answers
  # as soon as the runner stands, so the record is awaited, not assumed.
  defp spawn_of(keeper, pid) do
    wait_until(
      fn -> Enum.any?(spawns(keeper), &(&1.owner == pid)) end,
      5_000,
      "the keeper to record the runner's spawn"
    )

    Enum.find(spawns(keeper), &(&1.owner == pid))
  end

  # Run `fun` with runner `spawn`'s process suspended, so a release the
  # keeper delivers it is never handled and the runner is never reported
  # retired; it is resumed however `fun` ends.
  defp never_retired(%{runner: runner}, fun) do
    :ok = :sys.suspend(runner)

    try do
      fun.()
    after
      if Process.alive?(runner), do: :sys.resume(runner)
    end
  end

  @unretired "was not retired by its keeper within the retirement bound"

  # The runner `pid` stays the pool's, being ended, for all of `ms`: read
  # every 100 ms, it is there each time.
  defp assert_until_held(pool, pid, ms),
    do: held_until(pool, pid, System.monotonic_time(:millisecond) + ms)

  defp held_until(pool, pid, deadline) do
    assert %{state: ending} = Enum.find(Runners.runners(pool), &(&1.pid == pid)),
           "the runner left the pool before its keeper retired it"

    assert ending in [:tainted, :retiring]

    if System.monotonic_time(:millisecond) < deadline do
      # sleep-ok: nothing is awaited; the runner is read again a tenth of a second later.
      Process.sleep(100)
      held_until(pool, pid, deadline)
    end
  end

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
        # sleep-ok: poll interval of poll_refused's deadline-bounded wait for the keeper's
        # refusals
        Process.sleep(10)
        poll_refused(keeper, count, now, deadline)
    end
  end

  setup do
    keeper = ScriptedKeeper.start!(__MODULE__.Keeper)
    {:ok, keeper: keeper}
  end

  test "nothing is spawned before the pool serves, then the warm floor's one runner is spawned ahead",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    # sleep-ok: 50 ms in which a pool that does not serve yet must spawn nothing
    Process.sleep(50)
    assert spawns(keeper) == []
    assert counts(pool) == %{fresh: 0, idle: 0, busy: 0, tainted: 0}

    serve!(pool)
    wait_until(fn -> counts(pool).fresh == Prima.LocusPool.floor_runners() end)
    # A runner counts fresh while it spawns: it places itself first.
    wait_until(fn -> length(spawns(keeper)) == 1 end)
    assert counts(pool).fresh == 1

    for spawn <- spawns(keeper) do
      assert %{
               "RUNTIME_ROLE" => "runner",
               "RUNTIME_SERVICE_ID" => "wrk_local",
               "RUNTIME_BOOT_ID" => "boot_pool"
             } =
               spawn.spec.env

      assert spawn.spec.env["RUNTIME_RUNNER_ID"] == spawn.spec.runner
      refute Map.has_key?(spawn.spec.env, "LOCUS_RUNTIME_KEY")

      # The keeper refuses a spawn that carries any `CYFR_`, `LOCUS_` or
      # `KEEPER_` name: a runner is handed its own prefix alone.
      for {name, _value} <- spawn.spec.env do
        refute String.starts_with?(name, Prima.KeeperProtocol.reserved_env_prefixes()), name
      end

      assert spawn.spec.argv == ["runner"]
    end
  end

  test "a take uses an idle runner of the athanor first, a fresh one otherwise, and refills", %{
    keeper: keeper
  } do
    pool = start_pool!(keeper, [])
    serve!(pool)
    wait_until(fn -> counts(pool).fresh == 1 end)

    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    assert {:ok, token} = assign(pid)
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 0, busy: 1, tainted: 0} end)

    spawn = spawn_of(keeper, pid)
    assert spawn.spec.runner == id
    wait_until(fn -> ScriptedKeeper.read(spawn) != "" end)

    assert {:ok, %{type: :assign, assignment: ^token}} =
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

  # Whose each place the keeper holds is, by its id.
  defp whose(keeper),
    do: Map.new(ScriptedKeeper.places(keeper), fn {id, place} -> {id, place.whose} end)

  test "a runner's place is warm until its work, run for the work's athanor once its assign is answered, " <>
         "warm again at a clean end before the pool hears it, run at its reuse, and freed once it is released",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    wait_until(fn -> length(spawns(keeper)) == 1 end)
    [fresh] = spawns(keeper)
    fresh_place = whose(keeper)[fresh.spec.runner]

    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)
    assert {:ok, _token} = assign(pid, "ath_a")
    taken = whose(keeper)[spawn.spec.runner]
    complete(spawn, "exec_1", true)
    assert_receive {RunnerPool, ^pid, {:complete, "exec_1", true}}
    at_rest = whose(keeper)[id]
    wait_until(fn -> counts(pool).idle == 1 end)

    assert {:ok, ^pid, ^id} = RunnerPool.take(pool, "ath_a", "exec_2")
    assert {:ok, _token} = assign(pid, "ath_a")
    reused = whose(keeper)[id]
    assert :ok = RunnerPool.taint(pool, pid, 0, "exec_2")
    assert_receive {RunnerPool, ^pid, {:gone, _reason}}, 5_000
    wait_until(fn -> not Map.has_key?(ScriptedKeeper.places(keeper), id) end)

    assert %{
             fresh: fresh_place,
             place: spawn.spec.runner,
             taken: taken,
             at_rest: at_rest,
             reused: reused
           } == %{
             fresh: %{kind: "warm"},
             place: id,
             taken: %{kind: "run", athanor: "ath_a"},
             at_rest: %{kind: "warm", athanor: "ath_a"},
             reused: %{kind: "run", athanor: "ath_a"}
           }
  end

  # The take is in at the runner and the keeper: the runner answers after
  # what the take sent it, and the keeper after what that sent it.
  defp taken!(keeper, pid) do
    _info = RunnerProcess.info(pid)
    _places = ScriptedKeeper.places(keeper)
    :ok
  end

  test "a clean completion whose place the keeper does not make warm again ends its runner as the pool hears it: a take queued right after it never gets that runner",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)
    assert {:ok, _token} = assign(pid, "ath_a")
    :ok = ScriptedKeeper.assigning(keeper, {:refused, :unknown_place})

    # What the runner tells of its completion waits in the suspended pool,
    # and a take is queued right behind the first of it.
    :ok = :sys.suspend(pool)
    complete(spawn, "exec_1", true)
    _info = RunnerProcess.info(pid)
    taking = Task.async(fn -> RunnerPool.take(pool, "ath_a", "exec_2") end)

    wait_until(
      fn ->
        {:messages, messages} = Process.info(pool, :messages)

        Enum.any?(
          messages,
          &match?({:"$gen_call", _from, {:take, "ath_a", "exec_2", _deadline}}, &1)
        )
      end,
      5_000,
      "the take queued at the pool"
    )

    :ok = take_right_after_first(pool, pid)
    :ok = :sys.resume(pool)

    assert_receive {RunnerPool, ^pid, {:complete, "exec_1", true}}, 5_000
    assert {:ok, other, _other_id} = Task.await(taking)
    refute other == pid
  end

  # The suspended pool's mailbox, from inside the pool: the first of what
  # `runner` told it, then every other message (the take queued behind),
  # then the rest of what `runner` told.
  defp take_right_after_first(pool, runner) do
    :sys.replace_state(pool, fn state ->
      {[first | rest], others} =
        Enum.split_with(mailbox([]), &match?({RunnerProcess, ^runner, _event}, &1))

      Enum.each([first | others] ++ rest, &send(self(), &1))
      state
    end)

    :ok
  end

  defp mailbox(messages) do
    receive do
      message -> mailbox([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  test "a runner's work is written only once the keeper has answered the assign of its place",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "family@example", "exec_1")
    spawn = spawn_of(keeper, pid)
    :ok = taken!(keeper, pid)
    attempt = ScriptedHost.attempt!(ScriptedHost.start!(), athanor_id: "family@example")
    :ok = ScriptedKeeper.assigning(keeper, :held)

    assigning =
      Task.async(fn ->
        RunnerProcess.assign(pid, attempt.assignment, "{}", attempt.keys, @host_url, soon())
      end)

    wait_until(
      fn -> ScriptedKeeper.held_assigns(keeper) != [] end,
      5_000,
      "the keeper to hold the runner's assign"
    )

    held = %{
      written: ScriptedKeeper.read(spawn),
      held: ScriptedKeeper.held_assigns(keeper),
      whose: whose(keeper)[id]
    }

    :ok = ScriptedKeeper.answer_assigns(keeper)
    assert :ok = Task.await(assigning)
    token = attempt.assignment

    assert held == %{
             written: "",
             held: [{id, %{kind: "run", athanor: "family@example"}}],
             whose: %{kind: "warm"}
           }

    assert {:ok, %{type: :assign, assignment: ^token}} =
             RunnerControl.decode(ScriptedKeeper.read(spawn))

    assert whose(keeper)[id] == %{kind: "run", athanor: "family@example"}
  end

  test "a refused assign sends the runner none of its work, and its caller hears the refusal",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "family@example", "exec_1")
    spawn = spawn_of(keeper, pid)
    :ok = taken!(keeper, pid)
    :ok = ScriptedKeeper.assigning(keeper, {:refused, :unknown_place})

    assert {{:error, {:unsent, {:assign, :unknown_place}}}, _token} =
             assign(pid, "family@example")

    assert %{written: ScriptedKeeper.read(spawn), whose: whose(keeper)[id]} ==
             %{written: "", whose: %{kind: "warm"}}
  end

  test "a runner whose process dies before it spawns, or that is refused, leaves no place",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])

    # Held at the keeper as it places itself, the floor's runner's process
    # dies.
    :ok = :sys.suspend(keeper)
    serve!(pool)
    {:ok, dying, dying_id} = RunnerPool.take(pool, "ath_a", "exec_1")

    wait_until(fn ->
      {:message_queue_len, waiting} = Process.info(Process.whereis(keeper), :message_queue_len)
      waiting > 0
    end)

    Process.exit(dying, :kill)
    assert_receive {RunnerPool, ^dying, {:gone, _reason}}, 5_000
    :ok = :sys.resume(keeper)

    # The runner the pool spawned behind it starts; the next one the keeper
    # refuses.
    wait_until(fn -> counts(pool).fresh == 1 and length(spawns(keeper)) == 1 end)
    [%{spec: %{runner: started}}] = spawns(keeper)
    :ok = ScriptedKeeper.refuse(keeper, :memory_unavailable)
    {:ok, _started, ^started} = RunnerPool.take(pool, "ath_a", "exec_2")
    wait_until(fn -> ScriptedKeeper.refused(keeper) == 1 end)

    assert %{
             places: Map.keys(ScriptedKeeper.places(keeper)),
             spawned: Enum.map(spawns(keeper), & &1.spec.runner)
           } == %{places: [started], spawned: [started]}

    refute started == dying_id
  end

  test "an idle runner is retired at its TTL and the pool refills", %{keeper: keeper} do
    pool = start_pool!(keeper, idle_ttl_ms: 100)
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)
    complete(spawn, "exec_1", true)
    assert_receive {RunnerPool, ^pid, {:complete, "exec_1", true}}
    wait_until(fn -> counts(pool).idle == 1 end)

    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 0, busy: 0, tainted: 0} end, 2_000)
    wait_until(fn -> Enum.count(Runners.runners(pool)) == 1 end)
    assert [{^id, 0}] = ScriptedKeeper.releases(keeper)
    refute Process.alive?(pid)
  end

  # A runner idle for `athanor`, its subtree completed cleanly.
  defp idle!(pool, keeper, athanor, execution_id) do
    {:ok, pid, id} = RunnerPool.take(pool, athanor, execution_id)
    assert {:ok, _token} = assign(pid, athanor)
    complete(spawn_of(keeper, pid), execution_id, true)
    assert_receive {RunnerPool, ^pid, {:complete, ^execution_id, true}}, 5_000
    wait_until(fn -> Enum.any?(Runners.runners(pool), &(&1.pid == pid and &1.state == :idle)) end)
    {pid, id}
  end

  defp queued?(pid, pattern_fun) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.any?(messages, pattern_fun)
  end

  test "a give_way ends exactly the idle runner it names: a busy runner, one taken before the pool heard it, the fresh one and the pool live",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {idle, idle_id} = idle!(pool, keeper, "ath_a", "exec_1")
    {:ok, busy, busy_id} = RunnerPool.take(pool, "ath_b", "exec_2")
    assert {:ok, _token} = assign(busy, "ath_b")
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 1, busy: 1, tainted: 0} end)
    %{pid: fresh} = Enum.find(Runners.runners(pool), &(&1.state == :fresh))

    :ok = ScriptedKeeper.give_way(keeper, busy_id)
    _info = RunnerProcess.info(busy)
    :ok = ScriptedKeeper.give_way(keeper, idle_id)
    wait_until(fn -> ScriptedKeeper.releases(keeper) != [] end)
    wait_until(fn -> not Enum.any?(Runners.runners(pool), &(&1.pid == idle)) end)

    # One idle the keeper names while a take of it waits at the pool ahead
    # of the pool hearing the ask: the take has it, and the ask ends nothing.
    {taken, taken_id} = idle!(pool, keeper, "ath_c", "exec_3")
    :ok = :sys.suspend(pool)
    taking = Task.async(fn -> RunnerPool.take(pool, "ath_c", "exec_4") end)

    wait_until(fn ->
      queued?(pool, &match?({:"$gen_call", _from, {:take, "ath_c", _, _}}, &1))
    end)

    :ok = ScriptedKeeper.give_way(keeper, taken_id)
    wait_until(fn -> queued?(pool, &match?({RunnerProcess, ^taken, :give_way}, &1)) end)
    :ok = :sys.resume(pool)
    assert {:ok, ^taken, ^taken_id} = Task.await(taking)

    _status = RunnerPool.status(pool)

    assert %{
             releases: ScriptedKeeper.releases(keeper),
             alive: Enum.map([busy, fresh, taken, pool], &Process.alive?/1),
             counts: counts(pool)
           } == %{
             releases: [{idle_id, 0}],
             alive: [true, true, true, true],
             counts: %{fresh: 1, idle: 0, busy: 2, tainted: 0}
           }
  end

  test "a give_way never takes the floor's one fresh runner, and a runner that turned one down goes at the next once idle",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, busy, busy_id} = RunnerPool.take(pool, "ath_a", "exec_1")
    assert {:ok, _token} = assign(busy, "ath_a")
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 0, busy: 1, tainted: 0} end)
    %{pid: fresh, id: fresh_id} = Enum.find(Runners.runners(pool), &(&1.state == :fresh))

    # The floor's runner, asked after the runner above it was taken, stays.
    :ok = ScriptedKeeper.give_way(keeper, fresh_id)
    # Turned down while busy...
    :ok = ScriptedKeeper.give_way(keeper, busy_id)
    _status = RunnerPool.status(pool)
    assert ScriptedKeeper.releases(keeper) == []

    # ...and asked again once it is idle, it goes; a second ask of it
    # while it goes ends nothing more.
    complete(spawn_of(keeper, busy), "exec_1", true)
    assert_receive {RunnerPool, ^busy, {:complete, "exec_1", true}}, 5_000
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 1, busy: 0, tainted: 0} end)
    :ok = ScriptedKeeper.give_way(keeper, busy_id)
    :ok = ScriptedKeeper.give_way(keeper, busy_id)
    wait_until(fn -> not Enum.any?(Runners.runners(pool), &(&1.pid == busy)) end)

    assert %{
             releases: ScriptedKeeper.releases(keeper),
             fresh: Process.alive?(fresh),
             counts: counts(pool)
           } == %{
             releases: [{busy_id, 0}],
             fresh: true,
             counts: %{fresh: 1, idle: 0, busy: 0, tainted: 0}
           }
  end

  # The service may read an ask to end a runner after the pool handed the
  # runner out again: the ask names the execution it was for.
  test "a taint naming an execution its runner has completed, or another than it runs, ends nothing",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {runner, id} = idle!(pool, keeper, "ath_a", "exec_1")
    assert :ok = RunnerPool.taint(pool, runner, 0, "exec_1")
    assert {:ok, ^runner, ^id} = RunnerPool.take(pool, "ath_a", "exec_2")
    assert :ok = RunnerPool.taint(pool, runner, 0, "exec_1")

    assert %{
             releases: ScriptedKeeper.releases(keeper),
             runner: Enum.find(Runners.runners(pool), &(&1.pid == runner)).execution_id
           } == %{releases: [], runner: "exec_2"}

    assert :ok = RunnerPool.taint(pool, runner, 0, "exec_2")
    wait_until(fn -> ScriptedKeeper.releases(keeper) == [{id, 0}] end)
  end

  test "an unclean completion, an exit and a kill taint the runner, which is released and gone",
       %{
         keeper: keeper
       } do
    pool = start_pool!(keeper, [])
    serve!(pool)

    {:ok, unclean, unclean_id} = RunnerPool.take(pool, "ath_a", "exec_1")
    complete(spawn_of(keeper, unclean), "exec_1", false)
    assert_receive {RunnerPool, ^unclean, {:complete, "exec_1", false}}
    left!(pool, unclean)
    assert {unclean_id, 0} in ScriptedKeeper.releases(keeper)

    {:ok, exited, exited_id} = RunnerPool.take(pool, "ath_a", "exec_2")

    ScriptedKeeper.write(
      spawn_of(keeper, exited),
      RunnerControl.encode(%{type: :exit, runner: exited_id, open: ["att_2", "att_child"]})
    )

    assert_receive {RunnerPool, ^exited, {:exit, ^exited_id, ["att_2", "att_child"]}}
    left!(pool, exited)
    assert {exited_id, 0} in ScriptedKeeper.releases(keeper)

    {:ok, killed, killed_id} = RunnerPool.take(pool, "ath_a", "exec_3")
    assert :ok = RunnerPool.taint(pool, killed, 250, "exec_3")
    assert counts(pool) == %{fresh: 1, idle: 0, busy: 0, tainted: 1}
    wait_until(fn -> {killed_id, 250} in ScriptedKeeper.releases(keeper) end)

    # Ended by the keeper after its grace, without a frame of its own.
    assert_receive {RunnerPool, ^killed, {:gone, _reason}}, 2_000
    left!(pool, killed)
  end

  test "a runner's exit frame heard after the keeper's exited still reports its open attempts",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)

    never_retired(spawn, fn ->
      send(pid, {ScriptedKeeper, spawn.ref, {:exited, {:status, 137}}})
      frame = RunnerControl.encode(%{type: :exit, runner: id, open: ["att_1", "att_child"]})
      send(pid, {ScriptedKeeper, spawn.ref, {:control, IO.iodata_to_binary(frame)}})
      send(pid, {ScriptedKeeper, spawn.ref, :control_closed})
      assert_receive {RunnerPool, ^pid, {:exit, ^id, ["att_1", "att_child"]}}, 5_000
      _ = :sys.get_state(pid)
      _ = RunnerPool.status(pool)
      refute_received {RunnerPool, ^pid, {:gone, _}}
    end)
  end

  test "an exited runner whose control channel stays open is reported gone within a bound", %{
    keeper: keeper
  } do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)

    never_retired(spawn, fn ->
      send(pid, {ScriptedKeeper, spawn.ref, {:exited, {:status, 137}}})
      assert_receive {RunnerPool, ^pid, {:gone, {:exited, {:status, 137}}}}, 5_000
    end)
  end

  test "a killed runner's own exit frame still reaches the assignee, once", %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    assert :ok = RunnerPool.taint(pool, pid, 1_000, "exec_1")

    ScriptedKeeper.write(
      spawn_of(keeper, pid),
      RunnerControl.encode(%{type: :exit, runner: id, open: ["att_1", "att_child"]})
    )

    assert_receive {RunnerPool, ^pid, {:exit, ^id, ["att_1", "att_child"]}}
    assert counts(pool).tainted == 1
    # Its end after the grace is not a second event: `Runners.retire_busy/2`
    # answers once the keeper has retired it, by when anything the pool
    # tells of its end has been sent.
    assert :ok = Runners.retire_busy(pool)
    refute Enum.any?(Runners.runners(pool), &(&1.pid == pid))
    refute_received {RunnerPool, ^pid, _}
  end

  test "a closed channel or an exited process with the subtree assigned is reported gone", %{
    keeper: keeper
  } do
    pool = start_pool!(keeper, [])
    serve!(pool)

    {:ok, closed, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
    ScriptedKeeper.close(spawn_of(keeper, closed))
    assert_receive {RunnerPool, ^closed, {:gone, :closed}}

    {:ok, exited, _id} = RunnerPool.take(pool, "ath_a", "exec_2")
    ScriptedKeeper.exit(spawn_of(keeper, exited), 1)
    assert_receive {RunnerPool, ^exited, {:gone, _}}
    left!(pool, exited)
    left!(pool, closed)

    # Reported once: the exit that follows the close is not a second event.
    refute_receive {RunnerPool, ^closed, _}, 100
  end

  test "a killed runner that still completes is heard once and never returns to the pool", %{
    keeper: keeper
  } do
    pool = start_pool!(keeper, [])
    serve!(pool)

    {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)
    assert :ok = RunnerPool.taint(pool, pid, 300, "exec_1")
    complete(spawn, "exec_1", true)
    assert_receive {RunnerPool, ^pid, {:complete, "exec_1", true}}
    assert counts(pool) == %{fresh: 1, idle: 0, busy: 0, tainted: 1}

    # Its end after the grace is not a second event, and it is gone.
    left!(pool, pid)
    refute_received {RunnerPool, ^pid, _}
  end

  test "every busy runner is offered a cancel_child", %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, a, _} = RunnerPool.take(pool, "ath_a", "exec_1")
    {:ok, b, _} = RunnerPool.take(pool, "ath_b", "exec_2")
    assert {:ok, _token} = assign(a)
    assert {:ok, _token} = assign(b)
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
    fresh = Enum.find(Runners.runners(pool), &(&1.state == :fresh))
    assert ScriptedKeeper.read(spawn_of(keeper, fresh.pid)) == ""
  end

  test "a line that is not a runner's frame taints the runner", %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)

    ScriptedKeeper.write(
      spawn,
      RunnerControl.encode(%{type: :cancel_child, execution_id: "exec_x"})
    )

    assert_receive {RunnerPool, ^pid, {:gone, {:protocol, {:not_a_runner_frame, :cancel_child}}}}
    left!(pool, pid)

    {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_2")
    ScriptedKeeper.write(spawn_of(keeper, pid), "not json\n")
    assert_receive {RunnerPool, ^pid, {:gone, {:protocol, :malformed}}}
  end

  test "a runner's control bytes are taken once handled, and its relay bytes once its relay read them",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
    assert {:ok, _token} = assign(pid)
    spawn = spawn_of(keeper, pid)
    before = ScriptedKeeper.takings(spawn)

    # The keeper reads the runner's next bytes only on these words.
    complete(spawn, "exec_1", true)
    wait_until(fn -> ScriptedKeeper.takings(spawn) == before + 1 end, 5_000, "the line taken")
    ScriptedKeeper.write_relay(spawn, <<2::32, "[]">>)

    wait_until(
      fn -> ScriptedKeeper.takings(spawn) == before + 2 end,
      5_000,
      "the relay's bytes taken"
    )
  end

  test "a runner whose relay closes is retired: the service tells it why and ends the stream", %{
    keeper: keeper
  } do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
    assert {:ok, _token} = assign(pid)
    spawn = spawn_of(keeper, pid)

    # A frame the codec refuses: the relay closes the channel.
    ScriptedKeeper.write_relay(spawn, <<2::32, "[]">>)

    assert_receive {RunnerPool, ^pid, {:gone, {:relay, {:shutdown, {:closed, :malformed}}}}},
                   5_000

    wait_until(fn -> ScriptedKeeper.relay_closed?(spawn) end)
    assert ScriptedKeeper.read_relay(spawn) =~ ~s("kind":"close")
    left!(pool, pid)
  end

  test "retiring the busy runners ends each at once and answers once they are gone, keeping the fresh and idle",
       %{keeper: keeper} do
    pool = start_pool!(keeper, retire_bound_ms: 100)
    serve!(pool)
    wait_until(fn -> counts(pool).fresh == 1 end)

    {:ok, idle, _} = RunnerPool.take(pool, "ath_a", "exec_idle")
    complete(spawn_of(keeper, idle), "exec_idle", true)
    assert_receive {RunnerPool, ^idle, {:complete, "exec_idle", true}}
    {:ok, a, a_id} = RunnerPool.take(pool, "ath_b", "exec_1")
    {:ok, b, b_id} = RunnerPool.take(pool, "ath_c", "exec_2")
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 1, busy: 2, tainted: 0} end)
    # Each released through its keeper: a runner taken while it still waits
    # for its place has its handle ended instead, and no release is asked.
    wait_until(fn -> Enum.all?(Map.values(:sys.get_state(pool).runners), & &1.placed) end)

    assert :ok = Runners.retire_busy(pool)

    assert counts(pool) == %{fresh: 1, idle: 1, busy: 0, tainted: 0}
    assert {a_id, 0} in ScriptedKeeper.releases(keeper)
    assert {b_id, 0} in ScriptedKeeper.releases(keeper)
    refute Enum.any?(Runners.runners(pool), &(&1.pid in [a, b]))
    assert_received {RunnerPool, ^a, {:gone, _}}
    assert_received {RunnerPool, ^b, {:gone, _}}

    # Nothing busy: answered at once.
    assert :ok = Runners.retire_busy(pool)

    # The bound's timers of runners retired in time change nothing. A
    # runner killed after them with a grace well past the bound is
    # retired by the keeper after that grace, so once it is gone their
    # timers have fired.
    {late_id, log} =
      with_log(fn ->
        {:ok, late, late_id} = RunnerPool.take(pool, "ath_d", "exec_3")
        assert :ok = RunnerPool.taint(pool, late, 400, "exec_3")
        wait_until(fn -> not Enum.any?(Runners.runners(pool), &(&1.pid == late)) end)
        late_id
      end)

    for id <- [a_id, b_id, late_id], do: refute(log =~ "runner #{id} #{@unretired}")
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 1, busy: 0, tainted: 0} end)
    assert Enum.count(ScriptedKeeper.releases(keeper), &match?({_, 0}, &1)) == 2
  end

  test "a busy runner its keeper has not retired is said so once at the retirement bound and held until it is",
       %{keeper: keeper} do
    pool = start_pool!(keeper, retire_bound_ms: 200)
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)

    never_retired(spawn, fn ->
      log =
        capture_log(fn ->
          assert :ok = RunnerPool.taint(pool, pid, 0, "exec_1")
          assert_receive {RunnerPool, ^pid, {:gone, :retire_bound}}, 5_000
          # Ten times the bound: the runner is still the pool's, and the
          # bound is not said again.
          assert_until_held(pool, pid, 2_000)
        end)

      assert length(String.split(log, "runner #{id} #{@unretired}")) == 2
      assert {id, 0} in ScriptedKeeper.releases(keeper)
      assert Process.alive?(pid)
      assert counts(pool) == %{fresh: 1, idle: 0, busy: 0, tainted: 1}
    end)

    # The keeper retires it: only then does it leave the pool.
    left!(pool, pid, 5_000)
    refute Process.alive?(pid)
    assert counts(pool) == %{fresh: 1, idle: 0, busy: 0, tainted: 0}
    assert :ok = Runners.retire_busy(pool, 5_000)
  end

  test "an idle runner its keeper has not retired at its TTL is held past the retirement bound until it is",
       %{keeper: keeper} do
    pool = start_pool!(keeper, idle_ttl_ms: 100, retire_bound_ms: 200)
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    spawn = spawn_of(keeper, pid)

    # Suspended before it completes, so the release at the TTL the
    # completion arms is never handled: the complete is the frame the
    # runner would write, handed to its handle as the runner hands one.
    never_retired(spawn, fn ->
      frame = RunnerControl.encode(%{type: :complete, execution_id: "exec_1", clean: true})
      send(spawn.owner, {ScriptedKeeper, spawn.ref, {:control, IO.iodata_to_binary(frame)}})
      assert_receive {RunnerPool, ^pid, {:complete, "exec_1", true}}

      log =
        capture_log(fn ->
          wait_until(fn -> ScriptedKeeper.releases(keeper) == [{id, 0}] end, 5_000)
          assert_until_held(pool, pid, 2_000)
        end)

      assert log =~ "runner #{id} #{@unretired}"
      assert Process.alive?(pid)
      refute_received {RunnerPool, ^pid, {:gone, _}}
      # Held, it is counted among the runners being ended.
      assert counts(pool) == %{fresh: 1, idle: 0, busy: 0, tainted: 1}
    end)

    left!(pool, pid, 5_000)
    refute Process.alive?(pid)
  end

  test "a runner whose handle dies is held, tainted, until its keeper's release reaches the pool as its heir",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    wait_until(fn -> counts(pool).fresh == 1 end)
    [%{pid: pid, id: id}] = Runners.runners(pool)
    spawn = spawn_of(keeper, pid)

    never_retired(spawn, fn ->
      log =
        capture_log(fn ->
          Process.exit(pid, :kill)
          wait_until(fn -> counts(pool).tainted == 1 end, 5_000, "the runner to be held tainted")
          # A runner is spawned ahead in its stead, and the dead one's stays
          # the pool's while the keeper holds it.
          wait_until(fn -> counts(pool) == %{fresh: 1, idle: 0, busy: 0, tainted: 1} end)
          assert_until_held(pool, pid, 1_000)
        end)

      assert log =~ "runner #{id}"
      assert [%{heir: {^pool, _tag}}] = for(s <- spawns(keeper), s.owner == pid, do: s.spec)
    end)

    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 0, busy: 0, tainted: 0} end, 5_000)
    refute Enum.any?(Runners.runners(pool), &(&1.pid == pid))
  end

  test "a runner whose handle dies while its place awaits the keeper is forgotten once the keeper says none of it started",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    :ok = ScriptedKeeper.placing(keeper, :held)
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    wait_until(fn -> hd(ScriptedKeeper.held_places(keeper)) == id end)

    capture_log(fn ->
      Process.exit(pid, :kill)
      assert_receive {RunnerPool, ^pid, {:gone, {:handle_down, :killed}}}
      left!(pool, pid, 5_000)
    end)

    # The runner spawned ahead in its stead waits for its place too.
    assert counts(pool) == %{fresh: 1, idle: 0, busy: 0, tainted: 0}
    assert spawns(keeper) == []
  end

  test "a runner tainted while its place awaits the keeper's room gives the place up at once and is never said unretired",
       %{keeper: keeper} do
    pool = start_pool!(keeper, retire_bound_ms: 100)
    :ok = ScriptedKeeper.placing(keeper, :held)
    serve!(pool)
    {:ok, pid, id} = RunnerPool.take(pool, "ath_a", "exec_1")
    wait_until(fn -> hd(ScriptedKeeper.held_places(keeper)) == id end)

    log =
      capture_log(fn ->
        assert :ok = RunnerPool.taint(pool, pid, 0, "exec_1")

        wait_until(
          fn -> id not in ScriptedKeeper.held_places(keeper) end,
          2_000,
          "the place to leave the keeper's queue"
        )

        left!(pool, pid, 5_000)
      end)

    refute log =~ "runner #{id} #{@unretired}"
    refute log =~ "runner #{id}'s handle ended"
    assert spawns(keeper) == []
  end

  test "a runner whose spawn went unanswered, the spawn made, is held until its keeper's release",
       %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    :ok = ScriptedKeeper.spawning(keeper, :held)
    serve!(pool)
    [%{owner: pid} = spawn] = wait_for_spawns(keeper, 1)
    # Only this spawn goes unanswered: the runner spawned ahead in its
    # stead waits for its place.
    :ok = ScriptedKeeper.placing(keeper, :held)
    :ok = ScriptedKeeper.spawning(keeper, :answered)
    {:ok, ^pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")

    never_retired(spawn, fn ->
      capture_log(fn ->
        assert_receive {RunnerPool, ^pid, {:gone, _unanswered}}, 10_000
        wait_until(fn -> counts(pool).tainted == 1 end, 5_000, "the runner to be held")
        assert_until_held(pool, pid, 1_000)
      end)
    end)

    wait_until(
      fn -> not Enum.any?(Runners.runners(pool), &(&1.pid == pid)) end,
      5_000,
      "the runner to leave once released"
    )

    assert counts(pool).tainted == 0
  end

  describe "a keeper that refuses runners" do
    test "a start after the keeper freed its uids is given its runner once it attaches, though the pool's last spawn was refused",
         %{keeper: keeper} do
      :ok = ScriptedKeeper.refuse(keeper, :capacity)
      pool = start_pool!(keeper, [])
      serve!(pool)
      wait_until(fn -> RunnerPool.status(pool).refusal != nil end)

      # The keeper has room again; the pool has not tried since.
      :ok = ScriptedKeeper.refuse(keeper, nil)
      assert {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
      spawn_of(keeper, pid)
      wait_until(fn -> counts(pool).busy == 1 end)
      refute_received {RunnerPool, ^pid, {:gone, _}}
    end

    test "a start during a lasting lack is refused with its own spawn's reason, not the one remembered, and leaves no run",
         %{keeper: keeper} do
      :ok = ScriptedKeeper.refuse(keeper, :capacity)
      pool = start_pool!(keeper, [])
      serve!(pool)
      wait_until(fn -> RunnerPool.status(pool).refusal != nil end)

      :ok = ScriptedKeeper.refuse(keeper, :memory_unavailable)

      assert {:error, {:refused, %{reason: "memory_unavailable"}}} =
               RunnerPool.take(pool, "ath_a", "exec_1")

      refute_received {RunnerPool, _pid, _event}
      assert counts(pool) == %{fresh: 0, idle: 0, busy: 0, tainted: 0}
    end

    test "a start after a release ends the refusal answers at once, its runner still spawning",
         %{keeper: keeper} do
      pool = start_pool!(keeper, [])
      serve!(pool)
      wait_until(fn -> match?([%{state: :fresh}], Runners.runners(pool)) end)
      :ok = ScriptedKeeper.refuse(keeper, :capacity)
      {:ok, busy, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
      wait_until(fn -> RunnerPool.status(pool).refusal != nil end)

      # The release ends the refusal; the runner the pool then spawns
      # never attaches, its place left unanswered.
      :ok = ScriptedKeeper.refuse(keeper, nil)
      :ok = ScriptedKeeper.placing(keeper, :held)
      :ok = ScriptedKeeper.exit(spawn_of(keeper, busy), 0)
      wait_until(fn -> RunnerPool.status(pool).refusal == nil end, 2_000)

      asked = System.monotonic_time(:millisecond)
      assert {:ok, _pid, _id} = RunnerPool.take(pool, "ath_b", "exec_2")
      assert System.monotonic_time(:millisecond) - asked < 1_000
    end

    test "a backoff a release cut short leaves no timer behind to spawn early",
         %{keeper: keeper} do
      pool = start_pool!(keeper, [])
      serve!(pool)
      wait_until(fn -> match?([%{state: :fresh}], Runners.runners(pool)) end)

      # The runner spawned behind the one taken is refused: the pool waits a
      # second before it tries again.
      :ok = ScriptedKeeper.refuse(keeper, :capacity)
      {:ok, busy, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
      wait_until(fn -> ScriptedKeeper.refused(keeper) == 1 end)
      # sleep-ok: the release lands inside the pending wait, which no event marks.
      Process.sleep(600)

      # The release ends the refusal; the spawn ahead it makes is refused, and
      # a new wait of a second starts.
      :ok = ScriptedKeeper.exit(spawn_of(keeper, busy), 0)
      wait_until(fn -> ScriptedKeeper.refused(keeper) == 2 end, 2_000)

      # The first wait's instant passes, and it spawns nothing.
      # sleep-ok: an instant at which nothing must happen, which no event marks.
      Process.sleep(700)
      assert ScriptedKeeper.refused(keeper) == 2
      wait_until(fn -> ScriptedKeeper.refused(keeper) == 3 end, 3_000, "the new wait to end")
    end

    test "a release ends the pool's refusal, and it spawns ahead at once, before its wait",
         %{keeper: keeper} do
      pool = start_pool!(keeper, [])
      serve!(pool)
      # Attached, not still spawning, so the refusals below never meet it.
      wait_until(fn -> match?([%{state: :fresh}], Runners.runners(pool)) end)

      # The runner spawned behind the one taken is refused, and so is each
      # try after it, until the pool's wait is seconds long.
      :ok = ScriptedKeeper.refuse(keeper, :capacity)
      {:ok, busy, _id} = RunnerPool.take(pool, "ath_a", "exec_1")

      wait_until(
        fn -> ScriptedKeeper.refused(keeper) >= 3 end,
        10_000,
        "the pool to try three times"
      )

      # The keeper has room once the busy runner is released.
      :ok = ScriptedKeeper.refuse(keeper, nil)
      before = length(spawns(keeper))
      :ok = ScriptedKeeper.exit(spawn_of(keeper, busy), 0)

      wait_until(
        fn -> length(spawns(keeper)) > before end,
        2_000,
        "the pool to spawn ahead on the release"
      )

      wait_until(fn -> RunnerPool.status(pool).refusal == nil end, 2_000)
    end

    test "starts in a row during a lasting refusal are refused, holding one refused runner each, none once released",
         %{keeper: keeper} do
      :ok = ScriptedKeeper.refuse(keeper, {:made, :exec_failed})
      pool = start_pool!(keeper, [])
      serve!(pool)
      wait_until(fn -> RunnerPool.status(pool).refusal != nil end)

      for n <- 1..4 do
        assert {:error, {:refused, %{reason: "exec_failed"}}} =
                 RunnerPool.take(pool, "ath_a", "exec_#{n}")
      end

      # Each start holds one runner the keeper made and refused, beside the
      # pool's own first one, and no run.
      wait_until(fn -> counts(pool).tainted == 5 end)
      assert ScriptedKeeper.refused(keeper) == 5
      refute_received {RunnerPool, _pid, _event}

      :ok = ScriptedKeeper.release_made(keeper)

      wait_until(
        fn -> counts(pool).tainted == 0 end,
        5_000,
        "every refused runner to leave once released"
      )
    end

    test "leaves no runner in the pool, which backs off and reports the keeper's account",
         %{keeper: keeper} do
      :ok = ScriptedKeeper.refuse(keeper, :memory_unavailable)
      pool = start_pool!(keeper, keeper_opts: [memory_bytes: 402_653_184])
      started = System.monotonic_time(:millisecond)
      serve!(pool)

      # The keeper counts a refusal as it answers a spawn, and the pool
      # hears of it through the runner's handle after that, so the pool is
      # read once it has heard of the floor's: then, and until the wait it
      # starts has run out, it holds no runner. Its bound is what the keeper
      # placed the refused runner with.
      assert %{
               runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0},
               memory_bytes: 402_653_184,
               refusal: %{reason: "memory_unavailable", message: message}
             } = emptied!(pool, keeper, 1)

      assert message =~ "refuses"

      # The runner the pool tries again is no runner it holds: held at the
      # keeper while it spawns, it is counted nowhere.
      :ok = :sys.suspend(keeper)

      wait_until(
        fn -> Enum.any?(Runners.runners(pool), &(&1.state == :spawning)) end,
        3_000,
        "the pool to try a runner again"
      )

      assert %{runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0}, refusal: %{}} =
               RunnerPool.status(pool)

      :ok = :sys.resume(keeper)

      # One runner is tried again at a time, the wait doubling from a
      # second. A wait starts once the pool has heard of the refusal
      # before it, after the keeper counted that refusal, so each is
      # measured from a reading taken before the count it follows moved
      # to one taken after the count it ends moved: never shorter than
      # the wait, and a second or so if the wait did not double.
      {before_first, first_retry} = refused_at(keeper, 2, started, 3_000)
      assert first_retry - started >= 900

      {_before_second, second_retry} = refused_at(keeper, 3, first_retry, 4_000)
      assert second_retry - before_first >= 1_900

      assert %{runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0}} = emptied!(pool, keeper, 3)

      # The keeper starts runners again: the next one tried ends the refusal
      # and the pool fills.
      :ok = ScriptedKeeper.refuse(keeper, nil)
      wait_until(fn -> counts(pool).fresh == 1 end, 10_000)
      assert %{refusal: nil} = RunnerPool.status(pool)
      assert {:ok, _pid, _id} = RunnerPool.take(pool, "ath_a", "exec_2")
    end

    test "a runner taken while spawning and then refused is gone for its assignee, never tainted",
         %{keeper: keeper} do
      :ok = ScriptedKeeper.refuse(keeper, :memory_unavailable)
      pool = start_pool!(keeper, [])
      # The floor's runner is still spawning, the keeper held, as it is
      # taken.
      :ok = :sys.suspend(keeper)
      serve!(pool)

      {:ok, pid, _id} = RunnerPool.take(pool, "ath_a", "exec_1")
      :ok = :sys.resume(keeper)
      # Its assignee hears the keeper's own code and sentence for it.
      assert_receive {RunnerPool, ^pid,
                      {:gone,
                       {:refused,
                        %{
                          reason: "memory_unavailable",
                          message: "the scripted keeper refuses (memory_unavailable)"
                        }}}}

      assert counts(pool) == %{fresh: 0, idle: 0, busy: 0, tainted: 0}
      assert Runners.runners(pool) == []

      # The next start asks the keeper again and waits for its answer, the
      # refusal of its own spawn.
      assert {:error, {:refused, %{reason: "memory_unavailable"}}} =
               RunnerPool.take(pool, "ath_a", "exec_2")
    end

    test "a runner refused after the keeper made it keeps its place among the runners ahead until the keeper's release: none is started in its stead, and a take goes to another",
         %{keeper: keeper} do
      pool = start_pool!(keeper, [])
      serve!(pool)
      # Attached, not still spawning, so the keeper's refusals below are
      # never ended by its start.
      wait_until(fn -> match?([%{state: :fresh}], Runners.runners(pool)) end)

      # The runner spawned behind the one taken is refused once the keeper
      # made it, its place still the keeper's.
      :ok = ScriptedKeeper.refuse(keeper, {:made, :exec_failed})
      {:ok, first, first_id} = RunnerPool.take(pool, "ath_a", "exec_1")
      wait_until(fn -> RunnerPool.status(pool).refusal != nil end)
      [held_id] = Map.keys(ScriptedKeeper.places(keeper)) -- [first_id]

      # The keeper would start a runner now, and the pool's wait after the
      # refusal runs out: the held runner's place is not the pool's to fill.
      :ok = ScriptedKeeper.refuse(keeper, nil)

      wait_until(
        fn -> :sys.get_state(pool).refill_scheduled == false end,
        5_000,
        "the pool's wait after the refusal to run out"
      )

      assert %{
               runners: Enum.sort(for r <- Runners.runners(pool), do: {r.id, r.state}),
               spawned: length(spawns(keeper))
             } == %{runners: Enum.sort([{first_id, :busy}, {held_id, :refused}]), spawned: 1}

      # The held runner is counted, among the runners being ended.
      assert counts(pool) == %{fresh: 0, idle: 0, busy: 1, tainted: 1}

      complete(spawn_of(keeper, first), "exec_1", true)
      assert_receive {RunnerPool, ^first, {:complete, "exec_1", true}}
      assert {:ok, ^first, ^first_id} = RunnerPool.take(pool, "ath_a", "exec_2")

      # A start no fresh or idle runner serves asks the keeper, which starts
      # runners again: it is given one, the pool's refusal notwithstanding.
      assert {:ok, third, _id} = RunnerPool.take(pool, "ath_b", "exec_3")
      spawn_of(keeper, third)
      refute_received {RunnerPool, ^third, {:gone, _}}

      # The keeper's release frees the place, and the pool fills it.
      :ok = ScriptedKeeper.release_made(keeper)
      wait_until(fn -> counts(pool).fresh == 1 end, 5_000)
      refute Enum.any?(Runners.runners(pool), &(&1.id == held_id))
      assert %{refusal: nil} = RunnerPool.status(pool)
    end
  end

  test "the keeper's loss ends every runner, the busy ones reported gone", %{keeper: keeper} do
    pool = start_pool!(keeper, [])
    serve!(pool)
    {:ok, busy, _} = RunnerPool.take(pool, "ath_a", "exec_1")
    wait_until(fn -> counts(pool) == %{fresh: 1, idle: 0, busy: 1, tainted: 0} end)
    # The keeper tells its loss to the spawns it has recorded.
    spawn_of(keeper, busy)

    ScriptedKeeper.kill!(keeper)

    # The pool tells the assignee as it takes the runner out of its busy
    # ones.
    wait_until(fn -> counts(pool).busy == 0 end)
    assert_received {RunnerPool, ^busy, {:gone, :channel_lost}}
    refute_receive {RunnerPool, _, {:gone, _}}, 100
  end
end
