# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WriteTurnTest do
  @moduledoc """
  The order `Arca.WriteTurn` issues turns in, on arbiters of the case's
  own: one at a time in the order asked, a waiting control-plane request
  next, nothing revoked, every exit and every surrender given back, the
  audit queue's fixed capacity, and what a new generation keeps and asks
  again.

  Each writer here is a process of the case's that asks, reports what it
  was answered, and holds its turn until told to give it back.
  """

  use ExUnit.Case, async: true

  alias Arca.WriteTurn

  setup do
    name = :"write_turn_#{System.unique_integer([:positive])}"
    start_supervised!({WriteTurn, name: name, capacity: 3})
    {:ok, server: name}
  end

  describe "the order" do
    test "one turn at a time, in the order asked", %{server: server} do
      a = writer(server, :a, :audit)
      assert_receive {:issued, :a, _}
      b = writer(server, :b, :audit)
      await_waiting(server, audit: 1)
      c = writer(server, :c, :audit)
      await_waiting(server, audit: 2)

      refute_received {:issued, _, _}
      release(a, :a)
      assert_receive {:issued, :b, _}
      refute_received {:issued, :c, _}
      release(b, :b)
      assert_receive {:issued, :c, _}
      release(c, :c)
      await_status(server, &(&1.holder == nil and &1.waiting == %{audit: 0, control_plane: 0}))
    end

    test "a waiting control-plane request is issued the next turn, ahead of every queued " <>
           "audit request",
         %{server: server} do
      a = writer(server, :a, :audit)
      assert_receive {:issued, :a, _}
      # b asks before c does: the arbiter issues in the order asked, so c is
      # started only once b is queued.
      writer(server, :b, :audit)
      await_waiting(server, audit: 1)
      writer(server, :c, :audit)
      await_waiting(server, audit: 2)
      renewal = writer(server, :renewal, :control_plane)
      await_waiting(server, audit: 2, control_plane: 1)

      release(a, :a)
      assert_receive {:issued, :renewal, _}
      refute_received {:issued, :b, _}
      release(renewal, :renewal)
      assert_receive {:issued, :b, _}
    end

    test "a turn issued is never revoked: a control-plane request waits for its release", %{
      server: server
    } do
      a = writer(server, :a, :audit)
      assert_receive {:issued, :a, _}
      writer(server, :renewal, :control_plane)
      await_waiting(server, control_plane: 1)

      refute_receive {:issued, :renewal, _}, 100
      assert %{holder: %{kind: :audit, pid: ^a}} = WriteTurn.status(server)
      release(a, :a)
      assert_receive {:issued, :renewal, _}
    end

    test "a process holding a turn is answered it again, and gives it back once", %{
      server: server
    } do
      deadline = System.monotonic_time(:millisecond) + 1_000
      assert {:ok, turn} = WriteTurn.acquire(:audit, deadline, server)
      assert {:ok, ^turn} = WriteTurn.acquire(:control_plane, deadline, server)
      assert WriteTurn.holding?()

      assert :ok = WriteTurn.release()
      refute WriteTurn.holding?()
      assert :ok = WriteTurn.release()
      await_status(server, &(&1.holder == nil))
    end
  end

  describe "a holder or a waiter that stops" do
    test "a holder's exit frees its turn, and a waiter's exit drops its request", %{
      server: server
    } do
      a = writer(server, :a, :audit)
      assert_receive {:issued, :a, _}
      b = writer(server, :b, :audit)
      writer(server, :c, :audit)
      await_waiting(server, audit: 2)

      Process.exit(b, :kill)
      await_waiting(server, audit: 1)
      Process.exit(a, :kill)
      assert_receive {:issued, :c, _}
    end

    test "a waiter that gives up cancels its request", %{server: server} do
      a = writer(server, :a, :audit)
      assert_receive {:issued, :a, _}
      writer(server, :b, :audit, 100)
      assert_receive {:timeout, :b}, 1_000
      await_waiting(server, audit: 0)

      release(a, :a)
      await_status(server, &(&1.holder == nil))
    end

    test "a turn issued as its waiter gave up comes back at once, and goes to a renewal first",
         %{server: server} do
      holder = writer(server, :holder, :audit)
      assert_receive {:issued, :holder, _}
      # The late waiter asks first, so it heads the audit queue.
      writer(server, :late, :audit, 1_000)
      await_waiting(server, audit: 1)
      writer(server, :audit, :audit)
      await_waiting(server, audit: 2)

      # The arbiter is held while three requests queue, each seen arriving
      # before the next is sent: the holder's release, a renewal's request
      # and the late waiter's cancel. So it issues the late waiter the turn
      # before it hears the renewal, and hears the cancel once the renewal
      # is waiting.
      :ok = :sys.suspend(server)
      send(holder, :release)
      assert_receive {:released, :holder}
      await_queued(server, [:release])
      writer(server, :renewal, :control_plane)
      await_queued(server, [:release, :ask])
      assert_receive {:timeout, :late}, 5_000
      await_queued(server, [:release, :ask, :cancel])
      :ok = :sys.resume(server)

      assert_receive {:issued, :renewal, _}
      refute_received {:issued, :late, _}
      refute_received {:issued, :audit, _}
      assert %{holder: %{kind: :control_plane}, waiting: %{audit: 1}} = WriteTurn.status(server)
    end
  end

  describe "the audit queue's capacity" do
    test "an audit request past it is refused at once; control-plane requests are not counted",
         %{server: server} do
      writer(server, :holder, :audit)
      assert_receive {:issued, :holder, _}
      for tag <- [:w1, :w2, :w3], do: writer(server, tag, :audit)
      await_waiting(server, audit: 3)

      writer(server, :over, :audit)
      assert_receive {:capacity, :over}, 1_000

      writer(server, :renewal, :control_plane)
      await_waiting(server, audit: 3, control_plane: 1)
    end

    test "the node's arbiter holds as many audit requests as the decision log has writers" do
      assert WriteTurn.status().capacity == Arca.DecisionLog.max_writers()
    end
  end

  describe "generations" do
    test "waiters ask a new generation within their deadlines; an old release frees nothing" do
      name = :"write_turn_bare_#{System.unique_integer([:positive])}"
      {:ok, first} = GenServer.start(WriteTurn, 3, name: name)
      on_exit(fn -> Process.exit(first, :kill) end)
      %{generation: g1} = WriteTurn.status(name)
      holder = writer(name, :holder, :audit)
      assert_receive {:issued, :holder, ^g1}

      # The next generation, under no name yet, with a turn of the case's
      # own already issued, so every waiter that asks it waits.
      {:ok, second} = GenServer.start(WriteTurn, 3)
      on_exit(fn -> Process.exit(second, :kill) end)
      %{generation: g2} = WriteTurn.status(second)
      current = writer(second, :current, :audit)
      assert_receive {:issued, :current, ^g2}
      assert g2 > g1

      asked = System.monotonic_time(:millisecond)
      writer(name, :short, :audit, 300)
      writer(name, :long, :audit, 1_500)
      await_waiting(name, audit: 2)

      # No generation runs until the short waiter has given up at its own
      # deadline; the long one keeps looking for the next.
      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first, _reason}
      assert_receive {:timeout, :short}, 2_000
      assert System.monotonic_time(:millisecond) - asked >= 300

      true = Process.register(second, name)
      registered = System.monotonic_time(:millisecond)
      await_waiting(name, audit: 1)
      recovered = System.monotonic_time(:millisecond) - registered

      # The first generation's holder still holds what it was issued; its
      # release names that generation and frees nothing of this one.
      release(holder, :holder)
      assert %{holder: %{pid: ^current}, generation: ^g2} = WriteTurn.status(name)

      # The long waiter gives up at the deadline it first asked with, never
      # at one counted again from its request to the second generation.
      assert_receive {:timeout, :long}, 3_000
      gave_up = System.monotonic_time(:millisecond)
      assert gave_up - asked >= 1_500
      assert gave_up < registered + 1_500

      IO.puts("write turn: a waiter asked a new generation #{recovered} ms after it started")
    end

    # Every waiter asks each new generation, and a renewal waiting there is
    # issued the next turn.
    test "killed while a turn is held and others are requested, then killed again",
         %{server: server} do
      writer(server, :holder, :audit)
      assert_receive {:issued, :holder, first}
      writer(server, :a1, :audit, 10_000)
      writer(server, :a2, :audit, 10_000)
      writer(server, :renewal, :control_plane, 10_000)
      await_waiting(server, audit: 2, control_plane: 1)

      killed = System.monotonic_time(:millisecond)
      second = restart!(server, first)
      assert_receive {:issued, issued, ^second}, 1_000
      recovered = System.monotonic_time(:millisecond) - killed
      renewal_next(server, issued, second, [:a1, :a2])

      # Killed again with the renewal holding its turn: it keeps it, and
      # the audit writers still waiting ask the third generation.
      third = restart!(server, second)
      assert third > second
      assert_receive {:issued, _tag, ^third}, 1_000

      IO.puts(
        "write turn: a restarted arbiter issued its first turn #{recovered} ms after the kill"
      )
    end
  end

  # ---- writers ----------------------------------------------------------------

  # A process that asks for a turn of `kind` within `wait_ms`, reports the
  # answer to the case, and holds an issued turn until `:release`.
  defp writer(server, tag, kind, wait_ms \\ 5_000) do
    test = self()

    pid =
      spawn(fn ->
        deadline = System.monotonic_time(:millisecond) + wait_ms

        case WriteTurn.acquire(kind, deadline, server) do
          {:ok, {_server, _ref, generation}} ->
            send(test, {:issued, tag, generation})

            receive do
              :release ->
                WriteTurn.release()
                send(test, {:released, tag})
            end

          {:error, reason} ->
            send(test, {reason, tag})
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp release(pid, tag) do
    send(pid, :release)
    assert_receive {:released, ^tag}
  end

  defp await_waiting(server, counts) do
    want = Map.merge(%{audit: 0, control_plane: 0}, Map.new(counts))
    await_status(server, &(&1.waiting == want))
  end

  defp await_status(server, fun, tries \\ 400) do
    status = status(server)

    cond do
      status != nil and fun.(status) ->
        status

      tries == 0 ->
        flunk("the arbiter never reached the state asked for: #{inspect(status)}")

      true ->
        Process.sleep(5)
        await_status(server, fun, tries - 1)
    end
  end

  # A held arbiter's queued requests, in the order they arrived, reaching
  # `kinds`. The exits of the processes it monitors queue beside them and
  # are not requests.
  defp await_queued(server, kinds, tries \\ 400) do
    {:messages, messages} = Process.info(GenServer.whereis(server), :messages)
    queued = for {:"$gen_cast", request} <- messages, do: elem(request, 0)

    cond do
      queued == kinds ->
        :ok

      tries == 0 ->
        flunk("the held arbiter has #{inspect(queued)} queued, not #{inspect(kinds)}")

      true ->
        Process.sleep(5)
        await_queued(server, kinds, tries - 1)
    end
  end

  # The status, or nil between generations.
  defp status(server) do
    WriteTurn.status(server)
  catch
    :exit, _reason -> nil
  end

  # Kill the arbiter and wait for the supervisor's next generation.
  defp restart!(server, previous) do
    Process.exit(GenServer.whereis(server), :kill)
    %{generation: generation} = await_status(server, &(&1.generation != previous))
    generation
  end

  # Whoever the generation issued its first turn to, a renewal still
  # waiting behind it is issued the next, ahead of the audit writers.
  defp renewal_next(_server, :renewal, _generation, _audits), do: :ok

  defp renewal_next(server, first, generation, audits) do
    await_status(server, &(&1.waiting.control_plane == 1))
    %{holder: %{pid: pid}} = WriteTurn.status(server)
    send(pid, :release)
    assert_receive {:released, ^first}
    assert_receive {:issued, :renewal, ^generation}
    for tag <- audits -- [first], do: refute_received({:issued, ^tag, _})
  end
end

defmodule Arca.WriteTurnLockTest do
  @moduledoc """
  The node's arbiter against SQLite's real write lock, outside the
  sandbox and with the control plane on a pool of its own: a renewal that
  asks while an audit writer holds its turn goes next once that one
  transaction is over; a writer out of time waiting for a turn raises as
  it does waiting for the lock; a holder killed inside the driver while it
  holds the lock frees its turn at its exit, the driver cancels its native
  call and the renewal behind it succeeds within the lease; a live
  holder's native call outlasting the lease makes the renewal fail and the
  member admit nothing; the arbiter killed while a holder's native call
  runs and requests wait.

  How soon a renewal behind a killed holder landed, and how soon a new
  generation answered, are printed as they are measured. On PostgreSQL
  there is no turn: the writes go through with the arbiter held still.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.Schemas.CellLease
  alias Arca.WriteTurn
  alias Ecto.Adapters.SQL.Sandbox

  @sqlite? Arca.Repo.adapter() == Ecto.Adapters.SQLite3

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    pool = Application.get_env(:arca, :control_plane_pool)
    turn = Application.get_env(:arca, :write_turn)
    repo = Application.get_env(:arca, Arca.Repo)
    node = "node-turn-#{System.unique_integer([:positive])}"

    # Every process takes a real connection of its own, as a deployment's
    # does; the suite's mode is put back after.
    Sandbox.mode(Arca.Repo, :auto)

    on_exit(fn ->
      Application.put_env(:arca, Arca.Repo, repo)
      Application.put_env(:arca, :control_plane_pool, pool)
      Application.put_env(:arca, :write_turn, turn)
      run(fn -> Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node)) end)
      Sandbox.mode(Arca.Repo, :manual)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end
    end)

    # Outside the sandbox, the control plane on its own pool and the
    # writers taking turns, as a deployment's are.
    Application.put_env(:arca, :control_plane_pool, true)
    Application.put_env(:arca, :write_turn, true)
    start_supervised!(ControlPlane.pool_spec(pool: DBConnection.ConnectionPool))
    {:ok, node: node}
  end

  if @sqlite? do
    # After that one transaction, ahead of the audit writers queued before.
    test "an audit writer paused with its turn: a renewal asking then comes next",
         %{node: node} do
      {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
      test = self()

      holder =
        spawn_link(fn ->
          {:ok, _} = WriteTurn.acquire(:audit, System.monotonic_time(:millisecond) + 10_000)
          send(test, :issued)
          receive do: (:resume -> :ok)

          {:ok, _} =
            Arca.Repo.locking_transaction(
              fn -> Arca.Repo.query!(lock_statement(), [], log: false) end,
              write_turn: :audit
            )

          WriteTurn.release()
          send(test, {:released, System.monotonic_time(:millisecond)})
        end)

      assert_receive :issued
      # a1 asks before a2, so a1 is issued the turn after the renewal.
      waiter(:a1, :audit)
      await_waiting(audit: 1)
      waiter(:a2, :audit)
      await_waiting(audit: 2)

      renewal = Task.async(fn -> timed(fn -> ControlPlane.renew(60_000) end) end)
      await_waiting(audit: 2, control_plane: 1)

      # The audit writers hold what they are issued until told, so a
      # renewal answered at all was issued ahead of both of them; and it
      # waited for that one transaction and at most a lock quantum more.
      send(holder, :resume)
      assert_receive {:released, released}, 5_000
      assert {{:ok, _slot}, _ms, done} = Task.await(renewal, 10_000)
      assert done - released < 100, "the renewal came #{done - released} ms after"
      assert_receive {:issued, :a1}, 1_000
      refute_received {:issued, :a2}
    end

    test "a writer out of time waiting for a turn raises as for the lock; its request goes" do
      test = self()

      holder =
        spawn_link(fn ->
          {:ok, _} = WriteTurn.acquire(:audit, System.monotonic_time(:millisecond) + 10_000)
          send(test, :issued)
          receive do: (:release -> WriteTurn.release())
          send(test, :released)
        end)

      assert_receive :issued
      started = System.monotonic_time(:millisecond)

      raised =
        run(fn ->
          try do
            Arca.Repo.locking_transaction(fn -> :ok end,
              write_turn: :audit,
              timeout: 1_600,
              pool_deadline: started + 1_600
            )
          rescue
            e in Arca.Repo.BusyTimeoutError -> {:raised, e}
          end
        end)

      elapsed = System.monotonic_time(:millisecond) - started

      # It waited for its turn (a writer with no time left raises at once,
      # having waited 0 ms), and raised inside the pool deadline it was
      # given: the wait for the turn spent that deadline and did not start
      # the lock step's own busy timeout again.
      assert {:raised, %Arca.Repo.BusyTimeoutError{deadline_ms: waited}} = raised
      assert waited > 0
      assert elapsed < 1_600, "raised after #{elapsed} ms"
      await_waiting(audit: 0)

      send(holder, :release)
      assert_receive :released
    end

    # The holder holds the lock in a statement sized to outlast the lease.
    # Its exit frees its turn; the driver cancels its native call when the
    # pool disconnects its connection, the statement stops and its
    # transaction rolls back, and the connection is closed. A renewal asked
    # behind it is issued the turn ahead of the queued audit writer and
    # takes the lock before the member's own countdown runs out.
    test "a holder killed inside the driver: its native call is cancelled and a renewal " <>
           "behind it succeeds within the lease",
         %{node: node} do
      {:ok, _} = ControlPlane.take(node, "boot_a", 5_000)
      {:held, standing} = :persistent_term.get({Arca.ControlPlane, :standing})
      marker = -System.unique_integer([:positive])
      on_exit(fn -> delete_marker(marker) end)

      zombie = zombie!(long_statement(9_000), marker)
      monitor = Process.monitor(zombie)
      refute lock_free?()

      renewal = Task.async(fn -> timed(fn -> ControlPlane.renew(60_000) end) end)
      a1 = waiter(:a1, :audit)
      await_waiting(audit: 1, control_plane: 1)

      Process.exit(zombie, :kill)
      killed = System.monotonic_time(:millisecond)
      assert_receive {:DOWN, ^monitor, :process, ^zombie, :killed}
      # Its turn is freed at its exit, whatever its native call is doing.
      await(fn -> not match?(%{holder: %{pid: ^zombie}}, status()) end)

      # The audit writer holds what it is issued until told, so a renewal
      # answered at all was issued its turn ahead of it; and it took the
      # lock the dead holder's statement held, before the standing ran out.
      assert {{:ok, _slot}, _ms, renewed} = Task.await(renewal, 15_000)

      assert renewed < standing,
             "the renewal came #{renewed - standing} ms after the member's standing ran out"

      assert ControlPlane.held?()
      assert {:ok, _slot} = ControlPlane.member_slot()
      assert_receive {:issued, :a1}, 1_000
      send(a1, :release)

      # The connection's cleanup is its own event: the pool closes it once
      # the cancelled call has returned. The lock is free after it, and the
      # dead holder's transaction left nothing behind.
      assert_receive {:disconnected, _conn}, 10_000
      assert lock_free?()
      refute marker_written?(marker)

      IO.puts(
        "write turn: a renewal behind a holder killed inside a statement sized to outlast " <>
          "the lease landed #{renewed - killed} ms after the kill"
      )
    end

    # A live holder is never killed and the driver does not cancel a live
    # caller's call, so a native call outlasting the lease is still
    # possible, and it is what the lease guards: the renewal behind it runs
    # out of time, the member's own countdown lapses and it admits nothing,
    # and once the holder is done the slot it held is gone.
    test "a live holder's native call outlasting the lease: the renewal fails, nothing admitted",
         %{node: node} do
      {:ok, slot} = ControlPlane.take(node, "boot_a", 1_500)
      test = self()
      statement = long_statement(5_000)

      holder =
        spawn_link(fn ->
          {:ok, _} = WriteTurn.acquire(:audit, System.monotonic_time(:millisecond) + 10_000)

          Arca.Repo.checkout(fn ->
            Arca.Repo.query!("BEGIN IMMEDIATE", [], log: false)
            send(test, :holding)
            Arca.Repo.query!(statement, [], log: false, timeout: 30_000)
            Arca.Repo.query!("ROLLBACK", [], log: false)
          end)

          WriteTurn.release()
          send(test, :holder_released)
        end)

      assert_receive :holding, 5_000
      await(fn -> stepping?(holder) end)
      await(fn -> match?(%{holder: %{pid: ^holder}}, status()) end)
      refute lock_free?()

      # The renewal's lock step waits a second here, not the suite's ten,
      # and gives up only once that deadline has passed: it spends it
      # waiting for the turn the holder keeps.
      busy_timeout(1_000)
      assert {{:error, :database_error}, ms, _} = timed(fn -> ControlPlane.renew(1_500) end)
      busy_timeout(:restore)
      assert ms >= 1_000

      # It ran out behind a call still running for a holder still alive.
      assert Process.alive?(holder)
      assert stepping?(holder)
      refute ControlPlane.held?()
      assert {:error, :not_owner} = ControlPlane.member_slot()

      assert_receive :holder_released, 15_000
      assert lock_free?()
      assert :lost = run(fn -> ControlPlane.check_held(slot) end)
      refute ControlPlane.held?()
    end

    # The holder keeps its turn past its own deadline, the waiters ask each
    # new generation, and an expired lease refuses protected work until the
    # renewal lands.
    test "the arbiter killed twice while a holder's native call runs and requests wait",
         %{node: node} do
      {:ok, _} = ControlPlane.take(node, "boot_a", 2_000)
      test = self()
      first = WriteTurn.status().generation

      # An audit writer of the first generation, in a native call holding
      # the lock well past its own deadline.
      holder =
        spawn_link(fn ->
          deadline = System.monotonic_time(:millisecond) + 500
          {:ok, _} = WriteTurn.acquire(:audit, deadline)

          Arca.Repo.checkout(fn ->
            Arca.Repo.query!("BEGIN IMMEDIATE", [], log: false)
            send(test, :holding)
            Arca.Repo.query!(long_statement(3_000), [], log: false, timeout: 30_000)
            send(test, {:native_done, System.monotonic_time(:millisecond), deadline})
            Arca.Repo.query!("ROLLBACK", [], log: false)
          end)

          WriteTurn.release()
          send(test, :holder_released)
        end)

      assert_receive :holding, 5_000
      waiter(:a1, :audit, 10_000)
      # A lease long enough to outlast the renewal's own wait: the countdown
      # it publishes is counted from before that wait.
      renewal = Task.async(fn -> timed(fn -> ControlPlane.renew(60_000) end) end)
      await_waiting(audit: 1, control_plane: 1)

      killed = System.monotonic_time(:millisecond)
      second = restart!(first)
      recovered = System.monotonic_time(:millisecond) - killed
      await(fn -> requests(status()) == 2 end)

      third = restart!(second)
      assert third > second
      await(fn -> requests(status()) >= 1 end)

      # The lease's countdown runs out while the holder's native call keeps
      # the lock: the member admits nothing, though its renewal is asked.
      await(fn -> not ControlPlane.held?() end, 3_000)
      assert {:error, :not_owner} = ControlPlane.member_slot()
      assert Task.yield(renewal, 0) == nil

      assert_receive {:native_done, native_done, holder_deadline}, 10_000
      assert native_done > holder_deadline
      assert_receive :holder_released, 5_000
      assert {{:ok, _slot}, _ms, renewed} = Task.await(renewal, 15_000)
      assert renewed >= native_done
      assert ControlPlane.held?()
      assert {:ok, _slot} = ControlPlane.member_slot()
      assert is_pid(holder)

      IO.puts(
        "write turn: a restarted arbiter answered #{recovered} ms after its predecessor was killed"
      )
    end

    # ---- SQLite helpers -----------------------------------------------------------

    defp timed(fun) do
      started = System.monotonic_time(:millisecond)
      result = fun.()
      done = System.monotonic_time(:millisecond)
      {result, done - started, done}
    end

    # A process that asks for a turn of `kind` and, issued, reports it and
    # holds it until `:release`.
    defp waiter(tag, kind, wait_ms \\ 5_000) do
      test = self()

      pid =
        spawn(fn ->
          case WriteTurn.acquire(kind, System.monotonic_time(:millisecond) + wait_ms) do
            {:ok, _turn} ->
              send(test, {:issued, tag})
              receive do: (:release -> WriteTurn.release())

            {:error, reason} ->
              send(test, {reason, tag})
          end
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    defp requests(nil), do: 0

    defp requests(%{holder: holder, waiting: waiting}),
      do: if(holder, do: 1, else: 0) + waiting.audit + waiting.control_plane

    defp await_waiting(counts) do
      want = Map.merge(%{audit: 0, control_plane: 0}, Map.new(counts))
      await(fn -> match?(%{waiting: ^want}, status()) end)
    end

    defp restart!(previous) do
      Process.exit(Process.whereis(WriteTurn), :kill)
      await(fn -> match?(%{generation: g} when g != previous, status()) end)
      status().generation
    end

    # The lock step's deadline is read from the configuration at each
    # transaction; the renewal that must run out of time gets a short one.
    defp busy_timeout(:restore) do
      Application.put_env(:arca, Arca.Repo, Process.delete(:repo_config))
    end

    defp busy_timeout(ms) do
      config = Application.get_env(:arca, Arca.Repo)
      Process.put(:repo_config, config)
      Application.put_env(:arca, Arca.Repo, Keyword.put(config, :busy_timeout, ms))
    end

    defp database, do: Arca.Repo.config()[:database]

    # A holder issued an audit turn whose connection, the one of a pool this
    # case watches, holds SQLite's write lock with `marker` written in its
    # transaction and is inside the driver running `statement`: one native
    # call, so a kill lands inside it. The pool reports its connection's
    # disconnect.
    defp zombie!(statement, marker) do
      name = :"zombie_#{System.unique_integer([:positive])}"
      test = self()

      start_supervised!(
        Supervisor.child_spec(
          {Arca.Repo,
           name: name,
           pool_size: 1,
           pool: DBConnection.ConnectionPool,
           connection_listeners: [test]},
          id: name
        )
      )

      assert_receive {:connected, _conn}, 5_000

      pid =
        spawn(fn ->
          Arca.Repo.put_dynamic_repo(name)
          {:ok, _} = WriteTurn.acquire(:audit, System.monotonic_time(:millisecond) + 60_000)

          Arca.Repo.checkout(
            fn ->
              Arca.Repo.query!("BEGIN IMMEDIATE", [], log: false)
              Arca.Repo.query!(insert_marker(marker), [], log: false)
              send(test, :stepping)
              Arca.Repo.query!(statement, [], log: false, timeout: :infinity)
            end,
            timeout: :infinity
          )
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)

      # The statement runs well past the case's own steps, so once it is
      # stepping inside the driver it stays there.
      assert_receive :stepping, 5_000
      await(fn -> stepping?(pid) end)
      await(fn -> match?(%{holder: %{pid: ^pid}}, status()) end)
      pid
    end

    # Inside the driver running a statement: stepping it, not preparing it.
    defp stepping?(pid) do
      case Process.info(pid, :current_function) do
        {:current_function, {Exqlite.Sqlite3NIF, step, _arity}} -> step in [:step, :multi_step]
        _elsewhere -> false
      end
    end

    defp lock_statement, do: ~s(UPDATE "schema_migrations" SET version = version WHERE 0)

    # A write that takes the lock when it starts and then runs for about
    # `ms`: a recursive count that inserts nothing, sized from a measured
    # one.
    defp long_statement(ms) do
      rows = max(ms * rows_per_ms(), 1_000)

      "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < #{rows}) " <>
        ~s|INSERT INTO "schema_migrations" (version) SELECT x FROM c WHERE x < 0|
    end

    defp rows_per_ms do
      {:ok, conn} = Exqlite.Sqlite3.open(database())

      {us, :ok} =
        :timer.tc(fn ->
          Exqlite.Sqlite3.execute(
            conn,
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 500000) " <>
              "SELECT count(*) FROM c WHERE x < 0"
          )
        end)

      :ok = Exqlite.Sqlite3.close(conn)
      max(div(500_000 * 1_000, max(us, 1)), 1)
    end

    # Whether a connection outside every pool of the repo takes SQLite's
    # write lock at once; it gives the lock straight back.
    defp lock_free? do
      {:ok, probe} = Exqlite.Sqlite3.open(database())

      try do
        :ok = Exqlite.Sqlite3.execute(probe, "PRAGMA busy_timeout = 0")

        case Exqlite.Sqlite3.execute(probe, "BEGIN IMMEDIATE") do
          :ok ->
            :ok = Exqlite.Sqlite3.execute(probe, "ROLLBACK")
            true

          {:error, "database is locked"} ->
            false
        end
      after
        Exqlite.Sqlite3.close(probe)
      end
    end

    # A migration row no migration writes: the dead holder's own write.
    defp insert_marker(marker),
      do: ~s|INSERT INTO "schema_migrations" (version) VALUES (#{marker})|

    defp marker_written?(marker) do
      run(fn ->
        Arca.Repo.exists?(from(m in "schema_migrations", where: m.version == ^marker))
      end)
    end

    defp delete_marker(marker) do
      run(fn ->
        Arca.Repo.delete_all(from(m in "schema_migrations", where: m.version == ^marker))
      end)
    end
  else
    test "PostgreSQL asks for no turn: the writes go through with the arbiter held still",
         %{node: node} do
      call_id = "call_turnless_#{System.unique_integer([:positive])}"
      :ok = :sys.suspend(WriteTurn)

      try do
        assert {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
        assert {:ok, _} = ControlPlane.renew(60_000)

        decision =
          Prima.Decision.new(
            call_id: call_id,
            plane: :external,
            admission: :admitted,
            tool: "t",
            action: "a",
            inserted_at: DateTime.utc_now()
          )

        assert :ok =
                 run(fn -> Arca.DecisionLog.append(Prima.Actor.in_athanor("ath_t"), decision) end)
      after
        :sys.resume(WriteTurn)

        run(fn ->
          Arca.Repo.delete_all(from(r in "decision_logs", where: r.call_id == ^call_id))
        end)
      end

      await(fn -> status() != nil end)
    end
  end

  # ---- helpers ------------------------------------------------------------------

  defp run(fun), do: fun |> Task.async() |> Task.await(:infinity)

  # The node's arbiter as it stands, or nil between generations.
  defp status do
    WriteTurn.status()
  catch
    :exit, _reason -> nil
  end

  defp await(fun, within_ms \\ 2_000),
    do: await_until(fun, System.monotonic_time(:millisecond) + within_ms)

  defp await_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the condition never held: #{inspect(status())}")

      true ->
        Process.sleep(5)
        await_until(fun, deadline)
    end
  end
end
