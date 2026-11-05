# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.OwnersTest do
  @moduledoc """
  The owner table: the version rules of a sync, table-driven, a sync
  starting nothing; the uid pool claimed at a scratch open, `capacity` and
  `unavailable` told apart, a pool read that never answers refused within
  its bound while the table answers, a uid freed once; sessions opened,
  attached by their key and started again after their process ended; the
  shapes an open must have; the open's arguments appended as the
  command's own; a crash's backoff and a program failed until a new
  version; the bound on sessions, the oldest ended one forgotten; idleness
  and leases through a driven sweep; kept homes shared by the sessions of
  one entry, held to their bound, reset and retired; renew, release,
  reconcile and status. Sessions run through the test environment's
  `Locus.DirectLauncher`; the pool and the kept homes the owners read are
  a stub the test sets, which keeps its homes through the same launcher.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Locus.Backends.{Backend, LeaseSweeper, Owners}
  alias Prima.LocusBackends

  @athanor "ath_owners"
  @idle "exec cat >/dev/null"
  @home "vlt_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1b"

  defmodule Stub do
    @moduledoc false
    # The pool a test sets (an answer, or `:hang` for a launcher that
    # never answers) and kept homes under the test's root, through the
    # direct launcher.
    def pool_stats(agent, "backends") do
      case Agent.get(agent, & &1.pool) do
        :hang -> Process.sleep(:infinity)
        answer -> answer
      end
    end

    def home_ensure(agent, id), do: Locus.DirectLauncher.home_ensure(root(agent), id)
    # A measure the test makes fail stands for one the keeper could not
    # take over the whole home.
    def home_measure(agent, id) do
      case Agent.get(agent, &Map.get(&1, :measure)) do
        :fail -> {:error, {:refused, "internal"}}
        _ -> Locus.DirectLauncher.home_measure(root(agent), id)
      end
    end

    def home_list(agent), do: Locus.DirectLauncher.home_list(root(agent))
    def home_reset(agent, id), do: Locus.DirectLauncher.home_reset(root(agent), id)
    def home_retire(agent, id), do: Locus.DirectLauncher.home_retire(root(agent), id)

    defp root(agent), do: [kept_root: Agent.get(agent, & &1.kept_root)]
  end

  setup do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    root = Path.join(System.tmp_dir!(), "locus_kept_#{Prima.Hex.short()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    stub = start_supervised!({Agent, fn -> %{pool: pool(4), kept_root: root} end}, id: :stub)
    clock = start_supervised!({Agent, fn -> 1_000_000 end}, id: :clock)
    {:ok, supervisor: supervisor, stub: stub, clock: clock, root: root}
  end

  defp pool(size, quarantined \\ 0),
    do: {:ok, %{size: size, free: size - quarantined, quarantined: quarantined}}

  defp set_pool(%{stub: stub}, answer), do: Agent.update(stub, &%{&1 | pool: answer})

  defp start_owners(context, opts \\ []) do
    %{supervisor: supervisor, stub: stub, clock: clock, root: root} = context

    start_supervised!(
      {Owners,
       Keyword.merge(
         [
           boot: "bb_owners",
           launcher: Stub,
           launcher_server: stub,
           supervisor: supervisor,
           clock: fn -> Agent.get(clock, & &1) end,
           stop_grace_ms: 200,
           pool_timeout_ms: 500,
           memory_bytes: 268_435_456,
           bounds: [restart_backoff_ms: [300, 600], crash_window_ms: 60_000, max_crashes: 3],
           session_opts: [
             launcher: Locus.DirectLauncher,
             launcher_server: [kept_root: root],
             release_timeout_ms: 5_000
           ]
         ],
         opts
       )}
    )
  end

  defp advance(%{clock: clock}, ms), do: Agent.update(clock, &(&1 + ms))

  # A control message at the next sequence of generation `g`.
  defp control(owners, g, message, open_env \\ nil) do
    fields = %{
      generation: g,
      seq: System.unique_integer([:positive, :monotonic]),
      cyfr_boot: "boot_test",
      boot: "bb_owners",
      ts: 0
    }

    Owners.control(owners, fields, message, open_env)
  end

  defp program(name, command, opts \\ []) do
    Map.merge(
      %{
        name: name,
        command: command,
        login_command: nil,
        env: %{},
        home: :scratch,
        memory_bytes: nil,
        home_max_bytes: nil
      },
      Map.new(opts)
    )
  end

  # A sync of `server` at `(g, e)` defining `programs`, their environment
  # opened as given.
  defp sync(owners, server, {g, e}, programs, opts \\ []) do
    message = %{
      type: :sync,
      owner: %{athanor: @athanor, server: server},
      e: e,
      lease_ms: Keyword.get(opts, :lease_ms, 30_000),
      idle_ms: Keyword.get(opts, :idle_ms, 600_000),
      programs:
        for(
          p <- programs,
          do: p |> Map.delete(:env) |> Map.put(:env_names, Map.keys(p.env))
        ),
      sealed: "c2VhbGVk"
    }

    env = Map.new(programs, &{&1.name, &1.env})
    control(owners, g, message, fn -> {:ok, env} end)
  end

  defp idle_programs(count), do: for(i <- 1..count, do: program("b#{i}", @idle))

  defp invoke(server, {g, e}),
    do: %{athanor: @athanor, server: server, generation: g, epoch: e}

  defp open(owners, server, version, program, opts \\ []) do
    message = %{
      type: :open,
      owner: %{athanor: @athanor, server: server},
      e: elem(version, 1),
      program: program,
      home_id: Keyword.get(opts, :home_id),
      key: Keyword.get(opts, :key, "k"),
      mode: Keyword.get(opts, :mode, :run),
      argv: Keyword.get(opts, :argv, [])
    }

    Owners.open(owners, invoke(server, version), message)
  end

  defp session_pid(owners, server, version, id) do
    {:ok, pid, _secrets} = Owners.session(owners, invoke(server, version), id)
    pid
  end

  defp lines(pid, after_seq \\ 0, n) do
    wait_until(
      fn -> length(Backend.recv(pid, after_seq, 1_000).lines) >= n end,
      10_000
    )

    Enum.map(Backend.recv(pid, after_seq, 0).lines, & &1.text)
  end

  defp held(owners), do: :sys.get_state(owners).owners

  defp status(owners, server) do
    {:ok, %{owners: [owner]}} =
      control(owners, 1, %{type: :status, owners: [%{athanor: @athanor, server: server}]})

    owner
  end

  describe "the version rules" do
    test "a sync lower, equal or higher than the held version, by the version rules; nothing starts",
         ctx do
      owners = start_owners(ctx)
      a = [program("alpha", @idle, env: %{"TOKEN" => "secret-token-a"})]
      b = [program("beta", @idle)]

      assert {:ok, %{status: :running, programs: [%{name: "alpha", status: :idle}]}} =
               sync(owners, "srv", {2, 5}, a)

      assert DynamicSupervisor.count_children(ctx.supervisor).active == 0

      for {version, programs, expected} <- [
            {{2, 4}, a, {:error, :stale_epoch}},
            {{2, 1}, b, {:error, :stale_epoch}},
            {{2, 5}, b, {:error, :conflict}},
            {{2, 5}, a, :held}
          ] do
        case expected do
          :held ->
            assert {:ok, %{status: :running, programs: [%{name: "alpha"}]}} =
                     sync(owners, "srv", version, programs)

          refusal ->
            assert refusal == sync(owners, "srv", version, programs), inspect(version)
        end
      end

      [%{idle_ms: 600_000}] = Map.values(held(owners))

      assert {:ok, %{programs: [%{name: "beta"}]}} = sync(owners, "srv", {2, 6}, b)
      assert {:error, :stale_epoch} = Owners.admit(owners, invoke("srv", {2, 5}))
      assert :ok = Owners.admit(owners, invoke("srv", {2, 6}))
      assert {:error, :epoch_ahead} = Owners.admit(owners, invoke("srv", {2, 7}))
      assert {:error, :epoch_ahead} = Owners.admit(owners, invoke("srv", {3, 1}))
      assert {:error, :unknown_owner} = Owners.admit(owners, invoke("other", {2, 6}))

      assert {:ok, _} = sync(owners, "srv", {3, 1}, a)
      wait_until(fn -> map_size(held(owners)) == 1 end, 5_000)
    end

    test "an equal sync while the owner drains is lapsed; with nothing left it is admitted anew",
         ctx do
      owners = start_owners(ctx, stop_grace_ms: 3_000)
      # A session that outlives its term signal holds the drain for its grace.
      a = [program("alpha", "trap '' TERM; while :; do sleep 1; done")]

      assert {:ok, _} = sync(owners, "srv", {1, 1}, a, lease_ms: 1_000)
      assert {:ok, _} = open(owners, "srv", {1, 1}, "alpha")
      advance(ctx, 1_000)
      :ok = LeaseSweeper.sweep(owners)

      assert {:error, :lapsed} = sync(owners, "srv", {1, 1}, a)
      assert {:error, :lapsed} = Owners.admit(owners, invoke("srv", {1, 1}))

      wait_until(fn -> held(owners) == %{} end, 10_000)
      assert {:ok, _} = sync(owners, "srv", {1, 1}, a)
    end

    test "an environment that is not the definitions' is refused before anything is retired",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "srv", {1, 1}, [program("alpha", @idle, env: %{"A" => "x"})])

      message = %{
        type: :sync,
        owner: %{athanor: @athanor, server: "srv"},
        e: 2,
        lease_ms: 30_000,
        idle_ms: 60_000,
        programs: [
          program("alpha", @idle) |> Map.delete(:env) |> Map.put(:env_names, ["A"])
        ],
        sealed: "c2VhbGVk"
      }

      for opened <- [
            fn -> :error end,
            fn -> {:ok, %{}} end,
            fn -> {:ok, %{"alpha" => %{"B" => "x"}}} end,
            fn -> {:ok, %{"alpha" => %{"A" => 1}}} end,
            fn -> {:ok, %{"alpha" => %{"A" => "x"}, "beta" => %{}}} end
          ] do
        assert {:error, :bad_request} = control(owners, 1, message, opened)
      end

      assert :ok = Owners.admit(owners, invoke("srv", {1, 1}))
    end

    test "a control message at or below the high-water mark is stale", ctx do
      owners = start_owners(ctx)
      renew = %{type: :renew, lease_ms: 1_000, owners: []}
      fields = %{generation: 4, seq: 7, cyfr_boot: "b", boot: "bb_owners", ts: 0}

      assert :ok = Owners.fresh(owners, fields)
      assert {:ok, _} = Owners.control(owners, fields, renew)
      assert {:error, :stale_control} = Owners.fresh(owners, fields)
      assert {:error, :stale_control} = Owners.control(owners, fields, renew)
      assert {:error, :stale_control} = Owners.control(owners, %{fields | seq: 6}, renew)
      assert {:ok, _} = Owners.control(owners, %{fields | generation: 5, seq: 0}, renew)
    end

    test "the programs one sync may define are bounded", ctx do
      owners = start_owners(ctx)
      max = LocusBackends.max_programs()

      assert {:error, :bad_request} = sync(owners, "srv", {1, 1}, idle_programs(max + 1))
      assert {:ok, %{programs: programs}} = sync(owners, "srv", {1, 2}, idle_programs(max))
      assert length(programs) == max
    end
  end

  describe "the uid pool" do
    test "a scratch open past the pool is capacity, a pool not answered unavailable", ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))

      set_pool(ctx, pool(1))
      assert {:ok, %{resumed: false}} = open(owners, "a", {1, 1}, "b1", key: "one")
      assert {:error, :capacity} = open(owners, "a", {1, 1}, "b1", key: "two")

      # The quarantined uids are no uids to hold.
      set_pool(ctx, pool(2, 1))
      assert {:error, :capacity} = open(owners, "a", {1, 1}, "b1", key: "two")

      set_pool(ctx, {:error, {:launcher_unavailable, :timeout}})
      assert {:error, :unavailable} = open(owners, "a", {1, 1}, "b1", key: "two")

      assert {:error, :unavailable} =
               control(owners, 1, %{type: :hello, g: 1, cyfr_boot: "boot_test"})

      set_pool(ctx, pool(2))
      assert {:ok, %{resumed: false}} = open(owners, "a", {1, 1}, "b1", key: "two")

      assert {:ok, %{boot: "bb_owners", pool: %{size: 2, free: 2}}} =
               control(owners, 1, %{type: :hello, g: 1, cyfr_boot: "boot_test"})
    end

    test "a pool read that never answers is unavailable within its bound, and the table answers meanwhile",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      set_pool(ctx, :hang)

      pending = Task.async(fn -> open(owners, "a", {1, 1}, "b1") end)
      wait_until(fn -> map_size(:sys.get_state(owners).pending) == 1 end, 5_000)
      assert Owners.boot(owners) == "bb_owners"
      assert :ok = Owners.admit(owners, invoke("a", {1, 1}))
      assert :ok = Owners.sweep(owners)

      assert {:error, :unavailable} = Task.await(pending)
    end

    test "a retired owner holds its uids until its sessions stop, and frees each once", ctx do
      owners = start_owners(ctx)
      set_pool(ctx, pool(1))
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, _} = open(owners, "a", {1, 1}, "b1")

      release = %{type: :release, owners: [%{athanor: @athanor, server: "a", e: 1}]}
      assert {:ok, %{released: [%{server: "a", g: 1, e: 1}]}} = control(owners, 1, release)
      assert {:ok, %{released: []}} = control(owners, 1, release)

      assert {:ok, _} = sync(owners, "b", {1, 1}, idle_programs(1))
      wait_until(fn -> map_size(held(owners)) == 1 end, 5_000)

      assert {:ok, _} = open(owners, "b", {1, 1}, "b1", key: "one")
      assert {:error, :capacity} = open(owners, "b", {1, 1}, "b1", key: "two")
    end
  end

  describe "sessions" do
    test "an open attaches by its key while the process runs, and starts it again once it ended",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("cat", "exec cat")])

      assert {:ok, %{status: :running, session: first, resumed: false, pty: false}} =
               open(owners, "a", {1, 1}, "cat")

      assert {:ok, %{session: ^first, resumed: true}} = open(owners, "a", {1, 1}, "cat")
      assert {:ok, %{session: other, resumed: false}} = open(owners, "a", {1, 1}, "cat", key: "b")
      assert other != first

      pid = session_pid(owners, "a", {1, 1}, first)
      :ok = Backend.close(pid)
      assert %{running: false} = Backend.recv(pid, 0, 0)

      assert {:ok, %{session: again, resumed: false}} = open(owners, "a", {1, 1}, "cat")
      assert again != first

      # The ended session is still answered, as ended.
      assert {:ok, ^pid, _} = Owners.session(owners, invoke("a", {1, 1}), first)

      assert {:error, :unknown_session} =
               Owners.session(owners, invoke("a", {1, 1}), "ss_" <> String.duplicate("f", 32))

      assert {:error, :unknown_program} = open(owners, "a", {1, 1}, "nope")
    end

    test "an open's arguments are the command's own, whatever they hold", ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("args", ~s(printf '%s\\n'))])

      assert {:ok, %{session: id}} =
               open(owners, "a", {1, 1}, "args", argv: ["a b", "$HOME", "'quoted'"])

      assert lines(session_pid(owners, "a", {1, 1}, id), 3) == ["a b", "$HOME", "'quoted'"]
    end

    test "an open must have its program's shape", ctx do
      owners = start_owners(ctx)

      programs = [
        program("scratch", @idle, login_command: "echo login"),
        program("kept", @idle, home: :kept),
        program("signs", @idle, home: :kept, login_command: "echo login")
      ]

      assert {:ok, _} = sync(owners, "a", {1, 1}, programs)
      v = {1, 1}

      for {name, opts} <- [
            {"kept", []},
            {"scratch", [home_id: @home]},
            {"scratch", [mode: :sign_in]},
            {"kept", [home_id: @home, mode: :sign_in]},
            {"signs", [home_id: @home, mode: :sign_in, argv: ["--x"]]}
          ] do
        assert {:error, :bad_request} = open(owners, "a", v, name, opts), inspect({name, opts})
      end

      assert {:ok, %{pty: true, resumed: false}} =
               open(owners, "a", v, "signs", home_id: @home, mode: :sign_in)
    end

    test "a crash holds the next start back by its backoff, and the last crash fails the program until a new version",
         ctx do
      owners = start_owners(ctx)
      crash = [program("crash", "exit 1")]
      assert {:ok, _} = sync(owners, "a", {1, 1}, crash)

      crash_once = fn ->
        assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "crash")
        pid = session_pid(owners, "a", {1, 1}, id)
        wait_until(fn -> Backend.recv(pid, 0, 0).running == false end, 10_000)
        wait_until(fn -> hd(Map.values(held(owners))).programs["crash"].restarts > 0 end, 5_000)
      end

      crash_once.()

      # Within the backoff, the open waits it out before the process starts.
      started = System.monotonic_time(:millisecond)
      assert {:ok, _} = open(owners, "a", {1, 1}, "crash")
      assert System.monotonic_time(:millisecond) - started >= 250

      wait_until(fn -> hd(Map.values(held(owners))).programs["crash"].restarts == 2 end, 10_000)
      advance(ctx, 1_000)
      crash_once.()

      assert {:error, :program_failed} = open(owners, "a", {1, 1}, "crash")

      assert [%{name: "crash", status: :failed, restarts: 3, error: error}] =
               status(owners, "a").programs

      assert error =~ "code=1"

      assert {:ok, %{programs: [%{status: :idle}]}} = sync(owners, "a", {1, 2}, crash)
    end

    test "a key's crashes fail that key alone: another key of the program still opens", ctx do
      owners = start_owners(ctx)
      crash = [program("crash", "exit 1")]
      assert {:ok, _} = sync(owners, "a", {1, 1}, crash)

      for _ <- 1..3 do
        advance(ctx, 1_000)
        assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "crash", key: "bad")
        pid = session_pid(owners, "a", {1, 1}, id)
        wait_until(fn -> Backend.recv(pid, 0, 0).running == false end, 10_000)
      end

      wait_until(fn -> hd(Map.values(held(owners))).programs["crash"].restarts == 3 end, 10_000)
      assert {:error, :program_failed} = open(owners, "a", {1, 1}, "crash", key: "bad")
      assert {:ok, %{resumed: false}} = open(owners, "a", {1, 1}, "crash", key: "good")
      assert [%{status: :failed}] = status(owners, "a").programs
    end

    test "an owner holds its bound of sessions: the oldest ended one forgotten, capacity with all running",
         ctx do
      owners = start_owners(ctx)
      set_pool(ctx, pool(64))
      max = LocusBackends.max_sessions()

      assert {:ok, _} =
               sync(owners, "a", {1, 1}, [program("echo", "echo hi"), program("cat", @idle)])

      ids =
        for i <- 1..max do
          {:ok, %{session: id}} = open(owners, "a", {1, 1}, "echo", key: "k#{i}")
          id
        end

      [first | _] = ids

      wait_until(
        fn ->
          Enum.all?(hd(Map.values(held(owners))).sessions, fn {_id, s} ->
            not s.running and not s.slot
          end)
        end,
        10_000
      )

      assert {:ok, %{session: _}} = open(owners, "a", {1, 1}, "cat", key: "new")
      assert {:error, :unknown_session} = Owners.session(owners, invoke("a", {1, 1}), first)

      assert {:ok, _} = sync(owners, "b", {1, 1}, [program("cat", @idle)])

      for i <- 1..max,
          do: assert({:ok, _} = open(owners, "b", {1, 1}, "cat", key: "k#{i}"))

      assert {:error, :capacity} = open(owners, "b", {1, 1}, "cat", key: "one-more")
    end
  end

  describe "leases and idleness, through a driven sweep" do
    test "a lease that passes lapses the owner: lapsed while it retires, its sessions ended, then gone",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1), lease_ms: 1_000)
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      pid = session_pid(owners, "a", {1, 1}, id)

      advance(ctx, 999)
      :ok = LeaseSweeper.sweep(owners)
      assert :ok = Owners.admit(owners, invoke("a", {1, 1}))

      advance(ctx, 1)
      :ok = LeaseSweeper.sweep(owners)
      assert {:error, :lapsed} = Owners.admit(owners, invoke("a", {1, 1}))
      assert {:error, :lapsed} = open(owners, "a", {1, 1}, "b1")

      wait_until(
        fn -> Owners.admit(owners, invoke("a", {1, 1})) == {:error, :unknown_owner} end,
        5_000
      )

      refute Process.alive?(pid)
      assert DynamicSupervisor.count_children(ctx.supervisor).active == 0

      # Forgotten, the owner is not made again by an open: it is unknown,
      # and nothing starts.
      assert {:error, :unknown_owner} = open(owners, "a", {1, 1}, "b2")
      assert DynamicSupervisor.count_children(ctx.supervisor).active == 0
    end

    test "a released owner serves no open: lapsed while it retires, unknown once gone, nothing started",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      pid = session_pid(owners, "a", {1, 1}, id)

      release = %{type: :release, owners: [%{athanor: @athanor, server: "a", e: 1}]}
      assert {:ok, %{released: [%{server: "a"}]}} = control(owners, 1, release)

      assert open(owners, "a", {1, 1}, "b2") in [{:error, :lapsed}, {:error, :unknown_owner}]

      wait_until(
        fn -> Owners.admit(owners, invoke("a", {1, 1})) == {:error, :unknown_owner} end,
        5_000
      )

      assert {:error, :unknown_owner} = open(owners, "a", {1, 1}, "b3")
      # A release unroutes the owner at once and stops its sessions after.
      wait_until(fn -> not Process.alive?(pid) end, 5_000)
      assert DynamicSupervisor.count_children(ctx.supervisor).active == 0
    end

    test "a session ended by idle leaves its owner held: an open inside the lease is served",
         ctx do
      # An emptied pool is not a released owner: the image suite's release
      # is the service's word for it, never the absence of processes.
      owners = start_owners(ctx)

      assert {:ok, _} =
               sync(owners, "a", {1, 1}, idle_programs(1), idle_ms: 1_000, lease_ms: 5_000)

      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      pid = session_pid(owners, "a", {1, 1}, id)

      advance(ctx, 1_000)
      :ok = LeaseSweeper.sweep(owners)
      # Its session has ended (its record stays readable as a tombstone).
      wait_until(fn -> match?(%{running: false}, Backend.recv(pid, 0, 0)) end, 5_000)

      assert :ok = Owners.admit(owners, invoke("a", {1, 1}))
      assert {:ok, %{session: _, resumed: false}} = open(owners, "a", {1, 1}, "b1")
    end

    test "a session no send and no recv used within the idle period ends; the next open starts it again",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1), idle_ms: 1_000)
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      pid = session_pid(owners, "a", {1, 1}, id)

      advance(ctx, 999)
      :ok = LeaseSweeper.sweep(owners)
      assert %{running: true} = Backend.recv(pid, 0, 0)

      # The recv was a use: a full period from it.
      advance(ctx, 999)
      :ok = LeaseSweeper.sweep(owners)
      assert %{running: true} = Backend.recv(pid, 0, 0)

      advance(ctx, 1_000)
      :ok = LeaseSweeper.sweep(owners)
      wait_until(fn -> Backend.recv(pid, 0, 0).running == false end, 5_000)

      assert {:ok, %{session: again, resumed: false}} = open(owners, "a", {1, 1}, "b1")
      assert again != id
      assert [%{restarts: 0, error: nil}] = status(owners, "a").programs
    end
  end

  describe "kept homes" do
    test "the sessions of one entry share its home, and take no uid of the pool", ctx do
      owners = start_owners(ctx)
      set_pool(ctx, pool(0))
      kept = [program("kept", ~s(echo "$HOME"; exec cat), home: :kept)]
      assert {:ok, _} = sync(owners, "a", {1, 1}, kept)

      assert {:ok, %{session: one}} = open(owners, "a", {1, 1}, "kept", home_id: @home, key: "1")
      assert {:ok, %{session: two}} = open(owners, "a", {1, 1}, "kept", home_id: @home, key: "2")

      home = Path.join(ctx.root, @home)
      assert lines(session_pid(owners, "a", {1, 1}, one), 1) == [home]
      assert lines(session_pid(owners, "a", {1, 1}, two), 1) == [home]

      # A file one session writes outlives it.
      File.write!(Path.join(home, "kept.txt"), "kept")

      assert [%{home: :kept, sessions: 2, over_cap: false}] = status(owners, "a").programs
    end

    test "a home at its bound ends its sessions and refuses opens until a reset", ctx do
      owners = start_owners(ctx, measure_interval_ms: 10_000)
      fill = ~s(head -c 4096 /dev/zero > "$HOME/fill"; echo filled; exec cat)
      kept = [program("kept", fill, home: :kept, home_max_bytes: 1_024)]
      assert {:ok, _} = sync(owners, "a", {1, 1}, kept)

      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "kept", home_id: @home)
      pid = session_pid(owners, "a", {1, 1}, id)
      assert lines(pid, 1) == ["filled"]

      :ok = LeaseSweeper.sweep(owners)
      wait_until(fn -> Backend.recv(pid, 1, 0).running == false end, 10_000)

      assert {:error, :home_over_cap} = open(owners, "a", {1, 1}, "kept", home_id: @home)

      assert [%{over_cap: true, home_bytes: bytes, restarts: 0}] = status(owners, "a").programs
      assert bytes >= 4_096

      reset = %{type: :home, op: :reset, athanor: @athanor, home_id: @home}
      assert {:ok, %{home_id: @home, state: :empty}} = control(owners, 1, reset)
      assert File.ls!(Path.join(ctx.root, @home)) == ["tmp"]

      assert {:ok, %{resumed: false}} =
               open(owners, "a", {1, 1}, "kept", home_id: @home, key: "after")
    end

    test "a measure that fails ends the home's sessions and refuses opens until a reset", ctx do
      owners = start_owners(ctx, measure_interval_ms: 10_000)
      kept = [program("kept", ~s(echo up; exec cat), home: :kept, home_max_bytes: 1_048_576)]
      assert {:ok, _} = sync(owners, "a", {1, 1}, kept)

      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "kept", home_id: @home)
      pid = session_pid(owners, "a", {1, 1}, id)
      assert lines(pid, 1) == ["up"]

      Agent.update(ctx.stub, &Map.put(&1, :measure, :fail))
      :ok = LeaseSweeper.sweep(owners)
      wait_until(fn -> Backend.recv(pid, 1, 0).running == false end, 10_000)
      assert {:error, :home_over_cap} = open(owners, "a", {1, 1}, "kept", home_id: @home)

      Agent.update(ctx.stub, &Map.delete(&1, :measure))
      reset = %{type: :home, op: :reset, athanor: @athanor, home_id: @home}
      assert {:ok, %{state: :empty}} = control(owners, 1, reset)
      assert {:ok, _} = open(owners, "a", {1, 1}, "kept", home_id: @home, key: "after")
    end

    test "a session whose home's folder vanished is ended, and homes lists what is kept", ctx do
      owners = start_owners(ctx, measure_interval_ms: 10_000)
      kept = [program("kept", ~s(echo up; exec cat), home: :kept)]
      assert {:ok, _} = sync(owners, "a", {1, 1}, kept)
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "kept", home_id: @home)
      pid = session_pid(owners, "a", {1, 1}, id)
      assert lines(pid, 1) == ["up"]

      assert {:ok, %{homes: [@home]}} = control(owners, 1, %{type: :homes})

      File.rm_rf!(Path.join(ctx.root, @home))
      :ok = LeaseSweeper.sweep(owners)
      wait_until(fn -> Backend.recv(pid, 1, 0).running == false end, 10_000)
      assert {:ok, %{homes: []}} = control(owners, 1, %{type: :homes})
    end

    test "a home already past its bound refuses the open before anything starts", ctx do
      owners = start_owners(ctx)
      home = Path.join(ctx.root, @home)
      File.mkdir_p!(Path.join(home, "tmp"))
      File.write!(Path.join(home, "big"), :binary.copy("x", 2_048))

      kept = [program("kept", @idle, home: :kept, home_max_bytes: 1_024)]
      assert {:ok, _} = sync(owners, "a", {1, 1}, kept)
      assert {:error, :home_over_cap} = open(owners, "a", {1, 1}, "kept", home_id: @home)
      assert DynamicSupervisor.count_children(ctx.supervisor).active == 0
    end

    test "a home's retirement ends its sessions and removes it", ctx do
      owners = start_owners(ctx)
      kept = [program("kept", @idle, home: :kept)]
      assert {:ok, _} = sync(owners, "a", {1, 1}, kept)
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "kept", home_id: @home)
      pid = session_pid(owners, "a", {1, 1}, id)

      retire = %{type: :home, op: :retire, athanor: @athanor, home_id: @home}
      assert {:ok, %{home_id: @home, state: :absent}} = control(owners, 1, retire)
      assert %{running: false} = Backend.recv(pid, 0, 0)
      refute File.exists?(Path.join(ctx.root, @home))
    end

    test "a home the launcher cannot keep is unavailable", ctx do
      owners = start_owners(ctx)
      Agent.update(ctx.stub, &%{&1 | kept_root: nil})
      kept = [program("kept", @idle, home: :kept)]
      assert {:ok, _} = sync(owners, "a", {1, 1}, kept)
      assert {:error, :unavailable} = open(owners, "a", {1, 1}, "kept", home_id: @home)

      reset = %{type: :home, op: :reset, athanor: @athanor, home_id: @home}
      assert {:error, :unavailable} = control(owners, 1, reset)
    end
  end

  describe "renew, release, reconcile and status" do
    test "renew extends an owner at exactly (g, e) with a live lease; every other is unknown",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {3, 1}, idle_programs(1), lease_ms: 1_000)
      assert {:ok, _} = sync(owners, "b", {3, 2}, idle_programs(1), lease_ms: 1_000)

      renew = fn g, entries ->
        control(owners, g, %{
          type: :renew,
          lease_ms: 5_000,
          owners: for({server, e} <- entries, do: %{athanor: @athanor, server: server, e: e})
        })
      end

      assert {:ok, %{renewed: [%{server: "a", e: 1, state: :running}], unknown: unknown}} =
               renew.(3, [{"a", 1}, {"b", 1}, {"c", 1}])

      assert Enum.map(unknown, &{&1.server, &1.e}) == [{"b", 1}, {"c", 1}]

      advance(ctx, 1_000)

      assert {:ok, %{renewed: [%{server: "a"}], unknown: [%{server: "b"}]}} =
               renew.(3, [{"a", 1}, {"b", 2}])

      assert {:ok, %{renewed: [], unknown: [_]}} = renew.(4, [{"a", 1}])
    end

    test "release retires each owner at or below (g, e); reconcile each not at g and its kept e",
         ctx do
      owners = start_owners(ctx)

      assert {:ok, _} = sync(owners, "z", {2, 1}, idle_programs(1))
      assert {:ok, _} = sync(owners, "x", {3, 1}, idle_programs(1))
      assert {:ok, _} = sync(owners, "y", {3, 2}, idle_programs(1))
      assert {:ok, _} = sync(owners, "w", {3, 5}, idle_programs(1))

      entry = fn server, e -> %{athanor: @athanor, server: server, e: e} end

      assert {:ok, %{released: released}} =
               control(owners, 3, %{type: :release, owners: [entry.("y", 1), entry.("w", 5)]})

      assert Enum.map(released, &{&1.server, &1.g, &1.e}) == [{"w", 3, 5}]

      assert {:ok, %{released: released}} =
               control(owners, 3, %{type: :reconcile, keep: [entry.("x", 1), entry.("y", 9)]})

      assert released |> Enum.map(&{&1.server, &1.g, &1.e}) |> Enum.sort() ==
               [{"y", 3, 2}, {"z", 2, 1}]

      assert :ok = Owners.admit(owners, invoke("x", {3, 1}))

      for {server, version} <- [{"y", {3, 2}}, {"z", {2, 1}}, {"w", {3, 5}}],
          do: assert({:error, :unknown_owner} = Owners.admit(owners, invoke(server, version)))
    end

    test "status reports each named owner present, its programs as their sessions do", ctx do
      owners = start_owners(ctx)

      programs = [
        program("cat", ~s(echo "noise secret-token-x" >&2; exec cat),
          env: %{"TOKEN" => "secret-token-x"}
        ),
        program("kept", ~s(echo "a line of the home's" >&2; exec cat), home: :kept)
      ]

      assert {:ok, _} = sync(owners, "a", {1, 1}, programs, lease_ms: 10_000)
      assert {:ok, _} = open(owners, "a", {1, 1}, "cat")
      assert {:ok, _} = open(owners, "a", {1, 1}, "kept", home_id: @home)
      advance(ctx, 2_500)

      wait_until(
        fn ->
          [cat, kept] = status(owners, "a").programs
          cat.stderr_tail =~ "noise" and kept.stderr_bytes > 0
        end,
        10_000
      )

      assert {:ok, %{owners: [owner]}} =
               control(owners, 1, %{
                 type: :status,
                 owners: [%{athanor: @athanor, server: "a"}, %{athanor: @athanor, server: "no"}]
               })

      assert %{server: "a", g: 1, e: 1, state: :running, lease_ms_left: 7_500} = owner

      assert [
               %{
                 name: "cat",
                 status: :running,
                 restarts: 0,
                 error: nil,
                 home: :scratch,
                 home_bytes: nil,
                 over_cap: false,
                 sessions: 1,
                 stderr_tail: tail
               },
               %{
                 name: "kept",
                 status: :running,
                 home: :kept,
                 home_bytes: nil,
                 sessions: 1,
                 stderr_tail: nil,
                 stderr_bytes: kept_bytes
               }
             ] = owner.programs

      # A kept program's stderr is its home's, the person's: its length alone.
      assert kept_bytes == byte_size("a line of the home's\n")

      assert tail =~ "noise [REDACTED]"
      assert {:ok, _body} = LocusBackends.encode_answer(:status, %{owners: [owner]})
    end
  end
end
